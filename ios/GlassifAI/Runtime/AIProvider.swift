import Foundation
import Security

/// One model a provider offers, with what it can do. Listed by the
/// provider's own API wherever it has one (`discovered`); never invented.
struct ProviderModel: Codable, Equatable, Identifiable {
  let id: String
  let name: String
  let capabilities: ProviderCapabilities
  let contextWindow: Int?
  /// Listed by the provider's model API (false: its published list).
  let discovered: Bool
}

struct ProviderMessage: Equatable {
  enum Role: String { case user, assistant }

  var role: Role = .user
  var text: String
  /// JPEG images (camera frames), only for vision jobs.
  var images: [Data] = []
}

/// One request to a provider: the minimum context for one job.
struct ProviderRequest: Equatable {
  var role: AgentRole
  var system: String
  var messages: [ProviderMessage]
  /// nil: the registry picks one from the provider's models.
  var model: String?
  var maxOutputTokens = 1_200
  /// Use the provider's own web search (Gemini grounding, OpenRouter web).
  var wantsWeb = false
  var timeout: TimeInterval = 30
}

struct ProviderSource: Equatable, Codable {
  let url: URL
  let title: String?
  let published: String?
}

struct ProviderResponse: Equatable {
  var text: String
  var model: String
  var sources: [ProviderSource] = []
  var latencyMs = 0
}

struct ProviderTestResult: Equatable, Codable {
  let success: Bool
  let latencyMs: Int
  let model: String?
  let modelsFound: Int
  let message: String
  let at: Date
}

enum ProviderError: Error, Equatable, LocalizedError {
  case notConnected
  /// The key or token was refused: no retry, the user reconnects.
  case invalidCredentials
  /// The provider account needs credit.
  case billing
  case rateLimited(retryAfter: TimeInterval?)
  case server(Int)
  case network(String)
  case badRequest(String)
  case emptyResponse
  case unsupported(String)
  case timeout
  case cancelled

  var errorDescription: String? {
    switch self {
    case .notConnected: "not connected"
    case .invalidCredentials: "the key was refused"
    case .billing: "the provider account needs credit"
    case .rateLimited(let after): "rate limited" + (after.map { " (retry after \(Int($0)) s)" } ?? "")
    case .server(let code): "server error \(code)"
    case .network(let text): "network: \(text)"
    case .badRequest(let text): "rejected: \(text)"
    case .emptyResponse: "empty response"
    case .unsupported(let text): "unsupported: \(text)"
    case .timeout: "timed out"
    case .cancelled: "cancelled"
    }
  }

  /// One more try on the same provider is reasonable (a dropped
  /// connection). A timeout moves on to the next provider instead.
  var isRetryable: Bool {
    if case .network = self { return true }
    return false
  }

  /// The user must act (reconnect, add credit); never retried.
  var needsUser: Bool { self == .invalidCredentials || self == .billing }

  /// The provider is at fault for now: try the next one.
  var countsAgainstHealth: Bool {
    switch self {
    case .server, .network, .timeout, .emptyResponse, .rateLimited: true
    default: false
    }
  }
}

/// A provider adapter. Adapters only talk HTTP; routing, health, context
/// and the one assistant voice are the orchestrator's.
protocol AIProvider: Sendable {
  var id: ProviderID { get }
  func send(_ request: ProviderRequest, credential: String?) async throws -> ProviderResponse
  func listModels(credential: String?) async throws -> [ProviderModel]
  /// A tiny, low-cost request that proves the connection works.
  func testConnection(credential: String?) async throws -> ProviderTestResult
}

// MARK: HTTP

