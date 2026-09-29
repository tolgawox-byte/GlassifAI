import Foundation

/// Makes every provider's answer sound like AutoLoom: no provider
/// self-references, no reasoning traces, no stock openers; for speech, no
/// markdown, tables or URLs (the screen keeps the detail and the sources).
/// The persona itself is applied by the voice (see `JarvisStyle`).
enum ResponseNormalizer {
  /// Sentences that only talk about the model itself.
  static let selfReferences: [String] = [
    "as claude", "i'm claude", "i am claude", "as gemini", "i'm gemini", "i am gemini", "as an ai", "as a language model",
    "as an ai language model", "i am an ai", "i'm an ai", "ben claude", "ben gemini", "bir yapay zeka olarak",
    "bir dil modeli olarak", "perplexity olarak", "as perplexity", "i don't have personal", "my training data",
  ]

  /// Openers that add nothing to a spoken answer.
  static let openers: [String] = [
    "great question!", "good question!", "sure!", "sure,", "certainly!", "of course!", "absolutely!",
    "here's a summary:", "here is a summary:", "harika bir soru!", "güzel soru!",
  ]

  static func normalize(_ text: String) -> String {
    var result = removeReasoningTraces(text)
    // Provider brand mentions as the speaker ("Claude says", "Gemini'ye göre").
    for pattern in [
      #"(?i)\b(claude|gemini|perplexity|chatgpt|openrouter)\s+(says|thinks|suggests|found)\s*(that)?\s*"#,
      #"(?i)\b(claude|gemini|perplexity)'?(ye|ya|e|a)?\s+göre,?\s*"#,
      #"(?i)\baccording to (claude|gemini|perplexity|openrouter),?\s*"#,
    ] {
      result = result.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
    }
    // Only lines that talk about the model are split into sentences, so
    // code and lists stay exactly as written.
    result = result.components(separatedBy: "\n").map { line in
      guard isSelfReference(line) else { return line }
      return splitSentences(line).filter { !isSelfReference($0) }.joined(separator: " ")
    }.joined(separator: "\n")
    for opener in openers where result.lowercased().hasPrefix(opener) {
      result = String(result.dropFirst(opener.count))
    }
    result = result.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
    result = result.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
    let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let first = trimmed.first else { return "" }
    return first.uppercased() + trimmed.dropFirst()
  }

  static func isSelfReference(_ text: String) -> Bool {
    let lower = " " + text.lowercased()
    return selfReferences.contains { lower.contains(" " + $0) }
  }

  /// `<think>…</think>` blocks (reasoning models) are never shown or spoken.
  static func removeReasoningTraces(_ text: String) -> String {
    text.replacingOccurrences(of: #"(?s)<think>.*?</think>"#, with: "", options: .regularExpression)
      .replacingOccurrences(of: #"(?s)<thinking>.*?</thinking>"#, with: "", options: .regularExpression)
  }

  /// For the voice: markdown, tables, code blocks, links, URLs and citation
  /// marks removed; cut at a sentence end within `limit`.
  static func forSpeech(_ text: String, limit: Int = 1_400) -> String {
    var result = removeReasoningTraces(text)
    result = result.replacingOccurrences(of: #"(?s)```.*?```"#, with: " (kod ekranda) ", options: .regularExpression)
    var lines: [String] = []
    var sawTable = false
    for rawLine in result.components(separatedBy: .newlines) {
      var line = rawLine.trimmingCharacters(in: .whitespaces)
      if line.hasPrefix("|") || line.filter({ $0 == "|" }).count >= 2 {
        if !sawTable { lines.append(L.t("(The table is on the screen.)", "(Tablo ekranda.)")) }
        sawTable = true
        continue
      }
      line = line.replacingOccurrences(of: #"^#{1,6}\s*"#, with: "", options: .regularExpression)
      line = line.replacingOccurrences(of: #"^([-*•]|\d+[.)])\s+"#, with: "", options: .regularExpression)
      if !line.isEmpty { lines.append(line) }
    }
    result = lines.joined(separator: " ")
    result = result.replacingOccurrences(of: #"\[([^\]]+)\]\((https?://[^)]+)\)"#, with: "$1", options: .regularExpression)
    result = result.replacingOccurrences(of: #"https?://\S+"#, with: "", options: .regularExpression)
    result = result.replacingOccurrences(of: #"\[\d+(?:,\s*\d+)*\]"#, with: "", options: .regularExpression)
    result = result.replacingOccurrences(of: #"(\*\*|__|\*|`)"#, with: "", options: .regularExpression)
    result = result.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
    result = result.replacingOccurrences(of: #"\s+([.,;:!?])"#, with: "$1", options: .regularExpression)
    result = result.trimmingCharacters(in: .whitespacesAndNewlines)
    guard result.count > limit else { return result }
    let cut = String(result.prefix(limit))
    if let end = cut.lastIndex(where: { ".!?".contains($0) }), cut.distance(from: cut.startIndex, to: end) > limit / 2 {
      return String(cut[...end])
    }
    return cut + "…"
  }

  static func splitSentences(_ text: String) -> [String] {
    var sentences: [String] = []
    var current = ""
    for character in text {
      current.append(character)
      if ".!?".contains(character) {
        let trimmed = current.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { sentences.append(trimmed) }
        current = ""
      }
    }
    let rest = current.trimmingCharacters(in: .whitespaces)
    if !rest.isEmpty { sentences.append(rest) }
    return sentences
  }
}
