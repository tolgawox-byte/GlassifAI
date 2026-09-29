/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CoreMedia
import VideoToolbox

enum DecoderError: Error, Equatable {
  case invalidFormat
  case configurationError(OSStatus)
  case decodingFailed(OSStatus)
  /// After a reset, P-frames are skipped until the next keyframe.
  case waitingForKeyframe

  var status: OSStatus? {
    switch self {
    case .configurationError(let status), .decodingFailed(let status): status
    case .invalidFormat, .waitingForKeyframe: nil
    }
  }
}

/// Which VideoToolbox decoder the glasses stream uses.
enum GlassesDecoderMode: String, CaseIterable, Identifiable {
  /// Survives backgrounding. Meta's DAT sample (VideoFrameDecoder) forces it
  /// on iOS 17+: "iOS tears down hardware sessions when backgrounded, and a
  /// fresh one stalls until the next keyframe".
  case software
  /// Cheaper on screen; iOS removes it when the phone locks.
  case hardware

  static let defaultsKey = "autoloom.glasses.decoder"

  static var preferred: GlassesDecoderMode {
    GlassesDecoderMode(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .software
  }

  var id: String { rawValue }

  var label: String {
    switch self {
    case .software: L.t("Software — keeps working with the phone locked", "Yazılım — telefon kilitliyken de çalışır")
    case .hardware: L.t("Hardware — on screen only", "Donanım — yalnızca ekran açıkken")
    }
  }
}

/// Decodes compressed video frames (H.264/HEVC) into raw pixel buffers
/// using VTDecompressionSession, on the app's decode queue, in the foreground
/// and in the background (the `.hvc1` transport keeps streaming while the
/// phone is locked; the AI then reads these buffers, never the UI).
///
/// Recovery, all bounded: a session iOS invalidated is caught before the
/// next decode; three failures in a row (returned or reported in the output
/// callback) rebuild the session; a hardware session iOS took away is
/// rebuilt in software; a session that accepts frames but never returns an
/// image is rebuilt, in the other mode if this one never produced a frame.
/// A rebuilt session waits for the next keyframe, except that a keyframe
/// whose session just vanished is retried at once on the new session.
final class VideoDecoder {

  struct DecodedFrame {
    let pixelBuffer: CVPixelBuffer
    let presentationTimeStamp: CMTime
    let duration: CMTime
  }

  static let failureLimit = 3
  /// Accepted frames without an image before the session is rebuilt
  /// (about 3 s at 15 fps).
  static let silentLimit = 45

  private var decompressionSession: VTDecompressionSession?
  private var currentFormatDescription: CMFormatDescription?
  private var onFrameDecoded: ((DecodedFrame) -> Void)?
  private var onAsyncFailure: ((OSStatus) -> Void)?
  /// A fresh session cannot decode P-frames: wait for the next sync sample.
  private var needsKeyframe = true
  private(set) var mode: GlassesDecoderMode
  private var consecutiveFailures = 0
  private var acceptedWithoutImage = 0
  /// This mode has produced at least one image since it was chosen.
  private var modeProducedImage = false
  /// Written by the output callback during a decode call.
  private var callbackStatus: OSStatus = noErr
  private var callbackProducedImage = false
  private(set) var sessionsCreated = 0

  init(mode: GlassesDecoderMode = .preferred) {
    self.mode = mode
  }

  deinit {
    invalidateSession()
  }

  var usesSoftwareDecoder: Bool { mode == .software }
  var isAwaitingKeyframe: Bool { needsKeyframe }

  func setFrameCallback(_ callback: @escaping (DecodedFrame) -> Void) {
    onFrameDecoded = callback
  }

  /// Called when VideoToolbox reports a failure in its output callback.
  func setFailureCallback(_ callback: @escaping (OSStatus) -> Void) {
    onAsyncFailure = callback
  }

  /// Applies the decoder chosen in Settings; the next frame builds a new
  /// session when it changed.
  func setPreferredMode(_ preferred: GlassesDecoderMode) {
    guard preferred != mode else { return }
    mode = preferred
    modeProducedImage = false
    invalidateSession()
  }

  /// Starts over with a new session on the next keyframe (stall recovery).
  func restart(swapMode: Bool = false) {
    if swapMode {
      mode = mode == .software ? .hardware : .software
      modeProducedImage = false
    }
    consecutiveFailures = 0
    acceptedWithoutImage = 0
    invalidateSession()
  }

  func decode(_ sampleBuffer: CMSampleBuffer) throws {
    guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
      throw DecoderError.invalidFormat
    }

    if let session = decompressionSession {
      let sameFormat = currentFormatDescription.map {
        CMFormatDescriptionEqual($0, otherFormatDescription: formatDescription)
      } ?? false
      // A new resolution, or a session iOS invalidated (for example when the
      // app went to the background): replace it before a decode fails.
      if !sameFormat || !VTDecompressionSessionCanAcceptFormatDescription(session, formatDescription: formatDescription) {
        invalidateSession()
      }
    }
    if decompressionSession == nil {
      try createSession(formatDescription: formatDescription)
    }

    let keyframe = Self.isKeyframe(sampleBuffer)
    if needsKeyframe && !keyframe {
      throw DecoderError.waitingForKeyframe
    }

    guard let session = decompressionSession else {
      throw DecoderError.invalidFormat
    }

    var status = submit(sampleBuffer, to: session)
    if Self.sessionGone(status) {
      // The session vanished under us: hardware becomes software (iOS took
      // the hardware decoder away), and a keyframe is retried at once.
      if mode == .hardware {
        mode = .software
        modeProducedImage = false
      }
      invalidateSession()
      if keyframe {
        try createSession(formatDescription: formatDescription)
        if let fresh = decompressionSession {
          status = submit(sampleBuffer, to: fresh)
        }
      }
    }

