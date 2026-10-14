# Ray-Ban connection

How AutoLoom connects to Ray-Ban Meta glasses, what was found when the owner's sideloaded build would not connect (2026-10-13), what changed, and how to test it. Branch `autoloom-glasses-jarvis-v1`.

**Status: PHYSICAL TEST REQUIRED.** Everything below is built and unit-tested in CI. A green build only means the code compiles and the state machine behaves in tests. The connection is not called fixed until the tests at the end pass on the iPhone and the glasses.

**Hızlı cihaz testi (Türkçe, yaklaşık 20 dakika):**
1. `TEST_REPORT.md`'de yeşil görünen son koşunun Release IPA'sını indir. Dosya adındaki 7 karakter, uygulamada Ayarlar → Geliştirici → Commit ile aynı olmalı (satır T).
2. IPA'yı imzala ve yükle; bundle id'yi değiştirme (içinde `-` olmasın).
3. Hazırlık: Meta AI 290 veya üstü, gözlük yazılımı 128 veya üstü; Meta AI'da Geliştirici Modu açık; AirPods gibi başka bir Bluetooth kulaklık bağlı değil; gözlüğü güç anahtarından bir kez kapatıp aç.
4. Satır A ve B: bağlan, sonra uygulamayı kapatıp yeniden aç.
5. Satır N ve N2: Ray-Ban kamerası açıkken konuş. Önce kameraya güvenli ses açıkken (varsayılan), sonra Ayarlar → Ses çıkışı → "Ray-Ban kamerasıyla iPhone mikrofonu" kapalıyken.
6. Satır S ve U: akıcılık ve fotoğraf boyutu (Ayarlar → Geliştirici → Kamera tanılaması).
7. Bir şey başarısız olursa: Ayarlar → Geliştirici → Ray-Ban bağlantısı → raporu kopyala (Meta SDK günlüğü dahil, kimlikler maskeli) ve gönder (satır V).

Rollback tags:
- `rollback-43ca5f2-before-dat1-port`: the last DAT 0.5.0 build (plan 2.4, run 38492438643).
- `rollback-dd1b756-before-connection-fix`: before the first connection rework.

## Versions

| | Value | Source |
|---|---|---|
| DAT SDK in this build | **1.0.1** (`MWDATCore`, `MWDATCamera`), released 2026-10-09 | `Package.resolved` (revision `0bd36929`) |
| Meta AI app required by DAT 1.0 | **V290** or newer | Meta DAT "Version dependencies" |
| Ray-Ban Meta firmware required by DAT 1.0 | **V128** or newer | same page |
| iOS | **17.2** or newer (DAT 0.9 raised the minimum) | DAT changelog 0.9.0 |
| Previous builds | DAT 0.5.0 (Meta AI V254, firmware V22) until `43ca5f2` | tag `rollback-43ca5f2-before-dat1-port` |

Meta's table only lists minimum versions per release (0.5.0: V254/V22 … 0.9.0: V282/V126 … 1.0.0: V290/V128). It does not promise that an old SDK keeps working with new glasses software.

## Why the sideloaded build did not connect: the evidence

