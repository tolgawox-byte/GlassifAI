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

/// One camera frame as it arrived on the phone. Only the newest frame is kept.
struct CapturedFrame {
  let pixelBuffer: CVPixelBuffer
  let source: FrameSourceKind
  let arrivedAt: CFTimeInterval
  let presentationTime: CMTime
  let width: Int
  let height: Int
  let pixelFormat: OSType
  let sequence: UInt64

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

  private let lock = NSLock()
  private var latest: CapturedFrame?
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
    if presentationTime.isValid, presentationTime.isNumeric {
      let delta = CMTimeGetSeconds(CMTimeSubtract(hostNow, presentationTime))
      if delta >= 0, delta < 3 { transportMs = delta * 1_000 }
    }

    lock.lock()
    sequence &+= 1
    latest = CapturedFrame(
      pixelBuffer: pixelBuffer,
      source: source,
      arrivedAt: arrivedAt,
      presentationTime: presentationTime,
      width: width,
      height: height,
      pixelFormat: format,
      sequence: sequence)
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
    arrivals.removeAll()
    framesReceived = 0
    previewRendered = 0
    previewDropped = 0
    previewFailures = 0
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
  }

  private static let gpuContext = CIContext(options: [.cacheIntermediates: false])
  private static let cpuContext = CIContext(options: [.useSoftwareRenderer: true, .cacheIntermediates: false])
  private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)

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

/// Runs inline on the Meta SDK's frame callback thread. Keeps the work there to
/// one copy plus two pointer hand-offs so the callback returns immediately.
final class GlassesFrameIngestor: @unchecked Sendable {
  let renderer = LowLatencyPreviewRenderer()
  private let copier = PixelBufferCopier()
  private let lock = NSLock()
  private var legacyPreview = false
  private var inBackground = false
  private var sawFirstFrame = false

  func configure(legacyPreview: Bool) {
    lock.lock(); self.legacyPreview = legacyPreview; lock.unlock()
    FrameStore.shared.setPipelineDescription(
      mode: legacyPreview ? "Legacy (UIImage per frame on main thread)" : "Low-latency (sample buffer layer)",
      resolution: "full stream resolution, aspect-fill",
      conversions: legacyPreview
        ? "SDK makeUIImage per frame + 1 buffer copy"
        : "1 buffer copy, 0 UIImage, 0 JPEG (JPEG only on vision request)")
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

  func handle(_ sampleBuffer: CMSampleBuffer) -> Result {
    let arrivedAt = CACurrentMediaTime()
    lock.lock()
    let legacy = legacyPreview
    let background = inBackground
    let first = !sawFirstFrame
    sawFirstFrame = true
    lock.unlock()

    guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
      // Compressed sample: only the background decoder path can use it.
      return Result(handled: false, isFirstFrame: first)
    }
    guard let copy = copier.copy(imageBuffer) else {
      return Result(handled: false, isFirstFrame: first)
    }
    FrameStore.shared.ingest(
      pixelBuffer: copy,
      source: .glasses,
      presentationTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
      arrivedAt: arrivedAt)
    if background {
      return Result(handled: true, isFirstFrame: first)
    }
    if legacy || renderer.hasFailed {
      return Result(handled: false, isFirstFrame: first)
    }
    renderer.submit(pixelBuffer: copy)
    FrameStore.shared.recordProcessing(milliseconds: (CACurrentMediaTime() - arrivedAt) * 1_000)
    return Result(handled: true, isFirstFrame: first)
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
