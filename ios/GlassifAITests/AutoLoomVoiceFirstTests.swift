import Foundation
import XCTest

@testable import GlassifAI

/// The voice-first pass: the exact failing note command (brief §66), the
/// speech recogniser's spellings of the name, calls, messages, contacts,
/// maps, clipboard, share, the day plan, follow-up context, early
/// delegations and the store's duplicate guard.
@MainActor
final class AutoLoomVoiceFirstTests: XCTestCase {
  private let calendar = Calendar.current

  private func local(_ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
    calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
  }

  /// Sunday 27 September 2026, 20:00 local time.
  private var now: Date { local(9, 27, 20) }

  private func decide(
    _ text: String,
    _ context: VoiceBridgeContext = VoiceBridgeContext(),
    name: String = "AutoLoom"
  ) -> VoiceIntent? {
    var context = context
    context.assistantName = name
    return VoiceActionIntentBridge.decide(text, context: context, now: now)?.intent
  }

  // MARK: The failing command

  func testTheExactNoteCommandAndTheRecognisersSpellingsOfTheName() {
    let expected = VoiceIntent.saveNote(text: "Yarın kamerayı getireceğim")
    let spoken = [
      "AutoLoom, not al: yarın kamerayı getireceğim.",
      "Autoloom not al yarın kamerayı getireceğim",
      "Auto Loom, not al: yarın kamerayı getireceğim.",
      "Oto lum, not al: yarın kamerayı getireceğim.",
      "Otolum not al, yarın kamerayı getireceğim.",
      "Otoloom, not al: yarın kamerayı getireceğim.",
      "Autolum, not al: yarın kamerayı getireceğim.",
      "Hey AutoLoom, lütfen not al: yarın kamerayı getireceğim.",
      "Tamam AutoLoom, not al: yarın kamerayı getireceğim.",
      "not al: yarın kamerayı getireceğim",
    ]
    for text in spoken {
      XCTAssertEqual(decide(text), expected, text)
    }
    var addressed = VoiceBridgeContext()
    addressed.addressedOnly = true
    XCTAssertEqual(decide("Oto lum, not al: yarın kamerayı getireceğim.", addressed), expected, "a near spelling addresses the assistant")
    XCTAssertNil(decide("not al: yarın kamerayı getireceğim.", addressed), "addressed-only mode still needs the name")
    XCTAssertEqual(decide("Carvis, not al: yarın kamerayı getireceğim.", name: "Jarvis"), expected)
  }

  func testNearNamesDoNotTakeOrdinaryWords() {
    let autoLoom = AddressMatcher.names(assistantName: "AutoLoom")
    let jarvis = AddressMatcher.names(assistantName: "Jarvis")
    XCTAssertEqual(AddressMatcher.phonetic("AutoLoom"), "otolum")
    XCTAssertEqual(AddressMatcher.phonetic("Otoloom"), "otolum")
    XCTAssertEqual(AddressMatcher.phonetic("Carvis"), "jarvis")
    XCTAssertTrue(AddressMatcher.matches("Otolom", names: autoLoom))
    XCTAssertFalse(AddressMatcher.matches("otobüs", names: autoLoom))
    XCTAssertFalse(AddressMatcher.matches("okulum", names: autoLoom))
    XCTAssertFalse(AddressMatcher.matches("Travis", names: jarvis))
    XCTAssertFalse(AddressMatcher.names(assistantName: "Ali").contains("ali"), "short names only match exactly")
    XCTAssertNil(decide("Otobüs kaçta geliyor?"))
    XCTAssertNil(decide("Selam AutoLoom."))
  }

  func testTheFailingCommandIsSavedBeforeTheConfirmation() async throws {
    let orchestrator = AssistantOrchestrator.shared
    let store = MemoryStore.shared
    let marker = "kamera\(UUID().uuidString.prefix(6))"
    var context = VoiceBridgeContext()
    context.assistantName = "AutoLoom"
    let decision = try XCTUnwrap(VoiceActionIntentBridge.decide(
      "Oto lum, not al: yarın \(marker) getireceğim.", context: context, now: now))
    let outcome = await orchestrator.runVoiceIntent(decision, transcript: "not al")
    XCTAssertNil(outcome.failed)
    XCTAssertTrue(outcome.spoken.contains("Tamam, not aldım."))
    let note = try XCTUnwrap(store.notes.first { $0.content.contains(marker) }, "saved before anything is said")
    XCTAssertEqual(orchestrator.actionFeedback?.kind, .note)
    XCTAssertEqual(orchestrator.actionFeedback?.title, L.t("Note saved", "Not kaydedildi"))
    XCTAssertEqual(orchestrator.recentSaved?.text, note.content)
    store.deleteNote(note)
  }

