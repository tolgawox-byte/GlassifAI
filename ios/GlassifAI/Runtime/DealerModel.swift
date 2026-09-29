import Foundation

// MARK: VIN

/// One position the camera could not read with certainty.
struct VINAlternative: Equatable {
  /// 1-based, as said aloud ("8. karakter").
  let position: Int
  let options: [Character]
}

/// The result of checking a VIN as read. Characters are never invented:
/// unreadable ones stay "?", corrections of impossible letters are stated,
/// and when the check digit leaves a choice the choices are reported.
struct VINCheck: Equatable {
  enum Status: Equatable {
    /// 17 valid characters and the check digit matches.
    case valid
    /// 17 valid characters; the check digit does not match (it is only
    /// mandatory for North American vehicles).
    case checkDigitMismatch
    /// Some characters could not be read ("?").
    case incomplete
    case invalid(String)
  }

  let normalized: String
  let status: Status
  /// "O → 0 (5)": letters a VIN cannot contain, read as the digit they look like.
  let corrections: [String]
  let alternatives: [VINAlternative]

  var isUsable: Bool { status == .valid || status == .checkDigitMismatch }

  /// The last six characters, how a dealer refers to a car on the lot.
  var lastSix: String { String(normalized.suffix(6)) }

  func spoken(turkish: Bool) -> String {
    let alternativesText = alternatives.map { alternative in
      let options = alternative.options.map(String.init)
      let joined = options.count <= 2
        ? options.joined(separator: turkish ? " veya " : " or ")
        : options.dropLast().joined(separator: ", ") + (turkish ? " veya " : " or ") + (options.last ?? "")
      return turkish ? "\(alternative.position). karakter \(joined)" : "character \(alternative.position) is \(joined)"
    }.joined(separator: "; ")
    switch status {
    case .valid:
      return turkish ? "VIN okundu ve doğrulandı; son altı hanesi \(spell(lastSix))." : "VIN read and verified; last six \(spell(lastSix))."
    case .checkDigitMismatch:
      var text = turkish
        ? "VIN'i okudum ama kontrol hanesi tutmuyor; son altı hanesi \(spell(lastSix))."
        : "I read the VIN but its check digit does not match; last six \(spell(lastSix))."
      if !alternativesText.isEmpty { text += turkish ? " Olası: \(alternativesText)." : " Possible: \(alternativesText)." }
      return text
    case .incomplete:
      let base = turkish ? "VIN'in bir kısmı okunamadı." : "Part of the VIN could not be read."
      return alternativesText.isEmpty ? base : base + " " + (turkish ? "\(alternativesText)." : "\(alternativesText.prefix(1).uppercased() + alternativesText.dropFirst()).")
    case .invalid(let reason):
      return turkish ? "Okunan metin geçerli bir VIN değil (\(reason))." : "What I read is not a valid VIN (\(reason))."
    }
  }

  private func spell(_ text: String) -> String {
    text.map(String.init).joined(separator: " ")
  }
}

/// ISO 3779 VIN checks: 17 characters, no I/O/Q, the North American check
/// digit (position 9).
enum VINValidator {
  static let weights = [8, 7, 6, 5, 4, 3, 2, 10, 0, 9, 8, 7, 6, 5, 4, 3, 2]

  static func value(of character: Character) -> Int? {
    if let digit = character.wholeNumberValue { return digit }
    let table: [Character: Int] = [
      "A": 1, "B": 2, "C": 3, "D": 4, "E": 5, "F": 6, "G": 7, "H": 8, "J": 1, "K": 2, "L": 3, "M": 4, "N": 5, "P": 7,
      "R": 9, "S": 2, "T": 3, "U": 4, "V": 5, "W": 6, "X": 7, "Y": 8, "Z": 9,
    ]
    return table[character]
  }

  static let allowed: [Character] = Array("0123456789ABCDEFGHJKLMNPRSTUVWXYZ")

  /// Characters a camera or a person easily confuses.
  static let lookalikes: [Character: [Character]] = [
    "0": ["D"], "D": ["0"], "1": ["L", "7"], "L": ["1"], "2": ["Z"], "Z": ["2"], "5": ["S"], "S": ["5"],
    "6": ["G"], "G": ["6"], "8": ["B"], "B": ["8"], "U": ["V"], "V": ["U"], "M": ["N"], "N": ["M"], "7": ["1"],
  ]

