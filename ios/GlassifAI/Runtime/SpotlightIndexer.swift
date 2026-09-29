import CoreSpotlight
import Foundation
import UniformTypeIdentifiers

/// AutoLoom notes, tasks and vehicles in iOS Spotlight, on this iPhone only.
/// The index uses complete file protection (nothing is readable while the
/// phone is locked). Memories are left out unless turned on, because they can
/// hold codes and personal details; vehicles show only the VIN's last six
/// characters. Settings → Privacy → Spotlight.
@MainActor
final class SpotlightIndexer {
  static let shared = SpotlightIndexer()

  static let enabledKey = "autoloom.spotlight.enabled"
  static let memoriesKey = "autoloom.spotlight.memories"

  static var isEnabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
  static var includesMemories: Bool { UserDefaults.standard.bool(forKey: memoriesKey) }

  private lazy var index = CSSearchableIndex(name: "AutoLoom", protectionClass: .complete)
  private var pending: Task<Void, Never>?
  private(set) var lastCount = 0
  private(set) var lastIndexed: Date?

  /// Coalesces bursts of changes into one reindex a moment later.
  func scheduleReindex(after delay: TimeInterval = 2) {
    guard !AppRuntime.isUnitTestHost, CSSearchableIndex.isIndexingAvailable() else { return }
    pending?.cancel()
    pending = Task { [weak self] in
      try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
      guard !Task.isCancelled else { return }
      await self?.reindexAll()
    }
  }

  func reindexAll() async {
    let items = Self.isEnabled ? Self.items() : []
    do {
      try await index.deleteAllSearchableItems()
      if !items.isEmpty { try await index.indexSearchableItems(items) }
      lastCount = items.count
      lastIndexed = Date()
    } catch {
      NSLog("[AutoLoom] Spotlight indexing failed: %@", String(describing: type(of: error)))
    }
  }

  func removeAll() async {
    try? await index.deleteAllSearchableItems()
    lastCount = 0
  }

  // MARK: Items

  static func items() -> [CSSearchableItem] {
    var items: [CSSearchableItem] = []
    let memory = MemoryStore.shared
    for note in memory.notes.prefix(500) {
      items.append(item("note", note.id, title: note.title, text: note.content, date: note.createdAt, keywords: note.tags))
    }
    for task in memory.tasks.filter({ !$0.completed }).prefix(300) {
      items.append(item("task", task.id, title: task.title, text: task.notes, date: task.createdAt, keywords: ["görev", "task"]))
    }
    for vehicle in DealerStore.shared.vehicles.prefix(200) {
      let facts = [
        vehicle.maskedVIN.map { "VIN \($0)" }, vehicle.stockNumber.map { "Stok \($0)" }, vehicle.color,
        vehicle.odometer?.text, vehicle.damage.isEmpty ? nil : vehicle.damage.map(\.text).joined(separator: "; "),
      ].compactMap { $0 }.joined(separator: " · ")
      items.append(item(
        "vehicle", vehicle.id, title: vehicle.title, text: facts, date: vehicle.createdAt,
        keywords: [vehicle.make, vehicle.model, vehicle.stockNumber].compactMap { $0 } + ["araç", "vehicle"]))
    }
    if includesMemories, memory.isEnabled {
      for record in memory.memories where record.kind != .conversationSummary {
        items.append(item("memory", record.id, title: record.title, text: record.text, date: record.createdAt))
      }
    }
    return items
  }

  static func item(
    _ domain: String,
    _ id: UUID,
    title: String,
    text: String,
    date: Date,
    keywords: [String] = []
  ) -> CSSearchableItem {
    let attributes = CSSearchableItemAttributeSet(contentType: UTType.text)
    attributes.title = title
    attributes.contentDescription = String(text.prefix(300))
    attributes.textContent = String(text.prefix(2_000))
    attributes.keywords = keywords + ["AutoLoom"]
    attributes.contentCreationDate = date
    let item = CSSearchableItem(uniqueIdentifier: "\(domain):\(id.uuidString)", domainIdentifier: domain, attributeSet: attributes)
    item.expirationDate = .distantFuture
    return item
  }

  /// "note:<uuid>" → ("note", uuid).
  nonisolated static func parse(_ identifier: String) -> (domain: String, id: UUID)? {
    let parts = identifier.split(separator: ":", maxSplits: 1).map(String.init)
    guard parts.count == 2, let id = UUID(uuidString: parts[1]) else { return nil }
    return (parts[0], id)
  }

  nonisolated static func kind(forDomain domain: String) -> SearchResult.Kind? {
    switch domain {
    case "note": .note
    case "task": .task
    case "vehicle": .vehicle
    case "memory": .memory
    default: nil
    }
  }

  /// A tap on an AutoLoom result in iOS Spotlight: the search screen on it.
  func open(identifier: String) {
    guard let (domain, id) = Self.parse(identifier) else { return }
    var title: String?
    switch domain {
    case "note": title = MemoryStore.shared.notes.first { $0.id == id }?.title
    case "task": title = MemoryStore.shared.tasks.first { $0.id == id }?.title
    case "vehicle": title = DealerStore.shared.vehicle(id)?.title
    case "memory": title = MemoryStore.shared.memories.first { $0.id == id }?.title
    default: break
    }
    guard let title else { return }
    AppNavigator.shared.show(.search(title))
  }
}

extension GlobalSearch {
  /// Spotlight's semantic matches among AutoLoom's own items (iOS 18+,
  /// on device), mapped back to search results. Best effort: empty when
  /// unavailable.
  static func spotlightMatches(_ text: String, limit: Int = 12, timeout: TimeInterval = 2) async -> [SearchResult] {
    guard SpotlightIndexer.isEnabled, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
    guard #available(iOS 18.0, *) else { return [] }
    // Best effort: a semantic query that does not answer in time is dropped.
    return await withTaskGroup(of: [SearchResult]?.self) { group in
      group.addTask { await Self.collectSpotlight(text, limit: limit) }
      group.addTask {
        try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
        return nil
      }
      let first = await group.next() ?? nil
      group.cancelAll()
      return first ?? []
    }
  }

  @available(iOS 18.0, *)
  nonisolated static func collectSpotlight(_ text: String, limit: Int) async -> [SearchResult] {
    let context = CSUserQueryContext()
    context.fetchAttributes = ["title", "contentDescription", "contentCreationDate"]
    context.maxResultCount = limit
    let query = CSUserQuery(userQueryString: text, userQueryContext: context)
    var results: [SearchResult] = []
    do {
      for try await response in query.responses {
        guard case .item(let found) = response else { continue }
        let item = found.item
        guard let (domain, id) = SpotlightIndexer.parse(item.uniqueIdentifier),
              let kind = SpotlightIndexer.kind(forDomain: domain) else { continue }
        results.append(SearchResult(
          id: "\(kind.rawValue):\(id.uuidString)", kind: kind, title: item.attributeSet.title ?? "",
          snippet: item.attributeSet.contentDescription ?? "", date: item.attributeSet.contentCreationDate, score: 0.55))
        if results.count >= limit { break }
      }
    } catch {
      return results
    }
    return results
  }

  /// The local results plus Spotlight's semantic matches not already found.
  static func runWithSpotlight(_ query: Query, limit: Int = 20) async -> [SearchResult] {
    var results = run(query, limit: limit)
    let known = Set(results.map(\.id))
    let extra = await spotlightMatches(query.text).filter { !known.contains($0.id) }
    results.append(contentsOf: extra.filter { query.kinds?.contains($0.kind) ?? true })
    return Array(results.prefix(limit))
  }
}