enum ProviderHTTP {
  static let session: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.waitsForConnectivity = false
    configuration.timeoutIntervalForRequest = 120
    configuration.timeoutIntervalForResource = 180
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.httpCookieStorage = nil
    configuration.urlCache = nil
    return URLSession(configuration: configuration)
  }()

  static func jsonRequest(url: URL, method: String = "POST", body: [String: Any]?, timeout: TimeInterval) throws -> URLRequest {
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.timeoutInterval = timeout
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if let body {
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONSerialization.data(withJSONObject: body)
    }
    return request
  }

  /// Sends and returns the JSON object; maps every failure to a
  /// `ProviderError` whose text never contains the credential.
  static func json(_ request: URLRequest, session: URLSession) async throws -> [String: Any] {
    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await session.data(for: request)
    } catch is CancellationError {
      throw ProviderError.cancelled
    } catch let error as URLError {
      switch error.code {
      case .cancelled: throw ProviderError.cancelled
      case .timedOut: throw ProviderError.timeout
      default: throw ProviderError.network(LogSanitizer.sanitize(error.localizedDescription, limit: 120))
      }
    } catch {
      throw ProviderError.network(LogSanitizer.sanitize(error.localizedDescription, limit: 120))
    }
    guard let http = response as? HTTPURLResponse else { throw ProviderError.network("no HTTP response") }
    guard (200..<300).contains(http.statusCode) else {
      throw error(status: http.statusCode, body: data, retryAfter: http.value(forHTTPHeaderField: "retry-after"))
    }
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw ProviderError.emptyResponse
    }
    return json
  }

  static func error(status: Int, body: Data, retryAfter: String?) -> ProviderError {
    let message = errorMessage(body)
    switch status {
    case 401, 403: return .invalidCredentials
    case 402: return .billing
    case 408: return .timeout
    case 429:
      // Some providers report exhausted credit as 429 with a quota message.
      if message.lowercased().contains("credit") || message.lowercased().contains("billing") { return .billing }
      return .rateLimited(retryAfter: retryAfter.flatMap { Double($0.trimmingCharacters(in: .whitespaces)) })
    case 400, 404, 409, 413, 422:
      if message.lowercased().contains("credit balance") { return .billing }
      return .badRequest(message.isEmpty ? "HTTP \(status)" : message)
    default: return .server(status)
    }
  }

  /// `error.message` in the Anthropic, Google and OpenAI-compatible shapes,
  /// sanitized and short.
  static func errorMessage(_ body: Data) -> String {
    guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return "" }
    let error = json["error"] as? [String: Any]
    let text = error?["message"] as? String ?? json["message"] as? String ?? json["detail"] as? String ?? ""
    return LogSanitizer.sanitize(text, limit: 160)
  }

  static func milliseconds(since start: Date) -> Int {
    Int((Date().timeIntervalSince(start) * 1_000).rounded())
  }
}

// MARK: Credentials

/// Provider API keys, in the iOS Keychain only: this device only, readable
/// after the first unlock (voice requests also run with the phone locked).
/// Never in UserDefaults, files, logs or diagnostics.
enum ProviderCredentialStore {
  static let defaultService = "com.autoloom.providers"

  static func load(_ provider: ProviderID, service: String = defaultService) -> String? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: provider.rawValue,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
          let data = item as? Data, let secret = String(data: data, encoding: .utf8), !secret.isEmpty else { return nil }
    return secret
  }

  static func has(_ provider: ProviderID, service: String = defaultService) -> Bool {
    load(provider, service: service) != nil
  }

  @discardableResult
  static func save(_ secret: String, for provider: ProviderID, service: String = defaultService) -> Bool {
    let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return false }
    delete(provider, service: service)
    let item: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: provider.rawValue,
      kSecValueData as String: Data(trimmed.utf8),
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    ]
    return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
  }

  static func delete(_ provider: ProviderID, service: String = defaultService) {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: provider.rawValue,
    ]
    _ = SecItemDelete(query as CFDictionary)
  }

  /// "••••4f2a" for the provider card; never more of the key.
  static func maskedHint(_ secret: String) -> String {
    "••••" + String(secret.suffix(4))
  }
}
