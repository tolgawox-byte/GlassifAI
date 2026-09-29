import CoreSpotlight
import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// iOS 27 additions to the on-device brain, kept apart so the rest builds and
// runs unchanged on iOS 26 (and without the model at all).

#if canImport(FoundationModels)
/// One session, instructions chosen per request (Dynamic Profiles, iOS 27):
/// fast local routing, memory, dealer, document, translation, general.
@available(iOS 27.0, *)
struct AutoLoomBrainProfile: LanguageModelSession.DynamicProfile {
  var kind: LocalBrain.Profile

  var body: some LanguageModelSession.DynamicProfile {
    LanguageModelSession.Profile {
      Instructions { kind.instructions }
    }
    .temperature(kind.temperature)
  }
}

@available(iOS 27.0, *)
extension LocalBrain {
  /// A session on the iOS 27 profile API.
  static func makeProfileSession(_ profile: Profile) -> LanguageModelSession {
    LanguageModelSession(profile: AutoLoomBrainProfile(kind: profile))
  }

  /// "Geçen hafta Corolla hakkında ne not etmiştim?": the model searches this
  /// app's Spotlight items (on this iPhone) before answering; a focused guide
  /// keeps the results inside the on-device context window.
  static func answerFromMyData(_ question: String) async -> String? {
    guard isReady else { return nil }
    do {
      let tool = SpotlightSearchTool(configuration: .init(
        sources: [.coreSpotlight(.init(fetchAttributes: [.title, .contentDescription, .keywords]))],
        guide: .focused(.documents)))
      let session = LanguageModelSession(
        tools: [tool],
        instructions: Profile.memory.instructions
          + " Search the user's AutoLoom items before answering and answer only from what the search returns.")
      let response = try await session.respond(to: question)
      let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
      return text.isEmpty ? nil : text
    } catch {
      lastError = String(describing: type(of: error))
      return nil
    }
  }
}
#endif
