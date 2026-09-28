# Voice selection — the "voice never changes" bug and its fix

## Symptom (owner report, 2026-09-28)

Choosing another voice in Settings "often still gives the same voice".

## Root cause (confirmed in code)

1. **Wrong voice list.** Settings offered `juniper, alloy, ash, ballad, cedar, coral, echo, marin, sage, shimmer, verse` (`AssistantPreferences.voices` in vNext).
2. **The protocol rejects most of them.** The app uses Codex's frameless realtime protocol (`RealtimeEventParser::FramelessBidi`, "v3"). Codex allows only the v1 list for v1 and v3:
   - `codex-rs/protocol/src/protocol.rs`: `RealtimeVoicesList::builtin().v1 = [Juniper, Maple, Spruce, Ember, Vale, Breeze, Arbor, Sol, Cove]`
   - `codex-rs/core/src/realtime_conversation.rs`: `validate_realtime_voice` maps `V1 | V3 => voices.v1`
   - The v2 voices (Alloy, Ash, Ballad, Coral, Echo, Sage, Shimmer, Verse, Marin, Cedar) belong to the other protocol.
3. **A silent fallback hid the failure.** When the customised start failed, `createDirectRealtimeCall` retried with the original baseline entry point, which always uses Juniper and the old GlassifAI instructions. The reason was only logged. The user heard Juniper (and lost the AutoLoom instructions and name) without being told.
4. **The bridge also mapped unknown voice names to Juniper silently.**
5. **Mid-conversation changes cannot apply.** The voice is fixed when a realtime session starts, so a change during a conversation only applied to the next one.

## Fix (Jarvis v1)

| Part | Change |
|---|---|
| Catalog | `VoiceCatalog` lists only the nine frameless voices, with ChatGPT's own short descriptions. A native bridge test pins the same list to `RealtimeVoicesList::builtin().v1`, so a Codex update that changes it fails CI |
| Migration | A stored v2 voice becomes Juniper once, and Settings says which voice was replaced and why |
| Start ladder | `full` (AutoLoom instructions, selected voice, resume context) → `withoutResume` → `defaultVoice` → `baseline`. Each failure is recorded; a voice error skips the `withoutResume` step |
| Bridge v3 | Every start result carries `voice` and `model` (what was really sent) and `voice_note` when a name was unknown |
| Settings → Voice | **Selected voice** and **Active voice** side by side, the fallback reason when they differ, **Apply now** (restart with the new voice, resuming from the summary) and **Preview** (a short line, microphone off, only when no conversation runs) |
| Diagnostics | Requested/active voice and model, start step, fallback reason, each attempt, connect time |

## Voices

| Voice | ChatGPT's description | Tested on device |
|---|---|---|
| Juniper (default) | Open and upbeat | |
| Maple | Cheerful and candid | |
| Spruce | Calm and affirming | |
| Ember | Confident and optimistic | |
| Vale | Bright and inquisitive | |
| Breeze | Animated and earnest | |
| Arbor | Easygoing and versatile | |
| Sol | Savvy and relaxed | |
| Cove | Composed and direct | |

## Jarvis Style

A **style**, not a voice clone (brief sections 42–45).

| Part | What it is |
|---|---|
| Voice | The closest of the nine ChatGPT voices this protocol accepts: **Cove**, "composed and direct" in ChatGPT's own description. Chosen from the descriptions; none of the nine is documented as British-accented, so the Settings text does not promise an accent. The user can pick any other voice while the style is on |
| Delivery | Extra realtime instructions: composed, discreet, courteous, economical with words, occasional dry humour, steady pace; Turkish in a polished *siz* register with "efendim" now and then, never in every sentence; the user's name only occasionally |
| Limits | "Do not imitate any real actor or film character, do not quote films, and never claim to be a character from a film." |
| Greeting | Turning the style on switches the connection phrase from Normal to Jarvis ("Bağlantı hazır. Sizi dinliyorum."); turning it off switches back |
| Offline fallback | For the few moments the realtime voice cannot speak (a failed connection), an Apple voice installed on the iPhone is used: premium, then enhanced quality; with Jarvis Style, a British English male voice for English. Nothing is downloaded or bundled |

Not done, on purpose: no film audio, no scraped dialogue, no actor clone, no downloaded voice model. The primary live conversation stays on the realtime voice; it is never replaced by a local TTS voice to get a special sound. Nothing voice-related is bundled, so `THIRD_PARTY_NOTICES.md` has no voice entry.

Settings → Voice now shows **Selected voice**, **Active voice**, **Style** (Natural / Jarvis Style), the Jarvis Style switch, the voice list with previews, **Connection feedback** (Chime + voice / Voice only / Chime only / Off, with the phrase), **Language** and **Conversation tone**, and the offline Apple voice with a test button.

## Device check

1. Settings → Voice → press ▶ next to three different voices. Each preview should sound clearly different.
2. Choose **Maple**, start a conversation, then open Settings → Voice: **Active voice = Maple**, no warning.
3. During the conversation choose **Cove**: Active still shows Maple and **Apply now** appears; press it. The conversation restarts and speaks with Cove.
4. Developer → Diagnostics: "Voice (selected / active)" matches, "Voice fallback reason" = none.

If the active voice differs, the fallback reason in Settings shows ChatGPT's own error text. That is the information needed to fix it.
5. Turn **Jarvis Style** on: the selected voice becomes Cove and the style shows "Jarvis Style". Start a conversation and ask something: calm, concise, courteous; no film quotes; "efendim" at most now and then.
6. Turn it off: the earlier voice comes back.
