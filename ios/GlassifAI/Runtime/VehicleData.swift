import Foundation

// MARK: Where a fact about a vehicle came from

/// Every equipment fact carries its source; nothing is listed as confirmed
/// unless it was decoded from a checked VIN, seen clearly, or said by the user.
enum FactProvenance: String, Codable, CaseIterable {
  case vinDecoded
  case visuallyConfirmed
  case userConfirmed
  case unverified

  var title: String {
    switch self {
    case .vinDecoded: L.t("VIN decoded", "VIN'den çözüldü")
    case .visuallyConfirmed: L.t("Seen", "Görüldü")
    case .userConfirmed: L.t("Confirmed by you", "Senin onayın")
    case .unverified: L.t("Unverified", "Doğrulanmadı")
    }
  }
}

struct VehicleOption: Codable, Equatable, Identifiable {
  var id = UUID()
  /// "Drive", "Engine", "Heated seats".
  var name: String
  var value: String
  var provenance: FactProvenance
  var at = Date()
}

// MARK: NHTSA vPIC

/// A VIN decoded by NHTSA's vPIC (keyless, US federal data). Only
/// ErrorCode "0" is a clean decode; anything else is shown as partial or
/// asks for a re-scan. Missing values mean "no data", never "not equipped".
struct VINDecode: Codable, Equatable {
  var vin: String
  var make: String?
  var model: String?
  var year: Int?
  var trim: String?
  var series: String?
  var bodyClass: String?
  var driveType: String?
  var engine: String?
  var fuel: String?
  var transmission: String?
  var plant: String?
  var errorCodes: [String]
  var errorText: String
  var at = Date()

  enum Quality: Equatable {
    case clean
    /// Some characters could not be matched: show what was found, ask for the rest.
    case partial
    /// The VIN is probably misread: read it again.
    case rescan
  }

  var quality: Quality {
    if errorCodes == ["0"] { return .clean }
    if errorCodes.contains(where: { ["1", "5", "6", "11", "400"].contains($0) }) { return .rescan }
    return .partial
  }

  /// Equipment facts worth keeping, labelled as VIN decoded.
  var options: [VehicleOption] {
    [
      (L.t("Drive", "Çekiş"), driveType), (L.t("Engine", "Motor"), engine), (L.t("Fuel", "Yakıt"), fuel),
      (L.t("Transmission", "Şanzıman"), transmission), (L.t("Body", "Kasa"), bodyClass),
    ].compactMap { name, value in value.map { VehicleOption(name: name, value: $0, provenance: .vinDecoded) } }
  }
}

enum VPICClient {
  typealias Fetch = (URLRequest) async throws -> (Data, URLResponse)

  static func url(for vin: String, modelYear: Int? = nil) -> URL? {
    var components = URLComponents(string: "https://vpic.nhtsa.dot.gov/api/vehicles/DecodeVinValues/\(vin)")
    components?.queryItems = [URLQueryItem(name: "format", value: "json")]
      + (modelYear.map { [URLQueryItem(name: "modelyear", value: String($0))] } ?? [])
    return components?.url
  }

