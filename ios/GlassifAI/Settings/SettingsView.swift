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
        Text(L.t("Status", "Durum"))
        Spacer()
        ProgressView()
      }
    case .unauthenticated:
      Button(L.t("Connect ChatGPT", "ChatGPT'yi bağla"), action: onConnect)
    case .pending(let login):
      VStack(alignment: .leading, spacing: 10) {
        Text(L.t("Waiting for OpenAI verification", "OpenAI doğrulaması bekleniyor"))
          .font(.subheadline)
        Text(verbatim: login.userCode)
          .font(.system(.title3, design: .monospaced, weight: .semibold))
          .textSelection(.enabled)
        HStack {
          Button(L.t("Copy Code", "Kodu kopyala")) { UIPasteboard.general.string = login.userCode }
          Button(L.t("Open OpenAI", "OpenAI'yi aç")) { onOpenVerification(login.verificationUrl) }
        }
      }
    case .authenticated(let user):
      VStack(alignment: .leading, spacing: 8) {
        Label(user.email ?? user.name ?? L.t("Connected", "Bağlı"), systemImage: "checkmark.circle.fill")
          .foregroundStyle(.green)
        if let plan = user.plan {
          Text(L.t("Plan: ", "Plan: ") + plan)
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        if !models.isEmpty {
          Text(L.t("Available models: ", "Kullanılabilir modeller: ") + "\(models.count)")
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        Button(L.t("Disconnect ChatGPT", "ChatGPT bağlantısını kes"), role: .destructive, action: onDisconnect)
      }
    case .error(let message):
      VStack(alignment: .leading, spacing: 8) {
        Text(message)
          .font(.footnote)
          .foregroundStyle(.red)
        Button(L.t("Try Again", "Tekrar dene"), action: onConnect)
      }
    }
  }
}

/// The Settings tab: ASSISTANT, VOICE, AI, VISION, MEMORY, TOOLS, PRIVACY,
/// DEVELOPER, ABOUT.
struct SettingsView: View {
  var voice: GlassifAIRealtimeSession?
  var glassesStream: StreamSessionViewModel?
  var connection: WearableConnectionCoordinator?

  @State private var chatGPT = ChatGPTAuthSession.shared
  @ObservedObject private var memory = MemoryStore.shared
  @ObservedObject private var wake = WakePhraseListener.shared
  @AppStorage(AssistantPreferences.voiceKey) private var voiceName = AssistantPreferences.defaultVoice
  @AppStorage(AssistantPreferences.languageKey) private var language = "auto"
  @AppStorage(CaptureSource.defaultsKey) private var captureSourceRaw = CaptureSource.iPhoneCamera.rawValue
  @AppStorage(AssistantPreferences.webSearchKey) private var webSearchEnabled = true
  @AppStorage(AssistantPreferences.actionsKey) private var actionsEnabled = true
  @AppStorage(ModelSelector.overrideKey) private var modelOverride = ""
  @State private var confirmForget = false

  init(
    voice: GlassifAIRealtimeSession? = nil,
    glassesStream: StreamSessionViewModel? = nil,
    connection: WearableConnectionCoordinator? = nil
  ) {
    self.voice = voice
    self.glassesStream = glassesStream
    self.connection = connection
  }

