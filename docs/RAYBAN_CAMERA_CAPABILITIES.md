# Ray-Ban camera: capabilities, root causes, and the quality pipeline

Researched 2026-09-27 from Meta's official sources:
- the **Meta Wearables docs MCP server** (`https://mcp.developer.meta.com/wearables`, tool `search_dat_docs`), queried directly
- the SDK repository `facebook/meta-wearables-dat-ios` (tags 0.4.0 → 1.0.0, `CHANGELOG.md`)
- the published `.swiftinterface` files of DAT 0.4.0 and 0.5.0, diffed line by line

Items marked PHYSICAL TEST REQUIRED have not been measured on the glasses yet.

## Short version

1. **Root cause 1: the SDK could not deliver 720p.** The app was pinned to DAT **0.4.0**. Meta's 0.5.0 release notes say *"Fixed: High resolution (720x1280) video can now be requested."* On 0.4.0, a `.high` request most likely arrived at a lower resolution, which matches the *504×896* the brief quotes. This build moves to **DAT 0.5.0**.
2. **Root cause 2: too many frames for the Bluetooth link.** Meta's documentation: *"The image delivered to your app may appear lower quality than expected, even when the resolution reports high or medium. This is due to per-frame compression that adapts to available Bluetooth Classic bandwidth. Requesting a lower resolution, a lower frame rate, or both can yield higher visual quality with less compression loss."* The old default asked for 720p at 24 fps. The new default is **720p at 15 fps**, with a **720p at 7 fps** max-detail profile for reading.
3. **Root cause 3: the AI image was not chosen or labelled for detail.**
   - Vision used whatever frame was newest, even a blurred one.
   - The image went out without an explicit `detail` value.
   - Reading requests had no text-specific help.

   This build picks the sharpest recent frame, sends `detail: "high"`, enlarges small frames toward the model's patch budget, and adds on-device OCR plus a zoomed crop of the text.
4. **Not a phone-side bug:** the glasses compress video to fit Bluetooth Classic. Meta AI's own camera path is not limited the same way, so some softness compared with the glasses' own photos is a platform limit. Full-resolution stills (up to the native sensor) need DAT 1.0's `Camera.photo`, which needs glasses firmware V128 and Meta AI V290 (Meta's rollout starts 2026-09-30).

## Official version requirements (Meta docs, "Version Dependencies")

| DAT SDK | Meta AI app | Ray-Ban Meta firmware | Notes |
|---|---|---|---|
| 0.4.0 (previous build) | V254 | V20 | `.high` request not reliably honoured |
| **0.5.0 (this build)** | **V254** | **V22** | 720p fixed; `hvc1` codec (streams in background) |
| 0.6.0 | V254 | V22 | `DeviceSession` API added |
| 0.7.0 / 0.8.0 | V272 / V275 | V125 | Types renamed (`Stream`, `StreamConfiguration`); Wi-Fi transport (needs paid-team entitlements) |
| 0.9.0 | V282 | V126 | Consolidated `Camera`; iOS 17.2 minimum |
| 1.0.0 (tagged 2026-09-24) | V290 | V128 | `Camera.photo` full-resolution stills (beta), Hey Meta voice invocations |

Why 0.5.0 and not newer: 0.5.0 has the same `StreamSession` API as 0.4.0. The only compile changes were `StreamSessionError.audioStreamingError` → `.thermalCritical` and the removal of `HingeState`/`DeviceState`, which the app did not use. The MockDeviceKit test API is unchanged. Its firmware requirement (V22) is far below current firmware. 0.7+ is a larger migration with higher firmware requirements and no stream-quality change over 0.5.0.

## The chain, stage by stage

