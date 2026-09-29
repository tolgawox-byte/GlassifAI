# Providers

| Provider | Connection | Default role | Status |
|---|---|---|---|
| ChatGPT | The existing ChatGPT account sign-in (Codex endpoints). No API billing. | Voice, conversation, vision, web, reasoning — everything by default | **WORKING** (unchanged path) |
| Local | Built in | Notes, memory, tasks, reminders, calendar, contacts, maps, clipboard, Photos, OCR, time parsing, intent routing | **WORKING** (unchanged path) |
| Claude | Anthropic API key (Messages API) | Reasoning, coding, long documents | **NOT CONNECTED** until the user adds a key · unit-tested adapter |
| Gemini | Google AI Studio API key (Generative Language API) | Live vision (Flash), optional vision/translation, grounded research fallback | **NOT CONNECTED** · unit-tested adapter |
| Perplexity | Perplexity API key (Sonar) | Research with sources | **NOT CONNECTED** · unit-tested adapter |
| OpenRouter | OpenRouter API key | Fallbacks, pinned roles, experiments | **NOT CONNECTED** · unit-tested adapter |
| OpenClaw | The existing optional gateway (address + token) | External tools | Optional, unchanged |

## Official connection methods only

- **Claude**: `POST https://api.anthropic.com/v1/messages` with `x-api-key` and `anthropic-version: 2023-06-01`; models from `GET /v1/models`. A Claude.ai subscription cannot be used by third-party apps, so there is no sign-in and no cookie/session reuse.
- **Gemini**: `POST https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent` with the key in the `x-goog-api-key` header (never in the URL); models from `GET /v1beta/models`; Google Search grounding (`tools: [{google_search: {}}]`) for research. The streaming Live API is not used: Live Vision sends one frame about every 6 seconds to a Flash model.
- **Perplexity**: `POST https://api.perplexity.ai/chat/completions` (Bearer key); sources from `search_results` (title, URL, date) or `citations`. Perplexity has no model-list endpoint, so the app uses its published Sonar list (`sonar`, `sonar-pro`, `sonar-reasoning-pro`, `sonar-deep-research`), marked "published list". Deep Research is never chosen automatically.
- **OpenRouter**: `POST https://openrouter.ai/api/v1/chat/completions` (Bearer key, `HTTP-Referer`, `X-Title`); models from `GET /api/v1/models` (modalities, parameters, context); the key is checked with `GET /api/v1/key` (free); research uses the `web` plugin; text roles use `openrouter/auto`.
- **ChatGPT**: the existing `ResponsesClient` against the account's Codex endpoint; models from the account catalog.

No OAuth or device-code flow is offered for these four because none of them offers one for third-party mobile apps; each uses its official API key.

## Models and capabilities

Models are listed by each provider's own API and stored with a capability matrix (`text`, `vision`, `liveVision`, `reasoning`, `web`, `tools`, `code`, `longContext`, `audio`). Nothing is invented: a provider without a model list (Perplexity) uses its published list and says so. `ProviderModelChoice` picks a listed model per role and cost setting:

| Provider | Balanced | Best quality | Lower cost |
|---|---|---|---|
| Claude | newest Sonnet (Haiku for chat) | newest Opus | newest Haiku |
| Gemini | Flash (vision, live) / Pro (reasoning, documents), stable before preview, highest version | same | Flash-Lite |
| Perplexity | sonar-pro (reasoning: sonar-reasoning-pro) | same | sonar |
| OpenRouter | openrouter/auto; newest Gemini/Claude/GPT vision model for images | same | same |

## Test connection

Every provider card has **Test connection**: a tiny request (for example "Reply with OK." with at most 8 output tokens; OpenRouter only checks the key, for free). The result, latency and model are shown and recorded; the key is stored only if the first test succeeds.
