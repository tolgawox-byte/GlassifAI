import Foundation
import XCTest

@testable import GlassifAI

/// MCP skills: the protocol client, servers only from Settings, each tool's
/// risk, and a model's tool choice read strictly.
@MainActor
final class AutoLoomSkillsTests: XCTestCase {
  private func decide(_ text: String, _ tags: Set<String> = []) -> VoiceIntent? {
    VoiceActionIntentBridge.decide(text, context: AutoLoomActionCatalogTests.context(for: tags))?.intent
  }

  /// A tiny MCP server: JSON for initialize and tools/list, SSE for tools/call.
  private final class FakeServer {
    var requests: [[String: Any]] = []
    var sessionHeaders: [String?] = []

    func handle(_ request: URLRequest) -> (Data, URLResponse) {
      let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any] ?? [:]
      requests.append(body)
      sessionHeaders.append(request.value(forHTTPHeaderField: "Mcp-Session-Id"))
      let id = body["id"] as? Int ?? 0
      var headers = ["Content-Type": "application/json"]
      var reply: String
      switch body["method"] as? String {
      case "initialize":
        headers["Mcp-Session-Id"] = "abc123"
        reply = #"{"jsonrpc":"2.0","id":\#(id),"result":{"protocolVersion":"2025-06-18","capabilities":{"tools":{}},"serverInfo":{"name":"Fake"}}}"#
      case "tools/list":
        reply = #"{"jsonrpc":"2.0","id":\#(id),"result":{"tools":["#
          + #"{"name":"list_tasks","description":"Lists tasks","inputSchema":{"type":"object"},"annotations":{"readOnlyHint":true}},"#
          + #"{"name":"delete_page","description":"Deletes a page","inputSchema":{"type":"object","properties":{"id":{"type":"string"}}}}"#
          + "]}}"
      case "tools/call":
        headers["Content-Type"] = "text/event-stream"
        reply = "event: message\ndata: " + #"{"jsonrpc":"2.0","id":\#(id),"result":{"content":[{"type":"text","text":"3 tasks"}]}}"# + "\n\n"
      default:
        return (Data(), HTTPURLResponse(url: request.url!, statusCode: 202, httpVersion: nil, headerFields: nil)!)
      }
      return (Data(reply.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: headers)!)
    }
  }

  func testTheClientSpeaksMCP() async throws {
    let server = FakeServer()
    let client = MCPClient(endpoint: URL(string: "https://mcp.example.com/mcp")!, token: nil) { server.handle($0) }
    let name = try await client.initialize()
    XCTAssertEqual(name, "Fake")
    XCTAssertEqual(client.sessionID, "abc123")
    let tools = try await client.listTools()
    XCTAssertEqual(tools.map(\.name), ["list_tasks", "delete_page"])
    XCTAssertTrue(tools[0].readOnly)
    XCTAssertTrue(tools[1].destructive, "no annotations: may be destructive (MCP default)")
    let result = try await client.callTool("list_tasks", arguments: [:])
    XCTAssertEqual(result.text, "3 tasks")
    XCTAssertFalse(result.isError)
    XCTAssertEqual(server.requests.compactMap { $0["method"] as? String },
                   ["initialize", "notifications/initialized", "tools/list", "tools/call"])
    XCTAssertEqual(server.sessionHeaders.last, "abc123", "the session id is sent back")
  }

  func testRiskFollowsTheToolAndThePolicy() {
    let read = MCPTool(name: "a", title: nil, summary: "", inputSchema: "{}", readOnly: true, destructive: false)
    let write = MCPTool(name: "b", title: nil, summary: "", inputSchema: "{}", readOnly: false, destructive: false)
    let destroy = MCPTool(name: "c", title: nil, summary: "", inputSchema: "{}", readOnly: false, destructive: true)
    XCTAssertEqual(SkillRisk.risk(for: read, policy: .allowReadOnly), .safe)
    XCTAssertEqual(SkillRisk.risk(for: read, policy: .ask), .confirm)
    XCTAssertEqual(SkillRisk.risk(for: write, policy: .allowReadOnly), .confirm, "only read-only tools run unasked")
    XCTAssertEqual(SkillRisk.risk(for: destroy, policy: .ask), .strongConfirm)
    XCTAssertNil(SkillRisk.risk(for: read, policy: .block))

    var plan = DeviceActionPlan(kind: .skillCall)
    plan.skill = SkillCallRequest(serverID: UUID(), serverName: "N", host: "mcp.example.com", tool: "c", arguments: "{}", risk: .safe)
    XCTAssertEqual(plan.risk, .confirm, "a staged skill call is never less than a yes")
    plan.skill?.risk = .strongConfirm
    XCTAssertEqual(plan.risk, .strongConfirm)
    XCTAssertTrue(plan.summary.contains("mcp.example.com"), "the user sees which service receives it")
    XCTAssertFalse(DeviceActionKind.plannable.contains(.skillCall))
  }

  func testServersOnlyFromSettingsOverHTTPS() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("skills-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = SkillStore(directory: directory)
    XCTAssertNotNil(store.add(name: "Local", address: "http://192.168.1.5/mcp", token: nil), "plain http is refused")
    XCTAssertNil(store.add(name: "Notion", address: "https://mcp.notion.com/mcp", token: nil))
    XCTAssertEqual(store.servers.count, 1)
    XCTAssertEqual(store.server(named: "notion")?.host, "mcp.notion.com")
    XCTAssertTrue(store.enabledServers.isEmpty, "no tools read yet: not offered to the voice")
    let id = try XCTUnwrap(store.servers.first?.id)
    store.remove(id)
    XCTAssertTrue(SkillStore(directory: directory).servers.isEmpty)
  }

  func testChoiceAndPhrases() {
    let choice = AssistantOrchestrator.skillChoice(from: "Sure: {\"tool\": \"list_tasks\", \"arguments\": {\"day\": \"today\"}}")
    XCTAssertEqual(choice?.tool, "list_tasks")
    XCTAssertEqual(choice?.arguments, #"{"day":"today"}"#)
    XCTAssertNil(AssistantOrchestrator.skillChoice(from: #"{"tool": null, "reason": "no match"}"#))
    XCTAssertEqual(decide("Notion ile bugünkü görevlerimi listele", ["skill"]),
                   .skill(server: "Notion", request: "bugünkü görevlerimi listele"))
    XCTAssertEqual(decide("Ask Notion to list my tasks", ["skill"]), .skill(server: "Notion", request: "list my tasks"))
    XCTAssertNotEqual(decide("Notion ile bugünkü görevlerimi listele"), .skill(server: "Notion", request: "bugünkü görevlerimi listele"),
                      "no skill added: not a skill")
  }
}

/// The user's own Shortcuts: a tap on the phone runs them, never the camera
/// or the web.
@MainActor
final class AutoLoomShortcutTests: XCTestCase {
  func testShortcutsNeedTheUsersWordsAndATap() throws {
    let context = AutoLoomActionCatalogTests.context(for: [])
    XCTAssertEqual(VoiceActionIntentBridge.decide("Işıkları Aç kısayolunu çalıştır", context: context)?.intent, .runShortcut("Işıkları Aç"))
    XCTAssertEqual(VoiceActionIntentBridge.decide("Run the Good Night shortcut", context: context)?.intent, .runShortcut("Good Night"))
    let url = try XCTUnwrap(ShortcutLink.url(for: "Işıkları Aç"))
    XCTAssertTrue(ShortcutLink.isRunShortcut(url))
    XCTAssertEqual(ShortcutLink.name(in: url), "Işıkları Aç")
    XCTAssertFalse(URLSafety.isPublicWebURL(url))

    var plan = DeviceActionPlan(kind: .openURL)
    plan.url = url
    XCTAssertEqual(plan.risk, .strongConfirm, "a tap, never a spoken yes")
    XCTAssertTrue(plan.summary.contains("Işıkları Aç"))
    plan.afterUntrustedContent = true
    guard case .failure = DeviceActionParser.validate(plan, now: Date()) else {
      return XCTFail("a shortcut is never run from what the camera or the web said")
    }
  }
}
