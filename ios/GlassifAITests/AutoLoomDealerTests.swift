import Foundation
import XCTest

@testable import GlassifAI

/// Dealer Mode (Request F §101): VIN checks that never invent characters,
/// odometer and damage parsing, checklists, the vehicle store, voice
/// commands and linking notes, tasks and photos to the active vehicle.
@MainActor
final class AutoLoomDealerTests: XCTestCase {
  private let validVIN = "1HGCM82633A004352"

  override func tearDown() async throws {
    // Never leave a vehicle active for other tests.
    let store = DealerStore.shared
    for vehicle in store.vehicles where vehicle.createdAt > Date().addingTimeInterval(-600) && vehicle.stockNumber == "TEST" {
      store.delete(vehicle.id)
    }
    if store.active?.stockNumber == "TEST" { store.activate(nil) }
  }

  // MARK: VIN

  func testAVINIsVerifiedByItsCheckDigit() {
    let check = VINValidator.check(validVIN)
    XCTAssertEqual(check.status, .valid)
    XCTAssertEqual(check.lastSix, "004352")
    XCTAssertTrue(check.spoken(turkish: true).contains("0 0 4 3 5 2"))
    let letters = VINValidator.check("1HGCM82633AOO4352")
    XCTAssertEqual(letters.status, .valid, "O cannot be in a VIN: read as 0")
    XCTAssertEqual(letters.corrections.count, 2)
    XCTAssertEqual(VINValidator.candidate(in: "VIN: 1HGCM 82633 A004352"), validVIN)
    XCTAssertEqual(VINValidator.check("1HGCM8263").status, .invalid("9 karakter / characters"))
  }

  func testAConfusedCharacterIsReportedNotGuessed() {
    // "6" read as "G" at position 8.
    let check = VINValidator.check("1HGCM82G33A004352")
    XCTAssertEqual(check.status, .checkDigitMismatch)
    XCTAssertTrue(check.alternatives.contains(VINAlternative(position: 8, options: ["G", "6"])))
    XCTAssertTrue(check.spoken(turkish: true).contains("8. karakter G veya 6"))
    // One unreadable character: the options that fit the check digit, never one of them chosen.
    let unknown = VINValidator.check("1HGCM82633A00?352")
    XCTAssertEqual(unknown.status, .incomplete)
    XCTAssertEqual(unknown.alternatives, [VINAlternative(position: 14, options: ["4", "D", "M", "U"])])
    XCTAssertFalse(unknown.isUsable, "an incomplete VIN is not saved")
    XCTAssertTrue(unknown.spoken(turkish: true).contains("14. karakter 4, D, M veya U"))
  }

  // MARK: Odometer, zones, damage

  func testOdometerWords() {
    XCTAssertEqual(OdometerReading.parse("45 bin 320")?.value, 45_320)
    XCTAssertEqual(OdometerReading.parse("45.320 km")?.value, 45_320)
    XCTAssertEqual(OdometerReading.parse("28,500 miles")?.value, 28_500)
    XCTAssertEqual(OdometerReading.parse("28,500 miles")?.unit, .mi)
    XCTAssertEqual(OdometerReading.parse("120 bin")?.value, 120_000)
    XCTAssertEqual(OdometerReading.parse("45k")?.value, 45_000)
    XCTAssertNil(OdometerReading.parse("okunamadı"))
  }

