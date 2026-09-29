import Foundation
import XCTest

@testable import GlassifAI

/// Spoken notes (critical add-on): explicit note verbs are found anywhere in
/// the sentence and win over time words and over the other actions; the
/// content is the user's words without the command; "bunu" is the last
/// real answer; a follow-up task links to the note.
@MainActor
final class AutoLoomNoteReliabilityTests: XCTestCase {
  private let calendar = Calendar.current

  private func local(_ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
    calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
  }

  private var now: Date { local(9, 27, 20) }

  private func decide(
    _ text: String,
    _ context: VoiceBridgeContext = VoiceBridgeContext(),
    name: String = "AutoLoom"
  ) -> VoiceIntent? {
    var context = context
    context.assistantName = name
    return VoiceActionIntentBridge.decide(text, context: context, now: now)?.intent
  }

  // MARK: §19 Turkish set

  func testTurkishNoteSetMapsToSaveNote() {
    let cases: [(String, String)] = [
      ("not al yarın kamera getireceğim", "Yarın kamera getireceğim"),
      ("not al: yarın kamera getireceğim", "Yarın kamera getireceğim"),
      ("notlara yaz Mercedes cuma geliyor", "Mercedes cuma geliyor"),
      ("bir not düş sağ ön jant çizik", "Sağ ön jant çizik"),
      ("AutoLoom not al sağ ön jant çizik", "Sağ ön jant çizik"),
      ("Hey AutoLoom, not al: Ahmet cuma gelecek", "Ahmet cuma gelecek"),
      ("Yarın kamera getireceğim, not al", "Yarın kamera getireceğim"),
      ("Yarın Ahmet gelecek, bunu not et", "Yarın Ahmet gelecek"),
      ("Şunu not et, Mercedes cuma geliyor.", "Mercedes cuma geliyor"),
      ("AutoLoom bunu notlara ekle: sağ ön jant çizik.", "Sağ ön jant çizik"),
      ("Not al: yarın kamerayı getir.", "Yarın kamerayı getir"),
      ("AutoLoom, not al: yarın kamerayı getireceğim.", "Yarın kamerayı getireceğim"),
      // A word before the verb that is not the name never hides the command.
      ("AutoLoom benim için not al: yarın kamerayı getireceğim", "Yarın kamerayı getireceğim"),
      ("Oto lum hemen not al yarın kamerayı getireceğim", "Yarın kamerayı getireceğim"),
      ("Otomatik not al yarın kamerayı getireceğim", "Yarın kamerayı getireceğim"),
      ("Sağ ön jant çizik, kaydet", "Sağ ön jant çizik"),
      ("kaydet: Mercedes cuma geliyor", "Mercedes cuma geliyor"),
    ]
    for (text, content) in cases {
      XCTAssertEqual(decide(text), .saveNote(text: content), text)
    }
  }

  func testDeicticNoteVariantsUseTheLastAnswer() {
    var context = VoiceBridgeContext()
    context.lastAssistantText = "Bu aracın lastik ölçüsü 225/45 R18."
    for text in [
      "bunu not et", "şunu notlara ekle", "bunu not olarak kaydet", "Jarvis bunu not et", "Bunu bir yere yaz.",
      "Not olarak kaydet.", "bunu not al", "note this", "save this as a note", "add this to my notes", "write this down",
    ] {
      XCTAssertEqual(decide(text, context, name: "Jarvis"), .saveNote(text: "Bu aracın lastik ölçüsü 225/45 R18."), text)
    }
    XCTAssertEqual(decide("bunu not et"), .ask(.note), "nothing to point at: ask; never save \"bunu\"")
  }

  // MARK: §20 English

  func testEnglishNotes() {
    XCTAssertEqual(decide("take a note: bring the camera"), .saveNote(text: "Bring the camera"))
    XCTAssertEqual(
      decide("make a note that the Mercedes arrives Friday"), .saveNote(text: "The Mercedes arrives Friday"))
    XCTAssertEqual(decide("write down: tire pressure 32"), .saveNote(text: "Tire pressure 32"))
  }

  // MARK: §4, §17, §18 The explicit verb wins

  func testTheUsersVerbDecides() {
    XCTAssertEqual(decide("Yarın Ahmet gelecek, not al."), .saveNote(text: "Yarın Ahmet gelecek"))
    guard case .createTask? = decide("Yarın Ahmet gelecek, görev oluştur.") else { return XCTFail("task") }
    guard case .createReminder? = decide("Yarın 10'da Ahmet gelecek, hatırlat.") else { return XCTFail("reminder") }
    XCTAssertEqual(decide("Ahmet yarın gelecek, bunu hatırla."), .saveMemory(text: "Ahmet yarın gelecek", kind: nil))
    guard case .createTask(let title, _)? = decide("Yarın kamerayı getir, görev oluştur.") else {
      return XCTFail("TEST NOTE 4: a task, not a note")
    }
    XCTAssertEqual(title, "Kamerayı getir")
    XCTAssertEqual(decide("Yarın kamera getireceğim, not al."), .saveNote(text: "Yarın kamera getireceğim"), "TEST NOTE 5")
    guard case .saveMemory? = decide("bunu hafızaya kaydet", {
      var context = VoiceBridgeContext()
      context.previousUserText = "Kapı kodu 4512"
      return context
    }()) else { return XCTFail("hafızaya kaydet is memory") }
    guard case .createTask? = decide("bunu görev olarak kaydet", {
      var context = VoiceBridgeContext()
      context.previousUserText = "Lastikleri değiştir"
      return context
    }()) else { return XCTFail("görev olarak kaydet is a task") }
  }

