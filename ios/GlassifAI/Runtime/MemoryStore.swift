import Foundation
import NaturalLanguage
import SwiftData
import UserNotifications

/// What kind of thing a memory is.
enum MemoryKind: String, CaseIterable, Codable, Identifiable {
  case profile = "PROFILE"
  case preference = "PREFERENCE"
  case fact = "FACT"
  case person = "PERSON"
  case place = "PLACE"
  case vehicle = "VEHICLE"
  /// Something the user is working on ("AutoLoom projesi", "the kitchen
  /// renovation").
  case project = "PROJECT"
  case episode = "EPISODE"
  case note = "NOTE"
  case taskContext = "TASK_CONTEXT"
  case visual = "VISUAL_MEMORY"
  case conversationSummary = "CONVERSATION_SUMMARY"

  var id: String { rawValue }

  var label: String {
    switch self {
    case .profile: L.t("About me", "Hakkımda")
    case .preference: L.t("Preference", "Tercih")
    case .fact: L.t("Fact", "Bilgi")
    case .person: L.t("Person", "Kişi")
    case .place: L.t("Place", "Yer")
    case .vehicle: L.t("Vehicle", "Araç")
    case .project: L.t("Project", "Proje")
    case .episode: L.t("Moment", "An")
    case .note: L.t("Note", "Not")
    case .taskContext: L.t("Task context", "Görev bağlamı")
    case .visual: L.t("Visual", "Görsel")
    case .conversationSummary: L.t("Conversation", "Konuşma")
    }
  }

  var systemImage: String {
    switch self {
    case .profile: "person.crop.circle"
    case .preference: "heart"
    case .fact: "info.circle"
    case .person: "person.2"
    case .place: "mappin.and.ellipse"
    case .vehicle: "car"
    case .project: "folder"
    case .episode: "clock.arrow.circlepath"
    case .note: "note.text"
    case .taskContext: "checklist"
    case .visual: "eye"
    case .conversationSummary: "bubble.left.and.bubble.right"
    }
  }

  /// Kinds a user can pick when editing a memory by hand.
  static var editable: [MemoryKind] { allCases.filter { $0 != .conversationSummary } }

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
    let project = [" proje", " project", "sprint", " repo ", "repository", "milestone", "teslim tarihi", "deadline"]
    if project.contains(where: { words.contains($0) }) { return .project }
    return .fact
  }
}

/// Where a memory is listed in the Memory tab.
enum MemoryCategory: String, CaseIterable, Codable, Identifiable {
  case people
  case places
  case vehicles
  case projects
  case other

  var id: String { rawValue }

  var label: String {
    switch self {
    case .people: L.t("People", "Kişiler")
    case .places: L.t("Places", "Yerler")
    case .vehicles: L.t("Vehicles", "Araçlar")
    case .projects: L.t("Projects", "Projeler")
    case .other: L.t("Other", "Diğer")
    }
  }

