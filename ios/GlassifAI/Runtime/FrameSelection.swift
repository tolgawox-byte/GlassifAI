import CoreVideo
import Foundation
import QuartzCore

/// Cheap quality measurements on a camera frame's luma, used to choose the
/// best of the last few frames for a vision request.
struct FrameQualityMetrics: Equatable {
  /// Variance of the Laplacian over the central region; higher is sharper.
  let sharpness: Double
  /// Mean luma (0…255) over the central region.
  let meanLuma: Double
  /// 16×16 luma thumbnail of the whole frame, for scene-change checks.
  let thumbnail: [UInt8]
}

enum FrameQuality {
  static let thumbnailSide = 16

  /// Reads luma from bi-planar 4:2:0 (plane 0) or BGRA buffers. Other formats
  /// return nil, and selection then falls back to the newest frame.
  static func measure(_ pixelBuffer: CVPixelBuffer) -> FrameQualityMetrics? {
    let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
    guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else { return nil }
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
    switch format {
    case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
      guard let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else { return nil }
      return measureLuma(LumaReader(
        base: UnsafePointer(base.assumingMemoryBound(to: UInt8.self)),
        stride: CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0),
        width: CVPixelBufferGetWidthOfPlane(pixelBuffer, 0),
        height: CVPixelBufferGetHeightOfPlane(pixelBuffer, 0),
        isBGRA: false))
    case kCVPixelFormatType_32BGRA:
      guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
      return measureLuma(LumaReader(
        base: UnsafePointer(base.assumingMemoryBound(to: UInt8.self)),
        stride: CVPixelBufferGetBytesPerRow(pixelBuffer),
        width: CVPixelBufferGetWidth(pixelBuffer),
        height: CVPixelBufferGetHeight(pixelBuffer),
        isBGRA: true))
    default:
      return nil
    }
  }

  struct LumaReader {
    let base: UnsafePointer<UInt8>
    let stride: Int
    let width: Int
    let height: Int
    let isBGRA: Bool

    @inline(__always)
    func luma(_ x: Int, _ y: Int) -> Int {
      let row = base + y * stride
      if isBGRA {
        let pixel = row + x * 4
        return (Int(pixel[2]) * 77 + Int(pixel[1]) * 150 + Int(pixel[0]) * 29) >> 8
      }
      return Int(row[x])
    }
  }

  static func measureLuma(_ reader: LumaReader) -> FrameQualityMetrics? {
    let width = reader.width
    let height = reader.height
    guard width >= 16, height >= 16 else { return nil }
    // Central 70 % of the frame, every second pixel: what the wearer is
    // looking at, at a few milliseconds per 720×1280 frame.
    let x0 = max(1, width * 15 / 100)
    let x1 = min(width - 2, width * 85 / 100)
    let y0 = max(1, height * 15 / 100)
    let y1 = min(height - 2, height * 85 / 100)
    var sum = 0.0
    var sumSquares = 0.0
    var lumaSum = 0.0
    var count = 0.0
    var y = y0
    while y <= y1 {
      var x = x0
      while x <= x1 {
        let center = reader.luma(x, y)
        let laplacian = reader.luma(x - 1, y) + reader.luma(x + 1, y)
          + reader.luma(x, y - 1) + reader.luma(x, y + 1) - 4 * center
        let value = Double(laplacian)
        sum += value
        sumSquares += value * value
        lumaSum += Double(center)
        count += 1
        x += 2
      }
      y += 2
    }
    guard count > 0 else { return nil }
    let mean = sum / count
    let variance = max(0, sumSquares / count - mean * mean)

    let side = thumbnailSide
    var thumbnail = [UInt8](repeating: 0, count: side * side)
    for cellY in 0..<side {
      for cellX in 0..<side {
        var total = 0
        for sampleY in 0..<4 {
          for sampleX in 0..<4 {
            let x = min(width - 1, ((cellX * 4 + sampleX) * width) / (side * 4) + width / (side * 8))
            let y = min(height - 1, ((cellY * 4 + sampleY) * height) / (side * 4) + height / (side * 8))
            total += reader.luma(x, y)
          }
        }
        thumbnail[cellY * side + cellX] = UInt8(clamping: total / 16)
      }
    }
    return FrameQualityMetrics(sharpness: variance, meanLuma: lumaSum / count, thumbnail: thumbnail)
  }

  /// Mean absolute difference between two thumbnails (0…255).
  static func sceneDifference(_ a: [UInt8], _ b: [UInt8]) -> Double {
    guard a.count == b.count, !a.isEmpty else { return 255 }
    var total = 0
    for index in 0..<a.count {
      total += abs(Int(a[index]) - Int(b[index]))
    }
    return Double(total) / Double(a.count)
  }
}

