import EventKit
import Foundation
import UIKit

/// Native iPhone actions the assistant can prepare. Each has a risk level
/// that decides how it is confirmed:
/// - read-only: runs directly (after the iOS permission prompt);
/// - save: a spoken "yes" or a tap on Save;
/// - needs a tap: leaves the app or contacts someone, so only a tap on the
///   phone confirms it (a spoken "yes" is never enough).
enum DeviceActionKind: String, CaseIterable, Codable, Equatable {
  case createReminder = "create_reminder"
  case listReminders = "list_reminders"
  case todayEvents = "today_events"
  case upcomingEvents = "upcoming_events"
  case createEvent = "create_event"
  case saveNote = "save_note"
  case openMaps = "open_maps"
  case openURL = "open_url"
  case copyText = "copy_text"
  case shareText = "share_text"
  case call
  case message
  /// A request for the user's own OpenClaw agent (never chosen by the planner).
  case agentTask = "agent_task"
  case none

  enum Risk: Equatable {
    case readOnly
    case save
    case needsTap
  }

  var risk: Risk {
    switch self {
    case .listReminders, .todayEvents, .upcomingEvents, .copyText, .none: .readOnly
    case .createReminder, .createEvent, .saveNote, .agentTask: .save
    case .openMaps, .openURL, .shareText, .call, .message: .needsTap
    }
  }

  /// Kinds the action planner may choose.
  static var plannable: [DeviceActionKind] {
    allCases.filter { $0 != .agentTask }
  }

  var label: String {
    switch self {
    case .createReminder: "Reminder"
    case .listReminders: "Reminders"
    case .todayEvents: "Today's calendar"
    case .upcomingEvents: "Upcoming events"
    case .createEvent: "Calendar event"
    case .saveNote: "AutoLoom note"
    case .openMaps: "Directions"
    case .openURL: "Open link"
    case .copyText: "Copy"
    case .shareText: "Share"
    case .call: "Phone call"
    case .message: "Message"
    case .agentTask: "Your agent (OpenClaw)"
    case .none: "No action"
    }
  }

  var systemImage: String {
    switch self {
    case .createReminder, .listReminders: "checklist"
    case .todayEvents, .upcomingEvents, .createEvent: "calendar"
    case .saveNote: "note.text"
    case .openMaps: "map"
    case .openURL: "safari"
    case .copyText: "doc.on.doc"
    case .shareText: "square.and.arrow.up"
    case .call: "phone"
    case .message: "message"
    case .agentTask: "server.rack"
    case .none: "questionmark.circle"
    }
  }
}

/// A validated action ready to run or to confirm.
struct DeviceActionPlan: Equatable {
  var kind: DeviceActionKind
  var title: String?
  var notes: String?
  var date: Date?
  var endDate: Date?
  var location: String?
  var url: URL?
  var text: String?
  var recipient: String?
  var phone: String?
  /// The planner's short explanation (used for `none`).
  var reply: String = ""

  /// Agent requests that sound destructive (deleting, deploying, payments,
  /// email) need a tap, even though other agent requests accept a spoken yes.
  var risk: DeviceActionKind.Risk {
    if kind == .agentTask, ActionGuard.soundsDestructive(text ?? "") { return .needsTap }
    return kind.risk
  }

  /// One line for the confirmation card and the voice model.
  var summary: String {
    let when = date.map { $0.formatted(date: .abbreviated, time: .shortened) }
    switch kind {
    case .createReminder:
      return "Reminder \"\(title ?? "")\"" + (when.map { " at \($0)" } ?? " (no time)")
    case .createEvent:
      return "Event \"\(title ?? "")\" \(when ?? "")" + (location.map { " at \($0)" } ?? "")
    case .saveNote:
      return "Note \"\(title ?? String((text ?? "").prefix(40)))\""
    case .openMaps:
      return "Directions to \(location ?? "")"
    case .openURL:
      return "Open \(url?.host ?? url?.absoluteString ?? "")"
    case .copyText:
      return "Copy \"\((text ?? "").prefix(60))\""
    case .shareText:
      return "Share \"\((text ?? "").prefix(60))\""
    case .call:
      return "Call \(recipient ?? phone ?? "")" + (recipient != nil && phone != nil ? " (\(phone!))" : "")
    case .message:
      return "Message \(recipient ?? phone ?? "(choose recipient)"): \"\((text ?? "").prefix(80))\""
    case .agentTask:
      return "Ask your agent: \"\((text ?? "").prefix(120))\""
    case .listReminders, .todayEvents, .upcomingEvents, .none:
      return kind.label
    }
  }
}

