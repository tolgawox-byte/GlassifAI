import Foundation
import Observation

struct ChatGPTUser: Codable, Equatable {
  let accountId: String
  let email: String?
  let name: String?
  let plan: String?
}

struct ChatGPTPendingLogin: Codable, Equatable {
  let deviceAuthId: String
  let userCode: String
  let verificationUrl: URL
  let interval: Double
  let expiresAt: Double
}

enum ChatGPTAuthStatus: Equatable {
  case loading
  case unauthenticated
  case connecting
  case pending(ChatGPTPendingLogin)
  case authenticated(ChatGPTUser)
  case error(String)
}

enum ChatGPTAPI {
  static let clientId = "app_EMoamEEZ73f0CkXaXp7hrann"
  static let scope = "openid profile email offline_access"
  static let originator = "codex_cli_rs"
  static let clientVersion = "0.149.0"
  static let issuer = URL(string: "https://auth.openai.com")!
  static let codexBase = URL(string: "https://chatgpt.com/backend-api/codex")!
  static let deviceVerification = URL(string: "https://auth.openai.com/codex/device")!
  static let deviceRedirect = "https://auth.openai.com/deviceauth/callback"

  static func codexHeaders(tokens: ChatGPTAuthTokens) throws -> [String: String] {
    guard let accountId = tokens.accountId, !accountId.isEmpty else {
      throw ChatGPTAuthError.missingAccount
    }
    return [
      "Authorization": "Bearer \(tokens.accessToken)",
      "chatgpt-account-id": accountId,
      "OpenAI-Beta": "responses=experimental",
      "originator": originator,
    ]
  }
}

@MainActor
@Observable
final class ChatGPTAuthSession {
  static let shared = ChatGPTAuthSession()

  private(set) var status: ChatGPTAuthStatus = .loading
  /// Model slugs in Codex priority order (first = the service's default).
  private(set) var availableModels: [String] = []
  /// Full model metadata returned by `/models` for this account.
  private(set) var modelCatalog: [CatalogModel] = []
  private(set) var modelsFetchedAt: Date?
  private(set) var modelsError: String?
  private var pollingTask: Task<Void, Never>?
  private var refreshTask: Task<ChatGPTAuthTokens, Error>?
  /// Bumped on logout so a refresh that was already running cannot sign back in.
  private var authGeneration = 0

  var isAuthenticated: Bool {
    if case .authenticated = status { return true }
    return false
  }

  var user: ChatGPTUser? {
    if case .authenticated(let user) = status { return user }
    return nil
  }

  private init() {}

  func restore() async {
    pollingTask?.cancel()
    status = .loading
    let stored: ChatGPTAuthTokens?
    do {
      stored = try ChatGPTKeychain.load()
    } catch {
      stored = nil
    }
    guard let stored else {
      status = .unauthenticated
      return
    }
    do {
      let tokens = try await freshTokens()
      try await finishAuthentication(tokens)
    } catch ChatGPTAuthError.refreshUnavailable {
      // Offline, or the sign-in service is down. The session is kept: notes,
      // tasks and memory stay reachable, and the next request refreshes it.
      if let user = Self.user(from: stored) {
        status = .authenticated(user)
        availableModels = []
        modelCatalog = []
        modelsError = L.t(
          "Offline: models load when the connection returns.",
          "Çevrimdışı: modeller bağlantı gelince yüklenecek.")
      } else {
        status = .unauthenticated
      }
    } catch {
      // The service rejected the session (revoked or expired refresh token).
      try? ChatGPTKeychain.delete()
      availableModels = []
      modelCatalog = []
      status = .unauthenticated
    }
  }

  /// The signed-in user as recorded in stored tokens, without a network call.
  private static func user(from tokens: ChatGPTAuthTokens) -> ChatGPTUser? {
    guard let accountId = tokens.accountId, !accountId.isEmpty else { return nil }
    let claims = jwtClaims(tokens.idToken) ?? jwtClaims(tokens.accessToken) ?? [:]
    let auth = claims["https://api.openai.com/auth"] as? [String: Any]
    return ChatGPTUser(
      accountId: accountId,
      email: claims["email"] as? String,
      name: claims["name"] as? String,
      plan: auth?["chatgpt_plan_type"] as? String)
  }