  var body: some View {
    NavigationStack {
      List {
        Section(L.t("Assistant", "Asistan")) {
          NavigationLink { AssistantSettingsView() } label: {
            row(L.t("Name & conversation", "İsim ve konuşma"), "person.wave.2", value: AssistantIdentity.name)
          }
          NavigationLink { HandsFreeSettingsView() } label: {
            row(L.t("Wake phrase & hands-free", "Uyandırma ve eller serbest"), "ear", value: wake.isArmed ? L.t("On", "Açık") : L.t("Off", "Kapalı"))
          }
          NavigationLink { AudioSettingsView() } label: {
            row(L.t("Audio", "Ses çıkışı"), "speaker.wave.2", value: AudioRoutePreference.current.label)
          }
          NavigationLink { PersonalitySettingsView() } label: {
            row(L.t("Personality", "Kişilik"), "person.crop.circle.badge.checkmark",
                value: JarvisStyle.isEnabled ? L.t("Jarvis Style", "Jarvis tarzı") : L.t("Natural", "Doğal"))
          }
        }

        Section(L.t("Voice", "Ses")) {
          NavigationLink {
            if let voice {
              VoiceSettingsView(voice: voice)
            } else {
              Text(L.t("Voice settings are available on the main screen.", "Ses ayarları ana ekrandan kullanılabilir."))
            }
          } label: {
            row(L.t("Voice", "Ses"), "waveform", value: voiceSummary)
          }
          NavigationLink {
            if let voice {
              VoiceSettingsView(voice: voice)
            } else {
              Text(L.t("Voice settings are available on the main screen.", "Ses ayarları ana ekrandan kullanılabilir."))
            }
          } label: {
            row(L.t("Connection feedback", "Bağlantı bildirimi"), "bell.and.waves.left.and.right", value: ConnectionFeedback.current.label)
          }
        }

        Section(L.t("AI", "Yapay zekâ")) {
          NavigationLink { AccountSettingsView() } label: {
            row(L.t("ChatGPT account", "ChatGPT hesabı"), "person.crop.circle", value: chatGPT.isAuthenticated ? L.t("Connected", "Bağlı") : L.t("Not connected", "Bağlı değil"))
          }
          NavigationLink { IntelligenceSettingsView() } label: {
            row(L.t("Intelligence", "Zekâ"), "sparkles", value: intelligenceSummary)
          }
          if chatGPT.isAuthenticated {
            NavigationLink { ModelSettingsView() } label: {
              row(L.t("ChatGPT models", "ChatGPT modelleri"), "cpu", value: modelOverride.isEmpty ? L.t("Automatic", "Otomatik") : modelOverride)
            }
          }
          NavigationLink { WebSettingsView() } label: {
            row(L.t("Web search", "Web araması"), "globe", value: webSearchEnabled ? L.t("On", "Açık") : L.t("Off", "Kapalı"))
          }
        }

        Section(L.t("Vision", "Görüntü")) {
          NavigationLink { CameraSettingsView(glassesStream: glassesStream) } label: {
            row(L.t("Camera & Ray-Ban", "Kamera ve Ray-Ban"), "camera", value: (CaptureSource(rawValue: captureSourceRaw) ?? .iPhoneCamera).displayName)
          }
        }

        if let connection {
          GlassesConnectionSection(connection: connection, confirmForget: $confirmForget)
        }

        Section(L.t("Memory", "Hafıza")) {
          NavigationLink { MemorySettingsView() } label: {
            row(L.t("Memory", "Hafıza"), "brain", value: memory.isEnabled ? "\(memory.memories.count)" : L.t("Off", "Kapalı"))
          }
        }

        Section(L.t("Tools", "Araçlar")) {
          NavigationLink { ToolsSettingsView() } label: {
            row(L.t("iPhone tools", "iPhone araçları"), "checklist", value: actionsEnabled ? L.t("On", "Açık") : L.t("Off", "Kapalı"))
          }
        }

        Section(L.t("Privacy", "Gizlilik")) {
          NavigationLink { PrivacySettingsView() } label: {
            row(L.t("Privacy center", "Gizlilik merkezi"), "lock.shield", value: nil)
          }
        }

        Section(L.t("Developer", "Geliştirici")) {
          NavigationLink { DiagnosticsView(voice: voice, glassesStream: glassesStream) } label: {
            row(L.t("Diagnostics", "Tanılama"), "stethoscope", value: nil)
          }
          NavigationLink { TaskTraceView(voice: voice) } label: {
            row(L.t("Action & task trace", "İşlem ve görev izi"), "list.bullet.rectangle", value: nil)
          }
          if let voice {
            NavigationLink { VoiceDiagnosticsView(voice: voice) } label: {
              row(L.t("Voice diagnostics", "Ses tanılaması"), "waveform.badge.magnifyingglass", value: nil)
            }
          }
          NavigationLink { CameraDiagnosticsView(glassesStream: glassesStream) } label: {
            row(L.t("Camera diagnostics", "Kamera tanılaması"), "gauge.with.dots.needle.33percent", value: nil)
          }
          if let connection {
            NavigationLink { ConnectionDiagnosticsView(connection: connection) } label: {
              row(L.t("Ray-Ban connection", "Ray-Ban bağlantısı"), "antenna.radiowaves.left.and.right", value: nil)
            }
          }
        }

        Section(L.t("About", "Hakkında")) {
          NavigationLink { AboutView() } label: {
            HStack(spacing: 12) {
              GlassifAIMark(size: 36)
                .padding(6)
                .background(AutoLoomTheme.background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
              VStack(alignment: .leading, spacing: 2) {
                Text(AutoLoomBrand.appName).font(.subheadline.weight(.semibold))
                Text("\(AppInfo.version) (\(AppInfo.build)) · \(AppInfo.commit)")
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
            }
          }
        }
      }
      .navigationTitle(L.t("Settings", "Ayarlar"))
      .task {
        if case .loading = chatGPT.status { await chatGPT.restore() }
      }
    }
    .tint(AutoLoomTheme.electricBlue)
  }

  /// "Automatic · 3 providers".
  private var intelligenceSummary: String {
    let registry = ProviderRegistry.shared
    let count = ProviderID.allCases.filter { $0 != .local && registry.isConnected($0) }.count
    let mode = registry.automatic ? L.t("Automatic", "Otomatik") : L.t("Manual", "Elle")
    return "\(mode) · \(count)"
  }

  private var voiceSummary: String {
    let selected = VoiceCatalog.displayName(voiceName)
    guard let report = voice?.startReport, let active = report.activeVoice, voice?.isActive == true else { return selected }
    return active == voiceName ? selected : "\(selected) → \(VoiceCatalog.displayName(active))"
  }

  private func row(_ title: String, _ icon: String, value: String?) -> some View {
    HStack {
      Label(title, systemImage: icon)
      Spacer(minLength: 8)
      if let value {
        Text(value)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
    }
  }
}

/// Settings → Ray-Ban glasses: the connection in plain words, one Try Again
/// when it needs the user, and the only place that removes the Meta AI
/// registration (a temporary disconnect never does).
private struct GlassesConnectionSection: View {
  @ObservedObject var connection: WearableConnectionCoordinator
  @Binding var confirmForget: Bool

  var body: some View {
    let status = connection.status
    Section(
      header: Text(L.t("Ray-Ban glasses", "Ray-Ban gözlük")),
      footer: Text(L.t(
        "The registration with Meta AI stays when the glasses sleep, fold or lose Bluetooth; AutoLoom reconnects by itself. Forget glasses only to disconnect AutoLoom from Meta AI.",
        "Gözlük uyuduğunda, katlandığında ya da Bluetooth koptuğunda Meta AI kaydı kalır; AutoLoom kendiliğinden yeniden bağlanır. Gözlüğü unut, yalnızca AutoLoom'u Meta AI'dan ayırmak içindir."))
    ) {
      HStack(spacing: 10) {
        Circle()
          .fill(status.tone.color)
          .frame(width: 8, height: 8)
        VStack(alignment: .leading, spacing: 2) {
          Text(status.title)
          if let detail = status.detail {
            Text(detail)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        Spacer(minLength: 8)
        if let name = connection.deviceName {
          Text(name)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }
      if status.showsTryAgain {
        Button(L.t("Try Again", "Tekrar dene")) { connection.retry() }
      }
      if connection.phase.needsSetupScreen {
        Button(L.t("Connect glasses", "Gözlüğü bağla")) { connection.connect() }
          .disabled(connection.phase == .registrationStarting || connection.phase == .waitingForMetaAI)
      }
      if connection.isRegistered {
        Button(L.t("Forget glasses…", "Gözlüğü unut…"), role: .destructive) { confirmForget = true }
          .confirmationDialog(
            L.t("Disconnect AutoLoom from Meta AI?", "AutoLoom Meta AI'dan ayrılsın mı?"),
            isPresented: $confirmForget,
            titleVisibility: .visible
          ) {
            Button(L.t("Forget glasses", "Gözlüğü unut"), role: .destructive) { connection.forgetGlasses() }
          } message: {
            Text(L.t("You will need to connect again through Meta AI to use the Ray-Ban camera.",
                     "Ray-Ban kamerasını kullanmak için Meta AI üzerinden yeniden bağlanman gerekir."))
          }
      }
    }
  }
}

// MARK: Assistant

struct AssistantSettingsView: View {
  @AppStorage(AssistantPreferences.verbosityKey) private var verbosity = "concise"
  @AppStorage(AssistantPreferences.languageKey) private var language = "auto"
  @AppStorage(AssistantPreferences.addressedOnlyKey) private var addressedOnly = false
  @AppStorage(ConversationCommands.enabledKey) private var stopCommands = true
  @AppStorage(ConversationTimeout.defaultsKey) private var timeout = ConversationTimeout.minutes2.rawValue
  @AppStorage(DailyBriefing.enabledKey) private var dailyBriefing = false
  @State private var nameDraft = AssistantIdentity.name

  var body: some View {
    Form {
      Section(
        header: Text(L.t("Name", "İsim")),
        footer: Text(L.t(
          "How you address the assistant (“\(AssistantIdentity.name), what am I looking at?”). The wake phrase is set under Wake phrase & hands-free. Changes apply from the next conversation, or now with Voice → Apply now.",
          "Asistana nasıl hitap ettiğiniz (“\(AssistantIdentity.name), neye bakıyorum?”). Uyandırma ifadesi “Uyandırma ve eller serbest” bölümündedir. Değişiklikler sonraki konuşmada ya da Ses → Şimdi uygula ile hemen geçerli olur."))) {
        TextField(AssistantIdentity.defaultName, text: $nameDraft)
          .textInputAutocapitalization(.words)
          .autocorrectionDisabled()
          .submitLabel(.done)
          .onSubmit(commitName)
        if !nameDraft.isEmpty, AssistantIdentity.sanitize(nameDraft) == nil {
          Text(L.t("Use letters (up to \(AssistantIdentity.maxLength) characters).", "Harf kullanın (en fazla \(AssistantIdentity.maxLength) karakter)."))
            .font(.footnote)
            .foregroundStyle(.orange)
        }
      }
      Section(L.t("Conversation", "Konuşma")) {
        Picker(L.t("Language", "Dil"), selection: $language) {
          Text(L.t("Match my language", "Benim dilimle konuş")).tag("auto")
          Text("Türkçe").tag("tr")
          Text("English").tag("en")
        }
        Picker(L.t("Answer length", "Yanıt uzunluğu"), selection: $verbosity) {
          Text(L.t("Adaptive (short first)", "Uyarlanabilir (önce kısa)")).tag("concise")
          Text(L.t("Detailed", "Detaylı")).tag("detailed")
        }
        Picker(L.t("End a quiet conversation after", "Sessiz konuşmayı bitir"), selection: $timeout) {
          ForEach(ConversationTimeout.allCases) { Text($0.label).tag($0.rawValue) }
        }
      }
      Section(
        footer: Text(L.t(
          "Say “Dur”, “Sus”, “Bekle” or “Stop” to cut an answer short; “Kapat”, “Konuşmayı bitir” or “\(AssistantIdentity.name) stop” to end the conversation.",
          "Yanıtı kesmek için “Dur”, “Sus”, “Bekle”; konuşmayı bitirmek için “Kapat”, “Konuşmayı bitir” ya da “\(AssistantIdentity.name) dur” deyin."))) {
        Toggle(L.t("Spoken stop commands", "Sesli durdurma komutları"), isOn: $stopCommands)
        Toggle(L.t("Only answer when called by name (experimental)", "Yalnızca adıyla seslenince yanıtla (deneysel)"), isOn: $addressedOnly)
      }
      Section(
        footer: Text(L.t(
          "The first conversation of each day starts with a short summary of your calendar, reminders and AutoLoom tasks. Only data on this iPhone; no weather or news. You can also say “günün özeti” or “İşe başlıyorum” any time.",
          "Her günün ilk konuşması takviminiz, anımsatıcılarınız ve AutoLoom görevlerinizin kısa bir özetiyle başlar. Yalnızca bu iPhone'daki veriler; hava durumu veya haber yok. İstediğiniz zaman “günün özeti” ya da “İşe başlıyorum” da diyebilirsiniz."))) {
        Toggle(L.t("Daily briefing", "Günlük özet"), isOn: $dailyBriefing)
      }
    }
    .navigationTitle(L.t("Name & conversation", "İsim ve konuşma"))
    .onDisappear(perform: commitName)
  }

  private func commitName() {
    nameDraft = AssistantIdentity.setName(nameDraft)
  }
}

// MARK: Audio

struct AudioSettingsView: View {
  @ObservedObject private var audioRoute = AudioRouteMonitor.shared
  @AppStorage(AudioRoutePreference.defaultsKey) private var audioRouteRaw = AudioRoutePreference.automatic.rawValue

  var body: some View {
    Form {
      Section(footer: Text(L.t(
        "Automatic uses the glasses' microphone and speakers with the Ray-Ban camera or with the camera off, and the iPhone in iPhone-camera mode. Takes effect on the next conversation.",
        "Otomatik: Ray-Ban kamerasında veya kamera kapalıyken gözlüğün mikrofon ve hoparlörü, iPhone kamerasında iPhone kullanılır. Sonraki konuşmada geçerli olur."))) {
        Picker(L.t("Audio", "Ses"), selection: $audioRouteRaw) {
          ForEach(AudioRoutePreference.allCases) { Text($0.label).tag($0.rawValue) }
        }
        .pickerStyle(.segmented)
      }
      Section(L.t("Now", "Şu an")) {
        LabeledContent(L.t("Microphone", "Mikrofon"), value: audioRoute.inputSummary)
        LabeledContent(L.t("Speaker", "Hoparlör"), value: audioRoute.outputSummary)
      }
    }
    .navigationTitle(L.t("Audio", "Ses çıkışı"))
    .task { audioRoute.refresh() }
  }
}

// MARK: AI

struct AccountSettingsView: View {
  @Environment(\.openURL) private var openURL
  @State private var chatGPT = ChatGPTAuthSession.shared
  @State private var showConsent = false

  var body: some View {
    Form {
      Section(footer: Text(L.t(
        "Credentials stay in this iPhone's protected Keychain and are sent only to OpenAI. Signing in does not give this app every ChatGPT feature — see About.",
        "Kimlik bilgileri bu iPhone'un korumalı Anahtar Zinciri'nde kalır ve yalnızca OpenAI'ye gönderilir."))) {
        ChatGPTAccountSection(
          status: chatGPT.status,
          models: chatGPT.availableModels,
          onConnect: { showConsent = true },
          onOpenVerification: { openURL($0) },
          onDisconnect: { Task { await chatGPT.logout() } })
      }
    }
    .navigationTitle(L.t("ChatGPT account", "ChatGPT hesabı"))
    .sheet(isPresented: $showConsent) {
      ChatGPTConsentView {
        showConsent = false
        Task {
          if let login = try? await chatGPT.startLogin() {
            openURL(login.verificationUrl)
          }
        }
      }
    }
  }
}

struct WebSettingsView: View {
  @ObservedObject private var orchestrator = AssistantOrchestrator.shared
  @AppStorage(AssistantPreferences.webSearchKey) private var webSearchEnabled = true
  @AppStorage(AssistantPreferences.regionKey) private var region = ""

  var body: some View {
    Form {
      Section(footer: Text(L.t(
        "Live search runs through your ChatGPT account (no separate API key or extra fee from this app). Answers show their sources as cards.",
        "Canlı arama ChatGPT hesabınız üzerinden yapılır (ayrı API anahtarı veya ek ücret yok). Yanıtlar kaynaklarını kartlarda gösterir."))) {
        Toggle(L.t("Web search", "Web araması"), isOn: $webSearchEnabled)
        TextField(L.t("Usual location (e.g. Ottawa, Canada)", "Genellikle bulunduğunuz yer (ör. İstanbul)"), text: $region)
          .textInputAutocapitalization(.words)
      }
      Section(L.t("Last search", "Son arama")) {
        Text(orchestrator.lastWebStatus)
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
    }
    .navigationTitle(L.t("Web search", "Web araması"))
  }
}

// MARK: Vision

struct CameraSettingsView: View {
  var glassesStream: StreamSessionViewModel?
  @AppStorage(CaptureSource.defaultsKey) private var captureSourceRaw = CaptureSource.iPhoneCamera.rawValue
  @AppStorage(GlassesStreamProfile.defaultsKey) private var streamProfileRaw = GlassesStreamProfile.recommended.rawValue
  @AppStorage(GlassesVideoTransport.defaultsKey) private var transportRaw = GlassesVideoTransport.hevc.rawValue
  @AppStorage(AssistantPreferences.previewModeKey) private var previewMode = "lowLatency"
  @AppStorage(GlassesVisionCaptureMode.defaultsKey) private var glassesVisionCapture = GlassesVisionCaptureMode.automatic.rawValue
  @AppStorage(VisionQualityPreference.defaultsKey) private var visionQuality = VisionQualityPreference.automatic.rawValue
  @AppStorage(VisionAssistPreferences.textAssistKey) private var textDetailAssist = true
  @AppStorage(VisionAssistPreferences.upscaleKey) private var upscaleForReading = true
  @AppStorage(LiveVisionPolicy.maxMinutesKey) private var liveVisionMinutes = LiveVisionPolicy.defaultMaxMinutes
  @AppStorage(LockedScreenVision.defaultsKey) private var lockedScreenVision = true
  @AppStorage(CaptureSaveMode.defaultsKey) private var captureSaveMode = CaptureSaveMode.always.rawValue
  @AppStorage(GlassesDecoderMode.defaultsKey) private var decoderModeRaw = GlassesDecoderMode.software.rawValue

  private var lockedVisionSupported: Bool {
    LockedScreenVision.isSupported(transport: GlassesVideoTransport(rawValue: transportRaw) ?? .hevc)
  }

  var body: some View {
    Form {
      Section(
        header: Text(L.t("Camera", "Kamera")),
        footer: Text(L.t(
          "Reading requests (signs, labels, VINs, badges, screens) use the sharpest recent frame in high detail with on-device text recognition and a zoomed crop. If an answer is still unclear, the app retries in high detail before asking you to move.",
          "Okuma istekleri (tabela, etiket, şasi no, ekran) en net son kareyi yüksek ayrıntıda, cihaz üzerinde metin tanıma ve yakınlaştırılmış kesitle kullanır. Yanıt yine belirsizse uygulama sizden yaklaşmanızı istemeden önce yüksek ayrıntıda tekrar dener."))) {
        Picker(L.t("Camera", "Kamera"), selection: $captureSourceRaw) {
          ForEach(CaptureSource.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
        }
        .pickerStyle(.segmented)
        Picker(L.t("Vision quality", "Görüntü kalitesi"), selection: $visionQuality) {
          ForEach(VisionQualityPreference.allCases) { Text($0.label).tag($0.rawValue) }
        }
        Toggle(L.t("Text detail mode (OCR + zoomed crop)", "Metin ayrıntı modu (OCR + yakın kesit)"), isOn: $textDetailAssist)
        Toggle(L.t("Enlarge small frames for reading", "Okuma için küçük kareleri büyüt"), isOn: $upscaleForReading)
      }
      Section(
        header: Text(L.t("Live Vision", "Canlı Görüş")),
        footer: Text(L.t(
          "Say “keep looking” or tap the eye during a conversation. The assistant gets a short silent note when the view changes (at most every 6 seconds; slower when warm or low on battery). Notes are not spoken or stored.",
          "Konuşma sırasında “bakmaya devam et” deyin veya göz simgesine dokunun. Görüntü değiştiğinde asistana kısa, sessiz bir not gider (en sık 6 saniyede bir; ısınınca veya pil azalınca daha seyrek). Notlar okunmaz ve saklanmaz."))) {
        Picker(L.t("Time limit", "Süre sınırı"), selection: $liveVisionMinutes) {
          ForEach(LiveVisionPolicy.maxMinuteChoices, id: \.self) { Text("\($0) min").tag($0) }
        }
      }
      Section(
        header: Text("Ray-Ban Meta"),
        footer: Text(L.t(
          "Changes apply the next time the glasses stream starts. Meta compresses every frame for Bluetooth, so fewer frames per second give sharper frames. Developer → Diagnostics shows requested and actual values.",
          "Değişiklikler gözlük yayını yeniden başladığında geçerli olur. Meta her kareyi Bluetooth için sıkıştırır; saniyedeki kare azaldıkça kareler netleşir."))) {
        Picker(L.t("Stream profile", "Yayın profili"), selection: $streamProfileRaw) {
          ForEach(GlassesStreamProfile.allCases) { Text($0.label).tag($0.rawValue) }
        }
        Picker(L.t("Video transport", "Video aktarımı"), selection: $transportRaw) {
          ForEach(GlassesVideoTransport.allCases) { Text($0.label).tag($0.rawValue) }
        }
        if let note = glassesStream?.transportNote {
          Text(note).font(.footnote).foregroundStyle(.orange)
        }
        Picker(L.t("Preview", "Önizleme"), selection: $previewMode) {
          Text(L.t("Low latency", "Düşük gecikme")).tag("lowLatency")
          Text(L.t("Legacy", "Eski")).tag("legacy")
        }
        Picker(L.t("Vision image", "Görüntü kaynağı"), selection: $glassesVisionCapture) {
          ForEach(GlassesVisionCaptureMode.allCases) { Text($0.label).tag($0.rawValue) }
        }
      }
      Section(
        header: Text(L.t("Screen locked", "Ekran kilitli")),
        footer: Text(lockedVisionSupported
          ? L.t(
            "With HEVC the Ray-Ban camera keeps streaming while the iPhone is locked, and the assistant keeps seeing through the glasses (their frames, never the phone's screen). If no fresh frame arrives, the glasses take a still photo. Physical test required.",
            "HEVC ile Ray-Ban kamerası iPhone kilitliyken de yayına devam eder ve asistan gözlükten görmeye devam eder (gözlüğün kareleri, asla telefon ekranı değil). Yeni kare gelmezse gözlük fotoğraf çeker. Fiziksel test gerekir.")
          : L.t(
            "Not available with the raw transport: Meta pauses raw streaming while the app is in the background. Choose HEVC above.",
            "Ham aktarımda kullanılamaz: Meta, uygulama arka plandayken ham yayını duraklatır. Yukarıdan HEVC seçin."))) {
        Toggle(L.t("Continue vision with the screen locked", "Ekran kilitliyken görmeye devam et"), isOn: $lockedScreenVision)
          .disabled(!lockedVisionSupported)
        Picker(L.t("Video decoder", "Video çözücü"), selection: $decoderModeRaw) {
          ForEach(GlassesDecoderMode.allCases) { Text($0.label).tag($0.rawValue) }
        }
      }
      Section(
        header: Text(L.t("Ray-Ban photos and videos", "Ray-Ban fotoğraf ve videoları")),
        footer: Text(L.t(
          "Photos and videos come only from the Ray-Ban camera, never from the iPhone camera or the screen. Photos access is add-only: AutoLoom can add to your library but not see it. Nothing is uploaded. Videos are video only: DAT 0.5 gives no Ray-Ban camera audio, and the conversation uses the microphone.",
          "Fotoğraf ve videolar yalnızca Ray-Ban kamerasından gelir; asla iPhone kamerasından veya ekrandan değil. Fotoğraflar izni yalnızca eklemedir: AutoLoom arşivinize ekleyebilir ama göremez. Hiçbir şey yüklenmez. Videolar yalnızca görüntüdür: DAT 0.5 Ray-Ban kamerasından ses vermez ve mikrofonu konuşma kullanır."))) {
        Picker(L.t("Save captures", "Çekimleri kaydet"), selection: $captureSaveMode) {
          ForEach(CaptureSaveMode.allCases) { Text($0.label).tag($0.rawValue) }
        }
        LabeledContent(L.t("Video audio", "Video sesi"), value: L.t("Video only", "Yalnızca görüntü"))
        NavigationLink(L.t("Captures", "Çekimler")) { CapturesView() }
      }
    }
    .navigationTitle(L.t("Camera & Ray-Ban", "Kamera ve Ray-Ban"))
  }
}

// MARK: About

struct AboutView: View {
  var body: some View {
    List {
      Section {
        HStack(spacing: 14) {
          GlassifAIMark(size: 52)
            .padding(10)
            .background(AutoLoomTheme.background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
          VStack(alignment: .leading, spacing: 2) {
            Text(AutoLoomBrand.appName).font(.headline)
            Text("by \(AutoLoomBrand.company)").font(.subheadline).foregroundStyle(.secondary)
            Text(AutoLoomBrand.tagline).font(.caption).foregroundStyle(.secondary)
          }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        LabeledContent(L.t("Version", "Sürüm"), value: "\(AppInfo.version) (\(AppInfo.build))")
        LabeledContent(L.t("Build", "Derleme"), value: AppInfo.commit)
      }
      Section(L.t("What it can do", "Neler yapabilir")) {
        Label(L.t("Live voice through your ChatGPT account", "ChatGPT hesabınızla canlı sesli konuşma"), systemImage: "waveform")
        Label(L.t("Sees and reads through Ray-Ban Meta or the iPhone camera", "Ray-Ban Meta veya iPhone kamerasıyla görür ve okur"), systemImage: "eye")
        Label(L.t("Live web answers with sources", "Kaynaklı canlı web yanıtları"), systemImage: "globe")
        Label(L.t("Remembers what you ask, on this iPhone", "İstediğinizi bu iPhone'da hatırlar"), systemImage: "brain")
        Label(L.t("Reminders, calendar, notes and notifications with your OK", "Onayınızla anımsatıcı, takvim, not ve bildirim"), systemImage: "checklist")
        Label(L.t("Not available: ChatGPT memory/history sync, email, purchases", "Yok: ChatGPT hafıza/geçmiş eşitleme, e-posta, satın alma"), systemImage: "xmark.circle")
          .foregroundStyle(.secondary)
      }
      Section {
        NavigationLink(L.t("Licenses", "Lisanslar")) { LicensesView() }
      } footer: {
        Text(AutoLoomBrand.independenceNotice)
      }
    }
    .navigationTitle(L.t("About", "Hakkında"))
  }
}
