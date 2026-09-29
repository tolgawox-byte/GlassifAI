import SwiftUI
import UIKit

/// "● 01:23": shown while a Ray-Ban recording runs, so nothing is ever
/// recorded without the screen saying so (the glasses' own capture light is
/// on while their camera streams).
struct RecordingChip: View {
  @ObservedObject var media: RayBanMediaCoordinator
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var pulse = false

  var body: some View {
    HStack(spacing: 6) {
      Circle()
        .fill(Color.red)
        .frame(width: 8, height: 8)
        .opacity(pulse ? 0.35 : 1)
      if let started = media.recordingStartedAt {
        TimelineView(.periodic(from: started, by: 1)) { context in
          Text(Self.clock(context.date.timeIntervalSince(started)))
            .monospacedDigit()
        }
      } else {
        Text(label)
      }
    }
    .font(.caption.weight(.semibold))
    .foregroundStyle(.white)
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .background(Color.red.opacity(0.28), in: Capsule())
    .overlay(Capsule().strokeBorder(Color.red.opacity(0.7)))
    .onAppear {
      guard !reduceMotion else { return }
      withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { pulse = true }
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(L.t("Recording video", "Video kaydediliyor"))
  }

  private var label: String {
    switch media.recordingState {
    case .preparing: L.t("Starting…", "Başlıyor…")
    case .stopping, .finalizing: L.t("Finishing…", "Bitiriliyor…")
    case .savingToPhotos: L.t("Saving…", "Kaydediliyor…")
    default: L.t("REC", "KAYIT")
    }
  }

  static func clock(_ seconds: TimeInterval) -> String {
    let total = max(0, Int(seconds))
    return String(format: "%02d:%02d", total / 60, total % 60)
  }
}

/// The shutter and record buttons, only while the Ray-Ban camera streams.
struct RayBanCaptureControls: View {
  @ObservedObject var media: RayBanMediaCoordinator
  @ObservedObject private var orchestrator = AssistantOrchestrator.shared

  var body: some View {
    VStack(spacing: 12) {
      Button {
        // The same executor, trace and feedback as saying "fotoğraf çek".
        Task { _ = await ActionCatalog.run("camera.photo") }
      } label: {
        Image(systemName: "camera.fill")
          .font(.system(size: 17, weight: .semibold))
          .frame(width: 48, height: 48)
          .foregroundStyle(.white)
          .background(.thinMaterial, in: Circle())
          .overlay(Circle().strokeBorder(.white.opacity(0.12)))
      }
      .buttonStyle(PressableButtonStyle())
      .disabled(media.isTakingPhoto)
      .accessibilityLabel(L.t("Take a Ray-Ban photo", "Ray-Ban ile fotoğraf çek"))

      Button {
        // The same executor as "video kaydını başlat" / "kaydı durdur".
        Task {
          let outcome = await ActionCatalog.run(media.isRecording ? "camera.recordStop" : "camera.recordStart")
          if outcome.failed != nil, outcome.feedback == nil { orchestrator.postNotice(outcome.said ?? outcome.reply) }
        }
      } label: {
        ZStack {
          Circle()
            .strokeBorder(.white.opacity(0.85), lineWidth: 3)
            .frame(width: 48, height: 48)
          if media.isRecording {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
              .fill(Color.red)
              .frame(width: 18, height: 18)
          } else {
            Circle()
              .fill(Color.red)
              .frame(width: 34, height: 34)
          }
        }
        .frame(width: 48, height: 48)
        .background(.thinMaterial, in: Circle())
      }
      .buttonStyle(PressableButtonStyle())
      .disabled(media.recordingState.isFinishing)
      .accessibilityLabel(media.isRecording
        ? L.t("Stop recording", "Kaydı durdur")
        : L.t("Record Ray-Ban video", "Ray-Ban ile video kaydet"))
    }
  }

}

/// Explore → Captures: Ray-Ban photos and videos, today, for the dealer
/// (vehicle or walkaround label) and personal. Metadata and thumbnails
/// only; the photos and videos themselves are in the Photos library, or in
/// AutoLoom when they were kept here.
struct CapturesView: View {
  @ObservedObject private var library = CaptureLibrary.shared
  @ObservedObject private var media = RayBanMediaCoordinator.shared
  @State private var filter: CaptureLibrary.Filter = .today
  @State private var pendingDelete: CaptureRecord?
  @State private var saving: UUID?
  @State private var message: String?

