import SwiftUI
import UIKit

/// Vehicle screen sections for Dealer SuperMode: equipment with its source,
/// tires, Canadian recalls, the walk-around, reports, the lot spot and the
/// AutoLoom Media connection. Every button does exactly what it says.
struct VehicleSuperSections: View {
  let vehicleID: UUID
  @ObservedObject private var store = DealerStore.shared
  @State private var working: String?
  @State private var result: String?
  @Environment(\.openURL) private var openURL

  var body: some View {
    if let vehicle = store.vehicle(vehicleID) {
      equipment(vehicle)
      tires(vehicle)
      recalls(vehicle)
      walkAround(vehicle)
      lotSpot(vehicle)
      mediaConnection
    }
  }

  // MARK: Equipment

  private func equipment(_ vehicle: VehicleSession) -> some View {
    Section {
      let options = vehicle.options ?? []
      if options.isEmpty {
        Text(L.t("No equipment recorded yet.", "Henüz donanım kaydı yok.")).foregroundStyle(.secondary)
      }
      ForEach(options) { option in
        LabeledContent(option.name) {
          VStack(alignment: .trailing, spacing: 2) {
            Text(option.value)
            Text(option.provenance.title).font(.caption2).foregroundStyle(color(option.provenance))
          }
        }
      }
      if vehicle.vin != nil {
        runButton(L.t("Decode the VIN (NHTSA)", "VIN'i çöz (NHTSA)"), id: "decode", systemImage: "barcode.viewfinder") {
          await AssistantOrchestrator.shared.decodeVIN(traceID: UUID(), vehicleID: vehicleID).reply
        }
      }
      if let decode = vehicle.vinDecode, decode.quality != .clean {
        Text(decode.quality == .rescan
          ? L.t("The decoder reported a VIN error; read the VIN again.", "Çözücü VIN hatası bildirdi; VIN'i yeniden oku.")
          : L.t("Partly decoded; fill in the rest yourself.", "Kısmen çözüldü; eksikleri sen tamamla."))
          .font(.caption).foregroundStyle(.orange)
      }
    } header: {
      Text(L.t("Equipment", "Donanım"))
    } footer: {
      Text(L.t(
        "Only what a clean VIN decode, a clear look or you confirmed. A missing value means unknown, never “not equipped”.",
        "Yalnızca temiz bir VIN çözümü, net bir bakış veya senin onayladığın. Eksik değer “bilinmiyor” demektir, “yok” değil."))
    }
  }

  private func color(_ provenance: FactProvenance) -> Color {
    switch provenance {
    case .vinDecoded, .userConfirmed: .green
    case .visuallyConfirmed: AutoLoomTheme.electricBlue
    case .unverified: .orange
    }
  }

  // MARK: Tires

  private func tires(_ vehicle: VehicleSession) -> some View {
    Section {
      ForEach(vehicle.tires ?? []) { tire in
        VStack(alignment: .leading, spacing: 2) {
          Text(tire.position ?? L.t("Tire", "Lastik")).font(.subheadline)
          Text(tire.spoken(turkish: L.isTurkish)).font(.caption).foregroundStyle(.secondary)
        }
      }
      .onDelete { offsets in store.update(vehicleID) { $0.tires?.remove(atOffsets: offsets) } }
    } header: {
      Text(L.t("Tires", "Lastikler"))
    } footer: {
      Text(L.t(
        "Say “lastiği oku” (or “sağ ön lastiği oku”) while looking at the sidewall. Tread depth is never estimated from a photo.",
        "Yan yüzeye bakarken “lastiği oku” (ya da “sağ ön lastiği oku”) de. Diş derinliği fotoğraftan asla tahmin edilmez."))
    }
  }

  // MARK: Recalls

  private func recalls(_ vehicle: VehicleSession) -> some View {
    Section {
      if let check = vehicle.recallCheck {
        Text(check.spoken(turkish: L.isTurkish, portal: nil)).font(.caption)
        ForEach(check.safetyCampaigns.prefix(12)) { campaign in
          VStack(alignment: .leading, spacing: 2) {
            Text([campaign.number, campaign.system, campaign.date?.formatted(date: .abbreviated, time: .omitted)]
              .compactMap { $0 }.joined(separator: " · ")).font(.caption.weight(.semibold))
            if let summary = campaign.summary { Text(summary).font(.caption2).foregroundStyle(.secondary).lineLimit(4) }
          }
        }
      }
      let identified = vehicle.make != nil && vehicle.model != nil && vehicle.year != nil
      runButton(L.t("Check Transport Canada", "Transport Canada'da kontrol et"), id: "recalls", systemImage: "exclamationmark.shield") {
        let outcome = await AssistantOrchestrator.shared.checkRecallsOfficially(vehicleID, traceID: UUID())
        return outcome?.reply ?? L.t(
          "Transport Canada could not be reached, or the year, make and model are missing.",
          "Transport Canada'ya ulaşılamadı ya da yıl, marka ve model eksik.")
      }
      .disabled(!identified)
      if let make = vehicle.make, let portal = TransportCanadaRecalls.portal(forMake: make), let url = URL(string: portal) {
        Button {
          if let vin = vehicle.vin { UIPasteboard.general.string = vin }
          openURL(url)
        } label: {
          Label(L.t("Check this VIN with \(make)", "Bu VIN'i \(make) sayfasında kontrol et"), systemImage: "safari")
        }
      }
    } header: {
      Text(L.t("Recalls (Canada)", "Geri çağırmalar (Kanada)"))
    } footer: {
      Text(L.t(
        "Transport Canada searches by year, make and model, not by VIN; an empty result never means “no recalls”. The manufacturer's page checks the VIN itself (the VIN is copied for you to paste).",
        "Transport Canada VIN'e göre değil, yıl, marka ve modele göre arar; boş sonuç asla “geri çağırma yok” demek değildir. VIN'in kendisini üreticinin sayfası kontrol eder (VIN yapıştırman için kopyalanır)."))
    }
  }

