# Action Catalog

`ios/GlassifAI/Runtime/ActionCatalog.swift` lists every action the assistant can do as plain data (`ActionDefinition`). The voice parser's tests, the App Intents, the Command Library, the command palette, the Command Lab, user routines and the offline assistant all read the same list, and `AutoLoomActionCatalogTests` fails the CI test run when an entry is incomplete or its example sentences do not reach it through the parser that speech uses. The catalog does not parse speech itself: `VoiceActionIntentBridge` decides, and the catalog maps each decision back to an entry. This page describes commit `8ee1a24` (108 actions; the catalog has not changed since `b5802bd`).

## What an `ActionDefinition` contains

| Field | Meaning | Read at runtime by |
|---|---|---|
| `id` | Stable id, e.g. `note.create` | Everything below |
| `category` | One of 12 categories (next table) | Command Library, "Neler yapabilirsin?" |
| `name`, `nameTR`, `summary` | Titles (English, Turkish) and one line | UI, tool descriptions |
| `examplesTR`, `examplesEN` | Example sentences; a leading `[tag]` sets up test context | Tests, UI, on-device classifier |
| `negatives` | Sentences that must not reach the action | Tests only |
| `parameters` | Name, kind (`text`, `date`, `duration`, `contact`, `place`, `language`, `number`, `items`), required, summary | App Intents, palette, routines, tool schemas |
| `risk` | `SAFE`, `CONFIRM`, `STRONG_CONFIRM`, `BLOCKED` | `run` (refuses `BLOCKED`), badges, routines, offline assistant |
| `confirmation` | `none`, `whenAmbiguous`, `always`, `tapOnPhone` | Routine eligibility, Command Lab |
| `permissions`, `capabilities` | iOS permissions; needs such as `rayBanCamera`, `network`, `location`, `dealerSession`, `dat1` | Not read by app code (documentation) |
| `offline` | Works without internet (default `true`) | Command Library badge, offline assistant |
| `undo` | `supported`, `notApplicable`, `notSupported`, `impossible` | Documentation only |
| `route` | `local` (the app's parser), `conversation` (stop/end), `delegation(word)` (the voice model's `TASK:`) | `run`, palette, Command Lab, routines |
| `localPriority` | Must be recognised before any cloud reasoning | Tests |
| `appIntent` | The App Intent type that exposes it | Shortcuts suggestions, tests |
| `ui` / `voiceOnlyReason` | Where it is on screen, or why it has no screen | Tests (one of the two is required) |
| `status` | A `CapabilityStatus` label (default `EXPERIMENTAL`) | Command Library badge |
| `keys` | `VoiceIntent.catalogKey` values that are this action | Lookup from a parser decision |
| `quick` | Shown first in the palette and suggested in Shortcuts | Palette, App Intents, "Neler yapabilirsin?" |

`risk` and `confirmation` describe the intended behaviour; the executors enforce confirmation themselves (`DeviceActionPlan.risk`, `AssistantOrchestrator.stage`). A spoken yes is refused for `STRONG_CONFIRM` plans, and waiting actions expire after 120 s.

## Categories

| Category | Turkish | Actions |
|---|---|---|
| `general` | Genel | 13 |
| `camera` | Kamera | 8 |
| `vision` | Görüş | 8 |
| `memory` | Hafıza | 11 |
| `tasks` | Görevler | 10 |
| `dealer` | Bayi | 26 |
| `phone` | Telefon | 3 |
| `navigation` | Yol tarifi | 7 |
| `translation` | Çeviri | 1 |
| `research` | Araştırma | 2 |
| `media` | Medya | 5 |
| `automation` | Otomasyon | 14 |

Status labels in the catalog: 71 `EXPERIMENTAL`, 22 `PHYSICAL_TEST_REQUIRED`, 13 `WORKING`, 1 `PARTIAL`, 1 `REQUIRES_PROVIDER`. No action uses `WAITING_FOR_DAT1`, `REQUIRES_PERMISSION`, `UNAVAILABLE` or risk `BLOCKED`. Risks: 100 `SAFE`, 6 `CONFIRM`, 2 `STRONG_CONFIRM`.