  static func checkDigit(for vin: [Character]) -> Character? {
    guard vin.count == 17 else { return nil }
    var sum = 0
    for (index, character) in vin.enumerated() {
      guard let value = value(of: character) else { return nil }
      sum += value * weights[index]
    }
    let remainder = sum % 11
    return remainder == 10 ? "X" : Character(String(remainder))
  }

  static func isValid(_ vin: [Character]) -> Bool {
    vin.count == 17 && vin.allSatisfy(allowed.contains) && checkDigit(for: vin) == vin[8]
  }

  /// Checks what was read ("?" marks an unreadable character).
  static func check(_ raw: String) -> VINCheck {
    var characters: [Character] = []
    var corrections: [String] = []
    for character in raw.uppercased() where !character.isWhitespace && character != "-" && character != "*" {
      characters.append(character)
    }
    for (index, character) in characters.enumerated() {
      let replacement: Character? = switch character {
      case "O", "Q": "0"
      case "I": "1"
      default: nil
      }
      if let replacement {
        characters[index] = replacement
        corrections.append("\(character) → \(replacement) (\(index + 1))")
      }
    }
    let normalized = String(characters)
    guard characters.count == 17 else {
      return VINCheck(
        normalized: normalized, status: .invalid("\(characters.count) karakter / characters"), corrections: corrections,
        alternatives: [])
    }
    if let bad = characters.first(where: { $0 != "?" && !allowed.contains($0) }) {
      return VINCheck(normalized: normalized, status: .invalid("\"\(bad)\""), corrections: corrections, alternatives: [])
    }
    let unknown = characters.indices.filter { characters[$0] == "?" }
    if !unknown.isEmpty {
      // One unreadable character (not the check digit) can be narrowed down
      // by the check digit; it is still reported as options, never chosen.
      var alternatives: [VINAlternative] = []
      if unknown.count == 1, unknown[0] != 8 {
        let position = unknown[0]
        let options = allowed.filter { candidate in
          var copy = characters
          copy[position] = candidate
          return isValid(copy)
        }
        alternatives.append(VINAlternative(position: position + 1, options: options.isEmpty ? ["?"] : options))
      } else {
        alternatives = unknown.map { VINAlternative(position: $0 + 1, options: ["?"]) }
      }
      return VINCheck(normalized: normalized, status: .incomplete, corrections: corrections, alternatives: alternatives)
    }
    if isValid(characters) {
      return VINCheck(normalized: normalized, status: .valid, corrections: corrections, alternatives: [])
    }
    // Which single look-alike swap would satisfy the check digit.
    var alternatives: [VINAlternative] = []
    for index in characters.indices where index != 8 {
      for candidate in lookalikes[characters[index]] ?? [] {
        var copy = characters
        copy[index] = candidate
        if isValid(copy) { alternatives.append(VINAlternative(position: index + 1, options: [characters[index], candidate])) }
      }
    }
    return VINCheck(
      normalized: normalized, status: .checkDigitMismatch, corrections: corrections, alternatives: alternatives)
  }

  /// A 17-character VIN-like token in a longer text ("VIN: 1HGCM82633A004352").
  static func candidate(in text: String) -> String? {
    let tokens = text.uppercased().components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "?")).inverted)
    if let exact = tokens.first(where: { $0.count == 17 }) { return exact }
    // "1HGCM 82633 A004352": groups read with spaces.
    let joined = tokens.filter { !$0.isEmpty }
    for start in joined.indices {
      var text = ""
      for token in joined[start...] {
        text += token
        if text.count == 17 { return text }
        if text.count > 17 { break }
      }
    }
    return nil
  }
}

// MARK: Odometer

struct OdometerReading: Codable, Equatable {
  enum Unit: String, Codable {
    case km
    case mi
  }

  var value: Int
  var unit: Unit
  var at: Date
  /// "spoken" or "camera".
  var source: String

