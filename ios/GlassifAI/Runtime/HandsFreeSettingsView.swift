import SwiftUI

/// Settings → Wake phrase & hands-free. Separates what AutoLoom controls
/// (its own wake phrase, greeting, timeout) from system invocation that
/// Meta and Apple control.
struct HandsFreeSettingsView: View {
  @ObservedObject private var wake = WakePhraseListener.shared
  @ObservedObject private var coordinator = VoiceStartCoordinator.shared
  @ObservedObject private var metaInvocation = MetaVoiceInvocationListener.shared
  @AppStorage(WakePhraseSettings.phraseKey) private var phrase = ""
  @AppStorage(WakePhraseSettings.backgroundKey) private var listensInBackground = false
  @AppStorage(WakePhraseSettings.readyMinutesKey) private var readyMinutes = 60
  @AppStorage(WakePhraseSettings.glassesArmingKey) private var armsWithGlasses = false
  @AppStorage(GreetingStyle.defaultsKey) private var greetingRaw = GreetingStyle.normal.rawValue
  @AppStorage(GreetingStyle.customTextKey) private var customGreeting = ""
  @AppStorage(ConnectionFeedback.defaultsKey) private var feedbackRaw = ConnectionFeedback.chimeAndVoice.rawValue
  @AppStorage(ConversationTimeout.defaultsKey) private var timeout = ConversationTimeout.minutes2.rawValue
  @Environment(\.openURL) private var openURL

