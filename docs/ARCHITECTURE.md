# AutoLoom Media Glasses architecture

> **DAT 1.0 variant (`autoloom-glasses-dat1`):** this branch links DAT 1.0.0. Where this page describes DAT 0.5.0 limits (no standalone photo, no worn state, no "Hey Meta"), `docs/DAT_1_MIGRATION.md` describes what the variant does instead. Nothing DAT 1.0-specific has been tested on glasses.

AutoLoom Media Glasses is an iPhone app for natural voice, vision, web research, and confirmed iPhone actions on the iPhone and Meta Ray-Ban glasses. It is built on GlassifAI (MIT) and combines:
- a native SwiftUI app
- Meta's Wearables Device Access Toolkit (**DAT 0.5.0**)
- LiveKit's WebRTC framework
- a small Rust bridge built from pinned OpenAI Codex sources
- Apple frameworks: Vision (OCR), Speech (on-device wake phrase), EventKit, UserNotifications, Contacts, CoreLocation (opt-in), SwiftData, NaturalLanguage, App Intents

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
│ GlassifAIRealtimeSession (WebRTC mic/speaker, data channel, captions, reconnect budget, metrics, │
│   connection phases → ready chime/phrase, turn interception: mute model reply, speak app result) │
│      │ final user transcript ─► VoiceActionIntentBridge (LEVEL 1 parser) ─► runVoiceIntent       │
│      │ delegation.created  "TASK: … | QUERY: …"                         ▲ speakable result /     │
│      ▼                                                                  │ silent context notes   │
│ AssistantOrchestrator ── TaskLedger (session/turn/task IDs, phases, T0–T5, vision profile)       │
│  ├─ vision / vision_read / vision_web ─► VisionAttachment (full view, text crop, OCR hint)        │
│  ├─ web ─► hosted web_search (fallback backend search)          ┐                                │
│  ├─ reasoning / chat · memory (save:/recall:/forget:) · visual_memory ├─► ResponsesClient (SSE)  │
│  ├─ report ─► web research ─► AutoLoom note with sources        │   model per role from          │
│  ├─ action ─► ActionGuard ─► planner JSON ─► validate ─► confirm │   ModelCatalog / ModelHealth    │
│  ├─ agent ─► confirm ─► AgentGatewayClient (user's OpenClaw)    ┘                                │
│  ├─ confirm_action / cancel_action / cancel                                                       │
│  └─ live_vision_start/stop ─► LiveVisionController ─► scene notes as commentary context           │
│                                                                                                  │
│ ConversationContext · MemoryStore (SwiftData: memories, notes, tasks; profile; summaries)       │
│ GlassesLifecycleMonitor · ActionTraceLog · WakePhraseListener · Tools                            │
│ Keychain: ChatGPT OAuth, agent gateway token        GlassifAICodexBridge (Rust): call, sideband   │
└───────────────────────────────┬──────────────────────────────────────────────────────────────────┘
        auth.openai.com · chatgpt.com/backend-api/codex (voice, models, responses, search)
        · the user's OpenClaw gateway (optional) · EventKit (local)
```

## Components

| Component | Responsibility | Files |
|---|---|---|
| App root | Onboarding (once), login, then the tab shell; initializes DAT | `GlassifAIApp.swift`, `Runtime/OnboardingView.swift` |
| Authentication and models | Device-code login, refresh, **model catalog** (full `/models` metadata) | `Runtime/ChatGPTAuthSession.swift`, `Runtime/ChatGPTKeychain.swift` |
| Model routing | Roles (general, vision, reasoning, web), automatic choice by capability, overrides, health, GPT-6 Astra detection, effort mapping | `Runtime/ModelCatalog.swift`, `Runtime/ModelSettingsView.swift`, `Runtime/RoutingPolicy.swift` (`ModelSelector`) |
| Voice session | Audio session, WebRTC, data channel, captions, turn tracking, **connection phases and the ready announcement**, **turn interception for app-handled commands**, start ladder with Selected/Active voice, preview, apply now, stop words, end commands, quiet timeout, auto-reconnect, latency metrics | `Runtime/GlassifAIRealtimeSession.swift`, `Runtime/VoiceCatalog.swift`, `Runtime/ConversationPolicy.swift`, `Runtime/ConnectionFeedback.swift` (chime, Apple-voice fallback, Jarvis Style), `Runtime/VoiceDiagnosticsView.swift` (see `VOICE_ARCHITECTURE.md`) |
| Voice action bridge | LEVEL 1 parser for explicit commands; execution with permission checks, permission retry, action trace | `Runtime/VoiceActionIntentBridge.swift`, `Runtime/VoiceIntentRunner.swift` |
| Native bridge (v3) | Call creation (v1 and v2) returning the applied voice and model, sideband with reconnect and generation guard, context append (speakable or silent commentary) | `native/GlassifAICodexBridge/src/lib.rs` |
| Routing policy | Envelope parser, realtime and executor instructions, tool and action schemas, preferences | `Runtime/RoutingPolicy.swift` |
| Orchestrator | Verifies routes, runs tasks, vision attachments (with a high-detail retry before any "move closer"), memory and visual memory, reports, actions, contacts resolution, agent, cancellation, stale-result guard | `Runtime/AssistantOrchestrator.swift`, `Runtime/AssistantTasks.swift`, `Runtime/AssistantFlows.swift` |
| Responses client | Streaming SSE client, error mapping and retry, citations; direct search fallback | `Runtime/ResponsesClient.swift` |
| Frame pipeline | FrameStore (ring, epoch, metrics), pixel-buffer copy, low-latency preview, vision encoder (resample, upscale, crop) | `Runtime/FramePipeline.swift` |
| Frame selection | Luma sharpness, exposure, scene-change thumbnails, best-frame choice | `Runtime/FrameSelection.swift` |
| Vision profiles | FAST/BALANCED/HIGH_DETAIL, query classifier, still-photo coordination, assist settings | `Runtime/VisionCapture.swift` |
| OCR | Apple Vision text recognition with timeout, reading order, focus region | `Runtime/TextRecognition.swift` |
| Live Vision | Adaptive scene notes during a conversation | `Runtime/LiveVision.swift` |
| Glasses stream | DAT session, permissions, profiles, HEVC/raw transport and watchdog (foreground only), background-safe decoder (keyframe gate, session recreation, software fallback), device info | `ViewModels/StreamSessionViewModel.swift`, `ViewModels/VideoDecoder.swift` |
| Glasses lifecycle | ForegroundActive / BackgroundStreaming / ScreenLockedStreaming / Suspended / Disconnected, transitions with frame counters, honest "cannot see" reasons, Camera diagnostics | `Runtime/GlassesLifecycle.swift`, `Runtime/CameraDiagnosticsView.swift` (see `BACKGROUND_STREAMING.md`) |
| iPhone camera | AVCapture session and preview; throttled frame hand-off | `Runtime/GlassifAICamera.swift` |
| Tools | Action kinds with SAFE / CONFIRM / STRONG CONFIRM, local guard, plan parser, **deterministic time parsing**, EventKit / notifications / contacts executor, tool registry, permission center, Tasks tab | `Runtime/DeviceActions.swift`, `Runtime/TimePhraseParser.swift`, `Runtime/ToolRegistry.swift`, `Runtime/PermissionCenter.swift`, `Runtime/ActionViews.swift`, `Runtime/TasksViews.swift` (see `NATIVE_TOOLS.md`) |
| Memory | SwiftData memories, notes and AutoLoom tasks, user profile, conversation summaries (with `ConversationSummarizer`), ranking, on-device search, migration, Memory tab | `Runtime/MemoryStore.swift`, `Runtime/MemoryViews.swift`, `Runtime/ConversationMemory.swift` (see `MEMORY_ARCHITECTURE.md`) |
| Agent gateway | Optional OpenClaw client, address policy, Keychain token | `Runtime/AgentGateway.swift`, `Runtime/AgentGatewaySettingsView.swift` |
| Hands-free | Start coordinator, Siri intents and shortcuts (incl. Create AutoLoom Note), wake phrase, Hands-Free Ready, glasses link arming, greeting and chime | `Runtime/VoiceInvocation.swift`, `Runtime/WakePhrase.swift`, `Runtime/HandsFreeSettingsView.swift` (see `WAKE_INVOCATION.md`) |
| Audio route | Route, interruption and media-reset monitoring; glasses HFP selection | `Runtime/AudioRouteMonitor.swift` |
| Safety | Log sanitizer, SSRF-safe URL checks, untrusted-content wrapper | `Runtime/PrivacyGuards.swift` |
| UI | Tab shell (Assistant, Memory, Tasks, Settings), assistant screen with state word and orb, onboarding, settings sections, privacy center, developer diagnostics and task trace, bilingual strings | `Runtime/AppShellView.swift`, `Runtime/AssistantHomeView.swift`, `Runtime/AssistantOrb.swift`, `Runtime/UIText.swift`, `Settings/SettingsView.swift`, `Runtime/SettingsSections.swift`, `Runtime/VoiceSettingsView.swift` (see `UI_REDESIGN.md`) |
| Brand | Theme, mark; assets generated from `assets/brand/LOGO 2.png` | `Runtime/GlassifAITheme.swift`, `scripts/make-brand-assets.py` |

## Task routing

Explicit commands (notes, memory, the user's name, reminders, notifications, AutoLoom tasks, calendar, routines, translation, answers to pending questions) are recognised by the app from the final transcript and run locally; the model's own reply to such a turn is muted and the app's result spoken (`VOICE_ARCHITECTURE.md`). Everything else follows the path below.

The realtime voice model answers ordinary conversation itself. It delegates only when needed, with one structured line:

```text
TASK: <vision|vision_read|web|vision_web|reasoning|memory|visual_memory|action|confirm_action|cancel_action|report|live_vision_start|live_vision_stop|cancel> | QUERY: <self-contained request>
```

`agent` is described to the voice model only when an agent gateway is connected.

1. **Verified delegation.** `DelegationEnvelopeParser` maps the line (or JSON) to a known command; unknown kinds or empty queries are rejected.
2. **Verification against real state:**
   - camera off, web search off, memory off, or actions off → an honest reply
   - vision requests get a profile from the request text (`VisionQueryClassifier`)
3. **Tool routing fallback.** Without a valid envelope, the executor model chooses tools itself: hosted `web_search`, or a `look_at_camera` function that triggers the vision path.
4. **Web fallback.** A model that rejects the hosted tool is remembered for the session, and the backend search endpoint is used instead.
5. **Actions and the agent** are staged and confirmed as described in `NATIVE_TOOLS.md`.
6. **Memory** queries start with `save:`, `recall:`, `forget:` or `list`, so the store acts without an extra model call (`MEMORY_ARCHITECTURE.md`).
7. **Unclear vision answers** ("can't read", "yaklaşın") are retried once in HIGH_DETAIL (best frame, OCR, crop, upscale) before being spoken, and reposition advice is not repeated within 90 s.

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
3. Start the call with the start ladder: AutoLoom instructions (profile, memories, last conversation summary, Jarvis Style if on) and the selected voice, then without resume context, then the default voice, then the verified baseline. Every failure is recorded and shown (Selected vs Active voice).
4. Ready only when the data channel is open and the audio route is up (glasses HFP when preferred); then, once per new conversation, the chime and/or "Bağlandım, dinliyorum." — a failure says "Bağlantı kurulamadı.".
5. Captions and turns come from the data channel; delegations come from both the sideband and the data channel (deduplicated). Delegations that arrive before the final user transcript wait for the voice action bridge's decision.
6. **Mid-call failures** (ICE failed, task channel ended, audio services reset, a result that cannot be delivered) reconnect automatically within a budget of 3 in 2 minutes, resuming with the conversation summary. Initial-start failures and user hang-ups never reconnect.
7. Teardown closes everything, ends the orchestrator session (discarding pending results), and stops Live Vision. When the conversation really ends (not a reconnect), a short summary is saved if it was meaningful.

Metrics: connect time, and the median time from the end of the user's turn to the first words of the answer (Diagnostics → Realtime).

## Live Vision

`LiveVisionController` ticks every 0.5 s while a conversation is running and a camera is on.
- It measures only the newest frame for scene change. It re-checks at most once a second when the view is stable, and never sends more often than every 6 s. That interval stretches to 12 s on low battery and 15 s when the phone is warm, and it pauses at critical temperature.
- When a note is due, it picks the best recent frame, asks the vision model for a one- or two-sentence description (FAST image, low effort), and appends it as **silent commentary context**, which is never spoken.
- It stops at the time limit (default 10 min), when the conversation ends, or on a privacy wipe.

Why notes instead of streaming frames: OpenVision's live mode streams frames (1 fps to Gemini Live, or images to OpenAI's public Realtime API), because those APIs accept image input. The ChatGPT-account realtime protocol this app uses (Codex "frameless bidi", `vendor/codex/codex-rs/codex-api/src/endpoint/realtime_websocket`) accepts only audio and text items, with context append on a speakable or a silent commentary channel. A vision model therefore turns frames into short text notes on the silent channel, and detailed questions still get a full-quality frame through the vision path.

## Hands-free

`VoiceStartCoordinator` is the single start path for the voice button, Siri shortcuts, the wake phrase, and a future Hey Meta invocation. It is idempotent. `WakePhraseListener` uses on-device recognition only: while the app is open, or in the background with Hands-Free Ready (opt-in, time-limited), optionally only while the glasses report a connected link. See `WAKE_INVOCATION.md`.

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
| Settings (camera, profiles, transport, vision quality, assist toggles, Live Vision limit, audio, voice, language, web, region, model overrides, memory switches, tool switches, wake phrase, greeting, timeout, onboarding) | UserDefaults |
| Model health (which models worked or failed) | UserDefaults (no request content) |
| Memories and notes | SwiftData `Application Support/AutoLoom/AutoLoomMemory.store` (earlier `memory.json` / `notes.json` imported once and kept as `*.migrated-backup`) |
| Visual memory photos (only if enabled) | Inside the SwiftData store (external storage) |

Not stored: camera frames, audio, transcripts, OCR text, Live Vision notes, sideband messages, SDP, call IDs, model results (except notes you saved), sources.

## Failure behaviour

| Failure | Result | Recovery |
|---|---|---|
| Customized realtime session rejected | Next step of the start ladder; Settings shows Selected vs Active voice and the reason | Automatic; Apply now after changing the voice |
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
- The DAT 1.0 upgrade (full-resolution stills, Hey Meta, worn state) is planned on a separate branch after Meta's firmware and app rollout reaches the glasses; see `DAT_1_MIGRATION.md`.
- The private ChatGPT transport is unsupported by OpenAI. A server change may need a bridge update.
