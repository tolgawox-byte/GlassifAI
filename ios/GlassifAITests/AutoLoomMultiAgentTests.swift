import Foundation
import XCTest

@testable import GlassifAI

/// A provider that answers from a closure and records every request.
final class MockProvider: AIProvider, @unchecked Sendable {
  let id: ProviderID
  private let lock = NSLock()
  private let respond: @Sendable (ProviderRequest, Int) async throws -> ProviderResponse
  private var requests: [ProviderRequest] = []

  init(_ id: ProviderID, respond: @escaping @Sendable (ProviderRequest, Int) async throws -> ProviderResponse) {
    self.id = id
    self.respond = respond
  }

  var calls: [ProviderRequest] {
    lock.lock(); defer { lock.unlock() }
    return requests
  }

  func send(_ request: ProviderRequest, credential: String?) async throws -> ProviderResponse {
    lock.lock()
    requests.append(request)
    let number = requests.count
    lock.unlock()
    return try await respond(request, number)
  }

  func listModels(credential: String?) async throws -> [ProviderModel] { [] }

  func testConnection(credential: String?) async throws -> ProviderTestResult {
    if credential == "bad-key" { throw ProviderError.invalidCredentials }
    return ProviderTestResult(success: true, latencyMs: 5, model: "mock", modelsFound: 0, message: "OK", at: Date())
  }
}

private func reply(_ text: String, model: String = "mock-model", sources: [ProviderSource] = []) -> ProviderResponse {
  ProviderResponse(text: text, model: model, sources: sources, latencyMs: 3)
}

private let allCapabilities: [ProviderID: ProviderCapabilities] = [
  .chatgpt: [.text, .vision, .liveVision, .reasoning, .web, .code, .tools, .audio],
  .local: .localTools,
  .claude: [.text, .vision, .reasoning, .code, .longContext, .tools],
  .gemini: [.text, .vision, .liveVision, .web, .reasoning, .code, .audio],
  .perplexity: [.text, .web, .reasoning, .longContext],
  .openrouter: [.text, .vision, .web, .reasoning, .code],
  .openclaw: [.text, .externalTools],
]

private func routing(
  _ extra: Set<ProviderID> = [],
  cost: CostPreference = .balanced,
  overrides: [AgentRole: ProviderID] = [:],
  unavailable: Set<ProviderID> = [],
  online: Bool = true,
  automatic: Bool = true
) -> RoutingContext {
  var context = RoutingContext()
  context.connected = extra.union([.chatgpt, .local])
  context.available = context.connected.subtracting(unavailable)
  context.capabilities = allCapabilities.filter { context.connected.contains($0.key) }
  context.cost = cost
  context.overrides = overrides
  context.online = online
  context.automatic = automatic
  return context
}

private func plan(
  _ text: String, kind: AssistantTaskKind? = nil, local: Bool = false, _ context: RoutingContext = routing()
) -> AgentPlan {
  AgentRouter.plan(for: RequestAnalyzer.analyze(text, kind: kind, localCommand: local), context: context)
}

// MARK: Routing (§18, §87)

final class AutoLoomRoutingTests: XCTestCase {
  func testNotesAndMessagesStayOnThePhone() {
    let note = plan("Not al: yarın kamera getir.", local: true)
    XCTAssertEqual(note.strategy, .local)
    XCTAssertEqual(note.primary, AgentStep(role: .deviceAction, provider: .local, purpose: "native action"))
    XCTAssertEqual(note.privacyLevel, .local)
    XCTAssertLessThanOrEqual(note.timeout, 10, "never a long cloud chain for a note")
    XCTAssertEqual(plan("Ahmet'e 10 dakika gecikeceğimi yaz.", local: true, routing([.claude, .perplexity])).strategy, .local)
    XCTAssertEqual(plan("Hatırlat", kind: .authorizedAction).primary.provider, .local)
    let memory = plan("Geçen gün bunu konuşmuştuk, neydi?", kind: .localMemory, routing([.claude, .gemini]))
    XCTAssertEqual(memory.strategy, .local)
    XCTAssertEqual(memory.primary.role, .memory)
  }

  func testWithOnlyChatGPTEverythingIsTheDefaultPath() {
    for (text, kind) in [
      ("Bu aracın modeli ne?", AssistantTaskKind.vision), ("What am I looking at?", .vision),
      ("Bugünkü haberleri araştır", .webSearch), ("Bu kodu analiz et", .deepReasoning),
      ("Bu PDF'i detaylı analiz et", .deepReasoning), ("Bu arabanın Kanada piyasasına bak.", .visionPlusWeb),
      ("Bu aracın piyasa değerini, recall durumunu ve bilinen önemli sorunlarını araştır.", .webSearch),
    ] {
      let result = plan(text, kind: kind)
      XCTAssertEqual(result.strategy, .fast, text)
      XCTAssertEqual(result.primary.provider, .chatgpt, text)
    }
  }

