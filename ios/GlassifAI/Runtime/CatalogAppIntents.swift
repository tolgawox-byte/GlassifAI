import AppIntents
import Foundation

/// Every ActionCatalog entry as an App Entity, so Shortcuts, Siri and the
/// Action button can pick any AutoLoom action; they all run through
/// `ActionCatalog.run`, exactly like speech.
struct AutoLoomActionEntity: AppEntity {
  static var typeDisplayRepresentation: TypeDisplayRepresentation = "AutoLoom Action"
  static var defaultQuery = AutoLoomActionQuery()

  var id: String
  var title: String
  var subtitle: String

  init(_ definition: ActionDefinition) {
    id = definition.id
    title = definition.title
    subtitle = definition.displayExamples.first.map { "“\($0)”" } ?? definition.summary
  }

  var displayRepresentation: DisplayRepresentation {
    DisplayRepresentation(title: "\(title)", subtitle: "\(subtitle)")
  }
}

struct AutoLoomActionQuery: EntityQuery {
  func entities(for identifiers: [AutoLoomActionEntity.ID]) async throws -> [AutoLoomActionEntity] {
    identifiers.compactMap { ActionCatalog.definition($0) }.map(AutoLoomActionEntity.init)
  }

  func suggestedEntities() async throws -> [AutoLoomActionEntity] {
    ActionCatalog.all.filter { $0.quick || $0.appIntent != nil }.map(AutoLoomActionEntity.init)
  }
}

/// "Run an AutoLoom action": any catalog action, with optional details (the
/// note text, the item, the search words…).
struct RunAutoLoomActionIntent: AppIntent {
  static var title: LocalizedStringResource = "Run AutoLoom Action"
  static var description = IntentDescription("Runs an AutoLoom action the same way as saying it to the glasses.")
  static var openAppWhenRun: Bool = true

  @Parameter(title: "Action")
  var action: AutoLoomActionEntity

  @Parameter(title: "Details")
  var details: String?

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    var parameters: [String: String] = [:]
    if let details, let first = ActionCatalog.definition(action.id)?.parameters.first {
      parameters[first.name] = details
    }
    let outcome = await ActionCatalog.run(action.id, parameters: parameters, transcript: details)
    return .result(dialog: "\(outcome.said ?? outcome.reply)")
  }
}

/// "Take a Ray-Ban photo": the glasses' camera (never the iPhone's), saved to Photos.
struct TakeRayBanPhotoIntent: AppIntent {
  static var title: LocalizedStringResource = "Take Ray-Ban Photo"
  static var description = IntentDescription("Takes a photo with the Ray-Ban glasses' camera and saves it to Photos.")
  static var openAppWhenRun: Bool = true

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    let outcome = await ActionCatalog.run("camera.photo")
    return .result(dialog: "\(outcome.said ?? outcome.reply)")
  }
}

struct StartRayBanRecordingIntent: AppIntent {
  static var title: LocalizedStringResource = "Start Ray-Ban Recording"
  static var description = IntentDescription("Starts a video recording from the Ray-Ban glasses' camera.")
  static var openAppWhenRun: Bool = true

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    let outcome = await ActionCatalog.run("camera.recordStart")
    return .result(dialog: "\(outcome.said ?? outcome.reply)")
  }
}

struct StopRayBanRecordingIntent: AppIntent {
  static var title: LocalizedStringResource = "Stop Recording"
  static var description = IntentDescription("Stops the Ray-Ban recording and saves the video.")
  static var openAppWhenRun: Bool = false

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    let outcome = await ActionCatalog.run("camera.recordStop")
    return .result(dialog: "\(outcome.said ?? outcome.reply)")
  }
}

/// "Search AutoLoom": notes, tasks, memory, vehicles, captures — on this iPhone.
struct SearchAutoLoomIntent: AppIntent {
  static var title: LocalizedStringResource = "Search AutoLoom"
  static var description = IntentDescription("Searches notes, tasks, memories, vehicles and captures on this iPhone.")
  static var openAppWhenRun: Bool = true

  @Parameter(title: "Search for", requestValueDialog: "What should I look for?")
  var query: String

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    let outcome = await ActionCatalog.run("search.global", parameters: ["query": query])
    return .result(dialog: "\(outcome.reply)")
  }
}

/// "Find a vehicle": the Dealer Mode vehicles that match (stock, VIN, model).
struct FindVehicleIntent: AppIntent {
  static var title: LocalizedStringResource = "Find Vehicle"
  static var description = IntentDescription("Finds a Dealer Mode vehicle by model, stock number or VIN.")
  static var openAppWhenRun: Bool = false

  @Parameter(title: "Vehicle", requestValueDialog: "Which vehicle?")
  var query: String

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    var search = GlobalSearch.parse(query)
    search.kinds = [.vehicle]
    let results = GlobalSearch.run(search, limit: 3)
    guard let first = results.first else { return .result(dialog: "No vehicle matches \"\(query)\".") }
    return .result(dialog: "\(first.title) — \(first.snippet)")
  }
}

/// "Create a vehicle task": a task linked to the active Dealer Mode vehicle.
struct CreateVehicleTaskIntent: AppIntent {
  static var title: LocalizedStringResource = "Create Vehicle Task"
  static var description = IntentDescription("Adds a task linked to the active Dealer Mode vehicle.")
  static var openAppWhenRun: Bool = false

  @Parameter(title: "Task", requestValueDialog: "What should be done?")
  var task: String

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    guard DealerStore.shared.active != nil else { return .result(dialog: "There is no active vehicle in Dealer Mode.") }
    let outcome = await ActionCatalog.run("task.create", parameters: ["title": task])
    return .result(dialog: "\(outcome.said ?? outcome.reply)")
  }
}

/// "Translate what I see": reads the text in view and translates it.
struct StartTranslationIntent: AppIntent {
  static var title: LocalizedStringResource = "Translate What I See"
  static var description = IntentDescription("Reads the text in view and translates it.")
  static var openAppWhenRun: Bool = true

  @Parameter(title: "Into", default: "Turkish")
  var language: String

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    let outcome = await ActionCatalog.run("translation.view", parameters: ["language": language])
    return .result(dialog: "\(outcome.reply)")
  }
}