  func testAnEarlyDelegationIsTakenOverNotSkipped() {
    let orchestrator = AssistantOrchestrator.shared
    let ledger = orchestrator.ledger
    let running = ledger.begin(
      sessionID: UUID(), turnID: 1, handoffID: "early-\(UUID())", source: .voiceDelegation, request: "not al")
    XCTAssertEqual(orchestrator.takeOverDelegation(handoffID: running.handoffID ?? ""), .cancelled)
    XCTAssertEqual(ledger.record(running.id)?.cancelled, true, "stopped; the app's result answers it")

    let answered = ledger.begin(
      sessionID: UUID(), turnID: 1, handoffID: "chat-\(UUID())", source: .voiceDelegation, request: "not al")
    ledger.update(answered.id) {
      $0.kind = .generalChat
      $0.phase = .completed
    }
    XCTAssertEqual(
      orchestrator.takeOverDelegation(handoffID: answered.handoffID ?? ""), .completedOther,
      "an answer that saved nothing does not count as the note")

    let acted = ledger.begin(
      sessionID: UUID(), turnID: 1, handoffID: "action-\(UUID())", source: .voiceDelegation, request: "not al")
    ledger.update(acted.id) {
      $0.kind = .authorizedAction
      $0.phase = .completed
    }
    XCTAssertEqual(orchestrator.takeOverDelegation(handoffID: acted.handoffID ?? ""), .completedAction)
    XCTAssertEqual(orchestrator.takeOverDelegation(handoffID: "missing"), .unknown)
  }

  func testFreeTextDelegationsAndExecutorsNeverClaimAnAction() throws {
    let decision = try XCTUnwrap(VoiceActionIntentBridge.decide(
      "not al: yarın kamerayı getireceğim", context: VoiceBridgeContext(), now: now))
    XCTAssertTrue(decision.intent.runsFromDelegation)
    XCTAssertFalse(VoiceIntent.confirmPending(true).runsFromDelegation)
    XCTAssertTrue(AssistantInstructions.executor(kind: nil, detectedLanguage: nil).contains(AssistantInstructions.noActionClaims))
    XCTAssertTrue(AssistantInstructions.executor(kind: .generalChat, detectedLanguage: nil).contains(AssistantInstructions.noActionClaims))
    XCTAssertFalse(AssistantInstructions.executor(kind: .authorizedAction, detectedLanguage: nil).contains(AssistantInstructions.noActionClaims))
  }

  func testTheSameNoteOrTaskTwiceWithinAMinuteIsOne() throws {
    let store = MemoryStore(inMemory: true, defaults: UserDefaults(suiteName: "autoloom-dup-\(UUID().uuidString)")!)
    let first = try XCTUnwrap(store.addNote(title: nil, content: "Yarın kamerayı getireceğim", source: "voice"))
    let second = try XCTUnwrap(store.addNote(title: nil, content: "Yarın kamerayı getireceğim", source: "delegation"))
    XCTAssertEqual(first.id, second.id)
    XCTAssertEqual(store.notes.count, 1)
    XCTAssertNotNil(store.addNote(title: nil, content: "Başka bir not", source: "voice"))
    XCTAssertEqual(store.notes.count, 2)
    let task = try XCTUnwrap(store.addTask(title: "Lastik", source: "voice"))
    XCTAssertEqual(store.addTask(title: "Lastik", source: "voice")?.id, task.id)
    XCTAssertEqual(store.tasks.count, 1)
  }

  // MARK: Paraphrases

