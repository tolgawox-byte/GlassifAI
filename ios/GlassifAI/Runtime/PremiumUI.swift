import SwiftUI

// MARK: - Buttons

/// Buttons that give slightly under the finger (no scaling with Reduce
/// Motion).
struct PressableButtonStyle: ButtonStyle {
  var scale: CGFloat = 0.94

  func makeBody(configuration: Configuration) -> some View {
    PressableButtonBody(configuration: configuration, scale: scale)
  }
}

private struct PressableButtonBody: View {
  let configuration: ButtonStyleConfiguration
  let scale: CGFloat
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    configuration.label
      .scaleEffect(configuration.isPressed && !reduceMotion ? scale : 1)
      .opacity(configuration.isPressed ? 0.85 : 1)
      .animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.62), value: configuration.isPressed)
  }
}

// MARK: - Connection status

extension GlassesUserStatus.Tone {
  var color: Color {
    switch self {
    case .connected: Color(red: 0.25, green: 0.86, blue: 0.52)
    case .working: AutoLoomTheme.electricBlue
    case .attention: Color(red: 1.0, green: 0.62, blue: 0.22)
    case .idle: AutoLoomTheme.silver.opacity(0.7)
    }
  }
}

/// "● Ray-Ban Connected": the glasses link in two words at the top of the
/// Assistant screen. The dot pulses only while something is in progress.
struct ConnectionStatusPill: View {
  let status: GlassesUserStatus
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var pulsing = false

  var body: some View {
    HStack(spacing: 7) {
      ZStack {
        if status.tone == .working && !reduceMotion {
          Circle()
            .stroke(status.tone.color.opacity(0.7), lineWidth: 1.5)
            .frame(width: 14, height: 14)
            .scaleEffect(pulsing ? 1.3 : 0.6)
            .opacity(pulsing ? 0 : 0.9)
            .animation(.easeOut(duration: 1.2).repeatForever(autoreverses: false), value: pulsing)
        }
        Circle()
          .fill(status.tone.color)
          .frame(width: 7, height: 7)
          .shadow(color: status.tone.color.opacity(0.8), radius: status.tone == .connected ? 4 : 0)
      }
      .frame(width: 14, height: 14)
      Text(status.title)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.white.opacity(0.92))
        .lineLimit(1)
        .contentTransition(.opacity)
    }
    .padding(.horizontal, 11)
    .padding(.vertical, 6)
    .background(.ultraThinMaterial, in: Capsule())
    .overlay(Capsule().strokeBorder(.white.opacity(0.08)))
    .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: status)
    .onAppear { pulsing = true }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(status.title + (status.detail.map { ", " + $0 } ?? ""))
  }
}

/// A one-line confirmation when the glasses link comes up (never spoken).
struct ConnectedToast: View {
  var body: some View {
    Label(L.t("Ray-Ban Connected", "Ray-Ban bağlı"), systemImage: "checkmark.circle.fill")
      .font(.subheadline.weight(.semibold))
      .symbolRenderingMode(.hierarchical)
      .foregroundStyle(.white)
      .padding(.horizontal, 14)
      .padding(.vertical, 8)
      .background(.ultraThinMaterial, in: Capsule())
      .overlay(Capsule().strokeBorder(GlassesUserStatus.Tone.connected.color.opacity(0.5)))
      .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
      .accessibilityAddTraits(.isStaticText)
  }
}

// MARK: - Glasses link animation

/// The link animation's states, taken from the real connection phase so it
/// never shows "connected" before the glasses are.
enum GlassesLinkVisual: Equatable {
  /// Soft ring: not registered, or the glasses are asleep.
  case idle
  /// Rotating, pulsing ring: registration or the link is in progress.
  case searching
  /// The ring contracts into the centre: the glasses are linked, the camera
  /// is starting.
  case found
  /// A short glow expansion, then a calm glow.
  case connected
  /// A restrained amber pulse: something needs the user.
  case attention

  static func from(_ phase: GlassesConnectionPhase) -> GlassesLinkVisual {
    switch phase {
    case .restoring, .registrationStarting, .waitingForMetaAI, .deviceConnecting:
      .searching
    case .deviceConnected, .requestingCameraPermission, .startingCamera, .cameraStreaming:
      .found
    case .ready:
      .connected
    case .registrationStalled, .cameraPermissionNeeded, .cameraFailed, .sdkUnavailable:
      .attention
    case .notRegistered, .registeredNoDevice, .deviceDisconnected:
      .idle
    }
  }

  var color: Color {
    switch self {
    case .idle: AutoLoomTheme.silver
    case .searching, .found: AutoLoomTheme.electricBlue
    case .connected: GlassesUserStatus.Tone.connected.color
    case .attention: GlassesUserStatus.Tone.attention.color
    }
  }
}

