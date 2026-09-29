import Foundation

/// What the local intent bridge understood from one final user utterance.
/// Explicit commands ("not al", "hatırlat", "görev oluştur", "Ahmet'i ara",
/// "benim adım…") are executed by the app itself instead of depending on the
/// voice model to choose a delegation.
enum VoiceIntent: Equatable {
  /// A question the bridge asked; the next utterance answers it.
  enum Awaiting: Equatable {
    case note
    case memory
    case task
    case reminderTime(title: String)
    /// "Neyi hatırlatayım?" after a bare "hatırlatıcı oluştur".
    case reminderTitle
    case eventTime(title: String)
    /// "Ahmet'e ne yazayım?"
    case messageBody(contact: String)
    /// "Kime yazayım?"
    case messageRecipient(body: String?)
    /// "İki Ahmet buldum: Ahmet Yılmaz mı, Ahmet Kaya mı?"
    case chooseContact(action: ContactAction, names: [String])

    /// For the action trace: the kind of question, never its content.
    var label: String {
      switch self {
      case .note: "note"
      case .memory: "memory"
      case .task: "task"
      case .reminderTime: "reminderTime"
      case .reminderTitle: "reminderTitle"
      case .eventTime: "eventTime"
      case .messageBody: "messageBody"
      case .messageRecipient: "messageRecipient"
      case .chooseContact: "chooseContact"
      }
    }
  }

  /// What to do with a contact once the right one is known.
  enum ContactAction: Equatable {
    case call
    case message(body: String?)
    case find
  }

  enum CalendarRange: String, Equatable {
    case today
    case tomorrow
    case week
  }

  enum Routine: String, Equatable {
    /// "İşe başlıyorum": today's tasks, the next event, Hands-Free Ready.
    case startWork
    /// "Günün özeti": calendar, reminders and tasks.
    case briefing
    /// "Bugün ne yaptım?": what was saved, done and captured today.
    case eveningReview
    /// "Bu hafta ne yaptım?": the same for the last seven days.
    case weeklyReview
  }

  /// Yes or no to an action waiting for confirmation.
  case confirmPending(Bool)
  /// "Sabah" / "akşam" for an action whose time was ambiguous.
  case choosePendingTime(Date)
  case cancelTasks
  /// "Vazgeç" after the bridge asked something.
  case dropAwaiting
  case saveNote(text: String)
  /// "Notlarım neler?"
  case listNotes
  /// "Mercedes için aldığım notları söyle"
  case searchNotes(String)
  /// "Bu notu sil" (nil: the note just saved, else the newest); waits for a yes.
  case deleteNote(String?)
  case saveMemory(text: String, kind: MemoryKind?)
  case setName(String)
  case askName
  case recallMemory(String)
  case recallConversation(String)
  case listMemories
  case forgetMemory(String)
  case visualMemory(String)
  case createReminder(title: String, time: ParsedTime?)
  case notify(title: String?, time: ParsedTime)
  case createTask(title: String, time: ParsedTime?)
  case createEvent(title: String, time: ParsedTime?)
  case readCalendar(CalendarRange)
  case listTasks
  case completeTask(String)
  /// "Bugün ne yapmam gerekiyor?": AutoLoom tasks, Apple Reminders and the
  /// calendar together.
  case dayPlan(CalendarRange)
  /// Read the text in view and translate it (high detail).
  case translateView(language: String)
  /// "Ahmet'i ara": the contact is looked up; the call starts only after a
  /// tap on the phone (iOS asks once more).
  case call(contact: String)
  /// "Ahmet'e 10 dakika gecikeceğim diye mesaj yaz": the message is
  /// prepared in Messages; the user sends it.
  case message(contact: String?, body: String?)
  /// "Ahmet'in numarası ne?"
  case findContact(String)
  /// "Kadıköy'e yol tarifi aç", "beni eve götür" ("Home" and "Work" are the
  /// saved addresses).
  case directions(String)
  /// "En yakın benzinlik": a Maps search around the user.
  case nearby(String)
  /// "Buraya yol tarifi aç" while looking at an address: the camera reads
  /// it, the user checks it, then Maps.
  case directionsInView
  /// "Bunu kopyala": the text, or nil when there is nothing to copy.
  case copyText(String?)
  /// "Bunu paylaş": the share sheet with the text.
  case shareText(String?)
  case routine(Routine)
  /// "Fotoğraf çek", "jantın fotoğrafını çek", "bunun fotoğrafını çek ve not
  /// al: …": a Ray-Ban photo (never the iPhone camera). `caption` is what was
  /// just said about the thing in view ("Sağ ön jant çizik").
  case takePhoto(label: CaptureLabel?, note: String?, caption: String?)
  /// "Video kaydını başlat", "kayda başla", "start recording".
  case startRecording(note: String?)
  /// "Videoyu durdur", "kaydı durdur", "stop recording".
  case stopRecording
  /// "Kayıt yapıyor musun?", "Ne kadar oldu?" while recording.
  case recordingStatus
  /// "Galeriye kaydet": the newest capture kept in AutoLoom goes to Photos.
  case saveCaptureToPhotos
  /// Dealer Mode ("Yeni araç", "VIN oku", "hasar ekle: …", "Bu araç tamam").
  case dealer(DealerCommand)
  /// "10 dakika timer kur", "timerı durdur", "ne kadar kaldı?".
  case timer(TimerCommand)
  /// "Son yaptığını geri al": undoes the last local action (never a call
  /// or a message).
  case undoLast
  /// "Alışveriş listesine süt ekle", "alışveriş listemde ne var?".
  case shopping(ShoppingCommand)
  /// A command without its content: ask for it ("Neyi not alayım?").
  case ask(Awaiting)
  /// LEVEL 2: the kind of request is certain; the details are left to the
  /// structured model classification (strict JSON), never to free text.
  case classify(AssistantTaskKind, query: String)

  /// Short name for the action trace (no names, numbers or message text).
  var traceName: String {
    switch self {
    case .confirmPending(let yes): yes ? "confirmAction" : "cancelAction"
    case .choosePendingTime: "chooseTime"
    case .cancelTasks: "cancelTask"
    case .dropAwaiting: "dropQuestion"
    case .saveNote: "saveNote"
    case .listNotes: "listNotes"
    case .searchNotes: "searchNotes"
    case .deleteNote: "deleteNote"
    case .saveMemory: "saveMemory"
    case .setName: "setProfileName"
    case .askName: "askProfileName"
    case .recallMemory: "recallMemory"
    case .recallConversation: "recallConversation"
    case .listMemories: "listMemories"
    case .forgetMemory: "forgetMemory"
    case .visualMemory: "visualMemory"
    case .createReminder: "createReminder"
    case .notify: "scheduleNotification"
    case .createTask: "createTask"
    case .createEvent: "createEvent"
    case .readCalendar(let range): "readCalendar(\(range.rawValue))"
    case .listTasks: "listTasks"
    case .completeTask: "completeTask"
    case .dayPlan(let range): "dayPlan(\(range.rawValue))"
    case .translateView: "translateView"
    case .call: "call"
    case .message: "message"
    case .findContact: "findContact"
    case .directions: "directions"
    case .nearby: "nearbySearch"
    case .directionsInView: "directionsInView"
    case .copyText: "copyText"
    case .shareText: "shareText"
    case .routine(let routine): "routine(\(routine.rawValue))"
    case .takePhoto(let label, let note, _): "takePhoto(\(label?.rawValue ?? "-")\(note != nil ? "+note" : ""))"
    case .startRecording(let note): note != nil ? "startRecording(+note)" : "startRecording"
    case .stopRecording: "stopRecording"
    case .recordingStatus: "recordingStatus"
    case .saveCaptureToPhotos: "saveCaptureToPhotos"
    case .dealer(let command): "dealer(\(command.name))"
    case .undoLast: "undoLast"
    case .timer(let command):
      switch command {
      case .start: "timerStart"
      case .cancel: "timerCancel"
      case .remaining: "timerRemaining"
      }
    case .shopping(let command):
      switch command {
      case .add: "shoppingAdd"
      case .read: "shoppingRead"
      case .remove: "shoppingRemove"
      }
    case .ask(let awaiting): "ask(\(awaiting.label))"
    case .classify(let kind, _): "classify(\(kind.rawValue))"
    }
  }
}

/// What the bridge knows about the conversation when it reads an utterance.
struct VoiceBridgeContext {
  var assistantName = AssistantIdentity.name
  /// An action waiting for the user's yes, no or time choice.
  var pendingPlan: DeviceActionPlan?
  var tasksRunning = false
  var awaiting: VoiceIntent.Awaiting?
  /// The user's previous utterance (for "bunu hatırla", "bunu görev olarak ekle").
  var previousUserText: String?
  /// The assistant's last answer (for "bunu not al").
  var lastAssistantText: String?
  /// What the user saved moments ago (a note, task or memory), for
  /// "bununla ilgili bir görev oluştur".
  var recentSavedText: String?
  /// The person of the last call, message or lookup ("ona da yaz").
  var recentContact: String?
  var cameraAvailable = false
  var visualMemoryAvailable = false
  /// A Ray-Ban video recording is running ("ne kadar oldu?" asks about it).
  var isRecording = false
  /// A timer is running ("ne kadar kaldı?" asks about it).
  var timerRunning = false
  /// Addressed-only mode: act only when the user says the assistant's name.
  var addressedOnly = false

  /// The assistant's last answer when it was a real answer, not a short
  /// confirmation such as "Tamam, not aldım."
  var usefulAnswer: String? {
    guard let text = lastAssistantText, !VoiceActionIntentBridge.isAcknowledgement(text) else { return nil }
    return text
  }
}

struct VoiceBridgeDecision: Equatable {
  enum Level: String, Equatable {
    case deterministic = "LEVEL 1 parser"
    case model = "LEVEL 2 model classification"
  }

  let intent: VoiceIntent
  let level: Level
  /// The rule that matched, for the action trace.
  let rule: String

  init(_ intent: VoiceIntent, _ rule: String, level: Level = .deterministic) {
    self.intent = intent
    self.rule = rule
    self.level = level
  }
}

/// LEVEL 1 of the voice action routing: a deterministic, high-confidence
/// parser for explicit Turkish and English commands. Anything it does not
/// recognise with confidence goes to the voice model as before (LEVEL 3).
/// Priority: action confirmation → explicit native action → explicit memory
/// → an answer to the bridge's own question. Stop words are handled by the
/// voice session before this runs; vision and web stay with the voice model
/// (except translating the view, which needs the high-detail path).
///
/// Only the user's own words are read here. Text seen by the camera, OCR or
/// web results never reaches this parser, so it can never trigger an action.
enum VoiceActionIntentBridge {
  static func decide(_ text: String, context: VoiceBridgeContext, now: Date = Date()) -> VoiceBridgeDecision? {
    guard var utterance = Utterance(text) else { return nil }
    var addressed = utterance.stripAddress(assistantName: context.assistantName)
    // The speech recogniser spells the name its own way ("Oto lum",
    // "Otoloom", "Carvis"): a near match is the address too.
    if utterance.stripNearAddress(assistantName: context.assistantName) { addressed = true }
    guard !utterance.isEmpty, utterance.count <= 80 else { return nil }

    // 1. Stopping a recording (and asking about it) comes first: "hayır,
    // kaydı durdur" stops it even while a question waits. Stop speaking is
    // handled by the voice session before this runs.
    if let decision = recordingControl(utterance, context) { return decision }

    // 2. The answer to an action waiting for confirmation (it answers the
    // assistant's own question, so the name is not needed).
    if let plan = context.pendingPlan, let decision = confirmation(utterance, plan: plan, now: now) {
      return decision
    }
    if context.tasksRunning, isCancel(utterance) {
      return VoiceBridgeDecision(.cancelTasks, "cancel words while a task runs")
    }
    if utterance.stripDiscourse() {
      // "Tamam Jarvis, not al…": the name can follow a discourse word.
      if utterance.stripAddress(assistantName: context.assistantName) { addressed = true }
      if utterance.stripNearAddress(assistantName: context.assistantName) { addressed = true }
    }
    guard !utterance.isEmpty else { return nil }
    if context.addressedOnly && !addressed && context.awaiting == nil { return nil }

    // Ray-Ban photos and recordings, before notes: "bunun fotoğrafını çek ve
    // not al: …" is a photo with a note.
    if let decision = media(utterance, context) { return decision }
    // Dealer Mode commands ("VIN oku", "hasar ekle: …", "Bu araç tamam").
    if let decision = dealer(utterance, context) { return decision }
    // Timers and the shopping list.
    if let decision = daily(utterance, context) { return decision }
    if isUndo(utterance) { return VoiceBridgeDecision(.undoLast, "undo") }

    // 3–12. Explicit native actions and explicit memory, in priority order.
    // Messages come before notes: "Ahmet'e bunu yaz" is a message, "bunu
    // yaz" a note.
    let parsers: [(Utterance) -> VoiceBridgeDecision?] = [
      { profile($0) },
      { translation($0, context) },
      { messages($0, context) },
      { notes($0, context) },
      { noteQueries($0) },
      { reminders($0, context, now) },
      { tasks($0, context, now) },
      { dayPlan($0) },
      { calendar($0, now) },
      { taskQueries($0) },
      { routines($0) },
      { calls($0) },
      { contactQuestions($0) },
      { directions($0, context) },
      { clipboard($0, context) },
      { memory($0, context) },
    ]
    for parser in parsers {
      if let decision = parser(utterance) { return decision }
    }
    // An answer to the bridge's own question ("Neyi not alayım?").
    if let awaiting = context.awaiting {
      return answer(utterance, to: awaiting, now: now)
    }
    return nil
  }

