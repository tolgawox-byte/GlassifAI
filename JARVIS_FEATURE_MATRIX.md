# JARVIS feature matrix

## Türkçe özet

Brief'teki her özelliğin gerçek durumu tek tabloda.

Durum anahtarları:
- **CİHAZDA DOĞRULANDI**
- **OTOMATİK TESTLE DOĞRULANDI**: CI'da veya bu Windows bilgisayarda çalışan testler
- **SİMÜLASYONDA DOĞRULANDI**
- **KISMEN**
- **CİHAZ TESTİ BEKLİYOR**
- **TEKNİK OLARAK ENGELLİ**
- **YOK**

v1.5'in hiçbir özelliği henüz gerçek gözlükle test edilmedi. Bu yüzden iOS tarafında "çalışıyor" yazan her satır en fazla "otomatik testle doğrulandı" seviyesindedir. Windows companion ise bu bilgisayarda gerçekten çalıştırılıp test edildi.

## Legend

| Verification | Meaning |
|---|---|
| **Device** | Verified on the real iPhone and/or glasses |
| **Automated** | Unit/integration tests pass (iOS CI simulator, Rust, or Windows for the companion) |
| **Simulated** | Exercised in a simulated environment (mock devices, fake servers) |
| **Pending device** | Code complete; needs the physical test named |
| **Partial** | Some of the feature exists; the gap is named |
| **Blocked** | Cannot be done without something outside this environment (named) |
| **Missing** | Not built |

Priority: P0 critical infrastructure/security · P1 core JARVIS · P2 high value · P3 experimental.

## A. Meta Ray-Ban (brief §3A, §4, §5)

| Feature | Status | Verification | Evidence | Completion criterion | Pri |
|---|---|---|---|---|---|
| Hands-free voice through the glasses (HFP) | Partial; **not with the Ray-Ban camera on current glasses software** | Device (v1.0 era only); pending device N, N2 | `GlassifAIRealtimeSession.configureAudioSession`; `GlassesCameraAudio` (camera-safe audio) | With the camera off: HFP route active, mic and speaker on the glasses. With the Ray-Ban camera: the iPhone microphone until Meta's glasses fix (#206, #332) or DAT in-stream audio | P0 |
| Ray-Ban connection (registration, link, session, camera) | In CI (DAT 1.0.1) | Automated (`AutoLoomConnectionTests`, `AutoLoomRayBanDAT1Tests`); pending device A–V | `WearableConnection.swift`, `ConnectionLayers.swift`, `StreamSessionViewModel.swift` | `RAYBAN_CONNECTION.md` rows A, B, N, S pass | P0 |
| Connection diagnostics by layer + Meta SDK log | In CI | Automated; pending device V | `ConnectionDiagnosticsView`, `DATLogReader` | The copied report names the failing layer on the device | P0 |
| Live camera understanding | Working in code (DAT 1.0.1 in CI) | Automated (frame tests); pending device | `FramePipeline`, `FrameSelection`, `VisionCapture`; default "Live" 504×896 @ 24; in-stream photo for reading | M/LV/VM rows and S, U pass on glasses | P0 |
| Smoothness measured (frame interval, stutters, longest gap) | In CI | Automated (`testStuttersAndTheLongestGapAreMeasured`); pending device S | `FrameStore` metrics, Camera diagnostics | Live profile measured on the glasses | P1 |
| Image source of AI frames shown and stated | Partial → improved | Automated build; pending device CAM1 | Diagnostics "Last image sent to the AI"; source line added to prompts | Live Vision images + destination + capture age in diagnostics (plan 3.1) | P1 |
| AI never analyses UI/preview/mock images | Verified in code | Automated (code audit) | `JARVIS_AUDIT.md` §5 | — | P0 |
| Best frame selection, measurable quality settings | Working in code | Automated | FAST/BALANCED/HIGH profiles, best-of-recent | Capture-time freshness (plan 1.12) | P1 |
| Glasses photo capture | Working in code | Pending device M1 | `RayBanMediaCoordinator.takePhoto` | M1 pass | P1 |
| Glasses video capture | Partial (stream video, no audio) | Pending device M2 | `RayBanVideoRecorder` | DAT 1.x mic for audio (F13/F23) | P2 |
| Original media from the glasses' gallery | **Blocked** | — | No API in DAT 0.5.0 or 1.0.1 (VERIFIED) | Meta adds an API | — |
| Full-resolution still (4032×3024) | In CI (opt-in, Meta beta) | Pending device R | `StreamSessionViewModel.captureStandalonePhoto`; Settings → Camera → Vision image | R passes; the stream comes back through a fresh session | P2 |
| Originals kept separate from AI derivatives; EXIF | Done | Automated | Originals saved byte-for-byte; AI copies separate; stills sent to providers carry no GPS or camera metadata (`StillPhotoProcessor`) | — | P1 |
| DAT version warnings | In CI (session errors kept apart on 1.0.1) | Automated; pending device | `WearableConnection.alertIfIncompatible`, `GlassesSessionFailure` | Shown with the right action (update the app, update in Meta AI, power cycle) | P0 |
| Temple tap / gestures | In CI (follow the camera's DAT 1.0 session; the app's own stops ignored) | Automated; pending device P | `GlassesGestureSession` | P passes | P2 |
| Hey Meta invocation | Blocked on this build | — | DAT 1.0 + Meta approval | `DAT_1_MIGRATION.md` | P3 |

