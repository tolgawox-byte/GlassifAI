import AudioToolbox
import Foundation

/// A spoken command the app acts on itself, before the voice model answers.
enum ConversationCommand: Equatable {
  /// "Dur", "sus", "bekle", "stop", "wait" while the assistant is talking:
  /// the app silences the answer at once; the voice model then listens.
  case stopSpeaking
  /// "Kapat", "konuşmayı bitir", "görüşürüz", "Jarvis stop": ends the
  /// conversation after the assistant's short goodbye.
  case endConversation
}

enum ConversationCommands {
  static let enabledKey = "autoloom.voice.stopCommands"

  static var isEnabled: Bool {
    UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
  }

  /// Utterances that start with one of these stop the current answer.
  static let stopPhrases = [
    "dur", "sus", "bekle", "hayır", "bir dakika", "bir saniye", "yeter", "tamam tamam",
    "başka bir şey soracağım", "başka bir şey sorayım",
    "stop", "wait", "hold on", "one moment", "one second", "be quiet", "enough", "never mind",
  ]

  /// Whole utterances (after the name and "hey" are removed) that end the
  /// conversation.
  static let endPhrases = [
    "kapat", "konuşmayı bitir", "konuşmayı kapat", "sohbeti bitir", "sohbeti kapat", "görüşmeyi bitir",
    "görüşürüz", "hoşça kal", "şimdilik bu kadar",
    "end conversation", "end the conversation", "stop listening", "goodbye", "bye bye", "that's all", "hang up",
  ]

  /// Commands that end the conversation only when said with the name
  /// ("Jarvis stop", "AutoLoom kapat").
  static let namedEndWords = ["stop", "dur", "kapat", "bitir", "sus"]

  static func classify(_ utterance: String, assistantName: String, assistantSpeaking: Bool) -> ConversationCommand? {
    let words = normalizedWords(utterance)
    guard !words.isEmpty, words.count <= 8 else { return nil }
    let nameWords = normalizedWords(assistantName)
    var rest = words
    var named = false
    while let first = rest.first, ["hey", "hi", "ok", "okay", "hay", "hei"].contains(first) {
      rest.removeFirst()
    }
    if !nameWords.isEmpty, rest.count >= nameWords.count, Array(rest.prefix(nameWords.count)) == nameWords {
      rest.removeFirst(nameWords.count)
      named = true
    }
    if !named {
      // The recogniser's own spelling of the name ("Oto lum, kapat").
      let names = AddressMatcher.names(assistantName: assistantName)
      for length in [2, 1] where rest.count > length {
        if AddressMatcher.matches(rest.prefix(length).joined(), names: names) {
          rest.removeFirst(length)
          named = true
          break
        }
      }
    }
    while let last = rest.last, ["lütfen", "please", "artık"].contains(last) {
      rest.removeLast()
    }
    guard !rest.isEmpty else { return nil }
    let phrase = rest.joined(separator: " ")
    if endPhrases.contains(phrase) { return .endConversation }
    if named, rest.count == 1, namedEndWords.contains(phrase) {
      // "Jarvis dur" during an answer only stops the answer.
      if assistantSpeaking, ["dur", "sus", "stop"].contains(phrase) { return .stopSpeaking }
      return .endConversation
    }
    if assistantSpeaking, rest.count <= 6,
       stopPhrases.contains(where: { phrase == $0 || phrase.hasPrefix($0 + " ") }) {
      return .stopSpeaking
    }
    return nil
  }

  static func normalizedWords(_ text: String) -> [String] {
    text.lowercased(with: Locale(identifier: "tr_TR"))
      .replacingOccurrences(of: "’", with: "'")
      .components(separatedBy: CharacterSet.letters.union(CharacterSet(charactersIn: "'")).inverted)
      .filter { !$0.isEmpty }
  }
}

/// How long a quiet conversation stays open.
enum ConversationTimeout: Int, CaseIterable, Identifiable {
  case seconds15 = 15
  case seconds30 = 30
  case seconds60 = 60
  case minutes2 = 120
  case never = 0

  static let defaultsKey = "autoloom.conversation.timeout"

  var id: Int { rawValue }

  static var current: ConversationTimeout {
    let stored = UserDefaults.standard.object(forKey: defaultsKey) as? Int
    return stored.flatMap(ConversationTimeout.init(rawValue:)) ?? .minutes2
  }

  var interval: TimeInterval? { self == .never ? nil : TimeInterval(rawValue) }

  var label: String {
    switch self {
    case .seconds15: L.t("15 seconds", "15 saniye")
    case .seconds30: L.t("30 seconds", "30 saniye")
    case .seconds60: L.t("1 minute", "1 dakika")
    case .minutes2: L.t("2 minutes", "2 dakika")
    case .never: L.t("Never", "Asla")
    }
  }

  /// Whether a conversation that has been quiet for `idle` seconds should end.
  static func shouldEnd(idle: TimeInterval, limit: TimeInterval?, busy: Bool) -> Bool {
    guard let limit, !busy else { return false }
    return idle >= limit
  }
}

/// The words said when a new conversation is ready ("Bağlandım,
/// dinliyorum."). Said only once the connection really works.
enum GreetingStyle: String, CaseIterable, Identifiable {
  case here
  case listening
  case normal
  case howCanIHelp
  case minimal
  case jarvis
  case custom

  static let defaultsKey = "autoloom.greeting.style"
  static let customTextKey = "autoloom.greeting.custom"

  var id: String { rawValue }

  static var current: GreetingStyle {
    GreetingStyle(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .normal
  }

  var label: String {
    switch self {
    case .here: L.t("“I'm here.”", "“Buradayım.”")
    case .listening: L.t("“I'm listening.”", "“Dinliyorum.”")
    case .normal: L.t("“Connected, I'm listening.”", "“Bağlandım, dinliyorum.”")
    case .howCanIHelp: L.t("“How can I help?”", "“Nasıl yardımcı olabilirim?”")
    case .minimal: L.t("“Connected.”", "“Bağlandım.”")
    case .jarvis: L.t("Jarvis style", "Jarvis tarzı")
    case .custom: L.t("Custom", "Özel")
    }
  }

  func text(turkish: Bool, custom: String) -> String? {
    switch self {
    case .here: return turkish ? "Buradayım." : "I'm here."
    case .listening: return turkish ? "Dinliyorum." : "I'm listening."
    case .howCanIHelp: return turkish ? "Nasıl yardımcı olabilirim?" : "How can I help?"
    case .minimal: return turkish ? "Bağlandım." : "Connected."
    case .normal: return turkish ? "Bağlandım, dinliyorum." : "Connected, I'm listening."
    case .jarvis: return turkish ? "Bağlantı hazır. Sizi dinliyorum." : "Connection ready. I'm listening."
    case .custom:
      let cleaned = custom.trimmingCharacters(in: .whitespacesAndNewlines)
      return cleaned.isEmpty ? nil : String(cleaned.prefix(120))
    }
  }
}