/// Requests that are refused before any model call: email, money, deleting
/// data, code and deployment, public posting. The words cover English and
/// Turkish.
enum ActionGuard {
  /// Requests about reminders, notes or the calendar are planned even when
  /// they mention buying or email ("remind me to buy milk").
  private static let organizingTerms = [
    "remind", "reminder", "note", "calendar", "event", "meeting", "schedule",
    "hatırlat", "anımsat", "not al", "not et", "notu", "takvim", "etkinlik", "toplantı", "randevu",
  ]

  private static let repositoryAccess = "access to code repositories (not connected to this app)"

  private static let blocked: [(terms: [String], reason: String)] = [
    (["email", "e-mail", "e-posta", "eposta", "gmail", " mail "], "sending email"),
    ([" buy ", " purchase", "pay for", " payment", "transfer money", "wire money", "bank transfer",
      "satın al", "sipariş ver", "ödeme yap", "havale", "para gönder"], "purchases or payments"),
    ([" delete", " erase", " wipe", " sil ", "silmek", "temizle"], "deleting data"),
    (["github", "gitlab", "repository", " repo "], repositoryAccess),
    (["deploy", "git push", "push code", " commit ", " merge ", "production"],
     "code or deployment changes"),
    (["post on", "tweet", "publish", "instagram'a", "twitter'a"], "public posting"),
  ]

  /// For agent requests: whether the request sounds destructive or involves
  /// money, email or posting (reading a repository does not count).
  static func soundsDestructive(_ request: String) -> Bool {
    let text = " " + request.lowercased(with: Locale(identifier: "tr_TR")) + " "
    let english = " " + request.lowercased() + " "
    return blocked
      .filter { $0.reason != repositoryAccess }
      .contains { entry in entry.terms.contains { text.contains($0) || english.contains($0) } }
  }

  /// Why the request cannot be done here, or nil when it may be planned.
  static func blockedReason(for request: String) -> String? {
    let text = " " + request.lowercased(with: Locale(identifier: "tr_TR")) + " "
    let english = " " + request.lowercased() + " "
    func mentions(_ term: String) -> Bool { text.contains(term) || english.contains(term) }
    if organizingTerms.contains(where: mentions) { return nil }
    for entry in blocked where entry.terms.contains(where: mentions) {
      return entry.reason
    }
    return nil
  }

  static func declineText(reason: String) -> String {
    "This app cannot perform actions such as \(reason). It supports reminders, calendar, AutoLoom notes, maps, links, copy, share, and calls or messages that the user confirms on the phone. Tell the user honestly that this is not supported."
  }
}

