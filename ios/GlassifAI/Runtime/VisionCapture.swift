import CoreGraphics
import Foundation
import ImageIO
import QuartzCore
import UniformTypeIdentifiers

/// How much detail a visual question needs (the FAST / BALANCED /
/// HIGH_DETAIL vision profiles). `high` is used for reading text, badges,
/// labels, screens, VINs, dashboard warnings and similar fine detail.
///
/// Limits follow the Codex image path for `detail: high` (long side ≤ 2048 px,
/// ≤ 2500 patches of 32 px); larger images are downsized by the service
/// anyway, so sending them only adds upload time.
enum VisionDetail: String, Equatable, CaseIterable {
  case fast
  case standard
  case high

  static let maxPatches = 2_500
  static let patchSize = 32
  /// Frames with a long side below this are small enough to be enlarged for
  /// reading (the 720×1280 Ray-Ban stream); phone-camera frames are not.
  static let upscaleSourceLimit = 1_400
  /// Long side of an enlarged text crop.
  static let cropLongSide = 1_280
  static let maxCropScale = 3.0

  var label: String {
    switch self {
    case .fast: "Fast"
    case .standard: "Balanced"
    case .high: "High detail"
    }
  }

  var maxLongSide: Int {
    switch self {
    case .fast: 768
    case .standard: 1_280
    case .high: 2_048
    }
  }

  var jpegQuality: Double {
    switch self {
    case .fast: 0.75
    case .standard: 0.85
    case .high: 0.92
    }
  }

  var maxBytes: Int {
    switch self {
    case .fast: 450_000
    case .standard: 1_200_000
    case .high: 2_600_000
    }
  }

  /// How far a small frame may be enlarged for this profile.
  var maxUpscale: Double { self == .high ? 1.6 : 1.0 }

  static func patches(width: Int, height: Int) -> Int {
    ((width + patchSize - 1) / patchSize) * ((height + patchSize - 1) / patchSize)
  }

  /// Scales toward `scale`, shrinking until the patch budget fits.
  private static func fit(width: Int, height: Int, scale initial: Double) -> (width: Int, height: Int) {
    var scale = initial
    func size(_ scale: Double) -> (Int, Int) {
      (max(1, Int((Double(width) * scale).rounded())), max(1, Int((Double(height) * scale).rounded())))
    }
    while scale > 0.05 {
      let (w, h) = size(scale)
      if patches(width: w, height: h) <= maxPatches { break }
      scale *= 0.97
    }
    let (w, h) = size(scale)
    return (w, h)
  }

  /// Largest size within this profile's limits, keeping the aspect ratio and
  /// never upscaling.
  func fittedSize(width: Int, height: Int) -> (width: Int, height: Int) {
    guard width > 0, height > 0 else { return (width, height) }
    return Self.fit(width: width, height: height, scale: min(1.0, Double(maxLongSide) / Double(max(width, height))))
  }

  /// Like `fittedSize`, but a small source (below `upscaleSourceLimit`) is
  /// enlarged by up to `maxUpscale` within the long-side and patch limits.
  func upscaledSize(width: Int, height: Int) -> (width: Int, height: Int) {
    guard width > 0, height > 0, maxUpscale > 1, max(width, height) < Self.upscaleSourceLimit else {
      return fittedSize(width: width, height: height)
    }
    let scale = min(maxUpscale, Double(maxLongSide) / Double(max(width, height)))
    return Self.fit(width: width, height: height, scale: max(1.0, scale))
  }

  /// Size for an enlarged text crop: long side toward `cropLongSide`, at most
  /// `maxCropScale` times the crop, within the patch budget.
  static func cropTargetSize(width: Int, height: Int) -> (width: Int, height: Int, scale: Double) {
    guard width > 0, height > 0 else { return (width, height, 1) }
    let scale = min(maxCropScale, Double(cropLongSide) / Double(max(width, height)))
    let fitted = fit(width: width, height: height, scale: scale)
    return (fitted.width, fitted.height, Double(fitted.width) / Double(width))
  }
}

/// User preference for how much image detail vision requests use.
enum VisionQualityPreference: String, CaseIterable, Identifiable {
  /// Profile chosen per request (reading → high detail, colours → fast).
  case automatic
  /// Every visual question uses the high-detail profile.
  case alwaysHigh
  /// Smaller images except for reading requests.
  case dataSaver

  static let defaultsKey = "autoloom.vision.quality"

