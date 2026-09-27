import Foundation

/// A structured delegation written by the realtime voice model, e.g.
/// `TASK: web | QUERY: Ottawa weather today`. The voice model already
/// understands the user's intent; the envelope carries that decision to the
/// client, which verifies it before acting.
struct DelegationEnvelope: Equatable {
  enum Command: Equatable {
    case task(AssistantTaskKind)
    case cancel
  }

  let command: Command
  let query: String
  /// Image detail the vision step should use (reading text, badges, VINs…).
  var detail: VisionDetail = .standard
}

enum DelegationEnvelopeParser {
  /// Vision tasks that need fine detail (text, labels, badges, screens).
  private static let readTasks: Set<String> = ["vision_read", "read", "read_text", "vision_text", "ocr"]

  private static let aliases: [String: DelegationEnvelope.Command] = [
    "vision": .task(.vision), "see": .task(.vision), "camera": .task(.vision), "look": .task(.vision),
    "vision_read": .task(.vision), "read": .task(.vision), "read_text": .task(.vision),
    "vision_text": .task(.vision), "ocr": .task(.vision),
    "web": .task(.webSearch), "web_search": .task(.webSearch), "search": .task(.webSearch),
    "internet": .task(.webSearch), "browse": .task(.webSearch),
    "vision_web": .task(.visionPlusWeb), "vision+web": .task(.visionPlusWeb),
    "vision_plus_web": .task(.visionPlusWeb), "visual_search": .task(.visionPlusWeb),
    "reasoning": .task(.deepReasoning), "deep_reasoning": .task(.deepReasoning),
    "think": .task(.deepReasoning), "analysis": .task(.deepReasoning),
    "memory": .task(.localMemory), "local_memory": .task(.localMemory), "remember": .task(.localMemory),
    "action": .task(.authorizedAction), "authorized_action": .task(.authorizedAction),
    "chat": .task(.generalChat), "general": .task(.generalChat), "general_chat": .task(.generalChat),
    "cancel": .cancel, "cancel_task": .cancel, "stop_task": .cancel,
  ]

  private static let lineFormat = try? NSRegularExpression(
    pattern: #"(?is)\btask\s*[:=]\s*([a-z_+\- ]{2,30}?)\s*(?:\||;|,|\n)\s*query\s*[:=]\s*(.*)$"#)
  private static let taskOnly = try? NSRegularExpression(
    pattern: #"(?is)^\s*task\s*[:=]\s*([a-z_+\-]{2,30})\s*$"#)

  static func parse(_ raw: String) -> DelegationEnvelope? {
    let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, text.count <= 4_000 else { return nil }
    if let envelope = parseJSON(text) { return envelope }
    let range = NSRange(text.startIndex..., in: text)
    if let match = lineFormat?.firstMatch(in: text, range: range),
       let taskRange = Range(match.range(at: 1), in: text),
       let queryRange = Range(match.range(at: 2), in: text) {
      return make(task: String(text[taskRange]), query: String(text[queryRange]))
    }
    if let match = taskOnly?.firstMatch(in: text, range: range),
       let taskRange = Range(match.range(at: 1), in: text) {
      return make(task: String(text[taskRange]), query: "")
    }
    return nil
  }

  private static func parseJSON(_ text: String) -> DelegationEnvelope? {
    guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
          let data = String(text[start...end]).data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let task = (object["task"] ?? object["type"] ?? object["route"]) as? String else { return nil }
    let query = (object["query"] ?? object["request"] ?? object["prompt"]) as? String ?? ""
    var envelope = make(task: task, query: query)
    if (object["detail"] as? String)?.lowercased() == "high", envelope?.command == .task(.vision) {
      envelope?.detail = .high
    }
    return envelope
  }

  private static func make(task: String, query: String) -> DelegationEnvelope? {
    let key = task.trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
      .replacingOccurrences(of: " ", with: "_")
      .replacingOccurrences(of: "-", with: "_")
    guard let command = aliases[key] else { return nil }
    let cleanedQuery = query
      .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'`")))
    if case .task = command, cleanedQuery.isEmpty { return nil }
    // Reading text and identifying a product to research both depend on fine
    // detail, so they use the high-detail image profile.
    let detail: VisionDetail = readTasks.contains(key) || command == .task(.visionPlusWeb) ? .high : .standard
    return DelegationEnvelope(command: command, query: String(cleanedQuery.prefix(1_500)), detail: detail)
  }
}

/// The user's personal name for the assistant (for example "Jarvis"). It is
/// identity and conversation context only — the system wake phrase is
/// controlled by Meta/Apple, not by this setting.
enum AssistantIdentity {
  static let nameKey = "autoloom.assistant.name"
  static let defaultName = "AutoLoom"
  static let maxLength = 24

  /// Returns a cleaned name, or nil when the input is not a usable name.
  static func sanitize(_ raw: String) -> String? {
    let allowedPunctuation = CharacterSet(charactersIn: " -.'’")
    let filtered = raw.unicodeScalars.filter {
      CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) || allowedPunctuation.contains($0)
    }
    let collapsed = String(String.UnicodeScalarView(filtered))
      .split(whereSeparator: { $0 == " " })
      .joined(separator: " ")
      .trimmingCharacters(in: CharacterSet(charactersIn: " -.'’"))
    guard !collapsed.isEmpty,
          collapsed.count <= maxLength,
          collapsed.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) }) else { return nil }
    return collapsed
  }

  static var name: String {
    sanitize(UserDefaults.standard.string(forKey: nameKey) ?? "") ?? defaultName
  }

  /// Stores a name; invalid input falls back to the default.
  @discardableResult
  static func setName(_ raw: String) -> String {
    let value = sanitize(raw) ?? defaultName
    UserDefaults.standard.set(value, forKey: nameKey)
    return value
  }
}

