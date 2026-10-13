import EventKit
import Foundation

/// Which Apple reminder a spoken command means (plan 2.2).
enum ReminderTarget: Equatable {
  /// The user's words for it ("süt alma"); empty means the one just saved.
  case words(String)
  /// One the app offered and the user chose ("ikincisi").
  case id(String)
}

/// An open Apple reminder, as read from Reminders.
struct ReminderOption: Equatable {
  let id: String
  let title: String
  let list: String
  let due: Date?
  let hasTime: Bool

  /// What the user hears for a choice: the title, with the list when the
  /// choices span lists, and the due time when two still sound the same.
  static func labels(_ options: [ReminderOption]) -> [String] {
    let lists = Set(options.map(\.list))
    let base = options.map { option in
      lists.count > 1 && !option.list.isEmpty ? "\(option.title) (\(option.list))" : option.title
    }
    return base.indices.map { index -> String in
      guard base.filter({ $0 == base[index] }).count > 1, let due = options[index].due else { return base[index] }
      return base[index] + " · " + ActionFeedback.when(due, hasTime: options[index].hasTime)
    }
  }
}

/// Finds the reminder the user means by their words. Turkish verb nouns are
/// reduced to their stem on both sides, so "süt alma" finds "Süt al" and
/// "Ahmet'i arama" finds "Ahmet'i ara".
enum ReminderMatcher {
  enum Result: Equatable {
    case one(ReminderOption)
    /// About equally good matches: the user is asked which one.
    case several([ReminderOption])
    case noMatch
  }

  private static let fillers: Set<String> = ["bir", "bu", "su", "o", "ve", "ile", "the", "a", "an", "my", "to", "and"]

  static func words(_ text: String) -> [String] {
    MemorySearch.fold(text)
      .components(separatedBy: CharacterSet.alphanumerics.inverted)
      .filter { $0.count >= 2 && !fillers.contains($0) }
      .map(stem)
  }

  /// "almayı", "alma", "almak" → "al"; "aramamı" → "ara".
  static func stem(_ word: String) -> String {
    for suffix in ["mayi", "meyi", "mami", "memi", "mak", "mek", "ma", "me"]
    where word.hasSuffix(suffix) && word.count - suffix.count >= 2 {
      return String(word.dropLast(suffix.count))
    }
    return word
  }

  private static func same(_ a: String, _ b: String) -> Bool {
    a == b || MemorySearch.sameStem(a, b)
  }

  /// One reminder when one clearly fits; several when the words fit more
  /// than one about equally; none when fewer than half the words fit.
  static func match(_ text: String, in options: [ReminderOption]) -> Result {
    let query = words(text)
    guard !query.isEmpty else { return .noMatch }
    let scored = options.compactMap { option -> (option: ReminderOption, said: Double, covered: Double)? in
      let title = words(option.title)
      guard !title.isEmpty else { return nil }
      let said = Double(query.filter { word in title.contains { same(word, $0) } }.count) / Double(query.count)
      let covered = Double(title.filter { word in query.contains { same(word, $0) } }.count) / Double(title.count)
      return said >= 0.5 ? (option: option, said: said, covered: covered) : nil
    }
    guard let best = scored.map({ $0.said }).max() else { return .noMatch }
    let top = scored.filter { $0.said >= best * 0.9 }
    if top.count == 1 { return .one(top[0].option) }
    // Every word of one title was said, and of no other: that one.
    let whole = top.filter { $0.covered >= 1 }
    if whole.count == 1 { return .one(whole[0].option) }
    return .several(Array(top.sorted { $0.covered > $1.covered }.prefix(4).map { $0.option }))
  }
}

/// A Reminders list named in words: "İş listeme raporu gönder", "Market
/// listesindeki süt", "send the report in my Work list". Only the names of
/// real lists are looked for, so ordinary words never pick a list.
enum ReminderListMention {
  struct Found: Equatable {
    /// The list's name in Reminders.
    let name: String
    /// The words without the list phrase, capitalised.
    let remainder: String
  }

  /// "List" in Turkish after the list's name.
  static let turkishListWords = [
    "listesine", "listeme", "listeye", "listesinde", "listemde", "listede", "listesindeki", "listemdeki",
    "listedeki", "listesinden", "listemden", "listeden",
  ]
  private static let englishLeads: Set<String> = ["in", "to", "on", "into", "onto", "from", "my", "the"]

