import SwiftUI

/// Settings → Agent gateway (OpenClaw, optional).
struct AgentGatewaySettingsView: View {
  @AppStorage(AgentGatewayConfig.enabledKey) private var enabled = false
  @AppStorage(AgentGatewayConfig.urlKey) private var address = ""
  @AppStorage(AgentGatewayConfig.agentKey) private var agent = ""
  @State private var tokenDraft = ""
  @State private var hasToken = AgentTokenStore.hasToken
  @State private var testing = false
  @State private var testResult: String?

  private var parsedURL: URL? {
    URL(string: address.trimmingCharacters(in: .whitespaces))
  }

  private var addressProblem: String? {
    guard !address.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
    guard let url = parsedURL else { return "This is not a valid address." }
    return AgentGatewayPolicy.problem(with: url)
  }

  var body: some View {
    Form {
      Section(footer: Text("Optional. Connects the assistant to your own OpenClaw Gateway (its OpenAI-compatible /v1/chat/completions endpoint, enabled in the gateway config). Say \"ask my agent …\". Every request is shown for confirmation first; requests that sound destructive need a tap. OpenClaw's own approvals still apply on the gateway.")) {
        Toggle("Use my agent gateway", isOn: $enabled)
      }

      Section(
        header: Text("Gateway"),
        footer: Text("Example: https://my-mac.tailnet-name.ts.net or http://192.168.1.20:18789. Plain http is accepted only on a private network or tailnet.")) {
        TextField("Gateway address", text: $address)
          .keyboardType(.URL)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
        if let addressProblem {
          Text(addressProblem).font(.footnote).foregroundStyle(.orange)
        } else if let url = parsedURL, let warning = AgentGatewayPolicy.warning(for: url) {
          Text(warning).font(.footnote).foregroundStyle(.orange)
        }
        TextField("Agent (default: \(AgentGatewayConfig.defaultAgent))", text: $agent)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
      }

      Section(
        header: Text("Gateway token"),
        footer: Text("Stored only in this iPhone's Keychain and sent only to the gateway address above. OpenClaw treats this token as an owner credential.")) {
        SecureField(hasToken ? "Token saved — enter a new one to replace it" : "Paste the gateway token", text: $tokenDraft)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
        HStack {
          Button("Save token") {
            hasToken = AgentTokenStore.save(tokenDraft)
            tokenDraft = ""
          }
          .disabled(tokenDraft.trimmingCharacters(in: .whitespaces).isEmpty)
          Spacer()
          if hasToken {
            Button("Remove", role: .destructive) {
              AgentTokenStore.delete()
              hasToken = false
            }
          }
        }
      }

      Section {
        Button(testing ? "Testing…" : "Test connection") {
          testing = true
          testResult = nil
          Task {
            do {
              let agents = try await AgentGatewayClient().testConnection()
              testResult = "Connected. Agents: " + (agents.isEmpty ? "none listed" : agents.joined(separator: ", "))
            } catch {
              testResult = LogSanitizer.sanitize(error.localizedDescription, limit: 200)
            }
            testing = false
          }
        }
        .disabled(testing || !enabled || addressProblem != nil || address.isEmpty || !hasToken)
        if let testResult {
          Text(testResult).font(.footnote).foregroundStyle(.secondary)
        }
        LabeledContent("Status", value: AgentGatewayConfig.isReady ? "Ready" : "Not set up")
      }
    }
    .navigationTitle("Agent gateway")
  }
}
