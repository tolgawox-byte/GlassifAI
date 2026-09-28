# AutoLoom Media Glasses architecture

AutoLoom Media Glasses is an iPhone app for natural voice, vision, web research, and confirmed iPhone actions on the iPhone and Meta Ray-Ban glasses. It is built on GlassifAI (MIT) and combines:
- a native SwiftUI app
- Meta's Wearables Device Access Toolkit (**DAT 0.5.0**)
- LiveKit's WebRTC framework
- a small Rust bridge built from pinned OpenAI Codex sources
- Apple frameworks: Vision (OCR), Speech (on-device name listening), EventKit, App Intents

There is no AutoLoom backend. Everything runs on the iPhone against the user's own ChatGPT account, plus the user's own OpenClaw gateway if they connect one.

Internal type, target, and module names keep the `GlassifAI` prefix. The bundle ID, URL scheme, and Keychain service are unchanged, so the device-verified setup keeps working.

## System overview

```text
┌──────────────────────────────────────────── iPhone ──────────────────────────────────────────────┐
│ Capture                                                                                          │
│  Ray-Ban (DAT 0.5.0 StreamSession) ─ HEVC ─► VT hardware decode (420v) ─┐                        │
│                                    └ raw ─► one copy into app pool ─────┼─► FrameStore           │
│  iPhone AVCapture ─ ≤10 fps ────────────────────────────────────────────┘   (newest 8 glasses    │
│                                                                              frames, epoch, age)  │
│   PIPELINE A  preview: single pending slot ─► AVSampleBufferDisplayLayer                         │
│   PIPELINE B  AI vision (on demand): profile ─► best-frame ─► one encode (+OCR, +crop)            │
│                                                                                                  │
│ GlassifAIRealtimeSession (WebRTC mic/speaker, data channel, captions, reconnect budget, metrics) │
│      │ delegation.created  "TASK: … | QUERY: …"                         ▲ speakable result /     │
│      ▼                                                                  │ silent context notes   │
│ AssistantOrchestrator ── TaskLedger (session/turn/task IDs, phases, T0–T5, vision profile)       │
│  ├─ vision / vision_read / vision_web ─► VisionAttachment (full view, text crop, OCR hint)        │
│  ├─ web ─► hosted web_search (fallback backend search)          ┐                                │
│  ├─ reasoning / chat / memory                                   ├─► ResponsesClient (SSE)        │
│  ├─ report ─► web research ─► AutoLoom note with sources        │   model per role from          │
│  ├─ action ─► ActionGuard ─► planner JSON ─► validate ─► confirm │   ModelCatalog / ModelHealth    │
│  ├─ agent ─► confirm ─► AgentGatewayClient (user's OpenClaw)    ┘                                │
│  ├─ confirm_action / cancel_action / cancel                                                       │
│  └─ live_vision_start/stop ─► LiveVisionController ─► scene notes as commentary context           │
│                                                                                                  │
│ ConversationContext · LocalMemoryStore · AutoLoomNotesStore · WakePhraseListener (Mode B)        │
│ Keychain: ChatGPT OAuth, agent gateway token        GlassifAICodexBridge (Rust): call, sideband   │
└───────────────────────────────┬──────────────────────────────────────────────────────────────────┘
        auth.openai.com · chatgpt.com/backend-api/codex (voice, models, responses, search)
        · the user's OpenClaw gateway (optional) · EventKit (local)
```

## Components

