# Open-source research (brief §69)

Eight public projects were reviewed on 2026-09-28: the README, the LICENSE and one to three key files each. The aim was ideas, not code: nothing was copied, and each project's license limits what may be reused.

| Project | License | What it is |
|---|---|---|
| facebook/meta-wearables-dat-ios | Meta Wearables Developer Terms + Acceptable Use Policy (not open source) | The official DAT Swift package this app links |
| rayl15/OpenVision | MIT | SwiftUI glasses assistant (local MLX, Apple Foundation Models, OpenClaw, Gemini Live, OpenAI) |
| iannellomarco/GlassifAI | MIT (Codex and LiveKit WebRTC: Apache-2.0) | This app's upstream; its latest commit is already in this history |
| maxaistudios/max-ai-assistant | none found | SwiftUI glasses assistant (DAT 0.5.0, OpenAI, "Hey Max") |
| Couvbat/Jarvis | MIT | Local Python voice assistant (faster-whisper, Ollama, Piper) |
| samonti86/jarvis | MIT | Python voice assistant for Windows with a Claude tool loop |
| openclaw/openclaw | MIT | Agent gateway with chat channels and companion apps |
| Caerii/smartsight-ios | Meta DAT terms text (not open source) | Study assistant built on Meta's CameraAccess sample |

## Adopted in v1.1.1

| Idea | Source | What AutoLoom does now |
|---|---|---|
| Opt out of the SDK's data collection | DAT README, "Opting out of data collection" and "Crash reporting" | The DAT SDK's analytics (and, on 1.0, SDK crash capture) are on unless `Info.plist` opts out. The app now sets `MWDAT` → `Analytics` / `CrashReporting` → `OptOut` = YES, so "no analytics" in `PRIVACY_AND_PERMISSIONS.md` is true |
| Changes after untrusted content need a yes | Couvbat/Jarvis (`src/jarvis/policy/taint.py`) | A reminder, event, note, notification or copy that the planner model proposes in a turn that also brought camera, web or agent content waits for a spoken yes or a tap (`NATIVE_TOOLS.md`). Before, only the prompts said so |
| Wake-recognition restarts must not spin | OpenVision (`VoiceCommandService.swift`: restarts at most every 0.6 s, because the glasses' Bluetooth microphone can end recognition at once) | The listener ignores the end report of a cancelled request (which could restart recognition endlessly) and backs off 0.6–5 s after requests that end within a second (`WAKE_INVOCATION.md`) |

## Already equivalent in AutoLoom

- HEVC streaming that continues in the background (DAT 0.5.0 changelog). OpenVision uses the raw codec, which pauses when the phone is locked.
- One tool registry, dates computed by the app rather than the model, and confirmation levels (OpenVision, samonti86/jarvis).
- Wrapping outside content as untrusted (openclaw's `EXTERNAL_UNTRUSTED_CONTENT`, the app's `untrusted_content`).
- Memory with facts, conversation summaries, NLEmbedding scoring and deduplication (max-ai-assistant).
- Scene-change gating for Live Vision (OpenVision), wake phrase and start/stop sounds (SmartSight), a morning briefing and hybrid search (samonti86/jarvis).
- OpenClaw access: Keychain token, https or a private network only, a confirmation per request.

## Ideas for later (not built)

- **Keep the words said with the wake phrase** ("Hey Jarvis, not al …" in one breath) as the first request (Couvbat/Jarvis `WAKE_WORD_TAIL`, OpenVision). The brief's flow waits for "Bağlandım, dinliyorum." first, so this is optional.
- **DAT 1.0 Inputs** (touchpad select and navigate, capture button) to confirm or cancel on the glasses. Beta; test builds only.
- **Object list for visual memories**, so "where did I see X?" can answer from structured data (max-ai-assistant's idea; to be written from scratch, since that project has no license).
- **OpenClaw**: point the app at a restricted "reader" agent, as openclaw's prompt-injection guide recommends. This is an owner setting, not code.
- An audit that tool logs record parameter names but never values (OpenVision's rule; the app's trace already redacts numbers and user text).

## Not adopted, and why

- Face recognition or speaker identification: Meta's Acceptable Use Policy forbids identifying people from the glasses' sensors without Meta's approval.
- API keys in UserDefaults (max-ai-assistant): the app keeps secrets in the Keychain.
- Periodic photo uploads to a plain-HTTP backend (SmartSight).
- Bundled wake-word or voice models: openWakeWord's pretrained models (including `hey_jarvis`) are CC BY-NC-SA 4.0, which is non-commercial, and Piper includes eSpeak NG (GPL-3.0-or-later). The app bundles no voice assets.

## Licensing cautions

- DAT and SmartSight grant no open-source rights. Do not copy SmartSight's code or sounds.
- The DAT changelog says apps using experimental features (`Camera.photo`, voice invocation, Speech, Inputs) "cannot be published yet", so the DAT 1.0 build stays test-only.
- max-ai-assistant has no license, so it can be a source of ideas only.
- Reused MIT or Apache code keeps its notices (`THIRD_PARTY_NOTICES.md`). OpenVision's MP3 sounds have no stated source.
- Not a license, but a risk: the ChatGPT subscription voice connection is private and unsupported (README, "Important compatibility note").
