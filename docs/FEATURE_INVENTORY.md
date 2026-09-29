# Feature inventory (what exists in code today)

Branch `autoloom-glasses-jarvis-v1`, commit `405e461` (v1.4). Paths are relative to `ios/GlassifAI/Runtime/` unless they start with `Settings/`, `Views/`, `ViewModels/` or name the app root (`GlassifAIApp.swift`); `file:line` points at the main declaration.

**Status** is copied from `CAPABILITIES.md`; `Cnnn` is the line of that row. "not listed" = `CAPABILITIES.md` has no row for it. "not found" = no implementation in the code.

Not covered: uncommitted work that appeared in the working tree during this audit and is not in `405e461`. It includes the new files `ActionCatalog.swift`, `GlobalSearch.swift`, `IntentRunnerExtras.swift`, `JarvisSession.swift`, `MediaResourceCoordinator.swift`, `VoiceCommandsExtra.swift` and `ScreenshotMode.swift`, six new `VoiceIntent` cases, and edits to the bridge files. In the working tree, line numbers in `VoiceActionIntentBridge.swift`, `VoiceIntentRunner.swift`, `VoiceDealerCommands.swift`, `VoiceMediaCommands.swift` and `GlassifAIApp.swift` differ from the ones cited here.

## 1. Voice and conversation

| Feature | Main type (file:line) | Status |
|---|---|---|
| ChatGPT sign-in (device code), tokens in Keychain | `ChatGPTAuthSession` ChatGPTAuthSession.swift:53; `ChatGPTKeychain` ChatGPTKeychain.swift:12 | WORKING (C125) |
| Realtime voice call (WebRTC, `gpt-live-1-codex`), start ladder with recorded fallbacks | `GlassifAIRealtimeSession` GlassifAIRealtimeSession.swift:9; `EmbeddedCodexBridge` EmbeddedCodexBridge.swift:49; `RealtimeStartLadder` VoiceCatalog.swift:115 | WORKING (C126) |
| One idempotent start for the button, Siri and the wake phrase | `VoiceStartCoordinator` VoiceInvocation.swift:19 | not listed |
| 9 voices; selected vs active voice | `VoiceCatalog` VoiceCatalog.swift:24; `RealtimeStartReport` VoiceCatalog.swift:96 | PHYSICAL TEST REQUIRED (C127) / EXPERIMENTAL (C128) |
| Apply now, preview voice | `restartToApplySettings` GlassifAIRealtimeSession.swift:464; `previewVoice` :476 | PHYSICAL TEST REQUIRED (C132, C133) |
| Ready chime or phrase, greeting styles; failure tone plus on-device voice | `ConnectionFeedback` ConnectionFeedback.swift:31; `GreetingStyle` ConversationPolicy.swift:128; `LocalAnnouncer` ConnectionFeedback.swift:174 | PHYSICAL TEST REQUIRED (C130, C131) |
| Personality instructions (natural Turkish, adaptive length) | `AssistantInstructions.realtime` RoutingPolicy.swift:220 | EXPERIMENTAL (C134) |
| Stop words and end commands; quiet-conversation timeout | `ConversationCommands` ConversationPolicy.swift:14; `ConversationTimeout` :91 | PHYSICAL TEST REQUIRED (C135) / EXPERIMENTAL (C136) |
| Auto-reconnect | `RealtimeReconnectPolicy` GlassifAIRealtimeSession.swift:1501 | EXPERIMENTAL (C137) |
| One answer per command (model reply held back, app result spoken) | `interceptIfCommand` GlassifAIRealtimeSession.swift:910 | PHYSICAL TEST REQUIRED (C115) |
| Early delegation taken over; stable partial words finish a late turn | `takeOverDelegation` AssistantOrchestrator.swift:429; `finalizeUserTurnEarly` GlassifAIRealtimeSession.swift:1002 | PHYSICAL TEST REQUIRED (C95, C96) |
| Follow-up context ("bunu", "ona") | `VoiceBridgeContext` VoiceActionIntentBridge.swift:224; `ConversationContext` ConversationContext.swift:8 | EXPERIMENTAL (C106) |
| Typed questions and suggestion chips (same bridge as voice) | `AssistantOrchestrator.submitTyped` AssistantOrchestrator.swift:358 | not listed |
| Glasses temple tap mutes the mic; stop, fold or long press ends the call | `GlassesGestureSession` GlassesGestureSession.swift:48 (wired in Views/StreamSessionView.swift:170) | not listed |

