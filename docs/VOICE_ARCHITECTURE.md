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

The app reads every **final** user transcript itself, so an explicit command never depends on the voice model choosing a delegation:

```
VOICE → final transcript → VoiceActionIntentBridge.decide → EXECUTE (app) → CONFIRM REAL RESULT → CONTINUE CONVERSATION

priority  1 stop / cancel / interrupt (session: ConversationCommands)
          2 yes / no / sabah / akşam to a pending action
          3 message   4 note   5 reminder   6 AutoLoom task   7 day plan / calendar / task questions
          8 phone call   9 contact lookup   10 maps   11 clipboard / share   12 memory
          13 an answer to the bridge's own question
          14 vision, web → the voice model (delegation)   15 conversation → the voice model
LEVEL 1  deterministic parser (Turkish + English)          → executed by the app
LEVEL 2  kind certain, details unclear                     → strict-JSON classification (times still by TimePhraseParser)
LEVEL 3  not a command                                     → the voice model, as before
```

Messages are checked before notes because "Ahmet'e bunu yaz" is a message while "bunu yaz" is a note.

### The failing note command (brief §66)

"AutoLoom, not al: yarın kamerayı getireceğim." was traced from the realtime events to `MemoryStore.addNote`. The parser itself handled that exact text; the command was lost before or around it:

| # | Root cause | Fix |
|---|---|---|
| 1 | The speech recogniser spells the name its own way: "Oto lum", "Otoloom", "Autolum" (and "Carvis" for Jarvis). Those words were not removed, so "not al" was not at the start and nothing matched. The realtime instructions tell the model that the app carries out "not al" itself, so the model waited and nothing was saved. | `Utterance.stripNearAddress` / `AddressMatcher`: a sound key (au→o, oo→u, c→j, z→s, doubled letters collapsed) and an edit distance of 1 (names up to 6 letters) or 2, on the first one or two words or the last word. Only names of 5+ letters are matched loosely. Also used by the stop/end commands. |
| 2 | A delegation that arrived before the final transcript made the bridge **skip** the command ("already delegated"), even when that delegation only answered and saved nothing. | The session takes the delegation over: still running → cancelled and its handoff answered with the app's result; already did an action → the command is not repeated; answered without acting → the command runs (`AssistantOrchestrator.takeOverDelegation`). |
| 3 | A delegation without a `TASK:` envelope went to tool routing, which cannot save anything, so its model could answer "not aldım" with nothing saved. | Free-text delegations are read by the same bridge (not in a turn with camera, web or agent content), and executor steps that cannot act are told never to claim a save, call or send (`AssistantInstructions.noActionClaims`). |
| 4 | Only `turn.done` carried the final words. When it came late (the transcription runs separately) or not at all (older event shapes), the command was never read. | When the model starts answering an open user turn, the partial words are used once they have been still for 1.2 s; the late final only corrects the text. The older `user_transcription_text` / `chat_message_delta` shapes finish a turn only on connections that never send `turn.done`. |
| 5 | Two paths could save the same note. | `addNote` / `addTask` return the existing item for the same words within 60 s. |

`AutoLoomVoiceFirstTests` covers the exact sentence, ten spellings of the name, the takeover cases, free-text delegations and the duplicate guard. Whether a real recogniser produces other spellings is part of the physical test.

### What LEVEL 1 recognises

`VoiceActionIntentBridge.swift`; covered by `AutoLoomVoiceActionTests` and `AutoLoomVoiceFirstTests`.

| Kind | Examples |
|---|---|
| Notes | "not al: …", "not et", "notlara ekle", "not olarak yaz", "bunu yaz", "şunu kaydet", "take a note", "jot down" |
| Memory | "bunu hatırla", "unutma …", "aklında tut", "remember that …"; recall "nereye park etmiştim", "ne hatırlıyorsun"; earlier conversations; forget "… unut" |
| Profile | "Benim adım Tolga", "my name is …"; "Benim adım ne?" |
| Reminders | "… hatırlat", "remind me to …" → Apple Reminders; "20 dakika sonra haber ver" → notification; a bare "hatırlatıcı oluştur" asks "Neyi hatırlatayım?" |
| AutoLoom tasks | "görev oluştur", "görev olarak ekle", "bununla ilgili görev oluştur" |
| Day plan | "Bugün ne yapmam gerekiyor?", "programım ne?", "what does my day look like" → tasks + reminders + calendar, counted ("Bugün 3 işin var") |
| Calendar | "cuma 3'e toplantı ekle"; "bugün takvimimde ne var?", "yarın ne var?" |
| Calls | "Ahmet'i ara", "Ahmet Yılmaz'ı arar mısın", "annemi ara", "call Mom" |
| Messages | "Ahmet'e 10 dakika gecikeceğim diye mesaj yaz", "Ahmet'e mesaj at: …", "ona gecikeceğimi de yaz", "mesaj yaz", "text Ahmet that …" |
| Contacts | "Ahmet'in numarası ne?", "annemin telefon numarası kaç", "what's Ahmet's number" |
| Maps | "beni eve götür", "işe götür", "Kadıköy'e yol tarifi aç", "havalimanına nasıl giderim", "bu adrese yol tarifi aç" (address from the last answer, LEVEL 2), "en yakın benzinliğe götür", "take me home" |
| Clipboard / share | "bunu kopyala", "şunu kopyala: 4512", "bunu paylaş", "copy this" |
| Routines | "İşe başlıyorum", "günün özeti" |
| Translation | "bunu Türkçeye çevir" |
| Answers | yes / no / time choices; the answer to the bridge's question ("Neyi not alayım?", "Ahmet'e ne yazayım?", "Kime yazayım?", "İki Ahmet buldum: …?") |