  func testSpecialistsTakeTheirJobs() {
    let all = routing([.claude, .gemini, .perplexity, .openrouter])
    XCTAssertEqual(plan("What am I looking at?", kind: .vision, all).primary, AgentStep(role: .vision, provider: .chatgpt, purpose: "answer about what is in view"))
    XCTAssertEqual(plan("Bugünkü haberleri araştır", kind: .webSearch, all).primary.provider, .perplexity)
    XCTAssertEqual(plan("Bugün hava nasıl?", kind: .webSearch, all).primary.role, .research)
    let code = plan("Bu kod neden hata veriyor?", all)
    XCTAssertEqual(code.primary.role, .coding)
    XCTAssertEqual(code.primary.provider, .claude)
    XCTAssertEqual(code.strategy, .specialist)
    XCTAssertEqual(code.fallbacks.last, .chatgpt, "ChatGPT is the compatible fallback")
    let document = plan("Bu 50 sayfalık belgeyi analiz et.", all)
    XCTAssertEqual(document.primary.role, .document)
    XCTAssertEqual(document.primary.provider, .claude)
    let live = plan("Şu gördüğüm şeyi sürekli takip et.", all)
    XCTAssertEqual(live.intent, "live_vision")
    XCTAssertEqual(live.primary.provider, .gemini)
    let recall = plan("Bu aracın recall'u var mı?", kind: .webSearch, all)
    XCTAssertEqual(recall.intent, "dealer_research")
    XCTAssertEqual(recall.primary.provider, .perplexity)
  }

  func testTeamsOnlyWhenSeveralAgentsAddSomething() {
    let research = routing([.perplexity])
    let canada = plan("Bu arabanın Kanada piyasasına bak.", kind: .visionPlusWeb, research)
    XCTAssertEqual(canada.strategy, .team)
    XCTAssertEqual(canada.primary.role, .vision)
    XCTAssertEqual(canada.secondary.map(\.provider), [.perplexity])
    let dealer = plan(
      "Bu aracın piyasa değerini, recall durumunu ve bilinen önemli sorunlarını araştır.", kind: .webSearch, research)
    XCTAssertEqual(dealer.strategy, .team)
    XCTAssertTrue(dealer.parallel)
    XCTAssertEqual(dealer.allSteps.map(\.purpose), ["price", "recall", "known issues"])
    XCTAssertEqual(
      plan("Bu aracın piyasa değerini ve recall durumunu araştır.", kind: .webSearch, routing([.perplexity], cost: .lowerCost)).strategy,
      .fast, "lower cost: one call on the ChatGPT account")
    let best = plan(
      "Bu aracın piyasa değerini ve recall durumunu araştır.", kind: .webSearch, routing([.perplexity, .claude], cost: .bestQuality))
    XCTAssertEqual(best.secondary.last?.role, .reasoning, "best quality: a reasoning agent fuses the findings")
  }

  func testPinsCostFallbacksHealthAndOffline() {
    let pinned = plan("Bugünkü haberleri araştır", kind: .webSearch, routing([.perplexity, .openrouter], overrides: [.research: .openrouter]))
    XCTAssertEqual(pinned.primary.provider, .openrouter)
    XCTAssertEqual(pinned.fallbacks, [.perplexity, .chatgpt])
    XCTAssertEqual(plan("Bu kodu analiz et", routing([.claude], cost: .lowerCost)).primary.provider, .chatgpt)
    XCTAssertEqual(plan("Bu kodu analiz et", routing([.claude], unavailable: [.claude])).primary.provider, .chatgpt, "a paused provider is skipped")
    XCTAssertEqual(plan("Bu kodu analiz et", routing([.claude], automatic: false)).primary.provider, .chatgpt)
    XCTAssertEqual(
      plan("Bu kodu analiz et", routing([.claude], overrides: [.coding: .claude], automatic: false)).primary.provider, .claude,
      "a pin works with automatic routing off")
    let offline = plan("Bugünkü haberleri araştır", kind: .webSearch, routing([.perplexity], online: false))
    XCTAssertEqual(offline.strategy, .local)
    XCTAssertEqual(offline.reason, "offline")
    XCTAssertEqual(plan("not al", local: true, routing(online: false)).strategy, .local, "offline notes still work")
    let agent = plan("OpenClaw'a sor", kind: .agent, routing([.openclaw]))
    XCTAssertEqual(agent.primary.provider, .openclaw)
    XCTAssertTrue(agent.requiresConfirmation)
  }

  func testAPlanSummaryHasNoContent() {
    let result = plan("Ahmet'in adresi Kadıköy 5, bunu araştır", kind: .webSearch, routing([.perplexity]))
    XCTAssertFalse(result.summary.contains("Ahmet"))
    XCTAssertFalse(result.summary.contains("Kadıköy"))
  }
}

// MARK: Fallback, health and teams (§21, §22, §88, §89)

