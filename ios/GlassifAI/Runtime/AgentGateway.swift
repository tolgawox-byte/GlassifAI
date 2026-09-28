import Foundation
import Security

/// Optional connection to the user's own OpenClaw Gateway (its
/// OpenAI-compatible `POST /v1/chat/completions` endpoint). Off by default.
///
/// OpenClaw treats the gateway token as an owner credential and advises
/// keeping the gateway on loopback, a tailnet, or private ingress. This app
/// therefore requires a token, keeps it in the Keychain, sends it only to the
/// configured gateway, and refuses plain HTTP to public hosts.
enum AgentGatewayConfig {
  static let enabledKey = "autoloom.agent.enabled"
  static let urlKey = "autoloom.agent.url"
  static let agentKey = "autoloom.agent.id"
  static let defaultAgent = "openclaw/default"

  static var isEnabled: Bool {
    UserDefaults.standard.bool(forKey: enabledKey)
  }

  static var baseURL: URL? {
    let raw = UserDefaults.standard.string(forKey: urlKey)?.trimmingCharacters(in: .whitespaces) ?? ""
    guard !raw.isEmpty, let url = URL(string: raw), AgentGatewayPolicy.problem(with: url) == nil else { return nil }
    return url
  }

  static var agentID: String {
    let value = UserDefaults.standard.string(forKey: agentKey)?.trimmingCharacters(in: .whitespaces) ?? ""
    return value.isEmpty ? defaultAgent : value
  }

  /// Enabled, a valid URL, and a stored token.
  static var isReady: Bool {
    isEnabled && baseURL != nil && AgentTokenStore.hasToken
  }
}

enum AgentGatewayPolicy {
  /// Why the URL cannot be used, or nil when it is acceptable.
  static func problem(with url: URL) -> String? {
    guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
      return "Use an https:// or http:// address."
    }
    guard url.user == nil, url.password == nil else { return "Put the token in the token field, not in the address." }
    guard let host = url.host?.lowercased(), !host.isEmpty else { return "The address has no host." }
    if scheme == "http" && !isPrivateHost(host) {
      return "Plain http is only allowed on a private network or tailnet. Use https for other hosts."
    }
    return nil
  }

  /// Loopback, private and carrier-grade NAT (Tailscale) addresses, `.local`
  /// names and Tailscale MagicDNS names.
  static func isPrivateHost(_ host: String) -> Bool {
    let value = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    if value == "localhost" || value.hasSuffix(".local") || value.hasSuffix(".ts.net") { return true }
    let parts = value.split(separator: ".").compactMap { Int($0) }
    if parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) {
      return !URLSafety.isPublicIPv4(parts)
    }
    return value == "::1" || value.hasPrefix("fd") || value.hasPrefix("fc")
  }

  /// Public hosts work over https but go against OpenClaw's guidance.
  static func warning(for url: URL) -> String? {
    guard let host = url.host?.lowercased(), !isPrivateHost(host) else { return nil }
    return "OpenClaw recommends keeping the gateway on a private network or tailnet; a public address exposes an owner-level credential to the internet."
  }
}

/// The gateway token, stored only in this iPhone's Keychain.
enum AgentTokenStore {
  private static let service = "com.autoloom.agentgateway"
  private static let account = "token"

  static var hasToken: Bool { load() != nil }

  static func load() -> String? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
          let data = item as? Data, let token = String(data: data, encoding: .utf8), !token.isEmpty else { return nil }
    return token
  }

  @discardableResult
  static func save(_ token: String) -> Bool {
    delete()
    let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return false }
    let item: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecValueData as String: Data(trimmed.utf8),
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    ]
    return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
  }

  static func delete() {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    _ = SecItemDelete(query as CFDictionary)
  }
}

enum AgentGatewayError: LocalizedError, Equatable {
  case notConfigured
  case unauthorized
  case http(Int)
  case network(String)
  case emptyReply

  var errorDescription: String? {
    switch self {
    case .notConfigured:
      "No agent gateway is connected. It can be set up in Settings → Agent gateway (OpenClaw)."
    case .unauthorized:
      "The agent gateway rejected the token."
    case .http(let code):
      "The agent gateway answered with HTTP \(code)."
    case .network(let message):
      "The agent gateway could not be reached: \(message)"
    case .emptyReply:
      "The agent gateway returned no answer."
    }
  }
}

/// Minimal client for the gateway's chat completions endpoint.
struct AgentGatewayClient {
  private static let session: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 120
    configuration.timeoutIntervalForResource = 180
    configuration.httpCookieStorage = nil
    configuration.urlCache = nil
    return URLSession(configuration: configuration)
  }()

  static func requestBody(agent: String, prompt: String, sessionUser: String) -> [String: Any] {
    [
      "model": agent,
      "stream": false,
      "user": sessionUser,
      "messages": [
        [
          "role": "system",
          "content": "The request comes from the AutoLoom Media Glasses voice assistant on the owner's iPhone. Reply briefly in plain text suitable to be read aloud.",
        ],
        ["role": "user", "content": prompt],
      ],
    ]
  }

  /// Reads `choices[0].message.content` (a string or an array of text parts).
  static func replyText(from json: [String: Any]) -> String? {
    guard let choices = json["choices"] as? [[String: Any]],
          let message = choices.first?["message"] as? [String: Any] else { return nil }
    if let text = message["content"] as? String {
      return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    if let parts = message["content"] as? [[String: Any]] {
      let text = parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
      return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return nil
  }

  func send(prompt: String, sessionUser: String) async throws -> String {
    guard let base = AgentGatewayConfig.baseURL, let token = AgentTokenStore.load() else {
      throw AgentGatewayError.notConfigured
    }
    var request = URLRequest(url: base.appending(path: "v1/chat/completions"))
    request.httpMethod = "POST"
    request.timeoutInterval = 120
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.httpBody = try JSONSerialization.data(withJSONObject: Self.requestBody(
      agent: AgentGatewayConfig.agentID, prompt: prompt, sessionUser: sessionUser))
    let data = try await perform(request)
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let text = Self.replyText(from: json), !text.isEmpty else {
      throw AgentGatewayError.emptyReply
    }
    return String(text.prefix(6_000))
  }

  /// `GET /v1/models`: confirms the address and token, lists agent targets.
  func testConnection() async throws -> [String] {
    guard let base = AgentGatewayConfig.baseURL, let token = AgentTokenStore.load() else {
      throw AgentGatewayError.notConfigured
    }
    var request = URLRequest(url: base.appending(path: "v1/models"))
    request.timeoutInterval = 15
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    let data = try await perform(request)
    let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    return (json?["data"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
  }

  private func perform(_ request: URLRequest) async throws -> Data {
    let exchange: (Data, URLResponse)
    do {
      exchange = try await Self.session.data(for: request)
    } catch {
      throw AgentGatewayError.network(LogSanitizer.sanitize(error.localizedDescription, limit: 120))
    }
    let (data, response) = exchange
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    switch status {
    case 200..<300: return data
    case 401, 403: throw AgentGatewayError.unauthorized
    default: throw AgentGatewayError.http(status)
    }
  }
}
