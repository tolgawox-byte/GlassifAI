# Meta Wearables DAT 1.0 — the `autoloom-glasses-dat1` variant

**Status: implemented as a separate build and CI-built with the unit tests passing; not tested on glasses.** The Mock Device Kit integration tests (`ViewModelIntegrationTests`) were ported to the 1.0 API and compile in CI, but CI does not run them (they use long fixed sleeps; the same holds for the 0.5.0 build). Everything below is **EXPERIMENTAL / PHYSICAL TEST REQUIRED**.

| | 0.5.0 build (default) | DAT 1.0 variant |
|---|---|---|
| Branch | `autoloom-glasses-jarvis-v1` | `autoloom-glasses-dat1` (Jarvis v1.1.1 + the changes below) |
| IPA | `AutoLoomMediaGlasses-Release-unsigned.ipa` | `AutoLoomMediaGlasses-DAT1-Release-unsigned.ipa` |
| Meta SDK | DAT 0.5.0 | DAT 1.0.0 (iOS 17.2 minimum) |
| Glasses needed | current firmware | firmware **V128** and Meta AI app **V290** (Meta rollout from **2026-09-30**) |

Both builds use the bundle id `com.marcoiannello.GlassifAI`, so only one can be installed at a time. Keep the 0.5.0 IPA as the working build until the DAT 1.0 build passes the device tests below.

## Why it is a separate build

- The owner's glasses cannot run DAT 1.0 until the V128 firmware and V290 Meta AI app arrive, so nothing in it can be device-tested yet.
- Meta marks standalone photo capture **beta**: "available to every developer, but apps that use it cannot be published yet". Fine for a sideloaded build, not a stable API.
- DAT 1.0 streams the camera over **Wi-Fi** ("Wi-Fi is added for high-bandwidth features like camera streaming"; without Local Network access "your app integration will continue over Bluetooth LE, but without streaming"). How that behaves with the phone locked is unknown until tested.

## What the variant changes

| Area | 0.5.0 build | DAT 1.0 variant |
|---|---|---|
| Camera | `StreamSession` | One `DeviceSession` per glasses (`Wearables.createSession(deviceSelector:)`, `start()`), `session.addCamera(config:)` → `Camera` with `stream` and `photo` children. Same frame pipeline, HEVC transport, raw fallback and lock-screen handling |
| High-detail vision ("oku", labels, VINs) | Sharpest recent video frame (720×1280 at most) | A **standalone photo** `capturePhoto(resolution: .full, quality: .high)` — Meta: native sensor, 4032×3024 — then downscaled to the 2048 px model budget; the video frame is the fallback |
| Glasses folded, off or out of range | The stream waits for the glasses and resumes | DAT 1.0 stops the session and does not reconnect it (Meta: "inactive and not reconnecting"). The app starts a new session when the glasses are available again, when the app comes back on screen, or when a conversation starts |
| Temple gestures | A second session's states | The camera session's `DeviceSessionState` (`started`/`paused` toggles mute; `stopped` ends the call). The app's own stop (switching to the iPhone camera) is not read as the wearer ending the call |
| Wake-phrase arming "only while the glasses are …" | Connected (`LinkState`) | **Worn**: `Device.addDeviceStateListener` → `donState == .donned` and hinges not closed; falls back to the link state while unknown |
| "Hey Meta, start AutoLoom" | Not available | `VoiceInvocationsStream` listener: answers each `LaunchApp` with `sendSuccess`, then starts a conversation through `VoiceStartCoordinator` (the same path as the button and the wake phrase). Only works after Meta approves Voice Invocation for this app |
| Info.plist | `bluetooth-central` | Adds `NSBonjourServices` `_bonjour._tcp` and a Local Network description, as Meta's 1.0 integration guide requires. `processing` is **not** added: Meta's guide does not require it (only the sample app lists it) and nothing in AutoLoom uses it |
| Diagnostics | — | Camera diagnostics: device session state and standalone photo state; Settings → Hands-free: the Hey Meta listener status and launches received |

## Standalone photo flow

Follows Meta's photo guide and the BirdSpotter sample:

1. The stream is started first; it wakes the sensor. When it reports `streaming`, `photo.start()` is called (a photo start on a cold camera never finishes). All listeners are registered before any `start()`.
2. Startup is Meta's "most common failure point": if the photo child returns to `stopped` while starting, or is not `started` after 10 s, the camera is replaced once (`camera.stop()`, a fresh `addCamera()`), as Meta recommends. After a second failure, vision keeps using video frames.
3. A high-detail request in the foreground, with the session `started` and the photo child `started`: the stream is stopped (and waited for, up to 2 s, because stream and photo compete for the sensor), the photo is requested, and the reply is awaited for up to 15 s, or up to 30 s while transfer progress keeps arriving (Meta fails a capture after 30 s of silence).
4. However it ends, the stream is started again with fresh listeners (Meta does not document whether listeners survive a stop and start). Any failure returns no photo and the best fresh video frame is used; an old image is never used.
5. One capture at a time. Photos the wearer takes with the glasses' shutter button arrive on the same publisher; only a pending app request accepts a photo, so they never reach vision.
6. With the phone locked or the app in the background, no standalone photo is taken; vision uses video frames.

Camera diagnostics show photos requested / received / failed, the last photo's resolution and latency, and the photo child's state. Image content is never logged.

## Owner actions for "Hey Meta"

1. Wearables Developer Center: register the bundle id `com.marcoiannello.GlassifAI` and fill in the `MWDAT` `MetaAppID` (currently empty, Developer Mode).
2. Request the **Voice Invocation** permission and wait for Meta's approval. It is not granted in Developer Mode.
3. The phrase is "Hey Meta, start {APP NAME}", where the app name registered with Meta is the keyword. Record the exact phrase here after testing it on the glasses.

## Device tests for the DAT 1.0 build

Install `AutoLoomMediaGlasses-DAT1-Release-unsigned.ipa` from CI run [36393004694](https://github.com/tolgawox-byte/GlassifAI/actions/runs/36393004694) (commit `4ccad6e`; also listed in `TEST_REPORT.md`). Settings → Developer → Diagnostics must show **DAT SDK 1.0.0**.

| # | Test | Pass when | Result |
|---|---|---|---|
| D1 | Glasses on firmware V128, Meta AI V290. Start the app, select Ray-Ban | iOS asks for **Local Network** access once; after allowing it the preview appears | |
| D2 | "Ne görüyorum?" | Correct answer; Camera diagnostics: device session `started`, stream `streaming` | |
| D3 | Camera diagnostics after about 15 s of streaming | Standalone photo (beta) `started` | |
| D4 | Point at small text: "Şu etiketi oku" | Reads it; Camera diagnostics: photos received +1, last photo 4032×3024 (or note the size), latency noted; the preview resumes afterwards | |
| D5 | Same as D4 with the glasses' shutter button pressed during the capture | The answer is about the requested photo; no crash | |
| D6 | Lock screen tests L1–L5 (`TEST_REPORT.md`) | As on the 0.5.0 build; note whether streaming continues over Wi-Fi when locked | |
| D7 | During a conversation: temple tap, tap again; then switch Settings → Camera to iPhone and back | Mute toggles; switching the camera does **not** end the conversation | |
| D8 | During a conversation, fold the glasses; then unfold them without touching the phone | The conversation ends; after unfolding, the preview comes back by itself | |
| D9 | Wake phrase on, "Only while the glasses are worn" on. Take the glasses off, then put them on | Settings → Hands-free status: "Waiting for the glasses to be worn" off the head; listening again when worn | |
| D10 | After Meta approves Voice Invocation: "Hey Meta, start AutoLoom" | One conversation starts; Settings → Hands-free shows "Launches received" +1 and Recent starts "Hey Meta" | |
| D11 | Glasses on older firmware (if available) | The app says the glasses need an update, or the camera stays unavailable with a clear message; no crash. Reinstall the 0.5.0 IPA | |

## Constraints from Meta's documentation

- Stream and Photo compete for the camera; the toolkit does not arbitrate. The app stops the stream before a photo.
- Results carry no request id, and shutter-button photos arrive on the same publisher, so captures are serialized.
- `.started` can be published more than once; a paused session suspends transports and must not be restarted.
- iOS has no public camera-removal call; `camera.stop()` invalidates the camera, and a new one needs `addCamera()`.
- `DeviceSessionState` does not expose the reason for a transition, so a fold, a long press and a link loss all look like `stopped`.
- Stream resolutions stay `high` 720×1280, `medium` 504×896, `low` 360×640; compression still limits detail in video frames.

## Rollback

Reinstall `AutoLoomMediaGlasses-Release-unsigned.ipa` (the 0.5.0 build) from the `autoloom-glasses-jarvis-v1` run. If the glasses do not reconnect after switching builds, reconnect the app in the Meta AI app.
