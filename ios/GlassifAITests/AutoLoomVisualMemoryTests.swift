import Foundation
import UIKit
import XCTest

@testable import GlassifAI

/// Visual Second Brain: explicit visual memories found by what the phone
/// read in them, the opt-in Scene Timeline, "ne değişti?".
@MainActor
final class AutoLoomVisualMemoryTests: XCTestCase {
  private func decide(_ text: String, _ tags: Set<String> = []) -> VoiceIntent? {
    VoiceActionIntentBridge.decide(text, context: AutoLoomActionCatalogTests.context(for: tags))?.intent
  }

  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("visual-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return url
  }

  func testWhereDidISeeItIsAVisualSearch() {
    XCTAssertEqual(decide("Anahtarımı en son nerede gördüm?"), .findVisual("Anahtarımı"))
    XCTAssertEqual(decide("Cüzdanımı nerede görmüştüm?"), .findVisual("Cüzdanımı"))
    XCTAssertEqual(decide("Where did I last see my keys?"), .findVisual("keys"))
    XCTAssertEqual(decide("Bugün neler gördüm?"), .findVisual(""))
    XCTAssertEqual(decide("Görsel anılarımı göster"), .findVisual(""))
    // Where something was put is a saved-memory question, not a visual one.
    if case .findVisual = decide("Anahtarımı nereye bıraktım?") { XCTFail("placed, not seen") }
  }

  func testWhatChangedOnlyWhileLiveVisionWatches() {
    XCTAssertEqual(decide("Ne değişti?", ["live"]), .whatChanged)
    XCTAssertEqual(decide("Şimdi ne değişti?", ["live"]), .whatChanged)
    XCTAssertEqual(decide("What changed?", ["live"]), .whatChanged)
    XCTAssertNotEqual(decide("Ne değişti?"), .whatChanged, "without Live Vision it is a normal question")
    XCTAssertNotEqual(decide("Bu güncellemede ne değişti?", ["live"]), .whatChanged, "not about the view")
  }

  func testVisualMemoriesAreFoundByWhatThePhoneRead() throws {
    let memory = MemoryStore.shared
    let marker = "vm\(UUID().uuidString.prefix(5).lowercased())"
    let keys = try XCTUnwrap(memory.remember("Tezgâhın üstünde \(marker)", kind: .visual, source: "visual"))
    let invoice = try XCTUnwrap(memory.remember("Masada bir kâğıt \(marker)", kind: .visual, source: "visual"))
    let keysID = keys.id
    let invoiceID = invoice.id
    let index = VisualMemoryIndex.shared
    index.record(keysID, analysis: VisualAnalysis.Result(text: "", labels: ["key", "countertop"]), vehicleID: nil, image: nil)
    index.record(invoiceID, analysis: VisualAnalysis.Result(text: "FATURA NO 4471 TOPLAM 250 TL", labels: []), vehicleID: nil, image: nil)
    var keysDeleted = false
    defer {
      if !keysDeleted { memory.delete(keys) }
      memory.delete(invoice)
    }
    XCTAssertEqual(VisualMemorySearch.find("anahtarımı \(marker)").first?.record.id, keysID, "Turkish words find English labels")
    XCTAssertEqual(VisualMemorySearch.find("fatura \(marker)").first?.record.id, invoiceID, "text read in the photo")
    XCTAssertTrue(VisualMemorySearch.find("zürafa \(marker)").allSatisfy { $0.score < 1 })
    memory.delete(keys)
    keysDeleted = true
    XCTAssertNil(index.entries[keysID], "deleting the memory deletes what was read in it")
  }

  func testNoVisualMemoryIsNeverAGuess() {
    let outcome = AssistantOrchestrator.shared.findVisual("zürafa\(UUID().uuidString.prefix(4))", traceID: UUID())
    XCTAssertEqual(outcome.failed, "no visual memory")
    let changed = AssistantOrchestrator.shared.whatChanged(traceID: UUID())
    XCTAssertEqual(changed.failed, "live vision off")
  }

  func testOfflineDescriptionSaysWhereItCameFrom() {
    XCTAssertNil(VisualAnalysis.offlineDescription(VisualAnalysis.Result(text: " ", labels: [])))
    let text = VisualAnalysis.offlineDescription(VisualAnalysis.Result(text: "EXIT", labels: ["door"]))
    XCTAssertNotNil(text)
    XCTAssertTrue(text?.contains("EXIT") == true)
    XCTAssertTrue(text?.contains("offline") == true || text?.contains("çevrimdışı") == true)
  }

  func testTheIndexKeepsPhotosOnlyWhenGivenAndDeletesThem() throws {
    let directory = try temporaryDirectory()
    let index = VisualMemoryIndex(directory: directory)
    let id = UUID()
    let jpeg = try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
      UIColor.red.setFill()
      context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
    }.jpegData(compressionQuality: 0.8))
    index.record(id, analysis: VisualAnalysis.Result(text: "a", labels: ["b"]), vehicleID: nil, image: jpeg)
    XCTAssertNotNil(index.image(for: id))
    let other = UUID()
    index.record(other, analysis: VisualAnalysis.Result(text: "", labels: []), vehicleID: nil, image: nil)
    XCTAssertNil(index.image(for: other), "no photo unless the user allowed photos")
    XCTAssertEqual(VisualMemoryIndex(directory: directory).entries[id]?.analysis.labels, ["b"], "kept on disk")
    index.remove(id)
    XCTAssertNil(index.image(for: id))
    index.deleteEverything()
    XCTAssertTrue(VisualMemoryIndex(directory: directory).entries.isEmpty)
  }

  func testSceneTimelineIsOptInShortAndForgets() throws {
    let timeline = SceneTimeline(directory: try temporaryDirectory())
    let start = Date()
    XCTAssertFalse(timeline.note("Ofis, masada evraklar", now: start, enabled: false), "off by default")
    XCTAssertTrue(timeline.note("Ofis, masada evraklar. İki kişi konuşuyor.", now: start, enabled: true))
    XCTAssertEqual(timeline.entries.last?.text, "Ofis, masada evraklar", "the first sentence only")
    XCTAssertFalse(timeline.note("Otopark, beyaz araba", now: start.addingTimeInterval(30), enabled: true), "not every few seconds")
    XCTAssertFalse(timeline.note("Ofis, masada evraklar", now: start.addingTimeInterval(600), enabled: true), "same scene")
    XCTAssertTrue(timeline.note("Otopark, beyaz araba", now: start.addingTimeInterval(600), enabled: true))
    XCTAssertTrue(timeline.note("Servis girişi", now: start.addingTimeInterval(8 * 86_400), enabled: true))
    XCTAssertEqual(timeline.entries.count, 1, "a week later the old lines are gone")
    timeline.deleteEverything()
    XCTAssertTrue(timeline.entries.isEmpty)
  }
}
