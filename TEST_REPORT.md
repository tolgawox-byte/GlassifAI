# Test report — AutoLoom Media Glasses (`autoloom-glasses-jarvis-v1`, Jarvis v1.1)

Result categories:
- **BUILD PASS**: compiled into the Debug and Release IPAs in CI.
- **UNIT PASS**: automated test passed in CI (iOS Simulator or Rust host).
- **PHYSICAL TEST REQUIRED**: needs the iPhone and Ray-Ban Meta Gen 1. The tables below are for you to fill in.

Environment: Windows 11 (no Xcode). Everything compiles and runs on GitHub Actions (`xcode-27` runner). Test names and counts come from the `.xcresult` bundle and are published as annotations on each run page, and so are compiler errors.

## Automated results — Jarvis v1.1

<!-- AUTOMATED-RESULTS-V11 -->
| Run | Commit | Result | Notes |
|---|---|---|---|
| [36387415366](https://github.com/tolgawox-byte/GlassifAI/actions/runs/36387415366) | `1d4651d` | **BUILD PASS · iOS 145/145 · Rust 8/8** | **Final run for v1.1 — install this Release IPA.** Daily briefing, possessive reminder phrasings, brief scenarios; docs |
| [36385963557](https://github.com/tolgawox-byte/GlassifAI/actions/runs/36385963557) | `98e5feb` | **BUILD PASS · iOS 143/143 · Rust 8/8** | Voice actions, memory, tasks, connection feedback, Jarvis Style; Debug + Release IPAs |
| [36382827852](https://github.com/tolgawox-byte/GlassifAI/actions/runs/36382827852) | `a720297` | **BUILD PASS · iOS 126/126 · Rust 8/8** | Camera background fix (lifecycle states, decoder, `bluetooth-central`) |

New iOS tests in v1.1 (`AutoLoomVoiceActionTests`, plus updated risk and greeting tests):

| Area | Tests |
|---|---|
| Notes by voice (start/end triggers, "bunu", asking for content, awaiting answer) | `testSpokenNotesAreRecognised` |
| Ordinary speech left to the voice model (weather, "not almak için…", "mesaj yaz", "adım atmak", negatives, addressed-only) | `testOrdinarySpeechIsLeftToTheVoiceModel` |
| Reminders and notifications (titles "Patronu ara", relative times, "bunu tekrar", English) | `testRemindersKeepTheSpokenTimeAndAClearTitle` |
| AutoLoom tasks and calendar ("cuma 3'e", "yarın ne var?", routines) | `testTasksAndEvents`, `testTimePhrasesForCommonMeetingHours` |
| Memory, name, recall, forget, visual memory, conversation questions | `testMemoryCommands` |
| Answers to pending actions (evet/hayır/sabah/akşam; a new question is not a yes) | `testAnswersToAPendingAction` |
| The brief's own test sentences (§76–§82) | `testBriefScenarios` |
| Early hold of the model's reply | `testCommandStartsAreSpottedEarly` |
| Saved before the confirmation; tasks visible at once; trace | `testSpokenNoteAndTaskAreSavedBeforeTheConfirmation`, `testActionTraceRedactsNumbers` |
| Tasks grouping, profile, conversation summaries, summarizer | `testTasksAreGroupedByDay`, `testProfileNameIsExplicitAndCleaned`, `testConversationSummariesAreStoredAndRetrievedNotInjected`, `testConversationSummarizer` |
| Connection feedback, chime, Jarvis Style, instructions size | `testConnectionFeedback`, `testJarvisStyleIsAStyleNotAClone` |
| Daily briefing once per day | `testDailyBriefingIsOffByDefaultAndOncePerDay` |
| Ray-Ban lifecycle states | `testGlassesPipelineStates` |
| Updated: explicit reminders/events SAFE, greetings | `AutoLoomActionTests.testReminderTimeComesFromTheUsersWords`, `testRiskLevels`; `AutoLoomJarvisTests.testEveryPlannableActionHasATool`, `testQuietTimeoutAndGreetings` |

## Physical tests for Jarvis v1.1 (iPhone + Ray-Ban Meta Gen 1)

**Before you start**
1. Install **AutoLoomMediaGlasses-Release-unsigned.ipa** from the final run, [36387415366](https://github.com/tolgawox-byte/GlassifAI/actions/runs/36387415366) (`docs/WINDOWS_INSTALL.md`).
2. Settings → Developer → Diagnostics: **Commit** = `1d4651d0fd33`, **DAT SDK** = 0.5.0. (The DAT 1.0 variant has its own tests: `docs/DAT_1_MIGRATION.md`.)
3. Settings → Name & conversation: name **Jarvis**. Settings → Wake phrase & hands-free: phrase **Hey Jarvis**.
4. After a failed test: Developer → Action & task trace → **Copy sanitized task trace** (it now includes the voice actions), and keep the text. For camera tests also copy the Camera diagnostics transitions.

### Lock screen (brief §74) — mandatory

| # | Step | Pass when | Result |
|---|---|---|---|
| L1 | Start AutoLoom, select Ray-Ban, start a conversation, ask "Ne görüyorum?" | Correct answer | |
| L2 | Lock the iPhone, wait 10 s, look at a new object, ask "Bu ne?" through the glasses | Describes the **new** object | |
| L3 | Turn to another object, ask again | Describes that object | |
| L4 | Unlock | Preview resumes; the next answer is about the current view (no stale frame) | |
| L5 | Camera diagnostics after L2–L3 | State `ScreenLockedStreaming`; background samples and background decoded both rising; transport HEVC; note the last decode error if any | |

If L2 fails: note whether background samples rose (glasses kept sending) and whether background decoded stayed at 0 (decoder) — `docs/BACKGROUND_STREAMING.md` explains what each means. Do not mark it working otherwise.

### Voice actions (brief §78, §79, §82)

| # | Say | Pass when | Result |
|---|---|---|---|
| A1 | "Jarvis, not al: yarın kamerayı yanıma alacağım." | One answer, "Tamam, not aldım." (no "Tabii, not alabilirim" first); Memory → Notes shows it at once | |
| A2 | "Jarvis, iki dakika sonra test hatırlatıcısı oluştur." | Reminder "Test" in Apple Reminders and the Tasks tab at once; it alerts after two minutes | |
| A3 | "Yarın 10'a Ahmet'i aramamı hatırlat." | Reminder "Ahmet'i ara", tomorrow 10:00, no morning/evening question | |
| A4 | "Yarın 7'de koşuya çıkmayı hatırlat" → "akşam" | Asks "sabah mı akşam mı?"; saved at 19:00 after "akşam" | |
| A5 | "Cuma 3'e toplantı ekle" | Calendar event "Toplantı", Friday 15:00 | |
| A6 | "Bugün takvimimde ne var?" / "Yarın ne var?" | Reads the right day | |
| A7 | "Yarın bu arabayı tekrar kontrol et görev oluştur" | AutoLoom task in Tasks → Upcoming (tomorrow) | |
| A8 | "Görevlerim neler?" | Lists open tasks (and reminders) | |
| A9 | First time only, with Reminders permission not yet given and the phone locked: "Yarın 9'da su iç diye hatırlat" | Says to open the app; after opening and allowing, the reminder is created without repeating the sentence | |
| A10 | Developer → Action & task trace → Voice actions | Each command shows transcript, intent, parser, parsed time, permission, executor, result | |

### Memory and conversation memory (brief §76, §77)

| # | Test | Pass when | Result |
|---|---|---|---|
| M1 | "Jarvis, benim adım Tolga, bunu hatırla." Force-quit the app, reopen, start a conversation: "Benim adım ne?" | "Tolga"; Memory → About me shows it | |
| M2 | Talk for a minute about one project (e.g. the camera quality), end the conversation ("Kapat"). Close the app. Reopen: "Geçen konuşmamızda ne yapıyorduk?" | Answers from the summary; Memory → Conversations shows it | |
| M3 | "Arabamın otoparkın P2 katında olduğunu unutma" → later "Arabam nerede?" | "P2" | |
| M4 | Memory → ⋯ → Clear all AutoLoom memory | Confirmation; memories, summaries and name gone; notes and tasks kept | |

### Connection acknowledgement (brief §80)

| # | Test | Pass when | Result |
|---|---|---|---|
| K1 | Wake phrase on, say "Hey Jarvis" | Nothing while connecting; then chime + "Bağlandım, dinliyorum." **exactly once** | |
| K2 | Settings → Voice → Connection feedback = Chime only; start by wake phrase | Chime only, when ready | |
| K3 | Airplane mode, "Hey Jarvis" | Low tone + "Bağlantı kurulamadı." | |
| K4 | During a conversation switch Wi-Fi off and on | At most a subtle chime on reconnect; no second greeting | |
| K5 | During a conversation fold the glasses / turn them off | "Ray-Ban bağlantısı koptu." | |
| K6 | Developer → Voice diagnostics | Steps WakeDetected → … → Ready with times; the audio route | |

### Voices and Jarvis Style (brief §81)

| Voice | Selected | Active | Audibly different | Fallback | Pass/fail |
|---|---|---|---|---|---|
| Juniper | | | | | |
| Maple | | | | | |
| Spruce | | | | | |
| Ember | | | | | |
| Vale | | | | | |
| Breeze | | | | | |
| Arbor | | | | | |
| Sol | | | | | |
| Cove | | | | | |
| Jarvis Style on (Cove + style) | | | | | |

Jarvis Style is labelled in Settings as a style, not a voice clone; check the wording.

### Natural conversation (brief §82) — one conversation

Say in order: "Selam Jarvis." · "Bugün biraz yoğunum." · "Yarın 10'a Ahmet'i aramamı hatırlat." · "Bir de not al, kamerayı götüreceğim." · "Az önce ne not aldın?" · "Şu an önümdeki şeyi de bir kontrol et." · "Bunun Kanada fiyatına bak."

| Check | Pass when | Result |
|---|---|---|
| Flow | Feels like one conversation; no canned "Tabii, size yardımcı olabilirim" | |
| Reminder and note | Both saved, each confirmed once | |
| "Az önce ne not aldın?" | Says "kamerayı götüreceğim" | |
| Vision + web | Describes the item, then the Canadian price with a source name (no URL read aloud) | |

### Interface

| # | Check | Pass when | Result |
|---|---|---|---|
| U1 | Assistant screen with Ray-Ban | No resolution, FPS, frame, codec or age text anywhere | |
| U2 | Say a note | Status word shows "Kaydediyor"/"Saving" briefly | |
| U3 | Settings | Assistant, Voice, AI, Vision, Memory, Tools, Privacy, Developer, About | |
| U4 | Developer → Camera diagnostics | All camera numbers are here | |

---

# Jarvis v1 (earlier results and tests)

## Automated results

<!-- AUTOMATED-RESULTS -->
### Final build: run [36375889033](https://github.com/tolgawox-byte/GlassifAI/actions/runs/36375889033), commit `26f3685`

**BUILD PASS · iOS 126/126 UNIT PASS (0 skipped) · Rust 8/8 UNIT PASS.** Artifact `AutoLoomMediaGlasses-unsigned-IPAs` (55 MB, expires 2026-12-27) contains `AutoLoomMediaGlasses-Release-unsigned.ipa` (install this one) and `AutoLoomMediaGlasses-Debug-unsigned.ipa`.

- iOS: the vNext suites (adapted to the new APIs) plus 27 more:
  - `AutoLoomJarvisTests` 25
  - `AutoLoomActionTests` net +2 (time from the user's words, model timestamps ignored, notes run directly, forgetting waits for a yes; replacing two older tests)
- Rust: 8 (3 new: applied voice and model in the start result, requested voice applied, frameless voice list pinned to Codex).

### Runs on `autoloom-glasses-jarvis-v1`

| Run | Commit | Result | Notes |
|---|---|---|---|
| [36375889033](https://github.com/tolgawox-byte/GlassifAI/actions/runs/36375889033) | `26f3685` (final) | **BUILD PASS · iOS 126/126 · Rust 8/8** | Release IPA for the phone |
| [36373200187](https://github.com/tolgawox-byte/GlassifAI/actions/runs/36373200187) | `63b8cb3` | BUILD PASS · iOS 125/126 | `testCompressedRayBanFrameIsDecodedIntoFrameStore` failed once. That code is unchanged since vNext; the fix adds one retry with a fresh VideoToolbox session and a static test-host screen. The test passed in the final run |
| [36371678490](https://github.com/tolgawox-byte/GlassifAI/actions/runs/36371678490) | `bb8da67` | BUILD FAIL | `ParsedTime` memberwise argument order |

## What the automated tests cover (new in Jarvis v1)

| Area | Tests (`AutoLoomJarvisTests` unless noted) |
|---|---|
| Voice catalog = frameless voices; legacy voice migration | `testVoiceCatalogOffersOnlyTheFramelessVoices`, `testStoredLegacyVoiceIsMigratedVisibly`; Rust `frameless_voices_match_the_app_catalog` |
| Start ladder, bridge result with applied voice | `testStartLadderKeepsTheSelectedVoiceAsLongAsPossible`, `testBridgeResultReportsTheAppliedVoice`; Rust `start_summary_reports_the_applied_voice_and_model`, `requested_voice_is_applied`, `invalid_voice_falls_back_to_juniper_and_is_reported` |
| State words, friendly errors | `testPresenceWordsFollowRealState`, `testFriendlyErrorsHideTechnicalText` |
| Stop words and end commands | `testStopWordsSilenceOnlyAnAnswerInProgress`, `testEndCommandsEndTheConversation` |
| Quiet timeout, greetings | `testQuietTimeoutAndGreetings` |
| Wake phrase matching | `testWakePhraseMatchesNaturalTranscripts`; `AutoLoomVoiceTests` |
| Deterministic time parsing (Turkish, English, false friends) | `testRelativeTimes`, `testTurkishDayAndClock`, `testEnglishPhrases`, `testWordsThatAreNotTimes`, `testEventEndBelongsToTheStartDay`; `AutoLoomActionTests.testReminderTimeComesFromTheUsersWords`, `testModelTimestampsAreIgnored` |
| Memory store, dedupe, classification, Turkish search, pins, prompt bounds, notes, deletion | `testMemoryIsExplicitDedupedAndClassified`, `testMemorySearchUnderstandsTurkishWordForms`, `testPinnedMemoriesComeFirstAndPromptsStaySmall`, `testNotesAndDeletion`; `AutoLoomCoreTests.testMemoryIsExplicitAndDeletable` |
| Memory requests and visual memory routing | `testMemoryRequestsAreParsedDeterministically`, `testVisualMemoryDelegationRoutes` |
| Risk levels and confirmation | `AutoLoomActionTests.testRiskLevels`, `testNotesAreSavedDirectly`, `testForgettingAMemoryWaitsForAYes`, `testCallsAndMessagesAreNeverConfirmedByVoice` |
| Tool registry and switches | `testEveryPlannableActionHasATool` |
| Vision "move closer" escalation | `testUnclearVisionAnswersAreRecognised` |
| Instructions size and content | `testRealtimeInstructionsAreNaturalAndBounded` |
| Trace redaction | `testTraceRedactsPersonalDetails` |

Earlier suites (vision pipeline, camera, Live Vision, models, agent, core) still run unchanged.

## Physical tests of Jarvis v1 (where they overlap, the v1.1 tables above replace them: reminders and events are now saved without a yes, and the camera overlay is gone)

**Before you start**
1. Install **AutoLoomMediaGlasses-Release-unsigned.ipa** from the final run (`docs/WINDOWS_INSTALL.md`).
2. Go through the onboarding once. Settings → Developer → Diagnostics: **Commit** matches the run, **Native bridge** = `autoloom-bridge-3`, **DAT SDK** = 0.5.0.
3. Settings → Name & conversation: name **Jarvis**. Settings → Wake phrase & hands-free: phrase **Hey Jarvis**.
4. After a failed test: Developer → Task trace → **Copy sanitized task trace**, and keep the text.

### Voices

| Voice | Preview sounds different | Conversation uses it (Active = Selected) | Notes |
|---|---|---|---|
| Juniper | | | |
| Maple | | | |
| Spruce | | | |
| Ember | | | |
| Vale | | | |
| Breeze | | | |
| Arbor | | | |
| Sol | | | |
| Cove | | | |
| Apply now during a conversation (Maple → Cove) | — | | |

### Conversation

| # | Test | Pass when | Result |
|---|---|---|---|
| C1 | "Jarvis, nasılsın?" and 3–4 casual turns | Natural Turkish, short answers, no "As an AI", no lists | |
| C2 | Ask a long explanation, say "Dur" in the middle | Sound stops at once; the assistant listens | |
| C3 | "Başka bir şey soracağım" while it talks, then a new question | Old answer dropped; new question answered | |
| C4 | "Ne yapabilirsin?" | 2–3 sentences with examples, not a list | |
| C5 | "Kapat" / "Konuşmayı bitir" | Short goodbye, conversation ends | |
| C6 | Stay silent for 2 minutes | Conversation ends; notice "Ended after a quiet period" | |

### Wake states (see `docs/WAKE_INVOCATION.md`)

| State | Test | Pass when | Result |
|---|---|---|---|
| A | In a conversation: "Jarvis, saat kaç?" | Answers without re-invoking | |
| B | App open, wake phrase on: "Hey Jarvis" | Chime, conversation starts | |
| C | Hands-Free Ready 30 min, lock the phone, wait 1 min: "Hey Jarvis" | Starts, or shows "paused" (note which) | |
| C2 | After a hands-free conversation ends while locked, say it again | Starts again, or "paused" | |
| D | "Only while the glasses are connected": glasses off, then on | "Waiting for the glasses", then listening | |
| E | "Hey Siri, start AutoLoom" | App opens and listens | |
| Meta | "Hey Meta, start AutoLoom" | Not expected to work (DAT 1.0 needed); note what happens | |

### Memory, notes, visual memory

| # | Test | Pass when | Result |
|---|---|---|---|
| M1 | "Jarvis, arabamı otoparkın P2 katına park ettiğimi hatırla" | Short confirmation; Memory → Recent (Vehicles) | |
| M2 | Later: "Arabam nerede?" | Answers "P2" | |
| M3 | Save "kapı kodu 4512", then "kapı kodunu unut" | Asks to confirm; forgotten only after yes | |
| M4 | Memory tab: search, pin, edit, Delete all | Works; confirmation before Delete all | |
| M5 | Visual memories on; look at a sign: "bunu hatırla" | Description with the readable text; photo/place only if enabled | |
| N1 | "Not al: yarınki toplantıda bütçeyi konuş" | Note in Memory → Notes; Share works | |
| N2 | Shortcuts app: "Create AutoLoom Note" | Note saved without opening the app | |

### Reminders, calendar, notifications, contacts

| # | Test | Pass when | Result |
|---|---|---|---|
| R1 | "Jarvis, yarın saat 7'de bana süt almayı hatırlat" | Asks "sabah mı akşam mı?" (07:00 or 19:00); saved only after the answer and yes; appears in Reminders and the Tasks tab | |
| R2 | "20 dakika sonra ilacımı hatırlat" | Card shows the exact time (now + 20 min); saved after yes | |
| R3 | "Cuma akşam 8'de Ali'yi aramayı hatırlat" | Friday 20:00, no ambiguity question | |
| R4 | Tasks tab: complete, reschedule, delete (with confirmation) | Changes appear in Apple Reminders | |
| K1 | "Bugün takvimimde ne var?"; "Yarın 15:00'te dişçi randevusu ekle" | Events read; event added after yes | |
| K2 | "10 dakika sonra bana haber ver" | Notification arrives; listed in the Tasks tab before it fires | |
| P1 | "Annemi ara" (with a contact named Anne/Annem) | Contacts permission once; call card with the number; only a tap calls | |

### Vision

| # | Test | Pass when | Result |
|---|---|---|---|
| V1 | Ray-Ban: "Şu an neye bakıyorum?" | Correct description | |
| V2 | A small label ~40 cm away: "Etikette ne yazıyor?" | Reads it, or one specific tip; Task trace shows "high-detail retry" when the first try was unclear | |
| V3 | Ask V2 twice in a row | The tip is not repeated the second time | |

### Interface

| # | Check | Pass when | Result |
|---|---|---|---|
| U1 | Main screen | No FPS/frame numbers; state word changes Ready → Listening → Thinking → Speaking | |
| U2 | Camera off | Orb animates with the state | |
| U3 | Camera indicator | Switches Ray-Ban / iPhone / Off | |
| U4 | Airplane mode, start | Friendly "No internet connection" | |
| U5 | Settings → Developer → overlay on | Metrics appear; off again → gone | |
| U6 | Privacy center | Every permission listed with its state | |

## Camera measurement sheet (Settings → Developer → Camera diagnostics)

| Profile | Requested | Actual resolution | Actual fps (in / shown) | Transport | Dropped | Frame age |
|---|---|---|---|---|---|---|
| Detail 720p/15 (default) | 720×1280 @ 15 | | | | | |
| Max detail 720p/7 | 720×1280 @ 7 | | | | | |
| Balanced 720p/24 (original) | 720×1280 @ 24 | | | | | |
