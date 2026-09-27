import Foundation

/// In-memory context for the current conversation. The realtime voice model
/// keeps its own conversation state; this copy exists so delegated tasks
/// (vision, web, reasoning) understand follow-ups such as "the cheaper one",
/// and so a reconnect can resume with a summary. Nothing here is persisted.
@MainActor
final class ConversationContext: ObservableObject {
  struct Turn: Equatable {
    enum Role: String { case user, assistant }
    let role: Role
    let text: String
    let at: Date
  }

  struct Fact: Equatable {
    let kind: AssistantTaskKind
    let request: String
    let result: String
    let sources: [String]
    let at: Date
  }

  @Published private(set) var turns: [Turn] = []
  @Published private(set) var facts: [Fact] = []
  @Published private(set) var summary = ""
  @Published private(set) var detectedLanguage: String?

  private let recentTurnLimit = 14
  private let factLimit = 8
  private let summaryCharacterLimit = 1_600

  func addTurn(_ role: Turn.Role, _ text: String) {
    let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleaned.isEmpty else { return }
    if let last = turns.last, last.role == role, last.text == cleaned { return }
    turns.append(Turn(role: role, text: String(cleaned.prefix(1_200)), at: Date()))
    if role == .user { detectedLanguage = Self.guessLanguage(cleaned) ?? detectedLanguage }
    compactIfNeeded()
  }

  func addFact(kind: AssistantTaskKind, request: String, result: String, sources: [String]) {
    facts.append(Fact(
      kind: kind,
      request: String(request.prefix(300)),
      result: String(result.prefix(700)),
      sources: Array(sources.prefix(5)),
      at: Date()))
    if facts.count > factLimit { facts.removeFirst(facts.count - factLimit) }
  }

  func reset() {
    turns.removeAll()
    facts.removeAll()
    summary = ""
    detectedLanguage = nil
  }

  /// Folds older turns into a bounded running summary. Extractive and local:
  /// no extra model call, so it never adds latency or cost.
  private func compactIfNeeded() {
    guard turns.count > recentTurnLimit else { return }
    let overflow = turns.prefix(turns.count - recentTurnLimit)
    turns.removeFirst(overflow.count)
    let folded = overflow.map { "\($0.role == .user ? "User" : "Assistant"): \($0.text.prefix(160))" }
    var combined = summary.isEmpty ? folded.joined(separator: "\n") : summary + "\n" + folded.joined(separator: "\n")
    if combined.count > summaryCharacterLimit {
      combined = "…" + String(combined.suffix(summaryCharacterLimit))
    }
    summary = combined
  }

  /// Context block handed to delegated tasks. Earlier task results that came
  /// from the web or the camera are wrapped as untrusted content.
  func promptContext(memory: [String]) -> String {
    var sections: [String] = []
    if !summary.isEmpty {
      sections.append("Earlier in this conversation (condensed):\n\(summary)")
    }
    if !turns.isEmpty {
      let recent = turns.suffix(recentTurnLimit)
        .map { "\($0.role == .user ? "User" : "Assistant"): \($0.text)" }
        .joined(separator: "\n")
      sections.append("Recent conversation (oldest first):\n\(recent)")
    }
    if !facts.isEmpty {
      let results = facts.map { fact in
        let sources = fact.sources.isEmpty ? "" : " (sources: \(fact.sources.joined(separator: ", ")))"
        return "- [\(fact.kind.displayName)] \(fact.request) → \(fact.result)\(sources)"
      }.joined(separator: "\n")
      sections.append(
        "Results of earlier tasks in this conversation:\n" +
        UntrustedContent.wrap(results, origin: "earlier task results"))
    }
    if !memory.isEmpty {
      sections.append(
        "Things the user explicitly asked this app to remember:\n" +
        memory.map { "- \($0)" }.joined(separator: "\n"))
    }
    return sections.joined(separator: "\n\n")
  }

