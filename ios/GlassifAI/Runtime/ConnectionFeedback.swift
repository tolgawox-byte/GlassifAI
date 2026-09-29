import AVFoundation
import Foundation

/// Where a realtime start is. "Ready" is announced only when every
/// essential piece works: ChatGPT accepted the session, WebRTC and its data
/// channel are open, the microphone route is up and, when the glasses are
/// preferred, their audio route is selected.
enum ConnectionPhase: String, Equatable {
  case idle = "Idle"
  case wakeDetected = "WakeDetected"
  case preparingAudio = "PreparingAudio"
  case connectingRealtime = "ConnectingRealtime"
  case waitingForDataChannel = "WaitingForDataChannel"
  case routingAudio = "RoutingAudio"
  case ready = "Ready"
  case failed = "Failed"
}

/// One step of the last start, for Settings → Developer → Voice diagnostics.
struct ConnectionStep: Identifiable, Equatable {
  let id = UUID()
  let phase: ConnectionPhase
  /// Milliseconds since the start began.
  let atMs: Int
  var detail: String?
}

/// What the user hears when a new conversation is ready: a chime, the
/// spoken phrase ("Bağlandım, dinliyorum."), both, or nothing. Said once per
/// new conversation; an automatic reconnect only chimes.
enum ConnectionFeedback: String, CaseIterable, Identifiable {
  case chimeAndVoice
  case voice
  case chime
  case off

  /// The key of the earlier "activation feedback" setting, so a choice the
  /// user made there is kept.
  static let defaultsKey = "autoloom.activation.feedback"

  var id: String { rawValue }

  static var current: ConnectionFeedback {
    let stored = UserDefaults.standard.string(forKey: defaultsKey)
    switch stored {
    case "subtle"?: return .chime
    case "voiceOnly"?: return .voice
    case let raw?: return ConnectionFeedback(rawValue: raw) ?? .chimeAndVoice
    case nil: return .chimeAndVoice
    }
  }

  /// Rewrites a value stored by the earlier setting ("subtle", "voiceOnly").
  static func migrateStoredValue(_ defaults: UserDefaults = .standard) {
    switch defaults.string(forKey: defaultsKey) {
    case "subtle"?: defaults.set(ConnectionFeedback.chime.rawValue, forKey: defaultsKey)
    case "voiceOnly"?: defaults.set(ConnectionFeedback.voice.rawValue, forKey: defaultsKey)
    case "off"?, nil: break
    case let raw?:
      if ConnectionFeedback(rawValue: raw) == nil { defaults.removeObject(forKey: defaultsKey) }
    }
  }

  var label: String {
    switch self {
    case .chimeAndVoice: L.t("Chime + voice", "Ses + konuşma")
    case .voice: L.t("Voice only", "Yalnızca konuşma")
    case .chime: L.t("Chime only", "Yalnızca ses")
    case .off: L.t("Off", "Kapalı")
    }
  }

  var playsChime: Bool { self == .chime || self == .chimeAndVoice }
  var speaks: Bool { self == .voice || self == .chimeAndVoice }

  /// The phrase for a new conversation that became ready. Starts with the
  /// on-screen button only chime: the user is looking at the screen.
  @MainActor
  static func readyPhrase(for reason: VoiceStartReason, turkish: Bool) -> String? {
    guard reason != .button, current.speaks else { return nil }
    guard let text = GreetingStyle.current.text(
      turkish: turkish, custom: UserDefaults.standard.string(forKey: GreetingStyle.customTextKey) ?? "") else { return nil }
    // Jarvis Style: "Bağlantı hazır. Sizi dinliyorum efendim."
    return JarvisStyle.greeting(text, turkish: turkish, profileName: MemoryStore.shared.profile.preferredName)
  }

  static func failureText(turkish: Bool) -> String {
    turkish ? "Bağlantı kurulamadı." : "The connection could not be established."
  }

  static func glassesLostText(turkish: Bool) -> String {
    turkish ? "Ray-Ban bağlantısı koptu." : "The Ray-Ban connection dropped."
  }
}

/// Short tones generated in memory (no bundled audio files). They play on
/// the app's own audio session, so they reach the glasses when those are
/// the audio route, and are not muted by the ring/silent switch.
@MainActor
final class ChimePlayer {
  static let shared = ChimePlayer()

  enum Sound {
    case ready
    case reconnected
    case failed
  }

  private var player: AVAudioPlayer?

  func play(_ sound: Sound) {
    let tones: [(frequency: Double, seconds: Double)]
    switch sound {
    case .ready: tones = [(880, 0.09), (1_318.5, 0.16)]
    case .reconnected: tones = [(1_318.5, 0.08)]
    case .failed: tones = [(659.3, 0.12), (440, 0.24)]
    }
    guard let data = Self.wav(tones: tones) else { return }
    do {
      let player = try AVAudioPlayer(data: data)
      player.volume = 0.45
      player.prepareToPlay()
      player.play()
      self.player = player
    } catch {
      NSLog("[AutoLoom] chime failed: %@", LogSanitizer.sanitize(error.localizedDescription, limit: 120))
    }
  }

