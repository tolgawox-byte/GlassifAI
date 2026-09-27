import AppIntents
import Foundation

/// What asked the app to start listening.
enum VoiceStartReason: String {
  case button = "Button"
  case siriShortcut = "Siri / Shortcuts"
  case metaInvocation = "Hey Meta"
}

/// Single entry point for starting a voice conversation. Makes starting
/// idempotent: a second request while a start is in flight, or while a
/// conversation is already active, is ignored, so an invocation that arrives
/// twice (or together with a button press) can never open two realtime
/// sessions. Requests that arrive before the conversation screen exists (cold
/// launch from Siri) are held briefly and run once it registers.
@MainActor
final class VoiceStartCoordinator: ObservableObject {
  static let shared = VoiceStartCoordinator()

  enum Outcome: String, Equatable {
    case started
    case alreadyActive
    case queued
    case failed
  }

  /// Invocation diagnostics only: time, type, result. No audio is stored.
  struct Event: Identifiable, Equatable {
    let id = UUID()
    let reason: VoiceStartReason
    let at: Date
    let outcome: Outcome
  }

  @Published private(set) var events: [Event] = []

  private var start: (@MainActor (VoiceStartReason) async -> Void)?
  private var isActive: @MainActor () -> Bool = { false }
  private var inFlight = false
  private var pending: (reason: VoiceStartReason, at: Date)?
  private let pendingLifetime: TimeInterval = 30

  init() {}

  func register(
    isActive: @escaping @MainActor () -> Bool,
    start: @escaping @MainActor (VoiceStartReason) async -> Void
  ) {
    self.isActive = isActive
    self.start = start
    guard let queued = pending else { return }
    pending = nil
    if Date().timeIntervalSince(queued.at) <= pendingLifetime {
      Task { await self.request(queued.reason) }
    }
  }

  func unregister() {
    start = nil
    isActive = { false }
  }

  @discardableResult
  func request(_ reason: VoiceStartReason) async -> Outcome {
    guard let start else {
      pending = (reason, Date())
      record(reason, .queued)
      return .queued
    }
    if inFlight || isActive() {
      record(reason, .alreadyActive)
      return .alreadyActive
    }
    inFlight = true
    await start(reason)
    inFlight = false
    let outcome: Outcome = isActive() ? .started : .failed
    record(reason, outcome)
    return outcome
  }

  private func record(_ reason: VoiceStartReason, _ outcome: Outcome) {
    events.append(Event(reason: reason, at: Date(), outcome: outcome))
    if events.count > 10 { events.removeFirst(events.count - 10) }
  }
}

/// "Hey Siri, start AutoLoom" — an official iOS invocation. Opens the app and
/// starts listening through the same idempotent coordinator. Users can also
/// run it from a personal shortcut they name after their assistant (for
/// example "Jarvis"), from the Action button, or from Back Tap.
struct StartConversationIntent: AppIntent {
  static var title: LocalizedStringResource = "Start Conversation"
  static var description = IntentDescription("Opens AutoLoom Media Glasses and starts listening.")
  static var openAppWhenRun: Bool = true

  @MainActor
  func perform() async throws -> some IntentResult {
    _ = await VoiceStartCoordinator.shared.request(.siriShortcut)
    return .result()
  }
}

struct AutoLoomShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: StartConversationIntent(),
      phrases: [
        "Start \(.applicationName)",
        "Talk to \(.applicationName)",
        "Open \(.applicationName) conversation",
      ],
      shortTitle: "Start Conversation",
      systemImageName: "waveform")
  }
}

/// What hands-free invocation this build can really do. Shown in Settings so
/// the UI never claims more than the platforms allow.
enum HandsFreeCapabilities {
  static let metaInvocationAvailable = false
  static let metaInvocationPhrase = "Hey Meta, start <app name registered in the Meta Developer Center>"
  static let metaInvocationRequirement =
    "Needs Meta Wearables DAT 1.0 (this build uses 0.4.0), glasses firmware V128 and Meta AI app V290 " +
    "(rollout from 2026-09-30), and Voice Invocation approval in the Wearables Developer Center."
  static let customWakeWordSupported = false
  static let siriPhrase = "Hey Siri, start AutoLoom"
}
