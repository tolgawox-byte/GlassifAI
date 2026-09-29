# Changelog

All notable changes are documented here. The project follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and [Semantic Versioning](https://semver.org/).

## [AutoLoom Jarvis v1.4 — multi-agent, Ray-Ban media, reliable notes] — branch `autoloom-glasses-jarvis-v1`

Rollback tag: `rollback-f11377f-before-multi-agent` (before the multi-agent layer). Not device-verified.

### Added
- **Multi-agent orchestrator**: logical agents (chat, vision, live vision, research, reasoning, coding, actions, memory, dealer, translation, documents, planning, external), `AgentPlan`, `AgentRouter` (LOCAL / FAST / SPECIALIST / TEAM), cost preferences (Balanced, Best quality, Lower cost, Local first), per-role pins, automatic routing, offline handling.
- **Providers**: ChatGPT (existing account), Local, Claude, Gemini, Perplexity, OpenRouter (official APIs, keys in the Keychain), OpenClaw (existing gateway); model discovery with a capability matrix; Test connection; circuit breaker, rate-limit pause, bounded fallback, timeouts, cancellation; routing diagnostics without content.
- **Team mode and result fusion**: see-then-research, parallel research questions, one answer with merged sources and stated disagreements.
- **One voice**: response normalizer (no provider names, no `<think>` traces; speech without markdown, tables or URLs), entity context across agents.
- **Jarvis Style**: intensity (Subtle / Balanced / Full), form of address (None / My name / Sir – Efendim / Custom), persona confirmations ("Not aldım efendim."), greeting ("Bağlantı hazır. Sizi dinliyorum efendim."); Settings → Personality and Settings → Intelligence.
- **Ray-Ban photos and videos**: "fotoğraf çek", "video kaydını başlat", "kaydı durdur", "kayıt yapıyor musun?", "galeriye kaydet"; add-only Photos saving, Captures (Explore tab), recording chip, shutter and record buttons, dealer labels, photo + note.
- **Locked-screen vision**: software VideoToolbox decoder by default, bounded fresh-frame recovery, still-photo fallback in the background, "Continue vision with the screen locked".
- **Dealer Mode**: vehicle sessions ("yeni araç", "sonraki araç", "bu araç tamam"), VIN reading with the ISO 3779 check digit (never completes a character; look-alikes offered as options), odometer by voice or camera, damage with Turkish/English body zones, photo / delivery / test-drive checklists (a labelled Ray-Ban photo ticks its item), market research and listing drafts through the agent router, dealer briefing; notes, tasks and captures link to the active vehicle; Explore → Dealer. Rollback tag `rollback-c2d7cfe-before-dealer`.
- **Daily life**: timers with local notifications and a countdown chip, shopping list, parking spot ("park yerimi kaydet", "arabam nerede?", "beni arabama götür"), QR codes and barcodes read on the phone and never opened ("QR kodu oku"), evening and weekly review, undo of the last local action, assistant modes (Dealer automatically while a vehicle is active).
- **Shortcuts**: new task, remember, start dealer session, today's briefing, shopping list (App Intents).
- Tests: `AutoLoomMultiAgentTests`, `AutoLoomRayBanMediaTests`, `AutoLoomNoteReliabilityTests`, `AutoLoomDealerTests`, `AutoLoomDailyLifeTests`.

### Fixed
- Spoken notes: note verbs are found anywhere in the sentence (a misheard name or "benim için" before "not al" hid the command); the user's verb beats time words; delegations that did something else never stand in for the note.
- A tool's level in Settings is its main action's (Notes saves directly; deleting a note still waits for a yes).
- Background vision stopped when the phone locked: iOS tears down hardware decoder sessions; the app rebuilt hardware sessions and never switched to software.
- Routing: English keywords matched the start of Turkish words ("bug" in "bugün", "haber" in "haber ver", "market" the grocery store).
- A vehicle, shopping or parking file this version cannot read is renamed, never overwritten by the next save.

### Privacy
- Provider keys only in the Keychain (this device only), never logged or shown; each provider gets the minimum context; research providers never get images; nothing paid is enabled without a cost notice and the user's confirmation.
- Ray-Ban captures: add-only Photos access; nothing uploaded; the Captures list keeps labels and small thumbnails.
- Dealer Mode stores no customer, plate or driver's licence data; the screen shows only the VIN's last six characters. The parking spot is one location fix taken when the user asks, never tracking.

## [AutoLoom Jarvis v1.3 — voice-first actions] — branch `autoloom-glasses-jarvis-v1`

Rollback tag: `rollback-e79fd85-before-voice-first`. Not device-verified; physical TESTs 1–8 are in `TEST_REPORT.md`.

### Fixed
- **"AutoLoom, not al: yarın kamerayı getireceğim." could save nothing.** Traced from the realtime events to `MemoryStore.addNote` (`docs/VOICE_ARCHITECTURE.md`). The speech recogniser's spellings of the name ("Oto lum", "Otoloom", "Autolum", "Carvis") were not treated as the address, so the command was not recognised while the voice model waited for the app. Near spellings of names of five letters or more now count, also for "kapat"/"dur".
- A delegation that arrived before the final transcript made the app **skip** the command even when that delegation saved nothing. It is now taken over: stopped and answered with the app's result, or left alone when it already did the action.
- Delegations without a `TASK:` line went to a step that cannot save, whose model could say "not aldım". Explicit commands in them now run through the app, and steps that cannot act are told never to claim a save, call or send.
- A turn whose final transcript came late or only in older event shapes was never read; its stable partial words now finish it.
- The same note or task saved twice within a minute is stored once.
- "Yarına", "yarınki" and "bugünkü" are read as days.

### Added
- **Calls**: "Ahmet'i ara", "annemi ara", "call Mom" → Contacts (several matches are asked about: "İki Ahmet buldum: Ahmet Yılmaz mı, Ahmet Kaya mı?") → the iOS call prompt. The app never says a call was made.
- **Messages**: "Ahmet'e 10 dakika gecikeceğim diye mesaj yaz", "ona gecikeceğimi de yaz" → Messages' compose sheet with the text ("Mesajı hazırladım, göndermen için ekranı açtım."); "sent" only when Messages reports it. Missing parts are asked ("Kime yazayım?", "Ahmet'e ne yazayım?").
- **Contacts**: "Ahmet'in numarası ne?".
- **Maps**: "beni eve götür" / "işe götür" (addresses saved with "hatırla: ev adresim …"), "Kadıköy'e yol tarifi aç", "havalimanına nasıl giderim", "en yakın benzinliğe götür" (Maps search), "bu adrese yol tarifi aç" (from the last answer), "buraya yol tarifi aç" (the camera reads the address; a card shows it; the user taps).
- **Clipboard and share**: "bunu kopyala" ("Kopyaladım" after the clipboard changed), "bunu paylaş" (share sheet; "shared" only when completed).
- **Day plan**: "Bugün ne yapmam gerekiyor?", "programım ne?" → AutoLoom tasks, Apple Reminders and the calendar together, counted ("Bugün 3 işin var.").
- **Follow-up context**: "bunu" is the last useful answer, "bununla ilgili" what was just saved, "ona" the last contact.
- A bare "hatırlatıcı oluştur" asks "Neyi hatırlatayım?".
- Daily briefing: the weather from a web search when web search is on and a city is set.
- **UI**: action feedback cards with haptics, Recent activity, rotating quick suggestions, the WAKE orb state, the status pill for iPhone Camera / Camera Off, greeting options "Buradayım.", "Dinliyorum.", "Nasıl yardımcı olabilirim?", a Projects memory group, Tomorrow / Reschedule for AutoLoom tasks.
- Tests: `AutoLoomVoiceFirstTests`.

### Privacy
- Calls, messages and contact lookups keep no names, numbers or message text in the action trace or the conversation facts. Recent activity shows labels and times only.

## [AutoLoom Jarvis v1.2 — Ray-Ban connection and animated UI] — branch `autoloom-glasses-jarvis-v1`

Rollback tag: `rollback-dd1b756-before-connection-fix`. Not device-verified; see `docs/RAYBAN_CONNECTION.md` (tests A–L) and `TEST_REPORT.md`.

### Fixed
- **The Ray-Ban camera gave up after about a minute.** It was started by 20 tries 3 s apart, and every try failed while the glasses were asleep, folded or away. The camera permission check fails without a connected device (`PermissionError.noDevice` / `noDeviceWithConnection`). Nothing restarted it when the glasses came back. The camera now starts whenever the glasses are registered and linked, and again each time they return, with a bounded backoff.
- **Meta AI's registration callback could be lost** on a cold launch, while sign-in was restoring and the glasses screen did not exist yet. It is now handled at the app root.
- **Connect registered again** even when already registered, and could spin forever after Meta AI was closed without approving. Registration now runs only when needed and once at a time, and stops with "Meta AI didn't confirm" and one Try Again.
- A camera or codec failure no longer looks like a connection failure.

### Added
- `WearableConnectionCoordinator`: the one source of truth for registration, devices, link, permission and camera, with states SDK_UNAVAILABLE … READY.
- Settings → Ray-Ban glasses (status, Try Again, Forget glasses with confirmation) and Settings → Developer → Ray-Ban connection (every sub-state, the runtime MWDAT configuration without values, transitions, attempts, sanitized report, developer actions).
- An explanation when Developer Mode's one-app registration was taken by another app.
- MWDAT `MetaAppID` / `ClientToken` default to `0`, Meta's Developer Mode value, through build settings.
- **Animated UI:**
  - Ray-Ban status pill and "✓ Ray-Ban Connected" confirmation with haptic.
  - Link animation driven by the real phase.
  - Camera crossfades, and a veil instead of a frozen frame.
  - The state word above the controls.
  - The orb redrawn in Canvas with microphone- and voice-reactive states, orbit, radar, check and confirmation.
  - Press feedback, symbol transitions, haptics; Reduce Motion respected.
- Tests: `AutoLoomConnectionTests`.

## [AutoLoom Jarvis v1.1.1] — branch `autoloom-glasses-jarvis-v1`

From the open-source review (brief §69, `docs/OPEN_SOURCE_RESEARCH.md`). Not device-verified.

### Fixed
- **Wake phrase restart loop.** Cancelling a recognition request also reports an end, and that report restarted the *new* request, so after the first 50 s recycle the listener could cancel and recreate requests without end. Only the current request's end restarts recognition now, and requests that end within a second back off 0.6–5 s (the glasses' Bluetooth microphone can end them at once).
- **"No analytics" is now true.** Meta's DAT SDK collects analytics (and, on DAT 1.0, SDK crash reports) unless `Info.plist` opts out; the app now opts out of both.

