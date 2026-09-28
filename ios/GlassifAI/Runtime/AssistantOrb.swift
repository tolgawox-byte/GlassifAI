import QuartzCore
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

  /// The orb follows the real state: nothing looks like listening before the
  /// realtime audio is ready, and nothing looks like saving after a failure.
  var mood: OrbMood {
    switch self {
    case .ready: .idle
    case .connecting: .connecting
    case .listening: .listening
    case .thinking, .remembering, .acting: .thinking
    case .searching: .searching
    case .looking, .reading: .looking
    case .saving: .saving
    case .speaking: .speaking
    case .muted: .muted
    case .error: .error
    }
  }

  var color: Color { mood.color }
}

enum OrbMood: Equatable {
  /// Very slow breathing.
  case idle
  /// A rotating arc while the conversation connects.
  case connecting
  /// Follows the microphone's energy.
  case listening
  /// A slow orbital highlight.
  case thinking
  /// The same orbit, faster.
  case searching
  /// A soft radar-like pulse.
  case looking
  /// Rings that follow the assistant's voice.
  case speaking
  /// A short check mark.
  case saving
  /// A brief blue-silver confirmation.
  case success
  case muted
  /// A restrained amber pulse.
  case error

  var color: Color {
    switch self {
    case .idle: AutoLoomTheme.electricBlue.opacity(0.8)
    case .connecting: AutoLoomTheme.electricBlue
    case .listening: Color(red: 0.25, green: 0.78, blue: 1.0)
    case .thinking: Color(red: 0.55, green: 0.44, blue: 1.0)
    case .searching: Color(red: 0.40, green: 0.52, blue: 1.0)
    case .looking: Color(red: 0.22, green: 0.84, blue: 0.86)
    case .speaking: Color(red: 0.20, green: 0.62, blue: 1.0)
    case .saving: AutoLoomTheme.electricBlue
    case .success: Color(red: 0.70, green: 0.84, blue: 1.0)
    case .muted: Color.gray
    case .error: Color(red: 1.0, green: 0.52, blue: 0.30)
    }
  }
}

/// A calm animated orb for the assistant's state, drawn natively in one
/// Canvas pass (no image assets, no stacked blur layers). With Reduce Motion
/// it is a still image of the same state.
struct AssistantOrb: View {
  let mood: OrbMood
  var size: CGFloat = 220
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var moodStartedAt = Date()

  var body: some View {
    TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: reduceMotion)) { timeline in
      Canvas { context, canvasSize in
        OrbPainter(
          mood: mood,
          time: reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate,
          elapsed: reduceMotion ? 10 : timeline.date.timeIntervalSince(moodStartedAt),
          level: reduceMotion ? 0 : OrbPainter.audioLevel(for: mood)
        ).paint(in: &context, size: canvasSize)
      }
    }
    .frame(width: size, height: size)
    .onChange(of: mood) { _, _ in moodStartedAt = Date() }
    .accessibilityHidden(true)
  }
}

struct OrbPainter {
  let mood: OrbMood
  let time: Double
  /// Seconds since the mood changed, for one-shot animations.
  let elapsed: Double
  /// Smoothed microphone or voice level, 0...1.
  let level: Double

  static func audioLevel(for mood: OrbMood) -> Double {
    switch mood {
    case .listening: AudioLevelMeter.shared.level(.input)
    case .speaking: AudioLevelMeter.shared.level(.output)
    default: 0
    }
  }

  /// Breathing speed (cycles per second) and depth for each mood.
  static func breathing(for mood: OrbMood) -> (speed: Double, depth: Double) {
    switch mood {
    case .idle: (0.18, 0.03)
    case .connecting: (0.8, 0.035)
    case .listening: (0.45, 0.03)
    case .thinking, .searching, .looking: (0.35, 0.025)
    case .speaking: (0.7, 0.02)
    case .saving, .success: (0.3, 0.02)
    case .muted: (0.12, 0.01)
    case .error: (0.55, 0.04)
    }
  }

  func paint(in context: inout GraphicsContext, size: CGSize) {
    let radius = min(size.width, size.height) / 2
    let center = CGPoint(x: size.width / 2, y: size.height / 2)
    let color = mood.color
    let breath = Self.breathing(for: mood)
    let breathe = sin(time * breath.speed * 2 * .pi) * breath.depth

    // Glow.
    let glowRadius = radius * (0.8 + breathe * 1.4 + level * 0.18)
    context.fill(
      circle(center, glowRadius),
      with: .radialGradient(
        Gradient(colors: [color.opacity(0.42), color.opacity(0.12), color.opacity(0)]),
        center: center, startRadius: radius * 0.1, endRadius: glowRadius))

    // Behind the core.
    switch mood {
    case .connecting: connectingArc(&context, center, radius)
    case .looking: radar(&context, center, radius)
    case .speaking: voiceRings(&context, center, radius)
    case .listening:
      context.stroke(
        circle(center, radius * (0.5 + level * 0.12)),
        with: .color(color.opacity(0.12 + level * 0.5)), lineWidth: radius * 0.016)
    case .success: successRing(&context, center, radius)
    default: break
    }

    // Core with a soft highlight.
    let coreRadius = radius * 0.34 * (1 + breathe * 0.8 + level * 0.3)
    let highlight = CGPoint(x: center.x - coreRadius * 0.3, y: center.y - coreRadius * 0.36)
    context.fill(
      circle(center, coreRadius),
      with: .radialGradient(
        Gradient(colors: [.white.opacity(0.95), color.opacity(0.95), color.opacity(0.55)]),
        center: highlight, startRadius: 0, endRadius: coreRadius * 1.3))
    // A slow sheen around the core.
    if mood != .muted {
      context.stroke(
        circle(center, coreRadius * 1.1),
        with: .conicGradient(
          Gradient(colors: [.white.opacity(0), .white.opacity(0.32), .white.opacity(0)]),
          center: center, angle: .degrees(time * 24)),
        lineWidth: radius * 0.012)
    }

    // In front of the core.
    switch mood {
    case .thinking: orbit(&context, center, radius, count: 2, period: 2.6)
    case .searching: orbit(&context, center, radius, count: 3, period: 1.3)
    case .saving: checkMark(&context, center, radius)
    default: break
    }
  }

