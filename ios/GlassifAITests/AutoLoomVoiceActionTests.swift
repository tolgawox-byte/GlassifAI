import Foundation
import XCTest

@testable import GlassifAI

/// The voice action bridge (LEVEL 1 parser), local tasks, the profile,
/// conversation memory, connection feedback and Jarvis Style.
@MainActor
final class AutoLoomVoiceActionTests: XCTestCase {
  private let calendar = Calendar.current

  private func local(_ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
    calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
  }

  /// Sunday 27 September 2026, 20:00 local time.
  private var now: Date { local(9, 27, 20) }

  private func decide(_ text: String, _ context: VoiceBridgeContext = VoiceBridgeContext()) -> VoiceIntent? {
    var context = context
    context.assistantName = "Jarvis"
    return VoiceActionIntentBridge.decide(text, context: context, now: now)?.intent
  }

  // MARK: Notes

  func testSpokenNotesAreRecognised() {
    XCTAssertEqual(decide("Jarvis, not al: cuma Mercedes gelecek."), .saveNote(text: "Cuma Mercedes gelecek"))
    XCTAssertEqual(decide("Mercedes cuma gelecek, bunu not al"), .saveNote(text: "Mercedes cuma gelecek"))
    XCTAssertEqual(decide("Şunu not et: yarın lastikler değişecek"), .saveNote(text: "Yarın lastikler değişecek"))
    XCTAssertEqual(decide("take a note: buy tires"), .saveNote(text: "Buy tires"))
    var context = VoiceBridgeContext()
    context.lastAssistantText = "Kanada'da bu model 1.299 dolar."
    XCTAssertEqual(decide("bunu not olarak kaydet", context), .saveNote(text: "Kanada'da bu model 1.299 dolar."))
    XCTAssertEqual(decide("not al"), .ask(.note))
    context = VoiceBridgeContext()
    context.awaiting = .note
    XCTAssertEqual(decide("cuma Mercedes gelecek", context), .saveNote(text: "Cuma Mercedes gelecek"))
  }

  func testOrdinarySpeechIsLeftToTheVoiceModel() {
    XCTAssertNil(decide("Bugün hava nasıl?"))
    XCTAssertNil(decide("Not almak için hangi uygulama iyi?"))
    XCTAssertNil(decide("Ahmet'e mesaj yaz"))
    XCTAssertNil(decide("Adım atmak istiyorum"), "\"adım\" is also \"step\"")
    XCTAssertNil(decide("Bunu bana hatırlatma"), "a negative is not a request")
    var addressed = VoiceBridgeContext()
    addressed.addressedOnly = true
    XCTAssertNil(decide("not al: toplantı cuma", addressed), "addressed-only mode needs the name")
    XCTAssertEqual(decide("Jarvis, not al: toplantı cuma", addressed), .saveNote(text: "Toplantı cuma"))
  }

  // MARK: Reminders, notifications, tasks and the calendar

  func testRemindersKeepTheSpokenTimeAndAClearTitle() throws {
    guard case .createReminder(let title, let time)? = decide("yarın saat 10'da patronu aramamı hatırlat") else {
      return XCTFail("expected a reminder")
    }
    XCTAssertEqual(title, "Patronu ara")
    let parsed = try XCTUnwrap(time)
    XCTAssertEqual(parsed.date, local(9, 28, 10))
    XCTAssertFalse(parsed.isAmbiguous, "10 o'clock means the morning")

    guard case .notify(let notifyTitle, let notifyTime)? = decide("20 dakika sonra bana haber ver") else {
      return XCTFail("expected a notification")
    }
    XCTAssertNil(notifyTitle)
    XCTAssertEqual(notifyTime.date, now.addingTimeInterval(20 * 60))

    var context = VoiceBridgeContext()
    context.previousUserText = "Lastikleri değiştirmem lazım"
    guard case .createReminder(let again, let evening)? = decide("akşam bunu tekrar hatırlat", context) else {
      return XCTFail("expected a reminder from the conversation")
    }
    XCTAssertEqual(again, "Lastikleri değiştirmem lazım")
    XCTAssertEqual(evening?.hasTime, true)

    XCTAssertEqual(decide("süt almayı hatırlat"), .ask(.reminderTime(title: "Süt al")))
    guard case .createReminder(let english, let englishTime)? = decide("remind me to call mom tomorrow at 9") else {
      return XCTFail("expected an English reminder")
    }
    XCTAssertEqual(english, "Call mom")
    XCTAssertEqual(englishTime?.date, local(9, 28, 9))
    XCTAssertNil(decide("hava değişince haber ver"), "no time: not something the phone can schedule")
  }

