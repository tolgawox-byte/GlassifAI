import Foundation
import XCTest

@testable import GlassifAI

/// Plan 2.4: more than one iPhone action can wait for the user. A spoken
/// yes, no or time choice answers the newest; each card (the Assistant
/// screen, the approvals inbox) answers only its own; nothing is approved in
/// bulk, and an expired one cannot be approved.
@MainActor
final class AutoLoomApprovalQueueTests: XCTestCase {
  func testEachCardAnswersItsOwnActionAndAYesTheNewest() async throws {
    let orchestrator = AssistantOrchestrator.shared
    orchestrator.clearPendingActions()
    defer { orchestrator.clearPendingActions() }
    let store = MemoryStore.shared
    let marker = UUID().uuidString.prefix(6).lowercased()
    let first = try XCTUnwrap(store.addNote(title: nil, content: "Kuyruk bir \(marker)", source: "test"))
    let second = try XCTUnwrap(store.addNote(title: nil, content: "Kuyruk iki \(marker)", source: "test"))
    let firstID = first.id
    let secondID = second.id
    defer {
      for id in [firstID, secondID] {
        if let left = store.notes.first(where: { $0.id == id }) { store.deleteNote(left) }
      }
    }
    var deleteFirst = DeviceActionPlan(kind: .deleteNote)
    deleteFirst.noteID = firstID
    deleteFirst.text = "Kuyruk bir"
    var deleteSecond = DeviceActionPlan(kind: .deleteNote)
    deleteSecond.noteID = secondID
    deleteSecond.text = "Kuyruk iki"
    _ = await orchestrator.stage(deleteFirst)
    _ = await orchestrator.stage(deleteSecond)
    XCTAssertEqual(orchestrator.waitingActions.count, 2, "the second request did not replace the first")
    XCTAssertEqual(orchestrator.pendingAction?.plan.noteID, secondID, "a spoken answer is about the newest")

    // The older card's own button: only its note is deleted.
    let older = try XCTUnwrap(orchestrator.waitingActions.last)
    XCTAssertEqual(older.plan.noteID, firstID)
    _ = await orchestrator.confirmPendingAction(byVoice: false, id: older.id)
    XCTAssertFalse(store.notes.contains { $0.id == firstID }, "the tapped card's note is deleted")
    XCTAssertTrue(store.notes.contains { $0.id == secondID }, "the other one still waits")
    let again = await orchestrator.confirmPendingAction(byVoice: false, id: older.id)
    XCTAssertEqual(again, "There is no action waiting for confirmation.", "an answered card cannot answer twice")

    // A spoken yes answers the newest, which is now the only one.
    _ = await orchestrator.confirmPendingAction(byVoice: true)
    XCTAssertFalse(store.notes.contains { $0.id == secondID })
    XCTAssertNil(orchestrator.pendingAction)
  }

  func testANoAndACardsCancelTouchOnlyTheirOwn() async {
    let orchestrator = AssistantOrchestrator.shared
    orchestrator.clearPendingActions()
    defer { orchestrator.clearPendingActions() }
    var call = DeviceActionPlan(kind: .call)
    call.phone = "+16135550100"
    var link = DeviceActionPlan(kind: .openURL)
    link.url = URL(string: "https://example.com/queue")
    var message = DeviceActionPlan(kind: .message)
    message.text = "Geliyorum"
    for plan in [call, link, message] { _ = await orchestrator.stage(plan) }
    XCTAssertEqual(orchestrator.waitingActions.map(\.plan.kind), [.message, .openURL, .call], "newest first")

    let reply = await orchestrator.confirmPendingAction(byVoice: true)
    XCTAssertTrue(reply.contains("spoken yes is not enough"), reply)
    XCTAssertEqual(orchestrator.waitingActions.count, 3, "nothing was approved")

    let middle = orchestrator.waitingActions[1]
    orchestrator.cancelPendingAction(id: middle.id)
    XCTAssertEqual(orchestrator.waitingActions.map(\.plan.kind), [.message, .call])
    XCTAssertEqual(orchestrator.cancelPendingAction(id: middle.id), "There was no action waiting.")

    orchestrator.cancelPendingAction()
    XCTAssertEqual(orchestrator.waitingActions.map(\.plan.kind), [.call], "\"hayır\" cancels the newest only")
    orchestrator.completeTapAction("The call screen opened", id: orchestrator.pendingAction?.id)
    XCTAssertTrue(orchestrator.waitingActions.isEmpty)
  }

  func testTheQueueHoldsFiveAndTheSameRequestOnce() {
    let orchestrator = AssistantOrchestrator.shared
    orchestrator.clearPendingActions()
    defer { orchestrator.clearPendingActions() }
    func link(_ path: String) -> PendingDeviceAction {
      var plan = DeviceActionPlan(kind: .openURL)
      plan.url = URL(string: "https://example.com/\(path)")
      return PendingDeviceAction(plan: plan)
    }
    for index in 0..<7 { orchestrator.enqueuePending(link("\(index)")) }
    XCTAssertEqual(orchestrator.waitingActions.count, AssistantOrchestrator.pendingLimit)
    XCTAssertEqual(orchestrator.waitingActions.first?.plan.url?.lastPathComponent, "6", "newest first")
    XCTAssertEqual(orchestrator.waitingActions.last?.plan.url?.lastPathComponent, "2", "the two oldest were dropped")
    orchestrator.enqueuePending(link("6"))
    XCTAssertEqual(orchestrator.waitingActions.count, AssistantOrchestrator.pendingLimit, "the same request is kept once")
  }

  func testAnExpiredActionCannotBeApproved() async {
    let orchestrator = AssistantOrchestrator.shared
    orchestrator.clearPendingActions()
    defer { orchestrator.clearPendingActions() }
    var plan = DeviceActionPlan(kind: .openURL)
    plan.url = URL(string: "https://example.com/old")
    let old = PendingDeviceAction(plan: plan, createdAt: Date().addingTimeInterval(-(PendingDeviceAction.lifetime + 1)))
    orchestrator.enqueuePending(old)
    XCTAssertNil(orchestrator.pendingAction)
    XCTAssertTrue(orchestrator.waitingActions.isEmpty)
    let reply = await orchestrator.confirmPendingAction(byVoice: false, id: old.id)
    XCTAssertEqual(reply, "There is no action waiting for confirmation.")
  }
}
