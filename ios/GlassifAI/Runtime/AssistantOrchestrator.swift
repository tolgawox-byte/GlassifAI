import Foundation
import UIKit

/// A web source shown as a card under the answer. Only data the search
/// provider actually returned is kept; nothing is invented.
struct WebSource: Identifiable, Equatable {
  let id = UUID()
  let title: String
  let url: URL
  let snippet: String?
  let fetchedAt: Date
  let publishedAt: String?

  var host: String {
    (url.host ?? url.absoluteString).replacingOccurrences(of: "www.", with: "")
  }

  static func == (lhs: WebSource, rhs: WebSource) -> Bool { lhs.url == rhs.url }
}

/// What the assistant is visibly doing right now, derived from real task state.
enum AssistantActivity: Equatable {
  case seeing
  case searching
  case thinking
}

/// Routes every delegated request to the right capability, runs it with task
/// tracking and cancellation, and hands a speakable result back to the voice
/// session. Plain conversation never reaches this type — the voice model
/// answers it directly.
@MainActor
final class AssistantOrchestrator: ObservableObject {
  static let shared = AssistantOrchestrator()

  let ledger = TaskLedger()
  let context = ConversationContext()

  @Published private(set) var sources: [WebSource] = []
  @Published private(set) var typedAnswer: String?
  @Published private(set) var typedQuestion: String?
  @Published private(set) var lastWebStatus = "Not used yet"
  @Published private(set) var lastError: String?
  @Published private(set) var activity: AssistantActivity?

  /// The camera source currently selected in the app (persisted setting).
  func captureSource() -> CaptureSource {
    CaptureSource(rawValue: UserDefaults.standard.string(forKey: CaptureSource.defaultsKey) ?? "")
      ?? .iPhoneCamera
  }

  private(set) var sessionID: UUID?
  private(set) var turnID = 0
  private var running: [UUID: Task<Void, Never>] = [:]
  private var handledHandoffs = Set<String>()
  private var awaitingSpeech: UUID?
  /// Models whose requests rejected the hosted web-search tool in this run.
  private var hostedSearchUnsupported = Set<String>()
  private let client = ResponsesClient()

  private var availableModels: [String] { ChatGPTAuthSession.shared.availableModels }

  private init() {}

  // MARK: Session lifecycle

  func beginVoiceSession() -> UUID {
    cancelAll(reason: "new voice session", voiceOnly: true)
    let id = UUID()
    sessionID = id
    handledHandoffs.removeAll()
    return id
  }

  func endVoiceSession() {
    cancelAll(reason: "voice session ended", voiceOnly: true)
    sessionID = nil
    awaitingSpeech = nil
  }

  func noteUserTurn(_ text: String) {
    turnID += 1
    context.addTurn(.user, text)
  }

  func noteAssistantTurn(_ text: String) {
    context.addTurn(.assistant, text)
  }

  /// Called when the voice model starts speaking; closes the T5 milestone of
  /// the most recently delivered task.
  func noteAssistantSpeaking() {
    guard let id = awaitingSpeech else { return }
    awaitingSpeech = nil
    ledger.update(id) { record in
      if record.timeline.speechStarted == nil, let delivered = record.timeline.delivered,
         Date().timeIntervalSince(delivered) < 20 {
        record.timeline.speechStarted = Date()
      }
    }
  }

  func clearSources() {
    sources = []
    typedAnswer = nil
    typedQuestion = nil
  }

  /// Deletes every piece of conversation data held in memory.
  func wipeConversationData() {
    cancelAll(reason: "privacy wipe", voiceOnly: false)
    context.reset()
    ledger.clear()
    clearSources()
    lastError = nil
    lastWebStatus = "Not used yet"
  }

  // MARK: Entry points

