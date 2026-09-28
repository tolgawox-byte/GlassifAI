import QuartzCore
import XCTest

@testable import GlassifAI

/// The Ray-Ban connection state machine (registration, device, link,
/// permission, camera), its user-facing words and the animation states that
/// must follow the real state.
@MainActor
final class AutoLoomConnectionTests: XCTestCase {
  private func snapshot(
    registration: GlassesConnectionSnapshot.Registration = .registered,
    devices: Int = 1,
    link: GlassesConnectionSnapshot.Link = .connected,
    wanted: Bool = true,
    permission: GlassesConnectionSnapshot.Permission = .unknown,
    stream: GlassesConnectionSnapshot.Stream = .stopped,
    frames: Bool = false
  ) -> GlassesConnectionSnapshot {
    var value = GlassesConnectionSnapshot()
    value.sdkConfigured = true
    value.registration = registration
    value.deviceCount = devices
    value.link = link
    value.cameraWanted = wanted
    value.permission = permission
    value.stream = stream
    value.hasFrames = frames
    return value
  }

  private func phase(_ value: GlassesConnectionSnapshot) -> GlassesConnectionPhase {
    GlassesConnectionReducer.phase(for: value)
  }

  // MARK: Registration

  func testAnAlreadyRegisteredLaunchNeverShowsTheConnectScreen() {
    // Registered yesterday, glasses asleep today: wait for them, no Meta AI.
    let asleep = snapshot(link: .disconnected)
    XCTAssertEqual(phase(asleep), .deviceDisconnected)
    XCTAssertFalse(phase(asleep).needsSetupScreen)
    XCTAssertEqual(GlassesConnectionReducer.connectDecision(for: phase(asleep)), .refresh,
                   "a registered app looks for its glasses instead of registering again")

    // The SDK has not restored the registration yet in the first seconds.
    var launching = snapshot(registration: .available, devices: 0, link: .unknown)
    launching.restoring = true
    XCTAssertEqual(phase(launching), .restoring)
    XCTAssertFalse(phase(launching).needsSetupScreen)
    XCTAssertEqual(GlassesConnectionReducer.connectDecision(for: .restoring), .ignore)

    launching.restoring = false
    XCTAssertEqual(phase(launching), .notRegistered)
    XCTAssertTrue(phase(launching).needsSetupScreen)
    XCTAssertEqual(GlassesConnectionReducer.restoringGrace(wasRegistered: true), 6)
    XCTAssertEqual(GlassesConnectionReducer.restoringGrace(wasRegistered: false), 1.5)
  }

  func testRegistrationStepsAndDuplicateConnectPrevention() {
    var value = snapshot(registration: .available, devices: 0, link: .unknown)
    XCTAssertEqual(phase(value), .notRegistered)
    XCTAssertEqual(GlassesConnectionReducer.connectDecision(for: phase(value)), .startRegistration)

    value.registrationRequested = true
    XCTAssertEqual(phase(value), .registrationStarting)
    XCTAssertEqual(GlassesConnectionReducer.connectDecision(for: phase(value)), .ignore, "a second tap starts nothing")

    value.registration = .registering
    XCTAssertEqual(phase(value), .waitingForMetaAI)
    XCTAssertEqual(GlassesConnectionReducer.connectDecision(for: phase(value)), .ignore)

    value.registrationStalled = true
    XCTAssertEqual(phase(value), .registrationStalled)
    XCTAssertEqual(GlassesConnectionReducer.connectDecision(for: phase(value)), .startRegistration, "Try Again")
    XCTAssertTrue(GlassesConnectionReducer.status(for: phase(value)).showsTryAgain)

    value.registration = .registered
    value.registrationStalled = false
    value.registrationRequested = false
    XCTAssertEqual(phase(value), .registeredNoDevice)
    XCTAssertFalse(phase(value).needsSetupScreen)
    XCTAssertEqual(GlassesConnectionReducer.connectDecision(for: phase(value)), .refresh)
  }

