import SwiftUI

enum AppTab: String, Hashable {
  case assistant
  case memory
  case tasks
  case settings
}

/// The app's four tabs: Assistant, Memory, Tasks and Settings.
struct AppShellView: View {
  let captureSource: CaptureSource
  @ObservedObject var glassesStream: StreamSessionViewModel
  let glassesPlaceholder: (title: String, caption: String)
  @ObservedObject var voice: GlassifAIRealtimeSession
  @ObservedObject var camera: GlassifAICamera
  let glassesDeviceName: String?
  var wearablesViewModel: WearablesViewModel?
  /// Ray-Ban is the chosen camera but the glasses are not connected yet.
  let needsGlassesSetup: Bool
  let onGlassesRegistered: () -> Void

  @State private var tab: AppTab = .assistant
  @AppStorage(AssistantPreferences.languageKey) private var language = "auto"

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
      SettingsView(voice: voice, glassesStream: glassesStream, wearablesViewModel: wearablesViewModel)
        .tabItem { Label(L.t("Settings", "Ayarlar"), systemImage: "gearshape") }
        .tag(AppTab.settings)
    }
    .tint(AutoLoomTheme.electricBlue)
    .preferredColorScheme(.dark)
  }

  @ViewBuilder
  private var assistantTab: some View {
    if needsGlassesSetup, let wearablesViewModel {
      HomeScreenView(viewModel: wearablesViewModel, onRegistered: onGlassesRegistered)
    } else {
      AssistantHomeView(
        captureSource: captureSource,
        glassesStream: glassesStream,
        glassesPlaceholder: glassesPlaceholder,
        voice: voice,
        camera: camera,
        glassesDeviceName: glassesDeviceName)
    }
  }
}
