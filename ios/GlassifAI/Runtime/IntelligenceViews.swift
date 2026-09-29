import SwiftUI

/// Settings → Intelligence: automatic routing, quality/cost, the providers,
/// per-role pins (advanced) and the routing diagnostics. By default the
/// user configures nothing: with only ChatGPT everything works as before,
/// and each connected specialist makes routing smarter at once.
struct IntelligenceSettingsView: View {
  @ObservedObject private var registry = ProviderRegistry.shared
  @State private var showAdvanced = false

  var body: some View {
    let context = registry.routingContext()
    List {
      Section {
        agentCards(context)
      } header: {
        Text(L.t("AutoLoom Intelligence", "AutoLoom Zekâsı"))
      } footer: {
        Text(L.t(
          "One assistant answers; behind it each job goes to the best connected agent. You never have to choose.",
          "Tek bir asistan yanıtlar; arkada her iş bağlı en uygun ajana gider. Seçmeniz gerekmez."))
      }

      Section {
        Toggle(L.t("Automatic routing", "Otomatik yönlendirme"), isOn: $registry.automatic)
        Picker(L.t("Quality / cost", "Kalite / maliyet"), selection: $registry.cost) {
          ForEach(CostPreference.allCases) { Text($0.label).tag($0) }
        }
      } header: {
        Text(L.t("Routing", "Yönlendirme"))
      } footer: {
        Text(registry.cost.detail + " " + (registry.automatic
          ? L.t("Automatic: the router picks among connected providers.", "Otomatik: yönlendirici bağlı sağlayıcılar arasından seçer.")
          : L.t("Off: ChatGPT and the phone do everything, except roles you pinned below.",
                "Kapalı: aşağıda atadığınız roller dışında her şeyi ChatGPT ve telefon yapar.")))
      }

      Section(L.t("Providers", "Sağlayıcılar")) {
        ForEach(ProviderID.allCases) { provider in
          NavigationLink {
            ProviderDetailView(provider: provider)
          } label: {
            ProviderRow(provider: provider, registry: registry)
          }
        }
      }

      Section {
        DisclosureGroup(L.t("Agent roles (advanced)", "Ajan rolleri (gelişmiş)"), isExpanded: $showAdvanced) {
          ForEach(AgentRole.pinnable) { role in
            Picker(selection: pinBinding(role)) {
              Text(L.t("Automatic", "Otomatik")).tag(ProviderID?.none)
              ForEach(pinnableProviders(for: role, context: context)) { provider in
                Text(provider.displayName).tag(ProviderID?.some(provider))
              }
            } label: {
              Label(role.title, systemImage: role.systemImage)
            }
          }
        }
      } footer: {
        Text(L.t(
          "Pin a role to one provider (for example Research → Perplexity). Actions and memory always stay on the phone.",
          "Bir rolü tek sağlayıcıya atayın (örneğin Araştırma → Perplexity). İşlemler ve hafıza her zaman telefonda kalır."))
      }

      Section(L.t("Developer", "Geliştirici")) {
        NavigationLink(L.t("Routing diagnostics", "Yönlendirme tanılaması")) { RoutingDiagnosticsView() }
      }
    }
    .navigationTitle(L.t("Intelligence", "Zekâ"))
  }

  private func agentCards(_ context: RoutingContext) -> some View {
    let roles: [AgentRole] = [.chat, .vision, .research, .reasoning, .deviceAction, .memory]
    return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
      ForEach(roles) { role in
        let provider = AgentRouter.candidates(for: role, context: context).first ?? .chatgpt
        VStack(alignment: .leading, spacing: 6) {
          Image(systemName: role.systemImage)
            .font(.headline)
            .foregroundStyle(AutoLoomTheme.electricBlue)
          Text(role.title).font(.subheadline.weight(.semibold))
          Text((context.overrides[role] == nil ? L.t("Automatic · ", "Otomatik · ") : L.t("Pinned · ", "Atanmış · "))
            + provider.displayName)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
      }
    }
    .padding(.vertical, 4)
  }

