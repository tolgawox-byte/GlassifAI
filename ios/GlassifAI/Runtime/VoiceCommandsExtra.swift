import Foundation

/// A fact about the active Dealer Mode vehicle ("Kaç kilometre?").
enum VehicleField: String, CaseIterable, Equatable {
  case odometer, vin, color, damage, stock, complete, photos
}

/// Several explicit commands in one sentence ("VIN'i oku, recall kontrol et
/// ve yarın tekrar bakmam için görev oluştur"). Each part must be a command
/// the phone understands on its own; otherwise the sentence is left whole.
enum ActionGraph {
  struct Step: Equatable {
    let text: String
    let intent: VoiceIntent
  }

  /// Longest first, so ", sonra" is not split as "," + "sonra".
  static let separators = [
    ", ve sonra ", " ve sonra ", ", sonra da ", ", sonra ", " sonra da ", " ardından ", ", ardından ",
    ", and then ", " and then ", ", then ", " then ", ", ", " ve ", " and ",
  ]

  static func split(_ text: String) -> [String] {
    var parts = [text]
    for separator in separators {
      parts = parts.flatMap { $0.components(separatedBy: separator) }
    }
    return parts
      .map { $0.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".,;!?"))) }
      .filter { !$0.isEmpty }
  }

  /// The steps, or nil when the sentence is one command (or not commands).
  static func plan(_ text: String, context: VoiceBridgeContext, now: Date = Date()) -> [Step]? {
    // Words after a colon belong to their command ("not al: süt ve ekmek").
    let head: String
    var tail = ""
    if let colon = text.firstIndex(of: ":") {
      head = String(text[..<colon])
      tail = String(text[colon...])
    } else {
      head = text
    }
    var segments = split(head)
    guard segments.count >= 2, segments.count <= 5 else { return nil }
    segments[segments.count - 1] += tail
    var steps: [Step] = []
    for segment in segments {
      guard let decision = VoiceActionIntentBridge.decideSingle(segment, context: context, now: now),
            decision.level == .deterministic, decision.intent.isGraphStep else { return nil }
      steps.append(Step(text: segment, intent: decision.intent))
    }
    // "Süt ve ekmek" style splits give the same command twice.
    guard Set(steps.map { $0.intent.catalogKey }).count == steps.count else { return nil }
    return steps
  }
}

extension VoiceIntent {
  /// A command that may be one step of several in a sentence.
  var isGraphStep: Bool {
    switch self {
    case .ask, .classify, .graph, .dropAwaiting, .confirmPending, .choosePendingTime, .cancelTasks, .correctPending,
         .capabilities, .search, .findVisual, .whatChanged:
      false
    default:
      true
    }
  }

  /// Commands whose own parser already joins two verbs ("fotoğrafını çek ve
  /// not al: …" is one photo with a note).
  var handlesCompoundItself: Bool {
    switch self {
    case .takePhoto(_, let note, let caption): note != nil || caption != nil
    case .startRecording(let note): note != nil
    default: false
    }
  }
}

/// "Hayır, cumartesi": a corrected day keeps the time of day, a corrected
/// time keeps the day.
enum CorrectionMerge {
  static func merge(
    original: Date?,
    originalHasTime: Bool,
    correction: ParsedTime,
    calendar: Calendar = .current
  ) -> (date: Date, hasTime: Bool) {
    guard let original else { return (correction.date, correction.hasTime) }
    if correction.hasDay, !correction.hasTime, originalHasTime {
      var components = calendar.dateComponents([.year, .month, .day], from: correction.date)
      let clock = calendar.dateComponents([.hour, .minute], from: original)
      components.hour = clock.hour
      components.minute = clock.minute
      return (calendar.date(from: components) ?? correction.date, true)
    }
    if correction.hasTime, !correction.hasDay {
      var components = calendar.dateComponents([.year, .month, .day], from: original)
      let clock = calendar.dateComponents([.hour, .minute], from: correction.date)
      components.hour = clock.hour
      components.minute = clock.minute
      return (calendar.date(from: components) ?? correction.date, true)
    }
    return (correction.date, correction.hasTime)
  }
}

extension VoiceActionIntentBridge {
  // MARK: "What can you do?"

  static let capabilityPhrases: [[String]] = [
    ["neler", "yapabilirsin"], ["ne", "yapabilirsin"], ["neler", "yapabiliyorsun"], ["ne", "yapabiliyorsun"],
    ["hangi", "komutlar", "var"], ["komutlari", "goster"], ["komut", "listesi"], ["neler", "biliyorsun"],
    ["what", "can", "you", "do"], ["show", "me", "the", "commands"], ["what", "are", "your", "commands"],
    ["list", "the", "commands"], ["what", "are", "you", "able", "to", "do"],
  ]

