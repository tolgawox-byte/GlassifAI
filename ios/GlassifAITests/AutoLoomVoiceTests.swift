import XCTest

@testable import GlassifAI

final class AutoLoomVoiceTests: XCTestCase {

  func testReconnectBudgetPreventsLoops() {
    var policy = RealtimeReconnectPolicy()
    let start = Date()
    for attempt in 0..<RealtimeReconnectPolicy.maxReconnects {
      XCTAssertTrue(policy.allowsReconnect(now: start.addingTimeInterval(Double(attempt))))
      policy.record(start.addingTimeInterval(Double(attempt)))
    }
    XCTAssertFalse(policy.allowsReconnect(now: start.addingTimeInterval(10)), "no endless reconnect loop")
    XCTAssertTrue(
      policy.allowsReconnect(now: start.addingTimeInterval(RealtimeReconnectPolicy.window + 5)),
      "a later, separate failure may reconnect again")
  }

  @MainActor
  func testInterruptionWordsAreInTheVoiceInstructions() {
    let text = AssistantInstructions.realtime(memory: [], assistantName: "Jarvis")
    for word in ["\"dur\"", "\"bekle\"", "\"hayır\"", "\"başka bir şey soracağım\""] {
      XCTAssertTrue(text.contains(word), word)
    }
    XCTAssertTrue(text.contains("[Live view"), "live notes are explained to the voice model")
  }
}