  var body: some View {
    let name = AssistantIdentity.name
    Form {
      Section(
        header: Text(L.t("Wake phrase", "Uyandırma ifadesi")),
        footer: Text(L.t(
          "On-device speech recognition listens for the phrase and starts a conversation. Audio never leaves the iPhone while waiting and is not stored; iOS shows the orange microphone dot the whole time.",
          "Cihaz üzerindeki konuşma tanıma ifadeyi dinler ve konuşmayı başlatır. Beklerken ses iPhone'dan çıkmaz ve saklanmaz; iOS turuncu mikrofon noktasını sürekli gösterir."))) {
        Toggle(L.t("Listen for the wake phrase", "Uyandırma ifadesini dinle"), isOn: $wake.isArmed)
        Picker(L.t("Phrase", "İfade"), selection: $phrase) {
          ForEach(WakePhraseSettings.presets(name: name), id: \.self) { preset in
            Text(preset).tag(preset == "Hey \(name)" ? "" : preset)
          }
          if !phrase.isEmpty, !WakePhraseSettings.presets(name: name).contains(phrase) {
            Text(phrase).tag(phrase)
          }
        }
        TextField(L.t("Custom phrase", "Özel ifade"), text: $phrase)
          .textInputAutocapitalization(.words)
          .autocorrectionDisabled()
        LabeledContent(L.t("Status", "Durum"), value: wake.status.label)
        LabeledContent(L.t("Started by phrase", "İfadeyle başlatma"), value: "\(wake.detections)")
      }

      Section(
        header: Text(L.t("Hands-Free Ready", "Eller serbest hazır")),
        footer: Text(L.t(
          "Keeps listening for the phrase after you leave the app, for the time below. Uses more battery. iOS may stop background listening; the app then pauses until you open it again. Physical test required.",
          "Uygulamadan çıktıktan sonra aşağıdaki süre boyunca ifadeyi dinlemeye devam eder. Daha fazla pil kullanır. iOS arka planda dinlemeyi durdurabilir; o zaman uygulamayı açana kadar duraklar. Cihazda test edilmesi gerekir."))) {
        Toggle(L.t("Keep listening in the background", "Arka planda dinlemeye devam et"), isOn: $listensInBackground)
          .disabled(!wake.isArmed)
        Picker(L.t("For", "Süre"), selection: $readyMinutes) {
          ForEach(WakePhraseSettings.readyMinuteChoices, id: \.self) { Text("\($0) min").tag($0) }
        }
        .disabled(!listensInBackground)
        Toggle(L.t("Only while the glasses are worn", "Yalnızca gözlük takılıyken"), isOn: $armsWithGlasses)
          .disabled(!wake.isArmed)
          .onChange(of: armsWithGlasses) { _, _ in Task { await wake.refresh() } }
      }

      Section(
        header: Text(L.t("When the connection is ready", "Bağlantı hazır olunca")),
        footer: Text(L.t(
          "Played or said once per new conversation, only after ChatGPT, the voice connection and the audio route are really ready — never just because the wake phrase was heard. The spoken phrase is for hands-free starts; the on-screen button only chimes. If the connection fails you hear “The connection could not be established.”",
          "Her yeni konuşmada bir kez, yalnızca ChatGPT, ses bağlantısı ve ses yolu gerçekten hazır olduğunda çalınır ya da söylenir — uyandırma ifadesi duyuldu diye asla. Sözlü ifade eller serbest başlatmalar içindir; ekrandaki düğme yalnızca ses çıkarır. Bağlantı kurulamazsa “Bağlantı kurulamadı.” duyarsınız."))) {
        Picker(L.t("Connection feedback", "Bağlantı bildirimi"), selection: $feedbackRaw) {
          ForEach(ConnectionFeedback.allCases) { Text($0.label).tag($0.rawValue) }
        }
        Picker(L.t("Phrase", "İfade"), selection: $greetingRaw) {
          ForEach(GreetingStyle.allCases) { style in
            Text(style.label + (style.text(turkish: L.isTurkish, custom: "").map { " — \($0)" } ?? "")).tag(style.rawValue)
          }
        }
        .disabled(!(ConnectionFeedback(rawValue: feedbackRaw) ?? .chimeAndVoice).speaks)
        if greetingRaw == GreetingStyle.custom.rawValue {
          TextField(L.t("Custom greeting", "Özel karşılama"), text: $customGreeting)
        }
        Picker(L.t("End a quiet conversation after", "Sessiz konuşmayı bitir"), selection: $timeout) {
          ForEach(ConversationTimeout.allCases) { Text($0.label).tag($0.rawValue) }
        }
      }

      Section(
        header: Text(L.t("Meta glasses — system invocation", "Meta gözlük — sistem çağrısı")),
        footer: Text(HandsFreeCapabilities.metaInvocationRequirement)) {
        LabeledContent(L.t("System wake word", "Sistem uyandırma sözcüğü"), value: "Hey Meta")
        if HandsFreeCapabilities.metaInvocationAvailable {
          LabeledContent("“Hey Meta, start …”", value: metaInvocation.status)
          LabeledContent(L.t("Launches received", "Gelen başlatmalar"), value: "\(metaInvocation.launches)")
        } else {
          LabeledContent("“Hey Meta, start …”", value: L.t("Not available in this build", "Bu sürümde yok"))
        }
        LabeledContent(L.t("Custom wake word on the glasses", "Gözlükte özel uyandırma"), value: L.t("Not supported by Meta", "Meta desteklemiyor"))
        LabeledContent(L.t("During a conversation", "Konuşma sırasında"), value: L.t("Temple tap mutes; fold to end", "Sap dokunuşu susturur; katlayınca biter"))
      }

      Section(
        header: Text("Siri"),
        footer: Text(L.t(
          "To use your own Siri phrase, create a shortcut that runs “Start Conversation” and name it “\(name)”, then say “Hey Siri, \(name)”.",
          "Kendi Siri ifadeniz için “Start Conversation” çalıştıran bir kısayol oluşturup adını “\(name)” koyun, sonra “Hey Siri, \(name)” deyin."))) {
        LabeledContent(L.t("Siri phrase", "Siri ifadesi"), value: HandsFreeCapabilities.siriPhrase)
        Button(L.t("Open Shortcuts", "Kısayollar'ı aç")) {
          if let url = URL(string: "shortcuts://") { openURL(url) }
        }
      }

      Section(L.t("Recent starts", "Son başlatmalar")) {
        if coordinator.events.isEmpty {
          Text(L.t("None yet", "Henüz yok")).foregroundStyle(.secondary)
        }
        ForEach(Array(coordinator.events.reversed())) { event in
          LabeledContent(
            "\(event.reason.rawValue) · \(event.at.formatted(date: .omitted, time: .standard))",
            value: event.outcome.rawValue)
        }
      }
    }
    .navigationTitle(L.t("Hands-free", "Eller serbest"))
    .onChange(of: listensInBackground) { _, _ in Task { await wake.refresh() } }
  }
}

