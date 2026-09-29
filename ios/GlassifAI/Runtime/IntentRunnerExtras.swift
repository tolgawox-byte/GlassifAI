import Foundation

/// Screens the assistant opens on the phone while it answers by voice: the
/// Command Library for "neler yapabilirsin?", search results.
@MainActor
final class AppNavigator: ObservableObject {
  static let shared = AppNavigator()

  enum Sheet: Identifiable, Equatable {
    case commandLibrary(topic: String?)
    case search(String)
    case commandLab

    var id: String {
      switch self {
      case .commandLibrary(let topic): "commands-\(topic ?? "all")"
      case .search(let text): "search-\(text)"
      case .commandLab: "commandlab"
      }
    }
  }

  @Published var sheet: Sheet?

  func show(_ sheet: Sheet) {
    guard !AppRuntime.isUnitTestHost else { return }
    self.sheet = sheet
  }
}

extension AssistantOrchestrator {
  // MARK: "Neler yapabilirsin?"

  func runCapabilities(topic: String?, traceID: UUID) -> IntentOutcome {
    let snapshot = JarvisSession.snapshot()
    let category = topic.flatMap(ActionDefinition.Category.init(rawValue:)) ?? (snapshot.mode == .dealer ? .dealer : nil)
    let entries = category.map { ActionCatalog.definitions(in: $0) } ?? ActionCatalog.all.filter(\.quick)
    let turkish = entries.prefix(6).compactMap { $0.examplesTR.first }.map { ActionCatalog.stripTags($0).text }
    let english = entries.prefix(6).compactMap { $0.examplesEN.first ?? $0.examplesTR.first }.map { ActionCatalog.stripTags($0).text }
    AppNavigator.shared.show(.commandLibrary(topic: category?.rawValue))
    ActionTraceLog.shared.update(traceID) { $0.executor = "ActionCatalog (\(entries.count) actions)" }
    let area = category.map { " for \($0.rawValue)" } ?? ""
    return IntentOutcome(
      spoken: "The user asked what the assistant can do\(area). Name three or four of these briefly and naturally (not a list), then say the full Command Library is open on the phone. Turkish examples: \(turkish.joined(separator: "; ")). English: \(english.joined(separator: "; ")).",
      reply: L.t("Command Library opened", "Komut kütüphanesi açıldı") + (category.map { " · \($0.title)" } ?? ""),
      said: L.t("I named a few; the full list is on the phone.", "Birkaçını söyledim; tam liste telefonda."))
  }

  // MARK: Global search

  func runGlobalSearch(_ text: String, traceID: UUID) -> IntentOutcome {
    let query = GlobalSearch.parse(text)
    let results = GlobalSearch.run(query)
    ActionTraceLog.shared.update(traceID) {
      $0.executor = "GlobalSearch (on this iPhone)"
      $0.parsed = "\(results.count) results" + (query.kinds.map { " · " + $0.map(\.rawValue).sorted().joined(separator: ",") } ?? "")
    }
    AppNavigator.shared.show(.search(query.text))
    let lines = results.prefix(5).map { "• " + $0.title }.joined(separator: "\n")
    return IntentOutcome(
      spoken: GlobalSearch.spokenSummary(results, query: query),
      reply: lines.isEmpty ? L.t("Nothing found.", "Bir şey bulunamadı.") : lines,
      failed: results.isEmpty ? "no results" : nil)
  }

  // MARK: Questions about the active vehicle

