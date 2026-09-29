# App Intents and Siri

All are official App Intents with App Shortcuts (Siri, Shortcuts, Spotlight, the Action button). **PHYSICAL TEST REQUIRED** for each.

| Intent | Opens the app | Phrase examples |
|---|---|---|
| Start Conversation | yes | "Start AutoLoom", "Talk to AutoLoom" |
| Ask AutoLoom | yes | "Ask AutoLoom" |
| Create AutoLoom Note | no | "New AutoLoom note" |
| Start Live Vision | yes | "AutoLoom live vision" |
| Create AutoLoom Task (title, optional due date) | no | "New AutoLoom task" |
| Remember This | no | "Remember this in AutoLoom" (respects Memory off) |
| Start Dealer Session | yes | "New vehicle in AutoLoom" |
| Today's Briefing | no | "AutoLoom today's briefing" (tasks, reminders, calendar; permissions must already be given) |
| Add to Shopping List | no | "Add to my AutoLoom shopping list" |

Nine App Shortcuts (iOS allows ten). Siri phrases include the app name as iOS requires; a personal shortcut can use any name (for example "Jarvis").

Not available: Lock Screen / Control Center controls and Live Activities need widget-extension targets that this build does not add; a home-screen widget likewise (**UNAVAILABLE** in this build).

## Update: every App Intent and App Shortcut in the code (as of commit 8ee1a24)

This section supersedes the table above, which predates the Action Catalog: the build now declares **17 App Intents** and **10 App Shortcuts** (the table above lists nine). Sources: `Runtime/VoiceInvocation.swift`, `Runtime/MoreAppIntents.swift`, `Runtime/CatalogAppIntents.swift`. Apart from Start Conversation, Ask AutoLoom, Start Live Vision and Find Vehicle, every intent runs through `ActionCatalog.run`, the same executor as speech ([ACTION_CATALOG.md](ACTION_CATALOG.md)). The test `AutoLoomActionCatalogTests` only accepts these 17 type names in the catalog.

### App Intents

| Intent (type) | Title | Opens the app | Parameters | Does |
|---|---|---|---|---|
| `StartConversationIntent` | Start Conversation | yes | — | Starts listening through `VoiceStartCoordinator` (a second request while one is starting or active is ignored) |
| `AskAutoLoomIntent` | Ask AutoLoom | yes | Question (asked if missing) | Same as typing the question: local commands first; offline with Apple Intelligence ready, the on-device offline assistant; else the agents. The answer is on screen |
| `CreateAutoLoomNoteIntent` | Create AutoLoom Note | no | Note, optional Title | With a title: saved directly with that title. Without: `note.create` |
| `StartLiveVisionIntent` | Start Live Vision | yes | — | Starts a conversation, waits up to 10 s for it, then starts Live Vision |
| `CreateAutoLoomTaskIntent` | Create AutoLoom Task | no | Task, optional Due date | `task.create` |
| `RememberInAutoLoomIntent` | Remember This | no | What to remember | `memory.save` |
| `StartDealerSessionIntent` | Start Dealer Session | yes | — | `dealer.start` |
| `TodaysBriefingIntent` | Today's Briefing | no | — | `routine.briefing` (reply cut to 600 characters) |
| `AddToShoppingListIntent` | Add to Shopping List | no | Items | `shopping.add` |
| `RunAutoLoomActionIntent` | Run AutoLoom Action | yes | Action (any catalog action, `AutoLoomActionEntity`), optional Details | The chosen action; Details fill its first parameter |
| `TakeRayBanPhotoIntent` | Take Ray-Ban Photo | yes | — | `camera.photo` (the glasses' camera, never the iPhone's) |
| `StartRayBanRecordingIntent` | Start Ray-Ban Recording | yes | — | `camera.recordStart` |
| `StopRayBanRecordingIntent` | Stop Recording | no | — | `camera.recordStop` |
| `SearchAutoLoomIntent` | Search AutoLoom | yes | Search for (asked if missing) | `search.global` |
| `FindVehicleIntent` | Find Vehicle | no | Vehicle (asked if missing) | Global search limited to Dealer vehicles; says the best match or "No vehicle matches …" |
| `CreateVehicleTaskIntent` | Create Vehicle Task | no | Task | `task.create`, only while a Dealer vehicle is active ("There is no active vehicle in Dealer Mode.") |
| `StartTranslationIntent` | Translate What I See | yes | Into (default "Turkish") | `translation.view` |

`AutoLoomActionEntity` ("AutoLoom Action") shows each action's title in the app's language with its first example as subtitle. Its query (`AutoLoomActionQuery`) suggests the `quick` actions and those with a dedicated intent, and resolves any action by id; it has no text search (`EntityStringQuery` is not implemented), so whether other actions can be picked in the Shortcuts editor must be checked on the device.

### App Shortcuts (Siri phrases)

The app's display name is "AutoLoom" (alternative names "AutoLoom Media Glasses", "Auto Loom"); iOS requires the app name in each phrase. A personal shortcut can use any name.

| Shortcut | Phrases |
|---|---|
| Start Conversation | "Start AutoLoom", "Talk to AutoLoom", "Open AutoLoom conversation" |
| Ask | "Ask AutoLoom", "Ask AutoLoom a question" |
| New Note | "Create a note in AutoLoom", "New AutoLoom note" |
| Live Vision | "Start live vision in AutoLoom", "AutoLoom live vision" |
| New Task | "New AutoLoom task", "Add a task in AutoLoom" |
| Remember This | "Remember this in AutoLoom", "AutoLoom remember this" |
| Dealer Session | "Start a dealer session in AutoLoom", "New vehicle in AutoLoom" |
| Today's Briefing | "AutoLoom today's briefing", "What's my day in AutoLoom" |
| Ray-Ban Photo | "Take a Ray-Ban photo with AutoLoom", "AutoLoom take a photo" |
| Shopping List | "Add to my AutoLoom shopping list", "AutoLoom shopping list" |

The other seven intents (Run AutoLoom Action, Start/Stop Ray-Ban Recording, Search AutoLoom, Find Vehicle, Create Vehicle Task, Translate What I See) have no Siri phrase; they are available as actions in the Shortcuts app and for the Action button.

### Status

| Item | Status |
|---|---|
| Intents run the same executor as speech (`ActionCatalog.run`) | WORKING (unit-tested logic) |
| Siri phrases, Shortcuts actions, the Action button | PHYSICAL_TEST_REQUIRED |
| "Hey Meta, start AutoLoom" | WAITING_FOR_DAT1 (`HandsFreeCapabilities.metaInvocationAvailable = false`) |
| Widgets, Control Center controls, Live Activities | UNAVAILABLE |
