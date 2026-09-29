import AppIntents
import Foundation

/// "New AutoLoom task": an AutoLoom task without opening the app.
struct CreateAutoLoomTaskIntent: AppIntent {
  static var title: LocalizedStringResource = "Create AutoLoom Task"
  static var description = IntentDescription("Adds a task to AutoLoom Media Glasses on this iPhone.")
  static var openAppWhenRun: Bool = false

  @Parameter(title: "Task", requestValueDialog: "What is the task?")
  var taskTitle: String

  @Parameter(title: "Due")
  var due: Date?

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    guard let task = MemoryStore.shared.addTask(title: taskTitle, dueAt: due, dueHasTime: due != nil, source: "shortcut") else {
      return .result(dialog: "The task could not be saved.")
    }
    return .result(dialog: "Added \"\(task.title)\" to AutoLoom tasks.")
  }
}

/// "Remember this in AutoLoom": a memory, only because the user asked.
struct RememberInAutoLoomIntent: AppIntent {
  static var title: LocalizedStringResource = "Remember This"
  static var description = IntentDescription("Saves something to AutoLoom memory on this iPhone.")
  static var openAppWhenRun: Bool = false

  @Parameter(title: "What to remember", requestValueDialog: "What should AutoLoom remember?")
  var text: String

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    guard MemoryStore.shared.isEnabled else {
      return .result(dialog: "Memory is turned off in AutoLoom.")
    }
    guard let record = MemoryStore.shared.remember(text, source: "shortcut") else {
      return .result(dialog: "It could not be saved.")
    }
    return .result(dialog: "Remembered: \(record.text)")
  }
}

/// "Start a dealer session": opens the app on a new vehicle.
struct StartDealerSessionIntent: AppIntent {
  static var title: LocalizedStringResource = "Start Dealer Session"
  static var description = IntentDescription("Starts a new vehicle in AutoLoom's Dealer Mode.")
  static var openAppWhenRun: Bool = true

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    DealerStore.shared.start()
    return .result(dialog: "New vehicle started. Say “VIN oku” to read the VIN.")
  }
}

/// "Today's briefing": tasks, reminders and the calendar, read on the phone.
struct TodaysBriefingIntent: AppIntent {
  static var title: LocalizedStringResource = "Today's Briefing"
  static var description = IntentDescription("Your AutoLoom tasks, reminders and calendar for today.")
  static var openAppWhenRun: Bool = false

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    let outcome = await AssistantOrchestrator.shared.runVoiceIntent(
      VoiceBridgeDecision(.dayPlan(.today), "shortcut"), transcript: "Today's briefing")
    return .result(dialog: "\(String(outcome.reply.prefix(600)))")
  }
}

/// "Add to my AutoLoom shopping list".
struct AddToShoppingListIntent: AppIntent {
  static var title: LocalizedStringResource = "Add to Shopping List"
  static var description = IntentDescription("Adds items to the AutoLoom shopping list on this iPhone.")
  static var openAppWhenRun: Bool = false

  @Parameter(title: "Items", requestValueDialog: "What should I add?")
  var items: String

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    let added = ShoppingListStore.shared.add(ShoppingListStore.split(items))
    guard !added.isEmpty else { return .result(dialog: "Those are already on the list.") }
    return .result(dialog: "Added \(added.map(\.text).joined(separator: ", ")).")
  }
}
