import CoreBluetooth
import CoreMedia
import CoreVideo
import Foundation
import MWDATCore
import XCTest

@testable import GlassifAI

/// The Ray-Ban connection on Meta DAT 1.0.1: every layer reported on its own
/// (Bluetooth, versions, the device session, the camera), glasses that refuse
/// sessions, the signing of a sideloaded build, and how smoothly frames
/// arrive. None of this needs glasses; the device tests are in
/// `docs/RAYBAN_CONNECTION.md`.
@MainActor
final class AutoLoomRayBanDAT1Tests: XCTestCase {
  private func linked(
    wanted: Bool = true,
    permission: GlassesConnectionSnapshot.Permission = .granted,
    session: GlassesConnectionSnapshot.Session = .none,
    stream: GlassesConnectionSnapshot.Stream = .stopped,
    problem: GlassesSessionProblem? = nil
  ) -> GlassesConnectionSnapshot {
    var value = GlassesConnectionSnapshot()
    value.sdkConfigured = true
    value.registration = .registered
    value.deviceCount = 1
    value.link = .connected
    value.bluetooth = .ready
    value.cameraWanted = wanted
    value.permission = permission
    value.session = session
    value.stream = stream
    value.sessionProblem = problem
    return value
  }

  private func phase(_ value: GlassesConnectionSnapshot) -> GlassesConnectionPhase {
    GlassesConnectionReducer.phase(for: value)
  }

  // MARK: Layers kept apart

  func testBluetoothOffOrNotAllowedIsNotSleepingGlasses() {
    var value = linked()
    value.link = .disconnected
    value.bluetooth = .poweredOff
    XCTAssertEqual(phase(value), .bluetoothUnavailable)
    value.bluetooth = .denied
    XCTAssertEqual(phase(value), .bluetoothUnavailable)
    XCTAssertTrue(GlassesConnectionPhase.bluetoothUnavailable.needsUserAction)
    XCTAssertFalse(GlassesConnectionPhase.bluetoothUnavailable.isLinked)
    // Not asked yet, or unknown: still the usual wait for the glasses.
    value.bluetooth = .notDetermined
    XCTAssertEqual(phase(value), .deviceDisconnected)
    value.bluetooth = .unknown
    XCTAssertEqual(phase(value), .deviceDisconnected)
    // A link that is up wins over a stale Bluetooth reading.
    var up = linked(wanted: false)
    up.bluetooth = .poweredOff
    XCTAssertEqual(phase(up), .deviceConnected)
  }

  func testBluetoothStatesFromCoreBluetooth() {
    XCTAssertEqual(BluetoothAccess.from(authorization: .denied, state: nil), .denied)
    XCTAssertEqual(BluetoothAccess.from(authorization: .restricted, state: .poweredOn), .denied)
    XCTAssertEqual(BluetoothAccess.from(authorization: .notDetermined, state: nil), .notDetermined)
    XCTAssertEqual(BluetoothAccess.from(authorization: .allowedAlways, state: .poweredOn), .ready)
    XCTAssertEqual(BluetoothAccess.from(authorization: .allowedAlways, state: .poweredOff), .poweredOff)
    XCTAssertEqual(BluetoothAccess.from(authorization: .allowedAlways, state: .unsupported), .unsupported)
    XCTAssertEqual(BluetoothAccess.from(authorization: .allowedAlways, state: nil), .unknown)
    XCTAssertTrue(BluetoothAccess.poweredOff.blocksLink)
    XCTAssertFalse(BluetoothAccess.notDetermined.blocksLink, "the SDK asks for it when it needs it")
  }

  func testVersionsBlockEverythingAfterTheLinkAndSayWhoMustAct() {
    var appTooOld = linked()
    appTooOld.compatibilityIssue = .appUpdate
    XCTAssertEqual(phase(appTooOld), .appUpdateRequired)
    XCTAssertEqual(phase(linked(problem: .sdkTooOld)), .appUpdateRequired)
    XCTAssertFalse(GlassesConnectionReducer.status(for: .appUpdateRequired).showsTryAgain,
                   "only a newer AutoLoom build helps")

    var firmware = linked(wanted: false)
    firmware.compatibilityIssue = .glassesUpdate
    XCTAssertEqual(phase(firmware), .glassesUpdateRequired, "even with the iPhone camera chosen")
    XCTAssertEqual(phase(linked(problem: .glassesAppUpdateRequired)), .glassesUpdateRequired)
    XCTAssertTrue(GlassesConnectionReducer.status(for: .glassesUpdateRequired).showsTryAgain)

    for blocked in [GlassesConnectionPhase.appUpdateRequired, .glassesUpdateRequired] {
      XCTAssertTrue(blocked.isLinked, "the glasses are linked; only the versions do not match")
      XCTAssertTrue(blocked.needsUserAction)
      XCTAssertEqual(GlassesLinkVisual.from(blocked), .attention)
      XCTAssertEqual(GlassesConnectionReducer.connectDecision(for: blocked), .refresh, "never registers again")
    }
  }