  var text: String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.locale = Locale(identifier: L.isTurkish ? "tr_TR" : "en_US")
    return (formatter.string(from: NSNumber(value: value)) ?? "\(value)") + " " + (unit == .km ? "km" : "mi")
  }

  /// "45 bin 320", "45.320 km", "28,500 miles", "120 bin", "45k". The
  /// recogniser writes numbers as digits. Nil when there is no number.
  static func parse(_ text: String) -> (value: Int, unit: Unit)? {
    let folded = MemorySearch.fold(text)
    let unit: Unit = folded.contains("mile") || folded.contains(" mi ") || folded.hasSuffix(" mi") ? .mi : .km
    var total = 0
    var current = 0
    var found = false
    for raw in folded.split(whereSeparator: \.isWhitespace) {
      var token = String(raw).trimmingCharacters(in: CharacterSet(charactersIn: ":;!?()"))
      if token == "bin" || token == "thousand" {
        total += (current == 0 ? 1 : current) * 1_000
        current = 0
        found = true
        continue
      }
      if token.hasSuffix("km") { token.removeLast(2) }
      if token.hasSuffix("k"), let thousands = Int(token.dropLast()) {
        total += thousands * 1_000
        found = true
        continue
      }
      let digits = token.filter(\.isNumber)
      guard !digits.isEmpty, token.allSatisfy({ $0.isNumber || $0 == "." || $0 == "," }),
            let value = Int(digits) else { continue }
      current += value
      found = true
    }
    total += current
    guard found, total > 0, total < 3_000_000 else { return nil }
    return (total, unit)
  }
}

// MARK: Body zones and damage

enum BodySide: String, Codable { case left, right, center }
enum BodyPosition: String, Codable { case front, rear, middle }

enum BodyPart: String, Codable, CaseIterable {
  case bumper, hood, roof, trunk, fender, quarterPanel, door, mirror, windshield, rearWindow, window, headlight
  case taillight, wheel, tire, rocker, grille, seat, dashboard, interior, engine, underbody, other

  var isInterior: Bool { self == .seat || self == .dashboard || self == .interior }

  func title(turkish: Bool) -> String {
    switch self {
    case .bumper: turkish ? "tampon" : "bumper"
    case .hood: turkish ? "kaput" : "hood"
    case .roof: turkish ? "tavan" : "roof"
    case .trunk: turkish ? "bagaj" : "trunk"
    case .fender: turkish ? "çamurluk" : "fender"
    case .quarterPanel: turkish ? "arka çamurluk" : "quarter panel"
    case .door: turkish ? "kapı" : "door"
    case .mirror: turkish ? "ayna" : "mirror"
    case .windshield: turkish ? "ön cam" : "windshield"
    case .rearWindow: turkish ? "arka cam" : "rear window"
    case .window: turkish ? "cam" : "window"
    case .headlight: turkish ? "far" : "headlight"
    case .taillight: turkish ? "stop lambası" : "taillight"
    case .wheel: turkish ? "jant" : "wheel"
    case .tire: turkish ? "lastik" : "tire"
    case .rocker: turkish ? "marşpiyel" : "rocker panel"
    case .grille: turkish ? "ızgara" : "grille"
    case .seat: turkish ? "koltuk" : "seat"
    case .dashboard: turkish ? "gösterge paneli" : "dashboard"
    case .interior: turkish ? "iç mekan" : "interior"
    case .engine: turkish ? "motor" : "engine"
    case .underbody: turkish ? "alt takım" : "underbody"
    case .other: turkish ? "diğer" : "other"
    }
  }
}

enum DamageKind: String, Codable, CaseIterable {
  case scratch, dent, crack, broken, paint, rust, chip, tear, stain, wear, other

  func title(turkish: Bool) -> String {
    switch self {
    case .scratch: turkish ? "çizik" : "scratch"
    case .dent: turkish ? "göçük" : "dent"
    case .crack: turkish ? "çatlak" : "crack"
    case .broken: turkish ? "kırık" : "broken"
    case .paint: turkish ? "boya" : "paint"
    case .rust: turkish ? "pas" : "rust"
    case .chip: turkish ? "taş izi" : "chip"
    case .tear: turkish ? "yırtık" : "tear"
    case .stain: turkish ? "leke" : "stain"
    case .wear: turkish ? "aşınma" : "wear"
    case .other: turkish ? "hasar" : "damage"
    }
  }
}

