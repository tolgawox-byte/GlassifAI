import CoreSpotlight
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

  @State private var tab: AppTab = ScreenshotMode.initialTab ?? .assistant
  @ObservedObject private var navigator = AppNavigator.shared
  @Environment(\.scenePhase) private var scenePhase
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
    // While Remote Assist shares the view, on every screen.
    .safeAreaInset(edge: .top, spacing: 0) { RemoteAssistBar() }
    .preferredColorScheme(.dark)
    .sensoryFeedback(.selection, trigger: tab)
    // iOS Spotlight: indexed on launch and when the app goes to the
    // background; a tap on a result opens it here.
    .task {
      SpotlightIndexer.shared.scheduleReindex(after: 5)
      PerformanceGuard.shared.start()
    }
    .onChange(of: scenePhase) { _, phase in
      if phase == .background {
        SpotlightIndexer.shared.scheduleReindex(after: 0.5)
        // No hidden background sharing.
        RemoteAssistServer.shared.stop(.background)
      }
    }
    .onContinueUserActivity(CSSearchableItemActionType) { activity in
      if let identifier = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String {
        SpotlightIndexer.shared.open(identifier: identifier)
      }
    }
    .sheet(item: $navigator.sheet) { sheet in
      NavigationStack {
        switch sheet {
        case .commandLibrary(let topic): CommandLibraryView(topic: topic)
        case .search(let text): GlobalSearchView(initialText: text)
        case .commandLab: CommandLabView()
        case .visualMemory(let id):
          if let id { VisualMemoryDetail(recordID: id) } else { VisualMemoryGallery() }
        case .remoteAssist: RemoteAssistView()
        case .commandPalette: CommandPaletteView()
        }
      }
      .presentationDetents([.medium, .large])
    }
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