@MainActor
final class AutoLoomAgentTeamTests: XCTestCase {
  private func registry(_ adapters: [ProviderID: AIProvider]) -> ProviderRegistry {
    ProviderRegistry(
      defaults: UserDefaults(suiteName: "autoloom-agents-\(UUID().uuidString)")!,
      keychainService: "com.autoloom.providers.test.\(UUID().uuidString)", adapters: adapters)
  }

  private func specialist(_ role: AgentRole, _ provider: ProviderID, fallbacks: [ProviderID]) -> AgentPlan {
    AgentPlan(
      intent: role.rawValue, requiredCapabilities: role.capability, strategy: .specialist,
      primary: AgentStep(role: role, provider: provider, purpose: "test"), fallbacks: fallbacks)
  }

  func testAFailingSpecialistFallsBackOnce() async throws {
    let claude = MockProvider(.claude) { _, _ in throw ProviderError.server(503) }
    let chatgpt = MockProvider(.chatgpt) { _, _ in reply("ChatGPT answer.") }
    let team = AutoLoomAgentOrchestrator(registry: registry([.claude: claude, .chatgpt: chatgpt]))
    let answer = try await team.execute(specialist(.reasoning, .claude, fallbacks: [.chatgpt]), context: .init(query: "Analyse"))
    XCTAssertEqual(answer.providers, [.chatgpt])
    XCTAssertTrue(answer.fallbackUsed)
    XCTAssertEqual(claude.calls.count, 1, "a server error moves on; it is not retried on the same provider")
    XCTAssertEqual(team.registry.diagnostics.last?.strategy, .specialist)
  }

  func testRateLimitsAndRefusedKeysPauseTheProvider() async throws {
    let perplexity = MockProvider(.perplexity) { _, _ in throw ProviderError.rateLimited(retryAfter: 30) }
    let claude = MockProvider(.claude) { _, _ in throw ProviderError.invalidCredentials }
    let chatgpt = MockProvider(.chatgpt) { _, _ in reply("Fallback.") }
    let registry = registry([.perplexity: perplexity, .claude: claude, .chatgpt: chatgpt])
    let team = AutoLoomAgentOrchestrator(registry: registry)
    _ = try await team.execute(specialist(.research, .perplexity, fallbacks: [.chatgpt]), context: .init(query: "q"))
    XCTAssertFalse(registry.isAvailable(.perplexity), "rate limited: skipped for a while")
    XCTAssertTrue(registry.isAvailable(.perplexity, now: Date().addingTimeInterval(31)))
    _ = try await team.execute(specialist(.reasoning, .claude, fallbacks: [.chatgpt]), context: .init(query: "q"))
    XCTAssertEqual(claude.calls.count, 1, "a refused key is never retried")
    XCTAssertNotNil(registry.healthState(.claude).needsUser)
    XCTAssertNotNil(registry.healthLabel(.claude))
    // Paused providers are not even tried.
    _ = try await team.execute(specialist(.reasoning, .claude, fallbacks: [.chatgpt]), context: .init(query: "q"))
    XCTAssertEqual(claude.calls.count, 1)
  }

  func testANetworkDropIsRetriedOnceAndEverythingFailingIsReported() async throws {
    let gemini = MockProvider(.gemini) { _, number in
      if number == 1 { throw ProviderError.network("dropped") }
      return reply("Second try.")
    }
    let team = AutoLoomAgentOrchestrator(registry: registry([.gemini: gemini]))
    let answer = try await team.execute(specialist(.vision, .gemini, fallbacks: []), context: .init(query: "q"))
    XCTAssertEqual(gemini.calls.count, 2)
    XCTAssertEqual(answer.text, "Second try.")

    let broken = MockProvider(.claude) { _, _ in throw ProviderError.server(500) }
    let alsoBroken = MockProvider(.chatgpt) { _, _ in throw ProviderError.server(500) }
    let failing = AutoLoomAgentOrchestrator(registry: registry([.claude: broken, .chatgpt: alsoBroken]))
    do {
      _ = try await failing.execute(specialist(.reasoning, .claude, fallbacks: [.chatgpt]), context: .init(query: "q"))
      XCTFail("expected every provider to fail")
    } catch let error as AgentTeamError {
      guard case .allFailed(let last, let tried) = error else { return XCTFail("\(error)") }
      XCTAssertEqual(last, .server(500))
      XCTAssertEqual(tried, [.claude, .chatgpt])
    }
  }

  func testTheCircuitBreakerPausesAndRecovers() {
    var state = ProviderHealthState()
    let now = Date()
    state.recordFailure(.server(500), at: now)
    state.recordFailure(.timeout, at: now)
    XCTAssertTrue(state.isAvailable(at: now))
    state.recordFailure(.network("x"), at: now)
    XCTAssertFalse(state.isAvailable(at: now), "three in a row: paused")
    XCTAssertTrue(state.isAvailable(at: now.addingTimeInterval(ProviderHealthState.baseCooldown + 1)))
    state.recordFailure(.server(502), at: now)
    state.recordFailure(.server(502), at: now)
    state.recordFailure(.server(502), at: now)
    XCTAssertFalse(state.isAvailable(at: now.addingTimeInterval(ProviderHealthState.baseCooldown + 1)), "the pause doubles")
    state.recordSuccess(latencyMs: 120, model: "m", at: now)
    XCTAssertTrue(state.isAvailable(at: now))
    XCTAssertEqual(state.averageLatencyMs, 120)
  }

