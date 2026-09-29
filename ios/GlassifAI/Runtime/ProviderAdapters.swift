import Foundation

// MARK: Claude (Anthropic Messages API, API key)

/// Anthropic's Messages API with the user's own API key. A Claude.ai
/// subscription cannot be used by third-party apps, so there is no sign-in.
struct ClaudeProvider: AIProvider {
  let id = ProviderID.claude
  var session: URLSession = ProviderHTTP.session
  static let base = URL(string: "https://api.anthropic.com/v1/")!
  static let apiVersion = "2023-06-01"

  func messagesRequest(_ request: ProviderRequest, model: String, key: String) throws -> URLRequest {
    var messages: [[String: Any]] = []
    for message in request.messages {
      var content: [[String: Any]] = message.images.map { image in
        ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": image.base64EncodedString()]]
      }
      content.append(["type": "text", "text": message.text])
      messages.append(["role": message.role.rawValue, "content": content])
    }
    var body: [String: Any] = ["model": model, "max_tokens": request.maxOutputTokens, "messages": messages]
    if !request.system.isEmpty { body["system"] = request.system }
    var urlRequest = try ProviderHTTP.jsonRequest(
      url: Self.base.appending(path: "messages"), body: body, timeout: request.timeout)
    authorize(&urlRequest, key: key)
    return urlRequest
  }

  private func authorize(_ request: inout URLRequest, key: String) {
    request.setValue(key, forHTTPHeaderField: "x-api-key")
    request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
  }

  static func text(from json: [String: Any]) -> String? {
    let blocks = json["content"] as? [[String: Any]] ?? []
    let text = blocks.filter { ($0["type"] as? String) == "text" }.compactMap { $0["text"] as? String }
      .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    return text.isEmpty ? nil : text
  }

  func send(_ request: ProviderRequest, credential: String?) async throws -> ProviderResponse {
    guard let key = credential, !key.isEmpty else { throw ProviderError.notConnected }
    guard let model = request.model else { throw ProviderError.unsupported("no Claude model listed for this key") }
    let start = Date()
    let json = try await ProviderHTTP.json(try messagesRequest(request, model: model, key: key), session: session)
    guard let text = Self.text(from: json) else { throw ProviderError.emptyResponse }
    return ProviderResponse(
      text: text, model: json["model"] as? String ?? model, latencyMs: ProviderHTTP.milliseconds(since: start))
  }

  static func models(from json: [String: Any]) -> [ProviderModel] {
    (json["data"] as? [[String: Any]] ?? []).compactMap { item in
      guard let id = item["id"] as? String, id.hasPrefix("claude") else { return nil }
      // Claude 3.x before 3.7 has no extended thinking; every Claude model
      // reads images and has a 200k-token context.
      let legacy = id.hasPrefix("claude-3-") && !id.hasPrefix("claude-3-7")
      var capabilities: ProviderCapabilities = [.text, .vision, .code, .tools, .longContext]
      if !legacy { capabilities.insert(.reasoning) }
      return ProviderModel(
        id: id, name: item["display_name"] as? String ?? id, capabilities: capabilities, contextWindow: 200_000,
        discovered: true)
    }
  }

  func listModels(credential: String?) async throws -> [ProviderModel] {
    guard let key = credential, !key.isEmpty else { throw ProviderError.notConnected }
    var request = try ProviderHTTP.jsonRequest(
      url: Self.base.appending(path: "models").appending(queryItems: [URLQueryItem(name: "limit", value: "100")]),
      method: "GET", body: nil, timeout: 15)
    authorize(&request, key: key)
    return Self.models(from: try await ProviderHTTP.json(request, session: session))
  }

  func testConnection(credential: String?) async throws -> ProviderTestResult {
    let models = try await listModels(credential: credential)
    guard let model = ProviderModelChoice.claude(models, role: .chat, cost: .lowerCost) else {
      throw ProviderError.unsupported("this key lists no Claude models")
    }
    let start = Date()
    let reply = try await send(
      ProviderRequest(role: .chat, system: "", messages: [ProviderMessage(text: "Reply with OK.")], model: model,
                      maxOutputTokens: 8, timeout: 20),
      credential: credential)
    return ProviderTestResult(
      success: true, latencyMs: ProviderHTTP.milliseconds(since: start), model: reply.model, modelsFound: models.count,
      message: "OK", at: Date())
  }
}

