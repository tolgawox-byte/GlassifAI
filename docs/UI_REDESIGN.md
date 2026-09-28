# Interface redesign (Jarvis v1, updated in v1.1)

The vNext main screen looked like a developer console: FPS, frame counters, audio routes and a red "hang up" button. Jarvis v1 turns it into a consumer app. All technical information moved to Settings → Developer.

## Tabs

| Tab | Content |
|---|---|
| **Assistant** | The conversation screen (below). While Ray-Ban is chosen but not connected, the glasses setup appears here instead |
| **Memory** | Search (memories, notes, tasks); About me / Pinned / Recent / People / Places / Vehicles / Other / Conversations / Visual memories; notes; edit, pin, forget; Clear all AutoLoom memory |
| **Tasks** | AutoLoom tasks and Apple Reminders together: Today / Upcoming / Completed; create, edit, complete, delete, reschedule; scheduled notifications |
| **Settings** | ASSISTANT, VOICE, AI, VISION, MEMORY, TOOLS, PRIVACY, DEVELOPER, ABOUT |

## Assistant screen

```
┌────────────────────────────────────────────┐
│ [AL]  AutoLoom Media Glasses   [👓 Ray-Ban ●]│  brand · camera indicator (tap to switch)
│       ● Listening                            │  one state word
│  (👁 Live Vision) (“Hey Jarvis” deyin)       │  chips only when relevant
│                                              │
│        camera view  — or —  animated orb     │
│                                              │
│  [pending action card]                       │
│  you: "arabam nerede?"                       │  captions
│  AutoLoom: "Otoparkın P2 katında…"            │
│  [⌨]            ( orb / ◉ )            [🎙] │  voice area, not a call UI
│               Tap to talk                    │
└────────────────────────────────────────────┘
```

- **State words**: Ready, Connecting, Listening, Thinking, Looking, Reading, Searching, Remembering, **Saving** (a note, reminder, task or event the user asked for), Working on it, Speaking, Microphone off, or a friendly error title. They come from the real session and task state (`AssistantPresence.resolve`). A reply the app mutes (because it handles the command itself) is neither captioned nor shown as "Speaking".
- **Camera indicator**: source icon and name with a green (frames arriving) or orange (waiting) dot; tapping it opens a menu to switch camera.
- **Camera off**: an animated orb (`AssistantOrb`) that breathes, pulses or spins with the state; it respects Reduce Motion.
- **Voice button**: a blue circle to start; during a conversation the orb itself, tap to end. The right-hand button changes with context: cancel task, stop speaking, mute.
- **Errors**: `FriendlyError` turns technical text into a title and one line ("No internet connection — check Wi-Fi…"). The original text is in Developer → Diagnostics.
- **No technical camera text at all.** Requested/actual resolution, FPS, frame counts, codec, frame age and processing times were removed from the Assistant screen; the old "Camera metrics overlay" switch is gone. They live only in Settings → Developer → Camera diagnostics.
- **Notices**: a short chip for events such as "ended after a quiet period" or a command that finished after a permission was granted.
- The screen may sleep when no conversation is running (it stays on during a conversation).

## Onboarding

Seven pages, shown once before sign-in: Welcome · Just talk · It sees what you see · It remembers when you ask · It gets things done · Private by design · Meet <name>. No permission is requested during onboarding; each is asked when a feature first needs it.

## Settings map

| Section | Screens |
|---|---|
| Assistant | Name & conversation (name, language, answer length, quiet timeout, stop commands, addressed-only) · Wake phrase & hands-free (phrase, Hands-Free Ready, glasses arming, connection feedback) · Audio |
| Voice | Voice (selected / active / style, Jarvis Style, voices with preview, connection feedback and phrase, language, conversation tone, offline Apple voice) · Connection feedback (shortcut to the same screen) |
| AI | ChatGPT account · Intelligence (automatic or pinned models) · Web search |
| Vision | Camera & Ray-Ban (source, quality, text detail, enlarge, Live Vision limit, stream profile, transport, preview, vision image) |
| Memory | Memory on/off, conversation summaries, Smart Memory, visual memories, photos, place, Clear all AutoLoom memory |
| Tools | Allow iPhone actions; Reminders, Calendar, AutoLoom Notes, Memory, Notifications, Contacts, Maps, links, clipboard, share, phone, messages — each with its confirmation level, permission state and switch; AutoLoom Tasks and Siri & Shortcuts (always available); agent gateway |
| Privacy | Privacy center: what leaves the phone, what is stored, every permission, delete all local data |
| Developer | Diagnostics (models and system) · Action & task trace (voice actions + tasks, copy sanitized) · Voice diagnostics (connection phases, route, voice used) · Camera diagnostics (pipeline state, frames, decoder, transitions) |
| About | Brand, version, build, what it can do, licenses |

## Language

`L.t(english, turkish)` picks Turkish when the assistant language is Turkish, or when it is "match my language" on a Turkish iPhone. Main screens, settings, onboarding and errors are bilingual; low-level diagnostics stay English.

## Accessibility

Every icon button has a label; state changes give haptic feedback; the orb and transitions follow Reduce Motion; captions use Dynamic Type text styles.
