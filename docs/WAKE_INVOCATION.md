# Wake phrase and invocation

What each platform really allows, and what AutoLoom does with it. Earlier notes: `VOICE_INVOCATION.md`.

## Who controls what

| Invocation | Controlled by | In this build |
|---|---|---|
| "Hey Meta …" on the glasses | Meta | System assistant only |
| "Hey Meta, start AutoLoom" | Meta (DAT 1.0 `VoiceInvocationsStream`) | **UNAVAILABLE**: needs DAT 1.0, firmware V128, Meta AI V290 and Voice Invocation approval |
| "Hey Siri, start AutoLoom" / a personal shortcut named after the assistant | Apple (App Shortcuts) | **EXPERIMENTAL** |
| AutoLoom's own wake phrase ("Hey AutoLoom", "Jarvis", custom) | AutoLoom, on-device speech recognition | **PHYSICAL TEST REQUIRED** |
| A system-wide custom wake word | Nobody (not offered to third-party apps) | **UNAVAILABLE** |

The assistant's **name** (Settings → Name & conversation) and the **wake phrase** (Settings → Wake phrase & hands-free) are separate settings. The phrase defaults to "Hey <name>".

## States A–E

| State | When | How a conversation starts | Microphone while waiting |
|---|---|---|---|
| **A** Conversation running | Any | Just talk; the name is optional ("Jarvis, …") | Realtime call |
| **B** App open, wake phrase on | App on screen | Say the phrase | On-device recognition, orange dot |
| **C** Hands-Free Ready | App in the background or phone locked, for the chosen time (15–120 min) | Say the phrase | On-device recognition, orange dot. iOS may stop it; the app then shows "paused — open the app to resume" |
| **D** Glasses-connected arming | Optional with B or C | Listening runs only while the glasses report a connected link | Off while the glasses are disconnected |
| **E** System | Any | "Hey Siri, start AutoLoom" or your shortcut | None (Siri) |

State D uses the DAT 0.5.0 `Device.linkState` / `addLinkStateListener` event, a real SDK signal. DAT 0.5.0 has no worn/unworn (don) event; DAT 1.0 adds `donState` and `hingeState` (see `DAT_1_MIGRATION.md`).

## How it works

- `WakePhraseListener` runs `SFSpeechRecognizer` with `requiresOnDeviceRecognition = true`. If the iPhone cannot recognise on-device, the feature reports "unavailable": audio is never streamed to a server while waiting.
- Recognition sessions are recycled every 50 s **without** restarting the microphone (`RecognitionFeed`), so an already running listener can continue in the background.
- Only the current recognition request's end starts the next one. Cancelling a request also reports an end, and before v1.1.1 that report restarted the new request, which could loop without end. A request that ends within a second of starting (a Bluetooth microphone can end them at once, as OpenVision documents) is restarted after a growing pause, 0.6 s up to 5 s.
- After a hands-free conversation ends in the background, the call keeps the audio session active and the listener tries to take the microphone back. If iOS refuses, the state becomes "paused" and nothing is faked.
- `WakePhraseMatcher` folds case, accents and Turkish letters, matches whole words, and accepts split or joined compounds ("auto loom" = "AutoLoom"). A phrase that starts with "hey"/"ok" also matches without it.
- On a match: `VoiceStartCoordinator.request(.wakePhrase)` (idempotent) → the conversation starts. Nothing is played or said when the phrase is heard: the user hears the chime and/or "Bağlandım, dinliyorum." only when the connection is **ready** (next section).

## Connection-ready acknowledgement

"Hey AutoLoom" → WakeDetected → PreparingAudio → ConnectingRealtime → WaitingForDataChannel → RoutingAudio → **Ready** (or **Failed**). Ready means ChatGPT accepted the session, WebRTC and the data channel are open, the microphone route is up and the glasses' hands-free route is selected when preferred. Details and the diagnostics screen: `VOICE_ARCHITECTURE.md`.

| Setting (Settings → Voice, also in Wake phrase & hands-free) | Options | Default |
|---|---|---|
| Connection feedback | Chime + voice / Voice only / Chime only / Off | Chime + voice |
| Phrase | Minimal "Bağlandım." / Normal "Bağlandım, dinliyorum." / Jarvis "Bağlantı hazır. Sizi dinliyorum." / Custom | Normal (Jarvis while Jarvis Style is on) |
| End a quiet conversation after | 15 s / 30 s / 1 min / 2 min / Never | 2 min |
| Stop commands | "Dur", "Sus", "Bekle", "Hayır", "Bir dakika"; ending: "Kapat", "Konuşmayı bitir", "Görüşürüz", "<name> stop" | On |

- Said once per new conversation. A reconnect after network jitter only plays a short chime; applying a new voice does not greet again.
- Hands-free starts (wake phrase, Siri, shortcuts) say the phrase; the on-screen button only chimes (the user is looking at the screen).
- "Bağlantı kurulamadı." (low tone + on-device voice) when a start or a reconnect fails, so the user is never left in silence. "Ray-Ban bağlantısı koptu." when the glasses' link drops during a conversation.
- An earlier "Subtle chime" / "Spoken greeting" choice is carried over (chime only / voice only).

## Picovoice

Not used. A custom always-on wake-word engine such as Picovoice would need an AccessKey and a trained model; per the brief it is not added without the owner's approval.

## Device test (fill in)

| State | Steps | Pass when | Result |
|---|---|---|---|
| A | In a conversation: "Jarvis, saat kaç?" | Answers without re-invoking | |
| B | App open, wake phrase on, say "Hey Jarvis" | Nothing until ready; then chime + "Bağlandım, dinliyorum." once | |
| B2 | Airplane mode on, say "Hey Jarvis" | Low tone + "Bağlantı kurulamadı." within ~15 s | |
| B3 | During a conversation turn the glasses off | "Ray-Ban bağlantısı koptu." | |
| C | Hands-Free Ready 30 min, lock the phone, wait 1 min, say "Hey Jarvis" | Conversation starts, or the app shows "paused" (then note it) | |
| C2 | After a hands-free conversation ends while locked, say the phrase again | Starts again, or "paused" | |
| D | "Only while the glasses are connected" on; turn the glasses off, then on | Status "Waiting for the glasses", then listening | |
| E | "Hey Siri, start AutoLoom" | App opens and listens | |
