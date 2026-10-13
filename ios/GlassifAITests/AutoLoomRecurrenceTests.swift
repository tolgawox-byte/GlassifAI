import EventKit
import Foundation
import XCTest

@testable import GlassifAI

/// Plan 2.3: repeats said by voice ("her gün", "her pazartesi", "her ayın
/// 15'inde") for reminders, events and AutoLoom tasks; the next task added
/// when one is completed; undoing a completion. Apple Reminders and the
/// lock-screen alerts themselves are device tests TK2 and RM5.
@MainActor
final class AutoLoomRecurrenceTests: XCTestCase {
  private let calendar = Calendar.current

  private func local(_ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
    calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
  }

  /// Sunday 27 September 2026, 20:00 local time.
  private var now: Date { local(9, 27, 20) }

  private func parse(_ text: String) -> ParsedTime? {
    TimePhraseParser.parse(text, now: now, calendar: calendar)
  }

  // MARK: Reading the repeat

  func testRepeatsAreReadFromTheUsersWords() throws {
    let daily = try XCTUnwrap(parse("her gün saat 9'da"))
    XCTAssertEqual(daily.recurrence, .daily)
    XCTAssertEqual(daily.date, local(9, 28, 9), "the next nine o'clock")
    XCTAssertEqual(try XCTUnwrap(parse("every day at 9 am")).recurrence, .daily)
    XCTAssertEqual(try XCTUnwrap(parse("hafta içi her gün 8'de")).recurrence, .weekdays)
    let fridayEvening = local(10, 2, 20)
    let weekdays = try XCTUnwrap(TimePhraseParser.parse("hafta içi her gün 9'da", now: fridayEvening, calendar: calendar))
    XCTAssertEqual(weekdays.date, local(10, 5, 9), "said on a Friday evening: Monday, not Saturday")
    let monday = try XCTUnwrap(parse("her pazartesi 10'da"))
    XCTAssertEqual(monday.recurrence, .weekly)
    XCTAssertEqual(monday.date, local(9, 28, 10), "Monday the 28th")
    let fridays = try XCTUnwrap(parse("cumaları 17:00'de"))
    XCTAssertEqual(fridays.recurrence, .weekly)
    XCTAssertEqual(calendar.component(.weekday, from: fridays.date), 6)
    let monthly = try XCTUnwrap(parse("her ayın 15'inde"))
    XCTAssertEqual(monthly.recurrence, .monthly)
    XCTAssertEqual(monthly.date, local(10, 15, 0), "the 15th has passed this month: October")
    XCTAssertFalse(monthly.hasTime)
    XCTAssertEqual(try XCTUnwrap(parse("her yıl 15 Ekim'de")).recurrence, .yearly)
    let morning = try XCTUnwrap(parse("her sabah"))
    XCTAssertEqual(morning.recurrence, .daily)
    XCTAssertEqual(morning.date, local(9, 28, 9), "\"sabah\" is still read as the time")
    let alone = try XCTUnwrap(parse("her gün"))
    XCTAssertEqual(alone.recurrence, .daily)
    XCTAssertFalse(alone.hasTime, "no time was said")
  }

  func testWordsThatOnlyLookLikeRepeatsAreNotRepeats() {
    XCTAssertNil(parse("yarın 9'da")?.recurrence)
    XCTAssertNil(parse("haftalık toplantı yarın 10'da")?.recurrence, "\"haftalık\" is part of the title")
    XCTAssertNotEqual(parse("bu hafta içi cuma 3'te")?.recurrence, .weekdays, "\"bu hafta içi\" is this week")
    XCTAssertNil(parse("yarın pazarları gezmeyi")?.recurrence, "\"pazarları\" is also \"the markets\"")
    XCTAssertTrue(Recurrence.unsupported(in: "her saat başı su iç"))
    XCTAssertTrue(Recurrence.unsupported(in: "iki günde bir çiçekleri sula"))
    XCTAssertTrue(Recurrence.unsupported(in: "every other day"))
    XCTAssertNil(parse("her hafta sonu 10'da")?.recurrence, "every weekend is not \"every week\"")
    XCTAssertTrue(Recurrence.unsupported(in: "her hafta sonu 10'da"))
    XCTAssertFalse(Recurrence.unsupported(in: "her gün su iç"))
    XCTAssertFalse(AssistantOrchestrator.unsupportedRepeatNote("her saat başı su iç").isEmpty)
    XCTAssertTrue(AssistantOrchestrator.unsupportedRepeatNote("her gün su iç").isEmpty)
  }

  func testTheTitleLosesTheRepeatWords() throws {
    var context = VoiceBridgeContext()
    context.assistantName = "Jarvis"
    guard case .createReminder(let title, let time)? = VoiceActionIntentBridge.decide(
      "Her gün 9'da ilacımı içmeyi hatırlat", context: context, now: now)?.intent else {
      return XCTFail("expected a reminder")
    }
    XCTAssertEqual(title, "İlacımı iç")
    XCTAssertEqual(time?.recurrence, .daily)
    guard case .createTask(let task, let due)? = VoiceActionIntentBridge.decide(
      "Her pazartesi 10'da rapor hazırla diye görev oluştur", context: context, now: now)?.intent else {
      return XCTFail("expected a task")
    }
    XCTAssertEqual(task, "Rapor hazırla")
    XCTAssertEqual(due?.recurrence, .weekly)
  }