/// User-facing preferences that shape the assistant's behaviour.
enum AssistantPreferences {
  static let languageKey = "autoloom.voice.language"
  static let verbosityKey = "autoloom.voice.verbosity"
  static let voiceKey = "autoloom.voice.name"
  static let webSearchKey = "autoloom.web.enabled"
  static let regionKey = "autoloom.web.region"
  static let previewModeKey = "autoloom.camera.previewMode"
  static let debugOverlayKey = "autoloom.camera.debugOverlay"
  static let addressedOnlyKey = "autoloom.assistant.addressedOnly"

  /// Experimental: inside an active conversation, answer only when the user
  /// addresses the assistant by name. Not a wake word — the microphone is
  /// only live while a conversation is running.
  static var respondsOnlyWhenAddressed: Bool {
    UserDefaults.standard.bool(forKey: addressedOnlyKey)
  }

  static let defaultVoice = "juniper"
  static let voices = [
    "juniper", "alloy", "ash", "ballad", "cedar", "coral", "echo", "marin", "sage", "shimmer", "verse",
  ]

  static var language: String {
    UserDefaults.standard.string(forKey: languageKey) ?? "auto"
  }

  static var prefersDetailedAnswers: Bool {
    UserDefaults.standard.string(forKey: verbosityKey) == "detailed"
  }

  static var voice: String {
    let value = UserDefaults.standard.string(forKey: voiceKey) ?? defaultVoice
    return voices.contains(value) ? value : defaultVoice
  }

  static var webSearchEnabled: Bool {
    UserDefaults.standard.object(forKey: webSearchKey) as? Bool ?? true
  }