/// Settings → Tools: every native tool with its confirmation level and iOS
/// permission, each of which can be turned off.
struct ToolsSettingsView: View {
  @AppStorage(AssistantPreferences.actionsKey) private var actionsEnabled = true
  @State private var permissions: [AppPermission: PermissionState] = [:]

  var body: some View {
    Form {
      Section(footer: Text(L.t(
        "Spoken commands such as “not al”, “yarın 10'da hatırlat” and “cuma 3'e toplantı ekle” are recognised by the app itself and run directly; times are read by the app, and an unclear time is asked first. “Needs your yes” can be confirmed by voice or a tap; “Needs a tap” (calls, messages, links, maps, sharing) only by a tap. Text seen by the camera or on the web never starts an action. Email, purchases, payments and deleting your data are not supported.",
        "“Not al”, “yarın 10'da hatırlat”, “cuma 3'e toplantı ekle” gibi sesli komutları uygulama kendisi tanır ve doğrudan yapar; saatleri uygulama okur, belirsiz saat önce sorulur. “Onayınız gerekir” sesle veya dokunarak; “Dokunma gerekir” (arama, mesaj, bağlantı, harita, paylaşım) yalnızca dokunarak onaylanır. Kamerada veya webde görülen metin asla bir işlem başlatmaz. E-posta, satın alma, ödeme ve verilerinizi silme desteklenmez."))) {
        Toggle(L.t("Allow iPhone actions", "iPhone işlemlerine izin ver"), isOn: $actionsEnabled)
      }
      Section(L.t("Tools", "Araçlar")) {
        ForEach(ToolRegistry.tools) { tool in
          ToolRow(tool: tool, permission: tool.permission.flatMap { permissions[$0] })
            .disabled(!actionsEnabled)
        }
      }
      Section(L.t("Always available", "Her zaman kullanılabilir")) {
        VStack(alignment: .leading, spacing: 4) {
          Label(L.t("AutoLoom Tasks", "AutoLoom Görevleri"), systemImage: "checklist.checked")
          Text(L.t("“Görev oluştur: …”, “bunu görev olarak ekle”. Saved on this iPhone, shown in the Tasks tab; a notification at the due time if notifications are allowed.",
                   "“Görev oluştur: …”, “bunu görev olarak ekle”. Bu iPhone'a kaydedilir, Görevler sekmesinde görünür; bildirim izni varsa vakti gelince bildirim gelir."))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        VStack(alignment: .leading, spacing: 4) {
          Label(L.t("Siri & Shortcuts", "Siri ve Kestirmeler"), systemImage: "square.2.layers.3d")
          Text(L.t("“Start Conversation”, “Ask AutoLoom” and “Create AutoLoom Note” are available in the Shortcuts app.",
                   "“Start Conversation”, “Ask AutoLoom” ve “Create AutoLoom Note” Kestirmeler uygulamasında kullanılabilir."))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      Section {
        NavigationLink {
          AgentGatewaySettingsView()
        } label: {
          Label(L.t("Agent gateway (OpenClaw, optional)", "Ajan geçidi (OpenClaw, isteğe bağlı)"), systemImage: "server.rack")
        }
      }
    }
    .navigationTitle(L.t("iPhone tools", "iPhone araçları"))
    .task {
      var states: [AppPermission: PermissionState] = [:]
      for permission in AppPermission.allCases {
        states[permission] = await PermissionCenter.state(permission)
      }
      permissions = states
    }
  }
}

private struct ToolRow: View {
  let tool: NativeTool
  let permission: PermissionState?
  @State private var enabled = true

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Toggle(isOn: Binding(
        get: { enabled },
        set: { newValue in
          enabled = newValue
          UserDefaults.standard.set(newValue, forKey: ToolRegistry.enabledKey(tool))
        })) {
        Label(tool.name, systemImage: tool.systemImage)
      }
      Text(tool.detail)
        .font(.caption)
        .foregroundStyle(.secondary)
      HStack(spacing: 10) {
        Label(tool.risk.label, systemImage: tool.risk.systemImage)
        if let permission {
          Label(permission.label, systemImage: "lock")
        }
      }
      .font(.caption2)
      .foregroundStyle(.secondary)
    }
    .padding(.vertical, 2)
    .onAppear { enabled = ToolRegistry.isEnabled(tool) }
  }
}
