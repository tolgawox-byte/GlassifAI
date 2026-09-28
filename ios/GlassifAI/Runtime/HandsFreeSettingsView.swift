import SwiftUI

/// Settings → Wake phrase & hands-free. Separates what AutoLoom controls
/// (its own wake phrase, greeting, timeout) from system invocation that
/// Meta and Apple control.
struct HandsFreeSettingsView: View {
  @ObservedObject private var wake = WakePhraseListener.shared
  @ObservedObject private var coordinator = VoiceStartCoordinator.shared
  @AppStorage(WakePhraseSettings.phraseKey) private var phrase = ""
  @AppStorage(WakePhraseSettings.backgroundKey) private var listensInBackground = false
  @AppStorage(WakePhraseSettings.readyMinutesKey) private var readyMinutes = 60
  @AppStorage(WakePhraseSettings.glassesArmingKey) private var armsWithGlasses = false
  @AppStorage(GreetingStyle.defaultsKey) private var greetingRaw = GreetingStyle.normal.rawValue
  @AppStorage(GreetingStyle.customTextKey) private var customGreeting = ""
  @AppStorage(ActivationFeedback.defaultsKey) private var feedbackRaw = ActivationFeedback.subtle.rawValue
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
        Toggle(L.t("Only while the glasses are connected", "Yalnızca gözlük bağlıyken"), isOn: $armsWithGlasses)
          .disabled(!wake.isArmed)
          .onChange(of: armsWithGlasses) { _, _ in Task { await wake.refresh() } }
      }

      Section(
        header: Text(L.t("When a hands-free conversation starts", "Eller serbest konuşma başlayınca")),
        footer: Text(L.t(
          "Applies to the wake phrase, Siri and shortcuts. Starting with the button stays quiet.",
          "Uyandırma ifadesi, Siri ve kısayollar için geçerlidir. Düğmeyle başlatınca sessiz kalır."))) {
        Picker(L.t("Feedback", "Geri bildirim"), selection: $feedbackRaw) {
          ForEach(ActivationFeedback.allCases) { Text($0.label).tag($0.rawValue) }
        }
        Picker(L.t("Greeting", "Karşılama"), selection: $greetingRaw) {
          ForEach(GreetingStyle.allCases) { Text($0.label).tag($0.rawValue) }
        }
        .disabled(feedbackRaw != ActivationFeedback.voiceOnly.rawValue)
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
        LabeledContent("“Hey Meta, start …”", value: L.t("Not available in this build", "Bu sürümde yok"))
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
        "The AI only plans; the app runs every action itself. “Needs your yes” can be confirmed by voice or a tap; “Needs a tap” (calls, messages, links, maps, sharing) only by a tap. Email, purchases, payments and deleting your data are not supported.",
        "Yapay zekâ yalnızca planlar; her işlemi uygulama kendisi yapar. “Onayınız gerekir” sesle veya dokunarak; “Dokunma gerekir” (arama, mesaj, bağlantı, harita, paylaşım) yalnızca dokunarak onaylanır. E-posta, satın alma, ödeme ve verilerinizi silme desteklenmez."))) {
        Toggle(L.t("Allow iPhone actions", "iPhone işlemlerine izin ver"), isOn: $actionsEnabled)
      }
      Section(L.t("Tools", "Araçlar")) {
        ForEach(ToolRegistry.tools) { tool in
          ToolRow(tool: tool, permission: tool.permission.flatMap { permissions[$0] })
            .disabled(!actionsEnabled)
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
