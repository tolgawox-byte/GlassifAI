import SwiftUI

/// Liquid Glass for the floating controls over the camera (iOS 26+), the
/// thin material before that. Only for the control layer — content cards
/// keep standard materials, and glass never sits on glass.
struct GlassBackground<S: Shape>: ViewModifier {
  let shape: S
  var tint: Color?
  var interactive = false

  @ViewBuilder
  func body(content: Content) -> some View {
    if #available(iOS 26.0, *) {
      content.glassEffect(Glass.regular.tint(tint).interactive(interactive), in: shape)
    } else {
      content.background {
        ZStack {
          shape.fill(.ultraThinMaterial)
          if let tint { shape.fill(tint.opacity(0.22)) }
        }
      }
    }
  }
}

extension View {
  func glassBackground<S: Shape>(in shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
    modifier(GlassBackground(shape: shape, tint: tint, interactive: interactive))
  }

  @ViewBuilder
  func glassButtonStyle(prominent: Bool = false) -> some View {
    if #available(iOS 26.0, *) {
      if prominent { buttonStyle(.glassProminent) } else { buttonStyle(.glass) }
    } else {
      if prominent { buttonStyle(.borderedProminent) } else { buttonStyle(.bordered) }
    }
  }

  @ViewBuilder
  func tabBarMinimizesOnScroll() -> some View {
    if #available(iOS 26.0, *) { tabBarMinimizeBehavior(.onScrollDown) } else { self }
  }
}

/// A group of neighbouring glass controls (they blend, and glass does not
/// sample glass); plain content before iOS 26.
struct GlassGroup<Content: View>: View {
  private let spacing: CGFloat?
  private let content: Content

  init(spacing: CGFloat? = nil, @ViewBuilder content: () -> Content) {
    self.spacing = spacing
    self.content = content()
  }

  var body: some View {
    if #available(iOS 26.0, *) {
      GlassEffectContainer(spacing: spacing) { content }
    } else {
      content
    }
  }
}
