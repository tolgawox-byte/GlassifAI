import XCTest

@testable import GlassifAI

/// Model capability discovery and task-specific model routing.
final class AutoLoomModelTests: XCTestCase {

  /// Shape of the Codex `/models` response (fields as in the vendored Codex
  /// catalog), plus a hypothetical GPT-6 Astra entry.
  private let sampleResponse: [String: Any] = [
    "models": [
      ["slug": "gpt-5.5", "display_name": "GPT-5.5", "priority": 7, "visibility": "list",
       "input_modalities": ["text", "image"], "use_responses_lite": false, "support_verbosity": true,
       "supported_reasoning_levels": [["effort": "low"], ["effort": "medium"], ["effort": "high"]],
       "web_search_tool_type": "text_and_image", "supports_image_detail_original": true, "context_window": 272_000],
      ["slug": "gpt-5.6-sol", "display_name": "GPT-5.6 Sol", "priority": 1, "visibility": "list",
       "input_modalities": ["text", "image"], "use_responses_lite": true, "support_verbosity": true,
       "supported_reasoning_levels": [["effort": "low"], ["effort": "medium"], ["effort": "xhigh"]]],
      ["slug": "gpt-5.4-mini", "priority": 23, "visibility": "hide", "input_modalities": ["text"]],
      ["slug": "text-only-top", "priority": 0, "visibility": "list", "input_modalities": ["text"],
       "use_responses_lite": true, "support_verbosity": false,
       "supported_reasoning_levels": [["effort": "medium"], ["effort": "high"]]],
    ] as [[String: Any]],
  ]

  private var catalog: [CatalogModel] { CatalogModel.parseList(sampleResponse) }

  override func setUp() {
    super.setUp()
    for role in ModelRole.allCases { UserDefaults.standard.removeObject(forKey: role.overrideKey) }
    UserDefaults.standard.removeObject(forKey: ModelSelector.overrideKey)
  }

  override func tearDown() {
    for role in ModelRole.allCases { UserDefaults.standard.removeObject(forKey: role.overrideKey) }
    super.tearDown()
  }

  func testCatalogParsesCapabilitiesAndSortsByPriority() {
    let models = catalog
    XCTAssertEqual(models.map(\.slug), ["text-only-top", "gpt-5.6-sol", "gpt-5.5", "gpt-5.4-mini"])
    let sol = models.first { $0.slug == "gpt-5.6-sol" }
    XCTAssertEqual(sol?.acceptsImages, true)
    XCTAssertEqual(sol?.usesResponsesLite, true)
    XCTAssertEqual(sol?.reasoningLevels, ["low", "medium", "xhigh"])
    XCTAssertEqual(models.first { $0.slug == "gpt-5.5" }?.webSearchToolType, "text_and_image")
    XCTAssertEqual(models.first { $0.slug == "gpt-5.4-mini" }?.isListed, false)
    XCTAssertEqual(models.first?.supportsVerbosity, false)
    // Older response shape: names only.
    XCTAssertEqual(CatalogModel.parseList(["a", "b", "a"]).map(\.slug), ["a", "b"])
    XCTAssertTrue(CatalogModel.parseList(["models": "nonsense"]).isEmpty)
  }

  func testAutomaticRoutingPicksTheRightModelPerJob() {
    let models = catalog
    let slugs = models.map(\.slug)
    XCTAssertEqual(ModelSelector.model(for: .generalChat, available: slugs, catalog: models), "text-only-top",
                   "general follows the service's own order")
    XCTAssertEqual(ModelSelector.model(for: .vision, available: slugs, catalog: models, needsImages: true), "gpt-5.6-sol",
                   "vision needs a model that accepts images")
    XCTAssertEqual(ModelSelector.model(for: .webSearch, available: slugs, needsHostedWebSearch: true, catalog: models), "gpt-5.5",
                   "hosted web tools use a classic (non-lite) model")
    XCTAssertEqual(ModelSelector.model(for: .deepReasoning, available: slugs, catalog: models), "text-only-top")
    XCTAssertEqual(
      ModelSelector.model(for: .vision, available: slugs, catalog: models, needsImages: true, excluded: ["gpt-5.6-sol"]),
      "gpt-5.5", "a model that failed this session is skipped")
  }

