# Test report — AutoLoom Media Glasses (`autoloom-glasses-vNext`)

Result categories:
- **BUILD PASS**: compiled into the Debug and Release IPAs in CI.
- **UNIT PASS**: automated test passed in CI (iOS Simulator or Rust host).
- **PHYSICAL TEST REQUIRED**: needs the iPhone and Ray-Ban Meta Gen 1; the results table below is for you to fill.

Environment: Windows 11 (no Xcode). Everything compiles and runs on GitHub Actions (`xcode-27` runner). Test names and counts come from the `.xcresult` bundle and are published as annotations on each run page. Compiler errors are published the same way.

## Automated results

<!-- AUTOMATED-RESULTS -->
### Final build: run [36362397832](https://github.com/tolgawox-byte/GlassifAI/actions/runs/36362397832), commit `3cb0437`

**BUILD PASS · iOS 99/99 UNIT PASS (0 skipped) · Rust 5/5 UNIT PASS.** Artifact `AutoLoomMediaGlasses-unsigned-IPAs` (51 MB) contains `AutoLoomMediaGlasses-Release-unsigned.ipa` (install this one) and `AutoLoomMediaGlasses-Debug-unsigned.ipa`. Compared with `bdbf24a`, it adds:
- the Mode B audio-safety fix
- the HEVC never-started fallback
- rendered-fps and battery diagnostics
- the requested/actual line in Settings
- documentation

### Previous complete result: run [36361068283](https://github.com/tolgawox-byte/GlassifAI/actions/runs/36361068283), commit `bdbf24a`

- **BUILD PASS**: Rust bridge (3 iOS targets), Swift Debug and Release, and both unsigned IPAs (artifact `AutoLoomMediaGlasses-unsigned-IPAs`).
- **iOS: 99 passed, 0 failed, 0 skipped** (from the `.xcresult` bundle). The OCR test skips itself if Apple Vision is unavailable; 0 skipped means the real OCR pass ran and passed. Per-class counts come from the test sources and add up to the same 99.
  - `AutoLoomCoreTests` 23
  - `AutoLoomVisionTests` 10
  - `AutoLoomVisionPipelineTests` 13
  - `AutoLoomActionTests` 11
  - `AutoLoomModelTests` 8
  - `AutoLoomTaskTests` 7
  - `AutoLoomAssistantTests` 6
  - `AutoLoomAgentTests` 5
  - `AutoLoomCameraTests` 5
  - `AutoLoomLiveVisionTests` 5
  - `AutoLoomVoiceTests` 3
  - `GlassesGestureInterpreterTests` 3
  - The Meta mock-device integration class is excluded by design (long fixed sleeps).
- **Rust: 5 passed, 0 failed.**

### Runs on `autoloom-glasses-vNext`

