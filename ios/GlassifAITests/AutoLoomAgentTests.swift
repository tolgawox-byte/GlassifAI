import XCTest

@testable import GlassifAI

@MainActor
final class AutoLoomAgentTests: XCTestCase {

  func testGatewayAddressPolicy() {
    XCTAssertNil(AgentGatewayPolicy.problem(with: URL(string: "https://my-mac.tail1234.ts.net")!))
    XCTAssertNil(AgentGatewayPolicy.problem(with: URL(string: "http://192.168.1.20:18789")!))
    XCTAssertNil(AgentGatewayPolicy.problem(with: URL(string: "http://100.101.102.103:18789")!), "Tailscale addresses")
    XCTAssertNil(AgentGatewayPolicy.problem(with: URL(string: "http://studio.local:18789")!))
    XCTAssertNotNil(AgentGatewayPolicy.problem(with: URL(string: "http://example.com:18789")!),
                    "the token must never travel in clear text over the internet")
    XCTAssertNotNil(AgentGatewayPolicy.problem(with: URL(string: "ftp://192.168.1.20")!))
    XCTAssertNotNil(AgentGatewayPolicy.problem(with: URL(string: "https://user:secret@example.com")!))
    XCTAssertNotNil(AgentGatewayPolicy.warning(for: URL(string: "https://agent.example.com")!),
                    "public https works but is flagged")
    XCTAssertNil(AgentGatewayPolicy.warning(for: URL(string: "https://my-mac.tail1234.ts.net")!))
  }

  func testRequestAndReplyShapes() {
    let body = AgentGatewayClient.requestBody(agent: "openclaw/default", prompt: "check my repo", sessionUser: "autoloom-1")
    XCTAssertEqual(body["model"] as? String, "openclaw/default")
    XCTAssertEqual(body["stream"] as? Bool, false)
    XCTAssertEqual(body["user"] as? String, "autoloom-1")
    let messages = body["messages"] as? [[String: Any]]
    XCTAssertEqual(messages?.last?["content"] as? String, "check my repo")
    XCTAssertEqual(
      AgentGatewayClient.replyText(from: ["choices": [["message": ["role": "assistant", "content": " 3 open PRs "]]]]),
      "3 open PRs")
    XCTAssertEqual(
      AgentGatewayClient.replyText(from: ["choices": [["message": ["content": [["type": "text", "text": "done"]]]]]]),
      "done")
    XCTAssertNil(AgentGatewayClient.replyText(from: ["error": ["message": "nope"]]))
  }

  func testAgentRequestsAreConfirmedAndDestructiveOnesNeedATap() {
    var plan = DeviceActionPlan(kind: .agentTask)
    plan.text = "check my GitHub repository for open pull requests"
    XCTAssertEqual(plan.risk, .save, "a spoken yes may confirm a harmless agent request")
    plan.text = "delete the old branches and deploy to production"
    XCTAssertEqual(plan.risk, .needsTap, "destructive agent requests need a tap")
  }

  func testPlannerCannotChooseTheAgent() {
    let schema = AssistantTools.actionSchema.schema
    let action = (schema["properties"] as? [String: Any])?["action"] as? [String: Any]
    let allowed = action?["enum"] as? [String] ?? []
    XCTAssertFalse(allowed.contains("agent_task"))
    if case .success = DeviceActionParser.parse(#"{"action":"agent_task","text":"x"}"#) {
      XCTFail("the planner output cannot route to the agent")
    }
  }

  func testWithoutAGatewayTheAssistantSaysSoWithoutNetwork() async {
    let defaults = UserDefaults.standard
    let wasEnabled = defaults.object(forKey: AgentGatewayConfig.enabledKey)
    defer { defaults.set(wasEnabled, forKey: AgentGatewayConfig.enabledKey) }
    defaults.set(false, forKey: AgentGatewayConfig.enabledKey)
    let orchestrator = AssistantOrchestrator.shared
    _ = orchestrator.beginVoiceSession()
    let delivered = expectation(description: "delivered")
    var reply = ""
    orchestrator.handleDelegation(handoffID: "test-agent-\(UUID())", text: "TASK: agent | QUERY: check my GitHub repository") { text in
      reply = text
      delivered.fulfill()
      return true
    }
    await fulfillment(of: [delivered], timeout: 5)
    XCTAssertTrue(reply.contains("No agent gateway is connected"), reply)
    orchestrator.endVoiceSession()
  }
}
