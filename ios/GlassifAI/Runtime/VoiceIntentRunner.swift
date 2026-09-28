import EventKit
import Foundation
import UIKit
import UserNotifications

/// One command handled by the voice action bridge, for Settings → Developer
/// → Action & task trace: Transcript → Intent → Parser → Permission →
/// Executor → Result. Text is redacted; no audio is kept.
struct ActionTraceEntry: Identifiable, Equatable {
  let id = UUID()
  let at: Date
  var transcript: String
  var intent: String
  var parser: String
  var parsed = "—"
  var permission = "not needed"
  var executor = "—"
  var result = "running"
  var durationMs: Int?
}

@MainActor
final class ActionTraceLog: ObservableObject {
  static let shared = ActionTraceLog()

  @Published private(set) var entries: [ActionTraceEntry] = []

  func begin(transcript: String, decision: VoiceBridgeDecision) -> UUID {
    let entry = ActionTraceEntry(
      at: Date(),
      transcript: TaskTrace.redactUserText(transcript, limit: 120),
      intent: decision.intent.traceName,
      parser: "\(decision.level.rawValue): \(decision.rule)")
    entries.append(entry)
    if entries.count > 30 { entries.removeFirst(entries.count - 30) }
    return entry.id
  }

  func update(_ id: UUID, _ change: (inout ActionTraceEntry) -> Void) {
    guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
    change(&entries[index])
  }

  func clear() {
    entries.removeAll()
  }

  /// Copyable text of the recent entries.
  var text: String {
    entries.suffix(15).map { entry in
      """
      \(entry.at.formatted(date: .omitted, time: .standard))  "\(entry.transcript)"
        intent: \(entry.intent) · \(entry.parser)
        parsed: \(entry.parsed) · permission: \(entry.permission)
        executor: \(entry.executor) · result: \(entry.result)\(entry.durationMs.map { " · \($0) ms" } ?? "")
      """
    }.joined(separator: "\n")
  }
}

/// A spoken command that needs an iOS permission the user has not given.
/// It is kept for ten minutes and run as soon as the permission arrives, so
/// the user does not have to say it again.
struct PendingPermissionCommand {
  let decision: VoiceBridgeDecision
  let transcript: String
  let permission: AppPermission
  var needsFullCalendarAccess = false
  let createdAt = Date()

  static let lifetime: TimeInterval = 10 * 60

  var isExpired: Bool { Date().timeIntervalSince(createdAt) > Self.lifetime }
}

/// The result of one bridge command.
struct IntentOutcome {
  /// For the voice model: what the app did and how to tell the user.
  var spoken: String
  /// Plain text for the screen (typed requests and notices).
  var reply: String
  var failed: String?
}

/// Words the voice model is given for the app's own confirmations, so the
/// user hears one short natural answer ("Tamam, not aldım.").
enum BridgeSpeech {
  static func done(_ fact: String, tr: String, en: String) -> String {
    "\(fact) Tell the user in the conversation's language, in one short natural sentence such as \"\(tr)\" (in English: \"\(en)\"). Do not add anything else and do not ask a follow-up question."
  }

  static func ask(_ tr: String, en: String, note: String = "") -> String {
    "Nothing is saved yet.\(note.isEmpty ? "" : " \(note)") Ask the user in the conversation's language, in one short sentence: \"\(tr)\" (in English: \"\(en)\")."
  }
}

extension VoiceIntent {
  /// The task kind recorded in the conversation context.
  var factKind: AssistantTaskKind {
    switch self {
    case .saveMemory, .setName, .askName, .recallMemory, .recallConversation, .listMemories, .forgetMemory:
      .localMemory
    case .visualMemory: .visualMemory
    case .translateView: .vision
    case .classify(let kind, _): kind
    default: .authorizedAction
    }
  }

  var isQuestion: Bool {
    if case .ask = self { return true }
    return false
  }

  /// Answers to a pending action; they must not cancel it as "superseded".
  var isConfirmationOrChoice: Bool {
    switch self {
    case .confirmPending, .choosePendingTime: true
    default: false
    }
  }
}

extension AssistantOrchestrator {
  // MARK: Bridge entry points