  var systemImage: String {
    switch self {
    case .people: "person.2"
    case .places: "mappin.and.ellipse"
    case .vehicles: "car"
    case .projects: "folder"
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
    let projects = [" proje", " project", "sprint", " repo ", "repository", "milestone", "teslim tarihi", "deadline"]
    if projects.contains(where: { words.contains($0) }) { return .projects }
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

/// An AutoLoom task (local, separate from Apple Reminders): "bunu görev
/// olarak ekle", "yarın bu arabayı tekrar kontrol et görev oluştur".
@Model
final class TaskItem {
  @Attribute(.unique) var id: UUID
  var title: String
  var notes: String
  var createdAt: Date
  var dueAt: Date?
  /// False when only a day was given.
  var dueHasTime: Bool
  var completed: Bool
  var completedAt: Date?
  /// 0 normal, 1 high.
  var priority: Int
  /// voice, manual…
  var source: String
  var linkedMemoryID: UUID?
  var linkedNoteID: UUID?
  /// Identifier of the local notification for the due time, if any.
  var notificationID: String?

  init(
    id: UUID = UUID(),
    title: String,
    notes: String = "",
    createdAt: Date = Date(),
    dueAt: Date? = nil,
    dueHasTime: Bool = true,
    priority: Int = 0,
    source: String
  ) {
    self.id = id
    self.title = title
    self.notes = notes
    self.createdAt = createdAt
    self.dueAt = dueAt
    self.dueHasTime = dueHasTime
    self.completed = false
    self.completedAt = nil
    self.priority = priority
    self.source = source
    self.linkedMemoryID = nil
    self.linkedNoteID = nil
    self.notificationID = nil
  }
}

/// What the user explicitly told AutoLoom about themselves. Each field is
/// set only when the user says it or types it; nothing is inferred.
struct UserProfile: Codable, Equatable {
  var preferredName: String?

  static let defaultsKey = "autoloom.profile"

  static func load(_ defaults: UserDefaults = .standard) -> UserProfile {
    guard let data = defaults.data(forKey: defaultsKey),
          let profile = try? JSONDecoder().decode(UserProfile.self, from: data) else { return UserProfile() }
    return profile
  }

  func save(_ defaults: UserDefaults = .standard) {
    if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.defaultsKey) }
  }

  /// "tolga'yım", "Tolga." → "Tolga". Letters, spaces, hyphens and
  /// apostrophes inside a name only; at most three words and 40 characters.
  static func cleanName(_ raw: String) -> String? {
    var words: [String] = []
    for piece in raw.split(whereSeparator: { $0 == " " }) {
      // A Turkish suffix after an apostrophe is not part of the name.
      let stem = piece.split(whereSeparator: { $0 == "'" || $0 == "’" }).first.map(String.init) ?? ""
      let letters = stem.filter { $0.isLetter || $0 == "-" }
      guard !letters.isEmpty else { continue }
      words.append(letters)
      if words.count == 3 { break }
    }
    guard !words.isEmpty else { return nil }
    let name = words.map { word -> String in
      let first = String(word.prefix(1)).uppercased(with: Locale(identifier: "tr_TR"))
      return first + word.dropFirst()
    }.joined(separator: " ")
    guard name.count <= 40, name.contains(where: \.isLetter) else { return nil }
    return name
  }
}

/// A search result over memories and notes.
struct MemoryHit: Identifiable {
  enum Item {
    case memory(MemoryRecord)
    case note(NoteRecord)
    case task(TaskItem)
  }

  let item: Item
  let score: Double

