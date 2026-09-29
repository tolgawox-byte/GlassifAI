import Foundation

/// Dealer SuperMode: VIN decoding, official recall lookups, tires, warning
/// lights, the condition report, service handoff, lot memory, part numbers.
/// Readings from the camera are copied exactly (? for anything unclear);
/// nothing is certified, diagnosed or priced by the app.
extension AssistantOrchestrator {
  private var noVehicle: IntentOutcome {
    dealerOutcome(
      tr: "Açık bir araç yok; önce “yeni araç” de.", en: "No open vehicle; say “new vehicle” first.", failed: "no active vehicle")
  }

  /// The vehicle a screen asked about, else the active one (voice).
  private func dealerVehicle(_ id: UUID?) -> VehicleSession? {
    id.flatMap { DealerStore.shared.vehicle($0) } ?? DealerStore.shared.active
  }

  // MARK: VIN decoding (NHTSA vPIC)

  func decodeVIN(traceID: UUID, vehicleID: UUID? = nil) async -> IntentOutcome {
    guard let session = dealerVehicle(vehicleID) else { return noVehicle }
    guard let vin = session.vin else {
      return dealerOutcome(tr: "Önce VIN'i okuyalım: “VIN oku” de.", en: "Let's read the VIN first: say “read the VIN”.", failed: "no VIN")
    }
    ActionTraceLog.shared.update(traceID) { $0.executor = "NHTSA vPIC DecodeVinValues (keyless)" }
    let decode: VINDecode
    do {
      decode = try await VPICClient.decode(vin)
    } catch {
      return dealerOutcome(
        tr: "VIN çözme servisine ulaşamadım; internet gerekli.", en: "I couldn't reach the VIN decoder; it needs the internet.",
        failed: "vPIC unreachable")
    }
    applyDecode(decode, to: session.id)
    ActionTraceLog.shared.update(traceID) {
      $0.parsed = "ErrorCode \(decode.errorCodes.joined(separator: ","))"
      $0.persistence = "VIN decode saved on the vehicle"
    }
    let name = DealerStore.shared.vehicle(session.id)?.title ?? session.title
    switch decode.quality {
    case .clean:
      let extras = decode.options.prefix(3).map(\.value).joined(separator: ", ")
      return dealerOutcome(
        tr: "VIN çözüldü: \(name)" + (extras.isEmpty ? "." : "; \(extras)."),
        en: "VIN decoded: \(name)" + (extras.isEmpty ? "." : "; \(extras)."),
        feedback: ActionFeedback(kind: .note, title: L.t("VIN decoded", "VIN çözüldü"), detail: name))
    case .partial:
      let found = [decode.year.map(String.init), decode.make, decode.model].compactMap { $0 }.joined(separator: " ")
      return dealerOutcome(
        tr: "VIN kısmen çözüldü" + (found.isEmpty ? "." : ": \(found).") + " Eksikleri sen tamamlayabilirsin.",
        en: "The VIN decoded only partly" + (found.isEmpty ? "." : ": \(found).") + " You can fill in the rest.")
    case .rescan:
      return dealerOutcome(
        tr: "VIN doğru okunmamış olabilir; bir kez daha okuyalım.", en: "The VIN may be misread; let's read it once more.",
        failed: "VIN decode error")
    }
  }

  /// A clean decode fills what is missing or only guessed; a partial one
  /// only the make and year. Decoded equipment is labelled as such.
  func applyDecode(_ decode: VINDecode, to id: UUID) {
    DealerStore.shared.update(id) { session in
      session.vinDecode = decode
      guard decode.quality != .rescan else { return }
      let replace = session.identification != .confirmed
      if decode.quality == .clean {
        if replace || session.year == nil { session.year = decode.year ?? session.year }
        if replace || session.make == nil { session.make = decode.make ?? session.make }
        if replace || session.model == nil { session.model = decode.model ?? session.model }
        if replace || session.trim == nil { session.trim = decode.trim ?? session.trim }
        if session.bodyStyle == nil { session.bodyStyle = decode.bodyClass }
        if session.vinVerified { session.identification = .confirmed }
        session.options = (session.options ?? []).filter { $0.provenance != .vinDecoded } + decode.options
      } else {
        if session.year == nil { session.year = decode.year }
        if session.make == nil { session.make = decode.make }
      }
    }
  }

