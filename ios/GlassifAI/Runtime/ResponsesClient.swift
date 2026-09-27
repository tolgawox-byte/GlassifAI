import Foundation

struct URLCitation: Equatable {
  let url: URL
  let title: String?
}

struct WebSearchCall: Equatable {
  let id: String
  var query: String?
  var status: String?
  var sourceURLs: [URL]
}

struct ModelFunctionCall: Equatable {
  let name: String
  let callID: String
  let arguments: String
}

struct ResponsesResult {
  var text = ""
  var citations: [URLCitation] = []
  var webSearches: [WebSearchCall] = []
  var functionCalls: [ModelFunctionCall] = []
  var firstOutputAt: Date?
  var completedAt: Date?
  var incompleteReason: String?
}

enum ResponsesProgress {
  case requestSent
  case firstOutput
  case webSearchStarted(String?)
  case webSearchFinished
}

enum ResponsesError: LocalizedError, Equatable {
  case notSignedIn
  case unauthorized
  case rateLimited(retryAfter: Int?)
  case badRequest(String)
  case server(Int)
  case network(String)
  case timedOut
  case cancelled
  case emptyResponse
  case failed(String)

  var errorDescription: String? {
    switch self {
    case .notSignedIn: "Sign in with ChatGPT to continue."
    case .unauthorized: "Your ChatGPT session expired. Sign in again in Settings."
    case .rateLimited(let retryAfter):
      retryAfter.map { "ChatGPT is rate-limiting requests. Try again in \($0) seconds." }
        ?? "ChatGPT usage limit reached or too many requests. Try again shortly."
    case .badRequest(let message): "ChatGPT rejected the request: \(message)"
    case .server(let code): "ChatGPT is temporarily unavailable (HTTP \(code))."
    case .network(let message): "Network problem: \(message)"
    case .timedOut: "The request took too long."
    case .cancelled: "Cancelled."
    case .emptyResponse: "ChatGPT returned an empty answer."
    case .failed(let message): message
    }
  }

  /// Wording the voice model can relay to the user.
  var speakableSummary: String {
    switch self {
    case .rateLimited: "ChatGPT is rate-limiting requests right now; try again in a moment."
    case .network, .timedOut: "The network request failed; the connection may have dropped."
    case .unauthorized, .notSignedIn: "The ChatGPT session needs a fresh sign-in in the app settings."
    default: "The request failed."
    }
  }
}

/// Minimal streaming client for the ChatGPT-account Codex Responses endpoint
/// (`chatgpt.com/backend-api/codex/responses`). Uses the same account headers
/// as the original vision request and supports hosted tools such as web search.
struct ResponsesClient {
  struct Request {
    var model: String
    var instructions: String
    var input: [[String: Any]]
    var tools: [[String: Any]] = []
    /// nil omits `reasoning` (models that list no reasoning levels).
    var reasoningEffort: String? = "low"
    /// nil omits `text.verbosity` (models without verbosity support).
    var verbosity: String? = "low"
    var jsonSchema: (name: String, schema: [String: Any])?
    var include: [String] = ["reasoning.encrypted_content"]
    var promptCacheKey: String?
    var timeout: TimeInterval = 45
  }

