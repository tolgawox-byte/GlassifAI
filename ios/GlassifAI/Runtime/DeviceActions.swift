import Contacts
import EventKit
import Foundation
import UIKit
import UserNotifications

/// Native iPhone actions the assistant can prepare. The model only plans
/// (structured JSON); deterministic code validates and runs every action.
/// Each action has a risk level that decides how it is confirmed:
/// - SAFE: runs at once (after the iOS permission prompt when needed);
/// - CONFIRM: a spoken "yes" or a tap;
/// - STRONG CONFIRM: leaves the app or contacts someone, so only a tap on the
///   phone confirms it (a spoken "yes" is never enough).
enum DeviceActionKind: String, CaseIterable, Codable, Equatable {
  case createReminder = "create_reminder"
  case listReminders = "list_reminders"
  case todayEvents = "today_events"
  case upcomingEvents = "upcoming_events"
  case createEvent = "create_event"
  case saveNote = "save_note"
  case scheduleNotification = "schedule_notification"
  case findContact = "find_contact"
  case openMaps = "open_maps"
  case openURL = "open_url"
  case copyText = "copy_text"
  case shareText = "share_text"
  case call
  case message
  /// Forgetting a saved memory (chosen by the memory flow, not the planner).
  case forgetMemory = "forget_memory"
  /// Deleting an AutoLoom note ("bu notu sil"; never chosen by the planner).
  case deleteNote = "delete_note"
  /// A request for the user's own OpenClaw agent (never chosen by the planner).
  case agentTask = "agent_task"
  case none

  enum Risk: String, Equatable {
    case safe = "SAFE"
    case confirm = "CONFIRM"
    case strongConfirm = "STRONG CONFIRM"
  }

  var risk: Risk {
    switch self {
    // An explicit reminder or event is saved at once; an ambiguous time is
    // always asked first (see `DeviceActionPlan.ambiguityNote`).
    case .listReminders, .todayEvents, .upcomingEvents, .copyText, .saveNote, .scheduleNotification,
         .findContact, .createReminder, .createEvent, .none:
      .safe
    case .forgetMemory, .deleteNote, .agentTask:
      .confirm
    case .openMaps, .openURL, .shareText, .call, .message:
      .strongConfirm
    }
  }

  /// Changes something on the phone; the other SAFE kinds only read.
  var writes: Bool {
    switch self {
    case .createReminder, .createEvent, .saveNote, .scheduleNotification, .copyText: true
    default: false
    }
  }

  /// Kinds the action planner may choose.
  static var plannable: [DeviceActionKind] {
    allCases.filter { $0 != .agentTask && $0 != .forgetMemory && $0 != .deleteNote }
  }

  var label: String {
    switch self {
    case .createReminder: L.t("Reminder", "Anımsatıcı")
    case .listReminders: L.t("Reminders", "Anımsatıcılar")
    case .todayEvents: L.t("Today's calendar", "Bugünün takvimi")
    case .upcomingEvents: L.t("Upcoming events", "Yaklaşan etkinlikler")
    case .createEvent: L.t("Calendar event", "Takvim etkinliği")
    case .saveNote: L.t("AutoLoom note", "AutoLoom notu")
    case .scheduleNotification: L.t("Notification", "Bildirim")
    case .findContact: L.t("Contact", "Kişi")
    case .openMaps: L.t("Directions", "Yol tarifi")
    case .openURL: L.t("Open link", "Bağlantıyı aç")
    case .copyText: L.t("Copy", "Kopyala")
    case .shareText: L.t("Share", "Paylaş")
    case .call: L.t("Phone call", "Arama")
    case .message: L.t("Message", "Mesaj")
    case .forgetMemory: L.t("Forget memory", "Hafızadan sil")
    case .deleteNote: L.t("Delete note", "Notu sil")
    case .agentTask: L.t("Your agent (OpenClaw)", "Ajanınız (OpenClaw)")
    case .none: L.t("No action", "İşlem yok")
    }
  }

  var systemImage: String {
    switch self {
    case .createReminder, .listReminders: "checklist"
    case .todayEvents, .upcomingEvents, .createEvent: "calendar"
    case .saveNote: "note.text"
    case .scheduleNotification: "bell"
    case .findContact: "person.crop.circle"
    case .openMaps: "map"
    case .openURL: "safari"
    case .copyText: "doc.on.doc"
    case .shareText: "square.and.arrow.up"
    case .call: "phone"
    case .message: "message"
    case .forgetMemory: "brain"
    case .deleteNote: "trash"
    case .agentTask: "server.rack"
    case .none: "questionmark.circle"
    }
  }