  func testTasksAndEvents() throws {
    guard case .createTask(let title, let time)? = decide("yarın bu arabayı tekrar kontrol et görev oluştur") else {
      return XCTFail("expected a task")
    }
    XCTAssertEqual(title, "Bu arabayı tekrar kontrol et")
    XCTAssertEqual(time?.date, local(9, 28, 0))
    XCTAssertEqual(time?.hasTime, false)

    var context = VoiceBridgeContext()
    context.previousUserText = "yarın lastikleri değiştirmem lazım"
    guard case .createTask(let fromContext, let contextTime)? = decide("bunu görev olarak ekle", context) else {
      return XCTFail("expected a task from the conversation")
    }
    XCTAssertEqual(fromContext, "Yarın lastikleri değiştirmem lazım")
    XCTAssertEqual(contextTime?.date, local(9, 28, 0))

    guard case .createEvent(let event, let eventTime)? = decide("cuma 3'e toplantı ekle") else {
      return XCTFail("expected an event")
    }
    XCTAssertEqual(event, "Toplantı")
    let friday = try XCTUnwrap(eventTime)
    XCTAssertEqual(friday.date, local(10, 2, 15))
    XCTAssertFalse(friday.isAmbiguous, "a meeting at 3 is in the afternoon")

    XCTAssertEqual(decide("bugün takvimimde ne var?"), .readCalendar(.today))
    XCTAssertEqual(decide("yarın ne var?"), .readCalendar(.tomorrow))
    XCTAssertEqual(decide("görevlerim neler"), .listTasks)
    XCTAssertEqual(decide("İşe başlıyorum"), .routine(.startWork))
  }

  func testTimePhrasesForCommonMeetingHours() throws {
    let friday = try XCTUnwrap(TimePhraseParser.parse("cuma 3'e", now: now))
    XCTAssertEqual(friday.date, local(10, 2, 15))
    let ten = try XCTUnwrap(TimePhraseParser.parse("saat 10'da", now: now))
    XCTAssertFalse(ten.isAmbiguous)
    XCTAssertEqual(ten.date, local(9, 28, 10))
    XCTAssertTrue(try XCTUnwrap(TimePhraseParser.parse("yarın 7'de", now: now)).isAmbiguous, "7 is still asked")
    XCTAssertNil(TimePhraseParser.parse("3'e böl", now: now), "a dative number alone is not a time")
  }

  // MARK: Memory and profile

  func testMemoryCommands() {
    XCTAssertEqual(decide("Benim adım Tolga."), .setName("Tolga"))
    XCTAssertEqual(decide("My name is Tolga"), .setName("Tolga"))
    XCTAssertEqual(decide("Benim adım ne?"), .askName)
    XCTAssertEqual(
      decide("Arabamın P2 katında olduğunu unutma"),
      .saveMemory(text: "Arabamın P2 katında olduğunu", kind: nil))
    XCTAssertEqual(decide("unutma: kapı kodu 4512"), .saveMemory(text: "Kapı kodu 4512", kind: nil))
    XCTAssertEqual(decide("kapı kodunu unut"), .forgetMemory("kapı kodunu"))
    XCTAssertEqual(decide("Arabamı nereye park etmiştim?"), .recallMemory("Arabamı nereye park etmiştim"))
    if case .recallConversation? = decide("Geçen gün Ray-Ban kamerasıyla ne yapıyorduk?") {} else {
      XCTFail("expected a question about an earlier conversation")
    }

    var visual = VoiceBridgeContext()
    visual.visualMemoryAvailable = true
    visual.cameraAvailable = true
    if case .visualMemory? = decide("bunu hatırla", visual) {} else { XCTFail("\"bunu hatırla\" looks at the view") }
    if case .visualMemory? = decide("anahtarımı buraya bıraktığımı hatırla", visual) {} else {
      XCTFail("a place to remember is a visual memory")
    }
    var textOnly = VoiceBridgeContext()
    textOnly.previousUserText = "Arabam P2 katında"
    XCTAssertEqual(decide("bunu hatırla", textOnly), .saveMemory(text: "Arabam P2 katında", kind: nil))
    XCTAssertEqual(decide("hatırla"), .ask(.memory))
  }