## 2. Assistant name, wake and hands-free

| Feature | Main type | Status |
|---|---|---|
| Assistant name (default AutoLoom) | `AssistantIdentity` RoutingPolicy.swift:107 | EXPERIMENTAL (C143) |
| Recogniser spellings of the name ("Oto lum", "Carvis") | `AddressMatcher` VoiceActionIntentBridge.swift:1713 | PHYSICAL TEST REQUIRED (C94) |
| Addressed-only mode | `AssistantPreferences.respondsOnlyWhenAddressed` RoutingPolicy.swift:155 | not listed |
| Wake phrase, on-device | `WakePhraseListener` WakePhrase.swift:106; `WakePhraseMatcher` :9; `WakePhraseSettings` :60 | PHYSICAL TEST REQUIRED (C144) |
| States A–E (Hands-Free Ready in the background, glasses-connected arming) | `WakePhraseListener.Status` WakePhrase.swift:110 | PHYSICAL TEST REQUIRED / EXPERIMENTAL for A and E (C145) |
| Arming by wearing (`donState`), "Hey Meta, start …", system-wide wake word | not found (`HandsFreeCapabilities` VoiceInvocation.swift:231 reports them as unavailable) | UNAVAILABLE (C146–C148) |
| Routines "İşe başlıyorum" (also arms the wake phrase), "günün özeti" | `runRoutine` VoiceIntentRunner.swift:1622 | EXPERIMENTAL (C149) |
| Daily briefing on the first conversation of the day | `DailyBriefing` ConversationMemory.swift:79 | EXPERIMENTAL, off by default (C150) |

## 3. Local voice actions (the bridge)

| Feature | Main type | Status |
|---|---|---|
| LEVEL 1 parser (48 `VoiceIntent` cases) | `VoiceActionIntentBridge.decide` VoiceActionIntentBridge.swift:285; `VoiceIntent` :7 | EXPERIMENTAL (C113) |
| LEVEL 2 structured classification | `VoiceIntent.classify` → `runBridgeTask` AssistantOrchestrator.swift:1031 | EXPERIMENTAL (C114) |
| Runner (trace, feedback, conversation fact) and the action trace | `runVoiceIntent` VoiceIntentRunner.swift:285; `perform` :369; `ActionTraceLog` :31 | EXPERIMENTAL (C118, the trace) |
| Command kept 10 min for a missing permission | `PendingPermissionCommand` VoiceIntentRunner.swift:74; `resumePendingPermissionCommand` :336 | PHYSICAL TEST REQUIRED (C117) |
| Free-text delegations with an explicit command run through the bridge | `executeTask` AssistantOrchestrator.swift:477; `runAction` :854 | EXPERIMENTAL (C97) |
| Bridge questions ("Neyi not alayım?") and their answers | `VoiceIntent.Awaiting` VoiceActionIntentBridge.swift:9; `askQuestion` VoiceIntentRunner.swift:949 | not listed |
| Yes, no or morning/evening for a pending action | `confirmation` VoiceActionIntentBridge.swift:425; `stage` AssistantOrchestrator.swift:945 | EXPERIMENTAL (C113) |
| Camera, OCR and web text never trigger an action | only user words reach the bridge; `DeviceActionPlan.afterUntrustedContent` DeviceActions.swift:174 | UNAVAILABLE by design (C119) / EXPERIMENTAL (C179) |
| Feedback cards with haptics; Recent activity | `ActionFeedback` ActionFeedback.swift:8; `RecentActivityStrip` :282 | EXPERIMENTAL (C107) |
| Several commands in one sentence (only photo plus note) | `MediaTail` VoiceMediaCommands.swift:49 | PARTIAL (C83) |
| Deterministic time parsing | `TimePhraseParser` TimePhraseParser.swift:25 | EXPERIMENTAL (C172) |

## 4. Notes, memory, tasks

