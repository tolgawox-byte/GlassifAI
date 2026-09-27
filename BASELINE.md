# Baseline — last device-verified working build

Recorded 2026-09-27 before any AutoLoom Media Glasses work started.

## Repository state

| Item | Value |
| --- | --- |
| Fork | https://github.com/tolgawox-byte/GlassifAI |
| Upstream | https://github.com/iannellomarco/GlassifAI (`upstream/main` = `591b280`) |
| Local clone | `C:\Users\tolga\Projects\GlassifAI` (fresh clone, working tree clean) |
| Baseline branch | `main` |
| Baseline commit | `74d9be51eb6699f0c5c1d201f0bac9d31e277b92` ("Update lib.rs", 2026-09-27 01:09 -0400) |
| Backup tag | `baseline-74d9be5-working` (annotated, points at the commit above) |
| Development branch | `autoloom-glasses-next` (branched from the baseline commit) |
| Last green CI run | https://github.com/tolgawox-byte/GlassifAI/actions/runs/36296398412 (`Build GlassifAI IPA`, success) |
| CI artifact | `GlassifAI-unsigned-IPA` (31.5 MB, expires 2026-12-26) |

## What the fork changed versus upstream

Only three files differ from `upstream/main`:

1. `.github/workflows/main.yml` — new manual (`workflow_dispatch`) workflow on the `xcode-27` runner: installs Rust, runs `scripts/build-native.sh` (≈17 min, three Rust targets), builds the unsigned Debug app with `xcodebuild` (≈40 s), zips `Payload/GlassifAI.app` into `GlassifAI-unsigned.ipa` and uploads it.
2. `native/GlassifAICodexBridge/src/lib.rs` — realtime model `gpt-live-1-boulder-alpha` → `gpt-live-1-codex`.
3. `ios/GlassifAI/Runtime/GlassifAIExperienceView.swift` — the failed state shows the real error message instead of the generic "Error".

## Verified on the physical device (reported by the owner)

- The IPA installs on the iPhone (sideloaded, unsigned build re-signed on install).
- ChatGPT device-code login works.
- Ray-Ban Meta camera connection works; iPhone camera mode works.
- Bluetooth, microphone and camera permissions work.
- Voice connection works; spoken answers about the Ray-Ban camera view work.
- The realtime protocol error is resolved by the `gpt-live-1-codex` model name.

Known problems at baseline:

- Ray-Ban preview is blurry, laggy and low-FPS compared with Meta's own experience.
- Every realtime delegation is routed to `inspectCurrentView()`, so non-visual requests (web, reasoning) are forced through the camera path.
- No web search, no source cards, no task tracking/cancellation, no diagnostics screen.

## Fragile parts that must not change without a device test

- ChatGPT device-code OAuth (`ChatGPTAuthSession.swift`, client ID, token refresh, Keychain).
- Realtime call creation in `lib.rs` (headers, `FramelessBidi`, `gpt-live-1-codex`, sideband).
- WebRTC setup and data channel in `GlassifAIRealtimeSession.start()`.
- Audio session category/options and Bluetooth HFP routing.
- Meta DAT registration, `Info.plist` `MWDAT` block, URL scheme `glassifai://`, bundle ID `com.marcoiannello.GlassifAI`.

## Rollback

```bash
# Rebuild the exact baseline IPA
git checkout baseline-74d9be5-working
# or reset a branch pointer without losing history
git switch main   # main is untouched by this work
```

The baseline IPA can be downloaded again from the CI run above until 2026-12-26, or rebuilt by running the workflow on `main`.
