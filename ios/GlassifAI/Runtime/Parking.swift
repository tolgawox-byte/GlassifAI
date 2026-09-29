import Foundation

/// Where the user parked ("park yerimi kaydet"): one place, on this iPhone.
struct ParkingSpot: Codable, Equatable, Identifiable {
  var id = UUID()
  var latitude: Double?
  var longitude: Double?
  var placeName: String?
  /// The user's own words ("B2 katı, 45 numara").
  var note: String?
  var at = Date()
  /// The Ray-Ban photo taken with it ("park yerimi fotoğrafla kaydet").
  var captureID: UUID?

  var hasLocation: Bool { latitude != nil && longitude != nil }

  /// Walking directions in Apple Maps to the exact point.
  var mapsURL: URL? {
    guard let latitude, let longitude else { return nil }
    var components = URLComponents(string: "https://maps.apple.com/")
    components?.queryItems = [
      URLQueryItem(name: "daddr", value: String(format: "%.6f,%.6f", latitude, longitude)),
      URLQueryItem(name: "dirflg", value: "w"),
    ]
    return components?.url
  }
}

/// One location fix for the parking spot, or why there is none.
enum ParkingFix: Equatable {
  case located(MemoryLocation)
  case noPermission
  case unavailable
}

/// The saved parking spot (JSON in Application Support, this iPhone only).
/// The location is read once, when the user asks; never tracked.
@MainActor
final class ParkingStore: ObservableObject {
  static let shared = ParkingStore(directory: ScreenshotMode.storeDirectory)

  @Published private(set) var spot: ParkingSpot?
  private let fileURL: URL

  /// One fix with When In Use permission (tests replace it).
  var locate: @MainActor () async -> ParkingFix = {
    let provider = LocationProvider.shared
    guard provider.isAuthorized else {
      provider.requestPermission()
      return .noPermission
    }
    guard let location = await provider.currentLocation(timeout: 10, accuracy: 10) else { return .unavailable }
    return .located(location)
  }

  init(directory: URL? = nil) {
    let base = directory ?? (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory).appendingPathComponent("AutoLoom", isDirectory: true)
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    fileURL = base.appendingPathComponent("parking.json")
    if let data = try? Data(contentsOf: fileURL) {
      if let decoded = try? JSONDecoder().decode(ParkingSpot.self, from: data) {
        spot = decoded
      } else {
        LocalJSONFile.setAside(fileURL)
      }
    }
  }

  /// Saves the spot; false when the file could not be written.
  @discardableResult
  func save(_ newSpot: ParkingSpot) -> Bool {
    spot = newSpot
    return persist()
  }

  /// Puts back an earlier spot (undo), or none.
  func restore(_ earlier: ParkingSpot?) {
    spot = earlier
    persist()
  }

  func clear() {
    spot = nil
    persist()
  }

  @discardableResult
  private func persist() -> Bool {
    guard let spot else {
      try? FileManager.default.removeItem(at: fileURL)
      return true
    }
    guard let data = try? JSONEncoder().encode(spot) else { return false }
    do {
      try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
      return true
    } catch {
      return false
    }
  }
}

enum ParkingCommand: Equatable {
  /// "Park yerimi kaydet: B2 katı 45": the words said with it, if any.
  case save(note: String?)
  /// "Arabamı nereye park ettim?", "arabam nerede?"
  case recall
  /// "Beni arabama götür"
  case directions
  /// "Park yerini sil"
  case clear
  /// "Park yerimi fotoğrafla kaydet": the spot and a Ray-Ban photo of it.
  case saveWithPhoto
}

