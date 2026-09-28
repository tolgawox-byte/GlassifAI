import Foundation

/// What the local intent bridge understood from one final user utterance.
/// Explicit commands ("not al", "hatırlat", "görev oluştur", "benim adım…")
/// are executed by the app itself instead of depending on the voice model to
/// choose a delegation.
enum VoiceIntent: Equatable {
  /// A question the bridge asked; the next utterance answers it.
  enum Awaiting: Equatable {
    case note
    case memory
    case task
    case reminderTime(title: String)
    case eventTime(title: String)
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
  }

  /// Yes or no to an action waiting for confirmation.
  case confirmPending(Bool)
  /// "Sabah" / "akşam" for an action whose time was ambiguous.
  case choosePendingTime(Date)
  case cancelTasks
  /// "Vazgeç" after the bridge asked something.
  case dropAwaiting
  case saveNote(text: String)
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
  /// Read the text in view and translate it (high detail).
  case translateView(language: String)
  case routine(Routine)
  /// A command without its content: ask for it ("Neyi not alayım?").
  case ask(Awaiting)
  /// LEVEL 2: the kind of request is certain; the details are left to the
  /// structured model classification (strict JSON), never to free text.
  case classify(AssistantTaskKind, query: String)

  /// Short name for the action trace.
  var traceName: String {
    switch self {
    case .confirmPending(let yes): yes ? "confirmAction" : "cancelAction"
    case .choosePendingTime: "chooseTime"
    case .cancelTasks: "cancelTask"
    case .dropAwaiting: "dropQuestion"
    case .saveNote: "saveNote"
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
    case .translateView: "translateView"
    case .routine(let routine): "routine(\(routine.rawValue))"
    case .ask(let awaiting): "ask(\(awaiting))"
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
  var cameraAvailable = false
  var visualMemoryAvailable = false
  /// Addressed-only mode: act only when the user says the assistant's name.
  var addressedOnly = false
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
    guard !utterance.isEmpty, utterance.count <= 80 else { return nil }

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
      addressed = utterance.stripAddress(assistantName: context.assistantName) || addressed
    }
    guard !utterance.isEmpty else { return nil }
    if context.addressedOnly && !addressed && context.awaiting == nil { return nil }

    // 3–4. Explicit native actions and explicit memory.
    if let decision = profile(utterance)
      ?? translation(utterance, context)
      ?? notes(utterance, context)
      ?? reminders(utterance, context, now)
      ?? tasks(utterance, context, now)
      ?? calendar(utterance, now)
      ?? taskQueries(utterance)
      ?? routines(utterance)
      ?? memory(utterance, context) {
      return decision
    }
    // An answer to the bridge's own question ("Neyi not alayım?").
    if let awaiting = context.awaiting {
      return answer(utterance, to: awaiting, now: now)
    }
    return nil
  }

  /// Whether a partial transcript already starts with a command, so the
  /// voice model's own reply can be held back before the turn ends.
  static func looksLikeCommandStart(_ partial: String, assistantName: String) -> Bool {
    guard var utterance = Utterance(partial) else { return false }
    _ = utterance.stripAddress(assistantName: assistantName)
    _ = utterance.stripDiscourse()
    return commandStarts.contains { utterance.starts(with: $0) }
  }

  private static let commandStarts: [[String]] = [
    ["not", "al"], ["not", "et"], ["sunu", "not"], ["bunu", "not"], ["notlara", "ekle"], ["benim", "adim"],
    ["bunu", "hatirla"], ["sunu", "hatirla"], ["unutma"], ["aklinda", "tut"], ["hafizana"], ["hafizaya"],
    ["gorev", "olustur"], ["gorev", "ekle"], ["takvime", "ekle"], ["bana", "hatirlat"],
    ["remind", "me"], ["take", "a", "note"], ["make", "a", "note"], ["note", "that"], ["remember", "that"],
    ["my", "name", "is"], ["add", "a", "task"], ["add", "to", "my", "calendar"], ["write", "down"],
  ]

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