// MARK: Gemini (Google Generative Language API, API key)

struct GeminiProvider: AIProvider {
  let id = ProviderID.gemini
  var session: URLSession = ProviderHTTP.session
  static let base = "https://generativelanguage.googleapis.com/v1beta/"

  /// Model ids are checked before they go into a URL.
  static func isSafeModelID(_ id: String) -> Bool {
    !id.isEmpty && id.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." || $0 == "_" }
  }

  func generateRequest(_ request: ProviderRequest, model: String, key: String) throws -> URLRequest {
    guard Self.isSafeModelID(model), let url = URL(string: Self.base + "models/\(model):generateContent") else {
      throw ProviderError.badRequest("invalid model id")
    }
    var contents: [[String: Any]] = []
    for message in request.messages {
      var parts: [[String: Any]] = message.images.map { image in
        ["inline_data": ["mime_type": "image/jpeg", "data": image.base64EncodedString()]]
      }
      parts.append(["text": message.text])
      contents.append(["role": message.role == .user ? "user" : "model", "parts": parts])
    }
    var body: [String: Any] = [
      "contents": contents,
      "generationConfig": ["maxOutputTokens": request.maxOutputTokens],
    ]
    if !request.system.isEmpty { body["systemInstruction"] = ["parts": [["text": request.system]]] }
    // Grounding with Google Search, for research on Gemini 2 and later.
    if request.wantsWeb { body["tools"] = [["google_search": [String: Any]()]] }
    var urlRequest = try ProviderHTTP.jsonRequest(url: url, body: body, timeout: request.timeout)
    urlRequest.setValue(key, forHTTPHeaderField: "x-goog-api-key")
    return urlRequest
  }

  static func parse(_ json: [String: Any]) throws -> (text: String, sources: [ProviderSource]) {
    let candidate = (json["candidates"] as? [[String: Any]])?.first
    let parts = ((candidate?["content"] as? [String: Any])?["parts"] as? [[String: Any]]) ?? []
    let text = parts.compactMap { $0["text"] as? String }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else {
      if let reason = (json["promptFeedback"] as? [String: Any])?["blockReason"] as? String {
        throw ProviderError.badRequest("blocked (\(reason))")
      }
      throw ProviderError.emptyResponse
    }
    let chunks = ((candidate?["groundingMetadata"] as? [String: Any])?["groundingChunks"] as? [[String: Any]]) ?? []
    let sources = chunks.compactMap { chunk -> ProviderSource? in
      guard let web = chunk["web"] as? [String: Any], let uri = web["uri"] as? String, let url = URL(string: uri) else {
        return nil
      }
      return ProviderSource(url: url, title: web["title"] as? String, published: nil)
    }
    return (text, sources)
  }

  func send(_ request: ProviderRequest, credential: String?) async throws -> ProviderResponse {
    guard let key = credential, !key.isEmpty else { throw ProviderError.notConnected }
    guard let model = request.model else { throw ProviderError.unsupported("no Gemini model listed for this key") }
    let start = Date()
    let json = try await ProviderHTTP.json(try generateRequest(request, model: model, key: key), session: session)
    let parsed = try Self.parse(json)
    return ProviderResponse(
      text: parsed.text, model: json["modelVersion"] as? String ?? model, sources: parsed.sources,
      latencyMs: ProviderHTTP.milliseconds(since: start))
  }

  static func models(from json: [String: Any]) -> [ProviderModel] {
    let excluded = ["embedding", "aqa", "imagen", "veo", "tts", "image", "learnlm"]
    return (json["models"] as? [[String: Any]] ?? []).compactMap { item in
      guard let name = item["name"] as? String else { return nil }
      let id = name.hasPrefix("models/") ? String(name.dropFirst("models/".count)) : name
      let methods = item["supportedGenerationMethods"] as? [String] ?? []
      guard id.hasPrefix("gemini"), methods.contains("generateContent"),
            !excluded.contains(where: { id.contains($0) }) else { return nil }
      let limit = item["inputTokenLimit"] as? Int
      var capabilities: ProviderCapabilities = [.text, .vision, .code, .tools]
      let modern = !id.hasPrefix("gemini-1")
      if modern { capabilities.formUnion([.web, .audio]) }
      if (item["thinking"] as? Bool) == true || id.contains("2.5") || id.hasPrefix("gemini-3") || id.contains("thinking") {
        capabilities.insert(.reasoning)
      }
      if id.contains("flash") || methods.contains("bidiGenerateContent") { capabilities.insert(.liveVision) }
      if (limit ?? 0) >= 500_000 { capabilities.insert(.longContext) }
      return ProviderModel(
        id: id, name: item["displayName"] as? String ?? id, capabilities: capabilities, contextWindow: limit,
        discovered: true)
    }
  }