  func testCancellingStopsTheCallsAtOnce() async throws {
    let slow = MockProvider(.claude) { _, _ in
      try await Task.sleep(nanoseconds: 5_000_000_000)
      return reply("late")
    }
    let team = AutoLoomAgentOrchestrator(registry: registry([.claude: slow]))
    let started = Date()
    let task = Task { try await team.execute(specialist(.reasoning, .claude, fallbacks: []), context: .init(query: "q")) }
    try await Task.sleep(nanoseconds: 200_000_000)
    task.cancel()
    do {
      _ = try await task.value
      XCTFail("expected cancellation")
    } catch is CancellationError {
    } catch {
      XCTFail("expected CancellationError, got \(error)")
    }
    XCTAssertLessThan(Date().timeIntervalSince(started), 3)
  }

  func testATeamResearchesInParallelAndFusesOneAnswer() async throws {
    let perplexity = MockProvider(.perplexity) { request, _ in
      let text = request.messages.first?.text ?? ""
      if text.contains("part: price") { return reply("Around 25,000 USD.", sources: [ProviderSource(url: URL(string: "https://example.com/a")!, title: "A", published: nil)]) }
      if text.contains("part: recall") { return reply("One recall in 2022 for the fuel pump.") }
      return reply("Transmission issues are reported.")
    }
    let team = AutoLoomAgentOrchestrator(registry: registry([.perplexity: perplexity, .chatgpt: MockProvider(.chatgpt) { _, _ in reply("x") }]))
    let research = plan(
      "Bu aracın piyasa değerini, recall durumunu ve bilinen önemli sorunlarını araştır.", kind: .webSearch,
      routing([.perplexity]))
    let answer = try await team.execute(research, context: .init(query: "q"))
    XCTAssertEqual(perplexity.calls.count, 3)
    XCTAssertTrue(answer.text.contains("25,000"))
    XCTAssertTrue(answer.text.contains("fuel pump"))
    XCTAssertTrue(answer.text.contains("Transmission"))
    XCTAssertEqual(answer.providers, [.perplexity])
    XCTAssertEqual(answer.sources.count, 1)
    XCTAssertFalse(answer.spoken.contains("http"))
  }

  func testSeeThenResearchCarriesTheSubject() async throws {
    EntityContext.shared.reset()
    let chatgpt = MockProvider(.chatgpt) { _, _ in reply("This is a 2019 Honda Civic. It is red.") }
    let perplexity = MockProvider(.perplexity) { _, _ in reply("Similar cars sell for 22,000 to 26,000 CAD in Canada.") }
    let team = AutoLoomAgentOrchestrator(registry: registry([.chatgpt: chatgpt, .perplexity: perplexity]))
    let canada = plan("Bu arabanın Kanada piyasasına bak.", kind: .visionPlusWeb, routing([.perplexity]))
    var context = AutoLoomAgentOrchestrator.Context(query: "Bu arabanın Kanada piyasasına bak.")
    context.images = [Data([0xFF, 0xD8])]
    let answer = try await team.execute(canada, context: context)
    XCTAssertEqual(chatgpt.calls.first?.messages.first?.images.count, 1, "the image goes to the seeing agent")
    XCTAssertEqual(perplexity.calls.first?.messages.first?.images.count, 0, "never to the research agent")
    XCTAssertTrue(perplexity.calls.first?.messages.first?.text.contains("2019 Honda Civic") ?? false, "research knows the subject")
    XCTAssertTrue(answer.text.contains("22,000"))
    XCTAssertEqual(EntityContext.shared.current(.vehicle)?.name, "2019 Honda Civic")
  }

  func testDisagreementIsStatedNotHidden() {
    let low = ResultFusion.Part(purpose: "price", text: "About 20,000 USD.", sources: [])
    let high = ResultFusion.Part(purpose: "price", text: "Around 45,000 USD.", sources: [])
    let close = ResultFusion.Part(purpose: "price", text: "Roughly 21,500 USD.", sources: [])
    XCTAssertTrue(ResultFusion.disagree([low, high]))
    XCTAssertFalse(ResultFusion.disagree([low, close]))
    XCTAssertEqual(ResultFusion.numbers(in: "25.000 TL, 30 000 TL, 12k, 2019 model"), [25_000, 30_000, 12_000])
    XCTAssertTrue(ResultFusion.fuse([low, high], subject: nil, disagreement: true, turkish: true).contains("farklı rakamlar"))
  }