  /// What the bridge knows about the conversation right now.
  func bridgeContext() -> VoiceBridgeContext {
    var bridge = VoiceBridgeContext()
    bridge.assistantName = AssistantIdentity.name
    if let pending = pendingAction, !pending.isExpired { bridge.pendingPlan = pending.plan }
    bridge.tasksRunning = !ledger.active.isEmpty
    if let since = bridgeAwaitingSince, Date().timeIntervalSince(since) < 90 { bridge.awaiting = bridgeAwaiting }
    // The current utterance is already the last user turn.
    let userTurns = context.turns.filter { $0.role == .user }
    let previousUser = userTurns.dropLast().last
    bridge.previousUserText = previousUser?.text
    if let answer = context.turns.last(where: { $0.role == .assistant }),
       answer.at >= (previousUser?.at ?? .distantPast) {
      bridge.lastAssistantText = answer.text
    }
    let camera = captureSource() != .off
    bridge.cameraAvailable = camera
    bridge.visualMemoryAvailable = camera && MemoryStore.shared.isEnabled && MemoryStore.shared.visualMemoriesEnabled
    bridge.addressedOnly = AssistantPreferences.respondsOnlyWhenAddressed
    return bridge
  }

  /// Called with each final user transcript of a voice turn (after
  /// `noteUserTurn`). Returns true when the app handles the turn itself;
  /// `deliver` then receives, once, the text for the voice model to say.
  func interceptVoiceTurn(_ text: String, deliver: @escaping @MainActor (String) -> Void) -> Bool {
    guard let decision = VoiceActionIntentBridge.decide(text, context: bridgeContext()) else { return false }
    NSLog("[AutoLoom] voice action bridge: %@ (%@)", decision.intent.traceName, decision.level.rawValue)
    Task { @MainActor [weak self] in
      guard let self else { return }
      let outcome = await self.runVoiceIntent(decision, transcript: text)
      deliver(outcome.spoken)
    }
    return true
  }

  /// Runs one bridge decision with tracing. Used for voice turns, typed
  /// requests and commands resumed after a permission was granted.
  func runVoiceIntent(_ decision: VoiceBridgeDecision, transcript: String) async -> IntentOutcome {
    let trace = ActionTraceLog.shared
    let traceID = trace.begin(transcript: transcript, decision: decision)
    let started = Date()
    // Any new decision answers or replaces an open question.
    if !decision.intent.isQuestion {
      bridgeAwaiting = nil
      bridgeAwaitingSince = nil
    }
    beginLocalWork()
    let outcome = await perform(decision, transcript: transcript, traceID: traceID)
    endLocalWork()
    trace.update(traceID) { entry in
      entry.durationMs = Int((Date().timeIntervalSince(started) * 1_000).rounded())
      if entry.result == "running" {
        entry.result = outcome.failed.map { "failed: " + LogSanitizer.sanitize($0, limit: 120) } ?? "success"
      }
    }
    if outcome.failed == nil {
      context.addFact(kind: decision.intent.factKind, request: transcript, result: outcome.reply, sources: [])
      noteConversationAction()
    }
    return outcome
  }

  /// Runs a command that was waiting for a permission, once the app is on
  /// screen and the permission is given.
  func resumePendingPermissionCommand() async {
    guard let pending = pendingPermissionCommand else { return }
    guard !pending.isExpired else {
      pendingPermissionCommand = nil
      return
    }
    guard UIApplication.shared.applicationState == .active else { return }
    switch pending.permission {
    case .reminders:
      try? await DeviceActionExecutor.shared.ensureReminderAccess()
    case .calendars:
      try? await DeviceActionExecutor.shared.ensureEventAccess(fullAccess: pending.needsFullCalendarAccess)
    case .notifications:
      _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    default:
      break
    }
    let state = await PermissionCenter.state(pending.permission)
    let usable = state == .granted || (state == .limited && !pending.needsFullCalendarAccess)
    // Still missing: keep it, the user may allow it in iOS Settings.
    guard usable else { return }
    pendingPermissionCommand = nil
    let outcome = await runVoiceIntent(pending.decision, transcript: pending.transcript)
    if let speak = speakInConversation, speak(outcome.spoken) { return }
    postNotice(outcome.reply)
  }

  // MARK: Execution