    guard status == noErr else {
      noteFailure()
      throw DecoderError.decodingFailed(status)
    }

    needsKeyframe = false
    consecutiveFailures = 0
    if callbackProducedImage {
      acceptedWithoutImage = 0
      modeProducedImage = true
    } else {
      acceptedWithoutImage += 1
      if acceptedWithoutImage >= Self.silentLimit {
        // Frames go in, nothing comes out.
        restart(swapMode: !modeProducedImage)
        throw DecoderError.decodingFailed(kVTVideoDecoderMalfunctionErr)
      }
    }
  }

  /// Decodes one sample synchronously; returns the call's status, or the
  /// status the output callback reported.
  private func submit(_ sampleBuffer: CMSampleBuffer, to session: VTDecompressionSession) -> OSStatus {
    callbackStatus = noErr
    callbackProducedImage = false
    let result = Self.decodeFrame(sampleBuffer, with: session)
    guard result == noErr else { return result }
    VTDecompressionSessionWaitForAsynchronousFrames(session)
    return callbackStatus
  }

  private func noteFailure() {
    needsKeyframe = true
    consecutiveFailures += 1
    if consecutiveFailures >= Self.failureLimit {
      // Transient errors are tolerated; a persistent one rebuilds the
      // session, in the other mode if this one never produced an image.
      restart(swapMode: !modeProducedImage)
    }
  }

  static func sessionGone(_ status: OSStatus) -> Bool {
    status == kVTInvalidSessionErr || status == kVTVideoDecoderMalfunctionErr
      || status == kVTVideoDecoderNotAvailableNowErr
  }

  /// True for sync samples (keyframes). Samples without attachments are
  /// treated as sync, which is how single-frame tests and IDR-only streams
  /// arrive.
  static func isKeyframe(_ sampleBuffer: CMSampleBuffer) -> Bool {
    guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
      as? [[String: Any]], let first = attachments.first else { return true }
    let notSync = first[kCMSampleAttachmentKey_NotSync as String] as? Bool ?? false
    return !notSync
  }

  private static func decodeFrame(_ sampleBuffer: CMSampleBuffer, with session: VTDecompressionSession) -> OSStatus {
    var flagOut = VTDecodeInfoFlags(rawValue: 0)
    return VTDecompressionSessionDecodeFrame(
      session,
      sampleBuffer: sampleBuffer,
      flags: [._1xRealTimePlayback],
      frameRefcon: nil,
      infoFlagsOut: &flagOut
    )
  }

  func invalidateSession() {
    if let session = decompressionSession {
      VTDecompressionSessionInvalidate(session)
      decompressionSession = nil
    }
    currentFormatDescription = nil
    needsKeyframe = true
    acceptedWithoutImage = 0
  }

  /// Creates a session in the current mode, or in the other mode when the
  /// current one is refused.
  private func createSession(formatDescription: CMFormatDescription) throws {
    do {
      try createDecompressionSession(formatDescription: formatDescription, mode: mode)
    } catch {
      let other: GlassesDecoderMode = mode == .software ? .hardware : .software
      try createDecompressionSession(formatDescription: formatDescription, mode: other)
      mode = other
      modeProducedImage = false
    }
  }

  private func createDecompressionSession(formatDescription: CMFormatDescription, mode: GlassesDecoderMode) throws {
    // Bi-planar 4:2:0 is the decoders' native output: no colour conversion,
    // a third of the memory of BGRA (the frame store keeps a few recent
    // frames), and a luma plane the sharpness scorer reads directly. The
    // display layer and Core Image both render it natively.
    let attrs: [CFString: Any] = [
      kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
      kCVPixelBufferIOSurfacePropertiesKey: NSDictionary(),
    ]

    var outputCallback = VTDecompressionOutputCallbackRecord()
    outputCallback.decompressionOutputCallback = { refcon, _, status, _, imageBuffer, presentationTimeStamp, duration in
      guard let refcon else { return }
      let decoder = Unmanaged<VideoDecoder>.fromOpaque(refcon).takeUnretainedValue()
      guard status == noErr, let imageBuffer else {
        if status != noErr {
          decoder.callbackStatus = status
          decoder.onAsyncFailure?(status)
        }
        return
      }
      decoder.callbackProducedImage = true
      let frame = DecodedFrame(
        pixelBuffer: imageBuffer,
        presentationTimeStamp: presentationTimeStamp,
        duration: duration
      )
      decoder.onFrameDecoded?(frame)
    }
    outputCallback.decompressionOutputRefCon = Unmanaged.passUnretained(self).toOpaque()

    let specification: CFDictionary? = mode == .software
      ? [kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder as String: false] as CFDictionary
      : nil

    var session: VTDecompressionSession?
    let status = VTDecompressionSessionCreate(
      allocator: kCFAllocatorDefault,
      formatDescription: formatDescription,
      decoderSpecification: specification,
      imageBufferAttributes: attrs as CFDictionary,
      outputCallback: &outputCallback,
      decompressionSessionOut: &session
    )

    guard let session, status == noErr else {
      throw DecoderError.configurationError(status)
    }

    decompressionSession = session
    currentFormatDescription = formatDescription
    needsKeyframe = true
    acceptedWithoutImage = 0
    sessionsCreated += 1

    let subType = CMFormatDescriptionGetMediaSubType(formatDescription)
    NSLog("[VideoDecoder] Created %@ decompression session for codec: %@",
          mode.rawValue, FrameStore.fourCC(subType))
  }
}
