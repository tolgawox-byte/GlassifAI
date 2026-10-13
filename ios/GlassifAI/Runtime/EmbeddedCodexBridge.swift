import Foundation
import GlassifAICodex

struct EmbeddedCodexResult: Decodable {
  let ok: Bool
  let sdp: String?
  let callId: String?
  let error: String?
  /// The voice and model the bridge really sent (bridge 3 and later).
  var voice: String?
  var model: String?
  /// Set when the bridge replaced an unknown voice name.
  var voiceNote: String?
  /// What the service said about a failed start (bridge 4 and later).
  var errorDetails: RealtimeErrorDetails?

  enum CodingKeys: String, CodingKey {
    case ok
    case sdp
    case callId = "call_id"
    case error
    case voice
    case model
    case voiceNote = "voice_note"
    case errorDetails = "error_details"
  }
}

/// A failed call creation, as the service reported it: HTTP status, the
/// error's code, param, type and message, the request id, a body excerpt.
struct RealtimeErrorDetails: Decodable, Equatable {
  var kind: String?
  var status: Int?
  var code: String?
  var param: String?
  var type: String?
  var message: String?
  var requestId: String?
  var bodyExcerpt: String?

  enum CodingKeys: String, CodingKey {
    case kind
    case status
    case code
    case param
    case type
    case message
    case requestId = "request_id"
    case bodyExcerpt = "body_excerpt"
  }

  /// "HTTP 400 · invalid_value · param session.voice · request req_… — Invalid value for voice."
  var summary: String { line(includingRequestId: true) }

  /// The summary without the request id, for the message shown to the user
  /// (whose wording is matched against "401", "429" and so on).
  var headline: String { line(includingRequestId: false) }

  private func line(includingRequestId: Bool) -> String {
    var parts: [String] = []
    if let status { parts.append("HTTP \(status)") } else if let kind { parts.append(kind) }
    if let code { parts.append(code) }
    if let param { parts.append("param \(param)") }
    if includingRequestId, let requestId { parts.append("request \(requestId)") }
    var line = parts.joined(separator: " · ")
    if let message = message ?? bodyExcerpt { line += (line.isEmpty ? "" : " — ") + message }
    return LogSanitizer.sanitize(line, limit: 300)
  }

  /// Another start step with the same offer and token cannot fix these.
  var isUnfixableByRetrying: Bool {
    guard let status else { return false }
    return status == 429 || status >= 500
  }

  var isAuthenticationFailure: Bool { status == 401 || status == 403 }
}

/// Options for a realtime call. `nil` fields keep the baseline values that the
/// native bridge uses for the original entry point.
struct RealtimeStartOptions: Encodable {
  struct Item: Encodable {
    let role: String
    let text: String
  }

  var instructions: String?
  var voice: String?
  var model: String?
  var delegationAckFiller: Bool?
  var initialItems: [Item] = []

  enum CodingKeys: String, CodingKey {
    case instructions
    case voice
    case model
    case delegationAckFiller = "delegation_ack_filler"
    case initialItems = "initial_items"
  }
}

enum EmbeddedCodexBridge {
  /// Original baseline start (fixed instructions, voice and model).
  static func startRealtime(
    tokens: ChatGPTAuthTokens,
    sdp: String
  ) async throws -> EmbeddedCodexResult {
    guard let accountId = tokens.accountId else { throw EmbeddedCodexError.missingAccount }
    return try await Task.detached(priority: .userInitiated) {
      let pointer = tokens.accessToken.withCString { accessToken in
        accountId.withCString { account in
          sdp.withCString { offer in
            glassifai_codex_realtime_start(accessToken, account, offer)
          }
        }
      }
      guard let pointer else { throw EmbeddedCodexError.bridgeFailed }
      defer { glassifai_codex_string_free(pointer) }
      let data = Data(String(cString: pointer).utf8)
      return try JSONDecoder().decode(EmbeddedCodexResult.self, from: data)
    }.value
  }

  /// Start with AutoLoom instructions, voice and resume context.
  static func startRealtime(
    tokens: ChatGPTAuthTokens,
    sdp: String,
    options: RealtimeStartOptions
  ) async throws -> EmbeddedCodexResult {
    guard let accountId = tokens.accountId else { throw EmbeddedCodexError.missingAccount }
    let optionsJSON = String(data: try JSONEncoder().encode(options), encoding: .utf8) ?? "{}"
    return try await Task.detached(priority: .userInitiated) {
      let pointer = tokens.accessToken.withCString { accessToken in
        accountId.withCString { account in
          sdp.withCString { offer in
            optionsJSON.withCString { json in
              glassifai_codex_realtime_start_v2(accessToken, account, offer, json)
            }
          }
        }
      }
      guard let pointer else { throw EmbeddedCodexError.bridgeFailed }
      defer { glassifai_codex_string_free(pointer) }
      let data = Data(String(cString: pointer).utf8)
      return try JSONDecoder().decode(EmbeddedCodexResult.self, from: data)
    }.value
  }

  static func completeDelegation(handoffId: String, text: String) -> Bool {
    handoffId.withCString { handoff in
      text.withCString { content in
        glassifai_codex_delegation_complete(handoff, content)
      }
    }
  }

  /// Adds context to the live conversation; `speakable: false` informs the
  /// voice model without having it spoken.
  static func appendContext(_ text: String, speakable: Bool) -> Bool {
    text.withCString { content in
      glassifai_codex_context_append(content, speakable)
    }
  }

  static func nextSidebandEvent() -> [String: Any]? {
    guard let pointer = glassifai_codex_next_sideband_event() else { return nil }
    defer { glassifai_codex_string_free(pointer) }
    let data = Data(String(cString: pointer).utf8)
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
  }

  static func sidebandStatus() -> String {
    guard let pointer = glassifai_codex_sideband_status() else { return "status unavailable" }
    defer { glassifai_codex_string_free(pointer) }
    return String(cString: pointer)
  }

  static func bridgeVersion() -> String {
    guard let pointer = glassifai_codex_bridge_version() else { return "unknown" }
    defer { glassifai_codex_string_free(pointer) }
    return String(cString: pointer)
  }

  /// Terminal sideband states. Transient states such as "reconnecting" or a
  /// non-fatal "server error" keep the call alive.
  static func isSidebandTerminal(_ status: String) -> Bool {
    status.hasPrefix("ended")
  }

  static func closeRealtime() {
    glassifai_codex_realtime_close()
  }
}

private enum EmbeddedCodexError: LocalizedError {
  case missingAccount
  case bridgeFailed

  var errorDescription: String? {
    switch self {
    case .missingAccount: "The ChatGPT account identifier is missing."
    case .bridgeFailed: "The embedded Codex bridge could not start."
    }
  }
}