  func testBodyZonesInTurkishAndEnglish() {
    XCTAssertEqual(BodyZone.parse("sağ ön çamurluk çizik"), BodyZone(part: .fender, side: .right, position: .front))
    XCTAssertEqual(BodyZone.parse("sol arka çamurluk göçük"), BodyZone(part: .quarterPanel, side: .left, position: .rear))
    XCTAssertEqual(BodyZone.parse("ön cam çatlak"), BodyZone(part: .windshield, side: .center, position: .front))
    XCTAssertEqual(BodyZone.parse("arka tampon"), BodyZone(part: .bumper, side: .center, position: .rear))
    XCTAssertEqual(BodyZone.parse("left rear door dent"), BodyZone(part: .door, side: .left, position: .rear))
    XCTAssertEqual(BodyZone.parse("tavan döşemesi yırtık")?.part, .interior, "the headliner is not the roof")
    XCTAssertEqual(BodyZone.parse("sağ ön jant")?.part, .wheel)
    XCTAssertEqual(DamageFinding.kind(in: "sağ ön çamurluk çizik"), .scratch)
    XCTAssertEqual(DamageFinding.kind(in: "kapıda göçük var"), .dent)
    XCTAssertEqual(DamageFinding.kind(in: "kaputta taş izi"), .chip)
    XCTAssertEqual(
      DamageFinding(zone: BodyZone.parse("sağ ön çamurluk"), kind: .scratch, text: "x").title(turkish: true),
      "sağ ön çamurluk çizik")
  }

  // MARK: Vehicle session

  func testChecklistsAndFacts() {
    var session = VehicleSession()
    session.vin = validVIN
    session.make = "Honda"
    session.model = "Civic"
    session.identification = .visualGuess
    XCTAssertEqual(session.maskedVIN, "•••••••••••004352")
    XCTAssertEqual(session.remainingPhotos.count, 14, "no damage: no damage close-ups needed")
    XCTAssertEqual(session.tickPhoto(for: .front)?.id, "front34left")
    XCTAssertEqual(session.tickPhoto(for: .front)?.id, "front")
    session.damage.append(DamageFinding(zone: nil, kind: .dent, text: "Kapı göçük"))
    XCTAssertEqual(session.remainingPhotos.count, 13)
    let facts = session.factSheet(turkish: true)
    XCTAssertTrue(facts.contains("görsel tahmin"), "an unverified identification is labelled")
    XCTAssertTrue(facts.contains("Kapı göçük"), "known damage is never hidden")
    XCTAssertFalse(DealerChecklists.delivery().contains { $0.id.lowercased().contains("licen") }, "no licence data in delivery")
    XCTAssertTrue(DealerChecklists.testDrive().first?.english.contains("not stored") ?? false)
  }

