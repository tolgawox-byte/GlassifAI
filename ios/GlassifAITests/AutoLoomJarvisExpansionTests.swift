import Foundation
import XCTest

@testable import GlassifAI

/// Jarvis expansion: resources, capabilities, corrections, several commands
/// in one sentence, vehicle questions, moving tasks, global search, the
/// session snapshot.
@MainActor
final class AutoLoomJarvisExpansionTests: XCTestCase {
  private func decide(_ text: String, _ tags: Set<String> = []) -> VoiceIntent? {
    VoiceActionIntentBridge.decide(text, context: AutoLoomActionCatalogTests.context(for: tags))?.intent
  }

  // MARK: Media resources (§32)

  func testMediaResourcesNeverFight() {
    typealias Coordinator = MediaResourceCoordinator
    XCTAssertFalse(Coordinator.decide(.liveVision, active: []).allowed, "Live Vision needs the camera")
    XCTAssertTrue(Coordinator.decide(.liveVision, active: [.cameraStream]).allowed)
    XCTAssertTrue(
      Coordinator.decide(.videoRecording, active: [.cameraStream, .liveVision, .remoteAssist]).allowed,
      "frames are fanned out to recording, vision and sharing")
    let audio = Coordinator.decide(.remoteAssistAudio, active: [.cameraStream, .remoteAssist, .realtimeVoice])
    XCTAssertFalse(audio.allowed, "two-way sharing audio and the conversation both need the microphone")
    XCTAssertNotNil(audio.tr)
    XCTAssertFalse(Coordinator.decide(.realtimeVoice, active: [.cameraStream, .remoteAssist, .remoteAssistAudio]).allowed)
    XCTAssertFalse(Coordinator.decide(.liveTranslation, active: [.cameraStream, .liveVision]).allowed)

    let coordinator = MediaResourceCoordinator()
    XCTAssertTrue(coordinator.begin(.cameraStream).allowed)
    XCTAssertTrue(coordinator.begin(.liveVision).allowed)
    coordinator.end(.cameraStream)
    XCTAssertFalse(coordinator.isActive(.liveVision), "what needed the camera stops counting with it")
  }

  // MARK: Ray-Ban capabilities (§4)

  func testGen1CapabilitiesToday() {
    let matrix = RayBanCapabilityMatrix.current
    XCTAssertEqual(matrix.sdkVersion, "0.5.0")
    XCTAssertEqual(matrix.state(.cameraStream), .available)
    XCTAssertEqual(matrix.state(.highQualityPhoto), .waitingForDAT1)
    XCTAssertEqual(matrix.state(.voiceInvocation), .waitingForDAT1)
    XCTAssertEqual(matrix.state(.display), .unavailable)
    XCTAssertFalse(matrix.showsDisplayUI, "Gen 1 is displayless")

    var dat1 = RayBanCapabilityMatrix(sdkVersion: "1.0.0", deviceHasDisplay: false)
    XCTAssertEqual(dat1.state(.speech), .experimentalDevOnly)
    XCTAssertEqual(dat1.state(.voiceInvocation), .probe)
    XCTAssertEqual(dat1.state(.display), .unavailable)
    dat1.probes[.highQualityPhoto] = true
    XCTAssertEqual(dat1.state(.highQualityPhoto), .available, "a runtime probe overrides the table")
    XCTAssertEqual(RayBanCapabilityMatrix(sdkVersion: "1.0.0", deviceHasDisplay: true).state(.display), .available)
  }

  // MARK: Corrections (§70)

  func testACorrectedDayKeepsTheTimeAndViceVersa() {
    let calendar = Calendar.current
    let now = Date()
    let original = calendar.date(bySettingHour: 15, minute: 0, second: 0, of: now)!
    let saturday = TimePhraseParser.parse("cumartesi", now: now)!
    let dayOnly = CorrectionMerge.merge(original: original, originalHasTime: true, correction: saturday)
    XCTAssertEqual(calendar.component(.hour, from: dayOnly.date), 15, "a new day keeps 15:00")
    XCTAssertEqual(calendar.component(.weekday, from: dayOnly.date), 7, "Saturday")
    let four = TimePhraseParser.parse("saat 16:00", now: now)!
    let timeOnly = CorrectionMerge.merge(original: original, originalHasTime: true, correction: four)
    XCTAssertEqual(calendar.component(.hour, from: timeOnly.date), 16)
    XCTAssertTrue(calendar.isDate(timeOnly.date, inSameDayAs: original), "a new time keeps the day")
  }

  func testCorrectionsNeedSomethingToCorrect() {
    guard case .correctPending? = decide("Hayır, cumartesi", ["pending"]) else { return XCTFail("waiting action") }
    guard case .correctPending? = decide("Cumartesi olsun", ["recent"]) else { return XCTFail("just saved") }
    if case .correctPending? = decide("Hayır, cumartesi") { XCTFail("nothing to correct") }
    XCTAssertEqual(decide("Hayır", ["pending"]), .confirmPending(false), "a plain no is still a no")
  }