  func testTheDeviceSessionIsItsOwnStep() {
    XCTAssertEqual(phase(linked(session: .starting, stream: .waiting)), .startingSession)
    XCTAssertEqual(phase(linked(session: .started, stream: .waiting)), .startingCamera)
    XCTAssertEqual(phase(linked(session: .paused, stream: .waiting)), .sessionPaused)
    XCTAssertEqual(phase(linked(session: .paused)), .sessionPaused)
    XCTAssertEqual(phase(linked(session: .started, stream: .streaming)), .cameraStreaming)
    var frames = linked(session: .started, stream: .streaming)
    frames.hasFrames = true
    XCTAssertEqual(phase(frames), .ready)
    XCTAssertFalse(GlassesConnectionReducer.status(for: .sessionPaused).showsTryAgain,
                   "a temple tap resumes it; nothing to retry")
    XCTAssertEqual(GlassesLinkVisual.from(.startingSession), .found)
  }

  func testRefusingGlassesAskForAPowerCycleAndStopRetrying() {
    let refusing = linked(problem: .refusing(count: 3))
    XCTAssertEqual(phase(refusing), .glassesRefusing)
    let status = GlassesConnectionReducer.status(for: .glassesRefusing)
    XCTAssertTrue(status.showsTryAgain)
    XCTAssertTrue(status.detail?.isEmpty == false)
    XCTAssertTrue(GlassesSessionProblem.refusing(count: 3).blocksAutomaticRetry, "no busy attempts")
    XCTAssertFalse(GlassesSessionProblem.glassesAppUnavailable.blocksAutomaticRetry)
    XCTAssertEqual(phase(linked(problem: .glassesAppUnavailable)), .glassesAppUnavailable)
    // A stream that runs is the proof the problem is over.
    var streaming = linked(stream: .streaming, problem: .refusing(count: 3))
    streaming.hasFrames = true
    XCTAssertEqual(phase(streaming), .ready)
  }

  func testSessionFailuresAreNotCollapsedIntoOneState() {
    let refusal = GlassesSessionFailure.unexpected("Device unavailable")
    XCTAssertTrue(refusal.isRefusal)
    XCTAssertTrue(GlassesSessionFailure.unexpected("Session ended by device").isRefusal)
    XCTAssertFalse(GlassesSessionFailure.unexpected("timeout").isRefusal)
    XCTAssertFalse(GlassesSessionFailure.noEligibleDevice.isRefusal)

    // Refusals count up to the limit in the window; one or two may be bad luck.
    let limit = GlassesSessionProblemPolicy.refusalLimit
    XCTAssertNil(GlassesSessionProblemPolicy.problem(after: refusal, refusalsInWindow: limit - 1))
    XCTAssertEqual(GlassesSessionProblemPolicy.problem(after: refusal, refusalsInWindow: limit), .refusing(count: limit))
    XCTAssertGreaterThan(GlassesSessionProblemPolicy.refusalWindow, 60)

    // Each version error keeps its own meaning (Meta: do not collapse them).
    XCTAssertEqual(GlassesSessionProblemPolicy.problem(after: .sdkTooOld, refusalsInWindow: 0), .sdkTooOld)
    XCTAssertEqual(GlassesSessionProblemPolicy.problem(after: .glassesAppUpdateRequired, refusalsInWindow: 0),
                   .glassesAppUpdateRequired)
    XCTAssertEqual(GlassesSessionProblemPolicy.problem(after: .glassesAppUnavailable, refusalsInWindow: 0),
                   .glassesAppUnavailable)
    XCTAssertEqual(GlassesSessionProblemPolicy.problem(after: .versionWarning, refusalsInWindow: 0), .versionWarning)
    XCTAssertNil(GlassesSessionProblemPolicy.problem(after: .noEligibleDevice, refusalsInWindow: 0),
                 "glasses that are away are a wait, not a problem")
    XCTAssertNil(GlassesSessionProblemPolicy.problem(after: .appState("session already exists"), refusalsInWindow: 0))

    // A started session clears everything except the non-blocking warning.
    XCTAssertTrue(GlassesSessionProblem.refusing(count: 3).clearsWhenASessionStarts)
    XCTAssertFalse(GlassesSessionProblem.versionWarning.clearsWhenASessionStarts)
    XCTAssertFalse(GlassesSessionProblem.versionWarning.blocksAutomaticRetry, "the session can go on")
  }

