/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

//
// StreamSessionViewModel.swift
//
// The Ray-Ban camera on the DAT 1.0 session API: one `DeviceSession` for the
// glasses, its consolidated `Camera` with the `stream` child for live video
// and the `photo` child for standalone stills (Meta beta, only when Settings
// asks for it), plus the app's own frame ingestion, transport fallback and
// stall recovery.
//

import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import MWDATCamera
import MWDATCore
import SwiftUI
import VideoToolbox

enum StreamingStatus {
  case streaming
  case waiting
  case stopped
}

enum StreamingMode {
  case glasses
  case iPhone
}

/// The Meta Wearables Device Access Toolkit version this build links
/// (see Package.resolved). Shown in Diagnostics.
enum GlassesSDKInfo {
  static let datVersion = "1.0.1"
  /// DAT 1.0 `Camera.photo` (beta): standalone stills up to the native sensor
  /// resolution. Used only when Settings → Camera → Vision image asks for it.
  static let supportsFullResolutionPhoto = true
}

/// Resolution / frame-rate trade-offs for the glasses stream. Meta's DAT
/// documentation: frames are compressed per frame to fit the Bluetooth Classic
/// bandwidth, and "requesting a lower resolution, a lower frame rate, or both
/// can yield higher visual quality with less compression loss". The glasses
/// may still step the resolution down on a weak link (never below 15 fps);
/// Diagnostics shows what actually arrives next to what was requested.
///
/// Field reports on DAT 1.0 (SDK discussion #297): over Bluetooth a 720p
/// request is delivered as 504×896 after 15–25 s anyway, at about 60 kB/s
/// whatever the resolution, so 720p mostly costs frames. Meta's own sample
/// asks for less; an app measured 24 fps with no gaps at 24 fps.
enum GlassesStreamProfile: String, CaseIterable, Identifiable {
  /// 504p at 24 fps: the resolution Bluetooth sustains, at a smooth rate.
  /// Reading requests take an in-stream photo (about 1080×1440) instead.
  case live
  /// 720p at 15 fps: full resolution with less compression per frame.
  case sharp
  /// 720p at 7 fps: the least compression, for reading small text.
  case maxDetail = "max"
  /// 720p at 24 fps: the original GlassifAI configuration.
  case balanced
  /// 504p at 30 fps: smoothest preview, least detail.
  case smooth

  static let defaultsKey = "autoloom.glasses.profile"
  static let recommended: GlassesStreamProfile = .live

  static var current: GlassesStreamProfile {
    GlassesStreamProfile(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? recommended
  }

  var id: String { rawValue }

  var label: String {
    switch self {
    case .live: "Live — 504p, 24 fps (recommended over Bluetooth)"
    case .sharp: "Detail — 720p, 15 fps"
    case .maxDetail: "Max detail — 720p, 7 fps (text; choppier preview)"
    case .balanced: "Balanced — 720p, 24 fps (original)"
    case .smooth: "Smooth — 504p, 30 fps"
    }
  }

  var resolution: StreamingResolution {
    self == .smooth || self == .live ? .medium : .high
  }

  var frameRate: UInt {
    switch self {
    case .live: 24
    case .sharp: 15
    case .maxDetail: 7
    case .balanced: 24
    case .smooth: 30
    }
  }

  var requestedSize: (width: Int, height: Int) {
    self == .smooth || self == .live ? (504, 896) : (720, 1280)
  }

  var requestedSummary: String {
    "\(requestedSize.width)×\(requestedSize.height) @ \(frameRate) fps"
  }

  func makeConfig(transport: GlassesVideoTransport) -> StreamConfiguration {
    StreamConfiguration(videoCodec: transport.codec, resolution: resolution, frameRate: frameRate)
  }
}

/// How glasses frames reach the phone. HEVC delivers compressed samples that
/// this app decodes and that keep coming while the app is in the background;
/// raw frames are decoded by the SDK and pause when the app is backgrounded.
enum GlassesVideoTransport: String, CaseIterable, Identifiable {
  case hevc
  case raw

  static let defaultsKey = "autoloom.glasses.transport"

  static var preferred: GlassesVideoTransport {
    GlassesVideoTransport(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .hevc
  }

  var id: String { rawValue }

  var label: String {
    switch self {
    case .hevc: "HEVC — app decodes, works with the phone locked"
    case .raw: "Raw — SDK decodes, foreground only (original)"
    }
  }

  var shortLabel: String {
    self == .hevc ? "HEVC (hvc1)" : "raw"
  }

  var codec: VideoCodec {
    self == .hevc ? .hvc1 : .raw
  }
}

/// Decides whether an HEVC stream that is "streaming" but yields no usable
/// frames should fall back to the SDK-decoded raw transport. Counts are the
/// samples seen since the stream reached `.streaming`.
enum GlassesTransportWatchdog {
  /// A healthy cold start can take 15–18 s over Bluetooth (SDK reports;
  /// another app allows 20 s), so the fallback waits that long.
  static let gracePeriodNanoseconds: UInt64 = 20_000_000_000

  static func fallbackReason(
    compressedSamples: UInt64,
    decodedFrames: UInt64,
    decodeFailures: UInt64,
    rawSamples: UInt64
  ) -> String? {
    if decodedFrames > 0 || rawSamples > 0 { return nil }
    if compressedSamples == 0 { return "no HEVC samples arrived within 20 s of streaming" }
    return "\(compressedSamples) HEVC samples arrived but none decoded (\(decodeFailures) failures)"
  }