  func testRegistrationDoesNotSpinForever() {
    let start = Date(timeIntervalSince1970: 1_000)
    // Meta AI never opened.
    XCTAssertFalse(GlassesConnectionReducer.registrationStalled(
      requestedAt: start, leftAppAt: nil, returnedAt: nil, now: start.addingTimeInterval(5)))
    XCTAssertTrue(GlassesConnectionReducer.registrationStalled(
      requestedAt: start, leftAppAt: nil, returnedAt: nil, now: start.addingTimeInterval(11)))
    // In Meta AI: no timeout while the user is there (until the total limit).
    let left = start.addingTimeInterval(2)
    XCTAssertFalse(GlassesConnectionReducer.registrationStalled(
      requestedAt: start, leftAppAt: left, returnedAt: nil, now: start.addingTimeInterval(60)))
    // Back in AutoLoom without the approval (cancelled or lost callback).
    let back = start.addingTimeInterval(20)
    XCTAssertFalse(GlassesConnectionReducer.registrationStalled(
      requestedAt: start, leftAppAt: left, returnedAt: back, now: back.addingTimeInterval(5)))
    XCTAssertTrue(GlassesConnectionReducer.registrationStalled(
      requestedAt: start, leftAppAt: left, returnedAt: back, now: back.addingTimeInterval(13)))
    XCTAssertTrue(GlassesConnectionReducer.registrationStalled(
      requestedAt: start, leftAppAt: left, returnedAt: nil, now: start.addingTimeInterval(121)))
  }

  // MARK: Devices and link

  func testDeviceAndLinkStates() {
    XCTAssertEqual(phase(snapshot(devices: 0, link: .unknown)), .registeredNoDevice)
    XCTAssertEqual(phase(snapshot(link: .disconnected)), .deviceDisconnected)
    XCTAssertEqual(phase(snapshot(link: .connecting)), .deviceConnecting)
    XCTAssertEqual(phase(snapshot(link: .connected, wanted: false)), .deviceConnected)

    // The SDK's device selector alone is enough to know the glasses are there.
    var selected = snapshot(link: .unknown, wanted: false)
    selected.activeDevice = true
    XCTAssertEqual(phase(selected), .deviceConnected)

    // Disconnect and reconnect: back to connected without registering again.
    let dropped = phase(snapshot(link: .disconnected))
    XCTAssertFalse(dropped.isLinked)
    XCTAssertEqual(GlassesConnectionReducer.status(for: dropped).title, L.t("Wake your glasses", "Gözlüğünü uyandır"))
    XCTAssertTrue(phase(snapshot(link: .connected, stream: .waiting)).isLinked)
  }

  // MARK: Camera

  func testTheCameraStartsOnlyAfterTheGlassesAreLinked() {
    // Not linked: the camera state does not matter yet.
    XCTAssertEqual(phase(snapshot(link: .disconnected, permission: .granted)), .deviceDisconnected)
    // Linked: permission, then start, then streaming, then frames.
    XCTAssertEqual(phase(snapshot(permission: .checking)), .requestingCameraPermission)
    XCTAssertEqual(phase(snapshot(permission: .requesting)), .requestingCameraPermission)
    XCTAssertEqual(phase(snapshot(permission: .denied)), .cameraPermissionNeeded)
    XCTAssertEqual(phase(snapshot(permission: .granted)), .startingCamera)
    XCTAssertEqual(phase(snapshot(permission: .granted, stream: .waiting)), .startingCamera)
    XCTAssertEqual(phase(snapshot(permission: .granted, stream: .streaming)), .cameraStreaming)
    XCTAssertEqual(phase(snapshot(permission: .granted, stream: .streaming, frames: true)), .ready)
  }

  func testACameraOrCodecFailureIsNotAConnectionFailure() {
    var failed = snapshot(permission: .granted)
    failed.cameraFailure = "start timeout"
    XCTAssertEqual(phase(failed), .cameraFailed)
    XCTAssertTrue(phase(failed).isLinked, "the glasses stay connected when only the video transport fails")
    let status = GlassesConnectionReducer.status(for: .cameraFailed)
    XCTAssertEqual(status.title, L.t("Ray-Ban Connected", "Ray-Ban bağlı"))
    XCTAssertTrue(status.showsTryAgain)
    XCTAssertEqual(status.tone, .attention)
  }

  func testRetriesBackOffAndStayBounded() {
    let delays = (0...12).map { GlassesConnectionReducer.retryDelay(afterFailures: $0) }
    XCTAssertEqual(delays.first, 1)
    XCTAssertEqual(delays.last, 30)
    XCTAssertEqual(delays, delays.sorted(), "never shorter after more failures")
    XCTAssertEqual(delays.max(), 30, "no busy loop, no unbounded wait")
    XCTAssertEqual(GlassesConnectionReducer.retryDelay(afterFailures: -3), 1)
  }

  // MARK: What the user sees