  func testEveryNewPhaseHasPlainWordsAndNoFalseConnectedNotice() {
    let new: [GlassesConnectionPhase] = [
      .bluetoothUnavailable, .appUpdateRequired, .glassesUpdateRequired, .startingSession, .sessionPaused,
      .glassesAppUnavailable, .glassesRefusing,
    ]
    for phase in new {
      let status = GlassesConnectionReducer.status(for: phase)
      XCTAssertFalse(status.title.isEmpty, phase.rawValue)
      XCTAssertFalse(status.title.contains("_"), phase.rawValue)
      XCTAssertNotEqual(GlassesLinkVisual.from(phase), .connected, "never 'connected' before frames: \(phase.rawValue)")
    }
    // Problems never get the "✓ Ray-Ban Connected" confirmation.
    for phase in [GlassesConnectionPhase.appUpdateRequired, .glassesUpdateRequired, .glassesAppUnavailable, .glassesRefusing] {
      XCTAssertTrue(phase.needsUserAction, phase.rawValue)
    }
    XCTAssertFalse(GlassesConnectionPhase.ready.needsUserAction)
    XCTAssertFalse(GlassesConnectionPhase.startingSession.needsUserAction)
  }

  // MARK: Gestures follow the camera's session

  func testGesturesIgnoreTheAppsOwnStop() {
    var interpreter = GlassesGestureInterpreter()
    XCTAssertNil(interpreter.receive(.started))
    XCTAssertEqual(interpreter.receive(.paused), .toggleMicrophoneMute)
    XCTAssertEqual(interpreter.receive(.started), .toggleMicrophoneMute)
    XCTAssertNil(interpreter.receive(.stopped, byApp: true), "a camera switch never hangs up")
    XCTAssertNil(interpreter.receive(.started))
    XCTAssertEqual(interpreter.receive(.stopped, byApp: false), .endCall)
  }

  // MARK: The installed build

  func testABundleIdentifierWithADashIsReported() {
    let info: [String: Any] = [
      "CFBundleURLTypes": [["CFBundleURLSchemes": ["glassifai"]]],
      "MWDAT": ["AppLinkURLScheme": "glassifai://", "MetaAppID": "0"],
    ]
    XCTAssertTrue(DATConfigurationAudit.audit(info, bundleIdentifier: "com.marcoiannello.GlassifAI").warnings.isEmpty)
    let resigned = DATConfigurationAudit.audit(info, bundleIdentifier: "com.example-team.GlassifAI")
    XCTAssertEqual(resigned.warnings.count, 1)
    XCTAssertTrue(resigned.problems.isEmpty, "a warning, not a broken callback")
  }

  func testTheSigningProfileIsReadWithoutIdentifiers() throws {
    let expiry = Date(timeIntervalSinceNow: 5 * 86_400 + 3_600)
    let plist: [String: Any] = [
      "ExpirationDate": expiry,
      "TeamName": "Private Person",
      "ProvisionedDevices": ["00008110-0000000000000000"],
      "Entitlements": ["get-task-allow": true, "application-identifier": "ABCDE12345.com.example.app"],
    ]
    let xml = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    // The profile is a signed container: bytes before and after the plist.
    var container = Data([0x30, 0x82, 0x10, 0x00, 0x06, 0x09])
    container.append(xml)
    container.append(Data([0xA0, 0x82, 0x0B, 0x00]))
    let summary = ProvisioningSummary.parse(container)
    XCTAssertTrue(summary.present)
    XCTAssertEqual(summary.isDevelopment, true)
    XCTAssertFalse(summary.hasHotspotEntitlement)
    let text = summary.summary()
    XCTAssertTrue(text.contains("development profile"), text)
    XCTAssertTrue(text.contains("expires in 5 days"), text)
    XCTAssertTrue(text.contains("Bluetooth only"), text)
    XCTAssertFalse(text.contains("Private Person"), "no names")
    XCTAssertFalse(text.contains("ABCDE12345"), "no identifiers")
    XCTAssertFalse(text.contains("00008110"), "no device ids")
    XCTAssertFalse(ProvisioningSummary(present: false).summary().isEmpty)
  }

  // MARK: The layer table