  private func perform(_ decision: VoiceBridgeDecision, transcript: String, traceID: UUID) async -> IntentOutcome {
    let trace = ActionTraceLog.shared
    let store = MemoryStore.shared
    switch decision.intent {
    case .confirmPending(let yes):
      trace.update(traceID) { $0.executor = "pending action" }
      if yes {
        let text = await confirmPendingAction(byVoice: true)
        await refreshBoards()
        return IntentOutcome(spoken: text, reply: lastActionResult ?? text)
      }
      let text = cancelPendingAction()
      return IntentOutcome(
        spoken: BridgeSpeech.done(text, tr: "Tamam, vazgeçtim.", en: "Okay, cancelled."),
        reply: L.t("Cancelled.", "Vazgeçildi."))

    case .choosePendingTime(let date):
      trace.update(traceID) {
        $0.parsed = TimePhraseParser.describe(date, hasTime: true, turkish: false)
        $0.executor = "pending action"
      }
      guard let staged = await choosePendingTime(date) else {
        return IntentOutcome(
          spoken: "There is no action waiting for a time any more. Ask the user to say the request again.",
          reply: L.t("Nothing is waiting.", "Bekleyen bir işlem yok."), failed: "no pending action")
      }
      await refreshBoards()
      return IntentOutcome(spoken: staged.speakable, reply: staged.display ?? staged.speakable, failed: staged.failed)

    case .cancelTasks:
      let cancelled = cancelAll(reason: "cancelled by user", voiceOnly: false)
      return IntentOutcome(
        spoken: BridgeSpeech.done(
          cancelled.isEmpty ? "No task was running." : "The running task was cancelled; nothing more will come from it.",
          tr: "Tamam, iptal ettim.", en: "Okay, cancelled."),
        reply: L.t("Cancelled.", "İptal edildi."))

    case .dropAwaiting:
      return IntentOutcome(
        spoken: BridgeSpeech.done("The user changed their mind; nothing was saved.", tr: "Tamam.", en: "Okay."),
        reply: L.t("Okay.", "Tamam."))

    case .saveNote(let text):
      guard ToolRegistry.allows(.saveNote) else { return toolOff(.saveNote) }
      trace.update(traceID) { $0.executor = "SwiftData (AutoLoom Notes)" }
      guard let note = store.addNote(title: nil, content: text, source: "voice") else {
        return IntentOutcome(
          spoken: "The note could not be saved on this iPhone. Tell the user honestly.",
          reply: L.t("The note could not be saved.", "Not kaydedilemedi."), failed: "note save failed")
      }
      trace.update(traceID) { $0.parsed = "note \"\(TaskTrace.redactUserText(note.title, limit: 60))\"" }
      return IntentOutcome(
        spoken: BridgeSpeech.done(
          "The app saved an AutoLoom note on this iPhone: \"\(note.title)\"." + temporaryStorageNote(store),
          tr: "Tamam, not aldım.", en: "Done, I've noted it."),
        reply: L.t("Noted: ", "Not alındı: ") + note.title)

    case .saveMemory(let text, let kind):
      guard store.isEnabled else { return memoryOff() }
      trace.update(traceID) { $0.executor = "SwiftData (memory)" }
      guard let record = store.remember(text, kind: kind, source: "voice") else {
        return IntentOutcome(
          spoken: "The memory could not be saved on this iPhone. Tell the user honestly.",
          reply: L.t("The memory could not be saved.", "Hafızaya kaydedilemedi."), failed: "memory save failed")
      }
      trace.update(traceID) { $0.parsed = "\(record.kind.rawValue) · \(record.category.rawValue)" }
      return IntentOutcome(
        spoken: BridgeSpeech.done(
          "Saved to the user's memory on this iPhone: \"\(record.text)\"." + temporaryStorageNote(store),
          tr: "Tamam, aklımda tutacağım.", en: "Got it, I'll remember that."),
        reply: L.t("Remembered: ", "Hafızaya alındı: ") + record.text)

    case .setName(let name):
      guard store.isEnabled else { return memoryOff() }
      trace.update(traceID) { $0.executor = "profile (on this iPhone)" }
      guard let saved = store.setPreferredName(name) else {
        return IntentOutcome(
          spoken: "That did not sound like a name, so nothing was saved. Ask the user to say their name again.",
          reply: L.t("That was not a name.", "Bu bir isim gibi görünmüyor."), failed: "not a name")
      }
      return IntentOutcome(
        spoken: "The user told you their name: \(saved). It is saved in their profile on this iPhone. From now on use it naturally, not in every sentence. Reply warmly in one short sentence, for example \"Memnun oldum \(saved), bunu hatırlayacağım.\" (in English: \"Nice to meet you, \(saved). I'll remember that.\").",
        reply: L.t("Your name is saved: ", "Adınız kaydedildi: ") + saved)

    case .askName:
      trace.update(traceID) { $0.executor = "profile (on this iPhone)" }
      if let name = store.profile.preferredName {
        return IntentOutcome(
          spoken: "The user's name, from their profile on this iPhone, is \(name). Answer naturally in a few words.",
          reply: name)
      }
      return IntentOutcome(
        spoken: "The user has not told you their name yet; their profile on this iPhone has none. Say so briefly and invite them to tell you (\"Benim adım …\").",
        reply: L.t("No name saved yet.", "Henüz bir isim kayıtlı değil."))

    case .recallMemory(let query):
      guard store.isEnabled else { return memoryOff() }
      trace.update(traceID) { $0.executor = "on-device memory search" }
      let hits = store.search(query, limit: 5)
      store.noteRecalled(hits)
      trace.update(traceID) { $0.parsed = "\(hits.count) matches" }
      guard !hits.isEmpty else {
        return IntentOutcome(
          spoken: "Nothing the user saved on this iPhone matches this question. Say honestly that you don't have it saved; do not guess.",
          reply: L.t("Nothing saved matches.", "Kayıtlı bir eşleşme yok."))
      }
      let lines = hits.map { "- \($0.line)" }.joined(separator: "\n")
      return IntentOutcome(
        spoken: "From the user's saved memories, notes and tasks on this iPhone (answer the question naturally from them and ignore the ones that do not fit):\n" + lines,
        reply: lines)

    case .recallConversation(let query):
      guard store.isEnabled else { return memoryOff() }
      trace.update(traceID) { $0.executor = "conversation summaries" }
      let summaries = store.searchConversations(query)
      trace.update(traceID) { $0.parsed = "\(summaries.count) summaries" }
      guard !summaries.isEmpty else {
        let off = store.conversationMemoryEnabled ? "" : " (conversation memory is turned off in Settings, Memory)"
        return IntentOutcome(
          spoken: "No summaries of earlier AutoLoom conversations are saved\(off). Say so honestly. You have no access to ChatGPT app chats.",
          reply: L.t("No earlier conversations are saved.", "Kayıtlı önceki konuşma yok."))
      }
      let lines = summaries.map { record in
        "- \(record.createdAt.formatted(date: .abbreviated, time: .shortened)): \(record.text.prefix(500))"
      }.joined(separator: "\n")
      return IntentOutcome(
        spoken: "Summaries of earlier AutoLoom conversations saved on this iPhone (these are not ChatGPT app chats). Answer naturally from them and say what they do not cover:\n" + lines,
        reply: lines)

    case .listMemories:
      guard store.isEnabled else { return memoryOff() }
      trace.update(traceID) { $0.executor = "on-device memory" }
      var lines: [String] = []
      if let name = store.profile.preferredName { lines.append("- Name: \(name)") }
      lines += store.memories.filter { $0.kind != .conversationSummary }.prefix(8).map { "- \($0.text.prefix(160))" }
      guard !lines.isEmpty else {
        return IntentOutcome(
          spoken: "Nothing is saved in the user's memory yet. Tell them briefly how: \"hatırla …\" or \"remember that …\".",
          reply: L.t("Nothing saved yet.", "Henüz bir şey kayıtlı değil."))
      }
      return IntentOutcome(
        spoken: "What the user has asked you to remember (\(store.memories.count) saved in total). Summarise briefly and naturally:\n" + lines.joined(separator: "\n"),
        reply: lines.joined(separator: "\n"))

    case .forgetMemory(let query):
      guard store.isEnabled else { return memoryOff() }
      trace.update(traceID) { $0.executor = "memory (needs a yes)" }
      let hits = store.search(query, limit: 3, includeNotes: false, includeTasks: false)
      guard let best = hits.first, case .memory(let record) = best.item else {
        return IntentOutcome(
          spoken: "No saved memory matches \"\(query)\", so nothing was forgotten. Tell the user.",
          reply: L.t("No matching memory.", "Eşleşen anı yok."))
      }
      if hits.count > 1, hits[1].score >= best.score * 0.9 {
        let options = hits.prefix(3).map { "\"\($0.line)\"" }.joined(separator: "; ")
        return IntentOutcome(
          spoken: "Several memories match: \(options). Ask the user which one to forget.",
          reply: options)
      }
      var plan = DeviceActionPlan(kind: .forgetMemory)
      plan.memoryID = record.id
      plan.text = record.text
      let staged = await stage(plan)
      return IntentOutcome(spoken: staged.speakable, reply: staged.display ?? record.text, failed: staged.failed)

    case .visualMemory(let query):
      trace.update(traceID) { $0.executor = "camera + vision model + memory" }
      let result = await runBridgeTask(.visualMemory, query: query)
      return IntentOutcome(spoken: result.speakable, reply: result.display ?? result.speakable, failed: result.failed)

    case .createReminder(let title, let time):
      return await stageAction(.createReminder, title: title, time: time, decision: decision, transcript: transcript, traceID: traceID)

    case .notify(let title, let time):
      return await stageAction(
        .scheduleNotification, title: title ?? L.t("Reminder", "Hatırlatma"), time: time,
        decision: decision, transcript: transcript, traceID: traceID)

    case .createEvent(let title, let time):
      return await stageAction(.createEvent, title: title, time: time, decision: decision, transcript: transcript, traceID: traceID)

    case .createTask(let title, let time):
      return await createTask(title: title, time: time, traceID: traceID)

    case .readCalendar(let range):
      guard AssistantPreferences.actionsEnabled else { return actionsOff() }
      guard ToolRegistry.allows(.todayEvents) else { return toolOff(.todayEvents) }
      if let blocked = await permissionBlock(
        .calendars, fullCalendarAccess: true, decision: decision, transcript: transcript, traceID: traceID) {
        return blocked
      }
      trace.update(traceID) {
        $0.executor = "EventKit (read)"
        $0.parsed = range.rawValue
      }
      do {
        let (offset, days) = range == .today ? (0, 1) : range == .tomorrow ? (1, 1) : (0, 7)
        let text = try await DeviceActionExecutor.shared.readEvents(dayOffset: offset, days: days)
        return IntentOutcome(
          spoken: text + "\nTell the user naturally and briefly: times and titles, the next one first; do not read it like a list.",
          reply: text)
      } catch {
        let message = LogSanitizer.sanitize(error.localizedDescription)
        return IntentOutcome(spoken: message + " Tell the user.", reply: message, failed: message)
      }

    case .listTasks:
      trace.update(traceID) { $0.executor = "AutoLoom Tasks + EventKit" }
      let open = store.tasks.filter { !$0.completed }.prefix(8)
      var sections: [String] = []
      if !open.isEmpty {
        sections.append("Open AutoLoom tasks:\n" + open.map { "- " + taskLine($0) }.joined(separator: "\n"))
      }
      if AssistantPreferences.actionsEnabled, ToolRegistry.allows(.listReminders),
         await PermissionCenter.state(.reminders) == .granted,
         let reminders = try? await DeviceActionExecutor.shared.run(DeviceActionPlan(kind: .listReminders)) {
        sections.append(reminders)
      }
      guard !sections.isEmpty else {
        return IntentOutcome(
          spoken: "The user has no open AutoLoom tasks (and no readable reminders). Say so briefly.",
          reply: L.t("No open tasks.", "Açık görev yok."))
      }
      let text = sections.joined(separator: "\n")
      return IntentOutcome(
        spoken: text + "\nSummarise briefly and naturally, mentioning due times; the full list is in the Tasks tab.",
        reply: text)

    case .completeTask(let query):
      trace.update(traceID) { $0.executor = "AutoLoom Tasks" }
      let words = MemorySearch.tokens(query)
      let open = store.tasks.filter { !$0.completed }
      let scored = open.map { ($0, MemorySearch.lexicalScore(query: words, document: MemorySearch.tokens($0.title))) }
      guard let best = scored.max(by: { $0.1 < $1.1 }), best.1 >= 0.5 else {
        return IntentOutcome(
          spoken: "No open AutoLoom task matches \"\(query)\". Tell the user; Apple Reminders can be completed in the Tasks tab.",
          reply: L.t("No matching task.", "Eşleşen görev yok."))
      }
      let title = best.0.title
      store.setCompleted(best.0, true)
      return IntentOutcome(
        spoken: BridgeSpeech.done(
          "Marked the AutoLoom task \"\(title)\" as done.", tr: "Tamam, tamamlandı olarak işaretledim.", en: "Done, marked as complete."),
        reply: L.t("Completed: ", "Tamamlandı: ") + title)

    case .translateView(let language):
      trace.update(traceID) { $0.executor = "camera (high detail) + OCR + vision model" }
      let result = await runBridgeTask(
        .vision,
        query: "Read the text in view exactly and translate it into \(language). Say the translation naturally and mention in a few words what it is written on (sign, menu, label, screen).",
        detail: .high)
      return IntentOutcome(spoken: result.speakable, reply: result.display ?? result.speakable, failed: result.failed)

    case .routine(let routine):
      return await runRoutine(routine, traceID: traceID)

    case .ask(let awaiting):
      bridgeAwaiting = awaiting
      bridgeAwaitingSince = Date()
      switch awaiting {
      case .note:
        return IntentOutcome(spoken: BridgeSpeech.ask("Neyi not alayım?", en: "What should I note?"), reply: L.t("What should I note?", "Neyi not alayım?"))
      case .memory:
        return IntentOutcome(
          spoken: BridgeSpeech.ask("Neyi hatırlamamı istersin?", en: "What should I remember?"),
          reply: L.t("What should I remember?", "Neyi hatırlamamı istersiniz?"))
      case .task:
        return IntentOutcome(
          spoken: BridgeSpeech.ask("Göreve ne yazayım?", en: "What should the task say?"),
          reply: L.t("What should the task say?", "Göreve ne yazayım?"))
      case .reminderTime(let title):
        return IntentOutcome(
          spoken: BridgeSpeech.ask("Ne zaman hatırlatayım?", en: "When should I remind you?", note: "The reminder will say \"\(title)\"."),
          reply: L.t("When should I remind you?", "Ne zaman hatırlatayım?"))
      case .eventTime(let title):
        return IntentOutcome(
          spoken: BridgeSpeech.ask("Saat kaçta olsun?", en: "What time should it be?", note: "The event is \"\(title)\"."),
          reply: L.t("What time should it be?", "Saat kaçta olsun?"))
      }

    case .classify(let kind, let query):
      trace.update(traceID) { $0.executor = "model classification (strict JSON) → \(kind.rawValue)" }
      let result = await runBridgeTask(kind, query: query)
      await refreshBoards()
      return IntentOutcome(spoken: result.speakable, reply: result.display ?? result.speakable, failed: result.failed)
    }
  }