  var id: UUID {
    switch item {
    case .memory(let record): record.id
    case .note(let note): note.id
    case .task(let task): task.id
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
    case .task(let task):
      let due = task.dueAt.map { " — " + TimePhraseParser.describe($0, hasTime: task.dueHasTime, turkish: L.isTurkish) } ?? ""
      let state = task.completed ? L.t(" (done)", " (tamamlandı)") : ""
      return "\(L.t("Task", "Görev")) \"\(task.title)\"\(due)\(state)"
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
  /// on its own below the threshold. Relevance first, then small boosts for
  /// pinned items, exact names (people, brands, places) and recent items.
  static func combined(
    lexical: Double,
    semantic: Double?,
    pinned: Bool,
    ageDays: Double = 0,
    exactEntity: Bool = false
  ) -> Double {
    var score = lexical
    if let semantic { score = max(score, lexical * 0.6 + max(0, semantic - 0.35) * 0.9) }
    // The boosts only reorder results that are relevant on their own.
    guard score >= threshold else { return score }
    if pinned { score += 0.05 }
    if exactEntity { score += 0.1 }
    // Up to +0.05 for items from the last few days, fading over a month.
    score += 0.05 * max(0, 1 - ageDays / 30)
    return score
  }

  /// Whether a capitalised word of the query (a name, brand or place)
  /// appears as a whole word in the document.
  static func hasExactEntity(query: String, document: String) -> Bool {
    let names = query.split(separator: " ")
      .map { $0.trimmingCharacters(in: .punctuationCharacters) }
      .filter { $0.count >= 3 && ($0.first?.isUppercase ?? false) }
    guard !names.isEmpty else { return false }
    let words = Set(tokens(document))
    return names.contains { words.contains(fold($0)) }
  }

  static let threshold = 0.34
}

/// A compact record of one AutoLoom conversation, written when a meaningful
/// conversation ends (Settings → Memory → Conversation memory). Only this
/// summary is kept, never the transcript.
struct ConversationSummary: Equatable {
  var summary: String
  var topics: [String] = []
  var decisions: [String] = []
  var openTasks: [String] = []
  var entities: [String] = []
  var startedAt: Date
  var endedAt: Date

  /// The stored text: the summary first, then the labelled lists.
  var storedText: String {
    var lines = [summary]
    if !topics.isEmpty { lines.append(L.t("Topics: ", "Konular: ") + topics.joined(separator: ", ")) }
    if !decisions.isEmpty { lines.append(L.t("Decisions: ", "Kararlar: ") + decisions.joined(separator: "; ")) }
    if !openTasks.isEmpty { lines.append(L.t("Open tasks: ", "Açık işler: ") + openTasks.joined(separator: "; ")) }
    if !entities.isEmpty { lines.append(L.t("Mentioned: ", "Geçenler: ") + entities.joined(separator: ", ")) }
    return lines.joined(separator: "\n")
  }

  var title: String {
    topics.first.map { String($0.prefix(60)) } ?? MemoryStore.defaultTitle(for: summary)
  }
}

/// The user's memories, notes, AutoLoom tasks and profile. Memory is
/// explicit: nothing is saved unless the user asks ("hatırla", "kaydet",
/// "not al", "unutma", "remember…") or adds it on screen; the only automatic
/// entries are short conversation summaries, which the user can turn off.
/// Stored on this iPhone with SwiftData; never synced.
@MainActor
final class MemoryStore: ObservableObject {
  static let shared = MemoryStore()

  static let enabledKey = "autoloom.memory.v2.enabled"
  static let visualEnabledKey = "autoloom.memory.visual.enabled"
  static let visualPhotosKey = "autoloom.memory.visual.photos"
  static let locationKey = "autoloom.memory.location"
  /// Short summaries of meaningful conversations (on by default).
  static let conversationMemoryKey = "autoloom.memory.conversations"
  /// The assistant may suggest things worth remembering (off by default;
  /// even then nothing is saved without the user's yes).
  static let smartMemoryKey = "autoloom.memory.smart"
  private static let migratedKey = "autoloom.memory.v2.migrated"
  /// Conversation summaries kept; older unpinned ones are removed.
  static let summaryLimit = 200

  let container: ModelContainer?
  @Published private(set) var memories: [MemoryRecord] = []
  @Published private(set) var notes: [NoteRecord] = []
  @Published private(set) var tasks: [TaskItem] = []
  @Published private(set) var profile: UserProfile
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
  @Published var conversationMemoryEnabled: Bool {
    didSet { defaults.set(conversationMemoryEnabled, forKey: Self.conversationMemoryKey) }
  }
  @Published var smartMemoryEnabled: Bool {
    didSet { defaults.set(smartMemoryEnabled, forKey: Self.smartMemoryKey) }
  }

  private let defaults: UserDefaults

  init(inMemory: Bool = false, defaults: UserDefaults = .standard) {
    self.defaults = defaults
    isEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
    visualMemoriesEnabled = defaults.bool(forKey: Self.visualEnabledKey)
    saveVisualPhotos = defaults.bool(forKey: Self.visualPhotosKey)
    attachLocation = defaults.bool(forKey: Self.locationKey)
    conversationMemoryEnabled = defaults.object(forKey: Self.conversationMemoryKey) as? Bool ?? true
    smartMemoryEnabled = defaults.bool(forKey: Self.smartMemoryKey)
    profile = UserProfile.load(defaults)
    let schema = Schema([MemoryRecord.self, NoteRecord.self, TaskItem.self])
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
    let loadedTasks = (try? context.fetch(FetchDescriptor<TaskItem>())) ?? []
    tasks = loadedTasks.sorted(by: Self.taskOrder)
  }

  /// Open tasks first (earliest due first, undated after dated), then
  /// completed ones (most recently completed first).
  static func taskOrder(_ a: TaskItem, _ b: TaskItem) -> Bool {
    if a.completed != b.completed { return !a.completed }
    if a.completed { return (a.completedAt ?? .distantPast) > (b.completedAt ?? .distantPast) }
    switch (a.dueAt, b.dueAt) {
    case let (x?, y?) where x != y: return x < y
    case (.some, nil): return true
    case (nil, .some): return false
    default: return a.createdAt > b.createdAt
    }
  }

  /// Saves pending changes. On failure the changes are rolled back, so
  /// nothing is reported as saved that iOS did not store.
  @discardableResult
  private func save() -> Bool {
    var saved = true
    do {
      try context?.save()
    } catch {
      saved = false
      context?.rollback()
      storageError = LogSanitizer.sanitize(error.localizedDescription, limit: 200)
      NSLog("[AutoLoom] memory save failed: %@", storageError ?? "")
    }
    refresh()
    return saved
  }

  // MARK: Memories

  /// Saves an explicit memory. A memory with the same words is refreshed
  /// instead of duplicated. Returns nil when memory is off, the text is
  /// empty, or the store could not save it.
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
      return save() ? existing : nil
    }
    let resolvedTitle = (title?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
      ?? Self.defaultTitle(for: cleaned)
    let resolvedKind = kind ?? MemoryKind.classify(cleaned)
    let record = MemoryRecord(
      kind: resolvedKind,
      category: category ?? Self.category(for: resolvedKind) ?? MemoryCategory.classify(cleaned + " " + resolvedTitle),
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
    return save() ? record : nil
  }

  /// People, places and vehicles are listed under their own category.
  private static func category(for kind: MemoryKind) -> MemoryCategory? {
    switch kind {
    case .person: .people
    case .place: .places
    case .vehicle: .vehicles
    case .project: .projects
    default: nil
    }
  }

  nonisolated static func defaultTitle(for text: String) -> String {
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

  /// Memory → Clear all: every memory, conversation summary and the profile.
  /// Notes and tasks are kept (they have their own delete).
  func deleteAllMemories() {
    for record in memories { context?.delete(record) }
    save()
    clearProfile()
  }

  // MARK: Profile

  /// What the user said their name is ("Benim adım Tolga"). Returns the
  /// cleaned name, or nil when it is not a usable name.
  @discardableResult
  func setPreferredName(_ raw: String) -> String? {
    guard let name = UserProfile.cleanName(raw) else { return nil }
    profile.preferredName = name
    profile.save(defaults)
    return name
  }

  func clearProfile() {
    profile = UserProfile()
    profile.save(defaults)
  }

  /// Memories about the user that belong in "About me".
  var profileMemories: [MemoryRecord] {
    memories.filter { $0.kind == .profile }
  }

  // MARK: Conversation summaries

  var conversationSummaries: [MemoryRecord] {
    memories.filter { $0.kind == .conversationSummary }.sorted { $0.createdAt > $1.createdAt }
  }

  /// Stores a finished conversation's summary. Returns nil when memory or
  /// conversation memory is off.
  @discardableResult
  func saveConversationSummary(_ summary: ConversationSummary) -> MemoryRecord? {
    guard isEnabled, conversationMemoryEnabled, let context else { return nil }
    // Line by line, so the labelled lists keep their own lines.
    let text = summary.storedText
      .split(separator: "\n")
      .map { TaskTrace.redactUserText(String($0), limit: 500) }
      .joined(separator: "\n")
    guard !text.isEmpty else { return nil }
    let tags = Array((summary.topics + summary.entities).prefix(8))
    let record = MemoryRecord(
      kind: .conversationSummary,
      category: .other,
      title: String(summary.title.prefix(80)),
      text: text,
      createdAt: summary.endedAt,
      source: "conversation",
      tags: tags)
    context.insert(record)
    // Keep the newest summaries; pinned ones are never removed.
    let old = conversationSummaries.filter { !$0.pinned }.dropFirst(Self.summaryLimit - 1)
    for record in old { context.delete(record) }
    return save() ? record : nil
  }

  /// The latest conversation summary, if it is recent enough to help.
  func recentConversationSummary(within days: Double = 14, now: Date = Date()) -> MemoryRecord? {
    guard isEnabled, conversationMemoryEnabled,
          let latest = conversationSummaries.first,
          now.timeIntervalSince(latest.createdAt) < days * 86_400 else { return nil }
    return latest
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
    // The same words again within a minute (a command delivered twice, or
    // the app and a delegation both saving it) are one note.
    if let recent = notes.first(where: { $0.content == cleaned && Date().timeIntervalSince($0.createdAt) < Self.duplicateWindow }) {
      return recent
    }
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
    return save() ? note : nil
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

  // MARK: AutoLoom tasks

  /// Adds a local task. The due time comes from the app's time parser,
  /// never from a model.
  @discardableResult
  func addTask(
    title: String,
    notes: String = "",
    dueAt: Date? = nil,
    dueHasTime: Bool = true,
    priority: Int = 0,
    source: String
  ) -> TaskItem? {
    let cleaned = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
    guard !cleaned.isEmpty, let context else { return nil }
    if let recent = tasks.first(where: {
      !$0.completed && $0.title == cleaned && $0.dueAt == dueAt && Date().timeIntervalSince($0.createdAt) < Self.duplicateWindow
    }) {
      return recent
    }
    let task = TaskItem(
      title: cleaned, notes: String(notes.prefix(2_000)), dueAt: dueAt,
      dueHasTime: dueAt == nil ? true : dueHasTime, priority: priority, source: source)
    context.insert(task)
    return save() ? task : nil
  }

  func updateTask(_ task: TaskItem, title: String, notes: String, dueAt: Date?, dueHasTime: Bool) {
    let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleaned.isEmpty else { return }
    task.title = String(cleaned.prefix(200))
    task.notes = String(notes.prefix(2_000))
    if task.dueAt != dueAt || task.dueHasTime != dueHasTime { cancelNotification(of: task) }
    task.dueAt = dueAt
    task.dueHasTime = dueHasTime
    save()
  }

  func setCompleted(_ task: TaskItem, _ done: Bool) {
    task.completed = done
    task.completedAt = done ? Date() : nil
    if done { cancelNotification(of: task) }
    save()
  }

  /// "Bunun için görev oluştur" after a note: the task remembers the note.
  func link(_ task: TaskItem, toNote noteID: UUID) {
    task.linkedNoteID = noteID
    save()
  }

  func setNotificationID(_ task: TaskItem, _ id: String?) {
    task.notificationID = id
    save()
  }

  func deleteTask(_ task: TaskItem) {
    cancelNotification(of: task)
    context?.delete(task)
    save()
  }

  func deleteAllTasks() {
    for task in tasks {
      cancelNotification(of: task)
      context?.delete(task)
    }
    save()
  }

  func task(id: UUID) -> TaskItem? {
    tasks.first { $0.id == id }
  }

  private func cancelNotification(of task: TaskItem) {
    guard let id = task.notificationID else { return }
    UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
    task.notificationID = nil
  }

  /// A note or task with the same words saved again within this time is
  /// the same one.
  static let duplicateWindow: TimeInterval = 60

  /// The home or work address the user asked AutoLoom to remember ("Hatırla:
  /// ev adresim Bağdat Caddesi 12"), without the lead-in words.
  func savedAddress(home: Bool) -> String? {
    let leads = home
      ? ["ev adresim", "evimin adresi", "my home address is", "home address is", "my home address", "evim"]
      : ["is adresim", "isyerimin adresi", "isyeri adresim", "ofis adresim", "my work address is", "work address is",
         "my office address is", "my office is", "isyerim", "ofisim"]
    let otherPlace = home ? ["is adres", "isyer", "ofis", "work", "office"] : ["ev adres", "evim", "home"]
    for record in memories where record.kind != .conversationSummary {
      let folded = MemorySearch.fold(record.text)
      for lead in leads {
        guard let range = folded.range(of: lead) else { continue }
        // "Ev adresim" must not match inside "iş adresim".
        let before = folded[folded.startIndex..<range.lowerBound]
        guard !otherPlace.contains(where: { before.hasSuffix($0 + " ") || before.hasSuffix($0) }) else { continue }
        let offset = folded.distance(from: folded.startIndex, to: range.upperBound)
        guard offset < record.text.count else { continue }
        var address = String(record.text.dropFirst(offset))
          .trimmingCharacters(in: CharacterSet(charactersIn: ":;,-–").union(.whitespacesAndNewlines))
        for filler in ["şu", "su", "is", "=", ":"] where address.lowercased().hasPrefix(filler + " ") {
          address = String(address.dropFirst(filler.count + 1))
        }
        // "Evim Kadıköy'de" → "Kadıköy".
        var words = address.split(separator: " ").map(String.init)
        if let last = words.last, let apostrophe = last.firstIndex(where: { $0 == "'" || $0 == "’" }) {
          words[words.count - 1] = String(last[..<apostrophe])
          address = words.joined(separator: " ")
        }
        address = address.trimmingCharacters(in: CharacterSet(charactersIn: ".").union(.whitespaces))
        if address.count >= 3 { return address }
      }
    }
    return nil
  }

  /// Open tasks due today or overdue.
  func todayTasks(now: Date = Date(), calendar: Calendar = .current) -> [TaskItem] {
    let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
    return tasks.filter { !$0.completed && ($0.dueAt.map { $0 < end } ?? false) }
  }

  /// Open tasks due later, and open tasks without a date.
  func upcomingTasks(now: Date = Date(), calendar: Calendar = .current) -> [TaskItem] {
    let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
    return tasks.filter { !$0.completed && ($0.dueAt.map { $0 >= end } ?? true) }
  }

  var completedTasks: [TaskItem] {
    tasks.filter(\.completed)
  }

  /// Privacy center: removes every memory, note, task and the profile.
  func deleteEverything() {
    for record in memories { context?.delete(record) }
    for note in notes { context?.delete(note) }
    for task in tasks {
      cancelNotification(of: task)
      context?.delete(task)
    }
    save()
    clearProfile()
  }

  // MARK: Search and prompts

  func search(
    _ query: String,
    limit: Int = 8,
    includeNotes: Bool = true,
    includeTasks: Bool = true,
    now: Date = Date()
  ) -> [MemoryHit] {
    let queryTokens = MemorySearch.tokens(query)
    guard !queryTokens.isEmpty else { return [] }
    let embedding = MemorySearch.looksEnglish(query) ? NLEmbedding.sentenceEmbedding(for: .english) : nil
    func age(_ date: Date) -> Double { max(0, now.timeIntervalSince(date) / 86_400) }
    var hits: [MemoryHit] = []
    for record in memories {
      let recordText = record.title + " " + record.text + " " + record.tags.joined(separator: " ")
      let document = MemorySearch.tokens(recordText + " " + (record.placeName ?? ""))
      let lexical = MemorySearch.lexicalScore(query: queryTokens, document: document)
      let semantic = embedding.flatMap { MemorySearch.semanticScore(query, record.text, embedding: $0) }
      let score = MemorySearch.combined(
        lexical: lexical, semantic: semantic, pinned: record.pinned, ageDays: age(record.updatedAt),
        exactEntity: MemorySearch.hasExactEntity(query: query, document: recordText))
      if score >= MemorySearch.threshold { hits.append(MemoryHit(item: .memory(record), score: score)) }
    }
    if includeNotes {
      for note in notes {
        let noteText = note.title + " " + String(note.content.prefix(2_000)) + " " + note.tags.joined(separator: " ")
        let document = MemorySearch.tokens(noteText)
        let lexical = MemorySearch.lexicalScore(query: queryTokens, document: document)
        let semantic = embedding.flatMap { MemorySearch.semanticScore(query, note.title + ". " + note.content, embedding: $0) }
        let score = MemorySearch.combined(
          lexical: lexical, semantic: semantic, pinned: note.pinned, ageDays: age(note.updatedAt),
          exactEntity: MemorySearch.hasExactEntity(query: query, document: noteText)) * 0.95
        if score >= MemorySearch.threshold { hits.append(MemoryHit(item: .note(note), score: score)) }
      }
    }
    if includeTasks {
      for task in tasks {
        let taskText = task.title + " " + task.notes
        let lexical = MemorySearch.lexicalScore(query: queryTokens, document: MemorySearch.tokens(taskText))
        let score = MemorySearch.combined(
          lexical: lexical, semantic: nil, pinned: false, ageDays: age(task.createdAt),
          exactEntity: MemorySearch.hasExactEntity(query: query, document: taskText)) * 0.9
        if score >= MemorySearch.threshold { hits.append(MemoryHit(item: .task(task), score: score)) }
      }
    }
    return Array(hits.sorted { $0.score > $1.score }.prefix(limit))
  }

  /// Conversation summaries that match a question about earlier talks
  /// ("Geçen gün Ray-Ban kamerasıyla ne yapıyorduk?"), newest first when
  /// the words say nothing specific.
  func searchConversations(_ query: String, limit: Int = 3) -> [MemoryRecord] {
    let matches = search(query, limit: 20, includeNotes: false, includeTasks: false).compactMap { hit -> MemoryRecord? in
      if case .memory(let record) = hit.item, record.kind == .conversationSummary { return record }
      return nil
    }
    if !matches.isEmpty { return Array(matches.prefix(limit)) }
    return Array(conversationSummaries.prefix(limit))
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
  /// what the user said about themselves, preferences and the most recent
  /// facts. Bounded so the realtime instructions stay small; conversation
  /// summaries and visual memories are retrieved on demand instead.
  var promptItems: [String] {
    guard isEnabled else { return [] }
    let pinned = memories.filter { $0.pinned && $0.kind != .conversationSummary }
    let about = memories.filter { !$0.pinned && $0.kind == .profile }
    let preferences = memories.filter { !$0.pinned && $0.kind == .preference }
    let facts = memories.filter { !$0.pinned && [.fact, .person, .place, .vehicle].contains($0.kind) }
    var items: [String] = []
    var characters = 0
    for record in pinned + about + preferences + facts {
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
    return search(query, limit: limit, includeNotes: false, includeTasks: false).map(\.line)
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