  static func decode(
    _ vin: String,
    modelYear: Int? = nil,
    fetch: Fetch = { try await URLSession.shared.data(for: $0) }
  ) async throws -> VINDecode {
    guard let url = Self.url(for: vin, modelYear: modelYear) else { throw URLError(.badURL) }
    var request = URLRequest(url: url, timeoutInterval: 12)
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    let (data, response) = try await fetch(request)
    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
      throw URLError(.badServerResponse)
    }
    guard let decoded = parse(data, vin: vin) else { throw URLError(.cannotParseResponse) }
    return decoded
  }

  static func parse(_ data: Data, vin: String) -> VINDecode? {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let results = object["Results"] as? [[String: Any]], let row = results.first else { return nil }
    func value(_ key: String) -> String? {
      let text = (row[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      return text.isEmpty || text == "Not Applicable" ? nil : text
    }
    var engine: String?
    let cylinders = value("EngineCylinders")
    let displacement = value("DisplacementL").flatMap(Double.init).map { String(format: "%.1f L", $0) }
    if cylinders != nil || displacement != nil {
      engine = [cylinders.map { L.t("\($0) cyl", "\($0) silindir") }, displacement].compactMap { $0 }.joined(separator: ", ")
    }
    let codes = (value("ErrorCode") ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    return VINDecode(
      vin: vin, make: value("Make").map(titleCased), model: value("Model"), year: value("ModelYear").flatMap(Int.init),
      trim: value("Trim"), series: value("Series"), bodyClass: value("BodyClass"), driveType: value("DriveType"), engine: engine,
      fuel: value("FuelTypePrimary"), transmission: value("TransmissionStyle"),
      plant: [value("PlantCity"), value("PlantCountry")].compactMap { $0 }.joined(separator: ", ").nilIfEmpty,
      errorCodes: codes.isEmpty ? ["?"] : codes, errorText: value("ErrorText") ?? "")
  }

  /// "HONDA" → "Honda"; short all-caps makes keep their capitals ("BMW", "GMC").
  static func titleCased(_ make: String) -> String {
    make.count <= 3 ? make : make.capitalized
  }
}

extension String {
  var nilIfEmpty: String? { isEmpty ? nil : self }
}

// MARK: Transport Canada recalls

/// Transport Canada's Vehicle Recalls Database (official, keyless). It
/// searches by make, model and year — never by VIN — so a result is always
/// "listed for this model", and zero rows never means "no recalls".
struct RecallCampaign: Codable, Equatable, Identifiable {
  var number: String
  var date: Date?
  var system: String?
  var notificationType: String?
  var summary: String?
  var id: String { number }

  /// Safety and compliance recalls; not inconsequential, superseded or
  /// service campaigns.
  var isSafety: Bool {
    guard let type = notificationType?.lowercased() else { return true }
    return type.contains("safety") || type.contains("compliance")
  }
}

struct RecallCheckResult: Codable, Equatable {
  var make: String
  var model: String
  var year: Int
  var campaigns: [RecallCampaign]
  /// Rows returned before filtering to the exact model name.
  var rows: Int
  var checkedAt = Date()
  var source = "Transport Canada Vehicle Recalls Database"

  var safetyCampaigns: [RecallCampaign] { campaigns.filter(\.isSafety) }

  /// Honest wording: what was searched, what was listed, and that the VIN
  /// itself still has to be checked with the manufacturer.
  func spoken(turkish: Bool, portal: String?) -> String {
    let vehicle = "\(year) \(make) \(model)"
    let date = checkedAt.formatted(date: .abbreviated, time: .omitted)
    let vinStep = portal.map { turkish ? " Bu VIN için üreticinin sayfasında (\($0)) kontrol gerekiyor." : " This VIN still needs a check on the manufacturer's page (\($0))." }
      ?? (turkish ? " Bu VIN için üretici veya bayi sisteminde kontrol gerekiyor." : " This VIN still needs a check with the manufacturer or a dealer system.")
    if campaigns.isEmpty {
      return turkish
        ? "Transport Canada \(vehicle) için kayıt döndürmedi (\(date)). Bu, geri çağırma olmadığı anlamına gelmez; model adı farklı yazılmış olabilir." + vinStep
        : "Transport Canada returned no rows for the \(vehicle) (\(date)). That does not mean there are no recalls; the model name may be spelled differently." + vinStep
    }
    let safety = safetyCampaigns
    let systems = Array(Set(safety.compactMap(\.system))).sorted().prefix(4).joined(separator: ", ")
    let list = systems.isEmpty ? "" : (turkish ? " (sistemler: \(systems))" : " (systems: \(systems))")
    return turkish
      ? "Transport Canada \(vehicle) modeli için \(safety.count) güvenlik geri çağırması listeliyor\(list); bu arama model yılına göre, VIN'e göre değil (\(date))." + vinStep
      : "Transport Canada lists \(safety.count) safety recalls for the \(vehicle) model\(list); this search is by model year, not by VIN (\(date))." + vinStep
  }
}

enum TransportCanadaRecalls {
  typealias Fetch = VPICClient.Fetch
  static let base = "https://data.tc.gc.ca/v1.3/api/eng/vehicle-recall-database"

  static func searchURL(make: String, model: String, year: Int, page: Int) -> URL? {
    let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
    guard let make = make.lowercased().addingPercentEncoding(withAllowedCharacters: allowed),
          let model = model.lowercased().addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
    return URL(string: "\(base)/recall/make-name/\(make)/model-name/\(model)/year-range/\(year)-\(year)?format=json&page=\(page)")
  }

  static func summaryURL(number: String) -> URL? {
    URL(string: "\(base)/recall-summary/recall-number/\(number)?format=json")
  }

  static func check(
    make: String,
    model: String,
    year: Int,
    maxPages: Int = 4,
    maxSummaries: Int = 12,
    fetch: Fetch = { try await URLSession.shared.data(for: $0) }
  ) async throws -> RecallCheckResult {
    var rows: [[String: String]] = []
    for page in 1...maxPages {
      guard let url = searchURL(make: make, model: model, year: year, page: page) else { throw URLError(.badURL) }
      let pageRows = try await resultSet(url, fetch: fetch)
      if pageRows.isEmpty { break }
      rows += pageRows
      if pageRows.count < 25 { break }
    }
    // The model name is prefix-matched ("civ" finds CIVIC): keep exact names.
    let wanted = normalized(model)
    let exact = rows.filter { normalized($0["Model name"] ?? "") == wanted }
    var numbers: [String] = []
    for row in exact {
      if let number = row["Recall number"], !numbers.contains(number) { numbers.append(number) }
    }
    var campaigns: [RecallCampaign] = []
    for number in numbers.prefix(maxSummaries) {
      var campaign = RecallCampaign(number: number)
      if let url = summaryURL(number: number), let summary = try? await resultSet(url, fetch: fetch).first {
        campaign.system = summary["SYSTEM_TYPE_ETXT"]
        campaign.notificationType = summary["NOTIFICATION_TYPE_ETXT"]
        campaign.summary = summary["COMMENT_ETXT"].map { String($0.prefix(600)) }
        campaign.date = summary["RECALL_DATE_DTE"].flatMap(parseDate)
      } else {
        let row = exact.first(where: { $0["Recall number"] == number })
        campaign.date = row?["Recall date"].flatMap(parseDate)
      }
      campaigns.append(campaign)
    }
    // Campaigns beyond the summaries still count, without details.
    for number in numbers.dropFirst(maxSummaries) { campaigns.append(RecallCampaign(number: number)) }
    return RecallCheckResult(make: make, model: model, year: year, campaigns: campaigns, rows: rows.count)
  }

  /// Rows of a `{"ResultSet":[[{"Name":…,"Value":{"Literal":…}}]]}` envelope.
  static func resultSet(_ url: URL, fetch: Fetch) async throws -> [[String: String]] {
    var request = URLRequest(url: url, timeoutInterval: 15)
    // Without it the API answers HTTP 500.
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    let (data, response) = try await fetch(request)
    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
      throw URLError(.badServerResponse)
    }
    return parseResultSet(data)
  }

  static func parseResultSet(_ data: Data) -> [[String: String]] {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let set = object["ResultSet"] as? [[[String: Any]]] else { return [] }
    return set.map { fields in
      var row: [String: String] = [:]
      for field in fields {
        guard let name = field["Name"] as? String, let value = field["Value"] as? [String: Any] else { continue }
        if let literal = value["Literal"] as? String { row[name] = literal } else if let number = value["Literal"] as? NSNumber {
          row[name] = number.stringValue
        }
      }
      return row
    }
  }

  static func normalized(_ name: String) -> String {
    name.uppercased().filter { $0.isLetter || $0.isNumber }
  }

  /// "5/28/2020 12:00:00 AM" or an ISO date.
  static func parseDate(_ text: String) -> Date? {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "America/Toronto")
    for format in ["M/d/yyyy h:mm:ss a", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd"] {
      formatter.dateFormat = format
      if let date = formatter.date(from: text) { return date }
    }
    return nil
  }

  /// The manufacturer's Canadian VIN recall page, listed by Transport
  /// Canada. The app opens it for the user; it never reads those pages.
  static let manufacturerPortals: [String: String] = [
    "ACURA": "https://www.acura.ca/recalls", "HONDA": "https://www.honda.ca/recalls",
    "TOYOTA": "https://www.toyota.ca/toyota/en/my-toyota/recalls", "LEXUS": "https://www.lexus.ca/lexus/en/secure/owners/campaigns",
    "NISSAN": "https://service.nissan.ca/en/vin-recall", "INFINITI": "https://service.infiniti.ca/en/vin-recall",
    "MAZDA": "https://www.mazdarecalls.ca", "SUZUKI": "https://www.suzuki.ca/recalls/",
    "FORD": "https://www.ford.ca/support/recalls/", "LINCOLN": "https://www.lincolncanada.com/support/recalls/",
    "CHEVROLET": "https://experience.gm.ca/en/ownercenter/recalls", "GMC": "https://experience.gm.ca/en/ownercenter/recalls",
    "BUICK": "https://experience.gm.ca/en/ownercenter/recalls", "CADILLAC": "https://experience.gm.ca/en/ownercenter/recalls",
    "CHRYSLER": "https://recalls.mopar.ca", "DODGE": "https://recalls.mopar.ca", "JEEP": "https://recalls.mopar.ca",
    "RAM": "https://recalls.mopar.ca", "FIAT": "https://recalls.mopar.ca", "ALFA ROMEO": "https://recalls.mopar.ca",
    "TESLA": "https://www.tesla.com/vin-recall-search", "HYUNDAI": "https://recall.hyundaicanada.com/en",
    "GENESIS": "https://recall.genesis.ca/en", "KIA": "https://www.kia.ca/kia-recall",
    "VOLKSWAGEN": "https://www.vw.ca/en/owners-and-drivers/recalls.html", "AUDI": "https://www.audi.ca/en/recalls/",
    "BMW": "https://www.bmw.ca/en/ssl/VehicleRecall.html", "MINI": "https://www.mini.ca/en/owners/mini-recall",
    "MERCEDES-BENZ": "https://www.mercedes-benz.ca/en/recalls", "VOLVO": "https://www.volvocars.com/en-ca/l/recall-information/",
    "JAGUAR": "https://www.jaguar.com/en-ca/jdx/ownership/vin-recall.html",
    "LAND ROVER": "https://www.landrover.ca/en/ownership/vin-recall.html",
  ]

  static func portal(forMake make: String) -> String? {
    let key = make.uppercased()
    return manufacturerPortals[key] ?? (key == "MERCEDES" ? manufacturerPortals["MERCEDES-BENZ"] : nil)
  }
}

