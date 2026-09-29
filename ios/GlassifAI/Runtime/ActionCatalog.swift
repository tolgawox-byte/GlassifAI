import Foundation

/// Status labels used for every capability and action.
enum CapabilityStatus: String, CaseIterable, Codable {
  case working = "WORKING"
  case partial = "PARTIAL"
  case experimental = "EXPERIMENTAL"
  case waitingForDAT1 = "WAITING_FOR_DAT1"
  case physicalTestRequired = "PHYSICAL_TEST_REQUIRED"
  case requiresPermission = "REQUIRES_PERMISSION"
  case requiresProvider = "REQUIRES_PROVIDER"
  case unavailable = "UNAVAILABLE"

  var title: String {
    switch self {
    case .working: L.t("Working", "Çalışıyor")
    case .partial: L.t("Partial", "Kısmi")
    case .experimental: L.t("Experimental", "Deneysel")
    case .waitingForDAT1: L.t("Waiting for DAT 1.0", "DAT 1.0 bekleniyor")
    case .physicalTestRequired: L.t("Needs a device test", "Cihaz testi gerekli")
    case .requiresPermission: L.t("Needs permission", "İzin gerekli")
    case .requiresProvider: L.t("Needs a connection", "Bağlantı gerekli")
    case .unavailable: L.t("Unavailable", "Kullanılamaz")
    }
  }
}

/// One thing the assistant can do. Plain data: the voice parser tests, App
/// Intents, agent tools, the command library, the command lab and the CI
/// consistency check all read the same definition.
struct ActionDefinition: Identifiable, Equatable {
  enum Category: String, CaseIterable, Identifiable {
    case general, camera, vision, memory, tasks, dealer, phone, navigation, translation, research, media, automation

    var id: String { rawValue }

    var title: String {
      switch self {
      case .general: L.t("General", "Genel")
      case .camera: L.t("Camera", "Kamera")
      case .vision: L.t("Vision", "Görüş")
      case .memory: L.t("Memory", "Hafıza")
      case .tasks: L.t("Tasks", "Görevler")
      case .dealer: L.t("Dealer", "Bayi")
      case .phone: L.t("Phone", "Telefon")
      case .navigation: L.t("Navigation", "Yol tarifi")
      case .translation: L.t("Translation", "Çeviri")
      case .research: L.t("Research", "Araştırma")
      case .media: L.t("Media", "Medya")
      case .automation: L.t("Automation", "Otomasyon")
      }
    }

    var systemImage: String {
      switch self {
      case .general: "sparkles"
      case .camera: "camera"
      case .vision: "eye"
      case .memory: "brain"
      case .tasks: "checklist"
      case .dealer: "car"
      case .phone: "phone"
      case .navigation: "map"
      case .translation: "character.bubble"
      case .research: "magnifyingglass"
      case .media: "music.note"
      case .automation: "gearshape.2"
      }
    }
  }

  /// SAFE runs at once; CONFIRM asks when needed; STRONG_CONFIRM always asks
  /// (or needs a tap); BLOCKED never runs from voice or a model.
  enum Risk: String, CaseIterable {
    case safe = "SAFE"
    case confirm = "CONFIRM"
    case strongConfirm = "STRONG_CONFIRM"
    case blocked = "BLOCKED"
  }

  enum Confirmation: String {
    /// Runs at once.
    case none
    /// Asks only when something is unclear (a time, a contact, a place).
    case whenAmbiguous
    /// Always waits for the user's yes.
    case always
    /// iOS shows its own sheet or prompt; nothing happens until the user taps.
    case tapOnPhone
  }

  enum Undo: String {
    /// "Son yaptığını geri al" takes it back.
    case supported
    /// Nothing to undo (a question, a reading).
    case notApplicable
    /// Could be undone by hand in the other app; not by voice yet.
    case notSupported
    /// Irreversible outside the app (a call, a sent message).
    case impossible
  }

  /// How the words reach the action.
  enum Route: Equatable {
    /// The app's own parser (LEVEL 1), before any model.
    case local
    /// Conversation control ("dur", "kapat"), before the parser.
    case conversation
    /// The voice model delegates it (`TASK: <word>`); App Intents and the
    /// command palette run the same executor directly.
    case delegation(String)
  }

  enum Capability: String {
    case rayBanCamera, camera, network, location, microphone, appleIntelligence, dealerSession, dat1
  }

  struct Parameter: Equatable {
    enum Kind: String { case text, date, duration, contact, place, language, number, items }

    let name: String
    let kind: Kind
    let required: Bool
    let summary: String

    init(_ name: String, _ kind: Kind, required: Bool = true, _ summary: String) {
      self.name = name
      self.kind = kind
      self.required = required
      self.summary = summary
    }
  }

  let id: String
  let category: Category
  let name: String
  let nameTR: String
  let summary: String
  /// Example sentences; a leading "[tag,tag] " sets up context for the
  /// parser test (pending, ambiguous, tasks, timer, recording, vehicle,
  /// camera, visual, answer, contact, saved, awaiting).
  let examplesTR: [String]
  let examplesEN: [String]
  /// Sentences that must not reach this action.
  let negatives: [String]
  let parameters: [Parameter]
  let risk: Risk
  let confirmation: Confirmation
  let permissions: [AppPermission]
  let capabilities: [Capability]
  let offline: Bool
  let undo: Undo
  let route: Route
  /// Recognised locally before any cloud reasoning.
  let localPriority: Bool
  /// The App Intent type that exposes it, if any.
  let appIntent: String?
  /// Where the same action is in the UI.
  let ui: String?
  /// Why there is no UI for it, when there is none.
  let voiceOnlyReason: String?
  let status: CapabilityStatus
  /// `VoiceIntent.catalogKey` values that are this action.
  let keys: Set<String>
  /// Shown in the command palette.
  let quick: Bool

  init(
    _ id: String,
    _ category: Category,
    name: String,
    tr nameTR: String,
    summary: String,
    examplesTR: [String],
    examplesEN: [String] = [],
    negatives: [String] = [],
    parameters: [Parameter] = [],
    risk: Risk = .safe,
    confirmation: Confirmation = .none,
    permissions: [AppPermission] = [],
    capabilities: [Capability] = [],
    offline: Bool = true,
    undo: Undo = .notApplicable,
    route: Route = .local,
    localPriority: Bool = false,
    appIntent: String? = nil,
    ui: String? = nil,
    voiceOnly: String? = nil,
    status: CapabilityStatus = .experimental,
    keys: Set<String> = [],
    quick: Bool = false
  ) {
    self.id = id
    self.category = category
    self.name = name
    self.nameTR = nameTR
    self.summary = summary
    self.examplesTR = examplesTR
    self.examplesEN = examplesEN
    self.negatives = negatives
    self.parameters = parameters
    self.risk = risk
    self.confirmation = confirmation
    self.permissions = permissions
    self.capabilities = capabilities
    self.offline = offline
    self.undo = undo
    self.route = route
    self.localPriority = localPriority
    self.appIntent = appIntent
    self.ui = ui
    self.voiceOnlyReason = voiceOnly
    self.status = status
    self.keys = keys
    self.quick = quick
  }

  var title: String { L.t(name, nameTR) }

  /// Examples in the user's language first, without context tags.
  var displayExamples: [String] {
    let ordered = L.isTurkish ? examplesTR + examplesEN : examplesEN + examplesTR
    return ordered.map { ActionCatalog.stripTags($0).text }
  }
}

enum ActionCatalog {
  // MARK: Definitions

  static let all: [ActionDefinition] = general + memory + tasks + camera + vision + dealer + daily + phone

