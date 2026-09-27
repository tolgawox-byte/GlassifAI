import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import ImageIO
import QuartzCore
import SwiftUI
import UIKit

enum FrameSourceKind: String {
  case glasses = "Ray-Ban"
  case iPhone = "iPhone"
}

/// One camera frame as it arrived on the phone. The store keeps the newest
/// few so a vision request can pick the sharpest recent one.
struct CapturedFrame {
  let pixelBuffer: CVPixelBuffer
  let source: FrameSourceKind
  let arrivedAt: CFTimeInterval
  let presentationTime: CMTime
  let width: Int
  let height: Int
  let pixelFormat: OSType
  let sequence: UInt64
  /// Capture time on the host clock when the frame's timestamp is host-based
  /// (same time base as `arrivedAt`), otherwise nil.
  var captureTime: CFTimeInterval?
  /// FrameStore epoch at arrival. A camera-source switch starts a new epoch,
  /// so a frame from before the switch can be recognised and rejected.
  var epoch: UInt64 = 0

  var ageSeconds: CFTimeInterval { CACurrentMediaTime() - arrivedAt }
}

struct FrameMetricsSnapshot: Equatable {
  var source = "—"
  var inputWidth = 0
  var inputHeight = 0
  var pixelFormat = "—"
  var measuredFPS: Double = 0
  var framesReceived: UInt64 = 0
  var previewRendered: UInt64 = 0
  var previewDropped: UInt64 = 0
  var previewFailures: UInt64 = 0
  var processingMedianMs: Double?
  var processingP95Ms: Double?
  var transportMedianMs: Double?
  var transportP95Ms: Double?
  var lastFrameAgeMs: Int?
  var previewMode = "—"
  var previewResolution = "—"
  var conversionsPerFrame = "—"
  /// Most recent glasses sample buffer: codec FourCC and whether it arrived
  /// compressed (data buffer) or decoded (image buffer).
  var glassesCodec = "—"
  var glassesCompressed: Bool?
  var glassesSampleSize = "—"
  var rawSamples: UInt64 = 0
  var compressedSamples: UInt64 = 0
  var decodedFrames: UInt64 = 0
  var decodeFailures: UInt64 = 0
  var copyFailures: UInt64 = 0
  var latestSequence: UInt64 = 0
  var photosRequested: UInt64 = 0
  var photosReceived: UInt64 = 0
  var photoFailures: UInt64 = 0
  var lastPhotoResolution = "—"
  var lastPhotoLatencyMs: Int?
  var lastVisionImage = "—"

  var inputResolution: String {
    inputWidth > 0 ? "\(inputWidth)×\(inputHeight)" : "—"
  }
}

/// Fixed-size sample window for median / p95.
private struct SampleWindow {
  private var values: [Double] = []
  private let capacity: Int

  init(capacity: Int) { self.capacity = capacity }

  mutating func add(_ value: Double) {
    values.append(value)
    if values.count > capacity { values.removeFirst(values.count - capacity) }
  }

  mutating func reset() { values.removeAll() }

  func percentile(_ p: Double) -> Double? {
    guard !values.isEmpty else { return nil }
    let sorted = values.sorted()
    let index = min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * p).rounded())))
    return sorted[index]
  }
}

/// Thread-safe "latest frame wins" store shared by the Ray-Ban and iPhone
/// pipelines. Frame callbacks write here directly on their own queues; there is
/// no per-frame main-thread hop, no queue, and therefore no backlog.
final class FrameStore: @unchecked Sendable {
  static let shared = FrameStore()
  /// Recent frames kept for best-frame selection (about 0.5 s at 15 fps).
  /// iPhone frames are capture-pool buffers, so only the newest is kept.
  static let recentCapacity = 8

  private let lock = NSLock()
  private var latest: CapturedFrame?
  private var recent: [CapturedFrame] = []
  private var epoch: UInt64 = 0
  private var sequence: UInt64 = 0
  private var arrivals: [CFTimeInterval] = []
  private var framesReceived: UInt64 = 0
  private var previewRendered: UInt64 = 0
  private var previewDropped: UInt64 = 0
  private var previewFailures: UInt64 = 0
  private var processing = SampleWindow(capacity: 240)
  private var transport = SampleWindow(capacity: 240)
  private var previewMode = "—"
  private var previewResolution = "—"
  private var conversionsPerFrame = "—"
  private var glassesCodec = "—"
  private var glassesCompressed: Bool?
  private var glassesSampleSize = "—"
  private var rawSamples: UInt64 = 0
  private var compressedSamples: UInt64 = 0
  private var decodedFrames: UInt64 = 0
  private var decodeFailures: UInt64 = 0
  private var copyFailures: UInt64 = 0
  private var photosRequested: UInt64 = 0
  private var photosReceived: UInt64 = 0
  private var photoFailures: UInt64 = 0
  private var lastPhotoResolution = "—"
  private var lastPhotoLatencyMs: Int?
  private var lastVisionImage = "—"

