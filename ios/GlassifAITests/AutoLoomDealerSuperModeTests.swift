import Foundation
import XCTest

@testable import GlassifAI

/// Dealer SuperMode: VIN decoding, official recall wording, tires, the
/// walk-around, reports, photo hints and the voice phrases.
@MainActor
final class AutoLoomDealerSuperModeTests: XCTestCase {
  private func decide(_ text: String, _ tags: Set<String> = []) -> VoiceIntent? {
    VoiceActionIntentBridge.decide(text, context: AutoLoomActionCatalogTests.context(for: tags))?.intent
  }

  private static let cleanDecode = #"""
    {"Count":136,"Message":"Results returned successfully","SearchCriteria":"VIN:2HGFC2F58JH512345","Results":[{
    "Make":"HONDA","Model":"Civic","ModelYear":"2018","Trim":"LX","Series":"","BodyClass":"Sedan/Saloon",
    "DriveType":"FWD/Front-Wheel Drive","EngineCylinders":"4","DisplacementL":"2.0","FuelTypePrimary":"Gasoline",
    "TransmissionStyle":"Continuously Variable Transmission (CVT)","PlantCity":"ALLISTON","PlantCountry":"CANADA",
    "ErrorCode":"0","ErrorText":"0 - VIN decoded clean. Check Digit (9th position) is correct"}]}
    """#

  private static let partialDecode = #"""
    {"Results":[{"Make":"ACURA","Model":"","ModelYear":"2011","Trim":"","ErrorCode":"5,14",
    "ErrorText":"5 - VIN has errors in few positions; 14 - Unable to provide information for all the characters in the VIN"}]}
    """#

  // MARK: vPIC

  func testCleanDecodeFillsTheVehicleAndLabelsEquipment() throws {
    let decode = try XCTUnwrap(VPICClient.parse(Data(Self.cleanDecode.utf8), vin: "2HGFC2F58JH512345"))
    XCTAssertEqual(decode.quality, .clean)
    XCTAssertEqual(decode.make, "Honda")
    XCTAssertEqual(decode.year, 2018)
    XCTAssertTrue(decode.options.allSatisfy { $0.provenance == .vinDecoded })
    XCTAssertTrue(decode.options.contains { $0.value == "FWD/Front-Wheel Drive" })

    let store = DealerStore.shared
    let vehicle = store.start()
    defer { store.delete(vehicle.id) }
    store.update(vehicle.id) {
      $0.vin = "2HGFC2F58JH512345"
      $0.vinVerified = true
      $0.make = "Toyota"
      $0.identification = .visualGuess
    }
    AssistantOrchestrator.shared.applyDecode(decode, to: vehicle.id)
    let decoded = try XCTUnwrap(store.vehicle(vehicle.id))
    XCTAssertEqual(decoded.make, "Honda", "a clean decode replaces a visual guess")
    XCTAssertEqual(decoded.model, "Civic")
    XCTAssertEqual(decoded.identification, .confirmed)
    XCTAssertFalse((decoded.options ?? []).isEmpty)
  }

  func testPartialOrMisreadDecodesNeverInventTheRest() throws {
    let partial = try XCTUnwrap(VPICClient.parse(Data(Self.partialDecode.utf8), vin: "2HHFD5F79BH200001"))
    XCTAssertEqual(partial.quality, .rescan, "error 5 means misread characters")
    XCTAssertNil(partial.model, "empty means no data")
    let store = DealerStore.shared
    let vehicle = store.start()
    defer { store.delete(vehicle.id) }
    AssistantOrchestrator.shared.applyDecode(partial, to: vehicle.id)
    let after = try XCTUnwrap(store.vehicle(vehicle.id))
    XCTAssertNil(after.make, "a decode that asks for a re-scan fills nothing")
    XCTAssertTrue((after.options ?? []).isEmpty)

    var dataOnly = partial
    dataOnly.errorCodes = ["14"]
    XCTAssertEqual(dataOnly.quality, .partial)
  }

  // MARK: Transport Canada

  private nonisolated static func response(_ json: String, for request: URLRequest) -> (Data, URLResponse) {
    XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json", "without it the API answers 500")
    let http = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
    return (Data(json.utf8), http)
  }

  private static func row(_ number: String, model: String) -> String {
    #"[{"Name":"Recall number","Value":{"Type":"System.String","Literal":"\#(number)"}},"#
      + #"{"Name":"Model name","Value":{"Type":"System.String","Literal":"\#(model)"}},"#
      + #"{"Name":"Recall date","Value":{"Type":"System.DateTime","Literal":"5/28/2020 12:00:00 AM"}}]"#
  }

  func testRecallsAreListedByModelNeverAsNoRecalls() async throws {
    let search = #"{"ResultSet":["# + [Self.row("2020-123", model: "CIVIC"), Self.row("2020-123", model: "CIVIC"),
                                        Self.row("2019-555", model: "CIVIC HYBRID")].joined(separator: ",") + "]}"
    let summary = #"{"ResultSet":[[{"Name":"SYSTEM_TYPE_ETXT","Value":{"Literal":"Fuel System"}},"#
      + #"{"Name":"NOTIFICATION_TYPE_ETXT","Value":{"Literal":"Safety Mfr"}},"#
      + #"{"Name":"COMMENT_ETXT","Value":{"Literal":"Issue: fuel pump."}}]]}"#
    let result = try await TransportCanadaRecalls.check(make: "Honda", model: "Civic", year: 2018) { request in
      let url = request.url!.absoluteString
      if url.contains("recall-summary") { return Self.response(summary, for: request) }
      return Self.response(url.contains("page=1") ? search : #"{"ResultSet":[]}"#, for: request)
    }
    XCTAssertEqual(result.campaigns.map(\.number), ["2020-123"], "exact model only, each campaign once")
    XCTAssertEqual(result.safetyCampaigns.first?.system, "Fuel System")
    let english = result.spoken(turkish: false, portal: TransportCanadaRecalls.portal(forMake: "Honda"))
    XCTAssertTrue(english.contains("not by VIN"))
    XCTAssertTrue(english.contains("honda.ca/recalls"))

    let empty = try await TransportCanadaRecalls.check(make: "Honda", model: "Civik", year: 2018) { request in
      Self.response(#"{"ResultSet":[]}"#, for: request)
    }
    XCTAssertTrue(empty.campaigns.isEmpty)
    XCTAssertTrue(empty.spoken(turkish: false, portal: nil).contains("does not mean there are no recalls"))
    XCTAssertTrue(empty.spoken(turkish: true, portal: nil).contains("anlamına gelmez"))
  }

  // MARK: Tires

  func testTireSizeAndDOTAgeAreReadNotGuessed() throws {
    let size = try XCTUnwrap(TireSize.parse("SIZE: 215/55R16 93V"))
    XCTAssertEqual(size.text, "215/55R16 93V")
    XCTAssertNil(TireSize.parse("SIZE: 2?5/55R16"), "an unreadable digit is not completed")
    let dot = try XCTUnwrap(DOTDate.parse("DOT: U2LL LMLR 2319"))
    XCTAssertEqual(dot, DOTDate(week: 23, year: 2019))
    XCTAssertEqual(DOTDate.parse("DOT: 2319 (week 23, 2019)"), DOTDate(week: 23, year: 2019))
    XCTAssertNil(DOTDate.parse("DOT: U2LL LMLR 23?9"))
    var components = DateComponents()
    components.year = 2026
    components.month = 9
    components.day = 29
    let now = try XCTUnwrap(Calendar(identifier: .gregorian).date(from: components))
    let age = try XCTUnwrap(dot.ageInYears(now: now))
    XCTAssertEqual(age, 7.3, accuracy: 0.1)
    let reading = TireReading(position: "Sağ ön", size: size, dot: dot, raw: "")
    XCTAssertTrue(reading.spoken(turkish: false, now: now).contains("can't measure tread depth"))
  }

  // MARK: Voice

  func testDealerSuperModePhrases() {
    XCTAssertEqual(decide("VIN'i çöz"), .dealer(.decodeVIN))
    XCTAssertEqual(decide("Sağ ön lastiği oku", ["vehicle"]), .dealer(.readTire("Sağ ön")))
    XCTAssertEqual(decide("Lastiği oku"), .dealer(.readTire(nil)))
    XCTAssertEqual(decide("Uyarı ışıklarına bak"), .dealer(.readDashboard))
    XCTAssertEqual(decide("Hasar raporu hazırla"), .dealer(.conditionReport))
    XCTAssertEqual(decide("Servis notu hazırla"), .dealer(.serviceHandoff))
    XCTAssertEqual(decide("Sağ ön jant çizik, not et", ["vehicle"]), .dealer(.addDamage("Sağ ön jant çizik")))
    XCTAssertNotEqual(decide("Sağ ön jant çizik, not et"), .dealer(.addDamage("Sağ ön jant çizik")), "no vehicle: a note")
    XCTAssertEqual(decide("Sol taraf temiz", ["vehicle"]), .dealer(.areaClear("left")))
    if case .dealer(.areaClear)? = decide("Mutfak temiz", ["vehicle"]) { XCTFail("a kitchen is not an area of the vehicle") }
    XCTAssertEqual(decide("Aracın yerini kaydet", ["vehicle"]), .dealer(.saveLotSpot))
    XCTAssertEqual(decide("Araç nerede duruyor?", ["vehicle"]), .dealer(.findLotSpot))
    XCTAssertEqual(decide("Parça numarasını oku"), .dealer(.readPartNumber))
  }

  func testSeverityOnlyWhenSaid() {
    XCTAssertEqual(DamageSeverity.parse("arka tamponda derin çizik"), .severe)
    XCTAssertEqual(DamageSeverity.parse("hafif göçük"), .minor)
    XCTAssertNil(DamageSeverity.parse("sağ ön jant çizik"))
    XCTAssertEqual(VehicleArea.parse("sol taraf"), .left)
    XCTAssertEqual(VehicleArea.parse("interior"), .interior)
    XCTAssertNil(VehicleArea.parse("mutfak"))
    XCTAssertNil(VehicleArea.parse("sol ön"), "two areas are not one")
  }

  // MARK: Reports

  func testReportsListOnlyObservationsAndWhatIsNotChecked() {
    var session = VehicleSession()
    session.year = 2019
    session.make = "Honda"
    session.model = "Civic"
    session.vin = "2HGFC2F59KH512345"
    session.vinVerified = true
    session.damage = [DamageFinding(zone: BodyZone.parse("sağ ön jant"), kind: .scratch, text: "Sağ ön jant çizik")]
    session.inspected = ["left", "front"]
    let report = VehicleReport.condition(session, turkish: false)
    XCTAssertTrue(report.contains("not a safety inspection"))
    XCTAssertTrue(report.contains("Areas not checked"))
    XCTAssertFalse(report.contains("2HGFC2F59KH512345"), "the report shows the masked VIN")
    XCTAssertFalse(VehicleReport.uninspected(session).contains(.wheels), "a damage note means the area was looked at")
    XCTAssertFalse(VehicleReport.uninspected(session).contains(.left))
    let handoff = VehicleReport.serviceHandoff(session, turkish: false, openTasks: ["Order tires"])
    XCTAssertTrue(handoff.contains("2HGFC2F59KH512345"), "the service needs the whole VIN")
    XCTAssertTrue(handoff.contains("No recall check done yet."))
    XCTAssertTrue(handoff.contains("Open task: Order tires"))
    XCTAssertTrue(handoff.contains("No diagnosis"))
  }

  func testAPhotoRightAfterADamageNoteDocumentsIt() {
    let store = DealerStore.shared
    let vehicle = store.start()
    defer { store.delete(vehicle.id) }
    store.update(vehicle.id) { $0.damage = [DamageFinding(zone: nil, kind: .dent, text: "Göçük")] }
    var photo = CaptureRecord(kind: .photo)
    photo.vehicleSessionID = vehicle.id
    store.linkCapture(photo)
    XCTAssertEqual(store.vehicle(vehicle.id)?.damage.first?.captureIDs, [photo.id])
    var second = CaptureRecord(kind: .photo)
    second.vehicleSessionID = vehicle.id
    store.linkCapture(second)
    XCTAssertEqual(store.vehicle(vehicle.id)?.damage.first?.captureIDs, [photo.id], "only the first photo is linked")
  }

  // MARK: Photo director

  func testPhotoHintsAreMeasuredNotGuessed() {
    let side = 64
    let flat = [UInt8](repeating: 128, count: side * side)
    XCTAssertEqual(PhotoDirector.measure(flat, width: side, height: side).issues, [.blurry])
    var checker = [UInt8](repeating: 0, count: side * side)
    for y in 0..<side { for x in 0..<side { checker[y * side + x] = (x / 2 + y / 2) % 2 == 0 ? 60 : 190 } }
    XCTAssertEqual(PhotoDirector.measure(checker, width: side, height: side).issues, [])
    let dark = [UInt8](repeating: 10, count: side * side)
    XCTAssertTrue(PhotoDirector.measure(dark, width: side, height: side).issues.contains(.dark))

    let vehicleID = UUID()
    let thumbnail = PhotoDirector.thumbnail(checker, width: side, height: side)
    let assessment = PhotoDirector.Assessment(quality: PhotoDirector.measure(checker, width: side, height: side), thumbnail: thumbnail)
    XCTAssertFalse(PhotoDirector.review(assessment, vehicleID: vehicleID).issues.contains(.duplicate))
    XCTAssertTrue(PhotoDirector.review(assessment, vehicleID: vehicleID).issues.contains(.duplicate), "the same view twice")
    XCTAssertNotNil(PhotoQuality(sharpness: 1, brightness: 100, highlights: 0, issues: [.blurry]).hint(turkish: true))
  }
}