/// Turns the planner model's JSON into a validated plan.
enum DeviceActionParser {
  static func parse(_ json: String, now: Date = Date()) -> Result<DeviceActionPlan, ActionPlanError> {
    guard let data = json.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return .failure(.invalid("The action could not be understood."))
    }
    func text(_ key: String, limit: Int = 500) -> String? {
      guard let value = (object[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
            !value.isEmpty else { return nil }
      return String(value.prefix(limit))
    }
    guard let kind = DeviceActionKind(rawValue: text("action") ?? "none"), kind != .agentTask else {
      return .failure(.invalid("That action is not supported."))
    }
    var plan = DeviceActionPlan(kind: kind)
    plan.title = text("title", limit: 200)
    plan.notes = text("notes", limit: 1_000)
    plan.location = text("location", limit: 200)
    plan.text = text("text", limit: 4_000)
    plan.recipient = text("recipient", limit: 100)
    plan.reply = text("reply", limit: 400) ?? ""
    if let when = text("when") {
      guard let date = parseDate(when) else { return .failure(.invalid("The time \"\(when)\" could not be understood.")) }
      plan.date = date
    }
    if let end = text("end") {
      guard let date = parseDate(end) else { return .failure(.invalid("The end time \"\(end)\" could not be understood.")) }
      plan.endDate = date
    }
    if let raw = text("url") {
      guard let url = URL(string: raw), URLSafety.isPublicWebURL(url) else {
        return .failure(.invalid("Only public web links can be opened."))
      }
      plan.url = url
    }
    if let raw = text("phone") {
      guard let phone = normalizedPhone(raw) else { return .failure(.invalid("\"\(raw)\" is not a phone number.")) }
      plan.phone = phone
    }
    return validate(plan, now: now)
  }

  static func validate(_ plan: DeviceActionPlan, now: Date) -> Result<DeviceActionPlan, ActionPlanError> {
    var plan = plan
    switch plan.kind {
    case .createReminder:
      guard plan.title != nil else { return .failure(.missing("what to be reminded about")) }
      if let date = plan.date, date < now.addingTimeInterval(-60) {
        return .failure(.invalid("That time is in the past."))
      }
    case .createEvent:
      guard plan.title != nil else { return .failure(.missing("the event title")) }
      guard let start = plan.date else { return .failure(.missing("when the event is")) }
      if start < now.addingTimeInterval(-60) { return .failure(.invalid("That time is in the past.")) }
      if let end = plan.endDate, end <= start { return .failure(.invalid("The event ends before it starts.")) }
      if plan.endDate == nil { plan.endDate = start.addingTimeInterval(3_600) }
    case .saveNote, .copyText, .shareText:
      guard plan.text != nil else { return .failure(.missing("the text")) }
    case .openMaps:
      guard plan.location != nil else { return .failure(.missing("the destination")) }
    case .openURL:
      guard plan.url != nil else { return .failure(.missing("the web address")) }
    case .call:
      guard plan.phone != nil else { return .failure(.missing("a phone number (contacts are not searched)")) }
    case .message:
      guard plan.text != nil else { return .failure(.missing("the message text")) }
    case .agentTask:
      guard plan.text != nil else { return .failure(.missing("what to ask your agent")) }
    case .listReminders, .todayEvents, .upcomingEvents, .none:
      break
    }
    return .success(plan)
  }

  /// ISO 8601 with offset, or local "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm",
  /// or "yyyy-MM-dd".
  static func parseDate(_ raw: String) -> Date? {
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime]
    if let date = iso.date(from: raw) { return date }
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = iso.date(from: raw) { return date }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .current
    for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
      formatter.dateFormat = format
      if let date = formatter.date(from: raw) { return date }
    }
    return nil
  }

  /// Digits with an optional leading +, 5 to 17 digits.
  static func normalizedPhone(_ raw: String) -> String? {
    let allowed = raw.filter { $0.isNumber || $0 == "+" }
    let digits = allowed.filter(\.isNumber)
    guard (5...17).contains(digits.count), !allowed.dropFirst().contains("+") else { return nil }
    return allowed
  }
}

enum ActionPlanError: Error, Equatable {
  case invalid(String)
  case missing(String)

  var speakable: String {
    switch self {
    case .invalid(let message): message
    case .missing(let what): "I need \(what) to do that."
    }
  }
}

/// A plan waiting for the user's confirmation.
struct PendingDeviceAction: Identifiable, Equatable {
  let id = UUID()
  let plan: DeviceActionPlan
  let createdAt = Date()

  /// Unconfirmed actions expire.
  static let lifetime: TimeInterval = 120

  var isExpired: Bool { Date().timeIntervalSince(createdAt) > Self.lifetime }
}

/// Runs actions with Apple frameworks. Nothing here sends anything anywhere:
/// reminders and events go to the user's own lists and calendars, notes stay
/// on the phone, and calls/messages open the system UI for the user to finish.
@MainActor
final class DeviceActionExecutor {
  static let shared = DeviceActionExecutor()
  private let store = EKEventStore()

  enum ExecutionError: LocalizedError {
    case permissionDenied(String)
    case needsForeground(String)
    case failed(String)

    var errorDescription: String? {
      switch self {
      case .permissionDenied(let what):
        "Access to \(what) is not allowed. The user can allow it in iOS Settings → Privacy → \(what.capitalized)."
      case .needsForeground(let what):
        "iOS can only ask for \(what) permission while the app is open on screen. Ask the user to open the app once."
      case .failed(let message): message
      }
    }
  }

