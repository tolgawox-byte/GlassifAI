# Ray-Ban vision with the iPhone locked

> **DAT 1.0 variant (`autoloom-glasses-dat1`):** this branch links DAT 1.0.0. Where this page describes DAT 0.5.0 limits (no standalone photo, no worn state, no "Hey Meta"), `docs/DAT_1_MIGRATION.md` describes what the variant does instead. Nothing DAT 1.0-specific has been tested on glasses.

**Status: BUILD PASS and unit-tested; PHYSICAL TEST REQUIRED.** Nothing here is marked as working until the lock-screen test at the end passes on the owner's iPhone with Ray-Ban Meta Gen 1.

## The requirement

The AI must see through the **glasses**, not through the phone's screen. A locked screen that shows no preview is normal; the AI must keep receiving fresh glasses frames anyway.

```
Ray-Ban camera → DAT → CMSampleBuffer → VideoToolbox (background-safe) → CVPixelBuffer → FrameStore → vision request
```

The SwiftUI preview (`LowLatencyPreviewView`) is only UI. Vision requests read `FrameStore`, which is fed directly by the DAT sample buffers in `GlassesFrameIngestor`, never by the preview layer, a `UIImage`, or a screenshot. `VideoFrame.makeUIImage()` is not on the vision path.

## What Meta documents

- Bluetooth LE is the baseline link; `bluetooth-central` in `UIBackgroundModes` is Meta's documented key for background operation (DAT 1.0 integration guide, "Background mode for Bluetooth LE connectivity").
- DAT 0.5.0 changelog: "`VideoCodec.hvc1` … for compressed HEVC streaming that continues in the background. The default `VideoCodec.raw` pauses streaming when app is backgrounded." The app uses `.hvc1` and decodes the samples with VideoToolbox itself.
- Also in the 0.5.0 changelog: Meta's own Camera Access sample "can now run in background mode, without interrupting streaming (but stopping video decoding)". Meta's sample does not decode in the background; AutoLoom must, because vision needs pixels. That is why the decoder got a keyframe gate, session recreation and a software fallback, and why the background decode counters exist: the physical test shows whether iOS lets the decoder run while the phone is locked.
- DAT 1.0 adds a Wi-Fi transport that needs `NSLocalNetworkUsageDescription` and `NSBonjourServices`. The app is still on **DAT 0.5.0**, so those keys are not added here (see `DAT_1_MIGRATION.md`).

## Root causes found in the code (Jarvis v1)

| # | Cause | Fix |
|---|---|---|
| 1 | The stream was paused when the app went to the background and no conversation was running | Removed. The stream is never stopped because the app left the screen; it is only restarted on return if it had stopped (`StreamSessionView`) |
| 2 | The HEVC watchdogs could fall back to `.raw` while the app was in the background, and raw pauses there | The transport watchdog and the start watchdog only judge while the app is active (`StreamSessionViewModel`) |
| 3 | VideoToolbox sessions can become invalid in the background; P-frames after a reset fail; the hardware decoder can be refused | `VideoDecoder`: waits for the next keyframe after a reset, recreates the session on `kVTInvalidSessionErr` / `kVTVideoDecoderMalfunctionErr`, and retries in software on `kVTVideoDecoderNotAvailableNowErr`; hardware again in the foreground |
| 4 | `bluetooth-central` missing from `UIBackgroundModes` | Added. The existing `audio`, `bluetooth-peripheral` and `external-accessory` entries and `UISupportedExternalAccessoryProtocols = com.meta.ar.wearable` are kept |

Not added: `processing` (a `BGProcessingTask` mode that nothing in the app uses — adding it would be an unnecessary background entitlement), and the Wi-Fi keys (DAT 1.0 only).

## Lifecycle states

`GlassesLifecycleMonitor` (Runtime/GlassesLifecycle.swift) derives one state every 2 s and on every app lifecycle and protected-data notification:

| State | Meaning | Vision |
|---|---|---|
| ForegroundActive | App on screen, stream running | yes |
| BackgroundStreaming | App in the background, samples still arriving (< 3 s old) | yes |
| ScreenLockedStreaming | Screen locked (protected data unavailable), samples still arriving | yes |
| Suspended | Background or locked and samples stopped | no — the assistant says why |
| Disconnected | No glasses stream | no |

Every transition is recorded with the transport and the frame counters (samples, decoded, background samples, background decoded, background failures, last VideoToolbox error). When a visual question arrives without a fresh frame, the assistant gets an honest reason, for example "the stream is on the raw transport, which Meta pauses while the phone is locked" or "frames still arrive while the phone is locked, but the iPhone could not decode them (decoder error −12903)".

## Proof of origin

Every image sent to the AI records, in Developer → Action & task trace and Camera diagnostics (metadata only, never the image):
- source (Ray-Ban or iPhone), frame sequence, frame age, source and encoded dimensions;
- the pipeline state and transport at capture time, e.g. `ScreenLockedStreaming · HEVC (hvc1) app-decoded glasses sample`.

## Where to look

Settings → Developer → **Camera diagnostics**: pipeline state, screen locked, transport, samples raw/compressed, decoded/failures, background samples/decoded/failures, keyframe waits, decoder hardware/software, last decode error and its age, last sample age, frame age and sequence, and the transition log. None of these numbers appear on the Assistant screen.

## Physical lock-screen test (required)

1. Start AutoLoom, select Ray-Ban, start a conversation.
2. Ask "Ne görüyorum?" and confirm the answer matches the view (A).
3. Lock the iPhone. Wait 10 seconds.
4. Look at a new object and ask again through the glasses (B).
5. Turn to another object and ask again (C). The answer must describe the **new** object — that proves frames keep coming from the glasses.
6. Unlock the phone (D). The preview resumes; the next answer must not use a stale frame.
7. Open Camera diagnostics and copy the transition log and counters into `TEST_REPORT.md`.

Expected in diagnostics during step 4–5: state `ScreenLockedStreaming`, background samples and background decoded both rising, transport HEVC. If background samples rise but background decoded stays at 0, the decoder is the problem (note the error code). If background samples stop, iOS or the glasses stopped the stream while locked (a platform limit; note the transport).
