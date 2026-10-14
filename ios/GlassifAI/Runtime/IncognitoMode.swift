import Foundation

/// Incognito ("gizli mod", research idea D2-03): conversations leave nothing
/// behind on their own while it is on. The idea comes from the temporary
/// chats of HKUDS/nanobot (MIT); it is re-implemented here, no code taken.
///
/// While it is on:
/// - no conversation summary is saved, also for a conversation in which it
///   was turned off before the end (the earlier turns were said in
///   confidence);
/// - nothing is saved to memory, visual memory or the profile name, and the
///   user hears why;
/// - Live Vision adds no Scene Timeline line;
/// - the voice model is not asked to offer saving things (Smart Memory).
///
/// Commands the user gives by name (a note, a reminder, a message, a photo)
/// still run: the user asked for exactly that. The activity log keeps only
/// the kind of each action, never its words, so it stays the record of what
/// the app did. It stays on until the user turns it off (by voice, on Home
/// or in Settings → Memory), also across a restart: a privacy switch that
/// turned itself off would fail open. Only the user's words or a tap turn it
/// off; a model can only turn it on (`ActionCatalog.intent(for:)`).
@MainActor
final class IncognitoSession: ObservableObject {
  static let enabledKey = "autoloom.privacy.incognito"
  static let shared = IncognitoSession()

  @Published private(set) var isOn: Bool
  /// The current conversation was incognito at some moment.
  private(set) var coversConversation: Bool
  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    let stored = defaults.bool(forKey: Self.enabledKey)
    isOn = stored
    coversConversation = stored
  }

  func begin() {
    isOn = true
    coversConversation = true
    defaults.set(true, forKey: Self.enabledKey)
  }

  /// Turns it off. The conversation it covered still gets no summary.
  func end() {
    isOn = false
    defaults.set(false, forKey: Self.enabledKey)
  }

  /// Called when a conversation ends: whether its summary must be skipped.
  /// The next conversation is covered at once while the mode stays on.
  func conversationFinished() -> Bool {
    let covered = coversConversation || isOn
    coversConversation = isOn
    return covered
  }

  /// For the voice model when something would have been saved.
  static let refusalSpoken =
    "Incognito mode is on, so nothing from the conversation is saved to memory and nothing was saved now. Tell the user briefly; they can say \"gizli modu kapat\" (\"turn off incognito\") and ask again."

  static var refusalReply: String {
    L.t("Incognito is on: nothing is saved to memory.", "Gizli mod açık: hafızaya kaydedilmiyor.")
  }
}