  private static let session: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.waitsForConnectivity = false
    configuration.timeoutIntervalForRequest = 60
    configuration.timeoutIntervalForResource = 120
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.httpCookieStorage = nil
    configuration.urlCache = nil
    return URLSession(configuration: configuration)
  }()

  func send(
    _ request: Request,
    onProgress: @escaping @MainActor (ResponsesProgress) -> Void = { _ in }
  ) async throws -> ResponsesResult {
    var attempt = 0
    var forceRefresh = false
    while true {
      attempt += 1
      do {
        return try await sendOnce(request, forceRefresh: forceRefresh, onProgress: onProgress)
      } catch let error as ResponsesError {
        guard attempt == 1 else { throw error }
        switch error {
        case .unauthorized:
          forceRefresh = true
        case .server(let code) where code == 502 || code == 503 || code == 504:
          try await Task.sleep(nanoseconds: 350_000_000)
        case .network:
          try await Task.sleep(nanoseconds: 350_000_000)
        default:
          throw error
        }
      }
    }
  }

  private func sendOnce(
    _ request: Request,
    forceRefresh: Bool,
    onProgress: @escaping @MainActor (ResponsesProgress) -> Void
  ) async throws -> ResponsesResult {
    let tokens: ChatGPTAuthTokens
    do {
      tokens = try await ChatGPTAuthSession.shared.freshTokens(forceRefresh: forceRefresh)
    } catch {
      throw forceRefresh ? ResponsesError.unauthorized : ResponsesError.notSignedIn
    }
    var components = URLComponents(
      url: ChatGPTAPI.codexBase.appending(path: "responses"),
      resolvingAgainstBaseURL: false)!
    components.queryItems = [URLQueryItem(name: "client_version", value: ChatGPTAPI.clientVersion)]
    guard let url = components.url else { throw ResponsesError.failed("Invalid endpoint") }

    var urlRequest = URLRequest(url: url)
    urlRequest.httpMethod = "POST"
    urlRequest.timeoutInterval = request.timeout
    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
    urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
    do {
      for (name, value) in try ChatGPTAPI.codexHeaders(tokens: tokens) {
        urlRequest.setValue(value, forHTTPHeaderField: name)
      }
    } catch {
      throw ResponsesError.notSignedIn
    }
    urlRequest.httpBody = try JSONSerialization.data(withJSONObject: Self.body(for: request))

    let connection: (URLSession.AsyncBytes, URLResponse)
    do {
      connection = try await Self.session.bytes(for: urlRequest)
    } catch {
      throw Self.map(error)
    }
    let (bytes, response) = connection
    await onProgress(.requestSent)
    guard let http = response as? HTTPURLResponse else { throw ResponsesError.failed("No HTTP response") }
    guard (200..<300).contains(http.statusCode) else {
      var body = Data()
      do {
        for try await byte in bytes {
          body.append(byte)
          if body.count > 32_000 { break }
        }
      } catch {}
      throw Self.httpError(status: http.statusCode, body: body, headers: http)
    }

    var parser = ResponsesStreamParser()
    do {
      for try await line in bytes.lines {
        try Task.checkCancellation()
        for event in parser.consume(line: line) {
          switch event {
          case .firstOutput: await onProgress(.firstOutput)
          case .webSearchStarted(let query): await onProgress(.webSearchStarted(query))
          case .webSearchFinished: await onProgress(.webSearchFinished)
          }
        }
        if parser.isFinished { break }
      }
    } catch is CancellationError {
      throw ResponsesError.cancelled
    } catch let error as ResponsesError {
      throw error
    } catch {
      throw Self.map(error)
    }
    if let failure = parser.failureMessage {
      throw ResponsesError.failed(LogSanitizer.sanitize(failure, limit: 200))
    }
    var result = parser.result
    result.text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    if result.completedAt == nil { result.completedAt = Date() }
    if result.text.isEmpty && result.functionCalls.isEmpty {
      throw ResponsesError.emptyResponse
    }
    return result
  }

  static func body(for request: Request) -> [String: Any] {
    var body: [String: Any] = [
      "model": request.model,
      "stream": true,
      "store": false,
      "instructions": request.instructions,
      "input": request.input,
    ]
    if let effort = request.reasoningEffort {
      // No reasoning summary: nothing displays it and it only adds latency.
      body["reasoning"] = ["effort": effort]
    }
    var text: [String: Any] = [:]
    if let verbosity = request.verbosity { text["verbosity"] = verbosity }
    if let schema = request.jsonSchema {
      text["format"] = [
        "type": "json_schema",
        "name": schema.name,
        "schema": schema.schema,
        "strict": true,
      ]
    }
    if !text.isEmpty { body["text"] = text }
    if !request.include.isEmpty { body["include"] = request.include }
    if !request.tools.isEmpty {
      body["tools"] = request.tools
      body["tool_choice"] = "auto"
      body["parallel_tool_calls"] = false
    }
    if let key = request.promptCacheKey { body["prompt_cache_key"] = key }
    return body
  }

  static func map(_ error: Error) -> ResponsesError {
    if error is CancellationError { return .cancelled }
    if let urlError = error as? URLError {
      switch urlError.code {
      case .cancelled: return .cancelled
      case .timedOut: return .timedOut
      case .notConnectedToInternet: return .network("No internet connection")
      case .networkConnectionLost: return .network("Connection lost")
      default: return .network(urlError.localizedDescription)
      }
    }
    return .network(LogSanitizer.sanitize(error.localizedDescription, limit: 160))
  }

  static func httpError(status: Int, body: Data, headers: HTTPURLResponse) -> ResponsesError {
    let message = errorMessage(from: body)
    switch status {
    case 401, 403: return .unauthorized
    case 429:
      let retry = (headers.value(forHTTPHeaderField: "Retry-After")).flatMap { Int($0) }
      return .rateLimited(retryAfter: retry)
    case 400...499: return .badRequest(message ?? "HTTP \(status)")
    default: return .server(status)
    }
  }

  static func errorMessage(from body: Data) -> String? {
    guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
      let text = String(data: body.prefix(300), encoding: .utf8)
      return text.map { LogSanitizer.sanitize($0, limit: 200) }
    }
    let error = json["error"] as? [String: Any]
    let message = (error?["message"] as? String) ?? (json["detail"] as? String) ?? (json["message"] as? String)
    return message.map { LogSanitizer.sanitize($0, limit: 200) }
  }
}

