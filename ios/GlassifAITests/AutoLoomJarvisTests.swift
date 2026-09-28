import XCTest

@testable import GlassifAI

@MainActor
final class AutoLoomJarvisTests: XCTestCase {

  // MARK: Voice selection

  func testVoiceCatalogOffersOnlyTheFramelessVoices() {
    XCTAssertEqual(
      VoiceCatalog.ids, ["juniper", "maple", "spruce", "ember", "vale", "breeze", "arbor", "sol", "cove"],
      "must match RealtimeVoicesList::builtin().v1 (pinned by a native bridge test)")
    for legacy in VoiceCatalog.unsupportedLegacyVoices {
      XCTAssertFalse(VoiceCatalog.isSupported(legacy), legacy)
    }
    XCTAssertEqual(AssistantPreferences.voices, VoiceCatalog.ids)
    XCTAssertEqual(VoiceCatalog.displayName("maple"), "Maple")
  }

  func testStoredLegacyVoiceIsMigratedVisibly() {
    let defaults = UserDefaults(suiteName: "autoloom-voice-\(UUID().uuidString)")!
    defaults.set("alloy", forKey: AssistantPreferences.voiceKey)
    XCTAssertEqual(VoiceCatalog.migrateStoredSelection(defaults), "alloy")
    XCTAssertEqual(defaults.string(forKey: AssistantPreferences.voiceKey), "juniper")
    XCTAssertEqual(defaults.string(forKey: VoiceCatalog.migratedFromKey), "alloy")
    defaults.set("cove", forKey: AssistantPreferences.voiceKey)
    XCTAssertNil(VoiceCatalog.migrateStoredSelection(defaults), "a supported voice is kept")
    XCTAssertEqual(defaults.string(forKey: AssistantPreferences.voiceKey), "cove")
  }

  func testStartLadderKeepsTheSelectedVoiceAsLongAsPossible() {
    XCTAssertEqual(
      RealtimeStartLadder.steps(requestedVoice: "maple", hasResume: true),
      [.full, .withoutResume, .defaultVoice, .baseline])
    XCTAssertEqual(RealtimeStartLadder.steps(requestedVoice: "juniper", hasResume: false), [.full, .baseline])
    XCTAssertTrue(RealtimeStartLadder.shouldSkip(.withoutResume, after: "realtime voice `maple` is not supported"))
    XCTAssertFalse(RealtimeStartLadder.shouldSkip(.defaultVoice, after: "realtime voice `maple` is not supported"))
    XCTAssertTrue(RealtimeStartLadder.reason(from: "400: invalid voice").contains("voice"))
    XCTAssertTrue(RealtimeStartStep.full.keepsSelectedVoice)
    XCTAssertFalse(RealtimeStartStep.baseline.keepsSelectedVoice)
  }

