import Foundation

enum TimerCommand: Equatable {
  case start(seconds: Int, label: String?)
  case cancel
  case remaining
}

enum ShoppingCommand: Equatable {
  case add([String])
  case read
  case remove(String)
}

/// Timers and the shopping list (LEVEL 1, on the phone, offline).
extension VoiceActionIntentBridge {
  static func daily(_ u: Utterance, _ context: VoiceBridgeContext) -> VoiceBridgeDecision? {
    guard u.count <= 30 else { return nil }
    return timer(u, context) ?? shopping(u)
  }

  static func isTimerWord(_ key: String) -> Bool {
    key.hasPrefix("timer") || key.hasPrefix("zamanlayici") || key.hasPrefix("sayac")
  }

  private static func timer(_ u: Utterance, _ context: VoiceBridgeContext) -> VoiceBridgeDecision? {
    let named = u.keys.contains(where: isTimerWord) || u.range(of: ["geri", "sayim"]) != nil
    let questions: Set<String> = ["nasil", "neden", "niye", "nedir", "how", "why", "what"]
    // "Timerı durdur", "zamanlayıcıyı iptal et", "cancel the timer".
    if named, u.containsAny(["durdur", "iptal", "kapat", "sil", "kaldir", "cancel", "stop", "delete"]) {
      return VoiceBridgeDecision(.timer(.cancel), "timer cancel")
    }
    // "Ne kadar kaldı?": about a timer when one runs and nothing else was said.
    let remaining: [[String]] = [
      ["ne", "kadar", "kaldi"], ["kac", "dakika", "kaldi"], ["kac", "saniye", "kaldi"], ["how", "much", "time", "is", "left"],
      ["how", "long", "is", "left"], ["how", "much", "time", "left"],
    ]
    if let phrase = remaining.first(where: { u.range(of: $0) != nil }), let range = u.range(of: phrase) {
      // Bare "ne kadar kaldı?" only while a timer runs and with nothing else
      // said ("Eve ne kadar kaldı?" is about the way home).
      let fillers: Set<String> = ["peki", "acaba", "daha", "simdi", "su", "an", "hemen", "lutfen", "now", "please"]
      let outside = Array(u.keys[0..<range.lowerBound]) + Array(u.keys[range.upperBound...])
      if named || (context.timerRunning && outside.allSatisfy(fillers.contains)) {
        return VoiceBridgeDecision(.timer(.remaining), "timer remaining")
      }
    }
    // "10 dakika timer kur", "yumurta için 7 dakika timer", "set a timer for 10 minutes".
    guard named, !u.containsAny(questions), let seconds = DurationParser.seconds(in: u.text), seconds >= 1 else { return nil }
    var label: String?
    if let icin = u.keys.firstIndex(of: "icin"), icin > 0, icin <= 3 {
      label = capitalizedFirst(u.words[0..<icin].joined(separator: " "))
    }
    return VoiceBridgeDecision(.timer(.start(seconds: Int(seconds.rounded()), label: label)), "timer start")
  }

  static let shoppingListPhrases: [[String]] = [
    ["alisveris", "listesinden"], ["alisveris", "listemden"], ["alisveris", "listesine"], ["alisveris", "listeme"],
    ["alisveris", "listesinde"], ["alisveris", "listemde"], ["alisveris", "listesini"], ["alisveris", "listemi"],
    ["alisveris", "listesi"], ["alisveris", "listem"], ["shopping", "list"],
  ]

  private static func shopping(_ u: Utterance) -> VoiceBridgeDecision? {
    guard let (_, range) = firstPhrase(shoppingListPhrases, in: u) else { return nil }
    // Turkish items said before the list are in the accusative ("sütü").
    let turkish = !u.contains("shopping")
    var before = u.dropping(range.lowerBound..<u.count)
    var after = u.dropping(0..<range.upperBound)
    let addVerbs: Set<String> = ["ekle", "ekler", "yaz", "koy", "add", "put"]
    let removeVerbs: Set<String> = ["cikar", "sil", "kaldir", "remove", "delete", "take"]
    if u.containsAny(removeVerbs) {
      before.trimLeading(removeVerbs.union(["lutfen", "please"]))
      before.trimTrailing(["from", "the", "my", "off", "of"])
      after.trimTrailing(removeVerbs.union(["lutfen", "please"]))
      let text = before.isEmpty ? after.text : before.text
      guard !text.isEmpty else { return nil }
      return VoiceBridgeDecision(.shopping(.remove(turkish ? lastWordBase(text) : text)), "shopping remove")
    }
    if u.containsAny(addVerbs) {
      before.trimLeading(addVerbs.union(["lutfen", "please", "sunu", "bunu"]))
      before.trimTrailing(["to", "the", "my", "on", "onto"])
      after.trimTrailing(addVerbs.union(["lutfen", "please", "de", "da"]))
      let accusative = !before.isEmpty && turkish
      let text = before.isEmpty ? after.text : before.text
      let items = ShoppingListStore.split(text).map { accusative ? lastWordBase($0) : $0 }
      guard !items.isEmpty else { return nil }
      return VoiceBridgeDecision(.shopping(.add(items)), "shopping add")
    }
    let readWords: Set<String> = ["ne", "neler", "oku", "goster", "soyle", "what", "whats", "read", "show", "tell"]
    if u.containsAny(readWords) || u.count <= 3 {
      return VoiceBridgeDecision(.shopping(.read), "shopping read")
    }
    return nil
  }

  /// The base form of an item's last word ("tam buğday ekmeği" → "tam buğday ekmek").
  private static func lastWordBase(_ text: String) -> String {
    var words = text.split(separator: " ").map(String.init)
    guard let last = words.popLast() else { return text }
    words.append(ShoppingListStore.baseForm(last))
    return words.joined(separator: " ")
  }
}