## How the catalog is used

**Voice.** The parser returns a `VoiceIntent`; `ActionCatalog.definition(for:)` finds the entry through `catalogKey` → `keys`. The entry names the action in the action trace, in the Command Lab and in "several steps" reports. `instructionsSummary` (one example line per category for the voice model) exists but no code uses it in this build.

**One executor: `ActionCatalog.run(id, parameters, transcript)`.**
1. Unknown id → "Unknown action"; `BLOCKED` → refused.
2. `intent(for:parameters:)` builds the same `VoiceIntent` the parser would (for example `timer.start` with `duration: "10 dakika"` → 600 s). Actions that need the user's words return `ask` (the assistant asks) or nil.
3. A `delegation` route runs directly: Live Vision start/stop, or a vision, web or reasoning task.
4. Otherwise the words themselves go through `VoiceActionIntentBridge.decide`.
5. Nothing matched → "Say it with the details, for example: …".

**App Intents.** `RunAutoLoomActionIntent` offers every action as an `AutoLoomActionEntity`; its "Details" text fills the action's first parameter. Suggested entities are the `quick` actions and those with an `appIntent`. The dedicated intents also call `ActionCatalog.run` (see [APP_INTENTS.md](APP_INTENTS.md)).

**Agent tools.** `toolSchemas()` turns non-`BLOCKED`, non-conversation actions into JSON-schema functions (`note.create` → `note_create`; string parameters; description = summary + first English example); `id(forTool:)` maps back. Tested for valid JSON and unique names, but no provider adapter sends these tools in this build (**PARTIAL**).

**On-device model.** `LocalBrain.classify` shows the on-device model the first 60 local, non-`BLOCKED` actions (catalog order, without the yes/no answers) with their first Turkish example; the other 38 (from `dealer.readOdometer` on: timers, shopping, parking, phone, maps…) are cut off. `OfflineAssistant` runs its choice only when confidence ≥ 70, the action is `SAFE` and `offline` (see [APPLE_INTELLIGENCE.md](APPLE_INTELLIGENCE.md)).

**Command Library** (Settings → Command Library, also opened by "Neler yapabilirsin?"). Search uses `ActionCatalog.search` (word match over names, summary and examples). Badges: "Sorar/Asks" for `CONFIRM`, "Dokunuş/Tap" for `STRONG_CONFIRM`, "Çevrimdışı/Offline", and the status title unless it is `EXPERIMENTAL` or `WORKING`. **Run** appears only for actions with no required parameter, `SAFE`, not conversation control, with a buildable intent and no `ask.`/`confirmPending` key.

**Command palette** (Assistant → Commands button). Local-route actions, `quick` first; an action without parameters runs when tapped; otherwise a field takes the first parameter. It runs through `ActionCatalog.run`.

**Command Lab** (Settings → Developer → Command Lab). A dry run shows the transcript, normalised words, intent, parser rule, level (LEVEL 1 parser or LEVEL 2 model classification), catalog id and name, parameters, `risk · confirmation`, route and the steps of a multi-command sentence. "Gerçekten çalıştır / Run for real" executes it like speech and shows the executor from the action trace.

**User routines** (Explore → Routines). Steps may only be actions with route `local`, risk `SAFE` and confirmation `none`, excluding `action.confirm`, `action.cancel`, `undo.last`, `help.capabilities`, `conversation.*` and `routine.user`; at most 8 steps. A step that would only ask a question is reported as not done.

## Consistency tests (`GlassifAITests/AutoLoomActionCatalogTests.swift`)

