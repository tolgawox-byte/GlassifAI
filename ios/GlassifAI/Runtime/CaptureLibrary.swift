import AVFoundation
import CoreImage
import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// What a capture shows, mostly for dealer walkarounds ("Bu aracın önünü
/// çek", "Jantın fotoğrafını çek", "Hasarın fotoğrafını çek").
enum CaptureLabel: String, Codable, CaseIterable, Identifiable {
  case front
  case rear
  case side
  case wheel
  case tire
  case damage
  case interior
  case vin
  case odometer
  case engine

  var id: String { rawValue }

  var title: String {
    switch self {
    case .front: L.t("Front", "Ön")
    case .rear: L.t("Rear", "Arka")
    case .side: L.t("Side", "Yan")
    case .wheel: L.t("Wheel", "Jant")
    case .tire: L.t("Tire", "Lastik")
    case .damage: L.t("Damage", "Hasar")
    case .interior: L.t("Interior", "İç mekan")
    case .vin: "VIN"
    case .odometer: L.t("Odometer", "Kilometre")
    case .engine: L.t("Engine", "Motor")
    }
  }

  var systemImage: String {
    switch self {
    case .front, .rear, .side: "car.side"
    case .wheel, .tire: "circle.circle"
    case .damage: "exclamationmark.triangle"
    case .interior: "carseat.left"
    case .vin: "barcode"
    case .odometer: "gauge.with.dots.needle.33percent"
    case .engine: "engine.combustion"
    }
  }
}

enum CaptureKind: String, Codable {
  case photo
  case video
}

/// Where a capture lives. Photos: in the user's Photos library, and the app
/// keeps only its identifier, a label and a small thumbnail. App only: the
/// file stays in AutoLoom (the "AutoLoom only" setting, no Photos
/// permission, or a save that failed and can be tried again).
enum CaptureStorage: String, Codable {
  case photos
  case appOnly
}

/// Settings → Captures → "Save captures".
enum CaptureSaveMode: String, CaseIterable, Identifiable {
  /// Straight to the Photos library (add-only permission).
  case always
  /// Kept in AutoLoom until the user says "galeriye kaydet" or taps Save.
  case ask
  /// Kept in AutoLoom only.
  case appOnly

  static let defaultsKey = "autoloom.captures.saveMode"

  static var current: CaptureSaveMode {
    CaptureSaveMode(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .always
  }

  var id: String { rawValue }

  var label: String {
    switch self {
    case .always: L.t("Always save to Photos", "Her zaman Fotoğraflar'a kaydet")
    case .ask: L.t("Ask first", "Önce sor")
    case .appOnly: L.t("Keep in AutoLoom only", "Yalnızca AutoLoom'da tut")
    }
  }
}

/// One Ray-Ban photo or video: metadata only, plus a small thumbnail. The
/// photo or video itself is in the Photos library, or in the app's own
/// folder when it was not (or could not be) saved there.
struct CaptureRecord: Codable, Identifiable, Equatable {
  var id = UUID()
  var kind: CaptureKind
  var createdAt = Date()
  /// "Ray-Ban": the glasses' camera, never the iPhone camera or the screen.
  var source = "Ray-Ban"
  var label: CaptureLabel?
  var vehicleSessionID: UUID?
  /// The AutoLoom note taken with it ("fotoğrafını çek ve not al: …").
  var noteID: UUID?
  /// The user's words for this capture (its note, or what was just said
  /// about the thing in view: "Sağ ön jant çizik").
  var caption: String?
  /// PHAsset local identifier (add-only access cannot read the asset back).
  var photoAssetID: String?
  /// File name in the app's Captures folder while the file is kept here.
  var localFile: String?
  var durationSeconds: Double?
  var width: Int?
  var height: Int?
  var codec: String?
  var hasAudio = false
  var storage: CaptureStorage = .appOnly
  /// Why the Photos save did not happen (for "Save again").
  var saveError: String?
  /// Dealer photos: blur, exposure, glare and near-copy hints (phone only).
  var quality: PhotoQuality?

  /// Kept in the app only because the Photos save failed or waits.
  var needsPhotosSave: Bool {
    storage == .appOnly && localFile != nil && saveError != nil
  }

  var isDealer: Bool { vehicleSessionID != nil || label != nil }
}

/// The Captures list (Settings/Explore → Captures): Today, Dealer, Personal.
/// Stored as JSON in Application Support; media files only when a capture
/// is kept in AutoLoom. Nothing is uploaded anywhere.
@MainActor
final class CaptureLibrary: ObservableObject {
  static let shared = CaptureLibrary(directory: ScreenshotMode.storeDirectory)

  enum Filter: String, CaseIterable, Identifiable {
    case today
    case dealer
    case personal

    var id: String { rawValue }

