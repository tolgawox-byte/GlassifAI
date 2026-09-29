# Performance: camera, heat and battery

The camera features are built so that nothing streams video to a model: Live Vision sends a small image only when the view changed (at most one every 6 s), Remote Assist sends about two 720-pixel frames a second only while someone watches, and dealer photo hints are measured on a 320-pixel copy on the phone. The app reads the iPhone's thermal state and battery to slow down or stop the heavy features, and never stops a recording for heat. This page lists the numbers in the code and says which are measured at runtime and which are fixed heuristics. No on-device benchmark results are recorded in this repository. Code: `Runtime/LiveVision.swift` (`LiveVisionPolicy`), `FrameSelection.swift` (`FrameQuality`, `FrameSelector`), `RemoteAssist.swift`, `PhotoDirector.swift`, `MediaResourceCoordinator.swift`, `PerformanceGuard.swift`.

## Live Vision (`LiveVisionPolicy`)

| Rule | Value |
|---|---|
| Loop tick | every 0.5 s (cheap checks first) |
| Minimum interval between notes | 6 s |
| Thermal state serious | 15 s (6 × 2.5) |
| Battery < 20 % and not charging | 12 s (6 × 2); an unknown level (simulator) does not slow down |
| Thermal state critical | Paused ("phone too warm"); `PerformanceGuard` then stops Live Vision |
| "The view changed" | Mean difference of two 16×16 luma thumbnails ≥ 14 (0–255 scale) |
| Stable view | Refreshed at most every 45 s (heartbeat); skipped ticks are counted |
| After a skipped check | Next check 1 s later |
| Time limit | 10 min by default (5, 10, 20 or 30 selectable) |
| Frames used | Only frames ≤ 1.0 s old; the best of the recent ones (see `FrameSelector`) |
| Image sent | "Fast" profile: long side 768 px, JPEG quality 0.75, ≤ 450 KB. ChatGPT path: low reasoning effort, 20 s timeout (a connected live-vision specialist may answer instead) |
| Paused | Camera off; Ray-Ban with the screen locked unless "Continue vision with the screen locked" is on; waiting for a frame |
| Stopped | Conversation ended; time limit; critical heat |

Settings → Performance shows "N not, M atlandı" (notes sent, stable views skipped) while it runs.

## Frame quality and selection (`FrameQuality`, `FrameSelector`)

- Measured per frame on the phone: sharpness = variance of the Laplacian over the central 70 % of the frame, every second pixel; mean luma; a 16×16 luma thumbnail. The code comment estimates "a few milliseconds per 720×1280 frame"; this is not measured by any test.
- Formats: bi-planar 4:2:0 (plane 0) or BGRA; other formats fall back to the newest frame.
- Selection: frames older than the limit are never used; frames from before a scene change (thumbnail difference > 22) are dropped; score = sharpness × freshness (up to −35 % for age) × exposure (× 0.6 if mean luma < 30 or > 225); an older frame must beat the newest by 15 %.
- The frame store keeps the latest 8 frames (about 0.5 s at 15 fps); for the iPhone camera only the newest frame is kept.

## Remote Assist

| Rule | Value |
|---|---|
| Frame rate | One frame every 0.5 s (about 2 fps); every 1.0 s when the thermal state is serious or worse |
| Frame | JPEG, long side 720 px, quality 0.55, ≤ 220 KB |
| Only when | At least one viewer is connected and a frame ≤ 1.5 s old exists |
| Slow viewer | Dropped (no queue) |
| Limits | 15 minutes; 10 wrong codes; stops in the background and at critical heat |

Details: [REMOTE_ASSIST.md](REMOTE_ASSIST.md).

## Photo director (dealer photos)

After a Ray-Ban photo linked to a vehicle, a 320-pixel grayscale copy is measured off the main thread: Laplacian variance (< 40 → blurry), mean brightness (< 45 dark, > 215 bright), share of pixels ≥ 250 (> 6 % → glare), and a 16×16 thumbnail compared with the vehicle's previous photo (< 6 → duplicate). One hint is spoken; the photo is always kept; nothing is sent. Details: [DEALER_SUPERMODE.md](DEALER_SUPERMODE.md).

## Heat, battery and Low Power Mode (`PerformanceGuard`)

- Observes `ProcessInfo.thermalStateDidChangeNotification` and power-state changes, started when the app shell appears.
- At **critical**: stops Live Vision and Remote Assist and posts "Telefon çok ısındı: canlı görüş ve paylaşım durdu. Kayıt devam ediyor." A Ray-Ban recording is **never** stopped here, so its file stays intact.
- Settings → Performance: temperature ("Normal", "Ilık", "Sıcak — özellikler yavaşlar", "Çok sıcak — canlı görüş ve paylaşım durur"), Low Power Mode, battery level (when monitoring is on), and what is running (Live Vision counts, sharing, recording, the resource coordinator's summary).
- Low Power Mode is shown but does not change any rule in this build.

## Resource rules (`MediaResourceCoordinator`)

| Activity | Needs | Cannot run with |
|---|---|---|
| Live Vision, live translation, video recording, Remote Assist | The camera stream | — (frames are fanned out from one stream) |
| Remote Assist two-way audio | Remote Assist | The conversation (both need the microphone and audio route) |
| Live translation | The camera stream | Live Vision (both sample frames for the model) |

Ending an activity also ends what depended on it. A refusal comes with a sentence the assistant can say. In this build only Remote Assist (`begin`/`end`) and music (`note`) report to the coordinator; Live Vision, recording and the camera stream do not, and live translation and two-way audio are not implemented. See the known gap in [REMOTE_ASSIST.md](REMOTE_ASSIST.md).

## Measured vs heuristic

| Measured at runtime on the device | Fixed heuristics (constants in code, not calibrated on a device) |
|---|---|
| Thermal state, battery level and charging, Low Power Mode | 6 / 12 / 15 / 45 s Live Vision intervals, 10 min limit |
| Per-frame sharpness, luma, scene difference | Scene thresholds 14 (Live Vision) and 22 (frame selection); freshness and exposure weights |
| Per-photo sharpness, brightness, highlights, duplicate distance | Photo thresholds 40, 45/215, 6 %, 6 |
| Camera FPS in (received) and shown, frames dropped (Camera diagnostics) | Remote Assist 0.5 s / 1.0 s, 720 px, quality 0.55, 220 KB |
| Frame age (frames older than 1.0 s never answer; 1.5 s for sharing) | Vision profiles: 768 / 1,280 / 2,048 px long side |

Unit tests check the policy functions with synthetic inputs (`AutoLoomLiveVisionTests`, `AutoLoomDealerSuperModeTests.testPhotoHintsAreMeasuredNotGuessed`, `AutoLoomJarvisExpansionTests.testMediaResourcesNeverFight`); they do not measure speed, heat or battery on a real iPhone.

## Status

| Item | Status |
|---|---|
| Live Vision adaptive interval and scene-change rules | WORKING (unit tests) |
| Photo hint measurements | WORKING (unit tests) |
| Resource rules (pure decision table) | WORKING (unit tests) |
| Heat and battery behaviour on the iPhone and glasses | PHYSICAL_TEST_REQUIRED |
| Real frame rates, latency and battery drain | PHYSICAL_TEST_REQUIRED (not measured in this repo) |
| Coordinator wired to every camera feature | PARTIAL |