// MARK: Tires

/// "215/55R16 93V" and the DOT date code ("…2319" = week 23 of 2019),
/// read from the sidewall. Tread depth is never estimated from a photo.
struct TireSize: Codable, Equatable {
  var width: Int
  var aspect: Int
  var construction: String
  var rim: Int
  var loadIndex: Int?
  var speedRating: String?

  var text: String {
    "\(width)/\(aspect)\(construction)\(rim)" + (loadIndex.map { " \($0)" } ?? "") + (speedRating ?? "")
  }

  static func parse(_ raw: String) -> TireSize? {
    let text = raw.uppercased().replacingOccurrences(of: " ", with: "")
    guard let regex = try? NSRegularExpression(pattern: #"(?:P|LT)?(\d{3})/(\d{2})(ZR|R|D|B)(\d{2})(\d{2,3})?([A-Z])?"#),
          let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
    func group(_ index: Int) -> String? {
      guard let range = Range(match.range(at: index), in: text) else { return nil }
      return String(text[range])
    }
    guard let width = group(1).flatMap(Int.init), let aspect = group(2).flatMap(Int.init),
          let construction = group(3), let rim = group(4).flatMap(Int.init),
          (125...395).contains(width), (25...85).contains(aspect), (10...24).contains(rim) else { return nil }
    return TireSize(
      width: width, aspect: aspect, construction: construction, rim: rim, loadIndex: group(5).flatMap(Int.init),
      speedRating: group(6))
  }
}

struct DOTDate: Codable, Equatable {
  var week: Int
  var year: Int