  // MARK: Confirmation

  func testAnswersToAPendingAction() {
    var plan = DeviceActionPlan(kind: .createReminder)
    plan.title = "Koşu"
    plan.date = local(9, 28, 7)
    plan.alternativeDate = local(9, 28, 19)
    var context = VoiceBridgeContext()
    context.pendingPlan = plan
    XCTAssertEqual(decide("akşam", context), .choosePendingTime(local(9, 28, 19)))
    XCTAssertEqual(decide("sabah olan", context), .choosePendingTime(local(9, 28, 7)))
    XCTAssertEqual(decide("evet", context), .confirmPending(true))
    XCTAssertEqual(decide("Evet, kaydet", context), .confirmPending(true))
    XCTAssertEqual(decide("hayır", context), .confirmPending(false))
    XCTAssertNotEqual(decide("Tamam peki hava nasıl", context), .confirmPending(true), "a new question is not a yes")
  }

  func testCommandStartsAreSpottedEarly() {
    XCTAssertTrue(VoiceActionIntentBridge.looksLikeCommandStart("Jarvis not al", assistantName: "Jarvis"))
    XCTAssertTrue(VoiceActionIntentBridge.looksLikeCommandStart("hey jarvis benim adım", assistantName: "Jarvis"))
    XCTAssertFalse(VoiceActionIntentBridge.looksLikeCommandStart("Bugün hava", assistantName: "Jarvis"))
  }

  // MARK: Execution

  func testSpokenNoteAndTaskAreSavedBeforeTheConfirmation() async throws {
    let orchestrator = AssistantOrchestrator.shared
    let store = MemoryStore.shared
    let marker = "Mercedes\(UUID().uuidString.prefix(6))"
    let decision = try XCTUnwrap(VoiceActionIntentBridge.decide(
      "Jarvis, not al: cuma \(marker) gelecek.", context: VoiceBridgeContext(), now: now))
    let outcome = await orchestrator.runVoiceIntent(decision, transcript: "not al")
    XCTAssertNil(outcome.failed)
    XCTAssertTrue(outcome.spoken.contains("Tamam, not aldım."))
    let note = try XCTUnwrap(store.notes.first { $0.content.contains(marker) }, "saved before speaking")
    store.deleteNote(note)

    let task = VoiceBridgeDecision(.createTask(title: "Lastik \(marker)", time: nil), "test")
    let taskOutcome = await orchestrator.runVoiceIntent(task, transcript: "görev oluştur")
    XCTAssertNil(taskOutcome.failed)
    let saved = try XCTUnwrap(store.tasks.first { $0.title.contains(marker) }, "the Tasks tab sees it at once")
    store.deleteTask(saved)
    XCTAssertTrue(ActionTraceLog.shared.entries.contains { $0.intent == "createTask" && $0.result.hasPrefix("success") })
  }

  func testActionTraceRedactsNumbers() throws {
    let log = ActionTraceLog.shared
    let id = log.begin(
      transcript: "not al: kapı kodu +90 555 123 45 67",
      decision: VoiceBridgeDecision(.saveNote(text: "x"), "note trigger"))
    log.update(id) {
      $0.executor = "SwiftData"
      $0.result = "success"
    }
    let entry = try XCTUnwrap(log.entries.last)
    XCTAssertEqual(entry.intent, "saveNote")
    XCTAssertTrue(entry.parser.contains("LEVEL 1"))
    XCTAssertFalse(entry.transcript.contains("555"))
    XCTAssertTrue(log.text.contains("executor: SwiftData"))
  }

  // MARK: Store

  private func makeStore(_ defaults: UserDefaults? = nil) -> MemoryStore {
    MemoryStore(inMemory: true, defaults: defaults ?? UserDefaults(suiteName: "autoloom-voice-\(UUID().uuidString)")!)
  }

