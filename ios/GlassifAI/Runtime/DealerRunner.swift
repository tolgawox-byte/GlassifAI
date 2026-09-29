import Foundation

/// Runs Dealer Mode commands. Readings (VIN, odometer) come from the camera
/// through the high-detail vision path and are checked on the phone; the
/// VIN is never completed by guessing. Research and listings go through the
/// agent router (a research or reasoning specialist when connected) with
/// only the vehicle's known facts. Everything is stored on this iPhone.
extension AssistantOrchestrator {
  func runDealer(_ command: DealerCommand, transcript: String, traceID: UUID) async -> IntentOutcome {
    let store = DealerStore.shared
    let trace = ActionTraceLog.shared
    let turkish = L.isTurkish
    trace.update(traceID) { $0.executor = "DealerStore (Dealer Mode, on this iPhone)" }

    switch command {
    case .startVehicle:
      let session = store.start()
      trace.update(traceID) { $0.persistence = "vehicle session \(session.id.uuidString.prefix(8)) started" }
      return dealerOutcome(
        tr: "Yeni araç oturumunu başlattım. VIN için “VIN oku” diyebilirsin.",
        en: "New vehicle started. Say “read the VIN” when you're ready.",
        feedback: ActionFeedback(kind: .task, title: L.t("Vehicle started", "Araç başlatıldı")))

    case .nextVehicle:
      let finished = store.finishActive()
      store.start()
      let previous = finished.map { $0.title } ?? ""
      return dealerOutcome(
        tr: finished == nil ? "Yeni aracı başlattım." : "\(previous) kapandı; sıradaki aracı başlattım.",
        en: finished == nil ? "Next vehicle started." : "\(previous) is closed; next vehicle started.",
        feedback: ActionFeedback(kind: .task, title: L.t("Next vehicle", "Sıradaki araç")))

    case .finishVehicle:
      guard let finished = store.finishActive() else {
        return dealerOutcome(tr: "Açık bir araç yok.", en: "There's no open vehicle.")
      }
      let missing = finished.remainingPhotos.count
      let damage = finished.damage.count
      return dealerOutcome(
        tr: "\(finished.title) tamamlandı: \(damage) hasar kaydı" + (missing > 0 ? ", \(missing) fotoğraf eksik." : ", fotoğraflar tamam."),
        en: "\(finished.title) is done: \(damage) damage notes" + (missing > 0 ? ", \(missing) photos missing." : ", all photos taken."),
        feedback: ActionFeedback(kind: .taskDone, title: L.t("Vehicle closed", "Araç kapatıldı")))

    case .readVIN:
      let session = store.active ?? store.start()
      let result = await runBridgeTask(
        .vision,
        query: "Read the vehicle identification number (VIN) in view exactly, character by character. Reply with only the 17 characters; write ? for any character you cannot read with certainty. Never guess a character.",
        detail: .high)
      guard result.failed == nil, let text = result.display, !text.isEmpty else {
        return dealerOutcome(
          tr: "VIN'i okuyamadım; plakaya biraz daha yaklaşıp tekrar dene.",
          en: "I couldn't read the VIN; move a little closer to the plate and try again.", failed: result.failed ?? "no answer")
      }
      guard let raw = VINValidator.candidate(in: text) else {
        return dealerOutcome(
          tr: "Görüntüde 17 haneli bir VIN bulamadım.", en: "I couldn't find a 17-character VIN in view.", failed: "no VIN")
      }
      let check = VINValidator.check(raw)
      trace.update(traceID) { $0.parsed = "VIN …\(check.lastSix) · \(check.status)" }
      if check.isUsable {
        store.update(session.id) {
          $0.vin = check.normalized
          $0.vinVerified = check.status == .valid
          if $0.status == .intake { $0.status = .inspection }
        }
        trace.update(traceID) { $0.persistence = "VIN saved on the vehicle" + (check.status == .valid ? " (verified)" : " (check digit mismatch)") }
      }
      // A verified VIN is decoded right away (NHTSA vPIC, about 0.3 s).
      var decoded = ("", "")
      if check.status == .valid, let decode = try? await VPICClient.decode(check.normalized) {
        applyDecode(decode, to: session.id)
        if decode.quality == .clean, let name = store.vehicle(session.id)?.title {
          decoded = (" VIN'den çözüldü: \(name).", " Decoded from the VIN: \(name).")
        }
      }
      return dealerOutcome(
        tr: check.spoken(turkish: true) + decoded.0, en: check.spoken(turkish: false) + decoded.1,
        failed: check.isUsable ? nil : "VIN incomplete")

    case .readOdometer:
      let session = store.active ?? store.start()
      let result = await runBridgeTask(
        .vision,
        query: "Read the odometer (total distance, not the trip meter) on the instrument cluster. Reply with only the number and its unit, for example “45320 km”. If you cannot read it with certainty, reply “unclear”.",
        detail: .high)
      guard result.failed == nil, let text = result.display, !text.lowercased().contains("unclear"),
            let reading = OdometerReading.parse(text) else {
        return dealerOutcome(
          tr: "Kilometreyi net okuyamadım; göstergeye biraz daha yaklaş.",
          en: "I couldn't read the odometer clearly; move a little closer to the cluster.", failed: "odometer unclear")
      }
      return saveOdometer(reading.value, reading.unit, source: "camera", session: session.id, traceID: traceID)

    case .setOdometer(let value, let unit):
      let session = store.active ?? store.start()
      return saveOdometer(value, unit, source: "spoken", session: session.id, traceID: traceID)

    case .addDamage(let text):
      guard !text.isEmpty else {
        return dealerOutcome(
          tr: "Hasarı söyler misin? Örneğin: sağ ön çamurluk çizik.", en: "What's the damage? For example: right front fender scratch.")
      }
      let session = store.active ?? store.start()
      let finding = DamageFinding(
        zone: BodyZone.parse(text), kind: DamageFinding.kind(in: text), text: text, severity: DamageSeverity.parse(text),
        source: "spoken")
      store.update(session.id) { $0.damage.append(finding) }
      let findingID = finding.id
      let vehicleID = session.id
      LocalUndo.shared.record(kind: "damage", english: "damage note removed", turkish: "hasar kaydı silindi") {
        guard DealerStore.shared.vehicle(vehicleID)?.damage.contains(where: { $0.id == findingID }) == true else { return false }
        DealerStore.shared.update(vehicleID) { $0.damage.removeAll { $0.id == findingID } }
        return true
      }
      trace.update(traceID) { $0.persistence = "damage saved on the vehicle (\(finding.title(turkish: false)))" }
      return dealerOutcome(
        tr: "Hasarı ekledim: \(finding.title(turkish: true)).", en: "Damage added: \(finding.title(turkish: false)).",
        feedback: ActionFeedback(kind: .note, title: L.t("Damage added", "Hasar eklendi"), detail: finding.title(turkish: turkish)))

    case .photoChecklist:
      guard let session = store.active else {
        return dealerOutcome(tr: "Açık bir araç yok; “yeni araç” diyerek başlayabilirsin.", en: "No open vehicle; say “new vehicle” to start.")
      }
      let remaining = session.remainingPhotos
      guard !remaining.isEmpty else { return dealerOutcome(tr: "Fotoğraf listesi tamam.", en: "The photo checklist is complete.") }
      let names = remaining.prefix(5).map { $0.turkish }.joined(separator: ", ")
      let english = remaining.prefix(5).map { $0.english }.joined(separator: ", ")
      return dealerOutcome(
        tr: "\(remaining.count) fotoğraf kaldı: \(names)" + (remaining.count > 5 ? " ve diğerleri." : "."),
        en: "\(remaining.count) photos left: \(english)" + (remaining.count > 5 ? " and more." : "."))

    case .deliveryChecklist:
      guard let session = store.active else {
        return dealerOutcome(tr: "Açık bir araç yok.", en: "There's no open vehicle.")
      }
      let remaining = session.deliveryChecklist.filter { !$0.done }
      guard !remaining.isEmpty else { return dealerOutcome(tr: "Teslim listesi tamam.", en: "The delivery checklist is complete.") }
      return dealerOutcome(
        tr: "Teslim için kalanlar: " + remaining.map(\.turkish).joined(separator: ", ") + ".",
        en: "Left before delivery: " + remaining.map(\.english).joined(separator: ", ") + ".")

    case .marketResearch:
      // With a vehicle: its known facts; without one: what is in view.
      guard let session = store.active, session.make != nil || session.vin != nil else {
        let result = await runBridgeTask(.visionPlusWeb, query: transcript, detail: .high)
        return IntentOutcome(spoken: result.speakable, reply: result.display ?? result.speakable, failed: result.failed)
      }
      let query = "Current used-car market prices for this vehicle (comparable listings, price range, with sources and dates). "
        + "The dealer decides the price; give a suggestion only, labelled as such.\n\(session.factSheet(turkish: false))\nRequest: \(transcript)"
      let result = await runBridgeTask(.webSearch, query: query)
      if result.failed == nil, let display = result.display {
        store.update(session.id) { $0.research.append(ResearchEntry(kind: .market, summary: String(display.prefix(1_500)))) }
      }
      return IntentOutcome(spoken: result.speakable, reply: result.display ?? result.speakable, failed: result.failed)

    case .listing:
      guard let session = store.active else {
        return dealerOutcome(tr: "Açık bir araç yok; önce “yeni araç” de.", en: "No open vehicle; say “new vehicle” first.")
      }
      let query = "Write a short used-car listing in \(turkish ? "Turkish" : "English") using ONLY the facts below. "
        + "Do not add equipment, options, history or condition that is not listed; state every known damage honestly; "
        + "mark unverified identification as such. No price.\n\(session.factSheet(turkish: turkish))"
      let result = await runBridgeTask(.deepReasoning, query: query)
      guard result.failed == nil, let listing = result.display, !listing.isEmpty else {
        return IntentOutcome(spoken: result.speakable, reply: result.display ?? result.speakable, failed: result.failed ?? "no listing")
      }
      if let note = MemoryStore.shared.addNote(
        title: L.t("Listing: ", "İlan: ") + session.title, content: listing, source: "dealer") {
        store.update(session.id) {
          $0.noteIDs.append(note.id)
          $0.research.append(ResearchEntry(kind: .listing, summary: String(listing.prefix(1_500))))
          if [.intake, .inspection, .photos].contains($0.status) { $0.status = .listing }
        }
      }
      return dealerOutcome(
        tr: "İlan taslağını hazırladım ve notlara kaydettim.", en: "I drafted the listing and saved it to your notes.",
        feedback: .noteSaved(preview: listing))

    case .summary:
      guard let session = store.active else { return dealerOutcome(tr: "Açık bir araç yok.", en: "There's no open vehicle.") }
      let facts = session.factSheet(turkish: turkish)
      return IntentOutcome(
        spoken: "The active vehicle in Dealer Mode (known facts only):\n\(facts)\nMissing photos: \(session.remainingPhotos.count). Summarise in two short sentences.",
        reply: facts)

    case .saveVehicle:
      guard let session = store.active else {
        return dealerOutcome(tr: "Açık bir araç yok; önce “yeni araç” de.", en: "No open vehicle; say “new vehicle” first.")
      }
      trace.update(traceID) { $0.persistence = "vehicle stored on this iPhone (saved automatically)" }
      return dealerOutcome(
        tr: "\(session.title) kayıtlı.", en: "\(session.title) is saved.",
        feedback: ActionFeedback(kind: .task, title: L.t("Vehicle saved", "Araç kayıtlı"), detail: session.title))

    case .decodeVIN:
      return await decodeVIN(traceID: traceID)
    case .readTire(let position):
      return await readTire(position, traceID: traceID)
    case .readDashboard:
      return await readDashboard(traceID: traceID)
    case .conditionReport:
      return conditionReport(traceID: traceID)
    case .serviceHandoff:
      return serviceHandoff(traceID: traceID)
    case .saveLotSpot:
      return await saveLotSpot(transcript: transcript, traceID: traceID)
    case .findLotSpot:
      return await findLotSpot(traceID: traceID)
    case .readPartNumber:
      return await readPartNumber(traceID: traceID)
    case .areaClear(let area):
      return markAreaClear(area, traceID: traceID)
    case .exportVehicle:
      return await exportVehicle(traceID: traceID)

    case .recallCheck:
      if let session = store.active, let outcome = await checkRecallsOfficially(session.id, traceID: traceID) {
        return outcome
      }
      guard let session = store.active, session.make != nil || session.vin != nil else {
        return dealerOutcome(
          tr: "Önce aracı tanımlayalım: “VIN oku” de ya da marka ve modeli söyle.",
          en: "First identify the vehicle: say “read the VIN” or tell me the make and model.", failed: "vehicle unknown")
      }
      let query = """
        Check vehicle safety recalls that apply in CANADA for this vehicle. Use Transport Canada's Motor Vehicle Safety \
        Recalls Database first, then the manufacturer's Canadian recall lookup, then NHTSA for comparison. For each recall give \
        the recall number, date, affected system, the source, and whether it applies to this VIN or only to the \
        year/make/model. If only a year/make/model search was possible, say clearly that a VIN-specific check with the \
        manufacturer or a dealer system is still needed. Never say there are no recalls: say what was searched and what was \
        found, with the date of the search.
        \(session.factSheet(turkish: false))
        """
      let result = await runBridgeTask(.webSearch, query: query)
      if result.failed == nil, let display = result.display {
        store.update(session.id) { $0.research.append(ResearchEntry(kind: .recall, summary: String(display.prefix(1_500)))) }
        trace.update(traceID) { $0.persistence = "recall research saved on the vehicle" }
      }
      return IntentOutcome(
        spoken: result.speakable
          + "\nIf the search was by year, make and model only, say that a VIN-specific check is still needed. Never say there are no recalls.",
        reply: result.display ?? result.speakable, failed: result.failed)

    case .briefing:
      let today = store.today()
      let tasks = MemoryStore.shared.tasks
      let turkishLines = DealerBriefing.lines(vehicles: store.vehicles, tasks: tasks, turkish: true)
      let englishLines = DealerBriefing.lines(vehicles: store.vehicles, tasks: tasks, turkish: false)
      trace.update(traceID) { $0.parsed = "\(today.count) vehicles today, \(store.openVehicles.count) open" }
      return IntentOutcome(
        spoken: "The dealer's picture for today, from this iPhone's records only (in the conversation's language):\n"
          + L.t(englishLines.joined(separator: "\n"), turkishLines.joined(separator: "\n"))
          + "\nSay it in two or three short sentences, most urgent first. Do not read VINs aloud.",
        reply: L.t(englishLines.joined(separator: "\n"), turkishLines.joined(separator: "\n")))
    }
  }

