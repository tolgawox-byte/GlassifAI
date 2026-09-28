import Foundation
import NaturalLanguage
import SwiftData

/// What kind of thing a memory is.
enum MemoryKind: String, CaseIterable, Codable, Identifiable {
  case fact = "FACT"
  case episode = "EPISODE"
  case note = "NOTE"
  case visual = "VISUAL_MEMORY"
  case preference = "PREFERENCE"
  case taskContext = "TASK_CONTEXT"

  var id: String { rawValue }

  var label: String {
    switch self {
    case .fact: L.t("Fact", "Bilgi")
    case .episode: L.t("Moment", "An")
    case .note: L.t("Note", "Not")
    case .visual: L.t("Visual", "Görsel")
    case .preference: L.t("Preference", "Tercih")
    case .taskContext: L.t("Task context", "Görev bağlamı")
    }
  }

  var systemImage: String {
    switch self {
    case .fact: "info.circle"
    case .episode: "clock.arrow.circlepath"
    case .note: "note.text"
    case .visual: "eye"
    case .preference: "heart"
    case .taskContext: "checklist"
    }
  }

  /// Deterministic guess from the saved words; the user can change it.
  static func classify(_ text: String) -> MemoryKind {
    let words = " " + MemorySearch.fold(text) + " "
    let preference = [
      " seviyorum", " sevmiyorum", " sevmem", " severim", " tercih", " favori", " hep ", " asla ", " istemiyorum",
      " like ", " love ", " prefer", " favorite", " favourite", " hate ", " never ", " always ", " allergic", " alerji",
    ]
    if preference.contains(where: { words.contains($0) }) { return .preference }
    let episode = [
      " park ettim", " koydum", " biraktim", " birakti", " gordum", " bugun ", " dun ", " aldim",
      " parked", " i left", " i put", " yesterday", " today ", " i saw", " i bought",
    ]
    if episode.contains(where: { words.contains($0) }) { return .episode }
    return .fact
  }
}

/// Where a memory is listed in the Memory tab.
enum MemoryCategory: String, CaseIterable, Codable, Identifiable {
  case people
  case places
  case vehicles
  case other

  var id: String { rawValue }

  var label: String {
    switch self {
    case .people: L.t("People", "Kişiler")
    case .places: L.t("Places", "Yerler")
    case .vehicles: L.t("Vehicles", "Araçlar")
    case .other: L.t("Other", "Diğer")
    }
  }

  var systemImage: String {
    switch self {
    case .people: "person.2"
    case .places: "mappin.and.ellipse"
    case .vehicles: "car"
    case .other: "square.grid.2x2"
    }
  }

  /// Keyword classification in Turkish and English; the user can change it.
  static func classify(_ text: String) -> MemoryCategory {
    let words = " " + MemorySearch.fold(text) + " "
    let vehicles = [
      "araba", "arac", "plaka", "sasi", "vin ", "motor", "lastik", "benzin", "yakit", "otomobil", "kamyon",
      " car ", " cars ", "vehicle", "plate", "tire", "tyre", "engine", "truck", "suv ", "sedan",
      "bmw", "mercedes", "toyota", "honda", "ford", "tesla", "audi", "volkswagen", " vw ", "hyundai", "kia ",
      "nissan", "chevrolet", "jeep", "porsche", "lexus", "renault", "fiat", "peugeot", "volvo", "mazda", "subaru",
    ]
    if vehicles.contains(where: { words.contains($0) }) { return .vehicles }
    let people = [
      "annem", "babam", "esim", "karim", "kocam", "kardesim", "abim", "ablam", "oglum", "kizim", "arkadasim",
      "patronum", "doktorum", "komsum", "dogum gunu", "numarasi", "telefonu",
      " mom", " dad", " mother", " father", " wife", " husband", " sister", " brother", " son ", " daughter",
      " friend", " boss", " doctor", " neighbor", " neighbour", "birthday", "colleague",
    ]
    if people.contains(where: { words.contains($0) }) { return .people }
    let places = [
      " ev ", "evim", " is yeri", "isyeri", "ofis", "adres", "sokak", "cadde", "mahalle", "otopark", " kat ",
      "restoran", "magaza", "otel", "havaalani", "istasyon", "sehir",
      " home", "office", "address", "street", "avenue", " road", "parking", "garage", "restaurant", "store",
      "shop", "hotel", "airport", "station", " city", "floor", "level ",
    ]
    if places.contains(where: { words.contains($0) }) { return .places }
    return .other
  }
}

