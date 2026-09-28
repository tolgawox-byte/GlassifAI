import XCTest

@testable import GlassifAI

@MainActor
final class AutoLoomActionTests: XCTestCase {

  // MARK: Guard (no network)

  func testUnsupportedRequestsAreRefusedLocally() {
    XCTAssertNotNil(ActionGuard.blockedReason(for: "send an email to Alex"))
    XCTAssertNotNil(ActionGuard.blockedReason(for: "buy it"))
    XCTAssertNotNil(ActionGuard.blockedReason(for: "delete all my photos"))
    XCTAssertNotNil(ActionGuard.blockedReason(for: "Jarvis, check my GitHub repository"))
    XCTAssertNotNil(ActionGuard.blockedReason(for: "Bunu satın al"))
    XCTAssertTrue(ActionGuard.declineText(reason: "sending email").contains("cannot perform actions"))
  }

  func testOrganizingRequestsAreNotBlockedByTheirSubject() {
    XCTAssertNil(ActionGuard.blockedReason(for: "remind me to buy milk tomorrow"))
    XCTAssertNil(ActionGuard.blockedReason(for: "Jarvis, yarın saat 7'de bana süt almayı hatırlat"))
    XCTAssertNil(ActionGuard.blockedReason(for: "save a note: email the landlord about the lease"))
    XCTAssertNil(ActionGuard.blockedReason(for: "what's on my calendar today"))
    XCTAssertNil(ActionGuard.blockedReason(for: "directions to the Rideau Centre"))
  }

  // MARK: Plan parsing and validation

  private func json(_ fields: [String: String]) -> String {
    var object: [String: String] = [
      "action": "none", "title": "", "notes": "", "when": "", "end": "", "location": "", "url": "",
      "text": "", "recipient": "", "phone": "", "reply": "",
    ]
    for (key, value) in fields { object[key] = value }
    let data = try! JSONSerialization.data(withJSONObject: object)
    return String(data: data, encoding: .utf8)!
  }

  private func local(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
    Calendar.current.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
  }

  func testReminderTimeComesFromTheUsersWords() throws {
    let now = local(2026, 9, 27, 20, 0)
    let plan = try DeviceActionParser.parse(
      json(["action": "create_reminder", "title": "Buy milk", "when": "yarın saat 7'de"]), now: now).get()
    XCTAssertEqual(plan.kind, .createReminder)
    XCTAssertEqual(plan.title, "Buy milk")
    XCTAssertEqual(plan.date, local(2026, 9, 28, 7, 0))
    XCTAssertEqual(plan.alternativeDate, local(2026, 9, 28, 19, 0), "morning or evening is asked, not guessed")
    XCTAssertNotNil(plan.ambiguityNote)
    XCTAssertEqual(plan.kind.risk, .safe, "an explicit reminder is saved at once; only the unclear time is asked")
  }

  func testModelTimestampsAreIgnored() throws {
    let now = local(2026, 9, 27, 20, 0)
    let plan = try DeviceActionParser.parse(
      json(["action": "create_reminder", "title": "Call Ali", "when": "2026-12-01T09:00:00-04:00"]),
      query: "20 dakika sonra Ali'yi aramamı hatırlat", now: now).get()
    XCTAssertEqual(plan.date, now.addingTimeInterval(20 * 60), "the user's words decide, not a model timestamp")
    XCTAssertNil(plan.alternativeDate)
  }