  /// Counter difference that survives a FrameStore reset in between.
  static func delta(_ now: UInt64, since baseline: UInt64) -> UInt64 {
    now >= baseline ? now - baseline : now
  }
}

/// A change of the glasses' device session, and whether this app caused it.
/// The temple-gesture interpreter ignores the app's own stops, so stopping
/// the camera (a source switch, a recovery) never ends the conversation.
struct GlassesSessionEvent: Equatable {
  let id = UUID()
  let state: DeviceSessionState
  let byApp: Bool
}

extension GlassesSessionFailure {
  /// The DAT 1.0 session error as the app's own type (Meta: "Do not collapse
  /// these errors into a single 'incompatible versions' state").
  init(_ error: DeviceSessionError) {
    let text = LogSanitizer.sanitize(error.description, limit: 160)
    switch error {
    case .noEligibleDevice: self = .noEligibleDevice
    case .insufficientSDKVersion: self = .sdkTooOld
    case .datAppOnTheGlassesUpdateRequired: self = .glassesAppUpdateRequired
    case .dwaUnavailable: self = .glassesAppUnavailable
    case .dwaOutOfStuRange: self = .versionWarning
    case .thermalCritical, .thermalEmergency: self = .deviceHealth("thermal")
    case .peakPowerShutdown: self = .deviceHealth("peak power")
    case .batteryCritical: self = .deviceHealth("battery")
    case .unexpectedError(let description):
      self = GlassesSessionFailure.unexpected(LogSanitizer.sanitize(description, limit: 160))
    case .sessionAlreadyStopped, .sessionAlreadyExists, .sessionIdle, .capabilityAlreadyActive, .capabilityNotFound:
      self = .appState(text)
    @unknown default:
      self = .unexpected(text)
    }
  }
}

@MainActor
class StreamSessionViewModel: ObservableObject {
  /// Only produced by the legacy preview path (Settings → Camera → Preview).
  @Published var currentVideoFrame: UIImage?
  @Published var hasReceivedFirstFrame: Bool = false
  @Published var streamingStatus: StreamingStatus = .stopped
  @Published var showError: Bool = false
  @Published var errorMessage: String = ""
  @Published var hasActiveDevice: Bool = false
  @Published var streamingMode: StreamingMode = .glasses
  @Published var selectedResolution: StreamingResolution = .high
  @Published private(set) var streamProfile: GlassesStreamProfile = .sharp
  @Published private(set) var lastStreamState = "stopped"
  /// Transport the current camera was created with (may differ from the
  /// preference after an automatic fallback).
  @Published private(set) var activeTransport: GlassesVideoTransport = .hevc
  /// Why the app switched transports automatically, if it did.
  @Published private(set) var transportNote: String?
  /// Name, type and compatibility of the active glasses, for Diagnostics.
  @Published private(set) var deviceDescription = "—"
  /// The glasses' device session (DAT 1.0 allows one per pair of glasses).
  @Published private(set) var deviceSessionState: DeviceSessionState = .idle
  /// Every session state change, marked when this app caused it.
  @Published private(set) var sessionEvent: GlassesSessionEvent?
  /// What the glasses refuse or need, for the connection screen (nil while
  /// sessions start normally).
  @Published private(set) var sessionProblem: GlassesSessionProblem?
  /// The last session error in words (sanitized), for Diagnostics.
  @Published private(set) var lastSessionError: String?
  /// When a session last reached `started`.
  @Published private(set) var lastSessionStartedAt: Date?
  /// The standalone photo child (DAT 1.0 `Camera.photo`, beta).
  @Published private(set) var photoState = "stopped"
  /// How the glasses microphone and the camera stream were ordered at the
  /// last conversation start (Meta: the microphone first).
  @Published private(set) var audioOrderNote = "—"

  var isStreaming: Bool {
    streamingStatus != .stopped
  }

  var resolutionLabel: String {
    switch selectedResolution {
    case .low: return "360x640"
    case .medium: return "504x896"
    case .high: return "720x1280"
    @unknown default: return "Unknown"
    }
  }

  // Photo capture properties
  @Published var capturedPhoto: UIImage?
  @Published var showPhotoPreview: Bool = false

  /// Receives every glasses frame on the SDK's callback thread: one copy into
  /// the shared latest-frame store and a hand-off to the preview layer.
  let frameIngestor = GlassesFrameIngestor()

  private let wearables: WearablesInterface?
  private let deviceSelector: AutoDeviceSelector?
  /// One device session per pair of glasses.
  private var deviceSession: DeviceSession?
  /// The consolidated camera on that session: `stream` and `photo` children.
  private var camera: Camera?
  private let sessionTokens = ListenerTokenBag()
  /// The stream child's listeners, one set per camera.
  private let streamTokens = ListenerTokenBag()
  private let photoTokens = ListenerTokenBag()
  private var deviceMonitorTask: Task<Void, Never>?
  private var lifecycleObservers: [NSObjectProtocol] = []
  /// Bumped whenever the session is replaced, so a late callback from a
  /// previous session can never change the current state.
  private var sessionGeneration = 0
  /// Bumped whenever the camera is replaced.
  private var cameraGeneration = 0
  /// Bumped whenever the stream's listeners are replaced.
  private var streamGeneration = 0
  /// Set when HEVC produced no usable frames; the preferred transport is
  /// skipped until the stream stops. HEVC is tried once more at the next
  /// start (raw pauses when the phone locks), then raw stays for the run.
  private var fallbackFrom: GlassesVideoTransport?
  private var fallbackCount = 0
  static let maxTransportFallbacks = 2
  private var watchdogTask: Task<Void, Never>?
  private var startWatchdogTask: Task<Void, Never>?
  private var stallTask: Task<Void, Never>?
  private var streamingSince: Date?
  private var decoderRestartsSinceImage = 0
  private var lastDecoderRestartAt: Date?
  private var stallStreamRestarts: [Date] = []
  /// Session refusals ("Device unavailable", "Session ended by device")
  /// while the glasses were linked; enough of them in a short time means the
  /// glasses need a power cycle (`GlassesSessionProblemPolicy`).
  private var refusals: [Date] = []
  /// The app itself is stopping the session: its `stopped` is not the wearer's.
  private var stoppingByApp = false
  /// A start is in progress; a second caller returns at once.
  private var isStartingSession = false
  /// Bumped by every stop: a start that began before it gives up after its
  /// next wait instead of opening a session nobody wants any more.
  private var startGeneration = 0
  /// The Ray-Ban camera is the chosen source. With the iPhone camera or the
  /// camera off nothing starts it, not even the wearer's resume.
  var wantsCamera = true
  /// Set by the media coordinator: a video recording is running (the stall
  /// monitor never restarts its stream).
  var isRecordingVideo: @MainActor () -> Bool = { false }
  /// Meta's order: when a conversation is starting with the glasses
  /// microphone, the camera stream waits until that route has settled.
  var waitForAudioRouteBeforeStream: (@MainActor () async -> Void)?
  /// The last stream error was a stream failure (not glasses off, folded,
  /// or missing permission), which is what an unsupported codec looks like.
  private var lastErrorWasStreamFailure = false
  /// One app-requested still capture at a time; photos that do not answer a
  /// pending request (shutter button, late arrivals) never reach vision.
  let stillPhotos = StillPhotoCoordinator()
  /// The HEVC to raw fallback is replacing the session: its stop is not a
  /// camera failure (read by `WearableConnectionCoordinator`).
  private(set) var isSwitchingTransport = false
  /// The stream is set aside on purpose (a standalone photo, or the glasses
  /// microphone starting first): its stop is neither a failure nor a stall.
  private(set) var isStreamSetAside = false
  /// The photo child's state, for the hand-over between the children.
  private var photoStateValue: PhotoState = .stopped
  /// When bytes of a standalone photo last arrived, to tell a slow transfer
  /// from a stuck one.
  private var lastTransferProgressAt: Date?