| Feature | Main type | Status |
|---|---|---|
| AutoLoom Notes; note verb anywhere, the user's verb decides | `notes` VoiceActionIntentBridge.swift:601; `MemoryStore.addNote` MemoryStore.swift:803 | EXPERIMENTAL (C163) / PHYSICAL TEST REQUIRED (C49) |
| Note list, search, delete (delete waits for a yes) | `noteQueries` VoiceActionIntentBridge.swift:663 | EXPERIMENTAL (C50) |
| Same note or task within 60 s stored once | `addNote` / `addTask` MemoryStore.swift:803 / :860 | EXPERIMENTAL (C98) |
| Memory store (SwiftData, 12 kinds) | `MemoryStore` MemoryStore.swift:505; `MemoryKind` :7 | EXPERIMENTAL (C156) |
| Save, recall, list and forget memories (bridge and delegation paths) | `memory` VoiceActionIntentBridge.swift:1449; `runMemory` AssistantOrchestrator.swift:1166 | EXPERIMENTAL (C156) |
| User profile name | `UserProfile` MemoryStore.swift:298; `profile` VoiceActionIntentBridge.swift:474 | EXPERIMENTAL (C157) |
| Conversation summaries; Smart Memory | `ConversationSummarizer` ConversationMemory.swift:6; instructions RoutingPolicy.swift:291 | EXPERIMENTAL (C158, C159) |
| Retrieval (stems, embedding, pinned, recency) | `MemorySearch` MemoryStore.swift:374 | PARTIAL (C160) |
| Visual memory | `runVisualMemory` AssistantOrchestrator.swift:1235 | PHYSICAL TEST REQUIRED (C162) |
| AutoLoom Tasks (voice create, list, complete; alert at the due time) | `createTask` VoiceIntentRunner.swift:1118; `TaskItem` MemoryStore.swift:251 | EXPERIMENTAL (C164) |
| Reports (web research saved as a note) | `runReport` AssistantOrchestrator.swift:1139 | EXPERIMENTAL (C230) |
| Apple Notes direct write; ChatGPT account memory | not found | UNAVAILABLE (C165, C166) |

## 5. Reminders, calendar, notifications

| Feature | Main type | Status |
|---|---|---|
| Reminders (create, list); local notifications | `reminders` VoiceActionIntentBridge.swift:731; `DeviceActionExecutor.createReminder` DeviceActions.swift:653; `LocalNotifications` :510 | PHYSICAL TEST REQUIRED (C173, C176) |
| Calendar (today, tomorrow, week, create) | `calendar` VoiceActionIntentBridge.swift:886; `readEvents` DeviceActions.swift:720 | PHYSICAL TEST REQUIRED (C174) |
| Day plan (tasks + Reminders + calendar) | `runDayPlan` VoiceIntentRunner.swift:1200 | PHYSICAL TEST REQUIRED (C99) |
| Place reminders at home or work (150 m Reminders alarm) | `placeTrigger` PlaceTriggers.swift:31; `locationAlarm` DeviceActions.swift:680 | PHYSICAL TEST REQUIRED (C79) |
| Planner path (model writes strict JSON, the app validates it) | `DeviceActionParser` DeviceActions.swift:297; `AssistantTools.actionSchema` RoutingPolicy.swift:534 | not listed separately |
| Email, purchases, payments, deleting data, posting refused locally | `ActionGuard` DeviceActions.swift:245 | UNAVAILABLE (C178) |

## 6. Calls, messages, contacts, maps, clipboard, share

| Feature | Main type | Status |
|---|---|---|
| Calls (Contacts, several matches asked, the iOS call prompt) | `prepareCall` VoiceIntentRunner.swift:1337 | PHYSICAL TEST REQUIRED (C100) |
| Messages (the compose sheet; "sent" only when Messages reports it) | `prepareMessage` VoiceIntentRunner.swift:1375; `SystemSheets` ActionFeedback.swift:166 | PHYSICAL TEST REQUIRED (C101) |
| Contact lookup | `lookUpContact` VoiceIntentRunner.swift:1430; `ContactsLookup` DeviceActions.swift:458 | PHYSICAL TEST REQUIRED (C102) |
| Maps: directions, home/work, nearby, an address from the answer, an address in view | `prepareDirections` VoiceIntentRunner.swift:1468; `prepareDirectionsInView` :1494 | PHYSICAL TEST REQUIRED (C103) |
| Copy; share | `copyToClipboard` VoiceIntentRunner.swift:1568; `prepareShare` :1592 | EXPERIMENTAL (C104) / PHYSICAL TEST REQUIRED (C105) |
| Open link (planner only), tap-only confirmation card | `PendingActionCard` ActionViews.swift:8; `URLSafety` PrivacyGuards.swift:39 | PHYSICAL TEST REQUIRED (C177) |
| Tool switches and the master switch | `ToolRegistry` ToolRegistry.swift:27 | not listed |

