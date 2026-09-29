import Foundation
import SwiftUI

/// "Search AutoLoom": one on-device search over notes, tasks, memories,
/// conversation summaries, vehicles, Ray-Ban captures, visual memories, the
/// shopping list and the parking spot. Voice ("geçen hafta Corolla ile ilgili
/// kaydettiğim şeyi bul") and the search screen use the same engine. Turkish
/// word forms match ("Corolla'nın" → "Corolla"); dates and kinds said in the
/// sentence become filters. Nothing leaves the phone.
struct SearchResult: Identifiable, Equatable {
  enum Kind: String, CaseIterable, Identifiable {
    case note, task, memory, conversation, vehicle, capture, visualMemory, shopping, parking, document

    var id: String { rawValue }

    var title: String {
      switch self {
      case .note: L.t("Notes", "Notlar")
      case .task: L.t("Tasks", "Görevler")
      case .memory: L.t("Memory", "Hafıza")
      case .conversation: L.t("Conversations", "Konuşmalar")
      case .vehicle: L.t("Vehicles", "Araçlar")
      case .capture: L.t("Photos and videos", "Fotoğraf ve videolar")
      case .visualMemory: L.t("Visual memory", "Görsel hafıza")
      case .shopping: L.t("Shopping list", "Alışveriş listesi")
      case .parking: L.t("Parking", "Park yeri")
      case .document: L.t("Documents and receipts", "Belgeler ve fişler")
      }
    }

    var systemImage: String {
      switch self {
      case .note: "note.text"
      case .task: "checklist"
      case .memory: "brain"
      case .conversation: "bubble.left.and.bubble.right"
      case .vehicle: "car"
      case .capture: "photo.on.rectangle"
      case .visualMemory: "eye"
      case .shopping: "cart"
      case .parking: "parkingsign.circle"
      case .document: "doc.text"
      }
    }
  }

  let id: String
  let kind: Kind
  let title: String
  let snippet: String
  let date: Date?
  let score: Double
}

@MainActor
enum GlobalSearch {
  struct Query: Equatable {
    var text: String
    var kinds: Set<SearchResult.Kind>?
    var from: Date?
    var to: Date?

    /// The words that are searched for (filters and command words removed).
    var terms: [String] { MemorySearch.tokens(text) }
  }

  /// Words that only say "search" or "saved", not what to find.
  static let commandWords: Set<String> = [
    "bul", "bulur", "musun", "misin", "goster", "gosterir", "ara", "kaydettigim", "kaydettigimiz", "kaydettiklerimi",
    "kaydettigimi", "ilgili", "hakkinda", "seyi", "seyleri", "neler", "neydi", "autoloom", "autoloomda", "icinde",
    "ile", "icin", "olan", "bir", "the", "a", "an", "my", "i", "what",
    "find", "search", "show", "saved", "about", "anything", "everything", "related", "stuff", "things", "for",
  ]

  /// Date and kind filters from the spoken sentence.
  static func parse(_ spoken: String, now: Date = Date(), calendar: Calendar = .current) -> Query {
    let folded = " " + MemorySearch.fold(spoken)
      .components(separatedBy: CharacterSet.alphanumerics.inverted)
      .filter { !$0.isEmpty }.joined(separator: " ") + " "
    func has(_ words: [String]) -> Bool { words.contains { folded.contains(" " + $0) } }
    var query = Query(text: spoken)
    let startOfToday = calendar.startOfDay(for: now)
    if has(["bugun", "today"]) {
      query.from = startOfToday
    } else if has(["dun ", "yesterday"]) {
      query.from = calendar.date(byAdding: .day, value: -1, to: startOfToday)
      query.to = startOfToday
    } else if has(["bu hafta", "this week"]) {
      query.from = calendar.date(byAdding: .day, value: -7, to: now)
    } else if has(["gecen hafta", "last week"]) {
      // Said loosely: roughly one to two weeks ago; recent items still count.
      query.from = calendar.date(byAdding: .day, value: -15, to: now)
    } else if has(["bu ay", "this month"]) {
      query.from = calendar.date(byAdding: .day, value: -31, to: now)
    } else if has(["gecen ay", "last month"]) {
      query.from = calendar.date(byAdding: .day, value: -62, to: now)
    }
    var kinds = Set<SearchResult.Kind>()
    if has(["not", "note"]) { kinds.insert(.note) }
    if has(["gorev", "task", "todo", "yapilacak"]) { kinds.insert(.task) }
    if has(["hafiza", "memory", "hatirladi"]) { kinds.insert(.memory) }
    if has(["konusma", "konustu", "conversation", "talked"]) { kinds.insert(.conversation) }
    if has(["arac", "vehicle", "stok", "stock"]) { kinds.insert(.vehicle) }
    if has(["fotograf", "foto ", "video", "cekim", "cektigim", "photo", "picture", "capture"]) { kinds.insert(.capture) }
    if has(["gordugum", "gordum", "saw", "seen"]) { kinds.insert(.visualMemory) }
    if !kinds.isEmpty {
      // Notes, memories and visual memories are close cousins: a memory word
      // never hides a matching note.
      if kinds.contains(.note) || kinds.contains(.memory) { kinds.formUnion([.note, .memory, .visualMemory]) }
      query.kinds = kinds
    }
    let dateWords: Set<String> = [
      "bugun", "dun", "bu", "hafta", "gecen", "ay", "today", "yesterday", "this", "last", "week", "month",
      "notlarimda", "notlarim", "notlarimi", "notlarda", "gorevlerde", "fotograflari", "fotograflarini",
    ]
    let kept = MemorySearch.fold(spoken)
      .components(separatedBy: CharacterSet.alphanumerics.inverted)
      .filter { !$0.isEmpty && !commandWords.contains($0) && !dateWords.contains($0) }
    query.text = kept.joined(separator: " ")
    return query
  }

