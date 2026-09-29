import Foundation
import UIKit
import UserNotifications

// MARK: Timers

/// One running timer ("10 dakika timer", "yumurta için 7 dakika").
struct AssistantTimer: Identifiable, Equatable {
  let id = UUID()
  let label: String?
  let duration: TimeInterval
  let endsAt: Date
  /// The local notification that rings when the app is not on screen.
  let notificationID: String

  func remaining(now: Date = Date()) -> TimeInterval { max(0, endsAt.timeIntervalSince(now)) }
}

/// Timers on this iPhone. Each one also schedules a local notification, so
/// it rings with the app in the background or the phone locked; with a
/// conversation open the assistant says it too.
@MainActor
final class TimerCenter: ObservableObject {
  static let shared = TimerCenter()

  @Published private(set) var timers: [AssistantTimer] = []
  private var tick: Task<Void, Never>?
  /// Tells the user a timer finished (spoken in the conversation, else a notice).
  var announce: @MainActor (String) -> Void = { text in
    let orchestrator = AssistantOrchestrator.shared
    if let speak = orchestrator.speakInConversation,
       speak(BridgeSpeech.done("A timer the user set has finished.", tr: text, en: text)) { return }
    orchestrator.postNotice(text)
  }

  var isRunning: Bool { !timers.isEmpty }

  /// Schedules the ringing notification (tests replace it: no iOS prompt).
  var scheduleNotification: @MainActor (AssistantTimer) async -> Bool = { timer in
    await TimerCenter.scheduleSystemNotification(for: timer)
  }

  /// Removes pending notifications (tests replace it: no system service).
  var removeNotifications: @MainActor ([String]) -> Void = { identifiers in
    guard !identifiers.isEmpty else { return }
    UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: identifiers)
  }

  @discardableResult
  func start(seconds: TimeInterval, label: String?) async -> (timer: AssistantTimer, notificationScheduled: Bool) {
    let id = "autoloom.timer.\(UUID().uuidString)"
    let timer = AssistantTimer(label: label, duration: seconds, endsAt: Date().addingTimeInterval(seconds), notificationID: id)
    timers.append(timer)
    timers.sort { $0.endsAt < $1.endsAt }
    let scheduled = await scheduleNotification(timer)
    watch()
    return (timer, scheduled)
  }

  /// Cancels the timer with this label, or the one ending first.
  @discardableResult
  func cancel(label: String? = nil) -> AssistantTimer? {
    let match = label.flatMap { wanted in timers.first { $0.label?.localizedCaseInsensitiveContains(wanted) == true } }
    guard let timer = match ?? timers.first else { return nil }
    timers.removeAll { $0.id == timer.id }
    removeNotifications([timer.notificationID])
    return timer
  }

  @discardableResult
  func cancel(id: UUID) -> AssistantTimer? {
    guard let timer = timers.first(where: { $0.id == id }) else { return nil }
    timers.removeAll { $0.id == id }
    removeNotifications([timer.notificationID])
    return timer
  }

  func cancelAll() {
    removeNotifications(timers.map(\.notificationID))
    timers.removeAll()
  }

  static func scheduleSystemNotification(for timer: AssistantTimer) async -> Bool {
    let center = UNUserNotificationCenter.current()
    var status = await center.notificationSettings().authorizationStatus
    if status == .notDetermined, UIApplication.shared.applicationState == .active {
      _ = try? await center.requestAuthorization(options: [.alert, .sound])
      status = await center.notificationSettings().authorizationStatus
    }
    guard status == .authorized || status == .provisional || status == .ephemeral else { return false }
    let content = UNMutableNotificationContent()
    content.title = L.t("Timer finished", "Süre doldu")
    content.body = timer.label.map { L.t("Timer: \($0)", "Zamanlayıcı: \($0)") } ?? L.t("Your timer has finished.", "Zamanlayıcınız bitti.")
    content.sound = .default
    let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, timer.duration), repeats: false)
    do {
      try await center.add(UNNotificationRequest(identifier: timer.notificationID, content: content, trigger: trigger))
      return true
    } catch {
      return false
    }
  }

  private func watch() {
    guard tick == nil else { return }
    tick = Task { @MainActor [weak self] in
      while let self, !self.timers.isEmpty, !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        let now = Date()
        let finished = self.timers.filter { $0.endsAt <= now }
        guard !finished.isEmpty else { continue }
        self.timers.removeAll { $0.endsAt <= now }
        for timer in finished {
          UINotificationFeedbackGenerator().notificationOccurred(.warning)
          self.announce(Self.finishedText(timer.label, turkish: L.isTurkish))
        }
      }
      self?.tick = nil
    }
  }

  nonisolated static func finishedText(_ label: String?, turkish: Bool) -> String {
    if let label { return turkish ? "Süre doldu: \(label)." : "Time's up: \(label)." }
    return turkish ? "Süre doldu." : "Time's up."
  }

  /// "7 dakika 30 saniye", "1 saat 5 dakika".
  nonisolated static func spoken(_ seconds: TimeInterval, turkish: Bool) -> String {
    let total = max(0, Int(seconds.rounded()))
    let hours = total / 3_600
    let minutes = (total % 3_600) / 60
    let rest = total % 60
    var parts: [String] = []
    if turkish {
      if hours > 0 { parts.append("\(hours) saat") }
      if minutes > 0 { parts.append("\(minutes) dakika") }
      if rest > 0 || parts.isEmpty { parts.append("\(rest) saniye") }
    } else {
      if hours > 0 { parts.append("\(hours) hour\(hours == 1 ? "" : "s")") }
      if minutes > 0 { parts.append("\(minutes) minute\(minutes == 1 ? "" : "s")") }
      if rest > 0 || parts.isEmpty { parts.append("\(rest) second\(rest == 1 ? "" : "s")") }
    }
    return parts.joined(separator: " ")
  }
}

