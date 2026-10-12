import SwiftUI
import UIKit

/// Settings → Computer (PC): pairing, the PC's real connection state, tasks
/// waiting for approval, running and recent tasks, and what the PC shares.
struct PCCompanionView: View {
  @ObservedObject private var store = PCCompanionStore.shared
  @State private var pasted = ""
  @State private var message: String?
  @State private var confirmUnpair = false

  var body: some View {
    List {
      if let offer = store.offer { offerSection(offer) }
      if let link = store.link {
        connectionSection(link)
        approvalsSection
        tasksSection
        sharedSection
        Section {
          Button(role: .destructive) {
            confirmUnpair = true
          } label: {
            Label(L.t("Unpair this PC", "Bu bilgisayarla eşleşmeyi kaldır"), systemImage: "link.badge.minus")
          }
        }
      } else if store.offer == nil {
        setupSection
      }
      if let message {
        Section { Text(message).font(.footnote).foregroundStyle(.secondary) }
      }
      if let error = store.lastError {
        Section {
          Label(error, systemImage: "exclamationmark.triangle")
            .font(.footnote)
            .foregroundStyle(.orange)
        }
      }
    }
    .navigationTitle(L.t("Computer (PC)", "Bilgisayar (PC)"))
    .onAppear { store.startPolling() }
    .onDisappear { store.stopPolling() }
    .refreshable { await store.refresh() }
    .confirmationDialog(
      L.t("Unpair this PC?", "Bu bilgisayarla eşleşme kaldırılsın mı?"),
      isPresented: $confirmUnpair,
      titleVisibility: .visible
    ) {
      Button(L.t("Unpair", "Eşleşmeyi kaldır"), role: .destructive) {
        Task {
          await store.unpair()
          message = L.t("The PC was unpaired on this phone.", "Bilgisayarla eşleşme bu telefonda kaldırıldı.")
        }
      }
    } message: {
      Text(L.t(
        "The phone forgets the PC and its key. The PC also revokes this phone when it can be reached.",
        "Telefon bilgisayarı ve anahtarını unutur. Bilgisayara ulaşılabiliyorsa o da bu telefonu kaldırır."))
    }
  }

  // MARK: Pairing

  private var setupSection: some View {
    Section {
      Text(L.t(
        "1. On the PC, in the pc-companion folder: node src/cli.ts start --lan --pair\n2. Scan the QR code with the iPhone Camera and open it in this app.\nOr copy the jarvis-pc:// link here.",
        "1. Bilgisayarda, pc-companion klasöründe: node src/cli.ts start --lan --pair\n2. QR kodunu iPhone Kamera ile okut ve bu uygulamada aç.\nYa da jarvis-pc:// bağlantısını buraya yapıştır."))
        .font(.footnote)
      TextField("jarvis-pc://pair?…", text: $pasted)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .keyboardType(.URL)
      Button(L.t("Use this link", "Bu bağlantıyı kullan")) {
        if let url = URL(string: pasted.trimmingCharacters(in: .whitespacesAndNewlines)), store.receive(url) {
          pasted = ""
        }
      }
      .disabled(pasted.isEmpty)
    } header: {
      Text(L.t("Pair a Windows PC", "Windows bilgisayar eşleştir"))
    } footer: {
      Text(L.t(
        "The PC shares only the folders, programs and commands you add on the PC. Reading runs at once; changing files, opening programs and running commands always wait for your approval. The connection is encrypted and accepts only that PC's key.",
        "Bilgisayar yalnızca orada eklediğin klasörleri, programları ve komutları paylaşır. Okuma hemen çalışır; dosya değiştirmek, program açmak ve komut çalıştırmak her zaman onayını bekler. Bağlantı şifrelidir ve yalnızca o bilgisayarın anahtarını kabul eder."))
    }
  }

  private func offerSection(_ offer: PCPairingOffer) -> some View {
    Section {
      LabeledContent(L.t("PC", "Bilgisayar"), value: offer.name)
      LabeledContent(L.t("Address", "Adres"), value: "\(offer.host):\(offer.port)")
      LabeledContent(L.t("Key", "Anahtar"), value: String(offer.pin.prefix(12)) + "…")
      Button {
        Task {
          let problem = await store.pair(offer, deviceName: UIDevice.current.name)
          message = problem ?? L.t("Paired. Say “Bilgisayarda …” to use it.", "Eşleşti. Kullanmak için “Bilgisayarda …” de.")
        }
      } label: {
        HStack {
          Label(L.t("Pair with this PC", "Bu bilgisayarla eşleş"), systemImage: "link")
          if store.busy {
            Spacer()
            ProgressView()
          }
        }
      }
      .disabled(store.busy)
      Button(L.t("Cancel", "Vazgeç"), role: .cancel) { store.offer = nil }
    } header: {
      Text(L.t("Pairing request", "Eşleştirme isteği"))
    } footer: {
      Text(L.t(
        "Only pair with your own PC. Check that the key shown on the PC starts the same way. If the PC asks, type “evet” in its window.",
        "Yalnızca kendi bilgisayarınla eşleş. Bilgisayardaki anahtarın aynı başladığını kontrol et. Bilgisayar sorarsa penceresine “evet” yaz."))
    }
  }

  // MARK: Connection