  // MARK: Actions with a time

  /// Reminders, notifications and events: validated plan, permission, then
  /// the SAFE action runs (an ambiguous time is asked first). Success is
  /// reported only after iOS confirmed it.
  private func stageAction(
    _ kind: DeviceActionKind,
    title: String,
    time: ParsedTime?,
    decision: VoiceBridgeDecision,
    transcript: String,
    traceID: UUID
  ) async -> IntentOutcome {
    let trace = ActionTraceLog.shared
    guard AssistantPreferences.actionsEnabled else { return actionsOff() }
    guard ToolRegistry.allows(kind) else { return toolOff(kind) }
    var plan = DeviceActionPlan(kind: kind)
    plan.title = title
    if let time {
      plan.date = time.date
      plan.hasTime = time.hasTime
      plan.alternativeDate = time.isAmbiguous ? time.alternative : nil
    }
    let validated: DeviceActionPlan
    switch DeviceActionParser.validate(plan, now: Date()) {
    case .success(let checked):
      validated = checked
    case .failure(let error):
      trace.update(traceID) { $0.result = "invalid: \(error.speakable)" }
      return IntentOutcome(
        spoken: error.speakable + " Tell the user briefly and ask for what is missing.",
        reply: error.speakable, failed: error.speakable)
    }
    trace.update(traceID) { $0.parsed = Self.traceText(validated, time: time) }
    let permission: AppPermission = kind == .createEvent ? .calendars : kind == .scheduleNotification ? .notifications : .reminders
    if let blocked = await permissionBlock(
      permission, fullCalendarAccess: false, decision: decision, transcript: transcript, traceID: traceID) {
      return blocked
    }
    trace.update(traceID) { $0.executor = kind == .scheduleNotification ? "UserNotifications" : "EventKit" }
    let staged = await stage(validated)
    await refreshBoards()
    let waiting = pendingAction != nil
    trace.update(traceID) { entry in
      entry.result = staged.failed.map { "failed: " + LogSanitizer.sanitize($0, limit: 120) }
        ?? (waiting ? "waiting for the user's choice" : "success (iOS confirmed)")
    }
    return IntentOutcome(spoken: staged.speakable, reply: staged.display ?? staged.speakable, failed: staged.failed)
  }