  /// "Son yaptığını geri al", "bunu geri al", "undo that".
  static func isUndo(_ u: Utterance) -> Bool {
    guard u.count <= 6 else { return false }
    let phrases: [[String]] = [
      ["son", "yaptigini", "geri", "al"], ["sonuncuyu", "geri", "al"], ["bunu", "geri", "al"], ["onu", "geri", "al"],
      ["geri", "al"], ["undo", "that"], ["undo", "the", "last", "one"], ["undo"],
    ]
    guard let phrase = phrases.first(where: { u.range(of: $0) != nil }), let range = u.range(of: phrase) else { return false }
    let fillers: Set<String> = ["son", "yaptigin", "lutfen", "please", "hemen", "sunu", "the", "last", "thing"]
    let outside = Array(u.keys[0..<range.lowerBound]) + Array(u.keys[range.upperBound...])
    return outside.allSatisfy(fillers.contains)
  }

  /// Whether a partial transcript already starts with a command, so the
  /// voice model's own reply can be held back before the turn ends.
  static func looksLikeCommandStart(_ partial: String, assistantName: String) -> Bool {
    guard var utterance = Utterance(partial) else { return false }
    _ = utterance.stripAddress(assistantName: assistantName)
    _ = utterance.stripNearAddress(assistantName: assistantName)
    _ = utterance.stripDiscourse()
    return commandStarts.contains { utterance.starts(with: $0) }
  }

  private static let commandStarts: [[String]] = [
    ["not", "al"], ["notal"], ["not", "et"], ["not", "tut"], ["not", "dus"], ["not", "olarak"], ["sunu", "not"],
    ["bunu", "not"], ["notlara"], ["notlarima"], ["bir", "not"], ["bir", "yere"], ["bir", "kenara"], ["kaydet"],
    ["benim", "adim"], ["bunu", "hatirla"], ["sunu", "hatirla"], ["unutma"], ["aklinda", "tut"], ["hafizana"],
    ["hafizaya"], ["gorev", "olustur"], ["gorev", "ekle"], ["takvime", "ekle"], ["bana", "hatirlat"],
    ["bunu", "kopyala"], ["bunu", "paylas"], ["mesaj", "yaz"], ["mesaj", "at"], ["beni", "eve"],
    ["remind", "me"], ["take", "a", "note"], ["make", "a", "note"], ["note", "that"], ["remember", "that"],
    ["my", "name", "is"], ["add", "a", "task"], ["add", "to", "my", "calendar"], ["write", "down"],
    ["fotograf", "cek"], ["foto", "cek"], ["bir", "fotograf"], ["bunun", "fotografini"], ["sunun", "fotografini"],
    ["video", "cek"], ["video", "kaydi"], ["video", "kaydini"], ["kayda", "basla"], ["kaydi", "durdur"],
    ["videoyu", "durdur"], ["cekimi", "bitir"], ["galeriye", "kaydet"], ["take", "a", "photo"], ["take", "a", "picture"],
    ["start", "recording"], ["stop", "recording"], ["record", "a", "video"],
    ["yeni", "arac"], ["vin", "oku"], ["hasar", "ekle"], ["kilometre"], ["bu", "arac", "tamam"], ["sonraki", "arac"],
    ["ilan", "hazirla"], ["piyasa", "bak"], ["foto", "checklist"], ["alisveris", "listesine"], ["alisveris", "listeme"],
    ["timer"], ["zamanlayici"],
  ]

  /// A short confirmation ("Tamam, not aldım.", "Got it.") that "bunu"
  /// should not point at.
  static func isAcknowledgement(_ text: String) -> Bool {
    guard let u = Utterance(text) else { return true }
    if u.count <= 3 { return true }
    let openers: Set<String> = [
      "tamam", "peki", "anladim", "tabii", "tabi", "olur", "harika", "super", "kaydettim", "ekledim",
      "okay", "ok", "sure", "got", "done", "alright", "noted",
    ]
    if u.count <= 7, let first = u.keys.first, openers.contains(first) { return true }
    let done: Set<String> = [
      "aldim", "kaydettim", "ekledim", "kurdum", "olusturdum", "hazirladim", "kopyaladim", "saved", "added", "created",
    ]
    return u.count <= 5 && u.containsAny(done)
  }

  // MARK: 2. Confirmation

  private static let yesWords: Set<String> = [
    "evet", "tamam", "olur", "onayla", "onayliyorum", "kaydet", "ekle", "dogru", "aynen", "tabii", "tabi",
    "yes", "yeah", "yep", "yup", "sure", "confirm", "ok", "okay", "correct",
  ]
  private static let yesPhrases: [[String]] = [["do", "it"], ["go", "ahead"], ["please", "do"], ["that", "one"], ["oyle", "yap"]]
  private static let noWords: Set<String> = [
    "hayir", "iptal", "vazgec", "vazgectim", "bosver", "istemiyorum", "no", "nope", "cancel", "dont", "nevermind",
  ]
  private static let morningWords: Set<String> = ["sabah", "sabahki", "sabahleyin", "morning", "am", "erken"]
  private static let eveningWords: Set<String> = [
    "aksam", "aksamki", "aksamleyin", "gece", "geceki", "evening", "afternoon", "pm", "tonight", "night",
  ]

  private static func confirmation(_ u: Utterance, plan: DeviceActionPlan, now: Date) -> VoiceBridgeDecision? {
    guard u.count <= 7 else { return nil }
    if let date = plan.date, let alternative = plan.alternativeDate {
      let hour = Calendar.current.component(.hour, from: date)
      let otherHour = Calendar.current.component(.hour, from: alternative)
      let (morning, evening) = hour < otherHour ? (date, alternative) : (alternative, date)
      let wantsMorning = u.containsAny(morningWords) || u.range(of: ["ogleden", "once"]) != nil
      let wantsEvening = u.containsAny(eveningWords) || u.range(of: ["ogleden", "sonra"]) != nil
      if wantsMorning != wantsEvening {
        return VoiceBridgeDecision(.choosePendingTime(wantsMorning ? morning : evening), "morning/evening choice")
      }
      if let spoken = TimePhraseParser.parse(u.text, now: now), spoken.hasTime {
        let spokenHour = Calendar.current.component(.hour, from: spoken.date)
        if spokenHour == hour { return VoiceBridgeDecision(.choosePendingTime(date), "spoken time choice") }
        if spokenHour == otherHour { return VoiceBridgeDecision(.choosePendingTime(alternative), "spoken time choice") }
      }
    }
    // A plain no. "Hayır, cuma" corrects the request instead: the voice
    // model plans it again.
    if let first = u.keys.first, noWords.contains(first) || u.starts(with: ["gerek", "yok"]) || u.starts(with: ["never", "mind"]),
       u.count <= 3, TimePhraseParser.parse(u.text, now: now) == nil {
      return VoiceBridgeDecision(.confirmPending(false), "no to the pending action")
    }
    // A plain yes: "evet", "tamam, kaydet", "evet ekle". "Tamam, peki hava
    // nasıl?" is a new question, not a yes.
    let yesCompanions: Set<String> = [
      "lutfen", "please", "kaydet", "ekle", "onayla", "olsun", "yap", "kur", "ayarla", "do", "it", "go", "ahead",
    ]
    if let first = u.keys.first, yesWords.contains(first), u.keys.dropFirst().allSatisfy({ yesWords.contains($0) || yesCompanions.contains($0) }) {
      return VoiceBridgeDecision(.confirmPending(true), "yes to the pending action")
    }
    if yesPhrases.contains(where: { u.starts(with: $0) }) {
      return VoiceBridgeDecision(.confirmPending(true), "yes to the pending action")
    }
    return nil
  }

  private static func isCancel(_ u: Utterance) -> Bool {
    guard u.count <= 5 else { return false }
    let phrases: [[String]] = [
      ["gorevi", "iptal", "et"], ["islemi", "iptal", "et"], ["aramayi", "iptal", "et"], ["aramayi", "durdur"],
      ["iptal", "et"], ["vazgec"], ["vazgectim"], ["cancel", "that"], ["cancel", "the", "task"], ["cancel", "it"],
      ["stop", "searching"],
    ]
    return phrases.contains { u.starts(with: $0) } || u.keys == ["cancel"]
  }

  // MARK: Profile

  private static func profile(_ u: Utterance) -> VoiceBridgeDecision? {
    let questions: [[String]] = [
      ["benim", "adim", "ne"], ["benim", "adim", "neydi"], ["adim", "ne"], ["adim", "neydi"], ["ismim", "ne"],
      ["benim", "ismim", "ne"], ["adimi", "biliyor", "musun"], ["adimi", "hatirliyor", "musun"],
      ["bana", "nasil", "hitap", "ediyorsun"], ["whats", "my", "name"], ["what", "is", "my", "name"],
      ["do", "you", "know", "my", "name"], ["do", "you", "remember", "my", "name"],
    ]
    if questions.contains(where: { u.starts(with: $0) }) {
      return VoiceBridgeDecision(.askName, "name question")
    }
    // "Benim adım Tolga", "my name is Tolga": any word is the name.
    let explicit: [[String]] = [["benim", "adim"], ["benim", "ismim"], ["my", "name", "is"], ["my", "names"], ["call", "me"]]
    for prefix in explicit where u.starts(with: prefix) {
      if let name = nameWords(u, from: prefix.count, requireCapital: false) {
        return VoiceBridgeDecision(.setName(name), "name introduction")
      }
    }
    // "Adım Tolga": the name must be written as a name (capitalised), since
    // "adım" is also "step".
    for prefix in [["adim"], ["ismim"]] where u.starts(with: prefix) {
      if let name = nameWords(u, from: prefix.count, requireCapital: true) {
        return VoiceBridgeDecision(.setName(name), "name introduction")
      }
    }
    // "Bana Tolga de", "bana Tolga diye hitap et".
    if u.starts(with: ["bana"]) {
      for ending in [["diye", "hitap", "et"], ["diye", "seslen"], ["diyebilirsin"], ["de"]] where u.ends(with: ending) {
        let innerCount = u.count - ending.count - 1
        guard (1...2).contains(innerCount) else { continue }
        let words = Array(u.words[1..<(1 + innerCount)])
        guard words.allSatisfy({ $0.first?.isUppercase ?? false }) else { continue }
        if let name = UserProfile.cleanName(words.joined(separator: " ")) {
          return VoiceBridgeDecision(.setName(name), "name introduction")
        }
      }
    }
    return nil
  }

  private static func nameWords(_ u: Utterance, from start: Int, requireCapital: Bool) -> String? {
    let stops: Set<String> = ["ve", "bunu", "hatirla", "unutma", "and", "remember", "lutfen", "please", "bu", "o"]
    var words: [String] = []
    var index = start
    while index < u.count, words.count < 3, !stops.contains(u.keys[index]) {
      words.append(u.words[index])
      index += 1
    }
    guard !words.isEmpty else { return nil }
    // "Adım atmak istiyorum" is not an introduction: short and name-like only.
    if requireCapital {
      guard u.count - start <= 3, words.allSatisfy({ $0.first?.isUppercase ?? false }) else { return nil }
    }
    let notNames: Set<String> = ["ne", "neydi", "nedir", "what", "at", "atmak", "sayar", "sayisi"]
    guard !notNames.contains(Utterance.key(words[0])) else { return nil }
    return UserProfile.cleanName(words.joined(separator: " "))
  }

  // MARK: 3. Notes

  /// Words that only point at something said before ("bunu", "this").
  static let deictic: Set<String> = [
    "bunu", "sunu", "onu", "bu", "su", "o", "bunlari", "sunlari", "tekrar", "yine", "de", "da", "bir", "daha",
    "ki", "this", "that", "it", "again", "these", "bununla", "sununla", "onunla", "ilgili", "hakkinda", "about",
    "bunun", "sunun", "onun", "icin",
  ]