  /// Describes a glasses sample buffer as delivered by the Meta SDK.
  func recordGlassesSample(compressed: Bool, codec: String, width: Int, height: Int) {
    lock.lock()
    glassesCompressed = compressed
    glassesCodec = codec
    glassesSampleSize = width > 0 ? "\(width)×\(height)" : "—"
    if compressed { compressedSamples &+= 1 } else { rawSamples &+= 1 }
    lock.unlock()
  }

  func recordDecode(success: Bool) {
    lock.lock()
    if success { decodedFrames &+= 1 } else { decodeFailures &+= 1 }
    lock.unlock()
  }

  func recordCopyFailure() {
    lock.lock(); copyFailures &+= 1; lock.unlock()
  }

  func recordPhotoRequest() {
    lock.lock(); photosRequested &+= 1; lock.unlock()
  }

  func recordPhoto(width: Int?, height: Int?, latencyMs: Int?, success: Bool) {
    lock.lock()
    if success {
      photosReceived &+= 1
      if let width, let height { lastPhotoResolution = "\(width)×\(height)" }
      lastPhotoLatencyMs = latencyMs
    } else {
      photoFailures &+= 1
    }
    lock.unlock()
  }

  /// Short description of the image most recently sent to the vision model
  /// (never the image itself).
  func recordVisionImage(_ description: String) {
    lock.lock(); lastVisionImage = description; lock.unlock()
  }

  /// Records a new frame. `presentationTime` is checked against the host clock;
  /// when it is host-based the difference is the capture→phone latency.
  func ingest(
    pixelBuffer: CVPixelBuffer,
    source: FrameSourceKind,
    presentationTime: CMTime,
    arrivedAt: CFTimeInterval = CACurrentMediaTime()
  ) {
    let width = CVPixelBufferGetWidth(pixelBuffer)
    let height = CVPixelBufferGetHeight(pixelBuffer)
    let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
    let hostNow = CMClockGetTime(CMClockGetHostTimeClock())
    var transportMs: Double?
    var captureTime: CFTimeInterval?
    if presentationTime.isValid, presentationTime.isNumeric {
      let delta = CMTimeGetSeconds(CMTimeSubtract(hostNow, presentationTime))
      if delta >= 0, delta < 3 {
        transportMs = delta * 1_000
        captureTime = CMTimeGetSeconds(presentationTime)
      }
    }

    lock.lock()
    sequence &+= 1
    let frame = CapturedFrame(
      pixelBuffer: pixelBuffer,
      source: source,
      arrivedAt: arrivedAt,
      presentationTime: presentationTime,
      width: width,
      height: height,
      pixelFormat: format,
      sequence: sequence,
      captureTime: captureTime,
      epoch: epoch)
    latest = frame
    if source == .iPhone {
      recent.removeAll { $0.source == .iPhone }
    }
    recent.append(frame)
    if recent.count > Self.recentCapacity {
      recent.removeFirst(recent.count - Self.recentCapacity)
    }
    framesReceived &+= 1
    arrivals.append(arrivedAt)
    let cutoff = arrivedAt - 2
    if let firstValid = arrivals.firstIndex(where: { $0 >= cutoff }), firstValid > 0 {
      arrivals.removeFirst(firstValid)
    }
    if let transportMs { transport.add(transportMs) }
    lock.unlock()
  }

  func recordProcessing(milliseconds: Double) {
    lock.lock(); processing.add(milliseconds); lock.unlock()
  }

  func recordPreview(rendered: Bool = false, dropped: Bool = false, failed: Bool = false) {
    lock.lock()
    if rendered { previewRendered &+= 1 }
    if dropped { previewDropped &+= 1 }
    if failed { previewFailures &+= 1 }
    lock.unlock()
  }

