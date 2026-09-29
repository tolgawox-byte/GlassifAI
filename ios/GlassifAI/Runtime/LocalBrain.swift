import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// The on-device brain: Apple's Foundation Models (iOS 26+, Apple
/// Intelligence devices) for small private jobs — classifying a request the
/// parser did not recognise, titling and tagging notes, extracting the
/// vehicle/person/place talked about, summarising, rewriting a search, and a
/// short offline answer. Never mandatory: without it the deterministic parser
/// and the cloud agents do the work. It never executes anything itself; it
/// proposes an ActionCatalog action that goes through the same policy as
/// speech, and it never pretends to replace the stronger cloud reasoning.
enum LocalBrain {
  /// Tasks with their own instructions (Dynamic Profiles on iOS 27).
  enum Profile: String, CaseIterable {
    case fastLocal, memory, dealer, document, translation, general

    var instructions: String {
      let base = "You run on the user's iPhone inside AutoLoom, a voice assistant for Ray-Ban glasses. The person's locale is tr_TR; answer in the user's language (Turkish unless they wrote English). Be brief, factual and never invent facts, names, prices or results."
      switch self {
      case .fastLocal:
        return base + " Map requests to the listed actions only; when none fits, answer none."
      case .memory:
        return base + " Work only with the notes and memories given to you; say plainly when something is not in them."
      case .dealer:
        return base + " The user works at a car dealership. Never state a VIN, option, price or condition that was not given; never say a car is safe to drive."
      case .document:
        return base + " Summarise documents faithfully; keep dates, amounts and names exactly as written."
      case .translation:
        return base + " Translate faithfully and briefly; do not add explanations."
      case .general:
        return base + " You are the offline fallback: answer only from general knowledge in one or two sentences and say when an answer needs the internet."
      }
    }

    var temperature: Double { self == .general ? 0.4 : 0.1 }
  }

  enum Status: Equatable {
    case ready
    case unavailable(String)
    case unsupportedOS
  }

  struct Classification: Equatable {
    let actionID: String
    let parameters: [String: String]
    let confidence: Int
  }

  struct Entities: Equatable {
    var vehicle: String?
    var person: String?
    var place: String?
    var product: String?
  }

  /// Settings → Intelligence → "Use the on-device model" (on by default when
  /// the device supports it; nothing leaves the phone).
  static let enabledKey = "autoloom.localBrain.enabled"
  static var isEnabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

  /// The reason the last request failed (diagnostics; no user content).
  nonisolated(unsafe) static var lastError: String?

