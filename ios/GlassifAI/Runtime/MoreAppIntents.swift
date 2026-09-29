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
    var parameters = ["title": taskTitle]
    if let due { parameters["dueISO"] = ISO8601DateFormatter().string(from: due) }
    let outcome = await ActionCatalog.run("task.create", parameters: parameters, transcript: taskTitle)
    return .result(dialog: "\(outcome.said ?? outcome.reply)")
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
    let outcome = await ActionCatalog.run("memory.save", parameters: ["text": text], transcript: text)
    return .result(dialog: "\(outcome.said ?? outcome.reply)")
  }
}

/// "Start a dealer session": opens the app on a new vehicle.
struct StartDealerSessionIntent: AppIntent {
  static var title: LocalizedStringResource = "Start Dealer Session"
  static var description = IntentDescription("Starts a new vehicle in AutoLoom's Dealer Mode.")
  static var openAppWhenRun: Bool = true

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    let outcome = await ActionCatalog.run("dealer.start")
    return .result(dialog: "\(outcome.said ?? outcome.reply)")
  }
}

/// "Today's briefing": tasks, reminders and the calendar, read on the phone.
struct TodaysBriefingIntent: AppIntent {
  static var title: LocalizedStringResource = "Today's Briefing"
  static var description = IntentDescription("Your AutoLoom tasks, reminders and calendar for today.")
  static var openAppWhenRun: Bool = false

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    // The briefing (calendar, reminders, tasks, weather when web search is
    // on), the same as saying "günün özeti".
    let outcome = await ActionCatalog.run("routine.briefing", transcript: "Today's briefing")
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
    let outcome = await ActionCatalog.run("shopping.add", parameters: ["items": items], transcript: items)
    return .result(dialog: "\(outcome.said ?? outcome.reply)")
  }
}
