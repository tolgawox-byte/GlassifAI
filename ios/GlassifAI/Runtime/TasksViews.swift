import EventKit
import SwiftUI
import UIKit
import UserNotifications

/// Apple Reminders for the Tasks tab (the same lists the assistant writes
/// to). Every change is made through EventKit and shown only after iOS
/// accepted it.
@MainActor
final class RemindersBoard: ObservableObject {
  static let shared = RemindersBoard()

  struct Item: Identifiable, Equatable {
    let id: String
    let title: String
    let due: Date?
    let hasTime: Bool
    let completed: Bool
    let completedAt: Date?
    let list: String
  }

  struct ScheduledNotification: Identifiable, Equatable {
    let id: String
    let title: String
    let fireDate: Date?
  }

  @Published private(set) var today: [Item] = []
  @Published private(set) var upcoming: [Item] = []
  @Published private(set) var completed: [Item] = []
  @Published private(set) var notifications: [ScheduledNotification] = []
  @Published private(set) var access: PermissionState = .notAsked
  @Published private(set) var lastError: String?
  @Published private(set) var isLoading = false

  private var store: EKEventStore { DeviceActionExecutor.shared.store }

  func refreshAccess() {
    switch EKEventStore.authorizationStatus(for: .reminder) {
    case .fullAccess, .authorized: access = .granted
    case .notDetermined: access = .notAsked
    default: access = .denied
    }
  }

  func requestAccess() async {
    do {
      try await DeviceActionExecutor.shared.ensureReminderAccess()
    } catch {
      lastError = LogSanitizer.sanitize(error.localizedDescription, limit: 200)
    }
    refreshAccess()
    await load()
  }

  func load() async {
    refreshAccess()
    await loadNotifications()
    guard access == .granted else { return }
    isLoading = true
    defer { isLoading = false }
    let calendar = Calendar.current
    let open: [EKReminder] = await fetch(store.predicateForIncompleteReminders(
      withDueDateStarting: nil, ending: nil, calendars: nil))
    let weekAgo = calendar.date(byAdding: .day, value: -7, to: Date()) ?? Date()
    let done: [EKReminder] = await fetch(store.predicateForCompletedReminders(
      withCompletionDateStarting: weekAgo, ending: Date(), calendars: nil))
    let endOfToday = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date())) ?? Date()
    let openItems = open.map(Self.item)
    today = openItems.filter { item in item.due.map { $0 < endOfToday } ?? false }
      .sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
    upcoming = openItems.filter { item in item.due.map { $0 >= endOfToday } ?? true }
      .sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
    completed = done.map(Self.item)
      .sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
  }

  private func fetch(_ predicate: NSPredicate) async -> [EKReminder] {
    await withCheckedContinuation { continuation in
      _ = store.fetchReminders(matching: predicate) { continuation.resume(returning: $0 ?? []) }
    }
  }

  private static func item(_ reminder: EKReminder) -> Item {
    let components = reminder.dueDateComponents
    let due = components.flatMap { Calendar.current.date(from: $0) }
    return Item(
      id: reminder.calendarItemIdentifier,
      title: reminder.title ?? L.t("Untitled", "Başlıksız"),
      due: due,
      hasTime: components?.hour != nil,
      completed: reminder.isCompleted,
      completedAt: reminder.completionDate,
      list: reminder.calendar?.title ?? "")
  }

  private func reminder(_ item: Item) -> EKReminder? {
    store.calendarItem(withIdentifier: item.id) as? EKReminder
  }

  func setCompleted(_ item: Item, _ done: Bool) async {
    guard let reminder = reminder(item) else { return }
    reminder.isCompleted = done
    commit { try store.save(reminder, commit: true) }
    await load()
  }

  func delete(_ item: Item) async {
    guard let reminder = reminder(item) else { return }
    commit { try store.remove(reminder, commit: true) }
    await load()
  }

  func reschedule(_ item: Item, to date: Date, hasTime: Bool) async {
    guard let reminder = reminder(item) else { return }
    apply(date: date, hasTime: hasTime, to: reminder)
    commit { try store.save(reminder, commit: true) }
    await load()
  }

  func create(title: String, due: Date?, hasTime: Bool) async {
    guard access == .granted, let list = store.defaultCalendarForNewReminders() else { return }
    let reminder = EKReminder(eventStore: store)
    reminder.title = title
    reminder.calendar = list
    if let due { apply(date: due, hasTime: hasTime, to: reminder) }
    commit { try store.save(reminder, commit: true) }
    await load()
  }

  private func apply(date: Date, hasTime: Bool, to reminder: EKReminder) {
    let fields: Set<Calendar.Component> = hasTime ? [.year, .month, .day, .hour, .minute] : [.year, .month, .day]
    reminder.dueDateComponents = Calendar.current.dateComponents(fields, from: date)
    for alarm in reminder.alarms ?? [] { reminder.removeAlarm(alarm) }
    if hasTime { reminder.addAlarm(EKAlarm(absoluteDate: date)) }
  }

  private func commit(_ change: () throws -> Void) {
    do {
      try change()
      lastError = nil
    } catch {
      lastError = LogSanitizer.sanitize(error.localizedDescription, limit: 200)
    }
  }

  // MARK: Notifications scheduled by the assistant

  func loadNotifications() async {
    let pending = await UNUserNotificationCenter.current().pendingNotificationRequests()
    notifications = pending
      .filter { $0.identifier.hasPrefix("autoloom-") }
      .map { request in
        let fireDate = (request.trigger as? UNTimeIntervalNotificationTrigger)?.nextTriggerDate()
          ?? (request.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate()
        return ScheduledNotification(id: request.identifier, title: request.content.title, fireDate: fireDate)
      }
      .sorted { ($0.fireDate ?? .distantFuture) < ($1.fireDate ?? .distantFuture) }
  }

  func cancelNotification(_ notification: ScheduledNotification) async {
    UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [notification.id])
    await loadNotifications()
  }
}

