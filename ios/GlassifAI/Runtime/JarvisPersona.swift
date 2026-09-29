import Foundation

/// Jarvis Style intensity (Settings → Personality).
enum JarvisIntensity: String, CaseIterable, Identifiable {
  /// Mostly the usual conversation, with a little more precision.
  case subtle
  /// An occasional "efendim" / "sir" and formal precision.
  case balanced
  /// More butler-like wording, still natural, never a parody.
  case full

  static let defaultsKey = "autoloom.voice.jarvisIntensity"

  var id: String { rawValue }

  var label: String {
    switch self {
    case .subtle: L.t("Subtle", "Hafif")
    case .balanced: L.t("Balanced", "Dengeli")
    case .full: L.t("Full", "Tam")
    }
  }
}

/// How the assistant addresses the user (Settings → Personality).
enum JarvisAddress: String, CaseIterable, Identifiable {
  case none
  case name
  /// "efendim" in Turkish, "sir" in English (the Jarvis Style default).
  case sir
  case custom

  static let defaultsKey = "autoloom.voice.jarvisAddress"
  static let customKey = "autoloom.voice.jarvisAddressCustom"

  var id: String { rawValue }

  var label: String {
    switch self {
    case .none: L.t("None", "Hiçbiri")
    case .name: L.t("My name", "Adım")
    case .sir: L.t("Sir / Efendim", "Efendim / Sir")
    case .custom: L.t("Custom", "Özel")
    }
  }
}

/// The Jarvis Style layer on top of any answer: it changes presentation,
/// never the facts. Providers (ChatGPT, Claude, Gemini, Perplexity…) never
/// see it; the voice applies it to everything it says, and the app adapts
/// its own confirmation examples.
extension JarvisStyle {
  static var intensity: JarvisIntensity {
    JarvisIntensity(rawValue: UserDefaults.standard.string(forKey: JarvisIntensity.defaultsKey) ?? "") ?? .balanced
  }

  static var address: JarvisAddress {
    JarvisAddress(rawValue: UserDefaults.standard.string(forKey: JarvisAddress.defaultsKey) ?? "") ?? .sir
  }

  static var customAddress: String {
    (UserDefaults.standard.string(forKey: JarvisAddress.customKey) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// The word used for the user, or nil ("efendim", "sir", "Tolga").
  static func addressWord(
    turkish: Bool,
    address: JarvisAddress = JarvisStyle.address,
    profileName: String? = nil,
    custom: String = JarvisStyle.customAddress
  ) -> String? {
    switch address {
    case .none: return nil
    case .sir: return turkish ? "efendim" : "sir"
    case .name:
      guard let name = profileName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
        return turkish ? "efendim" : "sir"
      }
      return name
    case .custom:
      return custom.isEmpty ? nil : String(custom.prefix(30))
    }
  }

  /// The instructions the voice gets while Jarvis Style is on.
  static func instructions(
    intensity: JarvisIntensity = JarvisStyle.intensity,
    address: JarvisAddress = JarvisStyle.address,
    profileName: String? = nil,
    custom: String = JarvisStyle.customAddress
  ) -> String {
    var text = "Jarvis Style is on: a refined, calm, precise personal assistant. Competent, polite, slightly formal, confident but never arrogant, economical with words. Answer first; then one important detail; then one next step only if it is genuinely useful. No long introductions. Very rare, dry, understated humour, never during errors, safety matters or sensitive moments. Do not imitate any real actor or film character, do not quote films, never claim to be a film character."
    switch intensity {
    case .subtle:
      text += " Keep it subtle: an ordinary natural conversation with a little extra precision."
    case .balanced:
      text += " Balanced: formal precision with an occasional courteous address."
    case .full:
      text += " Full: more butler-like wording (\"Elbette.\", \"Hemen.\", \"Certainly.\", \"Right away.\"), still natural, never a parody."
    }
    let turkishWord = addressWord(turkish: true, address: address, profileName: profileName, custom: custom)
    let englishWord = addressWord(turkish: false, address: address, profileName: profileName, custom: custom)
    if let turkishWord, let englishWord, intensity != .subtle {
      text += " Address the user as \"\(turkishWord)\" in Turkish and \"\(englishWord)\" in English, at most once in a short reply and often not at all (for example \"Not aldım \(turkishWord).\", \"Done, \(englishWord).\")."
    } else {
      text += " Do not add a form of address."
    }
    text += " Turkish must sound natural and respectful (siz), never machine-translated."
    return text
  }

  /// Adapts one of the app's confirmation examples to the persona:
  /// "Tamam, not aldım." → "Not aldım efendim." (balanced: every other
  /// confirmation; full: every one; subtle: never). The facts never change.
  static func confirmation(
    _ sentence: String,
    turkish: Bool,
    intensity: JarvisIntensity = JarvisStyle.intensity,
    word: String?,
    addAddress: Bool
  ) -> String {
    var text = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
    // A butler does not open with "Tamam," / "Done,".
    for opener in turkish ? ["Tamam, ", "Tamam. ", "Peki, "] : ["Done, ", "Okay, ", "OK, "] where text.hasPrefix(opener) {
      text = String(text.dropFirst(opener.count))
      text = text.prefix(1).uppercased() + text.dropFirst()
    }
    guard intensity != .subtle, addAddress, let word, !word.isEmpty else { return text }
    let lowerWord = word.lowercased()
    guard !text.lowercased().contains(lowerWord) else { return text }
    // Before the final punctuation of the first sentence: "Not aldım efendim.", "I've noted it, sir."
    let end = text.firstIndex(where: { ".!?".contains($0) }) ?? text.endIndex
    let head = String(text[..<end])
    let tail = String(text[end...])
    return turkish ? "\(head) \(word)\(tail)" : "\(head), \(word)\(tail)"
  }

  /// Balanced mode addresses the user on every other confirmation.
  private static var confirmationCount = 0

  /// The persona version of a confirmation example, or the sentence as it
  /// is when Jarvis Style is off.
  static func adapt(_ sentence: String, turkish: Bool, profileName: String? = nil) -> String {
    guard isEnabled else { return sentence }
    let mode = intensity
    confirmationCount += 1
    let add = mode == .full || (mode == .balanced && confirmationCount % 2 == 1)
    return confirmation(
      sentence, turkish: turkish, intensity: mode, word: addressWord(turkish: turkish, profileName: profileName),
      addAddress: add)
  }

  /// The ready phrase with the address ("Bağlantı hazır. Sizi dinliyorum
  /// efendim."), when Jarvis Style is on and not subtle.
  static func greeting(_ text: String, turkish: Bool, profileName: String? = nil) -> String {
    guard isEnabled, intensity != .subtle,
          let word = addressWord(turkish: turkish, profileName: profileName) else { return text }
    guard !text.lowercased().contains(word.lowercased()) else { return text }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let last = trimmed.last, ".!?".contains(last) else { return trimmed + (turkish ? " \(word)." : ", \(word).") }
    let body = String(trimmed.dropLast())
    return turkish ? "\(body) \(word)\(last)" : "\(body), \(word)\(last)"
  }
}
