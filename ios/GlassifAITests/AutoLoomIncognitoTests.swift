import Foundation
import XCTest

@testable import GlassifAI

/// Research idea D2-03, incognito ("gizli mod"): while it is on,
/// conversations leave nothing behind on their own, commands said by name
/// still run, and only the user's words or a tap turn it off.
@MainActor
final class AutoLoomIncognitoTests: XCTestCase {
  private func decide(_ text: String) -> VoiceIntent? {
    var context = VoiceBridgeContext()
    context.assistantName = "Jarvis"
    return VoiceActionIntentBridge.decide(text, context: context)?.intent
  }

  /// Leaves the shared mode off for the other tests.
  private func reset() {
    IncognitoSession.shared.end()
    _ = IncognitoSession.shared.conversationFinished()
  }

  func testIncognitoIsSaidInPlainWords() {
    XCTAssertEqual(decide("Gizli modu aç"), .incognito(true))
    XCTAssertEqual(decide("Jarvis, bu konuşmayı kaydetme"), .incognito(true))
    XCTAssertEqual(decide("Gizli moda geç lütfen"), .incognito(true))
    XCTAssertEqual(decide("Go incognito"), .incognito(true))
    XCTAssertEqual(decide("Don't save this conversation"), .incognito(true))
    XCTAssertEqual(decide("Gizli modu kapat"), .incognito(false))
    XCTAssertEqual(decide("Gizli moddan çık"), .incognito(false))
    XCTAssertEqual(decide("Turn off incognito mode"), .incognito(false))
    for other in ["Gizli mod nedir?", "Gizli modu nasıl açarım?", "Bu notu kaydetme"] {
      if case .incognito? = decide(other) { XCTFail("\(other) is not a command") }
    }
  }

  /// "Gizli modu kapat" turns the mode off; it does not end the conversation.
  func testTurningItOffIsNotEndingTheConversation() {
    XCTAssertNil(ConversationCommands.classify("Gizli modu kapat", assistantName: "Jarvis", assistantSpeaking: false))
    XCTAssertNil(ConversationCommands.classify("Jarvis gizli modu kapat", assistantName: "Jarvis", assistantSpeaking: true))
    XCTAssertEqual(ConversationCommands.classify("Kapat", assistantName: "Jarvis", assistantSpeaking: false), .endConversation)
  }

  func testItCoversWholeConversationsAndSurvivesARestart() throws {
    let suite = "autoloom-incognito-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let session = IncognitoSession(defaults: defaults)
    XCTAssertFalse(session.isOn)
    XCTAssertFalse(session.conversationFinished(), "an ordinary conversation keeps its summary")
    session.begin()
    XCTAssertTrue(IncognitoSession(defaults: defaults).isOn, "a restart does not turn it off on its own")
    XCTAssertTrue(session.conversationFinished())
    XCTAssertTrue(session.conversationFinished(), "the next conversation is covered while it stays on")
    session.end()
    XCTAssertTrue(session.conversationFinished(), "turned off mid-conversation: the earlier turns still get no summary")
    XCTAssertFalse(session.conversationFinished(), "the conversation after that is ordinary again")
    XCTAssertFalse(IncognitoSession(defaults: defaults).isOn)
  }

  func testTheEndOfAConversationUsesTheMark() {
    reset()
    defer { reset() }
    let incognito = IncognitoSession.shared
    incognito.begin()
    incognito.end()
    XCTAssertTrue(incognito.coversConversation)
    AssistantOrchestrator.shared.finishConversation()
    XCTAssertFalse(incognito.coversConversation, "the conversation that ended took the mark with it (no summary)")
  }

  func testSavesAreRefusedAndSaidButNamedCommandsRun() async throws {
    reset()
    let orchestrator = AssistantOrchestrator.shared
    let store = MemoryStore.shared
    let wasEnabled = store.isEnabled
    store.isEnabled = true
    defer {
      reset()
      store.isEnabled = wasEnabled
    }
    let on = await orchestrator.runVoiceIntent(VoiceBridgeDecision(.incognito(true), "test"), transcript: "gizli modu aç")
    XCTAssertNil(on.failed)
    XCTAssertTrue(IncognitoSession.shared.isOn)

    let marker = "gizli\(UUID().uuidString.prefix(6).lowercased())"
    let memoriesBefore = store.memories.count
    let memory = await orchestrator.runVoiceIntent(
      VoiceBridgeDecision(.saveMemory(text: "Dolap kodu \(marker)", kind: nil), "test"), transcript: "hatırla")
    XCTAssertEqual(memory.failed, "incognito on")
    XCTAssertTrue(memory.spoken.contains("Incognito mode is on"), memory.spoken)
    XCTAssertEqual(store.memories.count, memoriesBefore)
    XCTAssertFalse(store.memories.contains { $0.text.contains(marker) })

    let nameBefore = store.profile.preferredName
    let name = await orchestrator.runVoiceIntent(VoiceBridgeDecision(.setName("Deniz"), "test"), transcript: "benim adım Deniz")
    XCTAssertEqual(name.failed, "incognito on")
    XCTAssertEqual(store.profile.preferredName, nameBefore)

    // Refused before the camera or a model is asked anything.
    let visual = await orchestrator.runVoiceIntent(VoiceBridgeDecision(.visualMemory("bunu hatırla"), "test"), transcript: "bunu hatırla")
    XCTAssertEqual(visual.failed, "incognito on")

    let note = await orchestrator.runVoiceIntent(
      VoiceBridgeDecision(.saveNote(text: "Not \(marker)"), "test"), transcript: "not al")
    XCTAssertNil(note.failed, "a note asked for by name is still saved")
    let saved = store.notes.first { $0.content.contains(marker) }
    XCTAssertNotNil(saved)
    if let saved { store.deleteNote(saved) }

    let off = await orchestrator.runVoiceIntent(VoiceBridgeDecision(.incognito(false), "test"), transcript: "gizli modu kapat")
    XCTAssertNil(off.failed)
    XCTAssertFalse(IncognitoSession.shared.isOn)
  }

  /// A model or a routine can only make the app more private.
  func testAModelCanOnlyTurnItOn() {
    XCTAssertEqual(ActionCatalog.intent(for: "privacy.incognito"), .incognito(true))
    XCTAssertEqual(ActionCatalog.intent(for: "privacy.incognito", parameters: ["on": "false"]), .incognito(true))
    XCTAssertEqual(ActionCatalog.definition(for: .incognito(false))?.id, "privacy.incognito")
  }

  func testTheVoiceModelIsToldNotToOfferMemory() {
    let text = AssistantInstructions.realtime(memory: [], jarvisStyle: false, smartMemory: false, incognito: true)
    XCTAssertTrue(text.contains("Incognito mode is on"))
    XCTAssertFalse(text.contains("Smart Memory is on"))
    XCTAssertFalse(AssistantInstructions.realtime(memory: [], jarvisStyle: false).contains("Incognito mode is on"))
  }
}
