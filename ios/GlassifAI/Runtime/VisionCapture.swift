import CoreGraphics
import Foundation
import ImageIO
import QuartzCore
import UniformTypeIdentifiers

/// How much detail a visual question needs. `high` is used for reading text,
/// badges, labels, screens, VINs and similar fine detail.
///
/// Limits follow the Codex image path (long side ≤ 2048 px, ≤ 2500 patches of
/// 32 px); larger images are downsized by the server anyway, so sending them
/// only adds upload time.
enum VisionDetail: String, Equatable, CaseIterable {
  case standard
  case high

  static let maxPatches = 2_500
  static let patchSize = 32

  var maxLongSide: Int { self == .high ? 2_048 : 1_280 }
  var jpegQuality: Double { self == .high ? 0.92 : 0.8 }
  var maxBytes: Int { self == .high ? 2_600_000 : 1_000_000 }

  static func patches(width: Int, height: Int) -> Int {
    ((width + patchSize - 1) / patchSize) * ((height + patchSize - 1) / patchSize)
  }

  /// Largest size within this profile's limits, keeping the aspect ratio and
  /// never upscaling.
  func fittedSize(width: Int, height: Int) -> (width: Int, height: Int) {
    guard width > 0, height > 0 else { return (width, height) }
    var scale = min(1.0, Double(maxLongSide) / Double(max(width, height)))
    func size(_ scale: Double) -> (Int, Int) {
      (max(1, Int((Double(width) * scale).rounded())), max(1, Int((Double(height) * scale).rounded())))
    }
    while scale > 0.05 {
      let (w, h) = size(scale)
      if Self.patches(width: w, height: h) <= Self.maxPatches { break }
      scale *= 0.97
    }
    let (w, h) = size(scale)
    return (w, h)
  }
}

/// Where Ray-Ban vision requests get their image.
enum GlassesVisionCaptureMode: String, CaseIterable, Identifiable {
  /// Detail requests try a fresh still photo first; others use the freshest
  /// video frame. Each falls back to the other.
  case automatic
  case videoOnly = "video"
  case photoFirst = "photo"

  static let defaultsKey = "autoloom.camera.glassesVisionCapture"

  var id: String { rawValue }

  var label: String {
    switch self {
    case .automatic: "Automatic (photo for reading, video otherwise)"
    case .videoOnly: "Video frames only"
    case .photoFirst: "Still photo first"
    }
  }

  static var current: GlassesVisionCaptureMode {
    GlassesVisionCaptureMode(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .automatic
  }

  func prefersPhoto(for detail: VisionDetail) -> Bool {
    switch self {
    case .automatic: detail == .high
    case .videoOnly: false
    case .photoFirst: true
    }
  }

  var allowsPhoto: Bool { self != .videoOnly }
}

/// A still photo returned by the glasses for one specific request.
struct StillPhoto {
  let jpeg: Data
  let width: Int
  let height: Int
  let latencyMs: Int
}

/// Coordinates DAT still captures. The SDK's photo publisher carries no
/// request identifier (and also delivers photos taken with the glasses'
/// shutter button), so this keeps at most one app capture in flight, accepts a
/// photo only while that request is pending, and rejects anything late.
final class StillPhotoCoordinator: @unchecked Sendable {
  private let lock = NSLock()
  private var pending: (token: UUID, startedAt: CFTimeInterval, continuation: CheckedContinuation<StillPhoto?, Never>)?

  var isCapturing: Bool {
    lock.lock(); defer { lock.unlock() }
    return pending != nil
  }

  /// Starts one capture. `trigger` asks the SDK for a photo and returns false
  /// if it refused. Returns nil on refusal, timeout, cancellation, or when a
  /// capture is already in flight.
  func capture(timeout: TimeInterval, trigger: @escaping @MainActor () -> Bool) async -> StillPhoto? {
    let token = UUID()
    return await withTaskCancellationHandler {
      await withCheckedContinuation { (continuation: CheckedContinuation<StillPhoto?, Never>) in
        lock.lock()
        if pending != nil {
          lock.unlock()
          continuation.resume(returning: nil)
          return
        }
        pending = (token, CACurrentMediaTime(), continuation)
        lock.unlock()

        Task { @MainActor [weak self] in
          guard let self else { return }
          if !trigger() {
            self.finish(token: token, with: nil)
            return
          }
          try? await Task.sleep(nanoseconds: UInt64(max(timeout, 0.1) * 1_000_000_000))
          self.finish(token: token, with: nil)
        }
      }
    } onCancel: {
      self.finish(token: token, with: nil)
    }
  }

  /// Offers a photo from the SDK. Returns true when it answered a pending
  /// request; false means it was unsolicited or late and must be ignored for
  /// vision (for example a shutter-button photo).
  @discardableResult
  func deliver(_ data: Data) -> Bool {
    lock.lock()
    guard let current = pending else {
      lock.unlock()
      return false
    }
    pending = nil
    lock.unlock()
    let latency = Int(((CACurrentMediaTime() - current.startedAt) * 1_000).rounded())
    let size = StillPhotoProcessor.pixelSize(of: data)
    guard let size, !data.isEmpty else {
      current.continuation.resume(returning: nil)
      return true
    }
    current.continuation.resume(returning: StillPhoto(
      jpeg: data, width: size.width, height: size.height, latencyMs: latency))
    return true
  }

  func cancel() {
    lock.lock()
    let current = pending
    pending = nil
    lock.unlock()
    current?.continuation.resume(returning: nil)
  }

  private func finish(token: UUID, with photo: StillPhoto?) {
    lock.lock()
    guard let current = pending, current.token == token else {
      lock.unlock()
      return
    }
    pending = nil
    lock.unlock()
    current.continuation.resume(returning: photo)
  }
}

/// Validates a still photo and fits it to a vision profile, passing it through
/// untouched when it already fits (no needless recompression).
enum StillPhotoProcessor {
  static func pixelSize(of data: Data) -> (width: Int, height: Int)? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = properties[kCGImagePropertyPixelWidth] as? Int,
          let height = properties[kCGImagePropertyPixelHeight] as? Int,
          width > 0, height > 0 else { return nil }
    let orientation = properties[kCGImagePropertyOrientation] as? UInt32 ?? 1
    // Orientations 5–8 are rotated by 90°.
    return orientation >= 5 ? (height, width) : (width, height)
  }

  static func prepare(_ data: Data, detail: VisionDetail) -> VisionFrameEncoder.Output? {
    guard let size = pixelSize(of: data),
          let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    let fitted = detail.fittedSize(width: size.width, height: size.height)
    let isJPEG = (CGImageSourceGetType(source) as String?) == UTType.jpeg.identifier
    let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    let upright = (properties?[kCGImagePropertyOrientation] as? UInt32 ?? 1) == 1
    if isJPEG, upright, fitted.width == size.width, fitted.height == size.height, data.count <= detail.maxBytes {
      return VisionFrameEncoder.Output(
        jpeg: data, width: size.width, height: size.height, quality: 1, reencoded: false)
    }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: max(fitted.width, fitted.height),
      kCGImageSourceShouldCacheImmediately: true,
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
    var quality = detail.jpegQuality
    for _ in 0..<3 {
      let output = NSMutableData()
      guard let destination = CGImageDestinationCreateWithData(
        output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
      CGImageDestinationAddImage(
        destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
      guard CGImageDestinationFinalize(destination) else { return nil }
      if output.length <= detail.maxBytes {
        return VisionFrameEncoder.Output(
          jpeg: output as Data, width: image.width, height: image.height, quality: quality)
      }
      quality -= 0.15
    }
    return nil
  }
}
