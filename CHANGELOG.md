# Changelog

All notable changes are documented here. The project follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and [Semantic Versioning](https://semver.org/).

## [JARVIS Ultimate — plan 2.3: repeating reminders, events and tasks; undo a spoken completion] — branch `autoloom-glasses-jarvis-v1`

Plan item 2.3. CI results: `TEST_REPORT.md`. Not tried on an iPhone yet (device tests TK2, RM5).

### Added
- **Repeats said by voice:** "her gün", "hafta içi her gün", "her pazartesi", "cumaları", "her ayın 15'inde", "her yıl", "her sabah", "every day", "every Monday".
  - "Her gün 9'da ilacımı içmeyi hatırlat" saves "İlacımı iç" as a reminder that repeats every day at 9. The repeat is the Reminders app's own, and the title loses the repeat words.
  - Calendar events repeat the same way ("her pazartesi 10'da toplantı ekle"). "Hayır, cumartesi" right after moves the whole series.
  - **AutoLoom tasks repeat too.** Completing one adds the next, by voice, in the Tasks tab or from its alert:
    - the next one is never in the past, and is counted from the first date, so "the 31st" stays the 31st;
    - it gets its own alert when the completed one had one.
  - The task and new-reminder sheets have a **Repeat** picker. Repeating rows show a repeat mark.
- **Repeats are read only when the user said one.** "Haftalık toplantı" or "bu hafta içi" do not make a repeat.
  - A repeat the app cannot set ("her saat", "iki günde bir", "every other day") is said, and the item is saved once.
  - A notification cannot repeat and the assistant says so; "her gün … hatırlat" makes a repeating reminder.
- **"Geri al" after "… görevini tamamla"** reopens the task. For a repeating task it also takes back the task its completion added. Tapping the circle again in the Tasks tab does the same.

### Changed
- Task repeats are kept in the app's settings, beside the SwiftData store. The store already on the iPhone therefore needs no schema migration, which could not be tried on the device first. Deleting a task, or all data, removes its repeat.

## [JARVIS Ultimate — plan 2.2: Apple Reminders by voice, list choice] — branch `autoloom-glasses-jarvis-v1`

Plan item 2.2. CI results: `TEST_REPORT.md`. Nothing here has been tried on an iPhone yet (device tests RM1–RM4).

### Added
- **Complete an Apple reminder by voice:** "Süt alma hatırlatıcısını tamamla", "Ahmet'i arama anımsatıcısını tamamlandı olarak işaretle", "mark the milk reminder as done".
  - It runs at once. "Son yaptığını geri al" reopens it.
  - "Lastik görevini tamamla" still completes an AutoLoom task first. When no task matches, an open reminder with those words is completed.
- **Delete an Apple reminder by voice:** "Süt alma hatırlatıcısını sil", "delete the dentist reminder".
  - It waits for "evet" or a tap. The card says it cannot be undone.
- **Both changes are read back.** Each is reported only after a fresh fetch from Reminders no longer lists the reminder as open; otherwise the user hears that Reminders did not confirm it.
- **Which reminder is meant:**
  - found by its words. Turkish verb nouns match their reminder, so "süt alma" finds "Süt al" and "Ahmet'i arama" finds "Ahmet'i ara";
  - "bu hatırlatıcıyı …" means the one saved in the last ten minutes;
  - when several fit, or nothing was saved just now, the assistant asks "Hangisi: …?". The answer can be the order ("ikincisi"), the list ("Market'teki") or words of the title.
  - Nothing is guessed. Several reminders at once ("tüm hatırlatıcılarımı sil") are never completed or deleted.
- **List choice for new reminders:**
  - a list named in the words: "İş listeme yarın 10'da raporu göndermeyi hatırlat" saves "Raporu gönder" in İş. Only the names of the user's real lists count;
  - otherwise the list chosen in Settings → iPhone tools → Apple Reminders;
  - otherwise iOS's default list. A list that no longer exists falls back to the default, and the assistant says so;
  - the Tasks tab's new-reminder sheet has a list picker.
- The reminder read-out names each reminder's list when they come from more than one.
- The planner model can choose neither action. Only the user's own words reach them, through the app's own parser.

### Fixed
- **A step waiting for a yes is no longer reported as done.** In a sentence with several commands, a step such as "bu notu sil" that waits for confirmation was reported "done". It now reads "NOT done yet — waiting for the user's yes or tap".
- **Tasks tab rows whose reminder was deleted elsewhere** (in the Reminders app) now say "This reminder is no longer in Apple Reminders" when tapped, and the list reloads. Before, nothing happened.
- **"Tool turned off" messages** name the switch (for example "Reminders"), not the action.

## [JARVIS Ultimate — phase 1g: the last Rust crate notices] — branch `autoloom-glasses-jarvis-v1`

Plan item 1.16. CI results: `TEST_REPORT.md`.

### Licenses
- **The six MIT/BSD crates that publish no license file now have their notices in the app** (Settings → Licenses → Full license texts).
  - Each published crate records the git commit it was built from. The text is that repository's license file at that commit, byte for byte, after the downloaded crate matched the checksum in both lockfiles:
    - Inflector 0.11.4: BSD-2-Clause, "Copyright 2017 Josh Teeter";
    - schemafy_core and schemafy_lib 0.5.2: MIT, "Copyright (c) 2016 Markus Westerlind". This is the same text that schemafy 0.5.2 ships, so the app lists it once;
    - ts-rs and ts-rs-macros 11.1.0: MIT, "Copyright (c) 2020 Aleph Alpha GmbH".
  - **debugserver-types 0.5.0** declares MIT, but neither the crate nor its repository (at its commit or on the default branch) has a license file or a copyright notice. Its entry says so and gives the MIT terms; no copyright line was made up.
  - The texts and their sources are in `scripts/rust-license-supplements/` (`sources.json`).
  - `scripts/rust-license-texts.py` uses a supplement only when the crate itself has no license file, so CI's output now matches the app's file. In run 38349904362 they were identical, character for character.
  - The app's file now has 272 distinct texts instead of 269.

### Fixed
- **Memory settings no longer point at an error that does not exist.** The storage row said "Temporary (see error)" whenever the store was not on disk. That included screenshot mode's deliberate throwaway store, where there is no error (seen in run 38346329047's screenshots). It now says "Temporary (this session only)" unless an error was recorded. In that case the error is shown above it, as before.

