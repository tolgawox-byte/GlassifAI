import Foundation
import Network

/// AutoLoom's logical agents. A role is the job, not who does it: the
/// router gives each role to a connected provider (or the one pinned in
/// Settings), and whatever runs behind it, the user hears one assistant.
enum AgentRole: String, CaseIterable, Codable, Identifiable {
  case chat
  case vision
  case liveVision
  case research
  case reasoning
  case coding
  case deviceAction
  case memory
  case dealer
  case translation
  case document
  case planning
  case external

  var id: String { rawValue }

  var title: String {
    switch self {
    case .chat: L.t("Conversation", "Sohbet")
    case .vision: L.t("Vision", "Görme")
    case .liveVision: L.t("Live vision", "Canlı görüş")
    case .research: L.t("Research", "Araştırma")
    case .reasoning: L.t("Reasoning", "Akıl yürütme")
    case .coding: L.t("Coding", "Kod")
    case .deviceAction: L.t("Actions", "İşlemler")
    case .memory: L.t("Memory", "Hafıza")
    case .dealer: L.t("Dealer", "Bayi")
    case .translation: L.t("Translation", "Çeviri")
    case .document: L.t("Documents", "Belgeler")
    case .planning: L.t("Planning", "Planlama")
    case .external: L.t("External agent", "Harici ajan")
    }
  }

  var systemImage: String {
    switch self {
    case .chat: "bubble.left.and.bubble.right"
    case .vision: "eye"
    case .liveVision: "eye.circle"
    case .research: "globe"
    case .reasoning: "brain.head.profile"
    case .coding: "chevron.left.forwardslash.chevron.right"
    case .deviceAction: "iphone"
    case .memory: "brain"
    case .dealer: "car"
    case .translation: "character.bubble"
    case .document: "doc.text"
    case .planning: "calendar"
    case .external: "server.rack"
    }
  }

  /// What a provider must be able to do to take this role.
  var capability: ProviderCapabilities {
    switch self {
    case .chat, .planning: .text
    case .vision, .liveVision, .translation: .vision
    case .research: .web
    case .reasoning: .reasoning
    case .coding: .code
    case .document: .longContext
    case .deviceAction, .memory, .dealer: .localTools
    case .external: .externalTools
    }
  }

  /// Roles the user may pin to one provider (Settings → Intelligence).
  static let pinnable: [AgentRole] = [.chat, .vision, .liveVision, .research, .reasoning, .coding, .translation]

  /// Roles that never leave the phone: iPhone actions and AutoLoom memory.
  var isLocalOnly: Bool { self == .deviceAction || self == .memory }
}

/// What a provider or model can do (the capability matrix).
struct ProviderCapabilities: OptionSet, Codable, Hashable {
  let rawValue: Int

  init(rawValue: Int) { self.rawValue = rawValue }

  static let text = ProviderCapabilities(rawValue: 1 << 0)
  static let vision = ProviderCapabilities(rawValue: 1 << 1)
  static let liveVision = ProviderCapabilities(rawValue: 1 << 2)
  static let reasoning = ProviderCapabilities(rawValue: 1 << 3)
  static let web = ProviderCapabilities(rawValue: 1 << 4)
  static let tools = ProviderCapabilities(rawValue: 1 << 5)
  static let code = ProviderCapabilities(rawValue: 1 << 6)
  static let longContext = ProviderCapabilities(rawValue: 1 << 7)
  static let audio = ProviderCapabilities(rawValue: 1 << 8)
  /// Notes, memory, tasks, reminders, calendar, contacts, maps, Photos, OCR.
  static let localTools = ProviderCapabilities(rawValue: 1 << 9)
  /// Email, smart home, computer actions through the user's own gateway.
  static let externalTools = ProviderCapabilities(rawValue: 1 << 10)

  static let named: [(ProviderCapabilities, String)] = [
    (.text, "text"), (.vision, "vision"), (.liveVision, "liveVision"), (.reasoning, "reasoning"), (.web, "web"),
    (.tools, "tools"), (.code, "code"), (.longContext, "longContext"), (.audio, "audio"), (.localTools, "localTools"),
    (.externalTools, "externalTools"),
  ]

  var names: [String] { Self.named.filter { contains($0.0) }.map(\.1) }
}

enum ProviderAuthKind: String, Codable {
  case chatgptAccount
  case apiKey
  case gateway
  case builtIn

