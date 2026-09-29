# Apple Intelligence (on-device model)

AutoLoom can use Apple's on-device Foundation Models for small private jobs: titling and tagging voice notes, noticing the vehicle, person, place or product being talked about, summarising a finished conversation or a document, rewriting a search that found nothing, and a short answer when the phone is offline. The model is optional. Without it (older iOS, an iPhone without Apple Intelligence, the model still downloading, the setting off) the deterministic parser and the cloud agents do the same work as before. The on-device model never executes anything itself: it can propose an Action Catalog action, which then runs through the same executor and rules as speech. Code: `Runtime/LocalBrain.swift`, `Runtime/LocalBrain27.swift`, `Runtime/OfflineAssistant.swift`.

## How it is linked

- Deployment target iOS 17.0. `FoundationModels` (and `Translation`) are **weak-linked** (`OTHER_LDFLAGS = -weak_framework FoundationModels -weak_framework Translation` in Debug and Release).
- All model code is inside `#if canImport(FoundationModels)` and `if #available(iOS 26.0, *)`; the iOS 27 additions are in `LocalBrain27.swift` behind `@available(iOS 27.0, *)`.
- `LocalBrain.isReady` = the setting is on **and** `SystemLanguageModel.default.availability` is `.available`. Every job returns nil otherwise.

## Settings

Settings → Intelligence → "On this iPhone":

| Control | Default | Shows / does |
|---|---|---|
| "Cihazdaki modeli kullan / Use the on-device model" | On | Turns every on-device job off when switched off |
| "Apple Intelligence" status | — | "Hazır (Türkçe ve İngilizce)", "Hazır (henüz Türkçe yok)", "This iPhone does not support Apple Intelligence.", "Apple Intelligence is turned off in Settings.", "The on-device model is still downloading.", or "iOS 26 ve Apple Intelligence gerekir" |

Turkish support is checked at runtime with `supportsLocale(tr_TR)`; the code comment says Turkish needs iOS 26.1+ models. When Turkish is not supported the model may still be "ready" for English.

## Profiles

Each job uses one profile. Every profile starts with the same base: it runs on the user's iPhone inside AutoLoom, the locale is `tr_TR`, it answers in the user's language (Turkish unless they wrote English), and it is brief and factual and never invents facts, names, prices or results.

| Profile | Extra instruction | Temperature | Used by |
|---|---|---|---|
| `fastLocal` | Map requests to the listed actions only, else "none" | 0.1 | classification, entities, search rewrite |
| `memory` | Work only with the notes and memories given; say when something is not there | 0.1 | note titles, conversation summaries, iOS 27 search answer |
| `dealer` | Never state a VIN, option, price or condition not given; never say a car is safe to drive | 0.1 | Defined; no job uses it yet |
| `document` | Summarise faithfully; keep dates, amounts and names exactly | 0.1 | document summaries |
| `translation` | Translate faithfully and briefly | 0.1 | Defined; no job uses it yet (translation uses Apple Translation instead) |
| `general` | The offline fallback: general knowledge in one or two sentences; say when the internet is needed | 0.4 | offline answers |

Sessions: each request creates a `LanguageModelSession`. On iOS 27 it is built from `AutoLoomBrainProfile`, a `LanguageModelSession.DynamicProfile` whose body sets the profile's instructions and temperature; on iOS 26 from the plain instructions string.

## What runs on the device

| Job | Function | Called from | Input limit | Output |
|---|---|---|---|---|
| Action classification | `classify` | `OfflineAssistant` (typed questions and "Ask AutoLoom" while offline) | The first 60 eligible local catalog actions in catalog order (see below) | Action id, words, time, confidence 0–100 (`@Generable LocalActionChoice`) |
| Note title and tags | `noteLabels` | `NoteEnricher` after a voice note, only while the title is still the automatic one | Notes ≥ 12 characters, first 1,500 characters | Title ≤ 6 words (kept ≤ 80 characters), ≤ 3 tags |
| Entities | `entities` | Every user turn (`noteUserTurn` → `EntityContext`) | 600 characters | Vehicle, person, place, product |
| Document summary | `summarize` | "Bu belgeyi özetle" | 6,000 characters | ≤ 3 sentences; passed to the voice model as "Summary made on this iPhone" |
| Search rewrite | `rewriteSearch` | Global search when nothing was found | — | 3–6 keywords, Turkish and English |
| Conversation summary | `conversationSummary` | End of a meaningful conversation; tried before the cloud | Last 6,000 characters; transcript ≥ 40 characters | Summary, topics, decisions, open tasks, entities |
| Offline answer | `answerOffline` | `OfflineAssistant` fallback | — | One or two sentences, labelled offline |
| Answer from my data (iOS 27) | `answerFromMyData` | Global search when the rewrite also found nothing | — | An answer built only from AutoLoom's Spotlight items |

