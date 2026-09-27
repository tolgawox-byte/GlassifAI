# Test report — AutoLoom Media Glasses (`autoloom-glasses-next`)

Result categories: **STATIC PASS** (reviewed / lint-level), **UNIT PASS** (automated unit test passed in CI), **INTEGRATION PASS** (automated multi-component test passed), **BUILD PASS** (compiled into the IPA in CI), **PHYSICAL TEST REQUIRED** (needs the iPhone + Ray-Ban Meta).

Environment: Windows 11 development machine (no Xcode). All compilation and tests run on GitHub Actions (`xcode-27` runner, iOS Simulator + macOS host for Rust).

## Automated results

<!-- AUTOMATED-RESULTS -->
### Run 36302332223 — commit `8f04249` (proof of executed tests)

Test names and counts come from the `.xcresult` bundle and are published as annotations.

- **iOS: 33 passed, 0 failed, 0 skipped.**
  - `AutoLoomCoreTests`: 23
  - `AutoLoomTaskTests`: 7
  - `GlassesGestureInterpreterTests`: 3
- **Rust: 5 passed, 0 failed.** `empty_options_keep_baseline_configuration`, `invalid_voice_falls_back_to_juniper`, `reconnect_delay_backs_off_and_caps`, `truncation_respects_char_boundaries`, `initial_items_are_bounded_and_typed`.

### Ray-Ban vision + assistant name work

Results are added after the CI run for this change. The new classes are:
- `AutoLoomVisionTests`: raw frame to FrameStore, compressed frame decoded to FrameStore, wrong source, stale frame, switch clears, pending-only photo, late photo rejected, one capture in flight, photo pass-through/fit, vision profile limits, reading requests use high detail, high-detail encoder
- `AutoLoomAssistantTests`: name validation, persistence and default, name in instructions, other settings unchanged, invocation cannot start two sessions, queued invocation runs once

The CI script now discovers every test class automatically, excluding only the Meta mock-device class.
### Run 36300781448 — commit `e104d71` (feature commits)

https://github.com/tolgawox-byte/GlassifAI/actions/runs/36300781448

| Step | Result | Notes |
|---|---|---|
| Rust native bridge, 3 iOS targets (`build-native.sh`) | **BUILD PASS** | reconnecting sideband, v2 start, context append compiled (5 min with cache) |
| Swift app, Debug + Release (`xcodebuild`, generic iOS) | **BUILD PASS** | first attempt, no compile errors |
| Unsigned IPAs (Debug + Release) | **BUILD PASS** | artifact `AutoLoomMediaGlasses-unsigned-IPAs`, 49.3 MB |
| iOS Simulator unit tests | **UNIT PASS** (step green) | classes `GlassesGestureInterpreterTests` (3) and `AutoLoomCoreTests` (23). `AutoLoomTaskTests` was **not selected** in this run (test-list omission) — covered by the follow-up run below |
| Rust unit tests (host) | see below | |

Per-test names were not visible here (Actions logs need authentication); the follow-up run publishes them as annotations.

### Previous runs

- 36299379608 (`8953f12`, CI-only change, app code identical to baseline): BUILD PASS Debug + Release, `GlassesGestureInterpreterTests` UNIT PASS.
- 36296398412 (`74d9be5`, baseline): BUILD PASS — the device-verified build.

## Scenario matrix