  func testTheLayerTableShowsWhatWasMeasured() {
    var facts = ConnectionLayerFacts()
    facts.bluetooth = .ready
    facts.sdkConfigured = true
    facts.registration = "registered"
    facts.link = "connected"
    facts.worn = true
    facts.battery = 80
    facts.sessionState = "started"
    facts.cameraWanted = true
    facts.cameraPermission = "granted"
    facts.streamState = "streaming"
    facts.measuredFPS = 14.6
    facts.lastFrameAgeMs = 40
    facts.frameSource = "Ray-Ban · 720×1280"
    facts.microphone = "Ray-Ban Meta (Bluetooth HFP)"
    facts.microphoneIsGlasses = true
    facts.output = "Ray-Ban Meta (Bluetooth HFP)"
    facts.voiceState = "listening"
    facts.voiceActive = true
    facts.dataChannelOpen = true
    let rows = ConnectionLayerReport.layers(facts)
    XCTAssertEqual(rows.map(\.id), ["bluetooth", "sdk", "registration", "link", "session", "camera", "source",
                                    "microphone", "output", "voice"])
    XCTAssertTrue(rows.allSatisfy { $0.state == .ok }, rows.map { "\($0.id)=\($0.state)" }.joined(separator: " "))
    XCTAssertTrue(rows.first { $0.id == "camera" }?.value.contains("15 fps") == true)
    XCTAssertTrue(rows.first { $0.id == "link" }?.value.contains("%80") == true)

    // Connected glasses with a refusing session: only that layer is a problem.
    facts.sessionProblem = .refusing(count: 3)
    facts.streamState = "stopped"
    facts.lastFrameAgeMs = nil
    let refusing = ConnectionLayerReport.layers(facts)
    XCTAssertEqual(refusing.first { $0.id == "session" }?.state, .problem)
    XCTAssertEqual(refusing.first { $0.id == "link" }?.state, .ok)
    XCTAssertNotEqual(refusing.first { $0.id == "camera" }?.state, .ok, "no frames, never shown as fine")

    // The iPhone camera chosen: the Ray-Ban camera and session are off, not failed.
    facts.cameraWanted = false
    facts.sessionProblem = nil
    let iPhone = ConnectionLayerReport.layers(facts)
    XCTAssertEqual(iPhone.first { $0.id == "camera" }?.state, .off)
    XCTAssertEqual(iPhone.first { $0.id == "session" }?.state, .off)
  }

  // MARK: Smoothness, measured

  func testStuttersAndTheLongestGapAreMeasured() throws {
    let store = FrameStore()
    var buffer: CVPixelBuffer?
    CVPixelBufferCreate(kCFAllocatorDefault, 8, 8, kCVPixelFormatType_32BGRA, nil, &buffer)
    let pixels = try XCTUnwrap(buffer)
    // 25 fps, then one 420 ms hole (a Bluetooth burst or a lost keyframe),
    // then 25 fps again.
    var times: [CFTimeInterval] = (0..<10).map { 100 + Double($0) * 0.04 }
    let resume = times.last! + 0.42
    times += (0..<10).map { resume + Double($0) * 0.04 }
    for time in times {
      store.ingest(pixelBuffer: pixels, source: .glasses, presentationTime: .invalid, arrivedAt: time)
    }
    let snapshot = store.snapshot()
    XCTAssertEqual(snapshot.stutters, 1)
    XCTAssertEqual(snapshot.longestGapMs, 420)
    XCTAssertEqual(snapshot.frameIntervalMedianMs ?? 0, 40, accuracy: 1)
    XCTAssertGreaterThan(snapshot.frameIntervalP95Ms ?? 0, 39)

    // iPhone frames do not count as Ray-Ban stutters, and a reset starts over.
    store.ingest(pixelBuffer: pixels, source: .iPhone, presentationTime: .invalid, arrivedAt: resume + 5)
    XCTAssertEqual(store.snapshot().stutters, 1)
    store.reset()
    let cleared = store.snapshot()
    XCTAssertEqual(cleared.stutters, 0)
    XCTAssertEqual(cleared.longestGapMs, 0)
    XCTAssertNil(cleared.frameIntervalMedianMs)
  }

  // MARK: The glasses microphone before the camera stream

  func testTheMicrophoneFirstOrderIsOnByDefault() {
    let defaults = UserDefaults.standard
    let saved = defaults.object(forKey: GlassesAudioOrder.defaultsKey)
    defer { defaults.set(saved, forKey: GlassesAudioOrder.defaultsKey) }
    defaults.removeObject(forKey: GlassesAudioOrder.defaultsKey)
    XCTAssertTrue(GlassesAudioOrder.isEnabled, "Meta's documented order")
    defaults.set(false, forKey: GlassesAudioOrder.defaultsKey)
    XCTAssertFalse(GlassesAudioOrder.isEnabled)
  }

  func testTheBuildLinksTheCurrentToolkit() {
    XCTAssertEqual(GlassesSDKInfo.datVersion, "1.0.1")
    XCTAssertTrue(GlassesSDKInfo.supportsFullResolutionPhoto)
    XCTAssertFalse(GlassesVisionCaptureMode.automatic.prefersPhoto(for: .high),
                   "the beta photo never interrupts the live view unless chosen")
  }
}
