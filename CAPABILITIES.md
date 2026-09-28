# AutoLoom Media Glasses — capability report

Branch `autoloom-glasses-dat1`: Jarvis v1.1 on Meta DAT **1.0.0**, a separate variant of `autoloom-glasses-jarvis-v1` (DAT 0.5.0) for glasses with firmware V128 and Meta AI V290. What differs is in `docs/DAT_1_MIGRATION.md`; nothing in this variant has been tested on glasses. Status meanings:
- **WORKING**: verified on the physical iPhone and Ray-Ban Meta Gen 1 by the owner, and unchanged since.
- **PARTIAL**: works with a stated limit.
- **EXPERIMENTAL**: implemented and covered by automated tests in CI; behaviour that depends on the AI model still needs real use.
- **PHYSICAL TEST REQUIRED**: implemented and built in CI, but it depends on iOS, the audio hardware or the glasses in a way only the phone can confirm. `TEST_REPORT.md` has the test.
- **UNAVAILABLE**: not possible on the current platforms or connection, or deliberately not built.

Nothing is marked WORKING without a device test. Everything new in Jarvis v1 and v1.1 starts as EXPERIMENTAL or PHYSICAL TEST REQUIRED.

This app reaches ChatGPT through the account-backed endpoints OpenAI's Codex uses (`chatgpt.com/backend-api/codex/*`). Signing in does not unlock every feature of the ChatGPT app. No new paid service, API key or subscription is used.

## Voice actions (new in v1.1)

| Capability | Status | Notes |
|---|---|---|
| Voice action intent bridge (LEVEL 1 parser on the final transcript) | **EXPERIMENTAL** | Notes, memory, name, reminders, notifications, AutoLoom tasks, calendar read/create, task lists, routines, translation, yes/no/sabah/akşam. Unit-tested; the voice model is no longer needed to pick a delegation |
| LEVEL 2 structured classification | **EXPERIMENTAL** | Only when the kind is certain but details are missing; strict JSON, times still from the user's words |
| One answer per command (model reply muted, app result spoken) | **PHYSICAL TEST REQUIRED** | Depends on event timing on the real call; see `docs/VOICE_ARCHITECTURE.md` |
| "Jarvis, not al: cuma Mercedes gelecek." → saved, then "Tamam, not aldım." | **PHYSICAL TEST REQUIRED** | Saved before the confirmation; unit test covers the saving |
| Permission retry (command kept 10 min, runs after the permission) | **PHYSICAL TEST REQUIRED** | iOS asks for permissions only on screen |
| Action trace (transcript → intent → parser → permission → executor → result) | **EXPERIMENTAL** | Developer → Action & task trace |
| Text from the camera/OCR/web triggering an action | **UNAVAILABLE by design** | Only the user's own words reach the parser |

## Voice and conversation

| Capability | Status | Notes |
|---|---|---|
| ChatGPT sign-in (device code) | **WORKING** | Unchanged |
| Realtime voice call (`gpt-live-1-codex`, WebRTC, frameless protocol) | **WORKING** | Call setup unchanged; the start tries the full AutoLoom configuration first and records every fallback |
| Voice selection (Juniper, Maple, Spruce, Ember, Vale, Breeze, Arbor, Sol, Cove) | **PHYSICAL TEST REQUIRED** | Root cause fixed in v1: earlier builds offered voices the protocol rejects. See `docs/VOICE_SELECTION.md` |
| Selected vs Active voice, fallback reason | **EXPERIMENTAL** | Settings → Voice and Developer → Voice diagnostics |
| Jarvis Style (Cove + persona, a style not a clone) | **EXPERIMENTAL** | No actor imitation, no bundled audio. "Composed and direct" is ChatGPT's description; an accent is not promised |
| Connection-ready acknowledgement ("Bağlandım, dinliyorum." / chime), once per new conversation | **PHYSICAL TEST REQUIRED** | Only after ChatGPT, WebRTC, the data channel and the audio route are ready. Setting: Chime + voice / Voice only / Chime only / Off |
| Connection failure feedback ("Bağlantı kurulamadı.", "Ray-Ban bağlantısı koptu.") | **PHYSICAL TEST REQUIRED** | Low tone + on-device Apple voice |
| Apply now (restart with the new voice) | **PHYSICAL TEST REQUIRED** | No new greeting |
| Preview voice | **PHYSICAL TEST REQUIRED** | Now phrased as an app message so the model says the line instead of answering it |
| Natural Turkish, no canned openers, adaptive length | **EXPERIMENTAL** | Instruction-level; depends on the voice model |
| Stop words and end commands | **PHYSICAL TEST REQUIRED** | Unchanged |
| Quiet-conversation timeout | **EXPERIMENTAL** | Unchanged |
| Auto-reconnect | **EXPERIMENTAL** | A subtle chime when it works, the failure announcement when the budget is used |