  // MARK: Recalls (Transport Canada)

  /// The official Canadian lookup by make, model and year. Nil when the
  /// vehicle is not identified well enough or the service is unreachable
  /// (the caller then researches on the web with the same honest wording).
  func checkRecallsOfficially(_ id: UUID, traceID: UUID) async -> IntentOutcome? {
    let store = DealerStore.shared
    guard var session = store.vehicle(id) else { return nil }
    if session.model == nil || session.year == nil, let vin = session.vin, session.vinVerified,
       let decode = try? await VPICClient.decode(vin) {
      applyDecode(decode, to: id)
      session = store.vehicle(id) ?? session
    }
    guard let make = session.make, let model = session.model, let year = session.year else { return nil }
    ActionTraceLog.shared.update(traceID) {
      $0.executor = "Transport Canada Vehicle Recalls Database (official API, by make/model/year)"
    }
    let result: RecallCheckResult
    do {
      result = try await TransportCanadaRecalls.check(make: make, model: model, year: year)
    } catch {
      ActionTraceLog.shared.update(traceID) { $0.result = "Transport Canada unreachable; web research instead" }
      return nil
    }
    let portal = TransportCanadaRecalls.portal(forMake: make)
    let turkish = result.spoken(turkish: true, portal: portal)
    let english = result.spoken(turkish: false, portal: portal)
    let search = TransportCanadaRecalls.searchURL(make: make, model: model, year: year, page: 1)?.absoluteString
    store.update(id) {
      $0.recallCheck = result
      $0.research.append(ResearchEntry(kind: .recall, summary: L.t(english, turkish), sources: [search, portal].compactMap { $0 }))
    }
    ActionTraceLog.shared.update(traceID) {
      $0.parsed = "\(result.safetyCampaigns.count) safety campaigns of \(result.campaigns.count); \(result.rows) rows"
      $0.persistence = "recall check saved on the vehicle"
    }
    return IntentOutcome(
      spoken: BridgeSpeech.done(
        "Official Transport Canada lookup by make, model and year (not by VIN). Never say there are no recalls.",
        tr: turkish, en: english),
      reply: L.t(english, turkish), said: L.t(english, turkish))
  }

  // MARK: Tires

  func readTire(_ position: String?, traceID: UUID) async -> IntentOutcome {
    ActionTraceLog.shared.update(traceID) { $0.executor = "vision (sidewall text) → TireSize/DOT parsing on the phone" }
    let result = await runBridgeTask(
      .vision,
      query: "Read the tire sidewall. Copy exactly what is printed: the size code (like 215/55R16 91V) and the DOT code (the letters and digits after DOT, especially the last four digits). Write ? for any character you cannot read with certainty; never guess. Reply as: SIZE: … DOT: … . Do not judge tread depth or condition.",
      detail: .high)
    guard result.failed == nil, let text = result.display, !text.isEmpty else {
      return dealerOutcome(
        tr: "Lastik yazısını okuyamadım; yazıya biraz daha yaklaş.", en: "I couldn't read the sidewall; move a little closer to the text.",
        failed: result.failed ?? "no answer")
    }
    let reading = TireReading(position: position, size: TireSize.parse(text), dot: DOTDate.parse(text), raw: String(text.prefix(120)))
    if reading.size != nil || reading.dot != nil, let session = DealerStore.shared.active {
      DealerStore.shared.update(session.id) { $0.tires = ($0.tires ?? []) + [reading] }
      ActionTraceLog.shared.update(traceID) { $0.persistence = "tire reading saved on the vehicle" }
    }
    return dealerOutcome(
      tr: reading.spoken(turkish: true), en: reading.spoken(turkish: false),
      failed: reading.size == nil && reading.dot == nil ? "sidewall unreadable" : nil)
  }

  // MARK: Warning lights

