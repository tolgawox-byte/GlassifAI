# Ray-Ban camera capabilities (Meta Wearables DAT)

Researched 2026-09-27 from Meta's official DAT documentation (wearables.developer.meta.com), the SDK repository (github.com/facebook/meta-wearables-dat-ios) and its changelog/`.swiftinterface`. Items marked UNVERIFIED come from non-staff forum posts or could not be confirmed officially.

## Short version

- The app is pinned to **DAT 0.4.0**. The latest SDK is **1.0.0** (tagged 2026-09-24) and it needs Meta AI app **V290** and glasses firmware **V128**; Meta's rollout of those starts **2026-09-30**. Upgrading now could break the working glasses connection, so this release stays on 0.4.0 and fixes the phone-side pipeline instead.
- On 0.4.0, requesting `.high` (720×1280) did not reliably take effect — the fix landed in 0.5.0. The diagnostics screen now shows the resolution that actually arrives.
- Third-party video goes over **Bluetooth Classic**, and the glasses compress harder as resolution and frame rate go up. Wi-Fi streaming arrived in 0.8.0 and needs Wi-Fi entitlements from a **paid Apple developer team**, which a free sideloading account can't provide. Meta AI's own experience is not limited this way, so some softness compared with it is a platform limit, not an app bug.
- The phone-side pipeline had real problems, and this release fixes them: every frame hopped to the main thread and was converted to a `UIImage` there, SDK buffers were retained until that ran, and a JPEG was encoded every second. Meta's SDK calls the frame callback inline, so holding its buffers can drain the decoder pool and stall the stream (UNVERIFIED staff-adjacent report, consistent with the observed lag).

## Capability table

| Capability | Current behavior (this build) | Official DAT max | Can improve? | Platform limitation? | Physical test? |
|---|---|---|---|---|---|
| Stream resolution | Requests 720×1280 by default (original profile). Actual size is shown in Diagnostics | 720×1280 (`.high`), 504×896 (`.medium`), 360×640 (`.low`) | Yes: upgrade to ≥0.5.0 so `.high` is honored. Try the "Smooth" or "Sharper frames" profile now | Yes. The ladder drops resolution first, then fps (never below 15), when Bluetooth bandwidth is low | Yes (Test 6) |
| Frame rate | 24 fps requested (original). Profiles: 30 fps (504p) or 15 fps (720p) | 2, 7, 15, 24, 30 fps | Yes. Fewer fps means less compression loss per frame | Yes (adaptive) | Yes |
| Codec | `.raw` (SDK-decoded 420v YUV) | `.raw` (foreground only), `.hvc1` (HEVC, 0.5.0+, foreground and background) | Yes, after upgrading: `.hvc1` plus hardware decode | — | Yes |
| Transport | Bluetooth Classic | Bluetooth Classic, or Wi-Fi (0.8.0+) | Only with Wi-Fi entitlements (paid Apple team) | Yes, bandwidth | — |
| Still capture | Not used. In-stream `capturePhoto` on 0.4.0 returns a stream frame and pauses the video | 1.0.0 `Camera.photo` up to 4032×3024 JPEG/HEIC. Experimental, can't run during a stream, can't be published | Yes, after the 1.0.0 upgrade (dev builds) | Yes | — |
| Frame timestamps | Arrival time on the phone; PTS used only if it is on the host clock | `VideoFrame` exposes only `sampleBuffer` and `makeUIImage()`; clock origin undocumented | — | Yes: no official capture timestamp | Stopwatch test |
| Preview pipeline | One buffer copy on the callback thread, then `AVSampleBufferDisplayLayer`; latest frame wins; no main-thread work | — | Done | — | Yes |
| AI frame | Encoded on request from the newest source buffer (≤1 s old), JPEG q0.82, long side ≤1600 px, `detail` high by default | Codex caps images at 2048 px | Done | — | Yes (Test 3) |
| Sessions | One DAT stream plus the gesture session | Only one session per device; some Meta AI features pause while a third-party session is active | — | Yes | — |
| Devices | Ray-Ban Meta (tested) | Ray-Ban Meta Gen 1/2, Meta Ray-Ban Display, Oakley Meta HSTN/Vanguard (1.0.0 needs firmware V128) | — | — | — |

## The measured chain

