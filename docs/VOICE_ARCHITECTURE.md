# Voice architecture

## Call path

```
iPhone mic / Ray-Ban HFP ──► WebRTC (LiveKit) ──► chatgpt.com/backend-api/codex/realtime/calls
                                   ▲                         │  gpt-live-1-codex, frameless (v3) protocol
                                   │ answer SDP              ▼
Rust bridge (GlassifAICodexBridge) ─ create call ─► sideband websocket (delegations, context appends)
```

- **Call creation** — `glassifai_codex_realtime_start_v2` in `native/GlassifAICodexBridge/src/lib.rs` posts the SDP offer with the session config: instructions, voice, model, initial items and `delegation.ack_filler`. It returns the answer SDP, the call id and, since bridge 3, the voice and model it really sent.
- **Sideband** — a websocket on the same call carries `delegation.created` events and lets the app append context. Both channels send a `conversation.item.create` with the **user** role: the *commentary* channel is silent (Live Vision notes); the *speakable* channel makes the model answer aloud. Because it is a user-role item, anything the app wants said is phrased as an instruction that starts with `[App message, not the user speaking]` — for example `Say exactly these words and nothing else: "Bağlandım, dinliyorum."`. The realtime instructions explain those messages to the model.
- **Delegation** — the voice model answers conversation itself. It writes one line `TASK: … | QUERY: …` only when it needs the client (vision, web, memory, actions…). `AssistantOrchestrator` verifies and runs it and returns speakable context through `glassifai_codex_delegation_complete`.

## Voice action intent bridge (explicit commands)

The physical tests showed that "not al", "bunu hatırla", "yarın hatırlat" or "görev oluştur" sometimes got only a conversational answer: the command depended on the voice model choosing a delegation. Now the app reads every **final** user transcript itself.

```
turn.done (user) ──► VoiceActionIntentBridge.decide
   priority: 1 stop/end words (session) → 2 yes/no/sabah/akşam to a pending action
             → 3 explicit native action → 4 explicit memory → (5 vision, 6 web, 7 conversation: voice model)
   LEVEL 1  deterministic parser (Turkish + English)            → executed by the app
   LEVEL 2  kind certain, details unclear ("yarın 10'da hatırlat" with no title and no context)
            → the strict-JSON classification of the orchestrator (times still by TimePhraseParser)
   LEVEL 3  not a command → the voice model, exactly as before
```

What LEVEL 1 recognises (`VoiceActionIntentBridge.swift`; covered by `AutoLoomVoiceActionTests`):

