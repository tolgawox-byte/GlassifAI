# JARVIS implementation plan

## Türkçe özet

Plan beş fazdan oluşuyor:
1. temel altyapı
2. temel deneyim
3. görsel zekâ ve hafıza
4. araçlar ve cihaz entegrasyonları
5. araştırmadan çıkan yeni özellikler

Bu oturumda Faz 1'in en kritik maddeleri ve Faz 4'ün ana parçası (güvenli Windows PC companion) **uygulandı ve test edildi**. Kalan her madde için şunlar yazılı:
- kabul ölçütü
- test yöntemi
- bağımlılıklar

Her madde dört durumdan birinde:
- **YAPILDI** (otomatik testle doğrulandı)
- **CİHAZ TESTİ GEREKİYOR**
- **SIRADA**
- **ENGELLİ**

Hiçbir özellik gerçek cihaz testi olmadan "çalışıyor" sayılmaz.

## 0. Rules for every item

1. **Status words:**
   - DONE-CI: built and passing automated tests.
   - DEVICE TEST: needs the glasses or iPhone; listed in `docs/PHYSICAL_TEST_MATRIX.md`.
   - NEXT: the next session's work.
   - LATER.
   - BLOCKED: names who or what unblocks it.
2. No fake features. A control that cannot work yet is disabled and says why.
3. Every change keeps existing behaviour unless the item says otherwise, and every phase ends with the full CI suite (iOS + Rust + PC companion).
4. Security rules: model output never approves anything, never becomes a shell command, and never widens a permission.

## Phase 1 — Infrastructure (P0)

| # | Item | Status | Acceptance criteria | Tests |
|---|---|---|---|---|
| 1.1 | Audit the system | DONE | `JARVIS_AUDIT.md` with evidence labels | — |
| 1.2 | Realtime: no model self-confirmation | DONE-CI | `TASK: confirm_action` from the model never runs an action; only the bridge-parsed user yes or a tap | `testTheVoiceModelCannotConfirmAnActionItself`; physical SEC1 |
| 1.3 | Realtime: start/stop race, `error`/`halted`, data-channel loss, mic permission, faster ICE | DONE-CI (build) / DEVICE TEST | A stale start never tears down a newer call; no "failed" UI with a live mic; a closed data channel reconnects; a denied mic says so; start ≈2 s faster | Physical VC1–VC3 (the session is not unit-testable without WebRTC) |
| 1.4 | Realtime: structured errors from Rust | NEXT | `bridge_call` returns `{status, code, param, request_id, body_excerpt}`; Swift keeps them per attempt; the copied diagnostics report includes them | New Rust unit tests for the error JSON; Swift decode test |
| 1.5 | Realtime: timeouts, sideband reconnect fix, smarter start ladder | NEXT | Call creation ≤20 s; sideband connect ≤10 s; retry counter resets only after 30 s stable; first-connect 404 retried 3×; ladder stops on 401/403/429/5xx and refreshes on 401 | Rust tests for backoff/limits; ladder unit tests |
| 1.6 | Audio-flow watchdog | NEXT | After Ready, inbound/outbound RTP packet counts and mic energy are checked within 5 s; no flow → spoken explanation + one route/restart attempt | Unit test of the watchdog decision; physical |
| 1.7 | WebRTC audio-session configuration set explicitly; HFP before the camera stream | NEXT | `RTCAudioSessionConfiguration` matches the app's category/options; effective options logged at Ready; HFP route requested before `stream.start()` | Physical (Meta's documented order) |
| 1.8 | Offline cold launch keeps the session; logout cannot race a refresh | DONE-CI / DEVICE TEST | Network errors keep tokens; only 400/401/403 from the token endpoint sign out | `testRefreshFailuresKeepTheSessionUnlessTheServiceRejectsIt`; physical AU1 |
| 1.9 | DAT version honesty | DONE-CI / DEVICE TEST | `sdkUpdateRequired` and `deviceUpdateRequired` produce clear alerts at first read and on change | Physical DAT1 |
| 1.10 | Image source stated to the model | DONE-CI | iPhone frames are never described as the glasses' view | Physical CAM1 |
| 1.11 | CI supply chain | DONE (CI) | Build job read-only, actions SHA-pinned, one small publish job with write access, IPA retention 30 days | The next CI run itself |
| 1.12 | Live Vision camera-switch guard; capture-time freshness; late-still guard | NEXT | Live Vision stops or re-checks on a switch; frames older than 1 s by capture time are refused; a still is accepted only for the request that asked | Unit tests (FrameStore, StillPhotoCoordinator) |
| 1.13 | EXIF stripped from stills sent to providers | NEXT | Pass-through stills re-encoded without metadata (or verified to have none) | Unit test on a JPEG with GPS EXIF |
| 1.14 | Session-wide untrusted-content taint; memory saves gated on the user's words | NEXT | QR/translation/document/Live Vision text set the taint; delegated `save:` needs a bridge-parsed command or a confirmation; memories rendered as a quoted data block | New security tests (multi-turn injection) |
| 1.15 | Remote Assist Wi-Fi only + TLS; OpenClaw HTTPS + hostname fix; authentication on personal-data intents | NEXT | `requiredInterfaceType = .wifi`; no token over plain HTTP except loopback/Tailscale; `fc`/`fd` hostnames not private; intents require device unlock | Unit tests |
| 1.16 | Third-party notices and privacy copy | PARTLY DONE | LiveKit line fixed; add WebRTC/BoringSSL and Rust crate notices (`cargo about`), `PrivacyInfo.xcprivacy`, correct privacy-centre text | Review |

