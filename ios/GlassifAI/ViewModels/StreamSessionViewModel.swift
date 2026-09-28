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
// Ray-Ban camera on the DAT 1.0 session API: one `DeviceSession` for the
// glasses, its consolidated `Camera` with the `stream` child for video and the
// `photo` child for standalone full-resolution stills (DAT 1.0, beta), and the
// same frame ingestion, transport fallback and still-photo coordination as the
// 0.5.0 build.
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
  static let datVersion = "1.0.0"
  /// DAT 1.0 `Camera.photo`: standalone stills at up to the native sensor
  /// resolution (4032×3024). Meta marks it beta.
  static let supportsFullResolutionPhoto = true
}

/// Resolution / frame-rate trade-offs for the glasses stream. Meta's DAT
/// documentation: frames are compressed per frame to fit the Bluetooth Classic
/// bandwidth, and "requesting a lower resolution, a lower frame rate, or both
/// can yield higher visual quality with less compression loss". The glasses
/// may still step the resolution down on a weak link; Diagnostics shows what
/// actually arrives next to what was requested.
enum GlassesStreamProfile: String, CaseIterable, Identifiable {
  /// 720p at 15 fps: full resolution with less compression per frame.
  case sharp
  /// 720p at 7 fps: the least compression, for reading small text.
  case maxDetail = "max"
  /// 720p at 24 fps: the original GlassifAI configuration.
  case balanced
  /// 504p at 30 fps: smoothest preview, least detail.
  case smooth

  static let defaultsKey = "autoloom.glasses.profile"
  static let recommended: GlassesStreamProfile = .sharp