  /// Whether a failed token refresh means the session is gone (sign in
  /// again) or only that the service could not be reached (keep it).
  enum RefreshFailure: Equatable {
    case rejected
    case unavailable

    /// `statusCode` is nil when the request never got an HTTP answer.
    static func classify(statusCode: Int?) -> RefreshFailure {
      guard let statusCode else { return .unavailable }
      switch statusCode {
      case 400, 401, 403: return .rejected
      default: return .unavailable
      }
    }
  }

  /// Reloads the model list and capabilities (Settings → AI models).
  func refreshModels() async {
    guard isAuthenticated else { return }
    await loadModels()
  }

  func startLogin() async throws -> ChatGPTPendingLogin {
    pollingTask?.cancel()
    status = .connecting
    do {
      var request = URLRequest(url: ChatGPTAPI.issuer.appending(path: "api/accounts/deviceauth/usercode"))
      request.httpMethod = "POST"
      request.timeoutInterval = 30
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.setValue("application/json", forHTTPHeaderField: "Accept")
      request.httpBody = try JSONSerialization.data(withJSONObject: ["client_id": ChatGPTAPI.clientId])
      let (data, response) = try await URLSession.shared.data(for: request)
      guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
        throw ChatGPTAuthError.deviceCodeFailed
      }
      guard let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let deviceAuthId = raw["device_auth_id"] as? String,
            let userCode = (raw["user_code"] ?? raw["usercode"]) as? String else {
        throw ChatGPTAuthError.deviceCodeFailed
      }
      let interval = (raw["interval"] as? NSNumber)?.doubleValue
        ?? (raw["interval"] as? String).flatMap(Double.init)
        ?? 5
      let pending = ChatGPTPendingLogin(
        deviceAuthId: deviceAuthId,
        userCode: userCode,
        verificationUrl: ChatGPTAPI.deviceVerification,
        interval: interval,
        expiresAt: Date().timeIntervalSince1970 * 1_000 + 15 * 60 * 1_000)
      status = .pending(pending)
      beginPolling(pending)
      return pending
    } catch {
      status = .error(error.localizedDescription)
      throw error
    }
  }

  func logout() async {
    pollingTask?.cancel()
    refreshTask?.cancel()
    refreshTask = nil
    // A refresh still in flight must not save tokens again after this.
    authGeneration += 1
    try? ChatGPTKeychain.delete()
    availableModels = []
    modelCatalog = []
    status = .unauthenticated
  }

  /// `forceRefresh` is used after the server rejects a token that still looked
  /// valid locally (for example after a password change or revoked session).
  func freshTokens(forceRefresh: Bool = false) async throws -> ChatGPTAuthTokens {
    if let refreshTask { return try await refreshTask.value }
    guard let stored = try ChatGPTKeychain.load() else { throw ChatGPTAuthError.notAuthenticated }
    if !forceRefresh,
       let expiry = stored.expiresAt,
       expiry > Date().timeIntervalSince1970 * 1_000 + 60_000,
       stored.accountId != nil {
      return stored
    }
    guard let refreshToken = stored.refreshToken else { throw ChatGPTAuthError.notAuthenticated }
    let generation = authGeneration
    let task = Task<ChatGPTAuthTokens, Error> {
      var request = URLRequest(url: ChatGPTAPI.issuer.appending(path: "oauth/token"))
      request.httpMethod = "POST"
      request.timeoutInterval = 30
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.setValue("application/json", forHTTPHeaderField: "Accept")
      request.httpBody = try JSONSerialization.data(withJSONObject: [
        "grant_type": "refresh_token",
        "refresh_token": refreshToken,
        "client_id": ChatGPTAPI.clientId,
        "scope": ChatGPTAPI.scope,
      ])
      let data: Data
      let response: URLResponse
      do {
        (data, response) = try await URLSession.shared.data(for: request)
      } catch {
        // No answer at all (offline, timeout, DNS): the session may still be valid.
        throw ChatGPTAuthError.refreshUnavailable
      }
      let code = (response as? HTTPURLResponse)?.statusCode
      guard code == 200 else {
        throw RefreshFailure.classify(statusCode: code) == .rejected
          ? ChatGPTAuthError.refreshFailed
          : ChatGPTAuthError.refreshUnavailable
      }
      guard let raw = try? JSONDecoder().decode(TokenResponse.self, from: data) else {
        throw ChatGPTAuthError.refreshUnavailable
      }
      let tokens = normalizedTokens(raw, previousRefreshToken: refreshToken)
      guard generation == self.authGeneration else { throw ChatGPTAuthError.notAuthenticated }
      try ChatGPTKeychain.save(tokens)
      return tokens
    }
    refreshTask = task
    defer { refreshTask = nil }
    let tokens = try await task.value
    // Signed in while offline: load the models now that the service answers.
    if modelCatalog.isEmpty, isAuthenticated {
      Task { [weak self] in await self?.loadModels(tokens) }
    }
    return tokens
  }

  private func beginPolling(_ pending: ChatGPTPendingLogin) {
    pollingTask = Task { [weak self] in
      while !Task.isCancelled, Date().timeIntervalSince1970 * 1_000 < pending.expiresAt {
        try? await Task.sleep(nanoseconds: UInt64(max(pending.interval, 1) * 1_000_000_000))
        guard !Task.isCancelled, let self else { return }
        do {
          var request = URLRequest(url: ChatGPTAPI.issuer.appending(path: "api/accounts/deviceauth/token"))
          request.httpMethod = "POST"
          request.timeoutInterval = 30
          request.setValue("application/json", forHTTPHeaderField: "Content-Type")
          request.setValue("application/json", forHTTPHeaderField: "Accept")
          request.httpBody = try JSONSerialization.data(withJSONObject: [
            "device_auth_id": pending.deviceAuthId,
            "user_code": pending.userCode,
          ])
          let (data, response) = try await URLSession.shared.data(for: request)
          let code = (response as? HTTPURLResponse)?.statusCode ?? 0
          if code == 403 || code == 404 || code == 429 { continue }
          guard code == 200 else { throw ChatGPTAuthError.deviceCodeFailed }
          let poll = try JSONDecoder().decode(DevicePollResponse.self, from: data)
          guard let authorizationCode = poll.authorizationCode,
                let verifier = poll.codeVerifier else { continue }
          let tokens = try await self.exchangeAuthorizationCode(
            authorizationCode,
            verifier: verifier)
          try await self.finishAuthentication(tokens)
          return
        } catch {
          continue
        }
      }
      if !Task.isCancelled {
        self?.status = .error("The sign-in code expired. Start again to get a new code.")
      }
    }
  }

  private func exchangeAuthorizationCode(
    _ code: String,
    verifier: String
  ) async throws -> ChatGPTAuthTokens {
    var request = URLRequest(url: ChatGPTAPI.issuer.appending(path: "oauth/token"))
    request.httpMethod = "POST"
    request.timeoutInterval = 30
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    var components = URLComponents()
    components.queryItems = [
      URLQueryItem(name: "grant_type", value: "authorization_code"),
      URLQueryItem(name: "client_id", value: ChatGPTAPI.clientId),
      URLQueryItem(name: "code", value: code),
      URLQueryItem(name: "code_verifier", value: verifier),
      URLQueryItem(name: "redirect_uri", value: ChatGPTAPI.deviceRedirect),
    ]
    request.httpBody = components.percentEncodedQuery?.data(using: .utf8)
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
      throw ChatGPTAuthError.tokenExchangeFailed
    }
    return normalizedTokens(try JSONDecoder().decode(TokenResponse.self, from: data))
  }

  private func finishAuthentication(_ tokens: ChatGPTAuthTokens) async throws {
    guard let accountId = tokens.accountId else { throw ChatGPTAuthError.missingAccount }
    try ChatGPTKeychain.save(tokens)
    let claims = jwtClaims(tokens.idToken) ?? jwtClaims(tokens.accessToken) ?? [:]
    let auth = claims["https://api.openai.com/auth"] as? [String: Any]
    status = .authenticated(ChatGPTUser(
      accountId: accountId,
      email: claims["email"] as? String,
      name: claims["name"] as? String,
      plan: auth?["chatgpt_plan_type"] as? String))
    await loadModels(tokens)
  }

  private func loadModels(_ current: ChatGPTAuthTokens? = nil) async {
    do {
      let tokens: ChatGPTAuthTokens
      if let current { tokens = current }
      else { tokens = try await freshTokens() }
      var components = URLComponents(
        url: ChatGPTAPI.codexBase.appending(path: "models"),
        resolvingAgainstBaseURL: false)!
      components.queryItems = [URLQueryItem(name: "client_version", value: ChatGPTAPI.clientVersion)]
      var request = URLRequest(url: components.url!)
      request.timeoutInterval = 30
      request.setValue("application/json", forHTTPHeaderField: "Accept")
      for (name, value) in try ChatGPTAPI.codexHeaders(tokens: tokens) {
        request.setValue(value, forHTTPHeaderField: name)
      }
      let (data, response) = try await URLSession.shared.data(for: request)
      guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
        throw ChatGPTAuthError.modelsFailed
      }
      let catalog = CatalogModel.parseList(try JSONSerialization.jsonObject(with: data))
      modelCatalog = catalog
      availableModels = catalog.map(\.slug)
      modelsFetchedAt = Date()
      modelsError = catalog.isEmpty ? "The service returned no models." : nil
    } catch {
      availableModels = []
      modelCatalog = []
      modelsError = LogSanitizer.sanitize(error.localizedDescription, limit: 160)
    }
  }
}

