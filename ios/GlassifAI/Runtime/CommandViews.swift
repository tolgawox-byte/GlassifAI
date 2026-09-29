import SwiftUI

/// Everything the assistant can do, from the ActionCatalog: searchable, by
/// category, with examples to say. Voice is primary; parameterless actions
/// can also run from here (the same executor as speech).
struct CommandLibraryView: View {
  /// The category to open with ("dealer" after "bayide neler yapabilirsin?").
  let topic: String?
  @State private var text = ""
  @State private var category: ActionDefinition.Category?
  @State private var running: String?
  @State private var result: String?
  @State private var appliedTopic = false

  init(topic: String? = nil) {
    self.topic = topic
  }

  private var entries: [ActionDefinition] {
    let found = ActionCatalog.search(text)
    guard let category else { return found }
    return found.filter { $0.category == category }
  }

  var body: some View {
    List {
      Section {
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 8) {
            chip(nil, L.t("All", "Tümü"), "square.grid.2x2")
            ForEach(ActionDefinition.Category.allCases) { chip($0, $0.title, $0.systemImage) }
          }
          .padding(.vertical, 4)
        }
        .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
      } footer: {
        Text(L.t(
          "Say it any way you like; these are examples. Actions that change something outside the app always wait for you.",
          "İstediğin gibi söyleyebilirsin; bunlar örnek. Uygulama dışında bir şey değiştiren işlemler her zaman seni bekler."))
      }
      if let result {
        Section {
          Text(result).font(.footnote)
        }
      }
      ForEach(ActionDefinition.Category.allCases) { group in
        let rows = entries.filter { $0.category == group }
        if !rows.isEmpty {
          Section(group.title) {
            ForEach(rows) { row($0) }
          }
        }
      }
    }
    .searchable(text: $text, prompt: L.t("Find a command", "Komut ara"))
    .navigationTitle(L.t("Command Library", "Komut kütüphanesi"))
    .onAppear {
      guard !appliedTopic else { return }
      appliedTopic = true
      category = topic.flatMap(ActionDefinition.Category.init(rawValue:))
    }
  }

  private func chip(_ value: ActionDefinition.Category?, _ title: String, _ icon: String) -> some View {
    Button {
      category = value
    } label: {
      Label(title, systemImage: icon)
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(category == value ? AutoLoomTheme.electricBlue.opacity(0.25) : Color.secondary.opacity(0.12), in: Capsule())
    }
    .buttonStyle(.plain)
  }

  private func row(_ definition: ActionDefinition) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 8) {
        Text(definition.title).font(.subheadline.weight(.semibold))
        Spacer(minLength: 4)
        if definition.risk != .safe { badge(definition.risk == .confirm ? L.t("Asks", "Sorar") : L.t("Tap", "Dokunuş"), .orange) }
        if definition.offline { badge(L.t("Offline", "Çevrimdışı"), .green) }
        if definition.status != .experimental && definition.status != .working { badge(definition.status.title, .secondary) }
      }
      ForEach(Array(definition.displayExamples.prefix(2).enumerated()), id: \.offset) { _, example in
        Text("“\(example)”").font(.caption).foregroundStyle(.secondary)
      }
      if runnable(definition) {
        Button {
          run(definition)
        } label: {
          if running == definition.id {
            ProgressView().controlSize(.small)
          } else {
            Label(L.t("Run", "Çalıştır"), systemImage: "play.fill").font(.caption.weight(.semibold))
          }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(running != nil)
      }
    }
    .padding(.vertical, 2)
    .accessibilityElement(children: .combine)
  }

  private func badge(_ text: String, _ color: Color) -> some View {
    Text(text)
      .font(.caption2.weight(.semibold))
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .foregroundStyle(color)
      .background(color.opacity(0.15), in: Capsule())
  }

  /// Actions that need no words from the user and are safe to start here.
  private func runnable(_ definition: ActionDefinition) -> Bool {
    definition.parameters.allSatisfy { !$0.required } && definition.risk == .safe
      && definition.route != .conversation && ActionCatalog.intent(for: definition.id) != nil
      && !definition.keys.contains(where: { $0.hasPrefix("ask.") || $0.hasPrefix("confirmPending") })
  }

  private func run(_ definition: ActionDefinition) {
    running = definition.id
    Task {
      let outcome = await ActionCatalog.run(definition.id)
      result = outcome.said ?? outcome.reply
      running = nil
    }
  }
}

/// Developer → Command Lab: what happens to a phrase, step by step —
/// transcript, normalised words, intent, catalog action, parameters,
/// confidence, confirmation, executor and result. Dry run by default.
struct CommandLabView: View {
  @State private var phrase = ""
  @State private var runForReal = false
  @State private var report: Report?
  @State private var working = false

  struct Report {
    var transcript: String
    var normalized: String
    var intent: String
    var rule: String
    var level: String
    var actionID: String
    var actionName: String
    var parameters: String
    var confidence: String
    var confirmation: String
    var route: String
    var steps: [String]
    var executor: String?
    var result: String?
  }