## [CI — simulator boot failures reported and contained] — branch `autoloom-glasses-jarvis-v1`

Phase 1c's run (38330128872) was red although every test passed. In that run:
- parallel testing had cloned the simulator once per worker;
- on a runner that was slow throughout (a pure parsing test took 139 s), clone 2 missed its 60-second boot ("Failed to prepare device 'Clone 2 of iPhone 18 Pro' … Timed out trying to boot simulator after waiting 60.00s");
- xcodebuild recorded that as a "System Failures" case and exited 65;
- the later, independent Rust step never ran.

### Changed
- **Fewer simulators boot at once:** at most two parallel test workers (`-maximum-parallel-testing-workers 2`).
- **A simulator-only failure is reported as one, and the step stays red.** `scripts/xcresult-classify.py` checks that every failure is the simulator's and none is a test's. If so, it adds an error annotation "Simulator infrastructure: Not a test failure …" with the device message and how many test cases ran out of how many exist in the source. The step stays red; it is never turned green. Test classes that did not run because of it run again on one simulator without clones, reported under "Rerun:".
- **The Rust tests always run**, unless the run was cancelled.
- The result summary moved from the shell script into `scripts/xcresult-summary.py`, so the rerun is summarised the same way.
- **The missing screenshots were a false alarm, now fixed.** In run 38341978615 every app reported "not running after launch" was `running-active-Visible` in the simulator's own log, and the relaunch returned the same pid. The script's liveness check (`launchctl list` inside the simulator) missed running apps. It now checks the pid that `simctl launch` prints (`kill -0` on the Mac), with `launchctl` as fallback. Run 38346329047 captured all 28 screens.
- **Screenshot launches that end without a crash report now say why.** Every run has lost 3–8 screens this way, and phase 1e reached the script's limit of 8. The script now records what the simulator's process manager (runningboardd, SpringBoard, launchd) logged about the app: in the annotation and in `logs/<screen>.termination.txt`.

## [JARVIS Ultimate — phase 1f: MCP tool pinning, Rust licenses in the app, phase 1e test fix] — branch `autoloom-glasses-jarvis-v1`

Research item F04 and plan items 1.16 and 2.3. CI results: `TEST_REPORT.md`.

