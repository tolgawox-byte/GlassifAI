import CoreGraphics
import CoreImage
import Foundation
import QuartzCore
import Vision

/// One line of text found on the phone by Apple's Vision framework.
struct RecognizedTextLine: Equatable {
  let text: String
  let confidence: Float
  /// Normalized bounding box, origin at the bottom left (Vision and Core
  /// Image coordinates).
  let box: CGRect
}

struct TextRecognitionResult: Equatable {
  let lines: [RecognizedTextLine]
  let languages: [String]
  let durationMs: Int

  var averageConfidence: Float {
    lines.isEmpty ? 0 : lines.map(\.confidence).reduce(0, +) / Float(lines.count)
  }
}

/// On-device OCR used as a supporting hint for reading requests. The model
/// always receives the image as well; OCR text is extra context, never a
/// replacement, and is treated as untrusted content.
enum OnDeviceTextRecognizer {
  static let minimumLineConfidence: Float = 0.35
  static let minimumAverageConfidence: Float = 0.5
  static let preferredLanguages = ["tr-TR", "en-US"]
  static let maxLines = 40

  /// Recognizes text, giving up after `timeout` so a slow OCR pass never
  /// holds back the vision request.
  static func recognize(_ image: CIImage, timeout: TimeInterval) async -> TextRecognitionResult? {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    // Language correction "fixes" codes, VINs, part numbers and prices into
    // words; exact characters matter more here.
    request.usesLanguageCorrection = false
    let supported = (try? request.supportedRecognitionLanguages()) ?? []
    let languages = preferredLanguages.filter { supported.contains($0) }
    if !languages.isEmpty { request.recognitionLanguages = languages }
    let once = OnceFlag()
    return await withCheckedContinuation { (continuation: CheckedContinuation<TextRecognitionResult?, Never>) in
      DispatchQueue.global(qos: .userInitiated).async {
        let start = CACurrentMediaTime()
        let handler = VNImageRequestHandler(ciImage: image, options: [:])
        var result: TextRecognitionResult?
        if (try? handler.perform([request])) != nil {
          let lines = (request.results ?? []).compactMap { observation -> RecognizedTextLine? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, candidate.confidence >= OnDeviceTextRecognizer.minimumLineConfidence else { return nil }
            return RecognizedTextLine(text: text, confidence: candidate.confidence, box: observation.boundingBox)
          }
          result = TextRecognitionResult(
            lines: OnDeviceTextRecognizer.readingOrder(lines),
            languages: languages,
            durationMs: Int(((CACurrentMediaTime() - start) * 1_000).rounded()))
        }
        if once.claim() { continuation.resume(returning: result) }
      }
      DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
        if once.claim() {
          request.cancel()
          continuation.resume(returning: nil)
        }
      }
    }
  }

  /// Top-to-bottom, then left-to-right.
  static func readingOrder(_ lines: [RecognizedTextLine]) -> [RecognizedTextLine] {
    lines.sorted { a, b in
      if abs(a.box.midY - b.box.midY) > min(a.box.height, b.box.height) * 0.5 {
        return a.box.midY > b.box.midY
      }
      return a.box.minX < b.box.minX
    }
  }

  /// Text for the model, or nil when the result is too unreliable to help.
  static func promptText(_ result: TextRecognitionResult?, limit: Int = 1_500) -> String? {
    guard let result, !result.lines.isEmpty, result.averageConfidence >= minimumAverageConfidence else {
      return nil
    }
    let body = result.lines.prefix(maxLines)
      .map { "\($0.text) (\(Int(($0.confidence * 100).rounded()))%)" }
      .joined(separator: "\n")
    return String(body.prefix(limit))
  }

  /// Region worth enlarging: all recognized lines plus a margin, at least a
  /// minimum size for context. Nil when the text already fills most of the
  /// frame, where a crop would add nothing.
  static func focusRegion(
    for lines: [RecognizedTextLine],
    margin: CGFloat = 0.06,
    minimumSide: CGFloat = 0.3,
    maximumArea: CGFloat = 0.55
  ) -> CGRect? {
    guard let first = lines.first else { return nil }
    var region = lines.dropFirst().reduce(first.box) { $0.union($1.box) }
    region = region.insetBy(dx: -margin, dy: -margin)
    if region.width < minimumSide { region = region.insetBy(dx: -(minimumSide - region.width) / 2, dy: 0) }
    if region.height < minimumSide { region = region.insetBy(dx: 0, dy: -(minimumSide - region.height) / 2) }
    let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
    // Shift back inside the frame before clipping, so a region near an edge
    // keeps its size.
    if region.minX < 0 { region.origin.x = 0 }
    if region.minY < 0 { region.origin.y = 0 }
    if region.maxX > 1 { region.origin.x = max(0, 1 - region.width) }
    if region.maxY > 1 { region.origin.y = max(0, 1 - region.height) }
    region = region.intersection(unit)
    guard !region.isNull, region.width * region.height <= maximumArea else { return nil }
    return region
  }
}

/// Lets exactly one of several racing callbacks win.
final class OnceFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var claimed = false

  func claim() -> Bool {
    lock.lock(); defer { lock.unlock() }
    if claimed { return false }
    claimed = true
    return true
  }
}
