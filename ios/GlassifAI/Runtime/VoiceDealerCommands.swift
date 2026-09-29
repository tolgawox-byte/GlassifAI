import Foundation

/// Dealer Mode commands (Request F quick commands).
enum DealerCommand: Equatable {
  case startVehicle
  case nextVehicle
  case finishVehicle
  case readVIN
  case readOdometer
  case setOdometer(Int, OdometerReading.Unit)
  /// The user's words ("Sağ ön çamurluk çizik"); empty asks for them.
  case addDamage(String)
  case photoChecklist
  case deliveryChecklist
  case marketResearch
  case listing
  case summary
  case briefing
  /// "Aracı kaydet": vehicles save automatically; this confirms it.
  case saveVehicle
  /// "Recall kontrol et": Canadian recall research for the active vehicle.
  case recallCheck

  var name: String {
    switch self {
    case .startVehicle: "startVehicle"
    case .nextVehicle: "nextVehicle"
    case .finishVehicle: "finishVehicle"
    case .readVIN: "readVIN"
    case .readOdometer: "readOdometer"
    case .setOdometer: "setOdometer"
    case .addDamage: "addDamage"
    case .photoChecklist: "photoChecklist"
    case .deliveryChecklist: "deliveryChecklist"
    case .marketResearch: "marketResearch"
    case .listing: "listing"
    case .summary: "vehicleSummary"
    case .briefing: "dealerBriefing"
    case .saveVehicle: "saveVehicle"
    case .recallCheck: "recallCheck"
    }
  }
}

/// LEVEL 1 parsing of Dealer Mode commands, after photos/videos and before
/// notes. A command must be the whole request (fillers aside): "yeni araç
/// almak istiyorum" is conversation, not a new vehicle session.
extension VoiceActionIntentBridge {
  static let dealerPhrases: [([String], DealerCommand)] = [
    (["yeni", "arac", "baslat"], .startVehicle), (["yeni", "araca", "basla"], .startVehicle),
    (["yeni", "arac", "oturumu"], .startVehicle), (["yeni", "arac"], .startVehicle), (["start", "a", "new", "vehicle"], .startVehicle),
    (["new", "vehicle"], .startVehicle), (["new", "car"], .startVehicle),
    (["sonraki", "arac"], .nextVehicle), (["siradaki", "arac"], .nextVehicle), (["next", "vehicle"], .nextVehicle),
    (["next", "car"], .nextVehicle),
    (["bu", "arac", "tamam"], .finishVehicle), (["arac", "tamam"], .finishVehicle), (["bu", "araci", "bitir"], .finishVehicle),
    (["araci", "bitir"], .finishVehicle), (["araci", "kapat"], .finishVehicle), (["done", "with", "this", "vehicle"], .finishVehicle),
    (["finish", "this", "vehicle"], .finishVehicle), (["vehicle", "done"], .finishVehicle),
    (["vin", "numarasini", "oku"], .readVIN), (["vin", "oku"], .readVIN), (["vini", "oku"], .readVIN),
    (["sasi", "numarasini", "oku"], .readVIN), (["sasi", "no", "oku"], .readVIN), (["sasiyi", "oku"], .readVIN),
    (["read", "the", "vin"], .readVIN), (["scan", "the", "vin"], .readVIN), (["read", "vin"], .readVIN),
    (["kilometreyi", "oku"], .readOdometer), (["kilometresini", "oku"], .readOdometer), (["kilometre", "oku"], .readOdometer),
    (["read", "the", "odometer"], .readOdometer), (["read", "the", "mileage"], .readOdometer),
    (["foto", "checklist"], .photoChecklist), (["fotograf", "checklist"], .photoChecklist),
    (["fotograf", "listesi"], .photoChecklist), (["hangi", "fotograflar", "kaldi"], .photoChecklist),
    (["photo", "checklist"], .photoChecklist), (["which", "photos", "are", "left"], .photoChecklist),
    (["delivery", "checklist"], .deliveryChecklist), (["teslim", "kontrol", "listesi"], .deliveryChecklist),
    (["teslim", "listesi"], .deliveryChecklist), (["teslimat", "listesi"], .deliveryChecklist),
    (["piyasa", "degerine", "bak"], .marketResearch), (["piyasasina", "bak"], .marketResearch), (["piyasa", "bak"], .marketResearch),
    (["piyasa", "arastir"], .marketResearch), (["check", "the", "market"], .marketResearch), (["market", "price"], .marketResearch),
    (["ilanini", "hazirla"], .listing), (["ilan", "hazirla"], .listing), (["ilan", "yaz"], .listing),
    (["create", "a", "listing"], .listing), (["write", "a", "listing"], .listing),
    (["arac", "durumu"], .summary), (["bu", "aracta", "ne", "var"], .summary), (["vehicle", "summary"], .summary),
    (["bayi", "ozeti"], .briefing), (["bugun", "hangi", "araclar"], .briefing), (["dealer", "briefing"], .briefing),
    (["bugun", "dealerde", "ne", "var"], .briefing), (["bugun", "bayide", "ne", "var"], .briefing),
    (["kac", "foto", "kaldi"], .photoChecklist), (["kac", "fotograf", "kaldi"], .photoChecklist),
    (["how", "many", "photos", "left"], .photoChecklist), (["vinini", "oku"], .readVIN),
    (["araci", "kaydet"], .saveVehicle), (["arabayi", "kaydet"], .saveVehicle), (["save", "the", "vehicle"], .saveVehicle),
    (["recall", "kontrol", "et"], .recallCheck), (["recall", "kontrolu", "yap"], .recallCheck), (["recalluna", "bak"], .recallCheck),
    (["recalllarina", "bak"], .recallCheck), (["recall", "bak"], .recallCheck), (["recall", "var", "mi"], .recallCheck),
    (["geri", "cagirma", "kontrol", "et"], .recallCheck), (["check", "recalls"], .recallCheck),
    (["check", "the", "recalls"], .recallCheck), (["check", "for", "recalls"], .recallCheck),
  ]