  var body: some View {
    List {
      Section {
        Picker(L.t("Show", "Göster"), selection: $filter) {
          ForEach(CaptureLibrary.Filter.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .listRowBackground(Color.clear)
      }
      let items = library.records(filter)
      if items.isEmpty {
        Section {
          Text(L.t(
            "No captures yet. Say “fotoğraf çek” or “video kaydını başlat” with the Ray-Ban camera on.",
            "Henüz çekim yok. Ray-Ban kamerası açıkken “fotoğraf çek” veya “video kaydını başlat” deyin."))
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
      } else {
        Section {
          ForEach(items) { record in
            row(record)
              .swipeActions {
                Button(role: .destructive) { pendingDelete = record } label: {
                  Label(L.t("Remove", "Kaldır"), systemImage: "trash")
                }
              }
          }
        } footer: {
          Text(L.t(
            "Removing a capture here deletes AutoLoom's copy and label only; a copy in Photos stays in Photos.",
            "Buradan kaldırmak yalnızca AutoLoom'daki kopyayı ve etiketi siler; Fotoğraflar'daki kopya kalır."))
        }
      }
      if let message {
        Section { Text(message).font(.footnote) }
      }
      Section {
        Button {
          PhotoLibrarySaver.openPhotosApp()
        } label: {
          Label(L.t("Open Photos", "Fotoğraflar'ı aç"), systemImage: "photo.on.rectangle")
        }
      } footer: {
        Text(L.t(
          "AutoLoom can only add to your library (add-only access), so it opens the Photos app rather than one photo. Nothing is uploaded.",
          "AutoLoom arşivinize yalnızca ekleme yapabilir (yalnızca ekleme izni); bu yüzden tek bir fotoğrafı değil Fotoğraflar uygulamasını açar. Hiçbir şey yüklenmez."))
      }
    }
    .navigationTitle(L.t("Captures", "Çekimler"))
    .confirmationDialog(
      L.t("Remove from AutoLoom?", "AutoLoom'dan kaldırılsın mı?"),
      isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
      titleVisibility: .visible
    ) {
      Button(L.t("Remove", "Kaldır"), role: .destructive) {
        if let record = pendingDelete { library.delete(record.id) }
        pendingDelete = nil
      }
    } message: {
      Text(pendingDelete?.storage == .appOnly
        ? L.t("This capture is only in AutoLoom; removing it deletes it.", "Bu çekim yalnızca AutoLoom'da; kaldırmak onu siler.")
        : L.t("The copy in Photos stays.", "Fotoğraflar'daki kopya kalır."))
    }
  }

  private func row(_ record: CaptureRecord) -> some View {
    HStack(spacing: 12) {
      thumbnail(record)
      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 6) {
          Image(systemName: record.kind == .photo ? "camera.fill" : "video.fill")
            .font(.caption)
            .foregroundStyle(.secondary)
          Text(title(record))
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)
        }
        Text(detail(record))
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
        if let caption = record.caption {
          Text(caption)
            .font(.caption)
            .lineLimit(2)
        }
        HStack(spacing: 8) {
          storageBadge(record)
          if record.storage == .appOnly, record.localFile != nil {
            Button {
              Task { await save(record) }
            } label: {
              Text(record.saveError == nil ? L.t("Save to Photos", "Galeriye kaydet") : L.t("Save again", "Tekrar kaydet"))
                .font(.caption.weight(.semibold))
            }
            .buttonStyle(.borderless)
            .disabled(saving == record.id)
            if let file = record.localFile {
              ShareLink(item: library.fileURL(named: file)) {
                Image(systemName: "square.and.arrow.up").font(.caption)
              }
              .buttonStyle(.borderless)
            }
          }
        }
      }
    }
    .padding(.vertical, 4)
    .accessibilityElement(children: .contain)
  }

