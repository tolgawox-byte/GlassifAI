# Baseline — last device-verified working build

## Baseline for the voice-first pass (recorded 2026-09-28, brief "ULTIMATE VOICE-FIRST PERSONAL ASSISTANT + PREMIUM UI")

| Item | Value |
| --- | --- |
| Branch | `autoloom-glasses-jarvis-v1` (work continues here; `main`, `autoloom-glasses-next`, `autoloom-glasses-vNext` and `autoloom-glasses-dat1` untouched) |
| Starting HEAD | `e79fd8547aac6046cbc6c28800b55832a709a405` (`e79fd85`, docs only on top of `d8513c9`) |
| Build of that HEAD | CI run [36430433665](https://github.com/tolgawox-byte/GlassifAI/actions/runs/36430433665), commit `d8513c9`: iOS 157/157, Rust 8/8, Debug + Release IPAs (Jarvis v1.2: Ray-Ban connection coordinator and animated UI) |
| Rollback tag | `rollback-e79fd85-before-voice-first` (annotated, on `e79fd85`); also `baseline-d8513c9-jarvis-v1.2` |
| Remote | `origin` https://github.com/tolgawox-byte/GlassifAI.git |

The brief starts from one failure: "AutoLoom, not al: yarın kamerayı getireceğim." must reliably become a saved note.

Rollback: install the IPA from run 36430433665, or rebuild with `git checkout rollback-e79fd85-before-voice-first`.

---

## Baseline for Jarvis v1.1 (recorded 2026-09-28, brief "ULTIMATE JARVIS / MEMORY / RAY-BAN VISION / VOICE ACTIONS")

| Item | Value |
| --- | --- |
| Branch | `autoloom-glasses-jarvis-v1` (work continues on the same branch; `main`, `autoloom-glasses-next` and `autoloom-glasses-vNext` untouched) |
| Starting HEAD | `4157c69` (docs only on top of `26f3685`) |
| Build of that HEAD | CI run [36375889033](https://github.com/tolgawox-byte/GlassifAI/actions/runs/36375889033), commit `26f3685`: iOS 126/126, Rust 8/8, Debug + Release IPAs |
| Rollback tag | `baseline-26f3685-jarvis-v1` (annotated, on `26f3685`) |
| Older rollbacks | `baseline-3cb0437-vnext` (vNext), `baseline-44f089d-vision-working` (last build confirmed on the phone, DAT 0.4.0) |

What the owner reported from the phone, and asked for, before this work:
- Spoken "not al", "bunu hatırla", "yarın hatırlat", "görev oluştur" sometimes got only a conversational answer and nothing was saved.
- With the iPhone screen locked, Ray-Ban vision stopped ("cannot see").
- The main screen still showed camera numbers (requested/actual, FPS, frame count, codec, frame age, processing).
- After "Hey AutoLoom" there was no audible sign of when the connection was really ready.
- The owner wants the assistant to remember them across sessions (name, facts, earlier AutoLoom conversations).

Rollback: install the IPA from run 36375889033, or rebuild with `git checkout baseline-26f3685-jarvis-v1`.

---


## Baseline for `autoloom-glasses-jarvis-v1` (recorded 2026-09-28)

| Item | Value |
| --- | --- |
| Previous branch | `autoloom-glasses-vNext`, HEAD `38c251d` (docs only on top of `3cb0437`) |
| Build of that branch | CI run [36362397832](https://github.com/tolgawox-byte/GlassifAI/actions/runs/36362397832), commit `3cb0437`: iOS 99/99, Rust 5/5, Debug + Release IPAs |
| Rollback tag | `baseline-3cb0437-vnext` (annotated, on `3cb0437`) |
| Older rollback | `baseline-44f089d-vision-working`: the last build confirmed on the phone before vNext (DAT 0.4.0) |
| New development branch | `autoloom-glasses-jarvis-v1` (from `38c251d`). `main`, `autoloom-glasses-next` and `autoloom-glasses-vNext` are left untouched |

What the owner reports from using the current builds (brief of 2026-09-28):
- ChatGPT device-code sign-in, realtime voice, Ray-Ban audio routing, iPhone and Ray-Ban camera, Ray-Ban vision, web and reasoning routing, the model catalogue, diagnostics and CI builds all work.
- **Bug:** choosing another voice in Settings often still gives the same voice.
- **Weak spots:**
  - the assistant can feel robotic
  - it often says "move closer"
  - the main screen looks like a developer console

---

## Earlier baseline for `autoloom-glasses-vNext` (recorded 2026-09-27)

| Item | Value |
| --- | --- |
| Working build on the iPhone | CI run [36303697299](https://github.com/tolgawox-byte/GlassifAI/actions/runs/36303697299), artifact `AutoLoomMediaGlasses-unsigned-IPAs` (Debug + Release, expires 2026-12-26) |
| Commit of that build | `44f089db656d` ("docs: voice invocation research, Ray-Ban vision root cause and quality path") |
| Rollback tag | `baseline-44f089d-vision-working` (annotated) |
| Branch head when vNext started | `f24256bb9ae95295907788c57021d9affd82ef37` on `autoloom-glasses-next`. It differs from `44f089d` only in `TEST_REPORT.md`, so its app code is identical to the installed build |
| New development branch | `autoloom-glasses-vNext` (from `f24256b`). `main` and `autoloom-glasses-next` are left untouched |

Verified on the physical device by the owner, per the vNext brief:
- The app installs and launches; ChatGPT device-code sign-in works.
- Natural realtime voice works (`gpt-live-1-codex`), and Ray-Ban microphone and speaker routing work.
- The iPhone camera works. Ray-Ban preview and Ray-Ban vision work (vision repaired in `a4d0d9a`).
- Debug and Release builds and CI tests pass.

Rollback: install the IPA from run 36303697299, or rebuild it with `git checkout baseline-44f089d-vision-working`, or run the workflow on `autoloom-glasses-next`.

---

## Original baseline (upstream fork state)

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