  private static let noteStarts: [[String]] = [
    ["bunu", "not", "olarak", "kaydet"], ["sunu", "not", "olarak", "kaydet"], ["not", "olarak", "kaydet"],
    ["not", "olarak", "ekle"], ["notlarima", "ekle"], ["notlara", "ekle"], ["nota", "ekle"],
    ["bir", "not", "al"], ["sunu", "not", "al"], ["bunu", "not", "al"], ["not", "alir", "misin"],
    ["not", "alabilir", "misin"], ["not", "al"], ["sunu", "not", "et"], ["bunu", "not", "et"],
    ["not", "eder", "misin"], ["not", "et"], ["not", "tut"], ["not", "yaz"], ["sunu", "yaz"], ["bunu", "yaz"],
    ["sunu", "kaydet"], ["bunu", "kaydet"],
    ["take", "a", "note"], ["make", "a", "note"], ["save", "a", "note"], ["add", "a", "note"], ["note", "that"],
    ["note", "down"], ["write", "this", "down"], ["write", "that", "down"], ["write", "down"], ["jot", "down"],
    ["save", "this", "as", "a", "note"], ["save", "that", "as", "a", "note"],
  ]

  private static let noteEnds: [[String]] = [
    ["bunu", "not", "olarak", "kaydet"], ["not", "olarak", "kaydet"], ["not", "olarak", "ekle"],
    ["notlarima", "ekle"], ["notlara", "ekle"], ["nota", "ekle"], ["bunu", "not", "al"], ["sunu", "not", "al"],
    ["not", "alir", "misin"], ["not", "alabilir", "misin"], ["not", "al"], ["bunu", "not", "et"],
    ["not", "eder", "misin"], ["not", "et"], ["bunu", "yaz"], ["sunu", "yaz"], ["bunu", "kaydet"], ["sunu", "kaydet"],
    ["note", "that", "down"], ["write", "that", "down"], ["write", "this", "down"], ["as", "a", "note"],
  ]

  /// Words that only point at something said before ("bunu", "this").
  static let deictic: Set<String> = [
    "bunu", "sunu", "onu", "bu", "su", "o", "bunlari", "sunlari", "tekrar", "yine", "de", "da", "bir", "daha",
    "ki", "this", "that", "it", "again", "these",
  ]

