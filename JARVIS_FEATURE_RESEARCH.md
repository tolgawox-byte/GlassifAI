# JARVIS feature research (2026-10-12)

## Türkçe özet

GitHub'da ve resmî dokümanlarda iki paralel araştırma yapıldı:
- **R6:** Meta gözlük uygulamaları, canlı görsel AI, iOS gerçek zamanlı ses, görsel hafıza. 34 repo incelendi, 16'sının kaynak kodu okundu.
- **R7:** Jarvis asistanları, Windows PC kontrolü, MCP, hafıza, görev motorları, belge işleme. 83 kaynak incelendi, 64'ünün kaynak kodu okundu.

Her proje için şunlar kaydedildi:
- lisans ve ticari kullanım kararı
- son commit tarihi
- gerçekten okunan dosyalar
- JARVIS'e ne katacağı
- tavsiye: entegre et / modül uyarla / yalnızca fikir / atla

Sadece README'si okunan projeler ayrıca işaretlendi. Hiçbir projeden kod kopyalanmadı. Tek istisna MIT lisanslı QR kod üreticisi; bildirimiyle birlikte eklendi.

Bu oturumda uygulamaya geçen fikirler: PC companion'ın güvenlik modeli. Bu modeli şu projelerin desenleri biçimlendirdi:
- OpenClaw (eşleştirme ve sertifika pini, plana bağlı onay)
- MCP dosya sistemi sunucusu (gerçek yol denetimi)
- `@openclaw/fs-safe` (Windows yol kuralları)
- Jan (companion'ın kendi klasörü her zaman yasak)
- Vercel AI SDK (onay özetiyle bağlama)
- Gemini CLI ve Desktop Commander (süreç ağacını kapatma, atomik yazma)

Ayrıca **28 yeni özellik fikri** üretildi (§5). Her biri için fayda, uygulanabilirlik, bağımlılık ve öncelik var.

## 1. Method

- **Sources:** shallow clones (`git clone --depth 1`), LICENSE files, source files, issues and release notes, official SDK documentation (Meta Wearables MCP docs server, OpenAI, Apple, MCP specification). The GitHub REST API was not used, to stay within the unauthenticated rate limit.
- **Evidence labels:**
  - **CODE-READ:** the cited files were opened and read.
  - **README-ONLY / DOCS:** only the README, LICENSE or docs were read.
  - **EXPERIMENT:** run on this Windows 11 PC with Node 24.
- **Coverage:**
  - R6: 34 repositories in 23 rows, with code read in 16 rows.
  - R7: 83 projects and sources, with code read for 64.
  - The previous review (`docs/OPEN_SOURCE_RESEARCH.md`, 2026-09-28) covered 8 projects; it is extended here, not repeated.
- **Licence rule:** business use (Dealer Mode) counts as commercial. "No licence" means all rights reserved, so ideas only.

## 2. Findings that matter most

1. **The PC trust problem has a good open-source model.** OpenClaw (MIT) does two things:
   - it separates device pairing from approving what a device may run;
   - it pairs through a QR link carrying a single-use code and the certificate pin, and binds each approval to the exact plan.

   Its defaults should not be copied: host exec is `full` with `ask: off`, and loopback is trusted. JARVIS's companion follows the model and not the defaults (§4).
2. **On Windows, a path allowlist is only as good as its canonicalisation** (EXPERIMENT on this PC):
   - junctions escape lexical checks without admin rights;
   - only the *native* realpath expands 8.3 names;
   - `evil.ps1.`, `NUL` and `name:stream` are created literally;
   - hard links pass every realpath check.

   The companion's `PathPolicy` handles all of these and has tests for each.
3. **A shell tool defeats every path rule.** Desktop Commander and Windows-MCP say so in their own docs. The companion therefore has no shell tool: the model can pick only owner-defined command ids and a shared folder.
4. **MCP's newest revision (2026-07-28) is breaking:** stateless, `server/discover`, and tasks as an extension. A dropped stream cancels a request, so long PC jobs need task handles. The companion already returns task handles and keeps 2025-06-18 for the phone's client; 2026-07-28 support is planned.
5. **DAT 1.0 has more than the migration plan used:**
   - glasses-button input;
   - head-motion sensors (a nod as "yes");
   - on-glasses speech recognition;
   - the glasses microphone inside the camera stream (no HFP).

   All four are experimental and test builds only. A still photo knocks the other capabilities off the session (Meta's BirdSpotter sample).
6. **A likely "deaf glasses" cause:** re-applying `setPreferredInput` mid-call. VisionClaw's code warns about it, and JARVIS does it on every route change. This needs a physical test.
7. **Long tasks in voice:** VisionClaw's relay waits up to 10 s, gives progress notes only while idle, checks that the result was actually spoken, and otherwise parks it for the next conversation. This is a design idea only (no licence).
8. **Semantic visual search:**
   - Queryable (MIT) shows a compact on-device embedding store.
   - Use SigLIP2 (Apache-2.0, multilingual) or OpenAI CLIP (MIT) as the model; MobileCLIP and FastVLM weights are research-only.
   - Immich on the PC exposes `POST /api/search/smart`, and calling it unmodified over the network does not trigger the AGPL.
9. **Memory that stays current:**
   - Omi (MIT) keeps a fact store at the current truth with add/skip/update/merge/supersede.
   - Graphiti stores facts with valid-from/until.
   - JARVIS today only deduplicates.
10. **MCP client hardening:**
    - OpenGlasses (BSL, ideas only) scans tool definitions for shadowing of built-in actions, typosquats and poisoned descriptions.
    - It pins the approved definitions, so a server that changes its tools after review is caught.
11. **Telemetry is on by default** in Desktop Commander, Windows-MCP, mem0, Graphiti and Cognee. JARVIS and the companion ship with none.
12. **Licence red flags:**
    - AGPL: Khoj, Basic Memory, ripgrep-all, MuPDF, Immich (API use only), PhotoPrism, Open Interpreter ≤0.4.2.
    - GPL: Poppler, Neo4j CE.
    - SSPL: Inngest server, FalkorDB.
    - Fair-code: n8n.
    - BSL: OpenGlasses, Moondream 3.
    - Non-commercial: isair/jarvis, openWakeWord models, MobileCLIP/FastVLM weights, InsightFace.
    - No licence: VisionClaw, HuggingSnap.

## 3. Projects (condensed)

### 3.1 Glasses, live vision, realtime voice, visual memory (R6)

| Project | Licence (commercial?) | Last commit | Evidence | Recommendation |
|---|---|---|---|---|
| [facebook/meta-wearables-dat-ios](https://github.com/facebook/meta-wearables-dat-ios) 1.0.1 (+ Android) | Meta developer terms (not open source); experimental features cannot be published | 2026-10-09 | CODE-READ (CHANGELOG, BirdSpotter, interfaces) | **Integrate** (it is the SDK); port v1.5 behind a camera-backend seam |
| [Intent-Lab/VisionClaw](https://github.com/Intent-Lab/VisionClaw) | No open-source grant | 2026-09-25 | CODE-READ | **Ideas only:** long-task relay, frame pin, assistive mode, HFP lessons, answer cards |
| [rayl15/OpenVision](https://github.com/rayl15/OpenVision) | MIT (yes) | 2026-10-04 | CODE-READ | **Adapt modules:** session recorder, per-turn latency timeline, document focus. Skip its face recognition (Meta policy) |
| [straff2002/OpenGlasses](https://github.com/straff2002/OpenGlasses) ("Avenkin") | BSL 1.1 (no commercial use until 2030-03-24) | 2026-10-12 | CODE-READ (~15 files) | **Ideas only:** MCP definition scan and pinning, egress screen, rewind, dwell capture |
| [Turbo1123/turbometa-rayban-ai](https://github.com/Turbo1123/turbometa-rayban-ai) | MIT (yes) | 2026-03-29 | CODE-READ | Idea: Siri "quick vision" modes |
| [kirill-markin/meta-glasses-ios-openai](https://github.com/kirill-markin/meta-glasses-ios-openai) | MIT | 2026-01-15 | CODE-READ (skim) | Skip (JARVIS is ahead) |
| [livekit-examples/agent-starter-swift](https://github.com/livekit-examples/agent-starter-swift) / vision-demo | MIT / Apache-2.0 | 2026-09-14 | CODE-READ / README-ONLY | Idea: voice-processing mode switch, sparse video sampling |
| [m1guelpf/swift-realtime-openai](https://github.com/m1guelpf/swift-realtime-openai) | MIT | 2025-10-06 | CODE-READ | Reference for an official-API provider (typed events, truncate on barge-in) |
| [pipecat-ai/pipecat-client-ios](https://github.com/pipecat-ai/pipecat-client-ios) (+ small-webrtc) | BSD-2 | 2026-09-27 | CODE-READ | Adapt idea: audio-route manager |
| [openai/openai-realtime-agents](https://github.com/openai/openai-realtime-agents) | MIT | 2026-01-07 | CODE-READ | Ideas: chat supervisor, output guardrail |
| [FluidInference/FluidAudio](https://github.com/FluidInference/FluidAudio), [argmaxinc/WhisperKit](https://github.com/argmaxinc/WhisperKit) | Apache-2.0 / MIT | 2026-10-11 / 10 | README-ONLY | Candidates: Silero VAD; offline Turkish ASR |
| [mazzzystar/Queryable](https://github.com/mazzzystar/Queryable) | MIT code; MobileCLIP weights research-only | 2026-03-29 | CODE-READ | **Adapt module** (embedding store + GPU search) with a commercially licensed model |
| [immich-app/immich](https://github.com/immich-app/immich) | AGPL-3.0 | 2026-10-12 | Spec + 1 file | **Integrate via its API** on the PC; never copy code |
| [BasedHardware/omi](https://github.com/BasedHardware/omi) | MIT | 2026-10-12 | CODE-READ | **Adapt prompts:** memory supersession, proactive relevance gate |
| [mediar-ai/screenpipe](https://github.com/mediar-ai/screenpipe) | Commercial licence | 2026-10-12 | CODE-READ (`ocr_gate.rs`) | Idea only: OCR only when the text crop changed |
| [Mentra-Community/MentraOS](https://github.com/Mentra-Community/MentraOS) | Apache-2.0 | 2026-10-12 | CODE-READ | Adapt one module: audio walking guidance |
| [brilliantlabsAR/noa-flutter](https://github.com/brilliantlabsAR/noa-flutter) | ISC | 2025-05-13 | CODE-READ | Idea only |
| Others: HuggingSnap (no licence), apple/ml-mobileclip (weights research-only), openrecall/rem/Windrecorder/PhotoPrism (copyleft), even-realities (no display glasses), xg-glass-sdk, meta-glasses-api (terms risk) | — | — | README-ONLY / licence | Skip |

### 3.2 PC control, assistants, memory, tasks, documents (R7)

| Project | Area | Licence | Evidence | Recommendation |
|---|---|---|---|---|
| [openclaw/openclaw](https://github.com/openclaw/openclaw) + [openclaw-windows-node](https://github.com/openclaw/openclaw-windows-node) + [fs-safe](https://github.com/openclaw/fs-safe) | Pairing, exec approvals, Windows path rules | MIT | CODE-READ | **Adapted patterns** (pairing + pin, plan-bound approvals, policy currency, Windows admission rules); defaults not copied |
| [MCP filesystem server](https://github.com/modelcontextprotocol/servers/tree/main/src/filesystem) | Allowed dirs, real-path validation | Apache-2.0/MIT | CODE-READ | **Adapted** (`validatePath`, exclusive create, roots barrier) |
| [Desktop Commander](https://github.com/wonderwhy-er/DesktopCommanderMCP) | Shell/file MCP | MIT, telemetry on | CODE-READ | Mostly anti-patterns; kill-tree idea adopted |
| [Windows-MCP](https://github.com/CursorTouch/Windows-MCP) | UI automation + PowerShell | MIT, analytics | CODE-READ | Skip integration (unrestricted PowerShell) |
| [microsoft/UFO](https://github.com/microsoft/UFO) | Windows UI agent | MIT | CODE-READ | Ideas only (model-declared confirmation is too weak) |
| [block/goose](https://github.com/block/goose) | Permission modes | Apache-2.0 | CODE-READ | Ideas (repetition guard); not its LLM-judged approvals |
| [openai/codex](https://github.com/openai/codex) | Approval policies, Windows sandbox | Apache-2.0 | CODE-READ (selected) | Ideas (execpolicy shape) |
| [microsoft/mxc](https://github.com/microsoft/mxc) | AppContainer sandbox, Node SDK | MIT | README-ONLY | Later: optional contained mode |
| [Gemini CLI](https://github.com/google-gemini/gemini-cli) | Policy tiers, atomic writes, kill-tree | Apache-2.0 | DOCS + CODE-READ | **Adapted** (atomic write with Windows retry) |
| [Vercel AI SDK](https://github.com/vercel/ai) | Approval digests and revalidation | Apache-2.0 | CODE-READ | **Adapted** (approval bound to a digest) |
| [janhq/jan](https://github.com/janhq/jan) | Permission gate, hidden root | Apache-2.0 | CODE-READ | **Adapted** (the companion's own folder is always off-limits) |
| [home-assistant/core](https://github.com/home-assistant/core) Assist/LLM API | Tool exposure, unannotated = destructive | Apache-2.0 | CODE-READ | Ideas (exposure profiles) |
| [leon-ai/leon](https://github.com/leon-ai/leon) | Satellite tool host, honest cancel | MIT | CODE-READ | Ideas ("may have executed" wording → our `interrupted`) |
| [pipecat-ai/pipecat](https://github.com/pipecat-ai/pipecat), [livekit/agents](https://github.com/livekit/agents) | Async tools, barge-in | BSD-2 / Apache-2.0 | CODE-READ | Ideas (async PC jobs in voice) |
| mem0, Letta, Graphiti, Cognee, LangMem, Basic Memory (AGPL), sqlite-vec, VecturaKit | Memory and RAG | mostly Apache/MIT | CODE-READ | Ideas: memory inbox, supersede-not-delete, verified forget; no integration needed at JARVIS scale |
| Temporal, Inngest SDK, Trigger.dev, Hatchet, DBOS, LangGraph.js, OpenAI Agents JS, goqite, plainjob, Cline, Aider | Task engines, undo | MIT/Apache (Inngest server SSPL; n8n fair-code) | CODE-READ | Ideas adopted: explicit states, `interrupted` after crash, expiry = deny, undo only when the file still matches |
| pdf.js / unpdf, mammoth.js, SheetJS, MarkItDown, Docling, ripgrep, Windows Search/OCR | Documents and search | Apache/MIT/BSD (SheetJS caution) | CODE-READ / EXPERIMENT | Companion uses its own zero-dependency OOXML/RTF/HTML extractor; pdf.js in a worker is the next step for PDF |

## 4. Adopted in this session (re-implemented, nothing copied)

| Pattern | Source | Where in JARVIS |
|---|---|---|
| QR pairing with a one-time code and the certificate key pin | OpenClaw | `pc-companion/src/pairing.ts`, `cert.ts`; `Runtime/PCCompanion.swift` |
| Only hashes of device tokens stored; constant-time compare | OpenClaw, Leon | `devices.ts` |
| Native real-path containment, junction and 8.3 handling, exclusive create, deepest-existing-ancestor check | MCP filesystem server, fs-safe | `pathPolicy.ts` |
| Device names, streams, trailing dots/spaces, UNC/`\\?\`, bidi/zero-width refused | fs-safe, Windows Hub display sanitizer | `pathPolicy.ts` |
| Hard-linked files never written | fs-safe tripwire, MCP filesystem | `pathPolicy.ts` |
| The companion's own data folder always off-limits | Jan `hidden_root` | `pathPolicy.ts` |
| No shell; owner-defined commands only; kill the whole process tree | Desktop Commander and Windows-MCP (as warnings), Gemini CLI kill-tree | `tools/processes.ts` |
| Approval bound to a digest of tool + arguments; the model cannot approve; a policy change voids approvals; expiry = deny | OpenClaw, Vercel AI SDK, Windows Hub currency check | `tasks.ts`, `server.ts`, `mcp.ts` |
| Honest crash recovery (`interrupted`, never silent resume) | Leon, DBOS, n8n | `tasks.ts` |
| Undo only when the file still matches the post-state; trash instead of delete | Aider, Cline | `tools/files.ts` |
| Zip-bomb limits for Office files | Slice E experiment, mammoth notes | `tools/zip.ts` |
| Hash-chained audit log without secrets or contents | OpenClaw audit | `audit.ts` |
| Never run `git` on untrusted repositories (core.fsmonitor and hooks can run code) | Codex execpolicy discussion | `tools/project.ts` |
| Untrusted wrapping of everything read from the PC | OpenClaw prompt-injection guide | `mcp.ts` |
| QR code generation (code reused, MIT) | Project Nayuki QR Code generator | `pc-companion/src/vendor/qrcodegen.ts` (notice kept) |

## 5. New feature ideas (not in the brief's list)

Priorities: **P0** critical, **P1** core JARVIS, **P2** high value, **P3** experimental. "Now" = built in this session.

| ID | Idea | What it does | Benefit | Feasibility | Dependencies | Priority | Inspiration |
|---|---|---|---|---|---|---|---|
| F01 | Long-task relay with parked results | A PC or web task that runs past 10 s is announced; progress is spoken only during silence; the result is checked as spoken, otherwise parked and said at the next conversation | No dead air, no lost results | High | Orchestrator, PC task handles (exist now) | P1 | VisionClaw |
| F02 | Pin the frame ("bunu sabitle") | Freezes the current camera frame so follow-up questions refer to it while the user looks away | Natural "this" questions | High | `FrameStore` pinned slot | P1 | VisionClaw |
| F03 | Audio-flow watchdog | WebRTC stats (packets in/out, mic energy) checked after Ready; a call that hears nothing says so and restarts the route | Ends "connected but deaf" | High | `LKRTCPeerConnection.statistics` | P0 | R3 audit |
| F04 | MCP tool-definition scan and pinning | Flags shadowing/typosquats/injected descriptions; pins each approved tool definition so a later change needs review | Stops "rug-pull" MCP servers | High | `Skills.swift` | P1 | OpenGlasses (idea) |
| F05 | Outbound egress screen with Turkish PII | Before text leaves the phone for a cloud model or MCP server, TC kimlik no, IBAN, phone numbers and card numbers are detected and masked or confirmed | Less accidental leakage | High | Regex + checksum validators | P1 | OpenGlasses (idea) |
| F06 | Memory supersession | New facts replace outdated ones ("Ankara'ya taşındım" ends the Istanbul fact) with history | Memory stays true | High | `MemoryStore` field `supersededBy` | P1 | Omi (MIT) |
| F07 | Memory inbox | Facts the model *proposes* wait in an inbox with source and quote; nothing is saved without approval | Consent by design, no poisoning | Medium | Memory UI | P1 | Cognee, LangMem |
| F08 | "Why do you know this?" + verified forget | Each memory shows where it came from; forget returns a receipt listing every store cleaned (store, index, Spotlight, backups) | Trust, real deletion | Medium | Spotlight, SwiftData | P2 | Graphiti, mem0 history (counter-example) |
| F09 | Assistive (low-vision) mode | Clock-direction descriptions, hazards first, verbatim reading, never "the path is clear"; earcons | Accessibility; safer walking | High | Prompt + tones | P2 | VisionClaw |
| F10 | Approval inbox on the phone | All waiting approvals (phone actions and PC tasks) in one list that survives disconnects; Approve / Edit / Deny | No lost or stale approvals | Medium | PC store (exists) + `PendingDeviceAction` queue | P1 | LangGraph, Trigger.dev |
| F11 | Approve on the glasses | The PC's own summary is read aloud; "onayla" approves CONFIRM-level PC tasks; STRONG needs a tap; later a head nod (DAT 1.0 motion) | Hands-free, still bound to the digest | Medium | Voice bridge (exists), DAT 1.0 for nods | P2 | Windows Hub, HA confirmations |
| F12 | Time-boxed folder grants | "Downloads klasörünü bir saatliğine paylaş" adds an expiring root on the PC | Least privilege by default | High | `config.json` roots with expiry | P2 | OpenClaw standing grants |
| F13 | Dry-run preview | Before approval the PC lists exact files, sizes and conflicts | Approve facts, not intentions | High | Companion `prepare` (exists) | P2 | OpenClaw `system.run.prepare` |
| F14 | Crash-recovery briefing | After the PC restarts, the phone hears which tasks were interrupted and whether retrying is safe | No silent double execution | High | `interrupted` state (exists) | P2 | n8n, DBOS |
| F15 | "Hangi dosyada X yazıyordu?" | Voice search over shared folders with file/line citations; "aç" is a CONFIRM-level open | Recall from the glasses | High | `search_text` (exists), Windows Search later | P1 (now: basic) | ripgrep, Windows Search |
| F16 | Local document index with Turkish folding | Incremental FTS5 index (`node:sqlite`) over shared documents' text | Instant offline answers | Medium | `node:sqlite`, extractors (exist) | P2 | rga, Basic Memory (idea) |
| F17 | Cited summaries with a cost/privacy preview | Long documents summarised map-reduce with `[s.3]` citations; the phone shows which provider and roughly how much text before sending | Trustworthy summaries, consent | Medium | Responses client | P2 | LangChain, Docling |
| F18 | Document risk badge | "Gizli metin çıkarıldı", "dış bağlantı", "makro" shown before a document is read aloud | Makes injection visible | High | Extractor counters | P2 | mammoth notes |
| F19 | Zero-install OCR on the PC | Scanned PDFs and screenshots read with Windows OCR via a companion-shipped PowerShell script | Scanned PDFs become searchable | Medium | WinRT OCR, `tr-TR` OCR pack | P2 | R7 slice E experiment |
| F20 | Immich on the PC as the photo-archive search | "Geçen yaz çektiğim kırmızı araba fotoğrafı" searched in the user's own Immich with a read-only key | Natural-language search over the whole archive without indexing it on the phone | Medium | User-run Immich (Docker) | P3 | Immich API |
| F21 | Multilingual semantic visual memory | On-device image/text embeddings (SigLIP2 or CLIP, commercially licensed) for visual memories and captures | "Mavi kutuyu nerede gördüm?" finds images, not just words | Medium | Core ML model (~150 MB) | P2 | Queryable |
| F22 | Per-turn latency timeline | Shows mic end → transcript → delegation → tool → speech per turn | Finds slow links honestly | High | Session timestamps (partly exist) | P2 | OpenVision |
| F23 | "Klip kaydet": POV + JARVIS's answer | Records the glasses video with the assistant's spoken answer in one file | Shareable evidence (dealer, support) | Medium | Recorder + remote audio tap | P3 | OpenVision |
| F24 | Exposure profiles per surface | The glasses voice gets fewer, safer tools than the phone screen; external MCP clients get their own folder list | Smaller blast radius for voice | High | ActionCatalog, companion config | P2 | Home Assistant, Leon |
| F25 | Routine suggestions | After the same three requests at similar times, JARVIS offers to make a routine (never creates one alone) | Less repetition | High | Routines (exist) | P2 | OpenGlasses (idea) |
| F26 | "Interrupt only if it matters" gate | Proactive messages (Live Vision, PC results) pass only above a relevance score | Fewer interruptions | High | Prompt + threshold | P2 | Omi |
| F27 | Signed approvals with a Secure Enclave key | The phone signs each approval and request with a non-exportable key; a stolen token alone is useless | Stronger PC security | Medium | CryptoKit Secure Enclave, `node:crypto` verify | P2 | OpenClaw device proof |
| F28 | Contained mode for risky commands | Owner-marked commands run in a Windows AppContainer (MXC) with no network | A sandbox where it matters | Low–Medium | Microsoft MXC | P3 | Windows Hub, Codex |

Ideas from the brief's own list (§6 of the brief) are tracked in `JARVIS_FEATURE_MATRIX.md`; most map to modules above (PC task queue, status by voice, retry on failure, results on the phone: built now; daily summary, visual memory search, OCR business cards: partly exist; approval before actions: built and hardened now).

## 6. Not adopted, and why

- **Face recognition / speaker identification:** Meta's Acceptable Use Policy forbids identifying people from the glasses' sensors.
- **Free shell or PowerShell tools for the model** (Windows-MCP, Desktop Commander, Open Interpreter): they make path rules meaningless.
- **LLM-judged approvals** (Goose "smart approve", UFO's model-declared confirmation): an LLM may raise a confirmation level, never lower it.
- **Continuous screen/scene recording** (screenpipe, OpenRecall): privacy of bystanders, Turkish law (KVKK, TCK 133) risk, and licences.
- **Bundled wake-word or voice models** with non-commercial licences (openWakeWord, MobileCLIP weights).
- **Heavy servers** for the companion (Temporal, Inngest server, Neo4j): unnecessary at a single-owner scale; their ideas are used instead.

## 7. Licensing cautions

- Anything adapted from MIT/Apache/BSD sources keeps its notice in `THIRD_PARTY_NOTICES.md`. Today only Project Nayuki's QR generator (MIT) is reused as code.
- AGPL/GPL/SSPL projects are design inspiration only. Immich is called as an unmodified network service.
- DAT experimental features (photo capture, inputs, motion, speech, in-stream audio) are allowed in sideloaded test builds only.
- The ChatGPT subscription transport is private and unsupported (see `JARVIS_AUDIT.md` §8, H3).
