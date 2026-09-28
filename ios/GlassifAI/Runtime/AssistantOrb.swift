import SwiftUI

/// The assistant's visual state, in one word for the main screen.
enum AssistantPresence: Equatable {
  case ready
  case connecting
  case listening
  case thinking
  case looking
  case reading
  case searching
  case remembering
  case saving
  case acting
  case speaking
  case muted
  case error(String)

  static func resolve(
    state: GlassifAIRealtimeSession.State,
    activity: AssistantActivity?,
    muted: Bool
  ) -> AssistantPresence {
    if case .failed(let message) = state { return .error(message) }
    if muted, state != .disconnected, state != .connecting { return .muted }
    switch activity {
    case .seeing: return .looking
    case .reading: return .reading
    case .searching: return .searching
    case .remembering: return .remembering
    case .saving: return .saving
    case .acting: return .acting
    case .thinking: return .thinking
    case nil: break
    }
    switch state {
    case .disconnected: return .ready
    case .connecting: return .connecting
    case .listening: return .listening
    case .thinking: return .thinking
    case .speaking: return .speaking
    case .failed(let message): return .error(message)
    }
  }

  var word: String {
    switch self {
    case .ready: L.t("Ready", "Hazır")
    case .connecting: L.t("Connecting", "Bağlanıyor")
    case .listening: L.t("Listening", "Dinliyor")
    case .thinking: L.t("Thinking", "Düşünüyor")
    case .looking: L.t("Looking", "Bakıyor")
    case .reading: L.t("Reading", "Okuyor")
    case .searching: L.t("Searching", "Arıyor")
    case .remembering: L.t("Remembering", "Hatırlıyor")
    case .saving: L.t("Saving", "Kaydediyor")
    case .acting: L.t("Working on it", "Hallediyor")
    case .speaking: L.t("Speaking", "Konuşuyor")
    case .muted: L.t("Microphone off", "Mikrofon kapalı")
    case .error(let message): FriendlyError.message(for: message).title
    }
  }

  var mood: OrbMood {
    switch self {
    case .ready: .idle
    case .connecting: .connecting
    case .listening: .listening
    case .thinking, .looking, .reading, .searching, .remembering, .saving, .acting: .working
    case .speaking: .speaking
    case .muted: .muted
    case .error: .error
    }
  }

  var color: Color { mood.color }
}

enum OrbMood: Equatable {
  case idle
  case connecting
  case listening
  case working
  case speaking
  case muted
  case error

  var color: Color {
    switch self {
    case .idle: AutoLoomTheme.electricBlue.opacity(0.75)
    case .connecting: AutoLoomTheme.electricBlue
    case .listening: Color(red: 0.25, green: 0.78, blue: 1.0)
    case .working: Color(red: 0.55, green: 0.42, blue: 1.0)
    case .speaking: Color(red: 0.20, green: 0.62, blue: 1.0)
    case .muted: Color.gray
    case .error: Color(red: 1.0, green: 0.35, blue: 0.35)
    }
  }

  /// Breathing speed and depth.
  fileprivate var pulse: (speed: Double, depth: Double) {
    switch self {
    case .idle: (0.6, 0.03)
    case .connecting: (1.4, 0.05)
    case .listening: (1.8, 0.07)
    case .working: (1.1, 0.04)
    case .speaking: (3.2, 0.09)
    case .muted: (0.4, 0.01)
    case .error: (0.8, 0.02)
    }
  }

  fileprivate var rotationSpeed: Double {
    switch self {
    case .working: 140
    case .connecting: 90
    case .speaking: 60
    default: 22
    }
  }
}

/// A calm animated orb that shows the assistant's state when the camera is
/// off and inside the voice button.
struct AssistantOrb: View {
  let mood: OrbMood
  var size: CGFloat = 220
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { context in
      let time = context.date.timeIntervalSinceReferenceDate
      let pulse = mood.pulse
      let breathe = reduceMotion ? 0 : sin(time * pulse.speed * .pi) * pulse.depth
      let wave = reduceMotion ? 0 : sin(time * pulse.speed * 2.3 * .pi) * pulse.depth * 0.6
      let angle = reduceMotion ? 0 : time * mood.rotationSpeed
      ZStack {
        Circle()
          .fill(RadialGradient(
            colors: [mood.color.opacity(0.45), mood.color.opacity(0.0)],
            center: .center, startRadius: size * 0.12, endRadius: size * 0.5))
          .scaleEffect(1 + breathe * 1.6)
        Circle()
          .fill(AngularGradient(
            colors: [mood.color, .white.opacity(0.85), mood.color.opacity(0.4), mood.color],
            center: .center, angle: .degrees(angle)))
          .frame(width: size * 0.58, height: size * 0.58)
          .blur(radius: size * 0.07)
          .scaleEffect(1 + wave)
        Circle()
          .fill(RadialGradient(
            colors: [.white.opacity(0.95), mood.color.opacity(0.9)],
            center: UnitPoint(x: 0.4, y: 0.35), startRadius: 1, endRadius: size * 0.24))
          .frame(width: size * 0.36, height: size * 0.36)
          .scaleEffect(1 + breathe)
          .shadow(color: mood.color.opacity(0.8), radius: size * 0.1)
      }
      .frame(width: size, height: size)
    }
    .accessibilityHidden(true)
  }
}