  private static let general: [ActionDefinition] = [
    ActionDefinition(
      "conversation.stop", .general, name: "Stop speaking", tr: "Konuşmayı kes",
      summary: "Stops the answer at once; a running recording is not touched.",
      examplesTR: ["Dur", "Sus", "Bir dakika"], examplesEN: ["Stop", "Wait"],
      route: .conversation, localPriority: true, ui: "Assistant → tap the orb", status: .physicalTestRequired),
    ActionDefinition(
      "conversation.end", .general, name: "End the conversation", tr: "Konuşmayı bitir",
      summary: "Ends the voice conversation.",
      examplesTR: ["Konuşmayı bitir", "Görüşürüz"], examplesEN: ["End conversation", "Goodbye"],
      route: .conversation, localPriority: true, appIntent: "StartConversationIntent",
      ui: "Assistant → end button", status: .physicalTestRequired),
    ActionDefinition(
      "action.confirm", .general, name: "Confirm", tr: "Onayla",
      summary: "Yes to the action waiting for confirmation.",
      examplesTR: ["[pending] Evet", "[pending] Evet, kaydet", "[pending] Onaylıyorum"],
      examplesEN: ["[pending] Yes", "[pending] Confirm"],
      localPriority: true, ui: "The confirmation card's button", keys: ["confirmPending.yes"]),
    ActionDefinition(
      "action.cancel", .general, name: "Cancel", tr: "Vazgeç",
      summary: "No to the waiting action, or cancel what is running.",
      examplesTR: ["[pending] Hayır", "[tasks] İptal et"], examplesEN: ["[pending] No", "[tasks] Cancel"],
      localPriority: true, ui: "The confirmation card's Cancel button",
      keys: ["confirmPending.no", "dropAwaiting", "cancelTasks"]),
    ActionDefinition(
      "action.chooseTime", .general, name: "Choose morning or evening", tr: "Sabah ya da akşamı seç",
      summary: "Answers \"sabah mı akşam mı?\" for an ambiguous time.",
      examplesTR: ["[ambiguous] Akşam", "[ambiguous] Sabah olan"],
      ui: "The confirmation card's time buttons", keys: ["choosePendingTime"]),
    ActionDefinition(
      "action.correct", .general, name: "Correct the last request", tr: "Son isteği düzelt",
      summary: "\"Hayır, cumartesi\": changes the day or time of the action just asked for or just saved.",
      examplesTR: ["[pending] Hayır, cumartesi", "[pending] Cumartesi olsun"], examplesEN: ["[pending] No, Saturday"],
      parameters: [.init("time", .date, "The corrected day or time")], permissions: [.reminders, .calendars],
      ui: "The confirmation card", keys: ["correctPending"]),
    ActionDefinition(
      "undo.last", .general, name: "Undo the last action", tr: "Son işlemi geri al",
      summary: "Takes back the last local action (note, task, memory, list item, timer, parking spot, damage, odometer); never a call or a message.",
      examplesTR: ["Son yaptığını geri al"], examplesEN: ["Undo that"],
      negatives: ["Parayı geri al"], localPriority: true, voiceOnly: "Each list has swipe-to-delete",
      keys: ["undoLast"]),
    ActionDefinition(
      "help.capabilities", .general, name: "What can you do?", tr: "Neler yapabilirsin?",
      summary: "A short, contextual answer and the Command Library on the phone.",
      examplesTR: ["Neler yapabilirsin?", "Ne yapabilirsin?", "Hangi komutlar var?"],
      examplesEN: ["What can you do?", "Show me the commands"],
      ui: "Settings → Command Library", keys: ["capabilities"]),
    ActionDefinition(
      "search.global", .general, name: "Search AutoLoom", tr: "AutoLoom'da ara",
      summary: "One on-device search over notes, tasks, memory, vehicles, captures, conversations and lists.",
      examplesTR: [
        "Geçen hafta Corolla ile ilgili kaydettiğim şeyi bul",
        "Mercedes için çektiğim jant fotoğraflarını göster",
        "Lastikle ilgili kaydettiklerimi bul",
      ],
      examplesEN: ["Find everything I saved about the Corolla"],
      parameters: [.init("query", .text, "What to find")],
      appIntent: "SearchAutoLoomIntent", ui: "Assistant → Search", keys: ["search"], quick: true),
    ActionDefinition(
      "profile.setName", .general, name: "Tell your name", tr: "Adını söyle",
      summary: "Saves how the assistant addresses you.",
      examplesTR: ["Benim adım Tolga"], examplesEN: ["My name is Tolga"],
      parameters: [.init("name", .text, "Your name")], undo: .supported,
      ui: "Memory → About me", keys: ["setName"]),
    ActionDefinition(
      "profile.askName", .general, name: "Ask your name", tr: "Adını sor",
      summary: "Says the name it knows.", examplesTR: ["Benim adım ne?"], examplesEN: ["What's my name?"],
      ui: "Memory → About me", keys: ["askName"]),
    ActionDefinition(
      "routine.startWork", .automation, name: "Start work", tr: "İşe başla",
      summary: "Today's tasks, the next event and hands-free listening.",
      examplesTR: ["İşe başlıyorum"], examplesEN: ["I'm starting work"],
      permissions: [.calendars, .reminders], voiceOnly: "A routine is a spoken start of the day",
      keys: ["routine.startWork"]),
    ActionDefinition(
      "routine.briefing", .automation, name: "Daily briefing", tr: "Günün özeti",
      summary: "Calendar, reminders, tasks and (with web search) the weather; private details only when asked.",
      examplesTR: ["Günün özeti", "Brifing ver"], examplesEN: ["Brief me"],
      permissions: [.calendars, .reminders], appIntent: "TodaysBriefingIntent", ui: "Tasks → Today",
      keys: ["routine.briefing"], quick: true),
    ActionDefinition(
      "routine.eveningReview", .automation, name: "What did I do today?", tr: "Bugün ne yaptım?",
      summary: "Counted from notes, tasks, memories, captures and vehicles; nothing guessed.",
      examplesTR: ["Bugün ne yaptım?"], examplesEN: ["What did I do today?"],
      voiceOnly: "A spoken summary", keys: ["routine.eveningReview"]),
    ActionDefinition(
      "routine.weeklyReview", .automation, name: "Weekly review", tr: "Haftalık özet",
      summary: "The same for the last seven days.", examplesTR: ["Haftalık özet", "Bu hafta ne yaptım?"],
      examplesEN: ["Weekly review"], voiceOnly: "A spoken summary", keys: ["routine.weeklyReview"]),
    ActionDefinition(
      "graph.run", .automation, name: "Several steps at once", tr: "Birden çok adım",
      summary: "\"… ve …\": runs each step in order and reports honestly which ones worked.",
      examplesTR: [
        "Alışveriş listesine süt ekle ve 10 dakika timer kur",
        "10 dakika timer kur, sonra alışveriş listesine ekmek ekle",
      ],
      examplesEN: ["Add milk to my shopping list and set a timer for 10 minutes"],
      voiceOnly: "Several spoken commands in one sentence", keys: ["graph"]),
  ]

