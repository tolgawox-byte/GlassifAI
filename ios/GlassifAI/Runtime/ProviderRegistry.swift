import Foundation

/// One provider's health: a small circuit breaker, rate-limit pause and
/// latency record. After three failures in a row the provider is skipped
/// for two minutes (doubling on each trip, at most 30 minutes); a refused
/// key or missing credit waits for the user.
struct ProviderHealthState: Equatable {
  var consecutiveFailures = 0
  var trips = 0
  var unhealthyUntil: Date?
  var rateLimitedUntil: Date?
  /// Set when the user must act (reconnect, add credit).
  var needsUser: String?
  var latencies: [Int] = []
  var lastSuccess: Date?
  var lastModel: String?
  var lastError: String?

  static let failureThreshold = 3
  static let baseCooldown: TimeInterval = 120
  static let maxCooldown: TimeInterval = 1_800
  static let defaultRateLimitPause: TimeInterval = 60

  mutating func recordSuccess(latencyMs: Int, model: String?, at now: Date) {
    consecutiveFailures = 0
    trips = 0
    unhealthyUntil = nil
    rateLimitedUntil = nil
    needsUser = nil
    lastSuccess = now
    lastModel = model
    latencies.append(latencyMs)
    if latencies.count > 20 { latencies.removeFirst(latencies.count - 20) }
  }

  mutating func recordFailure(_ error: ProviderError, at now: Date) {
    lastError = error.localizedDescription
    switch error {
    case .invalidCredentials, .billing:
      needsUser = error.localizedDescription
    case .rateLimited(let after):
      rateLimitedUntil = now.addingTimeInterval(min(after ?? Self.defaultRateLimitPause, Self.maxCooldown))
    case .cancelled, .notConnected, .unsupported, .badRequest:
      break
    default:
      consecutiveFailures += 1
      if consecutiveFailures >= Self.failureThreshold {
        let cooldown = min(Self.baseCooldown * pow(2, Double(trips)), Self.maxCooldown)
        unhealthyUntil = now.addingTimeInterval(cooldown)
        trips += 1
        consecutiveFailures = 0
      }
    }
  }

  func isAvailable(at now: Date) -> Bool {
    if needsUser != nil { return false }
    if let until = unhealthyUntil, now < until { return false }
    if let until = rateLimitedUntil, now < until { return false }
    return true
  }

  var averageLatencyMs: Int? {
    latencies.isEmpty ? nil : latencies.reduce(0, +) / latencies.count
  }
}

/// One routed request, for Developer → Routing diagnostics: intent, agents,
/// providers, models, latency and result. Never the request's words, the
/// answer, or any credential.
struct RoutingDiagnostic: Identifiable, Equatable {
  let id = UUID()
  let at: Date
  let intent: String
  let strategy: ExecutionStrategy
  let steps: [String]
  let result: String
  let latencyMs: Int?
  let fallback: String?
}

/// Every provider's connection, keys (Keychain), models, health, the
/// routing settings (automatic, cost, per-role pins) and the diagnostics.
@MainActor
final class ProviderRegistry: ObservableObject {
  static let shared = ProviderRegistry()

  static let enabledKeyPrefix = "autoloom.provider.enabled."
  static let modelsKeyPrefix = "autoloom.provider.models."
  static let automaticKey = "autoloom.agents.automatic"
  static let overridesKey = "autoloom.agents.overrides"

  @Published private(set) var health: [ProviderID: ProviderHealthState] = [:]
  @Published private(set) var models: [ProviderID: [ProviderModel]] = [:]
  @Published private(set) var lastTests: [ProviderID: ProviderTestResult] = [:]
  @Published private(set) var lastErrors: [ProviderID: String] = [:]
  @Published private(set) var diagnostics: [RoutingDiagnostic] = []
  @Published private(set) var busy: Set<ProviderID> = []
  /// Bumped whenever a connection changes (the router reads it fresh).
  @Published private(set) var revision = 0

  @Published var automatic: Bool {
    didSet { defaults.set(automatic, forKey: Self.automaticKey) }
  }

  @Published var cost: CostPreference {
    didSet { defaults.set(cost.rawValue, forKey: CostPreference.defaultsKey) }
  }

  @Published var overrides: [AgentRole: ProviderID] {
    didSet {
      let raw = Dictionary(uniqueKeysWithValues: overrides.map { ($0.key.rawValue, $0.value.rawValue) })
      defaults.set(raw, forKey: Self.overridesKey)
    }
  }

  private let defaults: UserDefaults
  private let keychainService: String
  private let adapters: [ProviderID: AIProvider]
  private var keyPresent: [ProviderID: Bool] = [:]
  /// Tests replace the ChatGPT sign-in check.
  var chatGPTSignedIn: @MainActor () -> Bool = { ChatGPTAuthSession.shared.isAuthenticated }

