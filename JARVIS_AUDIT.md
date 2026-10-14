# JARVIS audit — the real state of the system (2026-10-12)

## Türkçe özet

Bu belge, "JARVIS — GlassifAI Ultimate" çalışmasının başlangıç denetimidir. Kod tabanı (`autoloom-glasses-jarvis-v1`, `146a169`) yedi paralel inceleme ile tarandı:
1. realtime/Rust köprüsü
2. kamera ve DAT
3. ses ve Bluetooth
4. özelliklerin gerçek durumu ve arayüz
5. güvenlik ve CI
6. GitHub araştırması (gözlük ve görüntü)
7. GitHub araştırması (Jarvis, PC kontrolü, hafıza)

Her iddia kaynağa bakılarak etiketlendi: DOĞRULANDI (kod okundu), BELGE (resmî doküman) veya DOĞRULANMADI. Gerçek gözlük veya iPhone ile test yapılmadı. Bu ortamda Xcode yok; iOS derleme ve testleri GitHub Actions'ta çalışır.

**En önemli sonuçlar:**
- **Sesli bağlantı (HTTP 400 / "session mode"):** Depoda kayıtlı bir realtime HTTP 400 yok.
  - `RealtimeSessionMode::Conversational` bu protokolde sunucuya hiç gönderilmiyor, dolayısıyla 400'ün nedeni olamaz.
  - `gpt-live-1-codex` güncel upstream'de de aynı.
  - Asıl sorun hata ayrıntılarının kaybolması: 120–200 karaktere kesiliyor; `param`, `code` ve istek kimliği düşüyor.
- **Güvenlik (kritik):** Sesli model, bekleyen bir işlemi kullanıcı "evet" demeden kendi onaylayabiliyordu. **Bu oturumda düzeltildi.**
- **CI tedarik zinciri:** İş akışı tüm iş boyunca repo'ya yazma yetkisiyle ve sabitlenmemiş bir action ile çalışıyordu. **Bu oturumda düzeltildi.**
- **Kamera:** AI'ya ekran görüntüsü, önizleme veya sahte görüntü gitmiyor.
  - Ancak iPhone kamerası seçiliyken bile modele "gözlüğün görüntüsü" deniyordu. **Düzeltildi.**
  - Gözlüğün galerisindeki orijinal medyaya erişen bir DAT API'si yok (0.5.0 ve 1.0.1).
  - Canlı akış en fazla 720×1280.
- **DAT:** En güncel sürüm 1.0.1 (2026-10-09). 0.5.0 resmî olarak engellenmiş değil, ama kesilebilir.
  - Uygulama `sdkUpdateRequired` uyarısını hiç göstermiyordu. **Düzeltildi.**
- **Windows:** Hiç yoktu. **Bu oturumda güvenli bir PC companion yazıldı ve test edildi** (71 test).
- **Çevrimdışı açılış:** Süresi dolmuş token ile çevrimdışı açılışta ChatGPT oturumu siliniyor ve uygulama kilitleniyordu. **Düzeltildi.**

## 1. Scope, method and limits

| Item | Value |
|---|---|
| Repository | `C:\Users\tolga\Projects\GlassifAI` (fork `tolgawox-byte/GlassifAI`, upstream `iannellomarco/GlassifAI`) |
| Branch / commit audited | `autoloom-glasses-jarvis-v1` @ `146a169` (v1.5 "Ultimate Jarvis"), working tree clean |
| Rollback point | tag `rollback-146a169-before-jarvis-ultimate` (pushed) |
| Other branches | `autoloom-glasses-dat1` (v1.1.1 on DAT 1.0.0, 33 commits behind), `vNext`, `next`, `main` (untouched) |
| Method | Seven read-only review streams in parallel (R1–R7 below), each required to cite file:line or URLs and to label claims VERIFIED / DOCS / UNVERIFIED |
| Not possible here | Building or running iOS locally (no Xcode, no device), running the Rust tests locally (no cargo), any test with the glasses or the iPhone |
| Possible here | Building and testing the Windows companion end to end (Windows 11, Node 24) |

| Stream | Topic |
|---|---|
| R1 | Realtime voice bridge (`native/GlassifAICodexBridge/src/lib.rs`), Swift↔Rust flow, upstream Codex drift, the HTTP 400 history |
| R2 | Camera and media pipeline, image provenance, DAT versions and capabilities |
| R3 | Audio session, Bluetooth HFP, WebRTC, reconnect, background behaviour |
| R4 | Notes, tasks, reminders, memory, visual memory, action engine, providers, MCP, UI |
| R5 | Secrets, credentials, logging, network, prompt injection, licences, CI, tests |
| R6 | GitHub research: glasses, live vision, realtime voice, visual memory (34 repositories) |
| R7 | GitHub research: Jarvis assistants, PC control, MCP, memory, task engines, documents (83 sources) |

