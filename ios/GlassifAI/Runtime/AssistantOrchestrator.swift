import CoreImage
import Foundation
import MessageUI
import QuartzCore
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
  /// A high-detail vision request (text, labels, badges, screens).
  case reading
  case searching
  /// Preparing or running an iPhone action.
  case acting
  /// Saving to or searching the user's memory.
  case remembering
  /// Saving a note, reminder, task or event the user asked for.
  case saving
  case thinking
}

/// Everything a vision request sends besides the question: the full view,
/// optionally an enlarged crop of the text area, and optional on-device OCR
/// hints. All of it comes from one camera frame chosen for this task.
struct VisionAttachment {
  struct Image {
    let jpeg: Data
    let role: String
  }

  var images: [Image]
  var ocrText: String?
  var info: VisionFrameInfo
  let profile: VisionDetail

  var hasCrop: Bool { images.count > 1 }
  var totalBytes: Int { images.reduce(0) { $0 + $1.jpeg.count } }
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
  /// An iPhone action waiting for the user's yes or tap.
  @Published private(set) var pendingAction: PendingDeviceAction?
  @Published private(set) var lastActionResult: String?
  /// A short message for the assistant screen (for example a command that
  /// finished after a permission was granted outside a conversation).
  @Published private(set) var notice: String?

  /// A question the voice action bridge asked ("Neyi not alayım?"); the
  /// next utterance answers it.
  var bridgeAwaiting: VoiceIntent.Awaiting?
  var bridgeAwaitingSince: Date?
  /// A spoken command waiting for an iOS permission.
  var pendingPermissionCommand: PendingPermissionCommand?
  /// Speaks a line in the running conversation (set by the voice session;
  /// returns false when no conversation can speak it).
  var speakInConversation: ((String) -> Bool)?
  /// Commands the app is saving itself (notes, reminders, tasks…).
  private var localWork = 0
  /// The person of the last call, message or contact lookup ("ona da yaz").
  var recentContact: (name: String, at: Date)?
  /// What the user saved last (note, task, memory), for "bununla ilgili";
  /// the note's id when it was a note.
  var recentSaved: (text: String, at: Date, noteID: UUID?)?
  /// The app's last own result, shown as a short card with a haptic
  /// ("✓ Not kaydedildi"). Posted only after the store or iOS confirmed it.
  @Published private(set) var actionFeedback: ActionFeedback?
  /// Recent results for the assistant screen (labels and times only).
  @Published private(set) var recentActivity: [ActionFeedback] = []
  /// The current conversation's turns, in memory only until it ends; then
  /// a short summary is saved (Settings → Memory → Conversation memory) and
  /// the turns are dropped. Reconnects keep the same conversation.
  private var conversationLog: [ConversationContext.Turn] = []
  private var conversationStartedAt: Date?
  private var conversationActions = 0
  private var activeObserver: NSObjectProtocol?

  /// The camera source currently selected in the app (persisted setting).
  func captureSource() -> CaptureSource {
    CaptureSource(rawValue: UserDefaults.standard.string(forKey: CaptureSource.defaultsKey) ?? "")
      ?? .iPhoneCamera
  }

  /// Supplied by the camera screen: one fresh Ray-Ban still photo for one
  /// request (argument: timeout), and the DAT stream state for explanations.
  var glassesStillPhoto: (@MainActor (TimeInterval) async -> StillPhoto?)?
  var glassesStreamState: @MainActor () -> String = { "unknown" }
  /// The glasses stream's transport: "HEVC (hvc1)" or "raw".
  var glassesTransport: @MainActor () -> String = { "—" }

  private(set) var sessionID: UUID?
  private(set) var turnID = 0
  /// The user turn in which camera, web or agent content last entered the
  /// conversation.
  private var untrustedTurnID: Int?
  private var running: [UUID: Task<Void, Never>] = [:]
  private var handledHandoffs = Set<String>()
  private var awaitingSpeech: UUID?
  /// Models whose requests rejected the hosted web-search tool in this run.
  private var hostedSearchUnsupported = Set<String>()
  /// Set if the endpoint ever rejects an explicit image `detail`.
  private var imageDetailRejected = false
  /// When a vision answer last told the user to reposition the camera, so
  /// the advice is not repeated every turn.
  private var lastRepositionAdviceAt: Date?
  private let client = ResponsesClient()

  private var availableModels: [String] { ChatGPTAuthSession.shared.availableModels }
  private var catalog: [CatalogModel] { ChatGPTAuthSession.shared.modelCatalog }

  private init() {
    // A command that waited for a permission runs when the app is opened.
    activeObserver = NotificationCenter.default.addObserver(
      forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
    ) { [weak self] _ in
      Task { @MainActor in await self?.resumePendingPermissionCommand() }
    }
  }

  func postNotice(_ text: String) {
    notice = text
  }

  func clearNotice() {
    notice = nil
  }

  func postFeedback(_ feedback: ActionFeedback) {
    actionFeedback = feedback
    recentActivity.insert(feedback, at: 0)
    if recentActivity.count > 12 { recentActivity.removeLast(recentActivity.count - 12) }
  }

  func dismissFeedback(_ id: UUID) {
    if actionFeedback?.id == id { actionFeedback = nil }
  }

  func beginLocalWork() {
    localWork += 1
    refreshActivity()
  }