  func testCorrectingAWaitingActionChangesOnlyItsTime() async throws {
    let orchestrator = AssistantOrchestrator.shared
    let calendar = Calendar.current
    var plan = DeviceActionPlan(kind: .message)
    plan.recipient = "Ahmet"
    plan.text = "Geliyorum"
    plan.date = calendar.date(bySettingHour: 15, minute: 0, second: 0, of: Date().addingTimeInterval(86_400))
    _ = await orchestrator.stage(plan)
    defer { _ = orchestrator.cancelPendingAction() }
    let saturday = TimePhraseParser.parse("cumartesi", now: Date())!
    _ = await orchestrator.runVoiceIntent(VoiceBridgeDecision(.correctPending(saturday), "test"), transcript: "hayır, cumartesi")
    let corrected = try XCTUnwrap(orchestrator.pendingAction?.plan)
    XCTAssertEqual(corrected.text, "Geliyorum", "the rest of the action is unchanged")
    XCTAssertEqual(corrected.recipient, "Ahmet")
    XCTAssertEqual(calendar.component(.weekday, from: try XCTUnwrap(corrected.date)), 7)
    XCTAssertEqual(calendar.component(.hour, from: try XCTUnwrap(corrected.date)), 15)
  }

  // MARK: Several commands in one sentence (§67, §68, §126)

  func testOnlyRealCommandSequencesAreSplit() {
    guard case .graph(let steps)? = decide("Alışveriş listesine süt ekle ve 10 dakika timer kur") else {
      return XCTFail("two commands")
    }
    XCTAssertEqual(steps.map(\.intent.catalogKey), ["shopping.add", "timer.start"])
    XCTAssertEqual(decide("Alışveriş listesine süt ve ekmek ekle"), .shopping(.add(["süt", "ekmek"])), "one list, two items")
    XCTAssertEqual(decide("Not al: süt ve ekmek al"), .saveNote(text: "Süt ve ekmek al"), "words after a colon stay together")
    guard case .takePhoto(_, let note, _)? = decide("Bunun fotoğrafını çek ve not al: sağ ön jant çizik") else {
      return XCTFail("photo with a note")
    }
    XCTAssertNotNil(note)
    XCTAssertEqual(decide("Ahmet yarın gelecek, bunu hatırla"), .saveMemory(text: "Ahmet yarın gelecek", kind: nil))
    if case .graph? = decide("Evet, kaydet", ["pending"]) { XCTFail("an answer is not a sequence") }
  }

  func testAGraphRunsInOrderAndNeverClaimsAFailedStep() async throws {
    let parking = ParkingStore.shared
    let savedSpot = parking.spot
    parking.clear()
    let marker = "graph\(UUID().uuidString.prefix(6).lowercased())"
    defer {
      parking.restore(savedSpot)
      if let item = ShoppingListStore.shared.items.first(where: { $0.text.lowercased().contains(marker) }) {
        ShoppingListStore.shared.delete(item.id)
      }
    }
    let steps = [
      ActionGraph.Step(text: "alışveriş listesine \(marker) ekle", intent: .shopping(.add([marker]))),
      ActionGraph.Step(text: "beni arabama götür", intent: .parking(.directions)),
    ]
    let outcome = await AssistantOrchestrator.shared.runVoiceIntent(
      VoiceBridgeDecision(.graph(steps), "test"), transcript: "alışveriş listesine \(marker) ekle ve beni arabama götür")
    XCTAssertTrue(ShoppingListStore.shared.items.contains { $0.text.lowercased().contains(marker) }, "step 1 ran")
    XCTAssertTrue(outcome.spoken.contains("Step 2"))
    XCTAssertTrue(outcome.spoken.contains("NOT done"), "the failed step is reported as failed")
    XCTAssertNil(outcome.failed, "one step succeeded")
  }

  // MARK: The active vehicle (§10, §44)