/// The frame chosen for one vision request and why.
struct FrameSelection {
  let frame: CapturedFrame
  let metrics: FrameQualityMetrics?
  /// Fresh frames that were available.
  let available: Int
  /// Frames actually compared (same scene as the newest frame).
  let compared: Int
  let ageMs: Int

  var summary: String {
    let sharpness = metrics.map { String(format: "sharpness %.0f", $0.sharpness) } ?? "unscored"
    return "best of \(compared)/\(available) recent, \(sharpness), age \(ageMs) ms"
  }
}

/// Picks the best recent frame: sharp, well exposed and fresh. Frames from
/// before a scene change (the wearer turned their head) are never used, and
/// every candidate must already be within the freshness limit.
enum FrameSelector {
  /// Mean thumbnail difference above which two frames show different views.
  static let sceneChangeThreshold = 22.0
  /// An older frame must beat the newest by this factor to be chosen.
  static let preferNewestMargin = 1.15

  static func select(
    from frames: [CapturedFrame],
    maxAge: CFTimeInterval,
    now: CFTimeInterval = CACurrentMediaTime(),
    measure: (CVPixelBuffer) -> FrameQualityMetrics? = FrameQuality.measure
  ) -> FrameSelection? {
    let fresh = frames
      .filter { now - $0.arrivedAt <= maxAge && now - $0.arrivedAt >= -0.5 }
      .sorted { $0.arrivedAt < $1.arrivedAt }
    guard let newest = fresh.last else { return nil }
    func ageMs(_ frame: CapturedFrame) -> Int {
      Int(((now - frame.arrivedAt) * 1_000).rounded())
    }
    guard let newestMetrics = measure(newest.pixelBuffer) else {
      return FrameSelection(frame: newest, metrics: nil, available: fresh.count, compared: 1, ageMs: ageMs(newest))
    }
    var best = (frame: newest, metrics: newestMetrics,
                score: score(newestMetrics, age: now - newest.arrivedAt, maxAge: maxAge) * preferNewestMargin)
    var compared = 1
    for frame in fresh.dropLast().reversed() {
      guard let metrics = measure(frame.pixelBuffer) else { continue }
      if FrameQuality.sceneDifference(metrics.thumbnail, newestMetrics.thumbnail) > sceneChangeThreshold {
        // The view changed after this frame; it and everything older no
        // longer show what the wearer is looking at.
        break
      }
      compared += 1
      let candidate = score(metrics, age: now - frame.arrivedAt, maxAge: maxAge)
      if candidate > best.score {
        best = (frame, metrics, candidate)
      }
    }
    return FrameSelection(
      frame: best.frame, metrics: best.metrics, available: fresh.count, compared: compared, ageMs: ageMs(best.frame))
  }

  static func score(_ metrics: FrameQualityMetrics, age: CFTimeInterval, maxAge: CFTimeInterval) -> Double {
    let freshness = 1.0 - 0.35 * min(1, max(0, age / max(maxAge, 0.001)))
    let exposure = metrics.meanLuma < 30 || metrics.meanLuma > 225 ? 0.6 : 1.0
    return metrics.sharpness * freshness * exposure
  }
}