  private static let memory: [ActionDefinition] = [
    ActionDefinition(
      "note.create", .memory, name: "Take a note", tr: "Not al",
      summary: "Saves a note on this iPhone at once; the note links to the active vehicle.",
      examplesTR: [
        "Not al: yarın kamerayı getir", "Şunu not et: yarın lastikler değişecek", "Mercedes cuma gelecek, bunu not al",
        "Jarvis, not al: toplantı cuma",
      ],
      examplesEN: ["Take a note: buy tires", "Write down: tire pressure 32"],
      negatives: ["Notlarım neler?"],
      parameters: [.init("text", .text, "The note")], undo: .supported, localPriority: true,
      appIntent: "CreateAutoLoomNoteIntent", ui: "Memory → Notes → +", status: .physicalTestRequired,
      keys: ["saveNote", "ask.note"], quick: true),
    ActionDefinition(
      "note.list", .memory, name: "Read my notes", tr: "Notlarımı oku",
      summary: "The newest notes, briefly.", examplesTR: ["Notlarım neler?", "Son notumu göster"],
      examplesEN: ["Read my notes"], ui: "Memory → Notes", keys: ["listNotes"]),
    ActionDefinition(
      "note.search", .memory, name: "Find notes", tr: "Not bul",
      summary: "Notes about a subject.", examplesTR: ["Mercedes için aldığım notları söyle", "Mercedes notlarımı bul"],
      examplesEN: ["Notes about the Mercedes"], parameters: [.init("query", .text, "The subject")],
      ui: "Memory → Search", keys: ["searchNotes"]),
    ActionDefinition(
      "note.delete", .memory, name: "Delete a note", tr: "Notu sil",
      summary: "Deletes the note just saved (or the newest) after a yes.", examplesTR: ["Bu notu sil", "Son notu sil"],
      risk: .confirm, confirmation: .always, ui: "Memory → Notes → swipe", keys: ["deleteNote"]),
    ActionDefinition(
      "memory.save", .memory, name: "Remember this", tr: "Bunu hatırla",
      summary: "Saves something to memory because you asked; never automatically.",
      examplesTR: ["Bunu hatırla: arabam siyah", "Unutma: kapı kodu 4512", "Ahmet yarın gelecek, bunu hatırla"],
      examplesEN: ["Remember that my car is black"], parameters: [.init("text", .text, "What to remember")],
      undo: .supported, appIntent: "RememberInAutoLoomIntent", ui: "Memory → +",
      keys: ["saveMemory", "ask.memory"], quick: true),
    ActionDefinition(
      "memory.recall", .memory, name: "Recall", tr: "Hatırlat bana",
      summary: "Answers from saved memories, notes and tasks; never guesses.",
      examplesTR: ["Hatırlıyor musun kapı kodunu?", "Arabamı nereye park etmiştim?"],
      examplesEN: ["What did I tell you about the door code?"], ui: "Memory → Search", keys: ["recallMemory"]),
    ActionDefinition(
      "memory.conversation", .memory, name: "Earlier conversations", tr: "Önceki konuşmalar",
      summary: "What was talked about before (conversation summaries).",
      examplesTR: ["Geçen hafta bununla ilgili ne konuşmuştuk?"], examplesEN: ["What did we talk about last time?"],
      ui: "Memory → Conversations", keys: ["recallConversation"]),
    ActionDefinition(
      "memory.list", .memory, name: "What do you remember?", tr: "Ne hatırlıyorsun?",
      summary: "A short list of saved memories.", examplesTR: ["Ne hatırlıyorsun?", "Hafızanda ne var?"],
      ui: "Memory", keys: ["listMemories"]),
    ActionDefinition(
      "memory.forget", .memory, name: "Forget", tr: "Unut",
      summary: "Deletes a memory after a yes.", examplesTR: ["Kapı kodunu unut"], examplesEN: ["Forget about the door code"],
      risk: .confirm, confirmation: .always, ui: "Memory → swipe", keys: ["forgetMemory"]),
    ActionDefinition(
      "memory.visual", .memory, name: "Remember what I see", tr: "Gördüğümü hatırla",
      summary: "Saves a visual memory of the current view (opt-in).",
      examplesTR: ["[visual] Anahtarımı buraya bıraktığımı hatırla", "[visual] Bunu hatırla"],
      examplesEN: ["[visual] Remember this"], capabilities: [.camera],
      ui: "Memory → Visual memory", keys: ["visualMemory"]),
    ActionDefinition(
      "memory.findVisual", .memory, name: "Where did I see it?", tr: "Nerede görmüştüm?",
      summary: "Searches the user's own visual memories (text and objects read on the phone, place, vehicle) and shows the photo.",
      examplesTR: [
        "Anahtarımı en son nerede gördüm?", "Cüzdanımı nerede görmüştüm?", "Bugün neler gördüm?", "Görsel anılarımı göster",
      ],
      examplesEN: ["Where did I last see my keys?", "What did I see today?"],
      parameters: [.init("what", .text, required: false, "What to find")],
      ui: "Memory → Visual memory", status: .working, keys: ["findVisual"], quick: true),
  ]

  private static let tasks: [ActionDefinition] = [
    ActionDefinition(
      "task.create", .tasks, name: "Create a task", tr: "Görev oluştur",
      summary: "An AutoLoom task on this iPhone; links to the active vehicle.",
      examplesTR: [
        "Görev oluştur: lastikleri kontrol et", "Yarına görev oluştur: Civic evraklarını hazırla",
        "Todo'ya ekle: sigorta",
      ],
      examplesEN: ["Create a task to order tires", "Add a task: call the bank"],
      parameters: [.init("title", .text, "The task"), .init("due", .date, required: false, "When")],
      undo: .supported, localPriority: true, appIntent: "CreateAutoLoomTaskIntent", ui: "Tasks → +",
      keys: ["createTask", "ask.task"], quick: true),
    ActionDefinition(
      "task.list", .tasks, name: "My tasks", tr: "Görevlerim",
      summary: "Open tasks and reminders.", examplesTR: ["Görevlerim neler?"], examplesEN: ["What are my tasks?"],
      ui: "Tasks", keys: ["listTasks"]),
    ActionDefinition(
      "task.complete", .tasks, name: "Complete a task", tr: "Görevi tamamla",
      summary: "Marks an AutoLoom task as done.",
      examplesTR: ["Lastik görevini tamamla", "[saved] Bunu tamamla"], examplesEN: ["Mark the tire order as done"],
      undo: .notSupported, ui: "Tasks → tap the circle", keys: ["completeTask"]),
    ActionDefinition(
      "task.move", .tasks, name: "Move a task", tr: "Görevi ertele",
      summary: "Moves a task to another day or time.",
      examplesTR: ["[saved] Bunu yarına taşı", "Lastik görevini cumaya ertele"], examplesEN: ["[saved] Move it to tomorrow"],
      parameters: [.init("time", .date, "The new day or time")], ui: "Tasks → swipe → Reschedule", keys: ["moveTask"]),
    ActionDefinition(
      "reminder.create", .tasks, name: "Create a reminder", tr: "Hatırlatıcı oluştur",
      summary: "An Apple Reminder with an alarm, saved at once.",
      examplesTR: ["Yarın 10'da Ahmet'i aramayı hatırlat", "20 dakika sonra fırını kapatmayı hatırlat", "Yarın 10'a uyarı koy"],
      examplesEN: ["Remind me to call mom tomorrow at 9"],
      parameters: [.init("title", .text, "What"), .init("time", .date, "When")],
      permissions: [.reminders], undo: .notSupported, localPriority: true, ui: "Tasks → +",
      keys: ["createReminder", "ask.reminderTime", "ask.reminderTitle"], quick: true),
    ActionDefinition(
      "reminder.place", .tasks, name: "Remind me at a place", tr: "Yer hatırlatıcısı",
      summary: "An Apple Reminders location alarm at your saved home or work address.",
      examplesTR: ["Eve varınca süt almayı hatırlat", "İşten çıkınca Ahmet'i aramayı hatırlat"],
      examplesEN: ["Remind me to call mom when I get home"], permissions: [.reminders], capabilities: [.network],
      offline: false, undo: .notSupported, voiceOnly: "Apple Reminders shows and edits it",
      status: .physicalTestRequired, keys: ["locationReminder"]),
    ActionDefinition(
      "notification.schedule", .tasks, name: "Notify me", tr: "Haber ver",
      summary: "A local notification at a time.", examplesTR: ["20 dakika sonra bana haber ver"], examplesEN: ["Notify me in 20 minutes"],
      permissions: [.notifications], undo: .notSupported, voiceOnly: "Timers and reminders cover it on screen",
      keys: ["notify"]),
    ActionDefinition(
      "calendar.read", .tasks, name: "Read my calendar", tr: "Takvimimi oku",
      summary: "Events for today, tomorrow or the week.", examplesTR: ["Bugün takvimimde ne var?", "Yarın ne var?"],
      permissions: [.calendars], ui: "Tasks → Today", keys: ["readCalendar"]),
    ActionDefinition(
      "calendar.create", .tasks, name: "Add to calendar", tr: "Takvime ekle",
      summary: "A calendar event; asks when the time is unclear.",
      examplesTR: ["Cuma 3'te toplantı ekle", "Yarın 14:00'te randevu ekle"], examplesEN: ["Add a meeting tomorrow at 3"],
      parameters: [.init("title", .text, "What"), .init("time", .date, "When")], confirmation: .whenAmbiguous,
      permissions: [.calendars], undo: .notSupported, voiceOnly: "Apple Calendar shows and edits events",
      keys: ["createEvent", "ask.eventTime"]),
    ActionDefinition(
      "dayplan.read", .tasks, name: "My day", tr: "Günüm",
      summary: "Tasks, reminders and events together, counted.",
      examplesTR: ["Bugün ne yapmam gerekiyor?", "Yarın programım ne?"], examplesEN: ["What does my day look like?"],
      permissions: [.calendars, .reminders], ui: "Tasks → Today", keys: ["dayPlan"]),
  ]