  /// Explicit note verbs, longer phrases first. Like the task and reminder
  /// verbs they are found anywhere in the sentence: a word before "not al"
  /// (a misheard assistant name, "hemen", "benim için") must never hide the
  /// command, and the user's own verb decides ("Yarın Ahmet gelecek, not
  /// al" is a note although it mentions tomorrow).
  static let noteVerbs: [[String]] = [
    ["bunu", "not", "olarak", "kaydet"], ["sunu", "not", "olarak", "kaydet"], ["bunu", "not", "olarak", "yaz"],
    ["sunu", "not", "olarak", "yaz"], ["bunu", "notlara", "ekle"], ["sunu", "notlara", "ekle"], ["bunu", "notlara", "yaz"],
    ["sunu", "notlara", "yaz"], ["bunu", "notlarima", "ekle"], ["sunu", "notlarima", "ekle"],
    ["bir", "yere", "not", "et"], ["bir", "yere", "not", "al"], ["bir", "yere", "not", "dus"], ["bir", "yere", "yaz"],
    ["bir", "yere", "kaydet"], ["bir", "kenara", "not", "et"], ["bir", "kenara", "not", "al"], ["bir", "kenara", "not", "dus"],
    ["bir", "kenara", "yaz"], ["not", "defterine", "yaz"], ["deftere", "yaz"],
    ["bir", "not", "dus"], ["bir", "not", "al"], ["bir", "not", "yaz"], ["bir", "not", "ekle"],
    ["bunu", "not", "al"], ["sunu", "not", "al"], ["bunu", "not", "et"], ["sunu", "not", "et"], ["bunu", "not", "dus"],
    ["sunu", "not", "dus"],
    ["not", "olarak", "kaydet"], ["not", "olarak", "yaz"], ["not", "olarak", "ekle"], ["not", "olarak", "al"],
    ["notlarima", "ekle"], ["notlara", "ekle"], ["notlarima", "kaydet"], ["notlara", "kaydet"], ["notlarima", "yaz"],
    ["notlara", "yaz"], ["nota", "ekle"], ["nota", "yaz"], ["nota", "al"], ["nota", "gec"],
    ["not", "alir", "misin"], ["not", "alabilir", "misin"], ["not", "eder", "misin"], ["not", "edebilir", "misin"],
    ["not", "alsana"], ["not", "etsene"], ["not", "alin"], ["not", "edin"], ["not", "alalim"], ["not", "edelim"],
    ["not", "al"], ["not", "all"], ["note", "al"], ["notal"], ["not", "et"], ["not", "tut"], ["not", "dus"], ["not", "ekle"],
    ["not", "yaz"], ["bunu", "yaz"], ["sunu", "yaz"], ["bunu", "kaydet"], ["sunu", "kaydet"],
    ["save", "this", "as", "a", "note"], ["save", "that", "as", "a", "note"], ["save", "it", "as", "a", "note"],
    ["add", "this", "to", "my", "notes"], ["add", "that", "to", "my", "notes"], ["add", "it", "to", "my", "notes"],
    ["add", "to", "my", "notes"], ["write", "this", "down"], ["write", "that", "down"], ["write", "it", "down"],
    ["write", "down"], ["jot", "this", "down"], ["jot", "down"], ["take", "a", "note"], ["make", "a", "note"],
    ["save", "a", "note"], ["add", "a", "note"], ["note", "this"], ["note", "that"], ["note", "down"], ["as", "a", "note"],
  ]

  /// Words before the note verb that are not content ("benim için not al").
  private static let noteLeadFillers: Set<String> = [
    "benim", "icin", "hemen", "lutfen", "simdi", "bir", "su", "ki", "hey", "ok", "okay", "tamam", "peki", "sey",
    "please", "quickly", "now", "and", "ve", "also", "ayrica",
  ]

  /// Another command at the very end ("not al ve yarın hatırlat") is not
  /// part of the note: the sentence asks for more than a note.
  private static let otherFinalCommands: [[String]] = [
    ["hatirlat"], ["hatirlatir", "misin"], ["hatirlatsana"], ["haber", "ver"], ["beni", "uyar"], ["gorev", "olustur"],
    ["gorev", "ekle"], ["gorev", "olarak", "ekle"], ["gorev", "olarak", "kaydet"], ["gorevlere", "ekle"], ["todoya", "ekle"],
    ["yapilacaklara", "ekle"], ["takvime", "ekle"], ["takvimime", "ekle"], ["hatirla"], ["unutma"], ["aklinda", "tut"],
    ["hafizaya", "kaydet"], ["hafizana", "kaydet"],
  ]

  /// The earliest note verb, the longer phrase when two start together.
  static func noteVerb(in u: Utterance) -> (verb: [String], range: Range<Int>)? {
    var best: (verb: [String], range: Range<Int>)?
    for verb in noteVerbs {
      guard let range = u.range(of: verb) else { continue }
      if let current = best {
        if range.lowerBound < current.range.lowerBound
          || (range.lowerBound == current.range.lowerBound && verb.count > current.verb.count) {
          best = (verb, range)
        }
      } else {
        best = (verb, range)
      }
    }
    return best
  }

  static func notes(_ u: Utterance, _ context: VoiceBridgeContext) -> VoiceBridgeDecision? {
    guard let (verb, range) = noteVerb(in: u) else { return bareSave(u, context) }
    var tail = u.dropping(0..<range.upperBound)
    if otherFinalCommands.contains(where: { tail.ends(with: $0) }) { return nil }
    tail.trimLeading(["ki", "su", "sunu", "bunu", "that", "this", "olarak", "lutfen", "hemen", "please"])
    tail.trimTrailing(["lutfen", "please", "diye"])
    var head = u.dropping(range.lowerBound..<u.count)
    head.trimLeading(noteLeadFillers)
    head.trimTrailing(["diye", "olarak", "ki", "bunu", "sunu", "ve", "and", "lutfen", "please"])
    let rule = "note verb \"\(verb.joined(separator: " "))\""
    if !tail.isEmpty, !tail.isOnly(deictic) {
      return VoiceBridgeDecision(.saveNote(text: capitalizedFirst(tail.text)), rule)
    }
    if !head.isEmpty, !head.isOnly(deictic) {
      return VoiceBridgeDecision(.saveNote(text: capitalizedFirst(head.text)), rule)
    }
    return contextNote(context, rule: rule)
  }

  /// "Bunu not al": the last real answer, else what the user just said;
  /// asked when there is nothing to point at. "bunu" itself is never saved.
  private static func contextNote(_ context: VoiceBridgeContext, rule: String) -> VoiceBridgeDecision {
    if let previous = context.usefulAnswer ?? context.previousUserText ?? context.lastAssistantText,
       previous.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3,
       !(Utterance(previous)?.isOnly(deictic) ?? true) {
      return VoiceBridgeDecision(.saveNote(text: previous), rule + "; content from the conversation")
    }
    return VoiceBridgeDecision(.ask(.note), rule + " without content")
  }

  /// "Sağ ön jant çizik, kaydet", "kaydet: Mercedes cuma geliyor": a bare
  /// "kaydet" keeps the words as a note. Not "hafızaya kaydet" (memory),
  /// "takvime kaydet" (calendar), "görev olarak kaydet" (task) or "fotoğrafı
  /// kaydet".
  private static func bareSave(_ u: Utterance, _ context: VoiceBridgeContext) -> VoiceBridgeDecision? {
    let destinations: Set<String> = [
      "hafizaya", "hafizana", "hafizama", "takvime", "takvimime", "ajandaya", "ajandama", "olarak", "gorevlere",
      "gorevlerime", "yapilacaklara", "listeye", "listesine", "listeme", "hatirlaticiya", "rehbere", "kisilere",
    ]
    let objects: Set<String> = [
      "fotografi", "fotoyu", "resmi", "videoyu", "goruntuyu", "ekrani", "sesi", "dosyayi", "konumu", "numarayi", "sifreyi",
    ]
    var content: Utterance
    if u.count >= 2, u.ends(with: ["kaydet"]) || u.ends(with: ["kaydeder", "misin"]) {
      let length = u.ends(with: ["kaydet"]) ? 1 : 2
      content = u.dropping((u.count - length)..<u.count)
      guard let last = content.keys.last, !destinations.contains(last) else { return nil }
      content.trimTrailing(["bunu", "sunu", "diye", "ve", "lutfen"])
    } else if u.count >= 2, u.starts(with: ["kaydet"]) {
      content = u.dropping(0..<1)
      content.trimLeading(["bunu", "sunu", "su", "lutfen"])
    } else {
      return nil
    }
    guard !content.containsAny(destinations) else { return nil }
    if content.count == 1, objects.contains(content.keys[0]) { return nil }
    if content.isEmpty || content.isOnly(deictic) { return contextNote(context, rule: "bare \"kaydet\"") }
    return VoiceBridgeDecision(.saveNote(text: capitalizedFirst(content.text)), "bare \"kaydet\"")
  }

  /// "Notlarım neler?", "Mercedes için aldığım notları söyle", "bu notu
  /// sil". None of these creates a note.
  private static func noteQueries(_ u: Utterance) -> VoiceBridgeDecision? {
    guard u.count <= 10 else { return nil }
    let noteWords: Set<String> = [
      "notlarim", "notlarimi", "notlari", "notlar", "notlarimda", "notlarda", "notu", "notunu", "notumu", "notlarini",
      "notes", "note",
    ]
    guard let index = u.keys.firstIndex(where: noteWords.contains) else { return nil }
    // Delete: "bu notu sil", "son notu sil", "Mercedes notunu sil", "delete this note".
    if u.ends(with: ["sil"]) || u.ends(with: ["siler", "misin"]) || u.ends(with: ["kaldir"]) || u.starts(with: ["delete"]) {
      var target = u.dropping(index..<u.count)
      target.trimLeading(["bu", "su", "o", "son", "the", "this", "last", "delete", "en"])
      target.trimTrailing(["bu", "su", "son"])
      return VoiceBridgeDecision(.deleteNote(target.isEmpty ? nil : target.text), "delete a note (needs a yes)")
    }
    // "Notes about the Mercedes", "what did I note about the Mercedes".
    if u.keys[index] == "notes" || u.keys[index] == "note" {
      var about = u.dropping(0..<(index + 1))
      if about.starts(with: ["about"]) || about.starts(with: ["on"]) || about.starts(with: ["for"]) {
        about.trimLeading(["about", "on", "for", "the"])
        if !about.isEmpty { return VoiceBridgeDecision(.searchNotes(about.text), "note search") }
      }
    }
    let lists: [[String]] = [
      ["notlarim", "neler"], ["notlarim", "ne"], ["notlarimi", "oku"], ["notlarimi", "goster"], ["notlarimi", "soyle"],
      ["son", "notlarim"], ["notlarimda", "ne", "var"], ["notlarda", "ne", "var"], ["what", "are", "my", "notes"],
      ["read", "my", "notes"], ["show", "my", "notes"], ["my", "notes"],
    ]
    if lists.contains(where: { u.range(of: $0) != nil }) {
      return VoiceBridgeDecision(.listNotes, "note list question")
    }
    // "Mercedes için aldığım notları söyle", "Mercedes ile ilgili notlar",
    // "notes about the Mercedes".
    let asks: Set<String> = ["soyle", "oku", "neler", "ne", "goster", "nedir", "var", "mi"]
    let tailWords = u.dropping(0..<(index + 1))
    guard tailWords.isOnly(asks) else { return nil }
    var query = u.dropping(index..<u.count)
    query.trimTrailing([
      "icin", "ile", "ilgili", "hakkinda", "aldigim", "aldigin", "tuttugum", "yazdigim", "kaydettigim", "olan", "son",
      "about", "on",
    ])
    query.trimLeading(["bu", "su", "the"])
    guard !query.isEmpty else { return nil }
    return VoiceBridgeDecision(.searchNotes(query.text), "note search")
  }

  // MARK: 3. Reminders and notifications

  private static let reminderTriggers: [[String]] = [
    ["hatirlatma", "olustur"], ["hatirlatma", "kur"], ["hatirlatma", "ekle"], ["hatirlatma", "ayarla"],
    ["hatirlatici", "olustur"], ["hatirlatici", "kur"], ["hatirlatici", "ekle"], ["animsatici", "olustur"],
    ["animsatici", "kur"], ["animsatici", "ekle"],
    // "test hatırlatıcısı oluştur", "bir hatırlatması kur"
    ["hatirlaticisi", "olustur"], ["hatirlaticisi", "kur"], ["hatirlaticisi", "ekle"], ["hatirlatmasi", "olustur"],
    ["hatirlatmasi", "kur"], ["animsaticisi", "olustur"], ["animsaticisi", "ekle"],
    ["hatirlatir", "misin"], ["hatirlatabilir", "misin"],
    ["hatirlatsana"], ["hatirlatin"], ["hatirlat"],
    ["set", "a", "reminder"], ["create", "a", "reminder"], ["add", "a", "reminder"], ["make", "a", "reminder"],
    ["remind", "me"],
  ]

