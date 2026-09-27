# AutoLoom Media Glasses architecture

AutoLoom Media Glasses is an iPhone app for natural voice, vision, and web answers on the iPhone and Meta glasses. It is built on GlassifAI (MIT) and combines:
- a native SwiftUI app
- Meta's Wearables Device Access Toolkit (DAT 0.4.0)
- LiveKit's WebRTC framework
- a small Rust bridge built from pinned OpenAI Codex sources

It has no backend. Everything runs on the iPhone against the user's own ChatGPT account.

Internal type, target, and module names keep the `GlassifAI` prefix. The project structure, bundle ID, URL scheme, and Keychain service are unchanged, so the device-verified setup keeps working.

## System overview

```text
┌──────────────────────────────────── iPhone ─────────────────────────────────────┐
│                                                                                 │
│  Capture                               FrameStore (latest frame per source)     │
│  ├─ Ray-Ban (DAT raw 420v) ─ copy ──┬─► single pending slot ─► preview layer    │
│  │   (callback thread, no main hop) └─► latest frame + FPS/latency metrics      │
│  └─ iPhone AVCapture ─ ≤10 fps ─────────► latest frame (preview via AVCapture)  │
│                                                                                 │
│  GlassifAIRealtimeSession (WebRTC mic/speaker, data channel, captions)          │
│        │  delegation.created (TASK/QUERY envelope)                              │
│        ▼                                                                        │
│  AssistantOrchestrator ── TaskLedger (session/turn/task IDs, phases, T0–T5)     │
│   ├─ verify route (camera off? web off? action?)                                │
│   ├─ VISION ─────────► fresh frame ≤1 s ─► JPEG once ─┐                         │
│   ├─ WEB / VISION+WEB ► hosted web_search (fallback: backend search) ─┐         │
│   ├─ DEEP_REASONING / GENERAL_CHAT / LOCAL_MEMORY ─────────────────────┤         │
│   └─ no envelope ────► executor chooses tools (web, look_at_camera) ───┤         │
│                                                    ResponsesClient (SSE)        │
│        ▲ speakable result (sideband, ≤500 B chunks)          │                  │
│        └──────────────────────────────────────────────────────┘                 │
│                                                                                 │
│  ConversationContext (in memory) · LocalMemoryStore (opt-in) · Keychain (OAuth) │
│  GlassifAICodexBridge (Rust): call creation, reconnecting sideband, event queue │
└───────────────────────────────┬─────────────────────────────────────────────────┘
                                │
        auth.openai.com (device OAuth) · chatgpt.com/backend-api/codex (voice, responses, search)
        · api.openai.com/v1/live/{call_id} (sideband)
```

## Components

| Component | Responsibility | Files |
|---|---|---|
| App root | Restores login, picks onboarding or the main experience, initializes DAT | `GlassifAIApp.swift` |
| Authentication | Device-code login, refresh (including forced refresh after a 401), model discovery | `Runtime/ChatGPTAuthSession.swift`, `Runtime/ChatGPTKeychain.swift` |
| Voice session | Audio session, WebRTC, data channel, captions, turn tracking, local stop-speaking, v2 start with baseline fallback | `Runtime/GlassifAIRealtimeSession.swift` |
| Native bridge | Call creation (v1 baseline and v2 options), sideband with reconnect and generation guard, bounded event queue, context append | `native/GlassifAICodexBridge/src/lib.rs` |
| Routing policy | Delegation envelope parser, realtime and executor instructions, model selection, tool definitions, user preferences | `Runtime/RoutingPolicy.swift` |
| Orchestrator | Verifies routes, runs tasks, cancellation, stale-result guard, sources, activity state | `Runtime/AssistantOrchestrator.swift`, `Runtime/AssistantTasks.swift` |
| Responses client | Streaming SSE client, error mapping and retry, citations and search-call parsing; direct search fallback | `Runtime/ResponsesClient.swift` |
| Context and memory | Bounded conversation context, resume summary, opt-in on-device memory | `Runtime/ConversationContext.swift` |
| Frame pipeline | Latest-frame store, metrics, pixel-buffer copy, low-latency preview, on-demand vision encoder | `Runtime/FramePipeline.swift` |
| Glasses stream | DAT session, permissions, stream profiles, legacy preview path, background decode | `ViewModels/StreamSessionViewModel.swift`, `ViewModels/VideoDecoder.swift` |
| iPhone camera | AVCapture session and preview; throttled frame hand-off | `Runtime/GlassifAICamera.swift` |
| Audio route | Route/interruption/media-reset monitoring; glasses HFP selection that ignores other headsets | `Runtime/AudioRouteMonitor.swift` |
| Safety | Log sanitizer, SSRF-safe URL checks, untrusted-content wrapper | `Runtime/PrivacyGuards.swift` |
| UI | Main screen, camera switch, status, text input, source cards, settings, diagnostics, licenses | `Runtime/GlassifAIExperienceView.swift`, `Settings/SettingsView.swift`, `Runtime/SettingsSections.swift` |

