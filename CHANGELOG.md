# Changelog

All notable changes are documented here. The project follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and [Semantic Versioning](https://semver.org/).

## [AutoLoom 1.0-next] — branch `autoloom-glasses-next`

AutoLoom Media Glasses, built on GlassifAI. Baseline: `74d9be5` (tag `baseline-74d9be5-working`).

### Added

- **Task routing.** The voice model now answers ordinary conversation itself. It delegates only when needed, with a structured `TASK | QUERY` line. The client verifies each route (vision, web, vision+web, reasoning, memory, cancel, action). When no valid envelope arrives, the executor model picks its own tools (`web_search`, `look_at_camera`).
- **Live web search.** Runs on the ChatGPT account through the hosted `web_search` tool, falling back to the backend search endpoint. Source cards show title, host, and fetch time; links are checked for SSRF safety before they open.
- **Task tracking.** Every task carries session, turn, and task IDs, phases, and T0–T5 latency timings. Cancelled, superseded, stale, and duplicate results are never spoken. You can cancel by voice ("görevi iptal et") or with the on-screen button.
- **Conversation context.** Follow-ups work across delegations, and a summary is replayed after a reconnect. Opt-in on-device memory can be edited and deleted.
- **Camera Off mode.** Chat, web search, and reasoning keep working without a camera. The camera switch (Ray-Ban / iPhone / Off) is on the main screen, and switching no longer ends the call unless the audio route has to change.
- **Low-latency Ray-Ban preview.** One buffer copy on the SDK thread feeds `AVSampleBufferDisplayLayer` through a single pending slot. There is no main-thread work per frame and no backlog. A stale-frame badge appears, and a legacy preview switch is available for A/B comparison.
- **Frame store and metrics.** Only the latest frame is kept. Vision frames are encoded on demand from the source buffer and must be no more than 1 s old. Metrics cover resolution, pixel format, FPS, dropped frames, processing and capture latency (median/p95), and frame age, with an optional overlay.
- **Glasses stream profiles.** Balanced (original), Smooth, and Sharper frames.
- **Audio.** The audio route setting (Automatic / Glasses / iPhone) is separate from the camera. The glasses' HFP port is chosen without grabbing other Bluetooth headsets. Interruption and media-reset handling added, plus a local stop-speaking control.
- **Native bridge.** The sideband now reconnects with backoff, and a generation guard blocks late events from an earlier call. `realtime_start_v2` takes options and falls back to the baseline session if they are rejected. Context append and bridge version exports added.
- **Settings.** New sections: ChatGPT account and model, camera, Ray-Ban, audio route, voice, language and answer length, web search and location, memory, privacy wipe, diagnostics (sanitized report), about, and licenses.
- **Safety.** Log sanitizer, untrusted-content wrapping for web and image text, and honest refusal of actions the app can't do.
- **Branding.** AutoLoom Media Glasses branding, a derived app icon and brand mark, and the AutoLoom palette.
- **CI and tests.**
  - The Rust build is cached.
  - Debug and Release IPAs are built, and the commit SHA is stamped into Diagnostics.
  - Simulator unit tests and Rust unit tests run in CI.
- **Documentation.** `BASELINE.md`, `CAPABILITIES.md`, `TEST_REPORT.md`, and in `docs/`: `RAYBAN_CAMERA_CAPABILITIES.md`, `PRIVACY_AND_PERMISSIONS.md`, and `WINDOWS_INSTALL.md`. `docs/ARCHITECTURE.md` was updated.

### Changed

- Executor requests no longer ask for a reasoning summary, which lowers latency.
- iPhone camera frames no longer hop to the main thread and are no longer JPEG-encoded every second.
- The failed-state label shows a short "Error". The full message is available by long press and in Diagnostics.

### Unchanged on purpose

- Bundle ID, URL scheme, Keychain service, Meta DAT 0.4.0 and its configuration defaults, OAuth flow, realtime headers and model (`gpt-live-1-codex`), and the original bridge entry point.

## [Unreleased — upstream GlassifAI]

### Added

- New GlassifAI visual identity, app icon, social artwork, and immersive camera-first SwiftUI interface.
- Branded onboarding, privacy consent, Meta glasses connection, conversation controls, and settings.
- `com.marcoiannello.GlassifAI` application identifier.
- Reproducible native bridge build script and curated standalone repository.
- Detailed architecture, authentication, build, security-model, and Codex-to-iOS port documentation.
- Hands-free active-call controls on Meta glasses: Bluetooth HFP audio, temple-tap microphone mute/unmute, and long-press/doff/fold call termination.
- Deterministic tests for DAT session-state gesture interpretation.

### Changed

- Renamed the Xcode project, target, scheme, app entry point, and test target to GlassifAI.
- Reduced the source tree to the iOS app, embedded Codex bridge, pinned upstream source, and required notices.
- Replaced repository screenshots with metadata-minimized captures containing no account or camera data.
- Removed the developer-team identifier from the Xcode project; signing is now selected locally.

## [0.1.0] - 2026-08-22

### Added

- Single Login with ChatGPT device-code flow with Keychain restoration and refresh.
- Native ChatGPT live voice through an embedded Codex Rust XCFramework.
- Authenticated realtime sideband for camera-based visual questions.
- iPhone and Meta glasses capture sources.
- English and Italian visual-question verification on a physical iPhone.
- WebPKI certificate roots for the embedded iOS realtime sideband.

[Unreleased]: https://github.com/iannellomarco/GlassifAI/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/iannellomarco/GlassifAI/releases/tag/v0.1.0