  private static let notifyTriggers: [[String]] = [
    ["haber", "verir", "misin"], ["haber", "ver"], ["beni", "uyar"], ["bildirim", "gonder"], ["bildirim", "kur"],
    ["notify", "me"], ["alert", "me"], ["ping", "me"],
  ]

  /// Words dropped from a reminder or task title.
  private static let titleFillers: Set<String> = ["bana", "beni", "lutfen", "please"]

  private static func reminders(_ u: Utterance, _ context: VoiceBridgeContext, _ now: Date) -> VoiceBridgeDecision? {
    let time = TimePhraseParser.parse(u.text, now: now)
    if let range = firstTrigger(reminderTriggers, in: u) {
      var rest = u.dropping(range)
      if let time { rest.removeTimeWords(time) }
      rest.removeKeys(titleFillers)
      rest.trimLeading(["to", "that", "about", "me", "for"])
      rest.trimTrailing(["diye", "icin", "to"])
      var title: String?
      if !rest.isEmpty, !rest.isOnly(deictic) {
        title = reminderTitle(rest.text)
      } else if let previous = context.recentSavedText ?? context.previousUserText, previous.count >= 3 {
        title = shortTitle(previous)
      }
      guard let title else {
        // "Bir hatırlatıcı oluştur" alone: ask what to remind.
        if time == nil, u.count <= 4 {
          return VoiceBridgeDecision(.ask(.reminderTitle), "reminder trigger without content")
        }
        // "Yarın 10'da hatırlat" with nothing to go on: the model reads the
        // conversation and fills the details (strict JSON, time by the app).
        return VoiceBridgeDecision(.classify(.authorizedAction, query: u.text), "reminder trigger without a title", level: .model)
      }
      guard let time else {
        return VoiceBridgeDecision(.ask(.reminderTime(title: title)), "reminder trigger without a time")
      }
      return VoiceBridgeDecision(.createReminder(title: title, time: time), "reminder trigger")
    }
    if let range = firstTrigger(notifyTriggers, in: u) {
      // "Hava değişince haber ver" has no time: not something the phone can
      // schedule, so it stays with the voice model.
      guard let time, time.hasTime else { return nil }
      var rest = u.dropping(range)
      rest.removeTimeWords(time)
      rest.removeKeys(titleFillers)
      rest.trimLeading(["to", "that", "about", "me"])
      rest.trimTrailing(["diye", "icin"])
      var title: String?
      if !rest.isEmpty, !rest.isOnly(deictic) {
        title = reminderTitle(rest.text)
      } else if !rest.isEmpty, let previous = context.recentSavedText ?? context.previousUserText, previous.count >= 3 {
        title = shortTitle(previous)
      }
      return VoiceBridgeDecision(.notify(title: title, time: time), "notification trigger")
    }
    return nil
  }

  // MARK: 6. AutoLoom tasks

  private static let taskTriggers: [[String]] = [
    ["gorev", "olarak", "ekle"], ["gorev", "olarak", "kaydet"], ["gorev", "listesine", "ekle"],
    ["gorevlerime", "ekle"], ["gorevlere", "ekle"], ["gorev", "olustur"], ["gorev", "ekle"],
    ["yapilacaklar", "listesine", "ekle"], ["yapilacaklarima", "ekle"], ["yapilacaklara", "ekle"],
    ["is", "listesine", "ekle"], ["todoya", "ekle"], ["todo", "listeme", "ekle"], ["todo", "listesine", "ekle"],
    ["task", "olustur"], ["task", "ekle"], ["gorev", "yap"],
    ["add", "it", "to", "my", "tasks"], ["add", "this", "to", "my", "tasks"], ["add", "to", "my", "tasks"],
    ["add", "to", "my", "to", "do", "list"], ["add", "to", "my", "todo", "list"], ["add", "a", "task"],
    ["create", "a", "task"], ["new", "task"],
  ]

  private static func tasks(_ u: Utterance, _ context: VoiceBridgeContext, _ now: Date) -> VoiceBridgeDecision? {
    guard let range = firstTrigger(taskTriggers, in: u) ?? needToDo(u) else { return nil }
    var time = TimePhraseParser.parse(u.text, now: now)
    var rest = u.dropping(range)
    if let time { rest.removeTimeWords(time) }
    rest.removeKeys(titleFillers)
    rest.trimLeading(["bir", "yeni", "to", "that", "a", "ki"])
    rest.trimTrailing(["diye", "olarak", "icin", "bir", "yeni"])
    if !rest.isEmpty, !rest.isOnly(deictic) {
      return VoiceBridgeDecision(.createTask(title: capitalizedFirst(rest.text), time: time), "task trigger")
    }
    // "Bununla ilgili bir görev oluştur": what was just saved, else what the
    // user said before.
    guard let previous = context.recentSavedText ?? context.previousUserText ?? context.lastAssistantText,
          previous.count >= 3 else {
      return VoiceBridgeDecision(.ask(.task), "task trigger without content")
    }
    if time == nil { time = TimePhraseParser.parse(previous, now: now) }
    return VoiceBridgeDecision(.createTask(title: shortTitle(previous), time: time), "task trigger; content from the conversation")
  }

  /// "Bunu yapmam lazım", "bugün bunu yapmam gerekiyor": a to-do, but not a
  /// question ("Bugün ne yapmam lazım?" is the day plan).
  private static func needToDo(_ u: Utterance) -> Range<Int>? {
    let endings: [[String]] = [["yapmam", "lazim"], ["yapmam", "gerek"], ["yapmam", "gerekiyor"], ["yapmaliyim"]]
    guard let ending = endings.first(where: { u.ends(with: $0) }), u.count > ending.count,
          !u.containsAny(["ne", "neler", "nasil", "hangi", "mi", "mu"]) else { return nil }
    return (u.count - ending.count)..<u.count
  }

  // MARK: 7. The day at a glance

  /// "Bugün ne yapmam gerekiyor?", "programım ne?": AutoLoom tasks, Apple
  /// Reminders and the calendar together. Needs a day word, so "arabam
  /// bozuldu, ne yapmam gerekiyor?" stays a question for the voice model.
  private static func dayPlan(_ u: Utterance) -> VoiceBridgeDecision? {
    guard u.count <= 8 else { return nil }
    let tomorrow = u.containsAny(["yarin", "yarinki", "tomorrow"])
    let range: VoiceIntent.CalendarRange = tomorrow ? .tomorrow : .today
    let plans: [[String]] = [
      ["programim", "ne"], ["programim", "nasil"], ["programimda", "ne", "var"], ["planim", "ne"],
      ["whats", "my", "day", "look", "like"], ["what", "does", "my", "day", "look", "like"],
      ["how", "does", "my", "day", "look"],
    ]
    if plans.contains(where: { u.range(of: $0) != nil }) {
      return VoiceBridgeDecision(.dayPlan(range), "day plan question")
    }
    if u.keys == ["bugunku", "programim"] || u.keys == ["yarinki", "programim"] {
      return VoiceBridgeDecision(.dayPlan(range), "day plan question")
    }
    guard tomorrow || u.containsAny(["bugun", "bugunku", "today"]) else { return nil }
    let questions: [[String]] = [
      ["ne", "yapmam", "gerekiyor"], ["ne", "yapmam", "lazim"], ["neler", "yapmam", "gerekiyor"],
      ["neler", "yapmam", "lazim"], ["ne", "yapacagim"], ["neler", "yapacagim"], ["islerim", "neler"],
      ["islerim", "ne"], ["ne", "islerim", "var"], ["what", "do", "i", "need", "to", "do"],
      ["what", "do", "i", "have", "to", "do"], ["whats", "on", "my", "plate"],
    ]
    guard questions.contains(where: { u.range(of: $0) != nil }) else { return nil }
    return VoiceBridgeDecision(.dayPlan(range), "day plan question")
  }

  // MARK: 7. Calendar

  private static let eventTriggers: [([String], String?)] = [
    (["takvimime", "ekle"], nil), (["takvime", "ekle"], nil), (["takvime", "kaydet"], nil), (["ajandama", "ekle"], nil),
    (["toplanti", "ekle"], "Toplantı"), (["toplanti", "olustur"], "Toplantı"), (["toplanti", "ayarla"], "Toplantı"),
    (["toplanti", "koy"], "Toplantı"), (["randevu", "ekle"], "Randevu"), (["randevu", "olustur"], "Randevu"),
    (["etkinlik", "ekle"], "Etkinlik"), (["etkinlik", "olustur"], "Etkinlik"),
    (["add", "to", "my", "calendar"], nil), (["add", "it", "to", "my", "calendar"], nil), (["add", "to", "calendar"], nil),
    (["put", "on", "my", "calendar"], nil), (["add", "a", "meeting"], "Meeting"), (["schedule", "a", "meeting"], "Meeting"),
    (["book", "a", "meeting"], "Meeting"), (["create", "an", "event"], "Event"), (["add", "an", "event"], "Event"),
  ]

  private static let calendarWords: Set<String> = [
    "takvim", "takvimim", "takvimimde", "takvimde", "takvimimi", "ajandam", "ajandamda", "programim", "programimda",
    "calendar", "schedule", "agenda",
  ]

  private static func calendar(_ u: Utterance, _ now: Date) -> VoiceBridgeDecision? {
    for (trigger, noun) in eventTriggers {
      guard let range = u.range(of: trigger) else { continue }
      let time = TimePhraseParser.parse(u.text, now: now)
      var rest = u.dropping(range)
      if let time { rest.removeTimeWords(time) }
      rest.removeKeys(titleFillers)
      rest.trimLeading(["bir", "a", "an", "to", "for"])
      rest.trimTrailing(["icin", "diye", "bir"])
      // "Ahmet'le toplantı ekle" → "Ahmet'le toplantı"; "add a meeting
      // with John" → "Meeting with John".
      let title: String
      if rest.isOnly(deictic) {
        title = noun ?? L.t("Event", "Etkinlik")
      } else if let noun, rest.keys.first == "with" {
        title = noun + " " + rest.text
      } else if let noun {
        title = capitalizedFirst(rest.text + " " + noun.lowercased(with: Locale(identifier: "tr_TR")))
      } else {
        title = capitalizedFirst(rest.text)
      }
      guard let time, time.hasTime else {
        return VoiceBridgeDecision(.ask(.eventTime(title: title)), "event trigger without a time")
      }
      return VoiceBridgeDecision(.createEvent(title: title, time: time), "event trigger")
    }
    // Reading: "bugün takvimimde ne var?", "yarın ne var?", "what's on my calendar?"
    guard u.count <= 10 else { return nil }
    let creating: Set<String> = ["ekle", "olustur", "kaydet", "add", "create", "koy"]
    guard !u.containsAny(creating) else { return nil }
    let asks: Set<String> = ["ne", "neler", "var", "bak", "oku", "what", "whats", "anything", "check", "read"]
    let range: VoiceIntent.CalendarRange = u.containsAny(["yarin", "tomorrow", "yarinki"]) ? .tomorrow
      : u.containsAny(["hafta", "haftaki", "week", "yaklasan", "upcoming", "onumuzdeki"]) ? .week : .today
    if u.containsAny(calendarWords), u.containsAny(asks) {
      return VoiceBridgeDecision(.readCalendar(range), "calendar question")
    }
    let dayQuestions: [[String]] = [
      ["bugun", "ne", "var"], ["yarin", "ne", "var"], ["bugun", "neler", "var"], ["yarin", "neler", "var"],
      ["bugun", "toplantim", "var", "mi"], ["yarin", "toplantim", "var", "mi"],
      ["what", "do", "i", "have", "today"], ["what", "do", "i", "have", "tomorrow"],
      ["whats", "on", "today"], ["whats", "on", "tomorrow"], ["any", "meetings", "today"], ["any", "meetings", "tomorrow"],
    ]
    if dayQuestions.contains(where: { u.starts(with: $0) }) {
      return VoiceBridgeDecision(.readCalendar(range), "day question")
    }
    return nil
  }

  // MARK: 6. Task questions

