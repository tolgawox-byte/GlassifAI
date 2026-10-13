import EventKit
import Foundation

/// How a reminder, an event or an AutoLoom task repeats (plan 2.3): "her
/// gün", "hafta içi her gün", "her pazartesi", "her ayın 15'inde", "her
/// yıl", "every day". The time of day stays the same.
enum Recurrence: String, Codable, Equatable, CaseIterable, Identifiable {
  case daily, weekdays, weekly, monthly, yearly

  var id: String { rawValue }

  var label: String {
    switch self {
    case .daily: L.t("Every day", "Her gün")
    case .weekdays: L.t("Every weekday", "Hafta içi her gün")
    case .weekly: L.t("Every week", "Her hafta")
    case .monthly: L.t("Every month", "Her ay")
    case .yearly: L.t("Every year", "Her yıl")
    }
  }

  /// For the voice model.
  var english: String {
    switch self {
    case .daily: "every day"
    case .weekdays: "every weekday (Monday to Friday)"
    case .weekly: "every week"
    case .monthly: "every month"
    case .yearly: "every year"
    }
  }

  /// The first occurrence after `date`. Counted from `anchor` (the first
  /// due date), so "the 31st" comes back as the 31st after a shorter month.
  func next(after date: Date, anchor: Date, calendar: Calendar = .current) -> Date {
    let unit: Calendar.Component
    let step: Int
    switch self {
    case .weekdays:
      var next = calendar.date(byAdding: .day, value: 1, to: date) ?? date.addingTimeInterval(86_400)
      // Saturday is 7 and Sunday 1 in every Gregorian calendar.
      while [1, 7].contains(calendar.component(.weekday, from: next)) {
        next = calendar.date(byAdding: .day, value: 1, to: next) ?? next.addingTimeInterval(86_400)
      }
      return next
    case .daily:
      unit = .day
      step = 1
    case .weekly:
      unit = .day
      step = 7
    case .monthly:
      unit = .month
      step = 1
    case .yearly:
      unit = .year
      step = 1
    }
    let elapsed = calendar.dateComponents([unit], from: anchor, to: date).value(for: unit) ?? 0
    let first = max(1, elapsed / step)
    for count in first...(first + 3) {
      if let candidate = calendar.date(byAdding: unit, value: count * step, to: anchor), candidate > date {
        return candidate
      }
    }
    return calendar.date(byAdding: unit, value: step, to: date) ?? date.addingTimeInterval(86_400)
  }

  /// The same repeat for Apple Reminders and Calendar.
  var eventKitRule: EKRecurrenceRule {
    switch self {
    case .daily:
      return EKRecurrenceRule(recurrenceWith: .daily, interval: 1, end: nil)
    case .weekdays:
      let days: [EKWeekday] = [.monday, .tuesday, .wednesday, .thursday, .friday]
      return EKRecurrenceRule(
        recurrenceWith: .weekly, interval: 1, daysOfTheWeek: days.map { EKRecurrenceDayOfWeek($0) },
        daysOfTheMonth: nil, monthsOfTheYear: nil, weeksOfTheYear: nil, daysOfTheYear: nil, setPositions: nil, end: nil)
    case .weekly:
      return EKRecurrenceRule(recurrenceWith: .weekly, interval: 1, end: nil)
    case .monthly:
      return EKRecurrenceRule(recurrenceWith: .monthly, interval: 1, end: nil)
    case .yearly:
      return EKRecurrenceRule(recurrenceWith: .yearly, interval: 1, end: nil)
    }
  }

  /// Repeats the app cannot set ("her saat", "iki günde bir", "every other
  /// day"): said honestly instead of being saved as something else.
  static func unsupported(in text: String) -> Bool {
    let normalized = " " + TimePhraseParser.normalize(text) + " "
    let pattern = #"\b(her saat|saatte bir|her \d+ |\d+ (gunde|haftada|ayda|yilda) bir|(iki|uc|dort|bes|alti) (gunde|haftada|ayda|yilda) bir|gun asiri|her hafta sonu|hafta sonlari|every weekend|on weekends|every other|every hour|hourly|every \d+|every (two|three|four|five|six) )"#
    return normalized.range(of: pattern, options: .regularExpression) != nil
  }
}

/// Which AutoLoom tasks repeat (plan 2.3). Kept in the app's settings beside
/// the SwiftData store, so the store already on the user's iPhone needs no
/// schema migration; an entry whose task is gone is ignored.
@MainActor
final class TaskRecurrenceStore {
  struct Entry: Codable, Equatable {
    var recurrence: Recurrence
    /// The first due date; later ones are counted from it.
    var anchor: Date
  }

  private struct Saved: Codable {
    var entries: [UUID: Entry] = [:]
    /// A completed task → the task its completion created, so undoing the
    /// completion can take that one back.
    var successors: [UUID: UUID] = [:]
  }

  nonisolated static let defaultsKey = "autoloom.tasks.recurrence"
  private let defaults: UserDefaults
  private var saved: Saved

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    saved = defaults.data(forKey: Self.defaultsKey).flatMap { try? JSONDecoder().decode(Saved.self, from: $0) } ?? Saved()
  }

  func entry(for id: UUID) -> Entry? { saved.entries[id] }

  /// `anchor` is the task's due date now; the occurrences after it are
  /// counted from it.
  func set(_ recurrence: Recurrence?, for id: UUID, anchor: Date) {
    saved.entries[id] = recurrence.map { Entry(recurrence: $0, anchor: anchor) }
    persist()
  }

  /// The repeat moves to the task created when `old` was completed.
  func handOver(from old: UUID, to new: UUID) {
    guard let entry = saved.entries.removeValue(forKey: old) else { return }
    saved.entries[new] = entry
    saved.successors[old] = new
    persist()
  }

  /// The task created when `id` was completed, while it is recorded.
  func successor(of id: UUID) -> UUID? { saved.successors[id] }

  /// Undoing that completion: the repeat goes back to the earlier task.
  func handBack(from new: UUID, to old: UUID) {
    if let entry = saved.entries.removeValue(forKey: new) { saved.entries[old] = entry }
    saved.successors[old] = nil
    persist()
  }

  func remove(_ id: UUID) {
    saved.entries[id] = nil
    saved.successors[id] = nil
    saved.successors = saved.successors.filter { $0.value != id }
    persist()
  }

  func removeAll() {
    saved = Saved()
    defaults.removeObject(forKey: Self.defaultsKey)
  }

  private func persist() {
    if let data = try? JSONEncoder().encode(saved) { defaults.set(data, forKey: Self.defaultsKey) }
  }
}