  static var current: GlassesStreamProfile {
    GlassesStreamProfile(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? recommended
  }

  var id: String { rawValue }

  var label: String {
    switch self {
    case .sharp: "Detail — 720p, 15 fps (recommended)"
    case .maxDetail: "Max detail — 720p, 7 fps (text; choppier preview)"
    case .balanced: "Balanced — 720p, 24 fps (original)"
    case .smooth: "Smooth — 504p, 30 fps"
    }
  }

  var resolution: StreamingResolution {
    self == .smooth ? .medium : .high
  }

  var frameRate: UInt {
    switch self {
    case .sharp: 15
    case .maxDetail: 7
    case .balanced: 24
    case .smooth: 30
    }
  }

  var requestedSize: (width: Int, height: Int) {
    self == .smooth ? (504, 896) : (720, 1280)
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
  static let gracePeriodNanoseconds: UInt64 = 8_000_000_000

  static func fallbackReason(
    compressedSamples: UInt64,
    decodedFrames: UInt64,
    decodeFailures: UInt64,
    rawSamples: UInt64
  ) -> String? {
    if decodedFrames > 0 || rawSamples > 0 { return nil }
    if compressedSamples == 0 { return "no HEVC samples arrived within 8 s of streaming" }
    return "\(compressedSamples) HEVC samples arrived but none decoded (\(decodeFailures) failures)"
  }

  /// Counter difference that survives a FrameStore reset in between.
  static func delta(_ now: UInt64, since baseline: UInt64) -> UInt64 {
    now >= baseline ? now - baseline : now
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
  /// The device session's state. The temple-gesture interpreter reads it:
  /// a tap pauses and resumes the session, a long press or fold stops it.
  @Published private(set) var deviceSessionState: DeviceSessionState = .idle
  /// The standalone photo child (DAT 1.0 `Camera.photo`); "started" means a
  /// full-resolution still can be taken.
  @Published private(set) var photoState = "stopped"

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
  /// One device session per pair of glasses (DAT 1.0 allows no second one).
  private var deviceSession: DeviceSession?
  /// The consolidated camera on that session: `stream` and `photo` children.
  private var camera: Camera?
  private let sessionTokens = ListenerTokenBag()
  /// The stream child's listeners; taken out afresh whenever the stream is
  /// started again after a standalone photo.
  private let streamTokens = ListenerTokenBag()
  private let photoTokens = ListenerTokenBag()
  private var deviceMonitorTask: Task<Void, Never>?
  private var lifecycleObservers: [NSObjectProtocol] = []
  /// Bumped whenever the camera is replaced, so a late callback from a
  /// previous camera can never change the current state.
  private var sessionGeneration = 0
  /// Bumped whenever the stream's listeners are replaced, so a listener that
  /// outlives its replacement is ignored.
  private var streamGeneration = 0
  /// Set when HEVC produced no usable frames; the preferred transport is
  /// skipped until the user picks a different one.
  private var fallbackFrom: GlassesVideoTransport?
  private var watchdogTask: Task<Void, Never>?
  private var startWatchdogTask: Task<Void, Never>?
  /// The last stream error was a stream failure (not glasses off, folded,
  /// or missing permission), which is what an unsupported codec looks like.
  private var lastErrorWasStreamFailure = false
  /// The photo child's state, for the hand-over between the children.
  private var photoStateValue: PhotoState = .stopped
  private var photoStartRequested = false
  /// A standalone photo is being taken: the stream is set aside on purpose.
  private var isTakingStandalonePhoto = false
  /// A start is in progress; a second caller returns at once instead of
  /// asking for permission or creating a session again.
  private var isStartingSession = false
  /// Photo-child startups tried on this session. Meta: startup is the most
  /// common failure and the next attempt usually succeeds, so it is retried
  /// once on a fresh camera.
  private var photoStartAttempts = 0
  private var photoStartTimeoutTask: Task<Void, Never>?
  /// When bytes of a standalone photo last arrived, to tell a slow
  /// full-resolution transfer from a stuck one.
  private var lastTransferProgressAt: Date?
  /// One app-requested still capture at a time; photos that do not answer a
  /// pending request (shutter button, late arrivals) never reach vision.
  let stillPhotos = StillPhotoCoordinator()

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

  /// Applies the stream profile and transport chosen in Settings; they are
  /// used by the next camera (while the stream is stopped).
  func applyStreamProfileIfNeeded() {
    let profile = GlassesStreamProfile.current
    let transport = effectiveTransport
    frameIngestor.configure(legacyPreview: AssistantPreferences.usesLegacyPreview)
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

  func handleStartStreaming() async {
    // One start at a time: a second caller (the glasses coming back while the
    // launch start still runs) must not ask for permission or a session again.
    guard !isStartingSession else { return }
    isStartingSession = true
    defer { isStartingSession = false }
    glassesIssue = nil
    guard let wearables else {
      glassesIssue = .sdkUnavailable
      return
    }
    applyStreamProfileIfNeeded()
    do {
      let status = try await wearables.checkPermissionStatus(.camera)
      if status == .granted {
        await startSession()
        return
      }
      let requestStatus = try await wearables.requestPermission(.camera)
      if requestStatus == .granted {
        await startSession()
        return
      }
      glassesIssue = .permissionNeeded
    } catch {
      // Sleeping or out-of-range glasses are a wait state, not an error.
      let text = String(describing: error).lowercased()
      if text.contains("powered off") || text.contains("disconnected") || text.contains("no device") {
        NSLog("[Stream] glasses unavailable, waiting: %@", String(describing: error))
        glassesIssue = nil
      } else {
        glassesIssue = .reconnecting
      }
    }
  }

  /// Creates (or reuses) the device session, waits until it is started,
  /// attaches the camera and starts the stream.
  func startSession() async {
    guard let wearables, let deviceSelector else { return }
    armStartWatchdog()
    streamingStatus = .waiting
    let session: DeviceSession
    if let existing = deviceSession, existing.state != .stopped, existing.state != .stopping {
      session = existing
    } else {
      do {
        let created = try wearables.createSession(deviceSelector: deviceSelector)
        deviceSession = created
        // Subscribe before start() so no transition is missed.
        observeSession(created)
        deviceSessionState = .starting
        try created.start()
        session = created
      } catch {
        handleSessionError(error)
        cleanupSession()
        streamingStatus = .stopped
        return
      }
    }
    // `addCamera` returns nil until the session is started. A session that
    // stops meanwhile (glasses folded, the app switched cameras) ends the wait.
    _ = await waitUntil(timeout: 20) { session.state == .started || session.state == .stopped }
    guard session.state == .started else {
      NSLog("[Stream] device session did not start (state %@)", String(describing: session.state))
      if session.state != .stopped { glassesIssue = .reconnecting }
      if camera == nil { streamingStatus = .stopped }
      return
    }
    attachCameraIfNeeded(to: session)
    camera?.stream.start()
  }

  func stopSession() async {
    camera?.stop()
    deviceSession?.stop()
    guard await waitUntil(timeout: 3, { self.deviceSession == nil }) else {
      // No `stopped` arrived: forget the session anyway, so the next start
      // creates a fresh one.
      NSLog("[Stream] device session did not report stopped; cleared")
      clearCamera()
      cleanupSession()
      return
    }
  }

  private func observeSession(_ session: DeviceSession) {
    session.statePublisher.listen { [weak self] state in
      Task { @MainActor [weak self] in self?.handleSessionState(state) }
    }.store(in: sessionTokens)
    session.errorPublisher.listen { [weak self] error in
      Task { @MainActor [weak self] in self?.handleSessionError(error) }
    }.store(in: sessionTokens)
  }

  private func handleSessionState(_ state: DeviceSessionState) {
    NSLog("[GlassifAI] glasses session state: %@", String(describing: state))
    deviceSessionState = state
    if state == .stopped {
      clearCamera()
      cleanupSession()
    }
  }

  private func handleSessionError(_ error: Error) {
    lastStreamError = LogSanitizer.sanitize(error.localizedDescription, limit: 200)
    NSLog("[Stream] device session error: %@", lastStreamError ?? "")
  }

  private func cleanupSession() {
    sessionTokens.clear()
    deviceSession = nil
    deviceSessionState = .stopped
    photoStartAttempts = 0
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
      sessionGeneration += 1
      streamGeneration += 1
      photoStartRequested = false
      attachStreamListeners(created.stream, generation: streamGeneration)
      attachPhotoListeners(created.photo, generation: sessionGeneration)
      NSLog("[Stream] camera attached: %@ %@", streamProfile.requestedSummary, transport.shortLabel)
    } catch {
      handleSessionError(error)
    }
  }

  /// Detaches the camera (idempotent) so a later `addCamera` can register a
  /// new one, and cancels its listeners.
  private func clearCamera() {
    photoStartTimeoutTask?.cancel()
    camera?.stop()
    camera = nil
    streamTokens.clear()
    photoTokens.clear()
    photoStateValue = .stopped
    photoState = "stopped"
    photoStartRequested = false
    isTakingStandalonePhoto = false
    updateStatusFromState(.stopped)
  }

  private func attachStreamListeners(_ stream: MWDATCamera.Stream, generation: Int) {
    stream.statePublisher.listen { [weak self] state in
      Task { @MainActor [weak self] in
        guard let self, self.streamGeneration == generation else { return }
        self.updateStatusFromState(state)
        // The sensor is awake: the photo child can start on it now (a photo
        // start on a cold camera never finishes).
        if state == .streaming { self.startPhotoIfNeeded() }
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
      // Legacy preview path, foreground only. The ingestor already fed the
      // frame store, so vision works in this mode too.
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

    // In-stream photos (the preview's capture button). A photo that answers
    // a pending vision request goes to that request only.
    let photos = stillPhotos
    stream.photoDataPublisher.listen { [weak self] photoData in
      if photos.deliver(photoData.data) { return }
      Task { @MainActor [weak self] in
        guard let self, let image = UIImage(data: photoData.data) else { return }
        self.capturedPhoto = image
        self.showPhotoPreview = true
      }
    }.store(in: streamTokens)
  }

  private func attachPhotoListeners(_ photo: Photo, generation: Int) {
    photo.statePublisher.listen { [weak self] state in
      Task { @MainActor [weak self] in
        guard let self, self.sessionGeneration == generation else { return }
        let previous = self.photoStateValue
        self.photoStateValue = state
        self.photoState = String(describing: state)
        if state == .started { self.photoStartTimeoutTask?.cancel() }
        // Back to stopped while starting: the startup failed.
        if previous == .starting, state == .stopped {
          self.retryPhotoStartup(reason: "startup failed")
        }
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

  private func startPhotoIfNeeded() {
    guard !photoStartRequested, let camera else { return }
    photoStartRequested = true
    photoStartAttempts += 1
    camera.photo.start()
    // A photo child that is not started in time counts as a failed startup.
    photoStartTimeoutTask?.cancel()
    photoStartTimeoutTask = Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: 10_000_000_000)
      guard let self, !Task.isCancelled, self.camera === camera,
            self.photoStateValue != .started else { return }
      self.retryPhotoStartup(reason: "not started after 10 s")
    }
  }

  /// Meta's documented recovery for a photo child that would not start:
  /// stop the camera, add a new one and retry once (a stopped camera cannot
  /// be reused). The video stream pauses for a moment while it happens.
  private func retryPhotoStartup(reason: String) {
    guard photoStartAttempts < 2, !isTakingStandalonePhoto,
          let session = deviceSession, session.state == .started, camera != nil else {
      NSLog("[Stream] standalone photo unavailable (%@); video frames are used", reason)
      return
    }
    NSLog("[Stream] standalone photo %@; retrying once on a fresh camera", reason)
    clearCamera()
    attachCameraIfNeeded(to: session)
    camera?.stream.start()
  }

  private func handleStreamError(_ error: StreamError) {
    // Setting the stream aside for a photo is not a failure.
    guard !isTakingStandalonePhoto else { return }
    switch error {
    case .videoStreamingError, .internalError, .timeout:
      lastErrorWasStreamFailure = true
    default:
      lastErrorWasStreamFailure = false
    }
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

  // MARK: Still photos for vision

  /// One fresh still for a vision request. DAT 1.0: a standalone photo from
  /// the native sensor (`.full`, `.high`), taken by setting the stream aside,
  /// because the two children compete for the camera; the stream starts
  /// again however the capture ends. nil when it is not possible (the caller
  /// then uses the best video frame).
  func captureStillForVision(timeout: TimeInterval) async -> StillPhoto? {
    // A paused session suspends transports; nothing would arrive.
    guard streamingStatus == .streaming, deviceSessionState == .started, let camera else { return nil }
    guard photoStateValue == .started else {
      NSLog("[Stream] standalone photo not ready (%@)", photoState)
      return nil
    }
    FrameStore.shared.recordPhotoRequest()
    isTakingStandalonePhoto = true
    defer { isTakingStandalonePhoto = false }
    // Frames and stills compete for the sensor; a running stream wins.
    camera.stream.stop()
    _ = await waitUntil(timeout: 2) { camera.stream.state == .stopped }
    // A full-resolution still takes a few seconds to cross the link. Up to
    // 15 s in any case, and up to 30 s while bytes are still arriving (Meta
    // fails a capture after 30 s of silence).
    let requestedAt = Date()
    lastTransferProgressAt = nil
    let photos = stillPhotos
    let transferWatch = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 500_000_000)
        guard let self, !Task.isCancelled else { return }
        let elapsed = Date().timeIntervalSince(requestedAt)
        let arriving = self.lastTransferProgressAt.map { Date().timeIntervalSince($0) < 3 } ?? false
        if elapsed > max(timeout, 15), !arriving {
          photos.cancel()
          return
        }
      }
    }
    let photo = await stillPhotos.capture(timeout: 30) {
      camera.photo.capturePhoto(resolution: .full, quality: .high)
      return true
    }
    transferWatch.cancel()
    FrameStore.shared.recordPhoto(
      width: photo?.width, height: photo?.height, latencyMs: photo?.latencyMs, success: photo != nil)
    // The session may have ended during the capture (glasses folded).
    guard self.camera === camera else { return photo }
    // Whether listeners survive a stream stop and start is not documented,
    // so the stream's are taken out afresh before it starts again.
    streamTokens.clear()
    streamGeneration += 1
    attachStreamListeners(camera.stream, generation: streamGeneration)
    camera.stream.start()
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
    let generation = sessionGeneration
    watchdogTask = Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: GlassesTransportWatchdog.gracePeriodNanoseconds)
      guard let self, !Task.isCancelled, self.sessionGeneration == generation,
            self.streamingStatus == .streaming, self.activeTransport == .hevc else { return }
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

  /// Replaces the camera with a raw one on the same session.
  private func fallBackToRaw(reason: String) async {
    guard activeTransport == .hevc, let session = deviceSession else { return }
    NSLog("[Stream] HEVC transport fallback to raw: %@", reason)
    fallbackFrom = .hevc
    transportNote = "Switched to raw automatically: \(reason)"
    clearCamera()
    guard await waitUntil(timeout: 2, { session.state == .started }) else { return }
    attachCameraIfNeeded(to: session)
    camera?.stream.start()
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
      // Setting the stream aside for a standalone photo keeps the rest alive.
      if isTakingStandalonePhoto { return }
      currentVideoFrame = nil
      hasReceivedFirstFrame = false
      frameIngestor.resetFirstFrame()
      stillPhotos.cancel()
      watchdogTask?.cancel()
      streamingStatus = .stopped
    case .waitingForDevice, .starting, .stopping, .paused:
      if isTakingStandalonePhoto { return }
      streamingStatus = .waiting
    case .streaming:
      let wasStreaming = streamingStatus == .streaming
      streamingStatus = .streaming
      glassesIssue = nil
      startWatchdogTask?.cancel()
      lastErrorWasStreamFailure = false
      if !wasStreaming { armTransportWatchdog() }
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
