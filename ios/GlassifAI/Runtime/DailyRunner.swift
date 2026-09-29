import Foundation

/// Runs timers and the shopping list: on the phone, no model, offline.
extension AssistantOrchestrator {
  func runTimer(_ command: TimerCommand, traceID: UUID) async -> IntentOutcome {
    let center = TimerCenter.shared
    let trace = ActionTraceLog.shared
    trace.update(traceID) { $0.executor = "TimerCenter (+ a local notification)" }
    switch command {
    case .start(let seconds, let label):
      let result = await center.start(seconds: TimeInterval(seconds), label: label)
      let timerID = result.timer.id
      LocalUndo.shared.record(kind: "timer", english: "timer cancelled", turkish: "zamanlayıcı iptal edildi") {
        guard let timer = TimerCenter.shared.timers.first(where: { $0.id == timerID }) else { return false }
        return TimerCenter.shared.cancel(id: timer.id) != nil
      }
      let tr = TimerCenter.spoken(TimeInterval(seconds), turkish: true)
      let en = TimerCenter.spoken(TimeInterval(seconds), turkish: false)
      trace.update(traceID) {
        $0.parsed = "\(seconds) s" + (label == nil ? "" : " · labelled")
        $0.persistence = result.notificationScheduled ? "timer + notification scheduled" : "timer only (notifications off)"
      }
      var trText = label.map { "\($0) için \(tr) zamanlayıcı kurdum." } ?? "Zamanlayıcıyı \(tr) olarak kurdum."
      var enText = label.map { "\(en) timer set for \($0)." } ?? "Timer set for \(en)."
      if !result.notificationScheduled {
        trText += " Bildirim izni kapalı; uygulama açıkken haber vereceğim."
        enText += " Notifications are off, so I'll tell you while the app is open."
      }
      return dailyOutcome(
        tr: trText, en: enText,
        feedback: ActionFeedback(kind: .notification, title: L.t("Timer set", "Zamanlayıcı kuruldu"), detail: L.t(en, tr)))

    case .cancel:
      guard center.cancel() != nil else {
        return dailyOutcome(tr: "Çalışan bir zamanlayıcı yok.", en: "There's no timer running.")
      }
      return dailyOutcome(
        tr: "Zamanlayıcıyı durdurdum.", en: "Timer cancelled.",
        feedback: ActionFeedback(kind: .forgotten, title: L.t("Timer cancelled", "Zamanlayıcı durduruldu")))

    case .remaining:
      guard let timer = center.timers.first else {
        return dailyOutcome(tr: "Çalışan bir zamanlayıcı yok.", en: "There's no timer running.")
      }
      let left = timer.remaining()
      let tr = TimerCenter.spoken(left, turkish: true)
      let en = TimerCenter.spoken(left, turkish: false)
      return dailyOutcome(
        tr: timer.label.map { "\($0) için \(tr) kaldı." } ?? "\(tr) kaldı.",
        en: timer.label.map { "\(en) left for \($0)." } ?? "\(en) left.")
    }
  }

  func runShopping(_ command: ShoppingCommand, traceID: UUID) -> IntentOutcome {
    let store = ShoppingListStore.shared
    let trace = ActionTraceLog.shared
    trace.update(traceID) { $0.executor = "ShoppingListStore (on this iPhone)" }
    switch command {
    case .add(let texts):
      let added = store.add(texts)
      let addedIDs = added.map(\.id)
      if !added.isEmpty {
        LocalUndo.shared.record(kind: "shopping", english: "removed from the list", turkish: "listeden çıkarıldı") {
          let present = ShoppingListStore.shared.items.filter { addedIDs.contains($0.id) }
          present.forEach { ShoppingListStore.shared.delete($0.id) }
          return !present.isEmpty
        }
      }
      trace.update(traceID) { $0.persistence = "\(added.count) item(s) added; \(store.open.count) open" }
      guard !added.isEmpty else {
        return dailyOutcome(tr: "Bunlar zaten listede.", en: "Those are already on the list.")
      }
      let names = added.map(\.text).joined(separator: ", ")
      return dailyOutcome(
        tr: "Alışveriş listesine ekledim: \(names).", en: "Added to your shopping list: \(names).",
        feedback: ActionFeedback(kind: .task, title: L.t("Shopping list", "Alışveriş listesi"), detail: names))

    case .read:
      let open = store.open
      guard !open.isEmpty else {
        return dailyOutcome(tr: "Alışveriş listen boş.", en: "Your shopping list is empty.")
      }
      let names = open.prefix(12).map(\.text).joined(separator: ", ")
      return dailyOutcome(
        tr: "Listende \(open.count) şey var: \(names).", en: "\(open.count) items on your list: \(names).")

    case .remove(let text):
      guard let removed = store.remove(matching: text) else {
        return dailyOutcome(tr: "Listede \(text) bulamadım.", en: "I couldn't find \(text) on the list.")
      }
      return dailyOutcome(
        tr: "\(removed.text) listeden çıkarıldı.", en: "Removed \(removed.text) from the list.",
        feedback: ActionFeedback(kind: .taskDone, title: L.t("Removed from the list", "Listeden çıkarıldı"), detail: removed.text))
    }
  }

  private func dailyOutcome(tr: String, en: String, feedback: ActionFeedback? = nil) -> IntentOutcome {
    IntentOutcome(
      spoken: BridgeSpeech.done("Result of the user's command, done on this iPhone.", tr: tr, en: en),
      reply: L.t(en, tr), feedback: feedback, said: L.t(en, tr))
  }
}