  func readDashboard(traceID: UUID) async -> IntentOutcome {
    ActionTraceLog.shared.update(traceID) { $0.executor = "vision (instrument cluster), no diagnosis" }
    let result = await runBridgeTask(
      .vision,
      query: "Look at the instrument cluster. List only the warning or indicator lights that are clearly lit, by their standard name and colour (for example: check engine – amber), one per line. If none is clearly lit, reply exactly “none”. If the cluster is not visible or too blurry, reply exactly “unclear”. Do not diagnose causes.",
      detail: .high)
    guard result.failed == nil, let text = result.display?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
      return dealerOutcome(tr: "Göstergeyi okuyamadım.", en: "I couldn't read the cluster.", failed: result.failed ?? "no answer")
    }
    let lowered = text.lowercased()
    if lowered.hasPrefix("unclear") {
      return dealerOutcome(
        tr: "Göstergeyi net göremedim; biraz yaklaş, kontak açık olmalı.",
        en: "I can't see the cluster clearly; move closer, with the ignition on.", failed: "cluster unclear")
    }
    let lights = lowered.hasPrefix("none") ? [] : text.split(whereSeparator: { $0 == "\n" || $0 == "," || $0 == ";" })
      .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " -•*")) }.filter { !$0.isEmpty }.prefix(8).map { String($0) }
    if let session = DealerStore.shared.active {
      DealerStore.shared.update(session.id) { $0.warningLights = lights }
      ActionTraceLog.shared.update(traceID) { $0.persistence = "warning lights saved on the vehicle (\(lights.count))" }
    }
    guard !lights.isEmpty else {
      return dealerOutcome(
        tr: "Net yanan bir uyarı lambası görmedim. Kontak açıkken bakıldığından emin ol.",
        en: "I don't see any warning light clearly lit. Make sure the ignition is on.")
    }
    let list = lights.joined(separator: ", ")
    return dealerOutcome(
      tr: "Yanan uyarı lambaları: \(list). Bu bir teşhis değil; servis kontrol etmeli.",
      en: "Lit warning lights: \(list). That's not a diagnosis; service should check it.")
  }

  // MARK: Reports

  func conditionReport(traceID: UUID, vehicleID: UUID? = nil) -> IntentOutcome {
    guard let session = dealerVehicle(vehicleID) else { return noVehicle }
    let turkish = L.isTurkish
    let report = VehicleReport.condition(session, turkish: turkish)
    return saveReport(report, title: L.t("Condition report: ", "Kondisyon raporu: ") + session.title, session: session, traceID: traceID) {
      let open = VehicleReport.uninspected(session)
      let rest = open.prefix(3).map { $0.title(turkish: true).lowercased() }.joined(separator: ", ")
      let restEN = open.prefix(3).map { $0.title(turkish: false).lowercased() }.joined(separator: ", ")
      return (
        "Kondisyon raporunu notlara kaydettim: \(session.damage.count) hasar" + (open.isEmpty ? "." : "; kontrol edilmeyen: \(rest)."),
        "I saved the condition report to your notes: \(session.damage.count) damage notes" + (open.isEmpty ? "." : "; not yet checked: \(restEN).")
      )
    }
  }

  func serviceHandoff(traceID: UUID, vehicleID: UUID? = nil) -> IntentOutcome {
    guard let session = dealerVehicle(vehicleID) else { return noVehicle }
    let open = MemoryStore.shared.tasks.filter { !$0.completed && session.taskIDs.contains($0.id) }.map(\.title)
    let report = VehicleReport.serviceHandoff(session, turkish: L.isTurkish, openTasks: open)
    return saveReport(report, title: L.t("Service handoff: ", "Servis devri: ") + session.title, session: session, traceID: traceID) {
      ("Servis notunu hazırlayıp notlara kaydettim; paylaşmak istersen söyle.",
       "I prepared the service note and saved it to your notes; say if you want to share it.")
    }
  }

  private func saveReport(
    _ report: String,
    title: String,
    session: VehicleSession,
    traceID: UUID,
    spoken: () -> (String, String)
  ) -> IntentOutcome {
    guard let note = MemoryStore.shared.addNote(title: title, content: report, source: "dealer") else {
      return dealerOutcome(tr: "Raporu kaydedemedim.", en: "I couldn't save the report.", failed: "note save failed")
    }
    DealerStore.shared.update(session.id) { $0.noteIDs.append(note.id) }
    recentSaved = (report, Date(), note.id)
    ActionTraceLog.shared.update(traceID) { $0.persistence = "report saved as a note (\(note.id.uuidString.prefix(8)))" }
    let words = spoken()
    return dealerOutcome(tr: words.0, en: words.1, feedback: .noteSaved(preview: title))
  }

  // MARK: Lot memory

  func saveLotSpot(transcript: String, traceID: UUID, vehicleID: UUID? = nil) async -> IntentOutcome {
    guard let session = dealerVehicle(vehicleID) else { return noVehicle }
    ActionTraceLog.shared.update(traceID) { $0.executor = "one location fix (When In Use) → the vehicle's lot spot" }
    let fix = await ParkingStore.shared.locate()
    guard case .located(let location) = fix else {
      return dealerOutcome(
        tr: fix == .noPermission ? "Konum izni olmadan aracın yerini kaydedemem." : "Konumu şu an alamadım; biraz sonra tekrar dene.",
        en: fix == .noPermission ? "I can't save the spot without location access." : "I couldn't get the location; try again in a moment.",
        failed: fix == .noPermission ? "location permission" : "no location fix")
    }
    let previous = session.lotSpot
    let spot = LotSpot(latitude: location.latitude, longitude: location.longitude, note: location.placeName)
    DealerStore.shared.update(session.id) { $0.lotSpot = spot }
    let id = session.id
    LocalUndo.shared.record(kind: "lotSpot", english: "vehicle spot removed", turkish: "aracın yeri geri alındı") {
      guard DealerStore.shared.vehicle(id)?.lotSpot == spot else { return false }
      DealerStore.shared.update(id) { $0.lotSpot = previous }
      return true
    }
    ActionTraceLog.shared.update(traceID) { $0.persistence = "lot spot saved on the vehicle" }
    return dealerOutcome(tr: "\(session.title) aracının yerini kaydettim.", en: "Saved where the \(session.title) stands.")
  }

  func findLotSpot(traceID: UUID) async -> IntentOutcome {
    guard let session = DealerStore.shared.active else { return noVehicle }
    guard let spot = session.lotSpot, let latitude = spot.latitude, let longitude = spot.longitude else {
      return dealerOutcome(
        tr: "Bu aracın yeri kayıtlı değil; yanındayken “aracın yerini kaydet” de.",
        en: "This vehicle's spot isn't saved; say “save the vehicle location” next to it.", failed: "no lot spot")
    }
    guard AssistantPreferences.actionsEnabled else { return actionsOff() }
    guard ToolRegistry.allows(.openMaps) else { return toolOff(.openMaps) }
    let point = String(format: "%.6f,%.6f", latitude, longitude)
    var components = URLComponents(string: "https://maps.apple.com/")
    components?.queryItems = [URLQueryItem(name: "daddr", value: point), URLQueryItem(name: "dirflg", value: "w")]
    guard let url = components?.url else { return dealerOutcome(tr: "Harita açılamadı.", en: "Maps couldn't open.", failed: "bad URL") }
    ActionTraceLog.shared.update(traceID) { $0.executor = "Apple Maps (walking, to the vehicle's saved spot)" }
    return await openMaps(url, destination: point, label: session.title, traceID: traceID)
  }

  // MARK: Part numbers

  func readPartNumber(traceID: UUID) async -> IntentOutcome {
    ActionTraceLog.shared.update(traceID) { $0.executor = "vision (exact text), saved as research on the vehicle" }
    let result = await runBridgeTask(
      .vision,
      query: "Read the part number printed on the part or its label, exactly as printed. Write ? for any character you cannot read with certainty; never guess. Reply with only the part number(s), comma-separated, or exactly “none” if no part number is visible.",
      detail: .high)
    guard result.failed == nil, let text = result.display?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
          !text.lowercased().hasPrefix("none") else {
      return dealerOutcome(
        tr: "Parça numarası göremedim; etikete biraz daha yaklaş.", en: "I can't see a part number; move closer to the label.",
        failed: result.failed ?? "no part number")
    }
    let number = String(text.prefix(80))
    if let session = DealerStore.shared.active {
      DealerStore.shared.update(session.id) {
        $0.research.append(ResearchEntry(kind: .parts, summary: L.t("Part number read by the camera: ", "Kamerayla okunan parça numarası: ") + number))
      }
    }
    let unsure = number.contains("?")
    return dealerOutcome(
      tr: "Parça numarası: \(number)." + (unsure ? " Soru işaretli haneleri okuyamadım." : "") + " İstersen araştırırım.",
      en: "Part number: \(number)." + (unsure ? " I couldn't read the characters marked ?." : "") + " I can look it up if you want.")
  }

  // MARK: Walk-around

  func markAreaClear(_ raw: String, traceID: UUID) -> IntentOutcome {
    guard let session = DealerStore.shared.active else { return noVehicle }
    guard let area = VehicleArea(rawValue: raw) else {
      return dealerOutcome(tr: "Hangi bölge?", en: "Which area?", failed: "unknown area")
    }
    let id = session.id
    let before = session.inspected
    DealerStore.shared.update(id) {
      var list = $0.inspected ?? []
      if !list.contains(area.rawValue) { list.append(area.rawValue) }
      $0.inspected = list
    }
    LocalUndo.shared.record(kind: "area", english: "area check removed", turkish: "bölge kontrolü geri alındı") {
      DealerStore.shared.update(id) { $0.inspected = before }
      return true
    }
    ActionTraceLog.shared.update(traceID) { $0.persistence = "area \(area.rawValue) marked checked" }
    let remaining = DealerStore.shared.vehicle(id).map(VehicleReport.uninspected) ?? []
    let next = remaining.first
    return dealerOutcome(
      tr: "\(area.title(turkish: true)) temiz olarak işaretlendi." + (next.map { " Sıradaki: \($0.title(turkish: true).lowercased())." } ?? " Tüm bölgeler kontrol edildi."),
      en: "\(area.title(turkish: false)) marked clean." + (next.map { " Next: \($0.title(turkish: false).lowercased())." } ?? " Every area is checked."))
  }

  // MARK: Export

  /// The vehicle's report through the share sheet: the user picks where it
  /// goes. AutoLoom Media is never connected automatically.
  func exportVehicle(traceID: UUID) async -> IntentOutcome {
    guard let session = DealerStore.shared.active else { return noVehicle }
    let text = VehicleReport.condition(session, turkish: L.isTurkish)
    return await prepareShare(text, traceID: traceID)
  }
}