/// Where on the car, normalised from Turkish or English words.
struct BodyZone: Codable, Equatable {
  var part: BodyPart
  var side: BodySide
  var position: BodyPosition

  func title(turkish: Bool) -> String {
    var words: [String] = []
    if side != .center { words.append(turkish ? (side == .left ? "sol" : "sağ") : (side == .left ? "left" : "right")) }
    if position != .middle, part != .windshield, part != .rearWindow, part != .quarterPanel {
      words.append(turkish ? (position == .front ? "ön" : "arka") : (position == .front ? "front" : "rear"))
    }
    words.append(part.title(turkish: turkish))
    return words.joined(separator: " ")
  }

  /// "sağ ön çamurluk", "left rear door", "ön cam", "arka tampon".
  static func parse(_ text: String) -> BodyZone? {
    let folded = " " + MemorySearch.fold(text).components(separatedBy: CharacterSet.alphanumerics.inverted)
      .filter { !$0.isEmpty }.joined(separator: " ") + " "
    func has(_ terms: [String]) -> Bool { terms.contains { folded.contains(" " + $0) } }
    let side: BodySide = has(["sag", "right", "passenger"]) ? .right : (has(["sol", "left", "driver"]) ? .left : .center)
    let rear = has(["arka", "rear", "back"])
    let front = has(["on ", "onde", "front"])
    var position: BodyPosition = rear ? .rear : (front ? .front : .middle)
    // "ön çamurluk" folds to "on camurluk": fenders are checked before the
    // glass ("on cam"), and the headliner ("tavan döşeme") before the roof.
    let parts: [(BodyPart, [String])] = [
      (.fender, ["camurluk", "fender", "wing"]),
      (.quarterPanel, ["quarter"]),
      (.windshield, ["on cam", "windshield", "windscreen"]),
      (.rearWindow, ["arka cam", "rear window", "back window"]),
      (.interior, ["tavan doseme", "doseme", "interior", "headliner", "ic mekan"]),
      (.headlight, ["far", "headlight", "head light"]),
      (.taillight, ["stop", "taillight", "tail light", "arka lamba"]),
      (.bumper, ["tampon", "bumper"]),
      (.hood, ["kaput", "hood", "bonnet"]),
      (.roof, ["tavan", "roof"]),
      (.trunk, ["bagaj", "trunk", "tailgate", "boot", "hatch"]),
      (.door, ["kapi", "door"]),
      (.mirror, ["ayna", "mirror"]),
      (.wheel, ["jant", "wheel", "rim"]),
      (.tire, ["lastik", "tire", "tyre"]),
      (.rocker, ["marspiyel", "rocker", "sill"]),
      (.grille, ["izgara", "panjur", "grille", "grill"]),
      (.seat, ["koltuk", "seat"]),
      (.dashboard, ["torpido", "dashboard", "gosterge paneli", "konsol"]),
      (.engine, ["motor", "engine"]),
      (.underbody, ["alt takim", "underbody", "karter"]),
      (.window, ["cam", "window", "glass"]),
    ]
    guard var part = parts.first(where: { has($0.1) })?.0 else { return nil }
    if part == .fender, position == .rear { part = .quarterPanel }
    if part == .bumper, position == .middle { position = .front }
    let alwaysFront: Set<BodyPart> = [.windshield, .hood, .grille, .headlight]
    let alwaysRear: Set<BodyPart> = [.rearWindow, .trunk, .taillight, .quarterPanel]
    let centered: Set<BodyPart> = [.hood, .roof, .windshield, .rearWindow]
    if alwaysFront.contains(part) { position = .front }
    if alwaysRear.contains(part) { position = .rear }
    return BodyZone(part: part, side: centered.contains(part) ? .center : side, position: position)
  }
}

struct DamageFinding: Codable, Equatable, Identifiable {
  var id = UUID()
  var zone: BodyZone?
  var kind: DamageKind
  /// The user's own words.
  var text: String
  var at = Date()
  var captureIDs: [UUID] = []
  /// Said by the user ("hafif", "derin"); nil when not said — never guessed.
  var severity: DamageSeverity?
  /// "spoken" or "camera".
  var source: String?

  func title(turkish: Bool) -> String {
    [zone?.title(turkish: turkish), kind.title(turkish: turkish), severity?.title(turkish: turkish)]
      .compactMap { $0 }.joined(separator: " ")
  }