  func testBridgeResultReportsTheAppliedVoice() throws {
    let new = try JSONDecoder().decode(
      EmbeddedCodexResult.self,
      from: Data(#"{"ok":true,"sdp":"v=0","call_id":"c1","voice":"maple","model":"gpt-live-1-codex"}"#.utf8))
    XCTAssertEqual(new.voice, "maple")
    XCTAssertEqual(new.model, "gpt-live-1-codex")
    let old = try JSONDecoder().decode(
      EmbeddedCodexResult.self, from: Data(#"{"ok":false,"error":"boom"}"#.utf8))
    XCTAssertNil(old.voice, "older bridges still decode")
    var report = RealtimeStartReport(requestedVoice: "maple", requestedModel: "gpt-live-1-codex")
    report.activeVoice = "juniper"
    XCTAssertFalse(report.voiceMatches)
  }

  // MARK: Main screen state

  func testPresenceWordsFollowRealState() {
    XCTAssertEqual(AssistantPresence.resolve(state: .disconnected, activity: nil, muted: false), .ready)
    XCTAssertEqual(AssistantPresence.resolve(state: .listening, activity: nil, muted: false), .listening)
    XCTAssertEqual(AssistantPresence.resolve(state: .listening, activity: .seeing, muted: false), .looking)
    XCTAssertEqual(AssistantPresence.resolve(state: .thinking, activity: .remembering, muted: false), .remembering)
    XCTAssertEqual(AssistantPresence.resolve(state: .listening, activity: nil, muted: true), .muted)
    XCTAssertEqual(AssistantPresence.resolve(state: .speaking, activity: nil, muted: false), .speaking)
    XCTAssertEqual(AssistantPresence.resolve(state: .failed("x"), activity: .searching, muted: false), .error("x"))
    XCTAssertEqual(AssistantPresence.speaking.mood, .speaking)
    XCTAssertEqual(AssistantPresence.searching.mood, .searching)
    XCTAssertEqual(AssistantPresence.reading.mood, .looking)
    XCTAssertEqual(AssistantPresence.remembering.mood, .thinking)
  }

  func testFriendlyErrorsHideTechnicalText() {
    XCTAssertEqual(
      FriendlyError.message(for: "The Internet connection appears to be offline.").title,
      L.t("No internet connection", "İnternet bağlantısı yok"))
    XCTAssertEqual(
      FriendlyError.message(for: "Could not start ChatGPT voice. api error 401 Unauthorized").title,
      L.t("Please sign in again", "Yeniden giriş yapın"))
    XCTAssertEqual(
      FriendlyError.message(for: "The voice connection was interrupted. Tap to reconnect.").title,
      L.t("The conversation was interrupted", "Konuşma kesildi"))
    XCTAssertNotEqual(
      FriendlyError.message(for: "ChatGPT rejected the voice").title,
      L.t("The conversation was interrupted", "Konuşma kesildi"),
      "\"voice\" must not be read as an ICE interruption")
  }

  // MARK: Conversation commands

  func testStopWordsSilenceOnlyAnAnswerInProgress() {
    XCTAssertEqual(ConversationCommands.classify("Dur", assistantName: "Jarvis", assistantSpeaking: true), .stopSpeaking)
    XCTAssertEqual(ConversationCommands.classify("bekle bekle", assistantName: "Jarvis", assistantSpeaking: true), .stopSpeaking)
    XCTAssertEqual(
      ConversationCommands.classify("Hayır, öyle değil", assistantName: "Jarvis", assistantSpeaking: true), .stopSpeaking)
    XCTAssertEqual(
      ConversationCommands.classify("Başka bir şey soracağım", assistantName: "Jarvis", assistantSpeaking: true),
      .stopSpeaking)
    XCTAssertNil(ConversationCommands.classify("Dur", assistantName: "Jarvis", assistantSpeaking: false))
    XCTAssertNil(
      ConversationCommands.classify("durum nedir bugün piyasada", assistantName: "Jarvis", assistantSpeaking: true))
  }

  func testEndCommandsEndTheConversation() {
    XCTAssertEqual(ConversationCommands.classify("Kapat", assistantName: "Jarvis", assistantSpeaking: false), .endConversation)
    XCTAssertEqual(
      ConversationCommands.classify("Konuşmayı bitir lütfen", assistantName: "Jarvis", assistantSpeaking: false),
      .endConversation)
    XCTAssertEqual(ConversationCommands.classify("Jarvis stop", assistantName: "Jarvis", assistantSpeaking: false), .endConversation)
    XCTAssertEqual(ConversationCommands.classify("Hey Jarvis, kapat", assistantName: "Jarvis", assistantSpeaking: true), .endConversation)
    XCTAssertEqual(
      ConversationCommands.classify("Jarvis dur", assistantName: "Jarvis", assistantSpeaking: true), .stopSpeaking,
      "during an answer the named stop only stops the answer")
    XCTAssertNil(ConversationCommands.classify("ışığı kapat", assistantName: "Jarvis", assistantSpeaking: false))
    XCTAssertNil(ConversationCommands.classify("stop", assistantName: "Jarvis", assistantSpeaking: false))
  }

  func testQuietTimeoutAndGreetings() {
    XCTAssertTrue(ConversationTimeout.shouldEnd(idle: 31, limit: 30, busy: false))
    XCTAssertFalse(ConversationTimeout.shouldEnd(idle: 31, limit: 30, busy: true))
    XCTAssertFalse(ConversationTimeout.shouldEnd(idle: 9_999, limit: nil, busy: false), "Never means never")
    XCTAssertEqual(ConversationTimeout.never.interval, nil)
    XCTAssertEqual(GreetingStyle.jarvis.text(turkish: true, custom: ""), "Bağlantı hazır. Sizi dinliyorum.")
    XCTAssertEqual(GreetingStyle.custom.text(turkish: true, custom: "  "), nil)
    XCTAssertEqual(GreetingStyle.custom.text(turkish: false, custom: "Ready, boss"), "Ready, boss")
    XCTAssertNil(ConnectionFeedback.readyPhrase(for: .button, turkish: true), "button starts only chime")
  }

  // MARK: Wake phrase

  func testWakePhraseMatchesNaturalTranscripts() {
    XCTAssertTrue(WakePhraseMatcher.matches(phrase: "Hey AutoLoom", in: "hey auto loom what is this"))
    XCTAssertTrue(WakePhraseMatcher.matches(phrase: "Hey AutoLoom", in: "AutoLoom"))
    XCTAssertTrue(WakePhraseMatcher.matches(phrase: "Hey Jarvis", in: "okay Jarvis, neye bakıyorum"))
    XCTAssertTrue(WakePhraseMatcher.matches(phrase: "Jarvis", in: "hey jarvis"))
    XCTAssertFalse(WakePhraseMatcher.matches(phrase: "Jarvis", in: "the jarvisian era"))
    XCTAssertFalse(WakePhraseMatcher.matches(phrase: "Hey AutoLoom", in: "hey there"))
    XCTAssertFalse(WakePhraseMatcher.matches(phrase: "Hi", in: "hi"), "too short to be a wake phrase")
  }

  // MARK: Deterministic time phrases

  private let calendar = Calendar.current

  private func local(_ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0, year: Int = 2026) -> Date {
    calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
  }

  /// Sunday 27 September 2026, 20:00 local time.
  private var now: Date { local(9, 27, 20) }

  func testRelativeTimes() {
    XCTAssertEqual(TimePhraseParser.parse("20 dakika sonra hatırlat", now: now)?.date, now.addingTimeInterval(1_200))
    XCTAssertEqual(TimePhraseParser.parse("yarım saat sonra", now: now)?.date, now.addingTimeInterval(1_800))
    XCTAssertEqual(TimePhraseParser.parse("bir buçuk saat sonra", now: now)?.date, now.addingTimeInterval(5_400))
    XCTAssertEqual(TimePhraseParser.parse("1,5 saat sonra", now: now)?.date, now.addingTimeInterval(5_400))
    XCTAssertEqual(TimePhraseParser.parse("remind me in 2 hours", now: now)?.date, now.addingTimeInterval(7_200))
    XCTAssertEqual(TimePhraseParser.parse("in half an hour", now: now)?.date, now.addingTimeInterval(1_800))
    XCTAssertEqual(TimePhraseParser.parse("3 gün sonra", now: now)?.date, local(9, 30, 0))
    XCTAssertEqual(TimePhraseParser.parse("3 gün sonra", now: now)?.hasTime, false)
  }

  func testTurkishDayAndClock() throws {
    let tomorrowSeven = try XCTUnwrap(TimePhraseParser.parse("yarın saat 7'de", now: now))
    XCTAssertEqual(tomorrowSeven.date, local(9, 28, 7))
    XCTAssertTrue(tomorrowSeven.isAmbiguous)
    XCTAssertEqual(tomorrowSeven.alternative, local(9, 28, 19))

    let evening = try XCTUnwrap(TimePhraseParser.parse("yarın akşam 7'de", now: now))
    XCTAssertEqual(evening.date, local(9, 28, 19))
    XCTAssertFalse(evening.isAmbiguous)

    let morning = try XCTUnwrap(TimePhraseParser.parse("yarın sabah", now: now))
    XCTAssertEqual(morning.date, local(9, 28, 9))
    XCTAssertTrue(morning.usedDefaultTime)

    XCTAssertEqual(TimePhraseParser.parse("cuma akşam 8", now: now)?.date, local(10, 2, 20))
    XCTAssertEqual(TimePhraseParser.parse("cumartesi 10:30", now: now)?.date, local(10, 3, 10, 30))
    XCTAssertEqual(TimePhraseParser.parse("pazartesiye saat 9 buçukta", now: now)?.date, local(9, 28, 9, 30))
    XCTAssertEqual(TimePhraseParser.parse("15 ekim 14:30", now: now)?.date, local(10, 15, 14, 30))
    let dateOnly = try XCTUnwrap(TimePhraseParser.parse("15 Ekim'de", now: now))
    XCTAssertEqual(dateOnly.date, local(10, 15, 0))
    XCTAssertFalse(dateOnly.hasTime)
    XCTAssertTrue(dateOnly.hasDay)
    XCTAssertEqual(TimePhraseParser.parse("gece 2'de", now: now)?.date, local(9, 28, 2))
    XCTAssertEqual(TimePhraseParser.parse("8'e çeyrek kala", now: now)?.date, local(9, 28, 7, 45))
    XCTAssertEqual(TimePhraseParser.parse("saat 3'te", now: now)?.date, local(9, 28, 15))
    XCTAssertEqual(TimePhraseParser.parse("yarın yedide", now: now)?.date, local(9, 28, 7))
    XCTAssertEqual(TimePhraseParser.parse("bugün 13:00", now: now)?.date, local(9, 27, 13), "a past time today stays in the past")
  }

  func testEnglishPhrases() {
    XCTAssertEqual(TimePhraseParser.parse("tomorrow at 7 pm", now: now)?.date, local(9, 28, 19))
    XCTAssertEqual(TimePhraseParser.parse("tomorrow at 7:30am", now: now)?.date, local(9, 28, 7, 30))
    XCTAssertEqual(TimePhraseParser.parse("on October 15 at 2pm", now: now)?.date, local(10, 15, 14))
    XCTAssertEqual(TimePhraseParser.parse("friday evening", now: now)?.date, local(10, 2, 19))
    XCTAssertEqual(TimePhraseParser.parse("tonight at 9", now: now)?.date, local(9, 27, 21))
    XCTAssertEqual(TimePhraseParser.parse("half past 8 tomorrow", now: now)?.date, local(9, 28, 8, 30))
  }

  func testWordsThatAreNotTimes() {
    XCTAssertNil(TimePhraseParser.parse("Bir de süt al", now: now), "\"bir de\" is not 1 o'clock")
    XCTAssertNil(TimePhraseParser.parse("anahtar onda kaldı", now: now), "\"onda\" is not 10 o'clock")
    XCTAssertNil(TimePhraseParser.parse("pazara gidince hatırlat", now: now), "\"pazar\" also means market")
    XCTAssertNil(TimePhraseParser.parse("Salih'i ara", now: now))
    XCTAssertNil(TimePhraseParser.parse("sometime soonish", now: now))
  }

  func testEventEndBelongsToTheStartDay() throws {
    let start = local(9, 28, 12)
    let end = try XCTUnwrap(TimePhraseParser.parse("14:00", now: now))
    XCTAssertEqual(DeviceActionParser.endDate(end, start: start), local(9, 28, 14))
    XCTAssertTrue(DeviceActionParser.looksLikeMachineDate("2026-09-28T07:00:00Z"))
    XCTAssertFalse(DeviceActionParser.looksLikeMachineDate("yarın saat 7"))
  }

  // MARK: Memory

  private func makeStore() -> MemoryStore {
    let defaults = UserDefaults(suiteName: "autoloom-memory-\(UUID().uuidString)")!
    return MemoryStore(inMemory: true, defaults: defaults)
  }

  func testMemoryIsExplicitDedupedAndClassified() throws {
    let store = makeStore()
    XCTAssertTrue(store.isEnabled, "memory is on by default, explicit saving only")
    let parked = try XCTUnwrap(store.remember("Arabamı otoparkın P2 katına park ettim", source: "test"))
    XCTAssertEqual(parked.category, .vehicles)
    XCTAssertEqual(parked.kind, .episode)
    _ = store.remember("arabamı otoparkın p2 katına park ettim", source: "test")
    XCTAssertEqual(store.memories.count, 1, "the same words are refreshed, not duplicated")
    let coffee = try XCTUnwrap(store.remember("I don't like sugar in my coffee, I prefer it black", source: "test"))
    XCTAssertEqual(coffee.kind, .preference)
    XCTAssertEqual(MemoryCategory.classify("Annemin doğum günü 3 Mart"), .people)
    XCTAssertEqual(MemoryCategory.classify("Office address is 100 Queen Street"), .places)
  }

  func testMemorySearchUnderstandsTurkishWordForms() throws {
    let store = makeStore()
    _ = store.remember("Arabamı otoparkın P2 katına park ettim", source: "test")
    _ = store.remember("Kapı kodu 4512", source: "test")
    let hits = store.search("arabam nerede")
    XCTAssertEqual(hits.count, 1)
    if case .memory(let record)? = hits.first?.item {
      XCTAssertTrue(record.text.contains("P2"))
    } else {
      XCTFail("expected the parking memory")
    }
    XCTAssertEqual(store.search("kapının kodu").count, 1)
    XCTAssertTrue(store.search("uçak bileti").isEmpty)
  }

  func testPinnedMemoriesComeFirstAndPromptsStaySmall() throws {
    let store = makeStore()
    for index in 0..<30 {
      _ = store.remember("Fact number \(index) " + String(repeating: "x", count: 150), source: "test")
    }
    let pinned = try XCTUnwrap(store.remember("Wife's name is Ayşe", source: "test"))
    store.setPinned(pinned, true)
    XCTAssertEqual(store.memories.first?.id, pinned.id)
    let prompt = store.promptItems
    XCTAssertEqual(prompt.first, "Wife's name is Ayşe")
    XCTAssertLessThanOrEqual(prompt.count, 12)
    XCTAssertLessThanOrEqual(prompt.joined().count, 1_800)
    store.isEnabled = false
    XCTAssertTrue(store.promptItems.isEmpty)
  }

  func testNotesAndDeletion() throws {
    let store = makeStore()
    let note = try XCTUnwrap(store.addNote(title: nil, content: "Toplantıda bütçe 500 bin olarak konuşuldu", source: "test"))
    XCTAssertFalse(note.title.isEmpty)
    XCTAssertEqual(store.search("bütçe toplantı").count, 1)
    store.deleteNote(note)
    XCTAssertTrue(store.notes.isEmpty)
    _ = store.remember("Temporary", source: "test")
    store.deleteEverything()
    XCTAssertTrue(store.memories.isEmpty)
  }

  func testMemoryRequestsAreParsedDeterministically() {
    XCTAssertEqual(
      MemoryRequest.parse("save: Arabam P2 katında"), .save(text: "Arabam P2 katında", title: nil, kind: nil))
    XCTAssertEqual(MemoryRequest.parse("recall: where I parked"), .recall("where I parked"))
    XCTAssertEqual(MemoryRequest.parse("Forget: kapı kodu"), .forget("kapı kodu"))
    XCTAssertEqual(MemoryRequest.parse("list"), .list)
    XCTAssertNil(MemoryRequest.parse("remember my car is on P2"), "no prefix: a model classifies it")
    XCTAssertNil(MemoryRequest.parse("save:   "))
    XCTAssertEqual(
      MemoryRequest.decodePlan(#"{"operation":"save","text":"Kod 4512","title":"Kapı","kind":"FACT","query":"","reply":""}"#),
      .save(text: "Kod 4512", title: "Kapı", kind: .fact))
    XCTAssertNil(MemoryRequest.decodePlan(#"{"operation":"none","text":"","title":"","kind":"FACT","query":"","reply":""}"#))
  }

  func testVisualMemoryDelegationRoutes() {
    XCTAssertEqual(
      DelegationEnvelopeParser.parse("TASK: visual_memory | QUERY: nereye park ettiğimi hatırla")?.command,
      .task(.visualMemory))
    XCTAssertTrue(AssistantTaskKind.visualMemory.usesCamera)
  }

  // MARK: Vision

  func testUnclearVisionAnswersAreRecognised() {
    XCTAssertTrue(VisionAnswerCheck.suggestsUnclear("I can't read the label from here, please move closer."))
    XCTAssertTrue(VisionAnswerCheck.suggestsUnclear("Etiket net değil, biraz yaklaşır mısın?"))
    XCTAssertFalse(VisionAnswerCheck.suggestsUnclear("The label says Coca-Cola Zero, 330 ml."))
    XCTAssertTrue(VisionAnswerCheck.containsRepositionAdvice("Tilt the label toward the light."))
    let quiet = AssistantInstructions.executor(kind: .vision, detectedLanguage: nil, avoidRepositionAdvice: true)
    XCTAssertTrue(quiet.contains("do not suggest it again"))
    let normal = AssistantInstructions.executor(kind: .vision, detectedLanguage: nil)
    XCTAssertTrue(normal.contains("never a bare \"move closer\""))
  }

  // MARK: Tools and instructions

  func testEveryPlannableActionHasATool() {
    for kind in DeviceActionKind.plannable where kind != .none {
      XCTAssertNotNil(ToolRegistry.tool(for: kind), kind.rawValue)
    }
    XCTAssertEqual(ToolRegistry.tool(for: .call)?.risk, .strongConfirm)
    XCTAssertEqual(ToolRegistry.tool(for: .createReminder)?.risk, .safe)
    XCTAssertEqual(ToolRegistry.tool(for: .forgetMemory)?.risk, .confirm)
    XCTAssertEqual(ToolRegistry.tool(for: .saveNote)?.risk, .safe)
    let defaults = UserDefaults(suiteName: "autoloom-tools-\(UUID().uuidString)")!
    let phone = ToolRegistry.tool(for: .call)!
    XCTAssertTrue(ToolRegistry.allows(.call, defaults: defaults))
    defaults.set(false, forKey: ToolRegistry.enabledKey(phone))
    XCTAssertFalse(ToolRegistry.allows(.call, defaults: defaults))
  }

  func testRealtimeInstructionsAreNaturalAndBounded() {
    let memory = (0..<12).map { "Saved fact \($0) " + String(repeating: "ğ", count: 140) }
    let text = AssistantInstructions.realtime(memory: memory, assistantName: "Jarvis")
    XCTAssertLessThan(text.utf8.count, 16_000, "the bridge truncates instructions above 16 000 bytes")
    XCTAssertTrue(text.contains(AssistantInstructions.taskLine))
    XCTAssertTrue(text.contains("save:"))
    XCTAssertTrue(text.contains("\"dur\""))
    XCTAssertTrue(text.contains("Never save anything to memory unless the user asked"))
    XCTAssertTrue(text.contains("Your name is Jarvis"))
  }

  func testTraceRedactsPersonalDetails() {
    let redacted = TaskTrace.redactUserText("Call +1 (613) 555-0100 and email me@example.com about it", limit: 200)
    XCTAssertFalse(redacted.contains("555-0100"))
    XCTAssertFalse(redacted.contains("me@example.com"))
    XCTAssertTrue(redacted.contains("[number]"))
  }
}
