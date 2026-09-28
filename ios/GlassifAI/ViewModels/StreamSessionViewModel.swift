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
// Core view model demonstrating video streaming from Meta wearable devices using the DAT SDK.
// This class showcases the key streaming patterns: device selection, session management,
// video frame handling, photo capture, and error handling.
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
  static let datVersion = "0.5.0"
  /// DAT 1.0 `Camera.photo`: standalone stills at up to the native sensor
  /// resolution. Not in DAT 0.5.0 (in-stream photos are video frames).
  static let supportsFullResolutionPhoto = false
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

  func makeConfig(transport: GlassesVideoTransport) -> StreamSessionConfig {
    StreamSessionConfig(videoCodec: transport.codec, resolution: resolution, frameRate: frameRate)
  }
}

/// How glasses frames reach the phone. HEVC (DAT 0.5+) delivers compressed
/// samples that this app decodes in hardware and keeps delivering while the
/// app is in the background; raw frames are decoded by the SDK and pause when
/// the app is backgrounded.
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
  /// Transport the current stream session was created with (may differ from
  /// the preference after an automatic fallback).
  @Published private(set) var activeTransport: GlassesVideoTransport = .hevc
  /// Why the app switched transports automatically, if it did.
  @Published private(set) var transportNote: String?
  /// Name, type and compatibility of the active glasses, for Diagnostics.
  @Published private(set) var deviceDescription = "—"

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

  // The core DAT SDK StreamSession - handles all streaming operations.
  // nil when the Wearables SDK is unavailable (simulator, or a build without
  // glasses); the iPhone camera path never touches it.
  private var streamSession: StreamSession?
  // Listener tokens are used to manage DAT SDK event subscriptions
  private var stateListenerToken: AnyListenerToken?
  private var videoFrameListenerToken: AnyListenerToken?
  private var errorListenerToken: AnyListenerToken?
  private var photoDataListenerToken: AnyListenerToken?
  private let wearables: WearablesInterface?
  private let deviceSelector: AutoDeviceSelector?
  private var deviceMonitorTask: Task<Void, Never>?
  private var lifecycleObservers: [NSObjectProtocol] = []
  /// Bumped whenever the stream session is replaced, so a late callback from
  /// a previous session can never change the current state.
  private var sessionGeneration = 0
  /// Set when HEVC produced no usable frames; the preferred transport is
  /// skipped until the user picks a different one.
  private var fallbackFrom: GlassesVideoTransport?
  private var watchdogTask: Task<Void, Never>?
  private var startWatchdogTask: Task<Void, Never>?
  /// The last stream error was a stream failure (not glasses off, folded,
  /// or missing permission), which is what an unsupported codec looks like.
  private var lastErrorWasStreamFailure = false
  /// One app-requested still capture at a time; photos that do not answer a
  /// pending request (shutter button, late arrivals) never reach vision.
  let stillPhotos = StillPhotoCoordinator()
  /// The HEVC to raw fallback is replacing the session: its stop is not a
  /// camera failure (read by `WearableConnectionCoordinator`).
  private(set) var isSwitchingTransport = false

  init(wearables: WearablesInterface?) {
    self.wearables = wearables
    let profile = GlassesStreamProfile.current
    let transport = GlassesVideoTransport.preferred

    if let wearables {
      // Let the SDK auto-select from available devices
      let selector = AutoDeviceSelector(wearables: wearables)
      self.deviceSelector = selector
      // The profile's resolution and frame rate are a request: the glasses
      // step resolution down on weak Bluetooth links. Diagnostics shows the
      // resolution and frame rate that actually arrive.
      streamSession = StreamSession(
        streamSessionConfig: profile.makeConfig(transport: transport), deviceSelector: selector)

      // Monitor device availability
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
    attachListeners()
    observeLifecycle()
  }

  private static func describe(_ device: Device) -> String {
    "\(device.nameOrId()) · \(device.deviceType().rawValue) · \(String(describing: device.compatibility()))"
  }

  /// The transport to use for the next session: the user's preference unless
  /// it already failed in this app run.
  private var effectiveTransport: GlassesVideoTransport {
    let preferred = GlassesVideoTransport.preferred
    if let fallbackFrom, fallbackFrom == preferred { return .raw }
    return preferred
  }

  /// Asks the glasses for a fresh still photo for one vision request.
  /// Returns nil when the stream is not running, the SDK refuses, or no photo
  /// arrives before the timeout.
  func captureStillForVision(timeout: TimeInterval) async -> StillPhoto? {
    guard streamingStatus == .streaming, streamSession != nil else { return nil }
    FrameStore.shared.recordPhotoRequest()
    let photo = await stillPhotos.capture(timeout: timeout) { [weak self] in
      guard let session = self?.streamSession else { return false }
      return session.capturePhoto(format: .jpeg)
    }
    FrameStore.shared.recordPhoto(
      width: photo?.width, height: photo?.height, latencyMs: photo?.latencyMs, success: photo != nil)
    return photo
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

  /// Applies the stream profile and transport chosen in Settings. The session
  /// is only recreated when one of them changed and the stream is stopped.
  func applyStreamProfileIfNeeded() {
    let profile = GlassesStreamProfile.current
    let transport = effectiveTransport
    frameIngestor.configure(legacyPreview: AssistantPreferences.usesLegacyPreview)
    if fallbackFrom != nil, fallbackFrom != GlassesVideoTransport.preferred {
      // The user picked another transport; a new attempt starts clean.
      fallbackFrom = nil
      transportNote = nil
    }
    guard profile != streamProfile || transport != activeTransport, !isStreaming, let deviceSelector else { return }
    recreateSession(profile: profile, transport: transport, selector: deviceSelector)
  }

  private func recreateSession(
    profile: GlassesStreamProfile,
    transport: GlassesVideoTransport,
    selector: AutoDeviceSelector
  ) {
    streamSession = StreamSession(
      streamSessionConfig: profile.makeConfig(transport: transport), deviceSelector: selector)
    streamProfile = profile
    activeTransport = transport
    selectedResolution = profile.resolution
    attachListeners()
    NSLog("[Stream] Stream session: %@ %@", profile.requestedSummary, transport.shortLabel)
  }

  private func attachListeners() {
    guard let streamSession else { return }
    sessionGeneration += 1
    let generation = sessionGeneration
    let previousTokens = [stateListenerToken, videoFrameListenerToken, errorListenerToken, photoDataListenerToken]
    Task {
      for token in previousTokens { await token?.cancel() }
    }

    // Subscribe to session state changes using the DAT SDK listener pattern
    stateListenerToken = streamSession.statePublisher.listen { [weak self] state in
      Task { @MainActor [weak self] in
        guard let self, self.sessionGeneration == generation else { return }
        self.updateStatusFromState(state)
      }
    }

    // Subscribe to video frames from the device camera. The SDK invokes this
    // inline on its decoder thread, so the fast path must not hop to the main
    // actor or retain the SDK's buffer.
    let ingestor = frameIngestor
    videoFrameListenerToken = streamSession.videoFramePublisher.listen { [weak self] videoFrame in
      let result = ingestor.handle(videoFrame.sampleBuffer)
      if result.isFirstFrame {
        Task { @MainActor [weak self] in
          self?.hasReceivedFirstFrame = true
        }
      }
      if result.handled { return }

      // Legacy preview path (the original behaviour), foreground only. The
      // ingestor has already fed the frame store (raw copy or decode), so
      // vision works in this mode too.
      Task { @MainActor [weak self] in
        guard let self, UIApplication.shared.applicationState != .background else { return }
        if let image = videoFrame.makeUIImage() {
          self.currentVideoFrame = image
          if !self.hasReceivedFirstFrame {
            self.hasReceivedFirstFrame = true
          }
        }
      }
    }

    // Subscribe to streaming errors
    errorListenerToken = streamSession.errorPublisher.listen { [weak self] error in
      Task { @MainActor [weak self] in
        guard let self, self.sessionGeneration == generation else { return }
        // One voice: glasses-state conditions render as placeholder text on
        // the call screen, never as alert dialogs. Sleeping/absent glasses are
        // a plain wait; everything else maps to a typed issue.
        switch error {
        case .videoStreamingError, .internalError, .timeout:
          self.lastErrorWasStreamFailure = true
        default:
          self.lastErrorWasStreamFailure = false
        }
        switch error {
        case .deviceNotConnected, .deviceNotFound:
          self.glassesIssue = nil
        case .hingesClosed:
          self.glassesIssue = .hingesClosed
        case .permissionDenied:
          self.glassesIssue = .permissionNeeded
        case .thermalCritical:
          self.glassesIssue = .thermal
        default:
          self.glassesIssue = .reconnecting
        }
        self.lastStreamError = self.formatStreamingError(error)
      }
    }

    updateStatusFromState(streamSession.state)

    // Subscribe to photo capture events. A photo that answers a pending vision
    // request goes to that request only; anything else keeps the original
    // preview behaviour and is never used for vision.
    let photos = stillPhotos
    photoDataListenerToken = streamSession.photoDataPublisher.listen { [weak self] photoData in
      if photos.deliver(photoData.data) { return }
      Task { @MainActor [weak self] in
        guard let self else { return }
        guard let uiImage = UIImage(data: photoData.data) else { return }
        self.capturedPhoto = uiImage
        self.showPhotoPreview = true
      }
    }
  }

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

  private func fallBackToRaw(reason: String) async {
    guard let deviceSelector, activeTransport == .hevc else { return }
    NSLog("[Stream] HEVC transport fallback to raw: %@", reason)
    fallbackFrom = .hevc
    transportNote = "Switched to raw automatically: \(reason)"
    isSwitchingTransport = true
    defer { isSwitchingTransport = false }
    await streamSession?.stop()
    recreateSession(profile: streamProfile, transport: .raw, selector: deviceSelector)
    await streamSession?.start()
  }

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

  /// Starts the stream only when it is stopped, so a second trigger never
  /// starts it twice.
  func startSession() async {
    guard let streamSession, streamSession.state == .stopped else { return }
    armStartWatchdog()
    await streamSession.start()
  }

  /// If an HEVC stream has not started 12 s after a start request and the
  /// SDK reported a stream failure (not glasses off, folded or permission),
  /// fall back to raw once, so the camera works even if HEVC is refused.
  private func armStartWatchdog() {
    guard activeTransport == .hevc, fallbackFrom == nil else { return }
    startWatchdogTask?.cancel()
    lastErrorWasStreamFailure = false
    let generation = sessionGeneration
    startWatchdogTask = Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: 12_000_000_000)
      guard let self, !Task.isCancelled, self.sessionGeneration == generation,
            self.activeTransport == .hevc, self.streamingStatus != .streaming,
            self.lastErrorWasStreamFailure,
            UIApplication.shared.applicationState == .active else { return }
      await self.fallBackToRaw(reason: "HEVC stream did not start (\(self.lastStreamError ?? "stream error"))")
    }
  }

  private func showError(_ message: String) {
    errorMessage = message
    showError = true
  }

  func stopSession() async {
    await streamSession?.stop()
  }

  func dismissError() {
    showError = false
    errorMessage = ""
  }

  func capturePhoto() {
    streamSession?.capturePhoto(format: .jpeg)
  }

  func dismissPhotoPreview() {
    showPhotoPreview = false
    capturedPhoto = nil
  }

  private func updateStatusFromState(_ state: StreamSessionState) {
    NSLog("[GlassifAI] glasses stream state: %@", String(describing: state))
    lastStreamState = String(describing: state)
    switch state {
    case .stopped:
      currentVideoFrame = nil
      hasReceivedFirstFrame = false
      frameIngestor.resetFirstFrame()
      stillPhotos.cancel()
      watchdogTask?.cancel()
      streamingStatus = .stopped
    case .waitingForDevice, .starting, .stopping, .paused:
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

  private func formatStreamingError(_ error: StreamSessionError) -> String {
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
    case .thermalCritical:
      return "The glasses are too warm. The camera may slow down or stop until they cool down."
    case .permissionDenied:
      return "Camera permission denied. Please grant permission in Settings."
    case .hingesClosed:
      return "The hinges on the glasses were closed. Please open the hinges and try again."
    @unknown default:
      return "An unknown streaming error occurred."
    }
  }
}
