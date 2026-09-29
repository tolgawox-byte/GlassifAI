import Foundation

/// Undo for the app's own local actions ("Son yaptığını geri al"): a note,
/// a task, a memory, a shopping-list addition, a timer, a vehicle reading.
/// Calls, messages, shares and anything outside the app are never undone
/// (they are not recorded here). Entries expire after ten minutes.
@MainActor
final class LocalUndo {
  static let shared = LocalUndo()

  struct Entry {
    let kind: String
    let english: String
    let turkish: String
    let at: Date
    let undo: @MainActor () -> Bool
  }

  static let lifetime: TimeInterval = 600
  private(set) var entries: [Entry] = []

  func record(kind: String, english: String, turkish: String, undo: @escaping @MainActor () -> Bool) {
    entries.append(Entry(kind: kind, english: english, turkish: turkish, at: Date(), undo: undo))
    if entries.count > 10 { entries.removeFirst(entries.count - 10) }
  }

  /// Undoes the newest action that can still be undone.
  func popAndRun(now: Date = Date()) -> Entry? {
    entries.removeAll { now.timeIntervalSince($0.at) > Self.lifetime }
    while let entry = entries.popLast() {
      if entry.undo() { return entry }
    }
    return nil
  }

  func clear() { entries.removeAll() }
}