## Phase 2 — Core experience (P1)

| # | Item | Status | Acceptance criteria |
|---|---|---|---|
| 2.1 | Real connection and system state on Home | NEXT | One status strip: glasses link, voice session (real phases), camera source, PC reachability (answered < 30 s), pending approvals count; nothing green without a fresh fact |
| 2.2 | Reminders verified by fetch-back; list choice; complete/delete by voice | NEXT | After saving, `calendarItem(withIdentifier:)` returns the item or the reply says it failed |
| 2.3 | Tasks: priority, snooze, recurrence; notification delegate with Complete/Snooze actions | NEXT | Foreground banners; actions work from the lock screen; undo for completion |
| 2.4 | Approval inbox (F10) | NEXT | Every waiting phone action and PC task in one list; more than one slot; survives app restart |
| 2.5 | Persisted activity log on the phone | NEXT | Actions, approvals, PC tasks, failures kept 30 days (no content), viewable and exportable |
| 2.6 | Notes: attachments and visible links; bulk export | LATER | Photo/document attachments; links to tasks and conversations shown both ways; JSON/Markdown export |
| 2.7 | UI polish of inert rows and misleading copy | NEXT | Search, timeline and task rows open their item; privacy copy matches behaviour |

## Phase 3 — Visual intelligence and memory (P1/P2)

| # | Item | Status | Acceptance criteria |
|---|---|---|---|
| 3.1 | Diagnostics: "what the AI saw" | NEXT | Live Vision images recorded; destination provider/model; capture age; opt-in local thumbnail of the exact bytes; metadata status; glasses-only "Actual" |
| 3.2 | Memory supersession (F06) and memory inbox (F07) | NEXT | Outdated facts superseded with history; model proposals need approval |
| 3.3 | Semantic visual memory (F21) | LATER | On-device embeddings with a commercially licensed model; Turkish queries work; never indexes the photo library without consent |
| 3.4 | DAT 1.x port behind a camera-backend seam | NEXT (big) | Two builds share all code above the seam; full-resolution stills as an opt-in HIGH_DETAIL path; recording not cut by photos; D1–D11 pass on V128 |

## Phase 4 — Tools and device integrations