  func listModels(credential: String?) async throws -> [ProviderModel] {
    guard let key = credential, !key.isEmpty else { throw ProviderError.notConnected }
    guard let url = URL(string: Self.base + "models?pageSize=200") else { throw ProviderError.badRequest("url") }
    var request = try ProviderHTTP.jsonRequest(url: url, method: "GET", body: nil, timeout: 15)
    request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
    return Self.models(from: try await ProviderHTTP.json(request, session: session))
  }

  func testConnection(credential: String?) async throws -> ProviderTestResult {
    let models = try await listModels(credential: credential)
    guard let model = ProviderModelChoice.gemini(models, role: .chat, cost: .lowerCost) else {
      throw ProviderError.unsupported("this key lists no Gemini models")
    }
    let start = Date()
    let reply = try await send(
      ProviderRequest(role: .chat, system: "", messages: [ProviderMessage(text: "Reply with OK.")], model: model,
                      maxOutputTokens: 8, timeout: 20),
      credential: credential)
    return ProviderTestResult(
      success: true, latencyMs: ProviderHTTP.milliseconds(since: start), model: reply.model, modelsFound: models.count,
      message: "OK", at: Date())
  }
}

// MARK: OpenAI-compatible chat (Perplexity, OpenRouter, OpenClaw)

