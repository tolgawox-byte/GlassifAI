# Ray-Ban vision with the iPhone locked

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

### v1.4 root causes (why fresh frames still stopped when the phone locked)

| # | Cause (evidence) | Fix |
|---|---|---|
| 5 | **The hardware decoder.** Meta's own DAT sample (`VideoFrameDecoder.swift`): "Force software decoding so the session survives backgrounding. iOS tears down hardware sessions when backgrounded, and a fresh one stalls until the next keyframe." Our decoder used hardware and, after iOS invalidated it, rebuilt a **hardware** session; it switched to software only on one error code (`kVTVideoDecoderNotAvailableNowErr` from a decode), never when creating the session failed or the output callback reported errors. Samples kept arriving while locked, nothing decoded, `FrameStore` had no fresh frame. | `VideoDecoder` now uses the **software** decoder by default (`EnableHardwareAcceleratedVideoDecoder = false`, iOS 17+, exactly as Meta's sample), checks `VTDecompressionSessionCanAcceptFormatDescription` before every decode, counts failures from the call **and** from the output callback (3 in a row rebuild the session), rebuilds a vanished hardware session in software and retries its keyframe at once, rebuilds a session that accepts frames but returns no image, and tries the other mode when a session cannot be created. Settings → Camera & Ray-Ban → Video decoder can choose Hardware (on screen only). |
| 6 | **No photo fallback while locked.** `prepareVisionImage` skipped the glasses still photo when the app was in the background (`!background`), so a decoder hiccup meant "no image". | A glasses still photo (JPEG from the glasses, processed with ImageIO on the CPU) is the fallback in the background too. It does not need the video decoder. |
| 7 | **A raw fallback lasted the whole app run.** One HEVC problem on screen switched the transport to raw, which Meta pauses in the background, for the rest of the run. | The fallback lasts one stream: the next start tries HEVC again (at most two fallbacks per run), and the note says raw pauses when locked. |
| 8 | **No recovery while streaming.** Nothing noticed a stream that said "streaming" but produced no fresh image. | A fresh-frame monitor (`RayBanStallPolicy`, every 2 s): samples arrive but no image → rebuild the decoder (the other mode after the first try, 5 s apart); only P-frames for 8 s, or no samples for 10 s → restart the stream, **on screen only**, at most 3 times in 10 minutes, never during a recording. With the phone locked the stream is never restarted (Meta documents that streaming continues in the background, not that a new start works); vision uses the still photo instead. |

Also new: Settings → Camera & Ray-Ban → **Continue vision with the screen locked** (on by default; unavailable on the raw transport). When off, a Ray-Ban question while locked is answered honestly ("turned off in Settings") and Live Vision pauses.

### Exact DAT 0.5.0 behaviour (what this build relies on)

- `VideoCodec.hvc1`: compressed HEVC samples (`VideoFrame.sampleBuffer` with a data buffer, no image buffer) that keep arriving in the background. `VideoCodec.raw` pauses in the background.
- No API to request a keyframe; a new stream starts with one.
- `StreamSession.capturePhoto(format: .jpeg) -> Bool`, delivered on `photoDataPublisher` (in-stream photo; DAT 1.0 adds standalone `Camera.photo`).
- No camera audio in 0.5.0 (DAT 1.x beta channels add in-stream audio); the glasses microphone is Bluetooth HFP, which Meta says must be set up before the camera stream starts.
- Start timeout 10 s; publishers do not replay.

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

Expected in diagnostics during step 4–5: state `ScreenLockedStreaming`, background samples and background decoded both rising, transport HEVC, decoder **software**, recoveries 0 (or a decoder rebuild followed by decoded frames). If background samples rise but background decoded stays at 0, the decoder is the problem (note the error code). If background samples stop, iOS or the glasses stopped the stream while locked (a platform limit; note the transport).