  static func kind(in text: String) -> DamageKind {
    let folded = " " + MemorySearch.fold(text).components(separatedBy: CharacterSet.alphanumerics.inverted)
      .filter { !$0.isEmpty }.joined(separator: " ") + " "
    let table: [(DamageKind, [String])] = [
      (.scratch, ["cizik", "cizil", "scratch"]),
      (.dent, ["gocuk", "ezik", "dent"]),
      (.crack, ["catlak", "crack"]),
      (.broken, ["kirik", "broken"]),
      (.rust, ["pas", "rust"]),
      (.chip, ["tas izi", "chip"]),
      (.paint, ["boya", "paint"]),
      (.tear, ["yirtik", "tear"]),
      (.stain, ["leke", "stain"]),
      (.wear, ["asinma", "asinmis", "wear", "worn"]),
    ]
    return table.first { entry in entry.1.contains { folded.contains(" " + $0) } }?.0 ?? .other
  }
}

enum DamageSeverity: String, Codable, CaseIterable {
  case minor, moderate, severe

  func title(turkish: Bool) -> String {
    switch self {
    case .minor: turkish ? "(hafif)" : "(minor)"
    case .moderate: turkish ? "(orta)" : "(moderate)"
    case .severe: turkish ? "(ağır)" : "(severe)"
    }
  }

  /// Only words the user said; no words, no severity.
  static func parse(_ text: String) -> DamageSeverity? {
    let words = Set(MemorySearch.fold(text).components(separatedBy: CharacterSet.alphanumerics.inverted))
    if !words.isDisjoint(with: ["agir", "buyuk", "derin", "ciddi", "severe", "major", "deep", "heavy"]) { return .severe }
    if !words.isDisjoint(with: ["orta", "moderate", "medium"]) { return .moderate }
    if !words.isDisjoint(with: ["hafif", "kucuk", "minik", "ufak", "minor", "light", "small", "slight"]) { return .minor }
    return nil
  }
}

// MARK: Checklists

struct ChecklistItem: Codable, Equatable, Identifiable {
  let id: String
  let english: String
  let turkish: String
  /// A Ray-Ban capture with this label ticks the item.
  var captureLabel: CaptureLabel?
  var done = false
  var doneAt: Date?

  var title: String { L.t(english, turkish) }
}

enum DealerChecklists {
  static func photos() -> [ChecklistItem] {
    [
      ChecklistItem(id: "front34left", english: "Front 3/4 left", turkish: "Sol ön çapraz", captureLabel: .front),
      ChecklistItem(id: "front", english: "Front", turkish: "Ön", captureLabel: .front),
      ChecklistItem(id: "front34right", english: "Front 3/4 right", turkish: "Sağ ön çapraz", captureLabel: .front),
      ChecklistItem(id: "rightSide", english: "Right side", turkish: "Sağ yan", captureLabel: .side),
      ChecklistItem(id: "rear34right", english: "Rear 3/4 right", turkish: "Sağ arka çapraz", captureLabel: .rear),
      ChecklistItem(id: "rear", english: "Rear", turkish: "Arka", captureLabel: .rear),
      ChecklistItem(id: "rear34left", english: "Rear 3/4 left", turkish: "Sol arka çapraz", captureLabel: .rear),
      ChecklistItem(id: "leftSide", english: "Left side", turkish: "Sol yan", captureLabel: .side),
      ChecklistItem(id: "dashboard", english: "Dashboard and odometer", turkish: "Gösterge ve kilometre", captureLabel: .odometer),
      ChecklistItem(id: "interiorFront", english: "Front interior", turkish: "Ön iç mekan", captureLabel: .interior),
      ChecklistItem(id: "rearSeats", english: "Rear seats", turkish: "Arka koltuklar", captureLabel: .interior),
      ChecklistItem(id: "engine", english: "Engine bay", turkish: "Motor bölmesi", captureLabel: .engine),
      ChecklistItem(id: "wheels", english: "Wheels and tires", turkish: "Jantlar ve lastikler", captureLabel: .wheel),
      ChecklistItem(id: "vin", english: "VIN plate", turkish: "VIN plakası", captureLabel: .vin),
      ChecklistItem(id: "damage", english: "Damage close-ups", turkish: "Hasar yakın çekimleri", captureLabel: .damage),
    ]
  }