```text
Ray-Ban camera ─► glasses encoder (adaptive to Bluetooth bandwidth)                 [not observable]
  ─► Bluetooth Classic ─► DAT 0.5.0 StreamSession
      HEVC (default):  VideoFrame.sampleBuffer = compressed hvc1 sample             [codec, size, count]
        ─► VTDecompressionSession (hardware) on a serial queue ─► 420v CVPixelBuffer [decode ok/fail]
      raw (fallback):  SDK-decoded CVPixelBuffer ─► one copy into an app pool         [copy fallbacks]
  ─► FrameStore: newest 8 glasses frames (arrival, capture time, sequence, epoch)   [FPS, age, sequence]
  ├─► PIPELINE A – live preview: single pending slot ─► AVSampleBufferDisplayLayer   [rendered/dropped]
  └─► PIPELINE B – AI vision, only when a question needs it:
        profile by request (FAST / BALANCED / HIGH_DETAIL)
        ─► best-frame selection (sharpness, exposure, freshness, same scene)         [best of n, sharpness]
        ─► one encode: Lanczos resample, clamped edges, JPEG q0.75/0.85/0.92          [size, quality, bytes]
        ─► HIGH_DETAIL: enlarge small frames ≤1.6× within 2048 px / 2500 patches
                        + Apple Vision OCR (≤1.5 s) + enlarged crop of the text area [lines, confidence, crop]
        ─► Responses request with detail: "high"                                     [T0–T5 timings]
```

There is no main-thread work per frame, no `UIImage` per frame, no JPEG per frame, and no screenshot of the preview anywhere in the AI path.

## What changed in this build

| Area | Before (0.4.0 build) | Now |
|---|---|---|
| SDK | DAT 0.4.0 | DAT 0.5.0 |
| Transport | raw only (SDK decodes; pauses in background) | **HEVC** by default: hardware-decoded by the app to native 4:2:0, keeps streaming with the phone locked. A watchdog falls back to raw once if no frame decodes within 8 s of streaming. Selectable in Settings |
| Default profile | 720p @ 24 fps | **720p @ 15 fps**; also 720p @ 7 fps (max detail), 720p @ 24 (original), 504p @ 30 |
| Diagnostics | resolution that arrived | **Requested vs actual** (size, fps, codec), DAT version, glasses name/type/compatibility, transport and fallback reason |
| Frames kept | newest only | newest **8** glasses frames (iPhone: newest only, to spare the capture pool) |
| AI frame | newest frame | **sharpest recent frame of the same scene** (Laplacian variance on luma, exposure check, freshness weight). Frames from before a scene change are never used |
| Profiles | standard / high | **FAST** (768 px, q0.75), **BALANCED** (1280 px, q0.85), **HIGH_DETAIL** (≤2048 px & ≤2500 patches, q0.92) |
| Profile routing | voice model's choice | Voice model's choice, **upgraded by request words**: read/label/sign/VIN/badge/dashboard/warning/screen/menu/price, oku/yazı/etiket/tabela/şasi/plaka/uyarı/gösterge… → HIGH_DETAIL; colour questions → FAST |
| Reading help | none | On-device OCR as an untrusted hint; enlarged crop of the recognised text as a second image |
| `detail` | not sent (service default) | `"high"`, as Codex sends |
| Photos | photo first for reading | **Video first**: Meta documents in-stream photos as "a frame lifted out of a video stream", so they add latency without detail on 0.5.0. Photos remain the fallback when video stalls, and a "photo first" setting exists for comparison |
| Stale protection | ≤1.0 s, source filter, reset on switch | Same, plus a **frame epoch**: a frame selected before a camera switch is rejected even if its encode finishes after the switch |

## "Move closer" (Jarvis v1)

The owner reported that the assistant often said "move closer". It now tries everything the app can do first:

1. A reading request (read, label, VIN, badge, oku, yazı, etiket, plaka…) goes straight to HIGH_DETAIL: the sharpest of the recent frames, on-device OCR as an untrusted hint, a zoomed crop of the text region, and enlargement within the model's patch budget. Diagnostics shows the **source** resolution next to the **encoded** one, and an enlarged frame is marked "upscaled", never presented as more detail.
2. A standard vision answer that says it cannot see enough ("can't read", "blurry", "okunmuyor", "yaklaşın"…) is **retried once in HIGH_DETAIL** before anything is spoken (`VisionAnswerCheck`, task trace note "high-detail retry").
3. Only then may the answer ask for a better view. It first gives everything it could read, then **one specific tip** ("about half as far away", "tilt the label toward the light", "hold still for a second"), never a bare "move closer".
4. After such advice, the next answers within 90 seconds are told not to repeat it.
5. A full-resolution still (DAT 1.0 `Camera.photo`) would be the next step; it needs the migration in `DAT_1_MIGRATION.md`.

## Capability table