/// Durations in speech: "10 dakika", "5 dk", "1 saat", "30 saniye",
/// "yarım saat", "çeyrek saat", "bir buçuk saat", "10 minutes", "an hour",
/// "half an hour", "90 seconds".
enum DurationParser {
  static func seconds(in text: String) -> TimeInterval? {
    let words = MemorySearch.fold(text).components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    let numbers: [String: Double] = [
      "bir": 1, "iki": 2, "uc": 3, "dort": 4, "bes": 5, "alti": 6, "yedi": 7, "sekiz": 8, "dokuz": 9, "on": 10,
      "a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "ten": 10, "fifteen": 15, "twenty": 20,
      "thirty": 30,
    ]
    func unit(_ word: String) -> Double? {
      if word.hasPrefix("saat") || word.hasPrefix("hour") || word == "hr" { return 3_600 }
      if word.hasPrefix("dakika") || word.hasPrefix("minute") || word == "dk" || word == "min" || word == "mins" { return 60 }
      if word.hasPrefix("saniye") || word.hasPrefix("second") || word == "sn" || word == "sec" || word == "secs" { return 1 }
      return nil
    }
    var total: TimeInterval = 0
    var pending: Double?
    var found = false
    var index = 0
    while index < words.count {
      let word = words[index]
      defer { index += 1 }
      if word == "yarim" || word == "half" {
        // "yarım saat", "half an hour", "half a minute".
        var next = index + 1
        if next < words.count, words[next] == "an" || words[next] == "a" { next += 1 }
        if next < words.count, let size = unit(words[next]) {
          total += size / 2
          found = true
          index = next
        }
        continue
      }
      if word == "ceyrek" || word == "quarter" {
        var next = index + 1
        if next < words.count, words[next] == "of" || words[next] == "an" { next += 1 }
        if next < words.count, words[next] == "an" { next += 1 }
        if next < words.count, let size = unit(words[next]), size == 3_600 {
          total += 900
          found = true
          index = next
        }
        continue
      }
      if let value = Double(word) {
        pending = value
      } else if word == "bucuk", let value = pending {
        pending = value + 0.5
      } else if let size = unit(word) {
        if let value = pending {
          total += value * size
          found = true
          pending = nil
        }
      } else if let value = numbers[word] {
        pending = value
      }
    }
    guard found, total > 0, total <= 24 * 3_600 else { return nil }
    return total
  }
}