struct GlassesLinkAnimation: View {
  let visual: GlassesLinkVisual
  var size: CGFloat = 170
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var changedAt = Date()

  var body: some View {
    TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: reduceMotion)) { timeline in
      Canvas { context, canvasSize in
        LinkPainter(
          visual: visual,
          time: reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate,
          elapsed: reduceMotion ? 10 : timeline.date.timeIntervalSince(changedAt)
        ).paint(in: &context, size: canvasSize)
      }
    }
    .frame(width: size, height: size)
    .overlay {
      Image(systemName: "eyeglasses")
        .font(.system(size: size * 0.2, weight: .light))
        .foregroundStyle(.white.opacity(0.92))
    }
    .onChange(of: visual) { _, _ in changedAt = Date() }
    .accessibilityHidden(true)
  }
}

private struct LinkPainter {
  let visual: GlassesLinkVisual
  let time: Double
  let elapsed: Double

  func paint(in context: inout GraphicsContext, size: CGSize) {
    let radius = min(size.width, size.height) / 2
    let center = CGPoint(x: size.width / 2, y: size.height / 2)
    let color = visual.color

    // A calm disc behind the glasses symbol.
    context.fill(
      circle(center, radius * 0.36),
      with: .radialGradient(
        Gradient(colors: [color.opacity(0.28), AutoLoomTheme.deepNavy.opacity(0.9)]),
        center: center, startRadius: 0, endRadius: radius * 0.36))

    switch visual {
    case .idle:
      let breathe = 0.5 + 0.5 * sin(time * 2 * .pi / 3.2)
      context.stroke(circle(center, radius * 0.52), with: .color(color.opacity(0.18 + 0.12 * breathe)), lineWidth: radius * 0.014)

    case .searching:
      let pulse = (time / 1.6).truncatingRemainder(dividingBy: 1)
      context.stroke(
        circle(center, radius * (0.46 + 0.44 * pulse)),
        with: .color(color.opacity(0.35 * (1 - pulse))), lineWidth: radius * 0.012)
      let start = (time / 1.3).truncatingRemainder(dividingBy: 1) * 360
      var arc = Path()
      arc.addArc(center: center, radius: radius * 0.52, startAngle: .degrees(start), endAngle: .degrees(start + 115), clockwise: false)
      context.stroke(arc, with: .color(color.opacity(0.95)), style: StrokeStyle(lineWidth: radius * 0.035, lineCap: .round))
      context.stroke(circle(center, radius * 0.52), with: .color(color.opacity(0.14)), lineWidth: radius * 0.012)

    case .found:
      // Contracts from the outside into a steady ring.
      let progress = easeOut(min(1, elapsed / 0.7))
      let ring = radius * (0.9 - 0.44 * progress)
      context.stroke(circle(center, ring), with: .color(color.opacity(0.35 + 0.5 * progress)), lineWidth: radius * 0.03)
      let breathe = 0.5 + 0.5 * sin(time * 2 * .pi / 2)
      context.stroke(circle(center, radius * 0.56), with: .color(color.opacity(0.1 + 0.1 * breathe * progress)), lineWidth: radius * 0.012)

    case .connected:
      // One glow expansion, then a calm halo.
      let progress = min(1, elapsed / 0.9)
      if progress < 1 {
        context.fill(
          circle(center, radius * (0.4 + 0.6 * progress)),
          with: .radialGradient(
            Gradient(colors: [color.opacity(0.4 * (1 - progress)), color.opacity(0)]),
            center: center, startRadius: radius * 0.3, endRadius: radius * (0.4 + 0.6 * progress)))
      }
      context.stroke(circle(center, radius * 0.46), with: .color(color.opacity(0.75)), lineWidth: radius * 0.028)

    case .attention:
      let pulse = 0.5 + 0.5 * sin(time * 2 * .pi / 1.8)
      context.fill(
        circle(center, radius * (0.62 + 0.08 * pulse)),
        with: .radialGradient(
          Gradient(colors: [color.opacity(0.22 * pulse), color.opacity(0)]),
          center: center, startRadius: radius * 0.3, endRadius: radius * (0.62 + 0.08 * pulse)))
      context.stroke(circle(center, radius * 0.48), with: .color(color.opacity(0.55 + 0.3 * pulse)), lineWidth: radius * 0.024)
    }
  }

  private func easeOut(_ t: Double) -> Double { 1 - pow(1 - t, 3) }

  private func circle(_ center: CGPoint, _ radius: CGFloat) -> Path {
    Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
  }
}