  func testVehicleQuestionsAreAnsweredFromTheRecord() async throws {
    XCTAssertEqual(decide("Kaç kilometre?", ["vehicle"]), .vehicleQuestion(.odometer))
    XCTAssertNotEqual(decide("Kaç kilometre?"), .vehicleQuestion(.odometer), "no vehicle, no vehicle question")
    XCTAssertNotEqual(decide("İstanbul Ankara arası kaç kilometre?", ["vehicle"]), .vehicleQuestion(.odometer))
    let store = DealerStore.shared
    let vehicle = store.start()
    defer { store.delete(vehicle.id) }
    store.update(vehicle.id) {
      $0.stockNumber = "TEST"
      $0.make = "Honda"
      $0.model = "Civic"
      $0.vin = "1HGCM82633A004352"
      $0.vinVerified = true
      $0.odometer = OdometerReading(value: 45_320, unit: .km, at: Date(), source: "spoken")
    }
    let orchestrator = AssistantOrchestrator.shared
    let odometer = await orchestrator.runVoiceIntent(VoiceBridgeDecision(.vehicleQuestion(.odometer), "test"), transcript: "kaç kilometre")
    XCTAssertTrue((odometer.said ?? "").contains("45"), odometer.said ?? "")
    let vin = await orchestrator.runVoiceIntent(VoiceBridgeDecision(.vehicleQuestion(.vin), "test"), transcript: "VIN'i neydi")
    XCTAssertTrue((vin.said ?? "").contains("0 0 4 3 5 2"), vin.said ?? "")
    let photos = await orchestrator.runVoiceIntent(VoiceBridgeDecision(.vehicleQuestion(.photos), "test"), transcript: "ne eksik")
    XCTAssertTrue((photos.said ?? "").contains("15") || (photos.said ?? "").contains("14"), photos.said ?? "")
    let snapshot = JarvisSession.snapshot()
    XCTAssertEqual(snapshot.vehicle, "Honda Civic")
    XCTAssertTrue(snapshot.contextLine.contains("Current vehicle: Honda Civic"))
    XCTAssertTrue(snapshot.chips.contains("Honda Civic"))
  }

  // MARK: Tasks (§7)

  func testMovingATaskKeepsItsTimeAndCanBeUndone() async throws {
    let store = MemoryStore.shared
    let marker = "tasi\(UUID().uuidString.prefix(6).lowercased())"
    let calendar = Calendar.current
    let today = calendar.date(bySettingHour: 11, minute: 30, second: 0, of: Date().addingTimeInterval(3_600)) ?? Date()
    let task = try XCTUnwrap(store.addTask(title: "Lastik \(marker)", dueAt: today, dueHasTime: true, source: "test"))
    defer { store.deleteTask(task) }
    LocalUndo.shared.clear()
    let tomorrow = TimePhraseParser.parse("yarın", now: Date())!
    let outcome = await AssistantOrchestrator.shared.runVoiceIntent(
      VoiceBridgeDecision(.moveTask(title: marker, time: tomorrow), "test"), transcript: "\(marker) yarına taşı")
    XCTAssertNil(outcome.failed)
    let moved = try XCTUnwrap(task.dueAt)
    XCTAssertTrue(calendar.isDateInTomorrow(moved) || calendar.isDate(moved, inSameDayAs: tomorrow.date))
    XCTAssertEqual(calendar.component(.hour, from: moved), 11, "the time of day is kept")
    _ = await AssistantOrchestrator.shared.runVoiceIntent(VoiceBridgeDecision(.undoLast, "test"), transcript: "geri al")
    XCTAssertTrue(calendar.isDate(try XCTUnwrap(task.dueAt), inSameDayAs: today), "undo puts it back")
  }

  // MARK: Global search (§19)

  func testOneSearchFindsNotesVehiclesAndFilters() {
    let marker = "corolla\(UUID().uuidString.prefix(6).lowercased())"
    let memory = MemoryStore.shared
    let note = memory.addNote(title: nil, content: "\(marker) sol arka lastik değişecek", source: "test")
    let dealer = DealerStore.shared
    let vehicle = dealer.start()
    dealer.update(vehicle.id) {
      $0.stockNumber = "TEST"
      $0.model = marker
    }
    defer {
      if let note { memory.deleteNote(note) }
      dealer.delete(vehicle.id)
    }
    let query = GlobalSearch.parse("Geçen hafta \(marker) ile ilgili kaydettiğim şeyi bul")
    XCTAssertEqual(query.text, marker, "command and date words are not searched for")
    XCTAssertNotNil(query.from)
    let kinds = Set(GlobalSearch.run(query).map(\.kind))
    XCTAssertTrue(kinds.contains(.note))
    XCTAssertTrue(kinds.contains(.vehicle))
    XCTAssertEqual(GlobalSearch.parse("Mercedes için çektiğim jant fotoğraflarını göster").kinds, [.capture])
    XCTAssertTrue(GlobalSearch.run(GlobalSearch.parse("zzqqxx qqzzyy şeyi bul")).isEmpty)
  }

  // MARK: "Neler yapabilirsin?" (§76)

  func testCapabilitiesAreContextual() async {
    let outcome = await AssistantOrchestrator.shared.runVoiceIntent(
      VoiceBridgeDecision(.capabilities("dealer"), "test"), transcript: "bayide neler yapabilirsin")
    XCTAssertTrue(outcome.spoken.contains("VIN"))
    XCTAssertEqual(decide("Bayide neler yapabilirsin?"), .capabilities("dealer"))
    XCTAssertEqual(CommandLabView.parameters(of: .saveNote(text: "süt al")), "süt al")
  }
}