  func testTasksAreGroupedByDay() throws {
    let store = makeStore()
    let noon = try XCTUnwrap(calendar.date(bySettingHour: 12, minute: 0, second: 0, of: Date()))
    let today = try XCTUnwrap(store.addTask(title: "Bugün", dueAt: noon.addingTimeInterval(3_600), source: "test"))
    _ = try XCTUnwrap(store.addTask(title: "Sonra", dueAt: noon.addingTimeInterval(3 * 86_400), source: "test"))
    let undated = try XCTUnwrap(store.addTask(title: "Tarihsiz", source: "test"))
    XCTAssertEqual(store.todayTasks(now: noon).map(\.title), ["Bugün"])
    XCTAssertEqual(Set(store.upcomingTasks(now: noon).map(\.title)), ["Sonra", "Tarihsiz"])
    XCTAssertEqual(store.tasks.last?.title, "Tarihsiz", "undated tasks come after dated ones")
    store.setCompleted(today, true)
    XCTAssertEqual(store.completedTasks.map(\.title), ["Bugün"])
    XCTAssertTrue(store.todayTasks(now: noon).isEmpty)
    XCTAssertEqual(store.search("sonra").count, 1, "tasks are searchable")
    store.deleteTask(undated)
    XCTAssertEqual(store.tasks.count, 2)
    XCTAssertNil(store.addTask(title: "   ", source: "test"))
  }

  func testProfileNameIsExplicitAndCleaned() {
    let defaults = UserDefaults(suiteName: "autoloom-profile-\(UUID().uuidString)")!
    let store = makeStore(defaults)
    XCTAssertNil(store.profile.preferredName)
    XCTAssertEqual(store.setPreferredName("tolga'yım"), "Tolga")
    XCTAssertEqual(makeStore(defaults).profile.preferredName, "Tolga", "kept across launches")
    XCTAssertNil(UserProfile.cleanName("123 !!"))
    XCTAssertEqual(UserProfile.cleanName("ismail kaya"), "İsmail Kaya")
    store.deleteAllMemories()
    XCTAssertNil(store.profile.preferredName, "clearing memory also forgets the name")
  }

  func testConversationSummariesAreStoredAndRetrievedNotInjected() throws {
    let store = makeStore()
    let summary = ConversationSummary(
      summary: "Ray-Ban kamerasının kilit ekranında durduğunu konuştuk.",
      topics: ["Ray-Ban kamera"],
      decisions: ["HEVC kullanılacak"],
      openTasks: ["Kilit testi yap"],
      entities: ["Ray-Ban"],
      startedAt: Date().addingTimeInterval(-600),
      endedAt: Date())
    let record = try XCTUnwrap(store.saveConversationSummary(summary))
    XCTAssertEqual(record.kind, .conversationSummary)
    XCTAssertTrue(record.text.contains("\n"), "the labelled lists keep their own lines")
    XCTAssertEqual(store.searchConversations("Ray-Ban kamerasıyla ne yapıyorduk").first?.id, record.id)
    XCTAssertFalse(store.promptItems.contains { $0.contains("kilit ekranında") }, "summaries are retrieved, not always sent")
    XCTAssertNotNil(store.recentConversationSummary())
    store.conversationMemoryEnabled = false
    XCTAssertNil(store.saveConversationSummary(summary))
    XCTAssertNil(store.recentConversationSummary())
  }