  init(wearables: WearablesInterface?) {
    self.wearables = wearables
    let profile = GlassesStreamProfile.current
    let transport = GlassesVideoTransport.preferred

    if let wearables {
      // Let the SDK auto-select from available devices
      let selector = AutoDeviceSelector(wearables: wearables)
      self.deviceSelector = selector
      deviceMonitorTask = Task { @MainActor [weak self] in
        for await device in selector.activeDeviceStream() {
          guard let self else { return }
          self.hasActiveDevice = device != nil
          self.deviceDescription = device.flatMap { wearables.deviceForIdentifier($0) }
            .map(StreamSessionViewModel.describe) ?? "—"
        }
      }
    } else {
      self.deviceSelector = nil
    }

    streamProfile = profile
    activeTransport = transport
    selectedResolution = profile.resolution
    frameIngestor.configure(legacyPreview: AssistantPreferences.usesLegacyPreview)
    observeLifecycle()
  }

  private static func describe(_ device: Device) -> String {
    "\(device.nameOrId()) · \(device.deviceType().rawValue) · \(String(describing: device.compatibility()))"
  }

  /// The transport to use for the next camera: the user's preference unless
  /// it already failed in this app run.
  private var effectiveTransport: GlassesVideoTransport {
    let preferred = GlassesVideoTransport.preferred
    if let fallbackFrom, fallbackFrom == preferred { return .raw }
    return preferred
  }

  private func observeLifecycle() {
    let ingestor = frameIngestor
    lifecycleObservers.append(NotificationCenter.default.addObserver(
      forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
    ) { _ in
      ingestor.setBackground(true)
    })
    lifecycleObservers.append(NotificationCenter.default.addObserver(
      forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
    ) { _ in
      ingestor.setBackground(false)
    })
  }

  // MARK: Profile and transport

  /// Applies the stream profile and transport chosen in Settings; the next
  /// camera uses them (a running stream is not changed).
  func applyStreamProfileIfNeeded() {
    let profile = GlassesStreamProfile.current
    let transport = effectiveTransport
    frameIngestor.configure(legacyPreview: AssistantPreferences.usesLegacyPreview)
    frameIngestor.applyDecoderPreference()
    if fallbackFrom != nil, fallbackFrom != GlassesVideoTransport.preferred {
      // The user picked another transport; a new attempt starts clean.
      fallbackFrom = nil
      transportNote = nil
    }
    guard profile != streamProfile || transport != activeTransport, !isStreaming else { return }
    streamProfile = profile
    activeTransport = transport
    selectedResolution = profile.resolution
    NSLog("[Stream] next camera: %@ %@", profile.requestedSummary, transport.shortLabel)
  }

  // MARK: Starting and stopping

  /// Glasses-state conditions the call screen's placeholder can name --
  /// the app's own voice, replacing the sample's alert dialogs.
  enum GlassesIssue: Equatable {
    case sdkUnavailable
    case permissionNeeded
    case hingesClosed
    case reconnecting
    case thermal
  }

  @Published var glassesIssue: GlassesIssue?
  @Published private(set) var lastStreamError: String?

  /// Permission first, then the session and the stream (the connection
  /// coordinator checks the permission itself and calls `startSession()`).
  func handleStartStreaming() async {
    glassesIssue = nil
    guard let wearables else {
      glassesIssue = .sdkUnavailable
      return
    }
    applyStreamProfileIfNeeded()
    let permission = Permission.camera
    do {
      let status = try await wearables.checkPermissionStatus(permission)
      if status == .granted {
        await startSession()
        return
      }
      let requestStatus = try await wearables.requestPermission(permission)
      if requestStatus == .granted {
        await startSession()
        return
      }
      glassesIssue = .permissionNeeded
    } catch let error as PermissionError {
      // Sleeping or out-of-range glasses are a wait state, not an error:
      // permission checks report "no device" while nothing is connected.
      switch error {
      case .noDevice, .noDeviceWithConnection, .connectionError:
        NSLog("[Stream] glasses unavailable, waiting: %@", error.description)
        glassesIssue = nil
      default:
        glassesIssue = .reconnecting
      }
    } catch {
      glassesIssue = .reconnecting
    }
  }