  private static func notes(_ u: Utterance, _ context: VoiceBridgeContext) -> VoiceBridgeDecision? {
    var content: Utterance?
    if let trigger = noteStarts.first(where: { u.starts(with: $0) }) {
      content = u.dropping(0..<trigger.count)
    } else if let trigger = noteEnds.first(where: { u.ends(with: $0) }) {
      content = u.dropping((u.count - trigger.count)..<u.count)
      content?.trimTrailing(["diye", "olarak", "bunu", "sunu"])
    }
    guard var content else { return nil }
    content.trimLeading(["ki", "su", "sunu", "that", "this", "olarak"])
    if content.isOnly(deictic) {
      if let previous = context.lastAssistantText ?? context.previousUserText, previous.count >= 3 {
        return VoiceBridgeDecision(.saveNote(text: previous), "note trigger; content from the conversation")
      }
      return VoiceBridgeDecision(.ask(.note), "note trigger without content")
    }
    return VoiceBridgeDecision(.saveNote(text: capitalizedFirst(content.text)), "note trigger")
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
      } else if let previous = context.previousUserText, previous.count >= 3 {
        title = shortTitle(previous)
      }
      guard let title else {
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
      } else if !rest.isEmpty, let previous = context.previousUserText, previous.count >= 3 {
        title = shortTitle(previous)
      }
      return VoiceBridgeDecision(.notify(title: title, time: time), "notification trigger")
    }
    return nil
  }

  // MARK: 3. AutoLoom tasks

  private static let taskTriggers: [[String]] = [
    ["gorev", "olarak", "ekle"], ["gorev", "olarak", "kaydet"], ["gorev", "listesine", "ekle"],
    ["gorevlerime", "ekle"], ["gorevlere", "ekle"], ["gorev", "olustur"], ["gorev", "ekle"],
    ["yapilacaklar", "listesine", "ekle"], ["yapilacaklarima", "ekle"], ["yapilacaklara", "ekle"],
    ["is", "listesine", "ekle"],
    ["add", "it", "to", "my", "tasks"], ["add", "this", "to", "my", "tasks"], ["add", "to", "my", "tasks"],
    ["add", "to", "my", "to", "do", "list"], ["add", "to", "my", "todo", "list"], ["add", "a", "task"],
    ["create", "a", "task"], ["new", "task"],
  ]

  private static func tasks(_ u: Utterance, _ context: VoiceBridgeContext, _ now: Date) -> VoiceBridgeDecision? {
    guard let range = firstTrigger(taskTriggers, in: u) else { return nil }
    var time = TimePhraseParser.parse(u.text, now: now)
    var rest = u.dropping(range)
    if let time { rest.removeTimeWords(time) }
    rest.removeKeys(titleFillers)
    rest.trimLeading(["bir", "yeni", "to", "that", "a", "ki"])
    rest.trimTrailing(["diye", "olarak", "icin", "bir", "yeni"])
    if !rest.isEmpty, !rest.isOnly(deictic) {
      return VoiceBridgeDecision(.createTask(title: capitalizedFirst(rest.text), time: time), "task trigger")
    }
    guard let previous = context.previousUserText ?? context.lastAssistantText, previous.count >= 3 else {
      return VoiceBridgeDecision(.ask(.task), "task trigger without content")
    }
    if time == nil { time = TimePhraseParser.parse(previous, now: now) }
    return VoiceBridgeDecision(.createTask(title: shortTitle(previous), time: time), "task trigger; content from the conversation")
  }

  // MARK: 3. Calendar

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
      let title = rest.isOnly(deictic) ? noun ?? L.t("Event", "Etkinlik") : capitalizedFirst(rest.text)
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
      ["bugun", "toplantim", "var", "mi"], ["yarin", "toplantim", "var", "mi"], ["bugun", "programim", "ne"],
      ["bugunku", "programim"], ["what", "do", "i", "have", "today"], ["what", "do", "i", "have", "tomorrow"],
      ["whats", "on", "today"], ["whats", "on", "tomorrow"], ["any", "meetings", "today"], ["any", "meetings", "tomorrow"],
    ]
    if dayQuestions.contains(where: { u.starts(with: $0) }) {
      return VoiceBridgeDecision(.readCalendar(range), "day question")
    }
    return nil
  }

  // MARK: 3. Task questions

  private static func taskQueries(_ u: Utterance) -> VoiceBridgeDecision? {
    let lists: [[String]] = [
      ["gorevlerim", "neler"], ["gorevlerim", "ne"], ["gorevlerimi", "oku"], ["gorevlerimi", "say"],
      ["yapilacaklarim", "neler"], ["yapilacaklar", "listem"], ["bugun", "ne", "yapmam", "lazim"],
      ["bugun", "ne", "yapmam", "gerekiyor"], ["hatirlaticilarim", "neler"], ["hatirlaticilarimi", "oku"],
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

  // MARK: 3. Routines

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

  // MARK: 4. Memory

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
    case .eventTime(let title):
      guard let time = TimePhraseParser.parse(u.text, now: now), time.hasTime else { return nil }
      return VoiceBridgeDecision(.createEvent(title: title, time: time), "answer: event time")
    }
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

  /// Removes leading "tamam", "peki", "şimdi", "bir de"… Returns whether
  /// anything was removed.
  @discardableResult
  mutating func stripDiscourse() -> Bool {
    let words: Set<String> = [
      "tamam", "evet", "peki", "simdi", "sey", "bak", "hmm", "ee", "eee", "ayrica", "so", "now", "also", "and", "well",
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