| Scenario | How it is covered | Result |
|---|---|---|
| GENERAL CHAT without camera | Realtime instructions answer chat directly; camera Off mode keeps voice/web/reasoning | BUILD PASS · PHYSICAL TEST REQUIRED (Test 1) |
| VISION route | `TASK: vision` envelope → fresh frame → Responses | UNIT PASS (envelope, freshness, encoder) · PHYSICAL TEST REQUIRED (Test 3) |
| WEB route | `TASK: web` → hosted `web_search`, fallback backend search | UNIT PASS (parsing, fallback parsing, source filtering) · PHYSICAL TEST REQUIRED (Test 2) |
| VISION + WEB | `TASK: vision_web` → frame + web search | UNIT PASS (routing) · PHYSICAL TEST REQUIRED (Test 4) |
| Frame freshness | `FrameStore.waitForFreshFrame` never returns a stale frame; source-filtered | UNIT PASS |
| Camera source switch | Cache reset + task cancel on switch; call kept unless audio route changes | BUILD PASS · PHYSICAL TEST REQUIRED |
| Cancel task | Ledger cancellation; stale/duplicate results dropped; `TASK: cancel` | UNIT PASS · PHYSICAL TEST REQUIRED |
| Network failure | URLError mapping, one quick retry, spoken failure | UNIT PASS (mapping) · PHYSICAL TEST REQUIRED (Test 9) |
| Token refresh | Forced refresh + retry after 401 | UNIT PASS (401 mapping) · PHYSICAL TEST REQUIRED |
| Rate limit | 429 → `rateLimited(retryAfter:)` with honest spoken message | UNIT PASS |
| Bluetooth disconnect | Route/interruption monitor, HFP selection that ignores other headsets | UNIT PASS (port matching) · PHYSICAL TEST REQUIRED (Test 10) |
| Memory delete | Opt-in store add/forget/delete-all | UNIT PASS · PHYSICAL TEST REQUIRED (Test 11) |
| Prompt injection | Untrusted-content wrapper cannot be closed early; policy in every executor prompt | UNIT PASS |
| SSRF | Local, private, metadata, obfuscated-numeric, credential and odd-port URLs rejected | UNIT PASS |
| Log hygiene | Tokens, JWTs, emails, data URLs, blobs removed | UNIT PASS |
| Unsupported action | `TASK: action` declined honestly without any network call | INTEGRATION PASS (orchestrator, no network) |
| Camera off + vision | Spoken "camera is off" without network | INTEGRATION PASS |
| Duplicate delegation | Same handoff on data channel + sideband runs once | INTEGRATION PASS |
| Permissions denied | Camera/mic/glasses denial paths unchanged from baseline; camera Off works | STATIC PASS · PHYSICAL TEST REQUIRED |
| Brand assets | Icon 1024×1024 opaque, brand mark in asset catalog, display name AutoLoom | BUILD PASS (asset catalog compiled) |
| Realtime start v2 + fallback | Rust option parsing defaults/invalid voice/bounded items; Swift falls back to baseline | UNIT PASS (Rust) · PHYSICAL TEST REQUIRED |
| Sideband reconnect | Backoff schedule; generation guard | UNIT PASS (backoff) · PHYSICAL TEST REQUIRED (Test 9) |

## Physical test checklist (iPhone + Ray-Ban Meta)

Before starting: install the **Release** IPA, open Settings → Diagnostics and confirm the commit matches the Actions run and the bridge shows `autoloom-bridge-2`. Turn on Settings → Camera → *Show camera metrics overlay* for camera tests. After each test, Diagnostics → *Copy diagnostics report* captures everything (sanitized).

| # | Test | Steps | Expected | Result |
|---|---|---|---|---|
| 1 | General chat, no camera | Camera **Off**. Start voice. Say: "Bugün biraz sohbet edelim." Continue 3–4 turns, then "Asıl konuyu değiştir…" | Natural Turkish replies; status never shows *Seeing*; Diagnostics → Recent tasks shows no VISION task | |
| 2 | Web: weather | Say: "Bugün Ottawa hava durumunu internetten araştır." | Status *Searching*; spoken answer names a source; source cards appear with title/host/fetch time; task WEB_SEARCH via *verified delegation* | |
| 3 | Vision | Camera **Ray-Ban**. Look at an object. Say: "What am I looking at?" | Status *Seeing*; correct description; task shows frame age ≤1000 ms and stage timings T0–T5 | |
| 4 | Vision + web | Look at a product. Say: "Bu gördüğüm ürünün Kanada fiyatlarını araştır." | Identifies the product, then CAD prices with source name and cards; task VISION_PLUS_WEB | |
| 5 | Barge-in | Ask for a long answer ("detaylı anlat…"), then talk over it; also press the ✋ button once | Old answer stops; new request handled; ✋ silences immediately | |
| 6 | Ray-Ban preview metrics | Overlay on, 10 s steady; record resolution, FPS, dropped, processing median/p95, frame age; stopwatch glass-to-glass latency ×3; repeat with Preview = Legacy and with profiles Smooth / Sharper | Low-latency path has higher FPS, fewer drops, lower latency than Legacy | |
| 7 | Meta first-party comparison | Compare sharpness/smoothness/delay with Meta AI's own camera view | Subjective notes; remember Bluetooth DAT limits (camera doc) | |
| 8 | Phone locked / in pocket | Start voice with Ray-Ban audio, lock the phone, ask a chat question and a vision question | Voice continues; vision works if DAT delivers background frames (0.4.0 raw may not — note result) | |
| 9 | Wi-Fi ↔ cellular | During a call, toggle Wi-Fi off/on; ask a web question after each switch | Call survives or reconnects; Diagnostics → Sideband may show `reconnecting (n)` then `connected` | |
| 10 | Glasses disconnect/reconnect | Fold the glasses 10 s, unfold; also remove/put on | Placeholder "Glasses folded", stream resumes; audio route returns to glasses; AirPods (if paired) not selected | |
| 11 | Privacy delete | Enable Memory, say "Bütçemin 500 dolar olduğunu hatırla", verify in Settings → Memory; then Privacy → Delete all local data | Item appears, then everything is cleared | |
| 12 | Cancel | Ask a web question, immediately say "görevi iptal et" (or tap ✕) | "Cancelled" acknowledgement; no late answer from the cancelled task | |
| 13 | Typed question | Tap ⌨︎, type "Toronto'da bugün hava nasıl?" | Answer card with sources; not spoken | |

