# Meta Wearables DAT 1.0 — migration plan

**Status on this branch: not migrated.** This build stays on DAT **0.5.0**, the version the vNext camera work was built and CI-tested against. The migration below is now built as a separate variant on branch **`autoloom-glasses-dat1`** (IPA `AutoLoomMediaGlasses-DAT1-Release-unsigned.ipa`); that branch's copy of this document describes what it does and lists its device tests. Nothing in it has been tested on glasses.

## Why not in this build

- DAT 1.0 needs **Meta AI app V290 and glasses firmware V128**, rolling out from **2026-09-30**. The owner's glasses cannot run it yet, so nothing could be tested.
- The owner must keep a working IPA (brief: "without breaking Gen 1"). A blind SDK swap would put the working Ray-Ban preview and vision at risk.
- Standalone photo capture is marked **beta** by Meta: "available to every developer, but apps that use it cannot be published yet". That is fine for a sideloaded build, but it is not a production-stable API.

## What DAT 1.0 adds that AutoLoom wants

| Feature | DAT 1.0 API (Meta docs) | AutoLoom use |
|---|---|---|
| Full-resolution still photo | `DeviceSession.addCamera()` → `camera.photo`; register `statePublisher`, `photoDataPublisher`, `transferProgressPublisher`, `errorPublisher`, **then** `photo.start()` (iOS only); on the first `.started` call `photo.capturePhoto(resolution: .full, quality: .high)` | HIGH_DETAIL reading (VINs, labels, documents) from the native sensor instead of a compressed video frame |
| Video stream | `session.addCamera(config: StreamConfiguration(videoCodec:resolution:frameRate:))` → `camera.stream`; `statePublisher`, `videoFramePublisher`, `errorPublisher`; `stream.start()` | Replaces the 0.5.0 `StreamSession` |
| Voice invocation | `VoiceInvocationsStream(wearables:)`, `start(deviceIdentifier:)`, `invocationsPublisher`; answer `LaunchApp` with `responseHandle.sendSuccess(actionOutput: nil)` | "Hey Meta, start AutoLoom" (state E) |
| Device state | `Device.addDeviceStateListener`: `donState`, `hingeState`, `linkState`, battery, thermal | Arm hands-free when the glasses are worn (state D becomes "worn" instead of "connected") |

Constraints from Meta's documentation:
- **Stream and Photo compete for the camera and cannot capture at the same time.** The app must stop the stream, take the photo, then restart the stream; the toolkit does not arbitrate.
- **One capture in flight.** Results carry no request id, and photos the wearer takes with the shutter button arrive on the same publisher, so captures must be serialized.
- `.started` can be published more than once; capture on the first only.
- iOS exposes no public camera-removal call and no session-state publisher; readiness comes from `start(deviceIdentifier:)` throwing plus the error publisher.
- Stream resolutions stay `high` 720×1280, `medium` 504×896, `low` 360×640 at 2/7/15/24/30 fps; the Bluetooth ladder still lowers them and compression still limits detail.

## Voice invocation prerequisites (owner actions)

1. Wearables Developer Center: register the bundle id `com.marcoiannello.GlassifAI` and fill in the `MWDAT` MetaAppID (currently empty, Developer Mode).
2. Request the **Voice Invocation** permission and wait for Meta's approval.
3. The phrase is "Hey Meta, start {APP NAME}", where the app name registered with Meta is the keyword. The exact phrase must be verified on the glasses and recorded here.

## Migration steps (separate branch `autoloom-glasses-dat1`)

1. Bump the Swift package to the 1.0 tag and diff the `.swiftinterface` files, as was done for 0.4.0 → 0.5.0.
2. Wrap both APIs behind `GlassesCameraBackend` with `stream(profile:)`, `photo()`, `stop()`, so the rest of the app (FrameStore, FrameSelector, vision) is unchanged.
3. HIGH_DETAIL requests: pause stream → `photo.start()` → capture `.full/.high` (8 s timeout) → resume stream; fall back to the best video frame on any error. Record the source vs encoded resolution in diagnostics (never present an upscale as detail).
4. Add `VoiceInvocationsStream` behind the `HandsFreeCapabilities.metaInvocationAvailable` flag, routed through `VoiceStartCoordinator.request(.metaInvocation)`.
5. Map `donState` to "worn" arming.
6. CI: build both IPAs; unit-test the backend state machine with the Mock Device Kit.
7. Device tests on firmware V128: preview, vision, photo latency, photo resolution, "Hey Meta, start AutoLoom", worn/unworn arming, and a fallback check on older firmware (Gen 1 must keep working or fail with a clear message).

## Rollback

Keep the 0.5.0 build (`autoloom-glasses-jarvis-v1`) installed until the DAT 1.0 build passes the device tests above.
