import MessageUI
import SwiftUI
import UIKit

/// The confirmed result of one thing the app did itself, for the short
/// card on the assistant screen and Recent activity. Labels and times only:
/// never the note text, a name, a number or a message.
struct ActionFeedback: Identifiable, Equatable {
  enum Kind: String {
    case note
    case memory
    case reminder
    case task
    case taskDone
    case event
    case notification
    case call
    case message
    case directions
    case copy
    case share
    case contact
    case forgotten
    case photo
    case video
    case failure
  }

  let id = UUID()
  let kind: Kind
  let title: String
  let detail: String?
  let success: Bool
  let at: Date
  /// A short preview for the card only (the note's first words); never kept
  /// in Recent activity.
  let preview: String?

  init(kind: Kind, title: String, detail: String? = nil, success: Bool = true, at: Date = Date(), preview: String? = nil) {
    self.kind = kind
    self.title = title
    self.detail = detail
    self.success = success
    self.at = at
    self.preview = preview.map { String($0.prefix(90)) }
  }

  var systemImage: String {
    switch kind {
    case .note: "note.text"
    case .memory: "brain"
    case .reminder: "checklist"
    case .task: "checkmark.circle"
    case .taskDone: "checkmark.circle.fill"
    case .event: "calendar"
    case .notification: "bell"
    case .call: "phone"
    case .message: "message"
    case .directions: "map"
    case .copy: "doc.on.doc"
    case .share: "square.and.arrow.up"
    case .contact: "person.crop.circle"
    case .forgotten: "trash"
    case .photo: "camera.fill"
    case .video: "video.fill"
    case .failure: "exclamationmark.triangle"
    }
  }

  /// "✓ Hatırlatıcı oluşturuldu · yarın 10:00".
  var line: String {
    (success ? "✓ " : "") + title + (detail.map { " · \($0)" } ?? "")
  }

  // MARK: Common results

  static func noteSaved(preview: String? = nil) -> ActionFeedback {
    ActionFeedback(kind: .note, title: L.t("Note saved", "Not kaydedildi"), preview: preview)
  }

  static func memorySaved() -> ActionFeedback {
    ActionFeedback(kind: .memory, title: L.t("Remembered", "Hafızaya kaydedildi"))
  }

  static func taskAdded(due: Date?, hasTime: Bool) -> ActionFeedback {
    ActionFeedback(kind: .task, title: L.t("Task added", "Görev eklendi"), detail: due.map { when($0, hasTime: hasTime) })
  }

  /// "✓ Fotoğraf galeriye kaydedildi" only after Photos confirmed it.
  static func photoSaved(inPhotos: Bool) -> ActionFeedback {
    ActionFeedback(
      kind: .photo,
      title: inPhotos ? L.t("Photo saved to Photos", "Fotoğraf galeriye kaydedildi")
        : L.t("Photo kept in AutoLoom", "Fotoğraf AutoLoom'da saklandı"))
  }

  static func videoSaved(inPhotos: Bool, parts: Int) -> ActionFeedback {
    ActionFeedback(
      kind: .video,
      title: inPhotos ? L.t("Video saved to Photos", "Video galeriye kaydedildi")
        : L.t("Video kept in AutoLoom", "Video AutoLoom'da saklandı"),
      detail: parts > 1 ? L.t("\(parts) parts", "\(parts) parça") : nil)
  }

  static func failed(_ what: String) -> ActionFeedback {
    ActionFeedback(kind: .failure, title: what, success: false)
  }

  /// A SAFE plan that iOS or the store confirmed; nil for plans that only read.
  static func saved(_ plan: DeviceActionPlan) -> ActionFeedback? {
    let detail = plan.date.map { when($0, hasTime: plan.hasTime) }
    switch plan.kind {
    case .createReminder:
      return ActionFeedback(kind: .reminder, title: L.t("Reminder created", "Hatırlatıcı oluşturuldu"), detail: detail)
    case .createEvent:
      return ActionFeedback(kind: .event, title: L.t("Event added", "Etkinlik eklendi"), detail: detail)
    case .scheduleNotification:
      return ActionFeedback(kind: .notification, title: L.t("Notification set", "Bildirim kuruldu"), detail: detail)
    case .saveNote:
      return noteSaved()
    case .copyText:
      return ActionFeedback(kind: .copy, title: L.t("Copied", "Kopyalandı"))
    case .forgetMemory:
      return ActionFeedback(kind: .forgotten, title: L.t("Forgotten", "Hafızadan silindi"))
    case .deleteNote:
      return ActionFeedback(kind: .forgotten, title: L.t("Note deleted", "Not silindi"))
    default:
      return nil
    }
  }

  /// "Failed to save" for a plan that writes; nil for plans that only read.
  static func notSaved(_ plan: DeviceActionPlan) -> ActionFeedback? {
    switch plan.kind {
    case .createReminder: failed(L.t("Reminder not created", "Hatırlatıcı oluşturulamadı"))
    case .createEvent: failed(L.t("Event not added", "Etkinlik eklenemedi"))
    case .scheduleNotification: failed(L.t("Notification not set", "Bildirim kurulamadı"))
    case .saveNote: failed(L.t("Note not saved", "Not kaydedilemedi"))
    case .copyText: failed(L.t("Not copied", "Kopyalanamadı"))
    default: nil
    }
  }

