import Foundation
import XCTest

@testable import GlassifAI

/// The ActionCatalog is the single source of truth: every production action
/// is complete, every example sentence reaches its action through the same
/// parser speech uses, and nothing else reaches it. Fails CI when an action
/// is added without examples, a policy or a way to run it.
@MainActor
final class AutoLoomActionCatalogTests: XCTestCase {
  /// App Intent types declared in the app (the catalog may only name these).
  private let knownAppIntents: Set<String> = [
    "StartConversationIntent", "AskAutoLoomIntent", "CreateAutoLoomNoteIntent", "StartLiveVisionIntent",
    "CreateAutoLoomTaskIntent", "RememberInAutoLoomIntent", "StartDealerSessionIntent", "TodaysBriefingIntent",
    "AddToShoppingListIntent", "TakeRayBanPhotoIntent", "StartRayBanRecordingIntent", "StopRayBanRecordingIntent",
    "SearchAutoLoomIntent", "FindVehicleIntent", "CreateVehicleTaskIntent", "StartTranslationIntent",
    "RunAutoLoomActionIntent",
  ]

  /// A bridge context for "[tag,tag] sentence" examples.
  static func context(for tags: Set<String>, now: Date = Date()) -> VoiceBridgeContext {
    var context = VoiceBridgeContext()
    context.assistantName = "AutoLoom"
    if tags.contains("pending") {
      var plan = DeviceActionPlan(kind: .createReminder)
      plan.title = "Toplantı"
      plan.date = now.addingTimeInterval(3_600)
      context.pendingPlan = plan
    }
    if tags.contains("ambiguous") {
      var plan = DeviceActionPlan(kind: .createReminder)
      plan.title = "Ahmet'i ara"
      let calendar = Calendar.current
      let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) ?? now
      plan.date = calendar.date(bySettingHour: 7, minute: 0, second: 0, of: tomorrow)
      plan.alternativeDate = calendar.date(bySettingHour: 19, minute: 0, second: 0, of: tomorrow)
      context.pendingPlan = plan
    }
    if tags.contains("tasks") { context.tasksRunning = true }
    if tags.contains("timer") { context.timerRunning = true }
    if tags.contains("recording") { context.isRecording = true }
    if tags.contains("vehicle") { context.activeVehicle = true }
    if tags.contains("live") { context.liveVisionActive = true }
    if tags.contains("routine") { context.routineNames = ["Sabah turu"] }
    if tags.contains("skill") { context.skillNames = ["Notion"] }
    if tags.contains("camera") { context.cameraAvailable = true }
    if tags.contains("visual") {
      context.cameraAvailable = true
      context.visualMemoryAvailable = true
    }
    if tags.contains("answer") { context.lastAssistantText = "Bu ürünün modeli ABC123." }
    if tags.contains("saved") { context.recentSavedText = "Lastikleri kontrol et" }
    if tags.contains("contact") { context.recentContact = "Ahmet" }
    if tags.contains("recent") { context.recentTimedAction = true }
    return context
  }

  private func decide(_ example: String) -> VoiceBridgeDecision? {
    let (tags, text) = ActionCatalog.stripTags(example)
    return VoiceActionIntentBridge.decide(text, context: Self.context(for: tags))
  }

  // MARK: Completeness

  func testEveryActionIsComplete() {
    var problems: [String] = []
    var ids = Set<String>()
    var keys = [String: String]()
    for action in ActionCatalog.all {
      if !ids.insert(action.id).inserted { problems.append("\(action.id): duplicate id") }
      if action.examplesTR.isEmpty { problems.append("\(action.id): no Turkish example") }
      if action.examplesTR.count + action.examplesEN.count < 2 { problems.append("\(action.id): fewer than two examples") }
      if action.ui == nil && action.voiceOnlyReason == nil { problems.append("\(action.id): no UI and no voice-only reason") }
      if action.route == .local && action.keys.isEmpty { problems.append("\(action.id): local route without intent keys") }
      if action.risk != .safe && action.confirmation == .none { problems.append("\(action.id): risky but never confirmed") }
      if let intent = action.appIntent, !knownAppIntents.contains(intent) { problems.append("\(action.id): unknown App Intent \(intent)") }
      if action.name.isEmpty || action.nameTR.isEmpty || action.summary.isEmpty { problems.append("\(action.id): missing names") }
      for key in action.keys {
        if let other = keys[key] { problems.append("\(action.id): key \(key) already belongs to \(other)") }
        keys[key] = action.id
      }
    }
    XCTAssertTrue(problems.isEmpty, "Incomplete actions:\n" + problems.joined(separator: "\n"))
    XCTAssertGreaterThanOrEqual(ActionCatalog.all.count, 80)
  }

  // MARK: Voice parity: examples → the same parser as speech → the action

  func testEveryExampleReachesItsAction() {
    var failures: [String] = []
    for action in ActionCatalog.all where action.route == .local {
      for example in action.examplesTR + action.examplesEN {
        guard let decision = decide(example) else {
          failures.append("\(action.id): \"\(example)\" → nothing")
          continue
        }
        let reached = ActionCatalog.definition(for: decision.intent)?.id ?? decision.intent.catalogKey
        if reached != action.id { failures.append("\(action.id): \"\(example)\" → \(reached) (\(decision.rule))") }
      }
    }
    XCTAssertTrue(failures.isEmpty, "\(failures.count) examples missed:\n" + failures.joined(separator: "\n"))
  }

  func testNegativesDoNotReachTheAction() {
    var failures: [String] = []
    for action in ActionCatalog.all {
      for negative in action.negatives {
        if let decision = decide(negative), ActionCatalog.definition(for: decision.intent)?.id == action.id {
          failures.append("\(action.id): \"\(negative)\" should not reach it")
        }
      }
    }
    XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
  }

  func testDelegatedExamplesAreLeftToTheVoiceModel() {
    var failures: [String] = []
    for action in ActionCatalog.all {
      guard case .delegation = action.route else { continue }
      for example in action.examplesTR + action.examplesEN {
        if let decision = decide(example) {
          if case .classify = decision.intent { continue }
          failures.append("\(action.id): \"\(example)\" was taken by \(decision.intent.catalogKey)")
        }
      }
    }
    XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
  }

  func testConversationExamplesStopOrEnd() {
    for action in ActionCatalog.all where action.route == .conversation {
      for example in action.examplesTR + action.examplesEN {
        XCTAssertNotNil(
          ConversationCommands.classify(example, assistantName: "AutoLoom", assistantSpeaking: true), "\(action.id): \(example)")
      }
    }
  }

  /// §9: stop, recording, photo, note, task, reminder, timer, copy, cancel,
  /// confirm never wait for a model.
  func testHighPriorityCommandsAreDeterministic() {
    let required: Set<String> = [
      "conversation.stop", "camera.recordStop", "camera.photo", "camera.recordStart", "note.create", "task.create",
      "reminder.create", "timer.start", "text.copy", "action.cancel", "action.confirm",
    ]
    for id in required {
      guard let action = ActionCatalog.definition(id) else { return XCTFail("missing \(id)") }
      XCTAssertTrue(action.localPriority, id)
      guard action.route == .local else { continue }
      for example in action.examplesTR {
        XCTAssertEqual(decide(example)?.level, .deterministic, "\(id): \(example)")
      }
    }
  }

  func testEveryIntentHasACatalogEntry() {
    let now = Date()
    let time = TimePhraseParser.parse("yarın 10'da", now: now)!
    let intents: [VoiceIntent] = [
      .confirmPending(true), .confirmPending(false), .choosePendingTime(now), .cancelTasks, .dropAwaiting, .saveNote(text: "x"),
      .listNotes, .searchNotes("x"), .deleteNote(nil), .saveMemory(text: "x", kind: nil), .setName("x"), .askName,
      .recallMemory("x"), .recallConversation("x"), .listMemories, .forgetMemory("x"), .visualMemory("x"),
      .createReminder(title: "x", time: time), .locationReminder(title: "x", place: .home, arriving: true),
      .notify(title: nil, time: time), .createTask(title: "x", time: nil), .createEvent(title: "x", time: time),
      .readCalendar(.today), .listTasks, .completeTask("x"), .moveTask(title: nil, time: time), .dayPlan(.today),
      .translateView(language: "Türkçe"), .call(contact: "x"), .message(contact: "x", body: "y"), .findContact("x"),
      .directions("x"), .nearby("x"), .directionsInView, .copyText(nil), .shareText(nil), .routine(.startWork),
      .routine(.briefing), .routine(.eveningReview), .routine(.weeklyReview), .takePhoto(label: nil, note: nil, caption: nil),
      .startRecording(note: nil), .stopRecording, .recordingStatus, .saveCaptureToPhotos, .undoLast, .readCode,
      .capabilities(nil), .search("x"), .vehicleQuestion(.odometer), .correctPending(time), .graph([]),
      .ask(.note), .ask(.memory), .ask(.task), .ask(.reminderTitle), .ask(.eventTime(title: "x")),
      .timer(.start(seconds: 60, label: nil)), .timer(.cancel), .timer(.remaining), .shopping(.add(["x"])), .shopping(.read),
      .shopping(.remove("x")), .parking(.save(note: nil)), .parking(.recall), .parking(.directions), .parking(.clear), .parking(.saveWithPhoto),
      .findVisual("x"), .findVisual(""), .whatChanged, .document(.summarize), .document(.saveReceipt), .document(.spending),
      .music(.play(nil)), .music(.play("x")), .music(.pause), .music(.next), .music(.previous), .music(.nowPlaying),
      .userRoutine("x"), .remoteAssist(start: true), .remoteAssist(start: false), .skill(server: "x", request: "y"),
      .runShortcut("x"),
    ]
    let dealer: [DealerCommand] = [
      .startVehicle, .nextVehicle, .finishVehicle, .readVIN, .readOdometer, .setOdometer(1, .km), .addDamage("x"),
      .photoChecklist, .deliveryChecklist, .marketResearch, .listing, .summary, .briefing, .saveVehicle, .recallCheck,
      .decodeVIN, .readTire(nil), .readTire("sağ ön"), .readDashboard, .conditionReport, .serviceHandoff, .saveLotSpot,
      .findLotSpot, .readPartNumber, .areaClear("left"), .exportVehicle,
    ]
    for intent in intents + dealer.map({ VoiceIntent.dealer($0) }) {
      XCTAssertNotNil(ActionCatalog.definition(for: intent), "no catalog entry for \(intent.catalogKey)")
    }
  }

  // MARK: Tools, parameters, running

  func testToolSchemasAreValid() {
    let tools = ActionCatalog.toolSchemas()
    XCTAssertTrue(JSONSerialization.isValidJSONObject(tools))
    let names = tools.compactMap { $0["name"] as? String }
    XCTAssertEqual(Set(names).count, names.count, "tool names are unique")
    XCTAssertEqual(ActionCatalog.id(forTool: "note_create"), "note.create")
    XCTAssertFalse(names.contains("conversation_stop"), "conversation control is not a tool")
  }

  func testParametersBuildTheSameIntentsAsSpeech() {
    XCTAssertEqual(ActionCatalog.intent(for: "note.create", parameters: ["text": "süt al"]), .saveNote(text: "Süt al"))
    XCTAssertEqual(ActionCatalog.intent(for: "note.create"), .ask(.note), "no words: the assistant asks")
    XCTAssertEqual(ActionCatalog.intent(for: "timer.start", parameters: ["duration": "10 dakika"]), .timer(.start(seconds: 600, label: nil)))
    XCTAssertEqual(ActionCatalog.intent(for: "shopping.add", parameters: ["items": "süt ve ekmek"]), .shopping(.add(["süt", "ekmek"])))
    XCTAssertEqual(ActionCatalog.intent(for: "dealer.recall"), .dealer(.recallCheck))
    XCTAssertEqual(ActionCatalog.intent(for: "search.global", parameters: ["query": "Corolla"]), .search("Corolla"))
    let iso = ISO8601DateFormatter().string(from: Date().addingTimeInterval(86_400))
    guard case .createTask(let title, let due)? = ActionCatalog.intent(for: "task.create", parameters: ["title": "lastik", "dueISO": iso]) else {
      return XCTFail("task with a due date")
    }
    XCTAssertEqual(title, "Lastik")
    XCTAssertNotNil(due)
  }

  func testCommandLibrarySearchFindsByExample() {
    XCTAssertEqual(ActionCatalog.search("VIN").first?.id, "dealer.readVIN")
    XCTAssertTrue(ActionCatalog.search("fotoğraf").contains { $0.id == "camera.photo" })
    XCTAssertEqual(ActionCatalog.search("").count, ActionCatalog.all.count)
  }

  func testTagsAreStripped() {
    let (tags, text) = ActionCatalog.stripTags("[pending,timer] Ne kadar kaldı?")
    XCTAssertEqual(tags, ["pending", "timer"])
    XCTAssertEqual(text, "Ne kadar kaldı?")
    XCTAssertEqual(ActionCatalog.stripTags("Fotoğraf çek").text, "Fotoğraf çek")
  }
}
