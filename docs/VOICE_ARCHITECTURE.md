# Voice architecture

## Call path

```
iPhone mic / Ray-Ban HFP ──► WebRTC (LiveKit) ──► chatgpt.com/backend-api/codex/realtime/calls
                                   ▲                         │  gpt-live-1-codex, frameless (v3) protocol
                                   │ answer SDP              ▼
Rust bridge (GlassifAICodexBridge) ─ create call ─► sideband websocket (delegations, context appends)
```

- **Call creation** — `glassifai_codex_realtime_start_v2` in `native/GlassifAICodexBridge/src/lib.rs` posts the SDP offer with the session config: instructions, voice, model, initial items and `delegation.ack_filler`. It returns the answer SDP, the call id and, since bridge 3, the voice and model it really sent.
- **Sideband** — a websocket on the same call carries `delegation.created` events and lets the app append context. The *commentary* channel is silent (Live Vision notes); the *speakable* channel makes the model speak (greetings, voice preview).
- **Delegation** — the voice model answers conversation itself. It writes one line `TASK: … | QUERY: …` only when it needs the client (vision, web, memory, actions…). `AssistantOrchestrator` verifies and runs it and returns speakable context through `glassifai_codex_delegation_complete`.

## Start sequence (`GlassifAIRealtimeSession.createDirectRealtimeCall`)

| Step | Instructions | Voice | Resume context |
|---|---|---|---|
| `full` | AutoLoom (natural personality, delegation rules, pinned memories) | selected | yes, after a reconnect |
| `withoutResume` | AutoLoom | selected | no (skipped after a voice error) |
| `defaultVoice` | AutoLoom | Juniper | no |
| `baseline` | original GlassifAI | Juniper | no |

Every failed step is recorded in `RealtimeStartReport` (`attempts`, `fallbackReason`). Settings → Voice and Developer → Diagnostics show it, so a fallback is never silent. Details: `VOICE_SELECTION.md`.

## Conversation behaviour

| Behaviour | Where |
|---|---|
| Natural Turkish/English, adaptive length, no preambles, brief "what can you do" | `AssistantInstructions.realtime` |
| Barge-in | Server-side (the user talks over the answer). Also a local, instant mute for stop words: `ConversationCommands.classify` on the live user transcript → `suppressAssistantAudio()` |
| End commands ("kapat", "konuşmayı bitir", "görüşürüz", "<name> stop") | On the user's final transcript: a short goodbye, then `stop()` after the assistant's turn (≤ 4 s) |
| Quiet timeout | `checkIdle()` every 5 s; speech, running tasks, pending confirmations and Live Vision count as activity. Setting: Name & conversation → "End a quiet conversation after" |
| Greeting and chime for hands-free starts | `ActivationFeedback` + `GreetingStyle`; spoken through the speakable channel after connecting |
| Voice preview | `previewVoice(_:)`: microphone muted, speakable greeting, auto-stop after the assistant's turn or 12 s |
| Apply now | `restartToApplySettings()`: tear down and start again with the same audio route; the summary resumes the conversation |
| Auto-reconnect | Up to 3 times in 2 minutes after ICE or task-channel failures, iOS audio resets |

## Limits

- The frameless protocol has no client "cancel response" message; the local mute plus server barge-in stand in for it.
- The realtime model is not listed by `/models`; `gpt-live-1-codex` is fixed (device-verified).
- Instructions are capped at 16 000 bytes by the bridge. A unit test keeps the realtime instructions with 12 memories below it.