  /// Read-only and save actions. `needsTap` actions are performed by the
  /// confirmation card itself.
  func run(_ plan: DeviceActionPlan) async throws -> String {
    switch plan.kind {
    case .createReminder: return try await createReminder(plan)
    case .listReminders: return try await listReminders()
    case .todayEvents: return try await events(from: Calendar.current.startOfDay(for: Date()), days: 1, label: "today")
    case .upcomingEvents: return try await events(from: Date(), days: 7, label: "in the next 7 days")
    case .createEvent: return try await createEvent(plan)
    case .saveNote:
      AutoLoomNotesStore.shared.add(title: plan.title, body: plan.text ?? "", source: "voice")
      return "Saved as an AutoLoom note on this iPhone (Settings → AutoLoom Tasks & Notes)."
    case .copyText:
      UIPasteboard.general.string = plan.text
      return "Copied to the clipboard."
    case .none:
      return plan.reply.isEmpty ? "No supported action was found for that request." : plan.reply
    case .openMaps, .openURL, .shareText, .call, .message:
      throw ExecutionError.failed("This action must be confirmed with a tap on the phone.")
    case .agentTask:
      throw ExecutionError.failed("Agent requests are sent by the assistant, not the device executor.")
    }
  }

  private var isForeground: Bool {
    UIApplication.shared.applicationState == .active
  }

  private func ensureReminderAccess() async throws {
    switch EKEventStore.authorizationStatus(for: .reminder) {
    case .fullAccess, .authorized: return
    case .notDetermined:
      guard isForeground else { throw ExecutionError.needsForeground("Reminders") }
      guard try await store.requestFullAccessToReminders() else { throw ExecutionError.permissionDenied("reminders") }
    default:
      throw ExecutionError.permissionDenied("reminders")
    }
  }

  private func ensureEventAccess(fullAccess: Bool) async throws {
    let status = EKEventStore.authorizationStatus(for: .event)
    switch status {
    case .fullAccess, .authorized: return
    case .writeOnly where !fullAccess: return
    case .notDetermined, .writeOnly:
      guard isForeground else { throw ExecutionError.needsForeground("Calendars") }
      let granted = fullAccess
        ? try await store.requestFullAccessToEvents()
        : try await store.requestWriteOnlyAccessToEvents()
      guard granted else { throw ExecutionError.permissionDenied("calendars") }
    default:
      throw ExecutionError.permissionDenied("calendars")
    }
  }

  private func createReminder(_ plan: DeviceActionPlan) async throws -> String {
    try await ensureReminderAccess()
    guard let calendar = store.defaultCalendarForNewReminders() else {
      throw ExecutionError.failed("There is no default Reminders list on this iPhone.")
    }
    let reminder = EKReminder(eventStore: store)
    reminder.title = plan.title
    reminder.notes = plan.notes
    reminder.calendar = calendar
    if let date = plan.date {
      reminder.dueDateComponents = Calendar.current.dateComponents(
        [.year, .month, .day, .hour, .minute], from: date)
      reminder.addAlarm(EKAlarm(absoluteDate: date))
    }
    try store.save(reminder, commit: true)
    let when = plan.date.map { " for \($0.formatted(date: .abbreviated, time: .shortened))" } ?? ""
    return "Reminder saved in \(calendar.title)\(when): \(plan.title ?? "")."
  }

  private func listReminders() async throws -> String {
    try await ensureReminderAccess()
    let predicate = store.predicateForIncompleteReminders(
      withDueDateStarting: nil, ending: Date().addingTimeInterval(7 * 86_400), calendars: nil)
    let reminders: [EKReminder] = await withCheckedContinuation { continuation in
      _ = store.fetchReminders(matching: predicate) { continuation.resume(returning: $0 ?? []) }
    }
    guard !reminders.isEmpty else { return "There are no open reminders due in the next 7 days." }
    let calendar = Calendar.current
    func dueDate(_ reminder: EKReminder) -> Date? {
      reminder.dueDateComponents.flatMap { calendar.date(from: $0) }
    }
    let lines = reminders
      .sorted { (dueDate($0) ?? .distantFuture) < (dueDate($1) ?? .distantFuture) }
      .prefix(8)
      .map { reminder -> String in
        let due = dueDate(reminder).map { " (\($0.formatted(date: .abbreviated, time: .shortened)))" } ?? ""
        return "- \(reminder.title ?? "Untitled")\(due)"
      }
    return "Open reminders:\n" + lines.joined(separator: "\n")
  }

