import SwiftUI

private struct ChatGPTAccountSection: View {
  let status: ChatGPTAuthStatus
  let models: [String]
  let onConnect: () -> Void
  let onOpenVerification: (URL) -> Void
  let onDisconnect: () -> Void

  var body: some View {
    switch status {
    case .loading, .connecting:
      HStack {
        Text("Status")
        Spacer()
        ProgressView()
      }
    case .unauthenticated:
      Button("Connect ChatGPT", action: onConnect)
    case .pending(let login):
      VStack(alignment: .leading, spacing: 10) {
        Text("Waiting for OpenAI verification")
          .font(.subheadline)
        Text(verbatim: login.userCode)
          .font(.system(.title3, design: .monospaced, weight: .semibold))
          .textSelection(.enabled)
        HStack {
          Button("Copy Code") { UIPasteboard.general.string = login.userCode }
          Button("Open OpenAI") { onOpenVerification(login.verificationUrl) }
        }
      }
    case .authenticated(let user):
      VStack(alignment: .leading, spacing: 8) {
        Label(user.email ?? user.name ?? "Connected", systemImage: "checkmark.circle.fill")
          .foregroundStyle(.green)
        if let plan = user.plan {
          Text("Plan: \(plan)")
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        if !models.isEmpty {
          Text("Available models: \(models.count)")
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        Button("Disconnect ChatGPT", role: .destructive, action: onDisconnect)
      }
    case .error(let message):
      VStack(alignment: .leading, spacing: 8) {
        Text(message)
          .font(.footnote)
          .foregroundStyle(.red)
        Button("Try Again", action: onConnect)
      }
    }
  }
}

struct SettingsView: View {
  var voice: GlassifAIRealtimeSession?
  var glassesStream: StreamSessionViewModel?

  @Environment(\.dismiss) private var dismiss
  @Environment(\.openURL) private var openURL
  @State private var chatGPT = ChatGPTAuthSession.shared
  @State private var showChatGPTConsent = false
  @ObservedObject private var audioRoute = AudioRouteMonitor.shared
  @ObservedObject private var orchestrator = AssistantOrchestrator.shared
  @AppStorage(CaptureSource.defaultsKey) private var captureSourceRaw = CaptureSource.iPhoneCamera.rawValue
  @AppStorage(AudioRoutePreference.defaultsKey) private var audioRouteRaw = AudioRoutePreference.automatic.rawValue
  @AppStorage(GlassesStreamProfile.defaultsKey) private var streamProfileRaw = GlassesStreamProfile.balanced.rawValue
  @AppStorage(AssistantPreferences.previewModeKey) private var previewMode = "lowLatency"
  @AppStorage(AssistantPreferences.debugOverlayKey) private var showsDebugOverlay = false
  @AppStorage(AssistantPreferences.voiceKey) private var voiceName = AssistantPreferences.defaultVoice
  @AppStorage(AssistantPreferences.verbosityKey) private var verbosity = "concise"
  @AppStorage(AssistantPreferences.languageKey) private var language = "auto"
  @AppStorage(AssistantPreferences.webSearchKey) private var webSearchEnabled = true
  @AppStorage(AssistantPreferences.regionKey) private var region = ""
  @AppStorage(ModelSelector.overrideKey) private var modelOverride = ""

  init(voice: GlassifAIRealtimeSession? = nil, glassesStream: StreamSessionViewModel? = nil) {
    self.voice = voice
    self.glassesStream = glassesStream
  }

  var body: some View {
    NavigationStack {
      Form {
        Section(
          header: Text("ChatGPT account"),
          footer: Text("Credentials stay in this iPhone’s protected Keychain and are sent only to OpenAI. Signing in does not give this app every ChatGPT feature — see Settings → About for what is supported.")) {
          ChatGPTAccountSection(
            status: chatGPT.status,
            models: chatGPT.availableModels,
            onConnect: { showChatGPTConsent = true },
            onOpenVerification: { openURL($0) },
            onDisconnect: { Task { await chatGPT.logout() } })
          if !chatGPT.availableModels.isEmpty {
            Picker("Task model", selection: $modelOverride) {
              Text("Automatic").tag("")
              ForEach(chatGPT.availableModels, id: \.self) { model in
                Text(model).tag(model)
              }
            }
          }
        }

        Section(
          header: Text("Camera"),
          footer: Text(cameraFooter)) {
          Picker("Camera", selection: $captureSourceRaw) {
            ForEach(CaptureSource.allCases, id: \.rawValue) { source in
              Text(source.label).tag(source.rawValue)
            }
          }
          .pickerStyle(.segmented)
          Toggle("Show camera metrics overlay", isOn: $showsDebugOverlay)
        }

        Section(
          header: Text("Ray-Ban"),
          footer: Text("Changes apply the next time the glasses stream starts. Over Bluetooth the glasses compress harder at higher resolution and frame rate; the metrics overlay shows what actually arrives.")) {
          Picker("Stream profile", selection: $streamProfileRaw) {
            ForEach(GlassesStreamProfile.allCases) { profile in
              Text(profile.label).tag(profile.rawValue)
            }
          }
          Picker("Preview", selection: $previewMode) {
            Text("Low latency (new)").tag("lowLatency")
            Text("Legacy (original)").tag("legacy")
          }
        }

        Section(
          header: Text("Audio route"),
          footer: Text("Automatic uses the glasses’ microphone and speakers with the Ray-Ban camera or with the camera off, and the iPhone in iPhone-camera mode. Takes effect on the next conversation.")) {
          Picker("Audio", selection: $audioRouteRaw) {
            ForEach(AudioRoutePreference.allCases) { preference in
              Text(preference.label).tag(preference.rawValue)
            }
          }
          .pickerStyle(.segmented)
          LabeledContent("Microphone", value: audioRoute.inputSummary)
          LabeledContent("Speaker", value: audioRoute.outputSummary)
        }

        Section(
          header: Text("Voice"),
          footer: Text("Juniper is the verified default. Other voices are experimental; if one is rejected, the app falls back to the original configuration automatically.")) {
          Picker("Voice", selection: $voiceName) {
            ForEach(AssistantPreferences.voices, id: \.self) { name in
              Text(name == AssistantPreferences.defaultVoice ? "\(name.capitalized) (default)" : name.capitalized)
                .tag(name)
            }
          }
          Picker("Answers", selection: $verbosity) {
            Text("Short").tag("concise")
            Text("Detailed").tag("detailed")
          }
          Picker("Language", selection: $language) {
            Text("Match my language").tag("auto")
            Text("Türkçe").tag("tr")
            Text("English").tag("en")
          }
        }

        Section(
          header: Text("Web search"),
          footer: Text("Live search runs through your ChatGPT account (no separate API key or extra fee from this app). Answers show their sources as cards. Last status: \(orchestrator.lastWebStatus)")) {
          Toggle("Web search", isOn: $webSearchEnabled)
          TextField("Usual location (e.g. Ottawa, Canada)", text: $region)
            .textInputAutocapitalization(.words)
        }

        Section("Memory & privacy") {
          NavigationLink {
            MemorySettingsView()
          } label: {
            Label("Memory", systemImage: "brain")
          }
          NavigationLink {
            PrivacySettingsView()
          } label: {
            Label("Privacy & permissions", systemImage: "lock.shield")
          }
        }

        Section("Support") {
          NavigationLink {
            DiagnosticsView(voice: voice, glassesStream: glassesStream)
          } label: {
            Label("Diagnostics", systemImage: "stethoscope")
          }
          NavigationLink {
            LicensesView()
          } label: {
            Label("Licenses", systemImage: "doc.text")
          }
        }

        Section(
          header: Text("About"),
          footer: Text(AutoLoomBrand.independenceNotice)) {
          LabeledContent("Version", value: "\(AppInfo.version) (\(AppInfo.build))")
          LabeledContent("Build", value: AppInfo.commit)
          Label("Live voice through your ChatGPT account", systemImage: "waveform")
          Label("Vision on request from Ray-Ban or iPhone camera", systemImage: "eye")
          Label("Live web search with sources", systemImage: "globe")
          Label("Not available: ChatGPT memory/history sync, Work, Codex tasks, email, calendar, purchases", systemImage: "xmark.circle")
            .foregroundStyle(.secondary)
        }
      }
      .navigationTitle(AutoLoomBrand.appName)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
            .fontWeight(.semibold)
        }
      }
      .sheet(isPresented: $showChatGPTConsent) {
        ChatGPTConsentView {
          showChatGPTConsent = false
          Task {
            if let login = try? await chatGPT.startLogin() {
              openURL(login.verificationUrl)
            }
          }
        }
      }
      .task {
        if case .loading = chatGPT.status { await chatGPT.restore() }
        audioRoute.refresh()
      }
    }
    .tint(AutoLoomTheme.electricBlue)
  }

  private var cameraFooter: String {
    switch CaptureSource(rawValue: captureSourceRaw) ?? .iPhoneCamera {
    case .glasses: "Uses the camera in your connected Meta glasses."
    case .iPhoneCamera: "Uses this iPhone’s back camera."
    case .off: "No camera. Conversation, web search, and reasoning keep working."
    }
  }
}