  private func connectingArc(_ context: inout GraphicsContext, _ center: CGPoint, _ radius: CGFloat) {
    let ring = radius * 0.6
    let start = (time / 1.4).truncatingRemainder(dividingBy: 1) * 360
    var arc = Path()
    arc.addArc(center: center, radius: ring, startAngle: .degrees(start), endAngle: .degrees(start + 110), clockwise: false)
    context.stroke(arc, with: .color(mood.color.opacity(0.9)), style: StrokeStyle(lineWidth: radius * 0.035, lineCap: .round))
    let pulse = 0.5 + 0.5 * sin(time * 2 * .pi / 1.4)
    context.stroke(circle(center, ring), with: .color(mood.color.opacity(0.1 + 0.1 * pulse)), lineWidth: radius * 0.012)
  }

  private func radar(_ context: inout GraphicsContext, _ center: CGPoint, _ radius: CGFloat) {
    for offset in [0.0, 0.5] {
      let progress = (time / 1.8 + offset).truncatingRemainder(dividingBy: 1)
      context.stroke(
        circle(center, radius * (0.38 + 0.55 * progress)),
        with: .color(mood.color.opacity(0.45 * (1 - progress))), lineWidth: radius * 0.018)
    }
  }

  private func voiceRings(_ context: inout GraphicsContext, _ center: CGPoint, _ radius: CGFloat) {
    let wobble = 0.5 + 0.5 * sin(time * 2 * .pi * 1.1)
    for index in 0..<3 {
      let step = Double(index)
      let ring = radius * (0.46 + 0.1 * step + level * (0.16 + 0.05 * step) + 0.01 * wobble)
      context.stroke(
        circle(center, ring),
        with: .color(mood.color.opacity(0.4 - 0.11 * step)), lineWidth: radius * (0.02 - 0.004 * step))
    }
  }

  private func orbit(_ context: inout GraphicsContext, _ center: CGPoint, _ radius: CGFloat, count: Int, period: Double) {
    for index in 0..<count {
      let phase = (time / period + Double(index) / Double(count)).truncatingRemainder(dividingBy: 1)
      let angle = phase * 2 * .pi
      let point = CGPoint(
        x: center.x + cos(angle) * radius * 0.58,
        y: center.y + sin(angle) * radius * 0.58 * 0.6)
      // Brighter on the near side of the tilted orbit.
      let depth = (sin(angle) + 1) / 2
      let dot = radius * (0.03 + 0.02 * depth)
      context.fill(
        circle(point, dot * 2.8),
        with: .radialGradient(
          Gradient(colors: [mood.color.opacity(0.4 * (0.5 + depth)), mood.color.opacity(0)]),
          center: point, startRadius: 0, endRadius: dot * 2.8))
      context.fill(circle(point, dot), with: .color(.white.opacity(0.55 + 0.4 * depth)))
    }
  }

  private func checkMark(_ context: inout GraphicsContext, _ center: CGPoint, _ radius: CGFloat) {
    let progress = min(1, elapsed / 0.45)
    let unit = radius * 0.15
    var path = Path()
    path.move(to: CGPoint(x: center.x - unit, y: center.y + unit * 0.05))
    path.addLine(to: CGPoint(x: center.x - unit * 0.3, y: center.y + unit * 0.7))
    path.addLine(to: CGPoint(x: center.x + unit * 1.05, y: center.y - unit * 0.65))
    context.stroke(
      path.trimmedPath(from: 0, to: progress),
      with: .color(.white),
      style: StrokeStyle(lineWidth: radius * 0.045, lineCap: .round, lineJoin: .round))
  }

  private func successRing(_ context: inout GraphicsContext, _ center: CGPoint, _ radius: CGFloat) {
    let progress = min(1, elapsed / 0.9)
    guard progress < 1 else { return }
    context.stroke(
      circle(center, radius * (0.36 + 0.6 * progress)),
      with: .color(AutoLoomTheme.silver.opacity(0.75 * (1 - progress))),
      lineWidth: radius * 0.03 * (1 - progress * 0.6))
  }

  private func circle(_ center: CGPoint, _ radius: CGFloat) -> Path {
    Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
  }
}
