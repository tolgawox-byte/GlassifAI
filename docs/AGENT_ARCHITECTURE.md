# Agent architecture

**Status: BUILD + UNIT TESTS.** With only ChatGPT + Local connected, every request takes the path that existed before this layer. Specialist providers are NOT CONNECTED until the user adds their own keys, so nothing that uses them is device-verified.

## One assistant, many agents

```
user speech / text
  → LEVEL 1 intent bridge (notes, reminders, tasks, calls, messages, maps, photos, videos…)  ── LOCAL, no cloud
  → realtime voice (ChatGPT account): conversation, and TASK: kind | QUERY delegations
  → RequestAnalyzer   (what the request needs)
  → AgentRouter       (AgentPlan: LOCAL / FAST / SPECIALIST / TEAM, providers, fallbacks, timeout)
  → FAST: AssistantOrchestrator's existing ChatGPT path (vision, web, reasoning, memory, actions, reports, OpenClaw)
    SPECIALIST / TEAM: AutoLoomAgentOrchestrator → AIProvider adapters → ResultFusion
  → ResponseNormalizer (no provider voice, no reasoning traces; speech without markdown/URLs)
  → the one voice speaks it, in the chosen personality (Jarvis Style or natural)
```

The user never picks an agent. The router does; Settings → Intelligence lets them pin a role (advanced).

## Logical agents (`AgentRole`)

| Role | Job | Where it runs |
|---|---|---|
| Chat | Conversation | The realtime voice (ChatGPT) itself |
| Vision | What is in view, reading | ChatGPT's high-detail vision path by default; Gemini/Claude/OpenRouter when pinned |
| Live vision | Silent notes while "keep looking" is on | Gemini when connected (balanced/best quality), else ChatGPT |
| Research | Current facts, prices, markets, recalls, news, with sources | Perplexity when connected, else ChatGPT web search |
| Reasoning | Deep analysis, comparisons, plans | Claude when connected, else ChatGPT |
| Coding | Errors, code, technical analysis | Claude when connected, else ChatGPT |
| Document | Long documents | Claude (or Gemini) when connected, else ChatGPT |
| Translation | Text in view | ChatGPT's vision path by default |
| Planning | Days and schedules | Local tools + chat |
| Device action | Notes, reminders, tasks, calendar, calls, messages, maps, clipboard, Photos | **Always local** (native executor) |
| Memory | AutoLoom memory | **Always local** (source of truth on the phone) |
| Dealer | Vehicle context, dealer research | Local vehicle context + the research/vision agents |
| External | Email, smart home, computer actions | The user's own OpenClaw gateway (confirmed first) |

## Components (ios/GlassifAI/Runtime)

| File | What it holds |
|---|---|
| `AgentModel.swift` | `AgentRole`, `ProviderCapabilities`, `ProviderID` (why/data/billing/usage texts), `ExecutionStrategy`, `PrivacyLevel`, `CostPreference`, `RequirementProfile`, `AgentStep`, `AgentPlan`, `RoutingContext`, `EntityContext`, `NetworkStatus` |
| `AIProvider.swift` | `AIProvider` protocol, request/response/source/test types, `ProviderError`, `ProviderHTTP` (error mapping), `ProviderCredentialStore` (Keychain) |
| `ProviderAdapters.swift` | `ClaudeProvider`, `GeminiProvider`, `PerplexityProvider`, `OpenRouterProvider`, `ChatGPTProvider` (existing account client), `LocalProvider`, `OpenClawProvider`, `ProviderModelChoice` |
| `ProviderRegistry.swift` | Connections, keys, models, `ProviderHealthState` (circuit breaker), routing settings, diagnostics |
| `AgentRouter.swift` | `RequestAnalyzer` (Turkish + English cues), `AgentRouter` (plans, candidates, preferences, timeouts) |
| `AgentTeam.swift` | `AutoLoomAgentOrchestrator` (specialist and team execution), `SpecialistPrompts`, `ResultFusion` |
| `ResponseNormalizer.swift` | Provider voice removal, reasoning-trace removal, speech finalizer |
| `JarvisPersona.swift` | Jarvis Style intensity, form of address, confirmations, greeting |
| `IntelligenceViews.swift` | Settings → Intelligence, provider detail, connect sheet (cost notice), routing diagnostics, Personality |

`AssistantOrchestrator.executeTask` asks the router for a plan for every delegated or typed request, records it on the task (`agentPlan`), runs specialists when the plan says so, and otherwise continues on the existing code. Reports (saved as notes) and OpenClaw requests (confirmed first) always keep their own flows.

## One conversation

Switching agents never resets anything: the voice model keeps the conversation; each provider gets the recent conversation (`ConversationContext.promptContext`), a few relevant memories, and the current entities (`EntityContext`: vehicle, product, person, place, document, 30 minutes). A vehicle named by the vision agent becomes the current vehicle, so "Kaça satılıyor?" after "Bu nedir?" researches the same car.

## What never happens

- A provider never executes anything: side effects are only the native executor's (after the confirmation each action needs).
- A provider never gets the whole memory, contacts, notes or dealer data.
- Camera text, OCR, web pages and documents are wrapped as untrusted content and cannot change tools, prompts, credentials or memory policy.
- No provider speaks as itself ("Claude says…"); no chain-of-thought is shown or logged.