  static var status: Status {
    #if canImport(FoundationModels)
    if #available(iOS 26.0, *) {
      switch SystemLanguageModel.default.availability {
      case .available: return .ready
      case .unavailable(.deviceNotEligible): return .unavailable("This iPhone does not support Apple Intelligence.")
      case .unavailable(.appleIntelligenceNotEnabled): return .unavailable("Apple Intelligence is turned off in Settings.")
      case .unavailable(.modelNotReady): return .unavailable("The on-device model is still downloading.")
      case .unavailable(let other): return .unavailable("Unavailable: \(other)")
      }
    }
    #endif
    return .unsupportedOS
  }

  static var isReady: Bool { isEnabled && status == .ready }

  /// Turkish needs iOS 26.1+ models; checked at runtime.
  static var supportsTurkish: Bool {
    #if canImport(FoundationModels)
    if #available(iOS 26.0, *) {
      return SystemLanguageModel.default.supportsLocale(Locale(identifier: "tr_TR"))
    }
    #endif
    return false
  }

  static var statusText: String {
    switch status {
    case .ready: supportsTurkish ? L.t("Ready (Turkish and English)", "Hazır (Türkçe ve İngilizce)") : L.t("Ready (no Turkish yet)", "Hazır (henüz Türkçe yok)")
    case .unavailable(let reason): reason
    case .unsupportedOS: L.t("Needs iOS 26 and Apple Intelligence", "iOS 26 ve Apple Intelligence gerekir")
    }
  }

  // MARK: Jobs

  /// The catalog action a request asks for, or nil (none, unsure, or no model).
  static func classify(_ text: String) async -> Classification? {
    guard isReady else { return nil }
    #if canImport(FoundationModels)
    if #available(iOS 26.0, *) {
      let actions = ActionCatalog.all
        .filter { $0.route == .local && $0.risk != .blocked && !$0.keys.contains(where: { $0.hasPrefix("confirmPending") }) }
        .prefix(60)
        .map { action -> String in
          let example = action.examplesTR.first.map { ActionCatalog.stripTags($0).text } ?? action.name
          return "\(action.id): \(action.name) (\"\(example)\")"
        }
        .joined(separator: "\n")
      let prompt = "Actions:\n\(actions)\n\nRequest: \(text)\nChoose the action id, or none."
      guard let choice: LocalActionChoice = await respond(prompt, profile: .fastLocal) else { return nil }
      let id = choice.actionID.trimmingCharacters(in: .whitespacesAndNewlines)
      guard id != "none", let definition = ActionCatalog.definition(id) else { return nil }
      var parameters: [String: String] = [:]
      let words = choice.text.trimmingCharacters(in: .whitespacesAndNewlines)
      if !words.isEmpty, let first = definition.parameters.first(where: { $0.kind != .date }) { parameters[first.name] = words }
      let when = choice.when.trimmingCharacters(in: .whitespacesAndNewlines)
      if !when.isEmpty, let dated = definition.parameters.first(where: { $0.kind == .date }) { parameters[dated.name] = when }
      return Classification(actionID: id, parameters: parameters, confidence: max(0, min(100, choice.confidence)))
    }
    #endif
    return nil
  }

  /// A short title and up to three tags for a note (in its own language).
  static func noteLabels(_ text: String) async -> (title: String, tags: [String])? {
    guard isReady, text.count >= 12 else { return nil }
    #if canImport(FoundationModels)
    if #available(iOS 26.0, *) {
      guard let labels: LocalNoteLabels = await respond("Note:\n\(text.prefix(1_500))", profile: .memory) else { return nil }
      let title = labels.title.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !title.isEmpty else { return nil }
      let tags = labels.tags.map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
      return (String(title.prefix(80)), Array(tags.prefix(3)))
    }
    #endif
    return nil
  }

  /// Vehicle, person, place and product mentioned in the user's words.
  static func entities(in text: String) async -> Entities? {
    guard isReady, text.count >= 6 else { return nil }
    #if canImport(FoundationModels)
    if #available(iOS 26.0, *) {
      guard let found: LocalEntities = await respond("Text: \(text.prefix(600))", profile: .fastLocal) else { return nil }
      func value(_ string: String) -> String? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed.lowercased() == "none" ? nil : trimmed
      }
      return Entities(
        vehicle: value(found.vehicle), person: value(found.person), place: value(found.place), product: value(found.product))
    }
    #endif
    return nil
  }

  /// A faithful summary in at most `sentences` sentences.
  static func summarize(_ text: String, sentences: Int = 3, profile: Profile = .document) async -> String? {
    guard isReady, !text.isEmpty else { return nil }
    return await respondText(
      "Summarise in at most \(sentences) sentences, keeping names, dates and amounts exactly:\n\(text.prefix(6_000))",
      profile: profile)
  }

  /// Other words for a search that found nothing ("Corolla lastiği" → "Toyota Corolla lastik tire").
  static func rewriteSearch(_ text: String) async -> String? {
    guard isReady else { return nil }
    return await respondText(
      "Rewrite this search into 3 to 6 keywords (both Turkish and English forms when useful), space separated, nothing else: \(text)",
      profile: .fastLocal)
  }

  /// A structured summary of a finished conversation, made on the phone
  /// (preferred over the cloud: the transcript never leaves the iPhone).
  static func conversationSummary(_ transcript: String, startedAt: Date) async -> ConversationSummary? {
    guard isReady, transcript.count >= 40 else { return nil }
    #if canImport(FoundationModels)
    if #available(iOS 26.0, *) {
      let prompt = "Conversation between the user and the assistant:\n" + String(transcript.suffix(6_000))
      guard let result: LocalConversationSummary = await respond(prompt, profile: .memory) else { return nil }
      let summary = result.summary.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !summary.isEmpty else { return nil }
      return ConversationSummary(
        summary: summary, topics: result.topics, decisions: result.decisions, openTasks: result.openTasks,
        entities: result.entities, startedAt: startedAt, endedAt: Date())
    }
    #endif
    return nil
  }

  /// A short offline answer, labelled as such by the caller.
  static func answerOffline(_ question: String) async -> String? {
    guard isReady else { return nil }
    return await respondText(question, profile: .general)
  }

  // MARK: Model calls

  static func respondText(_ prompt: String, profile: Profile) async -> String? {
    #if canImport(FoundationModels)
    if #available(iOS 26.0, *) {
      do {
        let session = makeSession(profile)
        let response = try await session.respond(to: prompt, options: GenerationOptions(temperature: profile.temperature))
        let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
      } catch {
        lastError = describe(error)
        return nil
      }
    }
    #endif
    return nil
  }

  #if canImport(FoundationModels)
  @available(iOS 26.0, *)
  static func respond<Content: Generable>(_ prompt: String, profile: Profile) async -> Content? {
    do {
      let session = makeSession(profile)
      return try await session.respond(
        to: prompt, generating: Content.self, options: GenerationOptions(temperature: profile.temperature)).content
    } catch {
      lastError = describe(error)
      return nil
    }
  }

  @available(iOS 26.0, *)
  static func makeSession(_ profile: Profile) -> LanguageModelSession {
    if #available(iOS 27.0, *) { return makeProfileSession(profile) }
    return LanguageModelSession(instructions: profile.instructions)
  }

  /// A short reason for diagnostics (no user content).
  @available(iOS 26.0, *)
  static func describe(_ error: Error) -> String {
    if let generation = error as? LanguageModelSession.GenerationError {
      switch generation {
      case .exceededContextWindowSize: return "context window exceeded"
      case .guardrailViolation: return "guardrail"
      case .unsupportedLanguageOrLocale: return "language not supported"
      case .rateLimited: return "rate limited"
      case .concurrentRequests: return "busy"
      default: return "generation error"
      }
    }
    return String(describing: type(of: error))
  }
  #endif
}

