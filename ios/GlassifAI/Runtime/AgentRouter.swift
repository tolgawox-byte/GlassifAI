import Foundation

/// Reads what a request needs from the user's words and the voice model's
/// route (LEVEL 1 commands are already local). Turkish and English.
enum RequestAnalyzer {
  static func analyze(_ text: String, kind: AssistantTaskKind?, localCommand: Bool = false) -> RequirementProfile {
    let folded = " " + MemorySearch.fold(text)
      .replacingOccurrences(of: "'", with: "")
      .replacingOccurrences(of: "’", with: "")
      .components(separatedBy: CharacterSet.alphanumerics.inverted)
      .filter { !$0.isEmpty }
      .joined(separator: " ") + " "
    func has(_ terms: [String]) -> Bool {
      terms.contains { folded.contains(" " + $0) }
    }
    var profile = RequirementProfile()
    profile.needsDeviceAction = localCommand || kind == .authorizedAction
    profile.needsMemory = kind == .localMemory || kind == .visualMemory || has(memoryTerms)
    profile.needsExternalAgent = kind == .agent
    profile.needsVision = kind?.usesCamera == true || has(visionTerms)
    profile.needsLiveVideo = has(liveTerms)
    profile.needsWeb = kind?.usesWeb == true || has(webTerms)
    profile.needsCurrentInformation = profile.needsWeb
    profile.needsCode = has(codeTerms)
    profile.isDocument = has(documentTerms)
    profile.needsLongContext = profile.isDocument && (has(["pdf", "sayfalik", "pages", "page"]) || text.count > 4_000)
    profile.needsDeepReasoning = kind == .deepReasoning || has(reasoningTerms) || profile.needsCode
    profile.isTranslation = has(translationTerms)
    profile.isDealer = has(dealerTerms) || containsCarMake(text)
    profile.isPlanning = has(planningTerms)
    profile.researchFacets = profile.needsWeb ? facets(in: folded) : []

    if profile.needsDeviceAction || (profile.needsMemory && !profile.needsWeb && !profile.needsVision) {
      profile.privacy = .local
      profile.latency = .instant
    } else if profile.isDocument || profile.needsCode {
      profile.privacy = .minimal
      profile.latency = .patient
    } else if profile.needsWeb || profile.needsDeepReasoning {
      profile.latency = .patient
    }
    profile.intent = intent(for: profile)
    return profile
  }

  static func intent(for p: RequirementProfile) -> String {
    if p.needsDeviceAction { return "device_action" }
    if p.needsExternalAgent { return "external_agent" }
    if p.needsMemory && !p.needsWeb && !p.needsVision { return "memory" }
    if p.needsLiveVideo { return "live_vision" }
    if p.isTranslation && p.needsVision { return "translation" }
    if p.needsCode { return "coding" }
    if p.isDocument { return "document" }
    if p.isDealer && p.needsWeb { return "dealer_research" }
    if p.needsVision && p.needsWeb { return "vision_research" }
    if p.needsVision { return p.isDealer ? "dealer_vision" : "vision" }
    if p.needsWeb { return "research" }
    if p.needsDeepReasoning { return "reasoning" }
    if p.isPlanning { return "planning" }
    return "chat"
  }

  /// The role that does the main work.
  static func primaryRole(for p: RequirementProfile) -> AgentRole {
    if p.needsDeviceAction { return .deviceAction }
    if p.needsExternalAgent { return .external }
    if p.needsMemory && !p.needsWeb && !p.needsVision { return .memory }
    if p.needsLiveVideo { return .liveVision }
    if p.isTranslation && p.needsVision { return .translation }
    if p.needsCode { return .coding }
    if p.isDocument { return .document }
    if p.needsVision { return .vision }
    if p.needsWeb { return .research }
    if p.needsDeepReasoning { return .reasoning }
    if p.isPlanning { return .planning }
    return .chat
  }