| Test | Checks |
|---|---|
| `testEveryActionIsComplete` | Unique ids and keys; a Turkish example; at least two examples; a UI or a voice-only reason; `local` route has keys; non-`SAFE` risk is never confirmation `none`; `appIntent` is one of the 17 declared intents; names present; at least 80 actions |
| `testEveryExampleReachesItsAction` | Every example of every `local` action, with its context tags, reaches that action through `VoiceActionIntentBridge.decide` |
| `testNegativesDoNotReachTheAction` | No negative sentence reaches its action |
| `testDelegatedExamplesAreLeftToTheVoiceModel` | Examples of `delegation` actions are not taken by the parser |
| `testConversationExamplesStopOrEnd` | Examples of `conversation` actions are classified by `ConversationCommands` while the assistant speaks |
| `testHighPriorityCommandsAreDeterministic` | Stop, recording, photo, note, task, reminder, timer, copy, cancel and confirm are `localPriority` and decided at LEVEL 1 |
| `testEveryIntentHasACatalogEntry` | Every `VoiceIntent` and `DealerCommand` case maps to an entry |
| `testToolSchemasAreValid` | Tool JSON is valid, names unique, `note_create` ↔ `note.create`, no `conversation_stop` |
| `testParametersBuildTheSameIntentsAsSpeech` | Parameters build the same intents as speech |
| `testCommandLibrarySearchFindsByExample`, `testTagsAreStripped` | Search and tag handling |

Context tags used in examples: `pending` and `ambiguous` (an action waits for yes/no or morning/evening), `tasks` (a task runs), `timer`, `recording`, `vehicle` (a Dealer vehicle is active), `live` (Live Vision on), `routine` (a routine "Sabah turu" exists), `skill` (an MCP skill "Notion" exists), `camera`, `visual` (camera and visual memories on), `answer` (the assistant just answered), `saved` (something was just saved), `contact`, `recent` (a timed item was just saved). The comment in `ActionDefinition` lists fewer tags than the test supports.

`AutoLoomVoiceEvaluationTests` adds everyday phrases per area (≥ 90 % must reach their action) and two command chains. These tests run on CI; they were not run for this page.

## All actions

`[tag]` in an example is the context it needs (see above). Route `model: …` means the voice model decides (`TASK:`), not the app's parser.