  init(
    defaults: UserDefaults = .standard,
    keychainService: String = ProviderCredentialStore.defaultService,
    adapters: [ProviderID: AIProvider]? = nil
  ) {
    self.defaults = defaults
    self.keychainService = keychainService
    self.adapters = adapters ?? [
      .chatgpt: ChatGPTProvider(), .claude: ClaudeProvider(), .gemini: GeminiProvider(),
      .perplexity: PerplexityProvider(), .openrouter: OpenRouterProvider(), .local: LocalProvider(),
      .openclaw: OpenClawProvider(),
    ]
    automatic = defaults.object(forKey: Self.automaticKey) as? Bool ?? true
    cost = CostPreference(rawValue: defaults.string(forKey: CostPreference.defaultsKey) ?? "") ?? .balanced
    let raw = defaults.dictionary(forKey: Self.overridesKey) as? [String: String] ?? [:]
    var pins: [AgentRole: ProviderID] = [:]
    for (role, provider) in raw {
      if let role = AgentRole(rawValue: role), let provider = ProviderID(rawValue: provider) { pins[role] = provider }
    }
    overrides = pins
    for id in ProviderID.allCases where id.authKind == .apiKey {
      keyPresent[id] = ProviderCredentialStore.has(id, service: keychainService)
      if let data = defaults.data(forKey: Self.modelsKeyPrefix + id.rawValue),
         let stored = try? JSONDecoder().decode([ProviderModel].self, from: data) {
        models[id] = stored
      }
    }
  }

  func adapter(_ id: ProviderID) -> AIProvider {
    adapters[id] ?? LocalProvider()
  }

  /// The key, read from the Keychain only when a request needs it.
  func credential(_ id: ProviderID) -> String? {
    guard id.authKind == .apiKey else { return nil }
    return ProviderCredentialStore.load(id, service: keychainService)
  }

  func isEnabled(_ id: ProviderID) -> Bool {
    defaults.bool(forKey: Self.enabledKeyPrefix + id.rawValue)
  }

  func isConnected(_ id: ProviderID) -> Bool {
    switch id {
    case .chatgpt: chatGPTSignedIn()
    case .local: true
    case .openclaw: AgentGatewayConfig.baseURL != nil && AgentTokenStore.hasToken
    case .claude, .gemini, .perplexity, .openrouter: isEnabled(id) && (keyPresent[id] ?? false)
    }
  }

  func healthState(_ id: ProviderID) -> ProviderHealthState {
    health[id] ?? ProviderHealthState()
  }

  func isAvailable(_ id: ProviderID, now: Date = Date()) -> Bool {
    healthState(id).isAvailable(at: now)
  }

  /// The union of what the provider's models can do (or what it is known
  /// for, before its models are listed).
  func capabilities(of id: ProviderID) -> ProviderCapabilities {
    switch id {
    case .local: return .localTools
    case .openclaw: return [.text, .externalTools]
    case .chatgpt:
      let catalog = ChatGPTAuthSession.shared.modelCatalog
      guard !catalog.isEmpty else { return [.text, .vision, .liveVision, .reasoning, .web, .code, .tools, .audio] }
      return ChatGPTProvider.models(from: catalog).reduce(into: []) { $0.formUnion($1.capabilities) }
    case .perplexity:
      return PerplexityProvider.publishedModels.reduce(into: []) { $0.formUnion($1.capabilities) }
    case .claude, .gemini, .openrouter:
      let listed = models[id] ?? []
      if !listed.isEmpty { return listed.reduce(into: []) { $0.formUnion($1.capabilities) } }
      switch id {
      case .claude: return [.text, .vision, .reasoning, .code, .longContext, .tools]
      case .gemini: return [.text, .vision, .liveVision, .web, .reasoning, .code, .audio]
      default: return [.text, .vision, .web, .reasoning, .code]
      }
    }
  }

  /// The listed model a provider uses for a role.
  func model(for id: ProviderID, role: AgentRole) -> String? {
    ProviderModelChoice.choose(id, from: models[id] ?? [], role: role, cost: cost)
  }

  func routingContext(now: Date = Date(), online: Bool = NetworkStatus.shared.isOnline) -> RoutingContext {
    var context = RoutingContext()
    context.connected = Set(ProviderID.allCases.filter(isConnected))
    context.available = context.connected.filter { isAvailable($0, now: now) }
    var capabilities: [ProviderID: ProviderCapabilities] = [:]
    for id in context.connected { capabilities[id] = self.capabilities(of: id) }
    context.capabilities = capabilities
    context.overrides = overrides.filter { context.connected.contains($0.value) }
    context.cost = cost
    context.automatic = automatic
    context.online = online
    return context
  }

  // MARK: Connecting