  func testConnectingKeepsTheKeyOnlyWhenItWorks() async {
    let registry = registry([.claude: MockProvider(.claude) { _, _ in reply("ok") }])
    let refused = await registry.connect(.claude, key: "bad-key")
    XCTAssertEqual(refused, .failure(.invalidCredentials))
    XCTAssertFalse(registry.isConnected(.claude), "a refused key is not kept")
    let accepted = await registry.connect(.claude, key: "  sk-ant-test-1234  ")
    guard case .success = accepted else { return XCTFail("\(accepted)") }
    XCTAssertTrue(registry.isConnected(.claude))
    XCTAssertEqual(registry.credential(.claude), "sk-ant-test-1234")
    registry.overrides = [.reasoning: .claude]
    registry.disconnect(.claude)
    XCTAssertFalse(registry.isConnected(.claude))
    XCTAssertNil(registry.credential(.claude), "removed from the Keychain")
    XCTAssertTrue(registry.overrides.isEmpty, "the router falls back at once")
  }
}

// MARK: Adapters (§5–§10, §57, §58)

final class StubURLProtocol: URLProtocol {
  nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, [String: String], Data))?

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    guard let handler = Self.handler, let url = request.url else { return }
    let (status, headers, data) = handler(request)
    let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: data)
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}

  static func session() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    return URLSession(configuration: configuration)
  }
}

private func json(_ object: Any) -> Data { try! JSONSerialization.data(withJSONObject: object) }

final class AutoLoomProviderAdapterTests: XCTestCase {
  override func tearDown() {
    StubURLProtocol.handler = nil
    super.tearDown()
  }