    var title: String {
      switch self {
      case .today: L.t("Today", "Bugün")
      case .dealer: L.t("Dealer", "Bayi")
      case .personal: L.t("Personal", "Kişisel")
      }
    }
  }

  @Published private(set) var records: [CaptureRecord] = []

  private let directory: URL
  private let indexURL: URL

  init(directory: URL? = nil) {
    let base = directory ?? (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory).appendingPathComponent("AutoLoom/Captures", isDirectory: true)
    self.directory = base
    self.indexURL = base.appendingPathComponent("captures.json")
    try? FileManager.default.createDirectory(
      at: base.appendingPathComponent("Thumbnails", isDirectory: true), withIntermediateDirectories: true,
      attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
    load()
  }

  func records(_ filter: Filter, now: Date = Date(), calendar: Calendar = .current) -> [CaptureRecord] {
    switch filter {
    case .today: records.filter { calendar.isDate($0.createdAt, inSameDayAs: now) }
    case .dealer: records.filter(\.isDealer)
    case .personal: records.filter { !$0.isDealer }
    }
  }

  func record(_ id: UUID) -> CaptureRecord? {
    records.first { $0.id == id }
  }

  var latest: CaptureRecord? { records.first }

  @discardableResult
  func add(_ record: CaptureRecord, thumbnail: Data?) -> CaptureRecord {
    if let thumbnail {
      try? thumbnail.write(to: thumbnailURL(for: record.id), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    records.insert(record, at: 0)
    persist()
    return record
  }

  func update(_ id: UUID, _ change: (inout CaptureRecord) -> Void) {
    guard let index = records.firstIndex(where: { $0.id == id }) else { return }
    change(&records[index])
    persist()
  }

  /// Removes AutoLoom's record, thumbnail and any file kept in the app.
  /// A copy in the Photos library is never touched.
  func delete(_ id: UUID) {
    guard let index = records.firstIndex(where: { $0.id == id }) else { return }
    let record = records.remove(at: index)
    if let file = record.localFile { try? FileManager.default.removeItem(at: fileURL(named: file)) }
    try? FileManager.default.removeItem(at: thumbnailURL(for: record.id))
    persist()
  }

  func deleteEverything() {
    for record in records {
      if let file = record.localFile { try? FileManager.default.removeItem(at: fileURL(named: file)) }
      try? FileManager.default.removeItem(at: thumbnailURL(for: record.id))
    }
    records.removeAll()
    persist()
  }

  func thumbnailURL(for id: UUID) -> URL {
    directory.appendingPathComponent("Thumbnails/\(id.uuidString).jpg")
  }

  func thumbnail(for id: UUID) -> UIImage? {
    UIImage(contentsOfFile: thumbnailURL(for: id).path)
  }

  func fileURL(named name: String) -> URL {
    directory.appendingPathComponent(name)
  }

  /// Moves a finished file into the app's Captures folder and returns its
  /// name there.
  func keep(fileAt url: URL, id: UUID) throws -> String {
    let name = "\(id.uuidString).\(url.pathExtension.isEmpty ? "dat" : url.pathExtension)"
    let destination = fileURL(named: name)
    try? FileManager.default.removeItem(at: destination)
    try FileManager.default.moveItem(at: url, to: destination)
    return name
  }

  /// Writes photo data into the app's Captures folder.
  func keep(photo data: Data, id: UUID) throws -> String {
    let name = "\(id.uuidString).jpg"
    try data.write(to: fileURL(named: name), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    return name
  }

  // MARK: Storage

  private func load() {
    guard let data = try? Data(contentsOf: indexURL),
          let decoded = try? JSONDecoder().decode([CaptureRecord].self, from: data) else { return }
    records = decoded.sorted { $0.createdAt > $1.createdAt }
  }

  private func persist() {
    guard let data = try? JSONEncoder().encode(records) else { return }
    try? data.write(to: indexURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
  }

  // MARK: Thumbnails

  /// A small JPEG for the list (ImageIO on the CPU, so it works with the
  /// phone locked).
  nonisolated static func thumbnail(fromJPEG data: Data, maxPixels: Int = 320) -> Data? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: maxPixels,
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
    return jpeg(image)
  }

  nonisolated static func thumbnail(fromPixelBuffer pixelBuffer: CVPixelBuffer, maxPixels: Int = 320) -> Data? {
    let image = CIImage(cvPixelBuffer: pixelBuffer)
    let longSide = max(image.extent.width, image.extent.height)
    guard longSide > 0 else { return nil }
    let scale = min(1, CGFloat(maxPixels) / longSide)
    let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    let context = CIContext(options: [.useSoftwareRenderer: true, .cacheIntermediates: false])
    guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
    return jpeg(cgImage)
  }

  nonisolated private static func jpeg(_ image: CGImage) -> Data? {
    let output = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
      return nil
    }
    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return output as Data
  }
}