struct DirectSearchHit: Equatable {
  let url: URL
  let title: String?
  let snippet: String?
}

struct DirectSearchResult {
  let output: String
  let hits: [DirectSearchHit]
}

/// Fallback search through the Codex backend's search endpoint (what Codex
/// itself uses for models without the hosted web-search tool). Returns the
/// rendered search output for the model plus structured result links.
struct DirectSearchClient {
  private static let session: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 30
    configuration.httpCookieStorage = nil
    configuration.urlCache = nil
    return URLSession(configuration: configuration)
  }()

  func search(queries: [String], model: String, sessionID: String) async throws -> DirectSearchResult {
    let cleaned = queries
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
      .prefix(3)
    guard !cleaned.isEmpty else { throw ResponsesError.badRequest("Empty search query") }
    let tokens: ChatGPTAuthTokens
    do {
      tokens = try await ChatGPTAuthSession.shared.freshTokens()
    } catch {
      throw ResponsesError.notSignedIn
    }
    var request = URLRequest(url: ChatGPTAPI.codexBase.appending(path: "alpha/search"))
    request.httpMethod = "POST"
    request.timeoutInterval = 30
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    do {
      for (name, value) in try ChatGPTAPI.codexHeaders(tokens: tokens) {
        request.setValue(value, forHTTPHeaderField: name)
      }
    } catch {
      throw ResponsesError.notSignedIn
    }
    request.httpBody = try JSONSerialization.data(withJSONObject: Self.body(
      queries: Array(cleaned), model: model, sessionID: sessionID))

    let exchange: (Data, URLResponse)
    do {
      exchange = try await Self.session.data(for: request)
    } catch {
      throw ResponsesClient.map(error)
    }
    let (data, response) = exchange
    guard let http = response as? HTTPURLResponse else { throw ResponsesError.failed("No HTTP response") }
    guard (200..<300).contains(http.statusCode) else {
      throw ResponsesClient.httpError(status: http.statusCode, body: data, headers: http)
    }
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw ResponsesError.failed("Search returned an unreadable response.")
    }
    return Self.parse(json)
  }

  static func body(queries: [String], model: String, sessionID: String) -> [String: Any] {
    [
      "id": sessionID,
      "model": model,
      "commands": ["search_query": queries.map { ["q": $0] }],
      "settings": ["external_web_access": true],
      "max_output_tokens": 2_500,
    ]
  }

  static func parse(_ json: [String: Any]) -> DirectSearchResult {
    let output = json["output"] as? String ?? ""
    let hits = (json["results"] as? [[String: Any]] ?? []).compactMap { item -> DirectSearchHit? in
      guard let raw = item["url"] as? String, let url = URL(string: raw) else { return nil }
      let title = (item["title"] ?? item["name"]) as? String
      let snippet = (item["snippet"] ?? item["text"] ?? item["description"]) as? String
      return DirectSearchHit(url: url, title: title, snippet: snippet.map { String($0.prefix(280)) })
    }
    return DirectSearchResult(output: output, hits: hits)
  }
}

/// Incremental parser for the Responses server-sent event stream. Kept free of
/// networking so it can be unit tested with recorded streams.
struct ResponsesStreamParser {
  enum Event: Equatable {
    case firstOutput
    case webSearchStarted(String?)
    case webSearchFinished
  }

  private(set) var result = ResponsesResult()
  private(set) var isFinished = false
  private(set) var failureMessage: String?
  private var sawOutput = false
  private var textFromItems = ""

  mutating func consume(line: String) -> [Event] {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard trimmed.hasPrefix("data:") else { return [] }
    let payload = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
    if payload == "[DONE]" {
      finish()
      return []
    }
    guard let data = payload.data(using: .utf8),
          let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let type = event["type"] as? String else { return [] }
    return handle(type: type, event: event)
  }

  /// Parses a complete non-streaming JSON body (fallback).
  mutating func consume(body: [String: Any]) {
    if let output = body["output"] as? [[String: Any]] {
      for item in output { handleItem(item, done: true) }
    }
    if result.text.isEmpty, let text = body["output_text"] as? String { result.text = text }
    finish()
  }