  func testClaudeRequestAndReply() async throws {
    let request = ProviderRequest(
      role: .reasoning, system: "S", messages: [ProviderMessage(text: "Hi", images: [Data([1, 2, 3])])], model: "claude-x",
      maxOutputTokens: 100, timeout: 30)
    let urlRequest = try ClaudeProvider().messagesRequest(request, model: "claude-x", key: "sk-test-123")
    XCTAssertEqual(urlRequest.url?.absoluteString, "https://api.anthropic.com/v1/messages")
    XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "x-api-key"), "sk-test-123")
    XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
    let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(urlRequest.httpBody)) as? [String: Any])
    XCTAssertEqual(body["model"] as? String, "claude-x")
    XCTAssertEqual(body["system"] as? String, "S")
    XCTAssertEqual(body["max_tokens"] as? Int, 100)
    let content = try XCTUnwrap(((body["messages"] as? [[String: Any]])?.first?["content"]) as? [[String: Any]])
    XCTAssertEqual(content.map { $0["type"] as? String }, ["image", "text"])

    StubURLProtocol.handler = { _ in
      (200, [:], json(["model": "claude-x", "content": [["type": "thinking", "thinking": "hidden"], ["type": "text", "text": "Answer."]]]))
    }
    let response = try await ClaudeProvider(session: StubURLProtocol.session()).send(request, credential: "sk-test-123")
    XCTAssertEqual(response.text, "Answer.", "only text blocks, never thinking")
    StubURLProtocol.handler = { _ in (401, [:], json(["type": "error", "error": ["type": "authentication_error", "message": "invalid x-api-key"]])) }
    do {
      _ = try await ClaudeProvider(session: StubURLProtocol.session()).send(request, credential: "sk-test-123")
      XCTFail("expected a refusal")
    } catch let error as ProviderError {
      XCTAssertEqual(error, .invalidCredentials)
      XCTAssertFalse((error.errorDescription ?? "").contains("sk-test-123"), "never the key")
    }
  }

  func testClaudeModelsFromTheAPI() {
    let models = ClaudeProvider.models(from: ["data": [
      ["id": "claude-opus-4-1", "display_name": "Claude Opus 4.1"],
      ["id": "claude-sonnet-4-5", "display_name": "Claude Sonnet 4.5"],
      ["id": "claude-3-haiku-20240307", "display_name": "Claude Haiku 3"],
      ["id": "not-a-claude"],
    ]])
    XCTAssertEqual(models.map(\.id), ["claude-opus-4-1", "claude-sonnet-4-5", "claude-3-haiku-20240307"])
    XCTAssertTrue(models[1].capabilities.contains(.reasoning))
    XCTAssertFalse(models[2].capabilities.contains(.reasoning), "no extended thinking before 3.7")
    XCTAssertTrue(models.allSatisfy { $0.discovered && $0.capabilities.contains(.vision) })
    XCTAssertEqual(ProviderModelChoice.claude(models, role: .reasoning, cost: .balanced), "claude-sonnet-4-5")
    XCTAssertEqual(ProviderModelChoice.claude(models, role: .reasoning, cost: .bestQuality), "claude-opus-4-1")
    XCTAssertEqual(ProviderModelChoice.claude(models, role: .reasoning, cost: .lowerCost), "claude-3-haiku-20240307")
  }

  func testGeminiRequestGroundingAndModels() throws {
    var request = ProviderRequest(role: .research, system: "S", messages: [ProviderMessage(text: "Q")], timeout: 30)
    request.wantsWeb = true
    let urlRequest = try GeminiProvider().generateRequest(request, model: "gemini-2.5-flash", key: "AIza-test")
    XCTAssertEqual(
      urlRequest.url?.absoluteString, "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent")
    XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "x-goog-api-key"), "AIza-test")
    XCTAssertFalse(urlRequest.url?.absoluteString.contains("AIza") ?? true, "the key is a header, never in the URL")
    let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(urlRequest.httpBody)) as? [String: Any])
    XCTAssertNotNil((body["tools"] as? [[String: Any]])?.first?["google_search"])
    XCTAssertThrowsError(try GeminiProvider().generateRequest(request, model: "../evil", key: "k"))

    let parsed = try GeminiProvider.parse([
      "candidates": [[
        "content": ["parts": [["text": "Sunny, "], ["text": "22°C."]]],
        "groundingMetadata": ["groundingChunks": [["web": ["uri": "https://weather.example/x", "title": "Weather"]]]],
      ]],
    ])
    XCTAssertEqual(parsed.text, "Sunny, 22°C.")
    XCTAssertEqual(parsed.sources.first?.title, "Weather")
    XCTAssertThrowsError(try GeminiProvider.parse(["promptFeedback": ["blockReason": "SAFETY"]]))

    let models = GeminiProvider.models(from: ["models": [
      ["name": "models/gemini-2.5-flash", "supportedGenerationMethods": ["generateContent"], "inputTokenLimit": 1_048_576, "thinking": true],
      ["name": "models/gemini-2.5-pro", "supportedGenerationMethods": ["generateContent"], "inputTokenLimit": 1_048_576],
      ["name": "models/gemini-3-pro-preview", "supportedGenerationMethods": ["generateContent"]],
      ["name": "models/gemini-2.5-flash-lite", "supportedGenerationMethods": ["generateContent"]],
      ["name": "models/text-embedding-004", "supportedGenerationMethods": ["embedContent"]],
      ["name": "models/gemini-1.5-pro", "supportedGenerationMethods": ["generateContent"]],
    ]])
    XCTAssertEqual(models.count, 5, "embeddings are not chat models")
    let flash = try XCTUnwrap(models.first { $0.id == "gemini-2.5-flash" })
    XCTAssertTrue(flash.capabilities.isSuperset(of: [.vision, .liveVision, .web, .reasoning, .longContext]))
    XCTAssertFalse(try XCTUnwrap(models.first { $0.id == "gemini-1.5-pro" }).capabilities.contains(.web))
    XCTAssertEqual(ProviderModelChoice.gemini(models, role: .liveVision, cost: .balanced), "gemini-2.5-flash")
    XCTAssertEqual(ProviderModelChoice.gemini(models, role: .reasoning, cost: .balanced), "gemini-2.5-pro", "stable before preview")
    XCTAssertEqual(ProviderModelChoice.gemini(models, role: .vision, cost: .lowerCost), "gemini-2.5-flash-lite")
  }

  func testOpenAICompatibleProviders() throws {
    let perplexity = [
      "model": "sonar-pro",
      "choices": [["message": ["content": "<think>plan</think>Recall found."]]],
      "search_results": [["title": "NHTSA", "url": "https://www.nhtsa.gov/x", "date": "2025-01-02"]],
      "citations": ["https://ignored.example"],
    ] as [String: Any]
    XCTAssertEqual(OpenAICompatible.text(from: perplexity), "<think>plan</think>Recall found.")
    XCTAssertEqual(ResponseNormalizer.normalize(OpenAICompatible.text(from: perplexity)!), "Recall found.")
    XCTAssertEqual(OpenAICompatible.sources(from: perplexity).map(\.title), ["NHTSA"])
    XCTAssertEqual(OpenAICompatible.sources(from: perplexity).first?.published, "2025-01-02")
    XCTAssertEqual(
      OpenAICompatible.sources(from: ["citations": ["https://a.example", "https://a.example"]]).count, 1, "deduplicated")
    let openRouter = [
      "choices": [[
        "message": [
          "content": [["type": "text", "text": "Hello"]],
          "annotations": [["type": "url_citation", "url_citation": ["url": "https://b.example", "title": "B"]]],
        ],
      ]],
    ] as [String: Any]
    XCTAssertEqual(OpenAICompatible.text(from: openRouter), "Hello")
    XCTAssertEqual(OpenAICompatible.sources(from: openRouter).map(\.title), ["B"])

    var request = ProviderRequest(role: .research, system: "S", messages: [ProviderMessage(text: "Q", images: [Data([9])])], timeout: 30)
    request.wantsWeb = true
    let routerRequest = try OpenRouterProvider().chatRequest(request, model: "openrouter/auto", key: "sk-or-test")
    XCTAssertEqual(routerRequest.value(forHTTPHeaderField: "Authorization"), "Bearer sk-or-test")
    let routerBody = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(routerRequest.httpBody)) as? [String: Any])
    XCTAssertEqual((routerBody["plugins"] as? [[String: Any]])?.first?["id"] as? String, "web")
    let perplexityRequest = try PerplexityProvider().chatRequest(request, model: "sonar", key: "pplx-test")
    let perplexityBody = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(perplexityRequest.httpBody)) as? [String: Any])
    let messages = try XCTUnwrap(perplexityBody["messages"] as? [[String: Any]])
    XCTAssertTrue(messages.last?["content"] is String, "no images to the research provider")

    let models = OpenRouterProvider.models(from: ["data": [
      ["id": "meta/llama", "created": 1, "architecture": ["input_modalities": ["text"], "output_modalities": ["text"]]],
      ["id": "google/gemini-2.5-flash", "created": 3, "context_length": 1_000_000,
       "architecture": ["input_modalities": ["text", "image"], "output_modalities": ["text"]],
       "supported_parameters": ["tools", "reasoning"]],
      ["id": "image/gen", "created": 5, "architecture": ["input_modalities": ["text"], "output_modalities": ["image"]]],
    ]])
    XCTAssertEqual(models.map(\.id), ["google/gemini-2.5-flash", "meta/llama"], "newest first, text output only")
    XCTAssertTrue(models[0].capabilities.isSuperset(of: [.vision, .reasoning, .tools, .longContext]))
    XCTAssertEqual(ProviderModelChoice.openRouter(models, role: .vision), "google/gemini-2.5-flash")
    XCTAssertEqual(ProviderModelChoice.openRouter(models, role: .research), OpenRouterProvider.autoModel)
  }

  func testHTTPErrorsAreMappedWithoutSecrets() {
    XCTAssertEqual(ProviderHTTP.error(status: 401, body: Data(), retryAfter: nil), .invalidCredentials)
    XCTAssertEqual(ProviderHTTP.error(status: 429, body: Data(), retryAfter: "12"), .rateLimited(retryAfter: 12))
    XCTAssertEqual(ProviderHTTP.error(status: 402, body: Data(), retryAfter: nil), .billing)
    XCTAssertEqual(ProviderHTTP.error(status: 529, body: Data(), retryAfter: nil), .server(529))
    XCTAssertEqual(
      ProviderHTTP.error(status: 400, body: json(["error": ["message": "Your credit balance is too low"]]), retryAfter: nil),
      .billing)
    XCTAssertEqual(
      ProviderHTTP.error(status: 400, body: json(["error": ["message": "max_tokens too large"]]), retryAfter: nil),
      .badRequest("max_tokens too large"))
    XCTAssertTrue(ProviderError.network("x").isRetryable)
    XCTAssertFalse(ProviderError.timeout.isRetryable, "a timeout moves on to the next provider")
    XCTAssertTrue(ProviderError.invalidCredentials.needsUser)
  }

  func testKeysLiveInTheKeychainOnly() {
    let service = "com.autoloom.providers.test.\(UUID().uuidString)"
    XCTAssertNil(ProviderCredentialStore.load(.perplexity, service: service))
    XCTAssertTrue(ProviderCredentialStore.save(" pplx-abc-7890 ", for: .perplexity, service: service))
    XCTAssertEqual(ProviderCredentialStore.load(.perplexity, service: service), "pplx-abc-7890")
    XCTAssertEqual(ProviderCredentialStore.maskedHint("pplx-abc-7890"), "••••7890")
    ProviderCredentialStore.delete(.perplexity, service: service)
    XCTAssertFalse(ProviderCredentialStore.has(.perplexity, service: service))
    XCTAssertNil(UserDefaults.standard.dictionaryRepresentation().values.first { "\($0)".contains("pplx-abc-7890") })
  }
}