  func answerVehicleQuestion(_ field: VehicleField, transcript: String, traceID: UUID) async -> IntentOutcome {
    ActionTraceLog.shared.update(traceID) { $0.executor = "DealerStore (active vehicle record)" }
    guard let vehicle = DealerStore.shared.active else {
      return vehicleOutcome(tr: "Açık bir araç yok.", en: "There's no open vehicle.", failed: "no active vehicle")
    }
    let name = vehicle.title
    switch field {
    case .odometer:
      guard let odometer = vehicle.odometer else {
        // Not recorded yet: read it from the cluster.
        return await runDealer(.readOdometer, transcript: transcript, traceID: traceID)
      }
      return vehicleOutcome(tr: "\(name): \(odometer.text).", en: "\(name): \(odometer.text).")
    case .vin:
      guard let vin = vehicle.vin else {
        return vehicleOutcome(tr: "VIN henüz okunmadı; “VIN oku” diyebilirsin.", en: "The VIN hasn't been read yet; say “read the VIN”.")
      }
      let lastSix = vin.suffix(6).map(String.init).joined(separator: " ")
      let verified = vehicle.vinVerified
      return vehicleOutcome(
        tr: "VIN'in son altı hanesi \(lastSix)" + (verified ? ", doğrulandı." : "; kontrol hanesi doğrulanmadı."),
        en: "The VIN ends in \(lastSix)" + (verified ? ", verified." : "; the check digit is not verified."))
    case .color:
      guard let color = vehicle.color else {
        return vehicleOutcome(tr: "Renk kayıtlı değil.", en: "No colour is recorded.")
      }
      return vehicleOutcome(tr: "\(name): \(color).", en: "\(name): \(color).")
    case .damage:
      guard !vehicle.damage.isEmpty else {
        return vehicleOutcome(tr: "Kayıtlı hasar yok.", en: "No damage is recorded.")
      }
      let tr = vehicle.damage.prefix(5).map { $0.title(turkish: true) }.joined(separator: ", ")
      let en = vehicle.damage.prefix(5).map { $0.title(turkish: false) }.joined(separator: ", ")
      return vehicleOutcome(tr: "\(vehicle.damage.count) hasar kaydı: \(tr).", en: "\(vehicle.damage.count) damage notes: \(en).")
    case .stock:
      guard let stock = vehicle.stockNumber else {
        return vehicleOutcome(tr: "Stok numarası kayıtlı değil.", en: "No stock number is recorded.")
      }
      return vehicleOutcome(tr: "Stok numarası \(stock).", en: "Stock number \(stock).")
    case .complete, .photos:
      let photos = vehicle.remainingPhotos
      let delivery = vehicle.deliveryChecklist.filter { !$0.done }
      if field == .photos || !photos.isEmpty {
        guard !photos.isEmpty else {
          return vehicleOutcome(tr: "Fotoğraflar tamam.", en: "All photos are done.")
        }
        let tr = photos.prefix(4).map(\.turkish).joined(separator: ", ")
        let en = photos.prefix(4).map(\.english).joined(separator: ", ")
        return vehicleOutcome(
          tr: "Henüz tamam değil: \(photos.count) fotoğraf eksik (\(tr)).", en: "Not yet: \(photos.count) photos missing (\(en)).")
      }
      if !delivery.isEmpty, vehicle.status == .sold || vehicle.status == .ready {
        return vehicleOutcome(
          tr: "Fotoğraflar tamam; teslim listesinde \(delivery.count) madde kaldı.",
          en: "Photos are done; \(delivery.count) delivery items are left.")
      }
      return vehicleOutcome(tr: "Fotoğraflar tamam, eksik görünmüyor.", en: "Photos are done; nothing looks missing.")
    }
  }

  private func vehicleOutcome(tr: String, en: String, failed: String? = nil) -> IntentOutcome {
    IntentOutcome(
      spoken: BridgeSpeech.done("A fact from the active vehicle's record on this iPhone.", tr: tr, en: en),
      reply: L.t(en, tr), failed: failed, said: L.t(en, tr))
  }

  // MARK: Tasks: "bunu yarına taşı", "bunu tamamla"

  /// The task the user just talked about: saved in the last ten minutes,
  /// else the newest open one.
  func recentTask(in open: [TaskItem]) -> TaskItem? {
    if let saved = recentSaved, Date().timeIntervalSince(saved.at) < 600, saved.noteID == nil,
       let match = open.first(where: { $0.title == saved.text }) {
      return match
    }
    return open.max { $0.createdAt < $1.createdAt }
  }

  func moveTask(title: String?, time: ParsedTime, traceID: UUID) -> IntentOutcome {
    let store = MemoryStore.shared
    let open = store.tasks.filter { !$0.completed }
    var target: TaskItem?
    if let title, !title.isEmpty {
      let words = MemorySearch.tokens(title)
      target = open.map { ($0, MemorySearch.lexicalScore(query: words, document: MemorySearch.tokens($0.title))) }
        .filter { $0.1 >= 0.5 }
        .max { $0.1 < $1.1 }?.0
    } else {
      target = recentTask(in: open)
    }
    ActionTraceLog.shared.update(traceID) { $0.executor = "AutoLoom Tasks (reschedule)" }
    guard let task = target else {
      return IntentOutcome(
        spoken: BridgeSpeech.ask("Hangi görevi taşıyayım?", en: "Which task should I move?"),
        reply: L.t("No matching task.", "Eşleşen görev yok."), failed: "no matching task")
    }
    let previous = (task.dueAt, task.dueHasTime)
    let merged = CorrectionMerge.merge(original: task.dueAt, originalHasTime: task.dueHasTime, correction: time)
    store.updateTask(task, title: task.title, notes: task.notes, dueAt: merged.date, dueHasTime: merged.hasTime)
    let taskID = task.id
    LocalUndo.shared.record(kind: "task", english: "task moved back", turkish: "görev eski tarihine döndü") {
      guard let saved = MemoryStore.shared.tasks.first(where: { $0.id == taskID }) else { return false }
      MemoryStore.shared.updateTask(saved, title: saved.title, notes: saved.notes, dueAt: previous.0, dueHasTime: previous.1)
      return true
    }
    let tr = TimePhraseParser.describe(merged.date, hasTime: merged.hasTime, turkish: true)
    let en = TimePhraseParser.describe(merged.date, hasTime: merged.hasTime, turkish: false)
    ActionTraceLog.shared.update(traceID) { $0.persistence = "task moved" }
    return IntentOutcome(
      spoken: BridgeSpeech.done(
        "Moved the AutoLoom task \"\(task.title)\" to \(en).", tr: "Görevi \(tr) tarihine taşıdım.", en: "Moved it to \(en)."),
      reply: task.title + " → " + L.t(en, tr),
      feedback: ActionFeedback(kind: .task, title: L.t("Task moved", "Görev taşındı"), detail: L.t(en, tr)),
      said: L.t("Moved it to \(en).", "Görevi \(tr) tarihine taşıdım."))
  }

