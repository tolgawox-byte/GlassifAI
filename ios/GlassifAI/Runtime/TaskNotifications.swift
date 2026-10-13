import Foundation
import UserNotifications

/// Task alerts with lock-screen actions (plan 2.3): Complete, and Snooze for
/// an hour. Both are handled in the background; nothing opens. While the app
/// is on screen a task alert still shows as a banner; other notifications
/// keep their earlier behaviour (not shown while the app is open).
@MainActor
final class TaskNotifications: NSObject, UNUserNotificationCenterDelegate {
  static let shared = TaskNotifications()

  nonisolated static let category = "autoloom.task"
  nonisolated static let completeAction = "autoloom.task.complete"
  nonisolated static let snoozeAction = "autoloom.task.snooze"
  nonisolated static let taskIDKey = "taskID"
  nonisolated static let snoozeInterval: TimeInterval = 3_600

  /// Called once at launch, before any notification can be answered.
  func register() {
    let center = UNUserNotificationCenter.current()
    center.delegate = self
    let complete = UNNotificationAction(identifier: Self.completeAction, title: L.t("Complete", "Tamamla"), options: [])
    let snooze = UNNotificationAction(identifier: Self.snoozeAction, title: L.t("Snooze 1 hour", "1 saat ertele"), options: [])
    center.setNotificationCategories([
      UNNotificationCategory(identifier: Self.category, actions: [complete, snooze], intentIdentifiers: [], options: []),
    ])
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter, willPresent notification: UNNotification
  ) async -> UNNotificationPresentationOptions {
    notification.request.content.categoryIdentifier == Self.category ? [.banner, .sound, .list] : []
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
  ) async {
    let action = response.actionIdentifier
    guard let raw = response.notification.request.content.userInfo[Self.taskIDKey] as? String,
          let taskID = UUID(uuidString: raw) else { return }
    _ = await handle(action: action, taskID: taskID)
  }

  /// Applies a lock-screen action to the task. False when there is nothing to
  /// do (the task is gone or already done, or another action).
  @discardableResult
  func handle(action: String, taskID: UUID, now: Date = Date()) async -> Bool {
    let store = MemoryStore.shared
    guard let task = store.task(id: taskID), !task.completed else { return false }
    switch action {
    case Self.completeAction:
      store.setCompleted(task, true)
      ActivityLog.shared.record(.action, L.t("Task — completed from its alert", "Görev — bildiriminden tamamlandı"))
      return true
    case Self.snoozeAction:
      let next = now.addingTimeInterval(Self.snoozeInterval)
      store.updateTask(task, title: task.title, notes: task.notes, dueAt: next, dueHasTime: true)
      // A new alert only where alerts are already allowed (an alert's own
      // action implies it); never a permission prompt from here.
      let status = await LocalNotifications.authorizationStatus()
      if [UNAuthorizationStatus.authorized, .provisional, .ephemeral].contains(status),
         let id = try? await LocalNotifications.schedule(
           title: task.title, body: L.t("AutoLoom task", "AutoLoom görevi"), at: next, taskID: task.id) {
        store.setNotificationID(task, id)
      }
      ActivityLog.shared.record(.action, L.t("Task — snoozed for an hour from its alert", "Görev — bildiriminden 1 saat ertelendi"))
      return true
    default:
      return false
    }
  }
}