  private static let camera: [ActionDefinition] = [
    ActionDefinition(
      "camera.photo", .camera, name: "Take a Ray-Ban photo", tr: "Ray-Ban fotoğrafı çek",
      summary: "A photo from the glasses (never the iPhone camera), saved to Photos.",
      examplesTR: ["Fotoğraf çek", "Jantın fotoğrafını çek", "Fotoğrafını çek"], examplesEN: ["Take a photo", "Take a picture"],
      permissions: [.photos, .rayBanCamera], capabilities: [.rayBanCamera], localPriority: true,
      appIntent: "TakeRayBanPhotoIntent", ui: "Assistant → shutter button", status: .physicalTestRequired,
      keys: ["takePhoto"], quick: true),
    ActionDefinition(
      "camera.recordStart", .camera, name: "Start recording", tr: "Kaydı başlat",
      summary: "A Ray-Ban video (no sound on DAT 0.5), saved to Photos when stopped.",
      examplesTR: ["Video kaydını başlat", "Kayda başla", "Kayda gir"], examplesEN: ["Start recording"],
      permissions: [.photos, .rayBanCamera], capabilities: [.rayBanCamera], localPriority: true,
      appIntent: "StartRayBanRecordingIntent", ui: "Assistant → record button", status: .physicalTestRequired,
      keys: ["startRecording"], quick: true),
    ActionDefinition(
      "camera.recordStop", .camera, name: "Stop recording", tr: "Kaydı durdur",
      summary: "Stops and saves the video; \"dur\" alone never stops a recording.",
      examplesTR: ["[recording] Kaydı durdur", "[recording] Videoyu bitir"], examplesEN: ["[recording] Stop recording"],
      localPriority: true, appIntent: "StopRayBanRecordingIntent", ui: "Assistant → record button",
      status: .physicalTestRequired, keys: ["stopRecording"]),
    ActionDefinition(
      "camera.recordStatus", .camera, name: "Recording status", tr: "Kayıt durumu",
      summary: "Whether a recording runs and for how long.",
      examplesTR: ["Kayıt yapıyor musun?", "[recording] Ne kadar oldu?"], ui: "Assistant → recording chip",
      keys: ["recordingStatus"]),
    ActionDefinition(
      "captures.saveToPhotos", .camera, name: "Save to Photos", tr: "Galeriye kaydet",
      summary: "The newest capture kept in AutoLoom goes to Photos.",
      examplesTR: ["Galeriye kaydet"], examplesEN: ["Save it to photos"], permissions: [.photos],
      ui: "Explore → Captures → Save again", keys: ["saveCaptureToPhotos"]),
    ActionDefinition(
      "code.read", .camera, name: "Read a QR code or barcode", tr: "QR kod / barkod oku",
      summary: "Read on the phone with Vision; never opened, called or joined.",
      examplesTR: ["QR kodu oku", "Barkodu oku"], examplesEN: ["Read the QR code"], capabilities: [.camera],
      voiceOnly: "The camera is the input; the result is shown on screen", keys: ["readCode"]),
  ]

  private static let vision: [ActionDefinition] = [
    ActionDefinition(
      "vision.describe", .vision, name: "What am I looking at?", tr: "Ne görüyorum?",
      summary: "A fresh image from the current camera, described briefly.",
      examplesTR: ["Ne görüyorum?", "Bu ne?", "Şuna bi bak"], examplesEN: ["What am I looking at?"],
      capabilities: [.camera, .network], offline: false, route: .delegation("vision"),
      appIntent: "AskAutoLoomIntent", ui: "Assistant → camera", status: .physicalTestRequired),
    ActionDefinition(
      "vision.read", .vision, name: "Read this", tr: "Şunu oku",
      summary: "Reads text in view in fine detail (highest photo quality).",
      examplesTR: ["Şunu oku", "Bu tabelada ne yazıyor?"], examplesEN: ["Read this"],
      capabilities: [.camera, .network], offline: false, route: .delegation("vision_read"),
      ui: "Assistant → camera", status: .physicalTestRequired),
    ActionDefinition(
      "vision.live", .vision, name: "Keep watching", tr: "Bakmaya devam et",
      summary: "Live Vision: adaptive sampling, speaks only when something changes.",
      examplesTR: ["Bakmaya devam et", "Gördüklerimi takip et"], examplesEN: ["Keep watching"],
      capabilities: [.camera, .network], offline: false, route: .delegation("live_vision_start"),
      appIntent: "StartLiveVisionIntent", ui: "Assistant → Live Vision chip", status: .physicalTestRequired),
    ActionDefinition(
      "vision.liveStop", .vision, name: "Stop watching", tr: "Canlı görüşü kapat",
      summary: "Ends Live Vision.", examplesTR: ["Canlı görüşü kapat"], examplesEN: ["Stop watching"],
      route: .delegation("live_vision_stop"), ui: "Assistant → Live Vision chip"),
    ActionDefinition(
      "vision.whatChanged", .vision, name: "What changed?", tr: "Ne değişti?",
      summary: "While Live Vision watches: the last two scene notes, compared. Never a guess from an old frame.",
      examplesTR: ["[live] Ne değişti?", "[live] Bir şey değişti mi?"], examplesEN: ["[live] What changed?"],
      capabilities: [.camera], ui: "Assistant → Live Vision chip", status: .physicalTestRequired, keys: ["whatChanged"]),
    ActionDefinition(
      "document.summarize", .vision, name: "Summarise a document", tr: "Belgeyi özetle",
      summary: "Reads the document on the phone (text only kept), finds dates and amounts; a reminder only after your yes.",
      examplesTR: ["Bu belgeyi özetle", "Bu belgede ne var?"], examplesEN: ["Summarize this document"],
      capabilities: [.camera], ui: "Explore → Documents and receipts", status: .physicalTestRequired,
      keys: ["document.summarize"]),
    ActionDefinition(
      "document.receipt", .vision, name: "Save a receipt", tr: "Fişi kaydet",
      summary: "Store, total and date read on the phone; the photo is not kept.",
      examplesTR: ["Fişi kaydet", "Bu faturayı kaydet"], examplesEN: ["Save this receipt"], capabilities: [.camera],
      ui: "Explore → Documents and receipts", status: .physicalTestRequired, keys: ["document.saveReceipt"]),
    ActionDefinition(
      "document.spending", .vision, name: "This month's receipts", tr: "Bu ayki fişler",
      summary: "The total of the receipts you saved this month, per currency; not accounting.",
      examplesTR: ["Bu ay ne harcadım?"], examplesEN: ["How much did I spend this month?"],
      ui: "Explore → Documents and receipts", status: .working, keys: ["document.spending"]),
    ActionDefinition(
      "translation.view", .translation, name: "Translate what I see", tr: "Gördüğümü çevir",
      summary: "Reads the text in view and translates it.",
      examplesTR: ["[camera] Bu tabelayı Türkçeye çevir", "[camera] Şunu İngilizceye çevir"],
      examplesEN: ["[camera] Translate this sign into Turkish"], parameters: [.init("language", .language, "Target language")],
      capabilities: [.camera, .network], offline: false, ui: "Explore → Translation", keys: ["translateView"]),
    ActionDefinition(
      "research.web", .research, name: "Look it up", tr: "Araştır",
      summary: "Current information from the web, with sources on screen.",
      examplesTR: ["Bugün hava nasıl?", "Son dakika haberlerini araştır"], examplesEN: ["What's the weather today?"],
      capabilities: [.network], offline: false, route: .delegation("web"), appIntent: "AskAutoLoomIntent",
      ui: "Assistant → type a question"),
    ActionDefinition(
      "research.reasoning", .research, name: "Think it through", tr: "Detaylı düşün",
      summary: "A careful comparison or analysis.", examplesTR: ["Bu iki teklifi detaylı karşılaştır"],
      examplesEN: ["Compare these two offers in depth"], capabilities: [.network], offline: false,
      route: .delegation("reasoning"), appIntent: "AskAutoLoomIntent", ui: "Assistant → type a question"),
  ]