  private static func taskQueries(_ u: Utterance) -> VoiceBridgeDecision? {
    let lists: [[String]] = [
      ["gorevlerim", "neler"], ["gorevlerim", "ne"], ["gorevlerimi", "oku"], ["gorevlerimi", "say"],
      ["yapilacaklarim", "neler"], ["yapilacaklar", "listem"], ["hatirlaticilarim", "neler"], ["hatirlaticilarimi", "oku"],
      ["animsaticilarim", "neler"], ["what", "are", "my", "tasks"], ["read", "my", "tasks"],
      ["whats", "on", "my", "to", "do", "list"], ["what", "are", "my", "reminders"], ["read", "my", "reminders"],
    ]
    if u.count <= 9, lists.contains(where: { u.range(of: $0) != nil }) {
      return VoiceBridgeDecision(.listTasks, "task list question")
    }
    let completes: [[String]] = [["gorevini", "tamamla"], ["tamamlandi", "olarak", "isaretle"], ["tamamlandi", "isaretle"]]
    for ending in completes where u.ends(with: ending) {
      let target = u.dropping((u.count - ending.count)..<u.count)
      if !target.isEmpty { return VoiceBridgeDecision(.completeTask(target.text), "complete task") }
    }
    if u.starts(with: ["mark"]), u.ends(with: ["as", "done"]) {
      let target = u.dropping((u.count - 2)..<u.count).dropping(0..<1)
      if !target.isEmpty { return VoiceBridgeDecision(.completeTask(target.text), "complete task") }
    }
    return nil
  }

  // MARK: Routines

  private static func routines(_ u: Utterance) -> VoiceBridgeDecision? {
    guard u.count <= 6 else { return nil }
    let work: [[String]] = [
      ["ise", "basliyorum"], ["ise", "basladim"], ["mesaiye", "basliyorum"], ["gune", "basliyorum"],
      ["im", "starting", "work"], ["starting", "work"], ["start", "my", "workday"], ["start", "my", "day"],
    ]
    if work.contains(where: { u.starts(with: $0) }) {
      return VoiceBridgeDecision(.routine(.startWork), "routine: start work")
    }
    let briefing: [[String]] = [
      ["gunluk", "ozet"], ["gunun", "ozeti"], ["gunluk", "brifing"], ["brifing", "ver"], ["daily", "briefing"],
      ["brief", "me"], ["gunumu", "ozetle"],
    ]
    if briefing.contains(where: { u.range(of: $0) != nil }) {
      return VoiceBridgeDecision(.routine(.briefing), "routine: briefing")
    }
    let evening: [[String]] = [
      ["bugun", "ne", "yaptim"], ["bugun", "neler", "yaptim"], ["gun", "sonu", "ozeti"], ["gunu", "degerlendir"],
      ["what", "did", "i", "do", "today"], ["evening", "review"], ["end", "of", "day", "summary"],
    ]
    if evening.contains(where: { u.range(of: $0) != nil }) {
      return VoiceBridgeDecision(.routine(.eveningReview), "routine: evening review")
    }
    let weekly: [[String]] = [
      ["bu", "hafta", "ne", "yaptim"], ["bu", "hafta", "neler", "yaptim"], ["haftalik", "ozet"], ["haftami", "ozetle"],
      ["weekly", "review"], ["what", "did", "i", "do", "this", "week"],
    ]
    if weekly.contains(where: { u.range(of: $0) != nil }) {
      return VoiceBridgeDecision(.routine(.weeklyReview), "routine: weekly review")
    }
    return nil
  }

  // MARK: Translation of what is in view

  private static func translation(_ u: Utterance, _ context: VoiceBridgeContext) -> VoiceBridgeDecision? {
    guard context.cameraAvailable, u.count <= 10 else { return nil }
    let verbs: Set<String> = ["cevir", "cevirir", "cevirsene", "cevirebilir", "cevirin"]
    let pointers: Set<String> = [
      "bunu", "sunu", "bu", "su", "yaziyi", "yazi", "tabelayi", "tabela", "etiketi", "menuyu", "burada",
      "this", "that", "it", "sign", "label", "menu", "text",
    ]
    if let index = u.keys.firstIndex(where: verbs.contains), index > 0, u.containsAny(pointers) {
      // The target language is the word before the verb: "Türkçeye", "İngilizceye".
      let word = u.words[index - 1]
      let key = u.keys[index - 1]
      if key.hasSuffix("ceye") || key.hasSuffix("caya") {
        return VoiceBridgeDecision(.translateView(language: word), "translate the view")
      }
    }
    if u.starts(with: ["translate"]), u.containsAny(pointers) {
      var language = "Turkish"
      if let index = u.keys.firstIndex(where: { $0 == "into" || $0 == "to" }), index + 1 < u.count {
        language = u.words[index + 1]
      } else if !L.isTurkish {
        language = "English"
      }
      return VoiceBridgeDecision(.translateView(language: language), "translate the view")
    }
    return nil
  }

  // MARK: 8–10. Calls, messages and contacts

  enum GrammaticalCase: Equatable {
    case nominative
    case accusative
    case dative
    case genitive
  }

  /// Family words people call by title, in their accusative, dative and
  /// genitive forms, and the name they usually have in Contacts.
  private static let relations: [(accusative: String, dative: String, genitive: String, name: String)] = [
    ("annemi", "anneme", "annemin", "Annem"), ("babami", "babama", "babamin", "Babam"),
    ("esimi", "esime", "esimin", "Eşim"), ("karimi", "karima", "karimin", "Karım"),
    ("kocami", "kocama", "kocamin", "Kocam"), ("kardesimi", "kardesime", "kardesimin", "Kardeşim"),
    ("abimi", "abime", "abimin", "Abim"), ("ablami", "ablama", "ablamin", "Ablam"),
    ("oglumu", "ogluma", "oglumun", "Oğlum"), ("kizimi", "kizima", "kizimin", "Kızım"),
    ("patronumu", "patronuma", "patronumun", "Patronum"), ("dedemi", "dedeme", "dedemin", "Dedem"),
    ("anneannemi", "anneanneme", "anneannemin", "Anneannem"), ("babaannemi", "babaanneme", "babaannemin", "Babaannem"),
  ]

  /// Other names the same person often has in Contacts ("Annem" → "Anne").
  static let relationAlternatives: [String: [String]] = [
    "Annem": ["Anne", "Annecim", "Anneciğim"], "Babam": ["Baba", "Babacım", "Babacığım"], "Eşim": ["Eş"],
    "Kardeşim": ["Kardeş"], "Abim": ["Abi"], "Ablam": ["Abla"], "Oğlum": ["Oğul"], "Dedem": ["Dede"],
    "Anneannem": ["Anneanne"], "Babaannem": ["Babaanne"], "Mom": ["Mum", "Mother", "Mama"], "Dad": ["Father", "Papa"],
  ]

  private static let englishRelations: [[String]: String] = [
    ["mom"]: "Mom", ["mum"]: "Mum", ["dad"]: "Dad", ["my", "mom"]: "Mom", ["my", "mum"]: "Mum", ["my", "dad"]: "Dad",
    ["my", "wife"]: "Wife", ["my", "husband"]: "Husband", ["my", "brother"]: "Brother", ["my", "sister"]: "Sister",
    ["my", "boss"]: "Boss",
  ]

  /// Folded case endings, longest first.
  private static func caseSuffixes(_ grammaticalCase: GrammaticalCase) -> [String] {
    switch grammaticalCase {
    case .nominative: []
    case .accusative: ["yi", "yu", "ni", "nu", "i", "u"]
    case .dative: ["ye", "ya", "ne", "na", "e", "a"]
    case .genitive: ["nin", "nun", "in", "un"]
    }
  }

  private static func relationForm(
    _ relation: (accusative: String, dative: String, genitive: String, name: String),
    _ grammaticalCase: GrammaticalCase
  ) -> String {
    switch grammaticalCase {
    case .nominative: Utterance.key(relation.name)
    case .accusative: relation.accusative
    case .dative: relation.dative
    case .genitive: relation.genitive
    }
  }

  /// Words that are never a person ("Yarın'a", "Google'ı", "İnternet'te").
  private static let notPeople: Set<String> = [
    "yarin", "bugun", "dun", "aksam", "sabah", "gece", "ogle", "hafta", "pazartesi", "sali", "carsamba", "persembe",
    "cuma", "cumartesi", "pazar", "bu", "su", "o", "bura", "sura", "ora", "ev", "is", "not", "gorev", "takvim",
    "liste", "defter", "hafiza", "internet", "google", "youtube", "fiyat", "haber", "mesaj", "hava",
  ]

  /// "Ahmet'i" → "Ahmet", "Ayşe'ye" → "Ayşe", "Ahmet Yılmaz'ı" → "Ahmet
  /// Yılmaz", "annemi" → "Annem". Only names written as names (Turkish puts
  /// an apostrophe before a name's ending) and family words: "bunu ara" or
  /// "fiyatını ara" is not a person. Without the apostrophe the voice model
  /// handles the request instead.
  static func contactName(_ target: Utterance, _ grammaticalCase: GrammaticalCase) -> String? {
    guard (1...3).contains(target.count) else { return nil }
    if target.count == 1, let relation = relations.first(where: { relationForm($0, grammaticalCase) == target.keys[0] }) {
      return relation.name
    }
    var words = target.words
    if grammaticalCase == .nominative {
      // An answer to "Kime yazayım?": "Ahmet", "Ahmet Yılmaz".
      guard words.allSatisfy({ $0.first?.isUppercase ?? false }), !notPeople.contains(target.keys[0]) else { return nil }
      return words.joined(separator: " ")
    }
    guard let last = words.last, let apostrophe = last.firstIndex(where: { $0 == "'" || $0 == "’" }) else { return nil }
    let base = String(last[..<apostrophe])
    let ending = Utterance.key(String(last[last.index(after: apostrophe)...]))
    guard base.count >= 2, base.contains(where: \.isLetter), caseSuffixes(grammaticalCase).contains(ending),
          !notPeople.contains(Utterance.key(base)) else { return nil }
    words[words.count - 1] = base
    guard words.dropLast().allSatisfy({ $0.first?.isUppercase ?? false }) else { return nil }
    return words.joined(separator: " ")
  }

  /// "Ahmet", "Ahmet Yılmaz", "my wife": capitalised names or a family word.
  private static func englishContactName(_ target: Utterance) -> String? {
    guard (1...2).contains(target.count) else { return nil }
    if let relation = englishRelations[target.keys] { return relation }
    let excluded: Set<String> = [
      "me", "it", "that", "this", "you", "back", "him", "her", "them", "us", "home", "a", "the", "off", "out", "up",
    ]
    guard !target.keys.contains(where: excluded.contains),
          target.words.allSatisfy({ $0.first?.isUppercase ?? false }) else { return nil }
    return target.text
  }

  private static let callVerbs: [[String]] = [
    ["ara"], ["arar"], ["arasana"], ["arayabilir"], ["arayin"], ["telefonla", "ara"], ["telefonda", "ara"],
  ]

  /// "Ahmet'i ara", "Ahmet Yılmaz'ı arar mısın", "annemi ara", "call Ahmet".
  private static func calls(_ u: Utterance) -> VoiceBridgeDecision? {
    var w = u
    w.trimTrailing(["lutfen", "please", "hemen", "simdi", "misin", "musun", "misiniz"])
    for verb in callVerbs where w.ends(with: verb) && w.count > verb.count {
      let target = w.dropping((w.count - verb.count)..<w.count)
      if let name = contactName(target, .accusative) {
        return VoiceBridgeDecision(.call(contact: name), "call trigger")
      }
    }
    if w.starts(with: ["call"]) || w.starts(with: ["phone"]) || w.starts(with: ["ring"]) {
      if let name = englishContactName(w.dropping(0..<1)) {
        return VoiceBridgeDecision(.call(contact: name), "call trigger")
      }
    }
    return nil
  }

  private static let messageVerbs: Set<String> = [
    "yaz", "yazar", "yazsana", "yazabilir", "at", "atar", "atsana", "atabilir", "gonder", "gonderir", "gondersene",
    "gonderebilir", "yolla", "yollar", "yollasana", "ilet", "iletir", "soyle", "soyler", "soylesene",
  ]
  private static let messageNouns: Set<String> = ["mesaj", "mesaji", "mesajla", "sms"]

