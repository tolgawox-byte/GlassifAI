# Memory architecture

AutoLoom builds its **own** memory on this iPhone. It does not read ChatGPT's account memory or old ChatGPT chats: no official API exposes them to this app, and the assistant says so if asked.

## Principles

- **Explicit.** Facts, preferences, people, places, vehicles and notes are saved only when the user asks ("hatırla", "unutma", "aklında tut", "hafızaya kaydet", "not al", "remember…") or adds them on screen. The realtime instructions say "Never save anything to memory unless the user asked."
- **The one automatic entry: conversation summaries.** When a meaningful conversation ends, a short summary is saved (Settings → Memory → Conversation memory, **on** by default, can be turned off). Only the summary is kept, never the transcript, and sensitive details are left out.
- **Smart Memory (off by default).** When on, the assistant may *offer* to remember a stable fact ("Bunu hafızama kaydedeyim mi?") and saves only after a yes. It never offers health, money, passwords, codes, ID numbers or exact addresses.
- **On this iPhone.** SwiftData store at `Application Support/AutoLoom/AutoLoomMemory.store`; nothing is synced. The profile is in `UserDefaults`.
- **Bounded disclosure.** Each request gets a small, relevant slice, never the whole database (see Injection).

## Model

| Type | Stored fields |
|---|---|
| `MemoryRecord` | id, kind, category, title, text, created/updated, pinned, source (voice, manual, visual, conversation, shortcut, migrated), tags, place (optional), thumbnail (optional, visual only), lastRecalledAt |
| `NoteRecord` | id, title, content, created/updated, tags, links (for example report sources), source, pinned, place (optional) |
| `TaskItem` | id, title, notes, createdAt, dueAt (optional, with or without a time), completed/completedAt, priority, source, linkedMemoryID, linkedNoteID, notificationID (optional alert) |
| `UserProfile` | preferredName — set only when the user says it ("Benim adım Tolga") or types it in Memory → About me |

Memory kinds: PROFILE, PREFERENCE, FACT, PERSON, PLACE, VEHICLE, EPISODE, NOTE, TASK_CONTEXT, VISUAL_MEMORY, CONVERSATION_SUMMARY. Categories: People, Places, Vehicles, Other. Kinds and categories are guessed from the words (Turkish and English keywords) and can be edited; conversation summaries are written by the app.

Adding `TaskItem` to the schema is a lightweight SwiftData migration (a new entity). If the store ever fails to open, the app falls back to a temporary store and shows the error in the Memory tab instead of touching the file.

A save that SwiftData rejects is rolled back, and the command is reported as failed — the assistant never says "not aldım" for a note that was not stored.

## Voice flow (Jarvis v1.1)

Explicit commands are recognised by the app itself (`VoiceActionIntentBridge`, see `VOICE_ARCHITECTURE.md`), not left to the voice model:

| Said | Result |
|---|---|
| "Jarvis, not al: cuma Mercedes gelecek." | AutoLoom note saved, then "Tamam, not aldım." |
| "Arabamın P2 katında olduğunu unutma" | Memory saved (Vehicles), then "Tamam, aklımda tutacağım." |
| "bunu hatırla" (visual memories on, camera on) | Visual memory of the current view |
| "bunu hatırla" (visual off) | The user's previous sentence is saved; with none, "Neyi hatırlamamı istersin?" |
| "anahtarımı buraya bıraktığımı hatırla" | Visual memory (a place word) |
| "Benim adım Tolga." | Profile name saved; "Memnun oldum Tolga, bunu hatırlayacağım." |
| "Benim adım ne?" | Answered from the profile (or "you haven't told me yet") |
| "Arabamı nereye park etmiştim?" | On-device search; the hits are given to the voice model |
| "Geçen gün Ray-Ban kamerasıyla ne yapıyorduk?" | Conversation summaries are searched and answered from |
| "Kapı kodunu unut" | One clear match → CONFIRM ("evet"); several → the assistant asks which |

Anything the parser does not recognise stays with the voice model, which can still delegate `TASK: memory | QUERY: save: / recall: / forget: / list` (unchanged). If a memory request reaches the structured model classification and it fails, nothing is guessed; the bridge's own save uses the literal statement.

## Retrieval

`MemorySearch` over memories, notes, **tasks** and conversation summaries:
1. Folding: Turkish lowercase, accents removed, "ı" → "i".
2. Words: stop words removed; stems match when one word starts with the other ("arabam" ↔ "arabamı", "kapının" ↔ "kapı").
3. English queries add Apple's on-device `NLEmbedding.sentenceEmbedding(for: .english)`. iOS has no Turkish sentence embedding, so Turkish relies on step 2. No server, no paid vector database.
4. Ranking: relevance first (threshold 0.34), then tie-breakers only for results that are already relevant — pinned +0.05, an exact name from the question (a capitalised word such as "Mercedes") +0.1, and recency up to +0.05 fading over 30 days.