## Physical tests — Ray-Ban vision and assistant name

| # | Test | Steps | Expected | Result |
|---|---|---|---|---|
| E1 | Name | Settings → Assistant → name **Jarvis**. Start a conversation and say: "Jarvis, nasılsın?" | Normal reply; does not keep saying "I am Jarvis" | |
| E2 | Ray-Ban vision | Ray-Ban selected. Ask: "Jarvis, şu an neye bakıyorum?" | Correct description. Diagnostics → Recent tasks shows `VIDEO Ray-Ban #<seq> … age ≤1000 ms`, or `PHOTO` as fallback. **Also note** *Delivered as* (raw/compressed), decoded frames, and stream state | |
| E3 | Text reading | Point at text. Say: "Jarvis, önümdeki yazıyı oku." | Task shows `PHOTO … high detail` (or video fallback); exact transcription; unreadable parts named. Compare photo vs video legibility using Settings → Ray-Ban → Vision image | |
| E4 | Meta invocation | Try "Hey Meta, start AutoLoom" | **Expected not to work in this build** (DAT 0.4.0). Record Meta AI's response | |
| E5 | Siri | Say "Hey Siri, start AutoLoom", then create a Shortcut named "Jarvis" running *Start Conversation* and say "Hey Siri, Jarvis" | App opens and starts listening once; Settings → Hands-Free → Recent invocations shows `Siri / Shortcuts = started` | |
| E6 | Stall explanation | During a conversation, tap the glasses' temple (pauses the stream), then ask what you're looking at | The assistant says the camera is paused (or uses a fresh photo); it never describes an old image | |

## Camera acceptance (from the brief)

| Criterion | Status |
|---|---|
| Best official DAT mode identified | Done — documented in `docs/RAYBAN_CAMERA_CAPABILITIES.md` (0.4.0 limits; 1.0.0 upgrade path) |
| Unnecessary compression avoided | Done — no per-frame JPEG; one JPEG per vision request |
| Unnecessary resizing avoided | Done — preview uses source buffers; AI frame only downscaled above 1600 px |
| No frame backlog | Done — single pending slot, no per-frame main-actor tasks |
| Preview separated from AI frame | Done |
| Frame freshness implemented | Done (≤1.0 s, waits ≤1.5 s, source-filtered, cleared on switch) — UNIT PASS |
| FPS measured | Done in app — PHYSICAL TEST REQUIRED for numbers |
| Latency measured | Phone-side processing and host-clock capture latency in app; glass-to-glass via stopwatch — PHYSICAL TEST REQUIRED |
| Source resolution measured | Done in app — PHYSICAL TEST REQUIRED for numbers |
| Physical-device procedure ready | Done (Test 6/7) |

"Meta AI quality achieved" is **not** claimed until Test 6/7 numbers are recorded.