  /// "Ahmet'e 10 dakika gecikeceğim diye mesaj yaz", "Ahmet'e mesaj at:
  /// geliyorum", "ona gecikeceğimi de yaz", "mesaj yaz", "text Ahmet that…".
  private static func messages(_ u: Utterance, _ context: VoiceBridgeContext) -> VoiceBridgeDecision? {
    if let english = englishMessage(u, context) { return english }
    var w = u
    w.trimTrailing(["lutfen", "misin", "musun", "misiniz"])
    guard w.count >= 2 else { return nil }
    // "Mesaj yaz", "bir mesaj gönder": nobody named yet.
    let bare = w.keys.filter { $0 != "bir" }
    if bare.count == 2, messageNouns.contains(bare[0]), messageVerbs.contains(bare[1]) {
      return VoiceBridgeDecision(.message(contact: nil, body: nil), "message trigger without a recipient")
    }
    // "Mesaj at Ahmet'e: geliyorum".
    let lead = w.keys[0] == "bir" ? 1 : 0
    if w.count > lead + 2, messageNouns.contains(w.keys[lead]), messageVerbs.contains(w.keys[lead + 1]) {
      let rest = w.dropping(0..<(lead + 2))
      for length in [2, 1] where rest.count >= length {
        guard let name = contactName(rest.dropping(length..<rest.count), .dative) else { continue }
        let body = rest.dropping(0..<length)
        return VoiceBridgeDecision(
          .message(contact: name, body: body.isEmpty ? nil : capitalizedFirst(body.text)), "message trigger")
      }
      return nil
    }
    // The recipient first: "ona", "anneme", "Ahmet'e", "Ahmet Yılmaz'a".
    var recipient: String?
    var start = 0
    let toRecent = w.keys[0] == "ona"
    if toRecent {
      guard let recent = context.recentContact, w.keys[1] != "gore" else { return nil }
      recipient = recent
      start = ["da", "de"].contains(w.keys[1]) ? 2 : 1
    } else {
      for length in [2, 1] where w.count > length {
        if let name = contactName(w.dropping(length..<w.count), .dative) {
          recipient = name
          start = length
          break
        }
      }
    }
    guard let recipient, start < w.count else { return nil }
    let restKeys = Array(w.keys[start...])
    let restWords = Array(w.words[start...])
    var body: [String] = []
    var index = 0
    if restKeys[index] == "bir", restKeys.count > 1 { index += 1 }
    if index + 1 < restKeys.count, messageNouns.contains(restKeys[index]), messageVerbs.contains(restKeys[index + 1]) {
      // "… mesaj at: 10 dakika gecikeceğim"
      body = Array(restWords[(index + 2)...])
    } else {
      // "… 10 dakika gecikeceğim diye (mesaj) yaz"
      guard let verb = restKeys.last, messageVerbs.contains(verb) else { return nil }
      var keys = Array(restKeys.dropLast())
      var words = Array(restWords.dropLast())
      let fillers: Set<String> = ["mesaj", "mesaji", "mesajla", "sms", "olarak", "bir", "de", "da", "diye"]
      while let last = keys.last, fillers.contains(last) {
        keys.removeLast()
        words.removeLast()
      }
      body = words
      // "gecikeceğimi yaz": the message is "gecikeceğim".
      let nominalised = ["ecegimi", "acagimi", "digimi", "dugumu", "tigimi", "tugumu"]
      if let last = body.last, let key = keys.last, nominalised.contains(where: { key.hasSuffix($0) }) {
        body[body.count - 1] = String(last.dropLast())
      }
    }
    var text: String? = body.isEmpty ? nil : capitalizedFirst(body.joined(separator: " "))
    if !body.isEmpty, body.map(Utterance.key).allSatisfy({ deictic.contains($0) }) {
      // "Ahmet'e bunu yaz": the last real answer or what was just saved.
      text = context.usefulAnswer ?? context.recentSavedText ?? context.lastAssistantText
    }
    return VoiceBridgeDecision(.message(contact: recipient, body: text), toRecent ? "message to the recent contact" : "message trigger")
  }

  private static func englishMessage(_ u: Utterance, _ context: VoiceBridgeContext) -> VoiceBridgeDecision? {
    let rest: Utterance
    if u.starts(with: ["send", "a", "message", "to"]) || u.starts(with: ["send", "a", "text", "to"]) {
      rest = u.dropping(0..<4)
    } else if u.starts(with: ["text"]) || u.starts(with: ["message"]) {
      rest = u.dropping(0..<1)
    } else {
      return nil
    }
    guard !rest.isEmpty else { return nil }
    if ["them", "him", "her"].contains(rest.keys[0]), let recent = context.recentContact {
      var body = rest.dropping(0..<1)
      body.trimLeading(["that", "saying"])
      return VoiceBridgeDecision(
        .message(contact: recent, body: body.isEmpty ? nil : capitalizedFirst(body.text)), "message to the recent contact")
    }
    // The name is one or two capitalised words, or a family word.
    for length in [2, 1] where rest.count >= length {
      guard let name = englishContactName(rest.dropping(length..<rest.count)) else { continue }
      var body = rest.dropping(0..<length)
      body.trimLeading(["that", "saying", "to", "say"])
      return VoiceBridgeDecision(
        .message(contact: name, body: body.isEmpty ? nil : capitalizedFirst(body.text)), "message trigger")
    }
    return nil
  }

  /// "Ahmet'in numarası ne?", "annemin telefon numarası kaç", "what's
  /// Ahmet's number".
  private static func contactQuestions(_ u: Utterance) -> VoiceBridgeDecision? {
    guard u.count <= 7 else { return nil }
    let numberWords: Set<String> = ["numarasi", "numarasini", "telefonu", "telefonunu", "numarasina"]
    let asks: Set<String> = ["ne", "nedir", "neydi", "kac", "ver", "soyle", "bul", "goster", "oku"]
    if let index = u.keys.firstIndex(where: numberWords.contains), index >= 1,
       index == u.count - 1 || asks.contains(u.keys[u.count - 1]) {
      var end = index
      if end > 1, u.keys[end - 1] == "telefon" { end -= 1 }
      if let name = contactName(u.dropping(end..<u.count), .genitive) {
        return VoiceBridgeDecision(.findContact(name), "contact question")
      }
    }
    if u.ends(with: ["number"]) {
      let prefix = u.starts(with: ["whats"]) ? 1 : u.starts(with: ["what", "is"]) ? 2 : 0
      let suffix = u.ends(with: ["phone", "number"]) ? 2 : 1
      guard prefix > 0, u.count - suffix > prefix else { return nil }
      var words = Array(u.words[prefix..<(u.count - suffix)])
      guard let last = words.last, last.hasSuffix("'s") || last.hasSuffix("’s") else { return nil }
      words[words.count - 1] = String(last.dropLast(2))
      if let target = Utterance(words.joined(separator: " ")), let name = englishContactName(target) {
        return VoiceBridgeDecision(.findContact(name), "contact question")
      }
    }
    return nil
  }

  // MARK: 11. Maps

  private static let questionWords: Set<String> = [
    "nasil", "ne", "neden", "nedir", "mi", "mu", "kac", "hangi", "how", "what", "why", "which",
  ]

  /// "Beni eve götür", "Kadıköy'e yol tarifi aç", "havalimanına nasıl
  /// giderim", "en yakın benzinliğe götür", "take me to …". "Buraya yol
  /// tarifi" needs the camera, so it stays with the voice model.
  private static func directions(_ u: Utterance, _ context: VoiceBridgeContext) -> VoiceBridgeDecision? {
    var w = u
    w.trimTrailing(["lutfen", "please", "misin", "musun", "hemen", "simdi"])
    guard w.count >= 2, w.count <= 9 else { return nil }
    let guided = w.containsAny(["gotur", "goturur", "gotursene", "git", "gidelim", "take", "navigate", "drive"])
      || w.range(of: ["yol", "tarifi"]) != nil
    // Nearby: "en yakın benzinlik", "en yakın eczane nerede", "nearest gas station".
    if let near = w.range(of: ["en", "yakin"]) ?? w.range(of: ["nearest"]) ?? w.range(of: ["closest"]) {
      let lead = w.dropping(near.lowerBound..<w.count)
      let leads: [[String]] = [
        ["bana"], ["beni"], ["bizi"], ["where", "is", "the"], ["wheres", "the"], ["find", "the"], ["find", "me", "the"],
        ["take", "me", "to", "the"], ["navigate", "to", "the"], ["directions", "to", "the"],
      ]
      guard lead.isEmpty || leads.contains(where: { lead.keys == $0 }) else { return nil }
      var place = w.dropping(0..<near.upperBound)
      place.trimTrailing([
        "gotur", "goturur", "nerede", "nerde", "bul", "goster", "ac", "git", "yol", "tarifi", "where", "is", "find",
      ])
      let located = w.containsAny(["nerede", "nerde", "bul", "goster", "where", "find"]) || guided
      guard !place.isEmpty, place.count <= 3, located || w.count <= 3, !place.containsAny(questionWords) else { return nil }
      return VoiceBridgeDecision(.nearby(placeName(place, stripDative: guided)), "nearby search")
    }
    // English destinations.
    let homeCommands: [[String]] = [["take", "me", "home"], ["navigate", "home"], ["go", "home"]]
    if homeCommands.contains(w.keys) {
      return VoiceBridgeDecision(.directions("Home"), "directions home")
    }
    var destination: Utterance?
    var dative = false
    for prefix in [["take", "me", "to"], ["navigate", "to"], ["get", "directions", "to"], ["directions", "to"],
                   ["how", "do", "i", "get", "to"], ["drive", "to"]] where w.starts(with: prefix) {
      destination = w.dropping(0..<prefix.count)
      break
    }
    // Turkish destinations.
    if destination == nil {
      if w.ends(with: ["gotur"]) || w.ends(with: ["goturur"]) || w.ends(with: ["gotursene"]) {
        var rest = w.dropping((w.count - 1)..<w.count)
        let hasObject = ["beni", "bizi"].contains(rest.keys.first ?? "")
        rest.trimLeading(["beni", "bizi"])
        // "Beni eve götür", "Kadıköy'e götür"; not "bu işi sonuna götür".
        guard hasObject || rest.count == 1 else { return nil }
        destination = rest
        dative = true
      } else if let range = w.range(of: ["yol", "tarifi"]) ?? w.range(of: ["yol", "tarifini"]) {
        var rest = range.lowerBound > 0 ? w.dropping(range.lowerBound..<w.count) : w.dropping(0..<range.upperBound)
        rest.trimTrailing(["icin"])
        rest.trimLeading(["ac", "ver", "goster", "al", "baslat"])
        destination = rest
        dative = true
      } else if w.ends(with: ["nasil", "giderim"]) || w.ends(with: ["nasil", "gidilir"]) || w.ends(with: ["nasil", "gidebilirim"]) {
        destination = w.dropping((w.count - 2)..<w.count)
        dative = true
      }
    }
    guard let destination, !destination.isEmpty, destination.count <= 5, !destination.containsAny(questionWords) else {
      return nil
    }
    // "Bu restoranı bul ve yol tarifi aç" needs a search first: the voice
    // model plans it.
    guard !destination.containsAny(["ve", "bul", "and", "find", "search"]) else { return nil }
    let here: Set<String> = ["buraya", "suraya", "oraya", "bura", "sura", "ora", "here", "there"]
    let pointing: Set<String> = ["bu", "su", "o", "this", "that", "bunun", "sunun"]
    if destination.containsAny(here) || destination.containsAny(pointing) {
      // "Bu adrese", "şu restorana": the place from the last answer (the
      // model picks it out, strict JSON), else what is in view ("buraya").
      // Either way Maps opens only after the user checked it and tapped.
      if !destination.containsAny(here), let answer = context.usefulAnswer ?? context.recentSavedText {
        return VoiceBridgeDecision(
          .classify(.authorizedAction, query: "open_maps: directions to the place meant by \"\(destination.text)\" in: \(answer)"),
          "directions to a place from the conversation", level: .model)
      }
      return context.cameraAvailable ? VoiceBridgeDecision(.directionsInView, "directions to what is in view") : nil
    }
    if destination.count == 1 {
      switch destination.keys[0] {
      case "eve", "evime", "evimize", "home": return VoiceBridgeDecision(.directions("Home"), "directions home")
      case "ise", "isyerime", "ofise", "isime", "work", "office": return VoiceBridgeDecision(.directions("Work"), "directions to work")
      default: break
      }
    }
    return VoiceBridgeDecision(.directions(placeName(destination, stripDative: dative)), "directions")
  }

  /// "Kadıköy'e" → "Kadıköy", "havalimanına" → "havalimanı", "benzinliğe"
  /// → "benzinlik". Names without an apostrophe keep their ending
  /// ("Antalya" is not "Antal" + "ya").
  static func placeName(_ place: Utterance, stripDative: Bool) -> String {
    var words = place.words
    guard let last = words.last else { return place.text }
    if let apostrophe = last.firstIndex(where: { $0 == "'" || $0 == "’" }) {
      words[words.count - 1] = String(last[..<apostrophe])
    } else if stripDative, last.first?.isLowercase ?? false {
      let key = Utterance.key(last)
      for suffix in caseSuffixes(.dative) where key.hasSuffix(suffix) && key.count - suffix.count >= 3 {
        var base = String(last.dropLast(suffix.count))
        if base.hasSuffix("ğ") { base = String(base.dropLast()) + "k" }
        words[words.count - 1] = base
        break
      }
    }
    return words.joined(separator: " ")
  }

  // MARK: 12. Clipboard and share

