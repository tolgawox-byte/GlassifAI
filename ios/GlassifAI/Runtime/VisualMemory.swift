import Foundation
import ImageIO
import SwiftUI
import UIKit
import Vision

// MARK: On-device analysis

/// Text and object labels read on the phone (Vision), stored with a visual
/// memory so "anahtarımı en son nerede gördüm?" finds it without the cloud.
enum VisualAnalysis {
  struct Result: Codable, Equatable {
    var text: String
    var labels: [String]
  }

  /// OCR (Turkish and English) and up to six confident object labels.
  static func analyze(jpeg: Data) async -> Result {
    await Task.detached(priority: .utility) { () -> VisualAnalysis.Result in
      guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        return VisualAnalysis.Result(text: "", labels: [])
      }
      return VisualAnalysis.analyze(cgImage: image)
    }.value
  }

  static func analyze(cgImage: CGImage) -> Result {
    let text = VNRecognizeTextRequest()
    text.recognitionLevel = .accurate
    text.recognitionLanguages = ["tr-TR", "en-US"]
    text.usesLanguageCorrection = true
    let classify = VNClassifyImageRequest()
    let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
    try? handler.perform([text])
    try? handler.perform([classify])
    let lines = (text.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    let labels = (classify.results ?? [])
      .filter { $0.confidence >= 0.3 }
      .sorted { $0.confidence > $1.confidence }
      .prefix(6)
      .map { $0.identifier.replacingOccurrences(of: "_", with: " ") }
    return Result(text: String(lines.joined(separator: " ").prefix(1_500)), labels: Array(labels))
  }

  /// The memory's text when the online description is unavailable: only
  /// what the phone read, and said so. Nil when it read nothing.
  static func offlineDescription(_ result: Result) -> String? {
    var parts: [String] = []
    if !result.labels.isEmpty { parts.append(L.t("objects: ", "nesneler: ") + result.labels.prefix(4).joined(separator: ", ")) }
    let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    if !text.isEmpty { parts.append(L.t("text: ", "yazı: ") + "“" + String(text.prefix(200)) + "”") }
    guard !parts.isEmpty else { return nil }
    return L.t("Read on this iPhone (offline) — ", "Bu iPhone'da okundu (çevrimdışı) — ") + parts.joined(separator: "; ")
  }
}

// MARK: The extra facts of each visual memory

/// What a visual memory has besides its description: on-device text and
/// labels, the Dealer Mode vehicle it belongs to and, only when "Save photos
/// with visual memories" is on, an optimised photo. JSON in Application
/// Support; the SwiftData record keeps the description, place and thumbnail.
@MainActor
final class VisualMemoryIndex: ObservableObject {
  static let shared = VisualMemoryIndex(directory: ScreenshotMode.storeDirectory)

  struct Entry: Codable, Equatable {
    var analysis: VisualAnalysis.Result
    var vehicleID: UUID?
    var imageFile: String?
    var at: Date
  }

  @Published private(set) var entries: [UUID: Entry] = [:]
  private let folder: URL
  private let fileURL: URL

  init(directory: URL? = nil) {
    let base = directory ?? (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory).appendingPathComponent("AutoLoom", isDirectory: true)
    folder = base.appendingPathComponent("VisualMemories", isDirectory: true)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    fileURL = base.appendingPathComponent("visual-memories.json")
    if let data = try? Data(contentsOf: fileURL) {
      if let decoded = try? JSONDecoder().decode([UUID: Entry].self, from: data) {
        entries = decoded
      } else {
        LocalJSONFile.setAside(fileURL)
      }
    }
  }

  func record(_ id: UUID, analysis: VisualAnalysis.Result, vehicleID: UUID?, image: Data?) {
    var file: String?
    if let image {
      let name = "\(id.uuidString).jpg"
      let url = folder.appendingPathComponent(name)
      if (try? image.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])) != nil {
        file = name
      }
    }
    entries[id] = Entry(analysis: analysis, vehicleID: vehicleID, imageFile: file, at: Date())
    persist()
  }

  func image(for id: UUID) -> UIImage? {
    guard let name = entries[id]?.imageFile else { return nil }
    return UIImage(contentsOfFile: folder.appendingPathComponent(name).path)
  }

  func remove(_ id: UUID) {
    if let name = entries[id]?.imageFile {
      try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
    }
    entries[id] = nil
    persist()
  }

  func deleteEverything() {
    for entry in entries.values {
      if let name = entry.imageFile { try? FileManager.default.removeItem(at: folder.appendingPathComponent(name)) }
    }
    entries.removeAll()
    persist()
  }

  private func persist() {
    guard let data = try? JSONEncoder().encode(entries) else { return }
    try? data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
  }
}

