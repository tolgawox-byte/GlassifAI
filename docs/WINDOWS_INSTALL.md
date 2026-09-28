# Building and installing from Windows

There is no Xcode on Windows. GitHub Actions builds everything: the Rust bridge, the Swift app, the unit tests, and the unsigned IPAs. You sideload the IPA with the same Windows tool you used before (Sideloadly).

## 1. Get the IPA

1. Push to the `autoloom-glasses-jarvis-v1` branch (or `autoloom-glasses-vNext` / `autoloom-glasses-next` for the earlier lines). The workflow starts automatically. To run it by hand: GitHub → **Actions** → *Build AutoLoom Media Glasses IPA* → **Run workflow**.
   - A push whose newest commit message contains `[skip ci]` does not start a build.
2. Wait for the green check. The first run on a new branch takes about 25–30 minutes, because the Rust cache is per branch. Later runs take about 12–18 minutes.
3. Open the run and download the **AutoLoomMediaGlasses-unsigned-IPAs** artifact (a zip file).
4. Unzip it. It contains:
   - `AutoLoomMediaGlasses-Release-unsigned.ipa`: **install this one**. It is optimized, so the camera pipeline, OCR, and UI run faster.
   - `AutoLoomMediaGlasses-Debug-unsigned.ipa`: the same code, unoptimized. Use it only if the Release build misbehaves.

If a build fails, the run page lists compiler errors and failed tests as annotations. You don't need to open the raw log.

## 2. Install (sideload)

Use the same tool and Apple ID as before.

- **Keep the bundle ID `com.marcoiannello.GlassifAI`.** Turn off any "change bundle ID" option. Changing it breaks the Meta glasses registration and creates a separate app without your login.
- Signing with the same Apple ID updates the app in place and keeps your ChatGPT login (Keychain), the glasses registration, your settings, AutoLoom notes, and memory. Jarvis v1 imports the earlier memory and notes into its new store on first launch.
- If iOS asks: **Settings → General → VPN & Device Management**, trust the developer profile, and keep **Developer Mode** on.
- A free Apple ID expires sideloaded apps after 7 days. Re-sign with the same tool to renew.

## 3. Before the first test of this build

This build uses **Meta Wearables DAT 0.5.0**. The previous one used 0.4.0. Meta's official requirement for 0.5.0 is **Meta AI app V254 or later** and **Ray-Ban Meta firmware V22 or later**. Check both in the Meta AI app (Devices → your glasses → settings → firmware version, and the app's About page). A current installation normally has much newer versions.

## 4. First launch checklist

1. Jarvis v1 shows a short onboarding once. Then the Assistant tab opens if you were already signed in; otherwise use **Continue with ChatGPT** and enter the device code.
2. Tap the camera indicator at the top right and choose **Ray-Ban**. The glasses view should appear within a few seconds.
3. Open **Settings → Developer → Diagnostics** and check:
   - **Commit**: must match the Actions run
   - **DAT SDK**: 0.5.0
   - **Ray-Ban**: *Requested* (for example 720×1280 @ 15 fps, HEVC) and *Actual* (what really arrives)
   - **Transport**: HEVC (hvc1). If it shows raw with a transport note, HEVC failed and the app fell back automatically. Report the note.
4. Open **Settings → Models** and note the list. It shows whether GPT-6 Astra is exposed to this connection.
5. Open **Settings → Voice**: if an earlier build had a voice this protocol cannot use, a note says it was replaced by Juniper. Try ▶ Preview on a few voices.

## Rollback

- **Previous app (vNext):** the IPA from Actions run [36362397832](https://github.com/tolgawox-byte/GlassifAI/actions/runs/36362397832) (tag `baseline-3cb0437-vnext`). Older: run [36303697299](https://github.com/tolgawox-byte/GlassifAI/actions/runs/36303697299) (DAT 0.4.0, tag `baseline-44f089d-vision-working`).
- **Source:** the branches `autoloom-glasses-vNext` and `autoloom-glasses-next` are untouched; running the workflow on them rebuilds those versions. Memories and notes added in Jarvis v1 are not visible to older builds (their old JSON files are kept as backups).
- **Settings in this build that return to earlier behaviour without reinstalling:**
  - Settings → Camera & Ray-Ban → Video transport → **Raw** (the SDK decodes, as before)
  - Settings → Camera & Ray-Ban → Stream profile → **Balanced — 720p, 24 fps (original)**
  - Settings → Camera & Ray-Ban → Preview → **Legacy**
  - Settings → Camera & Ray-Ban → Text detail mode **off**, Enlarge small frames **off**
  - Settings → Models → overrides on Automatic

## Troubleshooting

| Symptom | What to check |
|---|---|
| A build step fails | The run page shows the compiler error or failing test as an annotation |
| Glasses stay on "Waiting for glasses" | Meta AI app open with developer mode on; glasses unfolded and charged; switch the camera to iPhone and back |
| Ray-Ban view appears but the transport note says it switched to raw | HEVC decoding failed on this phone; raw keeps working in the foreground. Report the note from Diagnostics |
| Voice says it is reconnecting | Automatic after a network or audio drop (up to 3 times in 2 minutes). Diagnostics → Realtime shows the reason |
| The voice is not the one selected | Settings → Voice shows Selected vs Active and ChatGPT's reason; press Apply now during a conversation |
| The wake phrase stops in the background | iOS stopped background listening; the status says "paused". Open the app to resume |
| Reminders/calendar say permission is needed | Open the app once and allow access when iOS asks (iOS cannot ask while the phone is locked) |
| Web answers never show sources | Diagnostics → Web search → last status; the fallback reports "direct search" |