/// A place attached to a memory or note (only when the user turned it on).
struct MemoryLocation: Equatable {
  let latitude: Double
  let longitude: Double
  let placeName: String?
}

/// One explicitly saved memory. Stored with SwiftData on this iPhone only.
@Model
final class MemoryRecord {
  @Attribute(.unique) var id: UUID
  var kindRaw: String
  var categoryRaw: String
  var title: String
  var text: String
  var createdAt: Date
  var updatedAt: Date
  var pinned: Bool
  /// voice, manual, visual, migrated…
  var source: String
  var tags: [String]
  var latitude: Double?
  var longitude: Double?
  var placeName: String?
  /// Small image of a visual memory, only when the user allowed photos.
  @Attribute(.externalStorage) var thumbnail: Data?
  var lastRecalledAt: Date?

  init(
    id: UUID = UUID(),
    kind: MemoryKind,
    category: MemoryCategory,
    title: String,
    text: String,
    createdAt: Date = Date(),
    source: String,
    tags: [String] = [],
    pinned: Bool = false
  ) {
    self.id = id
    self.kindRaw = kind.rawValue
    self.categoryRaw = category.rawValue
    self.title = title
    self.text = text
    self.createdAt = createdAt
    self.updatedAt = createdAt
    self.pinned = pinned
    self.source = source
    self.tags = tags
    self.latitude = nil
    self.longitude = nil
    self.placeName = nil
    self.thumbnail = nil
    self.lastRecalledAt = nil
  }

  var kind: MemoryKind { MemoryKind(rawValue: kindRaw) ?? .fact }
  var category: MemoryCategory { MemoryCategory(rawValue: categoryRaw) ?? .other }

  var location: MemoryLocation? {
    guard let latitude, let longitude else { return nil }
    return MemoryLocation(latitude: latitude, longitude: longitude, placeName: placeName)
  }
}

/// An AutoLoom note or saved report. Stored with SwiftData on this iPhone.
/// Apple Notes has no API for other apps, so notes are shared to it.
@Model
final class NoteRecord {
  @Attribute(.unique) var id: UUID
  var title: String
  var content: String
  var createdAt: Date
  var updatedAt: Date
  var tags: [String]
  /// Source links (for example web sources of a report).
  var links: [String]
  var source: String
  var pinned: Bool
  var latitude: Double?
  var longitude: Double?
  var placeName: String?

  init(
    id: UUID = UUID(),
    title: String,
    content: String,
    createdAt: Date = Date(),
    source: String,
    tags: [String] = [],
    links: [String] = []
  ) {
    self.id = id
    self.title = title
    self.content = content
    self.createdAt = createdAt
    self.updatedAt = createdAt
    self.tags = tags
    self.links = links
    self.source = source
    self.pinned = false
    self.latitude = nil
    self.longitude = nil
    self.placeName = nil
  }
}

/// A search result over memories and notes.
struct MemoryHit: Identifiable {
  enum Item {
    case memory(MemoryRecord)
    case note(NoteRecord)
  }

  let item: Item
  let score: Double

  var id: UUID {
    switch item {
    case .memory(let record): record.id
    case .note(let note): note.id
    }
  }

  /// One line for the voice model or the search list.
  var line: String {
    switch item {
    case .memory(let record):
      var text = record.text
      if let place = record.placeName { text += " (\(L.t("at", "konum")): \(place))" }
      return "\(text) [\(record.kind.rawValue.lowercased()), \(record.createdAt.formatted(date: .abbreviated, time: .omitted))]"
    case .note(let note):
      return "\(L.t("Note", "Not")) \"\(note.title)\": \(note.content.prefix(300))"
    }
  }
}