  static func run(_ query: Query, limit: Int = 20, now: Date = Date()) -> [SearchResult] {
    let terms = query.terms
    guard !terms.isEmpty || query.kinds != nil || query.from != nil else { return [] }
    var results: [SearchResult] = []
    func wants(_ kind: SearchResult.Kind) -> Bool { query.kinds?.contains(kind) ?? true }
    func inRange(_ date: Date?) -> Bool {
      guard let date else { return query.from == nil && query.to == nil }
      if let from = query.from, date < from { return false }
      if let to = query.to, date >= to { return false }
      return true
    }
    func score(_ text: String, date: Date?) -> Double? {
      let lexical = terms.isEmpty ? 0.5 : MemorySearch.lexicalScore(query: terms, document: MemorySearch.tokens(text))
      guard lexical > 0 else { return nil }
      var value = lexical
      if let date { value += max(0, 0.15 - now.timeIntervalSince(date) / 86_400 / 200) }
      return value
    }
    func add(_ kind: SearchResult.Kind, id: String, title: String, snippet: String, date: Date?, text: String) {
      guard wants(kind), inRange(date), let value = score(text, date: date) else { return }
      results.append(SearchResult(
        id: "\(kind.rawValue):\(id)", kind: kind, title: String(title.prefix(90)), snippet: String(snippet.prefix(160)),
        date: date, score: value))
    }

    let memory = MemoryStore.shared
    for note in memory.notes {
      add(.note, id: note.id.uuidString, title: note.title, snippet: note.content, date: note.createdAt,
          text: note.title + " " + note.content + " " + note.tags.joined(separator: " "))
    }
    for task in memory.tasks {
      add(.task, id: task.id.uuidString, title: task.title, snippet: task.notes, date: task.createdAt,
          text: task.title + " " + task.notes)
    }
    if memory.isEnabled {
      let visual = VisualMemoryIndex.shared.entries
      for record in memory.memories {
        let kind: SearchResult.Kind = record.kind == .conversationSummary ? .conversation
          : record.kind == .visual ? .visualMemory : .memory
        // A visual memory is also found by the text and objects read in it.
        let read = visual[record.id].map { $0.analysis.text + " " + $0.analysis.labels.joined(separator: " ") } ?? ""
        add(kind, id: record.id.uuidString, title: record.title, snippet: record.text, date: record.createdAt,
            text: record.title + " " + record.text + " " + (record.placeName ?? "") + " " + read)
      }
    }
    for vehicle in DealerStore.shared.vehicles {
      let facts = [vehicle.title, vehicle.vin ?? "", vehicle.stockNumber.map { "stok \($0) stock \($0)" } ?? "",
                   vehicle.color ?? "", vehicle.damage.map(\.text).joined(separator: " ")].joined(separator: " ")
      add(.vehicle, id: vehicle.id.uuidString, title: vehicle.title,
          snippet: vehicle.odometer.map { $0.text } ?? vehicle.status.title, date: vehicle.updatedAt, text: facts)
    }
    let vehicles = Dictionary(uniqueKeysWithValues: DealerStore.shared.vehicles.map { ($0.id, $0.title) })
    for capture in CaptureLibrary.shared.records {
      let vehicle = capture.vehicleSessionID.flatMap { vehicles[$0] } ?? ""
      let label = capture.label?.title ?? ""
      let words = [capture.kind == .video ? "video" : "fotoğraf photo", label, capture.caption ?? "", vehicle]
      add(.capture, id: capture.id.uuidString,
          title: [vehicle, label].filter { !$0.isEmpty }.joined(separator: " · ").ifEmpty(capture.kind == .video
            ? L.t("Video", "Video") : L.t("Photo", "Fotoğraf")),
          snippet: capture.caption ?? "", date: capture.createdAt, text: words.joined(separator: " "))
    }
    for item in ShoppingListStore.shared.items where !item.done {
      add(.shopping, id: item.id.uuidString, title: item.text, snippet: L.t("On the shopping list", "Alışveriş listesinde"),
          date: item.addedAt, text: item.text + " alışveriş shopping")
    }
    if let spot = ParkingStore.shared.spot {
      add(.parking, id: spot.id.uuidString, title: spot.placeName ?? L.t("Parking spot", "Park yeri"),
          snippet: spot.note ?? "", date: spot.at,
          text: [spot.placeName ?? "", spot.note ?? "", "park parking araba car"].joined(separator: " "))
    }
    for document in DocumentStore.shared.records {
      add(.document, id: document.id.uuidString, title: document.title, snippet: document.total?.text ?? String(document.text.prefix(120)),
          date: document.at, text: document.title + " " + document.text + " " + (document.merchant ?? ""))
    }
    for extra in extraSources {
      for result in extra(query) where wants(result.kind) && inRange(result.date) { results.append(result) }
    }
    return Array(results.sorted {
      $0.score != $1.score ? $0.score > $1.score : ($0.date ?? .distantPast) > ($1.date ?? .distantPast)
    }.prefix(limit))
  }

