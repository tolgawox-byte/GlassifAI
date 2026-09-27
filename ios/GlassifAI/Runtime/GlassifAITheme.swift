import SwiftUI

/// AutoLoom Media brand constants. Internal type and module names keep the
/// original GlassifAI prefix so the working project structure is unchanged.
enum AutoLoomBrand {
  static let appName = "AutoLoom Media Glasses"
  static let company = "AutoLoom Media"
  static let tagline = "See it. Ask it. Understand it."
  static let independenceNotice =
    "AutoLoom Media Glasses is an independent app by AutoLoom Media. It is not made, endorsed, or " +
    "supported by OpenAI, ChatGPT, Meta, Ray-Ban, or EssilorLuxottica. ChatGPT and OpenAI are " +
    "trademarks of OpenAI; Meta and Ray-Ban Meta are trademarks of their respective owners."
}

enum AutoLoomTheme {
  static let electricBlue = Color(red: 0.10, green: 0.56, blue: 1.00)
  static let deepNavy = Color(red: 0.03, green: 0.07, blue: 0.16)
  static let midnight = Color(red: 0.01, green: 0.02, blue: 0.05)
  static let silver = Color(red: 0.84, green: 0.87, blue: 0.92)

  static let background = LinearGradient(
    colors: [deepNavy, midnight],
    startPoint: .top,
    endPoint: .bottom)

  static let markGradient = LinearGradient(
    colors: [silver, electricBlue],
    startPoint: .leading,
    endPoint: .trailing)
}

/// Kept for existing call sites; now maps to the AutoLoom palette.
enum GlassifAITheme {
  static let accent = AutoLoomTheme.electricBlue
  static let markGradient = AutoLoomTheme.markGradient
}

struct GlassifAIBackdrop: View {
  var body: some View {
    ZStack {
      AutoLoomTheme.background
      RadialGradient(
        colors: [AutoLoomTheme.electricBlue.opacity(0.16), .clear],
        center: .top,
        startRadius: 10,
        endRadius: 420)
    }
    .ignoresSafeArea()
  }
}

/// The AutoLoom "A" symbol, derived from the brand logo (asset `BrandMark`).
struct AutoLoomMark: View {
  let size: CGFloat

  var body: some View {
    Image("BrandMark")
      .resizable()
      .scaledToFit()
      .frame(width: size, height: size * 0.56)
      .accessibilityHidden(true)
  }
}

/// Kept for existing call sites (onboarding, glasses setup).
struct GlassifAIMark: View {
  let size: CGFloat

  var body: some View {
    AutoLoomMark(size: size)
  }
}

struct GlassifAIPanelModifier: ViewModifier {
  func body(content: Content) -> some View {
    content
      .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
          .stroke(AutoLoomTheme.electricBlue.opacity(0.25), lineWidth: 0.6)
      }
  }
}

extension View {
  func glassifAIPanel() -> some View {
    modifier(GlassifAIPanelModifier())
  }
}
