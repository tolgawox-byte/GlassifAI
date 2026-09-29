import Foundation
import XCTest

@testable import GlassifAI

/// Remote Assist: never starts from words alone, stops at once, the room
/// code is compared safely.
@MainActor
final class AutoLoomRemoteAssistTests: XCTestCase {
  private func decide(_ text: String) -> VoiceIntent? {
    VoiceActionIntentBridge.decide(text, context: AutoLoomActionCatalogTests.context(for: []))?.intent
  }

  func testPhrases() {
    XCTAssertEqual(decide("Uzaktan yardımı başlat"), .remoteAssist(start: true))
    XCTAssertEqual(decide("Görüntümü paylaş"), .remoteAssist(start: true))
    XCTAssertEqual(decide("Paylaşımı durdur"), .remoteAssist(start: false))
    XCTAssertEqual(decide("Stop sharing"), .remoteAssist(start: false))
    XCTAssertEqual(decide("Kaydı durdur"), .stopRecording, "recording keeps its own words")
  }

  func testWordsNeverStartSharing() {
    let server = RemoteAssistServer.shared
    let start = AssistantOrchestrator.shared.runRemoteAssist(start: true, traceID: UUID())
    XCTAssertFalse(server.isSharing, "only the Start button shares")
    XCTAssertTrue(start.spoken.contains("tap Start"))
    let stop = AssistantOrchestrator.shared.runRemoteAssist(start: false, traceID: UUID())
    XCTAssertFalse(server.isSharing)
    XCTAssertTrue(stop.reply.isEmpty == false)
  }

  func testSharingNeedsTheCameraAndCodesCompareSafely() {
    let server = RemoteAssistServer.shared
    if !MediaResourceCoordinator.shared.isActive(.cameraStream) {
      XCTAssertNotNil(server.start(), "no camera stream, no sharing")
      XCTAssertFalse(server.isSharing)
    }
    XCTAssertTrue(RemoteAssistHub.constantTimeEqual("482913", "482913"))
    XCTAssertFalse(RemoteAssistHub.constantTimeEqual("482913", "482914"))
    XCTAssertFalse(RemoteAssistHub.constantTimeEqual("4829", "482913"))
    XCTAssertTrue(RemoteAssistHub.page.contains("/stream?code="))
    XCTAssertEqual(RemoteAssistServer.stopSentence(.background).0.isEmpty, false)
  }
}