## 7. Ray-Ban connection, camera, vision, Live Vision

| Feature | Main type | Status |
|---|---|---|
| Registration only when needed; Meta AI callback on a cold launch | `WearableConnectionCoordinator` WearableConnection.swift:333 | PHYSICAL TEST REQUIRED (C189, C190) |
| Auto reconnect; "Meta AI didn't confirm" with Try Again | `GlassesConnectionReducer` WearableConnection.swift:95 | PHYSICAL TEST REQUIRED (C191, C192) |
| Camera or codec failure shown apart from the connection | `GlassesConnectionReducer` WearableConnection.swift:95 | EXPERIMENTAL (C193) |
| Forget glasses | `GlassesConnectionSection` Settings/SettingsView.swift:248 | PHYSICAL TEST REQUIRED (C194) |
| MWDAT app id and client token audit | `DATConfigurationAudit` WearableConnection.swift:240 | PHYSICAL TEST REQUIRED (C196) |
| Glasses stream (profiles, HEVC or raw, watchdog, decoder) | `StreamSessionViewModel` ViewModels/StreamSessionViewModel.swift:162; `VideoDecoder` ViewModels/VideoDecoder.swift:64 | WORKING on DAT 0.4.0 / EXPERIMENTAL on 0.5.0 (C203) |
| iPhone camera vision | `GlassifAICamera` GlassifAICamera.swift:7 | WORKING / EXPERIMENTAL (profiles, OCR, crop) (C202) |
| Vision with the phone locked, still-photo fallback | `GlassesLifecycleMonitor` GlassesLifecycle.swift:136; `StillPhotoCoordinator` VisionCapture.swift:256 | PHYSICAL TEST REQUIRED (C39, C204) |
| Lifecycle states; frame store, selection, encoder, source proof | `GlassesPipelineState` GlassesLifecycle.swift:7; `FrameStore` FramePipeline.swift:124; `FrameSelector` FrameSelection.swift:147 | EXPERIMENTAL (C205, C206) |
| High-detail retry, OCR hints, zoomed crop | `VisionAnswerCheck` AssistantFlows.swift:67; `OnDeviceTextRecognizer` TextRecognition.swift:29 | EXPERIMENTAL (C208) |
| Translate what is in view | `translation` VoiceActionIntentBridge.swift:995 | EXPERIMENTAL (C209) |
| Live Vision (silent scene notes during a conversation) | `LiveVisionController` LiveVision.swift:53 | not listed (only its App Intent, C180) |
| Web search with sources, vision + web | `runExecutor` AssistantOrchestrator.swift:723; `ResponsesClient` ResponsesClient.swift:81 | EXPERIMENTAL (C230) |
| Full-resolution `Camera.photo`; face recognition | not found | UNAVAILABLE (C210, C211) |

## 8. Photos, videos, captures

| Feature | Main type | Status |
|---|---|---|
| "Fotoğraf çek" → Ray-Ban photo → Photos (add-only) | `RayBanMediaCoordinator.takePhoto` RayBanMediaCoordinator.swift:149 | PHYSICAL TEST REQUIRED (C40) |
| Start and stop recording → Photos, including with the phone locked | `startRecording` / `stopRecording` RayBanMediaCoordinator.swift:267 / :347; `RayBanVideoRecorder` RayBanVideoRecorder.swift:22 | PHYSICAL TEST REQUIRED (C41, C42) |
| "Kayıt yapıyor musun?", "galeriye kaydet" | `statusSpeech` RayBanMediaCoordinator.swift:550; `saveToPhotos` :218 | not listed |
| Captures list, dealer labels, photo + note | `CaptureLibrary` CaptureLibrary.swift:133; `CapturesView` CaptureViews.swift:136 | EXPERIMENTAL (C43) |
| Save mode (always, ask, AutoLoom only); on-screen shutter and record buttons | `CaptureSaveMode` CaptureLibrary.swift:67; `RayBanCaptureControls` CaptureViews.swift:57 | not listed |

## 9. Dealer Mode