  /// Delivery: no driver's licence or other personal data is stored.
  static func delivery() -> [ChecklistItem] {
    [
      ChecklistItem(id: "documents", english: "Documents ready", turkish: "Evraklar hazır"),
      ChecklistItem(id: "payment", english: "Payment confirmed", turkish: "Ödeme onaylandı"),
      ChecklistItem(id: "pdi", english: "Pre-delivery inspection", turkish: "Teslim öncesi kontrol"),
      ChecklistItem(id: "cleaned", english: "Cleaned", turkish: "Temizlik yapıldı"),
      ChecklistItem(id: "fuel", english: "Fuel or charge", turkish: "Yakıt veya şarj"),
      ChecklistItem(id: "keys", english: "Both keys", turkish: "İki anahtar"),
      ChecklistItem(id: "manuals", english: "Manuals", turkish: "Kılavuzlar"),
      ChecklistItem(id: "spare", english: "Spare or repair kit", turkish: "Stepne veya tamir kiti"),
      ChecklistItem(id: "walkthrough", english: "Customer walkthrough", turkish: "Müşteriye tanıtım"),
      ChecklistItem(id: "photos", english: "Delivery photos", turkish: "Teslim fotoğrafları"),
    ]
  }

  /// Test drive: the licence is checked by the person, never stored.
  static func testDrive() -> [ChecklistItem] {
    [
      ChecklistItem(id: "licenceSeen", english: "Licence checked (not stored)", turkish: "Ehliyet görüldü (saklanmaz)"),
      ChecklistItem(id: "startOdometer", english: "Start odometer", turkish: "Başlangıç kilometresi"),
      ChecklistItem(id: "fuel", english: "Fuel", turkish: "Yakıt"),
      ChecklistItem(id: "route", english: "Route agreed", turkish: "Rota belirlendi"),
      ChecklistItem(id: "returned", english: "Returned, end odometer", turkish: "Döndü, bitiş kilometresi"),
    ]
  }
}

// MARK: Vehicle session

enum VehicleStatus: String, Codable, CaseIterable {
  case intake
  case inspection
  case photos
  case listing
  case ready
  case sold
  case delivered

  var title: String {
    switch self {
    case .intake: L.t("Intake", "Giriş")
    case .inspection: L.t("Inspection", "Ekspertiz")
    case .photos: L.t("Photos", "Fotoğraf")
    case .listing: L.t("Listing", "İlan")
    case .ready: L.t("Ready", "Hazır")
    case .sold: L.t("Sold", "Satıldı")
    case .delivered: L.t("Delivered", "Teslim edildi")
    }
  }
}

/// How the make and model are known.
enum IdentificationSource: String, Codable {
  case none
  /// From the camera, not confirmed ("visual guess").
  case visualGuess
  /// Decoded from a verified VIN or said by the user.
  case confirmed
}

struct ResearchEntry: Codable, Equatable, Identifiable {
  enum Kind: String, Codable { case market, recall, parts, listing }

  var id = UUID()
  var kind: Kind
  var summary: String
  var sources: [String] = []
  var at = Date()
}

/// One vehicle a dealer is working on. Stored on this iPhone only; the
/// plate is kept only when explicitly saved; no customer or licence data.
struct VehicleSession: Codable, Equatable, Identifiable {
  var id = UUID()
  var createdAt = Date()
  var updatedAt = Date()
  var vin: String?
  var vinVerified = false
  var stockNumber: String?
  var year: Int?
  var make: String?
  var model: String?
  var trim: String?
  var bodyStyle: String?
  var color: String?
  var identification: IdentificationSource = .none
  var odometer: OdometerReading?
  var plate: String?
  var location: String?
  var status: VehicleStatus = .intake
  var damage: [DamageFinding] = []
  var interiorNotes: [String] = []
  var mechanicalNotes: [String] = []
  var warningLights: [String] = []
  var photoChecklist = DealerChecklists.photos()
  var deliveryChecklist = DealerChecklists.delivery()
  var testDriveChecklist = DealerChecklists.testDrive()
  var taskIDs: [UUID] = []
  var noteIDs: [UUID] = []
  var captureIDs: [UUID] = []
  var memoryIDs: [UUID] = []
  var research: [ResearchEntry] = []
  var closedAt: Date?
  // Added later: optional, so vehicles saved by older versions still load.
  /// Equipment with where each fact came from.
  var options: [VehicleOption]?
  var vinDecode: VINDecode?
  var recallCheck: RecallCheckResult?
  var tires: [TireReading]?
  var lotSpot: LotSpot?
  /// Areas walked for the condition report ("front", "left", …).
  var inspected: [String]?

