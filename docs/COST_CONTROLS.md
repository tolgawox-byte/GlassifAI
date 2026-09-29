# Cost controls

## Nothing paid is enabled automatically

Claude, Gemini, Perplexity and OpenRouter bill the account behind their API key. None is enabled until the user opens the provider, reads the notice and confirms:

- **Why it is useful** (for example Claude: "Better long-form reasoning, long documents, technical analysis and code").
- **What data is sent** (only the request it is chosen for; never the whole memory, contacts or notes; research providers get no images).
- **Billing requirement** (for example "Needs an Anthropic API key with credit. A Claude.ai subscription cannot be used here").
- **Expected use** (for example Perplexity: "One call per research question"; Gemini: "Live Vision updates about every 6 s while on").
- A required switch: "I understand my … account may be charged." Only then can the key be entered; connecting runs one tiny test request.

The app keeps working with only ChatGPT (no API billing) and the phone.

## Quality / cost setting (Settings → Intelligence)

| Setting | Behaviour |
|---|---|
| Balanced (default) | Specialists lead the jobs they are best at; ChatGPT does the rest; teams only when they add something |
| Best quality | Teams more often, including a reasoning agent that writes the fused answer; still no duplicate calls |
| Lower cost | ChatGPT and the phone first; specialists only as fallbacks; one provider per request; no research teams |
| Local first | On the phone whenever possible; ChatGPT next; specialists last |

## Bounded usage

- One provider call per step; a retry only for a dropped connection; each provider at most once per step; no endless loops.
- A refused key or missing credit stops that provider until the user acts; no retry storms.
- Rate limits pause the provider for its `Retry-After`.
- Live Vision on Gemini: one small frame per update, at most every 6 seconds (slower when warm or on low battery), up to the Live Vision time limit.
- Perplexity Deep Research and similar expensive models are never chosen automatically.
- Settings shows each provider's last success, average latency and last problem; Routing diagnostics show every call's provider and model.
