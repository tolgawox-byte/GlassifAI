import Foundation

/// One model as described by the Codex `/models` endpoint for the signed-in
/// ChatGPT account. Only fields the service actually returned are used;
/// missing ones fall back to Codex's own defaults.
struct CatalogModel: Identifiable, Equatable, Codable {
  let slug: String
  let displayName: String
  let summary: String?
  /// "list" (shown in Codex's picker), "hide" or "none".
  let visibility: String
  /// Codex sorts by this; the first listed model is its default.
  let priority: Int
  let supportedInAPI: Bool
  let inputModalities: [String]
  let reasoningLevels: [String]
  let defaultReasoningLevel: String?
  let supportsVerbosity: Bool
  let webSearchToolType: String?
  let supportsImageDetailOriginal: Bool
  let usesResponsesLite: Bool
  let contextWindow: Int?
  let specialty: String?
  let upgradeTo: String?

  var id: String { slug }
  var acceptsImages: Bool { inputModalities.contains("image") }
  var isListed: Bool { visibility == "list" }
  var supportsReasoning: Bool { !reasoningLevels.isEmpty }

  /// Matches the "GPT-6 Astra" family by slug or display name.
  var isGPT6Astra: Bool {
    let text = "\(slug) \(displayName)".lowercased()
    return text.contains("astra") || text.contains("gpt-6") || text.contains("gpt6")
  }

  /// Short capability tags for Settings and Diagnostics.
  var capabilityTags: [String] {
    var tags: [String] = []
    tags.append(acceptsImages ? "vision" : "text only")
    if supportsReasoning { tags.append("reasoning \(reasoningLevels.joined(separator: "/"))") }
    if let webSearchToolType { tags.append("web \(webSearchToolType)") }
    if supportsImageDetailOriginal { tags.append("original-res images") }
    if usesResponsesLite { tags.append("responses-lite") }
    if !isListed { tags.append(visibility) }
    if let contextWindow { tags.append("\(contextWindow / 1_000)k ctx") }
    return tags
  }

  /// A model known only by name (older response shape).
  static func slugOnly(_ slug: String, priority: Int) -> CatalogModel {
    CatalogModel(
      slug: slug, displayName: slug, summary: nil, visibility: "list", priority: priority,
      supportedInAPI: true, inputModalities: ["text", "image"], reasoningLevels: [],
      defaultReasoningLevel: nil, supportsVerbosity: true, webSearchToolType: nil,
      supportsImageDetailOriginal: false, usesResponsesLite: false, contextWindow: nil,
      specialty: nil, upgradeTo: nil)
  }