  func endLocalWork() {
    localWork = max(0, localWork - 1)
    refreshActivity()
  }

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
    LiveVisionController.shared.stop(reason: "conversation ended")
    sessionID = nil
    awaitingSpeech = nil
  }

  func noteUserTurn(_ text: String) {
    turnID += 1
    context.addTurn(.user, text)
    logConversationTurn(.user, text)
  }

  func noteAssistantTurn(_ text: String) {
    context.addTurn(.assistant, text)
    logConversationTurn(.assistant, text)
  }

  // MARK: Conversation memory

  /// A new conversation (not a reconnect of the running one).
  func beginConversation() {
    if conversationStartedAt == nil { conversationStartedAt = Date() }
  }

  func noteConversationAction() {
    conversationActions += 1
  }

  private func logConversationTurn(_ role: ConversationContext.Turn.Role, _ text: String) {
    let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleaned.isEmpty else { return }
    if conversationStartedAt == nil { conversationStartedAt = Date() }
    conversationLog.append(ConversationContext.Turn(role: role, text: String(cleaned.prefix(600)), at: Date()))
    if conversationLog.count > 80 { conversationLog.removeFirst(conversationLog.count - 80) }
  }

  /// The conversation ended: a meaningful one is summarised (topics,
  /// decisions, open tasks, names) and only that summary is kept.
  func finishConversation() {
    let turns = conversationLog
    let startedAt = conversationStartedAt ?? turns.first?.at ?? Date()
    let actions = conversationActions
    conversationLog = []
    conversationStartedAt = nil
    conversationActions = 0
    let store = MemoryStore.shared
    guard store.isEnabled, store.conversationMemoryEnabled,
          ConversationSummarizer.isMeaningful(turns, actions: actions) else { return }
    // A little time to finish in the background (the conversation often
    // ends with the phone locked).
    let background = UIApplication.shared.beginBackgroundTask(withName: "AutoLoom conversation summary")
    Task { @MainActor [weak self] in
      defer {
        if background != .invalid { UIApplication.shared.endBackgroundTask(background) }
      }
      let modelSummary = await self?.summarize(turns, startedAt: startedAt)
      let summary = modelSummary ?? ConversationSummarizer.localSummary(turns, startedAt: startedAt)
      store.saveConversationSummary(summary)
      NSLog("[AutoLoom] conversation summary saved (%@)", modelSummary == nil ? "local" : "model")
    }
  }

  /// One structured summary from the executor model (strict JSON).
  private func summarize(_ turns: [ConversationContext.Turn], startedAt: Date) async -> ConversationSummary? {
    guard let model = ModelSelector.model(
      for: .generalChat, available: availableModels, catalog: catalog,
      excluded: ModelHealth.shared.failedThisRun) else { return nil }
    let transcript = turns
      .map { "\($0.role == .user ? "User" : "Assistant"): \($0.text)" }
      .joined(separator: "\n")
    let info = catalog.first { $0.slug == model }
    var request = ResponsesClient.Request(
      model: model,
      instructions: ConversationSummarizer.instructions,
      input: [["role": "user", "content": [["type": "input_text", "text": String(transcript.suffix(12_000))]]]])
    request.reasoningEffort = ModelRouting.effort("low", supported: info?.reasoningLevels ?? [])
    request.verbosity = (info?.supportsVerbosity ?? true) ? "low" : nil
    request.jsonSchema = ConversationSummarizer.schema
    request.timeout = 25
    guard let result = try? await client.send(request) else { return nil }
    return ConversationSummarizer.decode(result.text, startedAt: startedAt, endedAt: Date())
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
    LiveVisionController.shared.stop(reason: "privacy wipe")
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
    if case .liveVision(let enable)? = envelope?.command {
      let reply = enable
        ? LiveVisionController.shared.start()
        : LiveVisionController.shared.stop(reason: "stopped by voice")
      _ = deliver(reply)
      return
    }
    if case .confirmAction(let confirmed)? = envelope?.command {
      Task { [weak self] in
        guard let self else { return }
        let reply = confirmed ? await self.confirmPendingAction(byVoice: true) : self.cancelPendingAction()
        _ = deliver(reply)
      }
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
    context.addTurn(.user, question)
    // "not al: …", "yarın 9'da hatırlat …" typed: the same local actions as
    // spoken commands.
    if let decision = VoiceActionIntentBridge.decide(question, context: bridgeContext()) {
      if !decision.intent.isConfirmationOrChoice {
        cancelAll(reason: "superseded by typed question", voiceOnly: false)
      }
      typedQuestion = question
      typedAnswer = nil
      Task { @MainActor [weak self] in
        guard let self else { return }
        let outcome = await self.runVoiceIntent(decision, transcript: question)
        self.typedAnswer = outcome.reply
        self.context.addTurn(.assistant, outcome.reply)
      }
      return
    }
    cancelAll(reason: "superseded by typed question", voiceOnly: false)
    typedQuestion = question
    typedAnswer = nil
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

  /// How a delegation the voice model made before the user's final words
  /// relates to a command the app then handles itself.
  enum DelegationTakeover: Equatable {
    /// Still running: cancelled; the app's result answers its handoff.
    case cancelled
    /// It already did an action (a note, reminder, memory…): not repeated.
    case completedAction
    /// It finished without acting (an answer, a failure): the app runs the
    /// command.
    case completedOther
    case unknown
  }

  /// The voice model delegated the user's words before their final
  /// transcript arrived, and the app now recognises them as its own
  /// command. One request, one result: the running delegation is stopped
  /// and the app's result answers it; one that already acted is kept.
  /// `signature` is what the user's command does ("save_note"). Only a
  /// delegation that already did exactly that counts as done: one that saved
  /// a memory or a reminder for "not al" does not, and the note is saved.
  func takeOverDelegation(handoffID: String, signature: String?) -> DelegationTakeover {
    guard let record = ledger.records.last(where: { $0.handoffID == handoffID }) else { return .unknown }
    if !record.phase.isTerminal {
      ledger.update(record.id) { $0.phase = .cancelled("taken over by the voice action bridge") }
      running[record.id]?.cancel()
      running[record.id] = nil
      refreshActivity()
      return .cancelled
    }
    if record.completed, let signature, record.executedAction == signature { return .completedAction }
    return .completedOther
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
    let outcome = await executeTask(taskID: taskID, envelope: envelope, rawText: rawText)
    if let kind = ledger.record(taskID)?.kind ?? outcome.kind, kind.bringsUntrustedContent {
      untrustedTurnID = turnID
    }
    return outcome
  }

  private func executeTask(taskID: UUID, envelope: DelegationEnvelope?, rawText: String) async -> Outcome {
    let camera = captureSource()
    var kind: AssistantTaskKind?
    var query = rawText
    var detail = VisionDetail.standard
    if let envelope, case .task(let requested) = envelope.command {
      kind = requested
      query = envelope.query
      detail = envelope.detail
      ledger.update(taskID) { $0.kind = requested; $0.routeOrigin = .verifiedEnvelope }
    } else {
      let origin: RouteOrigin = ledger.record(taskID)?.source == .typedInput ? .typedInput : .toolRouting
      ledger.update(taskID) { $0.routeOrigin = origin }
      // A delegation without an envelope can still be an explicit command
      // ("not al: …"). The app runs it itself rather than letting a model
      // answer "noted" with nothing saved; never in a turn that brought
      // camera, web or agent content.
      if origin == .toolRouting, untrustedTurnID != turnID {
        var bridge = bridgeContext()
        bridge.addressedOnly = false
        bridge.awaiting = nil
        if let decision = VoiceActionIntentBridge.decide(rawText, context: bridge), decision.intent.runsFromDelegation {
          ledger.update(taskID) {
            $0.kind = .authorizedAction
            $0.notes.append("free-text delegation run by the voice action bridge")
          }
          let result = await runVoiceIntent(decision, transcript: rawText)
          return Outcome(speakable: result.spoken, display: nil, kind: .authorizedAction, failed: result.failed)
        }
      }
    }

    // Verify the requested route against what the app can actually do now.
    if let requested = kind {
      if requested == .authorizedAction && !AssistantPreferences.actionsEnabled {
        return Outcome(
          speakable: "iPhone actions are turned off in the app settings, so nothing was done. The user can enable them in Settings, iPhone actions.",
          kind: requested)
      }
      if (requested == .localMemory || requested == .visualMemory) && !MemoryStore.shared.isEnabled {
        return Outcome(
          speakable: "Memory is turned off in the app. The user can turn it on in Settings, Memory. Nothing was saved or recalled.",
          kind: requested)
      }
      if requested == .visualMemory && !MemoryStore.shared.visualMemoriesEnabled {
        return Outcome(
          speakable: "Visual memories are off. The user can turn them on in Settings, Memory, Visual memories. Nothing was saved.",
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

    // Reading and fine-detail words in the request always get the
    // high-detail profile, whatever the voice model chose.
    if let kind, kind.usesCamera {
      detail = VisionQueryClassifier.profile(for: query, requested: detail)
    }

    do {
      // Multi-agent routing: every request gets a plan (Settings → Intelligence
      // → Routing diagnostics). A specialist or a team runs only when one is
      // connected and suits the job; otherwise, and whenever every
      // specialist fails, the ChatGPT path below answers as before.
      let plan = agentPlan(for: query, kind: kind, camera: camera)
      ledger.update(taskID) { $0.agentPlan = plan.summary }
      if plan.strategy == .local, plan.reason == "offline" {
        return Outcome(
          speakable: "The phone is offline, so this cannot be answered right now. Notes, tasks, reminders and memory still work. Tell the user briefly.",
          kind: kind, failed: "offline")
      }
      // Reports (saved as a note) and requests for the user's own agent
      // (confirmed first) keep their own flows.
      if plan.usesSpecialist, kind != .report, kind != .agent, plan.primary.role != .external,
         let outcome = try await runSpecialists(plan, taskID: taskID, kind: kind, query: query, detail: detail) {
        return outcome
      }
      if !plan.usesSpecialist {
        ProviderRegistry.shared.record(RoutingDiagnostic(
          at: Date(), intent: plan.intent, strategy: plan.strategy,
          steps: plan.allSteps.map { "\($0.role.rawValue) → \($0.provider.rawValue)" },
          result: plan.strategy == .local ? "local tools" : "default path (ChatGPT)", latencyMs: nil, fallback: nil))
      }
      if kind == .localMemory {
        return try await runMemory(taskID: taskID, query: query)
      }
      if kind == .visualMemory {
        return try await runVisualMemory(taskID: taskID, query: query)
      }
      if kind == .authorizedAction {
        return try await runAction(taskID: taskID, query: query)
      }
      if kind == .report {
        return try await runReport(taskID: taskID, query: query)
      }
      if kind == .agent {
        return await runAgent(query: query)
      }
      if let kind {
        return try await runExecutor(
          taskID: taskID, kind: kind, query: query, image: kind.usesCamera, detail: detail)
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

  // MARK: Multi-agent

  /// The router's plan for this request. Settings the user turned off
  /// (camera, web search) are respected before routing.
  private func agentPlan(for query: String, kind: AssistantTaskKind?, camera: CaptureSource) -> AgentPlan {
    var profile = RequestAnalyzer.analyze(query, kind: kind)
    if !AssistantPreferences.webSearchEnabled {
      profile.needsWeb = false
      profile.needsCurrentInformation = false
      profile.researchFacets = []
    }
    if camera == .off {
      profile.needsVision = false
      profile.needsLiveVideo = false
    }
    profile.intent = RequestAnalyzer.intent(for: profile)
    return AgentRouter.plan(for: profile, context: ProviderRegistry.shared.routingContext())
  }

  /// Runs the plan's specialists (or team) with the minimum context: the
  /// words, the camera image when the job is visual, a few relevant
  /// memories, the recent conversation and the current entities. Returns
  /// nil when every specialist failed, so the ChatGPT path answers instead.
  private func runSpecialists(
    _ plan: AgentPlan,
    taskID: UUID,
    kind: AssistantTaskKind?,
    query: String,
    detail: VisionDetail
  ) async throws -> Outcome? {
    var agentContext = AutoLoomAgentOrchestrator.Context(query: query)
    if plan.allSteps.contains(where: { $0.role == .vision || $0.role == .translation }) {
      ledger.update(taskID) { $0.visionProfile = detail }
      let attachment = try await prepareVisionImage(taskID: taskID, detail: detail)
      agentContext.images = attachment.images.map(\.jpeg)
      agentContext.ocrText = attachment.ocrText
    }
    agentContext.memory = MemoryStore.shared.relevantItems(for: query)
    agentContext.conversation = context.promptContext(memory: [])
    agentContext.entities = EntityContext.shared.contextLine()
    agentContext.turkish = context.detectedLanguage.map { $0 == "Turkish" } ?? L.isTurkish
    ledger.update(taskID) {
      $0.phase = plan.primary.role == .research || plan.strategy == .team ? .searching : .reasoning
      $0.model = plan.allSteps.map { "\($0.role.rawValue)→\($0.provider.rawValue)" }.joined(separator: ", ")
    }
    refreshActivity()
    do {
      let answer = try await AutoLoomAgentOrchestrator.shared.execute(plan, context: agentContext)
      try Task.checkCancellation()
      let fetched = Date()
      let sources = answer.sources.map { source in
        WebSource(
          title: source.title ?? source.url.host ?? source.url.absoluteString, url: source.url, snippet: nil,
          fetchedAt: fetched, publishedAt: source.published)
      }
      var speakable = String(answer.spoken.prefix(1_800))
      if !sources.isEmpty {
        let names = sources.prefix(3).map(\.host).joined(separator: ", ")
        speakable += "\n(Sources: \(names). Mention the main source by name; do not read URLs.)"
      }
      if answer.disagreement {
        speakable += "\n(The sources disagree on the figures: say so and give the range.)"
      }
      ledger.update(taskID) {
        $0.notes.append("agents: \(answer.providers.map(\.rawValue).joined(separator: ", "))"
          + (answer.fallbackUsed ? " (fallback used)" : ""))
      }
      let resultKind: AssistantTaskKind = kind
        ?? (plan.primary.role == .research ? .webSearch : (plan.primary.role == .vision ? .vision : .deepReasoning))
      return Outcome(speakable: speakable, display: answer.text, kind: resultKind, sources: sources)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      ledger.update(taskID) { $0.notes.append("specialists unavailable → ChatGPT path") }
      return nil
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
    let hostedModel = ModelSelector.model(
      for: nil, available: availableModels, needsHostedWebSearch: true, catalog: catalog,
      excluded: ModelHealth.shared.failedThisRun)
    if webEnabled, let hostedModel, !hostedSearchUnsupported.contains(hostedModel) {
      do {
        result = try await callModel(
          taskID: taskID, kind: nil, query: query, tools: tools + [AssistantTools.webSearch], attachment: nil)
      } catch ResponsesError.badRequest(let message) {
        hostedSearchUnsupported.insert(hostedModel)
        NSLog("[AutoLoom] hosted web search rejected for %@: %@", hostedModel, message)
        result = try await callModel(
          taskID: taskID, kind: nil, query: query, tools: tools + [AssistantTools.searchWebFunction], attachment: nil)
      }
    } else {
      let fallbackTools = webEnabled ? tools + [AssistantTools.searchWebFunction] : tools
      result = try await callModel(taskID: taskID, kind: nil, query: query, tools: fallbackTools, attachment: nil)
    }

    if let call = result.functionCalls.first(where: { $0.name == AssistantTools.lookAtCameraName }) {
      let arguments = (try? JSONSerialization.jsonObject(with: Data(call.arguments.utf8))) as? [String: Any]
      let wantsWeb = (arguments?["also_search_web"] as? Bool ?? false) && webEnabled
      let visionKind: AssistantTaskKind = wantsWeb ? .visionPlusWeb : .vision
      let requested: VisionDetail = (arguments?["detail"] as? String) == "high" || wantsWeb ? .high : .standard
      let detail = VisionQueryClassifier.profile(for: query, requested: requested)
      ledger.update(taskID) { $0.kind = visionKind }
      return try await runExecutor(taskID: taskID, kind: visionKind, query: query, image: true, detail: detail)
    }
    if let call = result.functionCalls.first(where: { $0.name == AssistantTools.searchWebName }) {
      let arguments = (try? JSONSerialization.jsonObject(with: Data(call.arguments.utf8))) as? [String: Any]
      let searchQuery = (arguments?["query"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? query
      ledger.update(taskID) { $0.kind = .webSearch }
      return try await runDirectSearch(
        taskID: taskID, kind: .webSearch, query: query, searchQueries: [searchQuery], attachment: nil)
    }
    let inferred: AssistantTaskKind = result.webSearches.isEmpty && result.citations.isEmpty ? .generalChat : .webSearch
    ledger.update(taskID) { $0.kind = inferred }
    return makeOutcome(kind: inferred, query: query, result: result)
  }

  private func runExecutor(
    taskID: UUID,
    kind: AssistantTaskKind,
    query: String,
    image: Bool,
    detail: VisionDetail = .standard
  ) async throws -> Outcome {
    var attachment: VisionAttachment?
    if image {
      ledger.update(taskID) { $0.visionProfile = detail }
      attachment = try await prepareVisionImage(taskID: taskID, detail: detail)
    }
    guard kind.usesWeb else {
      var result = try await callModel(
        taskID: taskID, kind: kind, query: query, tools: [], attachment: attachment, detail: detail)
      if kind == .vision, detail != .high, VisionAnswerCheck.suggestsUnclear(result.text) {
        // Before any "move closer": the sharpest recent frame in high detail
        // with on-device OCR and a zoomed crop of the text.
        NSLog("[AutoLoom] vision answer was unclear; retrying with the high-detail profile")
        ledger.update(taskID) {
          $0.visionProfile = .high
          $0.notes.append("unclear standard answer → high-detail retry (best frame, OCR, crop)")
        }
        let sharper = try await prepareVisionImage(taskID: taskID, detail: .high)
        result = try await callModel(
          taskID: taskID, kind: kind, query: query, tools: [], attachment: sharper, detail: .high)
      }
      if kind.usesCamera, VisionAnswerCheck.containsRepositionAdvice(result.text) {
        lastRepositionAdviceAt = Date()
      }
      return makeOutcome(kind: kind, query: query, result: result)
    }
    let hostedModel = ModelSelector.model(
      for: kind, available: availableModels, needsHostedWebSearch: true, catalog: catalog,
      needsImages: attachment != nil, excluded: ModelHealth.shared.failedThisRun)
    if let hostedModel, !hostedSearchUnsupported.contains(hostedModel) {
      do {
        let result = try await callModel(
          taskID: taskID, kind: kind, query: query, tools: [AssistantTools.webSearch], attachment: attachment,
          detail: detail)
        return makeOutcome(kind: kind, query: query, result: result)
      } catch ResponsesError.badRequest(let message) {
        // The hosted tool is not accepted for this model/account: remember it
        // for this run and use the backend search endpoint instead.
        hostedSearchUnsupported.insert(hostedModel)
        NSLog("[AutoLoom] hosted web search rejected for %@: %@", hostedModel, message)
      }
    }
    return try await runDirectSearch(
      taskID: taskID, kind: kind, query: query, searchQueries: [query], attachment: attachment, detail: detail)
  }

  /// Search through the backend search endpoint, then let the model answer
  /// from those results. Used when the hosted web-search tool is unavailable.
  private func runDirectSearch(
    taskID: UUID,
    kind: AssistantTaskKind,
    query: String,
    searchQueries: [String],
    attachment: VisionAttachment?,
    detail: VisionDetail = .standard
  ) async throws -> Outcome {
    ledger.update(taskID) { $0.phase = .searching }
    refreshActivity()
    lastWebStatus = "Searching (direct): \(searchQueries.first ?? query)"
    guard let model = ModelSelector.model(
      for: kind, available: availableModels, catalog: catalog, needsImages: attachment != nil,
      excluded: ModelHealth.shared.failedThisRun) else {
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
      taskID: taskID, kind: kind, query: query, tools: [], attachment: attachment,
      extraContext: extra, directSearch: true, detail: detail)
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

  // MARK: iPhone actions

  /// What staging an action produced: text for the voice model, plus an
  /// optional display text.
  struct ActionStageResult {
    let speakable: String
    let display: String?
    let failed: String?
  }

  private func runAction(taskID: UUID, query: String) async throws -> Outcome {
    if let reason = ActionGuard.blockedReason(for: query) {
      return Outcome(speakable: ActionGuard.declineText(reason: reason), kind: .authorizedAction)
    }
    // An explicit command in the delegated words ("not al: yarın …") runs
    // deterministically, exactly as when the user says it: a note stays a
    // note even when it mentions a time. Never after camera, web or agent
    // content in this turn.
    if untrustedTurnID != turnID {
      var bridge = bridgeContext()
      bridge.addressedOnly = false
      bridge.awaiting = nil
      if let decision = VoiceActionIntentBridge.decide(query, context: bridge), decision.intent.runsFromDelegation {
        ledger.update(taskID) {
          $0.notes.append("explicit command in the delegation, run by the voice action bridge")
          $0.executedAction = decision.intent.actionSignature
        }
        let result = await runVoiceIntent(decision, transcript: query)
        return Outcome(speakable: result.spoken, display: nil, kind: .authorizedAction, failed: result.failed)
      }
    }
    let result = try await callModel(
      taskID: taskID, kind: .authorizedAction, query: query, tools: [], attachment: nil,
      schema: AssistantTools.actionSchema)
    try Task.checkCancellation()
    let staged: ActionStageResult
    switch DeviceActionParser.parse(result.text, query: query) {
    case .failure(let error):
      staged = ActionStageResult(
        speakable: error.speakable + " Tell the user briefly and ask for what is missing.",
        display: nil, failed: "action plan: \(error.speakable)")
    case .success(var plan):
      guard ToolRegistry.allows(plan.kind) else {
        return Outcome(
          speakable: "The \(plan.kind.label) tool is turned off in Settings, Tools, so nothing was done. Tell the user.",
          kind: .authorizedAction)
      }
      if plan.kind == .call || plan.kind == .message, plan.phone == nil, let name = plan.recipient {
        switch await resolveContact(name) {
        case .found(let phone, let fullName):
          plan.phone = phone
          plan.recipient = fullName
          ledger.update(taskID) { $0.notes.append("contact resolved on the phone") }
        case .ask(let text):
          return Outcome(speakable: text, kind: .authorizedAction)
        case .unavailable(let text):
          // A message can still open without a recipient; a call cannot.
          if plan.kind == .call { return Outcome(speakable: text, kind: .authorizedAction) }
        }
      }
      if untrustedTurnID == turnID {
        // Text from the camera, the web or an agent never triggers a change
        // by itself (brief: prompt injection), whatever the model decided.
        plan.afterUntrustedContent = true
        ledger.update(taskID) { $0.notes.append("needs a yes: camera, web or agent content in this turn") }
      }
      staged = await stage(plan)
      let executed = plan.kind.rawValue
      ledger.update(taskID) { $0.executedAction = executed }
    }
    return Outcome(speakable: staged.speakable, display: staged.display, kind: .authorizedAction, failed: staged.failed)
  }

  private enum ContactResolution {
    case found(phone: String, name: String)
    case ask(String)
    case unavailable(String)
  }

  /// Finds the number for "call Ahmet" in Contacts (read-only). Several
  /// matches or numbers are handed back as a question, never guessed.
  private func resolveContact(_ name: String) async -> ContactResolution {
    do {
      let matches = try await ContactsLookup.find(name).filter { !$0.phones.isEmpty }
      guard !matches.isEmpty else {
        return .unavailable("No contact named \(name) with a phone number was found on this iPhone. Ask the user for the number.")
      }
      guard matches.count == 1, let match = matches.first else {
        let names = matches.prefix(4).map(\.name).joined(separator: ", ")
        return .ask("Several contacts match \(name): \(names). Ask the user which one they mean.")
      }
      let mobile = match.phones.first { phone in
        let label = phone.label.lowercased()
        return label.contains("mobile") || label.contains("cep") || label.contains("iphone")
      }
      if let chosen = match.phones.count == 1 ? match.phones.first : mobile,
         let phone = DeviceActionParser.normalizedPhone(chosen.number) {
        return .found(phone: phone, name: match.name)
      }
      let numbers = match.phones.prefix(4).map { "\($0.label) \($0.number)" }.joined(separator: ", ")
      return .ask("\(match.name) has several numbers: \(numbers). Ask the user which one to use.")
    } catch {
      return .unavailable(LogSanitizer.sanitize(error.localizedDescription) + " Tell the user.")
    }
  }

  /// SAFE actions run now; CONFIRM actions wait for a spoken yes or a tap;
  /// STRONG CONFIRM actions (anything that leaves the app or contacts
  /// someone) wait for a tap. An ambiguous time is always asked first.
  func stage(_ plan: DeviceActionPlan) async -> ActionStageResult {
    if let ambiguity = plan.ambiguityNote {
      pendingAction = PendingDeviceAction(plan: plan)
      return ActionStageResult(
        speakable: "\(ambiguity) Proposed: \(plan.summary). If the user means the other time, delegate the action again with those words; if they confirm this one, delegate TASK: confirm_action. Nothing is saved yet.",
        display: plan.summary, failed: nil)
    }
    switch plan.risk {
    case .safe:
      do {
        let text = try await DeviceActionExecutor.shared.run(plan)
        lastActionResult = text
        if let feedback = ActionFeedback.saved(plan) { postFeedback(feedback) }
        if plan.kind == .saveNote, let saved = plan.text {
          recentSaved = (saved, Date(), MemoryStore.shared.notes.first { $0.content == saved }?.id)
        }
        return ActionStageResult(
          speakable: text + "\nTell the user naturally and briefly.", display: text, failed: nil)
      } catch {
        let message = LogSanitizer.sanitize(error.localizedDescription)
        if let feedback = ActionFeedback.notSaved(plan) { postFeedback(feedback) }
        return ActionStageResult(speakable: message + " Tell the user.", display: nil, failed: message)
      }
    case .confirm:
      pendingAction = PendingDeviceAction(plan: plan)
      let reason = plan.afterUntrustedContent
        ? "It was planned right after content from the camera, the web or an agent, so it needs the user's yes. "
        : ""
      return ActionStageResult(
        speakable: reason + "Waiting for confirmation: \(plan.summary). Read it back briefly and ask the user to confirm. If they say yes, delegate TASK: confirm_action; if no, TASK: cancel_action. They can also tap Confirm or Cancel on the phone. Nothing is saved yet.",
        display: plan.summary, failed: nil)
    case .strongConfirm:
      pendingAction = PendingDeviceAction(plan: plan)
      return ActionStageResult(
        speakable: "\(plan.summary) is ready on the phone screen. For safety the user must tap to confirm it there; a spoken yes is not enough. Tell the user briefly. Nothing has happened yet.",
        display: plan.summary, failed: nil)
    }
  }

  /// "Hayır, cumartesi": the waiting action gets the corrected day or time
  /// (a new day keeps the time of day) and is staged again; nothing else
  /// about it changes. Nil when nothing is waiting.
  func correctPendingAction(to time: ParsedTime) async -> ActionStageResult? {
    guard let pending = pendingAction, !pending.isExpired else { return nil }
    var plan = pending.plan
    let merged = CorrectionMerge.merge(original: plan.date, originalHasTime: plan.hasTime, correction: time)
    if let start = plan.date, let end = plan.endDate {
      plan.endDate = merged.date.addingTimeInterval(end.timeIntervalSince(start))
    }
    plan.date = merged.date
    plan.hasTime = merged.hasTime
    plan.alternativeDate = nil
    pendingAction = nil
    return await stage(plan)
  }

  /// A yes by voice or a tap on Save. Actions that leave the app are never
  /// confirmed by voice.
  func confirmPendingAction(byVoice: Bool) async -> String {
    guard let pending = pendingAction, !pending.isExpired else {
      pendingAction = nil
      return "There is no action waiting for confirmation."
    }
    if byVoice && pending.plan.risk == .strongConfirm {
      return "For safety, this must be confirmed with a tap on the phone; a spoken yes is not enough."
    }
    pendingAction = nil
    if pending.plan.kind == .agentTask {
      return await sendToAgent(pending.plan.text ?? "")
    }
    do {
      let text = try await DeviceActionExecutor.shared.run(pending.plan)
      lastActionResult = text
      if let feedback = ActionFeedback.saved(pending.plan) { postFeedback(feedback) }
      return text + (byVoice ? " Tell the user it is done." : "")
    } catch {
      let message = LogSanitizer.sanitize(error.localizedDescription)
      lastActionResult = message
      if let feedback = ActionFeedback.notSaved(pending.plan) { postFeedback(feedback) }
      return message
    }
  }

  /// "Sabah" / "akşam": the chosen reading of an ambiguous time replaces
  /// the pending action's time; the action then runs like any other.
  func choosePendingTime(_ date: Date) async -> ActionStageResult? {
    guard let pending = pendingAction, !pending.isExpired else {
      pendingAction = nil
      return nil
    }
    var plan = pending.plan
    if let start = plan.date, let end = plan.endDate {
      plan.endDate = date.addingTimeInterval(end.timeIntervalSince(start))
    }
    plan.date = date
    plan.alternativeDate = nil
    pendingAction = nil
    return await stage(plan)
  }

  /// Runs one request kind for the voice action bridge (LEVEL 2 structured
  /// classification, visual memory, translation) and returns its result
  /// without delivering it; the bridge speaks it.
  func runBridgeTask(
    _ kind: AssistantTaskKind,
    query: String,
    detail: VisionDetail = .standard
  ) async -> (speakable: String, display: String?, failed: String?) {
    let record = ledger.begin(
      sessionID: sessionID ?? UUID(), turnID: turnID, handoffID: nil, source: .voiceIntent, request: query)
    let envelope = DelegationEnvelope(command: .task(kind), query: query, detail: detail)
    refreshActivity()
    let outcome = await execute(taskID: record.id, envelope: envelope, rawText: query)
    ledger.update(record.id) { entry in
      entry.timeline.delivered = Date()
      entry.sourceCount = outcome.sources.count
      entry.phase = outcome.failed.map { AssistantTaskPhase.failed($0) } ?? .completed
    }
    if let kind = outcome.kind, outcome.failed == nil, let display = outcome.display {
      context.addFact(kind: kind, request: query, result: display, sources: outcome.sources.map(\.host))
    }
    if !outcome.sources.isEmpty { sources = outcome.sources }
    if let failed = outcome.failed, failed != "cancelled" { lastError = LogSanitizer.sanitize(failed) }
    refreshActivity()
    return (outcome.speakable, outcome.display, outcome.failed)
  }

  @discardableResult
  func cancelPendingAction() -> String {
    guard pendingAction != nil else { return "There was no action waiting." }
    pendingAction = nil
    lastActionResult = "Cancelled"
    return "Cancelled. Nothing was saved or sent."
  }

  /// Called by the confirmation card after the user tapped an action that
  /// opens another app (Maps, Safari, Phone, Messages, share sheet).
  func completeTapAction(_ result: String, feedback: ActionFeedback? = nil) {
    pendingAction = nil
    lastActionResult = result
    if let feedback { postFeedback(feedback) }
  }

  /// What the user did in the Messages sheet the app opened. "Sent" is
  /// reported only when Messages says so.
  func messageSheetFinished(_ result: MessageComposeResult) {
    switch result {
    case .sent:
      lastActionResult = "The user sent the message in Messages"
      postFeedback(ActionFeedback(kind: .message, title: L.t("Message sent", "Mesaj gönderildi")))
      context.addFact(kind: .authorizedAction, request: "message", result: "The user sent the prepared message.", sources: [])
    case .failed:
      lastActionResult = "Messages could not send the message"
      postFeedback(.failed(L.t("Message not sent", "Mesaj gönderilemedi")))
    default:
      lastActionResult = "The user closed Messages without sending"
      postFeedback(ActionFeedback(kind: .message, title: L.t("Message not sent", "Mesaj gönderilmedi"), success: false))
    }
  }

  /// What the user did in the share sheet the app opened.
  func shareSheetFinished(_ completed: Bool) {
    lastActionResult = completed ? "The user shared the text" : "The user closed the share sheet"
    if completed {
      postFeedback(ActionFeedback(kind: .share, title: L.t("Shared", "Paylaşıldı")))
    }
  }

  // MARK: Agent gateway (OpenClaw, optional)

  /// Stable per-install session user, so the agent keeps its conversation.
  private var agentSessionUser: String {
    let key = "autoloom.agent.sessionUser"
    if let value = UserDefaults.standard.string(forKey: key) { return value }
    let value = "autoloom-\(UUID().uuidString.prefix(8).lowercased())"
    UserDefaults.standard.set(value, forKey: key)
    return value
  }

  /// Holds the request until the user confirms; nothing is sent before.
  private func runAgent(query: String) async -> Outcome {
    guard AgentGatewayConfig.isReady else {
      return Outcome(
        speakable: "No agent gateway is connected to this app, so that cannot be done here. The user can connect their own OpenClaw gateway in Settings, Agent gateway.",
        kind: .agent)
    }
    var plan = DeviceActionPlan(kind: .agentTask)
    plan.text = String(query.prefix(2_000))
    let staged = await stage(plan)
    return Outcome(speakable: staged.speakable, display: staged.display, kind: .agent, failed: staged.failed)
  }

  private func sendToAgent(_ prompt: String) async -> String {
    do {
      let reply = try await AgentGatewayClient().send(prompt: prompt, sessionUser: agentSessionUser)
      lastActionResult = reply
      typedQuestion = prompt
      typedAnswer = reply
      return "Your agent replied:\n" + UntrustedContent.wrap(reply, origin: "the user's OpenClaw agent") +
        "\nSummarise the reply for the user briefly."
    } catch {
      let message = LogSanitizer.sanitize(error.localizedDescription)
      lastActionResult = message
      return message + " Tell the user."
    }
  }

  // MARK: Reports

  /// "Research this and prepare a report": live web research written up and
  /// saved as an AutoLoom note with its sources; a short summary is spoken.
  private func runReport(taskID: UUID, query: String) async throws -> Outcome {
    let outcome = try await runExecutor(taskID: taskID, kind: .report, query: query, image: false)
    guard outcome.failed == nil, let report = outcome.display, !report.isEmpty else { return outcome }
    let title = "Report: " + String(query.prefix(60))
    guard MemoryStore.shared.addNote(
      title: title, content: report, source: "report", tags: ["report"],
      links: outcome.sources.map { $0.url.absoluteString }) != nil else {
      var failed = outcome
      failed.speakable = "The research finished but the note could not be saved. Tell the user and give the short answer:\n" +
        String(report.prefix(600))
      return failed
    }
    let summary = report
      .components(separatedBy: CharacterSet.newlines)
      .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
      .prefix(4)
      .joined(separator: " ")
    var spoken = outcome
    let sourceNames = outcome.sources.prefix(3).map(\.host).joined(separator: ", ")
    spoken.speakable = "The report was saved in AutoLoom notes on the phone. Give the user this summary in two or three sentences:\n" +
      String(summary.prefix(900)) + (sourceNames.isEmpty ? "" : "\n(Sources: \(sourceNames).)")
    return spoken
  }

  /// Explicit memory only: the voice model writes "save:", "recall:",
  /// "forget:" or "list"; without a prefix a model classifies the request
  /// (strict JSON) and the store executes it. Search runs on the phone.
  private func runMemory(taskID: UUID, query: String) async throws -> Outcome {
    let store = MemoryStore.shared
    var request = MemoryRequest.parse(query)
    if request == nil {
      let result = try await callModel(
        taskID: taskID, kind: .localMemory, query: query, tools: [], attachment: nil,
        schema: AssistantTools.memorySchema)
      request = MemoryRequest.decodePlan(result.text)
      ledger.update(taskID) { $0.notes.append("memory request classified by the model") }
    }
    guard let request else {
      return Outcome(
        speakable: "It is not clear what to remember or recall. Ask the user briefly.",
        kind: .localMemory)
    }
    switch request {
    case .save(let text, let title, let kind):
      ledger.update(taskID) { $0.executedAction = "memory.save" }
      guard let record = store.remember(text, title: title, kind: kind, source: "voice") else {
        return Outcome(speakable: "The memory could not be saved. Tell the user.", kind: .localMemory, failed: "memory save failed")
      }
      return Outcome(
        speakable: "Saved to memory on this iPhone: \"\(record.text)\". Confirm it in a few natural words.",
        display: record.text, kind: .localMemory)
    case .recall(let search):
      let hits = store.search(search, limit: 5)
      store.noteRecalled(hits)
      guard !hits.isEmpty else {
        return Outcome(
          speakable: "Nothing the user saved matches \"\(search)\". Say honestly that you don't have that saved.",
          kind: .localMemory)
      }
      let lines = hits.map { "- \($0.line)" }.joined(separator: "\n")
      return Outcome(
        speakable: "From the user's saved memories and notes (answer naturally from them):\n" + lines,
        display: lines, kind: .localMemory)
    case .forget(let search):
      let hits = store.search(search, limit: 3, includeNotes: false, includeTasks: false)
      guard let best = hits.first, case .memory(let record) = best.item else {
        return Outcome(
          speakable: "No saved memory matches \"\(search)\", so nothing was forgotten. Tell the user.",
          kind: .localMemory)
      }
      if hits.count > 1, hits[1].score >= best.score * 0.9 {
        let options = hits.prefix(3).map { "\"\($0.line)\"" }.joined(separator: "; ")
        return Outcome(
          speakable: "Several memories match: \(options). Ask the user which one to forget.",
          kind: .localMemory)
      }
      var plan = DeviceActionPlan(kind: .forgetMemory)
      plan.memoryID = record.id
      plan.text = record.text
      let staged = await stage(plan)
      return Outcome(speakable: staged.speakable, display: staged.display, kind: .localMemory, failed: staged.failed)
    case .list:
      let recent = store.memories.prefix(8)
      guard !recent.isEmpty else {
        return Outcome(speakable: "No memories are saved yet. Tell the user how: \"hatırla …\" or \"remember that …\".", kind: .localMemory)
      }
      let lines = recent.map { "- \($0.text.prefix(160))" }.joined(separator: "\n")
      return Outcome(
        speakable: "The user's most recent saved memories (\(store.memories.count) in total). Summarise briefly:\n" + lines,
        display: lines, kind: .localMemory)
    }
  }

  /// "Remember what I'm looking at": a high-detail description of the
  /// current view saved as a visual memory, with a small photo and the place
  /// only when the user allowed them.
  private func runVisualMemory(taskID: UUID, query: String) async throws -> Outcome {
    let store = MemoryStore.shared
    ledger.update(taskID) { $0.visionProfile = .high }
    let attachment = try await prepareVisionImage(taskID: taskID, detail: .high)
    let result = try await callModel(
      taskID: taskID, kind: .visualMemory, query: query, tools: [], attachment: attachment, detail: .high)
    try Task.checkCancellation()
    let description = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !description.isEmpty else {
      return Outcome(speakable: "The view could not be described, so nothing was saved. Tell the user.", kind: .visualMemory, failed: "empty description")
    }
    var location: MemoryLocation?
    if store.attachLocation {
      location = await LocationProvider.shared.currentLocation()
    }
    let thumbnail = store.saveVisualPhotos ? attachment.images.first.flatMap { Thumbnailer.jpeg($0.jpeg) } : nil
    guard let record = store.remember(
      String(description.prefix(600)), title: MemoryStore.defaultTitle(for: query), kind: .visual,
      source: "visual", location: location, thumbnail: thumbnail) else {
      return Outcome(speakable: "The visual memory could not be saved. Tell the user.", kind: .visualMemory, failed: "memory save failed")
    }
    ledger.update(taskID) { $0.executedAction = "memory.visual" }
    var spoken = "Saved as a visual memory on this iPhone: \(record.text)"
    if let place = location?.placeName { spoken += " (place: \(place))" }
    return Outcome(speakable: spoken + "\nConfirm briefly and naturally.", display: record.text, kind: .visualMemory)
  }

  /// Frames older than this never answer a visual question.
  static let maxFrameAge: CFTimeInterval = 1.0

  /// One short description of the current view for Live Vision. Uses the
  /// fast image profile and low effort, is not recorded as a task, and is
  /// only ever given to the voice model as silent context.
  func describeLiveView(_ frame: CapturedFrame) async throws -> String {
    let pixelBuffer = frame.pixelBuffer
    let background = UIApplication.shared.applicationState == .background
    let encoded = await Task.detached(priority: .utility) {
      VisionFrameEncoder.encode(pixelBuffer, detail: .fast, useCPU: background)
    }.value
    guard let encoded else { throw ResponsesError.failed("The live image could not be prepared.") }
    // Live Vision on a specialist (Gemini) when it leads the live-vision
    // role; ChatGPT otherwise, and whenever the specialist fails.
    let routing = ProviderRegistry.shared.routingContext()
    let specialists = Array(AgentRouter.candidates(for: .liveVision, context: routing).prefix { $0 != .chatgpt })
    if !specialists.isEmpty,
       let text = try? await AutoLoomAgentOrchestrator.shared.describeLive(
         jpeg: encoded.jpeg, providers: specialists,
         turkish: context.detectedLanguage.map { $0 == "Turkish" } ?? L.isTurkish),
       !text.isEmpty {
      return text
    }
    let catalog = self.catalog
    guard let model = ModelSelector.model(
      for: .vision, available: availableModels, catalog: catalog, needsImages: true,
      excluded: ModelHealth.shared.failedThisRun) else {
      throw ResponsesError.failed("No compatible ChatGPT model is available for this account.")
    }
    var image: [String: Any] = [
      "type": "input_image",
      "image_url": "data:image/jpeg;base64,\(encoded.jpeg.base64EncodedString())",
    ]
    if !imageDetailRejected { image["detail"] = "high" }
    let info = catalog.first { $0.slug == model }
    let content: [[String: Any]] = [["type": "input_text", "text": "Describe the current view."], image]
    var request = ResponsesClient.Request(
      model: model,
      instructions: AssistantInstructions.liveView(detectedLanguage: context.detectedLanguage),
      input: [["role": "user", "content": content]])
    request.reasoningEffort = ModelRouting.effort("low", supported: info?.reasoningLevels ?? [])
    request.verbosity = (info?.supportsVerbosity ?? true) ? "low" : nil
    request.timeout = 20
    let result = try await client.send(request)
    return String(result.text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(400))
  }

  /// Gets one current image from the selected camera for this task.
  /// - Ray-Ban: the best of the last few video frames (sharp, well exposed,
  ///   fresh, and showing the same scene as the newest frame), or a still
  ///   photo when video stalls or when chosen in Settings. Never the iPhone
  ///   camera, a preview screenshot, or an older image. With the phone
  ///   locked the same decoded glasses frames are used; when none is fresh
  ///   the glasses take a still photo (JPEG, processed on the CPU).
  /// - iPhone: the freshest camera frame.
  /// The current camera image for reading on the phone (QR codes), with the
  /// same rules as vision: a fresh image only, never an earlier one.
  func cameraImageForReading() async -> (jpeg: Data?, unavailable: String?) {
    do {
      let attachment = try await prepareVisionImage(taskID: UUID(), detail: .high)
      return (attachment.images.first?.jpeg, nil)
    } catch let error as VisionUnavailable {
      return (nil, error.speakable)
    } catch {
      return (nil, "The camera image could not be prepared.")
    }
  }

  private func prepareVisionImage(
    taskID: UUID,
    detail: VisionDetail
  ) async throws -> VisionAttachment {
    ledger.update(taskID) { $0.phase = .capturingFrame }
    refreshActivity()
    let source = captureSource()
    let background = UIApplication.shared.applicationState == .background

    switch source {
    case .off:
      throw VisionUnavailable(
        reason: "camera off",
        speakable: "The camera is turned off in the app, so nothing can be seen right now.")
    case .iPhoneCamera:
      guard let frame = await FrameStore.shared.waitForFreshFrame(
        maxAge: Self.maxFrameAge, timeout: 1.5, source: .iPhone) else {
        try Task.checkCancellation()
        throw VisionUnavailable(
          reason: "no fresh iPhone frame",
          speakable: "No fresh image arrived from the iPhone camera, so nothing can be described. Ask the user to point the phone at the subject and try again. Do not describe any earlier image.")
      }
      let selection = await selectFrame(source: .iPhone, fallback: frame, detail: detail)
      return try await buildVideoAttachment(selection, taskID: taskID, detail: detail, useCPU: background)
    case .glasses:
      if background, !LockedScreenVision.isEnabled {
        throw VisionUnavailable(
          reason: "vision with the screen locked is off",
          speakable: LockedScreenVision.offReason + " Tell the user briefly and do not describe any earlier image.")
      }
      let mode = GlassesVisionCaptureMode.current
      var triedPhoto = false
      if mode.prefersPhoto(for: detail), !background {
        triedPhoto = true
        if let photo = try await captureGlassesPhoto(taskID: taskID, detail: detail) { return photo }
      }
      if let frame = await FrameStore.shared.waitForFreshFrame(
        maxAge: Self.maxFrameAge, timeout: 2.0, source: .glasses) {
        let selection = await selectFrame(source: .glasses, fallback: frame, detail: detail)
        return try await buildVideoAttachment(selection, taskID: taskID, detail: detail, useCPU: background)
      }
      try Task.checkCancellation()
      // No fresh video frame (a stalled stream, or a decoder recovering while
      // the phone is locked): the glasses' own still photo. It does not need
      // the video decoder, so it also works in the background.
      if mode.allowsPhoto, !triedPhoto,
         let photo = try await captureGlassesPhoto(taskID: taskID, detail: detail) {
        return photo
      }
      let state = glassesStreamState().lowercased()
      let lifecycle = GlassesLifecycleMonitor.shared
      lifecycle.evaluate(reason: "vision request without a fresh frame")
      let reason: String
      if let specific = lifecycle.unavailableReason(transportIsRaw: glassesTransport() == "raw") {
        reason = specific
      } else if state.contains("paused") {
        reason = "The Ray-Ban camera stream is paused (a tap on the glasses' temple pauses it; tapping again resumes it)."
      } else if state.contains("waiting") || state.contains("starting") {
        reason = "The app is still waiting for the Ray-Ban camera to start."
      } else if state.contains("stopped") {
        reason = "The Ray-Ban camera stream is not running."
      } else {
        reason = "No fresh image arrived from the Ray-Ban camera in time."
      }
      throw VisionUnavailable(
        reason: "no fresh Ray-Ban image (stream: \(state))",
        speakable: "\(reason) Nothing can be described right now. Tell the user briefly and do not describe any earlier image.")
    }
  }

  /// Chooses among the recent frames of one source. Reading requests wait up
  /// to 0.4 s for a few more glasses frames when only one or two are fresh.
  private func selectFrame(
    source: FrameSourceKind,
    fallback: CapturedFrame,
    detail: VisionDetail
  ) async -> FrameSelection {
    let maxAge = Self.maxFrameAge
    var frames = FrameStore.shared.recentFrames(source: source, maxAge: maxAge)
    if detail == .high, source == .glasses {
      let deadline = CACurrentMediaTime() + 0.4
      while frames.count < 3, CACurrentMediaTime() < deadline, !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 50_000_000)
        frames = FrameStore.shared.recentFrames(source: source, maxAge: maxAge)
      }
    }
    let candidates = frames
    let selected = await Task.detached(priority: .userInitiated) {
      FrameSelector.select(from: candidates, maxAge: maxAge)
    }.value
    return selected ?? FrameSelection(
      frame: fallback, metrics: nil, available: 1, compared: 1,
      ageMs: Int((fallback.ageSeconds * 1_000).rounded()))
  }

  private func buildVideoAttachment(
    _ selection: FrameSelection,
    taskID: UUID,
    detail: VisionDetail,
    useCPU: Bool
  ) async throws -> VisionAttachment {
    let frame = selection.frame
    ledger.update(taskID) { $0.timeline.frameSelected = Date() }
    let pixelBuffer = frame.pixelBuffer
    let upscale = detail == .high && VisionAssistPreferences.upscale
    // The full image encodes while OCR runs.
    let fullTask = Task.detached(priority: .userInitiated) {
      VisionFrameEncoder.encode(pixelBuffer, detail: detail, useCPU: useCPU, allowUpscale: upscale)
    }
    let assist = await textAssist(CIImage(cvPixelBuffer: pixelBuffer), detail: detail, useCPU: useCPU)
    let encoded = await fullTask.value
    try Task.checkCancellation()
    guard FrameStore.shared.currentEpoch == frame.epoch else {
      throw VisionUnavailable(
        reason: "camera source changed during capture",
        speakable: "The camera was switched while the image was being prepared, so nothing is described. Ask the user to try again.")
    }
    guard let encoded else {
      throw VisionUnavailable(
        reason: "image encoding failed",
        speakable: "The camera image could not be prepared. Ask the user to try again.")
    }
    var info = VisionFrameInfo(
      kind: .video,
      source: frame.source.rawValue,
      sequence: frame.sequence,
      pixelFormat: FrameStore.fourCC(frame.pixelFormat),
      sourceWidth: frame.width, sourceHeight: frame.height,
      encodedWidth: encoded.width, encodedHeight: encoded.height,
      jpegQuality: encoded.quality, jpegBytes: encoded.jpeg.count,
      frameAgeMs: selection.ageMs, captureLatencyMs: nil, reencoded: true, detail: detail)
    info.selection = selection.summary + (assist.note.map { "; \($0)" } ?? "")
    info.upscaled = encoded.width > frame.width
    if frame.source == .glasses {
      let transport = glassesTransport()
      info.pipeline = "\(GlassesLifecycleMonitor.shared.state.rawValue) · \(transport) " +
        (transport == "raw" ? "SDK-decoded glasses sample" : "app-decoded glasses sample")
    } else {
      info.pipeline = "iPhone camera sample"
    }
    return finishAttachment(full: encoded.jpeg, assist: assist, info: info, taskID: taskID, profile: detail)
  }

  /// Optional, time-bounded help for reading requests: on-device OCR as a
  /// hint and an enlarged crop of the text region of the same frame.
  private struct TextAssist {
    var ocrText: String?
    var ocrSummary: String?
    var crop: VisionFrameEncoder.Output?
    var cropSummary: String?
    var note: String?
  }

  private func textAssist(_ image: CIImage, detail: VisionDetail, useCPU: Bool) async -> TextAssist {
    guard detail == .high, VisionAssistPreferences.textAssist else { return TextAssist() }
    var assist = TextAssist()
    guard let result = await OnDeviceTextRecognizer.recognize(image, timeout: 1.5) else {
      assist.note = "OCR timed out or failed"
      return assist
    }
    let confidence = Int((result.averageConfidence * 100).rounded())
    guard let text = OnDeviceTextRecognizer.promptText(result) else {
      assist.note = result.lines.isEmpty
        ? "OCR found no text (\(result.durationMs) ms)"
        : "OCR rejected \(result.lines.count) low-confidence lines (avg \(confidence)%)"
      return assist
    }
    assist.ocrText = text
    let languages = result.languages.isEmpty ? "default languages" : result.languages.joined(separator: "+")
    assist.ocrSummary = "\(result.lines.count) lines, avg \(confidence)%, \(result.durationMs) ms, \(languages)"
    if let region = OnDeviceTextRecognizer.focusRegion(for: result.lines) {
      let crop = await Task.detached(priority: .userInitiated) {
        VisionFrameEncoder.encodeCrop(image, normalizedRect: region, detail: detail, useCPU: useCPU)
      }.value
      if let crop {
        assist.crop = crop
        assist.cropSummary = String(
          format: "x %.2f y %.2f w %.2f h %.2f → %d×%d",
          region.minX, region.minY, region.width, region.height, crop.width, crop.height)
      }
    }
    return assist
  }

  private func finishAttachment(
    full: Data,
    assist: TextAssist,
    info: VisionFrameInfo,
    taskID: UUID,
    profile: VisionDetail
  ) -> VisionAttachment {
    var info = info
    var images = [VisionAttachment.Image(jpeg: full, role: "the full current view")]
    if let crop = assist.crop {
      images.append(VisionAttachment.Image(
        jpeg: crop.jpeg, role: "an enlarged crop of the text area of the same frame"))
      info.crop = assist.cropSummary
    }
    info.ocr = assist.ocrSummary
    info.totalImageBytes = images.reduce(0) { $0 + $1.jpeg.count }
    let prepared = info
    ledger.update(taskID) {
      $0.timeline.imagePrepared = Date()
      $0.frame = prepared
    }
    FrameStore.shared.recordVisionImage(prepared.summary)
    return VisionAttachment(images: images, ocrText: assist.ocrText, info: prepared, profile: profile)
  }

  /// Requests a new still photo from the glasses for this task only. Returns
  /// nil (so the caller can fall back to video) when the SDK refuses, times
  /// out, or the task stopped being current while waiting.
  private func captureGlassesPhoto(
    taskID: UUID,
    detail: VisionDetail
  ) async throws -> VisionAttachment? {
    guard let provider = glassesStillPhoto else { return nil }
    let requestedAt = Date()
    let still = await provider(4.0)
    try Task.checkCancellation()
    guard let still,
          let record = ledger.record(taskID), !record.phase.isTerminal else { return nil }
    let jpeg = still.jpeg
    let prepared = await Task.detached(priority: .userInitiated) {
      StillPhotoProcessor.prepare(jpeg, detail: detail)
    }.value
    try Task.checkCancellation()
    guard let prepared else { return nil }
    var assist = TextAssist()
    if let image = CIImage(data: jpeg, options: [.applyOrientationProperty: true]) {
      assist = await textAssist(image, detail: detail, useCPU: UIApplication.shared.applicationState == .background)
    }
    var info = VisionFrameInfo(
      kind: .photo,
      source: FrameSourceKind.glasses.rawValue,
      sequence: nil,
      pixelFormat: "JPEG",
      sourceWidth: still.width, sourceHeight: still.height,
      encodedWidth: prepared.width, encodedHeight: prepared.height,
      jpegQuality: prepared.quality, jpegBytes: prepared.jpeg.count,
      frameAgeMs: 0, captureLatencyMs: still.latencyMs, reencoded: prepared.reencoded, detail: detail)
    info.selection = assist.note
    ledger.update(taskID) {
      $0.timeline.frameSelected = requestedAt.addingTimeInterval(Double(still.latencyMs) / 1_000)
    }
    return finishAttachment(full: prepared.jpeg, assist: assist, info: info, taskID: taskID, profile: detail)
  }

  /// `detail` sent with input images. Codex sends "high" by default and never
  /// "low". The images this app sends already fit the high-detail budget
  /// (≤ 2048 px, ≤ 2500 patches), so "original" would not change anything.
  private func imageDetailValue(model: String, profile: VisionDetail) -> String {
    "high"
  }

  private func callModel(
    taskID: UUID,
    kind: AssistantTaskKind?,
    query: String,
    tools: [[String: Any]],
    attachment: VisionAttachment?,
    schema: (name: String, schema: [String: Any])? = nil,
    extraContext: String? = nil,
    directSearch: Bool = false,
    detail: VisionDetail = .standard
  ) async throws -> ResponsesResult {
    let usesWeb = tools.contains { ($0["type"] as? String) == "web_search" }
    let needsImages = attachment != nil
    let catalog = self.catalog
    guard let firstModel = ModelSelector.model(
      for: kind, available: availableModels, needsHostedWebSearch: usesWeb, catalog: catalog,
      needsImages: needsImages, excluded: ModelHealth.shared.failedThisRun) else {
      throw ResponsesError.failed("No compatible ChatGPT model is available for this account.")
    }
    ledger.update(taskID) {
      $0.model = firstModel
      $0.phase = usesWeb ? .searching : (kind == .deepReasoning ? .reasoning : (needsImages ? .analyzing : .reasoning))
    }
    refreshActivity()

    var imageDetail: String? = attachment.map { imageDetailValue(model: firstModel, profile: $0.profile) }
    if imageDetailRejected { imageDetail = nil }
    // Memory requests are answered from the store itself; other tasks get
    // the few saved memories relevant to the request.
    let memoryContext = kind == .localMemory ? [] : MemoryStore.shared.relevantItems(for: query)
    let contextText = context.promptContext(memory: memoryContext)
    let recentlyAdvised = lastRepositionAdviceAt.map { Date().timeIntervalSince($0) < 90 } ?? false
    var instructions = AssistantInstructions.executor(
      kind: kind,
      detectedLanguage: context.detectedLanguage,
      detail: detail,
      hasCrop: attachment?.hasCrop ?? false,
      hasOCR: attachment?.ocrText != nil,
      avoidRepositionAdvice: recentlyAdvised)
    if directSearch {
      instructions += "\nWeb search results are provided in the input. Base current facts only on them, " +
        "name the most relevant source briefly, and say so if they do not answer the request."
    }
    let sessionKey = sessionID.map { "autoloom-\($0.uuidString)" }

    func makeRequest(model: String, imageDetail: String?) -> ResponsesClient.Request {
      var content: [[String: Any]] = []
      if !contextText.isEmpty {
        content.append(["type": "input_text", "text": "Conversation context:\n\(contextText)"])
      }
      if let extraContext {
        content.append(["type": "input_text", "text": extraContext])
      }
      content.append(["type": "input_text", "text": "Request: \(query)"])
      if let attachment {
        for (index, image) in attachment.images.enumerated() {
          if attachment.images.count > 1 {
            content.append(["type": "input_text", "text": "Image \(index + 1): \(image.role)."])
          }
          var item: [String: Any] = [
            "type": "input_image",
            "image_url": "data:image/jpeg;base64,\(image.jpeg.base64EncodedString())",
          ]
          if let imageDetail { item["detail"] = imageDetail }
          content.append(item)
        }
        if let ocrText = attachment.ocrText {
          content.append([
            "type": "input_text",
            "text": "On-device OCR of image 1 (automatic, may contain mistakes; the images are authoritative):\n" +
              UntrustedContent.wrap(ocrText, origin: "on-device OCR of the camera image"),
          ])
        }
      }
      let info = catalog.first { $0.slug == model }
      var request = ResponsesClient.Request(
        model: model,
        instructions: instructions,
        input: [["role": "user", "content": content]])
      request.tools = tools
      // Only parameters the model advertises: an unsupported effort or
      // verbosity would get the request rejected.
      request.reasoningEffort = ModelRouting.effort(
        ModelSelector.reasoningEffort(for: kind), supported: info?.reasoningLevels ?? [])
      request.verbosity = (info?.supportsVerbosity ?? true)
        ? (AssistantPreferences.prefersDetailedAnswers ? "medium" : "low")
        : nil
      request.timeout = ModelSelector.timeout(for: kind)
      request.jsonSchema = schema
      request.promptCacheKey = sessionKey
      return request
    }

    if let imageDetail {
      ledger.update(taskID) { $0.frame?.imageDetail = imageDetail }
    }
    ledger.update(taskID) { $0.timeline.requestSent = Date() }
    if usesWeb { lastWebStatus = "Searching…" }
    let onProgress: @MainActor (ResponsesProgress) -> Void = { [weak self] progress in
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
        self.ledger.update(taskID) { $0.phase = needsImages ? .analyzing : .reasoning }
      }
      self.refreshActivity()
    }

    var model = firstModel
    var triedFallback = false
    var response: ResponsesResult?
    while response == nil {
      do {
        response = try await client.send(makeRequest(model: model, imageDetail: imageDetail), onProgress: onProgress)
      } catch ResponsesError.badRequest(let message)
        where imageDetail != nil && !usesWeb
          && (message.lowercased().contains("detail") || !ModelHealth.looksLikeModelProblem(message)) {
        // If the endpoint ever rejects the explicit image detail, the image is
        // still sent, with the service's default detail, for the rest of the run.
        imageDetailRejected = true
        imageDetail = nil
        NSLog("[AutoLoom] image detail rejected, retrying without it: %@", message)
        ledger.update(taskID) { $0.frame?.imageDetail = "service default (explicit detail rejected)" }
      } catch ResponsesError.badRequest(let message)
        where !triedFallback && !usesWeb && ModelHealth.looksLikeModelProblem(message) {
        // The chosen model was rejected (for example a newly listed model this
        // connection cannot use): record it and try the next best model once.
        ModelHealth.shared.recordFailure(model, message: message)
        triedFallback = true
        guard let fallback = ModelSelector.model(
          for: kind, available: availableModels, needsHostedWebSearch: usesWeb, catalog: catalog,
          needsImages: needsImages, excluded: ModelHealth.shared.failedThisRun),
          fallback != model else {
          throw ResponsesError.badRequest(message)
        }
        NSLog("[AutoLoom] model %@ rejected, falling back to %@", model, fallback)
        let failed = model
        model = fallback
        ledger.update(taskID) { $0.model = "\(fallback) (after \(failed) failed)" }
      }
    }
    guard let result = response else { throw ResponsesError.emptyResponse }
    ModelHealth.shared.recordSuccess(model)
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
    if localWork > 0 {
      activity = .saving
      return
    }
    let active = ledger.active
    let phases = active.map { ($0.kind, $0.phase) }
    let visual = active.filter { $0.phase == .capturingFrame || ($0.phase == .analyzing && $0.kind?.usesCamera == true) }
    if !visual.isEmpty {
      activity = visual.contains { $0.visionProfile == .high && $0.kind != .visualMemory } ? .reading : .seeing
    } else if active.contains(where: { $0.kind == .localMemory || $0.kind == .visualMemory }) {
      activity = .remembering
    } else if active.contains(where: { $0.kind == .authorizedAction }) {
      activity = .acting
    } else if phases.contains(where: { $0.1 == .searching }) {
      activity = .searching
    } else if !phases.isEmpty {
      activity = .thinking
    } else {
      activity = nil
    }
  }
}