  private static func traceText(_ plan: DeviceActionPlan, time: ParsedTime?) -> String {
    var text = "title \"\(TaskTrace.redactUserText(plan.title ?? "", limit: 50))\""
    if let date = plan.date {
      text += "; " + TimePhraseParser.describe(date, hasTime: plan.hasTime, turkish: false)
      if let other = plan.alternativeDate {
        text += " or " + other.formatted(date: .omitted, time: .shortened) + " (ambiguous)"
      }
    } else {
      text += "; no time"
    }
    if let matched = time?.matched, !matched.isEmpty { text += " from \"\(matched)\"" }
    return text
  }

  /// Checks an iOS permission before a spoken action. When it is missing,
  /// the command is kept and resumed as soon as the permission is given.
  private func permissionBlock(
    _ permission: AppPermission,
    fullCalendarAccess: Bool,
    decision: VoiceBridgeDecision,
    transcript: String,
    traceID: UUID
  ) async -> IntentOutcome? {
    let trace = ActionTraceLog.shared
    let state = await PermissionCenter.state(permission)
    let onScreen = UIApplication.shared.applicationState == .active
    let usable = state == .granted || (state == .limited && !fullCalendarAccess)
    if usable {
      trace.update(traceID) { $0.permission = "\(permission.rawValue): granted" }
      return nil
    }
    if (state == .notAsked || state == .limited) && onScreen {
      // The executor asks now; iOS shows its prompt on screen.
      trace.update(traceID) { $0.permission = "\(permission.rawValue): asked on screen" }
      return nil
    }
    var pending = PendingPermissionCommand(decision: decision, transcript: transcript, permission: permission)
    pending.needsFullCalendarAccess = fullCalendarAccess
    pendingPermissionCommand = pending
    let name = permission.label
    if state == .denied {
      trace.update(traceID) {
        $0.permission = "\(permission.rawValue): denied; command kept for 10 min"
        $0.result = "waiting for permission"
      }
      return IntentOutcome(
        spoken: "\(name) access is turned off for this app, so nothing was saved yet. The user can allow it in iOS Settings, AutoLoom Media Glasses, \(name). The command is kept for ten minutes and will be done as soon as they return to the app with access allowed. Tell them briefly.",
        reply: L.t("Allow \(name) in iOS Settings; it will be saved then.", "iOS Ayarlar'dan \(name) izni verin; o zaman kaydedilecek."),
        failed: "permission denied")
    }
    trace.update(traceID) {
      $0.permission = "\(permission.rawValue): needs the app on screen; command kept for 10 min"
      $0.result = "waiting for permission"
    }
    return IntentOutcome(
      spoken: "iOS asks for \(name) permission only while the app is open on the phone. The command is kept for ten minutes and will be done as soon as the user opens AutoLoom Media Glasses and allows it. Tell them this in one or two short sentences.",
      reply: L.t("Open the app and allow \(name); it will be saved then.", "Uygulamayı açıp \(name) izni verin; o zaman kaydedilecek."),
      failed: "permission needed")
  }

