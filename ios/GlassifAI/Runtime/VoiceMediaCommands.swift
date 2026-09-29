import Foundation

/// Ray-Ban photo and video commands (LEVEL 1, deterministic). They run
/// before confirmations and notes: "kaydı durdur" stops a recording at once,
/// and "bunun fotoğrafını çek ve not al: …" is a photo with a note. Only the
/// user's own words reach this parser; text the camera reads never does, so
/// nothing seen can take a photo or start a recording.
///
/// Not commands: "video nasıl çekilir?", "fotoğraf hakkında konuş",
/// "fotoğraf çekmeyi hatırlat", "not al: fotoğraf çek" (a note).
extension VoiceActionIntentBridge {
  /// Stopping a recording and asking about it: checked before a pending
  /// confirmation ("hayır, kaydı durdur" stops the recording).
  static func recordingControl(_ u: Utterance, _ context: VoiceBridgeContext) -> VoiceBridgeDecision? {
    guard u.count <= 30 else { return nil }
    return recordingQuestion(u, context) ?? stopRecording(u)
  }

  /// Photos, starting a recording and "galeriye kaydet": before notes.
  static func media(_ u: Utterance, _ context: VoiceBridgeContext) -> VoiceBridgeDecision? {
    guard u.count <= 30 else { return nil }
    if let decision = saveToPhotos(u) { return decision }
    if let decision = photo(u, context) { return decision }
    return startRecording(u, context)
  }

  static let mediaQuestionWords: Set<String> = [
    "nasil", "neden", "niye", "nicin", "kim", "kimin", "hangi", "hakkinda", "anlat", "ogret", "nedir",
    "how", "why", "who", "which", "what", "when", "about", "explain",
  ]

  /// Words that may follow a media command without changing it.
  static let mediaTailFillers: Set<String> = ["lutfen", "please", "hemen", "simdi", "now", "artik", "bakalim", "hadi"]

  /// A question ("nasıl", "how do I…") or another command ("not al:
  /// fotoğraf çek", "görev oluştur: video çek") before the media words:
  /// they are content or talk, not a command.
  static func isCommandPosition(_ u: Utterance, _ range: Range<Int>) -> Bool {
    !u.keys[0..<range.lowerBound].contains {
      mediaQuestionWords.contains($0) || mediaContentVerbs.contains($0) || mediaNegations.contains($0)
    }
  }

  /// "Don't record this", "sakın fotoğraf çekme" (Turkish negation is also
  /// in the verb: "çekme" never matches "çek").
  static let mediaNegations: Set<String> = ["dont", "never", "not", "asla", "sakin", "no"]

  /// What may follow the media words.
  enum MediaTail: Equatable {
    case plain
    /// "… ve not al: sağ ön jant çizik".
    case note(String)

    var note: String? {
      if case .note(let text) = self { return text }
      return nil
    }
  }

  /// Commands that, said before the media words, make those words their
  /// content ("not al: fotoğraf çek", "görev oluştur: video çek").
  static let mediaContentVerbs: Set<String> = [
    "not", "notu", "notlara", "notlarima", "nota", "hatirlat", "hatirlatici", "gorev", "gorevi", "todo", "todoya",
    "takvime", "ajandaya", "note", "remind", "task", "yaz",
  ]

  // MARK: Status

  private static func recordingQuestion(_ u: Utterance, _ context: VoiceBridgeContext) -> VoiceBridgeDecision? {
    let always: [[String]] = [
      ["kayit", "yapiyor", "musun"], ["kayit", "yapiyormusun"], ["kaydediyor", "musun"], ["kaydediyormusun"],
      ["video", "cekiyor", "musun"], ["video", "kaydediyor", "musun"], ["kayitta", "misin"],
      ["kayit", "devam", "ediyor", "mu"], ["kayit", "suruyor", "mu"], ["are", "you", "recording"],
      ["is", "it", "recording"], ["still", "recording"], ["is", "the", "video", "recording"],
    ]
    if u.count <= 8, always.contains(where: { u.range(of: $0) != nil }) {
      return VoiceBridgeDecision(.recordingStatus, "recording status question")
    }
    // "Ne kadar oldu?" is about the recording only while one runs.
    guard context.isRecording, u.count <= 6 else { return nil }
    let whileRecording: [[String]] = [
      ["ne", "kadar", "oldu"], ["kac", "dakika", "oldu"], ["kac", "saniye", "oldu"], ["ne", "kadardir"],
      ["how", "long", "has", "it", "been"], ["how", "long", "is", "it"], ["how", "long", "is", "the", "video"],
      ["how", "long", "have", "you", "been", "recording"],
    ]
    if whileRecording.contains(where: { u.range(of: $0) != nil }) {
      return VoiceBridgeDecision(.recordingStatus, "recording length question")
    }
    return nil
  }