## B. Voice and realtime (brief §5)

| Feature | Status | Verification | Evidence | Completion criterion | Pri |
|---|---|---|---|---|---|
| Realtime voice call (ChatGPT plan, `gpt-live-1-codex`) | Working | Device (v1.0 era); pending device for v1.5 | Upstream wire code identical (`JARVIS_AUDIT.md` §4) | Physical start/stop | P0 |
| HTTP 400 / session mode investigated | Done; structured errors built | Automated (code + upstream diff + error JSON tests) | No 400 in history; session mode not sent; bridge 4 reports status, code, param, request id per failed step | Physical VC4 on the live service | P0 |
| Start/stop race closed | Done | Automated build; pending device VC1 | `startGeneration` | VC1 pass | P0 |
| No "failed" UI with a live mic; data-channel loss reconnects | Done | Automated build; pending device | `error`/`halted`/`dataChannelClosed` | Physical | P0 |
| Microphone permission checked | Done | Pending device VC3 | `RealtimeError.microphoneDenied` | VC3 pass | P0 |
| Audio-flow watchdog | Built | Automated (decision) · Pending device (AU3) | WebRTC counters 1 s and 5 s after Ready; spoken explanation; one reconnect per conversation | No false alarms on the device | P0 |
| Faster start (no 2.5 s ICE wait) | Done | Pending device VC2 | ICE loop | VC2 pass | P1 |
| Barge-in / interruptions | Working in code (server-side + local silencing) | Pending device | `stopWordMutedTurn` | M3 pass | P1 |
| Reconnect with backoff | Partial | Automated (budget tests) | `RealtimeReconnectPolicy` | Backoff loop that waits for the network (plan 1.5) | P1 |
| Clear spoken errors | Partial | Automated | `ConnectionFeedback` | Cause-specific sentences | P2 |
| Background behaviour | Partial | Pending device | `UIBackgroundModes` audio | WK2 | P2 |
| Short spoken answers, details on screen | Working in code | Automated | Persona and length rules | — | P1 |
| Answers from real tool results ("did it finish?") | Working in code; PC tasks via `get_task` | Automated | Honest failure tests; PC task reports | — | P1 |

## C. Notes, tasks, reminders, memory (brief §7)

| Feature | Status | Verification | Evidence | Completion criterion | Pri |
|---|---|---|---|---|---|
| Voice notes ("bunu not et") | Working in code | Automated | `AutoLoomNoteReliabilityTests` | Device check | P1 |
| Note fields: title, content, time, tags, source | Working in code | Automated | `NoteRecord` | — | P1 |
| Linked image/document/task/conversation | Partial | — | Links written, not shown | Plan 2.6 | P2 |
| Tasks: create, edit, complete, list, search | Working in code | Automated | `TasksViews`, voice | — | P1 |
| Snooze, priority, recurrence | Partial | Automated | Snooze from the alert (phase 1f); recurrence passed CI (`AutoLoomRecurrenceTests`, run 38489746020); `priority` still a dead field | Device tests TK1, TK2 | P1 |
| Apple Reminders create | Working in code | Pending device | `DeviceActions.createReminder` | Device test RM4 | P1 |
| Reminder verified after creation | Working in code | Automated (build) | `calendarItem(withIdentifier:)` after saving | Device test | P1 |
| Reminder list choice (Settings, by name, Tasks sheet) | Working in code | Automated (parser; run 38485233267) | `ReminderLists`, `ReminderListMention` | Device test RM4 | P1 |
| Complete / delete a reminder by voice | Working in code | Automated (parser, matching; run 38485233267) | `AutoLoomReminderVoiceTests`; completion undone by "geri al"; deletion after a yes; both read back | Device tests RM1–RM3 | P1 |
| Personal memory (explicit, search, delete, edit) | Working in code | Automated | `MemoryStore` | — | P1 |
| Incognito ("gizli mod"): no summary, memory, visual memory, name or Scene Timeline line while on | In CI | Automated (`AutoLoomIncognitoTests`); pending device IN1 | `IncognitoMode.swift`; gates in `VoiceIntentRunner`, `AssistantOrchestrator`, `LiveVision` | IN1 passes | P1 |
| Memory export | Missing | — | — | Plan 3.2 | P2 |
| Consent: nothing saved without an explicit command | Partial | Automated (parser path) | Model-delegated saves trusted | Plan 1.14 | P0 |
| Daily summary (opt-in) | Working in code | Pending device RT2 | `DailyBriefing` | RT2 | P2 |