  func setPipelineDescription(mode: String, resolution: String, conversions: String) {
    lock.lock()
    previewMode = mode
    previewResolution = resolution
    conversionsPerFrame = conversions
    lock.unlock()
  }

  func latestFrame() -> CapturedFrame? {
    lock.lock(); defer { lock.unlock() }
    return latest
  }

  func freshFrame(maxAge: CFTimeInterval, source: FrameSourceKind? = nil) -> CapturedFrame? {
    guard let frame = latestFrame(), frame.ageSeconds <= maxAge else { return nil }
    if let source, frame.source != source { return nil }
    return frame
  }

  /// Frames from one source that are at most `maxAge` old and belong to the
  /// current epoch, oldest first.
  func recentFrames(
    source: FrameSourceKind,
    maxAge: CFTimeInterval,
    now: CFTimeInterval = CACurrentMediaTime()
  ) -> [CapturedFrame] {
    lock.lock(); defer { lock.unlock() }
    return recent.filter { $0.source == source && $0.epoch == epoch && now - $0.arrivedAt <= maxAge }
  }

  /// Changes whenever the store is reset (camera source switch, privacy wipe).
  var currentEpoch: UInt64 {
    lock.lock(); defer { lock.unlock() }
    return epoch
  }

  /// Returns a frame no older than `maxAge`, waiting up to `timeout` for the
  /// camera to deliver one. Never returns a stale frame.
  func waitForFreshFrame(
    maxAge: CFTimeInterval,
    timeout: TimeInterval,
    source: FrameSourceKind? = nil
  ) async -> CapturedFrame? {
    let deadline = CACurrentMediaTime() + timeout
    while true {
      if let frame = freshFrame(maxAge: maxAge, source: source) { return frame }
      if CACurrentMediaTime() >= deadline || Task.isCancelled { return nil }
      try? await Task.sleep(nanoseconds: 25_000_000)
    }
  }

  /// Clears the cached frame and statistics, e.g. when the camera source
  /// changes, so a frame from the previous source can never answer a question.
  func reset() {
    lock.lock()
    latest = nil
    recent.removeAll()
    epoch &+= 1
    arrivals.removeAll()
    framesReceived = 0
    previewRendered = 0
    previewDropped = 0
    previewFailures = 0
    rawSamples = 0
    compressedSamples = 0
    decodedFrames = 0
    decodeFailures = 0
    copyFailures = 0
    processing.reset()
    transport.reset()
    lock.unlock()
  }

  func snapshot() -> FrameMetricsSnapshot {
    lock.lock(); defer { lock.unlock() }
    var snapshot = FrameMetricsSnapshot()
    if let latest {
      snapshot.source = latest.source.rawValue
      snapshot.inputWidth = latest.width
      snapshot.inputHeight = latest.height
      snapshot.pixelFormat = Self.fourCC(latest.pixelFormat)
      snapshot.lastFrameAgeMs = Int((latest.ageSeconds * 1_000).rounded())
    }
    let now = CACurrentMediaTime()
    let recent = arrivals.filter { $0 >= now - 2 }
    if recent.count >= 2, let first = recent.first, let last = recent.last, last > first {
      snapshot.measuredFPS = Double(recent.count - 1) / (last - first)
    }
    snapshot.framesReceived = framesReceived
    snapshot.previewRendered = previewRendered
    snapshot.previewDropped = previewDropped
    snapshot.previewFailures = previewFailures
    snapshot.processingMedianMs = processing.percentile(0.5)
    snapshot.processingP95Ms = processing.percentile(0.95)
    snapshot.transportMedianMs = transport.percentile(0.5)
    snapshot.transportP95Ms = transport.percentile(0.95)
    snapshot.previewMode = previewMode
    snapshot.previewResolution = previewResolution
    snapshot.conversionsPerFrame = conversionsPerFrame
    snapshot.glassesCodec = glassesCodec
    snapshot.glassesCompressed = glassesCompressed
    snapshot.glassesSampleSize = glassesSampleSize
    snapshot.rawSamples = rawSamples
    snapshot.compressedSamples = compressedSamples
    snapshot.decodedFrames = decodedFrames
    snapshot.decodeFailures = decodeFailures
    snapshot.copyFailures = copyFailures
    snapshot.latestSequence = sequence
    snapshot.photosRequested = photosRequested
    snapshot.photosReceived = photosReceived
    snapshot.photoFailures = photoFailures
    snapshot.lastPhotoResolution = lastPhotoResolution
    snapshot.lastPhotoLatencyMs = lastPhotoLatencyMs
    snapshot.lastVisionImage = lastVisionImage
    return snapshot
  }