  // MARK: "Hayır, cumartesi"

  func correctLast(_ time: ParsedTime, traceID: UUID) async -> IntentOutcome {
    if let staged = await correctPendingAction(to: time) {
      ActionTraceLog.shared.update(traceID) { $0.executor = "pending action (corrected and staged again)" }
      return IntentOutcome(spoken: staged.speakable, reply: staged.display ?? staged.speakable, failed: staged.failed)
    }
    let executor = DeviceActionExecutor.shared
    guard let item = executor.lastCreated, Date().timeIntervalSince(item.at) < 180 else {
      return IntentOutcome(
        spoken: "Nothing is waiting or was just saved that could take that time. Ask the user briefly what they want to change.",
        reply: L.t("Nothing to correct.", "Düzeltilecek bir şey yok."), failed: "nothing to correct")
    }
    let merged = CorrectionMerge.merge(original: item.date, originalHasTime: item.hasTime, correction: time)
    ActionTraceLog.shared.update(traceID) { $0.executor = "EventKit (reschedule the item just saved)" }
    do {
      let text = try await executor.reschedule(item, to: merged.date, hasTime: merged.hasTime)
      let tr = TimePhraseParser.describe(merged.date, hasTime: merged.hasTime, turkish: true)
      let en = TimePhraseParser.describe(merged.date, hasTime: merged.hasTime, turkish: false)
      return IntentOutcome(
        spoken: BridgeSpeech.done(text, tr: "\(tr) olarak düzelttim.", en: "Changed to \(en)."),
        reply: text,
        feedback: ActionFeedback(
          kind: item.kind == .createEvent ? .event : .reminder, title: L.t("Corrected", "Düzeltildi"), detail: L.t(en, tr)),
        said: L.t("Changed to \(en).", "\(tr) olarak düzelttim."))
    } catch {
      let message = LogSanitizer.sanitize(error.localizedDescription)
      return IntentOutcome(
        spoken: "The correction could not be saved: \(message). Tell the user honestly; the original is unchanged.",
        reply: message, failed: message)
    }
  }

  // MARK: Several commands in one sentence

  func runGraph(_ steps: [ActionGraph.Step], traceID: UUID) async -> IntentOutcome {
    ActionTraceLog.shared.update(traceID) { $0.executor = "ActionGraph (\(steps.count) steps, in order)" }
    var lines: [String] = []
    var said: [String] = []
    var failures = 0
    for (index, step) in steps.enumerated() {
      // Decided again now: an earlier step may have changed the context
      // (a new vehicle, a saved note).
      let intent = VoiceActionIntentBridge.decideSingle(step.text, context: bridgeContext())?.intent ?? step.intent
      let outcome = await runVoiceIntent(VoiceBridgeDecision(intent, "graph step \(index + 1)"), transcript: step.text)
      let name = ActionCatalog.definition(for: intent)?.name ?? intent.canonicalName
      if let failed = outcome.failed {
        failures += 1
        lines.append("Step \(index + 1) (\(name)): NOT done — \(failed).")
      } else {
        let result = outcome.said ?? String(outcome.reply.prefix(160))
        lines.append("Step \(index + 1) (\(name)): done — \(result)")
        if let spoken = outcome.said { said.append(spoken) }
      }
    }
    let done = steps.count - failures
    ActionTraceLog.shared.update(traceID) { $0.persistence = "\(done)/\(steps.count) steps done" }
    return IntentOutcome(
      spoken: "The app ran several commands from one sentence, in order:\n" + lines.joined(separator: "\n")
        + "\nTell the user in one or two short sentences what was done and, honestly, what was not. Never say a step that was NOT done was done.",
      reply: lines.joined(separator: "\n"),
      failed: done == 0 ? "no step succeeded" : nil,
      said: said.joined(separator: " "))
  }
}