  /// `allowingNothingElse`: the list may be all that was said ("Market
  /// listesindeki").
  static func find(in text: String, listNames: [String], allowingNothingElse: Bool = false) -> Found? {
    guard let words = Utterance(text) else { return nil }
    let lists = listNames.compactMap { name -> (name: String, keys: [String])? in
      var keys = (Utterance(name)?.keys ?? []).filter { key in key.contains { $0.isLetter || $0.isNumber } }
      // "Alışveriş Listesi", "Shopping List": said "alışveriş listesine", "my shopping list".
      if keys.count > 1, let last = keys.last, last.hasPrefix("liste") || last == "list" { keys.removeLast() }
      return keys.isEmpty ? nil : (name: name, keys: keys)
    }
    // Longer names first: "İş Projeleri" before "İş".
    for list in lists.sorted(by: { $0.keys.count > $1.keys.count }) {
      for word in turkishListWords {
        if let range = words.range(of: list.keys + [word]) {
          return found(list.name, words.dropping(range), allowingNothingElse)
        }
      }
      if let range = words.range(of: list.keys + ["list"]) {
        // "in my", "to the": the words that lead to the name.
        var start = range.lowerBound
        while start > 0, range.lowerBound - start < 2, englishLeads.contains(words.keys[start - 1]) { start -= 1 }
        return found(list.name, words.dropping(start..<range.upperBound), allowingNothingElse)
      }
    }
    return nil
  }

  private static func found(_ name: String, _ rest: Utterance, _ allowingNothingElse: Bool) -> Found? {
    let text = rest.text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty || allowingNothingElse else { return nil }
    return Found(name: name, remainder: VoiceActionIntentBridge.capitalizedFirst(text))
  }
}

/// Where new Apple reminders go (plan 2.2): the list named in the request,
/// else the list chosen in Settings → iPhone tools, else iOS's default list.
/// Only lists that exist and accept changes are used.
@MainActor
enum ReminderLists {
  /// The chosen list's identifier; empty means iOS's default list.
  nonisolated static let preferredKey = "autoloom.reminders.listID"

  struct Option: Identifiable, Equatable {
    let id: String
    let title: String
  }

  static var hasAccess: Bool { EKEventStore.authorizationStatus(for: .reminder) == .fullAccess }

  /// Lists that take new reminders, by name.
  static func writable(in store: EKEventStore) -> [EKCalendar] {
    guard hasAccess else { return [] }
    return store.calendars(for: .reminder)
      .filter { $0.allowsContentModifications }
      .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
  }

  static func options(in store: EKEventStore) -> [Option] {
    writable(in: store).map { Option(id: $0.calendarIdentifier, title: $0.title) }
  }

  /// "İş listeme raporu gönder" → "Raporu gönder" in İş. The request itself
  /// is the fallback when a planned title lost the list's name. Nothing
  /// changes without access, or once a list is set.
  static func applyNamedList(to plan: inout DeviceActionPlan, request: String? = nil, store: EKEventStore) {
    guard plan.kind == .createReminder, plan.reminderListID == nil else { return }
    let lists = writable(in: store)
    guard !lists.isEmpty else { return }
    let names = lists.map { $0.title }
    if let title = plan.title, let found = ReminderListMention.find(in: title, listNames: names),
       let list = lists.first(where: { $0.title == found.name }) {
      plan.title = found.remainder
      plan.reminderListID = list.calendarIdentifier
      plan.reminderListName = list.title
    } else if let request, let found = ReminderListMention.find(in: request, listNames: names, allowingNothingElse: true),
              let list = lists.first(where: { $0.title == found.name }) {
      plan.reminderListID = list.calendarIdentifier
      plan.reminderListName = list.title
    }
  }

  /// Where a new reminder goes, with an English note for the voice model
  /// when a chosen list was not available.
  static func destination(
    for plan: DeviceActionPlan, store: EKEventStore, defaults: UserDefaults = .standard
  ) -> (list: EKCalendar?, note: String) {
    let fallback = store.defaultCalendarForNewReminders()
    let fallbackName = fallback?.title ?? "the default list"
    if let id = plan.reminderListID {
      if let list = store.calendar(withIdentifier: id), list.allowsContentModifications { return (list, "") }
      return (fallback, " The list \(plan.reminderListName ?? "the user named") is not available, so it went to \(fallbackName).")
    }
    if let id = defaults.string(forKey: preferredKey), !id.isEmpty {
      if let list = store.calendar(withIdentifier: id), list.allowsContentModifications { return (list, "") }
      return (fallback, " The list chosen in Settings is not available any more, so it went to \(fallbackName).")
    }
    return (fallback, "")
  }
}