// MARK: Search

@MainActor
enum VisualMemorySearch {
  struct Match: Identifiable {
    let record: MemoryRecord
    let entry: VisualMemoryIndex.Entry?
    let score: Double
    var id: UUID { record.id }
  }

  /// Visual memories that match the words (description, text read in the
  /// photo, object labels, place, vehicle), newest first on ties.
  static func find(_ text: String, limit: Int = 10) -> [Match] {
    let ignored: Set<String> = [
      "en", "son", "nerede", "nereye", "gordum", "gordugum", "gorduk", "gormustuk", "bul", "goster", "where", "did", "last",
      "see", "saw", "seen", "find", "show", "ben", "benim",
    ]
    let words = MemorySearch.tokens(text).filter { !ignored.contains($0) }
    // Each word with its other-language names: object labels are English,
    // descriptions follow the conversation.
    let groups = words.map { word in [word] + synonyms(of: word) }
    let index = VisualMemoryIndex.shared
    let vehicles = Dictionary(uniqueKeysWithValues: DealerStore.shared.vehicles.map { ($0.id, $0.title) })
    let visual = MemoryStore.shared.memories.filter { $0.kind == .visual }
    let scored = visual.map { record -> Match in
      let entry = index.entries[record.id]
      let haystack = [
        record.title, record.text, record.placeName ?? "", record.tags.joined(separator: " "),
        entry?.analysis.text ?? "", entry?.analysis.labels.joined(separator: " ") ?? "",
        entry?.vehicleID.flatMap { vehicles[$0] } ?? "",
      ].joined(separator: " ")
      let document = MemorySearch.tokens(haystack)
      let found = groups.filter { group in group.contains { word in document.contains { MemorySearch.sameStem(word, $0) } } }
      let score = groups.isEmpty ? 0.5 : Double(found.count) / Double(groups.count)
      return Match(record: record, entry: entry, score: score)
    }
    return Array(scored.filter { $0.score > 0 }.sorted {
      $0.score != $1.score ? $0.score > $1.score : $0.record.createdAt > $1.record.createdAt
    }.prefix(limit))
  }

  /// Everyday objects in Turkish and English (folded, stems).
  private static let objectNames: [(tr: [String], en: [String])] = [
    (["anahtar"], ["key", "keys", "keychain"]), (["cuzdan"], ["wallet", "purse"]),
    (["gozluk"], ["glasses", "sunglasses", "eyeglasses", "spectacles"]), (["telefon"], ["phone", "smartphone", "cellphone"]),
    (["araba", "arac", "oto"], ["car", "vehicle", "automobile"]), (["canta"], ["bag", "handbag", "backpack"]),
    (["semsiye"], ["umbrella"]), (["kitap"], ["book"]), (["bilgisayar", "laptop"], ["computer", "laptop", "notebook"]),
    (["saat"], ["watch", "clock"]), (["kulaklik"], ["headphones", "earphones", "earbuds"]), (["sarj"], ["charger", "cable"]),
    (["kalem"], ["pen", "pencil"]), (["fatura", "fis"], ["invoice", "bill", "receipt"]), (["lastik", "teker"], ["tire", "tyre", "wheel"]),
    (["kapi"], ["door"]), (["masa"], ["table", "desk"]), (["kutu", "koli"], ["box", "package", "carton"]),
    (["ilac"], ["medicine", "pill", "pills"]), (["belge", "evrak", "kagit"], ["document", "paper", "papers"]),
    (["kart"], ["card"]), (["bardak", "kupa"], ["cup", "mug", "glass"]), (["sise"], ["bottle"]), (["ayakkabi"], ["shoe", "shoes"]),
    (["ceket", "mont"], ["jacket", "coat"]), (["bisiklet"], ["bicycle", "bike"]), (["kedi"], ["cat"]), (["kopek"], ["dog"]),
  ]