## Assistant name, wake and hands-free

| Capability | Status | Notes |
|---|---|---|
| Assistant name (default AutoLoom) | **EXPERIMENTAL** | |
| Wake phrase ("Hey AutoLoom", "Jarvis", "Hey Jarvis", custom) | **PHYSICAL TEST REQUIRED** | On-device speech recognition |
| States A–E (conversation, app open, Hands-Free Ready, glasses arming, Siri) | **PHYSICAL TEST REQUIRED** / **EXPERIMENTAL** (A, E) | State D arms when the glasses are worn (DAT 1.0), falling back to the `LinkState` event while the worn state is unknown |
| Arming by wearing the glasses (`donState`) | **PHYSICAL TEST REQUIRED** | DAT 1.0 `DeviceState.donState` and `hingeState`; test D9 in `docs/DAT_1_MIGRATION.md` |
| "Hey Meta, start AutoLoom" | **EXPERIMENTAL** (waits for Meta approval) | The `VoiceInvocationsStream` listener is built in; Meta delivers launches only after it approves Voice Invocation for this app in the Wearables Developer Center (owner action), with firmware V128 and Meta AI V290 |
| A system-wide custom wake word | **UNAVAILABLE** | Not offered to third-party apps |
| Routines: "İşe başlıyorum" (today's tasks + calendar + arms Hands-Free Ready), "günün özeti" | **EXPERIMENTAL** | Reads only phone data; weather/news not included |
| Daily briefing on the first conversation of the day | **EXPERIMENTAL** (off by default) | Settings → Name & conversation → Daily briefing: once a day, after the ready greeting, from the calendar, reminders and AutoLoom tasks on this iPhone; also on request ("günün özeti") |

## Memory, notes and tasks

| Capability | Status | Notes |
|---|---|---|
| AutoLoom Memory (SwiftData on this iPhone) | **EXPERIMENTAL** | Types PROFILE, PREFERENCE, FACT, PERSON, PLACE, VEHICLE, EPISODE, NOTE, TASK_CONTEXT, VISUAL_MEMORY, CONVERSATION_SUMMARY |
| User profile ("Benim adım Tolga" → "Benim adım ne?") | **EXPERIMENTAL** | Only what the user says or types; used "naturally, not in every sentence" |
| Conversation memory (summaries of meaningful conversations) | **EXPERIMENTAL** | On by default; summaries only, never transcripts; searchable; the latest goes into the next conversation |
| Smart Memory (offers to remember, saves only after a yes) | **EXPERIMENTAL** | Off by default |
| Retrieval: Turkish stems, English on-device embedding, exact names, pinned, recency | **PARTIAL** | No Turkish sentence embedding exists on iOS |
| Memory tab (About me, Pinned, Recent, People, Places, Vehicles, Conversations, Visual; edit, pin, forget, Clear all) | **PHYSICAL TEST REQUIRED** | |
| Visual memory ("bunu hatırla", "anahtarımı buraya bıraktığımı hatırla") | **PHYSICAL TEST REQUIRED** | Opt-in; one frame when asked, never continuous |
| AutoLoom Notes | **EXPERIMENTAL** | Separate from memory; share to Apple Notes |
| AutoLoom Tasks (Today / Upcoming / Completed, optional alert) | **EXPERIMENTAL** | Local, next to Apple Reminders in the Tasks tab |
| Apple Notes direct write | **UNAVAILABLE** | No public API; Share is offered |
| ChatGPT account memory or chat history | **UNAVAILABLE** | Not reachable; the assistant says so |

## iPhone tools

| Capability | Status | Notes |
|---|---|---|
| Deterministic time parsing (Turkish and English) | **EXPERIMENTAL** | 9–11 read as morning, 1–5 as afternoon; 6–8 asked; "cuma 3'e"; model timestamps ignored |
| Reminders (create, list) | **PHYSICAL TEST REQUIRED** | EventKit; SAFE for an explicit request; success only after iOS saves it |
| Calendar (today, tomorrow, upcoming, create) | **PHYSICAL TEST REQUIRED** | SAFE for an explicit request; an unclear time is asked |
| Tasks tab | **PHYSICAL TEST REQUIRED** | AutoLoom tasks + Apple Reminders; refreshes right after a spoken action |
| Local notifications | **PHYSICAL TEST REQUIRED** | SAFE |
| Contacts lookup, maps, links, share, call, message | **EXPERIMENTAL** / **PHYSICAL TEST REQUIRED** | Unchanged; calls/messages/sharing need a tap |
| Email, purchases, payments, deleting data, posting | **UNAVAILABLE** | Refused locally |
| Camera, web or agent text never triggers a change (brief §70–71) | **EXPERIMENTAL** (v1.1.1) | Enforced in code: a change the planner proposes in a turn that brought camera, web or agent content waits for a spoken yes or a tap; see `docs/NATIVE_TOOLS.md` |
| App Intents: Start Conversation, Ask AutoLoom, Create AutoLoom Note, Start Live Vision | **EXPERIMENTAL** | "Ask AutoLoom" now also runs commands ("not al: …") |
| OpenClaw agent gateway | **EXPERIMENTAL** (optional) | Off by default |

## Camera and vision

| Capability | Status | Notes |
|---|---|---|
| iPhone camera vision | **WORKING** (earlier pipeline) / **EXPERIMENTAL** (profiles, OCR, crop) | |
| Ray-Ban preview and vision (foreground) | **PHYSICAL TEST REQUIRED** on DAT 1.0 (this build) | WORKING on DAT 0.4.0, EXPERIMENTAL on DAT 0.5.0. DAT 1.0 streams over Wi-Fi and needs the Local Network permission |
| Ray-Ban vision with the iPhone locked | **PHYSICAL TEST REQUIRED** | Root causes fixed (see `docs/BACKGROUND_STREAMING.md`): no background pause, no background fallback to raw, background-safe decoder, `bluetooth-central`. Meta's own sample stops decoding in the background, so the test decides |
| Lifecycle states (ForegroundActive, BackgroundStreaming, ScreenLockedStreaming, Suspended, Disconnected) | **EXPERIMENTAL** | Transitions logged with frame counters |
| Camera source proof per request (pipeline state, transport, sequence, age, dimensions) | **EXPERIMENTAL** | Metadata only, never the image |
| Camera diagnostics screen | **EXPERIMENTAL** | All technical camera numbers live here; none on the Assistant screen |
| High-detail retry before "move closer" | **EXPERIMENTAL** | Best frame, OCR, zoomed crop, upscaling |
| Translation of what is in view ("bunu Türkçeye çevir") | **EXPERIMENTAL** | High-detail read + translation |
| Ray-Ban full-resolution photo (`Camera.photo`) | **PHYSICAL TEST REQUIRED** (Meta beta API) | High-detail requests take a standalone photo (Meta: 4032×3024), with one startup retry and the best video frame as fallback; see `docs/DAT_1_MIGRATION.md` |
| Face recognition | **UNAVAILABLE** | Not built |

## Interface

| Capability | Status | Notes |
|---|---|---|
| Tabs: Assistant, Memory, Tasks, Settings | **PHYSICAL TEST REQUIRED** | |
| Assistant screen without any technical camera text | **PHYSICAL TEST REQUIRED** | The overlay switch was removed |
| Status words incl. "Saving" | **EXPERIMENTAL** | Unit-tested mapping |
| Settings: Assistant, Voice, AI, Vision, Memory, Tools, Privacy, Developer (Diagnostics, Action & task trace, Voice diagnostics, Camera diagnostics), About | **PHYSICAL TEST REQUIRED** | |
| Turkish / English interface | **PARTIAL** | Main screens and settings; diagnostics stay English |

## Web, models, battery

| Capability | Status | Notes |
|---|---|---|
| Live web search with sources; vision + web; reports | **EXPERIMENTAL** | Unchanged |
| Model discovery and task routing | **EXPERIMENTAL** | Unchanged |
| Battery | **PHYSICAL TEST REQUIRED** | The glasses stream no longer pauses in the background (needed for locked-screen vision), so it uses more battery while the glasses stream; Live Vision and Hands-Free Ready stay time-limited |
| Offline mode | **UNAVAILABLE** | Not built |
| Meta DAT SDK analytics and SDK crash capture | **OFF** (v1.1.1) | Opted out in `Info.plist`; both are on by default in the SDK |
