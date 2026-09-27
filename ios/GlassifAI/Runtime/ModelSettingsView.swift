import SwiftUI

/// Settings → AI models: what the signed-in account exposes to this app, what
/// Automatic picks for each job, and optional per-role overrides.
struct ModelSettingsView: View {
  @State private var auth = ChatGPTAuthSession.shared
  @ObservedObject private var health = ModelHealth.shared
  @State private var refreshing = false
  @State private var overrides: [ModelRole: String] = [:]
  @State private var legacyOverride = UserDefaults.standard.string(forKey: ModelSelector.overrideKey) ?? ""

  var body: some View {
    Form {
      Section(
        header: Text("Automatic"),
        footer: Text("Automatic follows the order the ChatGPT service gives this connection (the same order Codex uses) and picks, per job, the first model that supports it: images for vision, the classic request format for web tools. A model that fails is skipped for the rest of the session, and the task retries once with the next one.")) {
        ForEach(ModelRole.allCases) { role in
          LabeledContent(role.label, value: resolved(role))
        }
        LabeledContent("Voice (realtime)", value: "\(ModelSelector.realtimeModel) — verified; not listed by the service")
      }

      Section(
        header: Text("Override per job"),
        footer: Text("Only models this connection actually lists can be chosen. Leave on Automatic unless you are testing a model.")) {
        ForEach(ModelRole.allCases) { role in
          Picker(role.label, selection: binding(for: role)) {
            Text("Automatic (recommended)").tag("")
            ForEach(auth.modelCatalog) { model in
              Text(model.slug).tag(model.slug)
            }
          }
        }
      }

      if !legacyOverride.isEmpty {
        Section(
          header: Text("All-tasks override (older setting)"),
          footer: Text("Set in an earlier version. It applies to every job and takes precedence over Automatic.")) {
          LabeledContent("Model", value: legacyOverride)
          Button("Clear", role: .destructive) {
            UserDefaults.standard.removeObject(forKey: ModelSelector.overrideKey)
            legacyOverride = ""
          }
        }
      }

      Section(header: Text("GPT-6 Astra")) {
        Text(ModelRouting.gpt6AstraStatus(catalog: auth.modelCatalog, health: health.entries))
          .font(.footnote)
      }

      Section(
        header: Text("Models exposed to this connection (\(auth.modelCatalog.count))"),
        footer: Text(listFooter)) {
        if auth.modelCatalog.isEmpty {
          Text(auth.modelsError ?? "Not loaded yet.")
            .foregroundStyle(.secondary)
        }
        ForEach(auth.modelCatalog) { model in
          VStack(alignment: .leading, spacing: 3) {
            HStack {
              Text(model.displayName).font(.subheadline.weight(.semibold))
              Spacer()
              Text(healthLabel(model.slug))
                .font(.caption2)
                .foregroundStyle(healthColor(model.slug))
            }
            Text("\(model.slug) · priority \(model.priority)")
              .font(.caption2.monospaced())
              .foregroundStyle(.secondary)
            Text(model.capabilityTags.joined(separator: " · "))
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
          .padding(.vertical, 2)
        }
      }

      Section {
        Button(refreshing ? "Refreshing…" : "Refresh model list") {
          refreshing = true
          Task {
            await auth.refreshModels()
            refreshing = false
          }
        }
        .disabled(refreshing || !auth.isAuthenticated)
        Button("Reset model status", role: .destructive) { health.clear() }
      }
    }
    .navigationTitle("AI models")
    .onAppear {
      for role in ModelRole.allCases {
        overrides[role] = role.override ?? ""
      }
    }
  }

  private var listFooter: String {
    let fetched = auth.modelsFetchedAt.map { "Loaded \($0.formatted(date: .omitted, time: .shortened)). " } ?? ""
    return fetched + "\"Working\" means a real request through this app succeeded; \"failed\" shows the service's reason. Nothing here is claimed from the ChatGPT app itself."
  }

  private func binding(for role: ModelRole) -> Binding<String> {
    Binding(
      get: { overrides[role] ?? "" },
      set: { value in
        overrides[role] = value
        if value.isEmpty {
          UserDefaults.standard.removeObject(forKey: role.overrideKey)
        } else {
          UserDefaults.standard.set(value, forKey: role.overrideKey)
        }
      })
  }

  private func resolved(_ role: ModelRole) -> String {
    let catalog = auth.modelCatalog
    guard !catalog.isEmpty || !auth.availableModels.isEmpty else { return "—" }
    let kind: AssistantTaskKind? = switch role {
    case .general: .generalChat
    case .vision: .vision
    case .reasoning: .deepReasoning
    case .web: .webSearch
    }
    let model = ModelSelector.model(
      for: kind, available: auth.availableModels, needsHostedWebSearch: role == .web, catalog: catalog,
      needsImages: role == .vision, excluded: health.failedThisRun) ?? "none compatible"
    return role.override == nil ? model : "\(model) (pinned)"
  }

  private func healthLabel(_ slug: String) -> String {
    guard let entry = health.entries[slug] else { return "not used yet" }
    return entry.working ? "working" : "failed"
  }

  private func healthColor(_ slug: String) -> Color {
    guard let entry = health.entries[slug] else { return .secondary }
    return entry.working ? .green : .orange
  }
}