  /// Tests the key with a tiny request, then keeps it in the Keychain.
  /// Called only after the user confirmed the cost notice.
  func connect(_ id: ProviderID, key: String) async -> Result<ProviderTestResult, ProviderError> {
    guard id.authKind == .apiKey else { return .failure(.unsupported("this provider has no API key")) }
    let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return .failure(.invalidCredentials) }
    busy.insert(id)
    defer { busy.remove(id) }
    let adapter = adapter(id)
    do {
      let result = try await adapter.testConnection(credential: trimmed)
      let listed = (try? await adapter.listModels(credential: trimmed)) ?? []
      guard ProviderCredentialStore.save(trimmed, for: id, service: keychainService) else {
        return .failure(.badRequest("the Keychain did not accept the key"))
      }
      keyPresent[id] = true
      defaults.set(true, forKey: Self.enabledKeyPrefix + id.rawValue)
      store(listed, for: id)
      lastTests[id] = result
      lastErrors[id] = nil
      var state = ProviderHealthState()
      state.recordSuccess(latencyMs: result.latencyMs, model: result.model, at: Date())
      health[id] = state
      revision += 1
      return .success(result)
    } catch let error as ProviderError {
      lastErrors[id] = error.localizedDescription
      return .failure(error)
    } catch {
      lastErrors[id] = LogSanitizer.sanitize(error.localizedDescription, limit: 120)
      return .failure(.network(lastErrors[id] ?? "error"))
    }
  }

  /// Removes the key from the Keychain; the router falls back at once.
  func disconnect(_ id: ProviderID) {
    guard id.authKind == .apiKey else { return }
    ProviderCredentialStore.delete(id, service: keychainService)
    keyPresent[id] = false
    defaults.set(false, forKey: Self.enabledKeyPrefix + id.rawValue)
    defaults.removeObject(forKey: Self.modelsKeyPrefix + id.rawValue)
    models[id] = nil
    health[id] = nil
    lastTests[id] = nil
    lastErrors[id] = nil
    overrides = overrides.filter { $0.value != id }
    revision += 1
  }

  @discardableResult
  func test(_ id: ProviderID) async -> Result<ProviderTestResult, ProviderError> {
    busy.insert(id)
    defer { busy.remove(id) }
    do {
      let result = try await adapter(id).testConnection(credential: credential(id))
      lastTests[id] = result
      lastErrors[id] = nil
      recordSuccess(id, latencyMs: result.latencyMs, model: result.model)
      if id.authKind == .apiKey, let listed = try? await adapter(id).listModels(credential: credential(id)) {
        store(listed, for: id)
      }
      return .success(result)
    } catch let error as ProviderError {
      lastErrors[id] = error.localizedDescription
      recordFailure(id, error: error)
      lastTests[id] = ProviderTestResult(
        success: false, latencyMs: 0, model: nil, modelsFound: 0, message: error.localizedDescription, at: Date())
      return .failure(error)
    } catch {
      let text = LogSanitizer.sanitize(error.localizedDescription, limit: 120)
      lastErrors[id] = text
      return .failure(.network(text))
    }
  }

  private func store(_ listed: [ProviderModel], for id: ProviderID) {
    guard !listed.isEmpty else { return }
    models[id] = listed
    if let data = try? JSONEncoder().encode(listed) {
      defaults.set(data, forKey: Self.modelsKeyPrefix + id.rawValue)
    }
  }

  // MARK: Health

  func recordSuccess(_ id: ProviderID, latencyMs: Int, model: String?, now: Date = Date()) {
    var state = healthState(id)
    state.recordSuccess(latencyMs: latencyMs, model: model, at: now)
    health[id] = state
  }

  func recordFailure(_ id: ProviderID, error: ProviderError, now: Date = Date()) {
    var state = healthState(id)
    state.recordFailure(error, at: now)
    health[id] = state
  }

  /// "Temporarily unavailable", "Reconnect", "Rate limited" or nil.
  func healthLabel(_ id: ProviderID, now: Date = Date()) -> String? {
    let state = healthState(id)
    if state.needsUser != nil { return L.t("Needs attention: reconnect or add credit", "Dikkat: yeniden bağlanın veya kredi ekleyin") }
    if let until = state.rateLimitedUntil, now < until { return L.t("Rate limited for now", "Şimdilik hız sınırında") }
    if let until = state.unhealthyUntil, now < until { return L.t("Temporarily unavailable", "Geçici olarak kullanılamıyor") }
    return nil
  }

  // MARK: Diagnostics

  func record(_ diagnostic: RoutingDiagnostic) {
    diagnostics.append(diagnostic)
    if diagnostics.count > 60 { diagnostics.removeFirst(diagnostics.count - 60) }
  }

  func clearDiagnostics() { diagnostics.removeAll() }
}

extension ChatGPTProvider {
  /// The account's catalog as provider models (the capability matrix).
  static func models(from catalog: [CatalogModel]) -> [ProviderModel] {
    catalog.map { model in
      var capabilities: ProviderCapabilities = [.text, .code, .tools, .audio]
      if model.acceptsImages { capabilities.formUnion([.vision, .liveVision]) }
      if model.supportsReasoning { capabilities.insert(.reasoning) }
      if model.webSearchToolType != nil { capabilities.insert(.web) }
      if (model.contextWindow ?? 0) >= 200_000 { capabilities.insert(.longContext) }
      return ProviderModel(
        id: model.slug, name: model.displayName, capabilities: capabilities, contextWindow: model.contextWindow,
        discovered: true)
    }
  }
}