// MARK: Report text (pure, testable)

enum VehicleReport {
  static func area(of zone: BodyZone) -> VehicleArea {
    switch zone.part {
    case .roof: return .roof
    case .seat, .dashboard, .interior: return .interior
    case .wheel, .tire: return .wheels
    case .engine: return .engineBay
    case .underbody: return .underbody
    default:
      switch zone.side {
      case .left: return .left
      case .right: return .right
      case .center: return zone.position == .rear ? .rear : .front
      }
    }
  }

  /// Areas nobody has looked at yet: not marked clean and without damage notes.
  static func uninspected(_ session: VehicleSession) -> [VehicleArea] {
    let checked = Set((session.inspected ?? []).compactMap(VehicleArea.init(rawValue:)))
    let damaged = Set(session.damage.compactMap { $0.zone.map(area(of:)) })
    return VehicleArea.allCases.filter { !checked.contains($0) && !damaged.contains($0) }
  }

  static func condition(_ session: VehicleSession, turkish: Bool, now: Date = Date()) -> String {
    func t(_ tr: String, _ en: String) -> String { turkish ? tr : en }
    var lines = [t("Kondisyon raporu — ", "Condition report — ") + session.title]
    lines.append(t("Tarih: ", "Date: ") + now.formatted(date: .abbreviated, time: .shortened))
    if let masked = session.maskedVIN {
      lines.append("VIN: \(masked)" + (session.vinVerified ? t(" (doğrulandı)", " (verified)") : t(" (doğrulanmadı)", " (not verified)")))
    }
    if let stock = session.stockNumber { lines.append(t("Stok: ", "Stock: ") + stock) }
    if let odometer = session.odometer { lines.append(t("Kilometre: ", "Odometer: ") + odometer.text) }
    if let color = session.color { lines.append(t("Renk: ", "Colour: ") + color) }
    lines.append("")
    lines.append(t("Hasarlar", "Damage") + " (\(session.damage.count)):")
    if session.damage.isEmpty { lines.append(t("- Kayıtlı hasar yok", "- None recorded")) }
    for finding in session.damage {
      let photos = finding.captureIDs.isEmpty ? "" : t(" [fotoğraf: \(finding.captureIDs.count)]", " [photos: \(finding.captureIDs.count)]")
      lines.append("- \(finding.title(turkish: turkish)) — \(finding.text)\(photos)")
    }
    for tire in session.tires ?? [] { lines.append(t("Lastik: ", "Tire: ") + tire.spoken(turkish: turkish, now: now)) }
    lines.append(t("Uyarı lambaları: ", "Warning lights: ") + (session.warningLights.isEmpty ? t("kayıtlı değil", "none recorded") : session.warningLights.joined(separator: ", ")))
    for note in session.interiorNotes { lines.append(t("İç mekân: ", "Interior: ") + note) }
    for note in session.mechanicalNotes { lines.append(t("Mekanik: ", "Mechanical: ") + note) }
    for option in session.options ?? [] { lines.append("\(option.name): \(option.value) (\(option.provenance.title))") }
    let checked = (session.inspected ?? []).compactMap(VehicleArea.init(rawValue:))
    if !checked.isEmpty { lines.append(t("Temiz işaretlenen bölgeler: ", "Areas marked clean: ") + checked.map { $0.title(turkish: turkish) }.joined(separator: ", ")) }
    let open = uninspected(session)
    if !open.isEmpty { lines.append(t("Kontrol edilmeyen bölgeler: ", "Areas not checked: ") + open.map { $0.title(turkish: turkish) }.joined(separator: ", ")) }
    let photos = session.photoChecklist.filter(\.done).count
    lines.append(t("Fotoğraflar: ", "Photos: ") + "\(photos)/\(session.photoChecklist.count)")
    if let recalls = session.recallCheck {
      lines.append(recalls.spoken(turkish: turkish, portal: TransportCanadaRecalls.portal(forMake: recalls.make)))
    }
    lines.append("")
    lines.append(t(
      "Bu rapor kaydedilen gözlemlerden oluşur; güvenlik muayenesi veya ekspertiz yerine geçmez.",
      "This report lists recorded observations only; it is not a safety inspection."))
    return lines.joined(separator: "\n")
  }