/// LEVEL 1 parking commands (before notes, memory and directions: "park
/// yerimi hatırla" is the parking spot, "arabama götür" is not a place
/// called "araba").
extension VoiceActionIntentBridge {
  static let parkingSavePhrases: [[String]] = [
    ["park", "yerimi", "kaydet"], ["park", "yerini", "kaydet"], ["park", "yerimi", "hatirla"], ["park", "yerini", "hatirla"],
    ["park", "yerimi", "isaretle"], ["park", "ettigim", "yeri", "kaydet"], ["park", "ettigim", "yeri", "hatirla"],
    ["park", "ettigim", "yeri", "not", "al"], ["save", "my", "parking", "spot"], ["save", "my", "parking"],
    ["mark", "my", "parking", "spot"], ["remember", "my", "parking", "spot"], ["remember", "this", "parking", "spot"],
  ]
  static let parkingRecallPhrases: [[String]] = [
    ["nereye", "park", "ettim"], ["arabami", "nereye", "biraktim"], ["aracimi", "nereye", "biraktim"], ["arabam", "nerede"],
    ["arabam", "nerde"], ["aracim", "nerede"], ["park", "yerim", "nerede"], ["park", "yerim", "neresi"],
    ["park", "yerim", "neresiydi"], ["where", "did", "i", "park"], ["where", "i", "parked"], ["where", "is", "my", "car"],
    ["wheres", "my", "car"],
  ]
  static let parkingDirectionsPhrases: [[String]] = [
    ["arabama", "gotur"], ["aracima", "gotur"], ["arabaya", "gotur"], ["arabama", "yol", "tarifi"], ["araca", "yol", "tarifi"],
    ["arabama", "nasil", "giderim"], ["arabama", "nasil", "donerim"], ["park", "yerime", "gotur"], ["park", "yerine", "gotur"],
    ["park", "yerime", "yol", "tarifi"], ["park", "yerine", "yol", "tarifi"], ["take", "me", "to", "my", "car"],
    ["navigate", "to", "my", "car"], ["directions", "to", "my", "car"], ["back", "to", "my", "car"],
  ]
  static let parkingClearPhrases: [[String]] = [
    ["park", "yerini", "sil"], ["park", "yerimi", "sil"], ["park", "yerini", "unut"], ["park", "yerimi", "unut"],
    ["clear", "my", "parking"], ["forget", "my", "parking"], ["delete", "my", "parking"],
  ]

  static func parking(_ u: Utterance) -> VoiceBridgeDecision? {
    guard u.count <= 16 else { return nil }
    let howWords: Set<String> = ["nasil", "neden", "niye", "how", "why", "mi", "mu"]
    if firstPhrase(parkingClearPhrases, in: u) != nil {
      return VoiceBridgeDecision(.parking(.clear), "parking clear")
    }
    if firstPhrase(parkingDirectionsPhrases, in: u) != nil {
      return VoiceBridgeDecision(.parking(.directions), "parking directions")
    }
    let photoPhrases: [[String]] = [
      ["park", "yerimi", "fotografla", "kaydet"], ["park", "yerini", "fotografla", "kaydet"],
      ["save", "my", "parking", "spot", "with", "a", "photo"],
    ]
    if firstPhrase(photoPhrases, in: u) != nil {
      return VoiceBridgeDecision(.parking(.saveWithPhoto), "parking save with a photo")
    }
    if u.starts(with: ["remember", "where", "i", "parked"]) {
      return VoiceBridgeDecision(.parking(.save(note: nil)), "parking save")
    }
    if firstPhrase(parkingRecallPhrases, in: u) != nil {
      return VoiceBridgeDecision(.parking(.recall), "parking recall")
    }
    guard !u.containsAny(howWords) else { return nil }
    let fillers: Set<String> = ["lutfen", "please", "simdi", "now", "hemen", "su", "an", "here", "buraya", "burada"]
    if let (_, range) = firstPhrase(parkingSavePhrases, in: u) {
      var tail = u.dropping(0..<range.upperBound)
      tail.trimLeading(fillers)
      tail.trimTrailing(fillers)
      var before = u.dropping(range.lowerBound..<u.count)
      before.trimLeading(fillers.union(["arabami", "aracimi"]))
      let note = !tail.isEmpty ? tail.text : (!before.isEmpty ? before.text : "")
      return VoiceBridgeDecision(.parking(.save(note: note.isEmpty ? nil : capitalizedFirst(note))), "parking save")
    }
    // "Arabamı B2 katına park ettim", "buraya park ettim", "I parked on level 2".
    var said = u
    said.trimTrailing(fillers)
    if said.ends(with: ["park", "ettim"]) {
      var place = said.dropping((said.count - 2)..<said.count)
      let mentionsCar = place.containsAny(["arabami", "arabayi", "aracimi", "araci", "buraya", "burada"])
      place.trimLeading(fillers.union(["arabami", "arabayi", "aracimi", "araci", "araba", "arabam"]))
      place.trimTrailing(fillers)
      // A place is in the dative ("otoparka", "B2 katına"); "bugün çok kötü
      // park ettim" is talk, not a parking spot.
      let placeWord = place.keys.last.map { $0.hasSuffix("a") || $0.hasSuffix("e") } ?? false
      guard place.isEmpty || mentionsCar || placeWord else { return nil }
      return VoiceBridgeDecision(.parking(.save(note: place.isEmpty ? nil : capitalizedFirst(place.text))), "parking save")
    }
    if said.starts(with: ["i", "parked"]) {
      var place = said.dropping(0..<2)
      place.trimLeading(fillers.union(["the", "car", "my"]))
      place.trimTrailing(fillers)
      return VoiceBridgeDecision(.parking(.save(note: place.isEmpty ? nil : capitalizedFirst(place.text))), "parking save")
    }
    return nil
  }
}