| Feature | Main type | Status |
|---|---|---|
| Vehicle sessions, one active | `DealerStore` DealerModel.swift:588; `runDealer` DealerRunner.swift:9 | EXPERIMENTAL (C58) |
| VIN reading with the check digit | `VINValidator` DealerModel.swift:70 | PHYSICAL TEST REQUIRED (C59) |
| Odometer by voice / by camera | `OdometerReading` DealerModel.swift:186 | EXPERIMENTAL / PHYSICAL TEST REQUIRED (C61) |
| Damage with body zones | `BodyZone` DealerModel.swift:300; `DamageFinding` :362 | EXPERIMENTAL (C62) |
| Photo, delivery and test-drive checklists (test drive has no voice command) | `DealerChecklists` DealerModel.swift:408 | EXPERIMENTAL (C63) |
| Market research, listing draft | DealerRunner.swift:131, :145 | EXPERIMENTAL (C64) |
| Recall and parts research | web research only (facets AgentRouter.swift:118) | PARTIAL (C65) |
| Briefing, vehicle summary, export | DealerRunner.swift:168, :175; `VehicleDetailView` DealerViews.swift:138 | EXPERIMENTAL (C66) |
| Make, model and year from the VIN; plate, customer and CRM data | not found | UNAVAILABLE (C60, C67) |

## 10. Daily life

| Feature | Main type | Status |
|---|---|---|
| Timers | `TimerCenter` DailyLife.swift:23; `runTimer` DailyRunner.swift:5 | PHYSICAL TEST REQUIRED (C73) |
| Shopping list | `ShoppingListStore` DailyLife.swift:223; `runShopping` DailyRunner.swift:54 | EXPERIMENTAL (C74) |
| Parking | `ParkingStore` Parking.swift:37; `runParking` :192 | PHYSICAL TEST REQUIRED (C86) |
| QR code and barcode reading | `CodeReader` CodeReader.swift:9; `runCodeReading` :130 | PHYSICAL TEST REQUIRED (C80) |
| Place reminders | see §5 | PHYSICAL TEST REQUIRED (C79) |
| Today's and this week's review | `review` VoiceIntentRunner.swift:1681 | EXPERIMENTAL (C75) |
| Undo of the last local action | `LocalUndo` LocalUndo.swift:8 | EXPERIMENTAL (C76) |
| Modes | `AssistantMode` AssistantMode.swift:7 | EXPERIMENTAL (C77) |
| Long document reader; global search and history | `vision_read`; Memory search MemoryViews.swift:53 | PARTIAL (C82, C84) |
| Receipts, flights, widget, Live Activity, offline mode | not found | UNAVAILABLE (C81, C85, C233) |

## 11. Multi-agent providers, router, Jarvis persona

| Feature | Main type | Status |
|---|---|---|
| Orchestrator (LOCAL, FAST, SPECIALIST, TEAM) | `AgentRouter` AgentRouter.swift:145; `RequestAnalyzer` :5; `AutoLoomAgentOrchestrator` AgentTeam.swift:29 | EXPERIMENTAL (C20) |
| ChatGPT provider | `ChatGPTProvider` ProviderAdapters.swift:405 | WORKING (C21) |
| Local agent | `LocalProvider` ProviderAdapters.swift:491 | as listed per section (C22) |
| Claude, Gemini, Perplexity, OpenRouter | ProviderAdapters.swift:7, :93, :265, :323 | NOT CONNECTED (C23–C26) |
| OpenClaw (provider card; `TASK: agent` gateway) | `OpenClawProvider` ProviderAdapters.swift:516; `AgentGatewayClient` AgentGateway.swift:141 | PARTIAL (C27) / EXPERIMENTAL, optional (C181) |
| Fallback, circuit breaker, rate-limit pause | `ProviderRegistry` ProviderRegistry.swift:85 | EXPERIMENTAL (C28) |
| Team mode and result fusion | `ResultFusion` AgentTeam.swift:343 | EXPERIMENTAL (C29) |
| Provider settings, Keychain keys | `IntelligenceSettingsView` IntelligenceViews.swift:7; `ProviderCredentialStore` AIProvider.swift:209 | EXPERIMENTAL (C30) |
| Response normalizer | `ResponseNormalizer` ResponseNormalizer.swift:7 | EXPERIMENTAL (C31) |
| Jarvis Style; intensity and form of address | `JarvisStyle` ConnectionFeedback.swift:212, JarvisPersona.swift:52 | EXPERIMENTAL (C129) / PHYSICAL TEST REQUIRED (C32) |
| Model discovery and routing | `ModelRouting` ModelCatalog.swift:154; `ModelSelector` RoutingPolicy.swift:424 | EXPERIMENTAL (C231) |
| Delegation envelope (a `TASK:` … `QUERY:` line from the voice model) | `DelegationEnvelopeParser` RoutingPolicy.swift:23 | not listed |
| Gemini Live streaming API | not found | UNAVAILABLE (C33) |