// MARK: Shopping list

struct ShoppingItem: Codable, Equatable, Identifiable {
  var id = UUID()
  var text: String
  var done = false
  var addedAt = Date()
}

/// The shopping list, on this iPhone only (JSON in Application Support).
@MainActor
final class ShoppingListStore: ObservableObject {
  static let shared = ShoppingListStore()

  @Published private(set) var items: [ShoppingItem] = []
  private let fileURL: URL

  init(directory: URL? = nil) {
    let base = directory ?? (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory).appendingPathComponent("AutoLoom", isDirectory: true)
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    fileURL = base.appendingPathComponent("shopping.json")
    if let data = try? Data(contentsOf: fileURL) {
      if let decoded = try? JSONDecoder().decode([ShoppingItem].self, from: data) {
        items = decoded
      } else {
        LocalJSONFile.setAside(fileURL)
      }
    }
  }

  var open: [ShoppingItem] { items.filter { !$0.done } }

  /// Adds items not already open on the list; returns the ones added.
  @discardableResult
  func add(_ texts: [String]) -> [ShoppingItem] {
    var added: [ShoppingItem] = []
    for text in texts {
      let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !cleaned.isEmpty else { continue }
      let key = MemorySearch.fold(cleaned)
      if items.contains(where: { !$0.done && MemorySearch.fold($0.text) == key }) { continue }
      let item = ShoppingItem(text: cleaned.prefix(1).uppercased() + cleaned.dropFirst())
      items.append(item)
      added.append(item)
    }
    persist()
    return added
  }

  /// Removes the open item that matches ("sütü listeden çıkar").
  @discardableResult
  func remove(matching text: String) -> ShoppingItem? {
    let key = MemorySearch.fold(text)
    guard let index = items.firstIndex(where: {
      let item = MemorySearch.fold($0.text)
      return item == key || key.hasPrefix(item) || item.hasPrefix(key)
    }) else { return nil }
    let item = items.remove(at: index)
    persist()
    return item
  }

  func toggle(_ id: UUID) {
    guard let index = items.firstIndex(where: { $0.id == id }) else { return }
    items[index].done.toggle()
    persist()
  }

  func delete(_ id: UUID) {
    items.removeAll { $0.id == id }
    persist()
  }

  func clearDone() {
    items.removeAll(where: \.done)
    persist()
  }

  func deleteEverything() {
    items.removeAll()
    persist()
  }

  private func persist() {
    guard let data = try? JSONEncoder().encode(items) else { return }
    try? data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
  }

  /// "süt ve ekmek", "süt, ekmek, yumurta", "milk and eggs".
  nonisolated static func split(_ text: String) -> [String] {
    var parts = [text]
    for separator in [",", " ve ", " ile ", " and ", " & "] {
      parts = parts.flatMap { $0.components(separatedBy: separator) }
    }
    return parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)) }.filter { !$0.isEmpty }
  }

  /// "sütü" → "süt", "ekmeği" → "ekmek", "yumurtayı" → "yumurta": the
  /// accusative form said before "listeye ekle".
  nonisolated static func baseForm(_ word: String) -> String {
    let lower = word.lowercased(with: Locale(identifier: "tr_TR"))
    guard lower.count >= 4 else { return word }
    let vowels = Set("aeıioöuü")
    let characters = Array(lower)
    let last = characters[characters.count - 1]
    let previous = characters[characters.count - 2]
    guard vowels.contains(last) else { return word }
    if previous == "y", characters.count >= 4, vowels.contains(characters[characters.count - 3]) {
      return String(word.dropLast(2))
    }
    if previous == "ğ" { return String(word.dropLast(2)) + "k" }
    if !vowels.contains(previous) { return String(word.dropLast()) }
    return word
  }
}