  var isOpen: Bool { closedAt == nil }

  /// "2019 Honda Civic", "…4352" or "Araç 14:05".
  var title: String {
    let name = [year.map(String.init), make, model, trim].compactMap { $0 }.joined(separator: " ")
    if !name.isEmpty { return name }
    if let vin { return "VIN …" + vin.suffix(6) }
    return L.t("Vehicle ", "Araç ") + createdAt.formatted(date: .omitted, time: .shortened)
  }

  /// The VIN on screen: only the last six characters.
  var maskedVIN: String? {
    vin.map { String(repeating: "•", count: max(0, $0.count - 6)) + $0.suffix(6) }
  }

  var remainingPhotos: [ChecklistItem] {
    photoChecklist.filter { !$0.done && ($0.id != "damage" || !damage.isEmpty) }
  }

  /// Facts for a listing or research prompt: only what is known, nothing invented.
  func factSheet(turkish: Bool) -> String {
    func label(_ tr: String, _ en: String) -> String { turkish ? tr : en }
    var lines: [String] = []
    var name = label("Araç: ", "Vehicle: ") + title
    if identification == .visualGuess { name += label(" (görsel tahmin, doğrulanmadı)", " (visual guess, not verified)") }
    lines.append(name)
    if let vin {
      let note = vinVerified ? "" : label(" (kontrol hanesi doğrulanmadı)", " (check digit not verified)")
      lines.append("VIN: \(vin)\(note)")
    }
    if let odometer { lines.append(label("Kilometre: ", "Odometer: ") + odometer.text) }
    if let color { lines.append(label("Renk: ", "Colour: ") + color) }
    for finding in damage {
      lines.append("\(label("Hasar: ", "Damage: "))\(finding.title(turkish: turkish)) — \(finding.text)")
    }
    for note in interiorNotes { lines.append(label("İç mekan: ", "Interior: ") + note) }
    for note in mechanicalNotes { lines.append(label("Mekanik: ", "Mechanical: ") + note) }
    for light in warningLights { lines.append(label("Uyarı lambası: ", "Warning light: ") + light) }
    for option in options ?? [] {
      lines.append("\(option.name): \(option.value) [\(option.provenance.rawValue)]")
    }
    for tire in tires ?? [] {
      let facts = [tire.size?.text, tire.dot.map { "DOT \($0.week)/\($0.year)" }].compactMap { $0 }.joined(separator: ", ")
      if !facts.isEmpty { lines.append(label("Lastik", "Tire") + (tire.position.map { " (\($0))" } ?? "") + ": " + facts) }
    }
    if let recallCheck {
      lines.append(label(
        "Geri çağırma (Transport Canada, model yılına göre, VIN'e göre değil): ",
        "Recalls (Transport Canada, by model year, not by VIN): ") + "\(recallCheck.safetyCampaigns.count)")
    }
    return lines.joined(separator: "\n")
  }

  /// The photo checklist item a labelled capture completes.
  mutating func tickPhoto(for label: CaptureLabel, at date: Date = Date()) -> ChecklistItem? {
    guard let index = photoChecklist.firstIndex(where: { !$0.done && $0.captureLabel == label }) else { return nil }
    photoChecklist[index].done = true
    photoChecklist[index].doneAt = date
    return photoChecklist[index]
  }
}

/// Dealer Mode's vehicles, as JSON in Application Support (no database
/// migration risk). One vehicle can be active: notes, tasks and Ray-Ban
/// captures made while it is active link to it.
@MainActor
final class DealerStore: ObservableObject {
  static let shared = DealerStore(directory: ScreenshotMode.storeDirectory)

  @Published private(set) var vehicles: [VehicleSession] = []
  @Published private(set) var activeID: UUID?