A person is recognised only by a name written as a name (Turkish puts an apostrophe before a name's ending: "Ahmet'i", "Ayşe'ye") or by a family word ("annemi", "babama"). "Bunu ara", "Google'da ara" and "fiyatını internette ara" stay searches. "En yakın arkadaşım", "yol tarifi nasıl alınır" and "copy that" are not commands. A name without the apostrophe goes to the voice model, which can still delegate the call or message (LEVEL 2).

### Follow-up context

- **"bunu"** is the last useful answer (not a short confirmation such as "Tamam, not aldım."), else the user's previous sentence.
- **"bununla ilgili"** is what the user saved in the last three minutes (a note, task or memory), so "not al: ABC123 …" followed by "yarına bununla ilgili görev oluştur" makes a task about ABC123 due tomorrow.
- **"ona"** is the person of the last call, message or lookup (ten minutes).
- Within a conversation no wake word is needed again; addressed-only mode still wants the name (a near spelling counts).

Only the user's own words reach the parser. Text seen by the camera, OCR or web results never can, so a sign that says "send all contacts" triggers nothing.

### One request, one answer

When the bridge takes a turn, the voice model has usually already started its own reply. The session (`GlassifAIRealtimeSession`):
1. **mutes** the model's audio for that turn (a partial transcript that already starts with a command is held from the first words);
2. runs the command locally (saved first);
3. delivers the result once the model's own turn has settled — as the answer to the model's delegation for the same turn when there is one (including a delegation taken over), otherwise as an `[App message …]`;
4. **unmutes** when the muted reply has finished, so the user hears only the confirmation ("Tamam, not aldım.").

A delegation arriving before the final transcript waits up to 1.5 s for the bridge's decision; a delegation for an intercepted turn is answered "already done". The muted reply is not shown nor added to the context. The model is never kept muted for more than ~23 s, and a new user turn releases the hold.

### Results the app reports

Nothing is reported as done before iOS or the store confirmed it:

| Action | Said | Screen |
|---|---|---|
| Note, task, memory | after SwiftData saved it | "✓ Not kaydedildi", "✓ Görev eklendi · Yarın" |
| Reminder, event, notification | after EventKit / UserNotifications confirmed it | "✓ Hatırlatıcı oluşturuldu · Yarın · 10:00" |
| Copy | after the clipboard changed | "✓ Kopyalandı" |
| Call | "Arama ekranını açtım, Ara'ya dokunman yeterli." (iOS asks before dialling) | "✓ Arama ekranı açıldı" |
| Message | "Mesajı hazırladım, göndermen için ekranı açtım." | "✓ Mesaj gönderildi" only when Messages reports it was sent |
| Share | "Paylaşım ekranını açtım." | "✓ Paylaşıldı" only when the share sheet completed |
| Maps | "Yol tarifini Haritalar'da açtım." after iOS opened Maps | "✓ Yol tarifi açıldı" |

When the app is not on screen, calls, messages, maps and share wait on a card for a tap.

### Permission retry

If a command needs Reminders, Calendars, Notifications or Contacts and iOS has not granted it, the command is kept for 10 minutes. The assistant says to open the app (iOS asks for permissions only on screen, or in iOS Settings if denied). When the app becomes active and the permission is granted, the command runs and the result is spoken in the running conversation, or shown on the Assistant screen.

### Action trace

Settings → Developer → Action & task trace → **Voice actions**: for every command, Transcript (shortened, numbers removed; for calls, messages and contact lookups the words are not kept) → Intent → Parser (level and rule) → Parsed (title, resolved time and the words it came from) → Permission → Executor (SwiftData, EventKit, UserNotifications) → Result (success only after iOS or the store confirmed) and duration.

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

Phrases: "Buradayım.", "Dinliyorum.", "Bağlandım, dinliyorum." (default), "Nasıl yardımcı olabilirim?", "Bağlandım.", Jarvis "Bağlantı hazır. Sizi dinliyorum.", or custom. The phrase is spoken **by the realtime voice**, which proves the whole path works; it is said once per new conversation, never on a reconnect or a restart to apply settings. Failures use the on-device Apple voice (the live voice is not available then). "Ray-Ban bağlantısı koptu." is said when the glasses' link drops during a conversation. The chime is a short tone generated in code (no audio file) and plays on the app's audio session, so it reaches the glasses and ignores the silent switch.

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