  private static let dealer: [ActionDefinition] = [
    ActionDefinition(
      "dealer.start", .dealer, name: "New vehicle", tr: "Yeni araç",
      summary: "Starts a vehicle session; notes, tasks, damage and photos link to it.",
      examplesTR: ["Yeni araç", "Yeni araç başlat"], examplesEN: ["New vehicle"],
      appIntent: "StartDealerSessionIntent", ui: "Explore → Dealer → Start a vehicle",
      keys: ["dealer.startVehicle"], quick: true),
    ActionDefinition(
      "dealer.next", .dealer, name: "Next vehicle", tr: "Sonraki araç",
      summary: "Closes this vehicle and starts the next.", examplesTR: ["Sonraki araç"], examplesEN: ["Next vehicle"],
      ui: "Explore → Dealer → Next vehicle", keys: ["dealer.nextVehicle"]),
    ActionDefinition(
      "dealer.finish", .dealer, name: "Vehicle done", tr: "Bu araç tamam",
      summary: "Closes the active vehicle with a summary.", examplesTR: ["Bu araç tamam"],
      examplesEN: ["Done with this vehicle"], negatives: ["Bu araç tamam mı?"],
      ui: "Explore → Dealer → Done", keys: ["dealer.finishVehicle"]),
    ActionDefinition(
      "dealer.saveVehicle", .dealer, name: "Save the vehicle", tr: "Aracı kaydet",
      summary: "Confirms the vehicle is stored (vehicles save automatically).",
      examplesTR: ["[vehicle] Aracı kaydet"], examplesEN: ["[vehicle] Save the vehicle"],
      voiceOnly: "Vehicles save automatically; this answers the spoken step", keys: ["dealer.saveVehicle"]),
    ActionDefinition(
      "dealer.readVIN", .dealer, name: "Read the VIN", tr: "VIN oku",
      summary: "High-detail capture, 17-character check and check digit; unreadable characters are never invented.",
      examplesTR: ["VIN oku", "VIN'i oku", "Şasi numarasını oku"], examplesEN: ["Read the VIN"],
      capabilities: [.camera, .network], offline: false, ui: "Explore → Dealer → Read VIN",
      status: .physicalTestRequired, keys: ["dealer.readVIN"], quick: true),
    ActionDefinition(
      "dealer.recall", .dealer, name: "Check recalls", tr: "Recall kontrol et",
      summary: "Canadian recall research with sources and dates; never claims \"no recalls\" from a model search.",
      examplesTR: ["[vehicle] Recall kontrol et", "[vehicle] Recall'una bak"], examplesEN: ["[vehicle] Check recalls"],
      capabilities: [.network, .dealerSession], offline: false, ui: "Explore → Dealer → vehicle → Research",
      keys: ["dealer.recallCheck"]),
    ActionDefinition(
      "dealer.readOdometer", .dealer, name: "Read the odometer", tr: "Kilometreyi oku",
      summary: "Reads the total distance from the cluster; unclear readings are not saved.",
      examplesTR: ["Kilometreyi oku", "Kilometre"], examplesEN: ["Read the odometer"],
      capabilities: [.camera, .network], offline: false, ui: "Explore → Dealer → Odometer",
      status: .physicalTestRequired, keys: ["dealer.readOdometer"]),
    ActionDefinition(
      "dealer.setOdometer", .dealer, name: "Say the odometer", tr: "Kilometreyi söyle",
      summary: "Saves a spoken reading (km or miles).", examplesTR: ["Kilometre 45 bin 320"],
      examplesEN: ["Odometer 28,500 miles"], parameters: [.init("reading", .number, "The reading")], undo: .supported,
      ui: "Explore → Dealer → vehicle", keys: ["dealer.setOdometer"]),
    ActionDefinition(
      "dealer.damage", .dealer, name: "Add damage", tr: "Hasar ekle",
      summary: "Zone and kind from your words (Turkish or English), linked to the vehicle.",
      examplesTR: [
        "Hasar ekle: sağ ön çamurluk çizik", "Hasar: ön cam çatlak", "[vehicle] Sağ ön jant çizik, not et",
      ],
      examplesEN: ["Add damage: rear bumper scratch"],
      parameters: [.init("damage", .text, "Where and what")], undo: .supported, ui: "Explore → Dealer → vehicle → Damage",
      keys: ["dealer.addDamage"]),
    ActionDefinition(
      "dealer.photoChecklist", .dealer, name: "Photo checklist", tr: "Foto checklist",
      summary: "The photos still missing for the active vehicle.",
      examplesTR: ["Foto checklist", "Hangi fotoğraflar kaldı", "[vehicle] Kaç foto kaldı?"], examplesEN: ["Photo checklist"],
      ui: "Explore → Dealer → vehicle → Photo checklist", keys: ["dealer.photoChecklist"]),
    ActionDefinition(
      "dealer.deliveryChecklist", .dealer, name: "Delivery checklist", tr: "Teslim listesi",
      summary: "What is left before delivery.", examplesTR: ["Delivery checklist", "Teslim listesi"],
      examplesEN: ["Delivery checklist"], ui: "Explore → Dealer → vehicle → Delivery checklist",
      keys: ["dealer.deliveryChecklist"]),
    ActionDefinition(
      "dealer.market", .dealer, name: "Market research", tr: "Piyasa araştırması",
      summary: "Comparable listings with sources and dates; a suggestion, never the price.",
      examplesTR: ["Piyasa bak", "Kanada piyasasına bak"], examplesEN: ["Check the market"],
      capabilities: [.network], offline: false, ui: "Explore → Dealer → vehicle → Research",
      keys: ["dealer.marketResearch"]),
    ActionDefinition(
      "dealer.listing", .dealer, name: "Draft a listing", tr: "İlan hazırla",
      summary: "Only recorded facts, damage stated, no price; saved as a note.",
      examplesTR: ["İlan hazırla"], examplesEN: ["Write a listing"], capabilities: [.network], offline: false,
      ui: "Explore → Dealer → vehicle → Research", keys: ["dealer.listing"]),
    ActionDefinition(
      "dealer.summary", .dealer, name: "Vehicle summary", tr: "Araç durumu",
      summary: "The active vehicle's recorded facts.", examplesTR: ["Araç durumu"], examplesEN: ["Vehicle summary"],
      ui: "Explore → Dealer → vehicle", keys: ["dealer.vehicleSummary"]),
    ActionDefinition(
      "dealer.briefing", .dealer, name: "Dealer briefing", tr: "Bayi özeti",
      summary: "Today's vehicles, open ones, missing photos and damage notes.",
      examplesTR: ["Bayi özeti", "Bugün dealerde ne var?"], examplesEN: ["Dealer briefing"],
      ui: "Explore → Dealer", keys: ["dealer.dealerBriefing"]),
    ActionDefinition(
      "dealer.decodeVIN", .dealer, name: "Decode the VIN", tr: "VIN'i çöz",
      summary: "NHTSA vPIC decode (keyless); only a clean decode fills the vehicle, equipment marked VIN decoded.",
      examplesTR: ["VIN'i çöz", "VIN'i çözümle"], examplesEN: ["Decode the VIN"],
      capabilities: [.network, .dealerSession], offline: false, ui: "Explore → Dealer → vehicle → Decode VIN",
      status: .working, keys: ["dealer.decodeVIN"]),
    ActionDefinition(
      "dealer.readTire", .dealer, name: "Read the tire", tr: "Lastiği oku",
      summary: "Size and DOT date from the sidewall, copied exactly; tread depth is never estimated.",
      examplesTR: ["Lastiği oku", "[vehicle] Sağ ön lastiği oku"], examplesEN: ["Read the tire"],
      parameters: [.init("position", .text, required: false, "Which tire")],
      capabilities: [.camera, .network], offline: false, ui: "Explore → Dealer → vehicle → Tires",
      status: .physicalTestRequired, keys: ["dealer.readTire"]),
    ActionDefinition(
      "dealer.dashboard", .dealer, name: "Warning lights", tr: "Uyarı ışıkları",
      summary: "The lights clearly lit on the cluster, by name and colour; no diagnosis.",
      examplesTR: ["Uyarı ışıklarına bak", "Gösterge paneline bak"], examplesEN: ["Check the warning lights"],
      capabilities: [.camera, .network], offline: false, ui: "Explore → Dealer → vehicle → Warning lights",
      status: .physicalTestRequired, keys: ["dealer.readDashboard"]),
    ActionDefinition(
      "dealer.conditionReport", .dealer, name: "Condition report", tr: "Kondisyon raporu",
      summary: "Damage, tires, lights, checked and unchecked areas, photos; saved as a note. Not a safety inspection.",
      examplesTR: ["Kondisyon raporu", "Hasar raporu hazırla"], examplesEN: ["Condition report"],
      ui: "Explore → Dealer → vehicle → Condition report", status: .working, keys: ["dealer.conditionReport"]),
    ActionDefinition(
      "dealer.serviceHandoff", .dealer, name: "Service handoff", tr: "Servis notu",
      summary: "A note for the service department: VIN, odometer, lights, damage, tires, recalls to verify, open tasks.",
      examplesTR: ["Servis notu hazırla", "Servise devret"], examplesEN: ["Service handoff"],
      ui: "Explore → Dealer → vehicle → Service handoff", status: .working, keys: ["dealer.serviceHandoff"]),
    ActionDefinition(
      "dealer.lotSave", .dealer, name: "Save the vehicle's spot", tr: "Aracın yerini kaydet",
      summary: "One location fix for where the vehicle stands on the lot.",
      examplesTR: ["[vehicle] Aracın yerini kaydet"], examplesEN: ["[vehicle] Save the vehicle location"],
      permissions: [.location], capabilities: [.location, .dealerSession], undo: .supported,
      ui: "Explore → Dealer → vehicle → Lot spot", status: .physicalTestRequired, keys: ["dealer.saveLotSpot"]),
    ActionDefinition(
      "dealer.lotFind", .dealer, name: "Find the vehicle", tr: "Araç nerede?",
      summary: "Walking directions to the vehicle's saved spot (Apple Maps, after a tap).",
      examplesTR: ["[vehicle] Araç nerede duruyor?", "[vehicle] Aracın yeri neresi?"], examplesEN: ["[vehicle] Where is this vehicle?"],
      confirmation: .tapOnPhone, capabilities: [.dealerSession], ui: "Explore → Dealer → vehicle → Lot spot",
      keys: ["dealer.findLotSpot"]),
    ActionDefinition(
      "dealer.partNumber", .dealer, name: "Read a part number", tr: "Parça numarasını oku",
      summary: "The part number copied exactly (? for unclear characters), saved to the vehicle's research.",
      examplesTR: ["Parça numarasını oku"], examplesEN: ["Read the part number"],
      capabilities: [.camera, .network], offline: false, ui: "Explore → Dealer → vehicle → Research",
      status: .physicalTestRequired, keys: ["dealer.readPartNumber"]),
    ActionDefinition(
      "dealer.areaClear", .dealer, name: "Area checked", tr: "Bölge temiz",
      summary: "Marks one area of the walk-around as checked with no damage.",
      examplesTR: ["[vehicle] Sol taraf temiz", "[vehicle] Ön taraf hasarsız"], examplesEN: ["[vehicle] Interior is clean"],
      parameters: [.init("area", .text, "front, rear, left, right, roof, interior, underbody, wheels, engine bay")],
      undo: .supported, ui: "Explore → Dealer → vehicle → Condition report", status: .working, keys: ["dealer.areaClear"]),
    ActionDefinition(
      "dealer.export", .dealer, name: "Share the vehicle record", tr: "Aracı dışa aktar",
      summary: "The condition report through the share sheet; AutoLoom Media is never connected automatically.",
      examplesTR: ["Aracı dışa aktar"], examplesEN: ["Export the vehicle"], confirmation: .tapOnPhone,
      voiceOnly: "The share sheet is the UI", status: .working, keys: ["dealer.exportVehicle"]),
    ActionDefinition(
      "dealer.vehicleQuestion", .dealer, name: "Ask about the vehicle", tr: "Araç hakkında sor",
      summary: "\"Kaç kilometre?\", \"VIN'i neydi?\": answered from the active vehicle's record.",
      examplesTR: ["[vehicle] Kaç kilometre?", "[vehicle] VIN'i neydi?", "[vehicle] Bu araç tamam mı?"],
      examplesEN: ["[vehicle] What's the mileage?"], ui: "Explore → Dealer → vehicle", keys: ["vehicleQuestion"]),
  ]