  static var region: String {
    UserDefaults.standard.string(forKey: regionKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  }

  static var usesLegacyPreview: Bool {
    UserDefaults.standard.string(forKey: previewModeKey) == "legacy"
  }

  static var showsDebugOverlay: Bool {
    UserDefaults.standard.bool(forKey: debugOverlayKey)
  }

  static func languageInstruction(detected: String?) -> String {
    switch language {
    case "tr": "Always speak Turkish."
    case "en": "Always speak English."
    default:
      "Reply in the language the user is speaking" +
        (detected.map { " (currently \($0))" } ?? "") +
        "; if unsure, use Turkish when the user speaks Turkish."
    }
  }
}

/// Instructions for the realtime voice model and the delegated executor.
enum AssistantInstructions {
  static func realtime(memory: [String], assistantName: String = AssistantIdentity.name) -> String {
    let detail = AssistantPreferences.prefersDetailedAnswers
      ? "Give fuller answers (up to about six sentences) unless the user asks for brevity."
      : "Default to short spoken answers of one to three sentences; go into detail only when asked (for example \"detaylı anlat\", \"tell me more\")."
    var text = """
    Your name is \(assistantName). You are a warm, natural, general-purpose voice assistant in the AutoLoom Media Glasses app on the user's iPhone and Meta smart glasses. It is an independent app by AutoLoom Media, not an official OpenAI, ChatGPT, Meta, or Ray-Ban product.

    Your name:
    - The user may address you by name ("\(assistantName), what am I looking at?", "Thanks \(assistantName)"). Treat the name as getting your attention, not as part of the request.
    - Do not start answers with your name and do not keep introducing yourself; say your name only when asked who you are.

    How to talk:
    - Sound like a helpful friend: natural, fluent, relaxed. \(detail)
    - \(AssistantPreferences.languageInstruction(detected: nil)) Keep that language for follow-ups unless the user switches.
    - Track the conversation: earlier topics, products, budgets, places, and choices. Resolve follow-ups like "that one", "the cheaper one", "az önce konuştuğumuz".
    - If the user says stop, "dur", "sus", or starts talking over you, stop immediately and listen. If they change the subject, follow the new subject.
    - Never read URLs aloud and never repeat yourself.

    You cannot see or browse on your own. Delegate to the client only when it is really needed:
    - vision: the answer depends on what the user is looking at right now.
    - vision_read: the user wants something read or examined in fine detail — a sign, document, screen, label, badge, VIN, model number, price, menu, or warning message.
    - web: anything current or changeable (news, weather, prices, stock, store hours, schedules, sports, recent events) or an explicit request to look something up online.
    - vision_web: identify what the user is looking at, then research it online (prices, reviews, specs, where to buy).
    - reasoning: complex analysis, calculations, planning, or careful comparisons.
    - memory: the user asks you to remember, recall, or forget something about them.
    - cancel: the user asks to cancel the task in progress ("görevi iptal et", "cancel that").
    Do not delegate ordinary conversation, opinions, explanations, or general knowledge — answer those yourself right away.

    When you delegate, the delegation text must be exactly one line in this format:
    TASK: <vision|vision_read|web|vision_web|reasoning|memory|cancel> | QUERY: <complete, self-contained request in the user's language, including relevant details from the conversation such as product, budget, city, and date>

    When the client returns context, answer naturally and briefly from it. For web results, name the main source briefly (for example "Environment Canada'ya göre"). If the client reports that something is unavailable (camera off, no fresh frame, search failed, feature not supported), say so honestly. Never guess what the camera shows, never describe an earlier image as the current view, never invent facts, prices, or sources, and never claim to have done something you did not do.
    """
    if AssistantPreferences.respondsOnlyWhenAddressed {
      text += "\n\nAddressed-only mode is on: respond only when the user clearly addresses you as \(assistantName). If speech is not addressed to you (for example the user is talking to someone else), stay silent and do not delegate."
    }
    let region = AssistantPreferences.region
    if !region.isEmpty {
      text += "\n\nThe user is usually in \(region); use it for local questions unless they name another place."
    }
    if !memory.isEmpty {
      text += "\n\nThings the user asked this app to remember:\n" + memory.prefix(20).map { "- \($0)" }.joined(separator: "\n")
    }
    return text
  }

  static func executor(
    kind: AssistantTaskKind?,
    detectedLanguage: String?,
    detail: VisionDetail = .standard
  ) -> String {
    let formatter = DateFormatter()
    formatter.dateStyle = .full
    formatter.timeStyle = .short
    formatter.locale = Locale(identifier: "en_US_POSIX")
    let now = formatter.string(from: Date())
    let timeZone = TimeZone.current.identifier
    let length = AssistantPreferences.prefersDetailedAnswers
      ? "Up to six short sentences."
      : "One to three short sentences, unless the request explicitly asks for detail (then up to eight)."
    var text = """
    You are the perception and research engine behind AutoLoom Media Glasses, a voice assistant on smart glasses. Your answer is handed to a voice model that will speak it, so write plain spoken text: no markdown, no bullet lists, no URLs, no emojis. Put the direct answer first. \(length)
    \(AssistantPreferences.languageInstruction(detected: detectedLanguage))
    Be concrete and honest. State uncertainty instead of guessing. Never invent facts, numbers, prices, or sources.
    Current date and time: \(now) (time zone \(timeZone)).
    \(UntrustedContent.policy)
    """
    let region = AssistantPreferences.region
    if !region.isEmpty { text += "\nThe user's usual location: \(region)." }
    text += "\nThe user calls the assistant \"\(AssistantIdentity.name)\"; you do not need to mention that name."
    switch kind {
    case .vision:
      text += "\nAn image of the user's current first-person view is attached. Answer only from what is visible in it. Read visible text carefully. If the image is blurry, dark, or does not show what was asked, say so and suggest how to aim the camera."
      if detail == .high {
        text += " This is a reading request: transcribe the relevant text exactly as written, keeping letters, digits, units, and codes exact (for example VINs, model numbers, prices, warning messages). Say which parts are unreadable or cut off instead of guessing them; for long documents give the key lines."
      }
    case .webSearch:
      text += "\nUse web search for this request. Base factual claims on the search results, prefer official and recent sources, include dates for time-sensitive facts, and mention the most relevant source name briefly (for example \"according to Environment Canada\"). If results conflict or are missing, say so."
    case .visionPlusWeb:
      text += "\nAn image of the user's current first-person view is attached. First identify the item precisely from the image (brand, model, visible text). Then use web search about that item. Say what you identified, then the researched answer with the source name. If you cannot identify it confidently, say so instead of searching for a guess."
    case .deepReasoning:
      text += "\nThink the problem through carefully, then give the conclusion first in plain spoken language, followed by the key reason."
    case .localMemory:
      text += "\nYou manage the user's on-device memory list. Only add items the user explicitly asked to remember; only forget items they asked to forget. Reply with a short confirmation or the recalled information."
    case .generalChat, .authorizedAction:
      text += "\nAnswer conversationally."
    case nil:
      text += "\nDecide what you need. Use web search for anything current or changeable. Call look_at_camera only when the answer depends on what the user is looking at right now. Otherwise answer directly."
    }
    return text
  }
}

/// Picks the executor model from the account's available models.
/// - Vision and other tool-free tasks keep the device-verified original
///   choice: `gpt-5.6-sol` when present, otherwise the first listed model.
/// - Tasks that need the hosted web-search tool prefer `gpt-5.5`, which uses
///   the classic Responses shape that supports hosted tools in upstream Codex.
enum ModelSelector {
  static let overrideKey = "autoloom.model.override"
  static let baselineVisionModel = "gpt-5.6-sol"
  static let hostedToolPreference = ["gpt-5.5", "gpt-5.6-sol"]

