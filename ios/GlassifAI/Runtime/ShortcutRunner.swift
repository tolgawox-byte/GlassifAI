import Foundation

/// "Işıkları Aç kısayolunu çalıştır": the user's own Shortcut (Home scenes,
/// lights, anything they built), run by the Shortcuts app after a tap on the
/// phone. No unofficial Home access; nothing runs from a spoken yes alone,
/// and a shortcut is never run from what the camera or the web said.
enum ShortcutLink {
  static func url(for name: String) -> URL? {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    var components = URLComponents()
    components.scheme = "shortcuts"
    components.host = "run-shortcut"
    components.queryItems = [URLQueryItem(name: "name", value: trimmed)]
    return components.url
  }

  static func isRunShortcut(_ url: URL) -> Bool {
    url.scheme?.lowercased() == "shortcuts" && url.host?.lowercased() == "run-shortcut"
  }

  static func name(in url: URL) -> String? {
    URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "name" }?.value
  }
}

extension VoiceActionIntentBridge {
  static func shortcut(_ u: Utterance) -> VoiceBridgeDecision? {
    guard u.count >= 3, u.count <= 10 else { return nil }
    let endings: [[String]] = [
      ["kisayolunu", "calistir"], ["kisayolunu", "baslat"], ["kisayolunu", "ac"], ["kisayolu", "calistir"],
    ]
    if let ending = endings.first(where: { u.ends(with: $0) }) {
      let name = u.dropping((u.count - ending.count)..<u.count)
      guard !name.isEmpty else { return nil }
      return VoiceBridgeDecision(.runShortcut(name.text), "run a shortcut")
    }
    if u.starts(with: ["run", "the"]), u.ends(with: ["shortcut"]), u.count > 3 {
      return VoiceBridgeDecision(.runShortcut(u.dropping(0..<2).dropping((u.count - 3)..<(u.count - 2)).text), "run a shortcut")
    }
    if u.starts(with: ["run", "shortcut"]), u.count > 2 {
      return VoiceBridgeDecision(.runShortcut(u.dropping(0..<2).text), "run a shortcut")
    }
    return nil
  }
}

extension AssistantOrchestrator {
  func runShortcut(_ name: String, traceID: UUID) async -> IntentOutcome {
    ActionTraceLog.shared.update(traceID) { $0.executor = "Shortcuts app (the user's own shortcut), after a tap" }
    guard let url = ShortcutLink.url(for: name) else {
      let tr = "Hangi kısayolu çalıştırayım?"
      let en = "Which shortcut should I run?"
      return IntentOutcome(spoken: BridgeSpeech.ask(tr, en: en), reply: L.t(en, tr), failed: "no name")
    }
    guard AssistantPreferences.actionsEnabled else { return actionsOff() }
    var plan = DeviceActionPlan(kind: .openURL)
    plan.url = url
    plan.title = name
    let staged = await stage(plan)
    return IntentOutcome(spoken: staged.speakable, reply: staged.display ?? name, failed: staged.failed)
  }
}
