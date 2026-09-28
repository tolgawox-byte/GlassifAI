# Memory architecture

## Principles

- **Explicit only.** Nothing is saved unless the user asks ("hatırla", "kaydet", "not al", "unutma", "aklında tut", "remember…") or adds it on screen. The realtime instructions say "Never save anything to memory unless the user asked."
- **On this iPhone.** SwiftData store at `Application Support/AutoLoom/AutoLoomMemory.store`. Nothing is synced; ChatGPT's own memory is not reachable through this connection.
- **Minimal disclosure.** Only a few relevant memories go into a request: up to 12 pinned/preference/fact lines (≤ 1 800 characters) in the voice instructions, and up to 5 search hits in a delegated task's context.

## Model

| Type | Stored fields |
|---|---|
| `MemoryRecord` | id, kind, category, title, text, created/updated, pinned, source (voice, manual, visual, migrated), tags, latitude/longitude/place (optional), thumbnail (optional, visual only), lastRecalledAt |
| `NoteRecord` | id, title, content, created/updated, tags, links (for example report sources), source, pinned, place (optional) |

Kinds: FACT, EPISODE, NOTE, VISUAL_MEMORY, PREFERENCE, TASK_CONTEXT. Categories: People, Places, Vehicles, Other. Both are guessed from the words (Turkish and English keywords) and can be edited.

## Voice flow

```
"Arabamı P2'ye park ettim, hatırla"
  → voice model: TASK: memory | QUERY: save: Arabamı otoparkın P2 katına park ettim
  → MemoryRequest.parse → MemoryStore.remember(...)        (no extra model call)
  → "Saved to memory on this iPhone: …" → the voice model confirms in a few words
```

| QUERY prefix | Action | Confirmation |
|---|---|---|
| `save:` | remember (duplicates are refreshed, not repeated) | SAFE: explicit request |
| `recall:` | on-device search; the hits are given to the voice model to answer from | SAFE |
| `forget:` | search; one clear match → **CONFIRM** card ("Forget …?"); several → the assistant asks which | CONFIRM |
| `list` | most recent memories | SAFE |
| no prefix | a model classifies the request into strict JSON (`memory_request`); code executes it | as above |

## Visual memory (opt-in)

`TASK: visual_memory | QUERY: …` → the current view in high detail → the vision model describes what matters (text, numbers, level/spot, brand) → saved as `VISUAL_MEMORY`. Settings → Memory:
- **Visual memories**: off by default.
- **Keep a small photo**: off by default (480 px JPEG, SwiftData external storage).
- **Attach the place**: off by default (one location fix and a place name; When-In-Use permission asked when turned on).

## Search

`MemorySearch`:
1. Folding: Turkish lowercase, accents removed, "ı" → "i".
2. Words: stop words removed; stems match when one word starts with the other ("arabam" ↔ "arabamı", "kapının" ↔ "kapı").
3. English queries add Apple's on-device `NLEmbedding.sentenceEmbedding(for: .english)` cosine similarity. iOS has no Turkish sentence embedding, so Turkish relies on step 2.
4. Pinned items get a small boost. Threshold 0.34.

## Migration

On first launch `memory.json` and `notes.json` from earlier builds are imported and renamed `*.migrated-backup` (never deleted automatically).

## Deletion

Memory tab: swipe to forget, Delete all (with confirmation). Settings → Memory: Delete all memories. Privacy center: Delete all local data (memories, notes, context, diagnostics).

## Device test (fill in)

| # | Say / do | Pass when | Result |
|---|---|---|---|
| M1 | "Jarvis, arabamı otoparkın P2 katına park ettiğimi hatırla" | Confirmed briefly; Memory tab → Recent shows it (Vehicles) | |
| M2 | Later: "Arabam nerede?" | Answers "P2" from memory | |
| M3 | "Kapı kodunu unut" (after saving one) | Asks to confirm; forgotten only after yes | |
| M4 | Memory tab: pin, edit, search "kapı", Delete all | Works; confirmation shown before Delete all | |
| M5 | Visual memory on, look at a parking sign: "bunu hatırla" | Description with the readable text saved; photo/place only if enabled | |
| N1 | "Not al: yarınki toplantıda bütçeyi konuş" | Note appears in Memory → Notes; Share opens the share sheet | |