  static var current: VisionQualityPreference {
    VisionQualityPreference(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .automatic
  }

  var id: String { rawValue }

  var label: String {
    switch self {
    case .automatic: "Automatic (recommended)"
    case .alwaysHigh: "Always high detail"
    case .dataSaver: "Data saver (high detail only for reading)"
    }
  }
}

/// Picks the vision profile for a request from what the user asked. Reading
/// and fine-detail words always win over the voice model's own choice, so
/// "read this label" never goes out as a small image.
enum VisionQueryClassifier {
  private static let highDetailTerms = [
    // English
    "read", "text", "label", "sign", "menu", "price", "vin", "serial", "model number", "part number",
    "warning", "dashboard", "screen", "display", "document", "receipt", "badge", "emblem", "plate",
    "small", "tiny", "fine print", "code", "barcode", "qr", "number", "letters", "written", "says",
    "translate", "ingredient", "expiry", "expiration", "gauge", "odometer", "mileage",
    // Turkish
    "oku", "yazı", "yazıyor", "yazan", "yazılı", "etiket", "tabela", "levha", "menü", "fiyat",
    "şasi", "seri", "plaka", "rozet", "amblem", "uyarı", "ikaz", "gösterge", "ekran", "belge",
    "doküman", "fiş", "fatura", "küçük", "minik", "numara", "kod", "barkod", "çevir", "tercüme",
    "içindekiler", "son kullanma", "kilometre", "harf",
  ]

  private static let fastTerms = [
    "what color", "what colour", "which color", "which colour", "color is", "colour is",
    "hangi renk", "ne renk", "rengi ne", "renk",
  ]

  static func profile(
    for query: String,
    requested: VisionDetail,
    preference: VisionQualityPreference = .current
  ) -> VisionDetail {
    let text = query.lowercased(with: Locale(identifier: "tr_TR"))
    let english = query.lowercased()
    let reading = highDetailTerms.contains { term in
      containsWord(term, in: text) || containsWord(term, in: english)
    }
    if preference == .alwaysHigh || reading || requested == .high { return .high }
    let simple = fastTerms.contains { text.contains($0) || english.contains($0) }
    if preference == .dataSaver { return .fast }
    return simple ? .fast : requested
  }

  /// Word-prefix match, so "read" matches "reading" and "oku" matches
  /// "okur musun" but "sign" does not match "design".
  private static func containsWord(_ term: String, in text: String) -> Bool {
    var searchRange = text.startIndex..<text.endIndex
    while let range = text.range(of: term, range: searchRange) {
      if range.lowerBound == text.startIndex {
        return true
      }
      let before = text[text.index(before: range.lowerBound)]
      if !before.isLetter && !before.isNumber { return true }
      searchRange = range.upperBound..<text.endIndex
    }
    return false
  }
}

/// Where Ray-Ban vision requests get their image.
enum GlassesVisionCaptureMode: String, CaseIterable, Identifiable {
  /// The sharpest recent video frame; a still photo only when video stalls.
  /// Meta documents in-stream photos as frames lifted out of the video
  /// stream, so a photo adds latency without adding detail on DAT 0.5.
  case automatic
  case videoOnly = "video"
  case photoFirst = "photo"

  static let defaultsKey = "autoloom.camera.glassesVisionCapture"

  var id: String { rawValue }

  var label: String {
    switch self {
    case .automatic:
      GlassesSDKInfo.supportsFullResolutionPhoto
        ? "Automatic (full-resolution photo for reading, sharpest frame otherwise)"
        : "Automatic (sharpest recent frame; photo if video stalls)"
    case .videoOnly: "Video frames only"
    case .photoFirst: "Still photo first (experiment)"
    }
  }

  static var current: GlassesVisionCaptureMode {
    GlassesVisionCaptureMode(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .automatic
  }

  func prefersPhoto(for detail: VisionDetail) -> Bool {
    switch self {
    case .photoFirst: true
    // A standalone photo (DAT 1.0 `Camera.photo`) is far larger than a video
    // frame, so reading requests take it first; on DAT 0.5 an in-stream
    // photo adds latency without detail.
    case .automatic: detail == .high && GlassesSDKInfo.supportsFullResolutionPhoto
    case .videoOnly: false
    }
  }

  var allowsPhoto: Bool { self != .videoOnly }
}

/// Switches for the high-detail reading pipeline.
enum VisionAssistPreferences {
  static let textAssistKey = "autoloom.vision.textAssist"
  static let upscaleKey = "autoloom.vision.upscale"

  /// On-device OCR hints and an enlarged crop of the text area.
  static var textAssist: Bool {
    UserDefaults.standard.object(forKey: textAssistKey) as? Bool ?? true
  }

  /// Enlarges small frames toward the model's patch budget for reading.
  static var upscale: Bool {
    UserDefaults.standard.object(forKey: upscaleKey) as? Bool ?? true
  }
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