  static func capabilities(_ u: Utterance) -> VoiceBridgeDecision? {
    guard u.count <= 9, firstPhrase(capabilityPhrases, in: u) != nil else { return nil }
    var topic: String?
    if u.containsAny(["bayi", "bayide", "dealer", "dealerde", "arac", "araclar", "araclarla"]) {
      topic = ActionDefinition.Category.dealer.rawValue
    } else if u.containsAny(["kamera", "kamerayla", "camera", "foto", "fotograf", "video"]) {
      topic = ActionDefinition.Category.camera.rawValue
    } else if u.containsAny(["gorev", "gorevler", "gorevlerle", "tasks", "hatirlatici", "takvim"]) {
      topic = ActionDefinition.Category.tasks.rawValue
    } else if u.containsAny(["hafiza", "hafizayla", "memory", "not", "notlar", "notlarla"]) {
      topic = ActionDefinition.Category.memory.rawValue
    }
    return VoiceBridgeDecision(.capabilities(topic), "capabilities question")
  }

  // MARK: Global search (after every other parser)

  static func globalSearch(_ u: Utterance) -> VoiceBridgeDecision? {
    guard u.count >= 3, u.count <= 16 else { return nil }
    let endings: [[String]] = [["bul"], ["bulur", "musun"], ["bulabilir", "misin"], ["goster"], ["gosterir", "misin"]]
    let cues: Set<String> = [
      "kaydettigim", "kaydettigimiz", "kaydettiklerimi", "kaydettigimi", "ilgili", "hakkinda", "cektigim", "cektigimiz",
      "fotograflarini", "fotograflari", "videolarini", "videolari", "notlarimda", "hafizada", "kayitlarda", "gecen",
      "aldigim", "yazdigim",
    ]
    if endings.contains(where: { u.ends(with: $0) }), u.containsAny(cues) {
      return VoiceBridgeDecision(.search(u.text), "global search")
    }
    let english: [[String]] = [
      ["find", "everything"], ["find", "what", "i", "saved"], ["search", "autoloom"], ["search", "my"],
      ["find", "my", "photos"], ["show", "my", "photos"], ["find", "anything", "about"],
    ]
    if english.contains(where: { u.starts(with: $0) }) {
      return VoiceBridgeDecision(.search(u.text), "global search")
    }
    return nil
  }

  // MARK: Questions about the active vehicle

  static let vehicleQuestionPhrases: [([String], VehicleField)] = [
    (["kac", "kilometre"], .odometer), (["kilometresi", "kac"], .odometer), (["kilometresi", "ne"], .odometer),
    (["kac", "km"], .odometer), (["whats", "the", "mileage"], .odometer), (["what", "is", "the", "mileage"], .odometer),
    (["how", "many", "miles"], .odometer), (["how", "many", "kilometers"], .odometer),
    (["vini", "neydi"], .vin), (["vin", "neydi"], .vin), (["vini", "ne"], .vin), (["vin", "ne"], .vin),
    (["sasi", "numarasi", "ne"], .vin), (["whats", "the", "vin"], .vin), (["what", "is", "the", "vin"], .vin),
    (["rengi", "ne"], .color), (["ne", "renk"], .color), (["what", "color"], .color),
    (["hasarlari", "neler"], .damage), (["ne", "hasar", "var"], .damage), (["hangi", "hasarlar"], .damage),
    (["what", "damage"], .damage), (["stok", "numarasi", "ne"], .stock), (["stock", "number"], .stock),
    (["bu", "arac", "tamam", "mi"], .complete), (["arac", "tamam", "mi"], .complete),
    (["is", "this", "vehicle", "done"], .complete), (["ne", "eksik"], .photos), (["neler", "eksik"], .photos),
    (["whats", "missing"], .photos),
  ]

  static func vehicleQuestion(_ u: Utterance, _ context: VoiceBridgeContext) -> VoiceBridgeDecision? {
    guard context.activeVehicle, u.count <= 8 else { return nil }
    let fillers: Set<String> = [
      "peki", "bu", "bunun", "aracin", "arabanin", "da", "de", "acaba", "su", "o", "onun", "simdi", "of", "this", "car",
      "the", "vehicle", "and", "so", "now",
    ]
    for (phrase, field) in vehicleQuestionPhrases {
      guard let range = u.range(of: phrase) else { continue }
      var rest = u
      rest.remove(range)
      guard rest.isOnly(fillers) else { continue }
      return VoiceBridgeDecision(.vehicleQuestion(field), "vehicle question")
    }
    return nil
  }