  // MARK: Stop recording

  static let stopRecordingPhrases: [[String]] = [
    ["video", "kaydini", "durdur"], ["video", "kaydini", "bitir"], ["video", "kaydini", "kapat"], ["kaydini", "durdur"],
    ["kaydini", "bitir"], ["videoyu", "durdur"], ["videoyu", "bitir"], ["videoyu", "kapat"], ["videoyu", "kes"],
    ["kaydi", "durdur"], ["kaydi", "bitir"], ["kaydi", "kapat"], ["kaydi", "sonlandir"], ["kaydi", "kes"],
    ["kayit", "durdur"], ["kayit", "bitir"], ["cekimi", "bitir"], ["cekimi", "durdur"], ["cekimi", "sonlandir"],
    ["kaydetmeyi", "durdur"], ["kaydetmeyi", "birak"], ["cekmeyi", "birak"], ["cekmeyi", "durdur"],
    ["kaydi", "durdurur", "musun"], ["videoyu", "durdurur", "musun"],
    ["stop", "the", "recording"], ["stop", "recording"], ["stop", "the", "video"], ["stop", "video"], ["stop", "filming"],
    ["stop", "record"], ["finish", "the", "recording"], ["finish", "recording"], ["end", "the", "recording"],
    ["end", "recording"], ["end", "the", "video"],
  ]

  private static func stopRecording(_ u: Utterance) -> VoiceBridgeDecision? {
    guard let (phrase, range) = firstPhrase(stopRecordingPhrases, in: u), isCommandPosition(u, range) else { return nil }
    var tail = u.dropping(0..<range.upperBound)
    tail.trimLeading(mediaTailFillers)
    guard tail.isEmpty else { return nil }
    return VoiceBridgeDecision(.stopRecording, "stop recording \"\(phrase.joined(separator: " "))\"")
  }

  // MARK: Photos library

  private static func saveToPhotos(_ u: Utterance) -> VoiceBridgeDecision? {
    let phrases: [[String]] = [
      ["galeriye", "kaydet"], ["galeriye", "ekle"], ["galeriye", "at"], ["fotograflara", "kaydet"],
      ["fotograflara", "ekle"], ["film", "rulosuna", "kaydet"], ["save", "it", "to", "photos"],
      ["save", "it", "to", "my", "photos"], ["save", "to", "photos"], ["save", "to", "my", "photos"],
      ["add", "it", "to", "photos"], ["save", "it", "to", "the", "gallery"], ["save", "to", "camera", "roll"],
    ]
    guard u.count <= 7, let (phrase, range) = firstPhrase(phrases, in: u), isCommandPosition(u, range) else { return nil }
    var tail = u.dropping(0..<range.upperBound)
    tail.trimLeading(mediaTailFillers)
    guard tail.isEmpty else { return nil }
    return VoiceBridgeDecision(.saveCaptureToPhotos, "save to Photos \"\(phrase.joined(separator: " "))\"")
  }

  // MARK: Photo

  static let photoPhrases: [[String]] = [
    ["fotograf", "cekebilir", "misin"], ["fotograf", "cekebilirmisin"], ["fotograf", "ceker", "misin"],
    ["fotograf", "cekermisin"], ["fotografini", "cekebilir", "misin"], ["fotografini", "ceker", "misin"],
    ["fotografini", "cekermisin"], ["foto", "ceker", "misin"], ["fotograf", "cekiver"], ["fotografini", "cekiver"],
    ["fotograf", "cekelim"], ["fotografini", "cekelim"], ["fotograf", "cek"], ["foto", "cek"], ["fotografini", "cek"],
    ["fotografi", "cek"], ["fotosunu", "cek"], ["resim", "cek"], ["resmini", "cek"],
    ["take", "another", "photo"], ["take", "one", "more", "photo"], ["take", "a", "photo"], ["take", "a", "picture"],
    ["take", "a", "pic"], ["take", "photo"], ["take", "picture"], ["snap", "a", "photo"], ["snap", "a", "picture"],
    ["photograph", "this"], ["photograph", "that"], ["photograph", "it"],
  ]