  func testInvalidPlansAreRejectedWithAReason() {
    let now = local(2026, 9, 27, 20, 0)
    XCTAssertEqual(
      DeviceActionParser.parse(json(["action": "create_reminder", "title": "x", "when": "bugün 13:00"]), now: now),
      .failure(.invalid("That time is in the past.")))
    XCTAssertEqual(
      DeviceActionParser.parse(json(["action": "create_reminder", "title": "x", "when": "sometime soonish"]), now: now),
      .failure(.invalid("The time \"sometime soonish\" could not be understood.")))
    XCTAssertEqual(
      DeviceActionParser.parse(json(["action": "create_event", "title": "Lunch"]), now: now),
      .failure(.missing("when the event is")))
    XCTAssertEqual(
      DeviceActionParser.parse(json([
        "action": "create_event", "title": "Lunch", "when": "yarın 12:00", "end": "11:00",
      ]), now: now),
      .failure(.invalid("The event ends before it starts.")))
    if case .success = DeviceActionParser.parse(json(["action": "open_url", "url": "http://192.168.1.1/admin"]), now: now) {
      XCTFail("private network links must never be opened")
    }
    if case .success = DeviceActionParser.parse(json(["action": "call", "phone": "call mom"]), now: now) {
      XCTFail("a phone number is required")
    }
    if case .success = DeviceActionParser.parse(json(["action": "send_email"]), now: now) {
      XCTFail("unknown actions are rejected")
    }
    if case .success = DeviceActionParser.parse("not json", now: now) {
      XCTFail("invalid planner output is rejected")
    }
  }

  func testEventDefaultsToOneHourAndPhoneIsNormalised() throws {
    let now = local(2026, 9, 27, 20, 0)
    let event = try DeviceActionParser.parse(
      json(["action": "create_event", "title": "Dentist", "when": "salı 09:30"]), now: now).get()
    XCTAssertEqual(event.date, local(2026, 9, 29, 9, 30))
    XCTAssertEqual(event.endDate?.timeIntervalSince(event.date!), 3_600)
    let call = try DeviceActionParser.parse(json(["action": "call", "phone": "+1 (613) 555-0100", "recipient": "Office"]), now: now).get()
    XCTAssertEqual(call.phone, "+16135550100")
    XCTAssertEqual(call.kind.risk, .strongConfirm)
  }

  func testRiskLevels() {
    for kind: DeviceActionKind in [.openMaps, .openURL, .shareText, .call, .message] {
      XCTAssertEqual(kind.risk, .strongConfirm, kind.rawValue)
    }
    for kind: DeviceActionKind in [.forgetMemory, .agentTask] {
      XCTAssertEqual(kind.risk, .confirm, kind.rawValue)
    }
    for kind: DeviceActionKind in [.listReminders, .todayEvents, .upcomingEvents, .copyText, .saveNote,
                                   .scheduleNotification, .findContact, .createReminder, .createEvent] {
      XCTAssertEqual(kind.risk, .safe, kind.rawValue)
    }
    XCTAssertFalse(DeviceActionKind.plannable.contains(.forgetMemory), "only the memory flow forgets")
  }

  /// Brief §70–71: camera, web or agent text never triggers a change by
  /// itself. A change the model planned in such a turn waits for a yes.
  func testChangesPlannedAfterUntrustedContentWaitForAYes() {
    for kind: DeviceActionKind in [.createReminder, .createEvent, .saveNote, .scheduleNotification, .copyText] {
      var plan = DeviceActionPlan(kind: kind)
      XCTAssertEqual(plan.risk, .safe, kind.rawValue)
      plan.afterUntrustedContent = true
      XCTAssertEqual(plan.risk, .confirm, kind.rawValue)
    }
    for kind: DeviceActionKind in [.listReminders, .todayEvents, .upcomingEvents, .findContact] {
      var plan = DeviceActionPlan(kind: kind)
      plan.afterUntrustedContent = true
      XCTAssertEqual(plan.risk, .safe, "reading changes nothing: \(kind.rawValue)")
    }
    var call = DeviceActionPlan(kind: .call)
    call.afterUntrustedContent = true
    XCTAssertEqual(call.risk, .strongConfirm, "outbound actions still need a tap")
    for kind: AssistantTaskKind in [.vision, .visionPlusWeb, .visualMemory, .webSearch, .report, .agent] {
      XCTAssertTrue(kind.bringsUntrustedContent, kind.rawValue)
    }
    for kind: AssistantTaskKind in [.generalChat, .deepReasoning, .localMemory, .authorizedAction] {
      XCTAssertFalse(kind.bringsUntrustedContent, kind.rawValue)
    }
  }

  // MARK: Confirmation

