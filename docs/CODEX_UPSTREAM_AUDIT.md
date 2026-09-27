# Codex upstream audit (realtime + responses)

Compared on 2026-09-27: the vendored snapshot (`vendor/codex`, Codex 0.149.0) against `openai/codex` `main` @ `8f195c93d7e7acfef95acf273f0e49cce917e291` (latest stable tag `rust-v0.157.1`).

## Result

The realtime wire code is **byte-identical** upstream. That covers `realtime_call.rs`, the `protocol*.rs` parsers, `methods_frameless_bidi.rs`, `methods_common.rs`, `RealtimeSessionConfig`, and the voices. The only breaking change was the V3 model rename `gpt-live-1-boulder-alpha` → `gpt-live-1-codex`, which the fork had already applied.

| Item | Vendored / bridge | Upstream | Risk | Action in this branch |
|---|---|---|---|---|
| V3 realtime model | `gpt-live-1-codex` | same | — | Kept |
| Call creation | `POST …/realtime/calls?intent=quicksilver&architecture=avas`, JSON `{sdp, session}` | identical | — | Kept |
| Sideband | `wss://api.openai.com/v1/live/{call_id}`, no `session.update` | identical (call_id now percent-encoded) | — | Kept |
| Sideband drop | Loop exits, so delegations stop silently | Reconnects with the same call_id, backoff 200 ms → 5 s, stops on 404/410 | Medium | **Implemented** in `lib.rs` |
| `x-session-id` / `User-Agent` headers | Not sent | Sent | Low, unverified | Not changed. The current headers are device-verified |
| Voice tools on V3 | Not supported (only client delegation) | Same; V2-only tools | — | Routing is done client-side |
| Delegation output | `delegation.context.append`, speakable, ≤500 B chunks | same; also `[STATUS]` on commentary | — | Kept; commentary append exported for future use |
| Interrupt | `action_request stop_speaking` (legacy, likely ignored) | V3 has no cancel message; barge-in is server-side | Low | Kept, plus local audio silencing |
| `client_version` | `0.149.0` on /models and /responses | Sent only on /models; gpt-6 models need ≥0.153/0.155 | Medium | Not changed: the verified `gpt-5.6-sol` path keeps working. Newer models are an opt-in follow-up |
| Responses "Lite" shape (gpt-5.6-*, gpt-6-*) | Classic shape | Lite header, no hosted tools | Low–Med, unverified | Classic shape kept (verified). The web search task prefers `gpt-5.5` (non-lite) for the hosted tool and falls back to `/alpha/search` |
| Web search tool | Not used | `{"type":"web_search","external_web_access":true}`; ChatGPT auth allowed | — | **Implemented** |
| Reasoning summary | `"summary":"auto"` | Omitted (catalog default none) | Latency | **Removed** |
| Image input | `input_image`, default detail | `detail` high by default; images capped at 2048 px | — | Frames capped at 1600 px, JPEG q0.82 |
| `x-oai-attestation` | Static CBOR `{error_code:1,bundle_id:"com.openai.codex"}` | Generated per device by the app-server | Could be rejected in future | Kept, because it works today; documented as a risk |

## Upstream delegation handling (for reference)

Upstream Codex forwards each delegation to its agent as `<realtime_delegation><input>…</input><transcript_delta>…</transcript_delta></realtime_delegation>`, and the agent chooses its own tools. This app does the equivalent on the device:
- it verifies the structured route
- it attaches bounded conversation context
- it lets the executor model choose tools when no route is given