No connection report from the glasses was available, so the cause is found from the code, Meta's documentation and Meta's own SDK issue tracker. The diagnostics below now show which layer fails on the device. The research behind this list: `GlassifAI-research/2026-10-14/D1_dat_apps_connection_camera.md` (24 DAT apps and Meta's issues; not in the repository).

1. **The glasses stop the camera while their microphone is connected.** This is the most likely shared cause of both symptoms: no connection and a choppy image.
   - Meta, 2026-10-13, SDK issue #332: "Glasses firmware 129 added a rule: while the glasses consider a call to be active, they end any running DAT session and decline new ones." A WebRTC call routed to the glasses "matches that". "A 0.9.0 app on firmware 129 would behave the same way."
   - Meta, 2026-10-13, Android SDK issue #206: the camera session ends about 80 ms after the glasses microphone connects over Bluetooth hands-free (HFP/SCO). This happens in every order tried, including Meta's documented one. Meta: "nothing on the app or SDK side keeps HFP and a camera session running together on this firmware". A glasses update will fix it; there is no date. Until then: "keep the HFP route closed while a DAT session is active".
   - AutoLoom used exactly this setup by default with the Ray-Ban camera:
     - the conversation took the glasses' microphone over HFP (`.voiceChat`, `.allowBluetoothHFP`, WebRTC);
     - so did the wake phrase listener in Hands-Free Ready.
   - The camera was ended or refused as soon as a conversation, or the wake listener, opened the glasses microphone.
   - HFP also takes Bluetooth bandwidth from the camera. Meta measured about 8 of 24 requested frames per second (#260); another app measured a cap of 15 fps.
2. **The app's Meta toolkit was seven months behind the glasses.**
   - The build linked DAT **0.5.0** (2026-03-11).
   - Since then Meta introduced:
     - the DAT App Model (0.7), an app installed on the glasses;
     - made it mandatory (0.9);
     - and released 1.0 (2026-09-24), which needs Meta AI V290 and firmware V128, rolling out from 2026-09-30.
   - After that update the glasses report the on-glasses DAT app as "1.0.0.0.0" (SDK issue #308).
   - Meta's runtime guide: "`INSUFFICIENT_SDK_VERSION`: the app uses an SDK version the glasses no longer support… Release a newer version of your app built with the current SDK."
   - Meta's known issues: new versions "may not be compatible with apps that are not using the latest SDK".
   - Only apps on SDK 1.0 can take part in registrations that Meta AI starts itself.
   - No build since the 0.4.0 → 0.5.0 bump (2026-09-27) has been tried on the glasses.
   - No public report says whether 0.5.0 still works on firmware 128 or newer. Meta's answer to older SDKs failing with the new on-glasses DAT app is "update your app to 1.0.1" (#308).
   - Meta's known issues: after the V128 update, the glasses must be rebooted or camera capture does not work.
   - Developer Mode must be "re-pushed" (turned off and on in Meta AI) after firmware or SDK updates (Android issue #169).
3. **Developer Mode could not be switched on in Meta AI 290.x for some days.**
   - Tapping the version only showed "Copied to clipboard" (issues #310 and #325).
   - Meta says it fixed this on its side around 2026-10-06; the fix needs Meta AI to be force-quit and reopened.
   - Without Developer Mode, registration hands off to Meta AI, which shows "Internal error" and never calls the app back.
   - The app cannot change this. The connect screen now lists the steps.
4. **Glasses that refuse every new session.**
   - The pattern: `DeviceSession.start()` ends within a fraction of a second with "Device unavailable" or "Session ended by device", while the link is connected and the permission is granted.
   - Reported after firmware updates, and after the Bluetooth hands-free microphone (HFP) was released and set up again around sessions (issue #292).
   - Meta's engineer gives this recovery: switch the glasses off and on with the power switch; the case is not enough.
   - Before this change, the app would have shown this as a generic camera failure and retried every 30 s forever.
5. **One Developer Mode app at a time.** Using another glasses app (Meta's samples, VisionClaw, OpenVision and others) silently removes AutoLoom's registration. The app already explained this; it is now also on the connect screen.
6. **Bluetooth off or not allowed looked like sleeping glasses.** Bluetooth turned off, or the permission denied for AutoLoom, showed "Wake your glasses".
7. **The image came from the iPhone.**
   - The default camera is the iPhone's.
   - The Ray-Ban camera was used only after choosing it in Settings, even after connecting the glasses.
8. **The IPA itself** (see "The installed IPA" below):
   - it is unsigned, and the owner's signing tool re-signs it;
   - re-signing tools that change the bundle identifier can add a `-`, which Meta's toolkit has rejected (issues #212 and #282).

The earlier connection rework (`dd1b756`) fixed five other causes. They are still in place:
- a camera that gave up after a minute;
- a lost Meta AI callback;
- re-registering on every Connect;
- codec errors shown as connection errors;
- the one-app rule.

## What changed in this build (`9954e60`, `6c840b5`, `66b3388`)

- **Camera-safe audio (on by default).**
  - While the Ray-Ban camera is the chosen source, the glasses' hands-free microphone stays closed. Conversations use the iPhone's microphone and speaker, and the wake phrase listener uses the iPhone microphone.
  - The audio session then does not even allow Bluetooth hands-free (`.allowBluetoothHFP` is left out).
  - Settings → Audio → "Ray-Ban kamerasıyla iPhone mikrofonu" turns it off once Meta's glasses update has arrived.
  - If the glasses still end or refuse a session while their microphone is connected (a phone call, or the setting off), the app shows "Kamera görüşme yüzünden kapalı". It stops retrying and starts the camera again when the microphone link closes, no sooner than after 2 s.
- **DAT 1.0.1.**
  - One `DeviceSession` per glasses, started before anything else.
  - The camera is a `Camera` on that session, with:
    - the `stream` child (HEVC with an automatic raw fallback, through the same frame pipeline);
    - the `photo` child.
  - Session errors keep their meaning: insufficient SDK, DAT app update needed, DAT app unavailable, version warning, thermal or battery.
- **Refusals are counted.**
  - After three "Device unavailable" or "Session ended by device" errors in three minutes, the app stops retrying.
  - It says: "Gözlüğü güç düğmesiyle kapatıp aç (kutuya koymak yetmez), sonra tekrar dene."
  - A link that drops and comes back (the power cycle) clears it.
- **A stream that delivers nothing gets a fresh session.**
  - Meta's issue #287: re-adding the camera to a live session delivered nothing; a new session recovered every time.
- **Versions are named, not retried.**
  - "AutoLoom güncellemesi gerekiyor" when the glasses need a newer SDK. Only a newer build fixes this; the iPhone camera keeps working.
  - "Meta AI'da güncelleme gerekiyor" when the glasses' firmware or their DAT app needs an update. This one has an **Open in Meta AI** button (`openFirmwareUpdate` / `openDATGlassesAppUpdate`).
- **Bluetooth** permission and power are read from CoreBluetooth without scanning, and named on screen.
- **Registrations started in Meta AI** (DAT 1.0 `handleUrl(_:onRegistrationRequest:)`) are continued; the approval happens in Meta AI.
- **Temple gestures** follow the camera's session (DAT 1.0 allows one session per glasses). The app's own stops (a source switch, a recovery) never end the conversation.
- **Connecting the glasses switches the camera to the Ray-Ban.**
  - It switches from the iPhone camera; "camera off" stays off.
  - Home shows "Ray-Ban bağlı · gözlük kamerasına geç" whenever the glasses are linked but the iPhone camera is chosen.
- **Retries are paced:** never two session attempts within 2 s (Meta: rapid cycling wedges the glasses until a power cycle, #231). The HEVC → raw fallback and the stall monitor wait 20 s, because a cold start over Bluetooth can take 15–18 s.
- **A smoother default stream:** "Live", 504×896 at 24 fps.
  - Over Bluetooth a 720p request is delivered as 504×896 after 15–25 s anyway, at about 60 kB/s whatever the resolution (discussion #297).
  - Meta: "Request lower settings for higher visual quality per frame". Meta's own sample asks for 360×640 at 24 fps.
  - The 720p profiles are still in Settings → Camera.
- **Reading requests take an in-stream photo:** about 1080×1440 in 1–2 s on DAT 1.x (#297, #260), larger than the stream. Meta calls it "the supported way to get a still while you need live video". Ordinary questions use the sharpest recent frame at once. Camera diagnostics show the photo size that really arrives.
- **The full-resolution photo** (`Camera.photo`, Meta beta) is opt-in. The stream must stop for it, and restarting a stopped stream can fail on 1.0 (#260), so the live view comes back through a fresh session.
- **The Meta SDK's own log** (`MetaWearablesDAT.log`): its lines with causes appear in the connection diagnostics and the copied report, sanitized, with serials and IDs masked. Examples are "no longer registered", the glasses' DAT app, link switching.
- **The glasses microphone before the camera stream** (Meta's documented order). Only used when camera-safe audio is off (see "Audio and camera" below).
- **Diagnostics**: a layer table, signing, a bundle-id check and the worn/folded/battery state (see "Diagnostics" below).

## Connection states

```
SDK_UNAVAILABLE
RESTORING                    first 1.5 s after launch (6 s if registered before)
NOT_REGISTERED               → Connect
REGISTRATION_STARTING        Meta AI is opening
WAITING_FOR_META_AI          the user approves in Meta AI
REGISTRATION_STALLED         no approval came back → Try Again
BLUETOOTH_UNAVAILABLE        "Bluetooth kapalı" (off, or not allowed for AutoLoom)
REGISTERED_NO_DEVICE         "Wake your glasses"
DEVICE_DISCONNECTED          "Wake your glasses"
DEVICE_CONNECTING            "Connecting…"
DEVICE_CONNECTED             "Ray-Ban Connected" (camera not chosen)
APP_UPDATE_REQUIRED          this build's DAT is too old for the glasses (no retry)
GLASSES_UPDATE_REQUIRED      firmware or the on-glasses DAT app → Open in Meta AI, Try Again
REQUESTING_CAMERA_PERMISSION
CAMERA_PERMISSION_NEEDED     "Permission needed" → Try Again (opens Meta AI once)
STARTING_SESSION             the DAT device session is starting
SESSION_PAUSED               paused by a temple tap or the system
GLASSES_APP_UNAVAILABLE      the DAT app on the glasses did not come up → Try Again
GLASSES_REFUSING             refused sessions → power-switch cycle, Try Again (no retry)
STARTING_CAMERA              "Ray-Ban Connected · Starting camera…"
CAMERA_STREAMING             streaming, no frame yet
CAMERA_FAILED                "Ray-Ban Connected · Camera unavailable — trying again"
READY                        frames arriving
```

The phase is computed by a pure function (`GlassesConnectionReducer.phase(for:)`) from a snapshot of facts:
- Bluetooth;
- the SDK;
- registration;
- devices and link;
- compatibility;
- whether the Ray-Ban camera is chosen;
- camera permission;
- the device session and its problem;
- stream state and frames.

"✓ Ray-Ban Connected" appears only when the glasses are usable. Phases that need the user never show it.

## Diagnostics

Settings → Developer → Ray-Ban connection:

- **Layers (measured now)**, one row each, refreshed every second:
  - Bluetooth (permission, on/off);
  - Meta DAT SDK;
  - Meta AI registration;
  - glasses link (worn, folded, battery);
  - glasses session and its problem;
  - Ray-Ban camera (state, measured fps, last frame age);
  - the image the assistant sees (source, resolution, age);
  - microphone;
  - sound output;
  - the realtime AI session and its data channel.

  A value that cannot be measured is "—", never a guess.
- The configuration the installed app runs with:
  - bundle id, `AppLinkURLScheme`, URL schemes;
  - whether MetaAppID, ClientToken and TeamID are set (never their values);
  - warnings (a `-` in the bundle id);
  - **Signing**, read from the embedded provisioning profile: development or distribution, days until it expires, whether Wi-Fi streaming entitlements exist. Never team names, identifiers or device lists.
- Registration, devices, link, compatibility, worn, hinges, battery, thermal, last linked.
- Session state, session problem, camera permission, stream state, frames, last ready, codec, start attempts, last error.
- A switch for the microphone-first order (on by default; for comparison on the device).
- **Copy sanitized connection report**: states, counts and errors only (no identifiers, tokens, configuration values or image content).

Camera diagnostics also measure smoothness: Ray-Ban frame interval median and p95, stutters (gaps of 250 ms or more) and the longest gap.

## Audio and camera

**On current glasses software, the glasses' microphone and the Ray-Ban camera cannot run at the same time.** Meta has confirmed this (Android #206, iOS #332, 2026-10-13); a glasses-side fix is coming, with no date.

| Camera source | Conversation microphone and speaker | Why |
|---|---|---|
| Ray-Ban (camera-safe audio on, default) | iPhone | The glasses would end the camera session as soon as their microphone connects |
| Ray-Ban (camera-safe audio off, after Meta's fix) | Glasses (HFP), with Meta's documented order: the microphone settles before the stream starts | Meta's "Microphones and speakers" guide |
| iPhone camera or camera off | As set in Settings → Audio (Automatic: glasses with the camera off) | No DAT camera session |

- The cost: with the Ray-Ban camera, you are heard through the iPhone's microphone and the answer comes from the iPhone's speaker. Keep the phone where it can hear you.
- **Next (owner decision):** DAT 1.0's in-stream audio would bring the glasses microphone back while the camera runs. Meta says this "is the mic path that works alongside the camera right now". The catches:
  - it is experimental (apps using it cannot be published yet);
  - it is not beamformed, so ambient noise is louder;
  - the WebRTC voice pipeline needs a custom audio source for it.
- Releasing HFP and setting it up again around sessions has also locked glasses out until a power-switch cycle (#292). Camera-safe audio avoids that as well.

## The installed IPA

- CI builds unsigned Debug and Release IPAs.
  - The file names carry the commit, for example `AutoLoomMediaGlasses-Release-9954e60-unsigned.ipa`.
  - The app's Info.plist carries the commit (`AutoLoomCommitSHA`), shown in Settings → Developer as **Commit**.
- `scripts/ci-ipa-check.sh` checks every IPA before it is zipped and publishes what it contains as an annotation:
  - commit and bundle id;
  - Meta DAT version and embedded Meta frameworks;
  - MetaAppID (Developer Mode `0`), callback scheme `glassifai://`;
  - URL schemes, accessory protocol `com.meta.ar.wearable`, `bluetooth-central`.
  - A wrong commit, a missing scheme or protocol, a `-` in the bundle id, or the test-only mock framework inside fails the build.
- **Signing is the owner's step.** The IPA must be signed (with Xcode, or a sideloading tool and an Apple ID) before iOS installs it. A free Apple ID's signature expires after 7 days, then the app does not open; the diagnostics show the days left.
- Keep the bundle id unchanged when re-signing: no `-`.
- No secrets, certificates or profiles are in the repository.
- **Wi-Fi streaming (not used):** DAT can stream over Wi-Fi with the glasses' hotspot. It needs the Hotspot Configuration and Wi-Fi Information entitlements, which a free signing team cannot use. While streaming, the iPhone's Wi-Fi internet goes to the glasses' hotspot. This build streams over Bluetooth Classic, as Meta's camera guide describes, and adds no Wi-Fi keys. Wi-Fi streaming is an owner decision for a paid developer account.

## Before connecting (also on the connect screen)

1. Meta AI 290 or newer, glasses software 128 or newer (Meta AI → Devices → glasses → Settings → General → About).
2. Developer Mode on: Meta AI → Settings → App info → tap the version 5 times. If Meta AI offers to install DAT on the glasses, wear them and keep Meta AI open.
3. Developer Mode keeps one app at a time: after another glasses app, connect AutoLoom again.
4. iPhone Bluetooth on and allowed for AutoLoom.
5. Still refused: power-switch the glasses off and on, then Try Again.

## Physical test matrix

Install the Release IPA of the CI run named in `TEST_REPORT.md`. Its commit must match Settings → Developer → Commit.

After any failure, copy the report from Settings → Developer → Ray-Ban connection.

| # | Test | Pass when | Result |
|---|---|---|---|
| A | Fresh install → Connect → approve in Meta AI → back | "Approve in Meta AI" while there; back in AutoLoom the camera switches to Ray-Ban and starts without another tap; layer table: session started, camera fps > 0 | NOT RUN |
| B | Close AutoLoom (swipe away), reopen | No connect screen, no Meta AI; "Connecting to Ray-Ban…" then "Ray-Ban Connected"; camera starts | NOT RUN |
| C | Fold the glasses, wait 1 minute, open them | "Wake your glasses" while folded (worn/folded in the layer table); after opening, the camera returns by itself | NOT RUN |
| D | Out of Bluetooth range for 30 s, come back | Returns by itself; the report shows backoff attempts, not a busy loop | NOT RUN |
| E | Meta AI keeps the glasses paired; open AutoLoom | Starts normally, no registration | NOT RUN |
| F | Lock the phone 30 s, unlock (camera running) | No duplicate session; the view resumes | NOT RUN |
| G | Wi-Fi off/on, or Wi-Fi → cellular | The glasses stay connected (Bluetooth); the conversation reconnects on its own | NOT RUN |
| H | Turn AutoLoom's camera permission off in Meta AI; Try Again → allow | "Permission needed"; Try Again opens Meta AI once; after allowing, the camera starts | NOT RUN |
| I | Settings → Camera → transport HEVC; if the camera does not start, wait 15 s | Pill stays "Ray-Ban Connected" while the camera line says "Starting camera…"; a fallback shows "Switched to raw" | NOT RUN |
| J | Tap Connect twice quickly | Meta AI opens once | NOT RUN |
| K | Close Meta AI without approving, return | Within about 12 s: "Meta AI didn't confirm" with one Try Again | NOT RUN |
| L | Hey AutoLoom with the glasses on | "Bağlandım, dinliyorum." only when the voice is ready. Camera off or the iPhone camera: through the glasses' audio. Ray-Ban camera with camera-safe audio on (the default): through the iPhone, and the camera keeps streaming | NOT RUN |
| M | Turn Bluetooth off in Control Center, then on | "Bluetooth kapalı", not "Wake your glasses"; returns by itself | NOT RUN |
| N | Start a conversation with the Ray-Ban camera running (camera-safe audio on) | The camera keeps streaming; you are heard through the iPhone microphone and the answer plays from the iPhone; the layer table shows "iPhone mic" and the camera's fps does not drop | NOT RUN |
| N2 | Same with camera-safe audio off (Settings → Audio) | On current glasses software the camera stops within seconds and "Kamera görüşme yüzünden kapalı" appears; after the conversation the camera comes back by itself. This confirms the call rule on the owner's glasses | NOT RUN |
| O | Five conversations in a row (start, ask about the view, end) | No "Device unavailable"; if the glasses start refusing, "Gözlük bağlantıyı reddediyor" appears after three refusals and the app stops retrying; power-switch cycle + Try Again recovers | NOT RUN |
| P | Tap the glasses' temple during a conversation, then wait 40 s before tapping again | The first tap: "Duraklatıldı" (paused) and the microphone mutes; the camera stays paused for the whole 40 s (the app never restarts it); the second tap resumes both. The app's own camera switch never hangs up. A long press, fold or doff ends the conversation only when it runs on the glasses' microphone (camera-safe audio off) | NOT RUN |
| Q | Start the registration from Meta AI (App connections) instead of AutoLoom | AutoLoom opens and the registration completes | NOT RUN |
| R | Settings → Camera → Vision image → Full-resolution photo; ask "bunu oku" at a label | The view pauses for several seconds (a fresh session follows); the answer reads the label; Camera diagnostics → last photo shows a size larger than 1080×1440 | NOT RUN |
| S | Look around for 60 s with the Ray-Ban camera, first with "Live" (504p 24 fps), then "Detail" (720p 15 fps) | Camera diagnostics: actual resolution, fps, frame interval p95 and stutters for each; Live should be smoother at the same delivered resolution | NOT RUN |
| U | Ask "bunu oku" at a label with the default settings | Camera diagnostics → last photo shows the in-stream photo size (expected about 1080×1440) | NOT RUN |
| V | After a failure, open Settings → Developer → Ray-Ban connection → Meta SDK log | Lines naming the cause (for example "no longer registered", DWA, L2CAP) with IDs masked; copy the report | NOT RUN |
| T | Settings → Developer → Commit equals the IPA's file name | Same 7 characters | NOT RUN |

Do not mark a row passed on a green build.

## Files

- `Runtime/WearableConnection.swift`: phases, reducer, configuration audit, coordinator.
- `Runtime/ConnectionLayers.swift`:
  - session failures and problems;
  - Bluetooth;
  - signing summary;
  - the layer table;
  - the microphone-first switch.
- `Runtime/ConnectionDiagnosticsView.swift`: the developer screen.
- `ViewModels/StreamSessionViewModel.swift`: DAT 1.0 session, camera, stream, photo, recovery.
- `Runtime/GlassesGestureSession.swift`: temple gestures from the session state.
- `Views/StreamSessionView.swift`: camera source → coordinator; microphone-first conversation start.
- `Views/HomeScreenView.swift`: the connect screen and its checklist.
- `scripts/ci-ipa-check.sh`: the IPA content check.
- Tests:
  - `GlassifAITests/AutoLoomConnectionTests.swift`;
  - `GlassifAITests/AutoLoomRayBanDAT1Tests.swift`;
  - `GlassifAITests/GlassifAITests.swift` (gestures; mock-device integration, run locally).