  // MARK: AutoLoom tasks

  private func createTask(title: String, time: ParsedTime?, traceID: UUID) async -> IntentOutcome {
    let store = MemoryStore.shared
    let trace = ActionTraceLog.shared
    trace.update(traceID) { $0.executor = "SwiftData (AutoLoom Tasks)" }
    guard let task = store.addTask(
      title: title, dueAt: time?.date, dueHasTime: time?.hasTime ?? true, source: "voice") else {
      return IntentOutcome(
        spoken: "The task could not be saved on this iPhone. Tell the user honestly.",
        reply: L.t("The task could not be saved.", "Görev kaydedilemedi."), failed: "task save failed")
    }
    var due = ""
    if let date = task.dueAt {
      due = " due " + TimePhraseParser.describe(date, hasTime: task.dueHasTime, turkish: false)
      if time?.isAmbiguous == true, let other = time?.alternative {
        due += " (the user may have meant \(other.formatted(date: .omitted, time: .shortened)); mention the time so they can correct it)"
      }
      if task.dueHasTime, date > Date() { await scheduleNotification(for: task, traceID: traceID) }
    }
    trace.update(traceID) { $0.parsed = "title \"\(TaskTrace.redactUserText(task.title, limit: 50))\";\(due.isEmpty ? " no date" : due)" }
    return IntentOutcome(
      spoken: BridgeSpeech.done(
        "The app added an AutoLoom task on this iPhone: \"\(task.title)\"\(due). It is in the Tasks tab.",
        tr: "Tamam, görevlere ekledim.", en: "Done, it's on your task list."),
      reply: L.t("Task added: ", "Görev eklendi: ") + task.title)
  }

