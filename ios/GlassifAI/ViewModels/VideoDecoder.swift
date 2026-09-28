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

/// Decodes compressed video frames (H.264/HEVC) into raw pixel buffers
/// using VTDecompressionSession. Runs on the app's decode queue in the
/// foreground and in the background (the `.hvc1` transport keeps streaming
/// while the phone is locked; the AI then reads these buffers, never the UI).
final class VideoDecoder {

  struct DecodedFrame {
    let pixelBuffer: CVPixelBuffer
    let presentationTimeStamp: CMTime
    let duration: CMTime
  }

  private var decompressionSession: VTDecompressionSession?
  private var currentFormatDescription: CMFormatDescription?
  private var onFrameDecoded: ((DecodedFrame) -> Void)?
  private var onAsyncFailure: ((OSStatus) -> Void)?
  /// A fresh session cannot decode P-frames: wait for the next sync sample.
  private var needsKeyframe = true
  /// Set when the hardware decoder was refused (for example in the
  /// background); the next session asks for a software decoder.
  private(set) var usesSoftwareDecoder = false

  init() {}

  deinit {
    invalidateSession()
  }

  func setFrameCallback(_ callback: @escaping (DecodedFrame) -> Void) {
    onFrameDecoded = callback
  }

  /// Called when VideoToolbox reports a failure in its output callback.
  func setFailureCallback(_ callback: @escaping (OSStatus) -> Void) {
    onAsyncFailure = callback
  }

  /// Uses the hardware decoder again (for example back in the foreground).
  func preferHardware() {
    guard usesSoftwareDecoder else { return }
    usesSoftwareDecoder = false
    invalidateSession()
  }

  func decode(_ sampleBuffer: CMSampleBuffer) throws {
    guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
      throw DecoderError.invalidFormat
    }

    if let currentFormat = currentFormatDescription,
      !CMFormatDescriptionEqual(currentFormat, otherFormatDescription: formatDescription)
    {
      try recreateDecompressionSession(formatDescription: formatDescription)
    } else if decompressionSession == nil {
      try createDecompressionSession(formatDescription: formatDescription)
    }

    let keyframe = Self.isKeyframe(sampleBuffer)
    if needsKeyframe && !keyframe {
      throw DecoderError.waitingForKeyframe
    }

    guard var session = decompressionSession else {
      throw DecoderError.invalidFormat
    }

    var result = Self.decodeFrame(sampleBuffer, with: session)
    if result == kVTInvalidSessionErr || result == kVTVideoDecoderMalfunctionErr
      || result == kVTVideoDecoderNotAvailableNowErr
    {
      // The session became unusable (for example when the app went to the
      // background). A refused hardware decoder is retried in software.
      if result == kVTVideoDecoderNotAvailableNowErr && !usesSoftwareDecoder {
        usesSoftwareDecoder = true
      }
      try recreateDecompressionSession(formatDescription: formatDescription)
      guard keyframe, let fresh = decompressionSession else {
        throw DecoderError.decodingFailed(result)
      }
      session = fresh
      result = Self.decodeFrame(sampleBuffer, with: session)
    }

    guard result == noErr else {
      needsKeyframe = true
      throw DecoderError.decodingFailed(result)
    }

    needsKeyframe = false
    VTDecompressionSessionWaitForAsynchronousFrames(session)
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
      currentFormatDescription = nil
    }
    needsKeyframe = true
  }

  private func recreateDecompressionSession(formatDescription: CMFormatDescription) throws {
    invalidateSession()
    try createDecompressionSession(formatDescription: formatDescription)
  }

  private func createDecompressionSession(formatDescription: CMFormatDescription) throws {
    // Bi-planar 4:2:0 is the hardware decoder's native output: no colour
    // conversion, a third of the memory of BGRA (the frame store keeps a few
    // recent frames), and a luma plane the sharpness scorer reads directly.
    // The display layer and Core Image both render it natively.
    let attrs: [CFString: Any] = [
      kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
      kCVPixelBufferIOSurfacePropertiesKey: NSDictionary(),
    ]

    var outputCallback = VTDecompressionOutputCallbackRecord()
    outputCallback.decompressionOutputCallback = { refcon, _, status, _, imageBuffer, presentationTimeStamp, duration in
      guard let refcon else { return }
      let decoder = Unmanaged<VideoDecoder>.fromOpaque(refcon).takeUnretainedValue()
      guard status == noErr, let imageBuffer else {
        if status != noErr { decoder.onAsyncFailure?(status) }
        return
      }
      let frame = DecodedFrame(
        pixelBuffer: imageBuffer,
        presentationTimeStamp: presentationTimeStamp,
        duration: duration
      )
      decoder.onFrameDecoded?(frame)
    }
    outputCallback.decompressionOutputRefCon = Unmanaged.passUnretained(self).toOpaque()

    // A software decoder when the hardware one was refused (background).
    let specification: CFDictionary? = usesSoftwareDecoder
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

    let subType = CMFormatDescriptionGetMediaSubType(formatDescription)
    let subTypeStr = String(format: "%c%c%c%c",
                            (subType >> 24) & 0xFF,
                            (subType >> 16) & 0xFF,
                            (subType >> 8) & 0xFF,
                            subType & 0xFF)
    NSLog("[VideoDecoder] Created %@ decompression session for codec: %@",
          usesSoftwareDecoder ? "software" : "hardware", subTypeStr)
  }
}