  // MARK: The next occurrence

  func testTheNextOccurrenceKeepsTheTimeAndTheDay() {
    let monday = local(9, 28, 9)
    XCTAssertEqual(Recurrence.daily.next(after: monday, anchor: monday), local(9, 29, 9))
    XCTAssertEqual(Recurrence.weekly.next(after: monday, anchor: monday), local(10, 5, 9))
    let friday = local(10, 2, 9)
    XCTAssertEqual(Recurrence.weekdays.next(after: friday, anchor: monday), local(10, 5, 9), "Friday → Monday")
    let january = calendar.date(from: DateComponents(year: 2027, month: 1, day: 31, hour: 9))!
    let february = Recurrence.monthly.next(after: january, anchor: january)
    XCTAssertEqual(calendar.component(.day, from: february), 28)
    let march = Recurrence.monthly.next(after: february, anchor: january)
    XCTAssertEqual(calendar.component(.day, from: march), 31, "counted from the 31st, not from the 28th")
    XCTAssertEqual(Recurrence.yearly.next(after: monday, anchor: monday), calendar.date(byAdding: .year, value: 1, to: monday))
    XCTAssertEqual(Recurrence.daily.eventKitRule.frequency, .daily)
    XCTAssertEqual(Recurrence.weekdays.eventKitRule.daysOfTheWeek?.count, 5)
  }

  // MARK: Repeating AutoLoom tasks

  func testCompletingARepeatingTaskAddsTheNextAndUndoTakesItBack() throws {
    let suite = "autoloom.tests.recurrence.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = MemoryStore(inMemory: true, defaults: defaults)
    let due = Date().addingTimeInterval(3_600)
    let task = try XCTUnwrap(store.addTask(title: "İlaç iç", dueAt: due, dueHasTime: true, source: "test"))
    store.setRecurrence(.daily, for: task)
    XCTAssertEqual(store.recurrence(of: task), .daily)

    store.setCompleted(task, true)
    let next = try XCTUnwrap(store.nextOccurrence(of: task), "the next one is added")
    XCTAssertEqual(next.title, "İlaç iç")
    XCTAssertFalse(next.completed)
    XCTAssertEqual(next.dueAt, calendar.date(byAdding: .day, value: 1, to: due))
    XCTAssertEqual(store.recurrence(of: next), .daily, "the repeat moved to it")
    XCTAssertNil(store.recurrence(of: task))
    XCTAssertEqual(
      TaskRecurrenceStore(defaults: defaults).entry(for: next.id)?.recurrence, .daily, "kept across launches")

    store.setCompleted(task, false)
    XCTAssertNil(store.task(id: next.id), "undoing the completion takes the added one back")
    XCTAssertEqual(store.recurrence(of: task), .daily)

    store.deleteTask(task)
    XCTAssertNil(TaskRecurrenceStore(defaults: defaults).entry(for: task.id), "a deleted task leaves no repeat behind")
  }

  func testAOneOffTaskAddsNothingWhenCompleted() throws {
    let suite = "autoloom.tests.recurrence.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = MemoryStore(inMemory: true, defaults: defaults)
    let task = try XCTUnwrap(store.addTask(title: "Lastik", dueAt: Date().addingTimeInterval(3_600), source: "test"))
    let undated = try XCTUnwrap(store.addTask(title: "Tarihsiz", source: "test"))
    store.setRecurrence(.weekly, for: undated)
    XCTAssertNil(store.recurrence(of: undated), "no repeat without a due date")
    store.setCompleted(task, true)
    XCTAssertNil(store.nextOccurrence(of: task))
    XCTAssertEqual(store.tasks.filter { !$0.completed }.count, 1, "only the undated task is open")
  }

  func testASpokenTaskCompletionCanBeUndone() async throws {
    let orchestrator = AssistantOrchestrator.shared
    let store = MemoryStore.shared
    let marker = "tekrar\(UUID().uuidString.prefix(6).lowercased())"
    let task = try XCTUnwrap(store.addTask(title: "Kontrol \(marker)", source: "test"))
    defer { if let left = store.task(id: task.id) { store.deleteTask(left) } }
    LocalUndo.shared.clear()
    let outcome = await orchestrator.runVoiceIntent(
      VoiceBridgeDecision(.completeTask(marker), "test"), transcript: "\(marker) görevini tamamla")
    XCTAssertNil(outcome.failed, outcome.spoken)
    XCTAssertEqual(store.task(id: task.id)?.completed, true)
    let undone = try XCTUnwrap(LocalUndo.shared.popAndRun(), "\"geri al\" has something to undo")
    XCTAssertEqual(undone.kind, "task")
    XCTAssertEqual(store.task(id: task.id)?.completed, false, "the task is open again")
  }

  func testPlansSayThatTheyRepeat() {
    var plan = DeviceActionPlan(kind: .createReminder)
    plan.title = "İlacımı iç"
    plan.date = local(9, 28, 9)
    plan.recurrence = .daily
    XCTAssertTrue(plan.summary.contains(Recurrence.daily.label), plan.summary)
  }
}