  func testNotesAreSavedDirectly() async {
    let orchestrator = AssistantOrchestrator.shared
    orchestrator.cancelPendingAction()
    let store = MemoryStore.shared
    var plan = DeviceActionPlan(kind: .saveNote)
    plan.title = "Test note \(UUID().uuidString.prefix(6))"
    plan.text = "Parking level P2, spot 14"
    let before = store.notes.count
    let staged = await orchestrator.stage(plan)
    XCTAssertTrue(staged.speakable.contains("Saved as an AutoLoom note"), staged.speakable)
    XCTAssertNil(orchestrator.pendingAction, "an explicit note needs no extra confirmation")
    XCTAssertEqual(store.notes.count, before + 1)
    if let note = store.notes.first(where: { $0.title == plan.title }) {
      store.deleteNote(note)
    }
  }

  func testForgettingAMemoryWaitsForAYes() async {
    let orchestrator = AssistantOrchestrator.shared
    orchestrator.cancelPendingAction()
    let store = MemoryStore.shared
    let wasEnabled = store.isEnabled
    store.isEnabled = true
    defer { store.isEnabled = wasEnabled }
    guard let record = store.remember("Test locker code \(UUID().uuidString.prefix(6))", source: "test") else {
      return XCTFail("memory could not be saved")
    }
    var plan = DeviceActionPlan(kind: .forgetMemory)
    plan.memoryID = record.id
    plan.text = record.text
    let staged = await orchestrator.stage(plan)
    XCTAssertTrue(staged.speakable.contains("Waiting for confirmation"))
    XCTAssertNotNil(store.memory(id: record.id), "nothing is forgotten before the yes")
    let reply = await orchestrator.confirmPendingAction(byVoice: true)
    XCTAssertTrue(reply.contains("Forgotten"), reply)
    XCTAssertNil(store.memory(id: record.id))
  }

  func testCallsAndMessagesAreNeverConfirmedByVoice() async {
    let orchestrator = AssistantOrchestrator.shared
    var plan = DeviceActionPlan(kind: .call)
    plan.phone = "+16135550100"
    let staged = await orchestrator.stage(plan)
    XCTAssertTrue(staged.speakable.contains("must tap"))
    let reply = await orchestrator.confirmPendingAction(byVoice: true)
    XCTAssertTrue(reply.contains("spoken yes is not enough"))
    XCTAssertNotNil(orchestrator.pendingAction, "still waiting for a tap")
    XCTAssertTrue(orchestrator.cancelPendingAction().contains("Nothing was saved or sent"))
    XCTAssertNil(orchestrator.pendingAction)
  }

  func testVoiceConfirmationWithNothingPending() async {
    let orchestrator = AssistantOrchestrator.shared
    orchestrator.cancelPendingAction()
    _ = orchestrator.beginVoiceSession()
    let delivered = expectation(description: "delivered")
    var reply = ""
    orchestrator.handleDelegation(handoffID: "test-confirm-\(UUID())", text: "TASK: confirm_action") { text in
      reply = text
      delivered.fulfill()
      return true
    }
    await fulfillment(of: [delivered], timeout: 5)
    XCTAssertTrue(reply.contains("no action waiting"))
    orchestrator.endVoiceSession()
  }

  // MARK: Helpers for tap-confirmed actions

  func testSystemURLsAreBuiltByTheApp() {
    XCTAssertEqual(
      DeviceActionExecutor.mapsURL(for: "Rideau Centre, Ottawa")?.absoluteString,
      "https://maps.apple.com/?daddr=Rideau%20Centre,%20Ottawa&dirflg=d")
    XCTAssertEqual(DeviceActionExecutor.callURL(for: "+16135550100")?.absoluteString, "tel:+16135550100")
    XCTAssertEqual(
      DeviceActionExecutor.messageURL(phone: "+16135550100", body: "On my way")?.absoluteString,
      "sms:+16135550100?body=On%20my%20way")
  }

  func testActionSchemaIsStrict() {
    let schema = AssistantTools.actionSchema.schema
    XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
    let required = schema["required"] as? [String] ?? []
    let properties = (schema["properties"] as? [String: Any])?.keys.sorted() ?? []
    XCTAssertEqual(Set(required), Set(properties), "strict schemas require every property")
    XCTAssertTrue(required.contains("when"))
  }
}
