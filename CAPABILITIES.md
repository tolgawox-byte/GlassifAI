# AutoLoom Media Glasses — capability report

Branch `autoloom-glasses-vNext`. Status meanings:
- **WORKING**: verified on the physical iPhone and Ray-Ban Meta Gen 1 by the owner.
- **PARTIAL**: works with a stated limit.
- **EXPERIMENTAL**: implemented and covered by automated tests in CI, but not yet verified on the phone.
- **UNAVAILABLE**: not possible on the current platforms or connection, or deliberately not built.

Nothing is marked WORKING without a device test. Features that changed in vNext go back to EXPERIMENTAL until they are re-tested, even when the earlier version was WORKING. `TEST_REPORT.md` has the test for each item.

This app reaches ChatGPT through the account-backed endpoints OpenAI's Codex uses (`chatgpt.com/backend-api/codex/*`). Signing in does not unlock every feature of the ChatGPT app.

## Voice and conversation

| Capability | Status | Notes |
|---|---|---|
| ChatGPT sign-in (device code) | **WORKING** | Unchanged from the verified build |
| Natural realtime voice (`gpt-live-1-codex`, WebRTC) | **WORKING** | Unchanged call setup. Realtime models are not listed by the service, so the verified model is used |
| Ray-Ban microphone and speaker routing | **WORKING** | Unchanged |
| Barge-in / "dur", "bekle", "hayır" | **PARTIAL** | Server-side barge-in plus a local stop button. The protocol has no client "cancel response" message; the stop words are now in the instructions |
| Auto-reconnect after a network or audio drop | **EXPERIMENTAL** | Up to 3 times in 2 minutes, resumes with a conversation summary |
| Voice latency metrics | **EXPERIMENTAL** | Connect time and median time to first answer in Diagnostics |
| Custom assistant name ("Jarvis") | **EXPERIMENTAL** | Local setting, part of the voice instructions |
| Conversation context and follow-ups | **EXPERIMENTAL** | Bounded in-memory context, resumed after reconnect |
| Visual translation ("read this and translate to Turkish") | **EXPERIMENTAL** | High-detail reading profile with OCR, answer in the requested language |

## Camera and vision

| Capability | Status | Notes |
|---|---|---|
| iPhone camera vision | **WORKING** (earlier pipeline) / **EXPERIMENTAL** (vNext) | vNext adds profiles, OCR and crop |
| Ray-Ban camera preview | **WORKING** on DAT 0.4.0 / **EXPERIMENTAL** on 0.5.0 | Low-latency layer unchanged; the source changed to HEVC + app decode |
| Ray-Ban vision | **WORKING** on the previous build / **EXPERIMENTAL** vNext | Same freshness and source guards, plus best-frame selection |
| Ray-Ban 720×1280 stream | **EXPERIMENTAL** | DAT 0.5.0 fixes `.high`. Diagnostics shows requested vs actual; the glasses may still lower it on a weak link |
| Ray-Ban frames with the phone locked | **EXPERIMENTAL** | HEVC transport streams in the background; raw fallback does not |
| Ray-Ban high-quality (full sensor) photo | **UNAVAILABLE** | Needs DAT 1.0 `Camera.photo` plus glasses firmware V128 and Meta AI V290 (rollout from 2026-09-30) |
| Ray-Ban in-stream photo | **PARTIAL** | A frame lifted out of the video stream (Meta docs); used as the fallback when video stalls |
| Best-frame selection | **EXPERIMENTAL** | Sharpest of the last 8 frames of the same scene, ≤1 s old |
| FAST / BALANCED / HIGH_DETAIL profiles | **EXPERIMENTAL** | Chosen from the request; reading words always get HIGH_DETAIL |
| On-device OCR assist and zoomed text crop | **EXPERIMENTAL** | Apple Vision; hints are untrusted and never replace the image |
| Live Vision | **EXPERIMENTAL** | Silent scene notes when the view changes (≥6 s apart, adaptive, time-limited) |
| Stale-frame protection | **EXPERIMENTAL** (vNext epoch) | ≤1 s age, source filter, epoch check across camera switches |
| Face recognition | **UNAVAILABLE** | Deliberately not built in this phase (privacy first; camera quality came first) |

