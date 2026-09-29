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
  /// "VIN'i çöz": NHTSA vPIC decode of the saved VIN.
  case decodeVIN
  /// "Lastiği oku", "sağ ön lastiği oku": size and DOT date from the sidewall.
  case readTire(String?)
  /// "Uyarı ışıklarına bak": lit warning lights, named only when clear.
  case readDashboard
  /// "Kondisyon raporu": the condition report from what was recorded.
  case conditionReport
  /// "Servis notu hazırla": a handoff note for the service department.
  case serviceHandoff
  /// "Aracın yerini kaydet": where the vehicle stands on the lot.
  case saveLotSpot
  /// "Araç nerede duruyor?": walking directions to the saved lot spot.
  case findLotSpot
  /// "Parça numarasını oku".
  case readPartNumber
  /// "Sol taraf temiz": an area walked with no damage.
  case areaClear(String)
  /// "Aracı dışa aktar": the vehicle's record, shared by the user.
  case exportVehicle

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
    case .decodeVIN: "decodeVIN"
    case .readTire: "readTire"
    case .readDashboard: "readDashboard"
    case .conditionReport: "conditionReport"
    case .serviceHandoff: "serviceHandoff"
    case .saveLotSpot: "saveLotSpot"
    case .findLotSpot: "findLotSpot"
    case .readPartNumber: "readPartNumber"
    case .areaClear: "areaClear"
    case .exportVehicle: "exportVehicle"
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
    (["vini", "coz"], .decodeVIN), (["vin", "coz"], .decodeVIN), (["vini", "cozumle"], .decodeVIN),
    (["vin", "cozumle"], .decodeVIN), (["decode", "the", "vin"], .decodeVIN), (["decode", "vin"], .decodeVIN),
    (["lastigi", "oku"], .readTire(nil)), (["lastik", "oku"], .readTire(nil)), (["lastik", "ebadini", "oku"], .readTire(nil)),
    (["lastik", "olcusunu", "oku"], .readTire(nil)), (["dot", "kodunu", "oku"], .readTire(nil)),
    (["lastigin", "yasini", "oku"], .readTire(nil)), (["read", "the", "tire"], .readTire(nil)),
    (["read", "the", "tire", "size"], .readTire(nil)), (["read", "the", "dot", "code"], .readTire(nil)),
    (["uyari", "isiklarini", "oku"], .readDashboard), (["uyari", "isiklarina", "bak"], .readDashboard),
    (["uyari", "lambalarina", "bak"], .readDashboard), (["uyari", "lambalarini", "oku"], .readDashboard),
    (["gosterge", "paneline", "bak"], .readDashboard), (["gostergeye", "bak"], .readDashboard),
    (["check", "the", "warning", "lights"], .readDashboard), (["read", "the", "warning", "lights"], .readDashboard),
    (["check", "the", "dashboard"], .readDashboard),
    (["kondisyon", "raporu"], .conditionReport), (["durum", "raporu"], .conditionReport), (["hasar", "raporu"], .conditionReport),
    (["kondisyon", "raporu", "hazirla"], .conditionReport), (["hasar", "raporu", "hazirla"], .conditionReport),
    (["durum", "raporu", "hazirla"], .conditionReport), (["kondisyon", "raporu", "olustur"], .conditionReport),
    (["condition", "report"], .conditionReport), (["prepare", "a", "condition", "report"], .conditionReport),
    (["servis", "notu", "hazirla"], .serviceHandoff), (["servis", "notu"], .serviceHandoff), (["servise", "devret"], .serviceHandoff),
    (["service", "handoff"], .serviceHandoff), (["service", "note"], .serviceHandoff),
    (["parca", "numarasini", "oku"], .readPartNumber), (["parca", "no", "oku"], .readPartNumber),
    (["parca", "kodunu", "oku"], .readPartNumber), (["read", "the", "part", "number"], .readPartNumber),
    (["araci", "disa", "aktar"], .exportVehicle), (["arac", "kaydini", "paylas"], .exportVehicle),
    (["export", "the", "vehicle"], .exportVehicle), (["share", "the", "vehicle", "record"], .exportVehicle),
  ]

  /// Lot commands, only with an active vehicle ("arabamın yerini kaydet"
  /// without one is the user's own parking spot).
  static let lotPhrases: [([String], DealerCommand)] = [
    (["aracin", "yerini", "kaydet"], .saveLotSpot), (["aracin", "konumunu", "kaydet"], .saveLotSpot),
    (["arabanin", "yerini", "kaydet"], .saveLotSpot), (["lot", "yerini", "kaydet"], .saveLotSpot),
    (["save", "the", "vehicle", "location"], .saveLotSpot), (["save", "the", "lot", "spot"], .saveLotSpot),
    (["arac", "nerede", "duruyor"], .findLotSpot), (["aracin", "yeri", "neresi"], .findLotSpot), (["arac", "nerede"], .findLotSpot),
    (["bu", "arac", "nerede"], .findLotSpot), (["where", "is", "this", "vehicle"], .findLotSpot),
    (["where", "is", "the", "vehicle"], .findLotSpot), (["take", "me", "to", "the", "vehicle"], .findLotSpot),
  ]

  static func dealer(_ u: Utterance, _ context: VoiceBridgeContext) -> VoiceBridgeDecision? {
    guard u.count <= 30 else { return nil }
    if let decision = vehicleQuestion(u, context) { return decision }
    if let decision = odometerValue(u) { return decision }
    if let decision = damage(u) { return decision }
    if context.activeVehicle {
      if let decision = spokenDamage(u) { return decision }
      if let decision = areaClear(u) { return decision }
      if let match = lotPhrases.first(where: { u.count <= $0.0.count + 2 && u.range(of: $0.0) != nil }) {
        return VoiceBridgeDecision(.dealer(match.1), "dealer lot \"\(match.0.joined(separator: " "))\"")
      }
    }
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
    // "Sağ ön lastiği oku": the words before say which tire.
    if case .readTire = best.command, best.range.lowerBound > 0 {
      let position = u.dropping(best.range.lowerBound..<u.count)
      return VoiceBridgeDecision(.dealer(.readTire(position.text)), "dealer tire (\(position.text))")
    }
    guard best.range.lowerBound == 0 || !isReadCommand(best.command) || before.allSatisfy(dealerFillers.contains) else {
      return nil
    }
    return VoiceBridgeDecision(.dealer(best.command), "dealer \"\(best.phrase.joined(separator: " "))\"")
  }

  static let dealerFillers: Set<String> = ["simdi", "bir", "hemen", "lutfen", "please", "now", "sunu", "bu", "su"]

  /// Commands that read with the camera; words before them must be fillers.
  static func isReadCommand(_ command: DealerCommand) -> Bool {
    switch command {
    case .readDashboard, .readPartNumber, .decodeVIN: true
    default: false
    }
  }

  /// "Sağ ön jant çizik, not et", "arka tamponda göçük var kaydet": with an
  /// active vehicle, a zone and a kind of damage make a damage note.
  static func spokenDamage(_ u: Utterance) -> VoiceBridgeDecision? {
    let endings: [[String]] = [
      ["not", "et"], ["not", "al"], ["kaydet"], ["ekle"], ["yaz"], ["note", "it"], ["log", "it"], ["add", "it"], ["note", "that"],
    ]
    guard let ending = endings.first(where: { u.ends(with: $0) }), u.count > ending.count + 1 else { return nil }
    var content = u.dropping((u.count - ending.count)..<u.count)
    content.trimTrailing(["ve", "and", "bunu", "onu", "var", "diye"])
    guard content.count >= 2, content.count <= 10, BodyZone.parse(content.text) != nil,
          DamageFinding.kind(in: content.text) != .other else { return nil }
    return VoiceBridgeDecision(.dealer(.addDamage(capitalizedFirst(content.text))), "dealer spoken damage")
  }

  /// "Sol taraf temiz", "ön taraf hasarsız", "interior is clean".
  static func areaClear(_ u: Utterance) -> VoiceBridgeDecision? {
    let endings: [[String]] = [["temiz"], ["hasarsiz"], ["sorunsuz"], ["is", "clean"], ["clean"], ["no", "damage"]]
    guard let ending = endings.first(where: { u.ends(with: $0) }), u.count > ending.count, u.count <= 6 else { return nil }
    var area = u.dropping((u.count - ending.count)..<u.count)
    area.trimLeading(["the"])
    guard let canonical = VehicleArea.parse(area.text) else { return nil }
    return VoiceBridgeDecision(.dealer(.areaClear(canonical.rawValue)), "dealer area clear")
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
