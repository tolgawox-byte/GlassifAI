# Building and installing from Windows

There is no Xcode on Windows. GitHub Actions builds everything: the Rust bridge, the Swift app, and the unsigned IPAs. You then sideload the IPA with the same Windows tool you used for the baseline build.

## 1. Get the IPA

1. Push to the `autoloom-glasses-next` branch. The workflow starts automatically. To run it by hand: GitHub → **Actions** → *Build AutoLoom Media Glasses IPA* → **Run workflow**.
2. Wait for the green check. The first run takes about 25 minutes; runs that reuse the Rust cache take about 8–12 minutes.
3. Open the run and download the **AutoLoomMediaGlasses-unsigned-IPAs** artifact (a zip file).
4. Unzip it. It contains:
   - `AutoLoomMediaGlasses-Release-unsigned.ipa` — **recommended**. It's optimized, so the camera pipeline and UI run faster.
   - `AutoLoomMediaGlasses-Debug-unsigned.ipa` — the same configuration as the baseline build. Use it if the Release build misbehaves.

## 2. Install (sideload)

Use the same tool and Apple ID you used before (for example Sideloadly or AltServer for Windows).

- **Keep the bundle ID `com.marcoiannello.GlassifAI`.** Turn off any "change bundle ID" option. Changing the ID breaks Meta glasses registration and makes the app a separate install without your login.
- Signing with the same Apple ID/team updates the app in place and keeps the ChatGPT login (Keychain) and the glasses registration.
- After installing, if iOS asks: go to **Settings → General → VPN & Device Management**, trust the developer profile, and keep **Developer Mode** on.
- Free Apple IDs expire sideloaded apps after 7 days. Re-sign with the same tool to renew.

The home-screen name is now **AutoLoom** with the new icon. Inside the app the name is **AutoLoom Media Glasses**.

## 3. First launch checklist

1. The app opens straight to the main screen if you were already signed in. Otherwise use **Continue with ChatGPT** and enter the device code.
2. Select **Ray-Ban** at the top. The glasses view should appear within a few seconds.
3. Settings → Diagnostics shows the version, **commit** (it must match the Actions run), native bridge `autoloom-bridge-2`, realtime start mode, and camera metrics.

## Rollback

- **Previous app:** download the baseline IPA from Actions run [36296398412](https://github.com/tolgawox-byte/GlassifAI/actions/runs/36296398412) (available until 2026-12-26) and install it the same way.
- **Source:** the baseline is tagged `baseline-74d9be5-working`, and `main` is untouched. Running the workflow on `main` rebuilds the exact baseline.
- Settings in the new build that return to the original behavior without reinstalling:
  - Ray-Ban → Preview → **Legacy (original)**
  - Ray-Ban → Stream profile → **Balanced (original)**
  - Voice → **Juniper**

## Troubleshooting

| Symptom | What to check |
|---|---|
| Actions step "Build native Codex framework" fails | Look at the log. A `Cargo.lock` change invalidates the cache, so the next run is slow but should succeed |
| Actions step "Build unsigned iPhone app" fails | Swift compile error. Open the log, search for `error:`, then fix and push |
| Glasses stay on "Waiting for glasses" | The Meta AI app is open and developer mode is on in Meta AI; the glasses are unfolded and charged; switch the camera to iPhone and back |
| Voice says the task channel disconnected | Diagnostics → Sideband shows the reason. Tap the call button to reconnect |
| Web answers never show sources | Diagnostics → Web search → last status. The fallback reports "direct search" |
