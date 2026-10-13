import Foundation
import XCTest

@testable import GlassifAI

/// Plan 2.2: Apple reminders completed or deleted by voice, the answer to
/// "hangisi?", and the list a new reminder goes to. EventKit cannot be used
/// in the unsigned simulator test host, so these cover the parser, the
/// matching, list phrases, plans and the tool switch; reading Reminders back
/// on the iPhone is device test RM1–RM4.
@MainActor
final class AutoLoomReminderVoiceTests: XCTestCase {
  private func decide(_ text: String, _ context: VoiceBridgeContext = VoiceBridgeContext()) -> VoiceIntent? {
    var context = context
    context.assistantName = "Jarvis"
    return VoiceActionIntentBridge.decide(text, context: context)?.intent
  }

  private func option(_ id: String, _ title: String, _ list: String = "Anımsatıcılar") -> ReminderOption {
    ReminderOption(id: id, title: title, list: list, due: nil, hasTime: false)
  }

  // MARK: The spoken command

  func testCompletingOrDeletingAReminderIsRecognised() {
    XCTAssertEqual(decide("Süt alma hatırlatıcısını tamamla"), .completeReminder(.words("Süt alma")))
    XCTAssertEqual(
      decide("Jarvis, Ahmet'i arama anımsatıcısını tamamlandı olarak işaretle"), .completeReminder(.words("Ahmet'i arama")))
    XCTAssertEqual(decide("süt hatırlatıcısını tamamladım"), .completeReminder(.words("süt")))
    XCTAssertEqual(decide("Bu hatırlatıcıyı tamamla"), .completeReminder(.words("")), "the one just saved")
    XCTAssertEqual(decide("Mark the milk reminder as done"), .completeReminder(.words("milk")))
    XCTAssertEqual(decide("complete the reminder to call mom"), .completeReminder(.words("call mom")))
    XCTAssertEqual(decide("Süt alma hatırlatıcısını sil"), .deleteReminder(.words("Süt alma")))
    XCTAssertEqual(decide("diş hekimi anımsatıcısını lütfen kaldır"), .deleteReminder(.words("diş hekimi")))
    XCTAssertEqual(decide("Bu hatırlatıcıyı silebilir misin"), .deleteReminder(.words("")))
    XCTAssertEqual(decide("Delete the dentist reminder"), .deleteReminder(.words("dentist")))
    XCTAssertEqual(decide("remove the reminder about the dentist"), .deleteReminder(.words("dentist")))
  }

  func testOtherSentencesAreNotReminderEdits() {
    XCTAssertEqual(decide("süt almayı hatırlat"), .ask(.reminderTime(title: "Süt al")), "creating stays creating")
    XCTAssertEqual(decide("bir hatırlatıcı oluştur"), .ask(.reminderTitle))
    XCTAssertNil(decide("Bunu bana hatırlatma"), "a negative is not a request")
    XCTAssertEqual(decide("Lastik görevini tamamla"), .completeTask("Lastik"), "AutoLoom tasks keep their command")
    XCTAssertEqual(decide("bunu tamamla"), .completeTask(""))
    for bulk in ["Tüm hatırlatıcılarımı sil", "Bütün anımsatıcıları tamamla", "Delete all my reminders", "hatırlatıcıların hepsini sil"] {
      switch decide(bulk) {
      case .completeReminder?, .deleteReminder?: XCTFail("never several at once: \(bulk)")
      default: break
      }
    }
  }

  func testADeletionIsNeverOneStepOfSeveral() {
    XCTAssertFalse(VoiceIntent.deleteReminder(.words("süt")).isGraphStep, "it waits for its own yes")
    XCTAssertTrue(VoiceIntent.completeReminder(.words("süt")).isGraphStep)
  }

  // MARK: "Hangisi?"

  func testTheAnswerToWhichOneChoosesByOrderListOrWords() {
    let options = [option("a", "Süt al", "Market"), option("b", "Süt al", "İş"), option("c", "Süt makinesini temizle", "Ev")]
    var context = VoiceBridgeContext()
    context.awaiting = .chooseReminder(delete: false, options: options)
    XCTAssertEqual(decide("ikincisi", context), .completeReminder(.id("b")))
    XCTAssertEqual(decide("Market'teki", context), .completeReminder(.id("a")))
    XCTAssertEqual(decide("iş listesindeki", context), .completeReminder(.id("b")))
    XCTAssertEqual(decide("makine olanı", context), .completeReminder(.id("c")))
    XCTAssertNil(decide("süt", context), "two are called that: nothing is guessed")
    context.awaiting = .chooseReminder(delete: true, options: options)
    XCTAssertEqual(decide("ilki", context), .deleteReminder(.id("a")))
    XCTAssertEqual(
      ReminderOption.labels(Array(options.prefix(2))), ["Süt al (Market)", "Süt al (İş)"], "the list tells same titles apart")
  }

