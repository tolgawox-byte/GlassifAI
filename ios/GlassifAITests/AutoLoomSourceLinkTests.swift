import Foundation
import XCTest

@testable import GlassifAI

/// Research idea D2-02: a reminder or event made from an AutoLoom note links
/// back to it, and opening such a link only shows the item.
@MainActor
final class AutoLoomSourceLinkTests: XCTestCase {
  func testALinkNamesOneItemAndNothingElse() throws {
    let id = UUID()
    let url = try XCTUnwrap(SourceLink.url("note", id))
    XCTAssertEqual(url.absoluteString, "glassifai://item/note/\(id.uuidString)")
    XCTAssertEqual(SourceLink.parse(url)?.domain, "note")
    XCTAssertEqual(SourceLink.parse(url)?.id, id)
    XCTAssertNil(SourceLink.url("contact", id), "only AutoLoom's own items")
    let others = [
      "glassifai://?metaWearablesAction=register",
      "glassifai://item/note/not-a-uuid",
      "glassifai://item/contact/\(id.uuidString)",
      "glassifai://item/note/\(id.uuidString)?run=delete",
      "glassifai://item/note/\(id.uuidString)/extra",
      "jarvis-pc://item/note/\(id.uuidString)",
      "https://item/note/\(id.uuidString)",
    ]
    for other in others {
      let link = try XCTUnwrap(URL(string: other), other)
      XCTAssertNil(SourceLink.parse(link), other)
    }
  }

  func testAReminderMadeFromTheNoteJustSavedLinksBack() {
    let note = UUID()
    let now = Date()
    let saved: (text: String, at: Date, noteID: UUID?) = (
      "Lastik basıncını kontrol et. Ön lastikler 32 psi.", now.addingTimeInterval(-30), note)
    let title = VoiceActionIntentBridge.shortTitle(saved.text)
    XCTAssertEqual(AssistantOrchestrator.linkedNote(title: title, saved: saved, now: now), note)
    XCTAssertNil(AssistantOrchestrator.linkedNote(title: "Başka bir şey", saved: saved, now: now), "another title")
    XCTAssertNil(
      AssistantOrchestrator.linkedNote(title: title, saved: saved, now: now.addingTimeInterval(601)), "ten minutes later")
    let memory: (text: String, at: Date, noteID: UUID?) = (saved.text, saved.at, nil)
    XCTAssertNil(AssistantOrchestrator.linkedNote(title: title, saved: memory, now: now), "a memory is not a note")
  }

  /// Recognised and shown, nothing else: no action waits afterwards.
  func testOpeningALinkOnlyNavigates() throws {
    let orchestrator = AssistantOrchestrator.shared
    orchestrator.clearPendingActions()
    let url = try XCTUnwrap(SourceLink.url("note", UUID()))
    XCTAssertTrue(SourceLink.open(url))
    XCTAssertNil(orchestrator.pendingAction)
    let meta = try XCTUnwrap(URL(string: "glassifai://?metaWearablesAction=register"))
    XCTAssertFalse(SourceLink.open(meta), "Meta's callbacks still reach the glasses connection")
  }
}
