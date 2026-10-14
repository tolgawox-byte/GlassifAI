import Contacts
import Foundation
import XCTest

@testable import GlassifAI

/// Research idea D2-18: a business card in view becomes a contact draft in
/// iOS's own contact card. The parsing is tested here; reading a real card
/// and the tap that saves it are device test BC1.
@MainActor
final class AutoLoomBusinessCardTests: XCTestCase {
  typealias Line = BusinessCardParser.Line

  private func decide(_ text: String) -> VoiceIntent? {
    var context = VoiceBridgeContext()
    context.assistantName = "Jarvis"
    return VoiceActionIntentBridge.decide(text, context: context)?.intent
  }

  func testATurkishCardBecomesADraft() throws {
    let draft = try XCTUnwrap(BusinessCardParser.parse([
      Line("ABC Otomotiv San. ve Tic. A.Ş.", height: 0.05),
      Line("Ahmet Yılmaz", height: 0.06),
      Line("Satış Müdürü", height: 0.03),
      Line("Tel: +90 212 555 01 00  Faks: +90 212 555 01 01", height: 0.02),
      Line("GSM: 0532 123 45 67", height: 0.02),
      Line("Ahmet.Yilmaz@abcotomotiv.com.tr", height: 0.02),
      Line("www.abcotomotiv.com.tr", height: 0.02),
      Line("Atatürk Cad. No: 5 Kadıköy / İstanbul", height: 0.02),
    ]))
    XCTAssertEqual(draft.givenName, "Ahmet")
    XCTAssertEqual(draft.familyName, "Yılmaz")
    XCTAssertEqual(draft.organization, "ABC Otomotiv San. ve Tic. A.Ş.")
    XCTAssertEqual(draft.jobTitle, "Satış Müdürü")
    XCTAssertEqual(draft.phones, ["+90 212 555 01 00", "0532 123 45 67"], "the fax number is left out")
    XCTAssertEqual(draft.emails, ["ahmet.yilmaz@abcotomotiv.com.tr"])
    XCTAssertEqual(draft.websites, ["www.abcotomotiv.com.tr"])
  }

  func testAnEnglishCardInCapitals() throws {
    let draft = try XCTUnwrap(BusinessCardParser.parse([
      Line("JANE DOE", height: 0.07),
      Line("Head of Product", height: 0.03),
      Line("Northwind Technologies Inc.", height: 0.04),
      Line("M +1 (415) 555-0134 | jane@northwind.io", height: 0.02),
      Line("northwind.io", height: 0.02),
    ]))
    XCTAssertEqual(draft.fullName, "JANE DOE", "names keep the case printed on the card")
    XCTAssertEqual(draft.jobTitle, "Head of Product")
    XCTAssertEqual(draft.organization, "Northwind Technologies Inc.")
    XCTAssertEqual(draft.phones, ["+1 (415) 555-0134"])
    XCTAssertEqual(draft.emails, ["jane@northwind.io"])
    XCTAssertEqual(draft.websites, ["northwind.io"], "the e-mail's domain is not a second website")
  }

  func testAnHonorificIsNotANameAndAFaxIsNotAPhone() throws {
    let draft = try XCTUnwrap(BusinessCardParser.parse([
      Line("Dr. Ayşe Kaya", height: 0.06),
      Line("Faks: 0216 444 55 66", height: 0.02),
      Line("ayse@example.com", height: 0.02),
    ]))
    XCTAssertEqual(draft.givenName, "Ayşe")
    XCTAssertEqual(draft.familyName, "Kaya")
    XCTAssertTrue(draft.phones.isEmpty)
  }

  func testNumbersAreReadApartAndDatesAndIBANsAreNotPhones() {
    XCTAssertEqual(BusinessCardParser.phones(in: "GSM: 0532 123 45 67 / 0533 765 43 21"), ["0532 123 45 67", "0533 765 43 21"])
    XCTAssertEqual(BusinessCardParser.phones(in: "Tarih: 14.10.2026"), [])
    XCTAssertEqual(BusinessCardParser.phones(in: "IBAN TR12 0006 4000 0011 2345 6789 01"), [])
  }

  func testTextThatIsNotACardGivesNoDraft() {
    XCTAssertNil(BusinessCardParser.parse([Line("MİGROS", height: 0.05), Line("TOPLAM 123,45"), Line("KDV 12,34")]))
    XCTAssertNil(BusinessCardParser.parse([]))
  }

  func testTheDraftFillsIOSContactFields() {
    var draft = BusinessCardDraft()
    draft.givenName = "Ahmet"
    draft.familyName = "Yılmaz"
    draft.organization = "ABC A.Ş."
    draft.jobTitle = "Satış Müdürü"
    draft.phones = ["0532 123 45 67"]
    draft.emails = ["ahmet@abc.com.tr"]
    draft.websites = ["www.abc.com.tr"]
    let contact = draft.contact
    XCTAssertEqual(contact.givenName, "Ahmet")
    XCTAssertEqual(contact.familyName, "Yılmaz")
    XCTAssertEqual(contact.organizationName, "ABC A.Ş.")
    XCTAssertEqual(contact.jobTitle, "Satış Müdürü")
    XCTAssertEqual(contact.phoneNumbers.first?.value.stringValue, "0532 123 45 67")
    XCTAssertEqual(contact.emailAddresses.first.map { $0.value as String }, "ahmet@abc.com.tr")
    XCTAssertEqual(contact.urlAddresses.first.map { $0.value as String }, "www.abc.com.tr")
  }

  /// Someone else's details are not kept: half an hour, in memory only.
  func testTheDraftWaitsHalfAnHour() {
    let inbox = ContactDraftInbox.shared
    defer { inbox.clear() }
    let now = Date()
    var draft = BusinessCardDraft()
    draft.givenName = "Ada"
    draft.familyName = "Lovelace"
    inbox.offer(draft, now: now)
    XCTAssertEqual(inbox.current(now: now.addingTimeInterval(60)), draft)
    XCTAssertNil(inbox.current(now: now.addingTimeInterval(31 * 60)))
  }

  func testTheCommandIsSaidInPlainWords() {
    for text in ["Kartviziti oku", "Bu kartviziti rehbere ekle", "Jarvis, şu kartviziti tara", "Scan this business card"] {
      XCTAssertEqual(decide(text), .businessCard, text)
    }
    for text in ["Kartvizit nasıl tasarlanır?", "Kartvizit bastırmak istiyorum"] {
      XCTAssertNotEqual(decide(text), .businessCard, text)
    }
    XCTAssertEqual(ActionCatalog.definition(for: .businessCard)?.confirmation, .tapOnPhone)
  }

  /// Without a camera image nothing is read, and the trace keeps no words.
  func testWithoutACameraNothingIsRead() async {
    let defaults = UserDefaults.standard
    let previous = defaults.string(forKey: CaptureSource.defaultsKey)
    defaults.set(CaptureSource.off.rawValue, forKey: CaptureSource.defaultsKey)
    defer { defaults.set(previous, forKey: CaptureSource.defaultsKey) }
    ContactDraftInbox.shared.clear()
    let outcome = await AssistantOrchestrator.shared.runVoiceIntent(
      VoiceBridgeDecision(.businessCard, "test"), transcript: "Ahmet Yılmaz'ın kartvizitini oku")
    XCTAssertEqual(outcome.failed, "no image")
    XCTAssertNil(ContactDraftInbox.shared.current())
    XCTAssertFalse(ActionTraceLog.shared.entries.last?.transcript.contains("Ahmet") ?? true)
  }
}
