import XCTest

@testable import GlassifAI

@MainActor
final class AutoLoomLiveVisionTests: XCTestCase {

  func testAdaptiveIntervalFollowsThermalAndBattery() {
    XCTAssertEqual(LiveVisionPolicy.interval(thermal: .nominal, batteryLevel: 0.8, charging: false), 6)
    XCTAssertEqual(LiveVisionPolicy.interval(thermal: .fair, batteryLevel: -1, charging: false), 6,
                   "unknown battery level (simulator) does not slow down")
    XCTAssertEqual(LiveVisionPolicy.interval(thermal: .serious, batteryLevel: 0.8, charging: false), 15)
    XCTAssertEqual(LiveVisionPolicy.interval(thermal: .nominal, batteryLevel: 0.1, charging: false), 12)
    XCTAssertEqual(LiveVisionPolicy.interval(thermal: .nominal, batteryLevel: 0.1, charging: true), 6)
    XCTAssertNil(LiveVisionPolicy.interval(thermal: .critical, batteryLevel: 0.9, charging: true), "paused when critical")
  }

  func testUpdatesOnlyWhenTheSceneChangesOrForAHeartbeat() {
    XCTAssertTrue(LiveVisionPolicy.shouldUpdate(sceneDifference: nil, sinceLast: nil, interval: 6), "first note")
    XCTAssertFalse(LiveVisionPolicy.shouldUpdate(sceneDifference: 80, sinceLast: 3, interval: 6), "never faster than the interval")
    XCTAssertTrue(LiveVisionPolicy.shouldUpdate(sceneDifference: 30, sinceLast: 7, interval: 6), "view changed")
    XCTAssertFalse(LiveVisionPolicy.shouldUpdate(sceneDifference: 3, sinceLast: 20, interval: 6), "stable view is skipped")
    XCTAssertTrue(LiveVisionPolicy.shouldUpdate(sceneDifference: 3, sinceLast: 50, interval: 6), "occasional refresh")
  }

  func testVoiceCommandsParseToLiveVision() {
    XCTAssertEqual(DelegationEnvelopeParser.parse("TASK: live_vision_start")?.command, .liveVision(true))
    XCTAssertEqual(DelegationEnvelopeParser.parse("TASK: live_vision_stop | QUERY: stop")?.command, .liveVision(false))
    XCTAssertEqual(DelegationEnvelopeParser.parse(#"{"task":"keep_looking"}"#)?.command, .liveVision(true))
  }

  func testLiveVisionNeedsAConversationAndACameraAndNeverRunsHidden() async {
    let defaults = UserDefaults.standard
    let previous = defaults.string(forKey: CaptureSource.defaultsKey)
    defer { defaults.set(previous, forKey: CaptureSource.defaultsKey) }
    let controller = LiveVisionController.shared
    let savedVoice = controller.isVoiceActive
    defer { controller.isVoiceActive = savedVoice }

    defaults.set(CaptureSource.off.rawValue, forKey: CaptureSource.defaultsKey)
    controller.isVoiceActive = { true }
    XCTAssertTrue(controller.start().contains("camera is turned off"))
    XCTAssertFalse(controller.isActive)

    defaults.set(CaptureSource.iPhoneCamera.rawValue, forKey: CaptureSource.defaultsKey)
    controller.isVoiceActive = { false }
    XCTAssertTrue(controller.start().contains("during a voice conversation"))
    XCTAssertFalse(controller.isActive)

    controller.isVoiceActive = { true }
    XCTAssertTrue(controller.start().hasPrefix("Live vision is on"))
    XCTAssertTrue(controller.isActive)
    // The conversation ends: the next tick stops Live Vision on its own.
    controller.isVoiceActive = { false }
    let deadline = Date().addingTimeInterval(3)
    while controller.isActive && Date() < deadline {
      try? await Task.sleep(nanoseconds: 100_000_000)
    }
    XCTAssertFalse(controller.isActive)
    XCTAssertEqual(controller.lastStopReason, "conversation ended")
  }

  func testVoiceCommandIsHandledWithoutNetwork() async {
    let orchestrator = AssistantOrchestrator.shared
    let controller = LiveVisionController.shared
    let defaults = UserDefaults.standard
    let previous = defaults.string(forKey: CaptureSource.defaultsKey)
    let savedVoice = controller.isVoiceActive
    defer {
      controller.isVoiceActive = savedVoice
      defaults.set(previous, forKey: CaptureSource.defaultsKey)
    }
    defaults.set(CaptureSource.iPhoneCamera.rawValue, forKey: CaptureSource.defaultsKey)
    controller.isVoiceActive = { false }
    _ = orchestrator.beginVoiceSession()
    let delivered = expectation(description: "delivered")
    var reply = ""
    orchestrator.handleDelegation(handoffID: "test-live-\(UUID())", text: "TASK: live_vision_start") { text in
      reply = text
      delivered.fulfill()
      return true
    }
    await fulfillment(of: [delivered], timeout: 5)
    XCTAssertTrue(reply.contains("voice conversation"))
    orchestrator.endVoiceSession()
  }
}