  func testEveryPhaseHasPlainWords() {
    for phase in GlassesConnectionPhase.allCases {
      let status = GlassesConnectionReducer.status(for: phase)
      XCTAssertFalse(status.title.isEmpty, phase.rawValue)
      XCTAssertFalse(status.title.contains("_"), "no enum names on screen: \(phase.rawValue)")
    }
    let sdk = GlassesConnectionReducer.status(for: .sdkUnavailable)
    XCTAssertEqual(sdk.tone, .attention)
    XCTAssertFalse(sdk.showsTryAgain)
    XCTAssertTrue(GlassesConnectionReducer.status(for: .cameraPermissionNeeded).showsTryAgain)
    XCTAssertEqual(GlassesConnectionReducer.status(for: .ready).tone, .connected)
    XCTAssertEqual(GlassesConnectionReducer.status(for: .deviceConnecting).tone, .working)
  }

  func testAnimationsFollowTheRealState() {
    for phase in GlassesConnectionPhase.allCases where phase != .ready {
      XCTAssertNotEqual(GlassesLinkVisual.from(phase), .connected, "never 'connected' before frames: \(phase.rawValue)")
    }
    XCTAssertEqual(GlassesLinkVisual.from(.ready), .connected)
    XCTAssertEqual(GlassesLinkVisual.from(.startingCamera), .found)
    XCTAssertEqual(GlassesLinkVisual.from(.deviceConnecting), .searching)
    XCTAssertEqual(GlassesLinkVisual.from(.waitingForMetaAI), .searching)
    XCTAssertEqual(GlassesLinkVisual.from(.deviceDisconnected), .idle)
    XCTAssertEqual(GlassesLinkVisual.from(.cameraFailed), .attention)

    // The orb: nothing looks like listening before the audio is ready, and
    // nothing looks like saving after a failure.
    XCTAssertEqual(AssistantPresence.resolve(state: .connecting, activity: nil, muted: false).mood, .connecting)
    XCTAssertEqual(AssistantPresence.resolve(state: .listening, activity: nil, muted: false).mood, .listening)
    XCTAssertEqual(AssistantPresence.resolve(state: .failed("x"), activity: .saving, muted: false).mood, .error)
    XCTAssertEqual(AssistantPresence.resolve(state: .thinking, activity: .saving, muted: false).mood, .saving)
    XCTAssertEqual(AssistantPresence.resolve(state: .thinking, activity: .seeing, muted: false).mood, .looking)
    XCTAssertEqual(AssistantPresence.resolve(state: .thinking, activity: .searching, muted: false).mood, .searching)
  }

  // MARK: Configuration and levels

  func testConfigurationAuditNeverShowsSecretsAndFindsABrokenCallback() {
    let mwdat: [String: Any] = [
      "AppLinkURLScheme": "glassifai://",
      "MetaAppID": "0",
      "ClientToken": "AR|123456789|abcdef",
      "TeamID": "",
      "Analytics": ["OptOut": true],
    ]
    let info: [String: Any] = [
      "CFBundleURLTypes": [["CFBundleURLSchemes": ["glassifai"]]],
      "MWDAT": mwdat,
    ]
    let audit = DATConfigurationAudit.audit(info, bundleIdentifier: "com.example.test")
    XCTAssertTrue(audit.problems.isEmpty, audit.problems.joined(separator: "; "))
    XCTAssertEqual(audit.metaAppID, "0 (Developer Mode)")
    XCTAssertEqual(audit.teamID, "empty")
    XCTAssertTrue(audit.analyticsOptOut)
    XCTAssertFalse(audit.summary.contains("123456789"), "token values never appear")
    XCTAssertFalse(audit.clientToken.contains("abcdef"))

    var broken = info
    broken["CFBundleURLTypes"] = [["CFBundleURLSchemes": ["other"]]]
    XCTAssertFalse(DATConfigurationAudit.audit(broken, bundleIdentifier: "x").problems.isEmpty,
                   "Meta AI could not call back")
    XCTAssertEqual(DATConfigurationAudit.audit([:], bundleIdentifier: "x").problems, ["MWDAT AppLinkURLScheme is missing"])
  }

  func testAudioLevelsAreSmoothedAndFallBackToSilence() {
    XCTAssertEqual(AudioLevelMeter.displayLevel(0), 0)
    XCTAssertEqual(AudioLevelMeter.displayLevel(1), 1)
    XCTAssertGreaterThan(AudioLevelMeter.displayLevel(0.05), AudioLevelMeter.displayLevel(0.01))
    let meter = AudioLevelMeter()
    let now = CACurrentMediaTime()
    meter.update(input: 0.2, output: nil)
    _ = meter.level(.input, now: now)
    let rising = meter.level(.input, now: now + 0.2)
    XCTAssertGreaterThan(rising, 0.3)
    // No sample for a second: back towards silence.
    let later = meter.level(.input, now: now + 3)
    XCTAssertLessThan(later, rising)
  }
}