  func testNoteParaphrases() {
    let cases: [(String, VoiceIntent)] = [
      ("notlara ekle: lastik basıncı 32", .saveNote(text: "Lastik basıncı 32")),
      ("not olarak yaz: kapı kodu 4512", .saveNote(text: "Kapı kodu 4512")),
      ("bir not yaz, yarın banka", .saveNote(text: "Yarın banka")),
      ("not alsana: süt bitti", .saveNote(text: "Süt bitti")),
      ("şunu kaydet: otopark P2", .saveNote(text: "Otopark P2")),
      ("jot down: call the bank", .saveNote(text: "Call the bank")),
    ]
    for (text, expected) in cases {
      XCTAssertEqual(decide(text), expected, text)
    }
    var answer = VoiceBridgeContext()
    answer.lastAssistantText = "Environment Canada'ya göre yarın 15 derece ve yağmurlu."
    XCTAssertEqual(decide("bunu yaz", answer), .saveNote(text: "Environment Canada'ya göre yarın 15 derece ve yağmurlu."))
    var afterConfirmation = VoiceBridgeContext()
    afterConfirmation.lastAssistantText = "Tamam, not aldım."
    afterConfirmation.previousUserText = "Yarın lastikçiye gideceğim"
    XCTAssertEqual(
      decide("bunu da not al", afterConfirmation), .saveNote(text: "Yarın lastikçiye gideceğim"),
      "\"bunu\" is the last useful answer, not the confirmation")
  }

  func testFollowUpContextNoteThenRelatedTask() throws {
    var context = VoiceBridgeContext()
    context.recentSavedText = "ABC123 numaralı sipariş yarın gelecek"
    context.lastAssistantText = "Tamam, not aldım."
    guard case .createTask(let title, let time)? = decide("Bununla ilgili bir görev oluştur", context) else {
      return XCTFail("expected a task from the note")
    }
    XCTAssertEqual(title, "ABC123 numaralı sipariş yarın gelecek")
    XCTAssertEqual(time?.date, local(9, 28, 0))
    guard case .createReminder(let reminder, _)? = decide("bunu yarın hatırlat", context) else {
      return XCTFail("expected a reminder from the note")
    }
    XCTAssertEqual(reminder, "ABC123 numaralı sipariş yarın gelecek")
  }

  // MARK: Calls, messages, contacts

  func testCalls() {
    XCTAssertEqual(decide("Ahmet'i ara"), .call(contact: "Ahmet"))
    XCTAssertEqual(decide("AutoLoom, Ahmet Yılmaz'ı arar mısın?"), .call(contact: "Ahmet Yılmaz"))
    XCTAssertEqual(decide("Annemi ara"), .call(contact: "Annem"))
    XCTAssertEqual(decide("call Ahmet"), .call(contact: "Ahmet"))
    XCTAssertEqual(decide("call mom"), .call(contact: "Mom"))
    XCTAssertNil(decide("bunu ara"), "a search, not a person")
    XCTAssertNil(decide("Google'da ara"))
    XCTAssertNil(decide("fiyatını internette ara"))
    XCTAssertNil(decide("call it a day"))
    guard case .createReminder? = decide("Yarın 10'a Ahmet'i aramamı hatırlat.") else {
      return XCTFail("a reminder about a call stays a reminder")
    }
  }

  func testMessages() {
    XCTAssertEqual(
      decide("Ahmet'e 10 dakika gecikeceğim diye mesaj yaz"), .message(contact: "Ahmet", body: "10 dakika gecikeceğim"))
    XCTAssertEqual(decide("Ahmet'e mesaj at: 10 dakika gecikeceğim"), .message(contact: "Ahmet", body: "10 dakika gecikeceğim"))
    XCTAssertEqual(decide("Ahmet'e mesaj yaz"), .message(contact: "Ahmet", body: nil))
    XCTAssertEqual(decide("Mesaj yaz"), .message(contact: nil, body: nil))
    XCTAssertEqual(decide("Anneme eve geliyorum diye yaz"), .message(contact: "Annem", body: "Eve geliyorum"))
    XCTAssertEqual(decide("Ayşe Yılmaz'a yarın görüşürüz yaz"), .message(contact: "Ayşe Yılmaz", body: "Yarın görüşürüz"))
    XCTAssertEqual(decide("Mesaj at Ahmet'e: geliyorum"), .message(contact: "Ahmet", body: "Geliyorum"))
    XCTAssertEqual(decide("text Ahmet that I'm late"), .message(contact: "Ahmet", body: "I'm late"))
    var recent = VoiceBridgeContext()
    recent.recentContact = "Ahmet Yılmaz"
    XCTAssertEqual(
      decide("Ona 10 dakika gecikeceğimi de yaz", recent), .message(contact: "Ahmet Yılmaz", body: "10 dakika gecikeceğim"),
      "\"ona\" is the person of the last call or message")
    XCTAssertNil(decide("Ona göre yaz", recent))
    XCTAssertNil(decide("ona 10 dakika gecikeceğimi de yaz"), "nobody to refer to: the voice model asks")
  }