  /// Kinds whose time comes from the user's words.
  var usesTime: Bool {
    self == .createReminder || self == .createEvent || self == .scheduleNotification
  }
}

/// A validated action ready to run or to confirm.
struct DeviceActionPlan: Equatable {
  var kind: DeviceActionKind
  var title: String?
  var notes: String?
  var date: Date?
  /// False when the user gave a day but no time (a reminder without alarm).
  var hasTime = true
  /// The other reading of an ambiguous time ("8" → 08:00 or 20:00).
  var alternativeDate: Date?
  var endDate: Date?
  var location: String?
  var url: URL?
  var text: String?
  var recipient: String?
  var phone: String?
  /// The memory to forget (forget_memory).
  var memoryID: UUID?
  /// The note to delete (delete_note).
  var noteID: UUID?
  /// The planner's short explanation (used for `none`).
  var reply: String = ""
  /// Planned by the model in a turn that also brought camera, web or agent
  /// content (`AssistantOrchestrator.runAction`).
  var afterUntrustedContent = false

  /// Agent requests that sound destructive (deleting, deploying, payments,
  /// email) need a tap, even though other agent requests accept a spoken yes.
  /// A change planned right after camera, web or agent content may carry
  /// instructions from that content, so it waits for the user's yes;
  /// outbound actions need a tap anyway.
  var risk: DeviceActionKind.Risk {
    if kind == .agentTask, ActionGuard.soundsDestructive(text ?? "") { return .strongConfirm }
    if afterUntrustedContent, kind.writes, kind.risk == .safe { return .confirm }
    return kind.risk
  }

  var whenText: String? {
    date.map { TimePhraseParser.describe($0, hasTime: hasTime, turkish: L.isTurkish) }
  }

  /// One line for the confirmation card and the voice model.
  var summary: String {
    let when = whenText
    switch kind {
    case .createReminder:
      return L.t("Reminder", "Anımsatıcı") + " \"\(title ?? "")\"" + (when.map { " — \($0)" } ?? L.t(" (no time)", " (saatsiz)"))
    case .createEvent:
      return L.t("Event", "Etkinlik") + " \"\(title ?? "")\" — \(when ?? "")" + (location.map { " @ \($0)" } ?? "")
    case .saveNote:
      return L.t("Note", "Not") + " \"\(title ?? String((text ?? "").prefix(40)))\""
    case .scheduleNotification:
      return L.t("Notification", "Bildirim") + " \"\(title ?? text ?? "")\" — \(when ?? "")"
    case .findContact:
      return L.t("Find contact", "Kişi bul") + " \"\(recipient ?? "")\""
    case .openMaps:
      return L.t("Directions to ", "Yol tarifi: ") + (location ?? "")
    case .openURL:
      return L.t("Open ", "Aç: ") + (url?.host ?? url?.absoluteString ?? "")
    case .copyText:
      return L.t("Copy", "Kopyala") + " \"\((text ?? "").prefix(60))\""
    case .shareText:
      return L.t("Share", "Paylaş") + " \"\((text ?? "").prefix(60))\""
    case .call:
      let target = recipient ?? phone ?? ""
      return L.t("Call ", "Ara: ") + target + (recipient != nil && phone != nil ? " (\(phone ?? ""))" : "")
    case .message:
      let target = recipient ?? phone ?? L.t("(choose recipient)", "(alıcı seçin)")
      return L.t("Message ", "Mesaj: ") + target + ": \"\((text ?? "").prefix(80))\""
    case .forgetMemory:
      return L.t("Forget", "Unut") + ": \"\((text ?? "").prefix(80))\""
    case .deleteNote:
      return L.t("Delete note", "Notu sil") + ": \"\((text ?? "").prefix(80))\""
    case .agentTask:
      return L.t("Ask your agent", "Ajanınıza sor") + ": \"\((text ?? "").prefix(120))\""
    case .listReminders, .todayEvents, .upcomingEvents, .none:
      return kind.label
    }
  }