  /// Short text used to seed a new voice session after a reconnect.
  func resumeSummary() -> String? {
    guard !turns.isEmpty || !summary.isEmpty else { return nil }
    let recent = turns.suffix(6)
      .map { "\($0.role == .user ? "User" : "Assistant"): \($0.text.prefix(200))" }
      .joined(separator: "\n")
    let text = [summary.isEmpty ? nil : String(summary.suffix(600)), recent.isEmpty ? nil : recent]
      .compactMap { $0 }
      .joined(separator: "\n")
    return "The voice connection was re-established. Conversation so far:\n" + text
  }

  /// Very small heuristic used only as a hint for response language.
  static func guessLanguage(_ text: String) -> String? {
    let lower = text.lowercased()
    if lower.contains(where: { "çğışöü".contains($0) }) { return "Turkish" }
    let turkishWords = [" bu ", " ne ", " bir ", " ve ", " mi ", " nasıl", "bugün", "şu ", "lütfen", "merhaba"]
    let padded = " \(lower) "
    if turkishWords.contains(where: { padded.contains($0) }) { return "Turkish" }
    if lower.range(of: "[a-z]", options: .regularExpression) != nil { return "English" }
    return nil
  }
}

/// Opt-in, on-device memory the user controls completely. Stored as a small
/// JSON file with complete file protection; never synced, never sent anywhere
/// except as context in the user's own ChatGPT requests while enabled.
@MainActor
final class LocalMemoryStore: ObservableObject {
  struct Item: Identifiable, Codable, Equatable {
    let id: UUID
    var text: String
    let createdAt: Date
    var source: String
  }

  static let shared = LocalMemoryStore()
  static let enabledKey = "autoloom.memory.enabled"

  @Published private(set) var items: [Item] = []
  @Published var isEnabled: Bool {
    didSet { UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey) }
  }

  private let maxItems = 50
  private let maxItemLength = 300

  private init() {
    isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
    items = (try? load()) ?? []
  }

  var promptItems: [String] {
    isEnabled ? items.map(\.text) : []
  }

  @discardableResult
  func add(_ text: String, source: String) -> Bool {
    let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard isEnabled, !cleaned.isEmpty else { return false }
    guard !items.contains(where: { $0.text.caseInsensitiveCompare(cleaned) == .orderedSame }) else { return true }
    items.append(Item(id: UUID(), text: String(cleaned.prefix(maxItemLength)), createdAt: Date(), source: source))
    if items.count > maxItems { items.removeFirst(items.count - maxItems) }
    persist()
    return true
  }

  func update(_ id: UUID, text: String) {
    let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let index = items.firstIndex(where: { $0.id == id }) else { return }
    if cleaned.isEmpty {
      items.remove(at: index)
    } else {
      items[index].text = String(cleaned.prefix(maxItemLength))
    }
    persist()
  }

  func delete(_ id: UUID) {
    items.removeAll { $0.id == id }
    persist()
  }

  /// Removes items whose text contains the phrase; used by "forget …".
  @discardableResult
  func forget(matching phrase: String) -> Int {
    let needle = phrase.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !needle.isEmpty else { return 0 }
    let before = items.count
    items.removeAll { $0.text.lowercased().contains(needle) }
    persist()
    return before - items.count
  }

  func deleteAll() {
    items.removeAll()
    if let url = try? fileURL() {
      try? FileManager.default.removeItem(at: url)
    }
  }

  private func fileURL() throws -> URL {
    let directory = try FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
      .appending(path: "AutoLoom", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appending(path: "memory.json")
  }

  private func load() throws -> [Item] {
    let data = try Data(contentsOf: try fileURL())
    return try JSONDecoder().decode([Item].self, from: data)
  }

  private func persist() {
    do {
      let url = try fileURL()
      if items.isEmpty {
        try? FileManager.default.removeItem(at: url)
        return
      }
      let data = try JSONEncoder().encode(items)
      try data.write(to: url, options: [.atomic, .completeFileProtection])
    } catch {
      NSLog("[AutoLoom] memory save failed: %@", LogSanitizer.sanitize(error.localizedDescription))
    }
  }
}