  // MARK: Finding the reminder

  func testRemindersAreFoundByTheirWordsNotGuessed() {
    let options = [option("milk", "Süt al", "Market"), option("machine", "Süt makinesini temizle"), option("call", "Ahmet'i ara", "İş")]
    XCTAssertEqual(ReminderMatcher.match("süt alma", in: options), .one(options[0]), "the verb noun finds the imperative")
    XCTAssertEqual(ReminderMatcher.match("Ahmet'i arama", in: options), .one(options[2]))
    XCTAssertEqual(ReminderMatcher.match("makineyi temizleme", in: options), .one(options[1]))
    XCTAssertEqual(ReminderMatcher.match("süt", in: options), .several([options[0], options[1]]))
    XCTAssertEqual(ReminderMatcher.match("diş hekimi", in: options), .noMatch)
    XCTAssertEqual(ReminderMatcher.match("", in: options), .noMatch)
    XCTAssertEqual(ReminderMatcher.stem("almayi"), "al")
    XCTAssertEqual(ReminderMatcher.stem("aramami"), "ara")
    XCTAssertEqual(ReminderMatcher.stem("gondermek"), "gonder")
  }

  func testTheTargetComesFromWordsTheReminderJustSavedOrAChoice() {
    let options = [option("milk", "Süt al", "Market"), option("bread", "Ekmek al", "Market"), option("call", "Ahmet'i ara", "İş")]
    let resolve = AssistantOrchestrator.resolveReminder
    XCTAssertEqual(resolve(.words("süt alma"), options, nil), .one(options[0]))
    XCTAssertEqual(resolve(.words(""), options, "call"), .one(options[2]), "the one just saved")
    XCTAssertEqual(resolve(.words(""), options, nil), .several(options), "nothing saved just now: the user chooses")
    XCTAssertEqual(resolve(.words("Market listesindeki"), options, nil), .several([options[0], options[1]]))
    XCTAssertEqual(resolve(.words("İş listesindeki"), options, nil), .one(options[2]))
    XCTAssertEqual(resolve(.words("Market listesindeki ekmek"), options, nil), .one(options[1]))
    XCTAssertEqual(resolve(.id("bread"), options, nil), .one(options[1]))
    XCTAssertEqual(resolve(.id("gone"), options, nil), .noMatch, "a reminder deleted meanwhile is not guessed")
    XCTAssertEqual(resolve(.words("süt"), [], nil), .noMatch)
  }

  // MARK: The list for a new reminder

  func testAListIsTakenOnlyFromItsRealName() {
    let lists = ["İş", "Market", "Alışveriş Listesi", "Work"]
    func found(_ name: String, _ rest: String) -> ReminderListMention.Found {
      ReminderListMention.Found(name: name, remainder: rest)
    }
    XCTAssertEqual(ReminderListMention.find(in: "İş listeme raporu gönder", listNames: lists), found("İş", "Raporu gönder"))
    XCTAssertEqual(ReminderListMention.find(in: "market listesine süt al", listNames: lists), found("Market", "Süt al"))
    XCTAssertEqual(
      ReminderListMention.find(in: "alışveriş listesine ekmek al", listNames: lists), found("Alışveriş Listesi", "Ekmek al"))
    XCTAssertEqual(
      ReminderListMention.find(in: "Send the report in my Work list", listNames: lists), found("Work", "Send the report"))
    XCTAssertNil(ReminderListMention.find(in: "iş yerinde raporu gönder", listNames: lists), "no list word")
    XCTAssertNil(ReminderListMention.find(in: "Ev listesine süt al", listNames: lists), "not a list the user has")
    XCTAssertNil(ReminderListMention.find(in: "İş listeme", listNames: lists), "nothing left to be reminded of")
    XCTAssertEqual(
      ReminderListMention.find(in: "Market listesindeki", listNames: lists, allowingNothingElse: true), found("Market", ""))
  }