  private static let daily: [ActionDefinition] = [
    ActionDefinition(
      "timer.start", .automation, name: "Set a timer", tr: "Zamanlayıcı kur",
      summary: "A timer with a local notification.",
      examplesTR: ["10 dakika timer kur", "Yumurta için 7 dakika timer"], examplesEN: ["Set a timer for 10 minutes"],
      negatives: ["Timer nasıl kurulur?"], parameters: [.init("duration", .duration, "How long")],
      permissions: [.notifications], undo: .supported, localPriority: true, ui: "Explore → Timers",
      keys: ["timer.start"], quick: true),
    ActionDefinition(
      "timer.cancel", .automation, name: "Cancel the timer", tr: "Zamanlayıcıyı durdur",
      summary: "Stops the running timer.", examplesTR: ["Timerı durdur", "Zamanlayıcıyı iptal et"],
      localPriority: true, ui: "Explore → Timers → Cancel", keys: ["timer.cancel"]),
    ActionDefinition(
      "timer.remaining", .automation, name: "Time left", tr: "Ne kadar kaldı?",
      summary: "The time left on the running timer.", examplesTR: ["Timer ne kadar kaldı", "[timer] Ne kadar kaldı?"],
      negatives: ["Eve ne kadar kaldı?"], ui: "Assistant → timer chip", keys: ["timer.remaining"]),
    ActionDefinition(
      "shopping.add", .automation, name: "Add to the shopping list", tr: "Alışveriş listesine ekle",
      summary: "Items to the shopping list on this iPhone.",
      examplesTR: ["Alışveriş listesine süt ve ekmek ekle", "Sütü alışveriş listesine ekle"],
      examplesEN: ["Add milk and tomato to my shopping list"], parameters: [.init("items", .items, "What to add")],
      undo: .supported, appIntent: "AddToShoppingListIntent", ui: "Explore → Shopping list", keys: ["shopping.add"],
      quick: true),
    ActionDefinition(
      "shopping.read", .automation, name: "Read the shopping list", tr: "Alışveriş listesini oku",
      summary: "What is on the list.", examplesTR: ["Alışveriş listemde ne var"], examplesEN: ["What's on my shopping list"],
      ui: "Explore → Shopping list", keys: ["shopping.read"]),
    ActionDefinition(
      "shopping.remove", .automation, name: "Remove from the list", tr: "Listeden çıkar",
      summary: "Removes an item.", examplesTR: ["Sütü alışveriş listesinden çıkar"],
      examplesEN: ["Remove milk from the shopping list"], ui: "Explore → Shopping list → swipe", keys: ["shopping.remove"]),
    ActionDefinition(
      "parking.save", .navigation, name: "Save the parking spot", tr: "Park yerini kaydet",
      summary: "One location fix when asked plus your words; never tracking.",
      examplesTR: ["Park yerimi kaydet", "Park yerimi kaydet: B2 katı 45 numara", "Arabamı B2 katına park ettim"],
      examplesEN: ["Remember where I parked"], permissions: [.location], capabilities: [.location], undo: .supported,
      ui: "Explore → Daily → Parking", status: .physicalTestRequired, keys: ["parking.save"]),
    ActionDefinition(
      "parking.recall", .navigation, name: "Where did I park?", tr: "Arabam nerede?",
      summary: "The saved spot, or a memory about the car.", examplesTR: ["Arabam nerede?", "Arabamı nereye park ettim?"],
      examplesEN: ["Where did I park?"], ui: "Explore → Daily → Parking", keys: ["parking.recall"]),
    ActionDefinition(
      "parking.directions", .navigation, name: "Take me to my car", tr: "Beni arabama götür",
      summary: "Walking directions to the saved spot.", examplesTR: ["Beni arabama götür"], examplesEN: ["Take me to my car"],
      ui: "Explore → Daily → Parking → Directions", keys: ["parking.directions"]),
    ActionDefinition(
      "parking.clear", .navigation, name: "Clear the parking spot", tr: "Park yerini sil",
      summary: "Deletes the saved spot.", examplesTR: ["Park yerini sil"], examplesEN: ["Forget my parking spot"],
      ui: "Explore → Daily → Parking → Clear", keys: ["parking.clear"]),
  ]