  /// Starts the session (or reuses a started one), attaches the camera and
  /// starts the stream, once at a time.
  func startSession() async {
    guard wantsCamera, !isStartingSession, let wearables, let deviceSelector else { return }
    if let camera, camera.stream.state != .stopped { return }
    isStartingSession = true
    defer { isStartingSession = false }
    let generation = startGeneration
    // A camera whose stream stopped is not started again: on DAT 1.0 that
    // restart can deliver nothing (Meta #260), and a fresh session recovers
    // (#287). A stream set aside for a photo or the microphone is resumed
    // where it was set aside.
    if camera != nil, !isStreamSetAside {
      if deviceSession != nil {
        NSLog("[Stream] stream stopped on a live session; starting a fresh session")
        await endSession()
        guard startGeneration == generation else { return }
      } else {
        clearCamera()
      }
    }
    armStartWatchdog()
    streamingStatus = .waiting
    guard let session = await startedSession(wearables: wearables, selector: deviceSelector, generation: generation) else {
      if camera == nil {
        startWatchdogTask?.cancel()
        streamingStatus = .stopped
      }
      return
    }
    attachCameraIfNeeded(to: session)
    guard let camera else {
      startWatchdogTask?.cancel()
      streamingStatus = .stopped
      return
    }
    // Meta: the glasses microphone (HFP) must be set up before the camera
    // stream starts, or the audio route can fail silently.
    if let waitForAudio = waitForAudioRouteBeforeStream {
      await waitForAudio()
    }
    guard self.camera === camera, session.state == .started, startGeneration == generation else { return }
    camera.stream.start()
  }

  /// A started session: the current one, or a new one. nil when the glasses
  /// refuse, are paused by the wearer, or do not answer in time.
  private func startedSession(
    wearables: WearablesInterface, selector: AutoDeviceSelector, generation: Int
  ) async -> DeviceSession? {
    if let existing = deviceSession {
      if existing.state == .started { return existing }
      if existing.state == .paused { return nil }
      if existing.state == .stopping || existing.state == .stopped {
        // The SDK refuses a new session until the old one has ended. Its
        // camera goes with it: a camera kept from it would stream nothing.
        _ = await waitUntil(timeout: 3) { self.deviceSession == nil || existing.state == .stopped }
        if deviceSession === existing {
          clearCamera()
          cleanupSession()
        }
      } else {
        _ = await waitUntil(timeout: 20) { existing.state == .started || existing.state == .stopped }
        guard startGeneration == generation else { return nil }
        return existing.state == .started ? existing : nil
      }
    }
    var session: DeviceSession?
    for attempt in 0..<3 {
      // Stopped meanwhile (a source switch, the app going away): no session.
      guard startGeneration == generation else { return nil }
      do {
        let created = try wearables.createSession(deviceSelector: selector)
        deviceSession = created
        sessionGeneration += 1
        // Subscribe before start(): the publishers do not replay.
        observeSession(created, generation: sessionGeneration)
        deviceSessionState = .starting
        try created.start()
        session = created
        break
      } catch let error as DeviceSessionError {
        cleanupSession()
        // createSession refuses for a moment after the last session stopped.
        if error == .sessionAlreadyExists, attempt < 2 {
          try? await Task.sleep(nanoseconds: 400_000_000)
          continue
        }
        recordSessionFailure(GlassesSessionFailure(error))
        return nil
      } catch {
        cleanupSession()
        recordSessionFailure(.unexpected(LogSanitizer.sanitize(String(describing: error), limit: 160)))
        return nil
      }
    }
    guard let session else { return nil }
    // `addCamera` returns nil until the session is started. A session that
    // stops meanwhile (glasses folded, refused) ends the wait.
    _ = await waitUntil(timeout: 20) { session.state == .started || session.state == .stopped || session.state == .paused }
    guard startGeneration == generation else {
      if session.state != .stopped, session.state != .stopping { stopOwnSession(session) }
      return nil
    }
    guard session.state == .started else {
      NSLog("[Stream] device session did not start (state %@)", String(describing: session.state))
      if session.state != .stopped, session.state != .paused {
        stopOwnSession(session)
      }
      return nil
    }
    return session
  }

  /// Ends the camera and the device session (a source switch, a recovery or
  /// the app going away). The next start creates a fresh session.
  func stopSession() async {
    startGeneration += 1
    await endSession()
  }

  /// Ends the session without cancelling the start that asked for it (a
  /// start that replaces a stopped stream with a fresh session).
  private func endSession() async {
    startWatchdogTask?.cancel()
    guard let session = deviceSession else {
      clearCamera()
      return
    }
    stopOwnSession(session)
    guard await waitUntil(timeout: 3, { self.deviceSession == nil }) else {
      // No `stopped` arrived: forget the session anyway, so the next start
      // creates a fresh one.
      NSLog("[Stream] device session did not report stopped; cleared")
      clearCamera()
      cleanupSession()
      return
    }
  }

  private func stopOwnSession(_ session: DeviceSession) {
    stoppingByApp = true
    camera?.stop()
    session.stop()
  }

  private func observeSession(_ session: DeviceSession, generation: Int) {
    session.statePublisher.listen { [weak self] state in
      Task { @MainActor [weak self] in
        guard let self, self.sessionGeneration == generation else { return }
        self.handleSessionState(state)
      }
    }.store(in: sessionTokens)
    session.errorPublisher.listen { [weak self] error in
      Task { @MainActor [weak self] in
        guard let self, self.sessionGeneration == generation else { return }
        self.recordSessionFailure(GlassesSessionFailure(error))
      }
    }.store(in: sessionTokens)
  }

