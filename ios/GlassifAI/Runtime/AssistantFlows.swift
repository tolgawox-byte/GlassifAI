import Foundation
import ImageIO
import UIKit

/// A memory request as written by the voice model ("save: …", "recall: …",
/// "forget: …", "list"). Deterministic code executes it.
enum MemoryRequest: Equatable {
  case save(text: String, title: String?, kind: MemoryKind?)
  case recall(String)
  case forget(String)
  case list

  private static let prefixes: [(String, (String) -> MemoryRequest?)] = [
    ("save:", { $0.isEmpty ? nil : .save(text: $0, title: nil, kind: nil) }),
    ("remember:", { $0.isEmpty ? nil : .save(text: $0, title: nil, kind: nil) }),
    ("kaydet:", { $0.isEmpty ? nil : .save(text: $0, title: nil, kind: nil) }),
    ("recall:", { $0.isEmpty ? nil : .recall($0) }),
    ("search:", { $0.isEmpty ? nil : .recall($0) }),
    ("forget:", { $0.isEmpty ? nil : .forget($0) }),
    ("delete:", { $0.isEmpty ? nil : .forget($0) }),
    ("unut:", { $0.isEmpty ? nil : .forget($0) }),
    ("list:", { _ in .list }),
  ]

  /// Nil when the query has no recognised prefix (then a model classifies it).
  static func parse(_ query: String) -> MemoryRequest? {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    let lower = trimmed.lowercased()
    if lower == "list" || lower == "list:" { return .list }
    for (prefix, make) in prefixes where lower.hasPrefix(prefix) {
      let rest = String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
      return make(rest)
    }
    return nil
  }

  /// Reads the strict JSON of `AssistantTools.memorySchema`.
  static func decodePlan(_ json: String) -> MemoryRequest? {
    guard let data = json.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    func field(_ key: String) -> String {
      (object[key] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    switch field("operation") {
    case "save":
      let text = field("text")
      guard !text.isEmpty else { return nil }
      let title = field("title")
      return .save(text: text, title: title.isEmpty ? nil : title, kind: MemoryKind(rawValue: field("kind")))
    case "recall":
      let query = field("query")
      return query.isEmpty ? nil : .recall(query)
    case "forget":
      let query = field("query")
      return query.isEmpty ? nil : .forget(query)
    case "list":
      return .list
    default:
      return nil
    }
  }
}

/// Recognises vision answers that could not see enough, so the app first
/// retries with the high-detail path (best frame, OCR, zoomed crop) instead
/// of passing on a "move closer".
enum VisionAnswerCheck {
  private static let unclear = [
    "yaklaş", "daha yakın", "okunmuyor", "okuyamıyorum", "okunamıyor", "net değil", "bulanık", "seçilemiyor",
    "seçemiyorum", "göremiyorum", "belirgin değil", "çok uzak",
    "move closer", "come closer", "get closer", "closer to", "can't read", "cannot read", "unable to read",
    "unreadable", "too blurry", "blurry", "too far", "not clear", "can't make out", "cannot make out",
    "hard to read", "illegible", "too small to read", "not legible",
  ]

  private static let reposition = [
    "yaklaş", "daha yakın", "kamerayı", "eğ", "sabit tut", "ışığa",
    "closer", "move the camera", "tilt", "hold still", "toward the light", "point the camera", "aim the camera",
  ]

  static func suggestsUnclear(_ text: String) -> Bool {
    let lower = text.lowercased(with: Locale(identifier: "tr_TR"))
    return unclear.contains { lower.contains($0) }
  }

  static func containsRepositionAdvice(_ text: String) -> Bool {
    let lower = text.lowercased(with: Locale(identifier: "tr_TR"))
    return reposition.contains { lower.contains($0) }
  }
}

/// Small JPEG thumbnails for visual memories (only when photos are allowed).
enum Thumbnailer {
  static func jpeg(_ data: Data, maxPixel: Int = 480) -> Data? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceThumbnailMaxPixelSize: maxPixel,
      kCGImageSourceCreateThumbnailWithTransform: true,
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
    return UIImage(cgImage: image).jpegData(compressionQuality: 0.7)
  }
}

/// A sanitized, copyable trace of recent turns for support: routes, models,
/// timings, image metadata and errors. Requests are shortened and cleaned of
/// emails, long numbers, tokens and payloads; no audio or images.
enum TaskTrace {
  static func redactUserText(_ text: String, limit: Int = 80) -> String {
    var output = LogSanitizer.sanitize(text, limit: 400)
    if let digits = try? NSRegularExpression(pattern: #"\+?\d[\d\s\-().]{6,}\d"#) {
      output = digits.stringByReplacingMatches(
        in: output, range: NSRange(output.startIndex..., in: output), withTemplate: "[number]")
    }
    return output.count > limit ? String(output.prefix(limit)) + "…" : output
  }

  @MainActor
  static func text(records: [AssistantTaskRecord], start: RealtimeStartReport?, now: Date = Date()) -> String {
    var lines = ["\(AutoLoomBrand.appName) task trace \(now.formatted(date: .abbreviated, time: .standard))",
                 "version \(AppInfo.version) (\(AppInfo.build)) commit \(AppInfo.commit)"]
    if let start {
      lines.append(
        "voice start: requested \(start.requestedVoice)/\(start.requestedModel), active \(start.activeVoice ?? "—")/\(start.activeModel ?? "—"), " +
        "step \(start.step?.rawValue ?? "failed"), connect \(start.connectMs.map { "\($0) ms" } ?? "—"), fallback \(start.fallbackReason ?? "none")")
      for attempt in start.attempts { lines.append("  attempt: \(LogSanitizer.sanitize(attempt, limit: 200))") }
    }
    for record in records.suffix(12) {
      let phase: String
      switch record.phase {
      case .completed: phase = "completed"
      case .cancelled(let reason): phase = "cancelled (\(reason))"
      case .failed(let reason): phase = "failed (\(LogSanitizer.sanitize(reason, limit: 120)))"
      default: phase = "running"
      }
      let timeline = record.timeline.breakdown.map { "\($0.stage)=\($0.ms)ms" }.joined(separator: " ")
      lines.append(
        "turn \(record.turnID) \(record.kind?.rawValue ?? "ROUTING") via \(record.routeOrigin?.rawValue ?? "—") " +
        "[\(record.source.rawValue)] model \(record.model ?? "—") \(phase)")
      lines.append("  request: \(redactUserText(record.request))")
      if let frame = record.frame { lines.append("  image: \(frame.summary)") }
      for note in record.notes { lines.append("  note: \(LogSanitizer.sanitize(note, limit: 200))") }
      if !timeline.isEmpty { lines.append("  timing: \(timeline)") }
    }
    return lines.joined(separator: "\n")
  }
}