## 12. App Intents and Shortcuts

`AutoLoomShortcuts` VoiceInvocation.swift:166 registers 9 App Shortcuts, one per intent.

| Intent | Main type | Status |
|---|---|---|
| Start Conversation / Ask AutoLoom / Create AutoLoom Note / Start Live Vision | VoiceInvocation.swift:94 / :108 / :125 / :146 | EXPERIMENTAL (C180) |
| Create Task / Remember This / Start Dealer Session / Today's Briefing / Add to Shopping List | MoreAppIntents.swift:5 / :26 / :47 / :60 / :74 | PHYSICAL TEST REQUIRED (C78) |

## 13. UI screens and tabs

| Screen | Main type | Status |
|---|---|---|
| Tabs Assistant, Memory, Tasks, Explore, Settings | `AppShellView` AppShellView.swift:12 | PHYSICAL TEST REQUIRED (C217 lists only 4 tabs; Explore is missing there) |
| Entry: onboarding → ChatGPT access → glasses setup | `VisionRootView` GlassifAIApp.swift:87; `OnboardingView` OnboardingView.swift:5; `HomeScreenView` Views/HomeScreenView.swift:7 | not listed / PHYSICAL TEST REQUIRED (C189) |
| Assistant screen (orb, voice bar, captions, typed answer, sources, pending card) | `AssistantHomeView` AssistantHomeView.swift:9 | PHYSICAL TEST REQUIRED (C218) |
| Orb states, status words | `AssistantOrb` AssistantOrb.swift:131; `AssistantPresence` :5 | PHYSICAL TEST REQUIRED (C221) / EXPERIMENTAL (C219) |
| Ray-Ban status pill, connected toast, link animation, haptics | PremiumUI.swift:43, :83, :140; `PressableButtonStyle` :7 | PHYSICAL TEST REQUIRED (C220, C222) |
| Memory tab / Tasks tab | `MemoryTabView` MemoryViews.swift:7 / `TasksTabView` TasksViews.swift:171 | PHYSICAL TEST REQUIRED (C161 / C175) |
| Explore tab: Dealer, Shopping list, Parking, Timers, Captures | `ExploreTabView` CaptureViews.swift:327 | not listed as a tab |
| Turkish / English interface | `L` UIText.swift:6 | PARTIAL (C224) |

## 14. Settings

| Screen | Main type | Status |
|---|---|---|
| Settings root (Assistant, Voice, AI, Vision, Ray-Ban glasses, Memory, Tools, Privacy, Developer, About) | `SettingsView` Settings/SettingsView.swift:61 | PHYSICAL TEST REQUIRED (C223) |
| Name & conversation, wake phrase & hands-free, audio route | `AssistantSettingsView` Settings/SettingsView.swift:306; `HandsFreeSettingsView` HandsFreeSettingsView.swift:6; `AudioSettingsView` Settings/SettingsView.swift:372 | see C143–C150 |
| Personality (mode, Jarvis Style, intensity, address) | `PersonalitySettingsView` IntelligenceViews.swift:381 | EXPERIMENTAL (C77) / PHYSICAL TEST REQUIRED (C32) |
| Voice | `VoiceSettingsView` VoiceSettingsView.swift:8 | PHYSICAL TEST REQUIRED (C127) |
| ChatGPT account, Intelligence, ChatGPT models, Web search | Settings/SettingsView.swift:398; IntelligenceViews.swift:7; ModelSettingsView.swift:5; Settings/SettingsView.swift:430 | WORKING (C125) / EXPERIMENTAL (C30, C231, C230) |
| Camera & Ray-Ban (source, quality, OCR, locked vision, decoder, save mode) | `CameraSettingsView` Settings/SettingsView.swift:456 | see C202–C204 |
| Memory settings | `MemorySettingsView` MemoryViews.swift:692 | EXPERIMENTAL (C156–C159) |
| iPhone tools (master switch plus 12 tools); agent gateway | `ToolsSettingsView` HandsFreeSettingsView.swift:119; `AgentGatewaySettingsView` AgentGatewaySettingsView.swift:4 | not listed / EXPERIMENTAL (C181) |
| About, licenses | `AboutView` Settings/SettingsView.swift:556; `LicensesView` SettingsSections.swift:588 | not listed |