  private func pinBinding(_ role: AgentRole) -> Binding<ProviderID?> {
    Binding(
      get: { registry.overrides[role] },
      set: { value in
        var pins = registry.overrides
        pins[role] = value
        registry.overrides = pins
      })
  }

  private func pinnableProviders(for role: AgentRole, context: RoutingContext) -> [ProviderID] {
    ProviderID.allCases.filter { provider in
      provider != .local && provider != .openclaw && context.connected.contains(provider)
        && (provider == .chatgpt || (context.capabilities[provider] ?? []).contains(role.capability))
    }
  }
}

private struct ProviderRow: View {
  let provider: ProviderID
  @ObservedObject var registry: ProviderRegistry

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: provider.systemImage)
        .frame(width: 28)
        .foregroundStyle(AutoLoomTheme.electricBlue)
      VStack(alignment: .leading, spacing: 2) {
        Text(provider.displayName).font(.subheadline.weight(.semibold))
        Text(status).font(.caption).foregroundStyle(statusColor)
      }
      Spacer(minLength: 8)
      if let latency = registry.healthState(provider).averageLatencyMs {
        Text("\(latency) ms").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
      }
    }
  }

  private var connected: Bool { registry.isConnected(provider) }

  private var status: String {
    if let label = registry.healthLabel(provider), connected { return label }
    if connected { return L.t("Connected", "Bağlı") }
    return provider.isOptional ? L.t("Not connected (optional)", "Bağlı değil (isteğe bağlı)") : L.t("Not connected", "Bağlı değil")
  }

  private var statusColor: Color {
    if connected && registry.healthLabel(provider) == nil { return .green }
    return connected ? .orange : .secondary
  }
}

/// One provider: status, how it connects, models, capabilities, latency,
/// last success, the roles it currently leads, Test and Connect/Disconnect.
struct ProviderDetailView: View {
  let provider: ProviderID
  @ObservedObject private var registry = ProviderRegistry.shared
  @State private var showConnect = false
  @State private var confirmDisconnect = false
  @State private var testMessage: String?

