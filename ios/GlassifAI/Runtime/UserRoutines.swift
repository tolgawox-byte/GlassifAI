import Foundation
import SwiftUI

// MARK: Model

/// A routine the user builds: a name and a few steps, each an ActionCatalog
/// action with its words. Only safe, local actions can be steps — no code,
/// no calls or messages, nothing that leaves the phone.
struct UserRoutine: Codable, Equatable, Identifiable {
  struct Step: Codable, Equatable, Identifiable {
    var id = UUID()
    var actionID: String
    var parameters: [String: String] = [:]
  }

  var id = UUID()
  var name: String
  var steps: [Step]
}

@MainActor
final class UserRoutineStore: ObservableObject {
  static let shared = UserRoutineStore(directory: ScreenshotMode.storeDirectory)

  @Published private(set) var routines: [UserRoutine] = []
  private let fileURL: URL

  init(directory: URL? = nil) {
    let base = directory ?? (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory).appendingPathComponent("AutoLoom", isDirectory: true)
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    fileURL = base.appendingPathComponent("routines.json")
    if let data = try? Data(contentsOf: fileURL) {
      if let decoded = try? JSONDecoder().decode([UserRoutine].self, from: data) {
        routines = decoded
      } else {
        LocalJSONFile.setAside(fileURL)
      }
    }
  }

  /// Actions a routine may contain.
  static var eligibleActions: [ActionDefinition] {
    let excluded: Set<String> = ["action.confirm", "action.cancel", "undo.last", "help.capabilities"]
    return ActionCatalog.all.filter {
      $0.route == .local && $0.risk == .safe && $0.confirmation == .none && !excluded.contains($0.id)
        && !$0.id.hasPrefix("conversation.") && !$0.id.hasPrefix("routine.user")
    }
  }

  func save(_ routine: UserRoutine) {
    var cleaned = routine
    cleaned.name = routine.name.trimmingCharacters(in: .whitespacesAndNewlines)
    let allowed = Set(Self.eligibleActions.map(\.id))
    cleaned.steps = routine.steps.filter { allowed.contains($0.actionID) }.prefix(8).map { $0 }
    guard !cleaned.name.isEmpty, !cleaned.steps.isEmpty else { return }
    if let index = routines.firstIndex(where: { $0.id == cleaned.id }) {
      routines[index] = cleaned
    } else {
      routines.append(cleaned)
    }
    persist()
  }

  func delete(_ id: UUID) {
    routines.removeAll { $0.id == id }
    persist()
  }

  func routine(named name: String) -> UserRoutine? {
    let key = MemorySearch.fold(name).filter { $0.isLetter || $0.isNumber }
    return routines.first { MemorySearch.fold($0.name).filter { $0.isLetter || $0.isNumber } == key }
  }

  private func persist() {
    guard let data = try? JSONEncoder().encode(routines) else { return }
    try? data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
  }
}

// MARK: Voice: "Sabah turu rutinini başlat"

extension VoiceActionIntentBridge {
  static func userRoutine(_ u: Utterance, _ context: VoiceBridgeContext) -> VoiceBridgeDecision? {
    guard !context.routineNames.isEmpty, u.count <= 10 else { return nil }
    let endings: [[String]] = [
      ["rutinini", "baslat"], ["rutinini", "calistir"], ["rutinini", "yap"], ["rutinini", "ac"], ["rutini", "baslat"],
      ["rutini", "calistir"], ["rutini"], ["routine"],
    ]
    var name = u
    if let ending = endings.first(where: { u.ends(with: $0) }) {
      name = u.dropping((u.count - ending.count)..<u.count)
    } else if u.starts(with: ["run", "the"]), u.ends(with: ["routine"]) {
      name = u.dropping(0..<2)
    }
    name.trimLeading(["run", "the", "my", "start"])
    guard !name.isEmpty else { return nil }
    let key = Utterance.key(name.text).filter { $0.isLetter || $0.isNumber }
    guard let match = context.routineNames.first(where: {
      Utterance.key($0).filter { $0.isLetter || $0.isNumber } == key
    }) else { return nil }
    // The bare name only when it has two words or more ("sabah turu").
    if name.count == u.count, name.count < 2 { return nil }
    return VoiceBridgeDecision(.userRoutine(match), "user routine")
  }
}

// MARK: Running

