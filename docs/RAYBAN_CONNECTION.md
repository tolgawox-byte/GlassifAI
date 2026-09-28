# Ray-Ban connection

How AutoLoom connects to Ray-Ban Meta glasses, what was wrong, and how to test it. Branch `autoloom-glasses-jarvis-v1`; rollback tag before this work: `rollback-dd1b756-before-connection-fix`.

**Status: PHYSICAL TEST REQUIRED.** The fixes below are built and unit-tested in CI. A green build only means the code compiles and the state machine behaves in tests; the connection is not called fixed until the tests at the end pass on the iPhone and the glasses.

## Versions

| | Value | Source |
|---|---|---|
| DAT SDK in this build | **0.5.0** (`MWDATCore`, `MWDATCamera`) | `Package.resolved` |
| Meta AI app required by DAT 0.5.0 | **V254** or newer (iOS and Android) | Meta DAT "Version dependencies" |
| Ray-Ban Meta firmware required by DAT 0.5.0 | **V22** or newer | same page |
| DAT 1.0 (not this build) | Meta AI V290, firmware V128 | branch `autoloom-glasses-dat1`, `DAT_1_MIGRATION.md` |

No DAT 1.0 APIs are used in this build.

## Root causes found in the code

The code was traced from `Wearables.configure()` through registration, devices, link state, camera permission and `StreamSession.start()`. Each finding below is backed by the code or by Meta's documentation. Which one affected your glasses can only be confirmed on the device; the diagnostics screen now shows it.