  private func handleSessionState(_ state: DeviceSessionState) {
    NSLog("[GlassifAI] glasses session state: %@", String(describing: state))
    let byApp = stoppingByApp && (state == .stopping || state == .stopped)
    deviceSessionState = state
    sessionEvent = GlassesSessionEvent(state: state, byApp: byApp)
    switch state {
    case .started:
      lastSessionStartedAt = Date()
      // A session that starts is the proof the glasses accept the app.
      refusals.removeAll()
      if let problem = sessionProblem, problem.clearsWhenASessionStarts { sessionProblem = nil }
      // Resumed by the wearer (a temple tap): the stream goes on, if the
      // Ray-Ban camera is still the chosen source.
      if wantsCamera, let camera, camera.stream.state == .stopped, !isStartingSession, !isStreamSetAside {
        camera.stream.start()
      }
    case .stopped:
      stoppingByApp = false
      clearCamera()
      cleanupSession()
    default:
      break
    }
  }

  /// One session error: kept for Diagnostics and turned into what the user
  /// must do, if anything (`GlassesSessionProblemPolicy`).
  private func recordSessionFailure(_ failure: GlassesSessionFailure) {
    // The glasses' microphone open over hands-free when the session ends or
    // is refused: the glasses' call rule (Meta #206, #332).
    let handsFree = AVAudioSession.sharedInstance().currentRoute.inputs.contains { $0.portType == .bluetoothHFP }
    lastSessionError = failure.summary + (handsFree && failure.isRefusal ? " (glasses microphone link open)" : "")
    NSLog("[Stream] device session error: %@", lastSessionError ?? "")
    let now = Date()
    if failure.isRefusal { refusals.append(now) }
    refusals.removeAll { now.timeIntervalSince($0) > GlassesSessionProblemPolicy.refusalWindow }
    if let problem = GlassesSessionProblemPolicy.problem(
      after: failure, refusalsInWindow: refusals.count, handsFreeActive: handsFree) {
      sessionProblem = problem
    }
  }

  /// Try Again, or the glasses came back after a power cycle: the next
  /// start is judged afresh.
  func clearSessionProblem() {
    refusals.removeAll()
    sessionProblem = nil
  }

  private func cleanupSession() {
    sessionTokens.clear()
    deviceSession = nil
    deviceSessionState = .stopped
    stoppingByApp = false
  }

  // MARK: Camera

  /// Adds the consolidated camera to a started session, subscribes to both
  /// children before anything starts, and remembers which camera is current.
  private func attachCameraIfNeeded(to session: DeviceSession) {
    guard camera == nil else { return }
    let transport = effectiveTransport
    activeTransport = transport
    let config = streamProfile.makeConfig(transport: transport)
    do {
      guard let created = try session.addCamera(config: config) else {
        NSLog("[Stream] the camera would not attach yet")
        glassesIssue = .reconnecting
        return
      }
      camera = created
      cameraGeneration += 1
      streamGeneration += 1
      attachStreamListeners(created.stream, generation: streamGeneration)
      attachPhotoListeners(created.photo, generation: cameraGeneration)
      NSLog("[Stream] camera attached: %@ %@", streamProfile.requestedSummary, transport.shortLabel)
    } catch let error as DeviceSessionError {
      recordSessionFailure(GlassesSessionFailure(error))
    } catch {
      recordSessionFailure(.unexpected(LogSanitizer.sanitize(String(describing: error), limit: 160)))
    }
  }

  /// Detaches the camera (idempotent) and cancels its listeners.
  private func clearCamera() {
    camera?.stop()
    camera = nil
    streamTokens.clear()
    photoTokens.clear()
    photoStateValue = .stopped
    photoState = "stopped"
    isStreamSetAside = false
    updateStatusFromState(.stopped)
  }

  private func attachStreamListeners(_ stream: MWDATCamera.Stream, generation: Int) {
    stream.statePublisher.listen { [weak self] state in
      Task { @MainActor [weak self] in
        guard let self, self.streamGeneration == generation else { return }
        self.updateStatusFromState(state)
      }
    }.store(in: streamTokens)

    // The SDK invokes this inline on its decoder thread, so the fast path
    // must not hop to the main actor or retain the SDK's buffer.
    let ingestor = frameIngestor
    stream.videoFramePublisher.listen { [weak self] videoFrame in
      let result = ingestor.handle(videoFrame.sampleBuffer)
      if result.isFirstFrame {
        Task { @MainActor [weak self] in
          self?.hasReceivedFirstFrame = true
        }
      }
      if result.handled { return }
      // Legacy preview path (the original behaviour), foreground only. The
      // ingestor has already fed the frame store, so vision works in this
      // mode too.
      Task { @MainActor [weak self] in
        guard let self, UIApplication.shared.applicationState != .background else { return }
        if let image = videoFrame.makeUIImage() {
          self.currentVideoFrame = image
          if !self.hasReceivedFirstFrame {
            self.hasReceivedFirstFrame = true
          }
        }
      }
    }.store(in: streamTokens)

    stream.errorPublisher.listen { [weak self] error in
      Task { @MainActor [weak self] in
        guard let self, self.streamGeneration == generation else { return }
        self.handleStreamError(error)
      }
    }.store(in: streamTokens)

    // In-stream photos (the preview's shutter, vision stills). A photo that
    // answers a pending request goes to that request only; anything else
    // keeps the original preview behaviour and never reaches vision.
    let photos = stillPhotos
    stream.photoDataPublisher.listen { [weak self] photoData in
      if photos.deliver(photoData.data) { return }
      let data = photoData.data
      Task { @MainActor [weak self] in
        guard let self, let uiImage = UIImage(data: data) else { return }
        self.capturedPhoto = uiImage
        self.showPhotoPreview = true
      }
    }.store(in: streamTokens)
  }

