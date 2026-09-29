# Gap audit — "Ultimate Jarvis Product Expansion" brief (2026-09-29)

Every section of the brief with its state. Updated as work lands; the final report is built from this file.

States: **IMPLEMENTED** (in this pass, unit-tested in CI) · **ALREADY EXISTED** · **PARTIAL** · **BLOCKED** (reason) · **PHYSICAL TEST REQUIRED** · **WAITING_FOR_DAT1** · **REQUIRES_PROVIDER** · **REQUIRES_PERMISSION** · **TODO** (not done yet).

Rollback tag for this pass: `rollback-405e461-before-jarvis-expansion` (v1.4 final state).

| § | Requirement | State | Notes |
|---|---|---|---|
| 0 | One assistant that sees, hears, remembers, researches, acts | TODO | Summary of everything below |
| 1 | Implement, don't just plan | — | Working rule |
| 2 | Protect current work, rollback tag | IMPLEMENTED | `rollback-405e461-before-jarvis-expansion` |
| 3 | Research pass (Apple, Meta, public projects) | TODO | |
| 4 | DAT 1.0 timing, RayBanCapabilityMatrix | TODO | |
| 5 | Universal voice parity, ActionCatalog | TODO | |
| 6 | ActionCatalog powers voice, agents, App Intents, UI, Command Lab, tests | TODO | |
| 7 | Voice command for every important feature | TODO | |
| 8 | Transcript → intent → parameters → permission → executor → result → speech tested | TODO | |
| 9 | High-priority local commands | TODO | |
| 10 | Wake once, conversational follow-up, entity carry-over | TODO | |
| 11 | Jarvis personality | ALREADY EXISTED | v1.4 JarvisStyle (intensity, address) |
| 12 | Jarvis state awareness (current vehicle, person, place…) | TODO | |
| 13 | On-device brain (Foundation Models) | TODO | |
| 14 | Foundation Model profiles | TODO | |
| 15 | Offline mode | TODO | |
| 16 | App Intents | TODO | |
| 17 | Siri AI | TODO | |
| 18 | Core Spotlight second brain | TODO | |
| 19 | Global natural-language search | TODO | |
| 20 | Visual second brain | TODO | |
| 21 | Visual memory search | TODO | |
| 22 | No continuous recording by default | TODO | |
| 23 | Scene Timeline (opt-in) | TODO | |
| 24 | Live Vision adaptive sampling | TODO | |
| 25 | Scene change detection | TODO | |
| 26 | Live Vision commands | TODO | |
| 27 | Document intelligence | TODO | |
| 28 | OCR / barcode / QR local pipeline | TODO | |
| 29 | Live translation | TODO | |
| 30 | Remote Assist | TODO | |
| 31 | Remote Assist privacy | TODO | |
| 32 | MediaResourceCoordinator | TODO | |
| 33 | Remote Assist + AI | TODO | |
| 34 | Dealer SuperMode vehicle session | TODO | |
| 35 | VIN super pipeline (+ vPIC) | TODO | |
| 36 | Canada recall workflow | TODO | |
| 37 | Condition report | TODO | |
| 38 | Damage voice capture | TODO | |
| 39 | Damage photo follow-up | TODO | |
| 40 | Tire intelligence | TODO | |
| 41 | Dashboard intelligence | TODO | |
| 42 | Vehicle options with provenance | TODO | |
| 43 | Dealer photo director | TODO | |
| 44 | Photo session progress | TODO | |
| 45 | AutoLoom Media future adapter | TODO | |
| 46 | Market research agent | TODO | |
| 47 | Parts assistant | TODO | |
| 48 | Inventory walk | TODO | |
| 49 | Lot memory | TODO | |
| 50 | Quick inspection | TODO | |
| 51 | Delivery mode | TODO | |
| 52 | Service handoff | TODO | |
| 53 | Daily life supermode | TODO | |
| 54 | Shopping list | ALREADY EXISTED | v1.4 |
| 55 | Receipt memory | TODO | |
| 56 | Parking | ALREADY EXISTED | v1.4 (photo option TODO) |
| 57 | Cooking | TODO | |
| 58 | Apple Music (optional) | TODO | |
| 59 | Smart home (optional) | TODO | |
| 60 | MCP skills hub | TODO | |
| 61 | MCP security | TODO | |
| 62 | Provider + MCP teamwork | TODO | |
| 63 | Proactive Jarvis (opt-in) | TODO | |
| 64 | Daily briefing | TODO | |
| 65 | Dealer morning briefing | TODO | |
| 66 | User routines | TODO | |
| 67 | Action graph | TODO | |
| 68 | Transactional execution | TODO | |
| 69 | Undo | ALREADY EXISTED | v1.4 LocalUndo |
| 70 | Command correction | TODO | |
| 71 | Barge-in | TODO | |
| 72 | Local stop | TODO | |
| 73 | Wake feedback | TODO | |
| 74 | Meta voice invocation | TODO | |
| 75 | Custom wake | TODO | |
| 76 | "What can you do?" + Command Library | TODO | |
| 77 | Command Lab | TODO | |
| 78 | Voice evaluation suite | TODO | |
| 79 | AI evaluations | TODO | |
| 80 | PHYSICAL_TEST_MATRIX.md | TODO | |
| 81 | UI rebuild | TODO | |
| 82 | Liquid Glass | TODO | |
| 83 | GlassEffectContainer | TODO | |
| 84 | Main assistant screen | TODO | |
| 85 | Camera HUD | TODO | |
| 86 | Orb 2.0 | TODO | |
| 87 | Orb performance | TODO | |
| 88 | Dynamic home | TODO | |
| 89 | Context cards | TODO | |
| 90 | Tab structure | TODO | |
| 91 | Command palette | TODO | |
| 92 | Memory UI | TODO | |
| 93 | Vehicle UI | TODO | |
| 94 | Tasks UI | TODO | |
| 95 | Timeline | TODO | |
| 96 | Intelligence UI | ALREADY EXISTED | v1.4 |
| 97 | Skills UI | TODO | |
| 98 | Privacy dashboard | TODO | |
| 99 | Battery / performance manager | TODO | |
| 100 | Thermal manager | TODO | |
| 101 | Provider metrics | TODO | |
| 102 | Plugin architecture (registries) | TODO | |
| 103 | Provider-independent Jarvis | ALREADY EXISTED | v1.4 ResponseNormalizer |
| 104 | Response normalizer | ALREADY EXISTED | v1.4 |
| 105 | Spoken vs screen output | TODO | |
| 106 | Control Center / Lock Screen controls | TODO | |
| 107 | Live Activities | TODO | |
| 108 | Widgets | TODO | |
| 109 | Spotlight | TODO | |
| 110 | Share extension | TODO | |
| 111 | Captures | ALREADY EXISTED | v1.4 |
| 112 | Photo quality labels | TODO | |
| 113 | Media search | TODO | |
| 114 | Photos permission (add-only) | ALREADY EXISTED | v1.4 |
| 115 | Music / audio coordination | TODO | |
| 116 | Network resilience | TODO | |
| 117 | Provider failover | ALREADY EXISTED | v1.4 |
| 118 | Safety / action policy | TODO | |
| 119 | Prompt injection defense | TODO | |
| 120 | Face handling | TODO | |
| 121 | Natural confirmations | TODO | |
| 122 | Long-task feedback | TODO | |
| 123 | Result style | TODO | |
| 124 | Voice parity consistency check in CI | TODO | |
| 125 | Turkish-first colloquial commands | TODO | |
| 126 | Command chain tests | TODO | |
| 127 | Physical Jarvis test | TODO | |
| 128 | Physical background test | TODO | |
| 129 | Dealer physical test | TODO | |
| 130 | Remote Assist physical test | TODO | |
| 131 | UI quality review via screenshots | TODO | CI screenshot step added |
| 132 | No placeholder buttons | TODO | |
| 133 | Performance profiling | TODO | |
| 134 | Target experience | TODO | |
| 135 | Documentation | TODO | |
| 136 | Status labels | TODO | |
| 137 | CI + Release IPA | TODO | |
| 138 | Don't stop at green | — | Working rule |
| 139 | Final gap audit | TODO | This file |
| 140 | Final Turkish report | TODO | |
| 141 | Order of work | — | Followed |