| Component | Responsibility | Files |
|---|---|---|
| App root | Restores login, picks onboarding or the main experience, initializes DAT | `GlassifAIApp.swift` |
| Authentication and models | Device-code login, refresh, **model catalog** (full `/models` metadata) | `Runtime/ChatGPTAuthSession.swift`, `Runtime/ChatGPTKeychain.swift` |
| Model routing | Roles (general, vision, reasoning, web), automatic choice by capability, overrides, health, GPT-6 Astra detection, effort mapping | `Runtime/ModelCatalog.swift`, `Runtime/ModelSettingsView.swift`, `Runtime/RoutingPolicy.swift` (`ModelSelector`) |
| Voice session | Audio session, WebRTC, data channel, captions, turn tracking, stop-speaking, **auto-reconnect**, **latency metrics** | `Runtime/GlassifAIRealtimeSession.swift` |
| Native bridge | Call creation (v1 and v2), sideband with reconnect and generation guard, context append (speakable or silent commentary) | `native/GlassifAICodexBridge/src/lib.rs` |
| Routing policy | Envelope parser, realtime and executor instructions, tool and action schemas, preferences | `Runtime/RoutingPolicy.swift` |
| Orchestrator | Verifies routes, runs tasks, vision attachments, reports, actions, agent, cancellation, stale-result guard | `Runtime/AssistantOrchestrator.swift`, `Runtime/AssistantTasks.swift` |
| Responses client | Streaming SSE client, error mapping and retry, citations; direct search fallback | `Runtime/ResponsesClient.swift` |
| Frame pipeline | FrameStore (ring, epoch, metrics), pixel-buffer copy, low-latency preview, vision encoder (resample, upscale, crop) | `Runtime/FramePipeline.swift` |
| Frame selection | Luma sharpness, exposure, scene-change thumbnails, best-frame choice | `Runtime/FrameSelection.swift` |
| Vision profiles | FAST/BALANCED/HIGH_DETAIL, query classifier, still-photo coordination, assist settings | `Runtime/VisionCapture.swift` |
| OCR | Apple Vision text recognition with timeout, reading order, focus region | `Runtime/TextRecognition.swift` |
| Live Vision | Adaptive scene notes during a conversation | `Runtime/LiveVision.swift` |
| Glasses stream | DAT session, permissions, profiles, **HEVC/raw transport and watchdog**, device info | `ViewModels/StreamSessionViewModel.swift`, `ViewModels/VideoDecoder.swift` |
| iPhone camera | AVCapture session and preview; throttled frame hand-off | `Runtime/GlassifAICamera.swift` |
| Actions | Action kinds and risk, local guard, plan parser and validation, EventKit executor, notes store | `Runtime/DeviceActions.swift`, `Runtime/ActionViews.swift` |
| Agent gateway | Optional OpenClaw client, address policy, Keychain token | `Runtime/AgentGateway.swift`, `Runtime/AgentGatewaySettingsView.swift` |
| Hands-free | Start coordinator, Siri intents and shortcuts, Mode B name listener | `Runtime/VoiceInvocation.swift`, `Runtime/WakePhrase.swift` |
| Audio route | Route, interruption and media-reset monitoring; glasses HFP selection | `Runtime/AudioRouteMonitor.swift` |
| Safety | Log sanitizer, SSRF-safe URL checks, untrusted-content wrapper | `Runtime/PrivacyGuards.swift` |
| UI | Main screen, camera switch, Live Vision toggle, status, action card, settings, diagnostics | `Runtime/GlassifAIExperienceView.swift`, `Settings/SettingsView.swift`, `Runtime/SettingsSections.swift` |
| Brand | Theme, mark; assets generated from `assets/brand/LOGO 2.png` | `Runtime/GlassifAITheme.swift`, `scripts/make-brand-assets.py` |

## Task routing

The realtime voice model answers ordinary conversation itself. It delegates only when needed, with one structured line:

```text
TASK: <vision|vision_read|web|vision_web|reasoning|memory|action|confirm_action|cancel_action|report|live_vision_start|live_vision_stop|cancel> | QUERY: <self-contained request>
```

`agent` is described to the voice model only when an agent gateway is connected.

1. **Verified delegation.** `DelegationEnvelopeParser` maps the line (or JSON) to a known command; unknown kinds or empty queries are rejected.
2. **Verification against real state:**
   - camera off, web search off, memory off, or actions off → an honest reply
   - vision requests get a profile from the request text (`VisionQueryClassifier`)
3. **Tool routing fallback.** Without a valid envelope, the executor model chooses tools itself: hosted `web_search`, or a `look_at_camera` function that triggers the vision path.
4. **Web fallback.** A model that rejects the hosted tool is remembered for the session, and the backend search endpoint is used instead.
5. **Actions and the agent** are staged and confirmed as described in `TOOLS_AND_ACTIONS.md`.

### Task tracking, cancellation, freshness

- Each task records session, turn, task, and handoff IDs, source, kind, route origin, model, vision profile, phase, image details, and a T0–T5 timeline.
- A newer delegation supersedes older voice tasks. "Görevi iptal et" and the cancel button cancel the Swift task and its request.
- Results are delivered only while the task runs and belongs to the live voice session. The same handoff arriving twice runs once.
- A frame selected before a camera switch is rejected by its **epoch**, even if its encode finishes after the switch.

### Vision attachment (per request)

1. Wait up to 2 s for a frame at most 1 s old (camera-specific). For reading requests, wait up to 0.4 s more for a few frames.
2. `FrameSelector` picks the sharpest, well-exposed, fresh frame showing the same scene as the newest one.
3. Encode once from the source buffer:
   - FAST 768 px q0.75
   - BALANCED 1280 px q0.85
   - HIGH_DETAIL: small frames enlarged ≤1.6× within 2048 px / 2500 patches, q0.92
4. HIGH_DETAIL only: Apple Vision OCR (≤1.5 s, concurrent with the encode). Low-confidence results are dropped. The recognised text region is cropped and enlarged (≤3×) as a second image.
5. The request carries `detail: "high"`; OCR text is wrapped as untrusted content.

