import SwiftUI

/// The command palette: the ActionCatalog's quick actions and a search over
/// every action, run with the same executor as voice. Actions that need
/// words get a field; actions that need the camera or a yes still ask.
struct CommandPaletteView: View {
  @State private var query = ""
  @State private var selected: ActionDefinition?
  @State private var words = ""
  @State private var result: String?
  @State private var running = false
  @Environment(\.dismiss) private var dismiss

  private var actions: [ActionDefinition] {
    let local = ActionCatalog.all.filter { $0.route == .local }
    guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return local.filter(\.quick) + local.filter { !$0.quick } }
    let ids = Set(local.map(\.id))
    return ActionCatalog.search(query).filter { ids.contains($0.id) }
  }

  var body: some View {
    List {
      if let result {
        Section { Text(result).font(.callout) }
      }
      if let selected {
        Section {
          if let parameter = selected.parameters.first {
            TextField(parameter.summary, text: $words, axis: .vertical)
              .lineLimit(1...4)
              .submitLabel(.go)
              .onSubmit { run(selected) }
          }
          Button {
            run(selected)
          } label: {
            HStack {
              Label(selected.title, systemImage: "play.fill")
              if running {
                Spacer()
                ProgressView()
              }
            }
          }
          .disabled(running || (selected.parameters.first?.required == true && words.trimmingCharacters(in: .whitespaces).isEmpty))
        } header: {
          Text(selected.title)
        } footer: {
          Text(selected.summary)
        }
      }
      Section {
        ForEach(actions.prefix(60), id: \.id) { action in
          Button {
            select(action)
          } label: {
            VStack(alignment: .leading, spacing: 2) {
              Text(action.title).foregroundStyle(.primary)
              if let example = action.displayExamples.first {
                Text("“\(example)”").font(.caption).foregroundStyle(.secondary)
              }
            }
          }
        }
      } footer: {
        Text(L.t("Everything here can also be said.", "Buradaki her şey sesle de söylenebilir."))
      }
    }
    .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: L.t("Search actions", "İşlem ara"))
    .navigationTitle(L.t("Commands", "Komutlar"))
    .toolbar {
      ToolbarItem(placement: .cancellationAction) { Button(L.t("Close", "Kapat")) { dismiss() } }
    }
  }

  private func select(_ action: ActionDefinition) {
    selected = action
    words = ""
    result = nil
    if action.parameters.isEmpty { run(action) }
  }

  private func run(_ action: ActionDefinition) {
    var parameters: [String: String] = [:]
    let text = words.trimmingCharacters(in: .whitespacesAndNewlines)
    if let parameter = action.parameters.first, !text.isEmpty { parameters[parameter.name] = text }
    running = true
    Task { @MainActor in
      let outcome = await ActionCatalog.run(action.id, parameters: parameters, transcript: text.isEmpty ? action.name : text)
      result = outcome.said ?? outcome.reply
      running = false
    }
  }
}