## D. Visual memory and search (brief §8)

| Feature | Status | Verification | Evidence | Completion criterion | Pri |
|---|---|---|---|---|---|
| Save a view with OCR and labels (opt-in) | Working in code | Automated; pending device VM1 | `VisualMemory.swift` | VM1–VM3 | P1 |
| Natural-language search | Partial (lexical) | Automated | Stem match + 28-pair table | F21 semantic (plan 3.3) | P2 |
| Honest "not found" | Working in code | Automated | `testNoVisualMemoryIsNeverAGuess` | — | P1 |
| Never indexes the photo library without consent | Verified in code | Automated | Add-only Photos access | — | P0 |
| Read text saved for later search ("şu yazı neydi") | Working in code | Automated | OCR stored with visual memories | — | P2 |

## E. iPhone integrations (brief §9)

| Feature | Status | Verification | Evidence | Completion criterion | Pri |
|---|---|---|---|---|---|
| Contacts lookup | Working in code | Pending device | `ContactsLookup` | Privacy wording fix (M2) | P1 |
| Call (system call screen, never automatic) | Working in code | Pending device | `tel:` + tap card | — | P1 |
| Messages (compose sheet, user sends) | Working in code | Pending device | `MFMessageComposeViewController` | — | P1 |
| Photos (add-only) | Working in code | Pending device | `PhotoLibrarySaver` | — | P2 |
| Files | Missing | — | — | `fileImporter` | P2 |
| Calendar / Reminders | Partial | Pending device | EventKit | Reminders: plan 2.2 and 2.3 (repeats), CI passed; calendar edits by voice: not planned | P1 |
| Share sheet (outgoing) | Working in code | Pending device | `UIActivityViewController` | — | P2 |
| Share extension / widgets / Live Activities | **Blocked** | — | Extension signing in the sideloaded IPA | Paid developer team | P3 |
| Notifications with actions | Working in code | Automated | `TaskNotifications` (Complete, Snooze 1 hour; banner while the app is open) | Device test TK1 | P1 |
| Shortcuts and App Intents | Working in code | Pending device AP1 | 17 intents | Authentication policy (M5) | P1 |
| Permission denial and revocation handled | Working in code | Automated | `PermissionCenter`, kept commands | — | P1 |

## F. Windows PC companion (brief §10)