  private func attachPhotoListeners(_ photo: MWDATCamera.Photo, generation: Int) {
    photo.statePublisher.listen { [weak self] state in
      Task { @MainActor [weak self] in
        guard let self, self.cameraGeneration == generation else { return }
        self.photoStateValue = state
        self.photoState = String(describing: state)
      }
    }.store(in: photoTokens)
    photo.transferProgressPublisher.listen { [weak self] _ in
      Task { @MainActor [weak self] in self?.lastTransferProgressAt = Date() }
    }.store(in: photoTokens)
    // Standalone stills arrive here, including ones the wearer takes with
    // the shutter button; only a pending app request accepts one.
    let photos = stillPhotos
    photo.photoDataPublisher.listen { data in
      photos.deliver(data.imageData)
    }.store(in: photoTokens)
    photo.errorPublisher.listen { error in
      NSLog("[Stream] standalone photo error: %@", LogSanitizer.sanitize(error.description, limit: 160))
    }.store(in: photoTokens)
  }

  private func handleStreamError(_ error: StreamError) {
    // Setting the stream aside on purpose is not a failure.
    guard !isStreamSetAside else { return }
    switch error {
    case .videoStreamingError, .internalError, .timeout:
      lastErrorWasStreamFailure = true
    default:
      lastErrorWasStreamFailure = false
    }
    // One voice: glasses-state conditions render as placeholder text on the
    // call screen, never as alert dialogs. Sleeping/absent glasses are a
    // plain wait; everything else maps to a typed issue.
    switch error {
    case .deviceNotConnected, .deviceNotFound:
      glassesIssue = nil
    case .hingesClosed:
      glassesIssue = .hingesClosed
    case .permissionDenied:
      glassesIssue = .permissionNeeded
    case .thermalHot, .peakPowerLimit, .batteryLow:
      glassesIssue = .thermal
    default:
      glassesIssue = .reconnecting
    }
    lastStreamError = formatStreamingError(error)
  }

  // MARK: The glasses microphone first

  /// Meta's order for the glasses microphone and the camera: "the HFP
  /// microphone must be fully configured before the stream starts". A
  /// conversation that starts while the stream runs sets the stream aside
  /// (the device session stays), lets `setUpAudio` bring the microphone up,
  /// and starts the stream again.
  func withStreamSetAsideForAudio(_ setUpAudio: @MainActor () async -> Bool) async {
    guard let camera, deviceSession?.state == .started, camera.stream.state == .streaming,
          !isStreamSetAside, !stillPhotos.isCapturing else {
      let settled = await setUpAudio()
      audioOrderNote = settled
        ? "microphone settled; the stream starts after it"
        : "microphone not on the glasses route; the stream was not running"
      return
    }
    isStreamSetAside = true
    camera.stream.stop()
    _ = await waitUntil(timeout: 3) { camera.stream.state == .stopped }
    let settled = await setUpAudio()
    await resumeSetAsideStream(camera)
    audioOrderNote = settled
      ? "stream set aside; microphone settled; stream started again"
      : "stream set aside; microphone not on the glasses route; stream started again"
  }

  /// Starts a stream that was set aside on purpose. Its listeners stay: the
  /// stream object and its publishers outlive a stop and start, and a second
  /// frame listener would feed every frame to the decoder twice.
  private func resumeSetAsideStream(_ camera: Camera) async {
    guard self.camera === camera else {
      isStreamSetAside = false
      return
    }
    _ = await waitUntil(timeout: 3) { camera.stream.state == .stopped }
    isStreamSetAside = false
    if deviceSession?.state == .started {
      camera.stream.start()
    } else {
      // Paused by the wearer meanwhile: the stream starts again when the
      // session does (`handleSessionState`).
      updateStatusFromState(camera.stream.state)
    }
  }

  // MARK: Still photos

  /// A photo the user asked for ("fotoğraf çek"): an in-stream capture,
  /// never a preview screenshot. Nil when the stream is not running, the SDK
  /// refuses, or nothing arrives in time.
  func captureUserPhoto(timeout: TimeInterval) async -> StillPhoto? {
    await captureInStreamPhoto(timeout: timeout)
  }

  /// A fresh still for one vision request. With "Full-resolution photo" in
  /// Settings, reading requests take a standalone photo from the sensor
  /// (Meta beta; the live view pauses for a few seconds); otherwise an
  /// in-stream photo, which is a frame of the video.
  func captureStillForVision(timeout: TimeInterval) async -> StillPhoto? {
    if GlassesVisionCaptureMode.current == .fullPhoto {
      return await captureStandalonePhoto(timeout: timeout)
    }
    return await captureInStreamPhoto(timeout: timeout)
  }

  private func captureInStreamPhoto(timeout: TimeInterval) async -> StillPhoto? {
    guard streamingStatus == .streaming, let camera, !isStreamSetAside else { return nil }
    FrameStore.shared.recordPhotoRequest()
    let stream = camera.stream
    let photo = await stillPhotos.capture(timeout: timeout) {
      stream.capturePhoto(format: .jpeg)
    }
    FrameStore.shared.recordPhoto(
      width: photo?.width, height: photo?.height, latencyMs: photo?.latencyMs, success: photo != nil)
    return photo
  }

  /// Meta's documented sequence: the stream and the photo compete for the
  /// camera, so the stream stops; the photo child starts (retried once on a
  /// fresh camera, the most common failure); one capture is taken while its
  /// bytes keep arriving; then the photo child stops and the stream starts
  /// again, whatever happened.
  private func captureStandalonePhoto(timeout: TimeInterval) async -> StillPhoto? {
    guard streamingStatus == .streaming, deviceSession?.state == .started, let camera,
          !isStreamSetAside, !stillPhotos.isCapturing else { return nil }
    FrameStore.shared.recordPhotoRequest()
    isStreamSetAside = true
    camera.stream.stop()
    _ = await waitUntil(timeout: 3) { camera.stream.state == .stopped }

    var photoCamera: Camera? = camera
    var ready = await startPhotoChild(of: camera)
    if !ready {
      photoCamera = replaceCameraForPhoto()
      if let fresh = photoCamera {
        ready = await startPhotoChild(of: fresh)
      }
    }
    var photo: StillPhoto?
    if ready, let photoCamera {
      photo = await takeStandalonePhoto(on: photoCamera, timeout: timeout)
    }
    FrameStore.shared.recordPhoto(
      width: photo?.width, height: photo?.height, latencyMs: photo?.latencyMs, success: photo != nil)
    // Meta (SDK issue #260): restarting a stream after stopping it can fail
    // on DAT 1.0, while a fresh session recovers every time, so the live view
    // comes back through a new session.
    if let current = self.camera, current === photoCamera, photoStateValue != .stopped {
      current.photo.stop()
      _ = await waitUntil(timeout: 3) { self.photoStateValue == .stopped }
    }
    isSwitchingTransport = true
    await stopSession()
    isSwitchingTransport = false
    isStreamSetAside = false
    await startSession()
    return photo
  }