/// Runs parking commands on the phone.
extension AssistantOrchestrator {
  func runParking(_ command: ParkingCommand, transcript: String, traceID: UUID) async -> IntentOutcome {
    let store = ParkingStore.shared
    let trace = ActionTraceLog.shared
    switch command {
    case .save(let note):
      trace.update(traceID) { $0.executor = "ParkingStore + one location fix (When In Use)" }
      let fix = await store.locate()
      var spot = ParkingSpot(note: note)
      if case .located(let location) = fix {
        spot.latitude = location.latitude
        spot.longitude = location.longitude
        spot.placeName = location.placeName
      }
      guard spot.hasLocation || note != nil else {
        let reason = fix == .noPermission
          ? ("Konum izni olmadan park yerini kaydedemiyorum. İzin verip tekrar söyle ya da yeri söyle: “park yerimi kaydet: B2 katı”.",
             "I can't save the spot without location access. Allow it and ask again, or say where: “save my parking spot: level B2”.")
          : ("Konumu şu an alamadım. Yeri söylersen kaydederim: “park yerimi kaydet: B2 katı”.",
             "I couldn't get the location just now. Tell me where and I'll save it: “save my parking spot: level B2”.")
        return parkingOutcome(tr: reason.0, en: reason.1, failed: fix == .noPermission ? "location permission" : "no location fix")
      }
      let previous = store.spot
      guard store.save(spot) else {
        return parkingOutcome(tr: "Park yerini kaydedemedim.", en: "I couldn't save the parking spot.", failed: "parking save failed")
      }
      let spotID = spot.id
      LocalUndo.shared.record(kind: "parking", english: "parking spot removed", turkish: "park yeri kaydı geri alındı") {
        guard ParkingStore.shared.spot?.id == spotID else { return false }
        ParkingStore.shared.restore(previous)
        return true
      }
      trace.update(traceID) {
        $0.persistence = spot.hasLocation ? "parking spot saved with a location fix" : "parking spot saved (words only, no location)"
      }
      let place = spot.placeName.map { ": \($0)" } ?? ""
      let tr: String
      let en: String
      if spot.hasLocation {
        tr = "Park yerini kaydettim\(place)."
        en = "Parking spot saved\(place)."
      } else {
        tr = fix == .noPermission
          ? "Park yerini not olarak kaydettim; konum izni olmadığı için haritada gösteremem."
          : "Park yerini not olarak kaydettim; konumu alamadım."
        en = fix == .noPermission
          ? "I saved the spot as a note; without location access I can't show it on a map."
          : "I saved the spot as a note; I couldn't get the location."
      }
      return parkingOutcome(
        tr: tr, en: en,
        feedback: ActionFeedback(kind: .memory, title: L.t("Parking spot saved", "Park yeri kaydedildi"), detail: spot.placeName))

    case .recall:
      trace.update(traceID) { $0.executor = "ParkingStore (read), then memory search" }
      guard let spot = store.spot else {
        // A spot kept as a memory ("bunu hatırla: arabam P2 katında").
        let memory = MemoryStore.shared
        let hits = memory.isEnabled ? memory.search(transcript, limit: 3) : []
        guard !hits.isEmpty else {
          return parkingOutcome(tr: "Kayıtlı bir park yeri yok.", en: "There's no parking spot saved.")
        }
        memory.noteRecalled(hits)
        trace.update(traceID) { $0.parsed = "no parking spot; \(hits.count) memory matches" }
        let lines = hits.map { "- \($0.line)" }.joined(separator: "\n")
        return IntentOutcome(
          spoken: "No parking spot is saved, but these saved memories may say where the car is (answer from them and ignore the ones that do not fit):\n" + lines,
          reply: lines)
      }
      let minutes = Int(Date().timeIntervalSince(spot.at) / 60)
      var facts = ["saved at \(spot.at.formatted(date: .abbreviated, time: .shortened)) (\(minutes) minutes ago)"]
      if let place = spot.placeName { facts.append("place: \(place)") }
      if let note = spot.note { facts.append("the user's words: \(note)") }
      facts.append(spot.hasLocation ? "the exact point is saved (directions: \"arabama götür\")" : "no map location was saved")
      if spot.captureID != nil { facts.append("a Ray-Ban photo of the spot is in Captures") }
      return IntentOutcome(
        spoken: "The user's saved parking spot — " + facts.joined(separator: "; ")
          + ". Tell them in one or two short sentences in the conversation's language; do not add anything else.",
        reply: [spot.placeName, spot.note].compactMap { $0 }.joined(separator: " · "),
        said: [spot.placeName, spot.note].compactMap { $0 }.joined(separator: " · "))

    case .directions:
      guard let spot = store.spot else {
        return parkingOutcome(tr: "Kayıtlı bir park yeri yok.", en: "There's no parking spot saved.", failed: "no parking spot")
      }
      guard spot.hasLocation, let url = spot.mapsURL else {
        let words = spot.note.map { " Not: \($0)." } ?? ""
        let wordsEN = spot.note.map { " Your note: \($0)." } ?? ""
        return parkingOutcome(
          tr: "Park yerinin konumu kayıtlı değil.\(words)", en: "The spot has no saved location.\(wordsEN)", failed: "no location")
      }
      guard AssistantPreferences.actionsEnabled else { return actionsOff() }
      guard ToolRegistry.allows(.openMaps) else { return toolOff(.openMaps) }
      trace.update(traceID) { $0.executor = "Apple Maps (walking, to the saved point)" }
      let point = String(format: "%.6f,%.6f", spot.latitude ?? 0, spot.longitude ?? 0)
      return await openMaps(url, destination: point, label: spot.placeName ?? L.t("your car", "araban"), traceID: traceID)

    case .saveWithPhoto:
      let saved = await runParking(.save(note: nil), transcript: transcript, traceID: traceID)
      guard saved.failed == nil else { return saved }
      let photo = await RayBanMediaCoordinator.shared.takePhoto(
        label: nil, caption: L.t("Parking spot", "Park yeri"), noteID: nil)
      guard let record = photo.record, var spot = store.spot else {
        let speech = RayBanMediaCoordinator.photoSpeech(photo)
        return parkingOutcome(
          tr: "Park yerini kaydettim; fotoğraf çekilemedi: " + speech.tr, en: "Parking spot saved; no photo: " + speech.en,
          failed: "no photo")
      }
      spot.captureID = record.id
      store.save(spot)
      trace.update(traceID) { $0.persistence = "parking spot saved with a Ray-Ban photo" }
      return parkingOutcome(
        tr: "Park yerini fotoğrafıyla kaydettim.", en: "Parking spot saved with a photo.",
        feedback: ActionFeedback(kind: .memory, title: L.t("Parking spot saved", "Park yeri kaydedildi"), detail: spot.placeName))

    case .clear:
      guard store.spot != nil else {
        return parkingOutcome(tr: "Kayıtlı bir park yeri yok.", en: "There's no parking spot saved.")
      }
      store.clear()
      trace.update(traceID) { $0.persistence = "parking spot deleted" }
      return parkingOutcome(
        tr: "Park yerini sildim.", en: "Parking spot deleted.",
        feedback: ActionFeedback(kind: .forgotten, title: L.t("Parking spot deleted", "Park yeri silindi")))
    }
  }

  private func parkingOutcome(tr: String, en: String, failed: String? = nil, feedback: ActionFeedback? = nil) -> IntentOutcome {
    IntentOutcome(
      spoken: BridgeSpeech.done("Result of the user's parking command, done on this iPhone.", tr: tr, en: en),
      reply: L.t(en, tr), failed: failed, feedback: feedback, said: L.t(en, tr))
  }
}