  /// An optional alert at the task's due time. The task is saved even when
  /// notifications are not allowed.
  private func scheduleNotification(for task: TaskItem, traceID: UUID) async {
    guard let date = task.dueAt else { return }
    let state = await PermissionCenter.state(.notifications)
    let onScreen = UIApplication.shared.applicationState == .active
    guard state == .granted || (state == .notAsked && onScreen) else {
      ActionTraceLog.shared.update(traceID) { $0.permission = "notifications: \(state.label) (task saved without an alert)" }
      return
    }
    do {
      let id = try await LocalNotifications.schedule(
        title: task.title, body: L.t("AutoLoom task", "AutoLoom görevi"), at: date)
      MemoryStore.shared.setNotificationID(task, id)
      ActionTraceLog.shared.update(traceID) { $0.permission = "notifications: granted (alert scheduled)" }
    } catch {
      ActionTraceLog.shared.update(traceID) {
        $0.permission = "notifications: " + LogSanitizer.sanitize(error.localizedDescription, limit: 80)
      }
    }
  }

  private func taskLine(_ task: TaskItem) -> String {
    guard let due = task.dueAt else { return task.title }
    return "\(task.title) (\(TimePhraseParser.describe(due, hasTime: task.dueHasTime, turkish: false)))"
  }