private struct DeviceCodeResponse: Decodable {
  let deviceAuthId: String
  let userCode: String
  let interval: Double?

  enum CodingKeys: String, CodingKey {
    case deviceAuthId = "device_auth_id"
    case userCode = "user_code"
    case interval
  }
}

private struct DevicePollResponse: Decodable {
  let authorizationCode: String?
  let codeVerifier: String?

  enum CodingKeys: String, CodingKey {
    case authorizationCode = "authorization_code"
    case codeVerifier = "code_verifier"
  }
}

private struct TokenResponse: Decodable {
  let accessToken: String
  let refreshToken: String?
  let idToken: String?
  let expiresIn: Double?

  enum CodingKeys: String, CodingKey {
    case accessToken = "access_token"
    case refreshToken = "refresh_token"
    case idToken = "id_token"
    case expiresIn = "expires_in"
  }
}

private func normalizedTokens(
  _ raw: TokenResponse,
  previousRefreshToken: String? = nil
) -> ChatGPTAuthTokens {
  let claims = jwtClaims(raw.idToken) ?? jwtClaims(raw.accessToken) ?? [:]
  let auth = claims["https://api.openai.com/auth"] as? [String: Any]
  let accountId = auth?["chatgpt_account_id"] as? String
    ?? auth?["chatgpt_account_id"] as? String
    ?? claims["chatgpt_account_id"] as? String
  let expiry = raw.expiresIn.map { Date().timeIntervalSince1970 * 1_000 + $0 * 1_000 }
    ?? (claims["exp"] as? Double).map { $0 * 1_000 }
  return ChatGPTAuthTokens(
    accessToken: raw.accessToken,
    refreshToken: raw.refreshToken ?? previousRefreshToken,
    idToken: raw.idToken,
    accountId: accountId,
    expiresAt: expiry)
}

private func jwtClaims(_ token: String?) -> [String: Any]? {
  guard let token, let encoded = token.split(separator: ".").dropFirst().first else { return nil }
  var base64 = String(encoded).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
  base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
  guard let data = Data(base64Encoded: base64),
        let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
  return value
}

private enum ChatGPTAuthError: LocalizedError {
  case notAuthenticated
  case deviceCodeFailed
  case tokenExchangeFailed
  case refreshFailed
  case refreshUnavailable
  case missingAccount
  case modelsFailed

  var errorDescription: String? {
    switch self {
    case .notAuthenticated: "Sign in with ChatGPT to continue."
    case .deviceCodeFailed: "OpenAI could not start device sign-in. Try again."
    case .tokenExchangeFailed: "OpenAI could not finish sign-in. Try again."
    case .refreshFailed: "Your ChatGPT session expired. Sign in again."
    case .refreshUnavailable: "ChatGPT could not be reached. Check the connection and try again."
    case .missingAccount: "The ChatGPT account identifier was missing."
    case .modelsFailed: "Your available ChatGPT models could not be loaded."
    }
  }
}