The full reports (about 92,000 words) are kept outside the public repository (see §11). This file keeps what matters, without exploit-level detail for problems that are still open.

## 2. What the system really is

```text
Ray-Ban Meta ──DAT 0.5.0 (HEVC 720p stream, in-stream JPEG stills)──► iPhone app (SwiftUI)
                                                                          │
     ChatGPT account: realtime voice (WebRTC + private Codex call API,   │  Swift: camera, frames, UI, actions,
     model gpt-live-1-codex) and Responses (vision, web, reasoning)  ◄────┤  memory (SwiftData), EventKit, MCP client
                                                                          │  Rust (vendored Codex 0.149.0): call creation, sideband
     Optional: Claude / Gemini / Perplexity / OpenRouter (own keys),     │
     the user's OpenClaw gateway, MCP servers, Remote Assist viewers ◄────┘
NEW: Windows PC ◄── HTTPS, pinned key, paired token ── iPhone (PC Companion)
```

- Voice: the app creates a call through the user's **ChatGPT subscription** using pinned OpenAI Codex code (private, unsupported transport). Swift runs WebRTC; Rust creates the call and runs the sideband.
- Everything runs on the phone; there is no AutoLoom backend. Credentials live in the Keychain (`AfterFirstUnlockThisDeviceOnly`).
- The last device-verified build is `baseline-44f089d-vision-working` (DAT 0.4.0). **None of v1.4/v1.5 has been run on the glasses** (`TEST_REPORT.md`).

## 3. Area-by-area status

Status words: **WORKING-IN-CODE** (complete path + automated tests; no device test), **PARTIAL**, **DESIGN-ONLY**, **MISSING**, **FIXED-NOW** (changed in this session, see §10).

