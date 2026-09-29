import Foundation

/// What the assistant is focused on (Settings → Personality → Mode).
/// Automatic by default: Dealer while a vehicle session is active, otherwise
/// General. A mode only adds one short line to the voice instructions; it
/// never changes what the app is allowed to do.
enum AssistantMode: String, CaseIterable, Identifiable {
  case automatic
  case general
  case dealer
  case dailyLife
  case travel
  case shopping
  case translation
  case diy
  case accessibility

  static let defaultsKey = "autoloom.assistant.mode"

  static var chosen: AssistantMode {
    AssistantMode(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .automatic
  }

  /// The mode in effect: the choice, or (automatic) Dealer while a vehicle
  /// is active.
  @MainActor
  static var effective: AssistantMode {
    let mode = chosen
    guard mode == .automatic else { return mode }
    return DealerStore.shared.active != nil ? .dealer : .general
  }

  var id: String { rawValue }

  var label: String {
    switch self {
    case .automatic: L.t("Automatic", "Otomatik")
    case .general: L.t("General", "Genel")
    case .dealer: L.t("Dealer", "Bayi")
    case .dailyLife: L.t("Daily life", "Günlük yaşam")
    case .travel: L.t("Travel", "Seyahat")
    case .shopping: L.t("Shopping", "Alışveriş")
    case .translation: L.t("Translation", "Çeviri")
    case .diy: L.t("DIY", "Kendin yap")
    case .accessibility: L.t("Accessibility", "Erişilebilirlik")
    }
  }

  /// One short line for the voice instructions (none for General).
  var instructionLine: String? {
    switch self {
    case .automatic, .general:
      nil
    case .dealer:
      "Mode: Dealer. The user works at a car dealership (vehicles, VINs, damage, photos, listings, customers). Be brief and practical. Never say a car is safe to drive; never invent options, history or condition; prices are suggestions, the dealer decides."
    case .dailyLife:
      "Mode: Daily life. Help with notes, tasks, reminders, shopping, timers and errands; keep answers short."
    case .travel:
      "Mode: Travel. Help read signs, menus and directions, translate when useful, and give distances and times plainly."
    case .shopping:
      "Mode: Shopping. Compare products and prices carefully and say where facts come from; no health guarantees from food labels."
    case .translation:
      "Mode: Translation. Translate what the user says or shows faithfully and briefly."
    case .diy:
      "Mode: DIY. Explain steps plainly with the safety points first; say when a professional is needed."
    case .accessibility:
      "Mode: Accessibility. When asked what is around, describe it precisely and in order (text, obstacles, people, distances) in short sentences."
    }
  }
}