  private func saveOdometer(
    _ value: Int,
    _ unit: OdometerReading.Unit,
    source: String,
    session: UUID,
    traceID: UUID
  ) -> IntentOutcome {
    let reading = OdometerReading(value: value, unit: unit, at: Date(), source: source)
    let previous = DealerStore.shared.vehicle(session)?.odometer
    DealerStore.shared.update(session) { $0.odometer = reading }
    LocalUndo.shared.record(kind: "odometer", english: "odometer reading removed", turkish: "kilometre kaydı geri alındı") {
      guard DealerStore.shared.vehicle(session)?.odometer == reading else { return false }
      DealerStore.shared.update(session) { $0.odometer = previous }
      return true
    }
    ActionTraceLog.shared.update(traceID) { $0.persistence = "odometer saved on the vehicle (\(source))" }
    return dealerOutcome(
      tr: "Kilometre \(reading.text) olarak kaydedildi.", en: "Odometer saved: \(reading.text).",
      feedback: ActionFeedback(kind: .note, title: L.t("Odometer saved", "Kilometre kaydedildi"), detail: reading.text))
  }

  func dealerOutcome(tr: String, en: String, failed: String? = nil, feedback: ActionFeedback? = nil) -> IntentOutcome {
    IntentOutcome(
      spoken: BridgeSpeech.done("Result of the user's Dealer Mode command.", tr: tr, en: en),
      reply: L.t(en, tr), failed: failed, feedback: feedback, said: L.t(en, tr))
  }
}