  private static let phone: [ActionDefinition] = [
    ActionDefinition(
      "phone.call", .phone, name: "Call", tr: "Ara",
      summary: "Finds the contact; iOS asks before the call starts.",
      examplesTR: ["Ahmet'i ara", "Annemi ara"], examplesEN: ["Call Ahmet"],
      parameters: [.init("contact", .contact, "Who")], risk: .confirm, confirmation: .tapOnPhone,
      permissions: [.contacts], undo: .impossible, voiceOnly: "The Phone app is the UI", keys: ["call"]),
    ActionDefinition(
      "phone.message", .phone, name: "Write a message", tr: "Mesaj yaz",
      summary: "Prepares the message in Messages; you tap Send.",
      examplesTR: ["Ahmet'e 10 dakika gecikeceğim diye mesaj yaz", "Ahmet'e mesaj at: geliyorum"],
      examplesEN: ["Text Ahmet that I'm late"], parameters: [.init("contact", .contact, "Who"), .init("body", .text, "What")],
      risk: .strongConfirm, confirmation: .tapOnPhone, permissions: [.contacts], undo: .impossible,
      voiceOnly: "Messages is the UI", keys: ["message", "ask.messageBody", "ask.messageRecipient", "ask.chooseContact"]),
    ActionDefinition(
      "contact.find", .phone, name: "Find a contact", tr: "Kişi bul",
      summary: "A phone number from Contacts.", examplesTR: ["Ahmet'in numarası ne?"], examplesEN: ["What's Ahmet's number"],
      permissions: [.contacts], voiceOnly: "Contacts is the UI", keys: ["findContact"]),
    ActionDefinition(
      "maps.directions", .navigation, name: "Directions", tr: "Yol tarifi",
      summary: "Apple Maps with directions (home and work from memory).",
      examplesTR: ["Beni eve götür", "Kadıköy'e yol tarifi aç"], examplesEN: ["Take me home"],
      parameters: [.init("destination", .place, "Where")], confirmation: .whenAmbiguous, offline: false,
      voiceOnly: "Apple Maps is the UI", keys: ["directions"]),
    ActionDefinition(
      "maps.nearby", .navigation, name: "Find nearby", tr: "Yakında bul",
      summary: "A Maps search around you.", examplesTR: ["En yakın benzinliğe götür", "En yakın eczane nerede"],
      offline: false, voiceOnly: "Apple Maps is the UI", keys: ["nearby"]),
    ActionDefinition(
      "maps.inView", .navigation, name: "Directions to the address in view", tr: "Buraya yol tarifi",
      summary: "The camera reads the address; you check it and tap.", examplesTR: ["[camera] Buraya yol tarifi aç"], examplesEN: ["[camera] Get directions to this place"],
      risk: .confirm, confirmation: .tapOnPhone, capabilities: [.camera, .network], offline: false,
      voiceOnly: "The camera is the input", keys: ["directionsInView"]),
    ActionDefinition(
      "text.copy", .general, name: "Copy", tr: "Kopyala",
      summary: "Copies the last answer; says so only after the clipboard changed.",
      examplesTR: ["[answer] Bunu kopyala", "Şunu kopyala: 4512"], localPriority: true,
      voiceOnly: "Long-press any answer on screen to copy", keys: ["copyText"]),
    ActionDefinition(
      "text.share", .general, name: "Share", tr: "Paylaş",
      summary: "The share sheet with the last answer.", examplesTR: ["[answer] Bunu paylaş"], examplesEN: ["[answer] Share this"], confirmation: .tapOnPhone,
      voiceOnly: "The share sheet is the UI", keys: ["shareText"]),
  ]

  // MARK: Lookup

  static func definition(_ id: String) -> ActionDefinition? {
    byID[id]
  }