  static func synonyms(of word: String) -> [String] {
    var result: [String] = []
    for pair in objectNames {
      if pair.tr.contains(where: { MemorySearch.sameStem(word, $0) }) { result += pair.en }
      if pair.en.contains(word) { result += pair.tr }
    }
    return result
  }
}

// MARK: Scene Timeline (opt-in, default off)

/// While Live Vision runs and the user turned it on: one short line per
/// scene ("09:41 Bayi otoparkı") — text only, no images, kept for a week.
@MainActor
final class SceneTimeline: ObservableObject {
  static let shared = SceneTimeline(directory: ScreenshotMode.storeDirectory)
  static let enabledKey = "autoloom.sceneTimeline.enabled"
  static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }
  static let retention: TimeInterval = 7 * 86_400
  static let minimumGap: TimeInterval = 120

  struct Entry: Codable, Equatable, Identifiable {
    var id = UUID()
    var at: Date
    var text: String
  }

  @Published private(set) var entries: [Entry] = []
  private let fileURL: URL

  init(directory: URL? = nil) {
    let base = directory ?? (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory).appendingPathComponent("AutoLoom", isDirectory: true)
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    fileURL = base.appendingPathComponent("scene-timeline.json")
    if let data = try? Data(contentsOf: fileURL), let decoded = try? JSONDecoder().decode([Entry].self, from: data) {
      entries = decoded
    }
  }

  /// A new Live Vision description; kept only when the timeline is on, the
  /// last line is old enough and the scene really changed.
  @discardableResult
  func note(_ summary: String, now: Date = Date(), enabled: Bool = SceneTimeline.isEnabled) -> Bool {
    guard enabled else { return false }
    let text = String(summary.split(whereSeparator: { ".!?\n".contains($0) }).first ?? Substring(summary)).trimmingCharacters(in: .whitespaces)
    guard text.count >= 3 else { return false }
    if let last = entries.last {
      guard now.timeIntervalSince(last.at) >= Self.minimumGap else { return false }
      let same = MemorySearch.lexicalScore(query: MemorySearch.tokens(text), document: MemorySearch.tokens(last.text))
      guard same < 0.8 else { return false }
    }
    entries.append(Entry(at: now, text: String(text.prefix(90))))
    entries.removeAll { now.timeIntervalSince($0.at) > Self.retention }
    persist()
    return true
  }

  func deleteEverything() {
    entries.removeAll()
    persist()
  }

  private func persist() {
    guard let data = try? JSONEncoder().encode(entries) else { return }
    try? data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
  }
}

// MARK: Screens

/// Memory → Visual memory: what the user asked to remember, with photos when
/// they allowed them.
struct VisualMemoryGallery: View {
  @ObservedObject private var memory = MemoryStore.shared
  @ObservedObject private var index = VisualMemoryIndex.shared
  @ObservedObject private var timeline = SceneTimeline.shared
  @AppStorage(SceneTimeline.enabledKey) private var timelineOn = false
  @State private var text = ""