extension AssistantOrchestrator {
  func runUserRoutine(_ name: String, traceID: UUID) async -> IntentOutcome {
    guard let routine = UserRoutineStore.shared.routine(named: name) else {
      let tr = "“\(name)” adında bir rutin yok."
      let en = "There's no routine called “\(name)”."
      return IntentOutcome(spoken: BridgeSpeech.done("No such routine.", tr: tr, en: en), reply: L.t(en, tr), failed: "no routine", said: L.t(en, tr))
    }
    ActionTraceLog.shared.update(traceID) { $0.executor = "UserRoutine (\(routine.steps.count) ActionCatalog steps, in order)" }
    var done: [String] = []
    var failed: [String] = []
    var answers: [String] = []
    for step in routine.steps {
      let title = ActionCatalog.definition(step.actionID)?.title ?? step.actionID
      // A step without its words would only ask a question: not done.
      guard let intent = ActionCatalog.intent(for: step.actionID, parameters: step.parameters), !intent.isQuestion else {
        failed.append(title + L.t(" (needs words)", " (söz gerekli)"))
        continue
      }
      let outcome = await ActionCatalog.run(step.actionID, parameters: step.parameters, transcript: routine.name)
      if outcome.failed == nil {
        done.append(title)
        answers.append(outcome.said ?? outcome.reply)
      } else {
        failed.append(title)
      }
    }
    ActionTraceLog.shared.update(traceID) { $0.result = "\(done.count) done, \(failed.count) not done" }
    let failedText = failed.isEmpty ? "" : " Not done: " + failed.joined(separator: ", ") + "."
    return IntentOutcome(
      spoken: "The user's routine “\(routine.name)” ran \(routine.steps.count) steps. Done: \(done.joined(separator: ", ")).\(failedText) Step results: \(answers.joined(separator: " | "))\nTell the user briefly what was done and, honestly, what was not.",
      reply: L.t("Done: ", "Tamam: ") + done.joined(separator: ", ") + (failed.isEmpty ? "" : L.t(" · Not done: ", " · Yapılamadı: ") + failed.joined(separator: ", ")),
      failed: done.isEmpty ? "routine steps failed" : nil)
  }
}

// MARK: Dealer morning briefing

enum DealerBriefing {
  /// Today's dealer picture from the phone's own records: open vehicles,
  /// missing photos, VINs not read, recall checks not done, damage without
  /// photos, vehicle tasks due today.
  static func lines(vehicles: [VehicleSession], tasks: [TaskItem], now: Date = Date(), turkish: Bool) -> [String] {
    func t(_ tr: String, _ en: String) -> String { turkish ? tr : en }
    let open = vehicles.filter(\.isOpen)
    var lines: [String] = []
    lines.append(t("Açık araç: \(open.count)", "Open vehicles: \(open.count)"))
    let missing = open.filter { !$0.remainingPhotos.isEmpty }
    if !missing.isEmpty {
      lines.append(t("Fotoğrafı eksik: ", "Photos missing: ") + missing.prefix(4).map { "\($0.title) (\($0.remainingPhotos.count))" }.joined(separator: ", "))
    }
    let noVIN = open.filter { $0.vin == nil }
    if !noVIN.isEmpty { lines.append(t("VIN okunmadı: ", "No VIN yet: ") + noVIN.prefix(4).map(\.title).joined(separator: ", ")) }
    let noRecall = open.filter { $0.vin != nil && $0.recallCheck == nil }
    if !noRecall.isEmpty {
      lines.append(t("Geri çağırma kontrolü yapılmadı: ", "Recall check not done: ") + noRecall.prefix(4).map(\.title).joined(separator: ", "))
    }
    let undocumented = open.flatMap { vehicle in vehicle.damage.filter(\.captureIDs.isEmpty).map { _ in vehicle.title } }
    if !undocumented.isEmpty {
      lines.append(t("Fotoğrafsız hasar kaydı: \(undocumented.count)", "Damage notes without a photo: \(undocumented.count)"))
    }
    let calendar = Calendar.current
    let vehicleTasks = Set(open.flatMap(\.taskIDs))
    let due = tasks.filter { !$0.completed && vehicleTasks.contains($0.id) && ($0.dueAt.map { calendar.isDate($0, inSameDayAs: now) } ?? false) }
    if !due.isEmpty { lines.append(t("Bugün biten araç görevleri: ", "Vehicle tasks due today: ") + due.prefix(4).map(\.title).joined(separator: ", ")) }
    return lines
  }
}

// MARK: Screen: Explore → Routines

struct RoutinesView: View {
  @ObservedObject private var store = UserRoutineStore.shared
  @State private var editing: UserRoutine?