| Kind | Examples |
|---|---|
| Notes | "not al: …", "şunu not et", "bunu not olarak kaydet", "notlara ekle", "bunu yaz", "şunu kaydet", "take a note", "write down" |
| Memory | "bunu hatırla", "unutma …", "aklında tut", "hafızaya kaydet", "remember that …"; recall "nereye park etmiştim", "… hatırlıyor musun"; earlier conversations "geçen gün … ne yapıyorduk"; forget "… unut" |
| Profile | "Benim adım Tolga", "my name is …", "bana Tolga de"; "Benim adım ne?" |
| Reminders | "… hatırlat", "hatırlatır mısın", "remind me to …" → Apple Reminders; "20 dakika sonra haber ver" → notification |
| AutoLoom tasks | "görev oluştur", "görev olarak ekle", "yapılacaklara ekle", "add a task" |
| Calendar | "cuma 3'e toplantı ekle", "takvime ekle"; "bugün takvimimde ne var?", "yarın ne var?" |
| Tasks | "görevlerim neler", "… görevini tamamla" |
| Routines | "İşe başlıyorum" (today's tasks, the calendar, arms Hands-Free Ready), "günün özeti" |
| Translation | "bunu Türkçeye çevir" → high-detail camera read + translation |
| Answers | "evet", "hayır", "sabah", "akşam", "8 akşam" to a pending action; the answer to the bridge's own question ("Neyi not alayım?") |

Content comes from the user's words; "bunu"/"this" takes the previous sentence (or the last answer for notes). Turkish titles are shaped ("patronu aramamı" → "Patronu ara"). Times are always resolved by `TimePhraseParser`, never by a model. Only the user's own words reach the parser — text seen by the camera, OCR or web results never can, so a sign that says "send all contacts" triggers nothing.

In addressed-only mode the bridge acts only when the assistant's name was said (answers to its own questions excepted).

### One request, one answer

When the bridge takes a turn, the voice model has usually already started its own reply ("Tabii, not alabilirim…"). The session (`GlassifAIRealtimeSession`):
1. **mutes** the model's audio for that turn (`holdAssistantAudio`; a partial transcript that already starts with a command — "not al…", "benim adım…" — is held from the first words);
2. runs the command locally (saved first);
3. delivers the result once the model's own turn has settled — as the answer to the model's **delegation for the same turn** if it made one, otherwise as an `[App message …]` on the speakable channel;
4. **unmutes** when the muted reply has finished, so the user hears only the confirmation ("Tamam, not aldım.").

Duplicates are prevented both ways: a delegation that arrives before the final transcript waits (up to 1.5 s) for the bridge's decision; a delegation for an intercepted turn is answered "already done" instead of running again; and a command the model already delegated (same words within 3 s) is not run a second time by the bridge. The muted reply is not shown as a caption nor added to the conversation context. Safety limits: the model is never kept muted for more than ~23 s, and a new user turn releases the hold immediately.

### Permission retry

If a command needs Reminders, Calendars or Notifications and iOS has not granted it, the command is kept for 10 minutes. The assistant says to open the app (iOS asks for permissions only on screen, or in iOS Settings if denied). When the app becomes active and the permission is granted, the command runs and the result is spoken in the running conversation, or shown on the Assistant screen.

### Action trace

Settings → Developer → Action & task trace → **Voice actions**: for every command, Transcript (shortened, numbers removed) → Intent → Parser (level and rule) → Parsed (title, resolved time and the words it came from) → Permission → Executor (SwiftData, EventKit, UserNotifications) → Result (success only after iOS or the store confirmed) and duration.

## Connection states and the ready announcement

`GlassifAIRealtimeSession.connectionPhase`:

```
WakeDetected → PreparingAudio → ConnectingRealtime → WaitingForDataChannel → RoutingAudio → Ready
                                                                                        ↘ Failed
```

"Ready" requires: ChatGPT accepted the session (answer SDP), WebRTC and its data channel are open, the microphone route is up and — when the glasses are preferred — the Bluetooth HFP route is selected (waited for up to 1.5 s; otherwise Ready with the phone route, recorded). Only then:

| Connection feedback (Settings → Voice) | Wake phrase / Siri start | Button start | Reconnect | Failure |
|---|---|---|---|---|
| Chime + voice (default) | chime + phrase | chime | subtle chime | low tone + "Bağlantı kurulamadı." |
| Voice only | phrase | — | — | same |
| Chime only | chime | chime | subtle chime | same |
| Off | — | — | — | — |

Phrases: Minimal "Bağlandım.", Normal "Bağlandım, dinliyorum.", Jarvis "Bağlantı hazır. Sizi dinliyorum.", or custom. The phrase is spoken **by the realtime voice**, which proves the whole path works; it is said once per new conversation, never on a reconnect or a restart to apply settings. Failures use the on-device Apple voice (the live voice is not available then). "Ray-Ban bağlantısı koptu." is said when the glasses' link drops during a conversation. The chime is a short tone generated in code (no audio file) and plays on the app's audio session, so it reaches the glasses and ignores the silent switch.

Developer → Voice diagnostics shows each phase with its time, the audio route when ready, connect time, reconnects and the voice actually used.

## Start sequence (`GlassifAIRealtimeSession.createDirectRealtimeCall`)

| Step | Instructions | Voice | Resume context |
|---|---|---|---|
| `full` | AutoLoom (natural personality, delegation rules, profile, memories, last conversation summary, Jarvis Style if on) | selected | yes, after a reconnect |
| `withoutResume` | AutoLoom | selected | no (skipped after a voice error) |
| `defaultVoice` | AutoLoom | Juniper | no |
| `baseline` | original GlassifAI | Juniper | no |

Every failed step is recorded in `RealtimeStartReport` (`attempts`, `fallbackReason`). Settings → Voice and Developer → Voice diagnostics show it, so a fallback is never silent. Details: `VOICE_SELECTION.md`.

## Conversation behaviour

| Behaviour | Where |
|---|---|
| Natural Turkish/English, adaptive length, answer first, no canned openers ("Tabii, size yardımcı olabilirim") | `AssistantInstructions.realtime` |
| Barge-in | Server-side (the user talks over the answer). Also a local, instant mute for stop words: `ConversationCommands.classify` on the live user transcript → `suppressAssistantAudio()` |
| End commands ("kapat", "konuşmayı bitir", "görüşürüz", "<name> stop") | On the user's final transcript: a short goodbye, then `stop()` after the assistant's turn (≤ 4 s) |
| Quiet timeout | `checkIdle()` every 5 s; speech, running tasks, pending confirmations and Live Vision count as activity |
| Status words | Ready, Listening, Thinking, Looking, Reading, Searching, **Saving**, Speaking (Turkish on a Turkish UI) |
| Voice preview | `previewVoice(_:)`: microphone muted, the line is spoken as an app message, auto-stop after the assistant's turn or 12 s |
| Apply now | `restartToApplySettings()`: tear down and start again with the same audio route; no new greeting |
| Auto-reconnect | Up to 3 times in 2 minutes after ICE or task-channel failures, iOS audio resets; a subtle chime when it works, the failure announcement when the budget is used |
| Conversation memory | When the conversation ends, a short summary is saved (`MEMORY_ARCHITECTURE.md`) |

## Limits

- The frameless protocol has no client "cancel response" message; the local mute plus server barge-in stand in for it. Muting a reply the model already started is therefore the only way to keep one answer per command; the physical test shows whether any of the model's first words leak through before the final transcript.
- The realtime model is not listed by `/models`; `gpt-live-1-codex` is fixed (device-verified).
- Instructions are capped at 16 000 bytes by the bridge. A unit test keeps the realtime instructions with 12 memories, the profile, a summary and Jarvis Style below it.