  /// The last four digits after "DOT" (2000 and later).
  static func parse(_ raw: String) -> DOTDate? {
    let text = raw.uppercased()
    guard let dot = text.range(of: "DOT") else { return nil }
    // The TIN runs to the end of its line; the date code is its last group.
    let segment = text[dot.upperBound...].prefix { $0 != "\n" && $0 != "(" }
    let tokens = segment.split(whereSeparator: { $0 == " " || $0 == ":" || $0 == "," })
      .map { String($0).trimmingCharacters(in: .punctuationCharacters) }
      .filter { !$0.isEmpty }
    var code = tokens.last(where: { $0.count == 4 && $0.allSatisfy(\.isNumber) })
    if code == nil, let last = tokens.last, last.count >= 8, last.suffix(4).allSatisfy(\.isNumber) {
      code = String(last.suffix(4))
    }
    guard let code, let week = Int(code.prefix(2)), let year2 = Int(code.suffix(2)), (1...53).contains(week) else { return nil }
    return DOTDate(week: week, year: 2000 + year2)
  }

  func ageInYears(now: Date = Date(), calendar: Calendar = .current) -> Double? {
    var components = DateComponents()
    components.weekOfYear = week
    components.yearForWeekOfYear = year
    components.weekday = 2
    guard let made = Calendar(identifier: .iso8601).date(from: components) else { return nil }
    return now.timeIntervalSince(made) / (365.25 * 86_400)
  }
}

struct TireReading: Codable, Equatable, Identifiable {
  var id = UUID()
  /// "sağ ön", "right front", or nil when not said.
  var position: String?
  var size: TireSize?
  var dot: DOTDate?
  /// What was read, with ? for unreadable characters.
  var raw: String
  var at = Date()