  private func thumbnail(_ record: CaptureRecord) -> some View {
    ZStack {
      if let image = library.thumbnail(for: record.id) {
        Image(uiImage: image)
          .resizable()
          .scaledToFill()
      } else {
        Color.secondary.opacity(0.15)
        Image(systemName: record.kind == .photo ? "photo" : "video")
          .foregroundStyle(.secondary)
      }
      if record.kind == .video, let duration = record.durationSeconds {
        VStack {
          Spacer()
          HStack {
            Spacer()
            Text(RecordingChip.clock(duration))
              .font(.caption2.monospacedDigit().weight(.semibold))
              .padding(.horizontal, 4)
              .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 3))
              .foregroundStyle(.white)
          }
        }
        .padding(3)
      }
    }
    .frame(width: 64, height: 64)
    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
  }

  private func title(_ record: CaptureRecord) -> String {
    if let label = record.label { return label.title }
    return record.kind == .photo ? L.t("Photo", "Fotoğraf") : L.t("Video", "Video")
  }

  private func detail(_ record: CaptureRecord) -> String {
    var parts = [record.createdAt.formatted(date: .abbreviated, time: .shortened), record.source]
    if let width = record.width, let height = record.height { parts.append("\(width)×\(height)") }
    return parts.joined(separator: " · ")
  }

  @ViewBuilder
  private func storageBadge(_ record: CaptureRecord) -> some View {
    let inPhotos = record.storage == .photos
    Label(
      inPhotos ? L.t("In Photos", "Fotoğraflar'da") : L.t("In AutoLoom", "AutoLoom'da"),
      systemImage: inPhotos ? "checkmark.circle.fill" : "tray.full")
      .font(.caption2)
      .foregroundStyle(inPhotos ? Color.green : (record.saveError == nil ? Color.secondary : Color.orange))
  }

  private func save(_ record: CaptureRecord) async {
    saving = record.id
    defer { saving = nil }
    switch await media.saveToPhotos(record.id) {
    case .success:
      message = L.t("Saved to Photos.", "Galeriye kaydedildi.")
    case .failure(let error):
      switch error {
      case .permissionDenied:
        message = L.t("Photos access is off. Allow “Add Photos Only” for AutoLoom in iOS Settings.",
                      "Fotoğraflar izni kapalı. iOS Ayarlar'da AutoLoom için “Yalnızca Fotoğraf Ekle” izni verin.")
      case .needsPrompt, .failed:
        message = L.t("Could not save to Photos; the file stays in AutoLoom.", "Galeriye kaydedilemedi; dosya AutoLoom'da kalıyor.")
      }
    }
  }
}

/// The Explore tab: tools beyond the conversation. Only what works today
/// is listed.
struct ExploreTabView: View {
  @ObservedObject private var library = CaptureLibrary.shared
  @ObservedObject private var media = RayBanMediaCoordinator.shared
  @ObservedObject private var dealer = DealerStore.shared
  @ObservedObject private var shopping = ShoppingListStore.shared

  var body: some View {
    NavigationStack {
      List {
        Section {
          NavigationLink {
            DealerHomeView()
          } label: {
            HStack {
              Label(L.t("Dealer", "Bayi"), systemImage: "car.2")
              Spacer()
              Text(dealer.active?.title ?? L.t("No active vehicle", "Aktif araç yok"))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
          }
        } footer: {
          Text(L.t("Vehicle sessions: VIN, odometer, damage, photo and delivery checklists, market research, listings.",
                   "Araç oturumları: VIN, kilometre, hasar, fotoğraf ve teslim listeleri, piyasa araştırması, ilan."))
        }
        Section(L.t("Daily", "Günlük")) {
          NavigationLink {
            ShoppingListView()
          } label: {
            HStack {
              Label(L.t("Shopping list", "Alışveriş listesi"), systemImage: "cart")
              Spacer()
              Text("\(shopping.open.count)").font(.footnote).foregroundStyle(.secondary)
            }
          }
          ParkingRow()
        }
        TimersSection()
        Section {
          NavigationLink {
            CapturesView()
          } label: {
            HStack {
              Label(L.t("Captures", "Çekimler"), systemImage: "photo.stack")
              Spacer()
              Text("\(library.records(.today).count) " + L.t("today", "bugün"))
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
          }
          if media.isRecording {
            HStack {
              RecordingChip(media: media)
              Spacer()
            }
          }
        } header: {
          Text("Ray-Ban")
        } footer: {
          Text(L.t(
            "Say “fotoğraf çek”, “video kaydını başlat” and “kaydı durdur”. Photos and videos come from the Ray-Ban camera only.",
            "“Fotoğraf çek”, “video kaydını başlat” ve “kaydı durdur” deyin. Fotoğraf ve videolar yalnızca Ray-Ban kamerasından gelir."))
        }
      }
      .navigationTitle(L.t("Explore", "Keşfet"))
    }
  }
}
