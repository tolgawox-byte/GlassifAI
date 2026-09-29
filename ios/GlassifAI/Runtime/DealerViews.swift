import SwiftUI

/// Explore → Dealer: the active vehicle, today's dashboard and every
/// vehicle. Voice does the work ("VIN oku", "hasar ekle: …"); the screen
/// shows and corrects it.
struct DealerHomeView: View {
  @ObservedObject private var store = DealerStore.shared
  @ObservedObject private var orchestrator = AssistantOrchestrator.shared
  @State private var working: DealerCommand?

  var body: some View {
    List {
      Section {
        dashboard
      }
      if let active = store.active {
        Section(L.t("Active vehicle", "Aktif araç")) {
          NavigationLink { VehicleDetailView(vehicleID: active.id) } label: { VehicleCard(vehicle: active) }
          HStack(spacing: 10) {
            actionButton(L.t("Read VIN", "VIN oku"), "barcode.viewfinder", .readVIN)
            actionButton(L.t("Odometer", "Kilometre"), "gauge.with.dots.needle.33percent", .readOdometer)
          }
          HStack(spacing: 10) {
            actionButton(L.t("Next vehicle", "Sonraki araç"), "arrow.right.circle", .nextVehicle)
            actionButton(L.t("Done", "Tamam"), "checkmark.circle", .finishVehicle)
          }
        }
      } else {
        Section {
          Button {
            store.start()
          } label: {
            Label(L.t("Start a vehicle", "Araç başlat"), systemImage: "plus.circle.fill")
          }
        } footer: {
          Text(L.t(
            "Or say “yeni araç”. While a vehicle is active, notes, tasks, damage and Ray-Ban photos are linked to it.",
            "Veya “yeni araç” deyin. Bir araç aktifken notlar, görevler, hasarlar ve Ray-Ban fotoğrafları ona bağlanır."))
        }
      }
      let others = store.vehicles.filter { $0.id != store.active?.id }
      if !others.isEmpty {
        Section(L.t("Vehicles", "Araçlar")) {
          ForEach(others) { vehicle in
            NavigationLink { VehicleDetailView(vehicleID: vehicle.id) } label: { VehicleCard(vehicle: vehicle) }
          }
        }
      }
      Section {
        Text(L.t(
          "Say: “VIN oku”, “kilometre 45 bin 320”, “hasar ekle: sağ ön çamurluk çizik”, “jantın fotoğrafını çek”, “foto checklist”, “piyasa bak”, “ilan hazırla”, “bu araç tamam”.",
          "Deyin: “VIN oku”, “kilometre 45 bin 320”, “hasar ekle: sağ ön çamurluk çizik”, “jantın fotoğrafını çek”, “foto checklist”, “piyasa bak”, “ilan hazırla”, “bu araç tamam”."))
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
    }
    .navigationTitle(L.t("Dealer", "Bayi"))
  }

  private var dashboard: some View {
    let today = store.today()
    let open = store.openVehicles
    return HStack {
      stat("\(today.count)", L.t("Today", "Bugün"))
      stat("\(open.count)", L.t("Open", "Açık"))
      stat("\(store.vehicles.filter { $0.status == .ready }.count)", L.t("Ready", "Hazır"))
      stat("\(open.reduce(0) { $0 + $1.remainingPhotos.count })", L.t("Photos left", "Eksik foto"))
    }
  }

  private func stat(_ value: String, _ title: String) -> some View {
    VStack(spacing: 2) {
      Text(value).font(.title3.weight(.semibold)).monospacedDigit()
      Text(title).font(.caption2).foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity)
  }

  private func actionButton(_ title: String, _ icon: String, _ command: DealerCommand) -> some View {
    Button {
      working = command
      Task {
        let outcome = await orchestrator.runVoiceIntent(VoiceBridgeDecision(.dealer(command), "dealer button"), transcript: title)
        orchestrator.postNotice(outcome.said ?? outcome.reply)
        working = nil
      }
    } label: {
      HStack {
        if working == command { ProgressView() } else { Image(systemName: icon) }
        Text(title).lineLimit(1)
      }
      .frame(maxWidth: .infinity)
    }
    .buttonStyle(.bordered)
    .disabled(working != nil)
  }
}

/// One vehicle as a card: title, masked VIN, odometer, status, progress.
struct VehicleCard: View {
  let vehicle: VehicleSession

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Image(systemName: "car.fill").foregroundStyle(AutoLoomTheme.electricBlue)
        Text(vehicle.title).font(.subheadline.weight(.semibold)).lineLimit(1)
        Spacer()
        Text(vehicle.isOpen ? vehicle.status.title : L.t("Closed", "Kapalı"))
          .font(.caption2.weight(.semibold))
          .padding(.horizontal, 6)
          .padding(.vertical, 2)
          .background(.thinMaterial, in: Capsule())
      }
      HStack(spacing: 10) {
        if let masked = vehicle.maskedVIN {
          Label(masked, systemImage: vehicle.vinVerified ? "checkmark.seal" : "questionmark.diamond")
        }
        if let odometer = vehicle.odometer { Label(odometer.text, systemImage: "gauge.with.dots.needle.33percent") }
      }
      .font(.caption)
      .foregroundStyle(.secondary)
      HStack(spacing: 10) {
        Label("\(vehicle.damage.count)", systemImage: "exclamationmark.triangle")
        Label("\(vehicle.photoChecklist.count - vehicle.remainingPhotos.count)/\(vehicle.photoChecklist.count)", systemImage: "camera")
        Label("\(vehicle.noteIDs.count + vehicle.taskIDs.count)", systemImage: "note.text")
      }
      .font(.caption2)
      .foregroundStyle(.secondary)
    }
    .padding(.vertical, 2)
    .accessibilityElement(children: .combine)
  }
}

