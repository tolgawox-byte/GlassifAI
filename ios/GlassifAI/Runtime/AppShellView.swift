import SwiftUI

enum AppTab: String, Hashable {
  case assistant
  case memory
  case tasks
  case explore
  case settings
}

/// The app's tabs: Assistant, Memory, Tasks, Explore and Settings.
struct AppShellView: View {
  let captureSource: CaptureSource
  @ObservedObject var glassesStream: StreamSessionViewModel
  @ObservedObject var voice: GlassifAIRealtimeSession
  @ObservedObject var camera: GlassifAICamera
  @ObservedObject var connection: WearableConnectionCoordinator

  @State private var tab: AppTab = .assistant
  @AppStorage(AssistantPreferences.languageKey) private var language = "auto"
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// The connect screen only while Meta AI registration is really needed:
  /// an app that is already registered goes straight to the Assistant, and
  /// the first seconds after launch wait for the SDK to restore it.
  private var needsGlassesSetup: Bool {
    captureSource == .glasses && connection.phase.needsSetupScreen
  }

  var body: some View {
    TabView(selection: $tab) {
      assistantTab
        .tabItem { Label(L.t("Assistant", "Asistan"), systemImage: "waveform") }
        .tag(AppTab.assistant)
      MemoryTabView()
        .tabItem { Label(L.t("Memory", "Hafıza"), systemImage: "brain") }
        .tag(AppTab.memory)
      TasksTabView()
        .tabItem { Label(L.t("Tasks", "Görevler"), systemImage: "checklist") }
        .tag(AppTab.tasks)
      ExploreTabView()
        .tabItem { Label(L.t("Explore", "Keşfet"), systemImage: "square.grid.2x2") }
        .tag(AppTab.explore)
      SettingsView(voice: voice, glassesStream: glassesStream, connection: connection)
        .tabItem { Label(L.t("Settings", "Ayarlar"), systemImage: "gearshape") }
        .tag(AppTab.settings)
    }
    .tint(AutoLoomTheme.electricBlue)
    .preferredColorScheme(.dark)
    .sensoryFeedback(.selection, trigger: tab)
  }

  private var assistantTab: some View {
    ZStack {
      if needsGlassesSetup {
        HomeScreenView(connection: connection)
          .transition(.opacity)
      } else {
        AssistantHomeView(
          captureSource: captureSource,
          glassesStream: glassesStream,
          voice: voice,
          camera: camera,
          connection: connection)
          .transition(.opacity)
      }
    }
    .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: needsGlassesSetup)
  }
}