  /// Sources added by other modules (visual memories, Spotlight semantic
  /// results) without this file knowing them.
  static var extraSources: [(Query) -> [SearchResult]] = []

  /// Up to three results in one short spoken summary (facts only).
  static func spokenSummary(_ results: [SearchResult], query: Query) -> String {
    guard !results.isEmpty else {
      return "Nothing saved on this iPhone matches \"\(query.text)\". Say so honestly in one short sentence; do not guess."
    }
    let lines = results.prefix(3).map { result -> String in
      let date = result.date.map { " (\($0.formatted(date: .abbreviated, time: .omitted)))" } ?? ""
      return "- \(result.kind.rawValue): \(result.title)\(date)" + (result.snippet.isEmpty ? "" : " — \(result.snippet)")
    }
    return "Results of the user's search on this iPhone (\(results.count) found; the full list is on the phone screen):\n"
      + lines.joined(separator: "\n")
      + "\nTell the user the most relevant one or two in one or two short sentences; mention that the rest are on the screen."
  }
}

private extension String {
  func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}

/// The search screen: the same engine as voice.
struct GlobalSearchView: View {
  let initialText: String
  @State private var text = ""
  @State private var kind: SearchResult.Kind?
  @State private var results: [SearchResult] = []
  @State private var seeded = false

  init(initialText: String = "") {
    self.initialText = initialText
  }

  var body: some View {
    List {
      Section {
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 8) {
            filterChip(nil, L.t("All", "Tümü"), "square.grid.2x2")
            ForEach(SearchResult.Kind.allCases) { filterChip($0, $0.title, $0.systemImage) }
          }
          .padding(.vertical, 4)
        }
        .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
      }
      if results.isEmpty {
        Section {
          Text(text.trimmingCharacters(in: .whitespaces).isEmpty
            ? L.t("Search notes, tasks, memories, vehicles, photos and more. Or say “geçen hafta Corolla ile ilgili kaydettiğim şeyi bul”.",
                  "Notlarda, görevlerde, hafızada, araçlarda, fotoğraflarda ve fazlasında ara. Ya da “geçen hafta Corolla ile ilgili kaydettiğim şeyi bul” de.")
            : L.t("Nothing found on this iPhone.", "Bu iPhone'da bir şey bulunamadı."))
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
      } else {
        Section(L.t("\(results.count) results", "\(results.count) sonuç")) {
          ForEach(results) { result in
            HStack(alignment: .top, spacing: 12) {
              Image(systemName: result.kind.systemImage)
                .frame(width: 22)
                .foregroundStyle(AutoLoomTheme.electricBlue)
              VStack(alignment: .leading, spacing: 3) {
                Text(result.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                if !result.snippet.isEmpty {
                  Text(result.snippet).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                }
                if let date = result.date {
                  Text(date.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.tertiary)
                }
              }
            }
            .padding(.vertical, 2)
          }
        }
      }
    }
    .searchable(text: $text, prompt: L.t("Search AutoLoom", "AutoLoom'da ara"))
    .navigationTitle(L.t("Search", "Ara"))
    .onAppear {
      if !seeded {
        seeded = true
        text = initialText
      }
      refresh()
    }
    .onChange(of: text) { _, _ in refresh() }
    .onChange(of: kind) { _, _ in refresh() }
    // Spotlight's semantic matches (iOS 18+), merged in after the local ones.
    .task(id: "\(text)|\(kind?.rawValue ?? "")") {
      try? await Task.sleep(nanoseconds: 350_000_000)
      guard !Task.isCancelled else { return }
      var query = GlobalSearch.parse(text)
      if let kind { query.kinds = [kind] }
      let merged = await GlobalSearch.runWithSpotlight(query)
      if !Task.isCancelled, merged.count > results.count { results = merged }
    }
  }

  private func filterChip(_ value: SearchResult.Kind?, _ title: String, _ icon: String) -> some View {
    Button {
      kind = value
    } label: {
      Label(title, systemImage: icon)
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(kind == value ? AutoLoomTheme.electricBlue.opacity(0.25) : Color.secondary.opacity(0.12), in: Capsule())
    }
    .buttonStyle(.plain)
  }

  private func refresh() {
    var query = GlobalSearch.parse(text)
    if let kind { query.kinds = [kind] }
    results = GlobalSearch.run(query)
  }
}
