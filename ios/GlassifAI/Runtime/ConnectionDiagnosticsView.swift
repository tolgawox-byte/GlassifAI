import SwiftUI
import UIKit

/// Settings → Developer → Ray-Ban connection. Every layer of the connection
/// as measured now, every sub-state, the configuration the installed app
/// really runs with, the transition log, a sanitized report to copy, and the
/// developer-only recovery actions (never shown on normal screens).
struct ConnectionDiagnosticsView: View {
  @ObservedObject var connection: WearableConnectionCoordinator
  var voice: GlassifAIRealtimeSession?
  @State private var copied = false
  @State private var confirmReregister = false
  @State private var facts = ConnectionLayerFacts()
  /// Read once: the embedded profile does not change while the app runs.
  @State private var signing = ProvisioningSummary.read().summary()
  @AppStorage(GlassesAudioOrder.defaultsKey) private var microphoneFirst = true
  @AppStorage(GlassesCameraAudio.defaultsKey) private var cameraSafeAudio = true
  @State private var sdkLog: [String] = []

  private let timeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss"
    return formatter
  }()

  var body: some View {
    let config = DATConfigurationAudit.current
    let snapshot = connection.snapshot
    List {
      Section {
        ForEach(ConnectionLayerReport.layers(facts)) { layer in
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: layer.state.symbol)
              .foregroundStyle(layer.state.color)
              .frame(width: 18)
            Text(layer.title)
            Spacer(minLength: 12)
            Text(layer.value)
              .foregroundStyle(.secondary)
              .multilineTextAlignment(.trailing)
              .textSelection(.enabled)
          }
          .font(.subheadline)
        }
      } header: {
        Text(L.t("Layers (measured now)", "Katmanlar (şu an ölçülen)"))
      } footer: {
        Text(L.t(
          "Each layer can fail on its own: Bluetooth, the Meta toolkit, the Meta AI registration, the glasses link, the glasses session, the camera stream, the microphone and the AI session. Values are measured, never assumed.",
          "Her katman ayrı ayrı bozulabilir: Bluetooth, Meta araç seti, Meta AI kaydı, gözlük bağlantısı, gözlük oturumu, kamera akışı, mikrofon ve AI oturumu. Değerler ölçülür, varsayılmaz."))
      }

      Section("Status") {
        row("Phase", connection.phase.rawValue)
        row("Shown to the user", connection.status.title + (connection.status.detail.map { " — \($0)" } ?? ""))
        if connection.phase == .glassesUpdateRequired {
          Button(L.t("Open the update in Meta AI", "Güncellemeyi Meta AI'da aç")) { connection.openGlassesUpdate() }
        }
      }

      Section("SDK") {
        row("DAT version", GlassesSDKInfo.datVersion)
        row("SDK configured", snapshot.sdkConfigured ? "yes" : "no")
        if let error = connection.configureError {
          row("Configure error", error)
        }
      }

      Section {
        row("Bundle identifier", config.bundleIdentifier)
        row("AppLinkURLScheme", config.appLinkURLScheme ?? "missing")
        row("URL schemes", config.urlSchemes.joined(separator: ", "))
        row("MetaAppID", config.metaAppID)
        row("ClientToken", config.clientToken)
        row("TeamID", config.teamID)
        row("Analytics opt-out", config.analyticsOptOut ? "yes" : "no")
        row("Signing", signing)
        ForEach(config.problems + config.warnings, id: \.self) { problem in
          Label(problem, systemImage: "exclamationmark.triangle.fill")
            .font(.footnote)
            .foregroundStyle(.orange)
        }
      } header: {
        Text("Configuration (installed app)")
      } footer: {
        Text("Values are read from the installed bundle. MetaAppID, ClientToken and TeamID are never shown, only whether they are set. In Developer Mode Meta does not use them. The signing line comes from the embedded profile of a sideloaded IPA (dates and yes/no facts only).")
      }

      Section("Registration") {
        row("State", snapshot.registration.rawValue)
        row("Not restored after launch", connection.registrationLost ? "yes" : "no")
        row("Request in progress", snapshot.registrationRequested ? "yes" : "no")
      }

      Section("Glasses") {
        row("Bluetooth (iPhone)", snapshot.bluetooth.rawValue)
        row("Registered devices", "\(connection.devices.count)")
        row("Active device", snapshot.activeDevice ? "yes" : "no")
        row("Device (hash)", connection.deviceHash)
        row("Name", connection.deviceName ?? "—")
        row("Link state", snapshot.link.rawValue)
        row("Compatibility", connection.compatibility)
        row("Worn", connection.worn.map { $0 ? "yes" : "no" } ?? "—")
        row("Hinges open", connection.hingeOpen.map { $0 ? "yes" : "no" } ?? "—")
        row("Battery", connection.batteryLevel.map { "\($0)%" } ?? "—")
        row("Thermal", connection.thermal)
        row("Last linked", connection.lastLinkedAt.map { timeFormatter.string(from: $0) } ?? "never")
      }

      Section("Session and camera") {
        row("Device session", snapshot.session.rawValue)
        row("Session problem", snapshot.sessionProblem.map { ConnectionLayerReport.problemText($0) } ?? "none")
        row("Ray-Ban camera chosen", snapshot.cameraWanted ? "yes" : "no")
        row("Camera permission", snapshot.permission.rawValue)
        row("Stream state", connection.streamStateLabel)
        row("Frames arriving", snapshot.hasFrames ? "yes" : "no")
        row("Last ready", connection.lastReadyAt.map { timeFormatter.string(from: $0) } ?? "never")
        row("Active codec", connection.transportLabel)
        row("Start attempts since last stream", "\(connection.reconnectAttempts)")
        row("Last error", connection.lastError ?? "none")
      }

      Section {
        Toggle(L.t("iPhone microphone with the Ray-Ban camera", "Ray-Ban kamerasıyla iPhone mikrofonu"), isOn: $cameraSafeAudio)
          .onChange(of: cameraSafeAudio) { _, _ in Task { await WakePhraseListener.shared.audioRulesChanged() } }
        Toggle(L.t("Glasses microphone before the camera stream", "Kamera akışından önce gözlük mikrofonu"), isOn: $microphoneFirst)
          .disabled(cameraSafeAudio)
      } header: {
        Text(L.t("Audio and camera", "Ses ve kamera"))
      } footer: {
        Text(L.t(
          "Meta (SDK issues #206 and #332, 2026-10-13): on current glasses software the glasses end the camera session as soon as their microphone connects over Bluetooth hands-free, in every order, until a glasses update. With the first switch on (default), conversations with the Ray-Ban camera use the iPhone's microphone. The second switch only matters when the first is off: it applies Meta's documented order (the microphone set up before the stream).",
          "Meta (SDK kayıtları #206 ve #332, 13.10.2026): güncel gözlük yazılımında gözlük, mikrofonu Bluetooth eller serbest ile bağlanır bağlanmaz kamera oturumunu kapatıyor; sıra fark etmiyor, gözlük güncellemesine kadar. İlk anahtar açıkken (varsayılan) Ray-Ban kamerasıyla konuşmalar iPhone mikrofonunu kullanır. İkinci anahtar yalnızca ilki kapalıyken önemlidir: Meta'nın belgelediği sırayı uygular (mikrofon akıştan önce kurulur)."))
      }

      Section {
        if sdkLog.isEmpty {
          Text(L.t("No matching lines in the Meta SDK log yet.", "Meta SDK günlüğünde henüz eşleşen satır yok."))
            .foregroundStyle(.secondary)
        }
        ForEach(Array(sdkLog.enumerated()), id: \.offset) { _, line in
          Text(line)
            .font(.caption2.monospaced())
            .textSelection(.enabled)
        }
      } header: {
        Text(L.t("Meta SDK log", "Meta SDK günlüğü"))
      } footer: {
        Text(L.t(
          "The toolkit's own log names causes the API does not report (an app no longer registered, the glasses' DAT app, link switching). Only matching lines, sanitized, identifiers masked; also in the copied report.",
          "Araç setinin kendi günlüğü, API'nin bildirmediği nedenleri adlandırır (uygulama artık kayıtlı değil, gözlükteki DAT uygulaması, bağlantı geçişi). Yalnızca eşleşen satırlar; temizlenmiş, kimlikler maskeli; kopyalanan raporda da var."))
      }

      Section {
        Button {
          UIPasteboard.general.string = connection.diagnosticsReport()
          copied = true
        } label: {
          Label(copied ? "Copied" : "Copy sanitized connection report", systemImage: copied ? "checkmark" : "doc.on.doc")
        }
      } footer: {
        Text("States, counts and errors only: no identifiers, tokens, configuration values or image content.")
      }

      Section("Developer actions") {
        Button("Refresh device state") { connection.refresh() }
        Button("Restart stream") { connection.restartStream() }
        Button("Re-register with Meta AI", role: .destructive) { confirmReregister = true }
      }

      Section("Transitions") {
        if connection.transitions.isEmpty {
          Text("None yet").foregroundStyle(.secondary)
        }
        ForEach(connection.transitions.reversed()) { transition in
          VStack(alignment: .leading, spacing: 2) {
            Text(timeFormatter.string(from: transition.at))
              .font(.caption2.monospaced())
              .foregroundStyle(.secondary)
            Text(transition.text)
              .font(.caption)
          }
        }
      }
    }
    .navigationTitle("Ray-Ban connection")
    .task {
      // The layers are measured again every second while this page is open;
      // the SDK log every five.
      var tick = 0
      while !Task.isCancelled {
        facts = connection.layerFacts(voice: voice)
        if tick % 5 == 0 {
          sdkLog = await Task.detached(priority: .utility) { DATLogReader.recentLines(limit: 30) }.value
        }
        tick += 1
        try? await Task.sleep(nanoseconds: 1_000_000_000)
      }
    }
    .confirmationDialog("Register with Meta AI again?", isPresented: $confirmReregister, titleVisibility: .visible) {
      Button("Re-register", role: .destructive) { connection.reregister() }
    } message: {
      Text("Opens Meta AI to approve AutoLoom again. Not needed for a temporary disconnect.")
    }
  }

  private func row(_ title: String, _ value: String) -> some View {
    HStack(alignment: .firstTextBaseline) {
      Text(title)
      Spacer(minLength: 12)
      Text(value)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.trailing)
        .textSelection(.enabled)
    }
    .font(.subheadline)
  }
}