  private func events(from start: Date, days: Int, label: String) async throws -> String {
    try await ensureEventAccess(fullAccess: true)
    let end = Calendar.current.date(byAdding: .day, value: days, to: start) ?? start.addingTimeInterval(Double(days) * 86_400)
    let events = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil))
      .sorted { $0.startDate < $1.startDate }
    guard !events.isEmpty else { return "There are no calendar events \(label)." }
    let lines = events.prefix(10).map { event -> String in
      let time = event.isAllDay ? "all day" : event.startDate.formatted(date: days > 1 ? .abbreviated : .omitted, time: .shortened)
      let place = event.location.map { " @ \($0)" } ?? ""
      return "- \(time): \(event.title ?? "Untitled")\(place)"
    }
    return "Calendar \(label):\n" + lines.joined(separator: "\n")
  }

  private func createEvent(_ plan: DeviceActionPlan) async throws -> String {
    try await ensureEventAccess(fullAccess: false)
    guard let start = plan.date, let calendar = store.defaultCalendarForNewEvents else {
      throw ExecutionError.failed("There is no default calendar on this iPhone.")
    }
    let event = EKEvent(eventStore: store)
    event.title = plan.title
    event.startDate = start
    event.endDate = plan.endDate ?? start.addingTimeInterval(3_600)
    event.location = plan.location
    event.notes = plan.notes
    event.calendar = calendar
    try store.save(event, span: .thisEvent, commit: true)
    return "Event saved in \(calendar.title): \(plan.title ?? "") on \(start.formatted(date: .abbreviated, time: .shortened))."
  }

  // MARK: Tap-confirmed actions (called from the confirmation card)

  static func mapsURL(for destination: String) -> URL? {
    var components = URLComponents(string: "https://maps.apple.com/")
    components?.queryItems = [
      URLQueryItem(name: "daddr", value: destination),
      URLQueryItem(name: "dirflg", value: "d"),
    ]
    return components?.url
  }

  static func callURL(for phone: String) -> URL? {
    URL(string: "tel:\(phone)")
  }

  static func messageURL(phone: String?, body: String?) -> URL? {
    var components = URLComponents()
    components.scheme = "sms"
    components.path = phone ?? ""
    if let body, !body.isEmpty {
      components.queryItems = [URLQueryItem(name: "body", value: body)]
    }
    return components.url
  }
}

/// On-device notes and saved reports ("create a note from this", "look this
/// up and save it"). Stored only on this iPhone with complete file
/// protection; Apple Notes has no public API, so notes are shared to it with
/// the share sheet.
@MainActor
final class AutoLoomNotesStore: ObservableObject {
  struct Note: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var body: String
    let createdAt: Date
    var source: String
    var sources: [String] = []
  }

  static let shared = AutoLoomNotesStore()
  @Published private(set) var notes: [Note] = []
  private let maxNotes = 200

  private init() {
    notes = (try? load()) ?? []
  }

  @discardableResult
  func add(title: String?, body: String, source: String, sources: [String] = []) -> Note {
    let cleanedBody = String(body.trimmingCharacters(in: .whitespacesAndNewlines).prefix(20_000))
    let cleanedTitle = (title?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
      ?? String(cleanedBody.prefix(50))
    let note = Note(
      id: UUID(), title: String(cleanedTitle.prefix(120)), body: cleanedBody, createdAt: Date(), source: source,
      sources: Array(sources.prefix(10)))
    notes.insert(note, at: 0)
    if notes.count > maxNotes { notes.removeLast(notes.count - maxNotes) }
    persist()
    return note
  }

  func delete(_ id: UUID) {
    notes.removeAll { $0.id == id }
    persist()
  }

  func deleteAll() {
    notes.removeAll()
    if let url = try? fileURL() { try? FileManager.default.removeItem(at: url) }
  }

  private func fileURL() throws -> URL {
    let directory = try FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
      .appending(path: "AutoLoom", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appending(path: "notes.json")
  }

  private func load() throws -> [Note] {
    try JSONDecoder().decode([Note].self, from: Data(contentsOf: try fileURL()))
  }

  private func persist() {
    do {
      let url = try fileURL()
      if notes.isEmpty {
        try? FileManager.default.removeItem(at: url)
        return
      }
      try JSONEncoder().encode(notes).write(to: url, options: [.atomic, .completeFileProtection])
    } catch {
      NSLog("[AutoLoom] notes save failed: %@", LogSanitizer.sanitize(error.localizedDescription))
    }
  }
}