#if canImport(FoundationModels)
@available(iOS 26.0, *)
@Generable(description: "The AutoLoom action a spoken or typed request asks for")
struct LocalActionChoice {
  @Guide(description: "Exactly one action id from the list, or none when no action fits")
  var actionID: String
  @Guide(description: "The words the action needs (note text, task or reminder title, search words, item names); empty if none")
  var text: String
  @Guide(description: "The day or time exactly as said, for example yarın 10'da; empty if none")
  var when: String
  @Guide(description: "How sure, from 0 to 100", .range(0...100))
  var confidence: Int
}

@available(iOS 26.0, *)
@Generable(description: "A short title and topic tags for a note")
struct LocalNoteLabels {
  @Guide(description: "A title of at most six words, in the note's own language")
  var title: String
  @Guide(description: "Up to three one-word topic tags", .maximumCount(3))
  var tags: [String]
}

@available(iOS 26.0, *)
@Generable(description: "A summary of a finished conversation, for the user's own memory")
struct LocalConversationSummary {
  @Guide(description: "Two or three sentences: what was talked about and what came of it")
  var summary: String
  @Guide(description: "Main topics", .maximumCount(4))
  var topics: [String]
  @Guide(description: "Decisions that were made", .maximumCount(3))
  var decisions: [String]
  @Guide(description: "Things the user still has to do", .maximumCount(3))
  var openTasks: [String]
  @Guide(description: "Names of people, places, vehicles or products", .maximumCount(5))
  var entities: [String]
}

@available(iOS 26.0, *)
@Generable(description: "Things named in a short text; empty when not mentioned")
struct LocalEntities {
  @Guide(description: "A vehicle make and model, for example Honda Civic; empty if none")
  var vehicle: String
  @Guide(description: "A person's name; empty if none")
  var person: String
  @Guide(description: "A place or address; empty if none")
  var place: String
  @Guide(description: "A product or part; empty if none")
  var product: String
}
#endif