| Run | Commit | Result | Notes |
|---|---|---|---|
| [36362397832](https://github.com/tolgawox-byte/GlassifAI/actions/runs/36362397832) | `3cb0437` (final) | **BUILD PASS · iOS 99/99 · Rust 5/5** | Release IPA for the phone |
| [36361068283](https://github.com/tolgawox-byte/GlassifAI/actions/runs/36361068283) | `bdbf24a` (all features + agent gateway) | **BUILD PASS · iOS 99/99 UNIT PASS · Rust 5/5 UNIT PASS** | |
| [36358353416](https://github.com/tolgawox-byte/GlassifAI/actions/runs/36358353416) | `5bf325b` (DAT 0.5.0, HEVC, profiles) | **BUILD PASS · iOS 54/54 UNIT PASS · Rust 5/5 UNIT PASS** | First build against DAT 0.5.0 |
| [36360275311](https://github.com/tolgawox-byte/GlassifAI/actions/runs/36360275311) | `b3a64ca` (vision pipeline, models, Live Vision, voice, actions) | BUILD PASS · test target did not compile | `ModelHealth` main-actor call from a non-isolated test |
| [36360687135](https://github.com/tolgawox-byte/GlassifAI/actions/runs/36360687135) | `8fd60fe` (+ brand, Mode B, shortcuts) | BUILD PASS · test target did not compile | Missing `import CoreMedia` (MemberImportVisibility). Found through the new error annotations |

## What the automated tests cover

| Area (brief §46) | Tests |
|---|---|
| Auth, routing, envelopes | `AutoLoomCoreTests` (envelopes, JSON, cancel, invalid input), `AutoLoomLiveVisionTests.testVoiceCommandsParseToLiveVision` |
| Conversation context | `AutoLoomTaskTests.testConversationContextCompactsAndWrapsTaskResults` |
| Camera source, raw and compressed frames, decode | `AutoLoomVisionTests` (raw → FrameStore, H.264 keyframe decoded → FrameStore, wrong source, stale, switch clears) |
| DAT 0.5.0 profiles and HEVC fallback | `AutoLoomCameraTests` (documented frame rates, defaults, watchdog decisions, counter reset) |
| Stale-frame rejection and camera-switch epoch | `AutoLoomVisionTests`, `AutoLoomVisionPipelineTests.testFrameStoreKeeps…NewEpochOnReset` |
| Best-frame selection | `AutoLoomVisionPipelineTests` (sharp beats blurred, scene change excluded, stale rejected, newest wins ties) |
| Photo matching | `AutoLoomVisionTests` (pending-only, late rejected, one in flight, pass-through) |
| Vision quality modes and routing | `AutoLoomVisionPipelineTests.testQueryClassifierMatchesTheBrief` (every example from the brief, in English and Turkish) |
| Upscale and crop within the patch budget | `AutoLoomVisionPipelineTests.testProfilesAndUpscale…`, `testEncoderUpscalesAndCrops` |
| OCR path | `AutoLoomVisionPipelineTests.testOnDeviceOCRReadsRenderedText` (real Apple Vision pass), focus region, low-confidence rejection |
| Web search, vision + web | `AutoLoomCoreTests` (SSE parsing, citations, direct search fallback, source filtering) |
| Task cancellation, duplicates, stale results | `AutoLoomTaskTests` |
| Tool confirmation | `AutoLoomActionTests` (risk levels, voice yes accepted for saves, refused for calls/messages, cancel, expiry, local refusal without network) |
| Action validation | `AutoLoomActionTests` (time zones, past times, private links rejected, phone format, unknown actions) |
| Model discovery and fallback | `AutoLoomModelTests` (catalog parsing, per-role choice, exclusion after failure, overrides, GPT-6 Astra only when exposed, effort mapping, request shape) |
| Assistant name and wake state | `AutoLoomAssistantTests`, `AutoLoomVoiceTests` (name matching, reconnect budget, interruption words) |
| Live Vision policy | `AutoLoomLiveVisionTests` (thermal/battery intervals, scene-change gating, needs conversation and camera, stops by itself) |
| Agent gateway | `AutoLoomAgentTests` (address policy, request/reply shape, tap for destructive requests, planner can't route to the agent, honest reply without a gateway) |
| Privacy guards, prompt injection | `AutoLoomCoreTests` (sanitizer, SSRF, untrusted wrapper); OCR and agent replies wrapped as untrusted |
| Memory deletion | `AutoLoomTaskTests.testLocalMemoryIsOptInAndDeletable` |
| Native bridge | Rust: option parsing, voice fallback, bounded items, reconnect backoff, UTF-8 truncation |

## Physical test plan (iPhone + Ray-Ban Meta Gen 1)

**Before you start**
1. Install **AutoLoomMediaGlasses-Release-unsigned.ipa** from the final run (see `docs/WINDOWS_INSTALL.md`).
2. Settings → Diagnostics:
   - **Commit** matches the run
   - **DAT SDK** is 0.5.0
   - **Transport** is HEVC (hvc1)
3. Settings → Assistant: name **Jarvis**.
4. Settings → Camera: **Show camera metrics overlay** on for the camera tests.
5. After each test, Diagnostics → **Copy diagnostics report** (sanitized) and keep the text.

| # | Test | Steps | Pass when | Result |
|---|---|---|---|---|
| 1 | General conversation | Camera **Off**. Start a conversation. "Jarvis, nasılsın?", then 3–4 more turns | Natural Turkish replies; no "Looking" status; no VISION task in Recent tasks | |
| 2 | Ray-Ban vision | Camera **Ray-Ban**. "Jarvis, şu an neye bakıyorum?" | Correct description. Recent tasks: `VIDEO Ray-Ban`, "best of n", age ≤1000 ms. **Note the overlay's Requested vs Actual** (resolution, fps) | |
| 3 | Freshness | Look at object A, ask. Turn to object B, ask at once | The second answer describes **B**, never A | |
| 4 | Large text | "Jarvis, önümdeki yazıyı oku." | Status "Reading"; exact transcription; task shows `OCR+VIDEO`, HIGH_DETAIL, upscaled | |
| 5 | Small detail | A small label ~40 cm away: "Jarvis, etiketteki küçük yazıyı oku." Repeat with Stream profile **Max detail 720p/7** | Readable where the optics allow; Recent tasks shows the crop and OCR line count. Note which profile read better | |
| 6 | Vehicle badge | "Jarvis, bu arabanın arkasındaki badge ne yazıyor?" | Badge text read or honestly "unreadable"; HIGH_DETAIL | |
| 7 | Live Vision | "Jarvis, start live vision." Walk between two rooms, then "Burada ne var?" and a follow-up | Red "Live Vision" chip. Diagnostics → Live Vision: notes sent only when the view changed (stable skips grow when still). Follow-ups work. "Stop live vision" ends it | |
| 8 | Web | "Bugünkü Ottawa hava durumunu internetten kontrol et." | Status "Searching"; answer names a source; source cards show title, host, fetch time | |
| 9 | Vision + web | Look at a product: "Jarvis, bunun Kanada fiyatını bul." | Identifies the product, then CAD prices with a source | |
| 10 | Reminder | "Jarvis, yarın saat 7'de bana süt almayı hatırlat." | iOS asks for Reminders access (first time). The card shows the reminder; "evet" or Save stores it; it appears in Reminders at 07:00 tomorrow | |
| 11 | Calendar | "Jarvis, bugün takvimimde ne var?", then "Yarın 15:00'te dişçi randevusu ekle" | Today's events read out; the event appears in Calendar after yes/Save | |
| 12 | Bluetooth | During a conversation, fold the glasses 10 s, then unfold | "Glasses folded" placeholder, stream resumes; audio returns to the glasses; other headsets not grabbed | |
| 13 | Wi-Fi ↔ cellular | During a conversation, turn Wi-Fi off, then on; ask a question after each | Call survives or shows "Connecting" and resumes by itself; Diagnostics → Auto-reconnects shows the reason | |
| 14 | Phone locked | Start a conversation with Ray-Ban, lock the phone, ask a chat question and "şu an neye bakıyorum?" | Voice continues. Vision works while locked (HEVC); if it can't, the assistant says why and never describes an old image | |
| 15 | Thermal / 10-minute Live Vision | Live Vision on for 10 minutes while walking | Stops by itself at 10 min; Diagnostics thermal state; no overheating warning; note the battery drop | |

**Extra checks**
- **Settings → AI models**: write down the list and whether **GPT-6 Astra** is exposed.
- **Mode B**: Settings → Hands-Free → turn on listening, keep the app open, say "Hey Jarvis". A conversation should start.
- **Call confirmation**: "Jarvis, 613 555 0100'ı ara". Saying "evet" must **not** start the call; only the Call button may.

## Camera measurement sheet (from the overlay / Diagnostics)

| Profile | Requested | Actual resolution | Actual fps (in / shown) | Transport | Dropped | Frame age | Glass-to-glass (stopwatch ×3) |
|---|---|---|---|---|---|---|---|
| Detail 720p/15 (default) | 720×1280 @ 15 | | | | | | |
| Max detail 720p/7 | 720×1280 @ 7 | | | | | | |
| Balanced 720p/24 (original) | 720×1280 @ 24 | | | | | | |
| Smooth 504p/30 | 504×896 @ 30 | | | | | | |

No "Meta AI quality" or "higher resolution" is claimed until this sheet is filled in.