### Added
- **Changes after camera, web or agent content need a yes.** A reminder, event, note, notification or copy that the planner model proposes in a turn that brought camera, web or agent content waits for a spoken yes or a tap. The local parser's commands, which come from the user's own words, are unchanged.
- `docs/OPEN_SOURCE_RESEARCH.md`.

## [AutoLoom Jarvis v1.1] — branch `autoloom-glasses-jarvis-v1`

Baseline: `26f3685` (tag `baseline-26f3685-jarvis-v1`, CI run 36375889033). Nothing below is device-verified yet; see `TEST_REPORT.md`.

### Fixed
- **Spoken commands really run.** "Not al", "bunu hatırla", "yarın hatırlat" and "görev oluştur" depended on the voice model choosing a delegation and sometimes only got a conversational answer. A local voice action bridge now reads every final transcript (LEVEL 1 parser, LEVEL 2 structured classification only when details are missing) and executes notes, memory, the user's name, reminders, notifications, AutoLoom tasks and calendar requests itself — saved first, confirmed after. See `docs/VOICE_ARCHITECTURE.md`.
- **One answer per command.** The model's own reply to a command the app handles is muted and the app's result is spoken instead (through the model's delegation for the same turn when there is one); delegations arriving before the final transcript wait, so nothing runs twice.
- **Ray-Ban vision with the phone locked** (root causes in code; physical test required): the glasses stream is no longer paused in the background; the HEVC→raw fallback is never decided in the background; the decoder waits for keyframes, recreates lost sessions and falls back to software; `bluetooth-central` added. See `docs/BACKGROUND_STREAMING.md`.
- **No developer text on the Assistant screen.** Camera numbers live only in Settings → Developer → Camera diagnostics; the overlay switch is gone.
- **Greetings through the speakable channel** were sent as user messages and could be answered instead of said; app lines are now explicit "[App message …]" instructions.

### Added
- **Connection-ready acknowledgement:** WakeDetected → PreparingAudio → ConnectingRealtime → WaitingForDataChannel → RoutingAudio → Ready/Failed; chime and/or "Bağlandım, dinliyorum." once per new conversation, only when really ready; "Bağlantı kurulamadı." and "Ray-Ban bağlantısı koptu."; Connection Feedback setting; Voice diagnostics.
- **Persistent memory:** user profile (name), conversation summaries (on by default, never transcripts), memory types PROFILE/PERSON/PLACE/VEHICLE/CONVERSATION_SUMMARY, ranking by relevance + exact names + pinned + recency, bounded injection (profile + memories + last summary), Smart Memory (off), Memory tab sections About me / Conversations / Visual memories, Clear all AutoLoom memory.
- **AutoLoom Tasks** (local) next to Apple Reminders in the Tasks tab, with Today/Upcoming/Completed, editor and optional alert; voice: "görev oluştur", "görevlerim neler", "… görevini tamamla".
- **Calendar:** "yarın ne var?"; explicit reminders and events are SAFE (an unclear time is still asked); 9–11 o'clock read as morning, 1–5 as afternoon; "cuma 3'e".
- **Permission retry**, **action trace**, **"Saving"** status word, **routines** ("İşe başlıyorum", "günün özeti"), **daily briefing** (off by default), **translation** of the view.
- **Jarvis Style:** closest ChatGPT voice (Cove) plus persona instructions; a style, never an actor imitation; Apple voice only as the offline fallback.
- **Settings:** Voice section (selected/active/style, Jarvis Style, connection feedback, language, tone), Intelligence, conversation memory and Smart Memory, Tools shows AutoLoom Tasks and Shortcuts, Developer: Action & task trace, Voice diagnostics, Camera diagnostics.
- **Glasses lifecycle states** with transition log and per-request proof of origin.
- **Docs:** BACKGROUND_STREAMING (new), and updates to ARCHITECTURE, CAPABILITIES, MEMORY_ARCHITECTURE, VOICE_ARCHITECTURE, VOICE_SELECTION, WAKE_INVOCATION, NATIVE_TOOLS, RAYBAN_CAMERA_CAPABILITIES, DAT_1_MIGRATION, UI_REDESIGN, PRIVACY_AND_PERMISSIONS, TEST_REPORT.

### Not in this build
- DAT 1.0 (`Camera.photo`, "Hey Meta, start AutoLoom", `donState`): see `docs/DAT_1_MIGRATION.md`.

## [AutoLoom Jarvis v1] — branch `autoloom-glasses-jarvis-v1`

Baseline: `3cb0437` (tag `baseline-3cb0437-vnext`, CI run 36362397832).

### Fixed
- **The selected voice now really changes.** Settings offered voices the frameless realtime protocol rejects, and the silent fallback always spoke with Juniper. Only the nine accepted voices are offered; earlier choices are migrated with a note; a start ladder keeps the selected voice when anything else fails; Settings shows Selected vs Active voice and the reason; Apply now and Preview. See `docs/VOICE_SELECTION.md`.
- **Fewer "move closer" answers.** An unclear answer is retried once in high detail (best frame, OCR, zoomed crop) first; any advice is one specific tip and is not repeated.

### Added
- **Consumer interface:** Assistant, Memory, Tasks and Settings tabs; a state word and camera indicator; an animated orb when the camera is off; a voice button that is not a call UI; seven-page onboarding; privacy center; friendly errors; Turkish/English strings. FPS and frame data moved to Settings → Developer.
- **Conversation:** natural Turkish and adaptive answer length; local instant mute for "Dur/Sus/Bekle/Hayır"; end commands; quiet-conversation timeout; short "what can you do".
- **Assistant identity and wake:** wake phrase setting separate from the name; Hands-Free Ready (background, time-limited, visible); arming while the glasses report a connected link; greeting styles and activation feedback.
- **AutoLoom Memory:** SwiftData store with kinds and categories, explicit saving only, Turkish-aware search plus on-device English embeddings, pin/edit/forget, visual memories (opt-in), notes with tags and links; migration of the earlier JSON files.
- **Tools:** deterministic Turkish/English time parsing (model timestamps ignored, ambiguous times asked); SAFE / CONFIRM / STRONG CONFIRM; local notifications; contacts lookup for calls and messages; tool registry with switches; Tasks tab on Apple Reminders; App Intent "Create AutoLoom Note".
- **Observability:** Selected/Active voice and model, start attempts, fallback reason; copyable sanitized task trace.
- **Battery:** the screen may sleep when idle; an idle glasses stream pauses in the background.
- **Docs:** VOICE_ARCHITECTURE, VOICE_SELECTION, WAKE_INVOCATION, MEMORY_ARCHITECTURE, NATIVE_TOOLS, DAT_1_MIGRATION, UI_REDESIGN.

### Not in this build
- DAT 1.0 (`Camera.photo`, "Hey Meta, start AutoLoom", worn state): planned on a separate branch; see `docs/DAT_1_MIGRATION.md`.

## [AutoLoom vNext] — branch `autoloom-glasses-vNext`

Baseline: `44f089d` (tag `baseline-44f089d-vision-working`), the build on the phone.

### Camera and vision
- **Meta DAT 0.4.0 → 0.5.0.** 0.4.0 could not reliably deliver 720×1280; 0.5.0 fixes that and adds the HEVC codec. Official requirement: Meta AI app V254 and glasses firmware V22.
- **HEVC transport by default.** Frames are hardware-decoded by the app to native 4:2:0 and keep streaming with the phone locked. A watchdog switches to the SDK's raw transport once if nothing decodes.
- **Profiles follow Meta's guidance** (fewer frames per second means less compression per frame):
  - new default 720p/15
  - new max-detail 720p/7
  - original 720p/24 and 504p/30 kept
- **Requested vs actual** resolution, fps, and codec in Diagnostics and the overlay, plus the DAT version, the glasses, and the transport fallback reason.
- **Best-frame selection** from the newest 8 frames: sharpness, exposure, freshness, and the same scene only. A camera-switch **epoch** rejects frames from before a switch.
- **FAST / BALANCED / HIGH_DETAIL** vision profiles. Reading words (read, label, VIN, badge, dashboard, oku, yazı, etiket, plaka…) always get HIGH_DETAIL.
- **HIGH_DETAIL** enlarges small frames within the model's 2048 px / 2500-patch budget. It adds on-device OCR (Apple Vision, untrusted hint) and a zoomed crop of the text region.
- Images are sent with `detail: "high"`, as Codex does.
- Automatic capture uses the sharpest video frame. Meta documents in-stream photos as frames of the video stream; photos are the fallback when video stalls.
- **Live Vision:** adaptive, time-limited scene notes sent as silent context during a conversation ("start live vision", eye button, Siri).

### Models
- **Capability discovery** from the full `/models` metadata: modalities, reasoning levels, verbosity, web search type, responses-lite, context.
- **Routing per job** (general, vision, reasoning, web) following the service's order. Requests send only parameters the model supports. A rejected model is skipped for the session and the task retries once. Model health is recorded.
- **GPT-6 Astra** is used only if this connection lists it; Settings → AI models says whether it does.

### Voice and hands-free
- **Automatic reconnect** after mid-call network or audio failures (3 in 2 minutes), resuming with context.
- Connect time and response latency metrics.
- More interruption words (bekle, hayır, başka bir şey soracağım).
- **Mode B:** opt-in listening for the assistant's name while the app is open (on-device recognition only).
- **Siri:** Ask AutoLoom and Start Live Vision shortcuts.

### Actions and tasks
- **iPhone actions:** reminders, calendar, AutoLoom notes, Maps directions, links, copy, share, calls, messages.
  - Saves need a spoken yes or a tap; anything leaving the app needs a tap.
  - Email, payments, deleting data, posting, and code changes are refused locally.
- **Reports:** web research written up and saved as a note with sources.
- **AutoLoom Tasks & Notes** screen.
- **Optional OpenClaw agent gateway:** off by default, Keychain token, private-network rule for plain http, confirmation before sending.

### Brand, CI, docs
- App icon (with dark and tinted variants), brand mark, and launch screen built from **LOGO 2** (kept unchanged in `assets/brand`) by `scripts/make-brand-assets.py`.
- CI publishes Swift compile errors as annotations.
- New docs: `MODEL_CAPABILITIES.md` and `TOOLS_AND_ACTIONS.md`. Camera, architecture, capabilities, privacy, voice invocation, Windows install, and test report updated.

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

### Added — Ray-Ban vision and assistant name

- **Ray-Ban vision.**
  - Compressed glasses frames are now hardware-decoded in the foreground and in the background. Every frame that can be displayed reaches vision.
  - If the CPU copy fails, the original buffer is kept.
  - Diagnostics shows raw vs compressed, codec, decoded frames and failures, FrameStore sequence, photo statistics, and the last AI image source.
- **Still photos for vision.**
  - Fresh Ray-Ban stills are used for reading and detail requests, and as the fallback when video stalls.
  - One request is in flight at a time. Late and shutter-button photos are rejected.
- **Vision profiles.**
  - Standard: 1280 px, q0.80.
  - High detail: ≤2048 px and ≤2500 patches, q0.92. Photos that already fit are sent unchanged.
  - New `TASK: vision_read` route and a `look_at_camera(detail:)` parameter.
- **Honest explanations.** When the camera stalls, the assistant reports the stream state ("paused", "waiting", "not running") and never describes an older image.
- **Assistant name.** Settings → Assistant sets a custom name (for example "Jarvis"). It is validated, stored locally, and used as identity in the voice instructions. An experimental "only answer when called by name" option is included.
- **Siri.** "Hey Siri, start AutoLoom" works through an App Shortcut, and users can create their own Siri phrase with a shortcut. Alternative app names were added for Siri.
- **Single start path.** `VoiceStartCoordinator` handles the button, Siri, and the future "Hey Meta" invocation idempotently, so two sessions can never start.
- **Settings → Hands-Free.** Shows what really works: Meta invocation (not available in this build), custom wake word (not supported), Siri, and background limits.
- **CI.** Test classes are discovered automatically.
- **Documentation.** `docs/VOICE_INVOCATION.md` is new; the camera document is updated.

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