/// On-device search: Turkish-aware word matching (folded letters and word
/// stems, so "arabamı" finds "araba") plus Apple's on-device sentence
/// embedding for English when it is available. Nothing leaves the phone.
enum MemorySearch {
  private static let stopWords: Set<String> = [
    "ve", "ile", "bir", "bu", "su", "o", "da", "de", "ta", "te", "mi", "mu", "ne", "icin", "gibi", "ki",
    "benim", "bana", "beni", "ben", "sen", "senin", "hatirla", "hatirliyor", "musun", "misin", "kaydet", "not",
    "al", "unutma", "nerede", "neydi", "nedir", "hangi", "zaman", "the", "a", "an", "my", "me", "i", "is", "was",
    "what", "where", "when", "which", "did", "do", "does", "you", "remember", "of", "to", "in", "on", "at", "and",
    "for", "about", "that", "this", "it", "save", "note", "recall",
  ]

  /// Lowercased with Turkish rules, accents removed, "ı" → "i".
  static func fold(_ text: String) -> String {
    text.lowercased(with: Locale(identifier: "tr_TR"))
      .replacingOccurrences(of: "ı", with: "i")
      .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
  }

  static func tokens(_ text: String) -> [String] {
    fold(text)
      .components(separatedBy: CharacterSet.alphanumerics.inverted)
      .filter { $0.count >= 2 && !stopWords.contains($0) }
  }

  /// Whether two words share a stem: equal, or one starts with the other and
  /// the shorter one is at least three letters (Turkish suffixes).
  static func sameStem(_ a: String, _ b: String) -> Bool {
    if a == b { return true }
    let (short, long) = a.count <= b.count ? (a, b) : (b, a)
    guard short.count >= 3, long.hasPrefix(short) else { return false }
    return long.count - short.count <= 6
  }

  /// Share of the query words found in the document (0…1).
  static func lexicalScore(query: [String], document: [String]) -> Double {
    guard !query.isEmpty, !document.isEmpty else { return 0 }
    let matched = query.filter { word in document.contains { sameStem(word, $0) } }.count
    return Double(matched) / Double(query.count)
  }

  /// Cosine similarity of Apple's on-device English sentence embedding, or
  /// nil when it is unavailable.
  static func semanticScore(_ query: String, _ document: String, embedding: NLEmbedding?) -> Double? {
    guard let embedding,
          let a = embedding.vector(for: query),
          let b = embedding.vector(for: String(document.prefix(500))),
          a.count == b.count, !a.isEmpty else { return nil }
    var dot = 0.0
    var normA = 0.0
    var normB = 0.0
    for index in a.indices {
      dot += a[index] * b[index]
      normA += a[index] * a[index]
      normB += b[index] * b[index]
    }
    guard normA > 0, normB > 0 else { return nil }
    return dot / (normA.squareRoot() * normB.squareRoot())
  }

  static func looksEnglish(_ text: String) -> Bool {
    let recognizer = NLLanguageRecognizer()
    recognizer.processString(text)
    return recognizer.dominantLanguage == .english
  }

  /// Combined score; `semantic` only adds evidence, it never finds a result
  /// on its own below the threshold.
  static func combined(lexical: Double, semantic: Double?, pinned: Bool) -> Double {
    var score = lexical
    if let semantic { score = max(score, lexical * 0.6 + max(0, semantic - 0.35) * 0.9) }
    if pinned && score > 0 { score += 0.05 }
    return score
  }

  static let threshold = 0.34
}

/// The user's memories and notes. Explicit only: nothing is saved unless the
/// user asks ("hatırla", "kaydet", "not al", "unutma", "remember…") or adds
/// it on screen. Stored on this iPhone with SwiftData; never synced.
@MainActor
final class MemoryStore: ObservableObject {
  static let shared = MemoryStore()

  static let enabledKey = "autoloom.memory.v2.enabled"
  static let visualEnabledKey = "autoloom.memory.visual.enabled"
  static let visualPhotosKey = "autoloom.memory.visual.photos"
  static let locationKey = "autoloom.memory.location"
  private static let migratedKey = "autoloom.memory.v2.migrated"

  let container: ModelContainer?
  @Published private(set) var memories: [MemoryRecord] = []
  @Published private(set) var notes: [NoteRecord] = []
  @Published private(set) var storageError: String?
  @Published private(set) var isPersistent = false

