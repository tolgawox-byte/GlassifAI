import AppIntents
import Foundation
import MWDATCore

/// What asked the app to start listening.
enum VoiceStartReason: String {
  case button = "Button"
  case siriShortcut = "Siri / Shortcuts"
  case metaInvocation = "Hey Meta"
  case wakePhrase = "Wake phrase (app open)"
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

/// "Hey Siri, ask AutoLoom": opens the app and asks a typed question; the
/// answer appears on screen with its sources.
struct AskAutoLoomIntent: AppIntent {
  static var title: LocalizedStringResource = "Ask AutoLoom"
  static var description = IntentDescription("Opens AutoLoom Media Glasses and asks a question. The answer appears on screen.")
  static var openAppWhenRun: Bool = true

  @Parameter(title: "Question", requestValueDialog: "What would you like to ask?")
  var question: String

  @MainActor
  func perform() async throws -> some IntentResult {
    AssistantOrchestrator.shared.submitTyped(question)
    return .result()
  }
}

/// "Create a note in AutoLoom": saves an AutoLoom note without opening the
/// app. The note is stored on this iPhone (Memory tab → Notes).
struct CreateAutoLoomNoteIntent: AppIntent {
  static var title: LocalizedStringResource = "Create AutoLoom Note"
  static var description = IntentDescription("Saves a note in AutoLoom Media Glasses on this iPhone.")
  static var openAppWhenRun: Bool = false

  @Parameter(title: "Note", requestValueDialog: "What should the note say?")
  var content: String

  @Parameter(title: "Title")
  var noteTitle: String?

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    guard let note = MemoryStore.shared.addNote(title: noteTitle, content: content, source: "shortcut") else {
      return .result(dialog: "The note could not be saved.")
    }
    return .result(dialog: "Saved \"\(note.title)\" in AutoLoom.")
  }
}

/// Starts a conversation (if needed) and turns Live Vision on.
struct StartLiveVisionIntent: AppIntent {
  static var title: LocalizedStringResource = "Start Live Vision"
  static var description = IntentDescription("Starts a conversation in AutoLoom Media Glasses with Live Vision on.")
  static var openAppWhenRun: Bool = true

  @MainActor
  func perform() async throws -> some IntentResult {
    _ = await VoiceStartCoordinator.shared.request(.siriShortcut)
    let controller = LiveVisionController.shared
    for _ in 0..<40 where !controller.isActive {
      if controller.isVoiceActive() {
        _ = controller.start()
        break
      }
      try? await Task.sleep(nanoseconds: 250_000_000)
    }
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
    AppShortcut(
      intent: AskAutoLoomIntent(),
      phrases: [
        "Ask \(.applicationName)",
        "Ask \(.applicationName) a question",
      ],
      shortTitle: "Ask",
      systemImageName: "text.bubble")
    AppShortcut(
      intent: CreateAutoLoomNoteIntent(),
      phrases: [
        "Create a note in \(.applicationName)",
        "New \(.applicationName) note",
      ],
      shortTitle: "New Note",
      systemImageName: "note.text")
    AppShortcut(
      intent: StartLiveVisionIntent(),
      phrases: [
        "Start live vision in \(.applicationName)",
        "\(.applicationName) live vision",
      ],
      shortTitle: "Live Vision",
      systemImageName: "eye")
  }
}

/// What hands-free invocation this build can really do. Shown in Settings so
/// the UI never claims more than the platforms allow.
enum HandsFreeCapabilities {
  /// This build links DAT 1.0 and listens for "Hey Meta, start …" launches.
  static let metaInvocationAvailable = true
  static let metaInvocationPhrase = "Hey Meta, start <app name registered in the Meta Developer Center>"
  static let metaInvocationRequirement =
    "This DAT \(GlassesSDKInfo.datVersion) build listens for it. Meta only delivers it with glasses firmware V128, Meta AI app V290 " +
    "and Voice Invocation approval for this app in the Wearables Developer Center (not granted in Developer Mode). Experimental."
  /// No system-wide custom wake word exists for third-party apps on iOS or
  /// the Meta glasses. The app's own wake phrase uses on-device recognition
  /// while the app is open, or in the background with Hands-Free Ready.
  static let customWakeWordSupported = false
  static let siriPhrase = "Hey Siri, start AutoLoom"
}


/// "Hey Meta, start AutoLoom" (DAT 1.0 `VoiceInvocationsStream`, experimental).
/// Meta routes a launch only to a registered app whose Voice Invocation
/// permission was approved in the Wearables Developer Center. Each `LaunchApp`
/// is answered at once — Meta AI holds it open until the app replies — and the
/// conversation then starts through the same coordinator as every other start.
@MainActor
final class MetaVoiceInvocationListener: ObservableObject {
  static let shared = MetaVoiceInvocationListener()

  @Published private(set) var status = L.t("Off", "Kapalı")
  @Published private(set) var launches = 0

  private var stream: VoiceInvocationsStream?
  private let tokens = ListenerTokenBag()
  private var listeningOn: DeviceIdentifier?

  private init() {}

  /// Opens the channel (once) and listens on the given glasses; asked again
  /// on every device or registration change.
  func listen(wearables: WearablesInterface, deviceId: DeviceIdentifier?) {
    guard wearables.registrationState == .registered else {
      status = L.t("Waiting for registration", "Kayıt bekleniyor")
      return
    }
    if stream == nil {
      do {
        let created = try VoiceInvocationsStream(wearables: wearables)
        created.invocationsPublisher.listen { invocation in
          Task { @MainActor in await MetaVoiceInvocationListener.shared.answer(invocation) }
        }.store(in: tokens)
        created.errorPublisher.listen { error in
          Task { @MainActor in MetaVoiceInvocationListener.shared.dropped(error.description) }
        }.store(in: tokens)
        stream = created
      } catch {
        status = L.t("Unavailable: ", "Kullanılamıyor: ") + LogSanitizer.sanitize(error.localizedDescription, limit: 120)
        return
      }
    }
    guard let deviceId, deviceId != listeningOn, let stream else { return }
    if listeningOn != nil { stream.stop() }
    listeningOn = nil
    do {
      try stream.start(deviceIdentifier: deviceId)
      listeningOn = deviceId
      status = L.t("Listening (needs Meta approval)", "Dinliyor (Meta onayı gerekir)")
    } catch {
      status = L.t("Not started: ", "Başlamadı: ") + LogSanitizer.sanitize(error.localizedDescription, limit: 120)
    }
  }

  private func answer(_ invocation: any VoiceInvocation) async {
    guard let launch = invocation as? LaunchApp else { return }
    launches += 1
    // Answered before anything else: Meta AI waits for this reply.
    if await launch.responseHandle.sendSuccess(actionOutput: nil) == false {
      NSLog("[AutoLoom] Hey Meta launch: the answer did not deliver")
    }
    _ = await VoiceStartCoordinator.shared.request(.metaInvocation)
  }

  /// A dropped channel is reopened on the next device change.
  private func dropped(_ description: String) {
    status = L.t("Channel error: ", "Kanal hatası: ") + LogSanitizer.sanitize(description, limit: 120)
    listeningOn = nil
  }
}