  // MARK: Moving a task

  static func moveTask(_ u: Utterance, _ now: Date) -> VoiceBridgeDecision? {
    guard u.count <= 12 else { return nil }
    let turkishEndings: [[String]] = [["tasi"], ["ertele"], ["tasir", "misin"], ["erteler", "misin"], ["kaydir"]]
    let turkish = turkishEndings.contains { u.ends(with: $0) }
    let english = u.starts(with: ["move"]) || u.starts(with: ["postpone"]) || u.starts(with: ["reschedule"])
    guard turkish || english, let time = TimePhraseParser.parse(u.text, now: now) else { return nil }
    var rest = u
    rest.removeTimeWords(time)
    rest.removeKeys([
      "tasi", "ertele", "tasir", "misin", "erteler", "kaydir", "move", "postpone", "reschedule", "to", "it", "that",
      "this", "bunu", "onu", "sunu", "lutfen", "please", "gorevi", "gorevini", "task", "the", "my",
    ])
    return VoiceBridgeDecision(.moveTask(title: rest.isEmpty ? nil : rest.text, time: time), "move task")
  }
}

// MARK: Visual Second Brain and Live Vision questions

extension VoiceActionIntentBridge {
  static let seeVerbs: Set<String> = [
    "gordum", "gormustum", "gorduk", "gormustuk", "gordugum", "gordugumu", "gorduydum", "gormusum", "saw", "seen",
  ]

  /// "Anahtarımı en son nerede gördüm?", "where did I last see my keys?",
  /// "bugün neler gördüm?", "görsel anılarımı göster".
  static func visualRecall(_ u: Utterance) -> VoiceBridgeDecision? {
    guard u.count <= 10 else { return nil }
    let whereWords: Set<String> = ["nerede", "nerde", "nereye", "where"]
    if u.containsAny(whereWords), u.containsAny(seeVerbs) || (u.starts(with: ["where"]) && u.contains("see")) {
      var object = u
      object.removeKeys(whereWords.union(seeVerbs).union([
        "en", "son", "ben", "acaba", "did", "i", "last", "see", "my", "the", "a", "an", "have", "had", "do",
      ]))
      return VoiceBridgeDecision(.findVisual(object.text), "where did I see it (visual memories)")
    }
    let today: [[String]] = [
      ["bugun", "neler", "gordum"], ["bugun", "ne", "gordum"], ["what", "did", "i", "see", "today"],
    ]
    if today.contains(where: { u.range(of: $0) != nil }) {
      return VoiceBridgeDecision(.findVisual(""), "what did I see today")
    }
    let gallery: [[String]] = [["gorsel", "anilarimi"], ["gorsel", "hafizami"], ["gorsel", "anilarim"], ["visual", "memories"]]
    if gallery.contains(where: { u.range(of: $0) != nil }),
       u.containsAny(["goster", "ac", "show", "open", "neler", "listele", "var"]) {
      return VoiceBridgeDecision(.findVisual(""), "visual memory gallery")
    }
    return nil
  }

  /// "Ne değişti?" — only while Live Vision is watching; otherwise the
  /// words are left to the conversation.
  static func whatChanged(_ u: Utterance, _ context: VoiceBridgeContext) -> VoiceBridgeDecision? {
    guard context.liveVisionActive, u.count <= 5 else { return nil }
    let phrases: [[String]] = [
      ["ne", "degisti"], ["neler", "degisti"], ["degisen", "ne"], ["bir", "sey", "degisti", "mi"], ["birsey", "degisti", "mi"],
      ["ne", "farkli"], ["what", "changed"], ["whats", "changed"], ["what", "has", "changed"], ["anything", "changed"],
      ["whats", "different"],
    ]
    guard let phrase = phrases.first(where: { u.range(of: $0) != nil }), let range = u.range(of: phrase) else { return nil }
    // Only about the view: "bu güncellemede ne değişti?" is left alone.
    var rest = u.dropping(range)
    rest.removeKeys([
      "simdi", "peki", "acaba", "orada", "burada", "sahnede", "goruntude", "etrafta", "now", "there", "here", "in", "the",
      "view", "scene",
    ])
    guard rest.isEmpty else { return nil }
    return VoiceBridgeDecision(.whatChanged, "live vision: what changed")
  }
}
