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

  func testReminderWithTimeZoneOffsetParses() throws {
    let now = ISO8601DateFormatter().date(from: "2026-09-27T20:00:00-04:00")!
    let result = DeviceActionParser.parse(
      json(["action": "create_reminder", "title": "Buy milk", "when": "2026-09-28T07:00:00-04:00"]), now: now)
    let plan = try result.get()
    XCTAssertEqual(plan.kind, .createReminder)
    XCTAssertEqual(plan.title, "Buy milk")
    XCTAssertEqual(plan.date, ISO8601DateFormatter().date(from: "2026-09-28T11:00:00Z"))
    XCTAssertEqual(plan.kind.risk, .save)
  }

  func testInvalidPlansAreRejectedWithAReason() {
    let now = ISO8601DateFormatter().date(from: "2026-09-27T20:00:00-04:00")!
    XCTAssertEqual(
      DeviceActionParser.parse(json(["action": "create_reminder", "title": "x", "when": "2026-09-01T07:00:00-04:00"]), now: now),
      .failure(.invalid("That time is in the past.")))
    XCTAssertEqual(
      DeviceActionParser.parse(json(["action": "create_event", "title": "Lunch"]), now: now),
      .failure(.missing("when the event is")))
    XCTAssertEqual(
      DeviceActionParser.parse(json([
        "action": "create_event", "title": "Lunch", "when": "2026-09-28T12:00:00-04:00", "end": "2026-09-28T11:00:00-04:00",
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
    let now = ISO8601DateFormatter().date(from: "2026-09-27T20:00:00-04:00")!
    let event = try DeviceActionParser.parse(
      json(["action": "create_event", "title": "Dentist", "when": "2026-09-29 09:30"]), now: now).get()
    XCTAssertEqual(event.endDate?.timeIntervalSince(event.date!), 3_600)
    let call = try DeviceActionParser.parse(json(["action": "call", "phone": "+1 (613) 555-0100", "recipient": "Office"]), now: now).get()
    XCTAssertEqual(call.phone, "+16135550100")
    XCTAssertEqual(call.kind.risk, .needsTap)
  }

  func testRiskLevels() {
    for kind: DeviceActionKind in [.openMaps, .openURL, .shareText, .call, .message] {
      XCTAssertEqual(kind.risk, .needsTap, kind.rawValue)
    }
    for kind: DeviceActionKind in [.createReminder, .createEvent, .saveNote] {
      XCTAssertEqual(kind.risk, .save, kind.rawValue)
    }
    for kind: DeviceActionKind in [.listReminders, .todayEvents, .upcomingEvents, .copyText] {
      XCTAssertEqual(kind.risk, .readOnly, kind.rawValue)
    }
  }

  // MARK: Confirmation

  func testSavesWaitForConfirmationAndRunOnYes() async {
    let orchestrator = AssistantOrchestrator.shared
    orchestrator.cancelPendingAction()
    var plan = DeviceActionPlan(kind: .saveNote)
    plan.title = "Test note \(UUID().uuidString.prefix(6))"
    plan.text = "Parking level P2, spot 14"
    let staged = await orchestrator.stage(plan)
    XCTAssertTrue(staged.speakable.contains("Waiting for confirmation"))
    XCTAssertEqual(orchestrator.pendingAction?.plan, plan)
    let before = AutoLoomNotesStore.shared.notes.count
    let reply = await orchestrator.confirmPendingAction(byVoice: true)
    XCTAssertTrue(reply.contains("Saved as an AutoLoom note"), reply)
    XCTAssertNil(orchestrator.pendingAction)
    XCTAssertEqual(AutoLoomNotesStore.shared.notes.count, before + 1)
    if let note = AutoLoomNotesStore.shared.notes.first(where: { $0.title == plan.title }) {
      AutoLoomNotesStore.shared.delete(note.id)
    }
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