  // MARK: Walk-around and reports

  private func walkAround(_ vehicle: VehicleSession) -> some View {
    let checked = Set(vehicle.inspected ?? [])
    let damaged = Set(vehicle.damage.compactMap { $0.zone.map(VehicleReport.area(of:)) })
    return Section {
      ForEach(VehicleArea.allCases, id: \.self) { area in
        Button {
          store.update(vehicleID) { session in
            var list = session.inspected ?? []
            if let index = list.firstIndex(of: area.rawValue) { list.remove(at: index) } else { list.append(area.rawValue) }
            session.inspected = list
          }
        } label: {
          HStack {
            Image(systemName: checked.contains(area.rawValue) ? "checkmark.circle.fill"
              : damaged.contains(area) ? "exclamationmark.triangle.fill" : "circle")
              .foregroundStyle(checked.contains(area.rawValue) ? Color.green : damaged.contains(area) ? Color.orange : Color.secondary)
            Text(area.title(turkish: L.isTurkish)).foregroundStyle(.primary)
          }
        }
      }
      runButton(L.t("Save the condition report", "Kondisyon raporunu kaydet"), id: "condition", systemImage: "doc.text") {
        AssistantOrchestrator.shared.conditionReport(traceID: UUID(), vehicleID: vehicleID).reply
      }
      runButton(L.t("Save a service handoff note", "Servis notunu kaydet"), id: "service", systemImage: "wrench.and.screwdriver") {
        AssistantOrchestrator.shared.serviceHandoff(traceID: UUID(), vehicleID: vehicleID).reply
      }
      ShareLink(item: VehicleReport.condition(vehicle, turkish: L.isTurkish)) {
        Label(L.t("Share the condition report", "Kondisyon raporunu paylaş"), systemImage: "square.and.arrow.up")
      }
      if let result {
        Text(result).font(.caption).foregroundStyle(.secondary)
      }
    } header: {
      Text(L.t("Walk-around", "Araç turu"))
    } footer: {
      Text(L.t(
        "Tap an area when it is checked and clean, or say “sol taraf temiz”. Reports list recorded observations only; they are not a safety inspection.",
        "Kontrol edilip temiz olan bölgeye dokun ya da “sol taraf temiz” de. Raporlar yalnızca kayıtlı gözlemleri listeler; güvenlik muayenesi değildir."))
    }
  }

  // MARK: Lot spot

  private func lotSpot(_ vehicle: VehicleSession) -> some View {
    Section {
      if let spot = vehicle.lotSpot, let latitude = spot.latitude, let longitude = spot.longitude {
        LabeledContent(L.t("Saved", "Kaydedildi"), value: spot.at.formatted(date: .abbreviated, time: .shortened))
        if let note = spot.note { Text(note).font(.caption).foregroundStyle(.secondary) }
        Button {
          var components = URLComponents(string: "https://maps.apple.com/")
          components?.queryItems = [
            URLQueryItem(name: "daddr", value: String(format: "%.6f,%.6f", latitude, longitude)),
            URLQueryItem(name: "dirflg", value: "w"),
          ]
          if let url = components?.url { openURL(url) }
        } label: {
          Label(L.t("Walk there (Maps)", "Oraya yürü (Haritalar)"), systemImage: "figure.walk")
        }
      }
      runButton(L.t("Save the spot where I stand", "Durduğum yeri kaydet"), id: "lot", systemImage: "mappin.and.ellipse") {
        await AssistantOrchestrator.shared.saveLotSpot(transcript: "", traceID: UUID(), vehicleID: vehicleID).reply
      }
    } header: {
      Text(L.t("Lot spot", "Otopark yeri"))
    } footer: {
      Text(L.t("One location fix when you tap or say “aracın yerini kaydet”; never tracked.",
               "Dokunduğunda ya da “aracın yerini kaydet” dediğinde tek bir konum alınır; sürekli izlenmez."))
    }
  }

  // MARK: AutoLoom Media

  private var mediaConnection: some View {
    Section {
      let configured = InventoryAdapters.configured
      LabeledContent(
        L.t("Connection", "Bağlantı"),
        value: configured.isEmpty ? L.t("Not connected", "Bağlı değil") : configured.map(\.name).joined(separator: ", "))
    } header: {
      Text("AutoLoom Media")
    } footer: {
      Text(L.t(
        "Nothing is sent to AutoLoom Media automatically. Until a connection is set up, share the report yourself.",
        "AutoLoom Media'ya hiçbir şey otomatik gönderilmez. Bağlantı kurulana kadar raporu kendin paylaş."))
    }
  }

  // MARK: Buttons

  private func runButton(
    _ title: String,
    id: String,
    systemImage: String,
    action: @escaping @MainActor () async -> String
  ) -> some View {
    Button {
      working = id
      Task { @MainActor in
        result = await action()
        working = nil
      }
    } label: {
      HStack {
        Label(title, systemImage: systemImage)
        if working == id {
          Spacer()
          ProgressView()
        }
      }
    }
    .disabled(working != nil)
  }
}