  // MARK: §21 Negative tests

  func testNotANote() {
    XCTAssertEqual(decide("notlarım neler?"), .listNotes)
    XCTAssertEqual(decide("bu notu sil"), .deleteNote(nil))
    XCTAssertNil(decide("not almak ne demek?"))
    XCTAssertEqual(decide("görev oluştur"), .ask(.task))
    guard case .createReminder? = decide("yarın 9'da hatırlat", {
      var context = VoiceBridgeContext()
      context.previousUserText = "Lastikleri değiştir"
      return context
    }()) else { return XCTFail("a reminder") }
    guard case .ask(.memory)? = decide("bunu hatırla") else { return XCTFail("memory, asking what") }
    XCTAssertEqual(decide("Mercedes için aldığım notları söyle"), .searchNotes("Mercedes"))
    XCTAssertEqual(decide("notes about the Mercedes"), .searchNotes("Mercedes"))
    XCTAssertNil(decide("Not almak için hangi uygulama iyi?"))
  }

  // MARK: §24 Tasks still work

  func testTasksStillWork() {
    var context = VoiceBridgeContext()
    context.previousUserText = "Lastikleri değiştirmem lazım"
    guard case .createTask? = decide("bunu görev olarak ekle", context) else { return XCTFail("görev olarak ekle") }
    guard case .createTask(_, let time)? = decide("yarına görev oluştur", context) else { return XCTFail("yarına görev") }
    XCTAssertEqual(time?.date, local(9, 28, 0))
    guard case .createTask? = decide("todo'ya ekle", context) else { return XCTFail("todo'ya ekle") }
    guard case .createTask? = decide("bunu yapmam lazım", context) else { return XCTFail("bunu yapmam lazım") }
    XCTAssertEqual(decide("bugün ne yapmam lazım"), .dayPlan(.today), "a question stays the day plan")
  }

  // MARK: §16 Note → task follow-up

  func testANoteThenATaskForIt() {
    var context = VoiceBridgeContext()
    context.recentSavedText = "Sağ ön jant çizik"
    context.lastAssistantText = "Not aldım."
    guard case .createTask(let title, let time)? = decide("Bunun için yarına görev oluştur.", context) else {
      return XCTFail("expected a task from the note")
    }
    XCTAssertEqual(title, "Sağ ön jant çizik")
    XCTAssertEqual(time?.date, local(9, 28, 0))
  }

  // MARK: Execution, trace, UI refresh

  func testTheNoteIsSavedTracedAndVisibleAtOnce() async throws {
    let orchestrator = AssistantOrchestrator.shared
    let store = MemoryStore.shared
    let marker = "kamera\(UUID().uuidString.prefix(6))"
    let decision = try XCTUnwrap(VoiceActionIntentBridge.decide(
      "not al yarın \(marker) getireceğim", context: VoiceBridgeContext(), now: now))
    let started = Date()
    let outcome = await orchestrator.runVoiceIntent(decision, transcript: "not al yarın \(marker) getireceğim")
    XCTAssertLessThan(Date().timeIntervalSince(started), 1.0, "local: no model, no web")
    XCTAssertNil(outcome.failed)
    XCTAssertEqual(outcome.said, L.t("Done, I've noted it.", "Tamam, not aldım."))
    let note = try XCTUnwrap(store.notes.first { $0.content.contains(marker) }, "the Notes list sees it at once")
    XCTAssertEqual(note.source, "voice")
    XCTAssertEqual(orchestrator.actionFeedback?.preview?.contains(marker), true, "the card previews the note")
    let entry = try XCTUnwrap(ActionTraceLog.shared.entries.last)
    XCTAssertEqual(entry.canonical, "SAVE_NOTE")
    XCTAssertTrue(entry.executor.contains("MemoryStore.addNote"))
    XCTAssertTrue(entry.persistence.contains("Notes list shows it"), entry.persistence)
    XCTAssertEqual(entry.spoken, L.t("Done, I've noted it.", "Tamam, not aldım."))

    // "Bunun için yarına görev oluştur": the task links to the note.
    let follow = VoiceBridgeDecision(.createTask(title: note.content, time: nil), "test")
    _ = await orchestrator.runVoiceIntent(follow, transcript: "bunun için görev oluştur")
    let task = try XCTUnwrap(store.tasks.first { $0.title == note.content })
    XCTAssertEqual(task.linkedNoteID, note.id)
    store.deleteTask(task)
    store.deleteNote(note)
  }

  func testDeletingANoteWaitsForAYes() async throws {
    let orchestrator = AssistantOrchestrator.shared
    orchestrator.cancelPendingAction()
    let store = MemoryStore.shared
    let marker = "sil\(UUID().uuidString.prefix(6))"
    let note = try XCTUnwrap(store.addNote(title: nil, content: "Silinecek \(marker)", source: "test"))
    _ = await orchestrator.runVoiceIntent(VoiceBridgeDecision(.deleteNote(marker), "test"), transcript: "notu sil")
    XCTAssertEqual(orchestrator.pendingAction?.plan.kind, .deleteNote)
    XCTAssertTrue(store.notes.contains { $0.id == note.id }, "nothing deleted before the yes")
    _ = await orchestrator.confirmPendingAction(byVoice: true)
    XCTAssertFalse(store.notes.contains { $0.content.contains(marker) })
  }
}
