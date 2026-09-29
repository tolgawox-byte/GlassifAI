import CoreGraphics
import Foundation
import ImageIO

/// Quality hints for a dealer photo, measured on the phone: blur, exposure,
/// blown highlights (glare) and a near-copy of the previous photo of the
/// same vehicle. Only hints: the photo is always kept, and nothing is sent
/// anywhere to judge it.
struct PhotoQuality: Codable, Equatable {
  enum Issue: String, Codable, CaseIterable {
    case blurry, dark, bright, glare, duplicate
  }

  /// Variance of the Laplacian on a 320-pixel copy; higher is sharper.
  var sharpness: Double
  /// Mean brightness (0…255).
  var brightness: Double
  /// Share of nearly white pixels.
  var highlights: Double
  var issues: [Issue]

  /// One short suggestion for the most important issue, or nil.
  func hint(turkish: Bool) -> String? {
    guard let issue = issues.first else { return nil }
    switch issue {
    case .blurry:
      return turkish ? "Fotoğraf bulanık görünüyor; sabit durup tekrar çekebilirsin." : "It looks blurry; hold still and take it again."
    case .dark:
      return turkish ? "Fotoğraf karanlık; daha aydınlık bir açı dene." : "It's dark; try a brighter angle."
    case .bright:
      return turkish ? "Fotoğraf fazla parlak." : "It's overexposed."
    case .glare:
      return turkish ? "Parlama var; açıyı biraz değiştir." : "There's glare; change the angle a little."
    case .duplicate:
      return turkish ? "Bir öncekiyle neredeyse aynı." : "It's nearly the same as the previous one."
    }
  }
}

enum PhotoDirector {
  static let side = 320
  /// Below this the photo is called blurry (a 320-pixel copy; sharp car
  /// photos measure several hundred).
  static let blurThreshold = 40.0
  /// Mean difference of two 16×16 thumbnails (0…255) below which two
  /// photos are near copies.
  static let duplicateDifference = 6.0

  /// Thumbnails of the last photo of each vehicle, for near-copy checks.
  @MainActor static var lastThumbnails: [UUID: [UInt8]] = [:]

  struct Assessment {
    var quality: PhotoQuality
    /// 16×16 brightness thumbnail (FrameQuality format).
    var thumbnail: [UInt8]
  }

  static func assess(jpeg: Data) -> Assessment? {
    guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil) else { return nil }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceThumbnailMaxPixelSize: side,
      kCGImageSourceCreateThumbnailWithTransform: true,
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
    let width = image.width
    let height = image.height
    guard width >= 16, height >= 16 else { return nil }
    var pixels = [UInt8](repeating: 0, count: width * height)
    let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
      guard let context = CGContext(
        data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
      context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
      return true
    }
    guard drawn else { return nil }
    return Assessment(quality: measure(pixels, width: width, height: height), thumbnail: thumbnail(pixels, width: width, height: height))
  }

  /// Grayscale pixels (row-major) → the measurements and issues.
  static func measure(_ pixels: [UInt8], width: Int, height: Int) -> PhotoQuality {
    var sum = 0.0
    var sumSquares = 0.0
    var luma = 0.0
    var white = 0
    var count = 0.0
    for y in 1..<(height - 1) {
      for x in 1..<(width - 1) {
        let index = y * width + x
        let center = Int(pixels[index])
        let laplacian = Int(pixels[index - 1]) + Int(pixels[index + 1]) + Int(pixels[index - width]) + Int(pixels[index + width])
          - 4 * center
        sum += Double(laplacian)
        sumSquares += Double(laplacian * laplacian)
        luma += Double(center)
        if center >= 250 { white += 1 }
        count += 1
      }
    }
    guard count > 0 else { return PhotoQuality(sharpness: 0, brightness: 0, highlights: 0, issues: []) }
    let mean = sum / count
    let sharpness = max(0, sumSquares / count - mean * mean)
    let brightness = luma / count
    let highlights = Double(white) / count
    var issues: [PhotoQuality.Issue] = []
    if sharpness < blurThreshold { issues.append(.blurry) }
    if brightness < 45 {
      issues.append(.dark)
    } else if brightness > 215 {
      issues.append(.bright)
    } else if highlights > 0.06 {
      issues.append(.glare)
    }
    return PhotoQuality(sharpness: sharpness, brightness: brightness, highlights: highlights, issues: issues)
  }

  static func thumbnail(_ pixels: [UInt8], width: Int, height: Int) -> [UInt8] {
    let cells = FrameQuality.thumbnailSide
    var result = [UInt8](repeating: 0, count: cells * cells)
    for cellY in 0..<cells {
      for cellX in 0..<cells {
        let x0 = cellX * width / cells
        let x1 = max(x0 + 1, (cellX + 1) * width / cells)
        let y0 = cellY * height / cells
        let y1 = max(y0 + 1, (cellY + 1) * height / cells)
        var total = 0
        var count = 0
        for y in y0..<min(y1, height) {
          for x in x0..<min(x1, width) {
            total += Int(pixels[y * width + x])
            count += 1
          }
        }
        result[cellY * cells + cellX] = UInt8(clamping: count > 0 ? total / count : 0)
      }
    }
    return result
  }

  /// The photo's quality, with "duplicate" when it nearly copies the
  /// previous photo of the same vehicle.
  @MainActor
  static func review(_ assessment: Assessment, vehicleID: UUID) -> PhotoQuality {
    var quality = assessment.quality
    if let previous = lastThumbnails[vehicleID],
       FrameQuality.sceneDifference(previous, assessment.thumbnail) < duplicateDifference {
      quality.issues.append(.duplicate)
    }
    lastThumbnails[vehicleID] = assessment.thumbnail
    return quality
  }
}