  /// Handles a `delegation.created` from the voice model. `deliver` sends the
  /// speakable result back over the realtime sideband and reports success.
  func handleDelegation(handoffID: String, text: String, deliver: @escaping (String) -> Bool) {
    guard let sessionID else { return }
    // The same delegation can arrive over both the WebRTC data channel and the
    // sideband socket; run it once.
    guard handledHandoffs.insert(handoffID).inserted else { return }

    let envelope = DelegationEnvelopeParser.parse(text)
    if envelope?.command == .cancel {
      let cancelled = cancelAll(reason: "cancelled by user", voiceOnly: false)
      let reply = cancelled.isEmpty
        ? "There was no task in progress to cancel."
        : "The pending task was cancelled. Nothing more will be reported from it."
      _ = deliver(reply)
      return
    }

    // A new request supersedes whatever the assistant was still working on.
    cancelAll(reason: "superseded by a newer request", voiceOnly: true)

    let record = ledger.begin(
      sessionID: sessionID,
      turnID: turnID,
      handoffID: handoffID,
      source: .voiceDelegation,
      request: envelope?.query ?? text)
    let taskID = record.id
    running[taskID] = Task { [weak self] in
      guard let self else { return }
      let outcome = await self.execute(taskID: taskID, envelope: envelope, rawText: text)
      self.finish(taskID: taskID, outcome: outcome, deliver: deliver)
    }
  }

  /// Handles a question typed into the text field. The answer is shown on
  /// screen with its sources; it is not spoken.
  func submitTyped(_ text: String) {
    let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !question.isEmpty else { return }
    cancelAll(reason: "superseded by typed question", voiceOnly: false)
    typedQuestion = question
    typedAnswer = nil
    context.addTurn(.user, question)
    let record = ledger.begin(
      sessionID: sessionID ?? UUID(),
      turnID: turnID,
      handoffID: nil,
      source: .typedInput,
      request: question)
    let taskID = record.id
    running[taskID] = Task { [weak self] in
      guard let self else { return }
      let outcome = await self.execute(taskID: taskID, envelope: nil, rawText: question)
      self.finish(taskID: taskID, outcome: outcome, deliver: nil)
    }
  }

  /// Cancels running tasks; their late results are discarded.
  @discardableResult
  func cancelAll(reason: String, voiceOnly: Bool) -> [UUID] {
    var cancelled: [UUID] = []
    for record in ledger.active where !voiceOnly || record.source == .voiceDelegation {
      ledger.update(record.id) { $0.phase = .cancelled(reason) }
      running[record.id]?.cancel()
      running[record.id] = nil
      cancelled.append(record.id)
    }
    refreshActivity()
    return cancelled
  }

  // MARK: Execution

  private struct Outcome {
    var speakable: String
    var display: String?
    var kind: AssistantTaskKind?
    var sources: [WebSource] = []
    var failed: String?
  }

  private func execute(taskID: UUID, envelope: DelegationEnvelope?, rawText: String) async -> Outcome {
    let camera = captureSource()
    var kind: AssistantTaskKind?
    var query = rawText
    if let envelope, case .task(let requested) = envelope.command {
      kind = requested
      query = envelope.query
      ledger.update(taskID) { $0.kind = requested; $0.routeOrigin = .verifiedEnvelope }
    } else {
      let origin: RouteOrigin = ledger.record(taskID)?.source == .typedInput ? .typedInput : .toolRouting
      ledger.update(taskID) { $0.routeOrigin = origin }
    }

    // Verify the requested route against what the app can actually do now.
    if let requested = kind {
      if requested == .authorizedAction {
        return Outcome(
          speakable: "This app cannot perform actions such as sending messages or emails, purchases, calendar changes, file changes, or deployments. Tell the user honestly that this is not supported yet.",
          kind: requested)
      }
      if requested == .localMemory && !LocalMemoryStore.shared.isEnabled {
        return Outcome(
          speakable: "On-device memory is turned off. The user can enable it in Settings, Memory. Nothing was saved.",
          kind: requested)
      }
      if requested.usesCamera && camera == .off {
        return Outcome(
          speakable: "The camera is turned off in the app, so nothing can be seen right now. The user can switch the camera to Ray-Ban or iPhone.",
          kind: requested)
      }
      if requested.usesWeb && !AssistantPreferences.webSearchEnabled {
        if requested == .visionPlusWeb {
          kind = .vision
          ledger.update(taskID) { $0.kind = .vision }
        } else {
          return Outcome(
            speakable: "Web search is turned off in the app settings, so no live information could be looked up.",
            kind: requested)
        }
      }
    }

    do {
      if kind == .localMemory {
        return try await runMemory(taskID: taskID, query: query)
      }
      if let kind {
        return try await runExecutor(taskID: taskID, kind: kind, query: query, image: kind.usesCamera)
      }
      return try await runToolRouting(taskID: taskID, query: query, camera: camera)
    } catch let error as VisionUnavailable {
      return Outcome(speakable: error.speakable, kind: kind, failed: error.reason)
    } catch let error as ResponsesError {
      if error == .cancelled { return Outcome(speakable: "", kind: kind, failed: "cancelled") }
      return Outcome(
        speakable: error.speakableSummary + " Tell the user briefly and offer to try again.",
        kind: kind,
        failed: error.localizedDescription)
    } catch is CancellationError {
      return Outcome(speakable: "", kind: kind, failed: "cancelled")
    } catch {
      return Outcome(
        speakable: "The request failed. Tell the user briefly and offer to try again.",
        kind: kind,
        failed: LogSanitizer.sanitize(error.localizedDescription))
    }
  }