```text
Ray-Ban camera
 → glasses encoder (adaptive to Bluetooth bandwidth)        [not observable]
 → DAT SDK decode (.raw → 420v CVPixelBuffer)              [pixel format, resolution]
 → frame callback (inline on the SDK thread)               [arrival time, FPS, count]
 → one copy into an app-owned IOSurface buffer             [processing time]
 ├→ FrameStore (latest frame only)                         [frame age]
 │    └→ on a vision request: select fresh frame (≤1 s)    [T1 frame selected]
 │         → scale ≤1600 px + JPEG q0.82 (once)            [T2, bytes, dimensions]
 │         → Responses request                             [T3 sent, T4 first output]
 │         → delegation back to the voice model            [T5 delivered → speech]
 └→ preview layer (single pending slot, stale frame dropped) [rendered / dropped]
```

Diagnostics → Camera pipeline shows:
- input resolution and pixel format
- measured FPS, frames received, preview rendered/dropped, preview failures
- phone processing time (median and p95)
- capture→phone latency (median and p95), when the frame PTS is on the host clock
- last frame age

Recent tasks show each vision request's frame (source size → encoded size, JPEG quality and bytes, frame age) and the T0–T5 stage timings.

**What the app cannot measure:** glass-to-glass latency. The glasses' capture clock isn't exposed, so use the stopwatch test below.

## What changed in this release

1. **No main-thread work per frame.** The SDK callback copies the frame once and returns. Nothing runs on the main actor for each frame.
2. **Latest frame wins.** The preview has a single pending slot, so a slow display replaces the waiting frame instead of queueing it. There is no backlog.
3. **SDK buffers are released immediately.** The copy goes into the app's own pool, so the decoder pool can't be drained.
4. **Preview is separate from the AI frame.** The preview goes straight to the display layer. The AI frame is encoded once, only when a question needs it, from the source buffer. It is never a screenshot of the preview.
5. **Freshness guard.** Vision uses a frame only if it is at most 1.0 s old, and waits up to 1.5 s for a new one. Otherwise the assistant says no fresh frame is available. Switching camera source clears the cache.
6. **A/B switch.** Settings → Ray-Ban → Preview → "Legacy (original)" restores the old path for a direct comparison.
7. **Stream profiles.** Balanced (original 720p/24), Smooth (504p/30), Sharper frames (720p/15). The profile applies on the next stream start.

## Physical test procedure (Test 6 and Test 7)

1. Settings → Camera → turn on **Show camera metrics overlay**. Select **Ray-Ban**.
2. Wait 10 s with the glasses on and unfolded. Note resolution, FPS, dropped frames, processing median/p95 and frame age.
3. **Latency (stopwatch):** point the glasses at a phone or computer showing a millisecond stopwatch. Photograph both screens together with a third device. The difference between the two displayed times is glass-to-glass latency. Repeat 3 times.
4. Repeat steps 2–3 with Preview = **Legacy (original)**. This gives the before/after comparison.
5. Repeat with the **Smooth** and **Sharper frames** profiles. Stop and restart the glasses stream by switching the camera to iPhone and back to Ray-Ban.
6. Ask "What am I looking at?" and open Diagnostics → Recent tasks. Record the frame size, age and stage timings.
7. Subjective comparison with Meta AI's own camera experience: note sharpness, smoothness and delay.

Record the numbers in `TEST_REPORT.md`. Don't claim "Meta AI quality" without them.

## Recommended next step: SDK upgrade (after 2026-09-30)

Once the glasses show firmware V128 and the Meta AI app is V290 or later:

1. Move the package to 1.0.0. Migrate `StreamSession` to `Wearables.createSession(deviceSelector:)` → `session.addCamera(config:)` → `camera.stream` (renames: `StreamSessionConfig` → `StreamConfiguration`, and so on). `start()`/`stop()` become synchronous. `DeviceStateSession` usage in the gesture code must be re-checked.
2. Use `.hvc1` and decode it yourself with `VTDecompressionSession` (hardware). Render with the existing low-latency layer. This also makes background frames work.
3. For AI stills in development builds, use `Camera.photo` at `.full`. It needs a stream stop/start and gives about 4032×3024.
4. Wi-Fi transport only if a paid Apple developer team is available.
5. Keep the current build as a rollback, because integration versions created before 1.0 don't work with 1.0 builds.