| Feature | Status | Verification | Evidence | Completion criterion | Pri |
|---|---|---|---|---|---|
| Secure pairing (QR, one-time code, pinned key, console confirmation) | **Done** | Automated (Windows + iOS pin cross-check); QR decoded by an independent decoder | `pairing.ts`, `cert.ts`, `PCCompanion.swift` | PC1 on device | P0 |
| Encrypted transport | Done | Automated | HTTPS, TLS 1.2+ | — | P0 |
| Shared folders chosen by the owner | Done | Automated | `roots add`, `PathPolicy` | — | P0 |
| Allowed programs chosen by the owner | Done | Automated | `config.apps`, `open_app` | PC rows | P1 |
| Allowed commands (no shell for the model) | Done | Automated | `config.commands`, `run_command` | PC4 | P0 |
| Risk classes (read/write/destructive/execute) and explicit approval | Done | Automated | `effectivePolicy`, digest-bound approvals | PC3/PC4 | P0 |
| Authentication separate from authorization | Done | Automated | `DeviceStore.authenticate` vs scopes/policy | — | P0 |
| Audit log | Done | Automated | Hash-chained `audit.log`, `audit verify` | — | P1 |
| File search and listing | Done | Automated; pending device PC2 | `search_files`, `list_dir` | PC2 | P1 |
| Read and summarise documents | Done (text extraction; summary by the phone's model) | Automated | `extract_text` (docx/xlsx/pptx/odt/html/rtf/text; PDF best effort) | PDF via pdf.js (plan 4.6) | P1 |
| Project analysis | Done | Automated | `analyze_project` (no git execution) | PC2 | P1 |
| Create/edit files in allowed folders | Done | Automated | create/append/replace/mkdir/rename with backups | PC3 | P1 |
| Run tests and report errors | Done (owner-defined commands) | Automated | `run_command`, exit code + output tail | PC4 | P1 |
| Task queue, long tasks, status, cancel | Done | Automated | `TaskManager`, kill tree | PC5 | P1 |
| Results to the iPhone and to voice | Done | Automated (REST/MCP); pending device | `/v1/tasks`, events, `approveAndWait` | PC3/PC5 | P1 |
| Undo / restore | Done | Automated | `undo_task`, trash | PC6 | P2 |
| Never on a public port by default | Done | Automated | Loopback default; private bind only | — | P0 |
| Network loss handled safely | Done | Automated | Tasks continue on the PC; approvals expire to "cancelled" | — | P1 |
| Tray app / autostart / DPAPI | Missing | — | — | Plan 4.7 | P2 |

## G. Multi-provider (brief §11)

| Feature | Status | Verification | Evidence | Completion criterion | Pri |
|---|---|---|---|---|---|
| Realtime provider abstraction | Partial | — | One realtime path (ChatGPT plan) | Official Realtime API provider (BYO key) | P2 |
| Vision / text / search routing | Working in code | Automated | `AgentRouter`, `ProviderRegistry` | — | P1 |
| Claude, Gemini, Perplexity, OpenRouter | Working in code (keys required) | Automated (stubbed HTTP) | Keychain storage | Owner keys + cost consent | P2 |
| Local / on-device model | Partial | Automated | Apple Foundation Models (optional) | — | P3 |
| Cost / latency / error metering | Partial | — | Circuit breaker, no spending cap | Spending cap | P2 |

## H. UI (brief §12)

| Feature | Status | Verification | Evidence | Completion criterion | Pri |
|---|---|---|---|---|---|
| Home with real status | Partial | Automated (screenshots in CI) | Assistant tab | Unified status strip (plan 2.1) | P1 |
| Notes, Tasks, Memory, Visual memory, Settings, Diagnostics | Working in code | CI screenshots | `AppShellView` | — | P1 |
| PC Control screen | Done | Automated build; pending device | `PCCompanionView` | PC1–PC8 | P1 |
| Activity history | Partial | — | Timeline rebuilt from stores | Persisted log (plan 2.5) | P1 |
| No decorative buttons; unfinished features disabled with reason | Mostly true | Code audit | Inert search/timeline rows | Plan 2.7 | P1 |
| Accessibility (VoiceOver, Dynamic Type) | Partial | — | Labels on key controls | Audit with VoiceOver | P2 |

## I. Task engine and safety (brief §13, §14)

| Feature | Status | Verification | Evidence | Completion criterion | Pri |
|---|---|---|---|---|---|
| Lifecycle states, approvals, retries, timeouts, cancellation, verification (PC) | Done | Automated | `tasks.ts` | — | P0 |
| Same on the phone (up to five waiting actions; not kept across a restart) | In CI | Automated | `AutoLoomApprovalQueueTests` | Device test AP1; restart: owner decision (plan 2.4) | P1 |
| Model cannot approve its own actions | Done | Automated | Phone + PC tests | SEC1 | P0 |
| Untrusted content wrapped; prompt-injection defence | Built | Automated · Pending device (SEC2, SEC3) | `UntrustedContent` (any tag spelling defused), PC `<untrusted_pc_content>`, conversation-wide `ConversationTaint`, memory saves only from the user's words, personal reads need a yes, memories as quoted data | Model-started Live Vision not gated yet (plan 1.14) | P0 |
| Secrets never in code or logs | Verified | Automated (secrets scan of all history) | `JARVIS_AUDIT.md` §8 | gitleaks in CI | P0 |
| CI least privilege | Done | CI | `main.yml` | — | P0 |

## Brief §6 idea list → where it stands

| Idea from the brief | Where |
|---|---|
| Remember a seen object/document | Visual memory (D) |
| Save read text and search later | Visual memory OCR (D) |
| Voice → note/task/calendar | Notes/tasks/reminders (C) |
| Gather photos/docs for a task | Plan 2.6 (links) |
| Link glasses vision to conversation context | Partial (conversation context + Live Vision notes) |
| Queue long PC tasks; ask progress by voice; explain failures and retry safely | Done (F) |
| Optional daily summary | Done (C) |
| Explicit personal memory | Done (C) |
| Natural-language visual search | Partial (D) |
| OCR business cards / documents / product info | Partial (documents, receipts) |
| Link notes and files of one task | Plan 2.6 |
| Smart search in PC folders | Done (F) |
| Web research with sources | Working in code (reports with sources) |
| Approval before actions | Done and hardened (I) |
| Offline local operations; pending tasks when the network returns | Partial (typed commands; PC tasks continue on the PC) |
| Provider choice per task | Working in code (G) |
| Clear explanations of connection problems | Partial (B) |
| Safe automation templates | Routines (SAFE steps only) |
| Undo / roll back allowed actions | PC: done; phone: partial |
| Task status sync across devices | PC ↔ phone: done (REST/events) |
| Categorise photos and documents | Missing (F21 later) |
| Highlight important results without notification spam | F26 (later) |