  /// 16-bit mono PCM WAV with short fades.
  nonisolated static func wav(tones: [(frequency: Double, seconds: Double)], sampleRate: Double = 44_100) -> Data? {
    var samples: [Int16] = []
    for tone in tones {
      let count = Int(tone.seconds * sampleRate)
      guard count > 0 else { continue }
      let fade = max(1, min(count / 4, Int(0.012 * sampleRate)))
      for index in 0..<count {
        var amplitude = 0.35
        if index < fade { amplitude *= Double(index) / Double(fade) }
        if index > count - fade { amplitude *= Double(count - index) / Double(fade) }
        let value = sin(2 * Double.pi * tone.frequency * Double(index) / sampleRate) * amplitude
        samples.append(Int16(value * Double(Int16.max)))
      }
    }
    guard !samples.isEmpty else { return nil }
    var data = Data()
    func append<T: FixedWidthInteger>(_ value: T) {
      var little = value.littleEndian
      withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }
    let byteCount = samples.count * 2
    data.append(contentsOf: Array("RIFF".utf8))
    append(UInt32(36 + byteCount))
    data.append(contentsOf: Array("WAVE".utf8))
    data.append(contentsOf: Array("fmt ".utf8))
    append(UInt32(16))
    append(UInt16(1))
    append(UInt16(1))
    append(UInt32(sampleRate))
    append(UInt32(sampleRate * 2))
    append(UInt16(2))
    append(UInt16(16))
    data.append(contentsOf: Array("data".utf8))
    append(UInt32(byteCount))
    for sample in samples { append(sample) }
    return data
  }
}

/// On-device Apple speech for the few moments the realtime voice cannot
/// speak: a connection that failed or dropped. Never used for the live
/// conversation itself.
@MainActor
final class LocalAnnouncer {
  static let shared = LocalAnnouncer()

  private let synthesizer = AVSpeechSynthesizer()

  func say(_ text: String, turkish: Bool) {
    try? AVAudioSession.sharedInstance().setActive(true)
    let utterance = AVSpeechUtterance(string: text)
    utterance.voice = Self.voice(turkish: turkish, jarvis: JarvisStyle.isEnabled)
    synthesizer.stopSpeaking(at: .immediate)
    synthesizer.speak(utterance)
  }

  /// The best installed voice: premium, then enhanced; Jarvis Style
  /// prefers a British English male voice for English.
  static func voice(turkish: Bool, jarvis: Bool) -> AVSpeechSynthesisVoice? {
    let language = turkish ? "tr-TR" : (jarvis ? "en-GB" : "en-US")
    let candidates = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == language }
    let best = candidates.max { rank($0, jarvis: jarvis) < rank($1, jarvis: jarvis) }
    return best ?? AVSpeechSynthesisVoice(language: language)
  }

  private static func rank(_ voice: AVSpeechSynthesisVoice, jarvis: Bool) -> Int {
    var score = 0
    switch voice.quality {
    case .premium: score += 20
    case .enhanced: score += 10
    default: break
    }
    if jarvis, voice.gender == .male { score += 5 }
    return score
  }
}

/// "Jarvis Style": a legally safe persona, not a voice clone. The closest
/// available ChatGPT voice (chosen from ChatGPT's own descriptions) plus
/// instructions for a composed, courteous, quietly witty delivery. It never
/// imitates an actor or quotes a film.
enum JarvisStyle {
  static let enabledKey = "autoloom.voice.jarvisStyle"
  /// The voice selected before Jarvis Style was turned on (restored after).
  static let previousVoiceKey = "autoloom.voice.beforeJarvis"
  /// "Composed and direct" in ChatGPT's own words: the closest of the nine
  /// voices this protocol accepts. The user can pick another one.
  static let suggestedVoice = "cove"

  static var isEnabled: Bool {
    UserDefaults.standard.bool(forKey: enabledKey)
  }


  /// Turns the style on or off, switching to the suggested voice (and back
  /// to the earlier voice when it is turned off).
  static func setEnabled(_ enabled: Bool, defaults: UserDefaults = .standard) {
    guard enabled != defaults.bool(forKey: enabledKey) else { return }
    defaults.set(enabled, forKey: enabledKey)
    let current = defaults.string(forKey: AssistantPreferences.voiceKey) ?? VoiceCatalog.defaultVoice
    if enabled {
      defaults.set(current, forKey: previousVoiceKey)
      defaults.set(suggestedVoice, forKey: AssistantPreferences.voiceKey)
    } else if current == suggestedVoice,
              let previous = defaults.string(forKey: previousVoiceKey), VoiceCatalog.isSupported(previous) {
      defaults.set(previous, forKey: AssistantPreferences.voiceKey)
    }
  }
}