  private mutating func handle(type: String, event: [String: Any]) -> [Event] {
    var events: [Event] = []
    switch type {
    case "response.output_text.delta":
      if let delta = event["delta"] as? String, !delta.isEmpty {
        if !sawOutput {
          sawOutput = true
          result.firstOutputAt = Date()
          events.append(.firstOutput)
        }
        result.text += delta
      }
    case "response.output_text.annotation.added":
      if let annotation = event["annotation"] as? [String: Any] { addAnnotation(annotation) }
    case "response.output_item.added":
      if let item = event["item"] as? [String: Any] {
        if item["type"] as? String == "web_search_call" {
          let query = (item["action"] as? [String: Any])?["query"] as? String
          events.append(.webSearchStarted(query))
        }
        handleItem(item, done: false)
      }
    case "response.web_search_call.in_progress", "response.web_search_call.searching":
      if !result.webSearches.contains(where: { $0.id == (event["item_id"] as? String) }) {
        events.append(.webSearchStarted(nil))
      }
    case "response.web_search_call.completed":
      events.append(.webSearchFinished)
    case "response.output_item.done":
      if let item = event["item"] as? [String: Any] {
        if item["type"] as? String == "web_search_call" { events.append(.webSearchFinished) }
        handleItem(item, done: true)
      }
    case "response.completed", "response.done":
      if let response = event["response"] as? [String: Any],
         let output = response["output"] as? [[String: Any]] {
        for item in output where (item["type"] as? String) != "message" || result.text.isEmpty {
          handleItem(item, done: true)
        }
      }
      finish()
    case "response.incomplete":
      let details = (event["response"] as? [String: Any])?["incomplete_details"] as? [String: Any]
      result.incompleteReason = details?["reason"] as? String ?? "incomplete"
      finish()
    case "response.failed":
      let error = (event["response"] as? [String: Any])?["error"] as? [String: Any]
      failureMessage = error?["message"] as? String ?? "The model request failed."
      finish()
    case "error":
      failureMessage = (event["message"] as? String)
        ?? ((event["error"] as? [String: Any])?["message"] as? String)
        ?? "The model request failed."
      finish()
    default:
      break
    }
    return events
  }

  private mutating func handleItem(_ item: [String: Any], done: Bool) {
    switch item["type"] as? String ?? "" {
    case "web_search_call":
      let id = item["id"] as? String ?? UUID().uuidString
      let action = item["action"] as? [String: Any]
      let query = action?["query"] as? String
        ?? (action?["queries"] as? [String])?.first
      var sources = (action?["sources"] as? [[String: Any]] ?? [])
        .compactMap { ($0["url"] as? String).flatMap(URL.init(string:)) }
      // `open_page` / `find_in_page` actions name the page the model read.
      if let opened = (action?["url"] as? String).flatMap(URL.init(string:)) {
        sources.append(opened)
      }
      if let index = result.webSearches.firstIndex(where: { $0.id == id }) {
        if let query { result.webSearches[index].query = query }
        result.webSearches[index].status = item["status"] as? String
        if !sources.isEmpty { result.webSearches[index].sourceURLs = sources }
      } else {
        result.webSearches.append(WebSearchCall(
          id: id, query: query, status: item["status"] as? String, sourceURLs: sources))
      }
    case "function_call":
      guard done, let name = item["name"] as? String else { return }
      let callID = item["call_id"] as? String ?? item["id"] as? String ?? UUID().uuidString
      guard !result.functionCalls.contains(where: { $0.callID == callID }) else { return }
      result.functionCalls.append(ModelFunctionCall(
        name: name, callID: callID, arguments: item["arguments"] as? String ?? "{}"))
    case "message":
      guard done else { return }
      let content = item["content"] as? [[String: Any]] ?? []
      for part in content {
        if let annotations = part["annotations"] as? [[String: Any]] {
          annotations.forEach { addAnnotation($0) }
        }
        if result.text.isEmpty, part["type"] as? String == "output_text", let text = part["text"] as? String {
          textFromItems += text
        }
      }
    default:
      break
    }
  }

  private mutating func addAnnotation(_ annotation: [String: Any]) {
    guard annotation["type"] as? String == "url_citation",
          let raw = annotation["url"] as? String,
          let url = URL(string: raw) else { return }
    let title = annotation["title"] as? String
    if !result.citations.contains(where: { $0.url == url }) {
      result.citations.append(URLCitation(url: url, title: title))
    }
  }

  private mutating func finish() {
    if result.text.isEmpty && !textFromItems.isEmpty {
      result.text = textFromItems
      if result.firstOutputAt == nil { result.firstOutputAt = Date() }
    }
    if result.completedAt == nil { result.completedAt = Date() }
    isFinished = true
  }
}
