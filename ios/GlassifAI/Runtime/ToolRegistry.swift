import Foundation

/// One native iPhone tool the assistant can use, as shown in Settings →
/// Tools. The model only plans; `DeviceActionExecutor` runs the action after
/// the confirmation its risk level requires.
struct NativeTool: Identifiable, Equatable {
  let id: String
  let english: String
  let turkish: String
  let systemImage: String
  let kinds: [DeviceActionKind]
  let permission: AppPermission?
  let englishDetail: String
  let turkishDetail: String

  var name: String { L.t(english, turkish) }
  var detail: String { L.t(englishDetail, turkishDetail) }

  /// The confirmation the tool's main action (its first kind) needs, as
  /// Settings shows it. Other actions keep their own level (deleting a note
  /// still waits for a yes; the detail text says so).
  var risk: DeviceActionKind.Risk {
    kinds.first?.risk ?? .safe
  }
}

enum ToolRegistry {
  static let tools: [NativeTool] = [
    NativeTool(
      id: "reminders", english: "Reminders", turkish: "Anımsatıcılar", systemImage: "checklist",
      kinds: [.createReminder, .listReminders], permission: .reminders,
      englishDetail: "Apple Reminders, saved at once. Times are read from your words by the app, never guessed by the model; an unclear time (\"7'de\") is asked first.",
      turkishDetail: "Apple Anımsatıcılar, hemen kaydedilir. Saatler uygulama tarafından sözlerinizden okunur, model tahmin etmez; belirsiz saat (\"7'de\") önce sorulur."),
    NativeTool(
      id: "calendar", english: "Calendar", turkish: "Takvim", systemImage: "calendar",
      kinds: [.todayEvents, .upcomingEvents, .createEvent], permission: .calendars,
      englishDetail: "Reads today, tomorrow and upcoming events; adds events you ask for, and asks first when the time is unclear.",
      turkishDetail: "Bugünü, yarını ve yaklaşan etkinlikleri okur; istediğiniz etkinliği ekler, saat belirsizse önce sorar."),
    NativeTool(
      id: "notes", english: "AutoLoom Notes", turkish: "AutoLoom Notları", systemImage: "note.text",
      kinds: [.saveNote, .deleteNote], permission: nil,
      englishDetail: "Saved on this iPhone at once; deleting a note waits for your yes. Share a note to Apple Notes from the Memory tab.",
      turkishDetail: "Bu iPhone'a hemen kaydedilir; not silmek onayınızı bekler. Notu Hafıza sekmesinden Apple Notlar'a paylaşabilirsiniz."),
    NativeTool(
      id: "memory", english: "Memory", turkish: "Hafıza", systemImage: "brain",
      kinds: [.forgetMemory], permission: nil,
      englishDetail: "Saves only what you ask. Forgetting needs your yes.",
      turkishDetail: "Yalnızca istediğinizi kaydeder. Silmek için onayınız gerekir."),
    NativeTool(
      id: "notifications", english: "Notifications", turkish: "Bildirimler", systemImage: "bell",
      kinds: [.scheduleNotification], permission: .notifications,
      englishDetail: "Local notifications (\"notify me in 20 minutes\").",
      turkishDetail: "Yerel bildirimler (\"20 dakika sonra haber ver\")."),
    NativeTool(
      id: "contacts", english: "Contacts lookup", turkish: "Kişi arama", systemImage: "person.crop.circle",
      kinds: [.findContact], permission: .contacts,
      englishDetail: "Finds a contact's number for calls and messages. Read-only.",
      turkishDetail: "Arama ve mesaj için kişinin numarasını bulur. Yalnızca okur."),
    NativeTool(
      id: "maps", english: "Maps", turkish: "Haritalar", systemImage: "map",
      kinds: [.openMaps], permission: nil,
      englishDetail: "Opens directions in Apple Maps after a tap.",
      turkishDetail: "Dokunduktan sonra Apple Haritalar'da yol tarifini açar."),
    NativeTool(
      id: "links", english: "Open link", turkish: "Bağlantı aç", systemImage: "safari",
      kinds: [.openURL], permission: nil,
      englishDetail: "Public web links only, after a tap.",
      turkishDetail: "Yalnızca herkese açık web bağlantıları, dokunduktan sonra."),
    NativeTool(
      id: "clipboard", english: "Clipboard", turkish: "Pano", systemImage: "doc.on.doc",
      kinds: [.copyText], permission: nil,
      englishDetail: "Copies text you ask for.",
      turkishDetail: "İstediğiniz metni kopyalar."),
    NativeTool(
      id: "share", english: "Share", turkish: "Paylaş", systemImage: "square.and.arrow.up",
      kinds: [.shareText], permission: nil,
      englishDetail: "Opens the share sheet after a tap.",
      turkishDetail: "Dokunduktan sonra paylaşım menüsünü açar."),
    NativeTool(
      id: "phone", english: "Phone call", turkish: "Telefon araması", systemImage: "phone",
      kinds: [.call], permission: nil,
      englishDetail: "Starts a call only after a tap. Names are looked up in Contacts.",
      turkishDetail: "Aramayı yalnızca dokunduktan sonra başlatır. İsimler Kişiler'de aranır."),
    NativeTool(
      id: "messages", english: "Message", turkish: "Mesaj", systemImage: "message",
      kinds: [.message], permission: nil,
      englishDetail: "Opens Messages with the text; you press Send. Never sent silently.",
      turkishDetail: "Mesajlar'ı metinle açar; Gönder'e siz basarsınız. Asla sessizce gönderilmez."),
  ]

  static func tool(for kind: DeviceActionKind) -> NativeTool? {
    tools.first { $0.kinds.contains(kind) }
  }

  static func enabledKey(_ tool: NativeTool) -> String { "autoloom.tool.\(tool.id).enabled" }

  static func isEnabled(_ tool: NativeTool, defaults: UserDefaults = .standard) -> Bool {
    defaults.object(forKey: enabledKey(tool)) as? Bool ?? true
  }

  /// Whether an action may be planned: iPhone actions on, and its tool on.
  static func allows(_ kind: DeviceActionKind, defaults: UserDefaults = .standard) -> Bool {
    guard let tool = tool(for: kind) else { return true }
    return isEnabled(tool, defaults: defaults)
  }
}

extension DeviceActionKind.Risk {
  var label: String {
    switch self {
    case .safe: L.t("Runs directly", "Doğrudan çalışır")
    case .confirm: L.t("Needs your yes", "Onayınız gerekir")
    case .strongConfirm: L.t("Needs a tap", "Dokunma gerekir")
    }
  }

  var systemImage: String {
    switch self {
    case .safe: "checkmark.shield"
    case .confirm: "hand.thumbsup"
    case .strongConfirm: "hand.tap"
    }
  }
}
