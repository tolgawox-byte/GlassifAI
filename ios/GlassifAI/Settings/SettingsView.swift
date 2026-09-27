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
  @AppStorage(GlassesStreamProfile.defaultsKey) private var streamProfileRaw = GlassesStreamProfile.recommended.rawValue
  @AppStorage(GlassesVideoTransport.defaultsKey) private var transportRaw = GlassesVideoTransport.hevc.rawValue
  @AppStorage(AssistantPreferences.previewModeKey) private var previewMode = "lowLatency"
  @AppStorage(AssistantPreferences.debugOverlayKey) private var showsDebugOverlay = false
  @AppStorage(AssistantPreferences.voiceKey) private var voiceName = AssistantPreferences.defaultVoice
  @AppStorage(AssistantPreferences.verbosityKey) private var verbosity = "concise"
  @AppStorage(AssistantPreferences.languageKey) private var language = "auto"
  @AppStorage(AssistantPreferences.webSearchKey) private var webSearchEnabled = true
  @AppStorage(AssistantPreferences.regionKey) private var region = ""
  @AppStorage(ModelSelector.overrideKey) private var modelOverride = ""
  @AppStorage(GlassesVisionCaptureMode.defaultsKey) private var glassesVisionCapture = GlassesVisionCaptureMode.automatic.rawValue
  @AppStorage(VisionQualityPreference.defaultsKey) private var visionQuality = VisionQualityPreference.automatic.rawValue
  @AppStorage(VisionAssistPreferences.textAssistKey) private var textDetailAssist = true
  @AppStorage(VisionAssistPreferences.upscaleKey) private var upscaleForReading = true
  @AppStorage(LiveVisionPolicy.maxMinutesKey) private var liveVisionMinutes = LiveVisionPolicy.defaultMaxMinutes
  @AppStorage(AssistantPreferences.actionsKey) private var actionsEnabled = true
  @AppStorage(AssistantPreferences.addressedOnlyKey) private var addressedOnly = false
  @State private var assistantNameDraft = AssistantIdentity.name

  private func commitAssistantName() {
    assistantNameDraft = AssistantIdentity.setName(assistantNameDraft)
  }

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
          if chatGPT.isAuthenticated {
            NavigationLink {
              ModelSettingsView()
            } label: {
              LabeledContent(
                "AI models",
                value: modelOverride.isEmpty ? "Automatic (\(chatGPT.modelCatalog.count) available)" : modelOverride)
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
          Picker("Vision quality", selection: $visionQuality) {
            ForEach(VisionQualityPreference.allCases) { preference in
              Text(preference.label).tag(preference.rawValue)
            }
          }
          Toggle("Text detail mode (on-device OCR + zoomed crop)", isOn: $textDetailAssist)
          Toggle("Enlarge small frames for reading", isOn: $upscaleForReading)
          Toggle("Show camera metrics overlay", isOn: $showsDebugOverlay)
        }

        Section(
          header: Text("Live Vision"),
          footer: Text("Say \"start live vision\" or tap the eye button during a conversation. The assistant then gets a short note about the view when it changes (at most every 6 seconds; slower when the phone is warm or the battery is low). Notes are not spoken or stored. Detailed questions still use a fresh full-quality frame. It stops when the conversation ends or at the time limit.")) {
          Picker("Time limit", selection: $liveVisionMinutes) {
            ForEach(LiveVisionPolicy.maxMinuteChoices, id: \.self) { minutes in
              Text("\(minutes) min").tag(minutes)
            }
          }
        }

        Section(
          header: Text("Ray-Ban"),
          footer: Text("Changes apply the next time the glasses stream starts (switch the camera to iPhone and back). Meta compresses every frame to fit the Bluetooth link, so fewer frames per second give sharper frames; the glasses may still lower the resolution on a weak link. Diagnostics shows requested and actual values.")) {
          Picker("Stream profile", selection: $streamProfileRaw) {
            ForEach(GlassesStreamProfile.allCases) { profile in
              Text(profile.label).tag(profile.rawValue)
            }
          }
          Picker("Video transport", selection: $transportRaw) {
            ForEach(GlassesVideoTransport.allCases) { transport in
              Text(transport.label).tag(transport.rawValue)
            }
          }
          if let note = glassesStream?.transportNote {
            Text(note)
              .font(.footnote)
              .foregroundStyle(.orange)
          }
          Picker("Preview", selection: $previewMode) {
            Text("Low latency (new)").tag("lowLatency")
            Text("Legacy (original)").tag("legacy")
          }
          Picker("Vision image", selection: $glassesVisionCapture) {
            ForEach(GlassesVisionCaptureMode.allCases) { mode in
              Text(mode.label).tag(mode.rawValue)
            }
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
          header: Text("Assistant"),
          footer: Text("The name is how you address the assistant in a conversation (\"\(AssistantIdentity.name), what am I looking at?\"). It is not a system wake word — see Hands-Free. Changes apply from the next conversation. Juniper is the verified voice; other voices are experimental and fall back automatically if rejected.")) {
          HStack {
            Text("Assistant name")
            Spacer()
            TextField(AssistantIdentity.defaultName, text: $assistantNameDraft)
              .multilineTextAlignment(.trailing)
              .textInputAutocapitalization(.words)
              .autocorrectionDisabled()
              .submitLabel(.done)
              .onSubmit(commitAssistantName)
          }
          if assistantNameDraft.trimmingCharacters(in: .whitespaces) != AssistantIdentity.name,
             !assistantNameDraft.isEmpty,
             AssistantIdentity.sanitize(assistantNameDraft) == nil {
            Text("Use letters (up to \(AssistantIdentity.maxLength) characters). Invalid names fall back to \(AssistantIdentity.defaultName).")
              .font(.footnote)
              .foregroundStyle(.orange)
          }
          Toggle("Only answer when called by name (experimental)", isOn: $addressedOnly)
          Picker("Voice", selection: $voiceName) {
            ForEach(AssistantPreferences.voices, id: \.self) { name in
              Text(name == AssistantPreferences.defaultVoice ? "\(name.capitalized) (default)" : name.capitalized)
                .tag(name)
            }
          }
          Picker("Response style", selection: $verbosity) {
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

        Section(
          header: Text("iPhone actions"),
          footer: Text("Reminders, calendar, AutoLoom notes, directions, links, copy, share, calls and messages. Saving a reminder, event or note needs your spoken yes or a tap on Save. Directions, links, calls, messages and sharing always need a tap on the phone. iOS asks for Reminders and Calendar access the first time. Email, purchases, payments, deleting data and posting are not supported.")) {
          Toggle("Allow iPhone actions", isOn: $actionsEnabled)
          NavigationLink {
            TasksAndNotesView()
          } label: {
            Label("AutoLoom Tasks & Notes", systemImage: "note.text")
          }
        }

        Section("Hands-free, memory & privacy") {
          NavigationLink {
            HandsFreeView()
          } label: {
            Label("Hands-Free", systemImage: "hand.wave")
          }
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
          Label("iPhone actions with your confirmation: reminders, calendar, notes, maps, calls, messages", systemImage: "checklist")
          Label("Live Vision and research reports saved as notes", systemImage: "eye")
          Label("Not available: ChatGPT memory/history sync, ChatGPT Work, Codex cloud tasks, email, purchases", systemImage: "xmark.circle")
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
    .onDisappear(perform: commitAssistantName)
    .tint(AutoLoomTheme.electricBlue)
  }

  private var cameraFooter: String {
    let source: String
    switch CaptureSource(rawValue: captureSourceRaw) ?? .iPhoneCamera {
    case .glasses: source = "Uses the camera in your connected Meta glasses."
    case .iPhoneCamera: source = "Uses this iPhone’s back camera."
    case .off: source = "No camera. Conversation, web search, and reasoning keep working."
    }
    return source + " Reading requests (signs, labels, VINs, badges, screens) use the sharpest recent frame in high detail. Text detail mode adds on-device OCR hints and a zoomed crop of the text; neither is stored."
  }
}
