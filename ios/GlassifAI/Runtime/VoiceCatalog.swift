import Foundation

/// A realtime voice the app can offer.
struct RealtimeVoiceOption: Identifiable, Equatable {
  let id: String
  /// ChatGPT's own short description of the voice.
  let english: String
  let turkish: String

  var displayName: String { id.capitalized }
  var character: String { L.t(english, turkish) }
}

/// The voices ChatGPT's live voice accepts on the protocol this app uses.
///
/// The app talks to `gpt-live-1-codex` with Codex's frameless (v3) realtime
/// protocol. Codex allows only the nine voices below for it
/// (`RealtimeVoicesList::builtin().v1`, enforced by `validate_realtime_voice`;
/// the native bridge has a test that pins the same list). The older
/// realtime-API voices (Alloy, Ash, Ballad, Coral, Echo, Sage, Shimmer, Verse,
/// Marin, Cedar) belong to the other protocol. Earlier builds offered those;
/// the start was rejected and the app silently fell back to the baseline
/// configuration, which always speaks with Juniper.
enum VoiceCatalog {
  static let defaultVoice = "juniper"
  /// The unsupported voice that a migration replaced, shown once in Settings.
  static let migratedFromKey = "autoloom.voice.migratedFrom"

  static let voices: [RealtimeVoiceOption] = [
    RealtimeVoiceOption(id: "juniper", english: "Open and upbeat", turkish: "Açık ve neşeli"),
    RealtimeVoiceOption(id: "maple", english: "Cheerful and candid", turkish: "Neşeli ve içten"),
    RealtimeVoiceOption(id: "spruce", english: "Calm and affirming", turkish: "Sakin ve güven veren"),
    RealtimeVoiceOption(id: "ember", english: "Confident and optimistic", turkish: "Özgüvenli ve iyimser"),
    RealtimeVoiceOption(id: "vale", english: "Bright and inquisitive", turkish: "Canlı ve meraklı"),
    RealtimeVoiceOption(id: "breeze", english: "Animated and earnest", turkish: "Hareketli ve samimi"),
    RealtimeVoiceOption(id: "arbor", english: "Easygoing and versatile", turkish: "Rahat ve çok yönlü"),
    RealtimeVoiceOption(id: "sol", english: "Savvy and relaxed", turkish: "Bilgili ve rahat"),
    RealtimeVoiceOption(id: "cove", english: "Composed and direct", turkish: "Ölçülü ve net"),
  ]

  /// Voices of the other realtime protocol, offered by earlier builds.
  static let unsupportedLegacyVoices: Set<String> = [
    "alloy", "ash", "ballad", "cedar", "coral", "echo", "marin", "sage", "shimmer", "verse",
  ]

  static var ids: [String] { voices.map(\.id) }

  static func isSupported(_ id: String) -> Bool { ids.contains(id) }

  static func option(_ id: String) -> RealtimeVoiceOption? { voices.first { $0.id == id } }

  static func displayName(_ id: String?) -> String {
    guard let id, !id.isEmpty else { return "—" }
    return id.capitalized
  }

  /// Replaces a stored voice that this protocol cannot use with the default
  /// and remembers what was replaced, so Settings can explain it.
  @discardableResult
  static func migrateStoredSelection(_ defaults: UserDefaults = .standard) -> String? {
    guard let stored = defaults.string(forKey: AssistantPreferences.voiceKey), !isSupported(stored) else {
      return nil
    }
    defaults.set(defaultVoice, forKey: AssistantPreferences.voiceKey)
    defaults.set(stored, forKey: migratedFromKey)
    return stored
  }
}

/// One attempt in the realtime start sequence.
enum RealtimeStartStep: String, Equatable {
  /// AutoLoom instructions, the selected voice and the resume context.
  case full
  /// The same without the resume context (initial items can be rejected).
  case withoutResume
  /// AutoLoom instructions with the default voice.
  case defaultVoice
  /// The original device-verified configuration (GlassifAI instructions, Juniper).
  case baseline

  var label: String {
    switch self {
    case .full: "AutoLoom, selected voice"
    case .withoutResume: "AutoLoom, selected voice, no resume context"
    case .defaultVoice: "AutoLoom, default voice (fallback)"
    case .baseline: "Baseline instructions and voice (fallback)"
    }
  }

  /// Whether this step keeps the voice the user selected.
  var keepsSelectedVoice: Bool { self == .full || self == .withoutResume }
}

/// What the last realtime start asked for and what it really got. Shown as
/// "Selected" and "Active" voice in Settings and in Developer diagnostics.
struct RealtimeStartReport: Equatable {
  var requestedVoice: String
  var requestedModel: String
  var activeVoice: String?
  var activeModel: String?
  var step: RealtimeStartStep?
  /// Why the first attempt failed; nil when it worked.
  var fallbackReason: String?
  var attempts: [String] = []
  var startedAt = Date()
  var connectMs: Int?
  var isPreview = false

  var voiceMatches: Bool { activeVoice == requestedVoice }
}

/// The order of start attempts. Each later step removes one thing that could
/// have caused the rejection, and every failure is recorded instead of being
/// hidden behind a silent fallback.
enum RealtimeStartLadder {
  static func steps(
    requestedVoice: String,
    hasResume: Bool,
    defaultVoice: String = VoiceCatalog.defaultVoice
  ) -> [RealtimeStartStep] {
    var steps: [RealtimeStartStep] = [.full]
    if hasResume { steps.append(.withoutResume) }
    if requestedVoice != defaultVoice { steps.append(.defaultVoice) }
    steps.append(.baseline)
    return steps
  }

  /// A voice rejection is not fixed by dropping the resume context.
  static func shouldSkip(_ step: RealtimeStartStep, after error: String) -> Bool {
    step == .withoutResume && error.lowercased().contains("voice")
  }

  /// A short reason for Settings and diagnostics (sanitized).
  static func reason(from error: String?) -> String {
    let text = LogSanitizer.sanitize(error ?? "no answer", limit: 200)
    let lower = text.lowercased()
    if lower.contains("voice") { return "ChatGPT rejected the voice: " + text }
    if lower.contains("401") || lower.contains("unauthorized") { return "Sign-in expired: " + text }
    if lower.contains("429") || lower.contains("rate limit") { return "Rate limited: " + text }
    return text
  }
}

/// The short line spoken by "Preview voice".
enum VoicePreview {
  static func greeting(name: String, voice: String, turkish: Bool) -> String {
    turkish
      ? "Merhaba, ben \(name). \(VoiceCatalog.displayName(voice)) sesi böyle duyuluyor."
      : "Hi, I'm \(name). This is the \(VoiceCatalog.displayName(voice)) voice."
  }
}