  func spoken(turkish: Bool, now: Date = Date()) -> String {
    var parts: [String] = []
    if let size { parts.append(turkish ? "ebat \(size.text)" : "size \(size.text)") }
    if let dot, let age = dot.ageInYears(now: now) {
      let years = String(format: "%.1f", max(0, age))
      parts.append(turkish ? "üretim \(dot.week). hafta \(dot.year) (yaklaşık \(years) yıllık)" : "made week \(dot.week) of \(dot.year) (about \(years) years old)")
    }
    let where_ = position.map { "\($0): " } ?? ""
    guard !parts.isEmpty else {
      return turkish ? "\(where_)Lastik yazısını net okuyamadım." : "\(where_)I couldn't read the sidewall clearly."
    }
    return where_ + parts.joined(separator: ", ") + (turkish ? ". Diş derinliğini fotoğraftan ölçemem." : ". I can't measure tread depth from a photo.")
  }
}

// MARK: Lot memory

/// Where a vehicle stands on the lot (GPS + optional words: "3. sıra, 12").
struct LotSpot: Codable, Equatable {
  var latitude: Double?
  var longitude: Double?
  var note: String?
  var at = Date()
}

// MARK: Areas of the walk-around

enum VehicleArea: String, Codable, CaseIterable {
  case front, rear, left, right, roof, interior, underbody, wheels, engineBay

  func title(turkish: Bool) -> String {
    switch self {
    case .front: turkish ? "Ön" : "Front"
    case .rear: turkish ? "Arka" : "Rear"
    case .left: turkish ? "Sol taraf" : "Left side"
    case .right: turkish ? "Sağ taraf" : "Right side"
    case .roof: turkish ? "Tavan" : "Roof"
    case .interior: turkish ? "İç mekân" : "Interior"
    case .underbody: turkish ? "Alt taraf" : "Underbody"
    case .wheels: turkish ? "Jant ve lastikler" : "Wheels and tires"
    case .engineBay: turkish ? "Motor bölümü" : "Engine bay"
    }
  }

  /// "Sol taraf", "ön", "interior", "jantlar". Nil for anything else.
  static func parse(_ text: String) -> VehicleArea? {
    let table: [(VehicleArea, Set<String>)] = [
      (.front, ["on", "onu", "front"]), (.rear, ["arka", "arkasi", "rear", "back"]), (.left, ["sol", "left"]),
      (.right, ["sag", "right"]), (.roof, ["tavan", "tavani", "roof"]),
      (.interior, ["ic", "ici", "icerisi", "interior", "inside", "kabin", "cabin", "mekan"]),
      (.underbody, ["alt", "alti", "underbody", "underneath"]),
      (.wheels, ["jant", "jantlar", "tekerlek", "tekerlekler", "lastik", "lastikler", "wheels", "tires", "tyres"]),
      (.engineBay, ["motor", "kaput", "engine", "bay"]),
    ]
    let fillers: Set<String> = ["taraf", "tarafi", "yan", "yani", "side", "the", "kismi", "bolum", "bolumu", "da", "de"]
    let words = MemorySearch.fold(text).components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    var found: Set<VehicleArea> = []
    for word in words {
      if fillers.contains(word) { continue }
      guard let area = table.first(where: { $0.1.contains(word) })?.0 else { return nil }
      found.insert(area)
    }
    return found.count == 1 ? found.first : nil
  }
}