  var label: String {
    switch self {
    case .chatgptAccount: L.t("ChatGPT account sign-in", "ChatGPT hesabıyla giriş")
    case .apiKey: L.t("API key (kept in the Keychain)", "API anahtarı (Anahtar Zinciri'nde)")
    case .gateway: L.t("Your gateway address and token", "Kendi ağ geçidiniz ve anahtarı")
    case .builtIn: L.t("Built in", "Yerleşik")
    }
  }
}

/// Every provider AutoLoom can route to. Only ChatGPT and Local are needed;
/// the others are optional specialists the user connects.
enum ProviderID: String, CaseIterable, Codable, Identifiable {
  case chatgpt
  case claude
  case gemini
  case perplexity
  case openrouter
  case local
  case openclaw

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .chatgpt: "ChatGPT"
    case .claude: "Claude"
    case .gemini: "Gemini"
    case .perplexity: "Perplexity"
    case .openrouter: "OpenRouter"
    case .local: L.t("Local AI", "Yerel AI")
    case .openclaw: "OpenClaw"
    }
  }

  var systemImage: String {
    switch self {
    case .chatgpt: "bubble.left.and.text.bubble.right"
    case .claude: "text.book.closed"
    case .gemini: "sparkles"
    case .perplexity: "magnifyingglass.circle"
    case .openrouter: "arrow.triangle.branch"
    case .local: "iphone"
    case .openclaw: "server.rack"
    }
  }

  var authKind: ProviderAuthKind {
    switch self {
    case .chatgpt: .chatgptAccount
    case .claude, .gemini, .perplexity, .openrouter: .apiKey
    case .openclaw: .gateway
    case .local: .builtIn
    }
  }

  /// Calls are billed by the provider to the account behind the key.
  var mayIncurCost: Bool {
    switch self {
    case .claude, .gemini, .perplexity, .openrouter: true
    case .chatgpt, .local, .openclaw: false
    }
  }

  /// Specialist providers are optional; the app works without them.
  var isOptional: Bool { self != .chatgpt && self != .local }

  /// "Why connect?" for the provider card.
  var why: String {
    switch self {
    case .chatgpt:
      L.t("Your ChatGPT account: the live voice, conversation, vision and web answers.",
          "ChatGPT hesabınız: canlı ses, sohbet, görme ve web yanıtları.")
    case .claude:
      L.t("Better long-form reasoning, long documents, technical analysis and code.",
          "Uzun akıl yürütme, uzun belgeler, teknik analiz ve kodda daha güçlü.")
    case .gemini:
      L.t("Optional multimodal specialist: continuous visual understanding and translation.",
          "İsteğe bağlı çok kipli uzman: sürekli görsel anlama ve çeviri.")
    case .perplexity:
      L.t("Optional real-time web research: prices, markets, recalls, news, with sources.",
          "İsteğe bağlı gerçek zamanlı web araştırması: fiyat, piyasa, geri çağırma, haber; kaynaklı.")
    case .openrouter:
      L.t("Optional gateway to many models, for fallbacks and experiments.",
          "Birçok modele isteğe bağlı erişim; yedek ve deneme için.")
    case .local:
      L.t("Notes, memory, tasks, reminders, calendar, contacts, maps, Photos and OCR on this iPhone, even offline.",
          "Notlar, hafıza, görevler, hatırlatıcılar, takvim, kişiler, harita, Fotoğraflar ve OCR bu iPhone'da, çevrimdışı da.")
    case .openclaw:
      L.t("Optional: your own agent gateway for email, smart home and computer actions.",
          "İsteğe bağlı: e-posta, akıllı ev ve bilgisayar işlemleri için kendi ajan ağ geçidiniz.")
    }
  }

  /// What leaves the phone when this provider is used.
  var dataSent: String {
    switch self {
    case .chatgpt:
      L.t("Your request, a camera image when it needs to see, the few relevant memories and the recent conversation, to OpenAI.",
          "İsteğiniz, görmesi gerektiğinde kamera görüntüsü, ilgili birkaç anı ve son konuşma; OpenAI'ye.")
    case .claude, .gemini, .openrouter:
      L.t("Only the request it is chosen for: your words, a camera image if the job needs one, and a few relevant memories. Never your whole memory, contacts or notes.",
          "Yalnızca seçildiği istek: sözleriniz, iş gerektiriyorsa bir kamera görüntüsü ve ilgili birkaç anı. Asla tüm hafızanız, kişileriniz veya notlarınız değil.")
    case .perplexity:
      L.t("Only research questions (the words, and what the camera identified when relevant). No images, contacts or notes.",
          "Yalnızca araştırma soruları (sözler ve gerekirse kameranın tanıdığı şey). Görüntü, kişi veya not gönderilmez.")
    case .local:
      L.t("Nothing: it runs on this iPhone.", "Hiçbir şey: bu iPhone'da çalışır.")
    case .openclaw:
      L.t("The requests you address to your agent, to your own gateway.",
          "Ajanınıza yönelttiğiniz istekler, kendi ağ geçidinize.")
    }
  }

  var billing: String {
    switch self {
    case .chatgpt: L.t("Included in your ChatGPT plan; no API billing.", "ChatGPT planınıza dahil; API ücreti yok.")
    case .claude:
      L.t("Needs an Anthropic API key with credit. A Claude.ai subscription cannot be used here.",
          "Krediye sahip bir Anthropic API anahtarı gerekir. Claude.ai aboneliği burada kullanılamaz.")
    case .gemini:
      L.t("Needs a Google AI Studio API key. Free-tier limits apply; paid use is billed by Google.",
          "Google AI Studio API anahtarı gerekir. Ücretsiz katman sınırları geçerlidir; ücretli kullanımı Google faturalar.")
    case .perplexity:
      L.t("Needs a Perplexity API key with credit; each search is billed.",
          "Krediye sahip bir Perplexity API anahtarı gerekir; her arama ücretlendirilir.")
    case .openrouter:
      L.t("Needs an OpenRouter key with credit; each model has its own price.",
          "Krediye sahip bir OpenRouter anahtarı gerekir; her modelin fiyatı ayrıdır.")
    case .local: L.t("Free.", "Ücretsiz.")
    case .openclaw: L.t("Your own server.", "Kendi sunucunuz.")
    }
  }

  var usagePattern: String {
    switch self {
    case .chatgpt: L.t("Every conversation.", "Her konuşma.")
    case .claude:
      L.t("A few calls a day: only deep analysis, long documents and code.",
          "Günde birkaç çağrı: yalnızca derin analiz, uzun belgeler ve kod.")
    case .gemini:
      L.t("Vision requests you route to it, and Live Vision updates (about every 6 s while on).",
          "Ona yönlendirilen görme istekleri ve Canlı Görüş güncellemeleri (açıkken yaklaşık 6 sn'de bir).")
    case .perplexity: L.t("One call per research question.", "Araştırma sorusu başına bir çağrı.")
    case .openrouter: L.t("Only as a fallback or when pinned to a role.", "Yalnızca yedek olarak veya bir role atanınca.")
    case .local: L.t("Always.", "Her zaman.")
    case .openclaw: L.t("Only requests for your agent.", "Yalnızca ajanınıza yönelik istekler.")
    }
  }

  /// Where the user creates a key (opened in Safari by the user).
  var keyPage: URL? {
    switch self {
    case .claude: URL(string: "https://console.anthropic.com/settings/keys")
    case .gemini: URL(string: "https://aistudio.google.com/apikey")
    case .perplexity: URL(string: "https://www.perplexity.ai/account/api/keys")
    case .openrouter: URL(string: "https://openrouter.ai/keys")
    default: nil
    }
  }
}