  /// "Tomorrow · 10:00" style: the day in words, then the time.
  static func when(_ date: Date, hasTime: Bool, now: Date = Date(), calendar: Calendar = .current) -> String {
    let dayWord: String
    if calendar.isDate(date, inSameDayAs: now) {
      dayWord = L.t("Today", "Bugün")
    } else if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
      dayWord = L.t("Tomorrow", "Yarın")
    } else {
      let formatter = DateFormatter()
      formatter.locale = Locale(identifier: L.isTurkish ? "tr_TR" : "en_US")
      formatter.setLocalizedDateFormatFromTemplate("EEEdMMM")
      dayWord = formatter.string(from: date)
    }
    guard hasTime else { return dayWord }
    return dayWord + " · " + date.formatted(date: .omitted, time: .shortened)
  }
}

/// The system's own sheets for sending and sharing. The app only prepares
/// them: nothing is sent or shared unless the user taps Send or picks a
/// target, and the result the sheet reports is what the app says.
@MainActor
enum SystemSheets {
  private static var messageDelegate: MessageComposeDelegate?

  /// The frontmost view controller, to present a system sheet from.
  static func topViewController() -> UIViewController? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let windows = scenes.flatMap { $0.windows }
    var top = (windows.first { $0.isKeyWindow } ?? windows.first)?.rootViewController
    while let presented = top?.presentedViewController { top = presented }
    return top
  }

  static var canSendMessages: Bool { MFMessageComposeViewController.canSendText() }

  /// Opens Messages' compose sheet with the text and, when known, the
  /// number. Returns false when it cannot be shown (app not on screen, no
  /// Messages on this device).
  static func presentMessage(
    phone: String?,
    body: String,
    finished: @escaping @MainActor (MessageComposeResult) -> Void
  ) -> Bool {
    guard UIApplication.shared.applicationState == .active, canSendMessages, let top = topViewController() else {
      return false
    }
    let controller = MFMessageComposeViewController()
    if let phone { controller.recipients = [phone] }
    controller.body = body
    let delegate = MessageComposeDelegate { result in
      messageDelegate = nil
      finished(result)
    }
    messageDelegate = delegate
    controller.messageComposeDelegate = delegate
    top.present(controller, animated: true)
    return true
  }

  /// Opens the share sheet with the text. `finished` reports whether the
  /// user completed a share.
  static func presentShare(text: String, finished: @escaping @MainActor (Bool) -> Void) -> Bool {
    guard UIApplication.shared.applicationState == .active, let top = topViewController() else { return false }
    let controller = UIActivityViewController(activityItems: [text], applicationActivities: nil)
    controller.completionWithItemsHandler = { _, completed, _, _ in
      Task { @MainActor in finished(completed) }
    }
    if let popover = controller.popoverPresentationController {
      popover.sourceView = top.view
      popover.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 1, height: 1)
      popover.permittedArrowDirections = []
    }
    top.present(controller, animated: true)
    return true
  }
}

/// Reports what the user did in the compose sheet and closes it.
final class MessageComposeDelegate: NSObject, MFMessageComposeViewControllerDelegate {
  private let finished: @MainActor (MessageComposeResult) -> Void

  init(finished: @escaping @MainActor (MessageComposeResult) -> Void) {
    self.finished = finished
  }

  func messageComposeViewController(_ controller: MFMessageComposeViewController, didFinishWith result: MessageComposeResult) {
    let finished = self.finished
    Task { @MainActor in
      controller.dismiss(animated: true)
      finished(result)
    }
  }
}

// MARK: Views

/// "✓ Not kaydedildi": a short card after an action really finished.
struct ActionFeedbackToast: View {
  let feedback: ActionFeedback

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: feedback.success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
        .font(.system(size: 18, weight: .semibold))
        .foregroundStyle(feedback.success ? AutoLoomTheme.electricBlue : GlassesUserStatus.Tone.attention.color)
        .symbolEffect(.bounce, value: feedback.id)
      VStack(alignment: .leading, spacing: 2) {
        Text(feedback.title)
          .font(.subheadline.weight(.semibold))
        if let detail = feedback.detail {
          Text(detail)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        if let preview = feedback.preview {
          Text(preview)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }
      }
      Spacer(minLength: 0)
      Image(systemName: feedback.systemImage)
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 11)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.08)))
    .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(feedback.line)
  }
}

/// The last few things the app did, labels and times only.
struct RecentActivityStrip: View {
  let items: [ActionFeedback]

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(L.t("Recent activity", "Son işlemler"))
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
      ForEach(items.prefix(3)) { item in
        HStack(spacing: 8) {
          Image(systemName: item.systemImage)
            .font(.caption)
            .foregroundStyle(item.success ? AutoLoomTheme.electricBlue : GlassesUserStatus.Tone.attention.color)
            .frame(width: 18)
          Text(item.title + (item.detail.map { " · \($0)" } ?? ""))
            .font(.caption)
            .lineLimit(1)
          Spacer(minLength: 4)
          Text(item.at, style: .relative)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
      }
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
  }
}
