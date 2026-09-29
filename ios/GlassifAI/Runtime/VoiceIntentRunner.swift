import Contacts
import EventKit
import Foundation
import MessageUI
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
  /// The short confirmed result for the screen ("✓ Not kaydedildi").
  var feedback: ActionFeedback?
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

  /// About other people: the trace and the conversation facts keep no
  /// names, numbers or message text.
  var isPrivate: Bool {
    switch self {
    case .call, .message, .findContact:
      return true
    case .ask(let awaiting):
      switch awaiting {
      case .messageBody, .messageRecipient, .chooseContact: return true
      default: return false
      }
    default:
      return false
    }
  }

  /// Commands a free-text delegation of the voice model may run directly.
  var runsFromDelegation: Bool {
    switch self {
    case .saveNote, .saveMemory, .createReminder, .notify, .createTask, .createEvent, .readCalendar, .listTasks,
         .dayPlan, .call, .message, .findContact, .directions, .nearby, .copyText, .shareText:
      true
    default:
      false
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
    if let saved = recentSaved, Date().timeIntervalSince(saved.at) < 180 { bridge.recentSavedText = saved.text }
    if let contact = recentContact, Date().timeIntervalSince(contact.at) < 600 { bridge.recentContact = contact.name }
    let camera = captureSource() != .off
    bridge.cameraAvailable = camera
    bridge.visualMemoryAvailable = camera && MemoryStore.shared.isEnabled && MemoryStore.shared.visualMemoriesEnabled
    bridge.addressedOnly = AssistantPreferences.respondsOnlyWhenAddressed
    return bridge
  }

  /// The bridge's decision for these words, if the app handles them itself.
  func bridgeDecision(for text: String) -> VoiceBridgeDecision? {
    VoiceActionIntentBridge.decide(text, context: bridgeContext())
  }

  /// Called with each final user transcript of a voice turn (after
  /// `noteUserTurn`). Returns true when the app handles the turn itself;
  /// `deliver` then receives, once, the text for the voice model to say.
  func interceptVoiceTurn(
    _ text: String,
    decision: VoiceBridgeDecision? = nil,
    deliver: @escaping @MainActor (String) -> Void
  ) -> Bool {
    guard let decision = decision ?? bridgeDecision(for: text) else { return false }
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
    let privateRequest = decision.intent.isPrivate
    let traceID = trace.begin(
      transcript: privateRequest ? "(about a contact; the words are not kept)" : transcript, decision: decision)
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
    if let feedback = outcome.feedback { postFeedback(feedback) }
    if outcome.failed == nil {
      if !privateRequest {
        context.addFact(kind: decision.intent.factKind, request: transcript, result: outcome.reply, sources: [])
      }
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
    case .contacts:
      if CNContactStore.authorizationStatus(for: .contacts) == .notDetermined {
        _ = try? await CNContactStore().requestAccess(for: .contacts)
      }
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
          reply: L.t("The note could not be saved.", "Not kaydedilemedi."), failed: "note save failed",
          feedback: .failed(L.t("Note not saved", "Not kaydedilemedi")))
      }
      recentSaved = (note.content, Date())
      trace.update(traceID) { $0.parsed = "note \"\(TaskTrace.redactUserText(note.title, limit: 60))\"" }
      return IntentOutcome(
        spoken: BridgeSpeech.done(
          "The app saved an AutoLoom note on this iPhone: \"\(note.title)\"." + temporaryStorageNote(store),
          tr: "Tamam, not aldım.", en: "Done, I've noted it."),
        reply: L.t("Noted: ", "Not alındı: ") + note.title,
        feedback: .noteSaved())

    case .saveMemory(let text, let kind):
      guard store.isEnabled else { return memoryOff() }
      trace.update(traceID) { $0.executor = "SwiftData (memory)" }
      guard let record = store.remember(text, kind: kind, source: "voice") else {
        return IntentOutcome(
          spoken: "The memory could not be saved on this iPhone. Tell the user honestly.",
          reply: L.t("The memory could not be saved.", "Hafızaya kaydedilemedi."), failed: "memory save failed",
          feedback: .failed(L.t("Not remembered", "Hafızaya kaydedilemedi")))
      }
      recentSaved = (record.text, Date())
      trace.update(traceID) { $0.parsed = "\(record.kind.rawValue) · \(record.category.rawValue)" }
      return IntentOutcome(
        spoken: BridgeSpeech.done(
          "Saved to the user's memory on this iPhone: \"\(record.text)\"." + temporaryStorageNote(store),
          tr: "Tamam, aklımda tutacağım.", en: "Got it, I'll remember that."),
        reply: L.t("Remembered: ", "Hafızaya alındı: ") + record.text,
        feedback: .memorySaved())

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
        reply: L.t("Your name is saved: ", "Adınız kaydedildi: ") + saved,
        feedback: ActionFeedback(kind: .memory, title: L.t("Name saved", "Adın kaydedildi")))

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
        reply: L.t("Completed: ", "Tamamlandı: ") + title,
        feedback: ActionFeedback(kind: .taskDone, title: L.t("Task completed", "Görev tamamlandı")))

    case .dayPlan(let range):
      return await runDayPlan(range, traceID: traceID)

    case .translateView(let language):
      trace.update(traceID) { $0.executor = "camera (high detail) + OCR + vision model" }
      let result = await runBridgeTask(
        .vision,
        query: "Read the text in view exactly and translate it into \(language). Say the translation naturally and mention in a few words what it is written on (sign, menu, label, screen).",
        detail: .high)
      return IntentOutcome(spoken: result.speakable, reply: result.display ?? result.speakable, failed: result.failed)

    case .call(let name):
      return await prepareCall(name, decision: decision, transcript: transcript, traceID: traceID)

    case .message(let name, let body):
      return await prepareMessage(to: name, body: body, decision: decision, transcript: transcript, traceID: traceID)

    case .findContact(let name):
      return await lookUpContact(name, decision: decision, transcript: transcript, traceID: traceID)

    case .directions(let destination):
      return await prepareDirections(to: destination, traceID: traceID)

    case .nearby(let query):
      guard AssistantPreferences.actionsEnabled else { return actionsOff() }
      guard ToolRegistry.allows(.openMaps) else { return toolOff(.openMaps) }
      trace.update(traceID) { $0.executor = "Apple Maps (search near the user)" }
      return await openMaps(query, search: true, traceID: traceID)

    case .copyText(let text):
      return copyToClipboard(text, traceID: traceID)

    case .shareText(let text):
      return await prepareShare(text, traceID: traceID)

    case .routine(let routine):
      return await runRoutine(routine, traceID: traceID)

    case .ask(let awaiting):
      return askQuestion(awaiting)

    case .classify(let kind, let query):
      trace.update(traceID) { $0.executor = "model classification (strict JSON) → \(kind.rawValue)" }
      let result = await runBridgeTask(kind, query: query)
      await refreshBoards()
      return IntentOutcome(spoken: result.speakable, reply: result.display ?? result.speakable, failed: result.failed)
    }
  }

  // MARK: Questions

  /// Asks for what the command was missing; the next utterance answers it.
  private func askQuestion(_ awaiting: VoiceIntent.Awaiting) -> IntentOutcome {
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
    case .messageBody(let contact):
      return IntentOutcome(
        spoken: BridgeSpeech.ask(
          "\(TurkishSuffix.dative(contact)) ne yazayım?", en: "What should I write to \(contact)?",
          note: "Nothing is sent without the user's own tap."),
        reply: L.t("What should I write?", "Ne yazayım?"))
    case .messageRecipient:
      return IntentOutcome(
        spoken: BridgeSpeech.ask("Kime yazayım?", en: "Who should I write to?"),
        reply: L.t("Who should I write to?", "Kime yazayım?"))
    case .chooseContact(_, let names):
      return IntentOutcome(
        spoken: BridgeSpeech.ask("Hangisi: \(names.joined(separator: ", "))?", en: "Which one: \(names.joined(separator: ", "))?"),
        reply: L.t("Which one? ", "Hangisi? ") + names.joined(separator: ", "))
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
        spoken: "\(name) access is turned off for this app, so nothing was done yet. The user can allow it in iOS Settings, AutoLoom Media Glasses, \(name). The command is kept for ten minutes and will be done as soon as they return to the app with access allowed. Tell them briefly.",
        reply: L.t("Allow \(name) in iOS Settings; it will be done then.", "iOS Ayarlar'dan \(name) izni verin; o zaman yapılacak."),
        failed: "permission denied")
    }
    trace.update(traceID) {
      $0.permission = "\(permission.rawValue): needs the app on screen; command kept for 10 min"
      $0.result = "waiting for permission"
    }
    return IntentOutcome(
      spoken: "iOS asks for \(name) permission only while the app is open on the phone. The command is kept for ten minutes and will be done as soon as the user opens AutoLoom Media Glasses and allows it. Tell them this in one or two short sentences.",
      reply: L.t("Open the app and allow \(name); it will be done then.", "Uygulamayı açıp \(name) izni verin; o zaman yapılacak."),
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
        reply: L.t("The task could not be saved.", "Görev kaydedilemedi."), failed: "task save failed",
        feedback: .failed(L.t("Task not added", "Görev eklenemedi")))
    }
    recentSaved = (task.title, Date())
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
      reply: L.t("Task added: ", "Görev eklendi: ") + task.title,
      feedback: .taskAdded(due: task.dueAt, hasTime: task.dueHasTime))
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

  // MARK: The day at a glance

  /// "Bugün ne yapmam gerekiyor?": AutoLoom tasks, Apple Reminders and the
  /// calendar for one day, counted together. Only what the phone has.
  private func runDayPlan(_ range: VoiceIntent.CalendarRange, traceID: UUID) async -> IntentOutcome {
    let store = MemoryStore.shared
    let calendar = Calendar.current
    let offset = range == .tomorrow ? 1 : 0
    let dayStart = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: Date())) ?? Date()
    let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86_400)
    let dayWord = offset == 0 ? "today" : "tomorrow"
    // Today also counts what is overdue.
    let tasks = store.tasks.filter { task in
      guard !task.completed, let due = task.dueAt else { return false }
      return due < dayEnd && (offset == 0 || due >= dayStart)
    }
    var total = tasks.count
    var parts: [String] = []
    if !tasks.isEmpty {
      parts.append("AutoLoom tasks (\(tasks.count)):\n" + tasks.prefix(6).map { "- " + taskLine($0) }.joined(separator: "\n"))
    }
    var unreadable: [String] = []
    if AssistantPreferences.actionsEnabled {
      if await PermissionCenter.state(.reminders) == .granted,
         let reminders = try? await DeviceActionExecutor.shared.dueReminderLines(from: dayStart, to: dayEnd, includeOverdue: offset == 0) {
        total += reminders.count
        if !reminders.isEmpty {
          parts.append("Apple Reminders (\(reminders.count)):\n" + reminders.map { "- " + $0 }.joined(separator: "\n"))
        }
      } else {
        unreadable.append("Reminders")
      }
      if await PermissionCenter.state(.calendars) == .granted,
         let events = try? await DeviceActionExecutor.shared.eventLines(from: dayStart, to: dayEnd) {
        total += events.count
        if !events.isEmpty {
          parts.append("Calendar events (\(events.count)):\n" + events.map { "- " + $0 }.joined(separator: "\n"))
        }
      } else {
        unreadable.append("Calendar")
      }
    }
    ActionTraceLog.shared.update(traceID) {
      $0.executor = "AutoLoom Tasks + EventKit (read)"
      $0.parsed = "\(dayWord): \(total) item(s)" + (unreadable.isEmpty ? "" : "; not readable: " + unreadable.joined(separator: ", "))
    }
    let missing = unreadable.isEmpty
      ? ""
      : "\n\(unreadable.joined(separator: " and ")) could not be read (no access); mention that briefly."
    let example = offset == 0 ? "\"Bugün \(total) işin var.\" (in English: \"You have \(total) things today.\")"
      : "\"Yarın \(total) işin var.\" (in English: \"You have \(total) things tomorrow.\")"
    guard total > 0 else {
      return IntentOutcome(
        spoken: "The user asked what they have to do \(dayWord). Nothing is due \(dayWord) in AutoLoom tasks\(unreadable.isEmpty ? ", Apple Reminders or the calendar" : "")." + missing + "\nSay so warmly in one short sentence.",
        reply: L.t("Nothing due.", "Bir şey yok."))
    }
    return IntentOutcome(
      spoken: "The user asked what they have to do \(dayWord). \(total) item(s) in total.\n" + parts.joined(separator: "\n") + missing +
        "\nStart with the count in one short sentence, for example \(example), then name them briefly, the earliest first. Do not read it like a list.",
      reply: parts.joined(separator: "\n"))
  }

  // MARK: Calls, messages and contacts

  private enum PhoneLookup {
    case found(name: String, phone: String)
    case choose([String])
    case failed(IntentOutcome)
  }

  /// One contact with a number, or the names to choose from. Several
  /// matches are asked about, never guessed.
  private func findPhone(for name: String, traceID: UUID) async -> PhoneLookup {
    // A number said as digits needs no lookup.
    if !name.contains(where: \.isLetter), let phone = DeviceActionParser.normalizedPhone(name) {
      return .found(name: phone, phone: phone)
    }
    let matches: [ContactsLookup.Match]
    do {
      matches = try await findContacts(name).filter { !$0.phones.isEmpty }
    } catch {
      let message = LogSanitizer.sanitize(error.localizedDescription)
      return .failed(IntentOutcome(spoken: message + " Tell the user briefly.", reply: message, failed: "contacts unavailable"))
    }
    ActionTraceLog.shared.update(traceID) { $0.parsed = "\(matches.count) contact match(es) with a number" }
    guard !matches.isEmpty else {
      return .failed(IntentOutcome(
        spoken: "No contact matching \"\(name)\" with a phone number is in the user's Contacts on this iPhone, so nothing was prepared. Tell them honestly and ask for the name as it is saved in Contacts.",
        reply: L.t("No contact found.", "Rehberde bulunamadı."), failed: "contact not found"))
    }
    var chosen: ContactsLookup.Match? = matches.count == 1 ? matches[0] : nil
    if chosen == nil {
      let spoken = MemorySearch.fold(name)
      let exact = matches.filter { MemorySearch.fold($0.name) == spoken }
      if exact.count == 1 { chosen = exact[0] }
    }
    guard let match = chosen else { return .choose(matches.prefix(4).map(\.name)) }
    guard let phone = Self.preferredPhone(match) else {
      return .failed(IntentOutcome(
        spoken: "\(match.name) has no usable phone number in Contacts. Tell the user.",
        reply: L.t("No usable number.", "Kullanılabilir numara yok."), failed: "no phone number"))
    }
    return .found(name: match.name, phone: phone)
  }

  /// "Annem" is often saved as "Anne".
  private func findContacts(_ name: String) async throws -> [ContactsLookup.Match] {
    let direct = try await ContactsLookup.find(name)
    if !direct.isEmpty { return direct }
    for alternative in VoiceActionIntentBridge.relationAlternatives[name] ?? [] {
      let found = try await ContactsLookup.find(alternative)
      if !found.isEmpty { return found }
    }
    return []
  }

  /// The mobile number, else the only or first one.
  static func preferredPhone(_ match: ContactsLookup.Match) -> String? {
    let mobile = match.phones.first { phone in
      let label = phone.label.lowercased()
      return label.contains("mobile") || label.contains("cep") || label.contains("iphone")
    }
    return (mobile ?? match.phones.first).flatMap { DeviceActionParser.normalizedPhone($0.number) }
  }

  /// "İki Ahmet buldum: Ahmet Yılmaz mı, Ahmet Kaya mı?"
  private func askToChoose(_ names: [String], spokenName: String, action: VoiceIntent.ContactAction) -> IntentOutcome {
    bridgeAwaiting = .chooseContact(action: action, names: names)
    bridgeAwaitingSince = Date()
    let turkish = names.map { "\($0) \(TurkishSuffix.question($0))" }.joined(separator: ", ")
    return IntentOutcome(
      spoken: BridgeSpeech.ask(
        "\(names.count) \(spokenName) buldum: \(turkish)?",
        en: "I found \(names.count) contacts for \(spokenName): \(names.joined(separator: " or "))?",
        note: "Nothing has been called or sent."),
      reply: L.t("Which one? ", "Hangisi? ") + names.joined(separator: ", "))
  }

  /// "Ahmet'i ara": the number from Contacts, then the phone's own call
  /// prompt (or a card when the app is not on screen). The app never says
  /// a call was made.
  private func prepareCall(_ name: String, decision: VoiceBridgeDecision, transcript: String, traceID: UUID) async -> IntentOutcome {
    let trace = ActionTraceLog.shared
    guard AssistantPreferences.actionsEnabled else { return actionsOff() }
    guard ToolRegistry.allows(.call) else { return toolOff(.call) }
    if let blocked = await permissionBlock(
      .contacts, fullCalendarAccess: false, decision: decision, transcript: transcript, traceID: traceID) {
      return blocked
    }
    trace.update(traceID) { $0.executor = "Contacts (read) → Phone (iOS asks before calling)" }
    let found: (name: String, phone: String)
    switch await findPhone(for: name, traceID: traceID) {
    case .found(let fullName, let phone): found = (fullName, phone)
    case .choose(let names): return askToChoose(names, spokenName: name, action: .call)
    case .failed(let outcome): return outcome
    }
    recentContact = (found.name, Date())
    var plan = DeviceActionPlan(kind: .call)
    plan.recipient = found.name
    plan.phone = found.phone
    if UIApplication.shared.applicationState == .active, let url = DeviceActionExecutor.callURL(for: found.phone),
       await UIApplication.shared.open(url) {
      trace.update(traceID) { $0.result = "call prompt opened; iOS asks the user" }
      return IntentOutcome(
        spoken: BridgeSpeech.done(
          "The phone's own call prompt for \(found.name) is open; the call starts only when the user taps Call. Nothing has been dialled yet.",
          tr: "Arama ekranını açtım, Ara'ya dokunman yeterli.", en: "The call screen is open; just tap Call."),
        reply: plan.summary,
        feedback: ActionFeedback(kind: .call, title: L.t("Call screen opened", "Arama ekranı açıldı")))
    }
    _ = await stage(plan)
    trace.update(traceID) { $0.result = "waiting for a tap on the phone" }
    return IntentOutcome(
      spoken: "The call to \(found.name) is ready on the phone screen; nothing has been dialled. The user opens the phone and taps Call. Tell them in one short sentence.",
      reply: plan.summary)
  }

  /// "Ahmet'e … diye mesaj yaz": Messages opens with the text; the user
  /// sends it. "Gönderdim" is never said; the sheet reports what happened.
  private func prepareMessage(
    to name: String?,
    body: String?,
    decision: VoiceBridgeDecision,
    transcript: String,
    traceID: UUID
  ) async -> IntentOutcome {
    let trace = ActionTraceLog.shared
    guard AssistantPreferences.actionsEnabled else { return actionsOff() }
    guard ToolRegistry.allows(.message) else { return toolOff(.message) }
    guard let name, !name.isEmpty else { return askQuestion(.messageRecipient(body: body)) }
    guard let body, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return askQuestion(.messageBody(contact: name))
    }
    if let blocked = await permissionBlock(
      .contacts, fullCalendarAccess: false, decision: decision, transcript: transcript, traceID: traceID) {
      return blocked
    }
    trace.update(traceID) { $0.executor = "Contacts (read) → Messages (the user sends)" }
    var plan = DeviceActionPlan(kind: .message)
    plan.text = String(body.prefix(1_000))
    plan.recipient = name
    var note = ""
    switch await findPhone(for: name, traceID: traceID) {
    case .found(let fullName, let phone):
      plan.recipient = fullName
      plan.phone = phone
      recentContact = (fullName, Date())
    case .choose(let names):
      return askToChoose(names, spokenName: name, action: .message(body: body))
    case .failed:
      // Still prepared; the user picks the recipient in Messages.
      note = " \(name) was not found in Contacts, so the user picks the recipient in Messages."
    }
    let recipient = plan.recipient ?? name
    let text = plan.text ?? body
    let opened = SystemSheets.presentMessage(phone: plan.phone, body: text) { [weak self] result in
      self?.messageSheetFinished(result)
    }
    if opened {
      trace.update(traceID) { $0.result = "Messages opened; sending is up to the user" }
      return IntentOutcome(
        spoken: BridgeSpeech.done(
          "A message to \(recipient) is prepared in Messages on the phone: \"\(text)\".\(note) Nothing has been sent; the user sends it with a tap.",
          tr: "Mesajı hazırladım, göndermen için ekranı açtım.", en: "I've prepared the message; it's on screen for you to send."),
        reply: plan.summary)
    }
    _ = await stage(plan)
    trace.update(traceID) { $0.result = "waiting for a tap on the phone" }
    return IntentOutcome(
      spoken: "A message to \(recipient) is prepared on the phone screen: \"\(text)\".\(note) Nothing has been sent: the user opens the phone, taps Write in Messages and sends it. Tell them in one short sentence.",
      reply: plan.summary)
  }

  /// "Ahmet'in numarası ne?": read-only, from the user's Contacts.
  private func lookUpContact(_ name: String, decision: VoiceBridgeDecision, transcript: String, traceID: UUID) async -> IntentOutcome {
    guard AssistantPreferences.actionsEnabled else { return actionsOff() }
    guard ToolRegistry.allows(.findContact) else { return toolOff(.findContact) }
    if let blocked = await permissionBlock(
      .contacts, fullCalendarAccess: false, decision: decision, transcript: transcript, traceID: traceID) {
      return blocked
    }
    ActionTraceLog.shared.update(traceID) { $0.executor = "Contacts (read)" }
    let matches: [ContactsLookup.Match]
    do {
      matches = try await findContacts(name)
    } catch {
      let message = LogSanitizer.sanitize(error.localizedDescription)
      return IntentOutcome(spoken: message + " Tell the user briefly.", reply: message, failed: "contacts unavailable")
    }
    ActionTraceLog.shared.update(traceID) { $0.parsed = "\(matches.count) match(es)" }
    guard !matches.isEmpty else {
      return IntentOutcome(
        spoken: "No contact matching \"\(name)\" is in the user's Contacts on this iPhone. Tell them honestly.",
        reply: L.t("No contact found.", "Rehberde bulunamadı."))
    }
    let spoken = MemorySearch.fold(name)
    let exact = matches.filter { MemorySearch.fold($0.name) == spoken }
    var chosen: ContactsLookup.Match? = matches.count == 1 ? matches.first : nil
    if chosen == nil, exact.count == 1 { chosen = exact.first }
    guard let match = chosen else {
      return askToChoose(matches.prefix(4).map(\.name), spokenName: name, action: .find)
    }
    recentContact = (match.name, Date())
    let numbers = match.phones.prefix(3).map { "\($0.label): \($0.number)" }.joined(separator: ", ")
    return IntentOutcome(
      spoken: "From the user's Contacts on this iPhone: \(match.name) — \(numbers.isEmpty ? "no phone number saved" : numbers). Tell the user naturally and read a number in clear digit groups.",
      reply: match.name + (numbers.isEmpty ? "" : "\n" + numbers))
  }

  // MARK: Maps

  /// "Beni eve götür" uses the address the user asked AutoLoom to remember.
  private func prepareDirections(to destination: String, traceID: UUID) async -> IntentOutcome {
    guard AssistantPreferences.actionsEnabled else { return actionsOff() }
    guard ToolRegistry.allows(.openMaps) else { return toolOff(.openMaps) }
    var place = destination
    if destination == "Home" || destination == "Work" {
      let home = destination == "Home"
      guard let saved = MemoryStore.shared.savedAddress(home: home) else {
        let example = home ? "Hatırla: ev adresim …" : "Hatırla: iş adresim …"
        return IntentOutcome(
          spoken: "The user's \(home ? "home" : "work") address is not saved in AutoLoom memory, so directions could not be opened. Tell them briefly that they can say once \"\(example)\" (in English: \"Remember that my \(home ? "home" : "work") address is …\") and then ask again.",
          reply: home ? L.t("Your home address is not saved yet.", "Ev adresin henüz kayıtlı değil.")
            : L.t("Your work address is not saved yet.", "İş adresin henüz kayıtlı değil."),
          failed: "no saved address")
      }
      place = saved
    }
    ActionTraceLog.shared.update(traceID) {
      $0.executor = "Apple Maps"
      $0.parsed = place == destination ? "destination as said" : "saved \(destination.lowercased()) address"
    }
    return await openMaps(place, search: false, traceID: traceID)
  }

  /// Opens Maps at once when the app is on screen and says so only after
  /// iOS opened it; otherwise a card waits for a tap.
  private func openMaps(_ place: String, search: Bool, traceID: UUID) async -> IntentOutcome {
    let url = search ? DeviceActionExecutor.mapsSearchURL(for: place) : DeviceActionExecutor.mapsURL(for: place)
    if UIApplication.shared.applicationState == .active, let url, await UIApplication.shared.open(url) {
      ActionTraceLog.shared.update(traceID) { $0.result = "Maps opened" }
      return IntentOutcome(
        spoken: BridgeSpeech.done(
          search ? "Apple Maps is open on the phone with places matching \"\(place)\" near the user."
            : "Apple Maps is open on the phone with directions to \(place).",
          tr: search ? "Haritalar'da en yakın yerleri açtım." : "Yol tarifini Haritalar'da açtım.",
          en: search ? "I've opened the nearest places in Maps." : "I've opened directions in Maps."),
        reply: L.t("Opened in Maps: ", "Haritalar'da açıldı: ") + place,
        feedback: ActionFeedback(
          kind: .directions,
          title: search ? L.t("Maps search opened", "Haritalar'da arama açıldı") : L.t("Directions opened", "Yol tarifi açıldı")))
    }
    var plan = DeviceActionPlan(kind: .openMaps)
    plan.location = place
    _ = await stage(plan)
    ActionTraceLog.shared.update(traceID) { $0.result = "waiting for a tap on the phone" }
    return IntentOutcome(
      spoken: "Directions to \(place) are ready on the phone screen; nothing has opened yet. The user taps Open in Maps when they look at the phone. Tell them in one short sentence.",
      reply: plan.summary)
  }

  // MARK: Clipboard and share

  /// "Kopyaladım" only after the clipboard really changed.
  private func copyToClipboard(_ text: String?, traceID: UUID) -> IntentOutcome {
    guard ToolRegistry.allows(.copyText) else { return toolOff(.copyText) }
    guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return IntentOutcome(
        spoken: "There is nothing to copy yet (no earlier answer). Ask the user briefly what to copy.",
        reply: L.t("Nothing to copy.", "Kopyalanacak bir şey yok."), failed: "nothing to copy")
    }
    ActionTraceLog.shared.update(traceID) { $0.executor = "UIPasteboard" }
    let pasteboard = UIPasteboard.general
    let before = pasteboard.changeCount
    pasteboard.string = text
    guard pasteboard.changeCount != before else {
      return IntentOutcome(
        spoken: "The clipboard could not be changed. Tell the user honestly.",
        reply: L.t("Not copied.", "Kopyalanamadı."), failed: "clipboard unchanged",
        feedback: .failed(L.t("Not copied", "Kopyalanamadı")))
    }
    return IntentOutcome(
      spoken: BridgeSpeech.done("The text was copied to the iPhone clipboard.", tr: "Kopyaladım.", en: "Copied."),
      reply: L.t("Copied.", "Kopyalandı."),
      feedback: ActionFeedback(kind: .copy, title: L.t("Copied", "Kopyalandı")))
  }

  /// The share sheet with the text; "shared" only when the user finishes.
  private func prepareShare(_ text: String?, traceID: UUID) async -> IntentOutcome {
    guard AssistantPreferences.actionsEnabled else { return actionsOff() }
    guard ToolRegistry.allows(.shareText) else { return toolOff(.shareText) }
    guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return IntentOutcome(
        spoken: "There is nothing to share yet (no earlier answer). Ask the user briefly what to share.",
        reply: L.t("Nothing to share.", "Paylaşılacak bir şey yok."), failed: "nothing to share")
    }
    ActionTraceLog.shared.update(traceID) { $0.executor = "share sheet (the user picks where)" }
    if SystemSheets.presentShare(text: text, finished: { [weak self] completed in self?.shareSheetFinished(completed) }) {
      ActionTraceLog.shared.update(traceID) { $0.result = "share sheet opened" }
      return IntentOutcome(
        spoken: BridgeSpeech.done(
          "The share sheet is open on the phone with the text; nothing has been shared yet, the user picks where.",
          tr: "Paylaşım ekranını açtım.", en: "The share sheet is open."),
        reply: L.t("Share sheet opened.", "Paylaşım ekranı açıldı."))
    }
    var plan = DeviceActionPlan(kind: .shareText)
    plan.text = text
    _ = await stage(plan)
    ActionTraceLog.shared.update(traceID) { $0.result = "waiting for a tap on the phone" }
    return IntentOutcome(
      spoken: "The text is ready to share on the phone screen; nothing has been shared. The user taps Share when they look at the phone. Tell them in one short sentence.",
      reply: plan.summary)
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
