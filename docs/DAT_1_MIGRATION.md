# Meta Wearables DAT 1.0 — migration

**Status: migrated on branch `autoloom-glasses-jarvis-v1` (`9954e60` and the follow-up commit), DAT 1.0.1. CI only; PHYSICAL TEST REQUIRED.**

- The previous DAT 0.5.0 build is tagged `rollback-43ca5f2-before-dat1-port`. Its run 38492438643 was green.
- The older separate variant on branch `autoloom-glasses-dat1` (v1.1.1 on DAT 1.0.0) is superseded and no longer updated.

## Why now

- The owner's sideloaded 0.5.0 build did not connect to the glasses (2026-10-13).
- Meta's glasses now run firmware 128/129 with the on-glasses DAT app 1.0.0.0.0, and Meta's answer to older SDKs failing on it is "update your app to 1.0.1" (SDK issue #308).
- Meta's runtime guide makes `insufficientSDKVersion` terminal ("release a newer version of your app built with the current SDK").
- Only 1.0 apps can take part in registrations started from Meta AI.
- See `RAYBAN_CONNECTION.md` for the full evidence.

**Requirements:**
- Meta AI V290 or newer.
- Glasses firmware V128 or newer.
- iOS 17.2 or newer.
- Reboot the glasses once after the V128 update; Meta lists camera capture failing until then.

## What changed in the code

| 0.5.0 | 1.0.1 (this build) |
|---|---|
| `StreamSession(streamSessionConfig:deviceSelector:)` | `Wearables.createSession(deviceSelector:)` → `start()` → wait for `.started` → `addCamera(config:)` → `camera.stream.start()` |
| `StreamSessionState`, `StreamSessionError` | `StreamState`, `StreamError` (`.thermalHot`, `.batteryLow`, `.peakPowerLimit`, `.audioStreamingError`, `.photoCaptureFailed`; `deviceNotFound/Connected` carry the device id) |
| No session errors | `DeviceSessionError` kept apart: `insufficientSDKVersion`, `datAppOnTheGlassesUpdateRequired`, `dwaUnavailable`, `dwaOutOfStuRange`, health, `unexpectedError("Device unavailable" / "Session ended by device")` |
| `DeviceStateSession` + `addDeviceSessionStateListener` for temple gestures | One session per glasses, so gestures follow the camera's `DeviceSessionState`; the app's own stops are marked and never end the call |
| `handleUrl(_:)` | `handleUrl(_:onRegistrationRequest:)`: registrations started in Meta AI are continued |
| No device state | `Device.addDeviceStateListener`: worn, hinges, battery, charging, thermal (diagnostics) |
| In-stream `capturePhoto` only | In-stream `stream.capturePhoto(format:)` (default for reading) and the standalone `camera.photo` (beta, opt-in) |
| Mock Device Kit `pairRaybanMeta()` | `enable()`, `pairGlasses(model: .rayBanMeta)`, `services.camera`, async `unpairDevice` / `disable` |
| iOS 17.0 | iOS 17.2 |

## Lessons from Meta's issue tracker, built in

- **One start at a time:**
  - wait for `.stopped` before a new session;
  - never two session attempts within 2 s (#231);
  - a cold start may take 15–18 s, so the raw fallback and the stall monitor wait 20 s.
- **Refusals:** "Device unavailable" or "Session ended by device" three times in three minutes, with the glasses linked, asks for a power-switch cycle instead of retrying (#292, #332).
- **The call rule:** while the glasses' microphone is connected over hands-free, the glasses end and refuse sessions (#206, #332). With the Ray-Ban camera, conversations use the iPhone microphone by default ("camera-safe audio").
- **A starved stream** gets a fresh session: re-adding a camera to a live session delivered nothing (#287).
- **Standalone photo:**
  - refused while the stream runs;
  - restarting a stopped stream can fail on 1.0 (#260);
  - so the opt-in full photo stops the stream, takes the photo, stops the photo child and starts a fresh session.
  - The startup failure is retried once on a new camera (Meta's "Capture reliability").
- **Smoother default:** "Live" 504×896 at 24 fps. Over Bluetooth 720p is delivered as 504×896 after 15–25 s at about 60 kB/s (#297).

## Not done (and why)

| Feature (DAT 1.0) | Why not in this build |
|---|---|
| In-stream audio (`StreamConfiguration.audioCodec`, `audioFramePublisher`) as the glasses microphone during camera use | Meta's suggested path while HFP and the camera cannot run together, but experimental, not beamformed, and it needs a custom audio source for the WebRTC voice pipeline. Owner decision; next step after the device tests |
| "Hey Meta, start AutoLoom" (`VoiceInvocationsStream`) | Needs Voice Invocation approval in the Wearables Developer Center (a registered app, not Developer Mode) |
| Inputs, Motion, Speech | Beta; nothing in AutoLoom needs them yet |
| Wi-Fi streaming | Needs the Hotspot Configuration and Wi-Fi Information entitlements (a paid team), takes the iPhone's Wi-Fi internet while streaming, and adds Bonjour keys. This build streams over Bluetooth Classic |
| Airship file transfer (`AirshipSession` in the interface) | Undocumented; not used |

## Known SDK issues to watch on the device

- `#324`: the 1.0.0 stream grows a heap buffer about 4 MB per minute. Whether 1.0.1 fixes it is unknown; the iOS camera binary is the same as 1.0.0.
- `#301`, `#332`: "Session ended by device" a few seconds into streaming. On firmware 129 this is the call rule.
- `#260`: in-stream photo during HFP; the stream dips to about 3.5–5 fps during an in-stream capture ("expected today").

## Device tests

`RAYBAN_CONNECTION.md` rows A–V. Keep the 0.5.0 IPA until A, B, N and S pass.