  static let memoryTerms = [
    "gecen gun", "gecen hafta", "konusmustuk", "konustuk", "hatirliyor musun", "ne demistim", "ne soylemistim",
    "last time we", "we talked", "do you remember", "what did i say",
  ]
  static let visionTerms = ["ne goruyorum", "gordugum", "what am i looking", "what is this in front"]
  static let liveTerms = [
    "surekli takip", "takip et", "izlemeye devam", "bakmaya devam", "canli gorus", "keep watching", "keep looking",
    "continuously", "surekli bak",
  ]
  static let webTerms = [
    "hava durumu", "hava nasil", "haberler", "son haber", "son dakika", "gundem", "guncel", "fiyat", "kac para",
    "kaca ", "piyasa", "borsa", "doviz", "kur ", "mac skoru", "skor", "acik mi", "recall", "geri cagirma", "arastir",
    "internette", "webde", "weather", "news", "latest", "current price", "price", "market value", "stock market",
    "on the market", "stock", "score", "research", "look up", "search the web",
  ]
  static let codeTerms = [
    "kod ", "kodu", "kodda", "kodun", "kodum", "kodlar", "kodla", "hata veriyor", "hata aliyorum", "derleme",
    "derlenmiyor", "compile", "compiler", "exception", "stack trace", "stacktrace", "swiftui", "swift kod",
    "swift code", "swift dili", "in swift", "python", "javascript", "typescript", "kotlin", "sql", "regex", "bug ",
    "bugs ", "buggy", "crash", "xcode", "github", "script", "code ", "coding", "function", "fonksiyon",
    "null pointer", "segfault",
  ]
  static let documentTerms = [
    "belge", "dokuman", "pdf", "sozlesme", "rapor", "sayfalik", "makale", "kilavuz", "document", "contract",
    "report", "pages", "paper", "manual", "whitepaper",
  ]
  static let reasoningTerms = [
    "analiz", "detayli", "derinlemesine", "karsilastir", "kiyasla", "degerlendir", "strateji", "artilari",
    "eksileri", "analyze", "analyse", "in depth", "compare", "evaluate", "pros and cons", "strategy",
    "step by step", "adim adim",
  ]
  static let translationTerms = ["cevir", "tercume", "translate", "translation"]
  static let dealerTerms = [
    "arac", "araba", "otomobil", "vin", "sasi", "kilometre", "ilan", "bayi", "galeri", "vehicle", "car ", "dealer",
    "listing", "mileage", "odometer", "trade in", "trim",
  ]
  static let planningTerms = ["planla", "gunumu", "haftami", "ajanda", "plan my", "schedule", "organize", "organize et"]

  /// Research questions of one request, one per kind of fact.
  static let facetGroups: [(name: String, terms: [String])] = [
    ("price", ["fiyat", "piyasa", "deger", "kac para", "price", "market value", "value", "worth"]),
    ("recall", ["recall", "geri cagirma", "geri cagir"]),
    ("known issues", ["sorun", "ariza", "kronik", "problem", "issues", "reliability", "known problems"]),
    ("specifications", ["ozellik", "donanim", "teknik ozellik", "specs", "specifications", "features"]),
    ("reviews", ["yorum", "inceleme", "review"]),
    ("availability", ["stok", "nereden alinir", "nerede satiliyor", "where to buy", "availability", "in stock"]),
  ]

  static func facets(in folded: String) -> [String] {
    facetGroups.filter { group in group.terms.contains { folded.contains(" " + $0) } }.map(\.name)
  }

  static func containsCarMake(_ text: String) -> Bool {
    let words = Set(text.split(whereSeparator: { !$0.isLetter && $0 != "-" }).map { $0.lowercased() })
    return ["honda", "toyota", "ford", "bmw", "audi", "mercedes", "mercedes-benz", "volkswagen", "hyundai", "kia",
            "nissan", "tesla", "renault", "fiat", "peugeot", "opel", "chevrolet", "lexus", "mazda", "subaru", "volvo",
            "jeep", "togg", "dodge", "porsche", "skoda", "dacia", "citroen"].contains { words.contains($0) }
  }
}