  var body: some View {
    Form {
      Section {
        TextField(L.t("Type or dictate a phrase", "Bir cümle yaz ya da dikte et"), text: $phrase, axis: .vertical)
          .lineLimit(1...4)
        Toggle(L.t("Run for real", "Gerçekten çalıştır"), isOn: $runForReal)
        Button {
          analyze()
        } label: {
          if working { ProgressView() } else { Label(L.t("Analyse", "Çözümle"), systemImage: "waveform.and.magnifyingglass") }
        }
        .disabled(phrase.trimmingCharacters(in: .whitespaces).isEmpty || working)
      } footer: {
        Text(L.t(
          "Dry run shows how the phrase is understood without doing anything. \"Run for real\" executes it exactly like speech.",
          "Deneme çözümlemesi hiçbir şey yapmadan cümlenin nasıl anlaşıldığını gösterir. \"Gerçekten çalıştır\" konuşmayla aynı şekilde yürütür."))
      }
      if let report {
        Section(L.t("Understanding", "Anlaşılan")) {
          line(L.t("Transcript", "Transkript"), report.transcript)
          line(L.t("Normalised", "Normalleştirilmiş"), report.normalized)
          line(L.t("Intent", "Niyet"), report.intent)
          line(L.t("Rule", "Kural"), report.rule)
          line(L.t("Level", "Seviye"), report.level)
          line(L.t("Confidence", "Güven"), report.confidence)
        }
        Section("ActionCatalog") {
          line("ID", report.actionID)
          line(L.t("Name", "Ad"), report.actionName)
          line(L.t("Parameters", "Parametreler"), report.parameters)
          line(L.t("Confirmation", "Onay"), report.confirmation)
          line(L.t("Route", "Yol"), report.route)
          if !report.steps.isEmpty {
            ForEach(Array(report.steps.enumerated()), id: \.offset) { index, step in
              line(L.t("Step \(index + 1)", "Adım \(index + 1)"), step)
            }
          }
        }
        if report.executor != nil || report.result != nil {
          Section(L.t("Execution", "Yürütme")) {
            if let executor = report.executor { line(L.t("Executor", "Yürütücü"), executor) }
            if let result = report.result { line(L.t("Result", "Sonuç"), result) }
          }
        }
      }
    }
    .navigationTitle("Command Lab")
  }

  private func line(_ title: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title).font(.caption).foregroundStyle(.secondary)
      Text(value.isEmpty ? "—" : value).font(.callout.monospaced()).textSelection(.enabled)
    }
  }

  private func analyze() {
    let text = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
    let orchestrator = AssistantOrchestrator.shared
    let context = orchestrator.bridgeContext()
    let decision = VoiceActionIntentBridge.decide(text, context: context)
    let normalized = Utterance(text)?.keys.joined(separator: " ") ?? ""
    var report = Report(
      transcript: text, normalized: normalized, intent: "—", rule: "—", level: "—", actionID: "—", actionName: "—",
      parameters: "—", confidence: "—", confirmation: "—", route: "—", steps: [])
    if let decision {
      let definition = ActionCatalog.definition(for: decision.intent)
      report.intent = decision.intent.traceName
      report.rule = decision.rule
      report.level = decision.level.rawValue
      report.confidence = decision.level == .deterministic
        ? L.t("1.0 — deterministic rule", "1.0 — kesin kural") : L.t("model classification", "model sınıflandırması")
      report.actionID = definition?.id ?? decision.intent.catalogKey
      report.actionName = definition?.title ?? "—"
      report.parameters = Self.parameters(of: decision.intent)
      if let definition {
        report.confirmation = "\(definition.risk.rawValue) · \(definition.confirmation.rawValue)"
        report.route = Self.describe(definition.route)
      }
      if case .graph(let steps) = decision.intent {
        report.steps = steps.map { "\($0.text) → \($0.intent.traceName)" }
      }
    } else {
      let profile = RequestAnalyzer.analyze(text, kind: nil)
      report.intent = L.t("No local command", "Yerel komut değil")
      report.level = L.t("Voice model (LEVEL 3)", "Ses modeli (LEVEL 3)")
      report.route = "→ \(profile.intent) · \(RequestAnalyzer.primaryRole(for: profile).rawValue)"
      report.confidence = L.t("left to the voice model", "ses modeline bırakıldı")
    }
    self.report = report
    guard runForReal, let decision else { return }
    working = true
    Task {
      let outcome = await orchestrator.runVoiceIntent(decision, transcript: text)
      let trace = ActionTraceLog.shared.entries.last
      self.report?.executor = trace.map { "\($0.executor) · \($0.persistence)" }
      self.report?.result = (outcome.failed.map { "FAILED: \($0) — " } ?? "") + (outcome.said ?? outcome.reply)
      working = false
    }
  }

  static func describe(_ route: ActionDefinition.Route) -> String {
    switch route {
    case .local: L.t("On the phone (LEVEL 1)", "Telefonda (LEVEL 1)")
    case .conversation: L.t("Conversation control", "Konuşma kontrolü")
    case .delegation(let word): L.t("Voice model → TASK: \(word)", "Ses modeli → TASK: \(word)")
    }
  }

  /// The intent's associated values, for diagnostics.
  static func parameters(of intent: VoiceIntent) -> String {
    let mirror = Mirror(reflecting: intent)
    guard let child = mirror.children.first else { return "—" }
    return describe(child.value)
  }

  /// "süt al" for one value; "title: Toplantı · time: …" for several;
  /// optionals without a value are left out.
  private static func describe(_ value: Any) -> String {
    let mirror = Mirror(reflecting: value)
    switch mirror.displayStyle {
    case .tuple:
      let parts = mirror.children.compactMap { child -> String? in
        let text = describe(child.value)
        guard text != "—" else { return nil }
        return mirror.children.count == 1 ? text : "\(child.label ?? "_"): \(text)"
      }
      return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    case .optional:
      guard let wrapped = mirror.children.first else { return "—" }
      return describe(wrapped.value)
    default:
      return String(describing: value)
    }
  }
}