  /// English text for the voice model when the time was ambiguous.
  var ambiguityNote: String? {
    guard let date, let alternativeDate else { return nil }
    let first = date.formatted(date: .omitted, time: .shortened)
    let second = alternativeDate.formatted(date: .omitted, time: .shortened)
    return "The time is ambiguous: \(first) or \(second). Ask the user which one they mean before confirming."
  }
}

/// Requests that are refused before any model call: email, money, deleting
/// data, code and deployment, public posting. The words cover English and
/// Turkish.
enum ActionGuard {
  /// Requests about reminders, notes or the calendar are planned even when
  /// they mention buying or email ("remind me to buy milk").
  private static let organizingTerms = [
    "remind", "reminder", "note", "calendar", "event", "meeting", "schedule", "notify", "notification",
    "hatırlat", "anımsat", "not al", "not et", "notu", "takvim", "etkinlik", "toplantı", "randevu", "bildirim",
    "haber ver",
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
    "This app cannot perform actions such as \(reason). It supports reminders, calendar, AutoLoom notes, notifications, contacts lookup, maps, links, copy, share, and calls or messages that the user confirms on the phone. Tell the user honestly that this is not supported."
  }
}

/// Turns the planner model's JSON into a validated plan. Times are never
/// taken from the model: it copies the user's words ("yarın saat 7'de") and
/// `TimePhraseParser` resolves them; the user's own request is the fallback.
enum DeviceActionParser {
  static func parse(
    _ json: String,
    query: String = "",
    now: Date = Date()
  ) -> Result<DeviceActionPlan, ActionPlanError> {
    guard let data = json.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return .failure(.invalid("The action could not be understood."))
    }
    func text(_ key: String, limit: Int = 500) -> String? {
      guard let value = (object[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
            !value.isEmpty else { return nil }
      return String(value.prefix(limit))
    }
    guard let kind = DeviceActionKind(rawValue: text("action") ?? "none"),
          DeviceActionKind.plannable.contains(kind) else {
      return .failure(.invalid("That action is not supported."))
    }
    var plan = DeviceActionPlan(kind: kind)
    plan.title = text("title", limit: 200)
    plan.notes = text("notes", limit: 1_000)
    plan.location = text("location", limit: 200)
    plan.text = text("text", limit: 4_000)
    plan.recipient = text("recipient", limit: 100)
    plan.reply = text("reply", limit: 400) ?? ""
    if kind.usesTime {
      let when = text("when")
      switch resolveTime(when, query: query, now: now) {
      case .success(let parsed?):
        plan.date = parsed.date
        plan.hasTime = parsed.hasTime
        plan.alternativeDate = parsed.isAmbiguous ? parsed.alternative : nil
      case .success(.none):
        break
      case .failure(let error):
        return .failure(error)
      }
      if kind == .createEvent, let end = text("end"), !looksLikeMachineDate(end),
         let parsedEnd = TimePhraseParser.parse(end, now: now) {
        plan.endDate = endDate(parsedEnd, start: plan.date)
      }
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

  /// The user's words for the time, resolved deterministically. A machine
  /// timestamp from the model is ignored; the request itself is the fallback.
  static func resolveTime(_ when: String?, query: String, now: Date) -> Result<ParsedTime?, ActionPlanError> {
    if let when, !looksLikeMachineDate(when), let parsed = TimePhraseParser.parse(when, now: now) {
      return .success(parsed)
    }
    if !query.isEmpty, let parsed = TimePhraseParser.parse(query, now: now) {
      return .success(parsed)
    }
    if let when, !when.isEmpty {
      return .failure(.invalid("The time \"\(when)\" could not be understood."))
    }
    return .success(nil)
  }

  /// An end time without a day ("until 3") belongs to the start's day.
  static func endDate(_ end: ParsedTime, start: Date?, calendar: Calendar = .current) -> Date {
    guard let start, !end.hasDay, end.hasTime else { return end.date }
    let parts = calendar.dateComponents([.hour, .minute], from: end.date)
    return calendar.date(bySettingHour: parts.hour ?? 0, minute: parts.minute ?? 0, second: 0, of: start) ?? end.date
  }

  /// "2026-09-28T07:00" and similar: a model-made timestamp, not user words.
  static func looksLikeMachineDate(_ text: String) -> Bool {
    text.range(of: #"^\s*\d{4}-\d{2}-\d{2}"#, options: .regularExpression) != nil
  }

  static func validate(_ plan: DeviceActionPlan, now: Date) -> Result<DeviceActionPlan, ActionPlanError> {
    var plan = plan
    switch plan.kind {
    case .createReminder:
      guard plan.title != nil else { return .failure(.missing("what to be reminded about")) }
      if let date = plan.date, plan.hasTime, date < now.addingTimeInterval(-60) {
        return .failure(.invalid("That time is in the past."))
      }
    case .createEvent:
      guard plan.title != nil else { return .failure(.missing("the event title")) }
      guard let start = plan.date else { return .failure(.missing("when the event is")) }
      guard plan.hasTime else { return .failure(.missing("the time of the event")) }
      if start < now.addingTimeInterval(-60) { return .failure(.invalid("That time is in the past.")) }
      if let end = plan.endDate, end <= start { return .failure(.invalid("The event ends before it starts.")) }
      if plan.endDate == nil { plan.endDate = start.addingTimeInterval(3_600) }
    case .scheduleNotification:
      guard plan.title != nil || plan.text != nil else { return .failure(.missing("what the notification should say")) }
      guard let date = plan.date, plan.hasTime else { return .failure(.missing("when to notify")) }
      if date < now.addingTimeInterval(-5) { return .failure(.invalid("That time is in the past.")) }
    case .saveNote, .copyText, .shareText:
      guard plan.text != nil else { return .failure(.missing("the text")) }
    case .findContact:
      guard plan.recipient != nil else { return .failure(.missing("whose contact details to look up")) }
    case .openMaps:
      guard plan.location != nil else { return .failure(.missing("the destination")) }
    case .openURL:
      guard plan.url != nil else { return .failure(.missing("the web address")) }
    case .call:
      guard plan.phone != nil || plan.recipient != nil else { return .failure(.missing("who to call")) }
    case .message:
      guard plan.text != nil else { return .failure(.missing("the message text")) }
    case .forgetMemory:
      guard plan.memoryID != nil else { return .failure(.missing("which memory to forget")) }
    case .deleteNote:
      guard plan.noteID != nil else { return .failure(.missing("which note to delete")) }
    case .agentTask:
      guard plan.text != nil else { return .failure(.missing("what to ask your agent")) }
    case .listReminders, .todayEvents, .upcomingEvents, .none:
      break
    }
    return .success(plan)
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

/// Contacts lookup for "call Ahmet" and "what is Ayşe's number". Read-only;
/// permission is asked the first time it is needed, with the app open.
enum ContactsLookup {
  struct Match: Equatable {
    let name: String
    let phones: [(label: String, number: String)]

    static func == (lhs: Match, rhs: Match) -> Bool {
      lhs.name == rhs.name && lhs.phones.map(\.number) == rhs.phones.map(\.number)
    }
  }

  static var authorization: CNAuthorizationStatus {
    CNContactStore.authorizationStatus(for: .contacts)
  }

  @MainActor
  static func find(_ name: String) async throws -> [Match] {
    let store = CNContactStore()
    switch authorization {
    case .authorized: break
    case .notDetermined:
      guard UIApplication.shared.applicationState == .active else {
        throw DeviceActionExecutor.ExecutionError.needsForeground("Contacts")
      }
      guard try await store.requestAccess(for: .contacts) else {
        throw DeviceActionExecutor.ExecutionError.permissionDenied("contacts")
      }
    default:
      if #available(iOS 18.0, *), authorization == .limited { break }
      throw DeviceActionExecutor.ExecutionError.permissionDenied("contacts")
    }
    let keys: [CNKeyDescriptor] = [
      CNContactGivenNameKey as CNKeyDescriptor, CNContactFamilyNameKey as CNKeyDescriptor,
      CNContactNicknameKey as CNKeyDescriptor, CNContactPhoneNumbersKey as CNKeyDescriptor,
      CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
    ]
    let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let contacts = try await Task.detached(priority: .userInitiated) {
      try CNContactStore().unifiedContacts(
        matching: CNContact.predicateForContacts(matchingName: cleaned), keysToFetch: keys)
    }.value
    return contacts.prefix(5).map { contact in
      let fullName = CNContactFormatter.string(from: contact, style: .fullName) ?? cleaned
      let phones = contact.phoneNumbers.map { labeled in
        (label: labeled.label.map { CNLabeledValue<CNPhoneNumber>.localizedString(forLabel: $0) } ?? "phone",
         number: labeled.value.stringValue)
      }
      return Match(name: fullName, phones: phones)
    }
  }
}

/// Local notifications ("20 dakika sonra bana haber ver").
enum LocalNotifications {
  static func authorizationStatus() async -> UNAuthorizationStatus {
    await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
  }

  /// Schedules one notification and confirms it was accepted by iOS.
  @MainActor
  static func schedule(title: String, body: String?, at date: Date) async throws -> String {
    let center = UNUserNotificationCenter.current()
    switch await authorizationStatus() {
    case .authorized, .provisional, .ephemeral: break
    case .notDetermined:
      guard UIApplication.shared.applicationState == .active else {
        throw DeviceActionExecutor.ExecutionError.needsForeground("Notifications")
      }
      guard try await center.requestAuthorization(options: [.alert, .sound]) else {
        throw DeviceActionExecutor.ExecutionError.permissionDenied("notifications")
      }
    default:
      throw DeviceActionExecutor.ExecutionError.permissionDenied("notifications")
    }
    let content = UNMutableNotificationContent()
    content.title = title
    if let body { content.body = body }
    content.sound = .default
    let seconds = max(1, date.timeIntervalSinceNow)
    let trigger = UNTimeIntervalNotificationTrigger(timeInterval: seconds, repeats: false)
    let identifier = "autoloom-\(UUID().uuidString)"
    try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
    let pending = await center.pendingNotificationRequests()
    guard pending.contains(where: { $0.identifier == identifier }) else {
      throw DeviceActionExecutor.ExecutionError.failed("iOS did not accept the notification.")
    }
    return identifier
  }
}

/// Runs actions with Apple frameworks. Nothing here sends anything anywhere:
/// reminders and events go to the user's own lists and calendars, notes stay
/// on the phone, and calls/messages open the system UI for the user to finish.
/// Success is reported only after iOS confirms it.
@MainActor
final class DeviceActionExecutor {
  static let shared = DeviceActionExecutor()
  let store = EKEventStore()

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

  /// SAFE and CONFIRM actions. STRONG CONFIRM actions are performed by the
  /// confirmation card itself.
  func run(_ plan: DeviceActionPlan) async throws -> String {
    switch plan.kind {
    case .createReminder: return try await createReminder(plan)
    case .listReminders: return try await listReminders()
    case .todayEvents: return try await events(from: Calendar.current.startOfDay(for: Date()), days: 1, label: "today")
    case .upcomingEvents: return try await events(from: Date(), days: 7, label: "in the next 7 days")
    case .createEvent: return try await createEvent(plan)
    case .saveNote:
      guard MemoryStore.shared.addNote(title: plan.title, content: plan.text ?? "", source: "voice") != nil else {
        throw ExecutionError.failed("The note could not be saved.")
      }
      return "Saved as an AutoLoom note on this iPhone (Memory tab → Notes)."
    case .scheduleNotification:
      guard let date = plan.date else { throw ExecutionError.failed("The notification needs a time.") }
      _ = try await LocalNotifications.schedule(
        title: plan.title ?? plan.text ?? AutoLoomBrand.appName,
        body: plan.title == nil ? nil : plan.text, at: date)
      return "Notification scheduled for \(date.formatted(date: .abbreviated, time: .shortened))."
    case .findContact:
      return try await findContact(plan.recipient ?? "")
    case .copyText:
      UIPasteboard.general.string = plan.text
      return "Copied to the clipboard."
    case .forgetMemory:
      guard let id = plan.memoryID, let record = MemoryStore.shared.memory(id: id) else {
        throw ExecutionError.failed("That memory no longer exists.")
      }
      // Read before deleting: a deleted SwiftData object must not be touched.
      let forgotten = String(record.text.prefix(80))
      MemoryStore.shared.delete(record)
      return "Forgotten: \(forgotten)"
    case .deleteNote:
      guard let id = plan.noteID, let note = MemoryStore.shared.notes.first(where: { $0.id == id }) else {
        throw ExecutionError.failed("That note no longer exists.")
      }
      // Read before deleting: a deleted SwiftData object must not be touched.
      let deleted = String(note.title.prefix(60))
      MemoryStore.shared.deleteNote(note)
      return "Deleted the AutoLoom note: \(deleted)"
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

  func ensureReminderAccess() async throws {
    switch EKEventStore.authorizationStatus(for: .reminder) {
    case .fullAccess, .authorized: return
    case .notDetermined:
      guard isForeground else { throw ExecutionError.needsForeground("Reminders") }
      guard try await store.requestFullAccessToReminders() else { throw ExecutionError.permissionDenied("reminders") }
    default:
      throw ExecutionError.permissionDenied("reminders")
    }
  }

  func ensureEventAccess(fullAccess: Bool) async throws {
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
      let fields: Set<Calendar.Component> = plan.hasTime ? [.year, .month, .day, .hour, .minute] : [.year, .month, .day]
      reminder.dueDateComponents = Calendar.current.dateComponents(fields, from: date)
      if plan.hasTime { reminder.addAlarm(EKAlarm(absoluteDate: date)) }
    }
    try store.save(reminder, commit: true)
    guard !reminder.calendarItemIdentifier.isEmpty else {
      throw ExecutionError.failed("iOS did not confirm the reminder.")
    }
    let when = plan.whenText.map { " for \($0)" } ?? ""
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

  /// Events of a day ("yarın ne var?": dayOffset 1) or of several days.
  func readEvents(dayOffset: Int, days: Int) async throws -> String {
    let calendar = Calendar.current
    let today = calendar.startOfDay(for: Date())
    let start = dayOffset == 0 && days > 1 ? Date() : calendar.date(byAdding: .day, value: dayOffset, to: today) ?? today
    let label: String
    switch (dayOffset, days) {
    case (0, 1): label = "today"
    case (1, 1): label = "tomorrow"
    default: label = "in the next \(days) days"
    }
    return try await events(from: start, days: days, label: label)
  }

  /// Open reminders due in [start, end) as short lines; with
  /// `includeOverdue`, also the ones already overdue. Reminders without a
  /// due date are not part of a day.
  func dueReminderLines(from start: Date, to end: Date, includeOverdue: Bool) async throws -> [String] {
    try await ensureReminderAccess()
    let predicate = store.predicateForIncompleteReminders(
      withDueDateStarting: includeOverdue ? nil : start, ending: end, calendars: nil)
    let reminders: [EKReminder] = await withCheckedContinuation { continuation in
      _ = store.fetchReminders(matching: predicate) { continuation.resume(returning: $0 ?? []) }
    }
    let calendar = Calendar.current
    let dated = reminders.compactMap { reminder -> (date: Date, hasTime: Bool, title: String)? in
      guard let components = reminder.dueDateComponents, let date = calendar.date(from: components), date < end else {
        return nil
      }
      return (date, components.hour != nil, reminder.title ?? "Untitled")
    }
    return dated.sorted { $0.date < $1.date }.prefix(8).map { item in
      if item.date < start { return "overdue: \(item.title)" }
      return item.hasTime ? "\(item.date.formatted(date: .omitted, time: .shortened)): \(item.title)" : item.title
    }
  }

  /// Calendar events in [start, end) as short lines.
  func eventLines(from start: Date, to end: Date) async throws -> [String] {
    try await ensureEventAccess(fullAccess: true)
    let events = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil))
      .sorted { $0.startDate < $1.startDate }
    return events.prefix(10).map { event in
      let time = event.isAllDay ? "all day" : event.startDate.formatted(date: .omitted, time: .shortened)
      return "\(time): \(event.title ?? "Untitled")" + (event.location.map { " @ \($0)" } ?? "")
    }
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
    guard event.eventIdentifier != nil else {
      throw ExecutionError.failed("iOS did not confirm the event.")
    }
    return "Event saved in \(calendar.title): \(plan.title ?? "") on \(start.formatted(date: .abbreviated, time: .shortened))."
  }

  private func findContact(_ name: String) async throws -> String {
    let matches = try await ContactsLookup.find(name)
    guard !matches.isEmpty else { return "No contact named \(name) was found on this iPhone." }
    let lines = matches.map { match -> String in
      let phones = match.phones.prefix(3).map { "\($0.label) \($0.number)" }.joined(separator: ", ")
      return "- \(match.name)" + (phones.isEmpty ? " (no phone number)" : ": \(phones)")
    }
    return "Contacts found:\n" + lines.joined(separator: "\n")
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

  /// A Maps search around the user ("benzinlik", "pharmacy").
  static func mapsSearchURL(for query: String) -> URL? {
    var components = URLComponents(string: "https://maps.apple.com/")
    components?.queryItems = [URLQueryItem(name: "q", value: query)]
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