## Task routing

The realtime voice model answers ordinary conversation itself; it doesn't delegate chat. It delegates only for vision, current information, deep reasoning, memory, or cancellation. The delegation is a structured line:

```text
TASK: <vision|web|vision_web|reasoning|memory|cancel> | QUERY: <self-contained request with conversation details>
```

1. **Verified delegation.** `DelegationEnvelopeParser` accepts the line format or JSON and maps the task to a known kind. Unknown kinds or empty queries are rejected.
2. **Verification.** Before anything runs, the orchestrator checks the route against real state:
   - camera off → the assistant says so
   - web search disabled → vision+web becomes vision only; web-only is declined
   - memory off → the assistant says so
   - `AUTHORIZED_ACTION` → declined honestly
3. **Tool routing fallback.** If the delegation has no valid envelope (for example, the model sent the raw user transcript), the executor model gets the request plus context. It chooses tools itself: hosted `web_search` and a `look_at_camera` function. When it calls `look_at_camera`, the app takes a fresh frame and runs the vision (or vision+web) path.
4. **Web search fallback.** If a model rejects the hosted tool (HTTP 400), the app remembers that for this run. It then uses the backend search endpoint and hands the results to the model as untrusted content. In tool routing, a client `search_web` function replaces the hosted tool.

No keyword lists decide the route. The decision comes from the voice model's structured output, the executor's tool choice, and explicit state checks.

### Task tracking and cancellation

- Each task records session ID, turn ID, task ID, handoff ID, source (voice/typed), start time, kind, route origin, model, phase, frame details, and a timeline.
- A newer delegation supersedes older voice tasks. "Görevi iptal et" (`TASK: cancel`) and the on-screen cancel button cancel the Swift task, which also cancels the URL request.
- A result is delivered only if its task is still running and belongs to the live voice session. Results from cancelled, superseded, or earlier-session tasks are discarded. The same handoff arriving over both the data channel and the sideband runs once.

### Latency timeline (vision)

| Mark | Meaning |
|---|---|
| T0 | Delegation received (speech intent detected by the voice model) |
| T1 | Fresh frame selected |
| T2 | JPEG prepared |
| T3 | Request sent |
| T4 | First model output (network + model) |
| T5 | Speech started after the result was handed back |

These appear per task in Diagnostics → Recent tasks, broken down as camera, image processing, network + model, voice start, and total.

## Voice call lifecycle