  private let fileURL: URL

  init(directory: URL? = nil) {
    let base = directory ?? (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory).appendingPathComponent("AutoLoom", isDirectory: true)
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    fileURL = base.appendingPathComponent("dealer.json")
    load()
  }

  var active: VehicleSession? {
    guard let activeID else { return nil }
    return vehicles.first { $0.id == activeID && $0.isOpen }
  }

  var openVehicles: [VehicleSession] { vehicles.filter(\.isOpen) }

  func vehicle(_ id: UUID) -> VehicleSession? { vehicles.first { $0.id == id } }

  @discardableResult
  func start() -> VehicleSession {
    let session = VehicleSession()
    vehicles.insert(session, at: 0)
    activeID = session.id
    persist()
    return session
  }

  func activate(_ id: UUID?) {
    activeID = id
    persist()
  }

  func update(_ id: UUID, _ change: (inout VehicleSession) -> Void) {
    guard let index = vehicles.firstIndex(where: { $0.id == id }) else { return }
    change(&vehicles[index])
    vehicles[index].updatedAt = Date()
    persist()
  }

  func updateActive(_ change: (inout VehicleSession) -> Void) {
    guard let id = active?.id else { return }
    update(id, change)
  }

  /// A Ray-Ban capture made while a vehicle was active: linked to it, and
  /// a labelled one ticks the photo checklist ("Jantın fotoğrafını çek").
  @discardableResult
  func linkCapture(_ record: CaptureRecord) -> ChecklistItem? {
    guard let id = record.vehicleSessionID, vehicle(id) != nil else { return nil }
    var ticked: ChecklistItem?
    update(id) { session in
      if !session.captureIDs.contains(record.id) { session.captureIDs.append(record.id) }
      if let label = record.label { ticked = session.tickPhoto(for: label) }
      // A photo within three minutes of a damage note documents that damage.
      if record.kind == .photo,
         let index = session.damage.lastIndex(where: { record.createdAt.timeIntervalSince($0.at) < 180 && $0.captureIDs.isEmpty }) {
        session.damage[index].captureIDs.append(record.id)
      }
      if session.status == .intake || session.status == .inspection { session.status = .photos }
    }
    return ticked
  }

  /// "Bu araç tamam": closes the active vehicle.
  @discardableResult
  func finishActive() -> VehicleSession? {
    guard let id = active?.id else { return nil }
    update(id) { $0.closedAt = Date() }
    activeID = nil
    persist()
    return vehicle(id)
  }

  func delete(_ id: UUID) {
    vehicles.removeAll { $0.id == id }
    if activeID == id { activeID = nil }
    persist()
  }

  func deleteEverything() {
    vehicles.removeAll()
    activeID = nil
    persist()
  }

  /// Vehicles touched today, for the dealer briefing.
  func today(now: Date = Date(), calendar: Calendar = .current) -> [VehicleSession] {
    vehicles.filter { calendar.isDate($0.updatedAt, inSameDayAs: now) }
  }

  private struct Snapshot: Codable {
    var vehicles: [VehicleSession]
    var activeID: UUID?
  }

  private func load() {
    guard let data = try? Data(contentsOf: fileURL) else { return }
    guard let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else {
      LocalJSONFile.setAside(fileURL)
      return
    }
    vehicles = snapshot.vehicles
    activeID = snapshot.activeID
  }

  private func persist() {
    guard let data = try? JSONEncoder().encode(Snapshot(vehicles: vehicles, activeID: activeID)) else { return }
    try? data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
  }
}

/// Small JSON files the app keeps on this iPhone.
enum LocalJSONFile {
  /// A file this version cannot read is renamed ("dealer-unreadable-…json")
  /// instead of being overwritten by the next save, so nothing is lost.
  @discardableResult
  static func setAside(_ url: URL, now: Date = Date()) -> URL? {
    let stamp = Int(now.timeIntervalSince1970)
    let name = url.deletingPathExtension().lastPathComponent + "-unreadable-\(stamp)." + url.pathExtension
    let target = url.deletingLastPathComponent().appendingPathComponent(name)
    do {
      try FileManager.default.moveItem(at: url, to: target)
      return target
    } catch {
      return nil
    }
  }
}