  /// "Bu aracın önünü çek", "jantı çek": a part of the car, then "çek" at
  /// the very end (dealer walkaround shots without the word "fotoğraf").
  static let dealerShotPhrases: [[String]] = [
    ["onunu", "cek"], ["arkasini", "cek"], ["yanini", "cek"], ["icini", "cek"], ["janti", "cek"], ["jantini", "cek"],
    ["jantlari", "cek"], ["lastigi", "cek"], ["lastigini", "cek"], ["hasari", "cek"], ["cizigi", "cek"],
    ["gostergeyi", "cek"], ["kilometreyi", "cek"], ["motoru", "cek"], ["motorunu", "cek"], ["sasiyi", "cek"],
    ["sasi", "numarasini", "cek"], ["torpidoyu", "cek"], ["koltuklari", "cek"], ["tamponu", "cek"], ["bagaji", "cek"],
  ]

  private static func photo(_ u: Utterance, _ context: VoiceBridgeContext) -> VoiceBridgeDecision? {
    var match = firstPhrase(photoPhrases, in: u)
    var rule = "photo phrase"
    if match == nil, let shot = dealerShotPhrases.first(where: { u.ends(with: $0) }) {
      match = (shot, (u.count - shot.count)..<u.count)
      rule = "dealer shot"
    }
    guard let (phrase, range) = match, isCommandPosition(u, range),
          let tail = mediaTail(after: range, in: u, context: context, allowsOf: true) else { return nil }
    let (label, caption) = labelAndCaption(u, note: tail.note, context: context)
    return VoiceBridgeDecision(
      .takePhoto(label: label, note: tail.note, caption: caption),
      "\(rule) \"\(phrase.joined(separator: " "))\"" + (tail.note != nil ? " + note" : ""))
  }

  // MARK: Start recording

  static let startRecordingPhrases: [[String]] = [
    ["video", "kaydini", "baslat"], ["video", "kaydi", "baslat"], ["video", "kaydina", "basla"],
    ["video", "cekmeye", "baslar", "misin"], ["video", "cekmeye", "basla"], ["video", "kaydetmeye", "basla"],
    ["video", "ceker", "misin"], ["video", "cekebilir", "misin"], ["videosunu", "cek"], ["videoya", "basla"],
    ["video", "baslat"], ["video", "cek"], ["video", "kaydet"], ["kayda", "basla"], ["kayda", "gec"],
    ["kaydi", "baslat"], ["kayit", "baslat"], ["cekime", "basla"], ["cekimi", "baslat"], ["kaydetmeye", "basla"],
    ["cekmeye", "basla"],
    ["record", "a", "video"], ["record", "video"], ["start", "recording"], ["start", "a", "video"],
    ["start", "the", "video"], ["start", "video"], ["begin", "recording"], ["start", "filming"], ["record", "this"],
    ["film", "this"],
  ]

  private static func startRecording(_ u: Utterance, _ context: VoiceBridgeContext) -> VoiceBridgeDecision? {
    guard let (phrase, range) = firstPhrase(startRecordingPhrases, in: u), isCommandPosition(u, range),
          let tail = mediaTail(after: range, in: u, context: context, allowsOf: false) else { return nil }
    return VoiceBridgeDecision(
      .startRecording(note: tail.note),
      "start recording \"\(phrase.joined(separator: " "))\"" + (tail.note != nil ? " + note" : ""))
  }

  // MARK: Helpers

  /// The earliest phrase, the longer one when two start together.
  static func firstPhrase(_ phrases: [[String]], in u: Utterance) -> (phrase: [String], range: Range<Int>)? {
    var best: (phrase: [String], range: Range<Int>)?
    for phrase in phrases {
      guard let range = u.range(of: phrase) else { continue }
      if let current = best,
         range.lowerBound > current.range.lowerBound
          || (range.lowerBound == current.range.lowerBound && phrase.count <= current.phrase.count) {
        continue
      }
      best = (phrase, range)
    }
    return best
  }

