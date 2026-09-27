# AutoLoom Media Glasses — capability matrix

Signing in with ChatGPT does **not** unlock every feature of the official ChatGPT app. This app reaches ChatGPT through the same account-backed endpoints that OpenAI's Codex CLI uses (`chatgpt.com/backend-api/codex/*`). Anything outside those endpoints is not available, and the app says so instead of pretending.

Status legend: **Official** = public, documented API · **Private** = undocumented endpoint used by an official OpenAI client (Codex) · **Experimental** = implemented here but not yet verified on the physical device · **Not available** = not implemented and not reachable through this interface.

| Capability | Current support | Provider / interface | Auth required | Extra cost | Official / private | Automated test | Physical test | Known limitations |
|---|---|---|---|---|---|---|---|---|
| Natural realtime voice | **Yes** (baseline, device-verified) | ChatGPT realtime `gpt-live-1-codex` over WebRTC; call created by the embedded Codex bridge (`/realtime/calls`, `openai-alpha: quicksilver=v2`, FramelessBidi) | ChatGPT account (Codex device-code OAuth) | None from this app; uses your ChatGPT plan's limits | Private | Bridge option parsing, reconnect backoff (Rust unit) | Required (Test 1, 5) | Private protocol can change without notice. The bridge sends a static `x-oai-attestation` value copied from upstream GlassifAI; OpenAI could start rejecting it. Voices other than Juniper are experimental (automatic fallback). |
| General conversation | **Yes** | Voice model answers directly; new instructions stop it from routing everything to the camera | Same | None | Private | Instruction content (unit) | Required (Test 1) | Answers come from the voice model's own knowledge; anything current is delegated to web search. |
| Vision ("what am I looking at?") | **Yes**, on request | Delegation → Codex Responses with one fresh camera frame (`gpt-5.6-sol` default, device-verified model) | Same | None | Private | Frame freshness, encoder, routing (unit) | Required (Test 3) | Uses the freshest stream frame (≤1 s old). The Ray-Ban stream is limited by DAT 0.4.0 over Bluetooth — see `docs/RAYBAN_CAMERA_CAPABILITIES.md`. |
| Web search | **Experimental** (implemented, not yet device-verified) | Hosted `web_search` tool (`external_web_access: true`) on Codex Responses, preferring `gpt-5.5`; automatic fallback to the Codex backend search endpoint (`/alpha/search`) + model summary | Same | None from this app | Private | SSE/citation parsing, fallback parsing, source filtering (unit) | Required (Test 2, 4) | Upstream Codex allows hosted search with ChatGPT auth, but whether each model accepts it on this backend is unverified — the fallback covers a rejection. Source links appear only when the service returns them; publish dates are not provided by the service and are never invented. |
| Vision + web ("price of what I see") | **Experimental** | Frame + hosted web search in one request (fallback as above) | Same | None | Private | Routing (unit) | Required (Test 4) | Identification quality depends on the frame (see camera doc). |
| Reasoning | **Yes** (experimental routing) | Same Responses endpoint with higher reasoning effort | Same | None | Private | Routing (unit) | Recommended | Slower (up to 90 s timeout); the voice model says a short filler while waiting. |
| Conversation context / follow-ups | **Yes** | Voice model keeps its own call context; the app keeps a bounded in-memory transcript + earlier task results for delegated tasks and to resume after a reconnect | — | None | App-local | Context compaction, untrusted wrapping (unit) | Required (Test 1–4) | Context lives only while the app runs. |
| Memory | **App-local, opt-in** | JSON file on the iPhone (complete file protection), editable/deletable in Settings → Memory | — | None | App-local | Opt-in, add/forget/delete (unit) | Required (Test 11) | **Not** ChatGPT's memory; nothing is synced with your ChatGPT account. |
| ChatGPT chat history | **Not available** | — | — | — | — | — | — | No endpoint for reading or writing ChatGPT conversations. Requests use `store: false`. |
| Interrupt / "dur" | **Yes** | Server-side barge-in (voice model stops when you talk) + on-screen stop button that silences assistant audio locally | — | None | Private | — | Required (Test 5) | The realtime protocol has no client "cancel response" message; the local stop mutes playback until you speak again or the turn ends. |
| Task cancellation ("görevi iptal et") | **Yes** | Voice model emits `TASK: cancel`; on-screen cancel button; tasks tracked by session/turn/task ID, late results discarded | — | None | App-local | Ledger + duplicate/stale handling (unit) | Required | — |
| Work (ChatGPT Work / business features) | **Not available** | — | — | — | — | — | — | Not exposed through the Codex endpoints. No UI is shown for it. |
| Codex tasks (coding agent, cloud tasks) | **Not available** | — | — | — | — | — | — | The app uses the Codex backend only for voice and model access. Future extension point: a separate, explicitly confirmed action flow. |
| Connected apps (Gmail, Calendar, GitHub …) | **Not available** | — | — | — | — | — | — | ChatGPT connectors are not reachable here. Would need separate OAuth integrations. Requests are declined honestly. |
| File creation | **Not available** | — | — | — | — | — | — | — |
| Email / calendar actions | **Not available** | — | — | — | — | Decline path (unit) | — | Routed to `AUTHORIZED_ACTION`, which declines. Any future action must require explicit on-screen confirmation — a spoken "yes" will not count. |
| Browser actions | **Not available** | — | — | — | — | — | — | The app never fetches web pages itself (SSRF-safe by design). |

## Cost summary

- No new paid service, API key, or subscription is used. Everything runs on the ChatGPT account you sign in with and counts against that plan's normal usage limits.
- An official OpenAI API key path (public Realtime API + `web_search`) would be billed per use; it is **not** implemented and was not needed. If the private endpoints stop working, that is the documented fallback option and would require your approval first.

## Honesty rules built into the assistant

- Never claims to see without a fresh frame; says when the camera is off or the frame is stale.
- Never invents facts, prices, or sources; says when a search failed or returned nothing.
- Never claims to have performed an action.
- States that it is an independent AutoLoom Media app, not an official OpenAI, ChatGPT, Meta, or Ray-Ban product.
