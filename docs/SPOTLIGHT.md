# Spotlight and global search

AutoLoom has one on-device search ("AutoLoom'da ara") over notes, tasks, memories, conversation summaries, Dealer Mode vehicles, Ray-Ban captures, the shopping list and the parking spot, used by voice and by the search screen. It also puts notes, open tasks and vehicles (and, only if you turn it on, memories) into iOS Spotlight on this iPhone, with complete file protection and the VIN masked to its last six characters. On iOS 18 and later the app asks Spotlight for semantic matches among its own items to add to the local results. Code: `Runtime/SpotlightIndexer.swift`, `Runtime/GlobalSearch.swift`, `Runtime/IntentRunnerExtras.swift` (`runGlobalSearch`).

## What goes into iOS Spotlight

Index name `AutoLoom`, `protectionClass: .complete`. Each item has a title, `contentDescription` (first 300 characters), `textContent` (first 2,000 characters), the creation date, keywords plus "AutoLoom", identifier `<domain>:<uuid>` and no expiry.

| Domain | What | Limit | Text | Keywords |
|---|---|---|---|---|
| `note` | Notes | 500 | Title and content | The note's tags |
| `task` | Open AutoLoom tasks only | 300 | Title and notes | "görev", "task" |
| `vehicle` | Dealer Mode vehicles | 200 | Title; masked VIN, stock number, colour, odometer, damage notes | Make, model, stock number, "araç", "vehicle" |
| `memory` | Memories, **only if "Include memories" is on** and Memory is on | All | Title and text; conversation summaries are never indexed | — |

Not in Spotlight: conversation summaries, captures, the shopping list, the parking spot, documents and receipts, visual memory photos.

## Privacy

- **On this iPhone only**; the index is Apple's on-device Core Spotlight store.
- **Complete protection**: nothing in the index is readable while the phone is locked.
- **Memories are opt-in** (they can hold codes and personal details). Default off.
- **Masked VIN**: vehicles show `•••••••••••004352`-style text (11 dots and the last six characters); the full VIN is never in the index. `AutoLoomAppleIntelligenceTests.testSpotlightKeepsMemoriesOutAndMasksTheVIN` checks both rules.
- Turning Spotlight off re-indexes with nothing, which deletes the items. Privacy center → "Delete all local data" also removes the whole index.

## When the index is updated

A full re-index (delete all, add all) runs 5 s after launch, 0.5 s after the app goes to the background, and 0.2 s after either Spotlight setting changes; bursts are coalesced. It does not run in unit tests or when `CSSearchableIndex.isIndexingAvailable()` is false. Tapping an AutoLoom result in iOS Spotlight opens AutoLoom's search screen on that item's title (not the item itself).

## Settings

Settings → Privacy center → **Spotlight**:

| Toggle | Default |
|---|---|
| "iOS Spotlight'ta göster / Show in iOS Spotlight" | On |
| "Anıları da ekle / Include memories" | Off (disabled while Spotlight is off) |

## The global search engine

Voice: "Geçen hafta Corolla ile ilgili kaydettiğim şeyi bul", "Mercedes için çektiğim jant fotoğraflarını göster", "Find everything I saved about the Corolla". Screen: Settings → Search AutoLoom, with a filter chip per kind. App Intent: "Search AutoLoom" (see [APP_INTENTS.md](APP_INTENTS.md)).

`GlobalSearch.parse` turns the sentence into a query:

| Said | Becomes |
|---|---|
| bugün / today | From the start of today |
| dün / yesterday | Yesterday only |
| bu hafta / this week | Last 7 days |
| geçen hafta / last week | Last 15 days (said loosely) |
| bu ay / this month · geçen ay / last month | Last 31 · 62 days |
| not, görev, hafıza, konuşma, araç/stok, fotoğraf/video/çektiğim, gördüm | Kind filters (a note or memory word also includes notes, memories and visual memories) |
| bul, göster, kaydettiğim, ilgili, find, saved, about … | Removed (command words) |

`GlobalSearch.run` then scores every item on the phone:

- Sources: notes, tasks (open and done), memories and conversation summaries (only while Memory is on), vehicles (matched on title, full VIN, stock number, colour and damage; only the title and odometer are shown), captures (label, caption, vehicle), open shopping items, the parking spot.
- Score: Turkish-aware word match (`MemorySearch`, "Corolla'nın" → "Corolla") plus a small bonus for recent items; ties go to the newest.
- Voice gets the top three in one short summary; the full list opens on the phone. Nothing found → it says so and does not guess.

When nothing is found: the on-device model rewrites the words (3–6 Turkish and English keywords) and searches again; on iOS 27 it may then answer from AutoLoom's Spotlight items with `SpotlightSearchTool` ([APPLE_INTELLIGENCE.md](APPLE_INTELLIGENCE.md)). Both need Apple Intelligence.

## Semantic Spotlight matches (iOS 18+)

`GlobalSearch.runWithSpotlight` adds Spotlight's own matches after the local ones:

- `CSUserQuery` with the query text, fetching `title`, `contentDescription`, `contentCreationDate`, up to 12 results.
- Only AutoLoom items are mapped back (by the `<domain>:<uuid>` identifier); results already found locally are skipped; kind filters still apply.
- Best effort: a query that has not answered within 2 s is dropped; on iOS 17 or with Spotlight off nothing is added.
- These results get a fixed score of 0.55. The search screen asks 350 ms after typing stops.

## Known gaps

- `GlobalSearch.extraSources` is never filled in this build. Visual memories are found as "Memory" results, and the "Görsel hafıza / Visual memory" filter chip returns nothing. Use Memory → Visual memory or "nerede gördüm?" instead ([VISUAL_MEMORY.md](VISUAL_MEMORY.md)).
- Semantic quality depends on Apple's on-device index; it is not measured by the app.

## Status

| Item | Status |
|---|---|
| Index content, masked VIN, memories opt-in, identifiers | WORKING (unit tests) |
| Global search parsing and ranking | WORKING (unit tests) |
| Results in iOS Spotlight, hidden while locked, opening a result | PHYSICAL_TEST_REQUIRED |
| Semantic `CSUserQuery` matches | EXPERIMENTAL, PHYSICAL_TEST_REQUIRED (iOS 18+) |
| iOS 27 answer from Spotlight items | EXPERIMENTAL, PHYSICAL_TEST_REQUIRED |
| Visual-memory filter in search | UNAVAILABLE (see Known gaps) |