  static func model(for kind: AssistantTaskKind?, available: [String], needsHostedWebSearch: Bool = false) -> String? {
    if let override = UserDefaults.standard.string(forKey: overrideKey),
       !override.isEmpty, available.contains(override) {
      return override
    }
    if needsHostedWebSearch,
       let preferred = hostedToolPreference.first(where: { available.contains($0) }) {
      return preferred
    }
    return available.first(where: { $0 == baselineVisionModel }) ?? available.first
  }

  static func reasoningEffort(for kind: AssistantTaskKind?) -> String {
    kind == .deepReasoning ? "medium" : "low"
  }

  static func timeout(for kind: AssistantTaskKind?) -> TimeInterval {
    switch kind {
    case .deepReasoning: 90
    case .webSearch, .visionPlusWeb, nil: 50
    default: 35
    }
  }
}

/// Hosted tools passed to the Responses endpoint.
enum AssistantTools {
  static let lookAtCameraName = "look_at_camera"
  static let searchWebName = "search_web"

  /// Hosted search, live results (Codex's "live" web-search mode).
  static var webSearch: [String: Any] {
    ["type": "web_search", "external_web_access": true]
  }

  /// Client-executed search used when the hosted tool is unavailable.
  static var searchWebFunction: [String: Any] {
    [
      "type": "function",
      "name": searchWebName,
      "description": "Search the live web. Use for anything current or changeable (news, weather, prices, store hours, schedules) or when the user asks to look something up.",
      "strict": true,
      "parameters": [
        "type": "object",
        "properties": [
          "query": ["type": "string", "description": "A focused web search query."],
        ],
        "required": ["query"],
        "additionalProperties": false,
      ] as [String: Any],
    ]
  }

  static var lookAtCamera: [String: Any] {
    [
      "type": "function",
      "name": lookAtCameraName,
      "description": "Get a fresh image of what the user is looking at right now through their glasses or phone camera. Call only when the request depends on the current view.",
      "strict": true,
      "parameters": [
        "type": "object",
        "properties": [
          "focus": [
            "type": "string",
            "description": "What to look for in the image, in the user's words.",
          ],
          "also_search_web": [
            "type": "boolean",
            "description": "True when the item in view must also be researched online (prices, reviews, specs).",
          ],
          "detail": [
            "type": "string",
            "enum": ["standard", "high"],
            "description": "high when text or fine detail must be read (signs, labels, screens, badges, VINs, prices); otherwise standard.",
          ],
        ],
        "required": ["focus", "also_search_web", "detail"],
        "additionalProperties": false,
      ] as [String: Any],
    ]
  }

  static var memorySchema: (name: String, schema: [String: Any]) {
    (
      name: "memory_update",
      schema: [
        "type": "object",
        "properties": [
          "reply": ["type": "string"],
          "add": ["type": "array", "items": ["type": "string"]],
          "forget": ["type": "array", "items": ["type": "string"]],
        ],
        "required": ["reply", "add", "forget"],
        "additionalProperties": false,
      ]
    )
  }
}
