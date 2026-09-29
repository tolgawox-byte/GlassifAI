import Foundation
import XCTest

@testable import GlassifAI

/// Documents, receipts and translation: read on the phone, amounts and
/// dates exact, nothing acted on without a yes, languages by their words.
@MainActor
final class AutoLoomDocumentsTranslationTests: XCTestCase {
  private func decide(_ text: String, _ tags: Set<String> = []) -> VoiceIntent? {
    VoiceActionIntentBridge.decide(text, context: AutoLoomActionCatalogTests.context(for: tags))?.intent
  }

  func testReceiptAmountsDatesAndTotalAreExact() throws {
    let text = "MIGROS\nKadıköy\n28.09.2026 18:42\nSüt 34,90\nEkmek 12,50\nTOPLAM 47,40 TL\nTel: 0216 555 12 34"
    let record = DocumentExtractor.record(from: text, kind: .receipt)
    XCTAssertEqual(record.merchant, "MIGROS")
    XCTAssertEqual(record.total, MoneyAmount(value: try XCTUnwrap(Decimal(string: "47.40")), currency: "TRY"))
    XCTAssertEqual(record.amounts.count, 3, "times, dates and phone numbers are not money")
    let components = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: try XCTUnwrap(record.dates.first))
    XCTAssertEqual(components.day, 28)
    XCTAssertEqual(components.month, 9)
  }

  func testNumberFormats() {
    XCTAssertEqual(DocumentExtractor.decimal("1.250,00"), Decimal(string: "1250.00"))
    XCTAssertEqual(DocumentExtractor.decimal("1,250.00"), Decimal(string: "1250.00"))
    XCTAssertEqual(DocumentExtractor.decimal("4250"), Decimal(4250))
    XCTAssertEqual(DocumentExtractor.amounts(in: "Total $45.99").first?.currency, "$")
    XCTAssertEqual(DocumentExtractor.amounts(in: "Amount due: CAD 120.00").first?.currency, "CAD")
    XCTAssertTrue(DocumentExtractor.amounts(in: "Kod A12 · 2026").isEmpty)
    let document = DocumentExtractor.record(
      from: "Sigorta poliçesi yenileme bildirimi\nSon ödeme tarihi: 15.10.2026\nTutar: 4.250,00 TL", kind: .document)
    XCTAssertEqual(document.total?.value, Decimal(string: "4250.00"))
    XCTAssertEqual(document.dates.count, 1)
    XCTAssertNil(document.merchant, "only receipts have a store")
  }

  func testSpendingIsOnlyWhatWasSaved() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("docs-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = DocumentStore(directory: directory)
    store.add(DocumentExtractor.record(from: "A101\nTOPLAM 20,00 TL", kind: .receipt))
    store.add(DocumentExtractor.record(from: "BIM\nTOPLAM 5,50 TL", kind: .receipt))
    store.add(DocumentExtractor.record(from: "Costco\nTOTAL $12.00", kind: .receipt))
    store.add(DocumentExtractor.record(from: "Mektup\nTutar 999,00 TL", kind: .document))
    let totals = store.monthTotals()
    XCTAssertEqual(totals.first { $0.currency == "TRY" }?.value, Decimal(string: "25.50"), "documents are not spending")
    XCTAssertEqual(totals.first { $0.currency == "$" }?.value, Decimal(string: "12.00"))
    XCTAssertEqual(DocumentStore(directory: directory).records.count, 4, "kept on disk")
  }

  func testDocumentPhrases() {
    XCTAssertEqual(decide("Bu belgeyi özetle"), .document(.summarize))
    XCTAssertEqual(decide("Fişi kaydet"), .document(.saveReceipt))
    XCTAssertEqual(decide("Bu faturayı kaydet"), .document(.saveReceipt))
    XCTAssertEqual(decide("Bu ay ne harcadım?"), .document(.spending))
    XCTAssertEqual(decide("How much did I spend this month?"), .document(.spending))
  }

  func testLanguagesByTheirWords() async {
    XCTAssertEqual(SpokenLanguage.code(for: "Türkçeye"), "tr")
    XCTAssertEqual(SpokenLanguage.code(for: "İngilizce"), "en")
    XCTAssertEqual(SpokenLanguage.code(for: "Almancaya"), "de")
    XCTAssertEqual(SpokenLanguage.code(for: "German"), "de")
    XCTAssertNil(SpokenLanguage.code(for: "bunu"))
    let same = await LocalTranslator.translate("Hello, how are you today? This is a test sentence.", to: "en")
    XCTAssertEqual(same, .sameLanguage(source: "en"))
    XCTAssertEqual(TranslationView.describe(.unavailable, language: "tr").isEmpty, false)
  }
}
