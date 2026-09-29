# Gap audit — "Ultimate Jarvis Product Expansion" brief (2026-09-29)

Every section of the brief with its state after this pass. "Unit-tested" means logic tested on the CI simulator; nothing here has been verified on the physical Ray-Ban glasses or iPhone yet (see `docs/PHYSICAL_TEST_MATRIX.md`).

States: **IMPLEMENTED** (this pass, unit-tested in CI) · **ALREADY EXISTED** (v1.4 or earlier) · **PARTIAL** · **BLOCKED** (reason) · **PHYSICAL TEST REQUIRED** · **WAITING_FOR_DAT1** · **REQUIRES_PROVIDER** · **REQUIRES_PERMISSION**.

Rollback tag for this pass: `rollback-405e461-before-jarvis-expansion` (v1.4 final state).

| § | Requirement | State | Notes |
|---|---|---|---|
| 0 | One assistant that sees, hears, remembers, researches, acts | PARTIAL | Everything below; physical verification pending |
| 1 | Implement, don't just plan | — | Working rule |
| 2 | Protect current work, rollback tag | IMPLEMENTED | `rollback-405e461-before-jarvis-expansion`; no force push, no history rewrite |
| 3 | Research pass (Apple, Meta, public projects) | IMPLEMENTED | Apple (Foundation Models, Translation, Liquid Glass, CoreSpotlight), Meta DAT 1.0 docs, NHTSA vPIC, Transport Canada API, MCP spec |
| 4 | DAT 1.0 timing, RayBanCapabilityMatrix | IMPLEMENTED | `RayBanCapabilityMatrix` (SDK 0.5.0 linked; DAT 1.0 items WAITING_FOR_DAT1; Gen 1 displayless, no display UI) |
| 5 | Universal voice parity, ActionCatalog | IMPLEMENTED | 100+ `ActionDefinition`s; every example parsed by the same bridge as speech (test) |
| 6 | ActionCatalog powers voice, agents, App Intents, UI, Command Lab, tests | PARTIAL | Voice, App Intents (`RunAutoLoomActionIntent`), Command Library/Lab, palette, routines and the on-device classifier use it; the generated tool schemas are tested but the realtime voice session still uses its own delegation tool |
| 7 | Voice command for every important feature | IMPLEMENTED | Voice-only actions carry a stated reason |
| 8 | Transcript → intent → parameters → permission → executor → result → speech | IMPLEMENTED | `IntentOutcome` (spoken vs reply vs said), trace log |
| 9 | High-priority local commands | IMPLEMENTED | Deterministic test for stop, recording, photo, note, task, reminder, timer, copy, cancel, confirm |
| 10 | Wake once, follow-up, entity carry-over | PARTIAL | Existing conversation + `EntityContext`; documents and places now feed it |
| 11 | Jarvis personality | ALREADY EXISTED | v1.4 JarvisStyle |
| 12 | Jarvis state awareness | IMPLEMENTED | `JarvisSession.snapshot` (vehicle, person, place, product, document, task, recording, mode, sharing, Scene Timeline, providers) |
| 13 | On-device brain (Foundation Models) | IMPLEMENTED | `LocalBrain` (optional, weak-linked); PHYSICAL TEST REQUIRED on an Apple Intelligence iPhone |
| 14 | Foundation Model profiles | IMPLEMENTED | fastLocal, memory, dealer, document, translation, general; iOS 27 Dynamic Profiles |
| 15 | Offline mode | IMPLEMENTED | `OfflineAssistant`, offline chip, local parsers, on-device translation/OCR |
| 16 | App Intents | IMPLEMENTED | Catalog-driven intent + photo, recording, search, vehicle, translation, briefing intents |
| 17 | Siri AI | PARTIAL | App Shortcuts/App Intents; never the primary Ray-Ban assistant (by design) |
| 18 | Core Spotlight second brain | IMPLEMENTED | Named, completely protected index; memories opt-in; masked VIN |
| 19 | Global natural-language search | IMPLEMENTED | `GlobalSearch` + Spotlight semantic + on-device rewrite |
| 20 | Visual second brain | IMPLEMENTED | Explicit visual memories + on-device OCR/labels + vehicle + optional photo |
| 21 | Visual memory search | IMPLEMENTED | "Anahtarımı en son nerede gördüm?" with TR/EN object names; shows the photo |
| 22 | No continuous recording by default | IMPLEMENTED | Only explicit memories; timeline is opt-in text |
| 23 | Scene Timeline (opt-in) | IMPLEMENTED | Default OFF, one text line per scene, 7 days, deletable |
| 24 | Live Vision adaptive sampling | ALREADY EXISTED | `LiveVisionPolicy` (thermal/battery aware) |
| 25 | Scene change detection | ALREADY EXISTED | Thumbnail difference |
| 26 | Live Vision commands | IMPLEMENTED | "Ne değişti?" compares the last two notes |
| 27 | Document intelligence | IMPLEMENTED | OCR, dates, amounts; reminder only after a yes; text kept, photo not |
| 28 | OCR / barcode / QR local pipeline | ALREADY EXISTED + IMPLEMENTED | Code reader (v1.4); sign OCR (this pass) |
| 29 | Live translation | PARTIAL | On request ("bu tabelayı Türkçeye çevir") on the phone with Apple Translation (downloaded languages, system sheet) or online; translation mode for speech; no continuous sign translation. PHYSICAL TEST REQUIRED |
| 30 | Remote Assist | PARTIAL | LAN share with room code implemented; internet (WebRTC) REQUIRES_PROVIDER (signalling server) |
| 31 | Remote Assist privacy | IMPLEMENTED | Tap-only start, red bar, stop by voice, stops in background / 15 min / wrong codes / heat |
| 32 | MediaResourceCoordinator | IMPLEMENTED | Activities and conflicts, used by sharing and music |
| 33 | Remote Assist + AI | PARTIAL | Live Vision and sharing can run together; no AI on the viewer side |
| 34 | Dealer SuperMode vehicle session | ALREADY EXISTED + IMPLEMENTED | New fields are optional so old data loads |
| 35 | VIN super pipeline (+ vPIC) | IMPLEMENTED | Check digit (v1.4) + vPIC decode; only ErrorCode "0" fills |
| 36 | Canada recall workflow | IMPLEMENTED | Transport Canada API by make/model/year, honest wording, manufacturer VIN pages; web research fallback |
| 37 | Condition report | IMPLEMENTED | Recorded observations, unchecked areas, not a safety inspection |
| 38 | Damage voice capture | IMPLEMENTED | "Sağ ön jant çizik, not et" with an active vehicle; severity only when said |
| 39 | Damage photo follow-up | IMPLEMENTED | Photo within 3 minutes of a damage note is linked to it |
| 40 | Tire intelligence | IMPLEMENTED | Size and DOT age read exactly; no tread depth |
| 41 | Dashboard intelligence | IMPLEMENTED | Clearly lit lights only; no diagnosis |
| 42 | Vehicle options with provenance | IMPLEMENTED | VIN decoded (vPIC) and confirmed by the user (vehicle screen); "seen" and "unverified" labels exist but nothing produces them yet |
| 43 | Dealer photo director | IMPLEMENTED | Blur, exposure, glare, near-copies measured on the phone |
| 44 | Photo session progress | ALREADY EXISTED | Photo checklist |
| 45 | AutoLoom Media future adapter | IMPLEMENTED | `InventoryAdapter` interface; never automatic; share sheet today |
| 46 | Market research agent | ALREADY EXISTED | v1.4 |
| 47 | Parts assistant | IMPLEMENTED | Part number read exactly, saved to research |
| 48 | Inventory walk | PARTIAL | Next vehicle, walk-around areas, briefing; no stock-list import |
| 49 | Lot memory | IMPLEMENTED | Lot spot + walking directions |
| 50 | Quick inspection | IMPLEMENTED | Walk-around areas ("sol taraf temiz") |
| 51 | Delivery mode | ALREADY EXISTED | Delivery checklist |
| 52 | Service handoff | IMPLEMENTED | Note with VIN, lights, damage, tires, recalls to verify, open tasks |
| 53 | Daily life supermode | PARTIAL | Pieces below |
| 54 | Shopping list | ALREADY EXISTED | v1.4 |
| 55 | Receipt memory | IMPLEMENTED | "Fişi kaydet", "bu ay ne harcadım?" (saved receipts only) |
| 56 | Parking | ALREADY EXISTED | Photo option not added |
| 57 | Cooking | PARTIAL | Timers, vision and translation cover it; no recipe feature |
| 58 | Apple Music (optional) | PARTIAL | System player + own library (MediaPlayer); catalogue needs MusicKit App Service (paid program) |
| 59 | Smart home (optional) | IMPLEMENTED | The user's own Shortcuts after a tap; no unofficial Home access |
| 60 | MCP skills hub | IMPLEMENTED | Streamable HTTP client, Settings → Skills; REQUIRES_PROVIDER (a server) to use |
| 61 | MCP security | IMPLEMENTED | User-added https servers only, Keychain tokens, per-tool policy, host shown, destructive → tap |
| 62 | Provider + MCP teamwork | PARTIAL | Model picks the tool (strict JSON); no multi-step skill plans |
| 63 | Proactive Jarvis (opt-in) | PARTIAL | Morning briefing notification (default off, no details) |
| 64 | Daily briefing | ALREADY EXISTED | "Günün özeti" |
| 65 | Dealer morning briefing | IMPLEMENTED | Open vehicles, missing photos, VIN, recalls, undocumented damage, tasks due |
| 66 | User routines | IMPLEMENTED | Safe catalog steps only, honest per-step result |
| 67 | Action graph | IMPLEMENTED | Several commands in one sentence (batch 1) |
| 68 | Transactional execution | PARTIAL | Per-step honest results and undo of local steps; no rollback of external steps (by design) |
| 69 | Undo | ALREADY EXISTED + IMPLEMENTED | LocalUndo; lot spot and area checks added |
| 70 | Command correction | IMPLEMENTED | "Hayır, cumartesi" |
| 71 | Barge-in | ALREADY EXISTED | "Dur" while speaking |
| 72 | Local stop | ALREADY EXISTED | "Dur" vs "Kaydı durdur" vs "Müziği durdur" |
| 73 | Wake feedback | ALREADY EXISTED | Wake chip, connection honesty |
| 74 | Meta voice invocation | WAITING_FOR_DAT1 | Capability matrix probe |
| 75 | Custom wake | ALREADY EXISTED | Wake phrase settings |
| 76 | "What can you do?" + Command Library | IMPLEMENTED | Batch 1 |
| 77 | Command Lab | IMPLEMENTED | Batch 1 |
| 78 | Voice evaluation suite | IMPLEMENTED | `AutoLoomVoiceEvaluationTests`, per-area accuracy on the CI page |
| 79 | AI evaluations | BLOCKED | Apple's Evaluations framework needs a real on-device model; not on CI VMs |
| 80 | PHYSICAL_TEST_MATRIX.md | IMPLEMENTED | docs/PHYSICAL_TEST_MATRIX.md |
| 81 | UI rebuild | PARTIAL | Glass controls, palette, timeline, dashboards; no full redesign of every screen |
| 82 | Liquid Glass | IMPLEMENTED | Built with the iOS 27 SDK (system bars, tabs, sheets) + glass floating controls |
| 83 | GlassEffectContainer | IMPLEMENTED | `GlassGroup` for chips and the voice bar |
| 84 | Main assistant screen | PARTIAL | Existing layout kept; glass controls, context chips, palette button |
| 85 | Camera HUD | PARTIAL | Glass chips over the camera |
| 86 | Orb 2.0 | ALREADY EXISTED | AssistantOrb moods |
| 87 | Orb performance | ALREADY EXISTED | |
| 88 | Dynamic home | PARTIAL | Chips appear only for what is running |
| 89 | Context cards | IMPLEMENTED | Vehicle, sharing, offline, recording, timer, Live Vision chips (only when relevant) |
| 90 | Tab structure | ALREADY EXISTED | Five tabs |
| 91 | Command palette | IMPLEMENTED | Every local action, searchable, same executor |
| 92 | Memory UI | IMPLEMENTED | Visual memory gallery, Scene Timeline settings |
| 93 | Vehicle UI | IMPLEMENTED | Equipment, tires, recalls, walk-around, reports, lot spot, AutoLoom Media |
| 94 | Tasks UI | ALREADY EXISTED | |
| 95 | Timeline | IMPLEMENTED | Activity timeline (7/30 days) |
| 96 | Intelligence UI | ALREADY EXISTED | + on-device model section |
| 97 | Skills UI | IMPLEMENTED | Settings → Skills |
| 98 | Privacy dashboard | IMPLEMENTED | Running now + kept on this iPhone |
| 99 | Battery / performance manager | IMPLEMENTED | `PerformanceGuard`, Live Vision policy, sharing frame rate |
| 100 | Thermal manager | IMPLEMENTED | Critical heat stops Live Vision and sharing, never a recording |
| 101 | Provider metrics | ALREADY EXISTED | Routing diagnostics (v1.4) |
| 102 | Plugin architecture (registries) | IMPLEMENTED | ToolRegistry, ProviderRegistry, SkillStore, InventoryAdapters |
| 103 | Provider-independent Jarvis | ALREADY EXISTED | |
| 104 | Response normalizer | ALREADY EXISTED | |
| 105 | Spoken vs screen output | ALREADY EXISTED | `IntentOutcome.spoken/reply` |
| 106 | Control Center / Lock Screen controls | BLOCKED | Needs a widget extension target; the sideloaded unsigned IPA would need extra bundle ids and App Group signing by the user. App Shortcuts + Action Button cover quick access |
| 107 | Live Activities | BLOCKED | Same extension/signing reason |
| 108 | Widgets | BLOCKED | Same extension/signing reason |
| 109 | Spotlight | IMPLEMENTED | §18 |
| 110 | Share extension | BLOCKED | Same extension/signing reason |
| 111 | Captures | ALREADY EXISTED | |
| 112 | Photo quality labels | IMPLEMENTED | Photo director hints on dealer captures |
| 113 | Media search | IMPLEMENTED | Global search includes captures |
| 114 | Photos permission (add-only) | ALREADY EXISTED | |
| 115 | Music / audio coordination | IMPLEMENTED | Mixing audio session; coordinator note |
| 116 | Network resilience | IMPLEMENTED | Offline chip, offline assistant, local-first commands |
| 117 | Provider failover | ALREADY EXISTED | |
| 118 | Safety / action policy | ALREADY EXISTED + IMPLEMENTED | Skills, shortcuts, sharing follow it |
| 119 | Prompt injection defense | ALREADY EXISTED + IMPLEMENTED | Untrusted wrappers for OCR, documents, skills |
| 120 | Face handling | IMPLEMENTED | Vision prompts never identify people from faces |
| 121 | Natural confirmations | ALREADY EXISTED | |
| 122 | Long-task feedback | ALREADY EXISTED | Activity chips, progress |
| 123 | Result style | ALREADY EXISTED | |
| 124 | Voice parity consistency check in CI | IMPLEMENTED | Catalog tests |
| 125 | Turkish-first colloquial commands | IMPLEMENTED | Evaluation suite |
| 126 | Command chain tests | IMPLEMENTED | Evaluation suite + graph tests |
| 127 | Physical Jarvis test | PHYSICAL TEST REQUIRED | Matrix |
| 128 | Physical background test | PHYSICAL TEST REQUIRED | Matrix |
| 129 | Dealer physical test | PHYSICAL TEST REQUIRED | Matrix |
| 130 | Remote Assist physical test | PHYSICAL TEST REQUIRED | Matrix |
| 131 | UI quality review via screenshots | IMPLEMENTED | CI screenshots; launch crash (missing package framework) diagnosed and fixed |
| 132 | No placeholder buttons | IMPLEMENTED | Every button acts; AutoLoom Media shows "Not connected" (no dead button) |
| 133 | Performance profiling | PARTIAL | Frame metrics and performance screen; no Instruments profiling on CI |
| 134 | Target experience | PARTIAL | Pending physical tests |
| 135 | Documentation | IMPLEMENTED | docs/*.md for each area |
| 136 | Status labels | IMPLEMENTED | `CapabilityStatus` on every catalog action |
| 137 | CI + Release IPA | IMPLEMENTED | Every run builds Debug + Release unsigned IPAs |
| 138 | Don't stop at green | — | Working rule |
| 139 | Final gap audit | IMPLEMENTED | This file |
| 140 | Final Turkish report | IMPLEMENTED | Delivered with the final run |
| 141 | Order of work | — | Followed |