/// Picks agents and providers for a request. Local jobs stay local; with
/// only ChatGPT connected everything runs as before (FAST on ChatGPT);
/// connected specialists take the jobs they do best; a team runs only when
/// several agents really add something (seeing and researching, or several
/// research questions on a research specialist). Never loops: every
/// provider appears once in a plan's fallbacks.
enum AgentRouter {
  static func plan(for profile: RequirementProfile, context: RoutingContext) -> AgentPlan {
    let role = RequestAnalyzer.primaryRole(for: profile)
    var tools: [String] = []
    if profile.needsVision { tools.append("camera") }
    if profile.needsWeb { tools.append("web search") }
    if profile.needsMemory { tools.append("memory") }
    if profile.needsDeviceAction { tools.append("native actions") }

    // 1. On the phone: iPhone actions and AutoLoom memory never need a cloud agent.
    if role.isLocalOnly {
      return AgentPlan(
        intent: profile.intent, requiredCapabilities: .localTools, strategy: .local,
        primary: AgentStep(role: role, provider: .local, purpose: role == .memory ? "search AutoLoom memory" : "native action"),
        tools: tools, privacyLevel: .local, timeout: 10, reason: "local tools")
    }
    if role == .external {
      let connected = context.available.contains(.openclaw)
      return AgentPlan(
        intent: profile.intent, requiredCapabilities: .externalTools, strategy: connected ? .specialist : .local,
        primary: AgentStep(role: .external, provider: connected ? .openclaw : .local, purpose: "your agent gateway"),
        tools: tools, requiresConfirmation: true, privacyLevel: .minimal, timeout: 120,
        reason: connected ? "OpenClaw gateway" : "no gateway connected")
    }
    // 2. Offline: the cloud cannot help; the phone's tools still work.
    guard context.online else {
      return AgentPlan(
        intent: profile.intent, requiredCapabilities: role.capability, strategy: .local,
        primary: AgentStep(role: role, provider: .local, purpose: "offline"), tools: tools, privacyLevel: .local,
        timeout: 5, reason: "offline")
    }

    let primaryCandidates = candidates(for: role, context: context)
    let primaryProvider = primaryCandidates.first ?? .chatgpt
    var plan = AgentPlan(
      intent: profile.intent, requiredCapabilities: role.capability,
      strategy: primaryProvider == .chatgpt ? .fast : .specialist,
      primary: AgentStep(role: role, provider: primaryProvider, purpose: purpose(for: role)),
      tools: tools, privacyLevel: profile.privacy, timeout: timeout(for: role, strategy: .fast),
      fallbacks: Array(primaryCandidates.dropFirst()),
      reason: primaryProvider == .chatgpt ? "default path" : "\(primaryProvider.rawValue) suits \(role.rawValue)")

    // 3. Teams, only when several agents add something.
    let researchCandidates = candidates(for: .research, context: context)
    let researcher = researchCandidates.first ?? .chatgpt
    let teamsAllowed = context.cost != .lowerCost && context.cost != .localFirst
    let facets = profile.researchFacets
    if profile.needsVision && profile.needsWeb && researcher != .chatgpt {
      // See first (the subject), then research it with the specialist.
      let vision = candidates(for: .vision, context: context)
      plan.strategy = .team
      plan.primary = AgentStep(role: .vision, provider: vision.first ?? .chatgpt, purpose: "identify what is in view")
      plan.secondary = researchSteps(facets: facets, provider: researcher, teamsAllowed: teamsAllowed)
      plan.parallel = plan.secondary.count > 1
      plan.fallbacks = Array(vision.dropFirst())
      plan.requiredCapabilities = [.vision, .web]
      plan.reason = "see, then research with \(researcher.rawValue)"
    } else if profile.needsWeb && facets.count >= 2 && teamsAllowed
                && (researcher != .chatgpt || context.cost == .bestQuality) {
      let steps = researchSteps(facets: facets, provider: researcher, teamsAllowed: true)
      plan.strategy = .team
      plan.primary = steps[0]
      plan.secondary = Array(steps.dropFirst())
      plan.parallel = true
      plan.fallbacks = Array(researchCandidates.dropFirst())
      plan.requiredCapabilities = .web
      plan.reason = "\(steps.count) research questions in parallel"
    }
    if plan.strategy == .team, context.cost == .bestQuality,
       let reasoner = candidates(for: .reasoning, context: context).first, reasoner != .local {
      // Best quality: a reasoning agent writes the fused answer.
      plan.secondary.append(AgentStep(role: .reasoning, provider: reasoner, purpose: "fuse the findings"))
    }
    plan.timeout = timeout(for: role, strategy: plan.strategy)
    return plan
  }