  private struct VisionUnavailable: Error {
    let reason: String
    let speakable: String
  }

  /// Tool routing: the executor sees the request plus conversation context and
  /// decides itself whether it needs web search or the camera.
  private func runToolRouting(taskID: UUID, query: String, camera: CaptureSource) async throws -> Outcome {
    let webEnabled = AssistantPreferences.webSearchEnabled
    var tools: [[String: Any]] = []
    if camera != .off { tools.append(AssistantTools.lookAtCamera) }
    let result: ResponsesResult
    let hostedModel = ModelSelector.model(for: nil, available: availableModels, needsHostedWebSearch: true)
    if webEnabled, let hostedModel, !hostedSearchUnsupported.contains(hostedModel) {
      do {
        result = try await callModel(
          taskID: taskID, kind: nil, query: query, tools: tools + [AssistantTools.webSearch], image: nil)
      } catch ResponsesError.badRequest(let message) {
        hostedSearchUnsupported.insert(hostedModel)
        NSLog("[AutoLoom] hosted web search rejected for %@: %@", hostedModel, message)
        result = try await callModel(
          taskID: taskID, kind: nil, query: query, tools: tools + [AssistantTools.searchWebFunction], image: nil)
      }
    } else {
      let fallbackTools = webEnabled ? tools + [AssistantTools.searchWebFunction] : tools
      result = try await callModel(taskID: taskID, kind: nil, query: query, tools: fallbackTools, image: nil)
    }

    if let call = result.functionCalls.first(where: { $0.name == AssistantTools.lookAtCameraName }) {
      let arguments = (try? JSONSerialization.jsonObject(with: Data(call.arguments.utf8))) as? [String: Any]
      let wantsWeb = (arguments?["also_search_web"] as? Bool ?? false) && webEnabled
      let visionKind: AssistantTaskKind = wantsWeb ? .visionPlusWeb : .vision
      ledger.update(taskID) { $0.kind = visionKind }
      return try await runExecutor(taskID: taskID, kind: visionKind, query: query, image: true)
    }
    if let call = result.functionCalls.first(where: { $0.name == AssistantTools.searchWebName }) {
      let arguments = (try? JSONSerialization.jsonObject(with: Data(call.arguments.utf8))) as? [String: Any]
      let searchQuery = (arguments?["query"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? query
      ledger.update(taskID) { $0.kind = .webSearch }
      return try await runDirectSearch(taskID: taskID, kind: .webSearch, query: query, searchQueries: [searchQuery], image: nil)
    }
    let inferred: AssistantTaskKind = result.webSearches.isEmpty && result.citations.isEmpty ? .generalChat : .webSearch
    ledger.update(taskID) { $0.kind = inferred }
    return makeOutcome(kind: inferred, query: query, result: result)
  }

  private func runExecutor(taskID: UUID, kind: AssistantTaskKind, query: String, image: Bool) async throws -> Outcome {
    var attachment: (jpeg: Data, info: VisionFrameInfo)?
    if image {
      attachment = try await prepareVisionImage(taskID: taskID)
    }
    guard kind.usesWeb else {
      let result = try await callModel(taskID: taskID, kind: kind, query: query, tools: [], image: attachment?.jpeg)
      return makeOutcome(kind: kind, query: query, result: result)
    }
    let hostedModel = ModelSelector.model(for: kind, available: availableModels, needsHostedWebSearch: true)
    if let hostedModel, !hostedSearchUnsupported.contains(hostedModel) {
      do {
        let result = try await callModel(
          taskID: taskID, kind: kind, query: query, tools: [AssistantTools.webSearch], image: attachment?.jpeg)
        return makeOutcome(kind: kind, query: query, result: result)
      } catch ResponsesError.badRequest(let message) {
        // The hosted tool is not accepted for this model/account: remember it
        // for this run and use the backend search endpoint instead.
        hostedSearchUnsupported.insert(hostedModel)
        NSLog("[AutoLoom] hosted web search rejected for %@: %@", hostedModel, message)
      }
    }
    return try await runDirectSearch(
      taskID: taskID, kind: kind, query: query, searchQueries: [query], image: attachment?.jpeg)
  }

  /// Search through the backend search endpoint, then let the model answer
  /// from those results. Used when the hosted web-search tool is unavailable.
  private func runDirectSearch(
    taskID: UUID,
    kind: AssistantTaskKind,
    query: String,
    searchQueries: [String],
    image: Data?
  ) async throws -> Outcome {
    ledger.update(taskID) { $0.phase = .searching }
    refreshActivity()
    lastWebStatus = "Searching (direct): \(searchQueries.first ?? query)"
    guard let model = ModelSelector.model(for: kind, available: availableModels) else {
      throw ResponsesError.failed("No compatible ChatGPT model is available for this account.")
    }
    let search = try await DirectSearchClient().search(
      queries: searchQueries,
      model: model,
      sessionID: (sessionID ?? UUID()).uuidString)
    try Task.checkCancellation()
    let fetched = Date()
    let rendered = search.output.isEmpty
      ? search.hits.map { "\($0.title ?? $0.url.absoluteString) — \($0.url.absoluteString)\n\($0.snippet ?? "")" }
        .joined(separator: "\n\n")
      : String(search.output.prefix(12_000))
    guard !rendered.isEmpty else {
      lastWebStatus = "Direct search returned no results"
      return Outcome(
        speakable: "The web search returned no results for this request. Tell the user honestly and offer to rephrase.",
        kind: kind,
        failed: "no search results")
    }
    let extra = "Web search results (retrieved \(fetched.formatted(date: .abbreviated, time: .shortened))):\n" +
      UntrustedContent.wrap(rendered, origin: "web search")
    var result = try await callModel(
      taskID: taskID, kind: kind, query: query, tools: [], image: image,
      extraContext: extra, directSearch: true)
    result.completedAt = result.completedAt ?? fetched
    var outcome = makeOutcome(kind: kind, query: query, result: result)
    let hitSources = search.hits.compactMap { hit -> WebSource? in
      guard URLSafety.isPublicWebURL(hit.url) else { return nil }
      return WebSource(
        title: hit.title ?? hit.url.host ?? hit.url.absoluteString,
        url: hit.url,
        snippet: hit.snippet,
        fetchedAt: fetched,
        publishedAt: nil)
    }
    if outcome.sources.isEmpty && !hitSources.isEmpty {
      outcome.sources = Array(hitSources.prefix(8))
      let names = outcome.sources.prefix(3).map(\.host).joined(separator: ", ")
      outcome.speakable = String(result.text.prefix(1_800)) +
        "\n(Sources: \(names). Mention the main source by name; do not read URLs.)"
    }
    lastWebStatus = "OK (direct search) — \(search.hits.count) result(s)"
    return outcome
  }

  private func runMemory(taskID: UUID, query: String) async throws -> Outcome {
    let memory = LocalMemoryStore.shared
    let listing = memory.items.isEmpty
      ? "(empty)"
      : memory.items.map { "- \($0.text)" }.joined(separator: "\n")
    let request = "Current memory list:\n\(listing)\n\nUser request: \(query)"
    let result = try await callModel(
      taskID: taskID, kind: .localMemory, query: request, tools: [], image: nil,
      schema: AssistantTools.memorySchema)
    guard let data = result.text.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return Outcome(speakable: "The memory request could not be processed.", kind: .localMemory, failed: "invalid memory reply")
    }
    let added = (object["add"] as? [String] ?? []).filter { memory.add($0, source: "voice") }
    var forgotten = 0
    for phrase in object["forget"] as? [String] ?? [] {
      forgotten += memory.forget(matching: phrase)
    }
    var reply = object["reply"] as? String ?? "Done."
    if added.isEmpty && forgotten == 0 && reply.isEmpty { reply = "Nothing was changed." }
    return Outcome(speakable: reply, kind: .localMemory)
  }

  private func prepareVisionImage(taskID: UUID) async throws -> (jpeg: Data, info: VisionFrameInfo) {
    ledger.update(taskID) { $0.phase = .capturingFrame }
    refreshActivity()
    let source = captureSource()
    let frameSource: FrameSourceKind = source == .glasses ? .glasses : .iPhone
    let background = UIApplication.shared.applicationState == .background

    guard let frame = await FrameStore.shared.waitForFreshFrame(maxAge: 1.0, timeout: 1.5, source: frameSource) else {
      try Task.checkCancellation()
      throw VisionUnavailable(
        reason: "no fresh frame",
        speakable: "No fresh camera frame is available right now, so nothing can be described. Ask the user to check that the \(frameSource.rawValue) camera is on and pointed at the subject, then try again.")
    }
    let ageMs = Int((frame.ageSeconds * 1_000).rounded())
    ledger.update(taskID) { $0.timeline.frameSelected = Date() }
    let pixelBuffer = frame.pixelBuffer
    let encoded = await Task.detached(priority: .userInitiated) {
      VisionFrameEncoder.encode(pixelBuffer, useCPU: background)
    }.value
    try Task.checkCancellation()
    guard let encoded else {
      throw VisionUnavailable(
        reason: "image encoding failed",
        speakable: "The camera image could not be prepared. Ask the user to try again.")
    }
    let info = VisionFrameInfo(
      source: frame.source.rawValue,
      sourceWidth: frame.width, sourceHeight: frame.height,
      encodedWidth: encoded.width, encodedHeight: encoded.height,
      jpegQuality: encoded.quality, jpegBytes: encoded.jpeg.count,
      frameAgeMs: ageMs, usedStillPhoto: false)
    ledger.update(taskID) {
      $0.timeline.imagePrepared = Date()
      $0.frame = info
    }
    return (encoded.jpeg, info)
  }

  private func callModel(
    taskID: UUID,
    kind: AssistantTaskKind?,
    query: String,
    tools: [[String: Any]],
    image: Data?,
    schema: (name: String, schema: [String: Any])? = nil,
    extraContext: String? = nil,
    directSearch: Bool = false
  ) async throws -> ResponsesResult {
    let usesWeb = tools.contains { ($0["type"] as? String) == "web_search" }
    guard let model = ModelSelector.model(
      for: kind, available: availableModels, needsHostedWebSearch: usesWeb) else {
      throw ResponsesError.failed("No compatible ChatGPT model is available for this account.")
    }
    ledger.update(taskID) {
      $0.model = model
      $0.phase = usesWeb ? .searching : (kind == .deepReasoning ? .reasoning : (image != nil ? .analyzing : .reasoning))
    }
    refreshActivity()

    var content: [[String: Any]] = []
    let background = context.promptContext(memory: LocalMemoryStore.shared.promptItems)
    if !background.isEmpty {
      content.append(["type": "input_text", "text": "Conversation context:\n\(background)"])
    }
    if let extraContext {
      content.append(["type": "input_text", "text": extraContext])
    }
    content.append(["type": "input_text", "text": "Request: \(query)"])
    if let image {
      content.append(["type": "input_image", "image_url": "data:image/jpeg;base64,\(image.base64EncodedString())"])
    }

    var instructions = AssistantInstructions.executor(kind: kind, detectedLanguage: context.detectedLanguage)
    if directSearch {
      instructions += "\nWeb search results are provided in the input. Base current facts only on them, " +
        "name the most relevant source briefly, and say so if they do not answer the request."
    }
    var request = ResponsesClient.Request(
      model: model,
      instructions: instructions,
      input: [["role": "user", "content": content]])
    request.tools = tools
    request.reasoningEffort = ModelSelector.reasoningEffort(for: kind)
    request.verbosity = AssistantPreferences.prefersDetailedAnswers ? "medium" : "low"
    request.timeout = ModelSelector.timeout(for: kind)
    request.jsonSchema = schema
    request.promptCacheKey = sessionID.map { "autoloom-\($0.uuidString)" }

    ledger.update(taskID) { $0.timeline.requestSent = Date() }
    if usesWeb { lastWebStatus = "Searching…" }
    let result = try await client.send(request) { [weak self] progress in
      guard let self else { return }
      switch progress {
      case .requestSent:
        break
      case .firstOutput:
        self.ledger.update(taskID) { record in
          if record.timeline.firstModelOutput == nil { record.timeline.firstModelOutput = Date() }
          if record.phase != .searching { record.phase = .delivering }
        }
      case .webSearchStarted(let query):
        self.ledger.update(taskID) { $0.phase = .searching }
        self.lastWebStatus = query.map { "Searching: \($0)" } ?? "Searching…"
      case .webSearchFinished:
        self.ledger.update(taskID) { $0.phase = image != nil ? .analyzing : .reasoning }
      }
      self.refreshActivity()
    }
    ledger.update(taskID) {
      if $0.timeline.firstModelOutput == nil { $0.timeline.firstModelOutput = result.firstOutputAt ?? Date() }
      $0.timeline.modelCompleted = result.completedAt ?? Date()
    }
    if usesWeb {
      let count = result.webSearches.count
      lastWebStatus = count > 0 || !result.citations.isEmpty
        ? "OK — \(count) search(es), \(result.citations.count) cited source(s)"
        : "Model answered without searching"
    }
    return result
  }

  private func makeOutcome(kind: AssistantTaskKind, query: String, result: ResponsesResult) -> Outcome {
    let sources = Self.sources(from: result)
    var speakable = String(result.text.prefix(1_800))
    if !sources.isEmpty {
      let names = sources.prefix(3).map(\.host).joined(separator: ", ")
      speakable += "\n(Sources: \(names). Mention the main source by name; do not read URLs.)"
    }
    return Outcome(speakable: speakable, display: result.text, kind: kind, sources: sources)
  }

  nonisolated static func sources(from result: ResponsesResult) -> [WebSource] {
    let fetched = result.completedAt ?? Date()
    var seen = Set<String>()
    var output: [WebSource] = []
    func add(_ url: URL, title: String?) {
      guard URLSafety.isPublicWebURL(url) else { return }
      let key = url.absoluteString.lowercased()
      guard seen.insert(key).inserted else { return }
      output.append(WebSource(
        title: (title?.isEmpty == false ? title! : (url.host ?? url.absoluteString)),
        url: url,
        snippet: nil,
        fetchedAt: fetched,
        publishedAt: nil))
    }
    for citation in result.citations { add(citation.url, title: citation.title) }
    for search in result.webSearches {
      for url in search.sourceURLs.prefix(6) { add(url, title: nil) }
    }
    return Array(output.prefix(8))
  }

  // MARK: Completion

  private func finish(taskID: UUID, outcome: Outcome, deliver: ((String) -> Bool)?) {
    running[taskID] = nil
    defer { refreshActivity() }
    guard let record = ledger.record(taskID), !record.phase.isTerminal else { return }
    if outcome.failed == "cancelled" {
      ledger.update(taskID) { $0.phase = .cancelled("cancelled") }
      return
    }
    guard ledger.mayDeliver(taskID, currentSession: sessionID) else {
      ledger.update(taskID) { $0.phase = .cancelled("stale result discarded") }
      return
    }

    if let kind = outcome.kind, outcome.failed == nil, let display = outcome.display {
      context.addFact(
        kind: kind,
        request: record.request,
        result: display,
        sources: outcome.sources.map(\.host))
    }
    if !outcome.sources.isEmpty || outcome.kind?.usesWeb == true {
      sources = outcome.sources
    }

    if let deliver {
      ledger.update(taskID) { $0.phase = .delivering }
      let sent = !outcome.speakable.isEmpty && deliver(outcome.speakable)
      ledger.update(taskID) { record in
        record.timeline.delivered = Date()
        record.sourceCount = outcome.sources.count
        if let failed = outcome.failed {
          record.phase = .failed(failed)
        } else {
          record.phase = sent ? .completed : .failed("voice channel unavailable")
        }
      }
      if sent { awaitingSpeech = taskID }
    } else {
      typedAnswer = outcome.display ?? outcome.speakable
      if let display = outcome.display { context.addTurn(.assistant, display) }
      ledger.update(taskID) { record in
        record.timeline.delivered = Date()
        record.sourceCount = outcome.sources.count
        record.phase = outcome.failed.map { AssistantTaskPhase.failed($0) } ?? .completed
      }
    }
    if let failed = outcome.failed {
      lastError = LogSanitizer.sanitize(failed)
    }
  }

  private func refreshActivity() {
    let phases = ledger.active.map { ($0.kind, $0.phase) }
    if phases.contains(where: { $0.1 == .capturingFrame || ($0.1 == .analyzing && $0.0?.usesCamera == true) }) {
      activity = .seeing
    } else if phases.contains(where: { $0.1 == .searching }) {
      activity = .searching
    } else if !phases.isEmpty {
      activity = .thinking
    } else {
      activity = nil
    }
  }
}
