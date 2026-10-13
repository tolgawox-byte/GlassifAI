# Remote Assist

Remote Assist lets a colleague on the **same Wi-Fi** see what the wearer's camera sees. The iPhone runs a small web server; the viewer opens the address shown on the phone in a browser and types a six-digit room code, then sees the camera view as a Motion JPEG stream (about two frames a second, 720 px, video only). Sharing never starts by itself or from words alone: only a tap on **Start** begins it, a red bar stays on every screen while it runs, and it stops on request, when the app leaves the screen, after 15 minutes, after ten wrong codes or when the phone is critically hot. The connection is **not encrypted**. Sharing over the internet would need a WebRTC signalling server, which is not set up. Code: `Runtime/RemoteAssist.swift`.

## Starting and stopping

| Do / say | What happens |
|---|---|
| Explore → "Uzaktan yardım / Remote Assist" → "Görüntümü paylaşmaya başla / Start sharing my view" | The only way to start. Shows the room code, the address (`http://<iPhone Wi-Fi IP>:<port>`) and the number of viewers |
| "Uzaktan yardımı başlat", "Görüntümü paylaş", "Start remote assist" | Opens the Remote Assist screen and says "Paylaşımı başlatmak için telefonda Başlat'a dokun; kod ekranda görünecek." Nothing is shared |
| "Paylaşımı durdur", "Paylaşımı bitir", "Stop sharing" | Stops at once ("Paylaşımı durdurdum.") |
| Red bar → "Durdur / Stop", or the screen's "Paylaşımı durdur" | Stops at once |

"Kaydı durdur" stops a recording, never the sharing (unit-tested).

## How it works

1. `RemoteAssistServer.start()` asks the `MediaResourceCoordinator` for `.remoteAssist` (see "Resource rules" below).
2. An `NWListener` (TCP, any free port) starts on the **Wi-Fi interface only** (`requiredInterfaceType = .wifi`) and accepts **only clients on the local network** (`acceptLocalOnly`): never cellular, a VPN or a global IPv6 address. The address uses the iPhone's `en0` IPv4 address. At most **four** viewers are served (a fifth gets "Too many viewers"), and a connection that sends no request within **10 s** is closed.
3. A random six-digit room code is made for this session.
4. The viewer's browser loads `/`: a small page (Turkish and English) that asks for the code.
5. `/stream?code=…` is compared with the code in constant time. Wrong code → HTTP 403; after **10 wrong codes** sharing stops. Right code → `multipart/x-mixed-replace` stream. Other methods get 405 and other paths 404.
6. Frames are sent only while at least one viewer is connected, from a camera frame at most 1.5 s old: JPEG, long side **720 px**, quality 0.55, at most 220 KB, one frame every **0.5 s** (every 1.0 s when the phone's thermal state is serious or worse). A viewer that falls behind is dropped.
7. No audio is sent. (`remoteAssistAudio` exists in the resource table for a future two-way audio mode; nothing uses it.)

## When it stops

| Reason | Notice |
|---|---|
| The user (voice, red bar, screen) | "Paylaşımı durdurdum." |
| The app goes to the background | "Uygulama arka plana geçtiği için paylaşım durdu." (no hidden background sharing) |
| 15 minutes | "Paylaşım 15 dakika sonunda durdu." |
| 10 wrong codes | "Çok fazla yanlış kod denendiği için paylaşım durdu." |
| Critical thermal state (`PerformanceGuard`) | "Telefon çok ısındığı için paylaşım durdu." |
| The listener fails | "Paylaşım bir hata yüzünden durdu." |

Sharing stops by itself when no camera frame has arrived for 10 s ("camera stopped"). Stopping closes every viewer connection and clears the code.

## Privacy and security

- **Starts only by a tap** on the phone; the voice command only opens the screen. The assistant's own planner cannot start it.
- A **red bar** ("Görüntün paylaşılıyor · <viewers>") with Stop is shown at the top of every screen while sharing, and a red chip on the Assistant screen.
- **Not encrypted**: plain HTTP on the local network. Anyone on the same network who has the code can watch, and the code travels in the address of the stream. Share only on a network you trust. TLS is planned (JARVIS plan 1.15): a per-session certificate makes browsers warn, so the viewer experience needs a device test first.
- Wi-Fi only and local network only (JARVIS audit M3); four viewers at most; idle connections are dropped after 10 s.
- The code is six digits and changes every session; there is no other account or login.
- Video only; nothing is recorded or uploaded by Remote Assist itself.
- The app's Local Network usage text mentions Remote Assist; whether iOS shows the Local Network prompt when sharing starts must be checked on the device.

## Over the internet (WebRTC)

Not implemented. Sharing outside the local network would need a WebRTC signalling server (and TURN for most networks). None is configured in this build (**REQUIRES_PROVIDER**).

## Resource rules (`MediaResourceCoordinator`)

- `.remoteAssist` requires `.cameraStream` to be running; `.remoteAssistAudio` would require `.remoteAssist` and conflicts with the conversation (`.realtimeVoice`) because both need the microphone.
- Frames are fanned out from one stream, so Remote Assist, Live Vision and a recording can run together.
- When sharing is refused, the reason is shown on the Remote Assist screen, e.g. "Önce kameranın açık olması gerekiyor."

**Known gap (code review at commit 8ee1a24):** no app code registers `.cameraStream` with the coordinator (only the unit tests do), so `start()` may always be refused with "The camera needs to be on first." even while the camera streams. This must be checked on the device (test RA1 in [PHYSICAL_TEST_MATRIX.md](PHYSICAL_TEST_MATRIX.md)) and, if confirmed, fixed in code.

## Tests

`AutoLoomRemoteAssistTests`: the phrases (start, stop, "Kaydı durdur" stays a recording command), words never start sharing, sharing needs the camera stream, constant-time code comparison, the viewer page asks for the code. The coordinator rules are tested in `AutoLoomJarvisExpansionTests.testMediaResourcesNeverFight`.

## Status

| Item | Status |
|---|---|
| Voice phrases; words never start sharing; code comparison | WORKING (unit tests) |
| LAN MJPEG sharing to a browser | PHYSICAL_TEST_REQUIRED (see Known gap) |
| Stops: background, 15 min, wrong codes, thermal | PHYSICAL_TEST_REQUIRED |
| Local Network permission prompt | REQUIRES_PERMISSION, PHYSICAL_TEST_REQUIRED |
| Two-way audio | UNAVAILABLE |
| Sharing over the internet (WebRTC) | REQUIRES_PROVIDER (signalling server not set up) |