  private static let byID: [String: ActionDefinition] = Dictionary(
    all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

  private static let byKey: [String: ActionDefinition] = {
    var map: [String: ActionDefinition] = [:]
    for definition in all {
      for key in definition.keys where map[key] == nil { map[key] = definition }
    }
    return map
  }()

  /// The catalog entry for something the parser decided.
  static func definition(for intent: VoiceIntent) -> ActionDefinition? {
    byKey[intent.catalogKey]
  }

  static func definitions(in category: ActionDefinition.Category) -> [ActionDefinition] {
    all.filter { $0.category == category }
  }

  /// Entries whose name, summary or examples match (the Command Library).
  static func search(_ text: String) -> [ActionDefinition] {
    let words = MemorySearch.tokens(text)
    guard !words.isEmpty else { return all }
    return all.map { definition -> (ActionDefinition, Double) in
      let haystack = ([definition.name, definition.nameTR, definition.summary] + definition.examplesTR + definition.examplesEN)
        .joined(separator: " ")
      return (definition, MemorySearch.lexicalScore(query: words, document: MemorySearch.tokens(haystack)))
    }
    .filter { $0.1 > 0 }
    .sorted { $0.1 > $1.1 }
    .map(\.0)
  }

  /// "[pending,timer] Ne kadar kaldı?" → (["pending", "timer"], "Ne kadar kaldı?").
  static func stripTags(_ example: String) -> (tags: Set<String>, text: String) {
    guard example.hasPrefix("["), let close = example.firstIndex(of: "]") else { return ([], example) }
    let tags = example[example.index(after: example.startIndex)..<close]
      .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    let text = example[example.index(after: close)...].trimmingCharacters(in: .whitespaces)
    return (Set(tags), text)
  }

  // MARK: Building intents from parameters (App Intents, palette, tools)

  /// The intent for an action and its parameters, or nil when the action
  /// needs words only the user can say (then the words are asked for).
  static func intent(for id: String, parameters: [String: String] = [:], now: Date = Date()) -> VoiceIntent? {
    func text(_ key: String) -> String? {
      let value = parameters[key]?.trimmingCharacters(in: .whitespacesAndNewlines)
      return value?.isEmpty == false ? value : nil
    }
    func time(_ key: String) -> ParsedTime? {
      text(key).flatMap { TimePhraseParser.parse($0, now: now) }
    }
    switch id {
    case "note.create":
      guard let words = text("text") else { return VoiceIntent.ask(.note) }
      return VoiceIntent.saveNote(text: VoiceActionIntentBridge.capitalizedFirst(words))
    case "note.list": return .listNotes
    case "note.search": return text("query").map { .searchNotes($0) }
    case "memory.save":
      guard let words = text("text") else { return VoiceIntent.ask(.memory) }
      return VoiceIntent.saveMemory(text: VoiceActionIntentBridge.capitalizedFirst(words), kind: nil)
    case "memory.list": return .listMemories
    case "memory.findVisual": return .findVisual(text("what") ?? "")
    case "vision.whatChanged": return .whatChanged
    case "document.summarize": return .document(.summarize)
    case "document.receipt": return .document(.saveReceipt)
    case "document.spending": return .document(.spending)
    case "task.create":
      guard let title = text("title") else { return .ask(.task) }
      var due = time("due")
      if due == nil, let iso = text("dueISO"), let date = ISO8601DateFormatter().date(from: iso) {
        due = ParsedTime(
          date: date, hasTime: true, isAmbiguous: false, alternative: nil, usedDefaultTime: false, matched: "shortcut",
          hasDay: true)
      }
      return .createTask(title: VoiceActionIntentBridge.capitalizedFirst(title), time: due)
    case "task.list": return .listTasks
    case "reminder.create":
      guard let title = text("title") else { return .ask(.reminderTitle) }
      guard let when = time("time") else { return .ask(.reminderTime(title: title)) }
      return .createReminder(title: VoiceActionIntentBridge.capitalizedFirst(title), time: when)
    case "calendar.read": return .readCalendar(.today)
    case "dayplan.read": return .dayPlan(.today)
    case "camera.photo": return .takePhoto(label: nil, note: text("note"), caption: nil)
    case "camera.recordStart": return .startRecording(note: text("note"))
    case "camera.recordStop": return .stopRecording
    case "camera.recordStatus": return .recordingStatus
    case "captures.saveToPhotos": return .saveCaptureToPhotos
    case "code.read": return .readCode
    case "translation.view": return .translateView(language: text("language") ?? L.t("English", "Türkçe"))
    case "dealer.start": return .dealer(.startVehicle)
    case "dealer.next": return .dealer(.nextVehicle)
    case "dealer.finish": return .dealer(.finishVehicle)
    case "dealer.saveVehicle": return .dealer(.saveVehicle)
    case "dealer.readVIN": return .dealer(.readVIN)
    case "dealer.recall": return .dealer(.recallCheck)
    case "dealer.readOdometer": return .dealer(.readOdometer)
    case "dealer.damage": return text("damage").map { .dealer(.addDamage(VoiceActionIntentBridge.capitalizedFirst($0))) }
    case "dealer.photoChecklist": return .dealer(.photoChecklist)
    case "dealer.deliveryChecklist": return .dealer(.deliveryChecklist)
    case "dealer.market": return .dealer(.marketResearch)
    case "dealer.listing": return .dealer(.listing)
    case "dealer.summary": return .dealer(.summary)
    case "dealer.briefing": return .dealer(.briefing)
    case "dealer.decodeVIN": return .dealer(.decodeVIN)
    case "dealer.readTire": return .dealer(.readTire(text("position")))
    case "dealer.dashboard": return .dealer(.readDashboard)
    case "dealer.conditionReport": return .dealer(.conditionReport)
    case "dealer.serviceHandoff": return .dealer(.serviceHandoff)
    case "dealer.lotSave": return .dealer(.saveLotSpot)
    case "dealer.lotFind": return .dealer(.findLotSpot)
    case "dealer.partNumber": return .dealer(.readPartNumber)
    case "dealer.areaClear": return text("area").flatMap(VehicleArea.parse).map { .dealer(.areaClear($0.rawValue)) }
    case "dealer.export": return .dealer(.exportVehicle)
    case "timer.start":
      guard let seconds = text("duration").flatMap({ DurationParser.seconds(in: $0) }) else { return nil }
      return .timer(.start(seconds: Int(seconds.rounded()), label: text("label")))
    case "timer.cancel": return .timer(.cancel)
    case "timer.remaining": return .timer(.remaining)
    case "shopping.add":
      let items = text("items").map(ShoppingListStore.split) ?? []
      return items.isEmpty ? nil : .shopping(.add(items))
    case "shopping.read": return .shopping(.read)
    case "shopping.remove": return text("item").map { .shopping(.remove($0)) }
    case "parking.save": return .parking(.save(note: text("note")))
    case "parking.recall": return .parking(.recall)
    case "parking.directions": return .parking(.directions)
    case "parking.clear": return .parking(.clear)
    case "undo.last": return .undoLast
    case "help.capabilities": return .capabilities(text("topic"))
    case "search.global": return text("query").map { .search($0) }
    case "routine.startWork": return .routine(.startWork)
    case "routine.briefing": return .routine(.briefing)
    case "routine.eveningReview": return .routine(.eveningReview)
    case "routine.weeklyReview": return .routine(.weeklyReview)
    case "phone.call": return text("contact").map { .call(contact: $0) }
    case "maps.directions": return text("destination").map { .directions($0) }
    default: return nil
    }
  }

  // MARK: Running

  /// Runs an action through the one executor every voice command uses, so
  /// App Intents, the palette and agent tools behave exactly like speech.
  @MainActor
  static func run(_ id: String, parameters: [String: String] = [:], transcript: String? = nil) async -> IntentOutcome {
    guard let definition = definition(id) else {
      return IntentOutcome(spoken: "That action does not exist.", reply: L.t("Unknown action.", "Bilinmeyen işlem."), failed: "unknown action")
    }
    guard definition.risk != .blocked else {
      return IntentOutcome(
        spoken: "This action is blocked by policy.", reply: L.t("Blocked.", "Engellendi."), failed: "blocked")
    }
    let orchestrator = AssistantOrchestrator.shared
    let words = transcript ?? parameters["text"] ?? parameters["query"] ?? stripTags(definition.examplesTR.first ?? id).text
    if let intent = intent(for: id, parameters: parameters) {
      return await orchestrator.runVoiceIntent(VoiceBridgeDecision(intent, "catalog \(id)"), transcript: words)
    }
    if case .delegation(let word) = definition.route {
      let query = parameters["query"] ?? transcript ?? definition.summary
      switch word {
      case "live_vision_start":
        let text = LiveVisionController.shared.start()
        return IntentOutcome(spoken: text, reply: text)
      case "live_vision_stop":
        let text = LiveVisionController.shared.stop(reason: "stopped by the user")
        return IntentOutcome(spoken: text, reply: text)
      default:
        let kind: AssistantTaskKind = word == "web" ? .webSearch : word == "reasoning" ? .deepReasoning : .vision
        let result = await orchestrator.runBridgeTask(kind, query: query, detail: word == "vision_read" ? .high : .standard)
        return IntentOutcome(spoken: result.speakable, reply: result.display ?? result.speakable, failed: result.failed)
      }
    }
    // The words themselves: the same parser as speech.
    if let decision = VoiceActionIntentBridge.decide(words, context: orchestrator.bridgeContext()) {
      return await orchestrator.runVoiceIntent(decision, transcript: words)
    }
    return IntentOutcome(
      spoken: "This action needs a few more words from the user. Ask briefly what exactly they want.",
      reply: L.t("Say it with the details, for example: ", "Ayrıntısıyla söyle, örneğin: ") + (definition.displayExamples.first ?? ""),
      failed: "missing parameters")
  }

  // MARK: Agent tools and instructions

  /// JSON-schema tool definitions for models that call tools.
  static func toolSchemas(including ids: Set<String>? = nil) -> [[String: Any]] {
    all.filter { definition in
      definition.risk != .blocked && definition.route != .conversation && (ids?.contains(definition.id) ?? true)
    }
    .map { definition in
      var properties: [String: Any] = [:]
      for parameter in definition.parameters {
        properties[parameter.name] = ["type": "string", "description": parameter.summary]
      }
      let examples = definition.examplesEN.prefix(1).map { stripTags($0).text }
      return [
        "type": "function",
        "name": toolName(definition.id),
        "description": definition.summary + (examples.isEmpty ? "" : " Example: \"\(examples[0])\"."),
        "parameters": [
          "type": "object",
          "properties": properties,
          "required": definition.parameters.filter(\.required).map(\.name),
        ] as [String: Any],
      ]
    }
  }

  static func toolName(_ id: String) -> String { id.replacingOccurrences(of: ".", with: "_") }

  static func id(forTool name: String) -> String? {
    all.first { toolName($0.id) == name }?.id
  }

  /// One compact line per category for the voice model's instructions.
  static var instructionsSummary: String {
    ActionDefinition.Category.allCases.compactMap { category -> String? in
      let entries = definitions(in: category).filter { $0.route == .local }
      guard !entries.isEmpty else { return nil }
      return "- \(category.rawValue): " + entries.map { $0.examplesTR.first.map { stripTags($0).text } ?? $0.name }
        .prefix(8).joined(separator: "; ")
    }.joined(separator: "\n")
  }
}

extension VoiceIntent {
  /// The ActionCatalog key ("saveNote", "dealer.readVIN", "timer.start").
  var catalogKey: String {
    switch self {
    case .confirmPending(let yes): yes ? "confirmPending.yes" : "confirmPending.no"
    case .choosePendingTime: "choosePendingTime"
    case .cancelTasks: "cancelTasks"
    case .dropAwaiting: "dropAwaiting"
    case .saveNote: "saveNote"
    case .listNotes: "listNotes"
    case .searchNotes: "searchNotes"
    case .deleteNote: "deleteNote"
    case .saveMemory: "saveMemory"
    case .setName: "setName"
    case .askName: "askName"
    case .recallMemory: "recallMemory"
    case .recallConversation: "recallConversation"
    case .listMemories: "listMemories"
    case .forgetMemory: "forgetMemory"
    case .visualMemory: "visualMemory"
    case .createReminder: "createReminder"
    case .locationReminder: "locationReminder"
    case .notify: "notify"
    case .createTask: "createTask"
    case .createEvent: "createEvent"
    case .readCalendar: "readCalendar"
    case .listTasks: "listTasks"
    case .completeTask: "completeTask"
    case .moveTask: "moveTask"
    case .dayPlan: "dayPlan"
    case .translateView: "translateView"
    case .call: "call"
    case .message: "message"
    case .findContact: "findContact"
    case .directions: "directions"
    case .nearby: "nearby"
    case .directionsInView: "directionsInView"
    case .copyText: "copyText"
    case .shareText: "shareText"
    case .routine(let routine): "routine." + routine.rawValue
    case .takePhoto: "takePhoto"
    case .startRecording: "startRecording"
    case .stopRecording: "stopRecording"
    case .recordingStatus: "recordingStatus"
    case .saveCaptureToPhotos: "saveCaptureToPhotos"
    case .dealer(let command): "dealer." + command.name
    case .timer(let command): "timer." + command.key
    case .undoLast: "undoLast"
    case .shopping(let command): "shopping." + command.key
    case .parking(let command): "parking." + command.key
    case .readCode: "readCode"
    case .capabilities: "capabilities"
    case .search: "search"
    case .vehicleQuestion: "vehicleQuestion"
    case .findVisual: "findVisual"
    case .whatChanged: "whatChanged"
    case .document(let command): "document." + command.key
    case .correctPending: "correctPending"
    case .graph: "graph"
    case .ask(let awaiting): "ask." + awaiting.label
    case .classify(let kind, _): "classify." + kind.rawValue
    }
  }
}

extension TimerCommand {
  var key: String {
    switch self {
    case .start: "start"
    case .cancel: "cancel"
    case .remaining: "remaining"
    }
  }
}

extension ShoppingCommand {
  var key: String {
    switch self {
    case .add: "add"
    case .read: "read"
    case .remove: "remove"
    }
  }
}

extension ParkingCommand {
  var key: String {
    switch self {
    case .save: "save"
    case .recall: "recall"
    case .directions: "directions"
    case .clear: "clear"
    }
  }
}
