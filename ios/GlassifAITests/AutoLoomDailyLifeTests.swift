import Foundation
import XCTest

@testable import GlassifAI

/// Daily life (Request F §102–§103): timers and the shopping list, by voice,
/// on the phone.
@MainActor
final class AutoLoomDailyLifeTests: XCTestCase {
  private func decide(_ text: String, timerRunning: Bool = false) -> VoiceIntent? {
    var context = VoiceBridgeContext()
    context.assistantName = "AutoLoom"
    context.timerRunning = timerRunning
    return VoiceActionIntentBridge.decide(text, context: context)?.intent
  }

  func testDurationsInTurkishAndEnglish() {
    XCTAssertEqual(DurationParser.seconds(in: "10 dakika"), 600)
    XCTAssertEqual(DurationParser.seconds(in: "5 dk"), 300)
    XCTAssertEqual(DurationParser.seconds(in: "1 saat 20 dakika"), 4_800)
    XCTAssertEqual(DurationParser.seconds(in: "yarım saat"), 1_800)
    XCTAssertEqual(DurationParser.seconds(in: "çeyrek saat"), 900)
    XCTAssertEqual(DurationParser.seconds(in: "bir buçuk saat"), 5_400)
    XCTAssertEqual(DurationParser.seconds(in: "on dakika"), 600)
    XCTAssertEqual(DurationParser.seconds(in: "half an hour"), 1_800)
    XCTAssertEqual(DurationParser.seconds(in: "an hour"), 3_600)
    XCTAssertEqual(DurationParser.seconds(in: "set a timer for 10 minutes"), 600)
    XCTAssertEqual(DurationParser.seconds(in: "90 seconds"), 90)
    XCTAssertNil(DurationParser.seconds(in: "yarın"))
  }

  func testTimerCommands() {
    XCTAssertEqual(decide("10 dakika timer kur"), .timer(.start(seconds: 600, label: nil)))
    XCTAssertEqual(decide("yumurta için 7 dakika timer"), .timer(.start(seconds: 420, label: "Yumurta")))
    XCTAssertEqual(decide("zamanlayıcı kur 5 dakika"), .timer(.start(seconds: 300, label: nil)))
    XCTAssertEqual(decide("set a timer for 10 minutes"), .timer(.start(seconds: 600, label: nil)))
    XCTAssertEqual(decide("Timerı durdur"), .timer(.cancel))
    XCTAssertEqual(decide("zamanlayıcıyı iptal et"), .timer(.cancel))
    XCTAssertEqual(decide("timer ne kadar kaldı"), .timer(.remaining))
    XCTAssertEqual(decide("Ne kadar kaldı?", timerRunning: true), .timer(.remaining))
    XCTAssertNotEqual(decide("Ne kadar kaldı?"), .timer(.remaining), "only about a timer while one runs")
    XCTAssertNotEqual(decide("Eve ne kadar kaldı?", timerRunning: true), .timer(.remaining))
    XCTAssertNil(decide("timer nasıl kurulur?"))
    if case .timer? = decide("10 dakika sonra haber ver") { XCTFail("a notification, not a timer") }
  }

  func testShoppingCommands() {
    XCTAssertEqual(decide("alışveriş listesine süt ve ekmek ekle"), .shopping(.add(["süt", "ekmek"])))
    XCTAssertEqual(decide("sütü alışveriş listesine ekle"), .shopping(.add(["süt"])))
    XCTAssertEqual(decide("yumurtayı ve ekmeği alışveriş listeme ekle"), .shopping(.add(["yumurta", "ekmek"])))
    XCTAssertEqual(decide("add milk and tomato to my shopping list"), .shopping(.add(["milk", "tomato"])))
    XCTAssertEqual(decide("alışveriş listemde ne var"), .shopping(.read))
    XCTAssertEqual(decide("what's on my shopping list"), .shopping(.read))
    XCTAssertEqual(decide("sütü alışveriş listesinden çıkar"), .shopping(.remove("süt")))
    XCTAssertEqual(decide("remove milk from the shopping list"), .shopping(.remove("milk")))
    XCTAssertEqual(ShoppingListStore.baseForm("peyniri"), "peynir")
    XCTAssertEqual(ShoppingListStore.baseForm("elmayı"), "elma")
  }

  func testTheShoppingListStoresAndDedupes() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("shopping-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = ShoppingListStore(directory: directory)
    XCTAssertEqual(store.add(["süt", "ekmek"]).map(\.text), ["Süt", "Ekmek"])
    XCTAssertTrue(store.add(["Süt"]).isEmpty, "already on the list")
    XCTAssertEqual(store.remove(matching: "süt")?.text, "Süt")
    XCTAssertEqual(ShoppingListStore(directory: directory).items.map(\.text), ["Ekmek"], "kept on the phone")
    XCTAssertEqual(ShoppingListStore.split("süt, ekmek ve yumurta"), ["süt", "ekmek", "yumurta"])
  }