| Area | Status | Key facts (VERIFIED unless marked) | Main gaps |
|---|---|---|---|
| Realtime voice (bridge) | WORKING-IN-CODE; device-verified in v1.0 era | Wire code byte-identical to upstream through `main` `0c329ad2` (2026-10-12); model `gpt-live-1-codex`; `Conversational` still valid | Error details truncated; no timeouts; sideband reconnect loop risk; static attestation header (§4) |
| Audio / Bluetooth | PARTIAL | `.playAndRecord/.voiceChat`, HFP preferred for glasses, interruption + media-reset observers | No audio-flow watchdog; HFP configured after the camera stream starts (Meta warns it can fail); WebRTC re-applies its own session settings (UNVERIFIED on device) |
| Camera → AI | WORKING-IN-CODE | Real frames only (no screenshot/preview/mock path); best-of-recent selection; 768/1280/2048 px profiles; epoch guard on camera switch | Prompts said "glasses" for iPhone frames (**FIXED-NOW**); Live Vision ignores camera switches; freshness from arrival time; late still can answer the next request |
| Glasses photos / videos | WORKING-IN-CODE | Stills saved byte-for-byte; videos = 720p stream, no audio | No original-media API exists (0.5.0 and 1.0.1) |
| DAT version | Risk | 0.5.0 linked; latest 1.0.1 (2026-10-09); 0.5.0 still listed by Meta, no deprecation | `sdkUpdateRequired` was never surfaced (**FIXED-NOW**); dat1 branch 33 commits behind |
| Notes | WORKING-IN-CODE | SwiftData, 60 s duplicate guard, rollback on failed save, search with Turkish folding | No attachments; links written but never shown; no bulk export |
| Tasks (app's own) | PARTIAL | Create/complete/move/undo-move | `priority` never set; no snooze and no notification delegate (**FIXED (CI)**, phase 1f: Complete and Snooze from the alert); no recurrence (**FIXED (CI)**, run 38489746020, with undo of a spoken completion) |
| Apple Reminders / Calendar | PARTIAL | Create/list; ambiguous time asked first; location alarms | Not fetched back after saving (**FIXED (CI)**, plan 2.2); default list only and no voice complete/delete (**FIXED (CI)**, run 38485233267: a list by name or from Settings, complete with undo, delete after a yes, each read back) |
| Memory | PARTIAL | Explicit save via parser; summaries; 12-line prompt cap | Model-delegated saves trusted without the user's words; no export |
| Visual memory | WORKING-IN-CODE (lexical) | Opt-in; OCR + labels; honest "not found"; photos never read from the library | No image embeddings; a half match can win |
| Action engine | PARTIAL | SAFE / CONFIRM / STRONG CONFIRM; untrusted-content raise | Model could confirm its own actions (**FIXED-NOW**); one pending slot (**IN CI**, plan 2.4: up to five, each card its own); undo misses EventKit (a reminder completed by voice can now be reopened, **FIXED (CI)**); staged graph steps reported as done (**FIXED (CI)**, run 38485233267) |
| Providers | WORKING-IN-CODE | ChatGPT; Claude/Gemini/Perplexity/OpenRouter adapters (keys in Keychain) | No OpenAI API-key provider; no spending cap |
| MCP skills | PARTIAL | https only, Keychain token, per-tool policy | No pinning (**FIXED-NOW** for the PC); tap-confirmed results discarded (**FIXED-NOW**) |
| Remote Assist | WORKING-IN-CODE | Tap-only start, red bar, 6-digit code | Plain HTTP; listener on all interfaces |
| Offline | PARTIAL | Typed commands run on device | Offline cold launch deleted the ChatGPT session (**FIXED-NOW**); no offline voice |
| Windows PC | MISSING → **FIXED-NOW** | New `pc-companion/` | See `docs/PC_COMPANION.md` |
| UI | WORKING-IN-CODE | 5 tabs, no placeholder buttons | Some inert rows (search/timeline), misleading privacy copy (§7) |
| CI / tests | WORKING | 325 iOS test methods (323 run in CI), 8 Rust tests | Write token for the whole job (**FIXED-NOW**); Keychain tests skip in CI |

## 4. Realtime voice and the HTTP 400 question (R1)

**Data flow (VERIFIED):**
1. Swift (`GlassifAIRealtimeSession.start`) configures audio, creates the WebRTC peer, mic track, a send-only video transceiver with no track, and a negotiated data channel.
2. It creates the SDP offer and calls `EmbeddedCodexBridge` → C FFI → Rust `bridge_call`.
3. Rust posts `…/realtime/calls?intent=quicksilver&architecture=avas` with `{sdp, session}`, model `gpt-live-1-codex`, frameless (v3) protocol, voice and instructions.
4. Swift sets the answer SDP and waits for the data channel.
5. Rust runs the sideband at `wss://api.openai.com/v1/live/{call_id}`.
6. Delegations arrive on both channels and are de-duplicated.

**Upstream comparison (VERIFIED):**
- The vendored crates equal `rust-v0.149.0`, plus the iOS certificate patch.
- Upstream `main` is `0c329ad2` (2026-10-12); the latest stable is `rust-v0.162.1` (2026-10-09).
- The realtime wire code (call creation, parsers, session JSON, `RealtimeSessionMode`) is byte-identical through `main`.
- `gpt-live-1-codex` has been the model since 0.150.0.
- Main added 16 new v3 voices on 2026-10-09.
- A vendor bump would need a code change: `RealtimeWebsocketClient::new` now takes a second argument.

**HTTP 400 / "session mode" (VERIFIED):**
- No realtime HTTP 400 is recorded anywhere in this repository's history. The recorded realtime fixes are:
  - the model rename (`74d9be5`): `gpt-live-1-boulder-alpha` → `gpt-live-1-codex`;
  - the rejected v2 voices (`204ccc1`).

  The current code matches both.
- `RealtimeSessionMode` is **not sent** for this protocol. The "session mode" errors in Codex are client-side checks in code the bridge does not use, so session mode cannot cause a 400 here. The diagnostics label "Baseline fallback (v1)" names a bridge entry point and is easy to misread as a mode problem.
- One server-side 400 is documented upstream: `invalid_quicksilver_alpha_header` (openai/codex #41668). The bridge sends the correct header.
- Plausible future 400 causes (UNVERIFIED): stricter validation of `ack_filler` or `initial_items`, the static `x-oai-attestation` value, or a changed alpha header.

**Real problems (VERIFIED), with status:**

| Problem | Where | Status |
|---|---|---|
| Error details lost: one string cut to 120–200 characters; `param`, `code` and request IDs dropped; sideband handshake bodies dropped; diagnostics copy omits per-step attempts | `lib.rs:517-521`, vendored `methods.rs:969-977`, Swift report | **FIXED (CI, bridge 4)**: status, code, param, type, message, request id and a 600-byte body excerpt per failed step, in Voice diagnostics and the copied report. Sideband handshake bodies are still dropped inside the vendored code |
| A data-channel `error` event marked the call failed without hanging up; nested `error.message` ignored | `GlassifAIRealtimeSession.swift` `case "error"` | **FIXED-NOW**: recorded with code, call kept; a closed data channel now reconnects |
| `start()` never closed an existing peer; a stop during a start could let the old start tear down the new call | `start()`, catch block | **FIXED-NOW**: generation token, leftover peer torn down |
| `halted` set "disconnected" while the peer stayed alive | `applyLegacyState` | **FIXED-NOW**: hangs up properly |
| No timeouts on call creation or sideband connect | `lib.rs` | **FIXED (CI)**: 20 s call creation, 10 s sideband handshake (a stop is honoured meanwhile) |
| Sideband retry counter resets on every connect; a first-connect 404 ends the sideband (upstream #35094 reports this 404) | `lib.rs:294-297` | **FIXED (CI)**: the budget starts over only after 30 s of stable connection; a first-connect 404 is retried 3 times |
| The start ladder resends the same offer for errors no step can fix (401/403/429/5xx), never refreshes on 401 | `VoiceCatalog.swift` `RealtimeStartLadder` | **FIXED (CI)**: 401/403 refresh once and repeat the step, then stop; 429/5xx stop |
| Static `x-oai-attestation` claiming `com.openai.codex`; no User-Agent / `x-session-id` | `lib.rs:443-449` | Open: owner decision (see §8, legal) and an on-device A/B test |
| 2.5 s fixed wait for ICE gathering on every start (never completes with continual gathering and no STUN servers) | `start()` | **FIXED-NOW**: proceeds 200 ms after the first host candidate |

**Official alternatives (DOCS), for a "bring your own key" or commercial path:**
- **GPT-Live** `gpt-live-1` via `POST /v1/live/sessions`, with client delegation. It takes no image input, costs $0.05/min, and needs its own adapter.
- **Realtime API** `gpt-realtime-2.1` via `/v1/realtime/calls` or client secrets. It takes image input and supports function calling.
- "Sign in with ChatGPT" plan usage covers the Responses API, not audio.

## 5. Camera and media: where every image comes from (R2)

| # | Category | Source | Size / codec | Stored | Metadata |
|---|---|---|---|---|---|
| 1 | Live stream (glasses) | DAT 0.5.0 `StreamSession`, HEVC (`hvc1`) or raw | Requested 720×1280 @ 15 fps; the glasses may step down (504×896) | RAM only (`FrameStore`: latest + 8 recent) | none |
| 1b | Live stream (iPhone) | `AVCaptureSession`, back wide camera | preset `.high`, ≤10 fps to the store | RAM only | none |
| 2 | Frames sent to the AI | Best recent frame of the same scene (≤1 s old), or a DAT still | FAST 432×768 q0.75 · BALANCED 720×1280 q0.85 · HIGH 1152×2048 (1.6× upscale) q0.92 + optional text crop | not stored | none for video frames; **pass-through stills keep DAT's original bytes** |
| 3 | Glasses photos | DAT in-stream `capturePhoto(.jpeg)` | size undocumented in 0.5.0 | Photos (add-only) or app Captures | kept as DAT sent |
| 4 | Glasses videos | DAT stream samples → `RayBanVideoRecorder` | ≤720p stream, HEVC, **no audio** | Photos or Captures | none written |
| 5 | Originals from the glasses' gallery | **No API** in DAT 0.5.0 or 1.0.1 | — | — | — |
| 6 | In-app preview | `AVSampleBufferDisplayLayer` / `AVCaptureVideoPreviewLayer` | display only | never read back | — |
| 7 | AI-derived copies | Encoder, crops, visual-memory 480/1600 px, Remote Assist 720 px | re-encodes | visual memory folder (opt-in) | none |

**Can the AI see something other than the real camera? (VERIFIED)**
- **Guarded:**
  - the UI, screenshots or the preview (never read back);
  - the Mock Device Kit (test target only);
  - screenshot-mode placeholders;
  - a stale frame after a camera switch for task vision (epoch check);
  - video over the voice call (the transceiver has no track).
- **Gaps:**
  - The prompts called every image "first-person view from the glasses", even iPhone frames. **FIXED-NOW:** the image's real source is now stated in the instructions.
  - Live Vision does not re-check the source or epoch after describing a frame, and a camera switch does not stop it (`LiveVision.swift:219-243`).
  - Frame age is measured from arrival or decode, not capture time.
  - A late still photo can answer the next request (`VisionCapture.swift:300-317`).
  - QR/document/translation reads take a still with a random task id that fails the ledger check, and are logged as "sent to the AI" although they are on-device.
  - Pass-through stills send DAT's original JPEG bytes (with any EXIF) to providers.

**Diagnostics:** "Last image sent to the AI" already shows the source, source → encoded size, JPEG quality, bytes, age and pipeline. It is missing:
- Live Vision images;
- the destination provider or model;
- the capture age;
- an opt-in thumbnail of the exact bytes;
- metadata-stripped status;
- a glasses-only "Actual" line.

**DAT facts:**
- Latest iOS SDK: 1.0.1 (2026-10-09). Its public API is identical to 1.0.0 (2026-09-24).
- Minimum versions:
  - 0.5.0: Meta AI V254, firmware V22;
  - 1.0.0: Meta AI V290, firmware V128;
  - 1.0.1: Meta AI V292, firmware V128.
- DAT 1.x needs iOS 17.2; the app targets 17.0.
- 1.x full-resolution still: 4032×3024. It is beta, cannot be published, and the stream must stop for each capture.
- Neither version has an API for video recording or for the glasses' gallery.
- Known issue: after the V128 OTA, reboot the glasses or camera capture fails.

**Recommendation:**
- Keep DAT 0.5.0 as the default build. It now warns clearly on `sdkUpdateRequired`.
- Port v1.5 to 1.0.x behind a shared camera-backend seam: about 3–5 developer-days, medium-high risk.
- Make 1.x the default once device tests D1–D11 pass on V128.

## 6. Voice, audio and Bluetooth (R3)

| Symptom | Likely root cause (VERIFIED in code unless noted) | Status |
|---|---|---|
| "Listening" but nobody hears / nothing heard | Ready = data channel open + any input route; no RTP/mic-energy watchdog; no mic-permission check; glasses HFP set up after the camera stream (Meta: can fail silently); interruption end never resumes | Mic permission check **FIXED-NOW**; audio-flow watchdog **FIXED (CI)** (one reconnect per conversation, physical AU3); HFP-before-stream order **open** (needs an owner decision after AU2/AU3, see plan 1.7) |
| A stopped call comes back or a new call dies | Stop/start race (old start tears down new call) | **FIXED-NOW** |
| UI "failed" while the mic is live | `error` / `halted` handling | **FIXED-NOW** |
| Speech from the earpiece / music interrupted | WebRTC re-applies its own `RTCAudioSessionConfiguration` (VERIFIED in LiveKit source, not in the shipped binary) | **FIXED (CI)**: the app's category, mode and options are mirrored into WebRTC's configuration before each start; the effective session is shown in Voice diagnostics (physical AU2) |
| Call ends after a short network blip | One reconnect attempt after a fixed 1 s; ICE `.disconnected`, data-channel close and network changes ignored | Data-channel close **FIXED-NOW**; backoff loop open (P1) |
| Glasses go deaf mid-call (UNVERIFIED) | `setPreferredInput` re-applied on every route change (VisionClaw notes this exact failure) | Open: physical test, then a once-per-call rule |
| CarPlay/wired audio forced to the speaker | Route policy when glasses are preferred but absent | Open (P1) |
| Silent endings | Quiet timeout, server goodbye and gestures end without a sound; temple tap mutes instead of stopping the answer | Open (P2) |

Logging: tokens and transcripts are never logged (VERIFIED); the Bluetooth device name is logged unsanitized (open, low).

## 7. Features, UI and documentation drift (R4)

What is solid (VERIFIED): notes, the app's tasks, memory, visual memory, the Turkish/English command parser, confirmation levels and honest failure messages all have complete code paths and unit tests.

Gaps that matter for JARVIS (top of R4's list):
- no real PC channel (now added);
- tap-confirmed MCP results were discarded (now fixed);
- no persisted activity or audit log on the phone;
- offline cold launch locked the app (now fixed);
- one pending-approval slot, expiring after 120 s;
- minimal reminders;
- shallow tasks;
- undo depends on order and misses EventKit items;
- notes have no attachments or visible links;
- lexical visual search;
- memory consent partly enforced only by prompt text;
- search ignores Reminders, Calendar and Contacts, and its rows are inert;
- app actions are not exposed as model tools;
- staged multi-step results are reported as done;
- misleading trust copy.

Misleading UI copy (VERIFIED, all open unless noted):
- The privacy centre and About say reminders and events "need your yes"; they run at once.
- "What leaves this iPhone" leaves out Claude, Gemini, Perplexity, OpenRouter, MCP, OpenClaw, Remote Assist and the dealer lookups.
- The Shortcuts text lists 3 of 17 intents.
- The offline chip implies voice works offline.
- Swipe-deletes have no confirmation.
- The master "Allow iPhone actions" switch does not stop notes, memory or the clipboard.

Stale docs:
- `CAPABILITIES.md` rows on receipts, multi-command, global search and offline;
- the "known gap" in `REMOTE_ASSIST.md` (already fixed in code);
- the wipe note in `SKILLS_MCP.md`;
- the filter note in `SPOTLIGHT.md`;
- the classifier limit in `ACTION_CATALOG.md`;
- kind and category counts in `MEMORY_ARCHITECTURE.md`.

## 8. Security, privacy and licences (R5)

No real secrets in the working tree or the full history of all refs: 296 pattern hits, all fixtures or placeholders (VERIFIED). Keychain use is sound; there is no TLS bypass.

| ID | Severity | Finding | Status |
|---|---|---|---|
| H1 | High | The voice model could confirm a waiting CONFIRM-level action itself (`TASK: confirm_action`), so injected text could approve its own agent/MCP request | **FIXED-NOW**: only the user's own words (deterministic parser) or a tap confirm; test added |
| H2 | High | CI job had `contents: write` for all steps, credentials persisted, `dtolnay/rust-toolchain@stable` unpinned, 550+ crate build scripts running with the token; the IPAs from this job are installed on the phone | **FIXED-NOW**: read-only build job, `persist-credentials: false`, all actions SHA-pinned, a separate 10-line publish job holds the only write token; IPA retention 30 days |
| H3 | High (legal) | Private ChatGPT/Codex endpoints under the Codex CLI identity with a static attestation header | **Owner decision.** Fine for personal use at your own risk; any commercial release needs the official API (§4) |
| H4 | High (legal) | Meta DAT is a developer preview for test users; sample-code terms bar production use without Meta's written permission; six files carry Meta headers pointing at the now-MIT LICENSE | **Owner decision** + header fix (open) |
| M1 | Medium | Untrusted-content flag lasts one turn; QR/translation/document/Live Vision text never sets it; model-delegated memory saves need no user words and memories are injected into every prompt | **FIXED (CI)**: conversation-wide mark set by all of those sources; model-delegated saves refused while it is set; personal-data reads need a yes; memories and the previous summary are quoted data; outside text cannot pose as an app message. Model-started Live Vision is not gated yet (plan 1.14) |
| M2 | Medium | Contact names/numbers are sent to the realtime model although the docs say "not uploaded" | **FIXED (CI)**: lookups the assistant makes on its own send names and labels only (numbers on screen); a number the user asks to hear still goes to the voice model, and the privacy page now says so |
| M3 | Medium | Remote Assist: plain HTTP, code in URL, listener on all interfaces | **Partly FIXED (CI)**: Wi-Fi only, local network only, four viewers, 10 s request timeout. TLS and the code in the URL are still open |
| M4 | Medium | OpenClaw token may travel over plain HTTP; hostnames starting "fc"/"fd" count as private | **FIXED (CI)**: host names are parsed properly; the token goes over plain HTTP only to loopback or Tailscale; home-network HTTP shows a warning |
| M5 | Medium | Personal-data App Intents have no authentication policy (may run from a locked phone) | **FIXED (CI)**: briefing, find-vehicle and remember intents require an unlocked phone; tasks, notes and the shopping list stay hands-free |
| M6–M9 | Medium | Privacy docs wrong in places; third-party notices incomplete (LiveKit was listed as Apache — **FIXED-NOW** to MIT; WebRTC/BoringSSL and Rust crate notices still missing); no `PrivacyInfo.xcprivacy`; private vulnerability reporting disabled while SECURITY.md points to it | Partly fixed; rest open — Update: notices for the modified Codex files and `vendor/codex/MODIFICATIONS.md`, full in-app license texts, a privacy manifest, the Rust crates' texts in the app, and SECURITY.md wording (**FIXED (CI)**); the six MIT/BSD crates without a license file now have their repositories' texts (**FIXED (CI)**, run 38349904362); enabling private vulnerability reporting is the owner's action |
| L1–L12 | Low | IPv6/DNS gaps in URL safety, wrapper escaping (**FIXED (CI)**: any spelling of the tag is defused, origin escaped), log gaps, data-at-rest class C, wipe residue, Keychain survives uninstall, tokens deleted on any error (**FIXED-NOW**), URLSession.shared redirects (**FIXED (CI)**: ephemeral session, no redirects, 4 MB cap, tool list wrapped), screenshot mode in Release, public CI artifacts growth | Mostly open (P2) |

## 9. Tests and CI

- **iOS:** 29 test files, 325 test methods; CI runs 323 and excludes `ViewModelIntegrationTests` (it needs the Meta mock device).
- **Last green run before this work:** 36600758014 @ `a4e0eb3`: iOS 321/323, 2 Keychain tests skipped, Rust 8/8.
- **Rust:** 8 unit tests (options, voices, backoff, truncation). The call, the error JSON, the C interface and the sideband reconnect have no tests.
- **New in this session:**
  - Windows companion: 71 tests, plus tsc strict, plus a Windows CI workflow.
  - iOS: `AutoLoomPCCompanionTests` (9) and a security test for model self-confirmation.
  - Phase 1b (run 38327327122: iOS 342/344, Rust 13/13): `AutoLoomSecurityHardeningTests` (metadata strip, locked-phone intents, structured start errors and ladder, multi-turn memory poisoning, wrapper escaping), `AutoLoomRealtimeReliabilityTests` (audio-flow watchdog, effective audio session), and 5 more Rust tests (call error JSON, sideband budget, first-connect 404, timeouts).
- **Not covered by automated tests at all:**
  - the glasses (camera, HFP, gestures);
  - the realtime call;
  - EventKit writes;
  - Siri;
  - the Keychain in CI;
  - the iOS Local Network prompt;
  - phone ↔ PC over Wi-Fi.

  These are listed in `docs/PHYSICAL_TEST_MATRIX.md`.
- **Results of this session's CI runs:** `TEST_REPORT.md`.

## 10. Changed in this session (summary)

See `CHANGELOG.md` ("JARVIS Ultimate — phase 1") and `JARVIS_IMPLEMENTATION_PLAN.md` for the full list with files and tests. In short:
- **PC companion:** a new module with REST, MCP, pairing, pinned TLS, path policy, tools, task engine, approvals and audit; a Windows CI workflow.
- **Phone PC client:**
  - pairing through a link or the Camera;
  - a pinned transport;
  - the "Bilgisayar" skill with the locative voice route;
  - one approval card that shows the PC's own summary;
  - Settings → Computer (PC);
  - the privacy wipe now covers the PC.
- **Security:**
  - the model can no longer confirm its own actions;
  - the CI write token and unpinned actions are replaced by a read-only build job;
  - the LiveKit licence line is corrected.
- **Reliability:**
  - an offline cold launch keeps the session, and a logout cannot race a refresh;
  - the realtime start/stop race is closed;
  - `error` and `halted` handling, data-channel loss and the mic-permission check are fixed;
  - each start is about 2.3 s faster.
- **Truthfulness:**
  - the image source is now stated to the model;
  - `sdkUpdateRequired` and `deviceUpdateRequired` alerts are shown;
  - tap-confirmed agent and skill results are now shown.

## 11. Where the evidence is

- The R1–R7 reports, the clones and experiment scripts were written to the session scratchpad and copied, outside this public repository, to `C:\Users\tolga\Projects\GlassifAI-research\2026-10-12\`. They contain exploit-level detail for open findings and are deliberately not committed.
- Public sources cited above: `openai/codex` (commits and issues #35094, #41668), `facebook/meta-wearables-dat-ios` (tags 0.5.0/1.0.0/1.0.1, CHANGELOG, swiftinterfaces), Meta Wearables developer docs (version dependencies, known issues, terms), LiveKit `webrtc-xcframework` LICENSE at `46f2af8`.

## 12. Ray-Ban connection and camera audit (2026-10-14, owner's brief of 2026-10-13)

**Türkçe özet:**
- Sahibin yüklediği IPA gözlüğe bağlanmıyordu ve görüntü takılıyordu.
- Gözlükten bir rapor yoktu. Neden; kod, Meta'nın belgeleri, Meta'nın SDK hata kayıtları ve 24 DAT uygulamasının kodu incelenerek arandı.
- En olası ortak neden: güncel gözlük yazılımı, gözlüğün kendi mikrofonu Bluetooth eller serbest (HFP) ile bağlıyken kamera oturumunu kapatıyor. Meta bunu 13 Ekim'de doğruladı. AutoLoom, Ray-Ban kamerasıyla tam olarak bu düzeni kullanıyordu.
- İkinci neden: uygulamanın Meta araç seti (DAT 0.5.0) gözlüğün yeni DAT uygulamasından yedi ay geride kalmıştı.
- Düzeltmeler CI'da. Gözlükte test edilmedi.

| # | Finding | Evidence | Status |
|---|---|---|---|
| C1 | The glasses' microphone over HFP ends and refuses DAT camera sessions on current glasses software, whatever the order; AutoLoom used it with the Ray-Ban camera, and the wake listener held it in Hands-Free Ready | Meta: Android #206, iOS #332 (2026-10-13); `GlassifAIRealtimeSession.configureAudioSession`, `WakePhrase.startListening` @`43ca5f2` | **FIXED (CI, run 38505949350)**: camera-safe audio; the call-rule phase. Device test N, N2 |
| C2 | DAT 0.5.0 (2026-03) against glasses running the on-glasses DAT app 1.0.0.0.0; Meta's answer to older SDKs failing is "update to 1.0.1"; 0.x cannot take part in registrations started from Meta AI | Meta #308, runtime guide, DAT docs; `Package.resolved` @`43ca5f2` | **FIXED (CI, run 38501997387)**: DAT 1.0.1. Device A, B |
| C3 | Session errors (insufficient SDK, DAT app update, DAT app unavailable, refusals) were not distinguished; refusals were retried every 30 s forever | DAT 1.0 runtime guide; #292; reducer @`43ca5f2` | **FIXED (CI, run 38501997387)**: typed failures, phases, no retry while the user must act |
| C4 | Session attempts could follow each other within 1 s; the raw fallback judged a cold start after 8 s | `retryDelay` steps 1 s; `GlassesTransportWatchdog` 8 s; Meta #231 (wait 2 s), reports of 15–18 s cold starts | **FIXED (CI, run 38505949350)**: 2 s minimum, 20 s warm-up |
| C5 | Bluetooth off or not allowed showed "Wake your glasses" | Reducer @`43ca5f2` | **FIXED (CI, run 38501997387)**: `BLUETOOTH_UNAVAILABLE` |
| C6 | After connecting the glasses the iPhone camera stayed the source | `StreamSessionView` default `.iPhoneCamera` | **FIXED (CI, run 38501997387)**: switch after a user-started registration; Home offers it |
| C7 | 720p @ 15 requested over Bluetooth; it settles at 504×896 and costs frames | Meta camera guide; discussion #297; profile `sharp` default | **CHANGED (CI, run 38505949350)**: default "Live" 504×896 @ 24; measured in Camera diagnostics. Device S |
| C8 | Reading used video frames although DAT 1.x in-stream photos are ~1080×1440 | #260, #297; `GlassesVisionCaptureMode.automatic` | **CHANGED (CI, run 38505949350)**: in-stream photo for reading. Device U |
| C9 | No view of the SDK's own log, which names causes the API hides | #292, #301; OpenVision (MIT) idea | **FIXED (CI, run 38505949350)**: `DATLogReader`, IDs masked |
| C10 | A downloaded IPA could not be tied to its commit from its file name | `main.yml` @`43ca5f2` | **FIXED (CI, run 38501997387)**: commit in the name; `ci-ipa-check.sh` |
| C11 | The `MWDAT` values (MetaAppID 0, empty TeamID) | Meta docs: in Developer Mode empty, 0 or a placeholder all mean "no app ID" | **NOT A CAUSE** |
| C12 | Original media in the glasses' gallery | No public DAT API (`AirshipSession` exists but is undocumented) | **NOT AVAILABLE** (unchanged) |
| C13 | The coordinator's 25 s start watchdog restarted a session the wearer had paused with a temple tap | `armStartWatchdog` @`6c840b5`; Meta: do not restart a paused session | **FIXED (IN CI)** `66b3388`: never while paused; one watchdog at a time. Device P |
| C14 | The wake-phrase listener kept HFP after a switch to the Ray-Ban camera, so the glasses refused the camera | `WakePhraseListener.startListening` decides once @`6c840b5` | **FIXED (IN CI)**: restarts when the source or camera-safe audio changes |
| C15 | A stop could not cancel a session start in progress: the Ray-Ban camera could come on with the iPhone camera or Off chosen, or a live session could be forgotten | `startedSession`/`stopSession` @`6c840b5` | **FIXED (IN CI)**: start generation; every switch away ends the session; a resume restarts only a chosen camera |
| C16 | A retry could reuse the camera of an ended session (no frames); a stopped stream was restarted on the same camera | `startedSession` dropped the session without its camera; Meta #260, #287 | **FIXED (IN CI)**: the camera goes with its session; a stopped stream gets a fresh session |
| C17 | Temple taps muted the wrong way round when the call began with the camera running; a fold before any tap did not end the call | `GlassesGestureSession.start` reset the interpreter | **FIXED (IN CI)**: gestures start from the session's state. Device P |
| C18 | Attempts within 2 s after coming back to the app or a fresh link | `nextAttemptAt = .distantPast` @`6c840b5`; Meta #231 | **FIXED (IN CI)**: a 2 s floor from the last attempt |
| C19 | A short link drop cleared the glasses' refusals, so a link that dropped at each refusal never reached the block | `applyLink` @`6c840b5` | **FIXED (IN CI)**: only a drop of 10 s or more (a power cycle). Device O |
| C20 | A camera stop for the glasses' own reasons hung up a call on the iPhone's microphone; a permission given in Meta AI was not checked on return | `StreamSessionView` `onStop`; `sceneBecameActive` | **FIXED (IN CI)**: only a call on the glasses' microphone ends; the permission is checked again (never re-requested) |

What only the device can settle:
- whether 0.5.0 still worked on the owner's firmware;
- whether Gen 1 glasses deliver the same in-stream photo size;
- how smooth "Live" really is;
- whether the owner's glasses show the call rule.

`docs/RAYBAN_CONNECTION.md` rows A–V cover each of these.