/// How a request is carried out.
enum ExecutionStrategy: String, Codable, Equatable {
  /// On the phone only (notes, reminders, memory…); no cloud.
  case local = "LOCAL"
  /// One best agent on the default path (ChatGPT).
  case fast = "FAST"
  /// One specialist provider for the job.
  case specialist = "SPECIALIST"
  /// Several agents, results fused into one answer.
  case team = "TEAM"
}

enum PrivacyLevel: String, Codable, Equatable {
  /// Never leaves the phone.
  case local = "LOCAL"
  /// Leaves the phone with the minimum context for the job.
  case minimal = "MINIMAL"
  /// Usual cloud request (the words, relevant memories, recent context).
  case standard = "STANDARD"
}

enum LatencyNeed: String, Codable, Equatable {
  /// Answer at once: local work, simple chat.
  case instant
  case interactive
  /// Research and deep analysis may take longer.
  case patient
}

/// Settings → Intelligence → Quality / Cost.
enum CostPreference: String, CaseIterable, Identifiable, Codable {
  case balanced
  case bestQuality
  case lowerCost
  case localFirst

  static let defaultsKey = "autoloom.agents.cost"

  static var current: CostPreference {
    CostPreference(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .balanced
  }

  var id: String { rawValue }

  var label: String {
    switch self {
    case .balanced: L.t("Balanced", "Dengeli")
    case .bestQuality: L.t("Best quality", "En iyi kalite")
    case .lowerCost: L.t("Lower cost", "Daha düşük maliyet")
    case .localFirst: L.t("Local first", "Önce yerel")
    }
  }

  var detail: String {
    switch self {
    case .balanced:
      L.t("Specialists for the jobs they do best; your ChatGPT account for the rest.",
          "Uzmanlar en iyi yaptıkları işlerde; gerisi ChatGPT hesabınızla.")
    case .bestQuality:
      L.t("Specialists and teams more often, never duplicate calls.",
          "Uzmanlar ve ekipler daha sık; asla gereksiz tekrar çağrı yok.")
    case .lowerCost:
      L.t("Your ChatGPT account and the phone first; one provider per request, few team calls.",
          "Önce ChatGPT hesabınız ve telefon; istek başına tek sağlayıcı, az ekip çağrısı.")
    case .localFirst:
      L.t("On the phone whenever possible; the cloud only when needed.",
          "Mümkün olduğunca telefonda; bulut yalnızca gerektiğinde.")
    }
  }
}

/// What a request needs, read from the user's words and the voice model's
/// route. Only the user's words and the route are read, never content the
/// camera or the web brought in.
struct RequirementProfile: Equatable {
  var intent = "chat"
  var needsVision = false
  var needsLiveVideo = false
  var needsWeb = false
  var needsCurrentInformation = false
  var needsDeepReasoning = false
  var needsCode = false
  var needsDeviceAction = false
  var needsMemory = false
  var needsLongContext = false
  var isDealer = false
  var isTranslation = false
  var isDocument = false
  var isPlanning = false
  var needsExternalAgent = false
  var privacy: PrivacyLevel = .standard
  var latency: LatencyNeed = .interactive
  /// Separate research questions in one request ("piyasa değeri, recall
  /// durumu ve bilinen sorunları").
  var researchFacets: [String] = []
}

/// One agent's part of a plan.
struct AgentStep: Equatable, Codable {
  let role: AgentRole
  let provider: ProviderID
  /// What this step does ("identify the vehicle", "recalls").
  let purpose: String
}

/// The router's structured decision for one request, for execution and
/// diagnostics. Never contains the request's content beyond its intent.
struct AgentPlan: Equatable {
  var intent: String
  var requiredCapabilities: ProviderCapabilities
  var strategy: ExecutionStrategy
  var primary: AgentStep
  var secondary: [AgentStep] = []
  var tools: [String] = []
  var parallel = false
  var requiresConfirmation = false
  var privacyLevel: PrivacyLevel = .standard
  var timeout: TimeInterval = 30
  /// Providers to try, in order, when the primary one fails.
  var fallbacks: [ProviderID] = []
  /// Why the router chose this (short, for diagnostics).
  var reason = ""