1. Configure `AVAudioSession` (`.playAndRecord`, `.voiceChat`). Glasses HFP is preferred when the audio route asks for it. The Meta-named port is chosen, and a lone unnamed HFP port is used only if it is the only one, so AirPods are never grabbed by mistake. The "iPhone" route forces the built-in mic and speaker.
2. Create the WebRTC peer, mic track, send-only video transceiver, and negotiated data channel.
3. Create the SDP offer and wait briefly for ICE gathering.
4. Get fresh tokens. Call `glassifai_codex_realtime_start_v2` with AutoLoom instructions, the voice, and an optional resume summary. If the server rejects it, the app retries at once with the original `glassifai_codex_realtime_start` configuration, which is device-verified.
5. Apply the answer SDP and wait for the data channel. The bridge joins the sideband.
6. Captions and turns come from the data channel. Delegations come from both the sideband and the data channel (deduplicated).
7. Sideband drops are retried with the same call ID (200 ms → 5 s backoff, 6 attempts; stops on 404/410). Only a terminal `ended:` status fails the call. A generation counter stops late events from a previous call leaking into the next one.
8. Teardown closes the sideband, data channel, tracks, peer, and audio session, and ends the orchestrator session so pending results are discarded.

Interruptions (phone calls, Siri) and media-server resets are observed. A media reset ends the call with a "tap to reconnect" message.

## Hands-free active-call controls

Unchanged from GlassifAI. A capability-free DAT `DeviceStateSession` maps running↔paused transitions to microphone mute toggles, and active→stopped (long press, doff, fold, link loss) to ending the call.

## Camera pipeline

See `RAYBAN_CAMERA_CAPABILITIES.md` for the full measured chain. In summary:
- Ray-Ban frames are copied once on the SDK callback thread into an app-owned buffer and sent to `AVSampleBufferDisplayLayer` through a single pending slot. There is no main-thread work, no `UIImage`, and no backlog.
- iPhone frames are stored at up to 10 fps; `AVCaptureVideoPreviewLayer` draws the preview.
- Vision frames are encoded on demand from the newest source buffer (at most 1.0 s old, waiting up to 1.5 s). They are never taken from the preview. The cache is cleared when the camera source changes.

## Concurrency

- UI, orchestrator, ledger, context, and audio monitor are `@MainActor`.
- Frame ingestion, the preview renderer, the frame store, and the copier are lock-protected and run on capture/SDK threads.
- Model requests are async `URLSession` byte streams. Cancelling the Swift task cancels the request.
- The bridge runs call creation on a short-lived Tokio runtime and the sideband on its own thread. The C ABI queues are mutex-protected and bounded (256 events, 8 pending commands).

## Persistence

| Stored | Where |
|---|---|
| OAuth tokens, account ID, expiry | Keychain (`AfterFirstUnlockThisDeviceOnly`) |
| Settings (camera source, audio route, voice, language, verbosity, web search, region, stream profile, preview mode, model override, memory toggle) | UserDefaults |
| Opt-in memory items | `Application Support/AutoLoom/memory.json` (complete file protection) |

Not stored: camera frames, audio, transcripts, sideband messages, SDP, call IDs, model results, sources.

## Failure behaviour

| Failure | User-visible result | Recovery |
|---|---|---|
| Customized realtime session rejected | Transparent fallback to the baseline session (shown in Diagnostics) | Automatic |
| Sideband drop | "reconnecting (n)" in Diagnostics; queued results are sent after reconnect | Automatic; the call fails only after `ended:` |
| No fresh frame / camera off | Spoken explanation | Point or enable the camera |
| Hosted web search rejected | Backend search fallback | Automatic |
| Network drop (Wi-Fi ↔ cellular) | One quick retry, then a spoken failure | Ask again |
| 401 | Forced token refresh, then retry | Sign in again if the refresh fails |
| 429 | "Rate-limited, try again shortly" | Wait |
| Glasses unavailable or folded | Placeholder text | Wake or unfold the glasses |
| Phone-call interruption | Audio resumes when iOS allows; the call fails only if ICE fails | Tap to reconnect |

## Compatibility policy

- The DAT 0.4.0 and LiveKit WebRTC Swift packages are pinned. The Codex source is vendored at 0.149.0, and its realtime wire code is byte-identical to upstream `main` as of 2026-09-27.
- The DAT 1.0.0 upgrade is planned after the Meta firmware and app rollout (see the camera document).
- The private ChatGPT transport is unsupported. A server change may need a bridge update.