  var body: some View {
    List {
      Section {
        builtIn("sunrise", L.t("Start of day", "Güne başlangıç"), "“İşe başlıyorum”")
        builtIn("list.bullet.rectangle", L.t("Daily briefing", "Günlük brifing"), "“Günün özeti”")
        builtIn("moon", L.t("Evening review", "Akşam özeti"), "“Bugün ne yaptım?”")
        builtIn("calendar", L.t("Weekly review", "Haftalık özet"), "“Bu hafta ne yaptım?”")
        builtIn("car.2", L.t("Dealer briefing", "Bayi özeti"), "“Bayi özeti”")
      } header: {
        Text(L.t("Built in", "Hazır"))
      }
      Section {
        if store.routines.isEmpty {
          Text(L.t("Make your own: a name and a few steps, then say “<name> rutinini başlat”.",
                   "Kendi rutinini yap: bir ad ve birkaç adım; sonra “<ad> rutinini başlat” de."))
            .font(.footnote).foregroundStyle(.secondary)
        }
        ForEach(store.routines) { routine in
          Button {
            editing = routine
          } label: {
            VStack(alignment: .leading, spacing: 2) {
              Text(routine.name).foregroundStyle(.primary)
              Text(routine.steps.compactMap { ActionCatalog.definition($0.actionID)?.title }.joined(separator: " → "))
                .font(.caption).foregroundStyle(.secondary)
            }
          }
        }
        .onDelete { offsets in
          let ids = offsets.map { store.routines[$0].id }
          ids.forEach(store.delete)
        }
        Button {
          editing = UserRoutine(name: "", steps: [])
        } label: {
          Label(L.t("New routine", "Yeni rutin"), systemImage: "plus")
        }
      } header: {
        Text(L.t("Yours", "Senin"))
      } footer: {
        Text(L.t("Steps run in order; the assistant says honestly which ones did not work. Only safe actions on this iPhone can be steps.",
                 "Adımlar sırayla çalışır; asistan hangisinin olmadığını dürüstçe söyler. Yalnızca bu iPhone'daki güvenli işlemler adım olabilir."))
      }
    }
    .navigationTitle(L.t("Routines", "Rutinler"))
    .sheet(item: $editing) { routine in
      NavigationStack { RoutineEditor(routine: routine) }
    }
  }

  private func builtIn(_ icon: String, _ title: String, _ phrase: String) -> some View {
    HStack {
      Label(title, systemImage: icon)
      Spacer()
      Text(phrase).font(.caption).foregroundStyle(.secondary)
    }
  }
}

struct RoutineEditor: View {
  @State var routine: UserRoutine
  @Environment(\.dismiss) private var dismiss
  @State private var adding = false

  var body: some View {
    Form {
      Section(L.t("Name (what you say)", "Ad (söyleyeceğin)")) {
        TextField(L.t("Morning lot walk", "Sabah turu"), text: $routine.name)
      }
      Section(L.t("Steps", "Adımlar")) {
        ForEach($routine.steps) { $step in
          let definition = ActionCatalog.definition(step.actionID)
          VStack(alignment: .leading, spacing: 4) {
            Text(definition?.title ?? step.actionID)
            if let parameter = definition?.parameters.first {
              TextField(parameter.summary, text: Binding(
                get: { step.parameters[parameter.name] ?? "" },
                set: { step.parameters[parameter.name] = $0 }))
                .font(.caption)
            }
          }
        }
        .onDelete { routine.steps.remove(atOffsets: $0) }
        .onMove { routine.steps.move(fromOffsets: $0, toOffset: $1) }
        Menu {
          ForEach(UserRoutineStore.eligibleActions, id: \.id) { action in
            Button(action.title) { routine.steps.append(UserRoutine.Step(actionID: action.id)) }
          }
        } label: {
          Label(L.t("Add a step", "Adım ekle"), systemImage: "plus.circle")
        }
        .disabled(routine.steps.count >= 8)
      }
    }
    .navigationTitle(routine.name.isEmpty ? L.t("New routine", "Yeni rutin") : routine.name)
    .toolbar {
      ToolbarItem(placement: .cancellationAction) { Button(L.t("Cancel", "Vazgeç")) { dismiss() } }
      ToolbarItem(placement: .confirmationAction) {
        Button(L.t("Save", "Kaydet")) {
          UserRoutineStore.shared.save(routine)
          dismiss()
        }
        .disabled(routine.name.trimmingCharacters(in: .whitespaces).isEmpty || routine.steps.isEmpty)
      }
    }
  }
}