## 15. Privacy

| Feature | Main type | Status |
|---|---|---|
| Privacy center (what leaves the phone, what is stored, permissions, delete all local data) | `PrivacySettingsView` SettingsSections.swift:25 | not listed |
| Ten permissions, asked only when needed | `AppPermission` PermissionCenter.swift:12; `PermissionCenter` :105 | not listed |
| Redacted trace; no contact details kept | `LogSanitizer` PrivacyGuards.swift:5; `TaskTrace` AssistantFlows.swift:109; `VoiceIntent.isPrivate` VoiceIntentRunner.swift:205 | EXPERIMENTAL (C118) |
| Untrusted-content wrapper | `UntrustedContent` PrivacyGuards.swift:128 | EXPERIMENTAL (C179) |
| Meta DAT analytics and crash capture | Info.plist | OFF (C234) |

## 16. Diagnostics and developer screens

| Screen | Main type | Status |
|---|---|---|
| Diagnostics | `DiagnosticsView` SettingsSections.swift:250 | not listed |
| Action & task trace | `TaskTraceView` SettingsSections.swift:172 | EXPERIMENTAL (C118) |
| Voice diagnostics; camera diagnostics | `VoiceDiagnosticsView` VoiceDiagnosticsView.swift:7; `CameraDiagnosticsView` CameraDiagnosticsView.swift:5 (uses `DeveloperOverlay` AssistantHomeView.swift:830) | EXPERIMENTAL (C128, C207) |
| Ray-Ban connection diagnostics | `ConnectionDiagnosticsView` ConnectionDiagnosticsView.swift:8 | EXPERIMENTAL (C195) |
| Routing diagnostics | `RoutingDiagnosticsView` IntelligenceViews.swift:350 | EXPERIMENTAL (C30) |

## 17. Tests (ios/GlassifAITests, 19 files, 268 test functions)

| File (tests) | Covers |
|---|---|
| AutoLoomActionTests (14) | ActionGuard, DeviceActionParser, risk levels, the untrusted-content escalation, schema |
| AutoLoomAgentTests (5), AutoLoomCameraTests (5), AutoLoomConnectionTests (11) | OpenClaw; stream profiles and watchdog; registration state machine |
| AutoLoomCoreTests (30: `AutoLoomCoreTests`, `AutoLoomTaskTests`) | delegation envelope, URL safety, sanitizer, stream parser, frames, ledger |
| AutoLoomDailyLifeTests (16), AutoLoomDealerTests (9) | timers, shopping, parking, QR, place reminders, undo, reviews, modes; Dealer Mode |
| AutoLoomJarvisTests (25), AutoLoomVoiceTests (3), AutoLoomLiveVisionTests (5), AutoLoomModelTests (8) | voices, stop and end words, wake phrase, time parsing, memory, tool registry; Live Vision policy; model catalog and routing |
| AutoLoomMultiAgentTests (28, four XCTestCase classes) | router, team, provider adapters, one voice, Jarvis |
| AutoLoomNoteReliabilityTests (9), AutoLoomVoiceActionTests (19), AutoLoomVoiceFirstTests (25) | the bridge and the runner for notes, reminders, tasks, calls, messages, maps, clipboard, day plan, delegation takeover |
| AutoLoomRayBanMediaTests (22, four classes), AutoLoomVisionAndAssistantTests (16), AutoLoomVisionPipelineTests (13) | locked-screen vision, recorder, captures, media commands; vision pipeline; invocation |
| GlassifAITests (5) | streaming flow, glasses gesture interpreter |

No test covers the App Intents.

## Drift noticed between docs and code

- `CAPABILITIES.md` C217 lists four tabs; the code has five (Explore is missing from that row).
- The Privacy center says reminders and events "need your yes" (SettingsSections.swift:107). In the code they are SAFE and run directly (DeviceActions.swift:48).
- Settings → Tools names 3 Shortcuts (HandsFreeSettingsView.swift:146); there are 9.
- `docs/TOOLS_AND_ACTIONS.md` marks itself as superseded and still describes the pre-v1 risk model ("Contacts are not searched").