/// The Tasks tab: Apple Reminders (Today / Upcoming / Completed) and
/// notifications the assistant scheduled.
struct TasksTabView: View {
  @ObservedObject private var board = RemindersBoard.shared
  @State private var showNew = false
  @State private var rescheduling: RemindersBoard.Item?
  @State private var deleting: RemindersBoard.Item?
  @Environment(\.openURL) private var openURL

  var body: some View {
    NavigationStack {
      List {
        switch board.access {
        case .granted:
          reminderSections
        case .notAsked:
          Section {
            VStack(alignment: .leading, spacing: 10) {
              Label(L.t("Connect Apple Reminders", "Apple Anımsatıcılar'ı bağlayın"), systemImage: "checklist")
                .font(.headline)
              Text(L.t("See and manage the reminders the assistant creates for you. iOS asks for permission once.",
                       "Asistanın sizin için oluşturduğu anımsatıcıları görün ve yönetin. iOS bir kez izin ister."))
                .font(.subheadline)
                .foregroundStyle(.secondary)
              Button(L.t("Connect", "Bağlan")) { Task { await board.requestAccess() } }
                .buttonStyle(.borderedProminent)
            }
            .padding(.vertical, 6)
          }
        case .denied, .limited:
          Section {
            VStack(alignment: .leading, spacing: 10) {
              Text(L.t("Reminders access is off.", "Anımsatıcı izni kapalı.")).font(.headline)
              Text(L.t("Allow it in iOS Settings → AutoLoom → Reminders.", "iOS Ayarlar → AutoLoom → Anımsatıcılar'dan izin verin."))
                .font(.subheadline)
                .foregroundStyle(.secondary)
              Button(L.t("Open Settings", "Ayarları aç")) {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
              }
            }
            .padding(.vertical, 6)
          }
        }
        if !board.notifications.isEmpty {
          Section(L.t("Scheduled notifications", "Planlanmış bildirimler")) {
            ForEach(board.notifications) { notification in
              VStack(alignment: .leading, spacing: 2) {
                Text(notification.title)
                if let date = notification.fireDate {
                  Text(date.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
              }
              .swipeActions {
                Button(role: .destructive) {
                  Task { await board.cancelNotification(notification) }
                } label: {
                  Label(L.t("Cancel", "İptal"), systemImage: "bell.slash")
                }
              }
            }
          }
        }
        if let error = board.lastError {
          Section {
            Label(error, systemImage: "exclamationmark.triangle")
              .font(.footnote)
              .foregroundStyle(.orange)
          }
        }
      }
      .navigationTitle(L.t("Tasks", "Görevler"))
      .toolbar {
        ToolbarItem(placement: .primaryAction) {
          Button { showNew = true } label: { Image(systemName: "plus") }
            .disabled(board.access != .granted)
            .accessibilityLabel(L.t("New reminder", "Yeni anımsatıcı"))
        }
      }
      .refreshable { await board.load() }
      .task { await board.load() }
      .sheet(isPresented: $showNew) {
        NavigationStack { ReminderEditorView(item: nil) }
      }
      .sheet(item: $rescheduling) { item in
        NavigationStack { ReminderEditorView(item: item) }
      }
      .confirmationDialog(
        L.t("Delete this reminder?", "Bu anımsatıcı silinsin mi?"),
        isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
        titleVisibility: .visible,
        presenting: deleting
      ) { item in
        Button(L.t("Delete", "Sil"), role: .destructive) {
          Task { await board.delete(item) }
        }
      } message: { item in
        Text(item.title)
      }
    }
  }

  @ViewBuilder
  private var reminderSections: some View {
    Section(L.t("Today", "Bugün")) {
      if board.today.isEmpty {
        Text(L.t("Nothing due today.", "Bugün için bir şey yok.")).foregroundStyle(.secondary)
      }
      ForEach(board.today) { row($0) }
    }
    Section(L.t("Upcoming", "Yaklaşan")) {
      if board.upcoming.isEmpty {
        Text(L.t("No upcoming reminders.", "Yaklaşan anımsatıcı yok.")).foregroundStyle(.secondary)
      }
      ForEach(board.upcoming) { row($0) }
    }
    if !board.completed.isEmpty {
      Section(L.t("Completed (last 7 days)", "Tamamlanan (son 7 gün)")) {
        ForEach(board.completed) { row($0) }
      }
    }
  }

  private func row(_ item: RemindersBoard.Item) -> some View {
    HStack(spacing: 12) {
      Button {
        Task { await board.setCompleted(item, !item.completed) }
      } label: {
        Image(systemName: item.completed ? "checkmark.circle.fill" : "circle")
          .font(.title3)
          .foregroundStyle(item.completed ? Color.green : AutoLoomTheme.electricBlue)
      }
      .buttonStyle(.plain)
      .accessibilityLabel(item.completed ? L.t("Mark as not done", "Yapılmadı olarak işaretle") : L.t("Complete", "Tamamla"))
      VStack(alignment: .leading, spacing: 2) {
        Text(item.title)
          .strikethrough(item.completed)
          .foregroundStyle(item.completed ? .secondary : .primary)
        HStack(spacing: 6) {
          if let due = item.due {
            Text(due.formatted(date: .abbreviated, time: item.hasTime ? .shortened : .omitted))
              .foregroundStyle(!item.completed && due < Date() ? Color.red : Color.secondary)
          }
          if !item.list.isEmpty {
            Text(item.list).foregroundStyle(.tertiary)
          }
        }
        .font(.caption)
      }
    }
    .contentShape(Rectangle())
    .swipeActions(edge: .trailing) {
      Button(role: .destructive) { deleting = item } label: {
        Label(L.t("Delete", "Sil"), systemImage: "trash")
      }
      Button { rescheduling = item } label: {
        Label(L.t("Reschedule", "Ertele"), systemImage: "calendar")
      }
      .tint(.blue)
    }
  }
}

/// New reminder, or a new time for an existing one. The time can be typed
/// naturally ("yarın 9'da") and is shown resolved before saving.
struct ReminderEditorView: View {
  let item: RemindersBoard.Item?
  @State private var title = ""
  @State private var hasDue = true
  @State private var includeTime = true
  @State private var due = Date().addingTimeInterval(3_600)
  @State private var phrase = ""
  @State private var loaded = false
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    Form {
      if item == nil {
        TextField(L.t("Reminder", "Anımsatıcı"), text: $title)
      } else {
        Text(item?.title ?? "").font(.headline)
      }
      Section {
        TextField(L.t("When, in your words (e.g. tomorrow at 9)", "Ne zaman, kendi sözlerinizle (ör. yarın 9'da)"), text: $phrase)
          .onChange(of: phrase) { _, text in
            if let parsed = TimePhraseParser.parse(text) {
              hasDue = true
              includeTime = parsed.hasTime
              due = parsed.date
            }
          }
        Toggle(L.t("Due date", "Tarih"), isOn: $hasDue)
        if hasDue {
          Toggle(L.t("Include time", "Saat ekle"), isOn: $includeTime)
          DatePicker(
            L.t("Due", "Zaman"), selection: $due,
            displayedComponents: includeTime ? DatePickerComponents([.date, .hourAndMinute]) : DatePickerComponents.date)
        }
      }
    }
    .navigationTitle(item == nil ? L.t("New reminder", "Yeni anımsatıcı") : L.t("Reschedule", "Ertele"))
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .cancellationAction) {
        Button(L.t("Cancel", "Vazgeç")) { dismiss() }
      }
      ToolbarItem(placement: .confirmationAction) {
        Button(L.t("Save", "Kaydet")) {
          let board = RemindersBoard.shared
          let item = item
          let title = title
          let due = due
          let hasDue = hasDue
          let includeTime = includeTime
          Task {
            if let item {
              if hasDue { await board.reschedule(item, to: due, hasTime: includeTime) }
            } else {
              await board.create(title: title, due: hasDue ? due : nil, hasTime: includeTime)
            }
          }
          dismiss()
        }
        .disabled(item == nil && title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
    .onAppear {
      guard !loaded else { return }
      loaded = true
      if let item {
        title = item.title
        if let date = item.due {
          due = date
          includeTime = item.hasTime
        }
      }
    }
  }
}