  func testTheStoreKeepsOneActiveVehicle() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dealer-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = DealerStore(directory: directory)
    let first = store.start()
    XCTAssertEqual(store.active?.id, first.id)
    store.updateActive { $0.odometer = OdometerReading(value: 45_320, unit: .km, at: Date(), source: "spoken") }
    let finished = try XCTUnwrap(store.finishActive())
    XCTAssertNotNil(finished.closedAt)
    XCTAssertNil(store.active)
    let reloaded = DealerStore(directory: directory)
    XCTAssertEqual(reloaded.vehicle(first.id)?.odometer?.value, 45_320)
    XCTAssertEqual(reloaded.today().count, 1)
  }

  // MARK: Voice

  private func decide(_ text: String) -> VoiceIntent? {
    var context = VoiceBridgeContext()
    context.assistantName = "AutoLoom"
    return VoiceActionIntentBridge.decide(text, context: context)?.intent
  }

  func testDealerQuickCommands() {
    XCTAssertEqual(decide("Yeni araç"), .dealer(.startVehicle))
    XCTAssertEqual(decide("AutoLoom yeni araç başlat"), .dealer(.startVehicle))
    XCTAssertEqual(decide("VIN oku"), .dealer(.readVIN))
    XCTAssertEqual(decide("şasi numarasını oku"), .dealer(.readVIN))
    XCTAssertEqual(decide("kilometre"), .dealer(.readOdometer))
    XCTAssertEqual(decide("kilometre 45 bin 320"), .dealer(.setOdometer(45_320, .km)))
    XCTAssertEqual(decide("hasar ekle: sağ ön çamurluk çizik"), .dealer(.addDamage("Sağ ön çamurluk çizik")))
    XCTAssertEqual(decide("hasar: ön cam çatlak"), .dealer(.addDamage("Ön cam çatlak")))
    XCTAssertEqual(decide("foto checklist"), .dealer(.photoChecklist))
    XCTAssertEqual(decide("hangi fotoğraflar kaldı"), .dealer(.photoChecklist))
    XCTAssertEqual(decide("delivery checklist"), .dealer(.deliveryChecklist))
    XCTAssertEqual(decide("piyasa bak"), .dealer(.marketResearch))
    XCTAssertEqual(decide("ilan hazırla"), .dealer(.listing))
    XCTAssertEqual(decide("Bu araç tamam"), .dealer(.finishVehicle))
    XCTAssertEqual(decide("Sonraki araç"), .dealer(.nextVehicle))
  }

  func testDealerWordsInConversationAreNotCommands() {
    XCTAssertNil(decide("VIN nedir?"))
    XCTAssertNotEqual(decide("yeni araç almak istiyorum"), .dealer(.startVehicle))
    if case .dealer(.setOdometer)? = decide("kaç kilometre yaptı?") { XCTFail("a question, not a reading") }
    XCTAssertNotEqual(decide("hasar raporu"), .dealer(.addDamage("Raporu")))
    XCTAssertEqual(decide("not al: yeni araç yarın geliyor"), .saveNote(text: "Yeni araç yarın geliyor"), "the note verb came first")
  }

  func testNotesTasksAndReadingsLinkToTheActiveVehicle() async throws {
    let store = DealerStore.shared
    let orchestrator = AssistantOrchestrator.shared
    let vehicle = store.start()
    store.update(vehicle.id) { $0.stockNumber = "TEST" }
    defer { store.delete(vehicle.id) }

    let odometer = await orchestrator.runVoiceIntent(
      VoiceBridgeDecision(.dealer(.setOdometer(45_320, .km)), "test"), transcript: "kilometre 45 bin 320")
    XCTAssertNil(odometer.failed)
    XCTAssertEqual(store.vehicle(vehicle.id)?.odometer?.value, 45_320)

    _ = await orchestrator.runVoiceIntent(
      VoiceBridgeDecision(.dealer(.addDamage("Sağ ön çamurluk çizik")), "test"), transcript: "hasar ekle")
    let damage = try XCTUnwrap(store.vehicle(vehicle.id)?.damage.first)
    XCTAssertEqual(damage.zone?.part, .fender)
    XCTAssertEqual(damage.kind, .scratch)

    let marker = "dealer\(UUID().uuidString.prefix(6))"
    _ = await orchestrator.runVoiceIntent(VoiceBridgeDecision(.saveNote(text: "Lastik \(marker)"), "test"), transcript: "not al")
    let note = try XCTUnwrap(MemoryStore.shared.notes.first { $0.content.contains(marker) })
    defer { MemoryStore.shared.deleteNote(note) }
    XCTAssertTrue(store.vehicle(vehicle.id)?.noteIDs.contains(note.id) ?? false, "TEST NOTE 3: the note links to the vehicle")

    var record = CaptureRecord(kind: .photo)
    record.label = .wheel
    record.vehicleSessionID = vehicle.id
    XCTAssertEqual(store.linkCapture(record)?.id, "wheels", "a wheel photo ticks the checklist")
    XCTAssertTrue(store.vehicle(vehicle.id)?.captureIDs.contains(record.id) ?? false)

    let checklist = await orchestrator.runVoiceIntent(VoiceBridgeDecision(.dealer(.photoChecklist), "test"), transcript: "foto checklist")
    XCTAssertTrue((checklist.said ?? "").contains(L.t("photos left", "fotoğraf kaldı")))

    let finished = await orchestrator.runVoiceIntent(VoiceBridgeDecision(.dealer(.finishVehicle), "test"), transcript: "bu araç tamam")
    XCTAssertNil(finished.failed)
    XCTAssertNil(store.active)
    XCTAssertNotNil(store.vehicle(vehicle.id)?.closedAt)
  }
}