## Injection (what the voice model gets)

At the start of each conversation (and after a reconnect):
- the **profile** line ("The user's name is Tolga"), used "naturally, not in every sentence";
- up to **12** memory lines, ≤ 1 800 characters: pinned, About me, preferences, then recent facts/people/places/vehicles;
- the **last conversation summary** if it is less than 14 days old (≤ 500 characters);
- never a raw transcript.

During a conversation, delegated tasks (vision, web, reasoning) get up to 5 relevant memories for their request; recall questions get up to 5 hits.

## Conversation memory

1. Every final turn of the running conversation is kept in memory (≤ 80 turns, ≤ 600 characters each). Reconnects keep the same conversation.
2. When it ends (the user ends it, the quiet timeout, or a failed reconnect), it is summarised if it was meaningful: something was done (a note, reminder, task…), or at least two user turns with some substance.
3. The executor model writes strict JSON: summary, topics, decisions, open tasks, entities, with sensitive details left out. Offline, a local fallback keeps the user's first requests.
4. The turns are then dropped. Numbers such as phone or card numbers are replaced with `[number]` before saving. The newest 200 summaries are kept; pinned ones never expire.

Summaries appear in Memory → Conversations (all of them in "All conversations"), are searchable, and can be pinned, edited or deleted.

## Visual memory (opt-in)

The current view in high detail → the vision model describes what matters (text, numbers, level/spot, brand) → saved as `VISUAL_MEMORY`. Settings → Memory:
- **Visual memories**: off by default.
- **Keep a small photo**: off by default (480 px JPEG, SwiftData external storage).
- **Attach the place**: off by default (one location fix and a place name).

Nothing is recorded continuously: a visual memory is one frame, taken when the user asks.

## Memory tab

Search (memories, notes and tasks) and the sections **About me** (name + profile memories), **Pinned**, **Recent** (7 days), **People**, **Places**, **Vehicles**, **Other**, **Conversations**, **Visual memories**. Each card shows title, content, date, kind and source; swipe to pin or forget; the detail screen has Edit, Pin and Forget. Notes are a separate segment (search, pin, edit, delete, share to Apple Notes).

## Deletion

- Memory tab → ⋯ → **Clear all AutoLoom memory** (with confirmation): memories, conversation summaries and the profile. Notes and tasks are kept.
- Settings → Memory → Clear all AutoLoom memory (same).
- Privacy center → Delete all local data: memories, notes, tasks, profile, conversation context and diagnostics.

## Migration

On first launch `memory.json` and `notes.json` from earlier builds are imported and renamed `*.migrated-backup` (never deleted automatically).

## Device tests (fill in)

| # | Say / do | Pass when | Result |
|---|---|---|---|
| M1 | "Benim adım Tolga." then, in a new conversation, "Benim adım ne?" | Answers "Tolga"; Memory → About me shows it | |
| M2 | "Jarvis, arabamı otoparkın P2 katına park ettiğimi unutma" | "Tamam, aklımda tutacağım."; Memory → Recent shows it | |
| M3 | Later: "Arabam nerede?" | Answers "P2" from memory | |
| M4 | "Kapı kodunu unut" (after saving one) | Asks to confirm; forgotten only after "evet" | |
| M5 | Talk about the camera for a minute, end the conversation, next day: "Geçen gün Ray-Ban kamerasıyla ne yapıyorduk?" | Answers from the conversation summary (Memory → Conversations shows it) | |
| M6 | Memory tab: pin, edit, search "kapı", Clear all | Works; confirmation shown; notes and tasks remain | |
| M7 | Visual memory on, look at a parking sign: "bunu hatırla" | Description with the readable text saved; photo/place only if enabled | |
| N1 | "Jarvis, not al: cuma Mercedes gelecek." | Memory → Notes shows it at once; one answer, "Tamam, not aldım." | |

## The Memory Agent (multi-agent, v1.4)

AutoLoom memory stays the source of truth on the phone, independent of any provider:

- Memory requests ("Geçen gün ne konuşmuştuk?", "hatırla…", "unut…") are routed to the **local Memory Agent** (strategy LOCAL); no cloud agent searches or owns memory.
- Before any agent is called, only what the request needs is retrieved: at most five relevant items (`MemoryStore.relevantItems`), the recent conversation summary, and the current entities (vehicle, product, person, place, document; 30 minutes). The whole database, contacts and notes are never sent to Claude, Gemini, Perplexity or OpenRouter.
- Providers never learn the conversation on their own: the orchestrator owns the conversation state and gives each call the minimum context.
