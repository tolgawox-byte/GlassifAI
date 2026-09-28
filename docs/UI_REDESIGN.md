# Interface redesign (Jarvis v1, updated in v1.1 and v1.2)

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
│ [AL]  AutoLoom Media Glasses   [👓 Ray-Ban ●]│  brand · camera switch
│ (● Ray-Ban Connected)  Starting camera…      │  v1.2: Ray-Ban status pill (glasses only)
│  (👁 Live Vision) (“Hey Jarvis” deyin)       │  chips only when relevant
│                                              │
│   camera edge to edge — or — animated orb    │  crossfade between sources
│                                              │
│  [pending action card]                       │
│  you: "arabam nerede?"                       │  captions
│  AutoLoom: "Otoparkın P2 katında…"            │
│              (● Listening)                   │  v1.2: the state word, above the controls
│  [⌨]            ( orb / ◉ )            [🎙] │  voice area, not a call UI
│               Tap to talk                    │
└────────────────────────────────────────────┘
```

### v1.2: connection, motion and feedback

- **Ray-Ban status pill** (top): "Ray-Ban Connected", "Connecting…", "Wake your glasses", "Permission needed" or "Ray-Ban unavailable". Its dot pulses only while something is in progress. The camera state appears as a short second line, for example "Starting camera…". When recovery needs the user, the pill becomes the one Try Again button. Everything comes from `WearableConnectionCoordinator` (`docs/RAYBAN_CONNECTION.md`).
- **"✓ Ray-Ban Connected"**: a short confirmation with a light haptic when the glasses link comes up, at most every 30 s, never spoken.
- **Glasses view before the first frame**: the link animation, drawn natively with `Canvas`, follows the real phase:
  - *searching*: a rotating, pulsing ring;
  - *found*: the ring contracts into the centre;
  - *connected*: a short glow expansion;
  - *attention*: a restrained amber pulse;
  - *idle*: a soft ring.
  It never shows "connected" before frames arrive.
- **No frozen frame**: when the glasses stop sending for 2 s, a soft material veil with "Glasses view paused" covers the last frame.
- **Camera transitions**: Ray-Ban ↔ iPhone ↔ Camera off crossfade (0.4 s). The connect screen and the Assistant crossfade too.
- **The orb** (`AssistantOrb`, one `Canvas` pass per frame, no image assets, no stacked blur layers):

  | State | Motion |
  |---|---|
  | Ready | Very slow breathing |
  | Connecting | Rotating arc with a faint pulsing ring |
  | Listening | Core and ring follow the microphone level |
  | Thinking | Slow orbital highlights |
  | Searching | The same orbit, faster, three highlights |
  | Looking / Reading | Soft radar-like pulses |
  | Speaking | Rings follow the assistant's voice level |
  | Saving | A check mark draws itself |
  | Success | A brief blue-silver ring after a save that finished |
  | Microphone off | Grey, almost still |
  | Error | Restrained amber |

  The microphone and voice levels come from WebRTC's own `audioLevel` statistics, sampled about eight times a second and only while the app is on screen. The orb reads them each frame without refreshing the rest of the screen. Each state comes from the real session and task state: nothing looks like listening before the realtime audio is ready, and the confirmation only follows a save that finished.
- **Microinteractions**: buttons scale slightly when pressed, and symbols morph (mic ↔ mic off, eye ↔ eye filled, camera source). Haptics fire for the glasses connecting, the wake phrase being heard, a finished save, the conversation becoming ready, errors and tab changes.
- **Performance**: camera frames are never drawn through SwiftUI images (the low-latency preview layer is unchanged), no image processing runs on the main actor for the UI, and animations are gradients rather than blur layers.
- **Reduce Motion**: the orb and the link animation become still images of the same state, with no scaling on press and no slides. Crossfades become instant.

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
| Vision | Camera & Ray-Ban (source, quality, text detail, enlarge, Live Vision limit, stream profile, transport, preview, vision image) · **Ray-Ban glasses** (v1.2: status, Try Again, Connect, Forget glasses with confirmation) |
| Memory | Memory on/off, conversation summaries, Smart Memory, visual memories, photos, place, Clear all AutoLoom memory |
| Tools | Allow iPhone actions; Reminders, Calendar, AutoLoom Notes, Memory, Notifications, Contacts, Maps, links, clipboard, share, phone, messages — each with its confirmation level, permission state and switch; AutoLoom Tasks and Siri & Shortcuts (always available); agent gateway |
| Privacy | Privacy center: what leaves the phone, what is stored, every permission, delete all local data |
| Developer | Diagnostics (models and system) · Action & task trace (voice actions + tasks, copy sanitized) · Voice diagnostics (connection phases, route, voice used) · Camera diagnostics (pipeline state, frames, decoder, transitions) · **Ray-Ban connection** (v1.2: every connection sub-state, runtime configuration, transitions, copy sanitized report, developer actions) |
| About | Brand, version, build, what it can do, licenses |

## Language

`L.t(english, turkish)` picks Turkish when the assistant language is Turkish, or when it is "match my language" on a Turkish iPhone. Main screens, settings, onboarding and errors are bilingual; low-level diagnostics stay English.

## Accessibility

Every icon button has a label; state changes give haptic feedback; the orb and transitions follow Reduce Motion; captions use Dynamic Type text styles.
