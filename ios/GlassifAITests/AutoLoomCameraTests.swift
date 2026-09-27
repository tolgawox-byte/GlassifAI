import XCTest

@testable import GlassifAI

/// Ray-Ban stream configuration and transport fallback (DAT 0.5).
final class AutoLoomCameraTests: XCTestCase {

  func testProfilesRequestFullResolutionAndDocumentedFrameRates() {
    // Meta DAT accepts 2, 7, 15, 24 or 30 fps.
    let allowed: Set<UInt> = [2, 7, 15, 24, 30]
    for profile in GlassesStreamProfile.allCases {
      XCTAssertTrue(allowed.contains(profile.frameRate), profile.rawValue)
    }
    XCTAssertEqual(GlassesStreamProfile.recommended, .sharp)
    XCTAssertEqual(GlassesStreamProfile.sharp.requestedSummary, "720×1280 @ 15 fps")
    XCTAssertEqual(GlassesStreamProfile.maxDetail.requestedSummary, "720×1280 @ 7 fps")
    XCTAssertEqual(GlassesStreamProfile.balanced.requestedSummary, "720×1280 @ 24 fps", "the original configuration")
    XCTAssertEqual(GlassesStreamProfile.smooth.requestedSummary, "504×896 @ 30 fps")
    // Existing stored values keep working.
    XCTAssertEqual(GlassesStreamProfile(rawValue: "balanced"), .balanced)
    XCTAssertEqual(GlassesStreamProfile(rawValue: "sharp"), .sharp)
    XCTAssertEqual(GlassesStreamProfile(rawValue: "smooth"), .smooth)
  }

  func testDefaultProfileAndTransportWhenNothingIsStored() {
    let defaults = UserDefaults.standard
    let savedProfile = defaults.object(forKey: GlassesStreamProfile.defaultsKey)
    let savedTransport = defaults.object(forKey: GlassesVideoTransport.defaultsKey)
    defer {
      defaults.set(savedProfile, forKey: GlassesStreamProfile.defaultsKey)
      defaults.set(savedTransport, forKey: GlassesVideoTransport.defaultsKey)
    }
    defaults.removeObject(forKey: GlassesStreamProfile.defaultsKey)
    defaults.removeObject(forKey: GlassesVideoTransport.defaultsKey)
    XCTAssertEqual(GlassesStreamProfile.current, .sharp)
    XCTAssertEqual(GlassesVideoTransport.preferred, .hevc)
    defaults.set("raw", forKey: GlassesVideoTransport.defaultsKey)
    XCTAssertEqual(GlassesVideoTransport.preferred, .raw)
  }

  func testWatchdogKeepsWorkingHEVCStreams() {
    XCTAssertNil(GlassesTransportWatchdog.fallbackReason(
      compressedSamples: 120, decodedFrames: 118, decodeFailures: 2, rawSamples: 0))
    XCTAssertNil(GlassesTransportWatchdog.fallbackReason(
      compressedSamples: 0, decodedFrames: 0, decodeFailures: 0, rawSamples: 90),
      "the SDK delivered decoded frames, nothing to fix")
  }

  func testWatchdogFallsBackWhenHEVCYieldsNoFrames() {
    let undecodable = GlassesTransportWatchdog.fallbackReason(
      compressedSamples: 100, decodedFrames: 0, decodeFailures: 100, rawSamples: 0)
    XCTAssertNotNil(undecodable)
    XCTAssertTrue(undecodable?.contains("none decoded") == true)
    let silent = GlassesTransportWatchdog.fallbackReason(
      compressedSamples: 0, decodedFrames: 0, decodeFailures: 0, rawSamples: 0)
    XCTAssertNotNil(silent)
  }

  func testWatchdogCounterDeltaSurvivesStoreReset() {
    XCTAssertEqual(GlassesTransportWatchdog.delta(50, since: 20), 30)
    XCTAssertEqual(GlassesTransportWatchdog.delta(7, since: 20), 7, "counters were reset in between")
  }
}