## Models

| Capability | Status | Notes |
|---|---|---|
| Model capability discovery | **EXPERIMENTAL** | Full `/models` metadata; Settings → AI models |
| Task-specific routing (general, vision, reasoning, web) | **EXPERIMENTAL** | Follows the service's order and each model's capabilities; per-role overrides |
| GPT-6 Astra | **EXPERIMENTAL** detection | Used automatically only if this connection lists it. **Not yet checked**; Settings → AI models shows the answer |
| Realtime model choice | **UNAVAILABLE** | Not listed by the service; the verified model is fixed |

## Web and research

| Capability | Status | Notes |
|---|---|---|
| Live web search with sources | **EXPERIMENTAL** | Hosted `web_search` on the ChatGPT account; backend search fallback |
| Vision + web ("price of this in Canada") | **EXPERIMENTAL** | High-detail image, identification, then search |
| Research reports saved as notes | **EXPERIMENTAL** | `report` task; note with source links |

## iPhone actions and tasks

| Capability | Status | Notes |
|---|---|---|
| Reminders (create, list) | **EXPERIMENTAL** | EventKit; spoken yes or tap to save |
| Calendar (today, upcoming, create) | **EXPERIMENTAL** | EventKit |
| AutoLoom notes | **EXPERIMENTAL** | On this iPhone; shareable to Apple Notes |
| Apple Notes direct write | **UNAVAILABLE** | No public API; Share is offered |
| Maps directions, open link, copy, share | **EXPERIMENTAL** | Tap to confirm (copy runs directly) |
| Call and message | **EXPERIMENTAL** | Tap to confirm; the system app sends. Contacts are not searched |
| Email, purchases, payments, deleting data, posting | **UNAVAILABLE** | Refused locally, before any model call |
| AutoLoom Tasks (reports, notes, confirmed actions) | **EXPERIMENTAL** | Settings → AutoLoom Tasks & Notes |
| OpenClaw agent gateway | **EXPERIMENTAL** (optional) | Off by default; needs your own gateway and token; confirmation before sending |
| ChatGPT Work | **UNAVAILABLE** | Not exposed through this connection |
| Codex cloud tasks | **UNAVAILABLE** | Codex endpoints are used for voice and models only |
| Siri shortcuts (Start Conversation, Ask AutoLoom, Start Live Vision) | **EXPERIMENTAL** | App Shortcuts |

## Memory

| Capability | Status | Notes |
|---|---|---|
| AutoLoom on-device memory (opt-in) | **EXPERIMENTAL** | Editable and deletable in Settings → Memory |
| ChatGPT account memory / chat history | **UNAVAILABLE** | No access through this connection; requests use `store: false` |

## Hands-free invocation

| Capability | Status | Notes |
|---|---|---|
| Mode A: active conversation, address by name | **EXPERIMENTAL** | No wake word needed while a conversation runs |
| Mode B: app-armed name listening | **EXPERIMENTAL** | Opt-in, app open on screen only, on-device recognition only |
| Mode C: "Hey Siri, start AutoLoom" | **EXPERIMENTAL** | App Shortcut; a custom phrase through the Shortcuts app |
| "Hey Meta, start AutoLoom" | **UNAVAILABLE** | Needs DAT 1.0, firmware V128, and Meta's Voice Invocation approval |
| Always-on custom system wake word ("Hey Jarvis" anywhere) | **UNAVAILABLE** | Not offered by iOS or the Meta glasses to third-party apps |

## Offline

| Capability | Status | Notes |
|---|---|---|
| Offline mode (local models) | **UNAVAILABLE** | Not built. On-device OCR and the name listener already run locally; a local model would plug in behind the same task routing |

## Cost

No new paid service, API key, or subscription is used. Everything runs on the ChatGPT account you sign in with, within that plan's usage limits. The optional agent gateway is your own OpenClaw installation.
