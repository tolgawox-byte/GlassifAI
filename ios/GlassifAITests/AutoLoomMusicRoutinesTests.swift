import Foundation
import XCTest

@testable import GlassifAI

/// Music commands, user routines (safe steps only, honest results) and the
/// dealer morning briefing.
@MainActor
final class AutoLoomMusicRoutinesTests: XCTestCase {
  private func decide(_ text: String, _ tags: Set<String> = []) -> VoiceIntent? {
    VoiceActionIntentBridge.decide(text, context: AutoLoomActionCatalogTests.context(for: tags))?.intent
  }

  func testMusicPhrasesAndTheirLimits() {
    XCTAssertEqual(decide("Müzik çal"), .music(.play(nil)))
    XCTAssertEqual(decide("Tarkan şarkısını çal"), .music(.play("Tarkan")))
    XCTAssertEqual(decide("Tarkan'dan bir şarkı çal"), .music(.play("Tarkan")))
    XCTAssertEqual(decide("Play Yesterday by the Beatles"), .music(.play("Yesterday")))
    XCTAssertEqual(decide("Müziği durdur"), .music(.pause))
    XCTAssertEqual(decide("Sonraki şarkı"), .music(.next))
    XCTAssertEqual(decide("Ne çalıyor?"), .music(.nowPlaying))
    XCTAssertEqual(decide("Kaydı durdur"), .stopRecording, "the recording keeps its own words")
    XCTAssertNotEqual(decide("Zili çal"), .music(.play("Zili")), "“çal” alone is not music")
    XCTAssertNil(decide("Play it again").flatMap { intent -> VoiceIntent? in
      if case .music = intent { return intent }
      return nil
    })
  }

  func testRoutinesKeepOnlySafeStepsAndSayWhatDidNotRun() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("routines-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = UserRoutineStore(directory: directory)
    let eligible = Set(UserRoutineStore.eligibleActions.map(\.id))
    XCTAssertFalse(eligible.contains("phone.call"), "nothing that leaves the phone")
    XCTAssertFalse(eligible.contains("memory.forget"), "nothing that needs a yes")
    XCTAssertTrue(eligible.contains("shopping.read"))
    store.save(UserRoutine(name: "  Sabah turu ", steps: [
      .init(actionID: "shopping.read"), .init(actionID: "phone.call", parameters: ["contact": "Ahmet"]),
    ]))
    XCTAssertEqual(store.routines.first?.name, "Sabah turu")
    XCTAssertEqual(store.routines.first?.steps.map(\.actionID), ["shopping.read"], "the call step is dropped")
    XCTAssertNotNil(store.routine(named: "sabah TURU"))
    store.save(UserRoutine(name: "", steps: [.init(actionID: "shopping.read")]))
    XCTAssertEqual(store.routines.count, 1, "a routine needs a name")
    XCTAssertEqual(UserRoutineStore(directory: directory).routines.count, 1, "kept on disk")

    XCTAssertEqual(decide("Sabah turu rutinini başlat", ["routine"]), .userRoutine("Sabah turu"))
    XCTAssertNil(decide("Akşam turu rutinini başlat", ["routine"]).flatMap { intent -> VoiceIntent? in
      if case .userRoutine = intent { return intent }
      return nil
    }, "only routines that exist")

    let shared = UserRoutineStore.shared
    let routine = UserRoutine(name: "Test \(UUID().uuidString.prefix(4))", steps: [
      .init(actionID: "shopping.read"), .init(actionID: "note.create"),
    ])
    shared.save(routine)
    defer { shared.delete(routine.id) }
    let outcome = await AssistantOrchestrator.shared.runUserRoutine(routine.name, traceID: UUID())
    XCTAssertTrue(outcome.spoken.contains("Not done"), "a note without words is not done")
    let missing = await AssistantOrchestrator.shared.runUserRoutine("yok böyle bir rutin", traceID: UUID())
    XCTAssertEqual(missing.failed, "no routine")
  }

  func testDealerBriefingFromRecordsOnly() {
    var photos = VehicleSession()
    photos.make = "Honda"
    photos.model = "Civic"
    var recall = VehicleSession()
    recall.make = "Toyota"
    recall.model = "Corolla"
    recall.vin = "2T1BURHE0JC000001"
    recall.damage = [DamageFinding(zone: nil, kind: .dent, text: "Göçük")]
    let lines = DealerBriefing.lines(vehicles: [photos, recall], tasks: [], turkish: false)
    XCTAssertEqual(lines.first, "Open vehicles: 2")
    XCTAssertTrue(lines.contains { $0.hasPrefix("No VIN yet:") && $0.contains("Honda Civic") })
    XCTAssertTrue(lines.contains { $0.hasPrefix("Recall check not done:") && $0.contains("Toyota Corolla") })
    XCTAssertTrue(lines.contains("Damage notes without a photo: 1"))
    XCTAssertFalse(lines.joined().contains("2T1BURHE0JC000001"), "VINs are never read aloud")
  }
}