  /// "Bunu kopyala", "şunu kopyala: 1234", "copy this", "bunu paylaş".
  private static func clipboard(_ u: Utterance, _ context: VoiceBridgeContext) -> VoiceBridgeDecision? {
    guard u.count <= 12 else { return nil }
    let current = context.usefulAnswer ?? context.recentSavedText ?? context.lastAssistantText
    let copies: [[String]] = [
      ["bunu", "panoya", "kopyala"], ["bunu", "kopyala"], ["sunu", "kopyala"], ["onu", "kopyala"], ["panoya", "kopyala"],
      ["kopyalar", "misin"], ["kopyalayabilir", "misin"], ["kopyala"], ["copy", "this"], ["copy", "it"],
      ["copy", "to", "clipboard"],
    ]
    if let trigger = copies.first(where: { u.starts(with: $0) }) {
      let rest = u.dropping(0..<trigger.count)
      if rest.isEmpty || rest.isOnly(deictic) {
        return VoiceBridgeDecision(.copyText(current), "copy trigger")
      }
      // "Şunu kopyala: 1234 5678"
      if trigger.first == "sunu" || trigger == ["kopyala"] {
        return VoiceBridgeDecision(.copyText(rest.text), "copy trigger with text")
      }
      return nil
    }
    if u.count <= 3, u.ends(with: ["kopyala"]), u.dropping((u.count - 1)..<u.count).isOnly(deictic) {
      return VoiceBridgeDecision(.copyText(current), "copy trigger")
    }
    let shares: [[String]] = [
      ["bunu", "paylas"], ["sunu", "paylas"], ["onu", "paylas"], ["paylasir", "misin"], ["paylas"],
      ["share", "this"], ["share", "it"],
    ]
    if u.count <= 4, let trigger = shares.first(where: { u.starts(with: $0) }), u.dropping(0..<trigger.count).isOnly(deictic) {
      return VoiceBridgeDecision(.shareText(current), "share trigger")
    }
    return nil
  }

  // MARK: 5. Memory

  private static let memoryStarts: [[String]] = [
    ["bunu", "hatirla"], ["sunu", "hatirla"], ["hatirla", "ki"], ["hatirla"], ["unutma", "ki"], ["unutma"],
    ["aklinda", "tut"], ["aklinda", "olsun"], ["hafizana", "kaydet"], ["hafizaya", "kaydet"], ["hafizana", "al"],
    ["hafizaya", "al"], ["remember", "that"], ["dont", "forget", "that"], ["dont", "forget"],
    ["keep", "in", "mind", "that"], ["keep", "in", "mind"], ["remember", "this"], ["remember"],
  ]

  private static let memoryEnds: [[String]] = [
    ["bunu", "hatirla"], ["sunu", "hatirla"], ["hatirla"], ["bunu", "unutma"], ["unutma"], ["aklinda", "tut"],
    ["aklinda", "olsun"], ["hafizana", "kaydet"], ["hafizaya", "kaydet"], ["hafizana", "al"],
    ["hatirlamani", "istiyorum"], ["remember", "that"], ["remember", "this"],
  ]

  /// Place words that make "remember" a visual memory ("buraya bıraktım").
  private static let placePointers: Set<String> = [
    "buraya", "burada", "burasi", "surada", "suraya", "orada", "oraya", "here", "there", "spot",
  ]

  private static func memory(_ u: Utterance, _ context: VoiceBridgeContext) -> VoiceBridgeDecision? {
    // Questions about earlier conversations.
    let earlier: [[String]] = [
      ["gecen", "gun"], ["gecen", "sefer"], ["gecen", "hafta"], ["dun"], ["daha", "once"], ["en", "son"],
      ["onceki", "konusmada"], ["last", "time"], ["yesterday"], ["earlier"], ["the", "other", "day"],
    ]
    let talked: Set<String> = [
      "konustuk", "konusmustuk", "konusuyorduk", "yapiyorduk", "yaptik", "yapmistik", "bahsettik", "bahsetmistik",
      "ugrasiyorduk", "talked", "discussed", "doing", "did", "talking",
    ]
    if earlier.contains(where: { u.range(of: $0) != nil }), u.containsAny(talked) {
      return VoiceBridgeDecision(.recallConversation(u.text), "question about an earlier conversation")
    }
    // Recall.
    if let range = u.range(of: ["hatirliyor", "musun"]) ?? u.range(of: ["do", "you", "remember"]) {
      let rest = u.dropping(range)
      if !rest.isEmpty { return VoiceBridgeDecision(.recallMemory(rest.text), "recall question") }
    }
    let placedVerbs: Set<String> = [
      "birakmistim", "koymustum", "etmistim", "biraktim", "koydum", "birakmisim", "koymusum", "park",
    ]
    if u.containsAny(["nereye", "nerede", "where"]), u.containsAny(placedVerbs), u.count <= 10 {
      return VoiceBridgeDecision(.recallMemory(u.text), "where-did-I question")
    }
    let recallPhrases: [[String]] = [
      ["ne", "kaydetmistim"], ["ne", "demistim"], ["ne", "soylemistim"], ["what", "did", "i", "tell", "you"],
      ["what", "did", "i", "save"],
    ]
    if recallPhrases.contains(where: { u.range(of: $0) != nil }) {
      return VoiceBridgeDecision(.recallMemory(u.text), "recall question")
    }
    let lists: [[String]] = [
      ["hafizanda", "ne", "var"], ["hafizamda", "ne", "var"], ["neleri", "hatirliyorsun"], ["ne", "hatirliyorsun"],
      ["benim", "hakkimda", "ne", "biliyorsun"], ["what", "do", "you", "remember"], ["what", "do", "you", "know", "about", "me"],
    ]
    if u.count <= 7, lists.contains(where: { u.starts(with: $0) }) {
      return VoiceBridgeDecision(.listMemories, "memory list question")
    }
    // Forget ("kapı kodunu unut"); "unutma" is the opposite and never matches.
    if u.ends(with: ["unut"]) || u.ends(with: ["hafizadan", "sil"]) || u.ends(with: ["hafizandan", "sil"]) {
      let length = u.ends(with: ["unut"]) ? 1 : 2
      var target = u.dropping((u.count - length)..<u.count)
      target.trimTrailing(["bunu", "sunu"])
      if !target.isEmpty, !target.isOnly(deictic) {
        return VoiceBridgeDecision(.forgetMemory(target.text), "forget request")
      }
    }
    if u.starts(with: ["forget", "about"]) || u.starts(with: ["forget", "that"]) {
      let target = u.dropping(0..<2)
      if !target.isEmpty { return VoiceBridgeDecision(.forgetMemory(target.text), "forget request") }
    }
    // Save.
    var content: Utterance?
    if let trigger = memoryStarts.first(where: { u.starts(with: $0) }) {
      // "Remember when…" and "remember how…" reminisce; they are not requests.
      let next = trigger.count < u.count ? u.keys[trigger.count] : ""
      if trigger == ["remember"], ["when", "how", "what", "where", "the", "me"].contains(next) { return nil }
      content = u.dropping(0..<trigger.count)
    } else if let trigger = memoryEnds.first(where: { u.ends(with: $0) }) {
      content = u.dropping((u.count - trigger.count)..<u.count)
      content?.trimTrailing(["bunu", "sunu", "ve", "and"])
    }
    guard var content else { return nil }
    content.trimLeading(["ki", "that", "bunu", "sunu"])
    let visual = context.visualMemoryAvailable
    if content.isEmpty || content.isOnly(deictic) {
      if visual { return VoiceBridgeDecision(.visualMemory(u.text), "remember this (visual)") }
      if let previous = context.previousUserText, previous.split(separator: " ").count >= 3 {
        return VoiceBridgeDecision(.saveMemory(text: previous, kind: nil), "memory trigger; content from the conversation")
      }
      return VoiceBridgeDecision(.ask(.memory), "memory trigger without content")
    }
    if visual, content.containsAny(placePointers) || (content.contains("nereye") && content.contains("park")) {
      return VoiceBridgeDecision(.visualMemory(u.text), "remember a place (visual)")
    }
    return VoiceBridgeDecision(.saveMemory(text: capitalizedFirst(content.text), kind: profileKind(content)), "memory trigger")
  }

  /// Statements about the user themselves go to About me.
  private static func profileKind(_ u: Utterance) -> MemoryKind? {
    let about: Set<String> = [
      "meslegim", "yasindayim", "dogum", "gunum", "dogdum", "yasiyorum", "oturuyorum", "calisiyorum", "isim",
    ]
    if u.containsAny(about) || u.starts(with: ["i", "am"]) || u.starts(with: ["im"]) || u.starts(with: ["i", "work"])
      || u.starts(with: ["i", "live"]) || u.starts(with: ["my", "birthday"]) {
      return .profile
    }
    return nil
  }

  // MARK: Answers to the bridge's questions

  private static func answer(_ u: Utterance, to awaiting: VoiceIntent.Awaiting, now: Date) -> VoiceBridgeDecision? {
    if isCancel(u) || u.starts(with: ["bosver"]) || u.starts(with: ["gerek", "yok"]) || u.starts(with: ["never", "mind"]) {
      return VoiceBridgeDecision(.dropAwaiting, "answer: never mind")
    }
    switch awaiting {
    case .note:
      return VoiceBridgeDecision(.saveNote(text: capitalizedFirst(u.text)), "answer: note content")
    case .memory:
      return VoiceBridgeDecision(.saveMemory(text: capitalizedFirst(u.text), kind: profileKind(u)), "answer: memory content")
    case .task:
      let time = TimePhraseParser.parse(u.text, now: now)
      var rest = u
      if let time { rest.removeTimeWords(time) }
      guard !rest.isEmpty else { return nil }
      return VoiceBridgeDecision(.createTask(title: capitalizedFirst(rest.text), time: time), "answer: task content")
    case .reminderTime(let title):
      if let time = TimePhraseParser.parse(u.text, now: now) {
        return VoiceBridgeDecision(.createReminder(title: title, time: time), "answer: reminder time")
      }
      let noTime: [[String]] = [
        ["fark", "etmez"], ["saatsiz"], ["zamansiz"], ["onemli", "degil"], ["no", "time"], ["doesnt", "matter"],
        ["any", "time"], ["whenever"],
      ]
      if noTime.contains(where: { u.range(of: $0) != nil }) {
        return VoiceBridgeDecision(.createReminder(title: title, time: nil), "answer: no time")
      }
      return nil
    case .reminderTitle:
      let time = TimePhraseParser.parse(u.text, now: now)
      var rest = u
      if let time { rest.removeTimeWords(time) }
      rest.removeKeys(titleFillers)
      rest.trimTrailing(["diye", "icin"])
      guard !rest.isEmpty else { return nil }
      let title = reminderTitle(rest.text)
      guard let time else {
        return VoiceBridgeDecision(.ask(.reminderTime(title: title)), "answer: reminder content; asking the time")
      }
      return VoiceBridgeDecision(.createReminder(title: title, time: time), "answer: reminder content")
    case .eventTime(let title):
      guard let time = TimePhraseParser.parse(u.text, now: now), time.hasTime else { return nil }
      return VoiceBridgeDecision(.createEvent(title: title, time: time), "answer: event time")
    case .messageBody(let contact):
      var body = u
      body.trimTrailing(["diye", "yaz", "gonder", "de", "da"])
      guard !body.isEmpty else { return nil }
      return VoiceBridgeDecision(.message(contact: contact, body: capitalizedFirst(body.text)), "answer: message text")
    case .messageRecipient(let body):
      var who = u
      who.trimTrailing(["yaz", "gonder", "at", "yolla", "mesaj", "mesaji"])
      guard let name = contactName(who, .dative) ?? contactName(who, .nominative) else { return nil }
      return VoiceBridgeDecision(.message(contact: name, body: body), "answer: message recipient")
    case .chooseContact(let action, let names):
      guard let chosen = chooseName(u, among: names) else { return nil }
      switch action {
      case .call: return VoiceBridgeDecision(.call(contact: chosen), "answer: which contact")
      case .message(let body): return VoiceBridgeDecision(.message(contact: chosen, body: body), "answer: which contact")
      case .find: return VoiceBridgeDecision(.findContact(chosen), "answer: which contact")
      }
    }
  }

  /// "Ahmet Kaya", "Kaya", "ikincisi", "the first one". "Ahmet" alone does
  /// not choose between two Ahmets.
  static func chooseName(_ u: Utterance, among names: [String]) -> String? {
    let ordinals: [(words: Set<String>, index: Int)] = [
      (["birinci", "birincisi", "ilk", "ilki", "first"], 0), (["ikinci", "ikincisi", "second"], 1),
      (["ucuncu", "ucuncusu", "third"], 2), (["dorduncu", "dorduncusu", "fourth"], 3),
    ]
    for ordinal in ordinals where u.containsAny(ordinal.words) && ordinal.index < names.count {
      return names[ordinal.index]
    }
    let spoken = Set(u.keys)
    let scored = names.map { name -> (name: String, score: Int) in
      let parts = name.split(separator: " ").map { Utterance.key(String($0)) }
      return (name, parts.filter(spoken.contains).count)
    }
    guard let best = scored.max(by: { $0.score < $1.score }), best.score > 0 else { return nil }
    return scored.filter({ $0.score == best.score }).count == 1 ? best.name : nil
  }