  func testAnswersToTheBridgesQuestions() {
    var asking = VoiceBridgeContext()
    asking.awaiting = .messageBody(contact: "Ahmet")
    XCTAssertEqual(decide("10 dakika gecikeceğim", asking), .message(contact: "Ahmet", body: "10 dakika gecikeceğim"))
    asking.awaiting = .messageRecipient(body: "Geliyorum")
    XCTAssertEqual(decide("Ahmet'e", asking), .message(contact: "Ahmet", body: "Geliyorum"))
    asking.awaiting = .chooseContact(action: .call, names: ["Ahmet Yılmaz", "Ahmet Kaya"])
    XCTAssertEqual(decide("Ahmet Kaya", asking), .call(contact: "Ahmet Kaya"))
    XCTAssertEqual(decide("ikincisi", asking), .call(contact: "Ahmet Kaya"))
    XCTAssertNil(decide("Ahmet", asking), "\"Ahmet\" alone does not choose between two Ahmets")
    XCTAssertEqual(decide("vazgeç", asking), .dropAwaiting)
  }

  func testContactQuestions() {
    XCTAssertEqual(decide("Ahmet'in numarası ne?"), .findContact("Ahmet"))
    XCTAssertEqual(decide("annemin telefon numarası kaç"), .findContact("Annem"))
    XCTAssertEqual(decide("what's Ahmet's number"), .findContact("Ahmet"))
    XCTAssertNotEqual(decide("Ahmet'in numarasını hatırla"), .findContact("Ahmet"), "a memory request")
  }

  func testTurkishEndingsForNames() {
    XCTAssertEqual(TurkishSuffix.dative("Ahmet"), "Ahmet'e")
    XCTAssertEqual(TurkishSuffix.dative("Ayşe"), "Ayşe'ye")
    XCTAssertEqual(TurkishSuffix.dative("Tolga"), "Tolga'ya")
    XCTAssertEqual(TurkishSuffix.dative("Annem"), "Anneme")
    XCTAssertEqual(TurkishSuffix.accusative("Ahmet"), "Ahmet'i")
    XCTAssertEqual(TurkishSuffix.question("Ahmet Kaya"), "mı")
    XCTAssertEqual(TurkishSuffix.question("Ayşe Demir"), "mi")
  }

  // MARK: Maps, clipboard, share, the day

  func testDirections() {
    XCTAssertEqual(decide("AutoLoom, beni eve götür"), .directions("Home"))
    XCTAssertEqual(decide("işe götür"), .directions("Work"))
    XCTAssertEqual(decide("Kadıköy'e yol tarifi aç"), .directions("Kadıköy"))
    XCTAssertEqual(decide("havalimanına nasıl giderim"), .directions("havalimanı"))
    XCTAssertEqual(decide("en yakın benzinliğe götür"), .nearby("benzinlik"))
    XCTAssertEqual(decide("en yakın eczane nerede"), .nearby("eczane"))
    XCTAssertEqual(decide("take me home"), .directions("Home"))
    XCTAssertEqual(decide("navigate to the airport"), .directions("the airport"))
    XCTAssertNil(decide("buraya nasıl giderim"), "needs the camera: the voice model")
    XCTAssertNil(decide("En yakın arkadaşım Ahmet"))
    XCTAssertNil(decide("yol tarifi nasıl alınır"))
    XCTAssertNil(decide("bu işi sonuna kadar götür"))
    XCTAssertEqual(
      VoiceActionIntentBridge.placeName(Utterance("Antalya")!, stripDative: true), "Antalya",
      "a name keeps its ending")
  }