  static func serviceHandoff(_ session: VehicleSession, turkish: Bool, openTasks: [String], now: Date = Date()) -> String {
    func t(_ tr: String, _ en: String) -> String { turkish ? tr : en }
    var lines = [t("Servis devri — ", "Service handoff — ") + session.title]
    if let stock = session.stockNumber { lines.append(t("Stok: ", "Stock: ") + stock) }
    // The service needs the whole VIN; this note stays on the phone unless shared.
    if let vin = session.vin { lines.append("VIN: \(vin)" + (session.vinVerified ? "" : t(" (doğrulanmadı)", " (not verified)"))) }
    if let odometer = session.odometer { lines.append(t("Kilometre: ", "Odometer: ") + odometer.text) }
    if !session.warningLights.isEmpty { lines.append(t("Uyarı lambaları: ", "Warning lights: ") + session.warningLights.joined(separator: ", ")) }
    for note in session.mechanicalNotes { lines.append(t("Mekanik not: ", "Mechanical note: ") + note) }
    for finding in session.damage { lines.append(t("Hasar: ", "Damage: ") + finding.title(turkish: turkish)) }
    for tire in session.tires ?? [] {
      var line = t("Lastik: ", "Tire: ") + tire.spoken(turkish: turkish, now: now)
      if let age = tire.dot?.ageInYears(now: now), age >= 6 { line += t(" — 6 yaşından büyük", " — older than 6 years") }
      lines.append(line)
    }
    if let recalls = session.recallCheck {
      lines.append(recalls.spoken(turkish: turkish, portal: TransportCanadaRecalls.portal(forMake: recalls.make)))
    } else {
      lines.append(t("Geri çağırma kontrolü yapılmadı.", "No recall check done yet."))
    }
    for task in openTasks { lines.append(t("Açık görev: ", "Open task: ") + task) }
    lines.append(t("Teşhis içermez; yalnızca kaydedilen gözlemler.", "No diagnosis; recorded observations only."))
    return lines.joined(separator: "\n")
  }
}

/// AutoLoom Media (inventory and listings) connects through an adapter the
/// dealer sets up. None is built in, and nothing is ever sent automatically;
/// until one exists, a vehicle leaves the phone only through the share sheet.
protocol InventoryAdapter {
  var name: String { get }
  var isConfigured: Bool { get }
  /// Sends one vehicle after the user confirmed it; returns the remote id.
  func publish(_ vehicle: VehicleSession) async throws -> String
}

@MainActor
enum InventoryAdapters {
  static var registered: [any InventoryAdapter] = []
  static var configured: [any InventoryAdapter] { registered.filter(\.isConfigured) }
}