  func testConversationSummarizer() throws {
    func turn(_ role: ConversationContext.Turn.Role, _ text: String) -> ConversationContext.Turn {
      ConversationContext.Turn(role: role, text: text, at: Date())
    }
    XCTAssertFalse(ConversationSummarizer.isMeaningful([turn(.user, "Merhaba")], actions: 0))
    XCTAssertTrue(ConversationSummarizer.isMeaningful([turn(.user, "Merhaba")], actions: 1))
    XCTAssertTrue(ConversationSummarizer.isMeaningful([
      turn(.user, "Ray-Ban kamerası kilit ekranında neden duruyor acaba"),
      turn(.assistant, "HEVC aktarımıyla devam etmeli."),
      turn(.user, "HEVC ile deneyelim o zaman bakalım"),
    ], actions: 0))
    let decoded = try XCTUnwrap(ConversationSummarizer.decode(
      #"{"summary":"Kamera konuşuldu.","topics":["kamera"],"decisions":[],"open_tasks":["test"],"entities":["Ray-Ban"]}"#,
      startedAt: Date(), endedAt: Date()))
    XCTAssertEqual(decoded.topics, ["kamera"])
    XCTAssertEqual(decoded.openTasks, ["test"])
    XCTAssertNil(ConversationSummarizer.decode(#"{"summary":""}"#, startedAt: Date(), endedAt: Date()))
    XCTAssertTrue(ConversationSummarizer.localSummary([turn(.user, "Hava nasıl?")], startedAt: Date()).summary.contains("Hava nasıl?"))
  }

  // MARK: Connection feedback and voice

  func testConnectionFeedback() throws {
    let key = ConnectionFeedback.defaultsKey
    let saved = UserDefaults.standard.object(forKey: key)
    defer { UserDefaults.standard.set(saved, forKey: key) }
    UserDefaults.standard.removeObject(forKey: key)
    XCTAssertEqual(ConnectionFeedback.current, .chimeAndVoice)
    UserDefaults.standard.set("subtle", forKey: key)
    XCTAssertEqual(ConnectionFeedback.current, .chime, "the earlier setting is kept")
    UserDefaults.standard.set("voice", forKey: key)
    XCTAssertTrue(ConnectionFeedback.current.speaks)
    XCTAssertFalse(ConnectionFeedback.current.playsChime)
    XCTAssertEqual(GreetingStyle.normal.text(turkish: true, custom: ""), "Bağlandım, dinliyorum.")
    XCTAssertEqual(GreetingStyle.minimal.text(turkish: true, custom: ""), "Bağlandım.")
    XCTAssertEqual(ConnectionFeedback.failureText(turkish: true), "Bağlantı kurulamadı.")
    XCTAssertEqual(ConnectionFeedback.glassesLostText(turkish: true), "Ray-Ban bağlantısı koptu.")
    let wav = try XCTUnwrap(ChimePlayer.wav(tones: [(880, 0.1)]))
    XCTAssertEqual(String(decoding: wav.prefix(4), as: UTF8.self), "RIFF")
    XCTAssertEqual(wav.count, 44 + 4_410 * 2)
  }

  func testJarvisStyleIsAStyleNotAClone() {
    let defaults = UserDefaults(suiteName: "autoloom-jarvis-\(UUID().uuidString)")!
    defaults.set("maple", forKey: AssistantPreferences.voiceKey)
    JarvisStyle.setEnabled(true, defaults: defaults)
    XCTAssertEqual(defaults.string(forKey: AssistantPreferences.voiceKey), JarvisStyle.suggestedVoice)
    XCTAssertTrue(VoiceCatalog.isSupported(JarvisStyle.suggestedVoice))
    JarvisStyle.setEnabled(false, defaults: defaults)
    XCTAssertEqual(defaults.string(forKey: AssistantPreferences.voiceKey), "maple", "the earlier voice comes back")

    let text = AssistantInstructions.realtime(
      memory: [], assistantName: "Jarvis", profileName: "Tolga", recentConversation: "27 Eyl: kamera konuşuldu",
      jarvisStyle: true, smartMemory: true)
    XCTAssertTrue(text.contains("Jarvis Style is on"))
    XCTAssertTrue(text.contains("Do not imitate any real actor"))
    XCTAssertTrue(text.contains("The user's name is Tolga"))
    XCTAssertTrue(text.contains("[App message"))
    XCTAssertTrue(text.contains("Smart Memory is on"))
    XCTAssertTrue(text.contains("kamera konuşuldu"))
    XCTAssertTrue(text.contains("Never open with filler"), "no canned opener")
    XCTAssertFalse(text.contains("(\"Tabii\","), "\"Tabii\" is no longer suggested as an opener")
    XCTAssertLessThan(text.utf8.count, 16_000)
    XCTAssertFalse(AssistantInstructions.realtime(memory: [], jarvisStyle: false).contains("Jarvis Style is on"))
  }

  // MARK: Ray-Ban lifecycle

  func testGlassesPipelineStates() {
    XCTAssertEqual(
      GlassesPipelineState.derive(appActive: true, screenLocked: false, streamRunning: false, lastSampleAgeMs: 10),
      .disconnected)
    XCTAssertEqual(
      GlassesPipelineState.derive(appActive: true, screenLocked: false, streamRunning: true, lastSampleAgeMs: nil),
      .foregroundActive)
    XCTAssertEqual(
      GlassesPipelineState.derive(appActive: false, screenLocked: true, streamRunning: true, lastSampleAgeMs: 200),
      .screenLockedStreaming)
    XCTAssertEqual(
      GlassesPipelineState.derive(appActive: false, screenLocked: false, streamRunning: true, lastSampleAgeMs: 200),
      .backgroundStreaming)
    XCTAssertEqual(
      GlassesPipelineState.derive(appActive: false, screenLocked: true, streamRunning: true, lastSampleAgeMs: 5_000),
      .suspended)
    XCTAssertTrue(GlassesPipelineState.screenLockedStreaming.allowsVision)
    XCTAssertFalse(GlassesPipelineState.suspended.allowsVision)
  }
}