  static func fourCC(_ code: OSType) -> String {
    let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
    if bytes.allSatisfy({ $0 >= 32 && $0 < 127 }) {
      return String(bytes: bytes, encoding: .ascii) ?? "\(code)"
    }
    return "\(code)"
  }
}

/// Encodes a camera frame for the vision model only when a vision task needs
/// it. The source pixel buffer is used directly — never a screenshot of the
/// preview — and is encoded exactly once.
enum VisionFrameEncoder {
  struct Output {
    let jpeg: Data
    let width: Int
    let height: Int
    let quality: Double
    /// False when an already-compressed photo was passed through unchanged.
    var reencoded = true
  }

  private static let gpuContext = CIContext(options: [.cacheIntermediates: false])
  private static let cpuContext = CIContext(options: [.useSoftwareRenderer: true, .cacheIntermediates: false])
  private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)

  /// Encodes with a vision profile: long side and patch count stay within
  /// what the Codex endpoint uses without further server-side downsizing.
  /// With `allowUpscale`, a small frame (the 720×1280 Ray-Ban stream) is
  /// enlarged toward the patch budget so small text covers more image patches.
  static func encode(
    _ pixelBuffer: CVPixelBuffer,
    detail: VisionDetail,
    useCPU: Bool = false,
    allowUpscale: Bool = false
  ) -> Output? {
    let width = CVPixelBufferGetWidth(pixelBuffer)
    let height = CVPixelBufferGetHeight(pixelBuffer)
    let target = allowUpscale
      ? detail.upscaledSize(width: width, height: height)
      : detail.fittedSize(width: width, height: height)
    if target.width > width || target.height > height {
      return render(
        CIImage(cvPixelBuffer: pixelBuffer),
        crop: nil,
        width: target.width,
        height: target.height,
        quality: detail.jpegQuality,
        maxBytes: detail.maxBytes,
        useCPU: useCPU)
    }
    return encode(
      pixelBuffer,
      maxLongSide: max(target.width, target.height),
      quality: detail.jpegQuality,
      maxBytes: detail.maxBytes,
      useCPU: useCPU)
  }

  /// Encodes an enlarged crop of `normalizedRect` (0…1, origin bottom-left as
  /// in Vision and Core Image) so small text in that region covers more of
  /// the model's image patches. Returns nil when the crop would not be
  /// meaningfully larger than it already is in the full image.
  static func encodeCrop(
    _ source: CIImage,
    normalizedRect: CGRect,
    detail: VisionDetail,
    useCPU: Bool = false
  ) -> Output? {
    let extent = source.extent
    guard extent.width > 0, extent.height > 0, !extent.isInfinite else { return nil }
    let rect = CGRect(
      x: extent.minX + normalizedRect.minX * extent.width,
      y: extent.minY + normalizedRect.minY * extent.height,
      width: normalizedRect.width * extent.width,
      height: normalizedRect.height * extent.height
    ).integral.intersection(extent)
    guard rect.width >= 24, rect.height >= 24 else { return nil }
    let target = VisionDetail.cropTargetSize(width: Int(rect.width), height: Int(rect.height))
    guard target.scale >= 1.25 else { return nil }
    return render(
      source,
      crop: rect,
      width: target.width,
      height: target.height,
      quality: detail.jpegQuality,
      maxBytes: detail.maxBytes,
      useCPU: useCPU)
  }

  /// Crops (optional) and resamples to an exact size with Lanczos, clamping
  /// the edges so resampling does not darken the border, then encodes once.
  static func render(
    _ source: CIImage,
    crop: CGRect?,
    width: Int,
    height: Int,
    quality: Double,
    maxBytes: Int,
    useCPU: Bool
  ) -> Output? {
    guard width > 0, height > 0, let colorSpace = sRGB else { return nil }
    var image = source
    if let crop {
      image = image.cropped(to: crop)
    }
    let inputExtent = image.extent
    guard inputExtent.width > 0, inputExtent.height > 0, !inputExtent.isInfinite else { return nil }
    image = image.transformed(by: CGAffineTransform(translationX: -inputExtent.minX, y: -inputExtent.minY))
    let scale = Double(height) / Double(inputExtent.height)
    let aspect = (Double(width) / Double(inputExtent.width)) / scale
    if abs(scale - 1) > 0.0001 || abs(aspect - 1) > 0.0001 {
      image = image.clampedToExtent().applyingFilter(
        "CILanczosScaleTransform",
        parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: aspect])
    }
    image = image.cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
    let context = useCPU ? cpuContext : gpuContext
    var currentQuality = quality
    for _ in 0..<3 {
      let options: [CIImageRepresentationOption: Any] = [
        CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): currentQuality
      ]
      guard let data = context.jpegRepresentation(of: image, colorSpace: colorSpace, options: options) else {
        return nil
      }
      if data.count <= maxBytes {
        return Output(jpeg: data, width: width, height: height, quality: currentQuality)
      }
      currentQuality -= 0.12
    }
    return nil
  }

  static func encode(
    _ pixelBuffer: CVPixelBuffer,
    maxLongSide: Int = 1_600,
    quality: Double = 0.82,
    maxBytes: Int = 1_400_000,
    useCPU: Bool = false
  ) -> Output? {
    var image = CIImage(cvPixelBuffer: pixelBuffer)
    let width = CVPixelBufferGetWidth(pixelBuffer)
    let height = CVPixelBufferGetHeight(pixelBuffer)
    let longSide = max(width, height)
    if longSide > maxLongSide {
      let scale = Double(maxLongSide) / Double(longSide)
      image = image.applyingFilter(
        "CILanczosScaleTransform",
        parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1.0])
    }
    let extent = image.extent.integral
    image = image.cropped(to: extent)
    guard let colorSpace = sRGB else { return nil }
    let context = useCPU ? cpuContext : gpuContext
    var currentQuality = quality
    for _ in 0..<3 {
      let options: [CIImageRepresentationOption: Any] = [
        CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): currentQuality
      ]
      guard let data = context.jpegRepresentation(of: image, colorSpace: colorSpace, options: options) else {
        return nil
      }
      if data.count <= maxBytes {
        return Output(jpeg: data, width: Int(extent.width), height: Int(extent.height), quality: currentQuality)
      }
      currentQuality -= 0.18
    }
    return nil
  }
}