  var usesSpecialist: Bool { strategy == .specialist || strategy == .team }

  var allSteps: [AgentStep] { [primary] + secondary }

  /// "RESEARCH · TEAM · vision→chatgpt, research→perplexity ×2".
  var summary: String {
    let steps = allSteps.map { "\($0.role.rawValue)→\($0.provider.rawValue)" }.joined(separator: ", ")
    return "\(intent.uppercased()) · \(strategy.rawValue) · \(steps)"
      + (fallbacks.isEmpty ? "" : " · fallback \(fallbacks.map(\.rawValue).joined(separator: "→"))")
  }
}

/// What the router knows about the providers right now.
struct RoutingContext: Equatable {
  var connected: Set<ProviderID> = [.chatgpt, .local]
  /// Connected and not paused by the circuit breaker or a rate limit.
  var available: Set<ProviderID> = [.chatgpt, .local]
  var capabilities: [ProviderID: ProviderCapabilities] = [:]
  var overrides: [AgentRole: ProviderID] = [:]
  var cost: CostPreference = .balanced
  var automatic = true
  var online = true

  func has(_ provider: ProviderID, _ capability: ProviderCapabilities) -> Bool {
    available.contains(provider) && (capabilities[provider] ?? []).contains(capability)
  }
}

/// The current vehicle, product, person, place and document of the
/// conversation, so "o araç", "bunu", "ona" keep their meaning when the
/// request moves from one agent to another.
@MainActor
final class EntityContext: ObservableObject {
  static let shared = EntityContext()

  enum Kind: String, CaseIterable {
    case vehicle
    case product
    case person
    case place
    case document
  }

  struct Entity: Equatable {
    let kind: Kind
    let name: String
    let at: Date
  }

  /// Entities older than this no longer answer "bunu".
  static let lifetime: TimeInterval = 30 * 60

  @Published private(set) var entities: [Kind: Entity] = [:]

  func note(_ kind: Kind, _ name: String, at date: Date = Date()) {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count >= 2 else { return }
    entities[kind] = Entity(kind: kind, name: String(trimmed.prefix(120)), at: date)
  }