  var body: some View {
    let connected = registry.isConnected(provider)
    let health = registry.healthState(provider)
    let context = registry.routingContext()
    List {
      Section {
        Text(provider.why)
        LabeledContent(L.t("Status", "Durum"), value: registry.healthLabel(provider)
          ?? (connected ? L.t("Connected", "Bağlı") : L.t("Not connected", "Bağlı değil")))
        LabeledContent(L.t("Connection", "Bağlantı"), value: provider.authKind.label)
        if provider.authKind == .apiKey, connected, let key = registry.credential(provider) {
          LabeledContent(L.t("Key", "Anahtar"), value: ProviderCredentialStore.maskedHint(key))
        }
      }

      if connected {
        Section(L.t("Models and abilities", "Modeller ve yetenekler")) {
          let models = registry.models[provider] ?? []
          LabeledContent(L.t("Models available", "Mevcut modeller"), value: modelCount(models))
          ForEach(models.prefix(6)) { model in
            VStack(alignment: .leading, spacing: 2) {
              Text(model.name).font(.subheadline)
              Text(model.capabilities.names.joined(separator: " · "))
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
          }
          Text(registry.capabilities(of: provider).names.joined(separator: " · "))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Section(L.t("Activity", "Etkinlik")) {
          LabeledContent(L.t("Last success", "Son başarılı istek"),
                         value: health.lastSuccess.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "—")
          LabeledContent(L.t("Average latency", "Ortalama gecikme"), value: health.averageLatencyMs.map { "\($0) ms" } ?? "—")
          LabeledContent(L.t("Leads", "Yönettiği roller"), value: leadingRoles(context))
          if let error = registry.lastErrors[provider] ?? health.lastError {
            LabeledContent(L.t("Last problem", "Son sorun"), value: error)
          }
        }
      }

      Section {
        LabeledContent(L.t("Data sent", "Gönderilen veri"), value: "")
        Text(provider.dataSent).font(.footnote)
        LabeledContent(L.t("Billing", "Ücret"), value: "")
        Text(provider.billing).font(.footnote)
      }

      Section {
        if connected {
          Button {
            Task {
              switch await registry.test(provider) {
              case .success(let result):
                var parts = [L.t("OK", "Tamam"), "\(result.latencyMs) ms"]
                if let model = result.model { parts.append(model) }
                testMessage = parts.joined(separator: " · ")
              case .failure(let error):
                testMessage = L.t("Failed: ", "Başarısız: ") + (error.errorDescription ?? "")
              }
            }
          } label: {
            HStack {
              Text(L.t("Test connection", "Bağlantıyı test et"))
              if registry.busy.contains(provider) { Spacer(); ProgressView() }
            }
          }
          .disabled(registry.busy.contains(provider))
          if let testMessage { Text(testMessage).font(.footnote).foregroundStyle(.secondary) }
        }
        switch provider.authKind {
        case .apiKey:
          if connected {
            Button(L.t("Disconnect", "Bağlantıyı kes"), role: .destructive) { confirmDisconnect = true }
          } else {
            Button(L.t("Connect…", "Bağlan…")) { showConnect = true }
          }
        case .gateway:
          NavigationLink(L.t("Agent gateway settings", "Ajan ağ geçidi ayarları")) { AgentGatewaySettingsView() }
        case .chatgptAccount:
          NavigationLink(L.t("ChatGPT account", "ChatGPT hesabı")) { AccountSettingsView() }
        case .builtIn:
          Text(LocalProvider.tools.joined(separator: " · ")).font(.footnote).foregroundStyle(.secondary)
        }
      }
    }
    .navigationTitle(provider.displayName)
    .sheet(isPresented: $showConnect) { ConnectProviderSheet(provider: provider) }
    .confirmationDialog(
      L.t("Disconnect \(provider.displayName)?", "\(provider.displayName) bağlantısı kesilsin mi?"),
      isPresented: $confirmDisconnect, titleVisibility: .visible
    ) {
      Button(L.t("Disconnect", "Bağlantıyı kes"), role: .destructive) { registry.disconnect(provider) }
    } message: {
      Text(L.t("The key is removed from the Keychain; AutoLoom keeps working with the other providers.",
               "Anahtar Anahtar Zinciri'nden silinir; AutoLoom diğer sağlayıcılarla çalışmaya devam eder."))
    }
  }

  private func modelCount(_ models: [ProviderModel]) -> String {
    guard !models.isEmpty else { return provider == .perplexity ? "4" : "—" }
    let listed = models.allSatisfy(\.discovered)
    return "\(models.count)" + (listed ? "" : L.t(" (published list)", " (yayımlanan liste)"))
  }

  private func leadingRoles(_ context: RoutingContext) -> String {
    let roles = AgentRole.pinnable.filter { AgentRouter.candidates(for: $0, context: context).first == provider }
    return roles.isEmpty ? "—" : roles.map(\.title).joined(separator: ", ")
  }
}

/// Connecting a provider that may bill the user's account: what it is for,
/// what is sent, billing and usage, then the key (kept in the Keychain).
/// Nothing is enabled until the user confirms.
struct ConnectProviderSheet: View {
  let provider: ProviderID
  @ObservedObject private var registry = ProviderRegistry.shared
  @Environment(\.dismiss) private var dismiss
  @State private var key = ""
  @State private var understood = false
  @State private var message: String?
  @State private var succeeded = false

  var body: some View {
    NavigationStack {
      Form {
        Section(L.t("Why connect", "Neden bağlanmalı")) { Text(provider.why) }
        Section(L.t("What is sent", "Ne gönderilir")) { Text(provider.dataSent).font(.footnote) }
        Section(L.t("Billing", "Ücret")) {
          Text(provider.billing).font(.footnote)
          Text(L.t("Expected use: ", "Beklenen kullanım: ") + provider.usagePattern).font(.footnote)
        }
        Section {
          if let page = provider.keyPage {
            Link(L.t("Get a key at \(page.host ?? "")", "\(page.host ?? "") adresinden anahtar alın"), destination: page)
          }
          SecureField(L.t("API key", "API anahtarı"), text: $key)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
          Toggle(L.t("I understand my \(provider.displayName) account may be charged.",
                     "\(provider.displayName) hesabımın ücretlendirilebileceğini anlıyorum."), isOn: $understood)
        } footer: {
          Text(L.t(
            "The key stays in this iPhone's Keychain (this device only). It is never logged, shown or uploaded anywhere except to \(provider.displayName). Connecting runs one tiny test request.",
            "Anahtar bu iPhone'un Anahtar Zinciri'nde kalır (yalnızca bu cihaz). Asla kaydedilmez, gösterilmez ve \(provider.displayName) dışında hiçbir yere gönderilmez. Bağlanırken çok küçük bir test isteği yapılır."))
        }
        if let message {
          Section { Text(message).foregroundStyle(succeeded ? .green : .orange) }
        }
      }
      .navigationTitle(provider.displayName)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(succeeded ? L.t("Done", "Bitti") : L.t("Cancel", "Vazgeç")) { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          if registry.busy.contains(provider) {
            ProgressView()
          } else if !succeeded {
            Button(L.t("Connect", "Bağlan")) { Task { await connect() } }
              .disabled(!understood || key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          }
        }
      }
    }
  }

  private func connect() async {
    switch await registry.connect(provider, key: key) {
    case .success(let result):
      key = ""
      succeeded = true
      var parts = [L.t("Connected", "Bağlandı"), "\(result.latencyMs) ms"]
      if let model = result.model { parts.append(model) }
      parts.append("\(result.modelsFound) " + L.t("models", "model"))
      message = parts.joined(separator: " · ")
    case .failure(let error):
      succeeded = false
      switch error {
      case .invalidCredentials: message = L.t("The key was refused.", "Anahtar reddedildi.")
      case .billing: message = L.t("The account needs credit.", "Hesabın krediye ihtiyacı var.")
      default: message = error.errorDescription
      }
    }
  }
}

/// Recent routing decisions: intent, strategy, agents and providers,
/// latency and result. Never the request's words, answers or keys.
struct RoutingDiagnosticsView: View {
  @ObservedObject private var registry = ProviderRegistry.shared

  var body: some View {
    List {
      if registry.diagnostics.isEmpty {
        Text(L.t("No requests routed yet.", "Henüz yönlendirilen istek yok.")).foregroundStyle(.secondary)
      }
      ForEach(registry.diagnostics.reversed()) { item in
        VStack(alignment: .leading, spacing: 3) {
          HStack {
            Text("\(item.intent) · \(item.strategy.rawValue)").font(.caption.weight(.semibold))
            Spacer()
            Text(item.at.formatted(date: .omitted, time: .standard)).font(.caption2).foregroundStyle(.secondary)
          }
          ForEach(item.steps, id: \.self) { Text($0).font(.caption2.monospaced()) }
          Text(item.result + (item.latencyMs.map { " · \($0) ms" } ?? "") + (item.fallback.map { " · \($0)" } ?? ""))
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
      }
    }
    .navigationTitle(L.t("Routing diagnostics", "Yönlendirme tanılaması"))
    .toolbar {
      Button(L.t("Clear", "Temizle")) { registry.clearDiagnostics() }
    }
  }
}

/// Settings → Personality: Jarvis Style, its intensity and how the
/// assistant addresses the user.
struct PersonalitySettingsView: View {
  @AppStorage(JarvisStyle.enabledKey) private var jarvisStyle = false
  @AppStorage(JarvisIntensity.defaultsKey) private var intensityRaw = JarvisIntensity.balanced.rawValue
  @AppStorage(JarvisAddress.defaultsKey) private var addressRaw = JarvisAddress.sir.rawValue
  @AppStorage(JarvisAddress.customKey) private var customAddress = ""
  @AppStorage(GreetingStyle.defaultsKey) private var greetingRaw = GreetingStyle.normal.rawValue
  @AppStorage(AssistantMode.defaultsKey) private var modeRaw = AssistantMode.automatic.rawValue

  var body: some View {
    Form {
      Section {
        Picker(L.t("Mode", "Mod"), selection: $modeRaw) {
          ForEach(AssistantMode.allCases) { Text($0.label).tag($0.rawValue) }
        }
      } footer: {
        Text(L.t(
          "Automatic: Dealer while a vehicle is active, otherwise General. A mode only shapes how the assistant answers; it applies from the next conversation.",
          "Otomatik: bir araç aktifken Bayi, değilse Genel. Mod yalnızca asistanın yanıt biçimini etkiler; bir sonraki konuşmadan itibaren geçerlidir."))
      }
      Section {
        Toggle(L.t("Jarvis Style", "Jarvis tarzı"), isOn: Binding(
          get: { jarvisStyle },
          set: { enabled in
            JarvisStyle.setEnabled(enabled)
            jarvisStyle = enabled
            if enabled && greetingRaw == GreetingStyle.normal.rawValue { greetingRaw = GreetingStyle.jarvis.rawValue }
            if !enabled && greetingRaw == GreetingStyle.jarvis.rawValue { greetingRaw = GreetingStyle.normal.rawValue }
          }))
      } footer: {
        Text(L.t(
          "A refined, calm, precise assistant with rare dry humour, inspired by the archetype of a futuristic AI butler. Not a film character, no film dialogue, no actor's voice. Turning it on selects the “Cove” voice (composed and direct); you can pick another.",
          "Nadir, ince bir mizahla zarif, sakin ve kesin bir asistan; fütüristik yapay zekâ uşağı arketipinden esinlenir. Film karakteri değildir, film repliği ve oyuncu sesi yoktur. Açınca “Cove” sesi seçilir (ölçülü ve net); başka bir ses seçebilirsiniz."))
      }
      if jarvisStyle {
        Section(L.t("Intensity", "Yoğunluk")) {
          Picker(L.t("Intensity", "Yoğunluk"), selection: $intensityRaw) {
            ForEach(JarvisIntensity.allCases) { Text($0.label).tag($0.rawValue) }
          }
          .pickerStyle(.segmented)
        }
        Section(L.t("Address me as", "Bana nasıl hitap etsin")) {
          Picker(L.t("Address", "Hitap"), selection: $addressRaw) {
            ForEach(JarvisAddress.allCases) { Text($0.label).tag($0.rawValue) }
          }
          if addressRaw == JarvisAddress.custom.rawValue {
            TextField(L.t("For example: Boss", "Örneğin: Patron"), text: $customAddress)
          }
        }
        Section(L.t("Sounds like", "Örnek")) {
          Text(example(JarvisStyle.confirmation(
            "Tamam, not aldım.", turkish: true, intensity: intensity, word: word(turkish: true), addAddress: true)))
          Text(example(JarvisStyle.greeting("Bağlantı hazır. Sizi dinliyorum.", turkish: true)))
          Text(example(JarvisStyle.confirmation(
            "Done, I've noted it.", turkish: false, intensity: intensity, word: word(turkish: false), addAddress: true)))
        }
      }
    }
    .navigationTitle(L.t("Personality", "Kişilik"))
  }

  private var intensity: JarvisIntensity { JarvisIntensity(rawValue: intensityRaw) ?? .balanced }

  private func word(turkish: Bool) -> String? {
    JarvisStyle.addressWord(
      turkish: turkish, address: JarvisAddress(rawValue: addressRaw) ?? .sir, custom: customAddress)
  }

  private func example(_ text: String) -> String { "“\(text)”" }
}