/// Low-latency Ray-Ban preview: sample buffers go straight to an
/// AVSampleBufferDisplayLayer from the frame callback. A single pending slot
/// means a slow display replaces the waiting frame instead of queueing it.
final class LowLatencyPreviewRenderer: @unchecked Sendable {
  let displayLayer = AVSampleBufferDisplayLayer()

  private let queue = DispatchQueue(label: "com.autoloom.glasses.preview", qos: .userInteractive)
  private let lock = NSLock()
  private var pending: CMSampleBuffer?
  private var drainScheduled = false
  private var formatDescription: CMVideoFormatDescription?
  private var consecutiveFailures = 0
  private var isSuspended = false
  private var lastPreviewSize = ""

  /// Set when the display layer repeatedly fails; the UI then falls back to
  /// the legacy image preview.
  private(set) var hasFailed = false

  init() {
    displayLayer.videoGravity = .resizeAspectFill
    displayLayer.backgroundColor = UIColor.black.cgColor
  }

  func setSuspended(_ suspended: Bool) {
    lock.lock()
    isSuspended = suspended
    pending = nil
    lock.unlock()
    if !suspended {
      queue.async { [displayLayer] in displayLayer.sampleBufferRenderer.flush() }
    }
  }

  /// Uncompressed frame (the DAT `raw` codec, or decoded frames).
  func submit(pixelBuffer: CVPixelBuffer) {
    guard let sample = makeImmediateSample(pixelBuffer) else {
      FrameStore.shared.recordPreview(failed: true)
      return
    }
    enqueueLatest(sample)
  }

  /// Compressed frame; the display layer decodes it itself.
  func submit(compressed sampleBuffer: CMSampleBuffer) {
    Self.markDisplayImmediately(sampleBuffer)
    enqueueLatest(sampleBuffer)
  }

  func flush() {
    lock.lock(); pending = nil; lock.unlock()
    queue.async { [displayLayer] in displayLayer.sampleBufferRenderer.flush() }
  }