  var body: some View {
    let matches = VisualMemorySearch.find(text, limit: 100)
    List {
      if memory.memories.contains(where: { $0.kind == .visual }) {
        Section {
          ForEach(matches) { match in
            NavigationLink { VisualMemoryDetail(recordID: match.record.id) } label: { row(match) }
          }
        }
      } else {
        Section {
          Text(L.t(
            "Say “bunu hatırla” or “anahtarımı buraya bıraktığımı hatırla” while looking at something. Turn on visual memories in Settings → Memory.",
            "Bir şeye bakarken “bunu hatırla” ya da “anahtarımı buraya bıraktığımı hatırla” de. Görsel anıları Ayarlar → Hafıza'da aç."))
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
      }
      Section {
        Toggle(L.t("Scene Timeline", "Sahne zaman çizelgesi"), isOn: $timelineOn)
        ForEach(timeline.entries.suffix(20).reversed()) { entry in
          HStack(alignment: .top) {
            Text(entry.at.formatted(date: .omitted, time: .shortened)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Text(entry.text).font(.caption)
          }
        }
        if !timeline.entries.isEmpty {
          Button(L.t("Delete the timeline", "Zaman çizelgesini sil"), role: .destructive) { timeline.deleteEverything() }
        }
      } footer: {
        Text(L.t(
          "Off by default. While Live Vision runs, one short line of text per scene is kept for a week — never a photo.",
          "Varsayılan olarak kapalı. Canlı görüş açıkken her sahne için kısa bir satır bir hafta saklanır; asla fotoğraf değil."))
      }
    }
    .searchable(text: $text, prompt: L.t("Search what you saw", "Gördüklerinde ara"))
    .navigationTitle(L.t("Visual memory", "Görsel hafıza"))
  }

  private func row(_ match: VisualMemorySearch.Match) -> some View {
    HStack(spacing: 12) {
      Group {
        if let data = match.record.thumbnail, let image = UIImage(data: data) {
          Image(uiImage: image).resizable().scaledToFill()
        } else {
          Image(systemName: "eye").font(.title3).foregroundStyle(AutoLoomTheme.electricBlue)
        }
      }
      .frame(width: 52, height: 52)
      .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
      VStack(alignment: .leading, spacing: 3) {
        Text(match.record.text).font(.subheadline).lineLimit(2)
        HStack(spacing: 6) {
          Text(match.record.createdAt.formatted(date: .abbreviated, time: .shortened))
          if let place = match.record.placeName { Text("· \(place)") }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
      }
    }
  }
}

struct VisualMemoryDetail: View {
  let recordID: UUID
  @ObservedObject private var memory = MemoryStore.shared
  @ObservedObject private var index = VisualMemoryIndex.shared
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    if let record = memory.memories.first(where: { $0.id == recordID }) {
      let entry = index.entries[recordID]
      List {
        if let image = index.image(for: recordID) ?? record.thumbnail.flatMap(UIImage.init(data:)) {
          Section {
            Image(uiImage: image)
              .resizable()
              .scaledToFit()
              .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
              .listRowInsets(EdgeInsets())
          }
        }
        Section {
          Text(record.text)
          LabeledContent(L.t("When", "Ne zaman"), value: record.createdAt.formatted(date: .abbreviated, time: .shortened))
          if let place = record.placeName { LabeledContent(L.t("Where", "Nerede"), value: place) }
          if let vehicleID = entry?.vehicleID, let vehicle = DealerStore.shared.vehicle(vehicleID) {
            LabeledContent(L.t("Vehicle", "Araç"), value: vehicle.title)
          }
        }
        if let entry, !entry.analysis.text.isEmpty || !entry.analysis.labels.isEmpty {
          Section(L.t("Read on this iPhone", "Bu iPhone'da okunan")) {
            if !entry.analysis.labels.isEmpty { Text(entry.analysis.labels.joined(separator: ", ")).font(.caption) }
            if !entry.analysis.text.isEmpty { Text(entry.analysis.text).font(.caption).foregroundStyle(.secondary) }
          }
        }
        Section {
          Button(L.t("Delete", "Sil"), role: .destructive) {
            index.remove(recordID)
            memory.delete(record)
            dismiss()
          }
        }
      }
      .navigationTitle(L.t("Visual memory", "Görsel anı"))
    } else {
      Text(L.t("This memory was deleted.", "Bu anı silindi.")).foregroundStyle(.secondary)
    }
  }
}

// MARK: Voice: "anahtarımı en son nerede gördüm?", "ne değişti?"

extension AssistantOrchestrator {
  func findVisual(_ text: String, traceID: UUID) -> IntentOutcome {
    let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
    ActionTraceLog.shared.update(traceID) { $0.executor = "VisualMemorySearch (on this iPhone)" }
    let memory = MemoryStore.shared
    guard memory.isEnabled else {
      let tr = "Hafıza kapalı; görsel anı yok."
      let en = "Memory is turned off, so there are no visual memories."
      return IntentOutcome(
        spoken: BridgeSpeech.done("Memory is turned off in the app.", tr: tr, en: en), reply: L.t(en, tr),
        failed: "memory off", said: L.t(en, tr))
    }
    guard !query.isEmpty else { return seenToday() }
    let matches = VisualMemorySearch.find(query, limit: 5)
    ActionTraceLog.shared.update(traceID) { $0.parsed = "\(matches.count) visual memories for “\(LogSanitizer.sanitize(query, limit: 40))”" }
    guard let best = matches.first else {
      AppNavigator.shared.show(.visualMemory(nil))
      let tr = "Görsel anılarında “\(query)” yok. Sadece “bunu hatırla” dediğin şeyleri bilirim."
      let en = "There's no visual memory of “\(query)”. I only know what you asked me to remember."
      return IntentOutcome(
        spoken: BridgeSpeech.done("No visual memory matches; nothing is guessed.", tr: tr, en: en),
        reply: L.t(en, tr), failed: "no visual memory", said: L.t(en, tr))
    }
    AppNavigator.shared.show(.visualMemory(best.record.id))
    let when = best.record.createdAt.formatted(date: .abbreviated, time: .shortened)
    let place = best.record.placeName.map { " at \($0)" } ?? ""
    let vehicle = best.entry?.vehicleID.flatMap { DealerStore.shared.vehicle($0)?.title }.map { " (vehicle: \($0))" } ?? ""
    return IntentOutcome(
      spoken: "From the user's own visual memory, saved \(when)\(place)\(vehicle): \(best.record.text)\nTell the user briefly when and where it was seen, as a saved memory (not what the camera sees now). The photo is open on the phone.",
      reply: best.record.text,
      said: L.t("From your visual memory (\(when)).", "Görsel anından (\(when))."))
  }

  /// "Bugün neler gördüm?": today's visual memories and, when the user turned
  /// it on, the Scene Timeline.
  private func seenToday() -> IntentOutcome {
    let calendar = Calendar.current
    let visual = MemoryStore.shared.memories.filter { $0.kind == .visual && calendar.isDateInToday($0.createdAt) }
    let timeline = SceneTimeline.shared.entries.filter { calendar.isDateInToday($0.at) }
    AppNavigator.shared.show(.visualMemory(nil))
    guard !visual.isEmpty || !timeline.isEmpty else {
      let off = !SceneTimeline.isEnabled
      let tr = "Bugün görsel anı kaydetmedin." + (off ? " Sahne zaman çizelgesi de kapalı." : "")
      let en = "You saved no visual memories today." + (off ? " Scene Timeline is off, too." : "")
      return IntentOutcome(spoken: BridgeSpeech.done("Nothing was saved today.", tr: tr, en: en), reply: L.t(en, tr), said: L.t(en, tr))
    }
    var lines = visual.prefix(5).map { "- " + $0.createdAt.formatted(date: .omitted, time: .shortened) + " " + String($0.text.prefix(120)) }
    lines += timeline.suffix(8).map { "- " + $0.at.formatted(date: .omitted, time: .shortened) + " (timeline) " + $0.text }
    return IntentOutcome(
      spoken: "What the user saved or Live Vision noted today, on this iPhone:\n" + lines.joined(separator: "\n") + "\nSummarise in two short sentences; the list is on the phone.",
      reply: lines.joined(separator: "\n"),
      said: L.t("Today's visual memories are on the phone.", "Bugünkü görsel anılar telefonda."))
  }

  func whatChanged(traceID: UUID) -> IntentOutcome {
    let live = LiveVisionController.shared
    ActionTraceLog.shared.update(traceID) { $0.executor = "LiveVisionController (last scene notes)" }
    guard live.isActive else {
      let tr = "Canlı görüş kapalı; karşılaştıracak bir şey yok."
      let en = "Live Vision is off, so there's nothing to compare."
      return IntentOutcome(spoken: BridgeSpeech.done("Live Vision is off.", tr: tr, en: en), reply: L.t(en, tr), failed: "live vision off", said: L.t(en, tr))
    }
    let notes = live.recentNotes
    guard notes.count >= 2 else {
      let tr = "Henüz karşılaştıracak iki görüntü yok."
      let en = "There aren't two views to compare yet."
      return IntentOutcome(spoken: BridgeSpeech.done("Only one scene note so far.", tr: tr, en: en), reply: L.t(en, tr), said: L.t(en, tr))
    }
    let before = notes[notes.count - 2]
    let now = notes[notes.count - 1]
    let t1 = before.at.formatted(date: .omitted, time: .shortened)
    let t2 = now.at.formatted(date: .omitted, time: .shortened)
    return IntentOutcome(
      spoken: "Two Live Vision notes of the user's view. Earlier (\(t1)): \(before.text)\nNow (\(t2)): \(now.text)\nSay in one or two short sentences what changed between them; if they describe the same scene, say nothing important changed. Do not add anything the notes do not say.",
      reply: "\(t1): \(before.text)\n\(t2): \(now.text)",
      said: L.t("Compared the last two views.", "Son iki görüntüyü karşılaştırdım."))
  }
}