  @Published var isEnabled: Bool {
    didSet { defaults.set(isEnabled, forKey: Self.enabledKey) }
  }
  /// "Remember what I'm looking at" — off until the user turns it on.
  @Published var visualMemoriesEnabled: Bool {
    didSet { defaults.set(visualMemoriesEnabled, forKey: Self.visualEnabledKey) }
  }
  /// Keep a small photo with visual memories (off: text description only).
  @Published var saveVisualPhotos: Bool {
    didSet { defaults.set(saveVisualPhotos, forKey: Self.visualPhotosKey) }
  }
  /// Attach the current place to visual memories and notes.
  @Published var attachLocation: Bool {
    didSet { defaults.set(attachLocation, forKey: Self.locationKey) }
  }

  private let defaults: UserDefaults

  init(inMemory: Bool = false, defaults: UserDefaults = .standard) {
    self.defaults = defaults
    isEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
    visualMemoriesEnabled = defaults.bool(forKey: Self.visualEnabledKey)
    saveVisualPhotos = defaults.bool(forKey: Self.visualPhotosKey)
    attachLocation = defaults.bool(forKey: Self.locationKey)
    let schema = Schema([MemoryRecord.self, NoteRecord.self])
    var created: ModelContainer?
    var error: String?
    if !inMemory, let url = Self.storeURL() {
      do {
        let configuration = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        created = try ModelContainer(for: schema, configurations: [configuration])
      } catch let failure {
        error = LogSanitizer.sanitize(failure.localizedDescription, limit: 200)
        NSLog("[AutoLoom] memory store unavailable, using a temporary store: %@", error ?? "")
      }
    }
    if created == nil {
      let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
      created = try? ModelContainer(for: schema, configurations: [configuration])
    }
    container = created
    isPersistent = !inMemory && error == nil && created != nil
    storageError = error
    if !inMemory { migrateLegacyFiles() }
    refresh()
  }

  private static func storeURL() -> URL? {
    guard let directory = try? FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
      .appending(path: "AutoLoom", directoryHint: .isDirectory) else { return nil }
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appending(path: "AutoLoomMemory.store")
  }

  private var context: ModelContext? { container?.mainContext }

  func refresh() {
    guard let context else { return }
    let loadedMemories = (try? context.fetch(FetchDescriptor<MemoryRecord>())) ?? []
    memories = loadedMemories.sorted {
      if $0.pinned != $1.pinned { return $0.pinned }
      return $0.updatedAt > $1.updatedAt
    }
    let loadedNotes = (try? context.fetch(FetchDescriptor<NoteRecord>())) ?? []
    notes = loadedNotes.sorted {
      if $0.pinned != $1.pinned { return $0.pinned }
      return $0.updatedAt > $1.updatedAt
    }
  }

  private func save() {
    do {
      try context?.save()
    } catch {
      storageError = LogSanitizer.sanitize(error.localizedDescription, limit: 200)
      NSLog("[AutoLoom] memory save failed: %@", storageError ?? "")
    }
    refresh()
  }

  // MARK: Memories