| Capability | This build | Official max | Physical test |
|---|---|---|---|
| Stream resolution | 720×1280 requested (profile) | 720×1280 (`.high`), 504×896, 360×640. The glasses lower resolution first when bandwidth is short | **Required**: record *Actual* in Diagnostics |
| Frame rate | 15 fps requested (7/24/30 selectable) | 2, 7, 15, 24, 30 fps; the ladder never goes below 15 fps on its own | Required |
| Codec | HEVC (hvc1) + app hardware decode; raw fallback | raw (foreground only), hvc1 (foreground + background) | Required: Transport must stay HEVC |
| Background frames | Yes with HEVC (phone locked, conversation running) | hvc1 only | Required (Test 14) |
| Still photo | In-stream `capturePhoto(format: .jpeg)` as fallback | 1.0 `Camera.photo` up to native resolution (beta, stream must stop) | Compare in Test 5 |
| Best-frame choice | Newest 8 frames, same scene, ≤1.0 s | — | Diagnostics → Recent tasks shows "best of n" |
| OCR | Apple Vision accurate, tr-TR + en-US (when the system supports Turkish), no language correction | — | Tests 4–6 |
| AI image | See profiles above | Codex high detail: ≤2048 px, ≤2500 patches of 32 px | Test 5 |
| Capture timestamps | Host-clock PTS when plausible, else arrival time | `VideoFrame` exposes only the sample buffer | — |

## What cannot be measured by the app

Glass-to-glass latency: the glasses' capture clock is not exposed. Use the stopwatch method below.

## Physical test procedure (camera part of `TEST_REPORT.md`)

1. Select **Ray-Ban**. Open Settings → Developer → **Camera diagnostics** (the metrics are no longer shown on the Assistant screen).
2. With the glasses on for 10 s, read *Requested* and *Actual* (resolution, fps, pixel format), dropped frames, processing times and frame age.
3. Repeat for each stream profile: Detail 720p/15, Max detail 720p/7, Balanced 720p/24, Smooth 504p/30. Switch the camera to iPhone and back after changing a profile.
4. Latency: point the glasses at a phone showing a millisecond stopwatch, take one photo of both screens with a third device, and compare the times. Repeat 3 times.
5. Reading: hold a label about 40 cm away and ask "Jarvis, etiketteki küçük yazıyı oku". Developer → Action & task trace shows the image source (`OCR+VIDEO`), best-of-n, upscale, crop, OCR line count and the pipeline proof (`ForegroundActive · HEVC (hvc1) app-decoded glasses sample`). Compare with Text detail mode off.
6. Locked screen: the procedure in `BACKGROUND_STREAMING.md`.
7. Record every number in `TEST_REPORT.md`. Don't claim "Meta AI quality" without them.

## Locked screen (Jarvis v1.1)

The vision path reads decoded glasses samples, never the preview. The stream is no longer paused in the background, the HEVC→raw fallback is never decided in the background (raw pauses there), the decoder survives background session loss (keyframe gate, session recreation, software fallback) and `bluetooth-central` was added. Lifecycle states, background decode counters and per-request proof of origin are in Camera diagnostics. Details and the physical test: `BACKGROUND_STREAMING.md`.

## Upgrade path to DAT 1.0 (after the Meta rollout reaches the glasses)

1. The glasses must show firmware V128 and Meta AI V290 or later.
2. Migrate to `Wearables.createSession` → `session.addCamera(config:)` → `camera.stream` (type renames from 0.7.0), and `DeviceStateSession` → `Device.addDeviceStateListener`.
3. For reading requests, use `Camera.photo` at `.full`/`.high` (stop the stream, capture, restart). The existing high-detail pipeline (OCR, crop, `detail: high`, patch budget) then works on a much larger source.
4. Add the Hey Meta `VoiceInvocationsStream` (see `VOICE_INVOCATION.md`).
5. Keep the 0.5.0 build as a rollback. Integration versions created before 1.0 don't work with 1.0 builds.
6. Check the transport: Meta's 1.0 guide says a user who denies Local Network access "will continue over Bluetooth LE, but without streaming", i.e. 1.0 camera streaming may need the Wi-Fi transport (`NSLocalNetworkUsageDescription`, `NSBonjourServices`, and possibly entitlements a free signing team cannot use). Only a device test on firmware V128 settles this; it is one more reason the 0.5.0 build stays the main build.
