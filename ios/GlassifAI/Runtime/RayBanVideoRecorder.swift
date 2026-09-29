import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

/// Records the Ray-Ban camera's own video into QuickTime files.
///
/// HEVC transport: the compressed samples DAT delivers
/// (`VideoFrame.sampleBuffer`) are written as they are, with AVAssetWriter
/// passthrough: no decoding, no re-encoding, the glasses' own resolution and
/// timestamps. Meta's DAT sample records this way, and it keeps working while
/// the phone is locked because nothing needs the video hardware. A file
/// starts at a keyframe (earlier P-frames cannot be decoded).
///
/// Raw transport, or HEVC the writer refuses to pass through: the decoded
/// pixel buffers are encoded to HEVC instead (never upscaled), off the main
/// thread.
///
/// If the glasses change resolution mid-recording, the file ends there and a
/// new one starts at the next keyframe, so nothing is lost. Thread-safe:
/// samples arrive on the SDK's callback thread and the decode queue.
final class RayBanVideoRecorder: @unchecked Sendable {
  enum Mode: String, Equatable {
    case passthrough = "HEVC passthrough"
    case encode = "HEVC encode"
  }

  struct Segment: Equatable {
    let url: URL
    let duration: Double
    let width: Int
    let height: Int
    let codec: String
    let mode: Mode
    let frames: Int
  }

  enum StartError: Error, Equatable {
    case alreadyRecording
    case lowStorage
  }

  enum StopResult: Equatable {
    case completed([Segment])
    /// Nothing was written (stopped before the first keyframe arrived).
    case noRecording
    /// The writer failed; `partial` holds files finished before that.
    case failed(String, partial: [Segment])
  }

  /// Free space needed to start, and the level that ends a recording.
  static let minimumFreeBytes: Int64 = 300_000_000
  static let stopFreeBytes: Int64 = 80_000_000

  private let lock = NSLock()
  private let finishing = DispatchGroup()
  private let directory: URL
  private let freeBytes: () -> Int64
  private var active = false
  private var passthroughRefused = false
  private var writer: AVAssetWriter?
  private var input: AVAssetWriterInput?
  private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
  private var mode: Mode = .passthrough
  private var segmentURL: URL?
  private var segmentFormat: CMFormatDescription?
  private var segmentFirstPTS: CMTime?
  private var segmentLastPTS: CMTime?
  private var segmentFrames = 0
  private var segmentWidth = 0
  private var segmentHeight = 0
  private var segmentCodec = "—"
  private var finished: [Segment] = []
  private var failure: String?
  private var firstFrameAt: Date?
  private var framesSinceSpaceCheck = 0
  private var droppedFrames = 0

  /// Called once, on the main queue, when the first frame is written.
  var onStarted: (@Sendable (Date) -> Void)?
  /// Called on the main queue when the recorder stopped itself ("storage",
  /// or the writer's error).
  var onProblem: (@Sendable (String) -> Void)?

  init(
    directory: URL = FileManager.default.temporaryDirectory.appendingPathComponent("AutoLoomRecordings", isDirectory: true),
    freeBytes: @escaping () -> Int64 = RayBanVideoRecorder.availableBytes
  ) {
    self.directory = directory
    self.freeBytes = freeBytes
  }

  var isActive: Bool {
    lock.lock(); defer { lock.unlock() }
    return active
  }

  /// When the first frame was written (the recording's real start).
  var startedAt: Date? {
    lock.lock(); defer { lock.unlock() }
    return firstFrameAt
  }

  var currentMode: Mode {
    lock.lock(); defer { lock.unlock() }
    return mode
  }

  var dropped: Int {
    lock.lock(); defer { lock.unlock() }
    return droppedFrames
  }

  static func availableBytes() -> Int64 {
    let url = FileManager.default.temporaryDirectory
    let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
    return values?.volumeAvailableCapacityForImportantUsage ?? Int64.max
  }

  func start() throws {
    lock.lock(); defer { lock.unlock() }
    guard !active else { throw StartError.alreadyRecording }
    guard freeBytes() >= Self.minimumFreeBytes else { throw StartError.lowStorage }
    // Written while the phone may be locked: readable after the first unlock.
    try? FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true,
      attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
    active = true
    passthroughRefused = false
    mode = .passthrough
    finished = []
    failure = nil
    firstFrameAt = nil
    framesSinceSpaceCheck = 0
    droppedFrames = 0
  }

