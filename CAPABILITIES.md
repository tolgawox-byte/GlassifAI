# AutoLoom Media Glasses — capability report

Branch `autoloom-glasses-jarvis-v1`. Status meanings:
- **WORKING**: verified on the physical iPhone and Ray-Ban Meta Gen 1 by the owner, and unchanged since.
- **PARTIAL**: works with a stated limit.
- **EXPERIMENTAL**: implemented and covered by automated tests in CI; behaviour that depends on the AI model still needs real use.
- **PHYSICAL TEST REQUIRED**: implemented and built in CI, but it depends on iOS, the audio hardware or the glasses in a way only the phone can confirm. `TEST_REPORT.md` has the test.
- **UNAVAILABLE**: not possible on the current platforms or connection, or deliberately not built.

Nothing is marked WORKING without a device test. Everything new in Jarvis v1 starts as EXPERIMENTAL or PHYSICAL TEST REQUIRED.

This app reaches ChatGPT through the account-backed endpoints OpenAI's Codex uses (`chatgpt.com/backend-api/codex/*`). Signing in does not unlock every feature of the ChatGPT app. No new paid service, API key or subscription is used.

## Voice and conversation

| Capability | Status | Notes |
|---|---|---|
| ChatGPT sign-in (device code) | **WORKING** | Unchanged |
| Realtime voice call (`gpt-live-1-codex`, WebRTC, frameless protocol) | **WORKING** | Call setup unchanged; the start now tries the full AutoLoom configuration first and records every fallback |
| Voice selection (Juniper, Maple, Spruce, Ember, Vale, Breeze, Arbor, Sol, Cove) | **PHYSICAL TEST REQUIRED** | Root cause fixed: earlier builds offered voices the protocol rejects, and the silent fallback always spoke with Juniper. See `docs/VOICE_SELECTION.md` |
| Selected vs Active voice, fallback reason | **EXPERIMENTAL** | Settings → Voice and Developer → Diagnostics. The bridge now reports the applied voice and model |
| Apply now (restart with the new voice) | **PHYSICAL TEST REQUIRED** | Resumes from the conversation summary |
| Preview voice | **PHYSICAL TEST REQUIRED** | Short line through the speakable context channel with the microphone off. Whether the model says the exact line must be heard |
| Natural Turkish, adaptive answer length | **EXPERIMENTAL** | New instructions; depends on the voice model |
| Stop words ("Dur", "Sus", "Bekle", "Hayır", "Bir dakika", "Başka bir şey soracağım") | **PHYSICAL TEST REQUIRED** | The app silences the answer locally at once; the server also stops an answer the user talks over |
| End commands ("Kapat", "Konuşmayı bitir", "Görüşürüz", "Jarvis stop") | **PHYSICAL TEST REQUIRED** | Ends after a short goodbye |
| Quiet-conversation timeout (15 s / 30 s / 1 min / 2 min / Never) | **EXPERIMENTAL** | Default 2 minutes; anything in progress counts as activity |
| "What can you do?" answered briefly | **EXPERIMENTAL** | Instruction-level |
| Auto-reconnect after a network or audio drop | **EXPERIMENTAL** | Unchanged from vNext |

## Assistant name, wake and hands-free

| Capability | Status | Notes |
|---|---|---|
| Assistant name (default AutoLoom) | **EXPERIMENTAL** | Used in the instructions, greetings and stop commands |
| Wake phrase setting ("Hey AutoLoom", "Jarvis", custom) | **PHYSICAL TEST REQUIRED** | On-device speech recognition; tolerant of split words |
| State A — conversation running, address by name | **EXPERIMENTAL** | No wake phrase needed |
| State B — app open, wake phrase armed | **PHYSICAL TEST REQUIRED** | |
| State C — Hands-Free Ready in the background or locked | **PHYSICAL TEST REQUIRED** | Opt-in, time-limited, orange microphone dot; iOS may stop it, then the app pauses honestly |
| State D — listening only while the glasses are connected | **PHYSICAL TEST REQUIRED** | Driven by the DAT `LinkState` event. DAT 0.5.0 has no worn/unworn event |
| State E — "Hey Siri, start AutoLoom" / personal Siri shortcut | **EXPERIMENTAL** | App Shortcuts |
| Greeting (Minimal / Normal / Jarvis style / Custom) and activation feedback (Off / Subtle chime / Spoken greeting) | **PHYSICAL TEST REQUIRED** | Hands-free starts only; button starts stay quiet |
| "Hey Meta, start AutoLoom" | **UNAVAILABLE** | Needs DAT 1.0, glasses firmware V128, Meta AI V290 and Voice Invocation approval in the Wearables Developer Center. See `docs/WAKE_INVOCATION.md` |
| A system-wide custom wake word | **UNAVAILABLE** | Not offered by iOS or the Meta glasses to third-party apps |

## Memory and notes