  // MARK: Routines

  /// "İşe başlıyorum" and "günün özeti": the day's calendar, tasks and
  /// reminders from the phone; nothing is invented.
  private func runRoutine(_ routine: VoiceIntent.Routine, traceID: UUID) async -> IntentOutcome {
    let store = MemoryStore.shared
    var parts: [String] = []
    let today = store.todayTasks()
    parts.append(today.isEmpty
      ? "No AutoLoom tasks are due today."
      : "AutoLoom tasks due today:\n" + today.prefix(6).map { "- " + taskLine($0) }.joined(separator: "\n"))
    if AssistantPreferences.actionsEnabled {
      if await PermissionCenter.state(.calendars) == .granted,
         let events = try? await DeviceActionExecutor.shared.readEvents(dayOffset: 0, days: 1) {
        parts.append(events)
      } else {
        parts.append("The calendar could not be read (calendar access is not allowed).")
      }
      if await PermissionCenter.state(.reminders) == .granted,
         let reminders = try? await DeviceActionExecutor.shared.run(DeviceActionPlan(kind: .listReminders)) {
        parts.append(reminders)
      }
    }
    ActionTraceLog.shared.update(traceID) { $0.executor = "AutoLoom Tasks + EventKit (read)" }
    switch routine {
    case .startWork:
      let wake = WakePhraseListener.shared
      if !wake.isArmed {
        wake.isArmed = true
        parts.append("The wake phrase \"\(WakePhraseSettings.phrase)\" is now armed (Hands-Free Ready) for after this conversation.")
      }
      return IntentOutcome(
        spoken: "The user is starting work. " + parts.joined(separator: "\n") +
          "\nGive a short, friendly start-of-day summary: the next event first, then what is due today. Two to four sentences.",
        reply: parts.joined(separator: "\n"))
    case .briefing:
      return IntentOutcome(
        spoken: "The user asked for a briefing of their day. " + parts.joined(separator: "\n") +
          "\nSummarise in three or four natural sentences. Weather or news are not included; offer to look them up if they want.",
        reply: parts.joined(separator: "\n"))
    }
  }

  // MARK: Helpers

  private func refreshBoards() async {
    await RemindersBoard.shared.load()
  }

  private func temporaryStorageNote(_ store: MemoryStore) -> String {
    store.isPersistent ? "" : " (Storage on this iPhone is temporary right now; mention that it may not survive a restart.)"
  }

  private func memoryOff() -> IntentOutcome {
    IntentOutcome(
      spoken: "Memory is turned off in the app, so nothing was saved or read. The user can turn it on in Settings, Memory. Tell them briefly.",
      reply: L.t("Memory is off in Settings.", "Hafıza Ayarlar'da kapalı."), failed: "memory off")
  }

  private func actionsOff() -> IntentOutcome {
    IntentOutcome(
      spoken: "iPhone actions are turned off in the app settings, so nothing was done. The user can turn them on in Settings, Tools. Tell them briefly.",
      reply: L.t("iPhone actions are off in Settings.", "iPhone işlemleri Ayarlar'da kapalı."), failed: "actions off")
  }

  private func toolOff(_ kind: DeviceActionKind) -> IntentOutcome {
    IntentOutcome(
      spoken: "The \(kind.label) tool is turned off in Settings, Tools, so nothing was done. Tell the user briefly.",
      reply: L.t("\(kind.label) is off in Settings → Tools.", "\(kind.label) Ayarlar → Araçlar'da kapalı."), failed: "tool off")
  }
}