On iOS 27, `answerFromMyData` gives the model a `SpotlightSearchTool` over this app's Core Spotlight items (`fetchAttributes: title, contentDescription, keywords`, guide `.focused(.documents)`) with the `memory` instructions plus "search the user's AutoLoom items before answering and answer only from what the search returns". What is indexed is described in [SPOTLIGHT.md](SPOTLIGHT.md); the index uses complete file protection, so it can only be searched while the iPhone is unlocked.

Errors are recorded in `LocalBrain.lastError` as a short reason without user content ("context window exceeded", "guardrail", "language not supported", "rate limited", "busy").

## Offline behaviour

- **Voice conversations need the network** (ChatGPT's realtime voice). Offline, a start fails with "Bağlantı kurulamadı." from an on-device Apple voice; nothing is faked.
- **Typed questions** (Assistant → keyboard) and **Siri "Ask AutoLoom"** use the app's parser first, so notes, tasks, reminders, timers, the shopping list, parking, QR codes and other local commands still run offline.
- If the parser finds nothing, the phone is offline and the model is ready, `OfflineAssistant.handle` runs:
  1. `classify`; the chosen action runs only if confidence ≥ 70, its catalog risk is `SAFE` and it is marked `offline`.
  2. Else a short answer prefixed "Çevrimdışı — bu iPhone'dan kısa bir yanıt: …".
  3. Else the notice "Çevrimdışıyım; bunun için internet gerekli. Notlar, görevler, hatırlatıcılar, zamanlayıcı, alışveriş listesi ve QR kodlar yine çalışır."
- Without the model the same typed request gets the parser only; the unit test checks that `classify` and `noteLabels` return nil and that "Bugün hava nasıl?" gets exactly the offline notice.
- The app never claims an internet result offline.

## Honest limits

- CI simulators have no Apple Intelligence, so the jobs above have never run in CI; only the no-model path is unit-tested (`AutoLoomAppleIntelligenceTests`).
- Turkish depends on Apple's model supporting `tr_TR`; the app shows "Hazır (henüz Türkçe yok)" when it does not.
- The on-device model is small: classifications below 70 confidence are ignored, and it is never used in place of the connected agents for harder questions.
- The classifier's action list is cut at 60 of the 98 eligible local actions (`.prefix(60)` in catalog order). Everything from `dealer.readOdometer` on — most Dealer actions, timers, the shopping list, parking, calls, messages, maps, copy and share — is never offered to the model. Those still work offline through the parser when phrased as commands ("10 dakika timer kur"), just not from free wording.
- The iOS 27 code uses `LanguageModelSession.DynamicProfile`, `LanguageModelSession(profile:)` and `SpotlightSearchTool` as written in `LocalBrain27.swift`. This page does not verify those APIs against Apple's SDK; the CI build of the commit is the check.
- Not every on-device result is shown to the user: entity notes and search rewrites are silent helpers.

## Status

| Item | Status |
|---|---|
| Optional, weak-linked model; honest status text; no-model fallbacks | WORKING |
| Note titles/tags, entities, conversation and document summaries on device | PHYSICAL_TEST_REQUIRED (Apple Intelligence iPhone, iOS 26+) |
| Offline classification and short answers | PHYSICAL_TEST_REQUIRED |
| Turkish on-device answers | PHYSICAL_TEST_REQUIRED (depends on model support) |
| iOS 27 Dynamic Profiles and `SpotlightSearchTool` answer | EXPERIMENTAL, PHYSICAL_TEST_REQUIRED (iOS 27 device) |
| `dealer` and `translation` profiles | UNAVAILABLE (defined, not used) |
