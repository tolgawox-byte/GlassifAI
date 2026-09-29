# Test report — AutoLoom Media Glasses (`autoloom-glasses-jarvis-v1`, v1.4)

Result categories:
- **BUILD PASS**: compiled into the Debug and Release IPAs in CI.
- **UNIT PASS**: automated test passed in CI (iOS Simulator or Rust host).
- **PHYSICAL TEST REQUIRED**: needs the iPhone and Ray-Ban Meta Gen 1. The tables below are for you to fill in.

Environment: Windows 11 (no Xcode). Everything compiles and runs on GitHub Actions (`xcode-27` runner). Test names and counts come from the `.xcresult` bundle and are published as annotations on each run page, and so are compiler errors.

## Multi-agent, Dealer Mode, daily life, Ray-Ban photos and video (v1.4)

| Run | Commit | Result | Notes |
|---|---|---|---|
| [36523415778](https://github.com/tolgawox-byte/GlassifAI/actions/runs/36523415778) | `f38bcad` | **BUILD PASS · iOS 263/265 (2 skipped) · Rust 8/8** | **Final run for v1.4 — install this Release IPA** (`AutoLoomMediaGlasses-Release-unsigned.ipa`) |
| [36520754831](https://github.com/tolgawox-byte/GlassifAI/actions/runs/36520754831) | `ac8be1f` | BUILD PASS · iOS 259/263 (2 skipped) · Rust 8/8 | Place reminders. The voice timer test ran past its 3-minute allowance (most likely why the tests of 36518376601 ran so long) and Vision found no QR code in the simulator; both fixed in `f38bcad` |
| [36520266622](https://github.com/tolgawox-byte/GlassifAI/actions/runs/36520266622) | `df7b690` | BUILD PASS · tests cancelled | Parking and QR; superseded by `ac8be1f` while its tests ran |
| [36518376601](https://github.com/tolgawox-byte/GlassifAI/actions/runs/36518376601) | `ba97b22` | BUILD PASS · tests cancelled | Superseded by `df7b690` while its tests ran |
| [36518316078](https://github.com/tolgawox-byte/GlassifAI/actions/runs/36518316078) | `d771f9b` | cancelled | Superseded by `ba97b22` |
| [36517875234](https://github.com/tolgawox-byte/GlassifAI/actions/runs/36517875234) | `06142d1` | build failed | The routine `switch` lacked the new review cases (fixed in `ba97b22`) |
| [36515901004](https://github.com/tolgawox-byte/GlassifAI/actions/runs/36515901004) | `d12b4bc` | BUILD PASS · iOS 235/239 · Rust 8/8 | Multi-agent. Two Keychain tests: the unsigned simulator app has no Keychain entitlement (now skipped with that reason). Two routing tests: "bug" matched "bugün" (fixed in `d771f9b`) |
| [36513869746](https://github.com/tolgawox-byte/GlassifAI/actions/runs/36513869746) | `0e425e8` | BUILD PASS · iOS 213/213 · Rust 8/8 | Ray-Ban background vision, photos, video, media library |
| [36512170295](https://github.com/tolgawox-byte/GlassifAI/actions/runs/36512170295) | `f11377f` | BUILD PASS · iOS 191/191 · Rust 8/8 | Spoken notes |
| [36510421307](https://github.com/tolgawox-byte/GlassifAI/actions/runs/36510421307) | `f917edb` | BUILD PASS · iOS 190/191 · Rust 8/8 | The Notes tool's risk label (fixed in `f11377f`) |

New test classes: `AutoLoomRayBanMediaTests` (decoder recovery, stall policy, locked-screen vision, photo and video outcomes, what is said), `AutoLoomMultiAgentTests` (routing, fallbacks, circuit breaker, teams and fusion, provider adapters against stubbed HTTP, the normaliser, Jarvis Style), `AutoLoomDealerTests` (VIN check digit and look-alikes, odometer, body zones, checklists, the vehicle store, quick commands, linking), `AutoLoomDailyLifeTests` (durations, timers, shopping list, parking, QR codes, undo, reviews, modes, unreadable files kept).

Skipped in CI: the two tests that store a provider key. CI builds the test app unsigned, and an unsigned simulator app has no Keychain. Test A5 below covers them on the phone.

### Physical tests (v1.4)

Install the Release IPA from the first row (Diagnostics **Commit** = `f38bcad`). After any failure, copy Settings → Developer → Action & task trace; for Ray-Ban, also Camera diagnostics.

Spoken notes:

| # | Say / do | Pass when | Result |
|---|---|---|---|
| N1 | "AutoLoom, not al: yarın lastikleri kontrol et." | "Tamam, not aldım." only once the note is in Memory → Notes | |
| N2 | "Lastikleri kontrol etmeyi görev olarak ekle." | A task in Tasks, not a note | |
| N3 | After any answer: "bunu not al" | The note holds that answer | |
| N4 | With a vehicle active: "not al: sol arka lastik değişecek" | In Notes, and the vehicle shows one linked note | |

Ray-Ban vision, photos and video:

| # | Say / do | Pass when | Result |
|---|---|---|---|
| R1 | Glasses streaming, lock the phone, ask "önümde ne var?" | It describes what the glasses see; Camera diagnostics shows frames still arriving | |
| R2 | Settings → Ray-Ban → Screen locked off; lock; ask again | It says the camera is off while locked; no image is used | |
| R3 | "Fotoğraf çek" | Shutter sound; "…Fotoğraflar'a kaydettim" only when the Photos app has it | |
| R4 | Deny adding to Photos, then "fotoğraf çek" | Kept in Explore → Captures and it says so; Save again works once allowed | |
| R5 | "Video kaydet" … 20 s … "kaydı durdur" | Start and stop sounds; the video is in Photos, silent (DAT 0.5 has no camera audio) | |
| R6 | Record, lock the phone for 30 s, unlock, stop | The locked time is in the video (maybe as segments); if it stopped, it said why | |
| R7 | "Kayıt ne kadar oldu?" while recording | The time so far | |
| R8 | With a vehicle active: "jantın fotoğrafını çek" | The photo is linked to the vehicle; "Wheels and tires" is ticked | |

Dealer Mode:

| # | Say / do | Pass when | Result |
|---|---|---|---|
| D1 | "Yeni araç" | Explore → Dealer shows the active vehicle | |
| D2 | Looking at the VIN plate: "VIN oku" | The last six characters are read out; "doğrulandı" only when the check digit matches; an unclear character comes as options, never a guess | |
| D3 | "Kilometre 45 bin 320"; then, at the cluster, "kilometreyi oku" | Saved as 45.320 km and shown on the card | |
| D4 | "Hasar ekle: sağ ön çamurluk çizik" | The vehicle lists "sağ ön çamurluk çizik" | |
| D5 | "Foto checklist" | The photos still missing | |
| D6 | "Piyasa bak" (web search on) | A price range with sources; saved under Research | |
| D7 | "İlan hazırla" | A listing in Notes that uses only the recorded facts and states the damage | |
| D8 | Right after D4: "Son yaptığını geri al" | The damage is gone | |
| D9 | "Bu araç tamam", then "sonraki araç" | A short summary; the next vehicle starts | |

Daily life and Shortcuts:

| # | Say / do | Pass when | Result |
|---|---|---|---|
| L1 | "10 dakika timer kur", lock the phone | The chip counts down; the notification rings at the end while locked | |
| L2 | With it running: "Ne kadar kaldı?", then "timerı durdur" | The time left; then no notification later | |
| L3 | "Alışveriş listesine süt ve ekmek ekle" → "alışveriş listemde ne var" → "sütü listeden çıkar" | Explore → Shopping list matches each step | |
| L4 | "Bugün ne yaptım?", "haftalık özet" | Counts of notes, tasks, memories, captures and vehicles; nothing invented | |
| L5 | Shortcuts / Siri: "New AutoLoom task", "AutoLoom shopping list", "Start a dealer session in AutoLoom", "AutoLoom today's briefing", "Remember this in AutoLoom" | Each does what it says | |
| L6 | Outdoors: "park yerimi kaydet: B2 katı" → walk away → "arabam nerede?" → "beni arabama götür" | The place and "B2 katı" are read back; Maps opens walking directions to the spot; the location prompt appears only the first time | |
| L7 | Look at a restaurant menu QR code: "QR kodu oku"; then a Wi-Fi QR code | The web address's site name is read out and nothing opens; for Wi-Fi only the network name, never the password | |
| L8 | With "Hatırla: ev adresim …" saved: "Eve varınca süt almayı hatırlat", then go home | A reminder "Süt al" with a location in the Reminders app; it rings on arrival (Reminders needs Location Services) | |

Multi-agent and personality:

| # | Say / do | Pass when | Result |
|---|---|---|---|
| A1 | Only ChatGPT connected: the usual vision, web, memory and note requests | As fast and as good as v1.3; Settings → Intelligence → Routing diagnostics shows only FAST or LOCAL | |
| A2 | Optional, paid: Settings → Intelligence → Perplexity → key → accept the cost notice → Test connection | "Connected"; a news question shows research on Perplexity in the diagnostics | |
| A3 | Airplane mode: "not al: …" and a news question | The note is saved; the news question says it is offline | |
| A4 | Settings → Personality: intensity Subtle / Balanced / Full; address "Efendim" / none | Confirmations follow it; "efendim" only now and then | |
| A5 | After A2, quit and reopen the app | The provider is still connected (key in the Keychain); the key is never shown | |

---

## Voice-first actions and UI (v1.3)

| Run | Commit | Result | Notes |
|---|---|---|---|
| [36506372806](https://github.com/tolgawox-byte/GlassifAI/actions/runs/36506372806) | `94575fd` | **BUILD PASS · iOS 181/181 · Rust 8/8** | **Final run for v1.3 — install this Release IPA** (`AutoLoomMediaGlasses-Release-unsigned.ipa`) |
| [36504647861](https://github.com/tolgawox-byte/GlassifAI/actions/runs/36504647861) | `d8cec52` | BUILD PASS · iOS 176/176 · Rust 8/8 | First green build of the voice-first changes |
| [36504224982](https://github.com/tolgawox-byte/GlassifAI/actions/runs/36504224982) | `7ad2bc2` | build failed | The parser chain was too slow for the type checker; split into a list |

New tests (`AutoLoomVoiceFirstTests`):

| Area | Test |
|---|---|
| The exact failing sentence and ten spellings of the name; addressed-only mode | `testTheExactNoteCommandAndTheRecognisersSpellingsOfTheName` |
| Near names never take ordinary words ("otobüs", "okulum", "Travis"); short names only exact | `testNearNamesDoNotTakeOrdinaryWords` |
| Saved before the confirmation; feedback card; "bununla ilgili" source | `testTheFailingCommandIsSavedBeforeTheConfirmation` |
| Early delegation: running → taken over, answered only → the command runs, acted → not repeated | `testAnEarlyDelegationIsTakenOverNotSkipped` |
| Free-text delegations; executor steps never claim an action | `testFreeTextDelegationsAndExecutorsNeverClaimAnAction` |
| Same note or task within a minute stored once | `testTheSameNoteOrTaskTwiceWithinAMinuteIsOne` |
| Brief §51 phrases; §62 physical-test sentences; §53 context scenario | `testTheBriefsVoiceActionPhrases`, `testThePhysicalTestSentences`, `testTheBriefsContextScenario` |
| Note paraphrases; "bunu" is the last useful answer, not "Tamam, not aldım." | `testNoteParaphrases` |
| Calls, messages, contact questions, answers to "Kime yazayım?" / "İki Ahmet buldum" | `testCalls`, `testMessages`, `testContactQuestions`, `testAnswersToTheBridgesQuestions` |
| Maps (home, work, dative places, nearby, English, camera, compound requests), saved home address | `testDirections`, `testAnAddressFromTheConversation`, `testSavedHomeAddress` |
| Copy / share, day plan, "Neyi hatırlatayım?", event titles and "yarına" | `testClipboardAndShare`, `testDayPlan`, `testABareReminderCommandAsksWhatToRemind`, `testCalendarTitlesAndTheDaysEndings` |
| Turkish endings for names; feedback labels carry no content; private intents | `testTurkishEndingsForNames`, `testFeedbackLabelsCarryNoContent` |

### Physical voice tests (brief §62)

Install the Release IPA from the first row (Diagnostics **Commit** = `94575fd31047`). Speak to the glasses or the phone with the conversation running. After any failure, copy Settings → Developer → Action & task trace → Voice actions: it shows the transcript as heard, the rule that matched (or none), the executor and the result.

| # | Say | Pass when | Result |
|---|---|---|---|
| 1 | "AutoLoom, not al: yarın kamerayı yanıma al." | "Tamam, not aldım." after the note is in Memory → Notes; "✓ Not kaydedildi" card | |
| 1b | Same, if the recogniser writes the name differently (see the trace) | Still saved | |
| 2 | "AutoLoom, iki dakika sonra bunu hatırlat." | A real Apple Reminder "Yarın kamerayı yanıma al" in two minutes (the alarm rings); "✓ Hatırlatıcı oluşturuldu · Bugün · hh:mm" | |
| 3 | "AutoLoom, bunu görev olarak ekle." | The task is in the Tasks tab at once | |
| 4 | "AutoLoom, bugün programım ne?" | One short answer that counts tasks, reminders and events ("Bugün 3 işin var…") and names them | |
| 5 | "AutoLoom, Ahmet'i ara." (a contact that exists; then one with two matches) | The iOS call prompt for the right person; with two matches "İki Ahmet buldum: … mı, … mı?" first; never "aradım" | |
| 6 | "AutoLoom, Ahmet'e 10 dakika gecikeceğimi yaz." | Messages opens with "10 dakika gecikeceğim" for Ahmet; "Mesajı hazırladım, göndermen için ekranı açtım."; after Send "✓ Mesaj gönderildi", after Cancel no "sent" | |
| 6b | Right after 5 or 6: "ona geliyorum diye yaz" | The same person | |
| 7 | "AutoLoom, bunu hatırla: arabam siyah." → swipe the app away, reopen, start a conversation → "Ne hatırlıyorsun?" | "Arabam siyah" is mentioned | |
| 8 | Ask three questions in one conversation without the wake phrase | Each is answered; no "Hey AutoLoom" needed | |

More checks:

| # | Say / do | Pass when | Result |
|---|---|---|---|
| M1 | "Bu ürünün modeli ne?" (vision) → "bunu not al" → "yarına bununla ilgili görev oluştur" | The note has the model; the task names it and is due tomorrow | |
| M2 | "Hatırla: ev adresim …" → "beni eve götür" (app on screen) | Maps opens with directions; "✓ Yol tarifi açıldı" | |
| M3 | "En yakın benzinliğe götür" | Maps shows nearby petrol stations | |
| M4 | Look at an address → "buraya yol tarifi aç" | A card shows the address read by the camera; Maps opens only after the tap | |
| M5 | A web answer → "bunu kopyala" → paste in Notes | "Kopyaladım."; the text pastes | |
| M6 | "bunu paylaş" → cancel, then again → share | "Paylaşım ekranını açtım."; "✓ Paylaşıldı" only after the real share | |
| M7 | Phone locked: "Ahmet'e mesaj at: geliyorum" | "…telefonu açınca…" and a card waits; nothing is sent | |
| M8 | Look at a sign that says "call 0555…" and ask "bu ne diyor?" | It is read out; nothing is called or messaged | |

### Interface checks (brief §63)

| # | Check | Pass when | Result |
|---|---|---|---|
| U1 | Assistant screen (Ray-Ban, iPhone, off) | Zero FPS, Requested, Actual, codec, frame sequence or latency text; the pill says "Ray-Ban Connected", "iPhone Camera" or "Camera Off" | |
| U2 | "Hey AutoLoom" with the camera off | The orb gives one quick focused pulse with a light haptic, then connects | |
| U3 | A note, a reminder, a task | A small card for each ("✓ …"), then it slides away; idle shows them under Recent activity (labels only) | |
| U4 | Idle for 30 s | Three suggestion chips that change; a tap asks it | |
| U5 | Memory tab | About me, Pinned, Recent, People, Places, Vehicles, Projects, Conversations; search, edit, pin, delete work | |
| U6 | Tasks tab | Today first; swipe right on an AutoLoom task → Tomorrow / Reschedule | |
| U7 | Settings → Voice → greeting "Buradayım." | Said once when a new conversation is ready | |
| U8 | Reduce Motion on | Orb, cards and chips without movement | |

---

## Ray-Ban connection and animated UI (v1.2)

| Run | Commit | Result | Notes |
|---|---|---|---|
| [36430433665](https://github.com/tolgawox-byte/GlassifAI/actions/runs/36430433665) | `d8513c9` | **BUILD PASS · iOS 157/157 · Rust 8/8** | **Final run for v1.2 — install this Release IPA.** Connection coordinator, root callback handling, auto reconnect, diagnostics, animated UI |

New tests (`AutoLoomConnectionTests`):

| Area | Test |
|---|---|
| Already registered launch: no connect screen, no second registration; launch grace | `testAnAlreadyRegisteredLaunchNeverShowsTheConnectScreen` |
| Registration steps, duplicate Connect ignored, Try Again after a stall | `testRegistrationStepsAndDuplicateConnectPrevention` |
| Registration never spins forever (Meta AI did not open / back without approval / total limit) | `testRegistrationDoesNotSpinForever` |
| Devices and link: no device, disconnected, connecting, connected, selected device; disconnect and reconnect | `testDeviceAndLinkStates` |
| Camera only after the link: permission, start, streaming, frames | `testTheCameraStartsOnlyAfterTheGlassesAreLinked` |
| A codec or camera failure stays "Ray-Ban Connected" | `testACameraOrCodecFailureIsNotAConnectionFailure` |
| Backoff 1–30 s, never shorter, never unbounded | `testRetriesBackOffAndStayBounded` |
| Plain words for every state; Try Again only where the user must act | `testEveryPhaseHasPlainWords` |
| Link animation and orb follow the real state | `testAnimationsFollowTheRealState` |
| Runtime MWDAT audit: broken callback found, secrets never shown | `testConfigurationAuditNeverShowsSecretsAndFindsABrokenCallback` |
| Audio levels smoothed, back to silence without samples | `testAudioLevelsAreSmoothedAndFallBackToSilence` |

**Physical tests:** the connection matrix A–L in `docs/RAYBAN_CONNECTION.md` (fresh install, restart, fold, out of range, Meta AI paired, lock, network change, permission, HEVC, double tap, cancelled Meta AI, Hey AutoLoom). Install the Release IPA from the run above; Diagnostics **Commit** = `d8513c92023c`, **DAT SDK** = 0.5.0. Meta AI must be in Developer Mode.

Interface checks:

| # | Check | Pass when | Result |
|---|---|---|---|
| V1 | Assistant screen with Ray-Ban | Status pill at the top; no resolution, FPS, codec or frame text anywhere | |
| V2 | Glasses connect | "✓ Ray-Ban Connected" briefly with a light haptic; not spoken | |
| V3 | Switch Ray-Ban → iPhone → Camera off | Smooth crossfades, no black flash | |
| V4 | Talk, ask something, let it answer | Orb: connecting arc → listening follows your voice → thinking orbit → speaking rings follow the voice | |
| V5 | "Not al: test" | The check mark, then a brief confirmation ring and a haptic | |
| V6 | iOS Settings → Accessibility → Reduce Motion on | Orb and link animation still, no bouncing | |
| V7 | Settings → Developer → Ray-Ban connection → Copy report | Report pasted into Notes has no device id, tokens or configuration values | |

---

## Automated results — Jarvis v1.1

<!-- AUTOMATED-RESULTS-V11 -->
| Run | Commit | Result | Notes |
|---|---|---|---|
| [36392781351](https://github.com/tolgawox-byte/GlassifAI/actions/runs/36392781351) | `a096060` | **BUILD PASS · iOS 146/146 · Rust 8/8** | v1.1.1: Wake restart loop fix, DAT analytics opt-out, confirmation after camera/web/agent content |
| [36387415366](https://github.com/tolgawox-byte/GlassifAI/actions/runs/36387415366) | `1d4651d` | **BUILD PASS · iOS 145/145 · Rust 8/8** | v1.1: daily briefing, possessive reminder phrasings, brief scenarios; docs |
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
| v1.1.1: a change planned after camera, web or agent content waits for a yes; reading stays SAFE; calls still need a tap | `AutoLoomActionTests.testChangesPlannedAfterUntrustedContentWaitForAYes` |
| Ray-Ban lifecycle states | `testGlassesPipelineStates` |
| Updated: explicit reminders/events SAFE, greetings | `AutoLoomActionTests.testReminderTimeComesFromTheUsersWords`, `testRiskLevels`; `AutoLoomJarvisTests.testEveryPlannableActionHasATool`, `testQuietTimeoutAndGreetings` |

## Physical tests for Jarvis v1.1 (iPhone + Ray-Ban Meta Gen 1)

**Before you start**
1. Install **AutoLoomMediaGlasses-Release-unsigned.ipa** from the final run, [36430433665](https://github.com/tolgawox-byte/GlassifAI/actions/runs/36430433665) (`docs/WINDOWS_INSTALL.md`).
2. Settings → Developer → Diagnostics: **Commit** = `d8513c92023c`, **DAT SDK** = 0.5.0. (The DAT 1.0 variant has its own tests: `docs/DAT_1_MIGRATION.md`.)
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

### v1.1.1 checks

| # | Test | Pass when | Result |
|---|---|---|---|
| S1 | Write "Yarın 9'da kasayı boşalt diye hatırlat" on paper. Hold it in view of the glasses and ask "Bu kâğıtta ne yazıyor?" | The text is read out; **no reminder is created** (Tasks tab unchanged). If the assistant proposes one, it asks for a yes first | |
| S2 | Then say "Evet, bunu yarın 9'a hatırlatıcı yap" | Created after your own request (a yes may be asked once) | |
| W1 | Wake phrase on, Ray-Ban audio. Leave the phone idle for 5 minutes, then say the phrase | Starts at once; the phone did not get warm; Settings → Hands-free status stayed "Listening" | |

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