  func testTimersRunCancelAndReport() async throws {
    let center = TimerCenter.shared
    let saved = center.scheduleNotification
    center.scheduleNotification = { _ in false }
    defer {
      center.scheduleNotification = saved
      center.cancelAll()
    }
    let orchestrator = AssistantOrchestrator.shared
    let started = await orchestrator.runVoiceIntent(
      VoiceBridgeDecision(.timer(.start(seconds: 420, label: "Yumurta")), "test"), transcript: "yumurta için 7 dakika timer")
    XCTAssertEqual(center.timers.count, 1)
    XCTAssertTrue((started.said ?? "").contains(L.t("Notifications are off", "Bildirim izni kapalı")), "honest when it cannot ring")
    let remaining = await orchestrator.runVoiceIntent(VoiceBridgeDecision(.timer(.remaining), "test"), transcript: "ne kadar kaldı")
    XCTAssertTrue((remaining.said ?? "").contains(L.t("minutes", "dakika")))
    _ = await orchestrator.runVoiceIntent(VoiceBridgeDecision(.timer(.cancel), "test"), transcript: "timerı durdur")
    XCTAssertTrue(center.timers.isEmpty)
    let none = await orchestrator.runVoiceIntent(VoiceBridgeDecision(.timer(.remaining), "test"), transcript: "ne kadar kaldı")
    XCTAssertEqual(none.said, L.t("There's no timer running.", "Çalışan bir zamanlayıcı yok."))
    XCTAssertEqual(TimerCenter.spoken(450, turkish: true), "7 dakika 30 saniye")
    XCTAssertEqual(TimerCenter.finishedText("Yumurta", turkish: true), "Süre doldu: Yumurta.")
  }

  func testUndoTakesBackTheLastLocalActionOnly() async throws {
    LocalUndo.shared.clear()
    XCTAssertEqual(decide("Son yaptığını geri al"), .undoLast)
    XCTAssertEqual(decide("undo that"), .undoLast)
    XCTAssertNotEqual(decide("parayı geri al"), .undoLast)
    let orchestrator = AssistantOrchestrator.shared
    let marker = "undo\(UUID().uuidString.prefix(6))"
    _ = await orchestrator.runVoiceIntent(VoiceBridgeDecision(.saveNote(text: "Geri \(marker)"), "test"), transcript: "not al")
    XCTAssertTrue(MemoryStore.shared.notes.contains { $0.content.contains(marker) })
    let undone = await orchestrator.runVoiceIntent(VoiceBridgeDecision(.undoLast, "test"), transcript: "son yaptığını geri al")
    XCTAssertEqual(undone.said, L.t("Undone: note removed.", "Geri aldım: not silindi."))
    XCTAssertFalse(MemoryStore.shared.notes.contains { $0.content.contains(marker) })
    let nothing = await orchestrator.runVoiceIntent(VoiceBridgeDecision(.undoLast, "test"), transcript: "geri al")
    XCTAssertEqual(nothing.said, L.t("There's nothing to undo.", "Geri alınacak bir şey yok."))
  }

  func testReviewsCountWhatIsOnThePhone() async {
    XCTAssertEqual(decide("Bugün ne yaptım?"), .routine(.eveningReview))
    XCTAssertEqual(decide("what did I do today"), .routine(.eveningReview))
    XCTAssertEqual(decide("haftalık özet"), .routine(.weeklyReview))
    let outcome = await AssistantOrchestrator.shared.runVoiceIntent(
      VoiceBridgeDecision(.routine(.eveningReview), "test"), transcript: "bugün ne yaptım")
    XCTAssertTrue(outcome.reply.contains("Notes saved:"))
    XCTAssertTrue(outcome.spoken.contains("mention only these facts"))
  }

  func testModesAddOneLineAndDealerIsAutomatic() {
    XCTAssertNil(AssistantMode.general.instructionLine)
    XCTAssertTrue(AssistantMode.dealer.instructionLine?.contains("Never say a car is safe to drive") ?? false)
    let dealer = AssistantInstructions.realtime(memory: [], jarvisStyle: false, mode: .dealer)
    XCTAssertTrue(dealer.contains("Mode: Dealer"))
    XCTAssertFalse(AssistantInstructions.realtime(memory: [], jarvisStyle: false).contains("Mode:"))
    let key = AssistantMode.defaultsKey
    let saved = UserDefaults.standard.object(forKey: key)
    defer { UserDefaults.standard.set(saved, forKey: key) }
    UserDefaults.standard.removeObject(forKey: key)
    let store = DealerStore.shared
    let vehicle = store.start()
    defer { store.delete(vehicle.id) }
    XCTAssertEqual(AssistantMode.effective, .dealer, "a vehicle session makes the mode Dealer")
    store.activate(nil)
    XCTAssertEqual(AssistantMode.effective, .general)
  }
}