  func testRoleOverrideWinsOnlyWhenTheModelIsExposed() {
    let models = catalog
    let slugs = models.map(\.slug)
    UserDefaults.standard.set("gpt-5.5", forKey: ModelRole.vision.overrideKey)
    XCTAssertEqual(ModelSelector.model(for: .vision, available: slugs, catalog: models, needsImages: true), "gpt-5.5")
    UserDefaults.standard.set("gpt-6-astra", forKey: ModelRole.vision.overrideKey)
    XCTAssertEqual(ModelSelector.model(for: .vision, available: slugs, catalog: models, needsImages: true), "gpt-5.6-sol",
                   "a pinned model the account does not expose is never used")
  }

  func testGPT6AstraIsUsedOnlyWhenExposed() {
    XCTAssertTrue(ModelRouting.gpt6AstraStatus(catalog: catalog, health: [:]).hasPrefix("Not exposed"))
    XCTAssertTrue(ModelRouting.gpt6AstraStatus(catalog: [], health: [:]).hasPrefix("Unknown"))
    var response = sampleResponse
    var list = response["models"] as! [[String: Any]]
    list.append(["slug": "gpt-6-astra", "display_name": "GPT-6 Astra", "priority": -1, "visibility": "list",
                 "input_modalities": ["text", "image"], "use_responses_lite": false])
    response["models"] = list
    let withAstra = CatalogModel.parseList(response)
    let status = ModelRouting.gpt6AstraStatus(catalog: withAstra, health: [:])
    XCTAssertTrue(status.hasPrefix("Exposed as gpt-6-astra"), status)
    XCTAssertEqual(
      ModelSelector.model(for: .vision, available: withAstra.map(\.slug), catalog: withAstra, needsImages: true),
      "gpt-6-astra", "an exposed, image-capable top model is used automatically")
  }

  func testReasoningEffortIsMappedToSupportedLevels() {
    XCTAssertEqual(ModelRouting.effort("low", supported: ["low", "medium"]), "low")
    XCTAssertEqual(ModelRouting.effort("low", supported: ["medium", "high"]), "medium")
    XCTAssertEqual(ModelRouting.effort("xhigh", supported: ["low", "medium"]), "medium")
    XCTAssertEqual(ModelRouting.effort("medium", supported: []), "medium", "unknown support keeps the original request")
  }

  func testRequestOmitsUnsupportedParameters() {
    var request = ResponsesClient.Request(model: "m", instructions: "i", input: [])
    request.verbosity = nil
    request.reasoningEffort = nil
    let body = ResponsesClient.body(for: request)
    XCTAssertNil(body["text"])
    XCTAssertNil(body["reasoning"])
    request.jsonSchema = (name: "s", schema: ["type": "object"])
    let withSchema = ResponsesClient.body(for: request)
    XCTAssertNotNil((withSchema["text"] as? [String: Any])?["format"])
    XCTAssertNil((withSchema["text"] as? [String: Any])?["verbosity"])
  }

  func testModelProblemDetection() {
    XCTAssertTrue(ModelHealth.looksLikeModelProblem("The model `gpt-6-astra` does not exist"))
    XCTAssertTrue(ModelHealth.looksLikeModelProblem("Unsupported value for reasoning.effort"))
    XCTAssertFalse(ModelHealth.looksLikeModelProblem("Invalid base64 image"))
  }

  func testLegacySelectionWithoutMetadataIsUnchanged() {
    let models = ["gpt-5.4", "gpt-5.6-sol", "gpt-5.5"]
    XCTAssertEqual(ModelSelector.model(for: .vision, available: models), "gpt-5.6-sol")
    XCTAssertEqual(ModelSelector.model(for: .webSearch, available: models, needsHostedWebSearch: true), "gpt-5.5")
    XCTAssertEqual(ModelSelector.realtimeModel, "gpt-live-1-codex")
  }
}
