import CoreSpotlight
import Foundation
import XCTest

@testable import GlassifAI

/// On-device intelligence and Spotlight: optional, honest when unavailable
/// (CI simulators have no Apple Intelligence), private by default.
@MainActor
final class AutoLoomAppleIntelligenceTests: XCTestCase {
  func testTheOnDeviceModelIsOptionalAndHonest() async {
    for profile in LocalBrain.Profile.allCases {
      XCTAssertTrue(profile.instructions.contains("tr_TR"), "\(profile): locale stated for the model")
      XCTAssertTrue(profile.instructions.contains("never invent"), "\(profile): no invented facts")
    }
    XCTAssertFalse(LocalBrain.statusText.isEmpty)
    guard !LocalBrain.isReady else { return }
    // Without the model: nothing is guessed, the offline notice is honest.
    let classification = await LocalBrain.classify("not al süt al")
    XCTAssertNil(classification)
    let labels = await LocalBrain.noteLabels("Corolla'nın sol arka lastiği değişecek; müşteri cuma teslim istiyor.")
    XCTAssertNil(labels)
    let offline = await OfflineAssistant.handle("Bugün hava nasıl?")
    XCTAssertEqual(offline, OfflineAssistant.offlineNotice)
  }

  func testSpotlightKeepsMemoriesOutAndMasksTheVIN() throws {
    let defaults = UserDefaults.standard
    let saved = defaults.object(forKey: SpotlightIndexer.memoriesKey)
    defer { defaults.set(saved, forKey: SpotlightIndexer.memoriesKey) }
    defaults.set(false, forKey: SpotlightIndexer.memoriesKey)

    let marker = "spot\(UUID().uuidString.prefix(6).lowercased())"
    let memory = MemoryStore.shared
    let note = try XCTUnwrap(memory.addNote(title: nil, content: "\(marker) lastik notu", source: "test"))
    let remembered = memory.remember("Kapı kodu \(marker) 4512", source: "test")
    let dealer = DealerStore.shared
    let vehicle = dealer.start()
    dealer.update(vehicle.id) {
      $0.stockNumber = "TEST"
      $0.vin = "1HGCM82633A004352"
      $0.model = marker
    }
    defer {
      memory.deleteNote(note)
      if let remembered { memory.delete(remembered) }
      dealer.delete(vehicle.id)
    }
    let items = SpotlightIndexer.items()
    let ids = Set(items.map(\.uniqueIdentifier))
    XCTAssertTrue(ids.contains("note:\(note.id.uuidString)"))
    XCTAssertTrue(ids.contains("vehicle:\(vehicle.id.uuidString)"))
    if let remembered { XCTAssertFalse(ids.contains("memory:\(remembered.id.uuidString)"), "memories are opt-in") }
    let vehicleItem = try XCTUnwrap(items.first { $0.uniqueIdentifier == "vehicle:\(vehicle.id.uuidString)" })
    let text = (vehicleItem.attributeSet.contentDescription ?? "") + (vehicleItem.attributeSet.textContent ?? "")
    XCTAssertFalse(text.contains("1HGCM82633A004352"), "only the last six VIN characters")
    XCTAssertTrue(text.contains("004352"))
  }

  func testSpotlightIdentifiersRoundTrip() {
    let id = UUID()
    let parsed = SpotlightIndexer.parse("note:\(id.uuidString)")
    XCTAssertEqual(parsed?.domain, "note")
    XCTAssertEqual(parsed?.id, id)
    XCTAssertNil(SpotlightIndexer.parse("garbage"))
    XCTAssertEqual(SpotlightIndexer.kind(forDomain: "vehicle"), .vehicle)
    XCTAssertNil(SpotlightIndexer.kind(forDomain: "unknown"))
  }
}