  func current(_ kind: Kind, now: Date = Date()) -> Entity? {
    guard let entity = entities[kind], now.timeIntervalSince(entity.at) < Self.lifetime else { return nil }
    return entity
  }

  /// "Current vehicle: 2019 Honda Civic. Current place: Kadıköy." for a
  /// provider's context, or nil.
  func contextLine(now: Date = Date()) -> String? {
    let parts = Kind.allCases.compactMap { kind -> String? in
      current(kind, now: now).map { "Current \(kind.rawValue): \($0.name)." }
    }
    return parts.isEmpty ? nil : parts.joined(separator: " ")
  }

  /// A vehicle named in an answer about what the user sees becomes the
  /// current vehicle ("Bu bir 2019 Honda Civic." → vehicle).
  func learn(fromAnswer text: String, role: AgentRole) {
    guard role == .vision || role == .dealer || role == .research else { return }
    if let vehicle = Self.vehicleMention(in: text) { note(.vehicle, vehicle) }
  }

  func reset() { entities.removeAll() }

  static let carMakes: [String] = [
    "Acura", "Alfa Romeo", "Audi", "BMW", "Buick", "Cadillac", "Chevrolet", "Chrysler", "Citroën", "Citroen", "Dacia",
    "Dodge", "Fiat", "Ford", "Genesis", "GMC", "Honda", "Hyundai", "Infiniti", "Jaguar", "Jeep", "Kia", "Land Rover",
    "Lexus", "Lincoln", "Mazda", "Mercedes-Benz", "Mercedes", "Mini", "Mitsubishi", "Nissan", "Opel", "Peugeot",
    "Porsche", "Ram", "Renault", "Seat", "Škoda", "Skoda", "Subaru", "Suzuki", "Tesla", "Togg", "Toyota", "Volkswagen",
    "VW", "Volvo",
  ]

  /// "2019 Honda Civic": a make with up to two following capitalised words
  /// (or numbers) in the same sentence, and the year before it if any.
  static func vehicleMention(in text: String) -> String? {
    var words: [String] = []
    var endsSentence: [Bool] = []
    for token in text.replacingOccurrences(of: "\n", with: ". ").split(separator: " ") {
      let word = token.trimmingCharacters(in: .punctuationCharacters)
      guard !word.isEmpty else { continue }
      words.append(word)
      endsSentence.append(token.last.map { ".!?".contains($0) } ?? false)
    }
    for index in words.indices {
      guard let make = make(at: index, in: words) else { continue }
      var parts: [String] = []
      if index > 0, !endsSentence[index - 1], words[index - 1].count == 4, let year = Int(words[index - 1]),
         (1950...2100).contains(year) {
        parts.append(words[index - 1])
      }
      parts.append(make)
      var position = index + make.split(separator: " ").count
      let limit = min(position + 2, words.count)
      while position < limit, !endsSentence[position - 1] {
        guard let first = words[position].first, first.isUppercase || first.isNumber else { break }
        parts.append(words[position])
        position += 1
      }
      return parts.joined(separator: " ")
    }
    return nil
  }

  private static func make(at index: Int, in words: [String]) -> String? {
    for make in carMakes {
      let count = make.split(separator: " ").count
      guard index + count <= words.count else { continue }
      let candidate = words[index..<(index + count)].joined(separator: " ")
      if candidate.caseInsensitiveCompare(make) == .orderedSame { return make }
    }
    return nil
  }
}

/// Whether the phone is online, so cloud agents are not tried offline.
final class NetworkStatus: @unchecked Sendable {
  static let shared = NetworkStatus()
  /// Posted (on the monitor's queue) when the connection comes or goes.
  static let changed = Notification.Name("AutoLoomNetworkStatusChanged")

  private let monitor = NWPathMonitor()
  private let queue = DispatchQueue(label: "com.autoloom.network")
  private let lock = NSLock()
  private var satisfied = true
  private var started = false

  var isOnline: Bool {
    lock.lock(); defer { lock.unlock() }
    return satisfied
  }

  func start() {
    lock.lock()
    guard !started else { lock.unlock(); return }
    started = true
    lock.unlock()
    monitor.pathUpdateHandler = { [weak self] path in
      guard let self else { return }
      self.lock.lock()
      let changed = self.satisfied != (path.status == .satisfied)
      self.satisfied = path.status == .satisfied
      self.lock.unlock()
      if changed { NotificationCenter.default.post(name: NetworkStatus.changed, object: nil) }
    }
    monitor.start(queue: queue)
  }
}