/// Everything about one vehicle: identification, readings, damage,
/// checklists, research, export and delete.
struct VehicleDetailView: View {
  let vehicleID: UUID
  @ObservedObject private var store = DealerStore.shared
  @State private var confirmDelete = false
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    if let vehicle = store.vehicle(vehicleID) {
      List {
        Section(L.t("Vehicle", "Araç")) {
          field(L.t("Year", "Yıl"), text: Binding(
            get: { vehicle.year.map(String.init) ?? "" },
            set: { value in store.update(vehicleID) { $0.year = Int(value) } }))
          field(L.t("Make", "Marka"), text: stringBinding(\.make))
          field(L.t("Model", "Model"), text: stringBinding(\.model))
          field(L.t("Trim", "Donanım"), text: stringBinding(\.trim))
          field(L.t("Colour", "Renk"), text: stringBinding(\.color))
          field(L.t("Stock number", "Stok no"), text: stringBinding(\.stockNumber))
          field(L.t("Lot location", "Park yeri"), text: stringBinding(\.location))
          if let masked = vehicle.maskedVIN {
            LabeledContent("VIN", value: masked + (vehicle.vinVerified ? " ✓" : L.t(" (not verified)", " (doğrulanmadı)")))
          }
          if let odometer = vehicle.odometer {
            LabeledContent(L.t("Odometer", "Kilometre"), value: odometer.text)
          }
          Picker(L.t("Status", "Durum"), selection: Binding(
            get: { vehicle.status }, set: { value in store.update(vehicleID) { $0.status = value } })) {
            ForEach(VehicleStatus.allCases, id: \.self) { Text($0.title).tag($0) }
          }
          if vehicle.identification == .visualGuess {
            Text(L.t("Make and model are a visual guess until the VIN confirms them.",
                     "Marka ve model VIN doğrulayana kadar görsel tahmindir."))
              .font(.caption).foregroundStyle(.orange)
          }
        }
        Section(L.t("Damage", "Hasar")) {
          if vehicle.damage.isEmpty { Text(L.t("None recorded", "Kayıt yok")).foregroundStyle(.secondary) }
          ForEach(vehicle.damage) { finding in
            VStack(alignment: .leading, spacing: 2) {
              Text(finding.title(turkish: L.isTurkish)).font(.subheadline)
              Text(finding.text).font(.caption).foregroundStyle(.secondary)
            }
          }
          .onDelete { offsets in store.update(vehicleID) { $0.damage.remove(atOffsets: offsets) } }
        }
        VehicleSuperSections(vehicleID: vehicleID)
        checklistSection(L.t("Photo checklist", "Fotoğraf listesi"), \.photoChecklist)
        checklistSection(L.t("Delivery checklist", "Teslim listesi"), \.deliveryChecklist)
        checklistSection(L.t("Test drive", "Test sürüşü"), \.testDriveChecklist)
        if !vehicle.research.isEmpty {
          Section(L.t("Research and drafts", "Araştırma ve taslaklar")) {
            ForEach(vehicle.research) { entry in
              VStack(alignment: .leading, spacing: 2) {
                Text(entry.kind.rawValue.capitalized + " · " + entry.at.formatted(date: .abbreviated, time: .shortened))
                  .font(.caption.weight(.semibold))
                Text(entry.summary).font(.caption).lineLimit(6)
              }
            }
          }
        }
        Section {
          LabeledContent(L.t("Linked notes / tasks / photos", "Bağlı not / görev / foto"),
                         value: "\(vehicle.noteIDs.count) / \(vehicle.taskIDs.count) / \(vehicle.captureIDs.count)")
          ShareLink(item: vehicle.factSheet(turkish: L.isTurkish)) {
            Label(L.t("Export summary", "Özeti paylaş"), systemImage: "square.and.arrow.up")
          }
          if vehicle.isOpen {
            Button(store.active?.id == vehicleID ? L.t("Active", "Aktif") : L.t("Make active", "Aktif yap")) {
              store.activate(vehicleID)
            }
            .disabled(store.active?.id == vehicleID)
          }
          Button(L.t("Delete vehicle", "Aracı sil"), role: .destructive) { confirmDelete = true }
        } footer: {
          Text(L.t("Stored on this iPhone only. The export shows the full VIN; the screen shows its last six characters.",
                   "Yalnızca bu iPhone'da saklanır. Paylaşılan özet VIN'in tamamını, ekran son altı hanesini gösterir."))
        }
      }
      .navigationTitle(vehicle.title)
      .confirmationDialog(L.t("Delete this vehicle?", "Bu araç silinsin mi?"), isPresented: $confirmDelete, titleVisibility: .visible) {
        Button(L.t("Delete", "Sil"), role: .destructive) {
          store.delete(vehicleID)
          dismiss()
        }
      } message: {
        Text(L.t("Its notes, tasks and photos stay.", "Notları, görevleri ve fotoğrafları kalır."))
      }
    } else {
      Text(L.t("This vehicle was deleted.", "Bu araç silindi.")).foregroundStyle(.secondary)
    }
  }

  private func field(_ title: String, text: Binding<String>) -> some View {
    HStack {
      Text(title).foregroundStyle(.secondary)
      TextField(title, text: text).multilineTextAlignment(.trailing)
    }
  }

  private func stringBinding(_ path: WritableKeyPath<VehicleSession, String?>) -> Binding<String> {
    Binding(
      get: { store.vehicle(vehicleID)?[keyPath: path] ?? "" },
      set: { value in
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        store.update(vehicleID) { $0[keyPath: path] = trimmed.isEmpty ? nil : trimmed }
      })
  }

  private func checklistSection(_ title: String, _ path: WritableKeyPath<VehicleSession, [ChecklistItem]>) -> some View {
    let items = store.vehicle(vehicleID)?[keyPath: path] ?? []
    return Section(title + " · \(items.filter(\.done).count)/\(items.count)") {
      ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
        Button {
          store.update(vehicleID) { session in
            session[keyPath: path][index].done.toggle()
            session[keyPath: path][index].doneAt = session[keyPath: path][index].done ? Date() : nil
          }
        } label: {
          HStack {
            Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
              .foregroundStyle(item.done ? Color.green : Color.secondary)
            Text(item.title).foregroundStyle(.primary)
          }
        }
      }
    }
  }
}