// MARK: One voice: normalizer and persona (§28–§41, §76, §90)

final class AutoLoomOneVoiceTests: XCTestCase {
  func testProviderVoicesAreRemoved() {
    XCTAssertEqual(
      ResponseNormalizer.normalize("<think>secret plan</think>As Claude, I think it is 4. The answer is 4."),
      "The answer is 4.")
    XCTAssertEqual(ResponseNormalizer.normalize("Claude says that the price is fine."), "The price is fine.")
    XCTAssertEqual(ResponseNormalizer.normalize("Great question! It is blue."), "It is blue.")
    let code = "Use `foo.bar()` here.\nfunc x() { a.b() }"
    XCTAssertEqual(ResponseNormalizer.normalize(code), code, "code stays exactly as written")
  }

  func testSpokenTextHasNoMarkdownTablesOrURLs() {
    let spoken = ResponseNormalizer.forSpeech(
      "## Summary\n| Model | Price |\n|---|---|\n| A | 1 |\nSee **[docs](https://x.example/a)** and https://y.example [1].\n- first point")
    XCTAssertFalse(spoken.contains("http"))
    XCTAssertFalse(spoken.contains("|"))
    XCTAssertFalse(spoken.contains("##"))
    XCTAssertFalse(spoken.contains("[1]"))
    XCTAssertFalse(spoken.contains("**"))
    XCTAssertTrue(spoken.contains("docs"))
    XCTAssertTrue(spoken.contains("first point"))
    XCTAssertLessThanOrEqual(ResponseNormalizer.forSpeech(String(repeating: "Bir cümle. ", count: 400), limit: 200).count, 201)
  }