  static func dealer(_ u: Utterance, _ context: VoiceBridgeContext) -> VoiceBridgeDecision? {
    guard u.count <= 30 else { return nil }
    if let decision = vehicleQuestion(u, context) { return decision }
    if let decision = odometerValue(u) { return decision }
    if let decision = damage(u) { return decision }
    // Longest phrase at the earliest position.
    var best: (phrase: [String], command: DealerCommand, range: Range<Int>)?
    for (phrase, command) in dealerPhrases {
      guard let range = u.range(of: phrase) else { continue }
      if let current = best,
         range.lowerBound > current.range.lowerBound
          || (range.lowerBound == current.range.lowerBound && phrase.count <= current.phrase.count) {
        continue
      }
      best = (phrase, command, range)
    }
    guard let best else {
      // "Kilometre" on its own reads the odometer.
      if u.keys == ["kilometre"] || u.keys == ["odometer"] || u.keys == ["mileage"] {
        return VoiceBridgeDecision(.dealer(.readOdometer), "dealer \"\(u.keys[0])\"")
      }
      return nil
    }
    let before = u.keys[0..<best.range.lowerBound]
    // "VIN nedir?", "yeni araç nasıl eklenir?" are questions; "hangi
    // fotoğraflar kaldı" is itself the command.
    let questions: Set<String> = ["nedir", "nasil", "neden", "niye", "what", "how", "why", "mi", "mu", "misin"]
    guard !before.contains(where: questions.contains), !before.contains(where: mediaNegations.contains) else { return nil }
    var tail = u.dropping(0..<best.range.upperBound)
    tail.trimLeading(mediaTailFillers.union(["simdi", "bir"]))
    // A few words may follow a research or listing command ("… Kanada'da").
    let allowsTail = best.command == .marketResearch || best.command == .listing || best.command == .recallCheck
    guard tail.isEmpty || (allowsTail && tail.count <= 6 && !tail.containsAny(questions)) else { return nil }
    return VoiceBridgeDecision(.dealer(best.command), "dealer \"\(best.phrase.joined(separator: " "))\"")
  }

  /// "Kilometre 45 bin 320", "kilometresi 45.320", "odometer 28,500 miles".
  private static func odometerValue(_ u: Utterance) -> VoiceBridgeDecision? {
    let starts: [[String]] = [["kilometre"], ["kilometresi"], ["kilometre", "su", "an"], ["odometer"], ["mileage"], ["km"]]
    guard let start = starts.first(where: { u.starts(with: $0) }), u.count > start.count,
          !u.containsAny(["kac", "how", "ne", "nedir"]) else { return nil }
    let rest = u.dropping(0..<start.count)
    guard let reading = OdometerReading.parse(rest.text) else { return nil }
    return VoiceBridgeDecision(.dealer(.setOdometer(reading.value, reading.unit)), "dealer odometer value")
  }

  /// "Hasar ekle: sağ ön çamurluk çizik", "hasar: ön cam çatlak", "add damage …".
  private static func damage(_ u: Utterance) -> VoiceBridgeDecision? {
    let starts: [[String]] = [
      ["hasar", "ekle"], ["hasar", "kaydet"], ["hasar", "not", "et"], ["hasar", "gir"], ["add", "damage"], ["log", "damage"],
      ["hasar"], ["damage"],
    ]
    guard let start = starts.first(where: { u.starts(with: $0) }) else { return nil }
    var content = u.dropping(0..<start.count)
    content.trimLeading(["olarak", "lutfen", "please", "su"])
    if start.count == 1 {
      // "Hasar" alone or "hasar raporu" is not a command; "hasar: ön cam çatlak" is.
      guard content.count >= 2, BodyZone.parse(content.text) != nil || DamageFinding.kind(in: content.text) != .other else {
        return nil
      }
    }
    return VoiceBridgeDecision(
      .dealer(.addDamage(content.isEmpty ? "" : capitalizedFirst(content.text))), "dealer damage")
  }
}
