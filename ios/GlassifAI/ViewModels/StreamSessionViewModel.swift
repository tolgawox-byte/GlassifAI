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

/// Resolution / frame-rate trade-offs for the glasses stream. Over Bluetooth
/// the glasses compress harder at higher resolution and frame rate, so fewer
/// frames can mean sharper frames. `balanced` is the original configuration.
enum GlassesStreamProfile: String, CaseIterable, Identifiable {
  case balanced
  case smooth
  case sharp

  static let defaultsKey = "autoloom.glasses.profile"

  static var current: GlassesStreamProfile {
    GlassesStreamProfile(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .balanced
  }

  var id: String { rawValue }

  var label: String {
    switch self {
    case .balanced: "Balanced — 720p request, 24 fps (original)"
    case .smooth: "Smooth — 504p, 30 fps"
    case .sharp: "Sharper frames — 720p request, 15 fps"
    }
  }

  var resolution: StreamingResolution {
    switch self {
    case .balanced, .sharp: .high
    case .smooth: .medium
    }
  }

  var frameRateLabel: String {
    switch self {
    case .balanced: "24"
    case .smooth: "30"
    case .sharp: "15"
    }
  }

  func makeConfig() -> StreamSessionConfig {
    switch self {
    case .balanced:
      StreamSessionConfig(videoCodec: VideoCodec.raw, resolution: StreamingResolution.high, frameRate: 24)
    case .smooth:
      StreamSessionConfig(videoCodec: VideoCodec.raw, resolution: StreamingResolution.medium, frameRate: 30)
    case .sharp:
      StreamSessionConfig(videoCodec: VideoCodec.raw, resolution: StreamingResolution.high, frameRate: 15)
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
  @Published private(set) var streamProfile: GlassesStreamProfile = .balanced
  @Published private(set) var lastStreamState = "stopped"

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
  // VideoDecoder for decompressing HEVC/H.264 frames in background
  private let videoDecoder = VideoDecoder()
  private var backgroundFrameCount = 0
  private var bgDiagLogged = false
  private var lifecycleObservers: [NSObjectProtocol] = []

  init(wearables: WearablesInterface?) {
    self.wearables = wearables
    let profile = GlassesStreamProfile.current

    if let wearables {
      // Let the SDK auto-select from available devices
      let selector = AutoDeviceSelector(wearables: wearables)
      self.deviceSelector = selector
      // The profile's resolution is a request: DAT 0.4.0 cannot always honour
      // `.high`, and the glasses step resolution down on weak Bluetooth links.
      // Diagnostics shows the resolution that actually arrives.
      streamSession = StreamSession(streamSessionConfig: profile.makeConfig(), deviceSelector: selector)

      // Monitor device availability
      deviceMonitorTask = Task { @MainActor in
        for await device in selector.activeDeviceStream() {
          self.hasActiveDevice = device != nil
        }
      }
    } else {
      self.deviceSelector = nil
    }

    streamProfile = profile
    selectedResolution = profile.resolution
    frameIngestor.configure(legacyPreview: AssistantPreferences.usesLegacyPreview)
    setupVideoDecoder()
    attachListeners()
    observeLifecycle()
  }

  private func setupVideoDecoder() {
    // Background frames decoded by VideoToolbox go straight to the shared
    // frame store; no image conversion or JPEG encoding happens per frame.
    videoDecoder.setFrameCallback { decodedFrame in
      FrameStore.shared.ingest(
        pixelBuffer: decodedFrame.pixelBuffer,
        source: .glasses,
        presentationTime: decodedFrame.presentationTimeStamp)
    }
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

  /// Recreate the StreamSession with the current selectedResolution.
  /// Only call when not actively streaming.
  func updateResolution(_ resolution: StreamingResolution) {
    guard !isStreaming, let deviceSelector else { return }
    selectedResolution = resolution
    let config = StreamSessionConfig(
      videoCodec: VideoCodec.raw,
      resolution: resolution,
      frameRate: 24)
    streamSession = StreamSession(streamSessionConfig: config, deviceSelector: deviceSelector)
    attachListeners()
    NSLog("[Stream] Resolution changed to %@", resolutionLabel)
  }

  /// Applies the stream profile chosen in Settings. The session is only
  /// recreated when the profile changed and the stream is stopped, so the
  /// original configuration is untouched unless the user picks another one.
  func applyStreamProfileIfNeeded() {
    let profile = GlassesStreamProfile.current
    frameIngestor.configure(legacyPreview: AssistantPreferences.usesLegacyPreview)
    guard profile != streamProfile, !isStreaming, let deviceSelector else { return }
    streamSession = StreamSession(streamSessionConfig: profile.makeConfig(), deviceSelector: deviceSelector)
    streamProfile = profile
    selectedResolution = profile.resolution
    attachListeners()
    NSLog("[Stream] Stream profile changed to %@", profile.rawValue)
  }

  private func attachListeners() {
    guard let streamSession else { return }
    // Subscribe to session state changes using the DAT SDK listener pattern
    stateListenerToken = streamSession.statePublisher.listen { [weak self] state in
      Task { @MainActor [weak self] in
        self?.updateStatusFromState(state)
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

      // Legacy preview path (the original behaviour), and background frames
      // that arrive compressed.
      Task { @MainActor [weak self] in
        guard let self else { return }

        let isInBackground = UIApplication.shared.applicationState == .background

        if !isInBackground {
          self.backgroundFrameCount = 0
          self.bgDiagLogged = false
          if let image = videoFrame.makeUIImage() {
            self.currentVideoFrame = image
            if !self.hasReceivedFirstFrame {
              self.hasReceivedFirstFrame = true
            }
          }
        } else {
          // In background: makeUIImage() uses VideoToolbox GPU rendering which iOS suspends.
          // Instead, use our VideoDecoder (VTDecompressionSession) to decode compressed
          // frames into pixel buffers for the frame store.
          self.backgroundFrameCount += 1

          let sampleBuffer = videoFrame.sampleBuffer
          if CMSampleBufferGetDataBuffer(sampleBuffer) != nil {
            do {
              try self.videoDecoder.decode(sampleBuffer)
            } catch {
              if self.backgroundFrameCount <= 5 || self.backgroundFrameCount % 120 == 0 {
                NSLog("[Stream] Background frame #%d decode error: %@",
                      self.backgroundFrameCount, String(describing: error))
              }
            }
          }
        }
      }
    }

    // Subscribe to streaming errors
    errorListenerToken = streamSession.errorPublisher.listen { [weak self] error in
      Task { @MainActor [weak self] in
        guard let self else { return }
        // One voice: glasses-state conditions render as placeholder text on
        // the call screen, never as alert dialogs. Sleeping/absent glasses are
        // a plain wait; everything else maps to a typed issue.
        switch error {
        case .deviceNotConnected, .deviceNotFound:
          self.glassesIssue = nil
        case .hingesClosed:
          self.glassesIssue = .hingesClosed
        case .permissionDenied:
          self.glassesIssue = .permissionNeeded
        default:
          self.glassesIssue = .reconnecting
        }
        self.lastStreamError = self.formatStreamingError(error)
      }
    }

    updateStatusFromState(streamSession.state)

    // Subscribe to photo capture events
    photoDataListenerToken = streamSession.photoDataPublisher.listen { [weak self] photoData in
      Task { @MainActor [weak self] in
        guard let self else { return }
        guard let uiImage = UIImage(data: photoData.data) else { return }
        self.capturedPhoto = uiImage
        self.showPhotoPreview = true
      }
    }
  }

  /// Glasses-state conditions the call screen's placeholder can name --
  /// the app's own voice, replacing the sample's alert dialogs.
  enum GlassesIssue: Equatable {
    case sdkUnavailable
    case permissionNeeded
    case hingesClosed
    case reconnecting
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

  func startSession() async {
    await streamSession?.start()
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
      streamingStatus = .stopped
    case .waitingForDevice, .starting, .stopping, .paused:
      streamingStatus = .waiting
    case .streaming:
      streamingStatus = .streaming
      glassesIssue = nil
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
    case .audioStreamingError:
      return "Audio streaming failed. Please try again."
    case .permissionDenied:
      return "Camera permission denied. Please grant permission in Settings."
    case .hingesClosed:
      return "The hinges on the glasses were closed. Please open the hinges and try again."
    @unknown default:
      return "An unknown streaming error occurred."
    }
  }
}