| # | Item | Status | Acceptance criteria |
|---|---|---|---|
| 4.1 | Windows PC companion (pairing, TLS pin, path policy, tools, task engine, approvals, audit, REST, MCP) | **DONE-CI** | 71 tests pass on Windows 11 and `windows-latest`; tsc strict clean |
| 4.2 | Phone PC client: pairing (Camera QR / paste), pinned transport, "Bilgisayar" skill with locative voice route, one-card approvals with the PC's own summary, Settings → Computer (PC), privacy wipe | DONE-CI (build + unit tests) / DEVICE TEST | Physical PC1–PC8 |
| 4.3 | Tap-confirmed agent/skill results shown | DONE-CI | `testATapShowsTheAnswerWithoutTheVoiceModelsInstructions` |
| 4.4 | PC: MCP 2026-07-28 support (dual-era) | LATER | `server/discover`, tasks extension; 2025-06-18 clients still work |
| 4.5 | PC: Secure Enclave request signing and signed approvals (F27) | LATER | Stolen bearer token alone useless; approvals signed and verified |
| 4.6 | PC: PDF via pdf.js in a worker; Windows OCR (F19); FTS5 index (F16) | LATER | Scanned PDFs readable; offline search across shared folders |
| 4.7 | PC: tray app, autostart, DPAPI for the key | LATER | Runs at sign-in without a terminal; key unusable outside the profile |
| 4.8 | Long-task relay in voice (F01) | NEXT | PC tasks over 10 s announced, results delivered later even after the conversation ended |
| 4.9 | iOS: Files import, share extension, widgets | BLOCKED | Extension signing in the sideloaded IPA (needs a paid developer team) |

## Phase 5 — New features from research

Ordered by value ÷ cost: F03 (audio watchdog, in 1.6), F10 (approval inbox, 2.4), F01 (relay, 4.8), F06/F07 (memory), F05 (egress PII screen), F04 (MCP definition pinning), F02 (frame pin), F13 (dry run), F14 (crash briefing), F09 (assistive mode), F24 (exposure profiles), F22 (latency timeline), then the P3 items. Details and sources: `JARVIS_FEATURE_RESEARCH.md` §5.

Multi-provider architecture: the existing router (ChatGPT, Claude, Gemini, Perplexity, OpenRouter, Apple on-device) stays. Next:
- an OpenAI API-key provider for the official Realtime API (`gpt-realtime-2.1`, image input);
- a spending cap with usage metering;
- routing by task type (fast / reasoning / vision / OCR / long document / code / embeddings).

All of these wait on the owner supplying keys and approving costs.

## Architecture decisions

| ADR | Decision | Why | Alternatives rejected |
|---|---|---|---|
| ADR-1 | The PC companion is Node.js + TypeScript (type stripping), no runtime dependencies | Node 22.18+ has HTTPS, X.509 parsing, ECDSA/P-256, AEAD, child processes and a test runner built in; no supply chain at runtime; Node is already on the PC | .NET (SDK not installed), Python (needs `cryptography` for TLS keys), Rust (toolchain absent, slow iteration from Windows) |
| ADR-2 | TLS with the PC's own key, pinned by the phone (SPKI-style pin of the EC point) | Encryption and server identity without a CA or a domain; renewals keep the pin | Plain HTTP + app-layer crypto (custom protocol risk); a public CA (needs a domain); Tailscale certs (optional later) |
| ADR-3 | Two channels: MCP for the model, REST for the human UI | The model can start and read tasks but cannot reach approvals, config or pairing | One combined API (the model could reach approvals); MCP-only (no human channel) |
| ADR-4 | Approvals bound to a digest of tool + arguments; destructive/execute always ask; policy changes void approvals | "What you see is what you approve" | Model-judged risk; pre-approval by a model flag |
| ADR-5 | DAT 0.5.0 stays the default; DAT 1.x is ported behind a camera-backend seam; 1.x becomes the default after device tests | 0.5.0 is not deprecated and is the tested base; 1.x has full-resolution stills | Blind SDK swap; maintaining dat1 as a permanent fork |
| ADR-6 | Keep the private ChatGPT transport for personal use; add an official-API provider for any commercial path | Works today on the owner's plan; commercial use needs supported APIs | Removing it (loses the plan-backed voice) |
| ADR-7 | PC actions reach voice through the existing MCP skill machinery (pinned), not a new voice protocol | Reuses tool choice, confirmation cards and untrusted wrapping that already have tests | A separate PC planner (duplicated logic) |

## Next session, in order

1. Read the CI results of this session's push and fix anything red (`TEST_REPORT.md`).
2. Owner's physical tests: AU1, SEC1, VC1–VC3, CAM1, DAT1, then PC1–PC8.
3. Phase 1 NEXT items: 1.4 → 1.5 → 1.6 → 1.7 → 1.12 → 1.13 → 1.14 → 1.15.
4. Phase 2: 2.1 (honest status strip) and 2.4 (approval inbox).
5. DAT 1.x port (3.4) once the glasses are on V128.