1. **The camera gave up after about a minute.** The Ray-Ban camera was started by a loop of 20 tries, 3 s apart. Each try first checks the camera permission, and that check fails while no glasses are connected (`PermissionError.noDevice` / `.noDeviceWithConnection`; Meta: "If all devices disconnect, permission checks will indicate unavailability"). Glasses that were asleep, folded, in the case or out of range for longer than the loop were never started again. Nothing reacted to the glasses coming back: not the link state, not the SDK's device selector. Only reopening the app or switching the camera source restarted it. After a fold and unfold the camera stayed off.
2. **Meta AI's callback could be lost.** The registration and permission callback (`glassifai://…?metaWearablesAction=…`) was handled by a view inside the glasses screen. After a cold launch, and iOS often terminates an app while the user is in Meta AI, that screen does not exist while the ChatGPT sign-in is still restoring. The callback that relaunched the app reached no handler, so registration never completed and the connect screen kept waiting.
3. **Connect registered again and could spin forever.** The Connect button always called `startRegistration()`, even for an app that was already registered. The registration state was read once at launch, so an update arriving before the listener started was missed. If Meta AI was closed without approving, the state stayed "registering" and the disabled "Connecting…" button never came back.
4. **A codec problem looked like a connection problem.** Stream errors were shown in the same place as "glasses unavailable".
5. **Developer Mode allows one app.** Meta: "only one 3rd party app can remain registered at a time in Developer Mode. Registering a new app will automatically unregister any previously registered app." Using another glasses app (Meta's samples, other assistants) silently removes AutoLoom's registration. This is Meta's rule, not a bug, but the app did not explain it.

The configuration was checked as well: `CFBundleURLSchemes` contains `glassifai`, which matches `AppLinkURLScheme` `glassifai://`. `bluetooth-central`, `external-accessory` and `com.meta.ar.wearable` are present, and the Bluetooth usage text is set. `MetaAppID` and `ClientToken` were empty strings. Meta says Developer Mode does not use them ("omit these values or simply use 0"), and Meta's own sample uses `0`, so they are now `0` by default through the build settings `META_APP_ID` and `CLIENT_TOKEN` (and can still be overridden for a production build).

## The connection now

`WearableConnectionCoordinator` (`ios/GlassifAI/Runtime/WearableConnection.swift`) is the one source of truth. It is attached at launch, before any screen. Screens read its phase and plain-language status; only the coordinator starts registration or the glasses camera.

```
SDK_UNAVAILABLE
RESTORING                   first 1.5 s after launch (6 s if registered before): the SDK may still restore the registration
NOT_REGISTERED              → Connect
REGISTRATION_STARTING       Meta AI is opening
WAITING_FOR_META_AI         the user approves in Meta AI
REGISTRATION_STALLED        no approval came back → Try Again
REGISTERED_NO_DEVICE        "Wake your glasses"
DEVICE_DISCONNECTED         "Wake your glasses"
DEVICE_CONNECTING           "Connecting…"
DEVICE_CONNECTED            "Ray-Ban Connected" (camera not chosen)
REQUESTING_CAMERA_PERMISSION
CAMERA_PERMISSION_NEEDED    "Permission needed" → Try Again (opens Meta AI once)
STARTING_CAMERA             "Ray-Ban Connected · Starting camera…"
CAMERA_STREAMING            streaming, no frame yet
CAMERA_FAILED               "Ray-Ban Connected · Camera unavailable — trying again"
READY                       frames arriving
```

The phase is computed by a pure function (`GlassesConnectionReducer.phase(for:)`) from a snapshot of facts: SDK configured, registration, devices, `LinkState`, the active device, whether the Ray-Ban camera is chosen, camera permission, stream state and frames. The unit tests drive it without glasses.

**Registration**
- Runs only when not registered, and one flow at a time. A second Connect tap starts nothing.
- An app that is already registered never registers again: Connect then looks for the glasses.
- The callback is handled by the app root's `onOpenURL`, whatever screen is showing.
- The registration state is also polled once a second while a request is open, so a missed event cannot hang the flow.
- If Meta AI does not open within 10 s, or the user is back in AutoLoom for 12 s without an approval, the flow stops with "Meta AI didn't confirm" and one Try Again.
- A registration lost to another Developer Mode app is explained on the connect screen.
- Nothing unregisters automatically. Only Settings → Ray-Ban glasses → Forget glasses does, after a confirmation.

**Link and camera**
- The coordinator listens to the devices stream, each device's `LinkState` and compatibility, and the SDK's `AutoDeviceSelector`, which selects the glasses only while they are connected. A device the SDK cannot resolve yet gets its listeners two seconds later.
- The camera is started only when the glasses are registered and linked and the Ray-Ban camera is chosen. It is never started twice: `startSession()` only runs from `stopped`, and only one attempt is in flight.
- Permission is checked first. Meta AI is asked for it only on screen and only once per app run; after that, Try Again asks again.
- **Auto reconnect.** When the glasses return, the link comes up or the device is selected again, the camera starts at once. After failures, attempts back off 1, 2, 4, 8, 15 and then every 30 s. There are no busy loops.
- A stream stuck in "starting" for 25 s while the glasses are linked is stopped and started again.
- The HEVC transport and its automatic raw fallback are unchanged. A transport failure shows as "Ray-Ban Connected · Camera unavailable", never as a connection failure, and the fallback's own stop is not counted as a failure.

**Foreground, background, lock**
- Returning to the app re-reads registration, devices and link from the SDK and tries a stopped camera at once.
- One `StreamSession` exists for the app's lifetime, as before. Coming back to the foreground creates no new session and no new listeners.
- The stream is never stopped because the app left the screen (see `BACKGROUND_STREAMING.md`). In the background the camera can be restarted if the permission is already granted; Meta AI is never opened from the background.

**What the user sees**
- The Assistant screen shows a status pill at the top: "Ray-Ban Connected", "Connecting…", "Wake your glasses", "Permission needed" or "Ray-Ban unavailable". The camera state appears as a short second line.
- When the glasses link comes up, a short "✓ Ray-Ban Connected" confirmation appears with a light haptic, at most every 30 s. It is never spoken.
- Until the first frame, the glasses view shows the link animation (searching, found, connected, attention), driven by the real phase, and at most one "Try Again".
- Failure messages are plain sentences, for example "Meta AI yüklü değil. App Store'dan yükleyip tekrar dene." Raw error names only appear in the diagnostics.

## Diagnostics

Settings → Developer → **Ray-Ban connection** shows:
- the phase, DAT version, whether the SDK started (and why not);
- the configuration the installed app really runs with: bundle id, `AppLinkURLScheme`, URL schemes, and whether `MetaAppID`, `ClientToken` and `TeamID` are set (never their values);
- registration state, registered devices, the active device, a device-id hash, link state and compatibility;
- camera permission, stream state, frames, codec, start attempts, the last error, and the last 60 transitions with times.

**Copy sanitized connection report** copies states, counts and errors only: no identifiers, tokens, configuration values or image content.

Developer-only actions: Refresh device state, Restart stream, and Re-register with Meta AI (with a confirmation).

## Physical test matrix

Install `AutoLoomMediaGlasses-Release-unsigned.ipa` from the CI run named in `TEST_REPORT.md`. Meta AI must be in Developer Mode (Meta AI → Settings → App Info → tap the version five times). After any failure, copy the report from Settings → Developer → Ray-Ban connection.

| # | Test | Pass when | Result |
|---|---|---|---|
| A | Fresh install → Connect → approve in Meta AI → back | "Approve in Meta AI" while there; back in AutoLoom the camera starts without another tap; pill "Ray-Ban Connected" | |
| B | Close AutoLoom (swipe away), reopen | No connect screen, no Meta AI; "Connecting to Ray-Ban…" then "Ray-Ban Connected"; camera starts | |
| C | Fold the glasses (or turn them off), wait 1 minute, open them | "Wake your glasses" while folded; after opening, the camera returns by itself (no tap, no reopening the app) | |
| D | Put the glasses out of Bluetooth range for 30 s (other room), come back | Returns by itself; the report shows backoff attempts, not a busy loop | |
| E | Meta AI keeps the glasses paired; open AutoLoom | Starts normally, no registration | |
| F | Lock the phone 30 s, unlock (camera running) | No duplicate session; the view resumes (see `BACKGROUND_STREAMING.md` for vision while locked) | |
| G | Switch Wi-Fi off and on, or go from Wi-Fi to cellular | The glasses stay connected (Bluetooth); the conversation reconnects on its own | |
| H | In Meta AI turn AutoLoom's camera permission off; open AutoLoom → then Try Again → allow | "Permission needed"; Try Again opens Meta AI once; after allowing, the camera starts | |
| I | Settings → Camera → transport HEVC; if the camera does not start, wait 15 s | Pill stays "Ray-Ban Connected" while the camera line says "Starting camera…" / "Camera unavailable"; with a fallback the report says "Switched to raw" | |
| J | Tap Connect twice quickly on the connect screen | Meta AI opens once | |
| K | Close Meta AI without approving, return to AutoLoom | Within about 12 s: "Meta AI didn't confirm" with one Try Again (no endless spinner) | |
| L | Hey AutoLoom (wake phrase) with the glasses on | "Connecting"; "Bağlandım, dinliyorum." only when the voice is really ready, through the glasses' audio when that route is selected | |

Do not mark a row passed on a green build. If A–C fail, send the copied connection report.

## Files

- `Runtime/WearableConnection.swift`: states, reducer, configuration audit, coordinator.
- `Runtime/ConnectionDiagnosticsView.swift`: the developer screen.
- `Views/StreamSessionView.swift`: camera source → coordinator; lifecycle events.
- `GlassifAIApp.swift`: attach at launch; root `onOpenURL`.
- `ViewModels/StreamSessionViewModel.swift`: idempotent start, typed permission errors, transport switch flag.
- Tests: `GlassifAITests/AutoLoomConnectionTests.swift`.