  static func parse(_ object: [String: Any], fallbackPriority: Int) -> CatalogModel? {
    guard let slug = (object["slug"] ?? object["id"]) as? String, !slug.isEmpty else { return nil }
    func bool(_ key: String, _ fallback: Bool) -> Bool {
      (object[key] as? Bool) ?? (object[key] as? NSNumber)?.boolValue ?? fallback
    }
    func int(_ key: String) -> Int? {
      (object[key] as? Int) ?? (object[key] as? NSNumber)?.intValue
    }
    let levels: [String] = (object["supported_reasoning_levels"] as? [Any] ?? []).compactMap { item in
      (item as? String) ?? (item as? [String: Any])?["effort"] as? String
    }
    let modalities = (object["input_modalities"] as? [String]) ?? ["text", "image"]
    return CatalogModel(
      slug: slug,
      displayName: (object["display_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? slug,
      summary: object["description"] as? String,
      visibility: (object["visibility"] as? String) ?? "list",
      priority: int("priority") ?? fallbackPriority,
      supportedInAPI: bool("supported_in_api", true),
      inputModalities: modalities,
      reasoningLevels: levels,
      defaultReasoningLevel: object["default_reasoning_level"] as? String,
      supportsVerbosity: bool("support_verbosity", true),
      webSearchToolType: object["web_search_tool_type"] as? String,
      supportsImageDetailOriginal: bool("supports_image_detail_original", false),
      usesResponsesLite: bool("use_responses_lite", false),
      contextWindow: int("context_window"),
      specialty: object["model_specialty"] as? String,
      upgradeTo: (object["upgrade"] as? [String: Any])?["model"] as? String)
  }

  /// Parses the `/models` response (object with `models`/`data`/`items`, or a
  /// bare array of objects or names), de-duplicated and sorted by priority.
  static func parseList(_ value: Any) -> [CatalogModel] {
    let root = value as? [String: Any]
    let items = (root?["models"] ?? root?["data"] ?? root?["items"] ?? value) as? [Any] ?? []
    var seen = Set<String>()
    var models: [CatalogModel] = []
    for (index, item) in items.enumerated() {
      let model: CatalogModel?
      if let name = item as? String, !name.isEmpty {
        model = .slugOnly(name, priority: 1_000 + index)
      } else if let object = item as? [String: Any] {
        model = parse(object, fallbackPriority: 1_000 + index)
      } else {
        model = nil
      }
      if let model, seen.insert(model.slug).inserted { models.append(model) }
    }
    return models.enumerated()
      .sorted { ($0.element.priority, $0.offset) < ($1.element.priority, $1.offset) }
      .map(\.element)
  }
}

/// What a model is used for. Each role can be left on Automatic or pinned
/// to one of the models the account actually exposes.
enum ModelRole: String, CaseIterable, Identifiable {
  case general
  case vision
  case reasoning
  case web

  var id: String { rawValue }

  var label: String {
    switch self {
    case .general: "General"
    case .vision: "Vision"
    case .reasoning: "Deep reasoning"
    case .web: "Web and tools"
    }
  }

  var overrideKey: String { "autoloom.model.role.\(rawValue)" }

  static func role(for kind: AssistantTaskKind?, needsHostedWebSearch: Bool) -> ModelRole {
    if needsHostedWebSearch { return .web }
    switch kind {
    case .vision, .visionPlusWeb: return .vision
    case .deepReasoning: return .reasoning
    case .webSearch: return .web
    default: return .general
    }
  }

  /// Model pinned in Settings for this role, if any.
  var override: String? {
    let value = UserDefaults.standard.string(forKey: overrideKey)?.trimmingCharacters(in: .whitespaces) ?? ""
    return value.isEmpty ? nil : value
  }
}

/// Picks models by role from the account's catalog.
enum ModelRouting {
  /// Automatic choice for a role (ignores Settings overrides).
  static func automaticModel(
    for role: ModelRole,
    catalog: [CatalogModel],
    needsImages: Bool,
    excluded: Set<String> = []
  ) -> CatalogModel? {
    let usable = catalog.filter { !excluded.contains($0.slug) }
    let listed = usable.filter(\.isListed)
    let pool = listed.isEmpty ? usable : listed
    let imageOK: (CatalogModel) -> Bool = { !needsImages || $0.acceptsImages }
    switch role {
    case .vision:
      return pool.first(where: \.acceptsImages)
    case .web:
      // Hosted tools are sent in the classic Responses shape, which Codex
      // uses for models that are not "responses-lite".
      return pool.first { !$0.usesResponsesLite && imageOK($0) } ?? pool.first(where: imageOK)
    case .general, .reasoning:
      return pool.first(where: imageOK)
    }
  }

  /// Reasoning effort the model supports: the desired level, else the
  /// nearest level above it, else the highest below. Unknown support lists
  /// keep the desired level (the original behaviour).
  static func effort(_ desired: String, supported: [String]) -> String {
    guard !supported.isEmpty, !supported.contains(desired) else { return desired }
    let order = ["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"]
    guard let target = order.firstIndex(of: desired) else { return supported.first ?? desired }
    let ranked = supported.compactMap { level in order.firstIndex(of: level).map { (level, $0) } }
    if let above = ranked.filter({ $0.1 >= target }).min(by: { $0.1 < $1.1 }) { return above.0 }
    return ranked.max(by: { $0.1 < $1.1 })?.0 ?? supported.first ?? desired
  }

  /// Status line for the GPT-6 Astra family on this connection.
  static func gpt6AstraStatus(catalog: [CatalogModel], health: [String: ModelHealth.Entry]) -> String {
    guard !catalog.isEmpty else { return "Unknown — the model list has not loaded" }
    guard let model = catalog.first(where: \.isGPT6Astra) else {
      return "Not exposed to the AutoLoom connection (it may still be available in the ChatGPT app)"
    }
    var text = "Exposed as \(model.slug) (\(model.capabilityTags.joined(separator: ", ")))"
    if let entry = health[model.slug] {
      text += entry.working ? " — worked \(entry.at.formatted(date: .abbreviated, time: .shortened))" : " — failed: \(entry.message ?? "error")"
    } else {
      text += " — not used yet"
    }
    return text
  }
}

/// Which models actually answered on this connection. A model is "working"
/// only after a real request succeeded; a model that fails is skipped by
/// Automatic for the rest of the app run.
@MainActor
final class ModelHealth: ObservableObject {
  static let shared = ModelHealth()
  static let defaultsKey = "autoloom.model.health"

  struct Entry: Codable, Equatable {
    var working: Bool
    var at: Date
    var message: String?
  }

  @Published private(set) var entries: [String: Entry] = [:]
  private(set) var failedThisRun = Set<String>()

  private init() {
    if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
       let stored = try? JSONDecoder().decode([String: Entry].self, from: data) {
      entries = stored
    }
  }

  func recordSuccess(_ slug: String) {
    failedThisRun.remove(slug)
    entries[slug] = Entry(working: true, at: Date(), message: nil)
    save()
  }

  func recordFailure(_ slug: String, message: String) {
    failedThisRun.insert(slug)
    entries[slug] = Entry(working: false, at: Date(), message: LogSanitizer.sanitize(message, limit: 140))
    save()
  }

  func clear() {
    entries = [:]
    failedThisRun = []
    UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
  }

  /// A request failure that points at the model rather than the input.
  nonisolated static func looksLikeModelProblem(_ message: String) -> Bool {
    let text = message.lowercased()
    return ["model", "not supported", "unsupported", "does not exist", "not found", "not available", "access"]
      .contains { text.contains($0) }
  }

  private func save() {
    if let data = try? JSONEncoder().encode(entries) {
      UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }
  }
}