  private func enqueueLatest(_ sample: CMSampleBuffer) {
    lock.lock()
    if isSuspended || hasFailed {
      lock.unlock()
      return
    }
    if pending != nil { FrameStore.shared.recordPreview(dropped: true) }
    pending = sample
    let shouldSchedule = !drainScheduled
    drainScheduled = true
    lock.unlock()
    if shouldSchedule {
      queue.async { [weak self] in self?.drain() }
    }
  }

  private func drain() {
    lock.lock()
    let sample = pending
    pending = nil
    drainScheduled = false
    lock.unlock()
    guard let sample else { return }

    let renderer = displayLayer.sampleBufferRenderer
    if renderer.status == .failed || renderer.requiresFlushToResumeDecoding {
      renderer.flush()
      consecutiveFailures += 1
      FrameStore.shared.recordPreview(failed: true)
      if consecutiveFailures >= 5 {
        lock.lock(); hasFailed = true; lock.unlock()
        NSLog("[AutoLoom] low-latency preview failed repeatedly; falling back to image preview")
        return
      }
    } else {
      consecutiveFailures = 0
    }
    renderer.enqueue(sample)
    FrameStore.shared.recordPreview(rendered: true)
  }

  private func makeImmediateSample(_ pixelBuffer: CVPixelBuffer) -> CMSampleBuffer? {
    if formatDescription == nil
      || !CMVideoFormatDescriptionMatchesImageBuffer(formatDescription!, imageBuffer: pixelBuffer) {
      var description: CMVideoFormatDescription?
      CMVideoFormatDescriptionCreateForImageBuffer(
        allocator: kCFAllocatorDefault,
        imageBuffer: pixelBuffer,
        formatDescriptionOut: &description)
      formatDescription = description
    }
    guard let formatDescription else { return nil }
    var timing = CMSampleTimingInfo(
      duration: .invalid,
      presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
      decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    let status = CMSampleBufferCreateReadyWithImageBuffer(
      allocator: kCFAllocatorDefault,
      imageBuffer: pixelBuffer,
      formatDescription: formatDescription,
      sampleTiming: &timing,
      sampleBufferOut: &sample)
    guard status == noErr, let sample else { return nil }
    Self.markDisplayImmediately(sample)
    return sample
  }

  private static func markDisplayImmediately(_ sample: CMSampleBuffer) {
    guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
          CFArrayGetCount(attachments) > 0 else { return }
    let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
    CFDictionarySetValue(
      dictionary,
      Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
      Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
  }
}

/// Copies a decoder-owned pixel buffer into an app-owned IOSurface buffer so
/// the SDK's decoder pool is released immediately. Holding the SDK's own
/// buffers (for preview or for a later vision request) can exhaust that pool
/// and stall the glasses stream.
final class PixelBufferCopier: @unchecked Sendable {
  private var pool: CVPixelBufferPool?
  private var poolWidth = 0
  private var poolHeight = 0
  private var poolFormat: OSType = 0

  func copy(_ source: CVPixelBuffer) -> CVPixelBuffer? {
    let width = CVPixelBufferGetWidth(source)
    let height = CVPixelBufferGetHeight(source)
    let format = CVPixelBufferGetPixelFormatType(source)
    if pool == nil || width != poolWidth || height != poolHeight || format != poolFormat {
      let attributes: [CFString: Any] = [
        kCVPixelBufferPixelFormatTypeKey: format,
        kCVPixelBufferWidthKey: width,
        kCVPixelBufferHeightKey: height,
        kCVPixelBufferIOSurfacePropertiesKey: [String: Any](),
      ]
      let poolAttributes: [CFString: Any] = [kCVPixelBufferPoolMinimumBufferCountKey: 4]
      var newPool: CVPixelBufferPool?
      CVPixelBufferPoolCreate(
        kCFAllocatorDefault, poolAttributes as CFDictionary, attributes as CFDictionary, &newPool)
      pool = newPool
      poolWidth = width
      poolHeight = height
      poolFormat = format
    }
    guard let pool else { return nil }
    var destination: CVPixelBuffer?
    guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &destination) == kCVReturnSuccess,
          let destination else { return nil }

    CVPixelBufferLockBaseAddress(source, .readOnly)
    CVPixelBufferLockBaseAddress(destination, [])
    defer {
      CVPixelBufferUnlockBaseAddress(destination, [])
      CVPixelBufferUnlockBaseAddress(source, .readOnly)
    }
    if CVPixelBufferIsPlanar(source) {
      for plane in 0..<CVPixelBufferGetPlaneCount(source) {
        guard let from = CVPixelBufferGetBaseAddressOfPlane(source, plane),
              let to = CVPixelBufferGetBaseAddressOfPlane(destination, plane) else { return nil }
        Self.copyRows(
          from: from, fromStride: CVPixelBufferGetBytesPerRowOfPlane(source, plane),
          to: to, toStride: CVPixelBufferGetBytesPerRowOfPlane(destination, plane),
          rows: CVPixelBufferGetHeightOfPlane(source, plane))
      }
    } else {
      guard let from = CVPixelBufferGetBaseAddress(source),
            let to = CVPixelBufferGetBaseAddress(destination) else { return nil }
      Self.copyRows(
        from: from, fromStride: CVPixelBufferGetBytesPerRow(source),
        to: to, toStride: CVPixelBufferGetBytesPerRow(destination),
        rows: height)
    }
    CVBufferPropagateAttachments(source, destination)
    return destination
  }

  private static func copyRows(
    from: UnsafeMutableRawPointer, fromStride: Int,
    to: UnsafeMutableRawPointer, toStride: Int,
    rows: Int
  ) {
    if fromStride == toStride {
      memcpy(to, from, fromStride * rows)
      return
    }
    let length = min(fromStride, toStride)
    for row in 0..<rows {
      memcpy(to + row * toStride, from + row * fromStride, length)
    }
  }
}

/// Runs inline on the Meta SDK's frame callback thread and makes sure every
/// glasses frame that can be shown can also answer a vision question:
/// - decoded (image-buffer) samples: one copy into an app-owned buffer
/// - compressed (data-buffer) samples: hardware decode on a serial queue
/// Both paths feed the shared FrameStore as `.glasses`, in the foreground and
/// in the background, and feed the low-latency preview in the foreground.
final class GlassesFrameIngestor: @unchecked Sendable {
  let renderer = LowLatencyPreviewRenderer()
  private let copier = PixelBufferCopier()
  private let decoder = VideoDecoder()
  private let decodeQueue = DispatchQueue(label: "com.autoloom.glasses.decode", qos: .userInitiated)
  private let lock = NSLock()
  private var legacyPreview = false
  private var inBackground = false
  private var sawFirstFrame = false
  private var pendingDecodes = 0
  private let store: FrameStore