enum OpenAICompatible {
  static func body(_ request: ProviderRequest, model: String, allowsImages: Bool) -> [String: Any] {
    var messages: [[String: Any]] = []
    if !request.system.isEmpty { messages.append(["role": "system", "content": request.system]) }
    for message in request.messages {
      if allowsImages, !message.images.isEmpty {
        var parts: [[String: Any]] = [["type": "text", "text": message.text]]
        for image in message.images {
          parts.append(["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(image.base64EncodedString())"]])
        }
        messages.append(["role": message.role.rawValue, "content": parts])
      } else {
        messages.append(["role": message.role.rawValue, "content": message.text])
      }
    }
    return ["model": model, "messages": messages, "max_tokens": request.maxOutputTokens]
  }

  /// `choices[0].message.content`, a string or text parts.
  static func text(from json: [String: Any]) -> String? {
    guard let message = (json["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any] else { return nil }
    var text = ""
    if let string = message["content"] as? String {
      text = string
    } else if let parts = message["content"] as? [[String: Any]] {
      text = parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }
    text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return text.isEmpty ? nil : text
  }

  /// Sources: Perplexity's `search_results` / `citations`, OpenRouter's
  /// `url_citation` annotations.
  static func sources(from json: [String: Any]) -> [ProviderSource] {
    var sources: [ProviderSource] = []
    for item in json["search_results"] as? [[String: Any]] ?? [] {
      if let string = item["url"] as? String, let url = URL(string: string) {
        sources.append(ProviderSource(url: url, title: item["title"] as? String, published: item["date"] as? String))
      }
    }
    if sources.isEmpty {
      for string in json["citations"] as? [String] ?? [] {
        if let url = URL(string: string) { sources.append(ProviderSource(url: url, title: nil, published: nil)) }
      }
    }
    let message = (json["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any]
    for annotation in message?["annotations"] as? [[String: Any]] ?? [] {
      guard let citation = annotation["url_citation"] as? [String: Any],
            let string = citation["url"] as? String, let url = URL(string: string) else { continue }
      sources.append(ProviderSource(url: url, title: citation["title"] as? String, published: nil))
    }
    var seen = Set<String>()
    return sources.filter { seen.insert($0.url.absoluteString).inserted }
  }
}

// MARK: Perplexity (Sonar, API key)

struct PerplexityProvider: AIProvider {
  let id = ProviderID.perplexity
  var session: URLSession = ProviderHTTP.session
  static let endpoint = URL(string: "https://api.perplexity.ai/chat/completions")!

  /// Perplexity publishes its model list in its documentation (there is no
  /// model-list endpoint); these are its Sonar models.
  static let publishedModels: [ProviderModel] = [
    ProviderModel(id: "sonar", name: "Sonar", capabilities: [.text, .web], contextWindow: 128_000, discovered: false),
    ProviderModel(
      id: "sonar-pro", name: "Sonar Pro", capabilities: [.text, .web, .longContext], contextWindow: 200_000,
      discovered: false),
    ProviderModel(
      id: "sonar-reasoning-pro", name: "Sonar Reasoning Pro", capabilities: [.text, .web, .reasoning],
      contextWindow: 128_000, discovered: false),
    ProviderModel(
      id: "sonar-deep-research", name: "Sonar Deep Research", capabilities: [.text, .web, .reasoning, .longContext],
      contextWindow: 128_000, discovered: false),
  ]

  func chatRequest(_ request: ProviderRequest, model: String, key: String) throws -> URLRequest {
    var urlRequest = try ProviderHTTP.jsonRequest(
      url: Self.endpoint, body: OpenAICompatible.body(request, model: model, allowsImages: false),
      timeout: request.timeout)
    urlRequest.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    return urlRequest
  }

  func send(_ request: ProviderRequest, credential: String?) async throws -> ProviderResponse {
    guard let key = credential, !key.isEmpty else { throw ProviderError.notConnected }
    let model = request.model ?? "sonar"
    let start = Date()
    let json = try await ProviderHTTP.json(try chatRequest(request, model: model, key: key), session: session)
    guard let text = OpenAICompatible.text(from: json) else { throw ProviderError.emptyResponse }
    return ProviderResponse(
      text: text, model: json["model"] as? String ?? model, sources: OpenAICompatible.sources(from: json),
      latencyMs: ProviderHTTP.milliseconds(since: start))
  }

  func listModels(credential: String?) async throws -> [ProviderModel] {
    guard credential?.isEmpty == false else { throw ProviderError.notConnected }
    return Self.publishedModels
  }

  func testConnection(credential: String?) async throws -> ProviderTestResult {
    let start = Date()
    let reply = try await send(
      ProviderRequest(role: .research, system: "", messages: [ProviderMessage(text: "Reply with OK.")], model: "sonar",
                      maxOutputTokens: 8, timeout: 25),
      credential: credential)
    return ProviderTestResult(
      success: true, latencyMs: ProviderHTTP.milliseconds(since: start), model: reply.model,
      modelsFound: Self.publishedModels.count, message: "OK", at: Date())
  }
}

// MARK: OpenRouter (API key)

struct OpenRouterProvider: AIProvider {
  let id = ProviderID.openrouter
  var session: URLSession = ProviderHTTP.session
  static let base = URL(string: "https://openrouter.ai/api/v1/")!
  /// OpenRouter's own router model: it picks a model for each request.
  static let autoModel = "openrouter/auto"

  func chatRequest(_ request: ProviderRequest, model: String, key: String) throws -> URLRequest {
    var body = OpenAICompatible.body(request, model: model, allowsImages: true)
    if request.wantsWeb { body["plugins"] = [["id": "web"]] }
    var urlRequest = try ProviderHTTP.jsonRequest(
      url: Self.base.appending(path: "chat/completions"), body: body, timeout: request.timeout)
    authorize(&urlRequest, key: key)
    return urlRequest
  }

  private func authorize(_ request: inout URLRequest, key: String) {
    request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    request.setValue("https://github.com/tolgawox-byte/GlassifAI", forHTTPHeaderField: "HTTP-Referer")
    request.setValue("AutoLoom Media Glasses", forHTTPHeaderField: "X-Title")
  }

  func send(_ request: ProviderRequest, credential: String?) async throws -> ProviderResponse {
    guard let key = credential, !key.isEmpty else { throw ProviderError.notConnected }
    let model = request.model ?? Self.autoModel
    let start = Date()
    let json = try await ProviderHTTP.json(try chatRequest(request, model: model, key: key), session: session)
    guard let text = OpenAICompatible.text(from: json) else { throw ProviderError.emptyResponse }
    return ProviderResponse(
      text: text, model: json["model"] as? String ?? model, sources: OpenAICompatible.sources(from: json),
      latencyMs: ProviderHTTP.milliseconds(since: start))
  }

  static func models(from json: [String: Any], limit: Int = 400) -> [ProviderModel] {
    var models = (json["data"] as? [[String: Any]] ?? []).compactMap { item -> (ProviderModel, Int)? in
      guard let id = item["id"] as? String else { return nil }
      let architecture = item["architecture"] as? [String: Any]
      let input = architecture?["input_modalities"] as? [String] ?? ["text"]
      let output = architecture?["output_modalities"] as? [String] ?? ["text"]
      guard output.contains("text") else { return nil }
      let parameters = item["supported_parameters"] as? [String] ?? []
      let context = item["context_length"] as? Int
      // The web plugin works with every model (billed per search).
      var capabilities: ProviderCapabilities = [.text, .code, .web]
      if input.contains("image") { capabilities.insert(.vision) }
      if input.contains("audio") { capabilities.insert(.audio) }
      if parameters.contains("reasoning") || parameters.contains("include_reasoning") { capabilities.insert(.reasoning) }
      if parameters.contains("tools") { capabilities.insert(.tools) }
      if (context ?? 0) >= 200_000 { capabilities.insert(.longContext) }
      let model = ProviderModel(
        id: id, name: item["name"] as? String ?? id, capabilities: capabilities, contextWindow: context, discovered: true)
      return (model, item["created"] as? Int ?? 0)
    }
    models.sort { $0.1 > $1.1 }
    return Array(models.prefix(limit).map(\.0))
  }

  func listModels(credential: String?) async throws -> [ProviderModel] {
    var request = try ProviderHTTP.jsonRequest(
      url: Self.base.appending(path: "models"), method: "GET", body: nil, timeout: 20)
    if let key = credential, !key.isEmpty { authorize(&request, key: key) }
    return Self.models(from: try await ProviderHTTP.json(request, session: session))
  }

  /// `GET /key` checks the key without spending anything.
  func testConnection(credential: String?) async throws -> ProviderTestResult {
    guard let key = credential, !key.isEmpty else { throw ProviderError.notConnected }
    let start = Date()
    var request = try ProviderHTTP.jsonRequest(url: Self.base.appending(path: "key"), method: "GET", body: nil, timeout: 15)
    authorize(&request, key: key)
    _ = try await ProviderHTTP.json(request, session: session)
    let latency = ProviderHTTP.milliseconds(since: start)
    let models = (try? await listModels(credential: credential)) ?? []
    return ProviderTestResult(
      success: true, latencyMs: latency, model: Self.autoModel, modelsFound: models.count, message: "OK", at: Date())
  }
}

// MARK: ChatGPT (the existing account connection)

/// The user's ChatGPT account through the existing Codex Responses client.
/// No API billing: the same connection the live voice uses.
struct ChatGPTProvider: AIProvider {
  let id = ProviderID.chatgpt

  static func taskKind(for role: AgentRole) -> AssistantTaskKind {
    switch role {
    case .vision, .liveVision, .translation: .vision
    case .research, .dealer: .webSearch
    case .reasoning, .coding, .document, .planning: .deepReasoning
    default: .generalChat
    }
  }

  @MainActor
  static func model(for request: ProviderRequest) -> String? {
    if let model = request.model { return model }
    let auth = ChatGPTAuthSession.shared
    return ModelSelector.model(
      for: taskKind(for: request.role), available: auth.availableModels, needsHostedWebSearch: request.wantsWeb,
      catalog: auth.modelCatalog, needsImages: request.messages.contains { !$0.images.isEmpty },
      excluded: ModelHealth.shared.failedThisRun)
  }

  static func map(_ error: ResponsesError) -> ProviderError {
    switch error {
    case .notSignedIn: .notConnected
    case .unauthorized: .invalidCredentials
    case .rateLimited(let after): .rateLimited(retryAfter: after.map { TimeInterval($0) })
    case .badRequest(let text): .badRequest(text)
    case .server(let code): .server(code)
    case .network(let text): .network(text)
    case .timedOut: .timeout
    case .cancelled: .cancelled
    case .emptyResponse: .emptyResponse
    case .failed(let text): .badRequest(text)
    }
  }

  func send(_ request: ProviderRequest, credential: String?) async throws -> ProviderResponse {
    guard let model = await Self.model(for: request) else { throw ProviderError.notConnected }
    let info = await MainActor.run { ChatGPTAuthSession.shared.modelCatalog.first { $0.slug == model } }
    var content: [[String: Any]] = []
    for message in request.messages {
      content.append(["type": "input_text", "text": message.text])
      for image in message.images {
        content.append(["type": "input_image", "image_url": "data:image/jpeg;base64,\(image.base64EncodedString())"])
      }
    }
    var responses = ResponsesClient.Request(
      model: model, instructions: request.system, input: [["role": "user", "content": content]])
    responses.reasoningEffort = ModelRouting.effort("low", supported: info?.reasoningLevels ?? [])
    responses.verbosity = (info?.supportsVerbosity ?? true) ? "low" : nil
    responses.timeout = request.timeout
    if request.wantsWeb { responses.tools = [AssistantTools.webSearch] }
    let start = Date()
    do {
      let result = try await ResponsesClient().send(responses)
      let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty else { throw ProviderError.emptyResponse }
      let sources = result.citations.map { ProviderSource(url: $0.url, title: $0.title, published: nil) }
      return ProviderResponse(text: text, model: model, sources: sources, latencyMs: ProviderHTTP.milliseconds(since: start))
    } catch let error as ResponsesError {
      throw Self.map(error)
    }
  }

  func listModels(credential: String?) async throws -> [ProviderModel] {
    await MainActor.run { Self.models(from: ChatGPTAuthSession.shared.modelCatalog) }
  }

  func testConnection(credential: String?) async throws -> ProviderTestResult {
    let start = Date()
    let reply = try await send(
      ProviderRequest(role: .chat, system: "Reply with OK.", messages: [ProviderMessage(text: "OK?")], timeout: 20),
      credential: nil)
    let count = try await listModels(credential: nil).count
    return ProviderTestResult(
      success: true, latencyMs: ProviderHTTP.milliseconds(since: start), model: reply.model, modelsFound: count,
      message: "OK", at: Date())
  }
}

// MARK: Local and OpenClaw

/// The phone's own tools. They run through the intent bridge and the
/// native executor, never through a model call; this adapter only describes
/// them for routing and Settings.
struct LocalProvider: AIProvider {
  let id = ProviderID.local

  static let tools = [
    "notes", "memory", "tasks", "reminders", "calendar", "contacts", "maps", "clipboard", "Photos", "OCR",
    "semantic search", "time parsing", "intent routing", "timers",
  ]

  static let model = ProviderModel(
    id: "on-device", name: L.t("On this iPhone", "Bu iPhone'da"), capabilities: [.localTools], contextWindow: nil,
    discovered: true)

  func send(_ request: ProviderRequest, credential: String?) async throws -> ProviderResponse {
    throw ProviderError.unsupported("local tools run through the intent bridge")
  }

  func listModels(credential: String?) async throws -> [ProviderModel] { [Self.model] }

  func testConnection(credential: String?) async throws -> ProviderTestResult {
    ProviderTestResult(
      success: true, latencyMs: 0, model: Self.model.id, modelsFound: 1, message: "OK", at: Date())
  }
}

/// The user's own OpenClaw gateway (optional, existing client).
struct OpenClawProvider: AIProvider {
  let id = ProviderID.openclaw

  func send(_ request: ProviderRequest, credential: String?) async throws -> ProviderResponse {
    let prompt = request.messages.map(\.text).joined(separator: "\n")
    let start = Date()
    do {
      let text = try await AgentGatewayClient().send(prompt: prompt, sessionUser: "autoloom")
      return ProviderResponse(text: text, model: AgentGatewayConfig.agentID, latencyMs: ProviderHTTP.milliseconds(since: start))
    } catch let error as AgentGatewayError {
      throw Self.map(error)
    }
  }

  static func map(_ error: AgentGatewayError) -> ProviderError {
    switch error {
    case .notConfigured: .notConnected
    case .unauthorized: .invalidCredentials
    case .network(let text): .network(text)
    case .http(let code): .server(code)
    case .emptyReply: .emptyResponse
    }
  }

  func listModels(credential: String?) async throws -> [ProviderModel] {
    do {
      return try await AgentGatewayClient().testConnection().map {
        ProviderModel(id: $0, name: $0, capabilities: [.text, .externalTools], contextWindow: nil, discovered: true)
      }
    } catch let error as AgentGatewayError {
      throw Self.map(error)
    }
  }

  func testConnection(credential: String?) async throws -> ProviderTestResult {
    let start = Date()
    let models = try await listModels(credential: credential)
    return ProviderTestResult(
      success: true, latencyMs: ProviderHTTP.milliseconds(since: start), model: models.first?.id,
      modelsFound: models.count, message: "OK", at: Date())
  }
}

// MARK: Model choice

/// Which listed model a provider uses for a role and cost preference.
/// Chosen from what the provider listed, never an invented name.
enum ProviderModelChoice {
  static func choose(_ provider: ProviderID, from models: [ProviderModel], role: AgentRole, cost: CostPreference) -> String? {
    switch provider {
    case .claude: claude(models, role: role, cost: cost)
    case .gemini: gemini(models, role: role, cost: cost)
    case .perplexity: perplexity(role: role, cost: cost)
    case .openrouter: openRouter(models, role: role)
    case .chatgpt, .local, .openclaw: nil
    }
  }

  /// Newest first (the API's order): Sonnet for balanced, Opus for best
  /// quality, Haiku for lower cost.
  static func claude(_ models: [ProviderModel], role: AgentRole, cost: CostPreference) -> String? {
    let families: [String]
    switch cost {
    case .bestQuality: families = ["opus", "sonnet", "haiku"]
    case .lowerCost, .localFirst: families = ["haiku", "sonnet", "opus"]
    case .balanced: families = role == .chat ? ["haiku", "sonnet", "opus"] : ["sonnet", "opus", "haiku"]
    }
    for family in families {
      if let model = models.first(where: { $0.id.contains(family) }) { return model.id }
    }
    return models.first?.id
  }

  /// Flash for vision, live vision and chat; Pro for reasoning and documents
  /// (Flash-Lite when cost matters); stable versions before previews; the
  /// highest version wins.
  static func gemini(_ models: [ProviderModel], role: AgentRole, cost: CostPreference) -> String? {
    let heavy = role == .reasoning || role == .document || role == .coding
    let family: String
    switch cost {
    case .bestQuality: family = heavy ? "pro" : "flash"
    case .balanced: family = heavy ? "pro" : "flash"
    case .lowerCost, .localFirst: family = "flash-lite"
    }
    func pick(_ matches: (String) -> Bool) -> String? {
      let candidates = models.filter { matches($0.id) }
      let stable = candidates.filter { !$0.id.contains("preview") && !$0.id.contains("exp") }
      return (stable.isEmpty ? candidates : stable).max { version($0.id) < version($1.id) }?.id
    }
    let exact: (String) -> Bool = { id in
      family == "flash" ? id.contains("flash") && !id.contains("lite") : id.contains(family)
    }
    return pick(exact) ?? pick { $0.contains("flash") } ?? models.first?.id
  }

  /// "gemini-2.5-flash" → 2.5.
  static func version(_ id: String) -> Double {
    let parts = id.split(separator: "-")
    guard parts.count > 1 else { return 0 }
    return Double(parts[1]) ?? 0
  }

  static func perplexity(role: AgentRole, cost: CostPreference) -> String {
    if role == .reasoning { return "sonar-reasoning-pro" }
    return cost == .lowerCost || cost == .localFirst ? "sonar" : "sonar-pro"
  }

  /// OpenRouter's own auto router for text; the newest vision model of a
  /// well-known family for images.
  static func openRouter(_ models: [ProviderModel], role: AgentRole) -> String? {
    guard role.capability == .vision else { return OpenRouterProvider.autoModel }
    let families = ["google/gemini", "anthropic/claude", "openai/gpt"]
    for family in families {
      if let model = models.first(where: { $0.id.hasPrefix(family) && $0.capabilities.contains(.vision) }) {
        return model.id
      }
    }
    return models.first { $0.capabilities.contains(.vision) }?.id
  }
}
