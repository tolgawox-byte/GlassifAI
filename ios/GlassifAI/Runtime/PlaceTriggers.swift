import Foundation

/// "Eve varınca", "işten çıkınca", "when I get home": a place instead of a
/// time for a reminder. Only home and work, whose addresses the user asked
/// AutoLoom to remember.
extension VoiceActionIntentBridge {
  static let placeTriggerPhrases: [([String], LocationTrigger.Place, Bool)] = {
    let arrive = ["varinca", "vardigimda", "gelince", "geldigimde", "gidince", "gittigimde", "donunce", "dondugumde", "ulasinca"]
    let leave = ["cikinca", "ciktigimda", "ayrilinca", "ayrildigimda"]
    var phrases: [([String], LocationTrigger.Place, Bool)] = []
    for word in arrive {
      phrases.append((["eve", word], .home, true))
      phrases.append((["ise", word], .work, true))
      phrases.append((["ofise", word], .work, true))
    }
    for word in leave {
      phrases.append((["evden", word], .home, false))
      phrases.append((["isten", word], .work, false))
      phrases.append((["ofisten", word], .work, false))
    }
    phrases += [
      (["when", "i", "get", "home"], .home, true), (["when", "i", "get", "back", "home"], .home, true),
      (["when", "i", "arrive", "home"], .home, true), (["when", "i", "leave", "home"], .home, false),
      (["when", "i", "get", "to", "work"], .work, true), (["when", "i", "arrive", "at", "work"], .work, true),
      (["when", "i", "get", "to", "the", "office"], .work, true), (["when", "i", "leave", "work"], .work, false),
      (["when", "i", "leave", "the", "office"], .work, false),
    ]
    return phrases
  }()

  static func placeTrigger(in u: Utterance) -> (place: LocationTrigger.Place, arriving: Bool, range: Range<Int>)? {
    for (phrase, place, arriving) in placeTriggerPhrases {
      if let range = u.range(of: phrase) { return (place, arriving, range) }
    }
    return nil
  }
}

/// Runs "eve varınca … hatırlat": the saved address, a Reminders alarm at it.
extension AssistantOrchestrator {
  func createLocationReminder(
    title: String,
    place: LocationTrigger.Place,
    arriving: Bool,
    decision: VoiceBridgeDecision,
    transcript: String,
    traceID: UUID
  ) async -> IntentOutcome {
    let home = place == .home
    guard let address = MemoryStore.shared.savedAddress(home: home) else {
      let example = home ? "Hatırla: ev adresim …" : "Hatırla: iş adresim …"
      return IntentOutcome(
        spoken: "The user's \(home ? "home" : "work") address is not saved in AutoLoom memory, so a reminder at that place cannot be set. Tell them briefly that they can say once \"\(example)\" (in English: \"Remember that my \(home ? "home" : "work") address is …\") and ask again, or give a time instead.",
        reply: home ? L.t("Your home address is not saved yet.", "Ev adresin henüz kayıtlı değil.")
          : L.t("Your work address is not saved yet.", "İş adresin henüz kayıtlı değil."),
        failed: "no saved address")
    }
    let trigger = LocationTrigger(place: place, arriving: arriving, address: address)
    ActionTraceLog.shared.update(traceID) { $0.parsed = "place reminder: \(trigger.englishLabel)" }
    return await stageLocationReminder(title: title, trigger: trigger, decision: decision, transcript: transcript, traceID: traceID)
  }
}