  func testJarvisConfirmationsAreRefinedAndNeverRepetitive() {
    XCTAssertEqual(
      JarvisStyle.confirmation("Tamam, not aldım.", turkish: true, intensity: .balanced, word: "efendim", addAddress: true),
      "Not aldım efendim.")
    XCTAssertEqual(
      JarvisStyle.confirmation("Done, I've noted it.", turkish: false, intensity: .full, word: "sir", addAddress: true),
      "I've noted it, sir.")
    XCTAssertEqual(
      JarvisStyle.confirmation("Tamam, not aldım.", turkish: true, intensity: .subtle, word: "efendim", addAddress: true),
      "Not aldım.", "subtle: no form of address")
    XCTAssertEqual(
      JarvisStyle.confirmation("Fotoğrafı çektim. Galeriye kaydettim.", turkish: true, intensity: .full, word: "efendim", addAddress: true),
      "Fotoğrafı çektim efendim. Galeriye kaydettim.", "at most once")
    XCTAssertEqual(
      JarvisStyle.confirmation("Not aldım efendim.", turkish: true, intensity: .full, word: "efendim", addAddress: true),
      "Not aldım efendim.")
    XCTAssertEqual(
      JarvisStyle.confirmation("Tamam, not aldım.", turkish: true, intensity: .balanced, word: "efendim", addAddress: false),
      "Not aldım.")
    XCTAssertEqual(JarvisStyle.addressWord(turkish: true, address: .name, profileName: "Tolga"), "Tolga")
    XCTAssertNil(JarvisStyle.addressWord(turkish: true, address: .none))
    XCTAssertEqual(JarvisStyle.addressWord(turkish: false, address: .sir), "sir")
  }

  func testJarvisInstructionsAndGreeting() {
    let balanced = JarvisStyle.instructions(intensity: .balanced, address: .sir)
    XCTAssertTrue(balanced.contains("Jarvis Style is on"))
    XCTAssertTrue(balanced.contains("Do not imitate any real actor"))
    XCTAssertTrue(balanced.contains("efendim"))
    XCTAssertTrue(balanced.contains("at most once"))
    XCTAssertTrue(balanced.contains("Answer first"))
    XCTAssertTrue(JarvisStyle.instructions(intensity: .subtle, address: .sir).contains("Do not add a form of address"))
    XCTAssertLessThan(balanced.utf8.count, 1_600, "keeps the realtime instructions under their limit")

    let defaults = UserDefaults.standard
    let saved = (defaults.object(forKey: JarvisStyle.enabledKey), defaults.object(forKey: JarvisIntensity.defaultsKey),
                 defaults.object(forKey: JarvisAddress.defaultsKey))
    defer {
      defaults.set(saved.0, forKey: JarvisStyle.enabledKey)
      defaults.set(saved.1, forKey: JarvisIntensity.defaultsKey)
      defaults.set(saved.2, forKey: JarvisAddress.defaultsKey)
    }
    defaults.set(true, forKey: JarvisStyle.enabledKey)
    defaults.set(JarvisIntensity.balanced.rawValue, forKey: JarvisIntensity.defaultsKey)
    defaults.set(JarvisAddress.sir.rawValue, forKey: JarvisAddress.defaultsKey)
    XCTAssertEqual(
      JarvisStyle.greeting("Bağlantı hazır. Sizi dinliyorum.", turkish: true), "Bağlantı hazır. Sizi dinliyorum efendim.")
    let adapted = (0..<4).map { _ in JarvisStyle.adapt("Tamam, not aldım.", turkish: true) }
    XCTAssertEqual(adapted.filter { $0.contains("efendim") }.count, 2, "balanced: every other confirmation")
    XCTAssertTrue(adapted.allSatisfy { !$0.hasPrefix("Tamam") })
    defaults.set(false, forKey: JarvisStyle.enabledKey)
    XCTAssertEqual(JarvisStyle.adapt("Tamam, not aldım.", turkish: true), "Tamam, not aldım.", "off: unchanged")
  }

  @MainActor
  func testEntitiesKeepTheSubjectAcrossAgents() {
    XCTAssertEqual(EntityContext.vehicleMention(in: "Bu bir 2019 Honda Civic Sedan, kırmızı."), "2019 Honda Civic Sedan")
    XCTAssertEqual(EntityContext.vehicleMention(in: "Evet efendim, bu bir Mercedes-Benz C 200."), "Mercedes-Benz C 200")
    XCTAssertNil(EntityContext.vehicleMention(in: "Bu bir elma."))
    let entities = EntityContext()
    entities.note(.place, "Kadıköy")
    XCTAssertEqual(entities.contextLine(), "Current place: Kadıköy.")
    XCTAssertNil(entities.current(.place, now: Date().addingTimeInterval(EntityContext.lifetime + 1)))
  }
}