  func testAnAddressFromTheConversation() {
    var context = VoiceBridgeContext()
    context.lastAssistantText = "Kartvizitte Bağdat Caddesi No 12, Kadıköy yazıyor."
    guard case .classify(.authorizedAction, let query)? = decide("bu adrese yol tarifi aç", context) else {
      return XCTFail("the model picks the address out; Maps waits for a tap")
    }
    XCTAssertTrue(query.contains("Bağdat Caddesi"))
    XCTAssertNil(decide("bu adrese yol tarifi aç"), "no address in the conversation")
  }

  func testSavedHomeAddress() throws {
    let store = MemoryStore(inMemory: true, defaults: UserDefaults(suiteName: "autoloom-address-\(UUID().uuidString)")!)
    XCTAssertNil(store.savedAddress(home: true))
    _ = try XCTUnwrap(store.remember("İş adresim Levent Plaza, Beşiktaş", source: "test"))
    XCTAssertNil(store.savedAddress(home: true), "a work address is not home")
    _ = try XCTUnwrap(store.remember("Ev adresim: Bağdat Caddesi 12, Kadıköy", source: "test"))
    XCTAssertEqual(store.savedAddress(home: true), "Bağdat Caddesi 12, Kadıköy")
    XCTAssertEqual(store.savedAddress(home: false), "Levent Plaza, Beşiktaş")
  }

  func testClipboardAndShare() {
    var answer = VoiceBridgeContext()
    answer.lastAssistantText = "Environment Canada'ya göre yarın 15 derece ve yağmurlu."
    XCTAssertEqual(decide("bunu kopyala", answer), .copyText("Environment Canada'ya göre yarın 15 derece ve yağmurlu."))
    XCTAssertEqual(decide("şunu kopyala: 4512"), .copyText("4512"))
    XCTAssertEqual(decide("bunu paylaş", answer), .shareText("Environment Canada'ya göre yarın 15 derece ve yağmurlu."))
    XCTAssertEqual(decide("bunu kopyala"), .copyText(nil), "nothing to copy: said honestly")
    XCTAssertNil(decide("copy that"), "radio talk, not a request")
  }

  func testDayPlan() {
    XCTAssertEqual(decide("Bugün ne yapmam gerekiyor?"), .dayPlan(.today))
    XCTAssertEqual(decide("Yarın ne yapmam lazım"), .dayPlan(.tomorrow))
    XCTAssertEqual(decide("programım ne"), .dayPlan(.today))
    XCTAssertEqual(decide("what does my day look like"), .dayPlan(.today))
    XCTAssertNil(decide("Arabam bozuldu, ne yapmam gerekiyor?"), "advice, not the day's plan")
    XCTAssertEqual(decide("yarın ne var?"), .readCalendar(.tomorrow))
    XCTAssertEqual(decide("görevlerim neler"), .listTasks)
  }

  func testFeedbackLabelsCarryNoContent() {
    var plan = DeviceActionPlan(kind: .createReminder)
    plan.title = "Patronu ara"
    plan.date = local(9, 28, 10)
    let feedback = try? XCTUnwrap(ActionFeedback.saved(plan))
    XCTAssertEqual(feedback?.kind, .reminder)
    XCTAssertFalse(feedback?.line.contains("Patronu") ?? true, "labels and times only")
    XCTAssertTrue(ActionFeedback.when(local(9, 28, 10), hasTime: true, now: now).contains(L.t("Tomorrow", "Yarın")))
    XCTAssertNil(ActionFeedback.saved(DeviceActionPlan(kind: .listReminders)), "reading is not a saved result")
    XCTAssertTrue(VoiceIntent.message(contact: "Ahmet", body: "x").isPrivate)
    XCTAssertEqual(VoiceIntent.message(contact: "Ahmet", body: "x").traceName, "message")
    XCTAssertEqual(VoiceIntent.ask(.messageBody(contact: "Ahmet")).traceName, "ask(messageBody)")
  }
}
