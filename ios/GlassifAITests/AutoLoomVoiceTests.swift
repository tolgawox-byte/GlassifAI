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

  func testWakePhraseMatchesTheNameAsAWord() {
    XCTAssertTrue(WakePhraseMatcher.contains(name: "Jarvis", in: "Hey Jarvis"))
    XCTAssertTrue(WakePhraseMatcher.contains(name: "Jarvis", in: "jarvis, what am I looking at?"))
    XCTAssertTrue(WakePhraseMatcher.contains(name: "Jarvis", in: "Jarvis şu an neye bakıyorum"))
    XCTAssertTrue(WakePhraseMatcher.contains(name: "Çağla", in: "hey cagla"), "accents are ignored")
    XCTAssertTrue(WakePhraseMatcher.contains(name: "Mr Loom", in: "okay mr loom start"))
    XCTAssertFalse(WakePhraseMatcher.contains(name: "Jarvis", in: "the jarvisian era"), "whole words only")
    XCTAssertFalse(WakePhraseMatcher.contains(name: "Nova", in: "casanova"))
    XCTAssertFalse(WakePhraseMatcher.contains(name: "Al", in: "al"), "names shorter than 3 letters are ignored")
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
