import Foundation

/// Offline requests (typed, Shortcuts): the phone's own parser has already
/// been tried by the caller; the on-device model then maps the words to a
/// safe offline action or answers briefly — always saying it is offline.
/// Never claims an internet result.
@MainActor
enum OfflineAssistant {
  static func handle(_ text: String) async -> String {
    if let choice = await LocalBrain.classify(text), choice.confidence >= 70,
       let definition = ActionCatalog.definition(choice.actionID), definition.risk == .safe, definition.offline {
      let outcome = await ActionCatalog.run(choice.actionID, parameters: choice.parameters, transcript: text)
      return outcome.said ?? outcome.reply
    }
    if let answer = await LocalBrain.answerOffline(text) {
      return L.t("Offline — a short answer from this iPhone: ", "Çevrimdışı — bu iPhone'dan kısa bir yanıt: ") + answer
    }
    return offlineNotice
  }

  static let offlineNotice = L.t(
    "I'm offline, so this needs the internet. Notes, tasks, reminders, timers, the shopping list and QR codes still work.",
    "Çevrimdışıyım; bunun için internet gerekli. Notlar, görevler, hatırlatıcılar, zamanlayıcı, alışveriş listesi ve QR kodlar yine çalışır.")
}

/// A note saved by voice gets a short title and tags from the on-device
/// model — only while its title is still the automatic one, so a title the
/// user chose is never replaced.
@MainActor
enum NoteEnricher {
  static func enrich(_ id: UUID) {
    guard LocalBrain.isReady else { return }
    Task { @MainActor in
      guard let note = MemoryStore.shared.notes.first(where: { $0.id == id }) else { return }
      let content = note.content
      guard note.title == MemoryStore.defaultTitle(for: content) else { return }
      guard let labels = await LocalBrain.noteLabels(content) else { return }
      guard let current = MemoryStore.shared.notes.first(where: { $0.id == id }), current.content == content,
            current.title == MemoryStore.defaultTitle(for: content) else { return }
      let tags = Array(Set(current.tags + labels.tags)).sorted()
      MemoryStore.shared.updateNote(current, title: labels.title, content: current.content, tags: tags)
    }
  }
}