### Fixed
- **Phase 1e's red run:** the task-alert test hung for 180 s. It reached `UNUserNotificationCenter.notificationSettings()`, which never returns in the unit-test host. Now:
  - the alert check and the alert scheduling are replaceable, and the test replaces both;
  - the test checks both paths: alerts not allowed (no new alert, no prompt) and allowed (a new alert an hour later, carrying the task's id);
  - in the app, the check gives up after 3 s, because a lock-screen action has little background time.

### Licenses
- **The Rust crates' license texts ship in the app** (Settings → Licenses → Full license texts).
  - CI collected them from the 451 crates resolved for iOS: 269 distinct texts, including aws-lc-sys, ring, rustls and ICU4X.
  - Every crate's declared license matched the crates.io declaration of the same version. The two OpenAI git forks of tungstenite and tokio-tungstenite declare the same as upstream.
  - 42 crates publish no license file:
    - the Apache-2.0 ones, and those offering Apache-2.0 as one choice, are covered by the Apache text included;
    - six MIT- or BSD-only crates (Inflector, debugserver-types, schemafy_core, schemafy_lib, ts-rs, ts-rs-macros) are named as still missing their notices; no text was made up for them.
  - `option-ext` (MPL-2.0) is noted as unmodified, with its source location.

### Security
- **A skill's tool that changes after you reviewed it is blocked** (protection against a "rug pull"). The app pins what you reviewed for each tool: its name, title, description, input schema and read-only/destructive claims. If a later sync finds any of these changed, that tool is blocked and marked "Changed since you last reviewed it". It stays blocked until you choose a policy for it again, and the sync message names the tools. Tools that are new on the server start at "Ask every time", as before. A tool the server drops loses its policy, so it cannot come back later with another definition and keep an old "Allow" (found while reviewing this change). The PC companion is exempt: it is your own, key-pinned, and approves on the PC.

## [JARVIS Ultimate — phase 1e: task alert actions, Rust crate license texts] — branch `autoloom-glasses-jarvis-v1`

Plan items 2.3 (part) and 1.16 (part). CI results: `TEST_REPORT.md`. New physical test TK1.

### Added
- **Task alerts can complete or snooze their task from the lock screen** (plan 2.3). The actions are "Tamamla / Complete" and "1 saat ertele / Snooze 1 hour"; both are handled in the background, without opening the app. Snoozing moves the due time an hour ahead and, where alerts are already allowed, sets a new alert; it never shows a permission prompt. While the app is on screen a task alert now shows as a banner; other notifications keep their earlier behaviour. Each action is written to the activity log.
- **CI collects the license texts of the Rust crates compiled for iOS** (plan 1.16): `cargo metadata --filter-platform aarch64-apple-ios`, then each crate's own LICENSE/COPYING/NOTICE files, with each distinct text written once. The file is published with the screenshots (`logs/rust-crate-licenses.txt`) so it can be bundled in the app; a CI failure in this step never fails the build.

### Licenses and policy
- **The vendored Codex files changed from `rust-v0.149.0` now say so** (Apache License 2.0, section 4(b)). The two files are `http-client/src/custom_ca.rs` (iOS trust roots) and its `Cargo.toml`. They carry a notice at the top and are listed in `vendor/codex/MODIFICATIONS.md`. A `diff -r` against the pristine release confirmed that every other file, including the realtime call and sideband code, is byte-identical. Audit M7.
- The in-app license text reads better on a phone: the app's own introduction is no longer hard-wrapped, and the separators fit the screen (seen in the phase 1d screenshot).
- `SECURITY.md` no longer points reporters at private vulnerability reporting while it is disabled. It asks for a details-free "Security contact request" issue until the owner enables the feature. Audit M9: enabling it is the owner's action.

## [JARVIS Ultimate — phase 1d: long PC tasks reported later, approval inbox] — branch `autoloom-glasses-jarvis-v1`

Plan items 4.8, 2.4 (part), 2.5, 2.7 and 3.1 (part). CI results: `TEST_REPORT.md`. New physical tests PC9, PC10.

### Added
- **Long PC tasks are reported when they finish** (plan 4.8, research F01). After an approval, the reply waits 10 s for the PC (was 25 s). A task that is still running is followed in the background for up to 30 minutes: polled every 2–10 s, backing off to 60 s while the PC cannot be reached. Its result is delivered when it finishes:
  - spoken into the conversation if one is running;
  - otherwise as an on-screen notice and a notification carrying only the PC's own one-line summary (no result text on the lock screen).

  Running tasks reported by the PC's MCP tools are followed the same way, and the voice model is told not to ask the PC again. The PC's report marks the conversation as holding outside content. Unpairing and the privacy wipe stop the follow-up.
- **Approval inbox** (plan 2.4, research F10): one screen with the action waiting on this iPhone and the tasks waiting for approval on the paired PC. Each item keeps its own Approve/Confirm and Deny/Cancel; nothing is approved in bulk. The Home chip opens it when the PC has approvals waiting. A note says when the PC has not answered for 30 s. Still one waiting action on the phone at a time.
- **Search results open their item** (plan 2.7): a note, memory, conversation summary, task, visual memory, vehicle or document opens its own screen; shopping and photos open their list; a parking spot, or a record deleted since the search, shows what the result said. A task found by the Memory search, and every timeline row except scene lines, now open too.
- **Activity log** (plan 2.5): Privacy center → Activity log keeps, on this iPhone only and for 30 days, what the app did for you — actions run, approvals given, refused or waiting, PC tasks, voice-start and audio problems — by kind only ("Reminder — done", "PC: run_command — approved by tap"), never what you said or what an item contained. It can be exported as text, and the privacy wipe deletes it.
- CI screenshots: the approval inbox and the full license texts.
- **What the AI saw** (plan 3.1, part): each vision task's record now names the image's capture age when the frame's timestamp is on the phone's clock, next to the arrival age, and what metadata the sent image carries (none for camera frames; "no location or camera details" for photos). Shown in the task trace and the copied diagnostics.

### Security
- **MCP servers you added** (audit L7): the app now uses its own ephemeral session for them (no cookies, no cache) and refuses redirects, so the bearer token can never follow one to another host. Answers are capped at 4 MB. The tool list a server sends (names, descriptions, inputs) reaches the tool-choice model wrapped as untrusted information. The PC companion keeps its own pinned session.

### Fixed
- **Privacy center copy matches the code**: explicit reminders, events and notes are saved at once (an unclear time is asked first); it used to say they need a yes. The untrusted-content line now explains the conversation-wide rule.
- Approving a PC task on the PC screen is followed like an approval in the conversation, so its result is also reported when it finishes.
- A camera, web or agent request that fetched nothing (camera off, web search off, the call failed) no longer marks the conversation as holding outside content: its reply is the app's own text.

## [JARVIS Ultimate — phase 1c: fresh frames, late photos, licenses, privacy manifest] — branch `autoloom-glasses-jarvis-v1`

Plan items 1.12, 1.16, 2.1 (part) and 2.2, and audit M2. CI results: `TEST_REPORT.md`. New physical test CAM2.

### Added
- **Home shows the paired PC** when it needs you or works for you: "Bilgisayar: 1 onay bekliyor" or "… görev çalışıyor". The state refreshes every 20 s while Home is on screen; " · yanıt vermiyor" is added once the PC has not answered for 30 s. Tapping opens the PC screen.

### Fixed
- **A frame captured long before it reached the phone is no longer "fresh"** (plan 1.12). Freshness still counts from arrival (at most 1 s for vision). When the frame's timestamp is on the phone's clock, the time since capture must also stay within that limit plus 0.5 s for the trip from the glasses. Bluetooth can deliver frames in bursts, so a just-arrived frame can show an old view.
- **A late photo no longer answers the next request** (plan 1.12). DAT photos carry no request id. When a capture times out after the glasses accepted it, the next photo within 12 s is taken to be that late one. The new request waits for its own photo. Diagnostics count the photos set aside.
- **Reminders are read back after saving** (plan 2.2). If Reminders does not return the new reminder, the reply says so and asks the user to check before trying again, so nothing is doubled. Events are not read back: with write-only calendar access iOS does not allow it.

### Privacy
- **Contact lookups the assistant makes on its own no longer send phone numbers to the voice model** (audit M2). The model gets names and number labels ("mobile, work"); the numbers are shown on the phone. When the user asks for a number to be read out, it still goes to the voice model, so it can be spoken. The privacy page now says so instead of "never uploaded".
- **`PrivacyInfo.xcprivacy`**, derived from the code:
  - required-reason APIs: UserDefaults (CA92.1), elapsed time from the system clock (35F9.1), and free disk space before recording video (E174.1);
  - no tracking;
  - data sent to the AI provider for the app's function: audio, photos and video, user content, contacts.

  **The owner must review this before any App Store submission.**

### Licenses
- **The app now ships the full license texts of the open-source code compiled into it** (Settings → Licenses → Full license texts). BSD-style licenses require them for a binary. Sources:
  - WebRTC's BSD 3-Clause license and patent grant, from the checksum-verified pinned framework;
  - BoringSSL and Abseil (Apache 2.0), and Opus, libvpx (with its patent grant), libyuv, libsrtp and CRC32C, all taken at the revisions pinned in WebRTC's DEPS for branch 7559;
  - the vendored OpenAI Codex license and NOTICE.
- **`docs/RUST_CRATE_LICENSES.md`**: the declared license of every crates.io package in the bridge's lockfile, with the ones that need attention flagged.

## [JARVIS Ultimate — phase 1b: realtime reliability, injection containment] — branch `autoloom-glasses-jarvis-v1`

Plan items 1.4–1.7 and 1.12–1.15 (`JARVIS_IMPLEMENTATION_PLAN.md`). CI results: `TEST_REPORT.md`. Not device-verified; new physical tests VC4, AU2, AU3, RA1, SEC2, SEC3 in `docs/PHYSICAL_TEST_MATRIX.md`.

### Added
- **Readable voice-start errors** (native bridge 4). A failed call now reports the service's HTTP status, error code, `param`, type, message and request id, plus a 600-byte body excerpt; request headers and the token are never included. Each failed start step shows them in Voice diagnostics and in the copied diagnostics. Before, all of it was one string cut to about 150 characters, which is how the field a 400 rejected was lost.
- **Audio-flow watchdog.** About 1 s and 5 s after a conversation is ready, WebRTC's own counters are read:
  - the microphone's captured audio;
  - audio packets sent;
  - audio packets received while the assistant speaks.

  A stuck direction is said out loud on the phone ("Mikrofondan ses alınamıyor; bağlantıyı yeniliyorum") and gets **one** reconnect per conversation, never a loop. A muted microphone, an audio interruption (a phone call) or missing counters are not judged. Voice diagnostics shows the result.
- **Effective audio session in diagnostics**: category, mode, options, sample rate and buffer a few seconds after Ready. It shows if WebRTC replaced the app's choices.

### Changed
- **Voice start ladder**:
  - a rejected sign-in (401/403) refreshes the token once and repeats the same step;
  - after that, and on rate limits (429) or server errors (5xx), it stops instead of resending the same offer with other options;
  - other errors try the next step as before.
- **Native bridge timeouts**:
  - creating the call is limited to 20 s (the HTTP client had none);
  - the task channel's handshake is limited to 10 s, and a stop is honoured while it runs;
  - its reconnect budget starts over only after 30 s of stable connection (an accept-and-close loop used to reset it each time);
  - a 404 before the first connection is retried 3 times (openai/codex#35094).
- **WebRTC's audio configuration mirrors the app's** category, mode and options (`mixWithOthers`, `defaultToSpeaker`, `allowBluetoothHFP`). WebRTC re-applies its own process-wide configuration whenever its audio unit starts; built with the iOS 26 SDK that configuration carried only `allowBluetoothHFP` (fork source, see `JARVIS_AUDIT.md` §6).

### Security
- **Prompt-injection containment across turns (audit M1).** Text from outside now marks the whole conversation, not only the turn it arrived in. Sources:
  - camera, web or agent answers;
  - QR codes, translated signs and documents;
  - Live Vision notes;
  - MCP and PC results.

  While the mark is set, what the voice model asks for on its own needs the user's words or a yes:
  - changes wait for a yes, as before;
  - reads of contacts, calendar and reminders now also wait for a yes;
  - **a memory is saved only from the user's own "hatırla …"** or typed input, because a planted memory would reach every future conversation.

  The mark ends with the conversation.
- Saved memories and the previous conversation's summary reach the voice model as **quoted data blocks**, never as instructions. The voice model is told that outside text is information only. Outside text cannot pose as an "[App message" or a "[Live view" note.
- The untrusted-content wrapper defuses its tag in **any** spelling ("</UNTRUSTED_CONTENT >", "< /untrusted_content"), and its origin cannot add attributes (audit L2).
- **Photos sent to a model carry no location or camera metadata**: GPS, make/model, serials and dates are stripped, or the image is re-encoded (plan 1.13).
- Today's briefing, "find my vehicle" and "remember in AutoLoom" need an unlocked iPhone (audit M5).
- **OpenClaw gateway**:
  - host names such as `fdic.gov` or `fc2.com` are no longer treated as private addresses;
  - the owner token goes over plain HTTP only to loopback or Tailscale;
  - plain HTTP on a home network now shows a warning (audit M4).
- **Remote Assist** (audit M3; TLS is still open, see the plan):
  - it listens on Wi-Fi only and accepts only devices on the local network;
  - at most four viewers;
  - a connection that sends nothing is dropped after 10 s.

### Fixed
- **Live Vision** drops a scene note that was described while the camera was switched or turned off (plan 1.12, part).

## [JARVIS Ultimate — phase 1: audit, PC companion, P0 fixes] — branch `autoloom-glasses-jarvis-v1`

Rollback tag: `rollback-146a169-before-jarvis-ultimate`. CI results: `TEST_REPORT.md`. Not device-verified; new physical tests PC1–PC8, SEC1, AU1, VC1–VC3, DAT1, CAM1 in `docs/PHYSICAL_TEST_MATRIX.md`.

### Added
- **Audit and research**: `JARVIS_AUDIT.md`, `JARVIS_FEATURE_RESEARCH.md`, `JARVIS_IMPLEMENTATION_PLAN.md`, `JARVIS_FEATURE_MATRIX.md`.
  - They come from seven review streams: realtime bridge, camera/DAT, audio, features, security/CI, and two GitHub research streams covering about 117 sources, with code read in about 80 of them.
- **JARVIS PC Companion** (`pc-companion/`, Windows, Node.js 22.18+, no runtime dependencies). Pairing and transport:
  - QR pairing with a one-time code;
  - HTTPS with the PC's own P-256 key, pinned by the phone;
  - hashed device tokens.

  Path policy: shared folders with real-path containment, secret files never read, safe write rules. Tools:
  - search, read and document text (docx/xlsx/pptx/odt/html/rtf; PDF best effort);
  - project overview;
  - create, edit, rename and trash with undo;
  - allowlisted programs and commands.

  Task engine:
  - approvals bound to the exact action;
  - the model channel (MCP) cannot approve;
  - timeouts, bounded retries, and a kill-tree on cancel.

  Also a REST API, server-sent events and a hash-chained audit log. 71 tests and tsc strict; the new workflow `pc-companion.yml` runs them on `windows-latest` with a read-only token. See `docs/PC_COMPANION.md`.
- **Phone side of the PC companion**:
  - `jarvis-pc://` pairing links (from the Camera app or pasted) and a pinned URLSession transport;
  - the paired PC becomes the "Bilgisayar" skill, and "Bilgisayarda …" / "Bilgisayarımda …" reach it by voice;
  - one approval card showing the PC's own description (tap for destructive/execute, the user's own "evet" for plain file changes), with the result spoken or shown;
  - Settings → Computer (PC) with real reachability, approvals, tasks (stop, undo), shared folders and unpair;
  - the privacy wipe also forgets the PC.
- iOS tests:
  - `AutoLoomPCCompanionTests`, including a cross-check that the phone computes the same key pin as the PC code;
  - `testTheVoiceModelCannotConfirmAnActionItself`.

### Security
- **The voice model can no longer confirm actions itself.** A `TASK: confirm_action` delegation is refused. Only the user's own words (parsed by the voice action bridge) or a tap confirm. The model's "no" still cancels.
- **CI least privilege:**
  - the build job runs with a read-only token and `persist-credentials: false`;
  - every action is pinned to a commit SHA;
  - a separate 10-line job holds the only write token, to publish screenshots;
  - IPA artifacts are kept 30 days;
  - PC-companion-only pushes no longer start the macOS build.
- The in-app Licenses screen and `THIRD_PARTY_NOTICES.md` list LiveKit WebRTC as MIT (checked at the pinned revision) and add Project Nayuki's QR generator (MIT).

### Fixed
- **Offline cold launch no longer signs out.** Network errors, timeouts, 429 and 5xx from the token endpoint keep the stored session; only 400/401/403 sign out. A logout can no longer be undone by a refresh that was already running.
- **Realtime call lifecycle:**
  - A start that was still waiting on the network when the user stopped can no longer tear down the next call (generation token).
  - A leftover peer is closed before a new start.
  - A server `error` event is recorded with its nested message and code, instead of showing "failed" while the microphone stays live.
  - `halted` hangs up properly.
  - A data channel that closes during a live call reconnects (within the existing budget).
  - A late ICE failure from an older peer is ignored.
  - A denied microphone is reported before connecting.
  - The fixed 2.5 s ICE wait is gone: the offer is sent 200 ms after the first host candidate.
- **Truthful camera answers:** the instructions now say whether the image came from the iPhone camera or the glasses.
- **DAT version honesty:** `sdkUpdateRequired` (the glasses need a newer toolkit than DAT 0.5.0) and `deviceUpdateRequired` show a clear alert at the first read, not only on change.
- **Tapped agent and skill results** are shown in the answer card instead of being discarded.
- The model is no longer told to delegate `confirm_action` (instructions and staged prompts).

## [AutoLoom Jarvis v1.5 — Ultimate Jarvis expansion] — branch `autoloom-glasses-jarvis-v1`

Final CI run [36600758014](https://github.com/tolgawox-byte/GlassifAI/actions/runs/36600758014) on `a4e0eb3`: iOS 321/323 (2 skipped), Rust 8/8; tag `baseline-a4e0eb3-jarvis-v1.5`. Rollback tag: `rollback-405e461-before-jarvis-expansion`. Not device-verified; `docs/PHYSICAL_TEST_MATRIX.md` lists the checks.

### Added
- **ActionCatalog**: one definition per action (names, Turkish/English examples, parameters, risk, confirmation, permissions, capabilities, offline, undo, route, App Intent, UI place, status) feeding the voice bridge, App Intents (`RunAutoLoomActionIntent` and dedicated intents), the tool schemas, the Command Library, Command Lab and the new command palette. CI checks that every example reaches its action through the same parser as speech.
- **Jarvis context**: several commands in one sentence, "hayır, cumartesi" corrections, "bunu yarına taşı", vehicle questions ("kaç kilometre?"), session snapshot (vehicle, person, place, document, task, recording, sharing, timeline, providers).
- **Apple intelligence (optional)**: on-device Foundation Models profiles (weak-linked), note titles and tags, entities, summaries, search rewrite, offline answers; iOS 27 Dynamic Profiles and Spotlight search tool; Spotlight second brain (masked VINs, memories opt-in, complete protection); global natural-language search.
- **Visual Second Brain**: visual memories keep on-device text and objects, the active vehicle and (only if allowed) a photo; "anahtarımı en son nerede gördüm?", "bugün neler gördüm?"; opt-in Scene Timeline (text only, 7 days); Live Vision "ne değişti?".
- **Translation and documents**: signs read and translated on the phone with Apple Translation (downloaded languages, system download sheet), cloud fallback; in Translation mode Live Vision also translates readable foreign text; "bu belgeyi özetle", "fişi kaydet", "bu ay ne harcadım?" (text kept, never the photo; reminders only after a yes).
- **Dealer SuperMode**: NHTSA vPIC decode, Transport Canada recalls (never "no recalls"; manufacturer VIN pages), tire size and DOT age, warning lights (no diagnosis), equipment with provenance, walk-around areas, condition report, service handoff, lot spot, part numbers, damage severity only when said, photos linked to fresh damage notes, photo director hints, dealer morning briefing, AutoLoom Media adapter interface (never automatic).
- **Daily life**: parking spot with a linked Ray-Ban photo ("park yerimi fotoğrafla kaydet"), music through the system player and the user's library, the user's own Shortcuts after a tap (Home scenes), user routines of safe steps, opt-in morning briefing notification.
- **Remote Assist** on the same Wi-Fi with a room code (tap to start, red bar, "paylaşımı durdur", stops in the background, after 15 minutes, after wrong codes or when hot).
- **MCP skills**: Streamable HTTP client, servers added only in Settings (https, Keychain token), per-tool policy, the receiving service shown before every call, destructive tools need a tap.
- **Interface**: Liquid Glass floating controls with a material fallback, context chips (vehicle, sharing, offline), command palette, activity timeline, visual memory gallery, vehicle SuperMode sections, translation, documents, routines, skills, privacy dashboard, performance screen.
- **Performance**: thermal guard (critical heat stops Live Vision and sharing, never a recording), sharing frame rate halves when hot.
- **CI**: builds continue after the first failing file; voice evaluation accuracy on the run page; screenshots with launch logs and crash reports.
- Tests: `AutoLoomActionCatalogTests`, `AutoLoomJarvisExpansionTests`, `AutoLoomAppleIntelligenceTests`, `AutoLoomVisualMemoryTests`, `AutoLoomDealerSuperModeTests`, `AutoLoomDocumentsTranslationTests`, `AutoLoomMusicRoutinesTests`, `AutoLoomRemoteAssistTests`, `AutoLoomSkillsTests`, `AutoLoomShortcutTests`, `AutoLoomVoiceEvaluationTests`.

### Fixed
- CI screenshots: the simulator app crashed at launch because the test build keeps `MWDATMockDevice.framework` beside the app; it is now copied in.
- Command Lab showed "(text: …)" for single labelled parameters.

### Privacy
- Vision prompts never identify people from faces.
- Documents keep text only; visual memory photos only when allowed; the Scene Timeline is text only and off by default.
- Nothing is shared or sent to a skill, a shortcut or AutoLoom Media without the user's own words and, where it leaves the phone, a tap.

## [AutoLoom Jarvis v1.4 — multi-agent, Ray-Ban media, reliable notes] — branch `autoloom-glasses-jarvis-v1`

Final CI run [36523415778](https://github.com/tolgawox-byte/GlassifAI/actions/runs/36523415778) on `f38bcad`: iOS 263/265 (2 skipped), Rust 8/8; tag `baseline-f38bcad-jarvis-v1.4`. Rollback tags: `rollback-f11377f-before-multi-agent`, `rollback-c2d7cfe-before-dealer`. Not device-verified.

### Added
- **Multi-agent orchestrator**: logical agents (chat, vision, live vision, research, reasoning, coding, actions, memory, dealer, translation, documents, planning, external), `AgentPlan`, `AgentRouter` (LOCAL / FAST / SPECIALIST / TEAM), cost preferences (Balanced, Best quality, Lower cost, Local first), per-role pins, automatic routing, offline handling.
- **Providers**: ChatGPT (existing account), Local, Claude, Gemini, Perplexity, OpenRouter (official APIs, keys in the Keychain), OpenClaw (existing gateway); model discovery with a capability matrix; Test connection; circuit breaker, rate-limit pause, bounded fallback, timeouts, cancellation; routing diagnostics without content.
- **Team mode and result fusion**: see-then-research, parallel research questions, one answer with merged sources and stated disagreements.
- **One voice**: response normalizer (no provider names, no `<think>` traces; speech without markdown, tables or URLs), entity context across agents.
- **Jarvis Style**: intensity (Subtle / Balanced / Full), form of address (None / My name / Sir – Efendim / Custom), persona confirmations ("Not aldım efendim."), greeting ("Bağlantı hazır. Sizi dinliyorum efendim."); Settings → Personality and Settings → Intelligence.
- **Ray-Ban photos and videos**: "fotoğraf çek", "video kaydını başlat", "kaydı durdur", "kayıt yapıyor musun?", "galeriye kaydet"; add-only Photos saving, Captures (Explore tab), recording chip, shutter and record buttons, dealer labels, photo + note.
- **Locked-screen vision**: software VideoToolbox decoder by default, bounded fresh-frame recovery, still-photo fallback in the background, "Continue vision with the screen locked".
- **Dealer Mode**: vehicle sessions ("yeni araç", "sonraki araç", "bu araç tamam"), VIN reading with the ISO 3779 check digit (never completes a character; look-alikes offered as options), odometer by voice or camera, damage with Turkish/English body zones, photo / delivery / test-drive checklists (a labelled Ray-Ban photo ticks its item), market research and listing drafts through the agent router, dealer briefing; notes, tasks and captures link to the active vehicle; Explore → Dealer. Rollback tag `rollback-c2d7cfe-before-dealer`.
- **Daily life**: timers with local notifications and a countdown chip, shopping list, parking spot ("park yerimi kaydet", "arabam nerede?", "beni arabama götür"), QR codes and barcodes read on the phone and never opened ("QR kodu oku"), place reminders at home or work as Apple Reminders location alarms ("eve varınca süt almayı hatırlat"), evening and weekly review, undo of the last local action, assistant modes (Dealer automatically while a vehicle is active).
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