  // MARK: Plans, confirmation and the tool switch

  func testReminderEditsAreAppOnlyAndDeletingNeedsAYes() {
    XCTAssertFalse(DeviceActionKind.plannable.contains(.completeReminder), "the planner never completes a reminder")
    XCTAssertFalse(DeviceActionKind.plannable.contains(.deleteReminder), "the planner never deletes one")
    XCTAssertEqual(DeviceActionKind.completeReminder.risk, .safe)
    XCTAssertEqual(DeviceActionKind.deleteReminder.risk, .confirm)
    var delete = DeviceActionPlan(kind: .deleteReminder)
    delete.title = "Süt al"
    delete.reminderListName = "Market"
    XCTAssertEqual(DeviceActionParser.validate(delete, now: Date()), .failure(.missing("which reminder")))
    delete.reminderID = "x"
    XCTAssertTrue(delete.summary.contains("Süt al") && delete.summary.contains("Market"), delete.summary)
    XCTAssertTrue(delete.summary.contains(L.t("cannot be undone", "geri alınamaz")), delete.summary)
    var complete = DeviceActionPlan(kind: .completeReminder)
    complete.reminderID = "x"
    complete.afterUntrustedContent = true
    XCTAssertEqual(complete.risk, .confirm, "after outside content even a completion waits for a yes")
    XCTAssertEqual(ToolRegistry.tool(for: .deleteReminder)?.id, "reminders", "the Reminders switch covers them")
    XCTAssertEqual(ActionFeedback.saved(complete)?.kind, .taskDone)
    XCTAssertEqual(ActionFeedback.notSaved(delete)?.success, false)
  }

  func testTheRemindersSwitchStopsSpokenEditsBeforeEventKit() async throws {
    let defaults = UserDefaults.standard
    let tool = try XCTUnwrap(ToolRegistry.tool(for: .completeReminder))
    let toolKey = ToolRegistry.enabledKey(tool)
    let previousTool = defaults.object(forKey: toolKey)
    let previousActions = defaults.object(forKey: AssistantPreferences.actionsKey)
    defaults.set(false, forKey: toolKey)
    defaults.set(true, forKey: AssistantPreferences.actionsKey)
    defer {
      defaults.set(previousTool, forKey: toolKey)
      defaults.set(previousActions, forKey: AssistantPreferences.actionsKey)
    }
    let orchestrator = AssistantOrchestrator.shared
    orchestrator.cancelPendingAction()
    for intent: VoiceIntent in [.completeReminder(.words("süt")), .deleteReminder(.words("süt"))] {
      let outcome = await orchestrator.runVoiceIntent(VoiceBridgeDecision(intent, "test"), transcript: "süt hatırlatıcısı")
      XCTAssertEqual(outcome.failed, "tool off")
      XCTAssertTrue(outcome.reply.contains(tool.name), outcome.reply)
    }
    XCTAssertNil(orchestrator.pendingAction, "nothing was staged")
  }

  // MARK: Several commands in one sentence

  func testAStepWaitingForAYesIsNotReportedAsDone() async throws {
    let orchestrator = AssistantOrchestrator.shared
    orchestrator.cancelPendingAction()
    let store = MemoryStore.shared
    let marker = "graf\(UUID().uuidString.prefix(6).lowercased())"
    let note = try XCTUnwrap(store.addNote(title: nil, content: "Silinecek \(marker)", source: "test"))
    let steps = [
      ActionGraph.Step(text: "\(marker) notunu sil", intent: .deleteNote(marker)),
      ActionGraph.Step(text: "notlarım neler", intent: .listNotes),
    ]
    let outcome = await orchestrator.runVoiceIntent(
      VoiceBridgeDecision(.graph(steps), "test"), transcript: "\(marker) notunu sil ve notlarım neler")
    XCTAssertEqual(orchestrator.pendingAction?.plan.kind, .deleteNote)
    XCTAssertTrue(outcome.reply.contains("Step 1") && outcome.reply.contains("NOT done yet"), outcome.reply)
    XCTAssertTrue(outcome.reply.contains("Step 2") && outcome.reply.contains(": done —"), outcome.reply)
    XCTAssertNil(outcome.failed)
    XCTAssertTrue(store.notes.contains { $0.id == note.id }, "nothing deleted without the yes")
    orchestrator.cancelPendingAction()
    store.deleteNote(note)
  }
}
