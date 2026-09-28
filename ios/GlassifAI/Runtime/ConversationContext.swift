import Foundation

/// In-memory context for the current conversation. The realtime voice model
/// keeps its own conversation state; this copy exists so delegated tasks
/// (vision, web, reasoning) understand follow-ups such as "the cheaper one",
/// and so a reconnect can resume with a summary. Nothing here is persisted.
@MainActor
final class ConversationContext: ObservableObject {
  struct Turn: Equatable {
    enum Role: String { case user, assistant }
    let role: Role
    let text: String
    let at: Date
  }

  struct Fact: Equatable {
    let kind: AssistantTaskKind
    let request: String
    let result: String
    let sources: [String]
    let at: Date
  }

  @Published private(set) var turns: [Turn] = []
  @Published private(set) var facts: [Fact] = []
  @Published private(set) var summary = ""
  @Published private(set) var detectedLanguage: String?

  private let recentTurnLimit = 14
  private let factLimit = 8
  private let summaryCharacterLimit = 1_600

  func addTurn(_ role: Turn.Role, _ text: String) {
    let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleaned.isEmpty else { return }
    if let last = turns.last, last.role == role, last.text == cleaned { return }
    turns.append(Turn(role: role, text: String(cleaned.prefix(1_200)), at: Date()))
    if role == .user { detectedLanguage = Self.guessLanguage(cleaned) ?? detectedLanguage }
    compactIfNeeded()
  }

  func addFact(kind: AssistantTaskKind, request: String, result: String, sources: [String]) {
    facts.append(Fact(
      kind: kind,
      request: String(request.prefix(300)),
      result: String(result.prefix(700)),
      sources: Array(sources.prefix(5)),
      at: Date()))
    if facts.count > factLimit { facts.removeFirst(facts.count - factLimit) }
  }

  func reset() {
    turns.removeAll()
    facts.removeAll()
    summary = ""
    detectedLanguage = nil
  }

  /// Folds older turns into a bounded running summary. Extractive and local:
  /// no extra model call, so it never adds latency or cost.
  private func compactIfNeeded() {
    guard turns.count > recentTurnLimit else { return }
    let overflow = turns.prefix(turns.count - recentTurnLimit)
    turns.removeFirst(overflow.count)
    let folded = overflow.map { "\($0.role == .user ? "User" : "Assistant"): \($0.text.prefix(160))" }
    var combined = summary.isEmpty ? folded.joined(separator: "\n") : summary + "\n" + folded.joined(separator: "\n")
    if combined.count > summaryCharacterLimit {
      combined = "…" + String(combined.suffix(summaryCharacterLimit))
    }
    summary = combined
  }

  /// Context block handed to delegated tasks. Earlier task results that came
  /// from the web or the camera are wrapped as untrusted content.
  func promptContext(memory: [String]) -> String {
    var sections: [String] = []
    if !summary.isEmpty {
      sections.append("Earlier in this conversation (condensed):\n\(summary)")
    }
    if !turns.isEmpty {
      let recent = turns.suffix(recentTurnLimit)
        .map { "\($0.role == .user ? "User" : "Assistant"): \($0.text)" }
        .joined(separator: "\n")
      sections.append("Recent conversation (oldest first):\n\(recent)")
    }
    if !facts.isEmpty {
      let results = facts.map { fact in
        let sources = fact.sources.isEmpty ? "" : " (sources: \(fact.sources.joined(separator: ", ")))"
        return "- [\(fact.kind.displayName)] \(fact.request) → \(fact.result)\(sources)"
      }.joined(separator: "\n")
      sections.append(
        "Results of earlier tasks in this conversation:\n" +
        UntrustedContent.wrap(results, origin: "earlier task results"))
    }
    if !memory.isEmpty {
      sections.append(
        "Things the user explicitly asked this app to remember:\n" +
        memory.map { "- \($0)" }.joined(separator: "\n"))
    }
    return sections.joined(separator: "\n\n")
  }

  /// Short text used to seed a new voice session after a reconnect.
  func resumeSummary() -> String? {
    guard !turns.isEmpty || !summary.isEmpty else { return nil }
    let recent = turns.suffix(6)
      .map { "\($0.role == .user ? "User" : "Assistant"): \($0.text.prefix(200))" }
      .joined(separator: "\n")
    let text = [summary.isEmpty ? nil : String(summary.suffix(600)), recent.isEmpty ? nil : recent]
      .compactMap { $0 }
      .joined(separator: "\n")
    return "The voice connection was re-established. Conversation so far:\n" + text
  }

  /// Very small heuristic used only as a hint for response language.
  static func guessLanguage(_ text: String) -> String? {
    let lower = text.lowercased()
    if lower.contains(where: { "çğışöü".contains($0) }) { return "Turkish" }
    let turkishWords = [" bu ", " ne ", " bir ", " ve ", " mi ", " nasıl", "bugün", "şu ", "lütfen", "merhaba"]
    let padded = " \(lower) "
    if turkishWords.contains(where: { padded.contains($0) }) { return "Turkish" }
    if lower.range(of: "[a-z]", options: .regularExpression) != nil { return "English" }
    return nil
  }
}