| id | Category | Turkish example | Risk | Confirmation | Route | Status |
|---|---|---|---|---|---|---|
| `conversation.stop` | general | Dur | SAFE | none | conversation | PHYSICAL_TEST_REQUIRED |
| `conversation.end` | general | Konuşmayı bitir | SAFE | none | conversation | PHYSICAL_TEST_REQUIRED |
| `action.confirm` | general | [pending] Evet | SAFE | none | local | EXPERIMENTAL |
| `action.cancel` | general | [pending] Hayır | SAFE | none | local | EXPERIMENTAL |
| `action.chooseTime` | general | [ambiguous] Akşam | SAFE | none | local | EXPERIMENTAL |
| `action.correct` | general | [pending] Hayır, cumartesi | SAFE | none | local | EXPERIMENTAL |
| `undo.last` | general | Son yaptığını geri al | SAFE | none | local | EXPERIMENTAL |
| `help.capabilities` | general | Neler yapabilirsin? | SAFE | none | local | EXPERIMENTAL |
| `search.global` | general | Geçen hafta Corolla ile ilgili kaydettiğim şeyi bul | SAFE | none | local | EXPERIMENTAL |
| `profile.setName` | general | Benim adım Tolga | SAFE | none | local | EXPERIMENTAL |
| `profile.askName` | general | Benim adım ne? | SAFE | none | local | EXPERIMENTAL |
| `routine.startWork` | automation | İşe başlıyorum | SAFE | none | local | EXPERIMENTAL |
| `routine.briefing` | automation | Günün özeti | SAFE | none | local | EXPERIMENTAL |
| `routine.eveningReview` | automation | Bugün ne yaptım? | SAFE | none | local | EXPERIMENTAL |
| `routine.weeklyReview` | automation | Haftalık özet | SAFE | none | local | EXPERIMENTAL |
| `graph.run` | automation | Alışveriş listesine süt ekle ve 10 dakika timer kur | SAFE | none | local | EXPERIMENTAL |
| `note.create` | memory | Not al: yarın kamerayı getir | SAFE | none | local | PHYSICAL_TEST_REQUIRED |
| `note.list` | memory | Notlarım neler? | SAFE | none | local | EXPERIMENTAL |
| `note.search` | memory | Mercedes için aldığım notları söyle | SAFE | none | local | EXPERIMENTAL |
| `note.delete` | memory | Bu notu sil | CONFIRM | always | local | EXPERIMENTAL |
| `memory.save` | memory | Bunu hatırla: arabam siyah | SAFE | none | local | EXPERIMENTAL |
| `memory.recall` | memory | Hatırlıyor musun kapı kodunu? | SAFE | none | local | EXPERIMENTAL |
| `memory.conversation` | memory | Geçen hafta bununla ilgili ne konuşmuştuk? | SAFE | none | local | EXPERIMENTAL |
| `memory.list` | memory | Ne hatırlıyorsun? | SAFE | none | local | EXPERIMENTAL |
| `memory.forget` | memory | Kapı kodunu unut | CONFIRM | always | local | EXPERIMENTAL |
| `memory.visual` | memory | [visual] Anahtarımı buraya bıraktığımı hatırla | SAFE | none | local | EXPERIMENTAL |
| `memory.findVisual` | memory | Anahtarımı en son nerede gördüm? | SAFE | none | local | WORKING |
| `task.create` | tasks | Görev oluştur: lastikleri kontrol et | SAFE | none | local | EXPERIMENTAL |
| `task.list` | tasks | Görevlerim neler? | SAFE | none | local | EXPERIMENTAL |
| `task.complete` | tasks | Lastik görevini tamamla | SAFE | none | local | EXPERIMENTAL |
| `task.move` | tasks | [saved] Bunu yarına taşı | SAFE | none | local | EXPERIMENTAL |
| `reminder.create` | tasks | Yarın 10'da Ahmet'i aramayı hatırlat | SAFE | none | local | EXPERIMENTAL |
| `reminder.place` | tasks | Eve varınca süt almayı hatırlat | SAFE | none | local | PHYSICAL_TEST_REQUIRED |
| `notification.schedule` | tasks | 20 dakika sonra bana haber ver | SAFE | none | local | EXPERIMENTAL |
| `calendar.read` | tasks | Bugün takvimimde ne var? | SAFE | none | local | EXPERIMENTAL |
| `calendar.create` | tasks | Cuma 3'te toplantı ekle | SAFE | whenAmbiguous | local | EXPERIMENTAL |
| `dayplan.read` | tasks | Bugün ne yapmam gerekiyor? | SAFE | none | local | EXPERIMENTAL |
| `camera.photo` | camera | Fotoğraf çek | SAFE | none | local | PHYSICAL_TEST_REQUIRED |
| `camera.recordStart` | camera | Video kaydını başlat | SAFE | none | local | PHYSICAL_TEST_REQUIRED |
| `camera.recordStop` | camera | [recording] Kaydı durdur | SAFE | none | local | PHYSICAL_TEST_REQUIRED |
| `camera.recordStatus` | camera | Kayıt yapıyor musun? | SAFE | none | local | EXPERIMENTAL |
| `captures.saveToPhotos` | camera | Galeriye kaydet | SAFE | none | local | EXPERIMENTAL |
| `code.read` | camera | QR kodu oku | SAFE | none | local | EXPERIMENTAL |
| `vision.describe` | vision | Ne görüyorum? | SAFE | none | model: vision | PHYSICAL_TEST_REQUIRED |
| `vision.read` | vision | Şunu oku | SAFE | none | model: vision_read | PHYSICAL_TEST_REQUIRED |
| `vision.live` | vision | Bakmaya devam et | SAFE | none | model: live_vision_start | PHYSICAL_TEST_REQUIRED |
| `vision.liveStop` | vision | Canlı görüşü kapat | SAFE | none | model: live_vision_stop | EXPERIMENTAL |
| `vision.whatChanged` | vision | [live] Ne değişti? | SAFE | none | local | PHYSICAL_TEST_REQUIRED |
| `media.play` | media | Müzik çal | SAFE | none | local | PARTIAL |
| `media.pause` | media | Müziği durdur | SAFE | none | local | WORKING |
| `media.next` | media | Sonraki şarkı | SAFE | none | local | WORKING |
| `media.previous` | media | Önceki şarkı | SAFE | none | local | WORKING |
| `media.nowPlaying` | media | Ne çalıyor? | SAFE | none | local | WORKING |
| `remoteAssist.start` | camera | Uzaktan yardımı başlat | CONFIRM | tapOnPhone | local | PHYSICAL_TEST_REQUIRED |
| `remoteAssist.stop` | camera | Paylaşımı durdur | SAFE | none | local | WORKING |
| `shortcut.run` | automation | Işıkları Aç kısayolunu çalıştır | STRONG_CONFIRM | tapOnPhone | local | PHYSICAL_TEST_REQUIRED |
| `skill.call` | automation | [skill] Notion ile bugünkü görevlerimi listele | CONFIRM | always | local | REQUIRES_PROVIDER |
| `routine.user` | automation | [routine] Sabah turu rutinini başlat | SAFE | none | local | WORKING |
| `document.summarize` | vision | Bu belgeyi özetle | SAFE | none | local | PHYSICAL_TEST_REQUIRED |
| `document.receipt` | vision | Fişi kaydet | SAFE | none | local | PHYSICAL_TEST_REQUIRED |
| `document.spending` | vision | Bu ay ne harcadım? | SAFE | none | local | WORKING |
| `translation.view` | translation | [camera] Bu tabelayı Türkçeye çevir | SAFE | none | local | EXPERIMENTAL |
| `research.web` | research | Bugün hava nasıl? | SAFE | none | model: web | EXPERIMENTAL |
| `research.reasoning` | research | Bu iki teklifi detaylı karşılaştır | SAFE | none | model: reasoning | EXPERIMENTAL |
| `dealer.start` | dealer | Yeni araç | SAFE | none | local | EXPERIMENTAL |
| `dealer.next` | dealer | Sonraki araç | SAFE | none | local | EXPERIMENTAL |
| `dealer.finish` | dealer | Bu araç tamam | SAFE | none | local | EXPERIMENTAL |
| `dealer.saveVehicle` | dealer | [vehicle] Aracı kaydet | SAFE | none | local | EXPERIMENTAL |
| `dealer.readVIN` | dealer | VIN oku | SAFE | none | local | PHYSICAL_TEST_REQUIRED |
| `dealer.recall` | dealer | [vehicle] Recall kontrol et | SAFE | none | local | EXPERIMENTAL |
| `dealer.readOdometer` | dealer | Kilometreyi oku | SAFE | none | local | PHYSICAL_TEST_REQUIRED |
| `dealer.setOdometer` | dealer | Kilometre 45 bin 320 | SAFE | none | local | EXPERIMENTAL |
| `dealer.damage` | dealer | Hasar ekle: sağ ön çamurluk çizik | SAFE | none | local | EXPERIMENTAL |
| `dealer.photoChecklist` | dealer | Foto checklist | SAFE | none | local | EXPERIMENTAL |
| `dealer.deliveryChecklist` | dealer | Delivery checklist | SAFE | none | local | EXPERIMENTAL |
| `dealer.market` | dealer | Piyasa bak | SAFE | none | local | EXPERIMENTAL |
| `dealer.listing` | dealer | İlan hazırla | SAFE | none | local | EXPERIMENTAL |
| `dealer.summary` | dealer | Araç durumu | SAFE | none | local | EXPERIMENTAL |
| `dealer.briefing` | dealer | Bayi özeti | SAFE | none | local | EXPERIMENTAL |
| `dealer.decodeVIN` | dealer | VIN'i çöz | SAFE | none | local | WORKING |
| `dealer.readTire` | dealer | Lastiği oku | SAFE | none | local | PHYSICAL_TEST_REQUIRED |
| `dealer.dashboard` | dealer | Uyarı ışıklarına bak | SAFE | none | local | PHYSICAL_TEST_REQUIRED |
| `dealer.conditionReport` | dealer | Kondisyon raporu | SAFE | none | local | WORKING |
| `dealer.serviceHandoff` | dealer | Servis notu hazırla | SAFE | none | local | WORKING |
| `dealer.lotSave` | dealer | [vehicle] Aracın yerini kaydet | SAFE | none | local | PHYSICAL_TEST_REQUIRED |
| `dealer.lotFind` | dealer | [vehicle] Araç nerede duruyor? | SAFE | tapOnPhone | local | EXPERIMENTAL |
| `dealer.partNumber` | dealer | Parça numarasını oku | SAFE | none | local | PHYSICAL_TEST_REQUIRED |
| `dealer.areaClear` | dealer | [vehicle] Sol taraf temiz | SAFE | none | local | WORKING |
| `dealer.export` | dealer | Aracı dışa aktar | SAFE | tapOnPhone | local | WORKING |
| `dealer.vehicleQuestion` | dealer | [vehicle] Kaç kilometre? | SAFE | none | local | EXPERIMENTAL |
| `timer.start` | automation | 10 dakika timer kur | SAFE | none | local | EXPERIMENTAL |
| `timer.cancel` | automation | Timerı durdur | SAFE | none | local | EXPERIMENTAL |
| `timer.remaining` | automation | Timer ne kadar kaldı | SAFE | none | local | EXPERIMENTAL |
| `shopping.add` | automation | Alışveriş listesine süt ve ekmek ekle | SAFE | none | local | EXPERIMENTAL |
| `shopping.read` | automation | Alışveriş listemde ne var | SAFE | none | local | EXPERIMENTAL |
| `shopping.remove` | automation | Sütü alışveriş listesinden çıkar | SAFE | none | local | EXPERIMENTAL |
| `parking.save` | navigation | Park yerimi kaydet | SAFE | none | local | PHYSICAL_TEST_REQUIRED |
| `parking.recall` | navigation | Arabam nerede? | SAFE | none | local | EXPERIMENTAL |
| `parking.directions` | navigation | Beni arabama götür | SAFE | none | local | EXPERIMENTAL |
| `parking.clear` | navigation | Park yerini sil | SAFE | none | local | EXPERIMENTAL |
| `phone.call` | phone | Ahmet'i ara | CONFIRM | tapOnPhone | local | EXPERIMENTAL |
| `phone.message` | phone | Ahmet'e 10 dakika gecikeceğim diye mesaj yaz | STRONG_CONFIRM | tapOnPhone | local | EXPERIMENTAL |
| `contact.find` | phone | Ahmet'in numarası ne? | SAFE | none | local | EXPERIMENTAL |
| `maps.directions` | navigation | Beni eve götür | SAFE | whenAmbiguous | local | EXPERIMENTAL |
| `maps.nearby` | navigation | En yakın benzinliğe götür | SAFE | none | local | EXPERIMENTAL |
| `maps.inView` | navigation | [camera] Buraya yol tarifi aç | CONFIRM | tapOnPhone | local | EXPERIMENTAL |
| `text.copy` | general | [answer] Bunu kopyala | SAFE | none | local | EXPERIMENTAL |
| `text.share` | general | [answer] Bunu paylaş | SAFE | tapOnPhone | local | EXPERIMENTAL |

The "Status" column is the label written in the catalog. It is not a test result: `EXPERIMENTAL` is the initializer default, and several camera actions (`memory.visual`, `code.read`, `translation.view`, `maps.inView`) still need a device test even though their label does not say so.

## Status

| Item | Status |
|---|---|
| Catalog data and consistency tests | WORKING |
| `ActionCatalog.run` shared by App Intents, palette, Command Library, routines | WORKING (logic); PHYSICAL_TEST_REQUIRED from Siri/Shortcuts |
| Command Library, command palette, Command Lab screens | EXPERIMENTAL (screens are not unit-tested) |
| Tool schemas for agents | PARTIAL (built and tested, not sent to any provider) |
| `instructionsSummary` for the voice model | UNAVAILABLE (defined, not used) |
| On-device classification from the catalog | PHYSICAL_TEST_REQUIRED (needs an Apple Intelligence iPhone) |