  init(store: FrameStore = .shared) {
    self.store = store
    decoder.setFrameCallback { [weak self] decoded in
      self?.handleDecoded(decoded)
    }
  }

  func configure(legacyPreview: Bool) {
    lock.lock(); self.legacyPreview = legacyPreview; lock.unlock()
    store.setPipelineDescription(
      mode: legacyPreview ? "Legacy (UIImage per frame on main thread)" : "Low-latency (sample buffer layer)",
      resolution: "full stream resolution, aspect-fill",
      conversions: legacyPreview
        ? "SDK makeUIImage per frame + 1 buffer copy or hardware decode"
        : "1 buffer copy (raw) or 1 hardware decode (compressed); 0 UIImage; JPEG only on vision request")
  }

  func setBackground(_ background: Bool) {
    lock.lock(); inBackground = background; lock.unlock()
    renderer.setSuspended(background)
  }

  func resetFirstFrame() {
    lock.lock(); sawFirstFrame = false; lock.unlock()
    renderer.flush()
  }

  var usesLegacyPreview: Bool {
    lock.lock(); defer { lock.unlock() }
    return legacyPreview || renderer.hasFailed
  }

  struct Result {
    /// The frame was fully handled here (stored and, in the foreground, shown).
    let handled: Bool
    /// True exactly once per stream, for the first frame.
    let isFirstFrame: Bool
  }

  /// Describes the sample buffer without touching its pixels.
  struct SampleInfo: Equatable {
    let compressed: Bool
    let codec: String
    let width: Int
    let height: Int
  }

  static func describe(_ sampleBuffer: CMSampleBuffer) -> SampleInfo {
    let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
    let format = CMSampleBufferGetFormatDescription(sampleBuffer)
    var codec = "—"
    var width = 0
    var height = 0
    if let imageBuffer {
      codec = FrameStore.fourCC(CVPixelBufferGetPixelFormatType(imageBuffer))
      width = CVPixelBufferGetWidth(imageBuffer)
      height = CVPixelBufferGetHeight(imageBuffer)
    } else if let format {
      codec = FrameStore.fourCC(CMFormatDescriptionGetMediaSubType(format))
      let dimensions = CMVideoFormatDescriptionGetDimensions(format)
      width = Int(dimensions.width)
      height = Int(dimensions.height)
    }
    let compressed = imageBuffer == nil && CMSampleBufferGetDataBuffer(sampleBuffer) != nil
    return SampleInfo(compressed: compressed, codec: codec, width: width, height: height)
  }