## Voice call lifecycle

1. Configure `AVAudioSession` (`.playAndRecord`, `.voiceChat`) with glasses HFP when preferred. Other headsets are never grabbed by mistake.
2. Create the WebRTC peer, mic track, send-only video transceiver, and negotiated data channel. Create the offer and wait briefly for ICE gathering.
3. Start the call with AutoLoom instructions and voice (`glassifai_codex_realtime_start_v2`). If rejected, fall back to the verified baseline start.
4. Captions and turns come from the data channel; delegations come from both the sideband and the data channel (deduplicated).
5. **Mid-call failures** (ICE failed, task channel ended, audio services reset, a result that cannot be delivered) reconnect automatically within a budget of 3 in 2 minutes, resuming with the conversation summary. Initial-start failures and user hang-ups never reconnect.
6. Teardown closes everything, ends the orchestrator session (discarding pending results), and stops Live Vision.

Metrics: connect time, and the median time from the end of the user's turn to the first words of the answer (Diagnostics → Realtime).

## Live Vision

`LiveVisionController` ticks every 0.5 s while a conversation is running and a camera is on.
- It measures only the newest frame for scene change. It re-checks at most once a second when the view is stable, and never sends more often than every 6 s. That interval stretches to 12 s on low battery and 15 s when the phone is warm, and it pauses at critical temperature.
- When a note is due, it picks the best recent frame, asks the vision model for a one- or two-sentence description (FAST image, low effort), and appends it as **silent commentary context**, which is never spoken.
- It stops at the time limit (default 10 min), when the conversation ends, or on a privacy wipe.

## Hands-free

`VoiceStartCoordinator` is the single start path for the call button, Siri shortcuts, Mode B, and a future Hey Meta invocation. It is idempotent. Mode B (`WakePhraseListener`) runs only while armed, the app is active, and no conversation is running; it uses on-device recognition only.

## Concurrency

- UI, orchestrator, ledger, context, model health, Live Vision, actions, and the audio monitor are `@MainActor`.
- Frame ingestion, the preview renderer, the frame store, and the copier are lock-protected and run on capture/SDK threads. Sharpness scoring, encoding, and OCR run on background tasks and queues.
- Model requests are async `URLSession` byte streams. Cancelling the Swift task cancels the request.
- The bridge runs call creation on a short-lived Tokio runtime and the sideband on its own thread, with bounded queues.

## Persistence

| Stored | Where |
|---|---|
| ChatGPT OAuth tokens | Keychain (`AfterFirstUnlockThisDeviceOnly`) |
| Agent gateway token (optional) | Keychain (`com.autoloom.agentgateway`, this device only) |
| Settings (camera, profiles, transport, vision quality, assist toggles, Live Vision limit, audio, voice, language, web, region, model overrides, memory, actions, agent address, Mode B) | UserDefaults |
| Model health (which models worked or failed) | UserDefaults (no request content) |
| Opt-in memory | `Application Support/AutoLoom/memory.json` (complete file protection) |
| AutoLoom notes and reports | `Application Support/AutoLoom/notes.json` (complete file protection) |

Not stored: camera frames, audio, transcripts, OCR text, Live Vision notes, sideband messages, SDP, call IDs, model results (except notes you saved), sources.

## Failure behaviour

| Failure | Result | Recovery |
|---|---|---|
| Customized realtime session rejected | Baseline session (shown in Diagnostics) | Automatic |
| Network or audio drop mid-call | "Connecting" and automatic reconnect with context | Automatic (budgeted); otherwise tap |
| HEVC yields no decodable frames | One automatic switch to raw, note in Settings and Diagnostics | Automatic |
| No fresh frame / camera off / camera switched mid-request | Spoken explanation; never an older image | Point or enable the camera |
| Model rejected by the service | Next model, once; marked failed for the session | Automatic |
| Explicit image `detail` rejected | Resent without it for the session | Automatic |
| Hosted web search rejected | Backend search fallback | Automatic |
| 401 / 429 | Forced refresh and retry / "try again shortly" | Automatic / wait |
| Reminders or Calendar permission not granted | Honest reply; asks to open the app when locked | User |
| Agent gateway unreachable or token rejected | Honest reply | User (Settings → Agent gateway → Test connection) |

## Compatibility policy

- Pinned packages: DAT **0.5.0** and LiveKit WebRTC. The Codex source is vendored at 0.149.0.
- The DAT 1.0 upgrade (full-resolution stills, Hey Meta) is planned after Meta's firmware and app rollout reaches the glasses; see `RAYBAN_CAMERA_CAPABILITIES.md`.
- The private ChatGPT transport is unsupported by OpenAI. A server change may need a bridge update.