  private static func researchSteps(facets: [String], provider: ProviderID, teamsAllowed: Bool) -> [AgentStep] {
    guard teamsAllowed, facets.count >= 2 else {
      return [AgentStep(role: .research, provider: provider, purpose: facets.first ?? "research")]
    }
    return facets.prefix(4).map { AgentStep(role: .research, provider: provider, purpose: $0) }
  }

  static func purpose(for role: AgentRole) -> String {
    switch role {
    case .vision: "answer about what is in view"
    case .liveVision: "describe the view"
    case .research: "research"
    case .reasoning: "analyse"
    case .coding: "technical analysis"
    case .document: "read the document"
    case .translation: "translate"
    case .planning: "plan"
    default: "answer"
    }
  }

  /// FAST answers quickly; research and deep work may take longer.
  static func timeout(for role: AgentRole, strategy: ExecutionStrategy) -> TimeInterval {
    if strategy == .team { return 120 }
    switch role {
    case .research, .dealer: return 45
    case .reasoning, .coding, .document: return 90
    case .vision, .translation: return 40
    case .liveVision: return 20
    default: return 30
    }
  }

  /// Providers for a role, best first: the user's pin, then (in automatic
  /// mode) the preference for the cost setting, then ChatGPT as the
  /// compatible fallback. Only connected, healthy providers that can do the
  /// job; each once.
  static func candidates(for role: AgentRole, context: RoutingContext) -> [ProviderID] {
    if role.isLocalOnly { return [.local] }
    if role == .external { return context.available.contains(.openclaw) ? [.openclaw] : [] }
    var order: [ProviderID] = []
    if let pinned = context.overrides[role] { order.append(pinned) }
    if context.automatic { order += preference(for: role, cost: context.cost) }
    order.append(.chatgpt)
    var seen = Set<ProviderID>()
    return order.filter { provider in
      guard seen.insert(provider).inserted, context.available.contains(provider) else { return false }
      return provider == .chatgpt || context.has(provider, role.capability)
    }
  }

  static func preference(for role: AgentRole, cost: CostPreference) -> [ProviderID] {
    let specialists: [ProviderID]
    switch role {
    case .research, .dealer: specialists = [.perplexity, .gemini, .openrouter]
    case .reasoning: specialists = [.claude, .gemini, .openrouter]
    case .coding: specialists = [.claude, .openrouter, .gemini]
    case .document: specialists = [.claude, .gemini, .openrouter]
    case .liveVision: specialists = [.gemini, .openrouter]
    case .vision, .translation: specialists = [.gemini, .claude, .openrouter]
    case .chat, .planning: specialists = [.claude, .gemini, .openrouter]
    default: specialists = []
    }
    switch cost {
    case .lowerCost, .localFirst:
      // The ChatGPT account costs nothing extra: specialists only as fallbacks.
      return [.chatgpt] + specialists
    case .balanced, .bestQuality:
      switch role {
      // ChatGPT stays first for conversation and seeing (its vision path
      // has the high-detail reading pipeline); specialists lead their jobs.
      case .chat, .planning, .vision, .translation: return [.chatgpt] + specialists
      default: return specialists + [.chatgpt]
      }
    }
  }
}