  private func connectionSection(_ link: PCLinkRecord) -> some View {
    Section {
      HStack(spacing: 8) {
        Circle()
          .fill(store.isReachable ? Color.green : Color.orange)
          .frame(width: 10, height: 10)
          .accessibilityHidden(true)
        Text(store.isReachable ? L.t("Connected", "Bağlı") : L.t("Not reachable right now", "Şu an ulaşılamıyor"))
        Spacer()
        if let contact = store.lastContact {
          Text(contact, style: .relative)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      LabeledContent(L.t("PC", "Bilgisayar"), value: store.status?.name ?? link.name)
      LabeledContent(L.t("Address", "Adres"), value: "\(link.host):\(link.port)")
      if let status = store.status {
        LabeledContent("JARVIS PC Companion", value: status.version)
      }
    } header: {
      Text(L.t("Connection", "Bağlantı"))
    } footer: {
      Text(L.t(
        "“Connected” means the PC answered in the last 30 seconds. The PC must run the companion with --lan on the same network (or Tailscale).",
        "“Bağlı”, bilgisayarın son 30 saniyede yanıt verdiği anlamına gelir. Bilgisayarda companion --lan ile aynı ağda (veya Tailscale'de) çalışmalı."))
    }
  }

  // MARK: Approvals and tasks

  @ViewBuilder
  private var approvalsSection: some View {
    if !store.pendingApprovals.isEmpty {
      Section {
        ForEach(store.pendingApprovals) { task in
          VStack(alignment: .leading, spacing: 6) {
            Text(task.summary)
              .font(.body.weight(.medium))
              .fixedSize(horizontal: false, vertical: true)
            Text(Self.riskTitle(task.risk))
              .font(.caption2)
              .foregroundStyle(.secondary)
            ForEach(task.warnings, id: \.self) { warning in
              Label(warning, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
            }
            HStack(spacing: 10) {
              Button(L.t("Approve", "Onayla")) { Task { await store.approve(task) } }
                .buttonStyle(.borderedProminent)
              Button(L.t("Deny", "Reddet"), role: .destructive) { Task { await store.deny(task) } }
                .buttonStyle(.bordered)
            }
            .disabled(store.busy)
          }
          .padding(.vertical, 4)
        }
      } header: {
        Text(L.t("Waiting for your approval", "Onayını bekleyenler"))
      } footer: {
        Text(L.t(
          "The PC runs a task only after you approve exactly what is shown here.",
          "Bilgisayar bir görevi yalnızca burada gösterileni onayladıktan sonra çalıştırır."))
      }
    }
  }

  private var tasksSection: some View {
    Section {
      let shown = store.tasks.filter { !$0.awaitingApproval }.prefix(15)
      if shown.isEmpty {
        Text(L.t("No tasks yet.", "Henüz görev yok.")).foregroundStyle(.secondary)
      }
      ForEach(Array(shown)) { task in
        VStack(alignment: .leading, spacing: 4) {
          HStack {
            Text(task.summary)
              .font(.subheadline)
              .lineLimit(2)
            Spacer()
            Text(task.stateTitle)
              .font(.caption2.weight(.semibold))
              .foregroundStyle(Self.stateColor(task))
          }
          if task.state == "running", let progress = task.progress {
            Text(progress.message)
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(2)
          }
          if let result = task.resultText, task.state == "completed" {
            Text(result)
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(4)
          }
          if let error = task.error, task.state != "completed" {
            Text(error.message)
              .font(.caption)
              .foregroundStyle(.orange)
              .lineLimit(3)
          }
          if let check = task.verification, task.state == "completed" {
            Label(check.details, systemImage: check.ok ? "checkmark.seal" : "xmark.seal")
              .font(.caption2)
              .foregroundStyle(check.ok ? Color.green : Color.orange)
              .lineLimit(2)
          }
          if task.isActive || task.undoAvailable {
            HStack(spacing: 10) {
              if task.isActive {
                Button(L.t("Stop", "Durdur")) { Task { await store.cancel(task) } }
                  .buttonStyle(.bordered)
              }
              if task.undoAvailable {
                Button(L.t("Undo", "Geri al")) { Task { await store.undo(task) } }
                  .buttonStyle(.bordered)
              }
            }
            .controlSize(.small)
            .disabled(store.busy)
          }
        }
        .padding(.vertical, 2)
      }
    } header: {
      Text(L.t("Tasks", "Görevler"))
    }
  }

  @ViewBuilder
  private var sharedSection: some View {
    if let status = store.status {
      Section {
        if status.roots.isEmpty {
          Text(L.t("No folders shared yet. On the PC: jarvis-pc roots add <folder> --name <name>",
                   "Henüz paylaşılan klasör yok. Bilgisayarda: jarvis-pc roots add <klasör> --name <ad>"))
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        ForEach(status.roots) { root in
          LabeledContent(root.name, value: root.access == "write" ? L.t("Read and write", "Okuma ve yazma") : L.t("Read only", "Salt okunur"))
        }
        if !status.apps.isEmpty {
          LabeledContent(L.t("Programs", "Programlar"), value: status.apps.map(\.label).joined(separator: ", "))
        }
        if !status.commands.isEmpty {
          LabeledContent(L.t("Commands", "Komutlar"), value: status.commands.map(\.label).joined(separator: ", "))
        }
      } header: {
        Text(L.t("Shared by the PC", "Bilgisayarın paylaştıkları"))
      }
    }
  }

  static func riskTitle(_ risk: String) -> String {
    switch risk {
    case "write": L.t("Changes files", "Dosya değiştirir")
    case "destructive": L.t("Overwrites or removes (kept in the PC's trash)", "Üzerine yazar veya kaldırır (bilgisayarın çöpünde saklanır)")
    case "execute": L.t("Starts a program or runs a command", "Program açar veya komut çalıştırır")
    default: L.t("Reads only", "Yalnızca okur")
    }
  }

  static func stateColor(_ task: PCTask) -> Color {
    switch task.state {
    case "completed": task.unsuccessful == true ? .orange : .green
    case "failed": .red
    case "cancelled": .secondary
    default: .blue
    }
  }
}