  /// Saves an explicit memory. A memory with the same words is refreshed
  /// instead of duplicated. Returns nil when memory is off or the text is empty.
  @discardableResult
  func remember(
    _ text: String,
    title: String? = nil,
    kind: MemoryKind? = nil,
    category: MemoryCategory? = nil,
    source: String,
    tags: [String] = [],
    location: MemoryLocation? = nil,
    thumbnail: Data? = nil
  ) -> MemoryRecord? {
    let cleaned = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1_000))
    guard isEnabled, !cleaned.isEmpty, let context else { return nil }
    let folded = MemorySearch.fold(cleaned)
    if let existing = memories.first(where: { MemorySearch.fold($0.text) == folded }) {
      existing.updatedAt = Date()
      save()
      return existing
    }
    let resolvedTitle = (title?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
      ?? Self.defaultTitle(for: cleaned)
    let record = MemoryRecord(
      kind: kind ?? MemoryKind.classify(cleaned),
      category: category ?? MemoryCategory.classify(cleaned + " " + resolvedTitle),
      title: String(resolvedTitle.prefix(80)),
      text: cleaned,
      source: source,
      tags: Array(tags.prefix(8)))
    if let location {
      record.latitude = location.latitude
      record.longitude = location.longitude
      record.placeName = location.placeName
    }
    record.thumbnail = thumbnail
    context.insert(record)
    save()
    return record
  }

  static func defaultTitle(for text: String) -> String {
    let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
    let words = firstLine.split(separator: " ").prefix(6).joined(separator: " ")
    return words.count < firstLine.count ? words + "…" : words
  }

  func update(_ record: MemoryRecord, title: String, text: String, kind: MemoryKind, category: MemoryCategory) {
    let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
    // Empty text is ignored (the editor disables Save); deleting here could
    // leave an open detail screen showing a deleted object.
    guard !cleaned.isEmpty else { return }
    record.text = String(cleaned.prefix(1_000))
    let cleanedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
    record.title = String((cleanedTitle.isEmpty ? Self.defaultTitle(for: cleaned) : cleanedTitle).prefix(80))
    record.kindRaw = kind.rawValue
    record.categoryRaw = category.rawValue
    record.updatedAt = Date()
    save()
  }

  func setPinned(_ record: MemoryRecord, _ pinned: Bool) {
    record.pinned = pinned
    save()
  }

  func delete(_ record: MemoryRecord) {
    context?.delete(record)
    save()
  }

  func memory(id: UUID) -> MemoryRecord? {
    memories.first { $0.id == id }
  }

  func deleteAllMemories() {
    for record in memories { context?.delete(record) }
    save()
  }

  // MARK: Notes

  @discardableResult
  func addNote(
    title: String?,
    content: String,
    source: String,
    tags: [String] = [],
    links: [String] = [],
    location: MemoryLocation? = nil
  ) -> NoteRecord? {
    let cleaned = String(content.trimmingCharacters(in: .whitespacesAndNewlines).prefix(20_000))
    guard !cleaned.isEmpty, let context else { return nil }
    let cleanedTitle = (title?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
      ?? Self.defaultTitle(for: cleaned)
    let note = NoteRecord(
      title: String(cleanedTitle.prefix(120)), content: cleaned, source: source,
      tags: Array(tags.prefix(10)), links: Array(links.prefix(20)))
    if let location {
      note.latitude = location.latitude
      note.longitude = location.longitude
      note.placeName = location.placeName
    }
    context.insert(note)
    save()
    return note
  }

  func updateNote(_ note: NoteRecord, title: String, content: String, tags: [String]) {
    note.title = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
    note.content = String(content.prefix(20_000))
    note.tags = Array(tags.prefix(10))
    note.updatedAt = Date()
    save()
  }

  func setPinned(_ note: NoteRecord, _ pinned: Bool) {
    note.pinned = pinned
    save()
  }

  func deleteNote(_ note: NoteRecord) {
    context?.delete(note)
    save()
  }

  func deleteAllNotes() {
    for note in notes { context?.delete(note) }
    save()
  }

  /// Privacy center: removes every memory and note.
  func deleteEverything() {
    for record in memories { context?.delete(record) }
    for note in notes { context?.delete(note) }
    save()
  }

  // MARK: Search and prompts

  func search(_ query: String, limit: Int = 8, includeNotes: Bool = true) -> [MemoryHit] {
    let queryTokens = MemorySearch.tokens(query)
    guard !queryTokens.isEmpty else { return [] }
    let embedding = MemorySearch.looksEnglish(query) ? NLEmbedding.sentenceEmbedding(for: .english) : nil
    var hits: [MemoryHit] = []
    for record in memories {
      let recordText = record.title + " " + record.text + " " + record.tags.joined(separator: " ")
      let document = MemorySearch.tokens(recordText + " " + (record.placeName ?? ""))
      let lexical = MemorySearch.lexicalScore(query: queryTokens, document: document)
      let semantic = embedding.flatMap { MemorySearch.semanticScore(query, record.text, embedding: $0) }
      let score = MemorySearch.combined(lexical: lexical, semantic: semantic, pinned: record.pinned)
      if score >= MemorySearch.threshold { hits.append(MemoryHit(item: .memory(record), score: score)) }
    }
    if includeNotes {
      for note in notes {
        let noteText = note.title + " " + String(note.content.prefix(2_000)) + " " + note.tags.joined(separator: " ")
        let document = MemorySearch.tokens(noteText)
        let lexical = MemorySearch.lexicalScore(query: queryTokens, document: document)
        let semantic = embedding.flatMap { MemorySearch.semanticScore(query, note.title + ". " + note.content, embedding: $0) }
        let score = MemorySearch.combined(lexical: lexical, semantic: semantic, pinned: note.pinned) * 0.95
        if score >= MemorySearch.threshold { hits.append(MemoryHit(item: .note(note), score: score)) }
      }
    }
    return Array(hits.sorted { $0.score > $1.score }.prefix(limit))
  }

  /// Marks memories as used by a recall (for sorting and diagnostics).
  func noteRecalled(_ hits: [MemoryHit]) {
    var changed = false
    for hit in hits {
      if case .memory(let record) = hit.item {
        record.lastRecalledAt = Date()
        changed = true
      }
    }
    if changed { save() }
  }

  /// A few memories the voice model always knows: pinned ones first, then
  /// preferences and the most recent facts. Bounded so the realtime
  /// instructions stay small.
  var promptItems: [String] {
    guard isEnabled else { return [] }
    let pinned = memories.filter(\.pinned)
    let preferences = memories.filter { !$0.pinned && $0.kind == .preference }
    let facts = memories.filter { !$0.pinned && $0.kind == .fact }
    var items: [String] = []
    var characters = 0
    for record in pinned + preferences + facts {
      let line = String(record.text.prefix(200))
      guard characters + line.count <= 1_800, items.count < 12 else { break }
      if items.contains(line) { continue }
      items.append(line)
      characters += line.count
    }
    return items
  }

  /// Memories relevant to a delegated request, for the executor's context.
  func relevantItems(for query: String, limit: Int = 5) -> [String] {
    guard isEnabled else { return [] }
    return search(query, limit: limit, includeNotes: false).map(\.line)
  }

  // MARK: Migration from the JSON files of earlier builds

  private struct LegacyMemoryItem: Decodable {
    let text: String
    let createdAt: Date
    let source: String?
  }

  private struct LegacyNote: Decodable {
    let title: String
    let body: String
    let createdAt: Date
    let source: String?
    let sources: [String]?
  }

  /// Imports memory.json and notes.json once and keeps the old files as
  /// `.migrated-backup` (never deleted automatically).
  private func migrateLegacyFiles() {
    guard !defaults.bool(forKey: Self.migratedKey), let context else { return }
    guard let directory = try? FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
      .appending(path: "AutoLoom", directoryHint: .isDirectory) else {
      defaults.set(true, forKey: Self.migratedKey)
      return
    }
    let memoryFile = directory.appending(path: "memory.json")
    if let data = try? Data(contentsOf: memoryFile),
       let items = try? JSONDecoder().decode([LegacyMemoryItem].self, from: data) {
      for item in items {
        let record = MemoryRecord(
          kind: MemoryKind.classify(item.text),
          category: MemoryCategory.classify(item.text),
          title: Self.defaultTitle(for: item.text),
          text: item.text,
          createdAt: item.createdAt,
          source: "migrated")
        context.insert(record)
      }
      try? FileManager.default.moveItem(at: memoryFile, to: directory.appending(path: "memory.json.migrated-backup"))
    }
    let notesFile = directory.appending(path: "notes.json")
    if let data = try? Data(contentsOf: notesFile),
       let items = try? JSONDecoder().decode([LegacyNote].self, from: data) {
      for item in items {
        let note = NoteRecord(
          title: item.title, content: item.body, createdAt: item.createdAt,
          source: item.source ?? "migrated", links: item.sources ?? [])
        context.insert(note)
      }
      try? FileManager.default.moveItem(at: notesFile, to: directory.appending(path: "notes.json.migrated-backup"))
    }
    do {
      try context.save()
      defaults.set(true, forKey: Self.migratedKey)
    } catch {
      storageError = LogSanitizer.sanitize(error.localizedDescription, limit: 200)
    }
  }
}