  /// What may follow the media words: nothing, fillers, "ve not al: …" (a
  /// note, returned), or for photos "of the wheel". Anything else is not a
  /// plain command (nil: the voice model handles the sentence).
  private static func mediaTail(
    after range: Range<Int>,
    in u: Utterance,
    context: VoiceBridgeContext,
    allowsOf: Bool
  ) -> MediaTail? {
    var tail = u.dropping(0..<range.upperBound)
    tail.trimLeading(mediaTailFillers)
    if tail.isEmpty { return .plain }
    if let first = tail.keys.first, first == "ve" || first == "and" {
      tail.remove(0..<1)
      // "Fotoğraf çek ve kaydet": saving is part of taking it.
      let saveWords: Set<String> = [
        "kaydet", "sakla", "galeriye", "fotograflara", "save", "it", "to", "my", "photos", "the", "gallery", "keep",
      ]
      if !tail.isEmpty, tail.isOnly(saveWords) { return .plain }
      guard case .saveNote(let text)? = notes(tail, context)?.intent else { return nil }
      return .note(text)
    }
    if allowsOf, let first = tail.keys.first, ["of", "from"].contains(first) {
      return .plain
    }
    return nil
  }

  /// The label from the words said now, or, for "fotoğrafını çek" right
  /// after "Sağ ön jant çizik", from what was just said or saved.
  private static func labelAndCaption(
    _ u: Utterance,
    note: String?,
    context: VoiceBridgeContext
  ) -> (CaptureLabel?, String?) {
    if let note {
      return (captureLabel(in: Utterance(note)) ?? captureLabel(in: u), note)
    }
    if let label = captureLabel(in: u) { return (label, nil) }
    for earlier in [context.recentSavedText, context.previousUserText].compactMap({ $0 }) {
      if let label = captureLabel(in: Utterance(earlier)) { return (label, earlier) }
    }
    return (nil, nil)
  }

  /// Damage first (it is why a dealer takes the photo), then VIN, odometer,
  /// wheel, tire, interior, engine, front, rear, side.
  static func captureLabel(in u: Utterance?) -> CaptureLabel? {
    guard let u else { return nil }
    let groups: [(CaptureLabel, Set<String>)] = [
      (.damage, [
        "hasar", "hasari", "hasarin", "hasarli", "cizik", "cizigi", "cizigin", "cizikler", "ciziklerin", "gocuk", "gocugu",
        "gocugun", "ezik", "ezigi", "catlak", "catlagi", "kirik", "boya", "damage", "scratch", "scratches", "dent", "crack",
      ]),
      (.vin, ["sasi", "sasiyi", "sasinin", "vin", "vini", "vinin"]),
      (.odometer, [
        "kilometre", "kilometreyi", "kilometresini", "km", "odometre", "gosterge", "gostergeyi", "gostergenin",
        "odometer", "mileage", "dashboard",
      ]),
      (.wheel, ["jant", "janti", "jantin", "jantini", "jantlari", "jantlarin", "wheel", "wheels", "rim", "rims"]),
      (.tire, ["lastik", "lastigi", "lastigin", "lastigini", "lastikleri", "tire", "tires", "tyre", "tyres"]),
      (.interior, [
        "ici", "icini", "icerisi", "iceriyi", "kabin", "koltuk", "koltuklari", "torpido", "torpidoyu", "interior",
        "seats", "cabin",
      ]),
      (.engine, ["motor", "motoru", "motorun", "motorunu", "kaput", "kaputu", "kaputun", "engine", "hood", "bonnet"]),
      (.front, ["onu", "onunu", "onden", "tampon", "tamponu", "front", "bumper"]),
      (.rear, ["arka", "arkasi", "arkasini", "arkadan", "bagaj", "bagaji", "rear", "back", "trunk", "boot"]),
      (.side, ["yani", "yanini", "yandan", "side"]),
    ]
    return groups.first { u.containsAny($0.1) }?.0
  }
}