extension AssistantOrchestrator {
  /// "Süt alma hatırlatıcısını tamamla" / "… sil" (plan 2.2): one open
  /// Apple reminder, found by its words, the one just saved, or the user's
  /// choice. Completing runs at once ("geri al" reopens it); deleting waits
  /// for a yes. Both are reported only after Reminders is read back.
  func runReminderEdit(
    _ target: ReminderTarget,
    delete: Bool,
    afterTaskSearch: Bool = false,
    decision: VoiceBridgeDecision,
    transcript: String,
    traceID: UUID
  ) async -> IntentOutcome {
    let trace = ActionTraceLog.shared
    let kind: DeviceActionKind = delete ? .deleteReminder : .completeReminder
    guard AssistantPreferences.actionsEnabled else { return actionsOff() }
    guard ToolRegistry.allows(kind) else { return toolOff(kind) }
    if let blocked = await permissionBlock(
      .reminders, fullCalendarAccess: false, decision: decision, transcript: transcript, traceID: traceID) {
      return blocked
    }
    trace.update(traceID) { $0.executor = "EventKit (" + (delete ? "delete after a yes" : "complete") + ", read back)" }
    let executor = DeviceActionExecutor.shared
    let open: [ReminderOption]
    do {
      open = try await executor.openReminderOptions()
    } catch {
      let message = LogSanitizer.sanitize(error.localizedDescription)
      return IntentOutcome(spoken: message + " Tell the user.", reply: message, failed: message)
    }
    let recentID = executor.lastCreated.flatMap { item in
      item.kind == .createReminder && Date().timeIntervalSince(item.at) < 600 ? item.identifier : nil
    }
    let chosen: ReminderOption
    switch Self.resolveReminder(target, among: open, recentID: recentID) {
    case .one(let option):
      chosen = option
    case .several(let options):
      trace.update(traceID) { $0.result = "asked which of \(options.count) reminders" }
      return askQuestion(.chooseReminder(delete: delete, options: options))
    case .noMatch:
      let lead = afterTaskSearch ? "No open AutoLoom task or Apple reminder" : "No open Apple reminder"
      let what: String
      if case .words(let words) = target, !words.isEmpty {
        what = " matches \"\(words)\""
      } else {
        what = " was found"
      }
      return IntentOutcome(
        spoken: "\(lead)\(what), so nothing was changed. Tell the user briefly.",
        reply: L.t("No matching reminder.", "Eşleşen hatırlatıcı yok."), failed: "no matching reminder")
    }
    var plan = DeviceActionPlan(kind: kind)
    plan.reminderID = chosen.id
    plan.title = chosen.title
    plan.reminderListName = chosen.list.isEmpty ? nil : chosen.list
    trace.update(traceID) { $0.parsed = "reminder \"\(TaskTrace.redactUserText(chosen.title, limit: 50))\"" }
    let staged = await stage(plan)
    await refreshBoards()
    if let failed = staged.failed {
      return IntentOutcome(spoken: staged.speakable, reply: staged.display ?? staged.speakable, failed: failed)
    }
    if delete {
      trace.update(traceID) { $0.result = "waiting for the user's yes" }
      return IntentOutcome(spoken: staged.speakable, reply: staged.display ?? staged.speakable)
    }
    let id = chosen.id
    LocalUndo.shared.record(kind: "reminder", english: "reminder reopened", turkish: "hatırlatıcı yeniden açıldı") {
      DeviceActionExecutor.shared.reopenReminder(id)
    }
    trace.update(traceID) { $0.persistence = "completed; Reminders read back" }
    let fact = staged.display ?? chosen.title
    return IntentOutcome(
      spoken: BridgeSpeech.done(fact, tr: "Tamam, tamamlandı olarak işaretledim.", en: "Done, marked as complete."),
      reply: fact, said: L.t("Done, marked as complete.", "Tamam, tamamlandı olarak işaretledim."))
  }

  /// The reminder a target means among the open ones. `recentID` is the
  /// reminder saved in the last ten minutes ("bu hatırlatıcıyı …"); without
  /// one, the user chooses among the soonest.
  nonisolated static func resolveReminder(
    _ target: ReminderTarget, among open: [ReminderOption], recentID: String?
  ) -> ReminderMatcher.Result {
    switch target {
    case .id(let id):
      guard let option = open.first(where: { $0.id == id }) else { return .noMatch }
      return .one(option)
    case .words(let words):
      let spoken = words.trimmingCharacters(in: .whitespacesAndNewlines)
      if spoken.isEmpty {
        if let recentID, let option = open.first(where: { $0.id == recentID }) { return .one(option) }
        return open.isEmpty ? .noMatch : .several(Array(open.prefix(4)))
      }
      // "Market listesindeki süt": only that list's reminders.
      let lists = Array(Set(open.map(\.list).filter { !$0.isEmpty }))
      if let mention = ReminderListMention.find(in: spoken, listNames: lists, allowingNothingElse: true) {
        let inList = open.filter { $0.list == mention.name }
        guard !mention.remainder.isEmpty else {
          if inList.count == 1 { return .one(inList[0]) }
          return inList.isEmpty ? .noMatch : .several(Array(inList.prefix(4)))
        }
        return ReminderMatcher.match(mention.remainder, in: inList)
      }
      return ReminderMatcher.match(spoken, in: open)
    }
  }
}