  // MARK: Helpers

  private static func firstTrigger(_ triggers: [[String]], in u: Utterance) -> Range<Int>? {
    for trigger in triggers {
      if let range = u.range(of: trigger) { return range }
    }
    return nil
  }

  /// "patronu aramamı" → "Patronu ara", "süt almayı" → "Süt al".
  static func reminderTitle(_ text: String) -> String {
    var words = text.split(separator: " ").map(String.init)
    if let last = words.last {
      let key = Utterance.key(last)
      for suffix in ["mami", "memi", "mayi", "meyi"] where key.hasSuffix(suffix) && key.count > suffix.count + 1 {
        words[words.count - 1] = String(last.dropLast(suffix.count))
        break
      }
    }
    return capitalizedFirst(words.joined(separator: " "))
  }

  /// A title from an earlier sentence: its first clause, at most 80 characters.
  static func shortTitle(_ text: String) -> String {
    let firstSentence = text.split(whereSeparator: { ".!?\n".contains($0) }).first.map(String.init) ?? text
    let trimmed = firstSentence.trimmingCharacters(in: .whitespacesAndNewlines)
    return capitalizedFirst(trimmed.count > 80 ? String(trimmed.prefix(80)) + "…" : trimmed)
  }

  static func capitalizedFirst(_ text: String) -> String {
    guard let first = text.first else { return text }
    return String(first).uppercased(with: Locale(identifier: "tr_TR")) + text.dropFirst()
  }
}

/// Turkish endings for names in the app's own sentences ("Ahmet'e",
/// "Ayşe'ye", "Tolga'ya", "Anneme"; "Ahmet Yılmaz mı").
enum TurkishSuffix {
  private static let vowels = "aeıioöuü"

  private static func lastVowel(_ word: String) -> Character? {
    word.lowercased(with: Locale(identifier: "tr_TR")).last(where: { vowels.contains($0) })
  }

  /// A family word ("Annem") takes the ending without an apostrophe.
  private static func joined(_ name: String, _ suffix: String) -> String {
    let familyWords: Set<String> = [
      "Annem", "Babam", "Eşim", "Karım", "Kocam", "Kardeşim", "Abim", "Ablam", "Oğlum", "Kızım", "Patronum",
      "Dedem", "Anneannem", "Babaannem",
    ]
    return familyWords.contains(name) ? name + suffix : name + "'" + suffix
  }

  static func dative(_ name: String) -> String {
    guard let vowel = lastVowel(name) else { return name }
    let endsWithVowel = name.lowercased(with: Locale(identifier: "tr_TR")).last.map { vowels.contains($0) } ?? false
    let buffer = endsWithVowel ? "y" : ""
    let ending = "aıou".contains(vowel) ? "a" : "e"
    return joined(name, buffer + ending)
  }

  static func accusative(_ name: String) -> String {
    guard let vowel = lastVowel(name) else { return name }
    let endsWithVowel = name.lowercased(with: Locale(identifier: "tr_TR")).last.map { vowels.contains($0) } ?? false
    let buffer = endsWithVowel ? "y" : ""
    let ending: String
    switch vowel {
    case "a", "ı": ending = "ı"
    case "e", "i": ending = "i"
    case "o", "u": ending = "u"
    default: ending = "ü"
    }
    return joined(name, buffer + ending)
  }

  /// The question particle after a name: "mı", "mi", "mu" or "mü".
  static func question(_ name: String) -> String {
    guard let vowel = lastVowel(name) else { return "mi" }
    switch vowel {
    case "a", "ı": return "mı"
    case "o", "u": return "mu"
    case "ö", "ü": return "mü"
    default: return "mi"
    }
  }
}

/// Near matches of the assistant's name for the spellings a speech
/// recogniser produces ("Oto lum", "Otoloom", "Autolum" for "AutoLoom";
/// "Carvis" for "Jarvis"). Only names of five letters or more are matched
/// loosely, so short words are never taken for a name.
enum AddressMatcher {
  static func names(assistantName: String) -> [String] {
    var names = ["jarvis", "autoloom"]
    if let configured = Utterance(assistantName)?.keys.joined(), !configured.isEmpty { names.insert(configured, at: 0) }
    return names.map(phonetic).filter { $0.count >= 5 }
  }

  static func matches(_ word: String, names: [String]) -> Bool {
    let spoken = phonetic(word)
    guard spoken.count >= 4 else { return false }
    return names.contains { name in
      let allowed = name.count <= 6 ? 1 : 2
      guard abs(name.count - spoken.count) <= allowed else { return false }
      return distance(spoken, name) <= allowed
    }
  }

  /// A rough sound key: "AutoLoom", "Oto lum" and "Otoloom" → "otolum";
  /// "Carvis" → "jarvis".
  static func phonetic(_ word: String) -> String {
    var text = Utterance.key(word).filter { $0.isLetter }
    let rules: [(String, String)] = [
      ("ph", "f"), ("au", "o"), ("ou", "u"), ("oo", "u"), ("c", "j"), ("z", "s"), ("w", "v"), ("y", "i"), ("q", "k"),
      ("x", "ks"),
    ]
    for (from, to) in rules {
      text = text.replacingOccurrences(of: from, with: to)
    }
    var collapsed = ""
    for character in text where character != collapsed.last {
      collapsed.append(character)
    }
    return collapsed
  }

  /// Levenshtein distance.
  static func distance(_ a: String, _ b: String) -> Int {
    let a = Array(a)
    let b = Array(b)
    if a.isEmpty { return b.count }
    if b.isEmpty { return a.count }
    var previous = Array(0...b.count)
    for i in 1...a.count {
      var current = [i] + Array(repeating: 0, count: b.count)
      for j in 1...b.count {
        let cost = a[i - 1] == b[j - 1] ? 0 : 1
        let deletion = previous[j] + 1
        let insertion = current[j - 1] + 1
        current[j] = Swift.min(deletion, insertion, previous[j - 1] + cost)
      }
      previous = current
    }
    return previous[b.count]
  }
}

/// One utterance as words (as spoken, outer punctuation removed) and keys
/// (lowercased, Turkish letters folded, apostrophes removed), aligned by index.
struct Utterance: Equatable {
  private(set) var words: [String]
  private(set) var keys: [String]

  private static let edges = CharacterSet(charactersIn: ".,;:!?\"“”«»()[]…–—").union(.whitespaces)

  init?(_ text: String) {
    var words: [String] = []
    for raw in text.split(whereSeparator: { $0.isWhitespace }) {
      let trimmed = raw.trimmingCharacters(in: Self.edges)
      if !trimmed.isEmpty, trimmed != "-" { words.append(trimmed) }
    }
    guard !words.isEmpty else { return nil }
    self.words = words
    self.keys = words.map(Self.key)
  }

  private init(words: [String], keys: [String]) {
    self.words = words
    self.keys = keys
  }

  static func key(_ word: String) -> String {
    MemorySearch.fold(word)
      .replacingOccurrences(of: "'", with: "")
      .replacingOccurrences(of: "’", with: "")
  }

  var count: Int { keys.count }
  var isEmpty: Bool { keys.isEmpty }
  var text: String { words.joined(separator: " ") }

  func starts(with phrase: [String]) -> Bool {
    !phrase.isEmpty && keys.count >= phrase.count && Array(keys.prefix(phrase.count)) == phrase
  }

  func ends(with phrase: [String]) -> Bool {
    !phrase.isEmpty && keys.count >= phrase.count && Array(keys.suffix(phrase.count)) == phrase
  }

  func range(of phrase: [String]) -> Range<Int>? {
    guard !phrase.isEmpty, keys.count >= phrase.count else { return nil }
    for start in 0...(keys.count - phrase.count) where Array(keys[start..<(start + phrase.count)]) == phrase {
      return start..<(start + phrase.count)
    }
    return nil
  }

  func contains(_ key: String) -> Bool { keys.contains(key) }

  func containsAny(_ set: Set<String>) -> Bool { keys.contains(where: set.contains) }

  /// Whether every word is one of `set` (true when empty).
  func isOnly(_ set: Set<String>) -> Bool { keys.allSatisfy(set.contains) }

  func dropping(_ range: Range<Int>) -> Utterance {
    var copy = self
    copy.remove(range)
    return copy
  }

  mutating func remove(_ range: Range<Int>) {
    let clamped = range.clamped(to: 0..<keys.count)
    words.removeSubrange(clamped)
    keys.removeSubrange(clamped)
  }

  mutating func removeKeys(_ set: Set<String>) {
    let kept = keys.indices.filter { !set.contains(keys[$0]) }
    self = Utterance(words: kept.map { words[$0] }, keys: kept.map { keys[$0] })
  }

  mutating func trimLeading(_ set: Set<String>) {
    while let first = keys.first, set.contains(first) { remove(0..<1) }
  }

  mutating func trimTrailing(_ set: Set<String>) {
    while let last = keys.last, set.contains(last) { remove((keys.count - 1)..<keys.count) }
  }

  /// Removes "hey", "Jarvis", the assistant's name (at the start or the
  /// end) and a trailing "lütfen". Returns whether the name was said.
  mutating func stripAddress(assistantName: String) -> Bool {
    var addressed = false
    let greetings: Set<String> = ["hey", "hi", "hay", "hei", "ey", "selam", "merhaba", "ok", "okay"]
    var names: [[String]] = [["jarvis"], ["autoloom"], ["auto", "loom"], ["otolum"]]
    if let configured = Utterance(assistantName)?.keys, !configured.isEmpty { names.insert(configured, at: 0) }
    var changed = true
    while changed, !isEmpty {
      changed = false
      if let first = keys.first, greetings.contains(first), count > 1 {
        remove(0..<1)
        changed = true
      }
      for name in names where starts(with: name) && count > name.count {
        remove(0..<name.count)
        addressed = true
        changed = true
        break
      }
    }
    for name in names where ends(with: name) && count > name.count {
      remove((count - name.count)..<count)
      addressed = true
      break
    }
    trimTrailing(["lutfen", "please", "artik"])
    return addressed
  }

  /// Removes the assistant's name when the speech recogniser spelled it
  /// differently: the first one or two words, or the last word, close enough
  /// to a name (see `AddressMatcher`). Returns whether a name was removed.
  mutating func stripNearAddress(assistantName: String) -> Bool {
    let names = AddressMatcher.names(assistantName: assistantName)
    var addressed = false
    for length in [2, 1] where count > length {
      if AddressMatcher.matches(keys[0..<length].joined(), names: names) {
        remove(0..<length)
        addressed = true
        break
      }
    }
    if !addressed, count > 2, let last = keys.last, AddressMatcher.matches(last, names: names) {
      remove((count - 1)..<count)
      addressed = true
    }
    if addressed { trimTrailing(["lutfen", "please", "artik"]) }
    return addressed
  }

  /// Removes leading "tamam", "peki", "şimdi", "lütfen", "bir de"… Returns
  /// whether anything was removed.
  @discardableResult
  mutating func stripDiscourse() -> Bool {
    let words: Set<String> = [
      "tamam", "evet", "peki", "simdi", "sey", "bak", "hmm", "ee", "eee", "ayrica", "lutfen", "hadi", "haydi",
      "so", "now", "also", "and", "well", "please",
    ]
    var removed = false
    while count > 1 {
      if let first = keys.first, words.contains(first) {
        remove(0..<1)
        removed = true
      } else if starts(with: ["bir", "de"]), count > 2 {
        remove(0..<2)
        removed = true
      } else {
        break
      }
    }
    return removed
  }

  /// Removes the words `TimePhraseParser` read as the time (its matched
  /// segments), so "yarın saat 10'da patronu ara" leaves "patronu ara".
  mutating func removeTimeWords(_ time: ParsedTime) {
    let segments = time.matched.components(separatedBy: " + ")
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
    for segment in segments {
      let forms = words.map { TimePhraseParser.normalize($0) }
      search: for start in forms.indices {
        var joined = ""
        for end in start..<forms.count {
          joined = joined.isEmpty ? forms[end] : joined + " " + forms[end]
          if joined == segment || (joined.hasPrefix(segment) && joined.count - segment.count <= 3) {
            remove(start..<(end + 1))
            break search
          }
          if joined.count > segment.count + 3 { break }
        }
      }
    }
  }
}