  /// Every glasses sample as DAT delivered it (compressed or raw).
  func append(_ sampleBuffer: CMSampleBuffer) {
    lock.lock(); defer { lock.unlock() }
    guard active else { return }
    let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
    if let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
      // Raw transport: the SDK already decoded the frame.
      if pts.isNumeric { appendPixelBufferLocked(imageBuffer, pts: pts) }
      return
    }
    guard !passthroughRefused, CMSampleBufferGetDataBuffer(sampleBuffer) != nil,
          let format = CMSampleBufferGetFormatDescription(sampleBuffer), pts.isNumeric else { return }
    if writer != nil, mode == .passthrough, let current = segmentFormat,
       !CMFormatDescriptionEqual(current, otherFormatDescription: format) {
      // New resolution: this file ends here; the next starts at a keyframe.
      finishSegmentLocked()
    }
    if writer == nil {
      guard VideoDecoder.isKeyframe(sampleBuffer) else { return }
      guard startPassthroughLocked(format: format, pts: pts) else {
        passthroughRefused = true
        return
      }
    }
    guard mode == .passthrough, let input else { return }
    if let last = segmentLastPTS, CMTimeCompare(pts, last) <= 0 {
      droppedFrames += 1
      return
    }
    guard input.isReadyForMoreMediaData else {
      droppedFrames += 1
      return
    }
    if input.append(sampleBuffer) {
      frameWrittenLocked(pts: pts)
    } else {
      writerFailedLocked()
    }
  }

  /// Decoded glasses frames; used only when passthrough was refused.
  func appendDecoded(_ pixelBuffer: CVPixelBuffer, pts: CMTime) {
    lock.lock(); defer { lock.unlock() }
    guard active, passthroughRefused, pts.isNumeric else { return }
    appendPixelBufferLocked(pixelBuffer, pts: pts)
  }

  /// Ends the recording and waits for the files to be finished.
  func stop() async -> StopResult {
    lock.lock()
    active = false
    finishSegmentLocked()
    lock.unlock()
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      finishing.notify(queue: .global(qos: .userInitiated)) { continuation.resume() }
    }
    lock.lock()
    let segments = finished
    let problem = failure
    finished = []
    failure = nil
    firstFrameAt = nil
    passthroughRefused = false
    lock.unlock()
    if let problem { return .failed(problem, partial: segments) }
    return segments.isEmpty ? .noRecording : .completed(segments)
  }

  // MARK: Writing (lock held)

  private func newSegmentURL() -> URL {
    directory.appendingPathComponent("RayBan-\(UUID().uuidString).mov")
  }

  private func startPassthroughLocked(format: CMFormatDescription, pts: CMTime) -> Bool {
    let url = newSegmentURL()
    guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return false }
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: format)
    input.expectsMediaDataInRealTime = true
    guard writer.canAdd(input) else { return false }
    writer.add(input)
    guard writer.startWriting() else {
      try? FileManager.default.removeItem(at: url)
      return false
    }
    writer.startSession(atSourceTime: pts)
    let dimensions = CMVideoFormatDescriptionGetDimensions(format)
    beginSegmentLocked(
      writer: writer, input: input, adaptor: nil, url: url, mode: .passthrough, format: format, pts: pts,
      width: Int(dimensions.width), height: Int(dimensions.height),
      codec: FrameStore.fourCC(CMFormatDescriptionGetMediaSubType(format)))
    return true
  }

  private func startEncoderLocked(width: Int, height: Int, pts: CMTime) -> Bool {
    let url = newSegmentURL()
    guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return false }
    // The frames' own size; about 4 bits per pixel per second.
    let settings: [String: Any] = [
      AVVideoCodecKey: AVVideoCodecType.hevc,
      AVVideoWidthKey: width,
      AVVideoHeightKey: height,
      AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: max(2_000_000, width * height * 4)],
    ]
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
    input.expectsMediaDataInRealTime = true
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
    guard writer.canAdd(input) else { return false }
    writer.add(input)
    guard writer.startWriting() else {
      try? FileManager.default.removeItem(at: url)
      return false
    }
    writer.startSession(atSourceTime: pts)
    beginSegmentLocked(
      writer: writer, input: input, adaptor: adaptor, url: url, mode: .encode, format: nil, pts: pts,
      width: width, height: height, codec: "hvc1 (encoded)")
    return true
  }

  private func beginSegmentLocked(
    writer: AVAssetWriter, input: AVAssetWriterInput, adaptor: AVAssetWriterInputPixelBufferAdaptor?, url: URL,
    mode: Mode, format: CMFormatDescription?, pts: CMTime, width: Int, height: Int, codec: String
  ) {
    self.writer = writer
    self.input = input
    self.adaptor = adaptor
    self.mode = mode
    segmentURL = url
    segmentFormat = format
    segmentFirstPTS = pts
    segmentLastPTS = nil
    segmentFrames = 0
    segmentWidth = width
    segmentHeight = height
    segmentCodec = codec
  }

  private func appendPixelBufferLocked(_ pixelBuffer: CVPixelBuffer, pts: CMTime) {
    let width = CVPixelBufferGetWidth(pixelBuffer)
    let height = CVPixelBufferGetHeight(pixelBuffer)
    if writer != nil, mode != .encode || width != segmentWidth || height != segmentHeight {
      finishSegmentLocked()
    }
    if writer == nil {
      guard startEncoderLocked(width: width, height: height, pts: pts) else {
        failure = "the video encoder could not start"
        active = false
        report(problem: failure ?? "encoder")
        return
      }
    }
    guard let input, let adaptor else { return }
    if let last = segmentLastPTS, CMTimeCompare(pts, last) <= 0 {
      droppedFrames += 1
      return
    }
    guard input.isReadyForMoreMediaData else {
      droppedFrames += 1
      return
    }
    if adaptor.append(pixelBuffer, withPresentationTime: pts) {
      frameWrittenLocked(pts: pts)
    } else {
      writerFailedLocked()
    }
  }

  private func frameWrittenLocked(pts: CMTime) {
    segmentLastPTS = pts
    segmentFrames += 1
    if firstFrameAt == nil {
      let now = Date()
      firstFrameAt = now
      let callback = onStarted
      DispatchQueue.main.async { callback?(now) }
    }
    framesSinceSpaceCheck += 1
    if framesSinceSpaceCheck >= 150 {
      framesSinceSpaceCheck = 0
      if freeBytes() < Self.stopFreeBytes {
        // Keep what was recorded; the coordinator saves it and tells the user.
        active = false
        finishSegmentLocked()
        report(problem: "storage")
      }
    }
  }

  private func writerFailedLocked() {
    let reason = LogSanitizer.sanitize(writer?.error?.localizedDescription ?? "the video writer failed", limit: 160)
    let url = segmentURL
    let wasPassthrough = mode == .passthrough
    let empty = segmentFrames == 0
    writer?.cancelWriting()
    clearSegmentLocked()
    if let url { try? FileManager.default.removeItem(at: url) }
    if wasPassthrough && empty {
      // The writer refused the glasses' samples as they are: encode the
      // decoded frames instead.
      passthroughRefused = true
      return
    }
    failure = reason
    active = false
    report(problem: reason)
  }

  private func finishSegmentLocked() {
    guard let writer, let input, let url = segmentURL else {
      clearSegmentLocked()
      return
    }
    let frames = segmentFrames
    let first = segmentFirstPTS ?? .zero
    let last = segmentLastPTS ?? first
    let span = max(0, CMTimeGetSeconds(CMTimeSubtract(last, first)))
    // The last frame lasts about one frame interval.
    let duration = frames > 1 ? span + span / Double(frames - 1) : span
    let segmentMode = mode
    let width = segmentWidth
    let height = segmentHeight
    let codec = segmentCodec
    clearSegmentLocked()
    guard frames > 0 else {
      writer.cancelWriting()
      try? FileManager.default.removeItem(at: url)
      return
    }
    input.markAsFinished()
    finishing.enter()
    writer.finishWriting { [weak self] in
      guard let self else { return }
      self.lock.lock()
      if writer.status == .completed {
        self.finished.append(Segment(
          url: url, duration: duration, width: width, height: height, codec: codec, mode: segmentMode, frames: frames))
      } else {
        self.failure = self.failure
          ?? LogSanitizer.sanitize(writer.error?.localizedDescription ?? "the video could not be finished", limit: 160)
      }
      self.lock.unlock()
      self.finishing.leave()
    }
  }

  private func clearSegmentLocked() {
    writer = nil
    input = nil
    adaptor = nil
    segmentURL = nil
    segmentFormat = nil
    segmentFirstPTS = nil
    segmentLastPTS = nil
    segmentFrames = 0
  }

  private func report(problem: String) {
    let callback = onProblem
    DispatchQueue.main.async { callback?(problem) }
  }
}