  func handle(_ sampleBuffer: CMSampleBuffer) -> Result {
    let arrivedAt = CACurrentMediaTime()
    lock.lock()
    let legacy = legacyPreview
    let background = inBackground
    let first = !sawFirstFrame
    sawFirstFrame = true
    lock.unlock()

    let info = Self.describe(sampleBuffer)
    store.recordGlassesSample(compressed: info.compressed, codec: info.codec, width: info.width, height: info.height)

    if let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
      // Decoded frame: copy it so the SDK's decoder pool is released at once.
      // If the buffer cannot be copied on the CPU (for example a GPU-only
      // format), keep the original reference rather than losing the frame.
      let frame: CVPixelBuffer
      if let copy = copier.copy(imageBuffer) {
        frame = copy
      } else {
        store.recordCopyFailure()
        frame = imageBuffer
      }
      store.ingest(
        pixelBuffer: frame,
        source: .glasses,
        presentationTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
        arrivedAt: arrivedAt)
      if background {
        return Result(handled: true, isFirstFrame: first)
      }
      if legacy || renderer.hasFailed {
        return Result(handled: false, isFirstFrame: first)
      }
      renderer.submit(pixelBuffer: frame)
      store.recordProcessing(milliseconds: (CACurrentMediaTime() - arrivedAt) * 1_000)
      return Result(handled: true, isFirstFrame: first)
    }

    guard info.compressed else {
      return Result(handled: false, isFirstFrame: first)
    }
    // Compressed frame: decode every frame in order (P-frames depend on the
    // previous ones). The decoded buffer reaches the store and, in the
    // foreground, the preview. A bounded backlog protects against a stalled
    // decoder; dropping a frame only costs one preview update, and decoding
    // resumes cleanly at the next keyframe.
    lock.lock()
    let backlog = pendingDecodes
    if backlog < 8 { pendingDecodes += 1 }
    lock.unlock()
    if backlog >= 8 {
      store.recordDecode(success: false)
      return Result(handled: !legacy || background, isFirstFrame: first)
    }
    decodeQueue.async { [weak self] in
      guard let self else { return }
      do {
        try self.decoder.decode(sampleBuffer)
      } catch {
        self.store.recordDecode(success: false)
        self.decoder.invalidateSession()
      }
      self.lock.lock(); self.pendingDecodes -= 1; self.lock.unlock()
    }
    // Legacy mode keeps the SDK's UIImage preview; the decoder still feeds
    // the store so vision works in every preview mode.
    return Result(handled: !legacy || background, isFirstFrame: first)
  }

  private func handleDecoded(_ decoded: VideoDecoder.DecodedFrame) {
    store.recordDecode(success: true)
    let arrivedAt = CACurrentMediaTime()
    store.ingest(
      pixelBuffer: decoded.pixelBuffer,
      source: .glasses,
      presentationTime: decoded.presentationTimeStamp,
      arrivedAt: arrivedAt)
    lock.lock()
    let showPreview = !legacyPreview && !inBackground
    lock.unlock()
    if showPreview && !renderer.hasFailed {
      renderer.submit(pixelBuffer: decoded.pixelBuffer)
    }
  }
}

struct LowLatencyPreviewView: UIViewRepresentable {
  let renderer: LowLatencyPreviewRenderer

  func makeUIView(context: Context) -> HostView {
    let view = HostView()
    view.backgroundColor = .black
    view.host(renderer.displayLayer)
    return view
  }

  func updateUIView(_ uiView: HostView, context: Context) {
    uiView.host(renderer.displayLayer)
  }

  final class HostView: UIView {
    private weak var hosted: CALayer?

    func host(_ layer: CALayer) {
      guard hosted !== layer else { return }
      hosted?.removeFromSuperlayer()
      self.layer.addSublayer(layer)
      hosted = layer
      setNeedsLayout()
    }

    override func layoutSubviews() {
      super.layoutSubviews()
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      hosted?.frame = bounds
      CATransaction.commit()
    }
  }
}