  /// Starts the photo child and waits for `started`; a return to `stopped`
  /// after `starting`, or no answer in 8 s, is a failed startup.
  private func startPhotoChild(of camera: Camera) async -> Bool {
    guard self.camera === camera else { return false }
    if photoStateValue == .started { return true }
    camera.photo.start()
    var sawStarting = false
    let started = await waitUntil(timeout: 8) {
      if self.photoStateValue == .starting { sawStarting = true }
      return self.photoStateValue == .started || (sawStarting && self.photoStateValue == .stopped)
    }
    return started && photoStateValue == .started
  }

  /// Meta: "stop the camera, add a new one, and retry once" (a stopped camera
  /// is invalidated).
  private func replaceCameraForPhoto() -> Camera? {
    guard let session = deviceSession, session.state == .started else { return nil }
    NSLog("[Stream] standalone photo did not start; retrying once on a fresh camera")
    camera?.stop()
    camera = nil
    streamTokens.clear()
    photoTokens.clear()
    photoStateValue = .stopped
    attachCameraIfNeeded(to: session)
    return camera
  }

  private func takeStandalonePhoto(on camera: Camera, timeout: TimeInterval) async -> StillPhoto? {
    // A large still takes a few seconds to cross the link; Meta fails a
    // capture after 30 s of silence. Up to `timeout` (at least 15 s) in any
    // case, and longer only while bytes are still arriving.
    let requestedAt = Date()
    lastTransferProgressAt = nil
    let limit = max(timeout, 15)
    let photos = stillPhotos
    let transferWatch = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 500_000_000)
        guard let self, !Task.isCancelled else { return }
        let elapsed = Date().timeIntervalSince(requestedAt)
        let arriving = self.lastTransferProgressAt.map { Date().timeIntervalSince($0) < 3 } ?? false
        if elapsed > limit, !arriving {
          photos.cancel()
          return
        }
      }
    }
    let photo = await stillPhotos.capture(timeout: 30) {
      camera.photo.capturePhoto(resolution: .large, quality: .high)
      return true
    }
    transferWatch.cancel()
    return photo
  }

  /// The preview's capture button: an in-stream photo, as before.
  func capturePhoto() {
    _ = camera?.stream.capturePhoto(format: .jpeg)
  }

  func dismissPhotoPreview() {
    showPhotoPreview = false
    capturedPhoto = nil
  }

  private func showError(_ message: String) {
    errorMessage = message
    showError = true
  }

  func dismissError() {
    showError = false
    errorMessage = ""
  }

  // MARK: Transport watchdogs

  /// HEVC is decoded by this app. If a stream reports `.streaming` but no
  /// frame has been decoded after the grace period, fall back to the
  /// SDK-decoded raw transport once, so the camera keeps working.
  private func armTransportWatchdog() {
    watchdogTask?.cancel()
    guard activeTransport == .hevc, fallbackFrom == nil else { return }
    let baseline = FrameStore.shared.snapshot()
    let generation = streamGeneration
    watchdogTask = Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: GlassesTransportWatchdog.gracePeriodNanoseconds)
      guard let self, !Task.isCancelled, self.streamGeneration == generation,
            self.streamingStatus == .streaming, self.activeTransport == .hevc, !self.isStreamSetAside else { return }
      // Only judged on screen: raw pauses in the background, so a fallback
      // decided there would stop vision exactly when the phone is locked.
      guard UIApplication.shared.applicationState == .active else { return }
      let now = FrameStore.shared.snapshot()
      let reason = GlassesTransportWatchdog.fallbackReason(
        compressedSamples: GlassesTransportWatchdog.delta(now.compressedSamples, since: baseline.compressedSamples),
        decodedFrames: GlassesTransportWatchdog.delta(now.decodedFrames, since: baseline.decodedFrames),
        decodeFailures: GlassesTransportWatchdog.delta(now.decodeFailures, since: baseline.decodeFailures),
        rawSamples: GlassesTransportWatchdog.delta(now.rawSamples, since: baseline.rawSamples))
      guard let reason else { return }
      await self.fallBackToRaw(reason: reason)
    }
  }

  /// A new session with the raw transport. Meta's reports show a camera
  /// re-added to a live session often delivers nothing, while a fresh
  /// session recovers, so the whole session is replaced.
  private func fallBackToRaw(reason: String) async {
    guard activeTransport == .hevc, !isSwitchingTransport else { return }
    NSLog("[Stream] HEVC transport fallback to raw: %@", reason)
    fallbackFrom = .hevc
    fallbackCount += 1
    transportNote = "Switched to raw automatically: \(reason). Raw pauses while the phone is locked"
      + (fallbackCount < Self.maxTransportFallbacks ? "; HEVC is tried again at the next start." : ".")
    isSwitchingTransport = true
    await stopSession()
    isSwitchingTransport = false
    await startSession()
  }

  /// If an HEVC stream has not started 12 s after a start request and the
  /// SDK reported a stream failure (not glasses off, folded or permission),
  /// fall back to raw once, so the camera works even if HEVC is refused.
  private func armStartWatchdog() {
    guard effectiveTransport == .hevc, fallbackFrom == nil else { return }
    startWatchdogTask?.cancel()
    lastErrorWasStreamFailure = false
    startWatchdogTask = Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: 12_000_000_000)
      guard let self, !Task.isCancelled,
            self.activeTransport == .hevc, self.streamingStatus != .streaming,
            self.lastErrorWasStreamFailure,
            UIApplication.shared.applicationState == .active else { return }
      await self.fallBackToRaw(reason: "HEVC stream did not start (\(self.lastStreamError ?? "stream error"))")
    }
  }

  // MARK: State

  private func updateStatusFromState(_ state: StreamState) {
    NSLog("[GlassifAI] glasses stream state: %@", String(describing: state))
    lastStreamState = String(describing: state)
    switch state {
    case .stopped:
      // A stream set aside on purpose keeps the rest alive.
      if isStreamSetAside, camera != nil { return }
      currentVideoFrame = nil
      hasReceivedFirstFrame = false
      frameIngestor.resetFirstFrame()
      stillPhotos.cancel()
      watchdogTask?.cancel()
      stallTask?.cancel()
      streamingSince = nil
      streamingStatus = .stopped
      if !isSwitchingTransport {
        // A recording ends with its stream; what was recorded is saved.
        RayBanMediaCoordinator.shared.streamStopped()
      }
      if fallbackFrom != nil, fallbackCount < Self.maxTransportFallbacks, !isSwitchingTransport {
        // A raw fallback lasts for one stream: the next start tries HEVC,
        // which keeps vision working with the phone locked.
        fallbackFrom = nil
      }
    case .waitingForDevice, .starting, .stopping, .paused:
      if isStreamSetAside, camera != nil { return }
      streamingStatus = .waiting
    case .streaming:
      let wasStreaming = streamingStatus == .streaming
      streamingStatus = .streaming
      glassesIssue = nil
      startWatchdogTask?.cancel()
      lastErrorWasStreamFailure = false
      if !wasStreaming {
        armTransportWatchdog()
        armStallMonitor()
      }
    }
  }

  // MARK: Fresh-frame monitor

  /// Every 2 s while streaming: if no fresh Ray-Ban image reaches the store,
  /// rebuild the decoder or (on screen) start a fresh session, within the
  /// limits of `RayBanStallPolicy`.
  private func armStallMonitor() {
    stallTask?.cancel()
    streamingSince = Date()
    decoderRestartsSinceImage = 0
    stallTask = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        // A set-aside keeps the status "streaming", so the monitor goes on.
        guard let self, !Task.isCancelled, self.streamingStatus == .streaming else { return }
        await self.checkForStall()
      }
    }
  }

  private func checkForStall() async {
    // A photo or the microphone hand-over pauses frames on purpose.
    guard !isStreamSetAside else {
      streamingSince = Date()
      return
    }
    let metrics = FrameStore.shared.snapshot()
    if (metrics.lastGlassesFrameAgeMs ?? Int.max) < 1_000 { decoderRestartsSinceImage = 0 }
    let now = Date()
    stallStreamRestarts.removeAll { now.timeIntervalSince($0) >= RayBanStallPolicy.streamRestartWindow }
    let input = RayBanStallPolicy.Input(
      streaming: streamingStatus == .streaming,
      hevc: activeTransport == .hevc,
      background: UIApplication.shared.applicationState == .background,
      recording: isRecordingVideo(),
      streamingFor: streamingSince.map { now.timeIntervalSince($0) } ?? 0,
      lastSampleAgeMs: metrics.lastSampleAgeMs,
      lastImageAgeMs: metrics.lastGlassesFrameAgeMs,
      keyframeWaitMs: metrics.keyframeWaitMs,
      decoderRestarts: decoderRestartsSinceImage,
      lastDecoderRestartAt: lastDecoderRestartAt,
      streamRestarts: stallStreamRestarts,
      now: now)
    switch RayBanStallPolicy.decide(input) {
    case .none:
      return
    case .restartDecoder(let swapMode):
      decoderRestartsSinceImage += 1
      lastDecoderRestartAt = now
      frameIngestor.restartDecoder(swapMode: swapMode)
      let text = swapMode ? "decoder rebuilt in the other mode" : "decoder rebuilt"
      FrameStore.shared.recordRecovery(text)
      NSLog("[Stream] stall recovery: %@", text)
    case .restartStream(let reason):
      stallStreamRestarts.append(now)
      FrameStore.shared.recordRecovery("session restarted (\(reason))")
      NSLog("[Stream] stall recovery: a fresh session (%@)", reason)
      stallTask?.cancel()
      // A starved stream recovers with a new session (Meta SDK reports); the
      // connection coordinator starts it again after a short backoff.
      await stopSession()
    }
  }

  /// Polls a condition on the main actor until it holds or the time is up.
  private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
      guard Date() < deadline, !Task.isCancelled else { return false }
      try? await Task.sleep(nanoseconds: 100_000_000)
    }
    return true
  }

  private func formatStreamingError(_ error: StreamError) -> String {
    switch error {
    case .internalError:
      return "An internal error occurred. Please try again."
    case .deviceNotFound:
      return "Device not found. Please ensure your device is connected."
    case .deviceNotConnected:
      return "Device not connected. Please check your connection and try again."
    case .timeout:
      return "The operation timed out. Please try again."
    case .videoStreamingError:
      return "Video streaming failed. Please try again."
    case .audioStreamingError:
      return "Audio streaming failed."
    case .thermalHot:
      return "The glasses are too warm. The camera may slow down or stop until they cool down."
    case .peakPowerLimit, .batteryLow:
      return "The glasses' battery or power limit stopped the camera."
    case .permissionDenied:
      return "Camera permission denied. Please grant permission in the Meta AI app."
    case .hingesClosed:
      return "The hinges on the glasses were closed, or the glasses were taken off."
    case .photoCaptureFailed:
      return "The photo could not be taken."
    @unknown default:
      return "An unknown streaming error occurred."
    }
  }
}