| Capability | Status | Notes |
|---|---|---|
| AutoLoom Memory (SwiftData on this iPhone) | **EXPERIMENTAL** | Kinds FACT / EPISODE / NOTE / VISUAL_MEMORY / PREFERENCE / TASK_CONTEXT. Explicit saving only |
| Memory tab (search, Pinned / Recent / People / Places / Vehicles / Other, edit, pin, forget, delete all) | **PHYSICAL TEST REQUIRED** | UI builds in CI; needs a look on the phone |
| Search | **PARTIAL** | Turkish: word stems and folded letters. English: plus Apple's on-device sentence embedding. No Turkish embedding exists on iOS |
| Visual memory ("bunu hatırla") | **PHYSICAL TEST REQUIRED** | Opt-in; a description is saved; photo and place only if turned on |
| Forgetting by voice | **EXPERIMENTAL** | Needs a yes (CONFIRM) |
| AutoLoom Notes (title, text, tags, links, place) | **EXPERIMENTAL** | Memory tab → Notes; share to Apple Notes |
| Apple Notes direct write | **UNAVAILABLE** | No public API; Share is offered |
| Migration of earlier memory.json / notes.json | **EXPERIMENTAL** | Imported once; the old files are kept as backups |
| ChatGPT account memory or chat history | **UNAVAILABLE** | Not reachable through this connection |

## iPhone tools

| Capability | Status | Notes |
|---|---|---|
| Deterministic time parsing (Turkish and English) | **EXPERIMENTAL** | About 40 unit-tested phrases, including words that must not be read as times. The model copies the user's words; model timestamps are ignored; morning/evening is asked when both fit |
| Reminders (create, list) | **PHYSICAL TEST REQUIRED** | EventKit; CONFIRM; success only after iOS saves it |
| Calendar (today, upcoming, create) | **PHYSICAL TEST REQUIRED** | CONFIRM for creating |
| Tasks tab (Today / Upcoming / Completed, create, complete, delete with confirmation, reschedule) | **PHYSICAL TEST REQUIRED** | On Apple Reminders |
| Local notifications | **PHYSICAL TEST REQUIRED** | SAFE; listed in the Tasks tab, cancellable |
| Contacts lookup (for calls and messages) | **PHYSICAL TEST REQUIRED** | Read-only; asks which one when several match |
| Maps, open link, share, call, message | **EXPERIMENTAL** | STRONG CONFIRM: only a tap confirms |
| Clipboard, notes | **EXPERIMENTAL** | SAFE |
| Tool registry with per-tool switches | **EXPERIMENTAL** | Settings → Tools |
| Deleting calendar events by voice | **UNAVAILABLE** | Not built; reminders can be deleted in the Tasks tab with confirmation |
| Email, purchases, payments, deleting data, posting | **UNAVAILABLE** | Refused locally before any model call |
| App Intents: Start Conversation, Ask AutoLoom, Create AutoLoom Note, Start Live Vision | **EXPERIMENTAL** | |
| OpenClaw agent gateway | **EXPERIMENTAL** (optional) | Off by default |

## Camera and vision

| Capability | Status | Notes |
|---|---|---|
| iPhone camera vision | **WORKING** (earlier pipeline) / **EXPERIMENTAL** (profiles, OCR, crop) | |
| Ray-Ban preview and vision | **WORKING** on DAT 0.4.0 / **EXPERIMENTAL** on DAT 0.5.0 | Pipeline unchanged since vNext |
| High-detail retry before "move closer" | **EXPERIMENTAL** | An unclear standard answer is retried with the best frame, OCR, a zoomed crop and upscaling |
| Specific, non-repeating reposition advice | **EXPERIMENTAL** | One specific tip; not repeated within 90 s |
| Source vs encoded resolution in diagnostics | **EXPERIMENTAL** | Upscaling is labelled, never presented as extra detail |
| Live Vision | **EXPERIMENTAL** | Adaptive, time-limited silent notes |
| Ray-Ban full-resolution photo (`Camera.photo`) | **UNAVAILABLE** in this build | Needs DAT 1.0 and firmware V128. Plan: `docs/DAT_1_MIGRATION.md` |
| Face recognition | **UNAVAILABLE** | Not built |

## Interface

| Capability | Status | Notes |
|---|---|---|
| Tabs: Assistant, Memory, Tasks, Settings | **PHYSICAL TEST REQUIRED** | |
| Assistant screen: state word, camera indicator, camera view or orb, voice button | **PHYSICAL TEST REQUIRED** | No FPS or frame numbers unless Developer → overlay is on |
| Seven-page onboarding | **PHYSICAL TEST REQUIRED** | Shown once |
| Privacy center with every permission's state | **PHYSICAL TEST REQUIRED** | |
| Friendly errors | **EXPERIMENTAL** | Mapping unit-tested; technical text in Developer |
| Turkish / English interface | **PARTIAL** | Main screens and settings; some diagnostics stay English |
| Developer: diagnostics, copyable sanitized task trace | **EXPERIMENTAL** | |

## Web, models, battery

| Capability | Status | Notes |
|---|---|---|
| Live web search with sources; vision + web; reports | **EXPERIMENTAL** | Unchanged from vNext |
| Model discovery and task routing | **EXPERIMENTAL** | Unchanged |
| GPT-6 Astra | **EXPERIMENTAL** (detection) | Used only if this connection lists it |
| Battery states (Idle / Hands-Free Ready / Conversation / Live Vision) | **PHYSICAL TEST REQUIRED** | Screen may sleep when idle; an idle glasses stream pauses in the background; Hands-Free Ready is time-limited |
| Offline mode | **UNAVAILABLE** | Not built |
