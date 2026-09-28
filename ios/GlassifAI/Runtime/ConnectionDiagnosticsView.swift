import SwiftUI
import UIKit

/// Settings → Developer → Ray-Ban connection. Every sub-state of the
/// connection, the configuration the installed app really runs with, the
/// transition log, a sanitized report to copy, and the developer-only
/// recovery actions (never shown on normal screens).
struct ConnectionDiagnosticsView: View {
  @ObservedObject var connection: WearableConnectionCoordinator
  @State private var copied = false
  @State private var confirmReregister = false

  private let timeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss"
    return formatter
  }()

  var body: some View {
    let config = DATConfigurationAudit.current
    let snapshot = connection.snapshot
    List {
      Section("Status") {
        row("Phase", connection.phase.rawValue)
        row("Shown to the user", connection.status.title + (connection.status.detail.map { " — \($0)" } ?? ""))
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
        ForEach(config.problems, id: \.self) { problem in
          Label(problem, systemImage: "exclamationmark.triangle.fill")
            .font(.footnote)
            .foregroundStyle(.orange)
        }
      } header: {
        Text("Configuration (installed app)")
      } footer: {
        Text("Values are read from the installed bundle. MetaAppID, ClientToken and TeamID are never shown, only whether they are set. In Developer Mode Meta does not use them.")
      }

      Section("Registration") {
        row("State", snapshot.registration.rawValue)
        row("Not restored after launch", connection.registrationLost ? "yes" : "no")
        row("Request in progress", snapshot.registrationRequested ? "yes" : "no")
      }

      Section("Glasses") {
        row("Registered devices", "\(connection.devices.count)")
        row("Active device", snapshot.activeDevice ? "yes" : "no")
        row("Device (hash)", connection.deviceHash)
        row("Name", connection.deviceName ?? "—")
        row("Link state", snapshot.link.rawValue)
        row("Compatibility", connection.compatibility)
      }

      Section("Camera") {
        row("Ray-Ban camera chosen", snapshot.cameraWanted ? "yes" : "no")
        row("Camera permission", snapshot.permission.rawValue)
        row("Stream state", connection.streamStateLabel)
        row("Frames arriving", snapshot.hasFrames ? "yes" : "no")
        row("Active codec", connection.transportLabel)
        row("Start attempts since last stream", "\(connection.reconnectAttempts)")
        row("Last error", connection.lastError ?? "none")
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
