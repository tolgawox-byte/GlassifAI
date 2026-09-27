# Voice invocation and the assistant name

Researched 2026-09-27 from Meta's official Wearables documentation ("Respond to Hey Meta voice invocations", https://wearables.developer.meta.com/docs/develop/dat/voice-invocations, DAT SDK v1.0 docs) and from the symbols in the Meta DAT binaries: `VoiceInvocation*` types exist in `MWDATCore` **1.0.0** and are absent from **0.4.0**, the version this app uses.

## Two separate things

| | Controlled by | What it does |
|---|---|---|
| **System invocation** | Meta (glasses) and Apple (Siri) | Wakes the device assistant and opens or starts an app |
| **Assistant name** (e.g. "Jarvis") | AutoLoom settings | Identity and conversation context once a conversation is running |

The assistant name never becomes a system wake word. The app does not pretend otherwise.

## Findings

| Question | Answer | Source |
|---|---|---|
| How are third-party DAT apps invoked? | The wearer says *"Hey Meta, start {YOUR APP NAME}"*. Meta AI launches or foregrounds the app and delivers a `LaunchApp` voice invocation. | Meta docs, voice-invocations |
| Does the developer register a phrase or name? | Yes. The **app name configured in the Wearables Developer Center** "acts as the keyword the voice service matches". Phrases are not declared in `Info.plist`. | same |
| What else is required? | 1. Mobile app configuration (bundle ID) in the Developer Center. 2. A request for the **Voice Invocation** permission, then Meta's approval. 3. An app registered with the Meta AI app. | same |
| Aliases? | Not documented; one app name per project. | same (no alias mechanism described) |
| Arbitrary wake word instead of "Hey Meta"? | **No.** "Hey Meta" is a system-owned transaction. | lifecycle docs ("Transactions … 'Hey Meta'") |
| Cold launch from a closed or background app? | Yes: "If your app is not already running, the command cold-launches it." | voice-invocations |
| Start a speech session immediately? | The app receives `LaunchApp` and can start its own voice session. Every invocation must be answered exactly once through `responseHandle.sendSuccess`/failure. | voice-invocations |
| Is ASR text after the phrase delivered? | **No.** The only documented invocation type is `LaunchApp` (on iOS it carries the `deviceIdentifier`). No transcript is included. | voice-invocations, API reference |
| Best practice | Avoid "AI" in the app name, because it is confused with Meta AI. Open the stream early at app launch. | voice-invocations |
| SDK version | `VoiceInvocationsStream` exists only in DAT **1.0.0** (not in 0.4.0) | binary symbols |
| Device and app requirements | DAT 1.0 needs glasses firmware **V128** and Meta AI **V290**. Rollout starts **2026-09-30**. Integration versions created before 1.0 do not work with 1.0 builds. | version-dependencies docs |
| Displayless Ray-Ban Meta | Invocation is voice only. The app answers through audio; nothing is shown on the glasses. | — |

### Siri (Apple)

| Question | Answer |
|---|---|
| Official iOS invocation | App Shortcuts. **"Hey Siri, start AutoLoom"** is implemented. |
| Custom phrase | The user can create a personal shortcut in the Shortcuts app that runs *Start Conversation* and name it after their assistant. "Hey Siri, Jarvis" then opens the app and starts listening. This is Apple's supported way to customize a Siri phrase. |
| Locked or closed app | Siri opens the app, and the iPhone must be unlocked for that. |
| Custom always-on wake word ("Hey Jarvis") | **Not supported by iOS** for third-party apps. Keeping the microphone running in the background to fake one is not allowed and **not implemented**. |
| Siri through the glasses' microphone | **UNVERIFIED.** Physical test required. |

## Status in this build

| Feature | Status |
|---|---|
| Custom assistant name (Settings → Assistant) | **Implemented.** Stored locally, validated (letters required, max 24 characters, default "AutoLoom"), and injected into the voice session's instructions. Applies from the next conversation. |
| Addressing by name in an active conversation | **Implemented** through the existing realtime session. The model treats "Jarvis, …" as getting its attention; no extra recognizer runs. |
| "Only answer when called by name" | **Experimental** toggle (off by default). It is an instruction to the voice model, not a gate on the microphone. |
| "Hey Siri, start AutoLoom" and a custom Siri shortcut | **Implemented** (App Intent + App Shortcut). Physical test required. |
| Idempotent start (button, Siri, future Meta invocation) | **Implemented** (`VoiceStartCoordinator`). A second request during a start or an active call is ignored. Unit tested. |
| "Hey Meta, start AutoLoom" | **Not available in this build.** Needs the DAT 1.0 upgrade, Developer Center configuration, and Voice Invocation approval. |
| Custom "Hey Jarvis" system wake word | **Not supported by the current Meta or iOS platforms.** Not implemented, not faked. |
| Always-on background custom wake word | **Not supported by the current platform.** |

## Plan for "Hey Meta" (after the DAT 1.0 upgrade)

1. In the Wearables Developer Center:
   - add the iOS bundle ID `com.marcoiannello.GlassifAI`
   - request the **Voice Invocation** permission
   - set the app name, for example "AutoLoom Glasses"; avoid "AI"
   - set up a release channel
   - put `MetaAppID`, `ClientToken`, and `TeamID` in `Info.plist` (no more Developer Mode)
2. At launch, create `VoiceInvocationsStream(wearables:)` and register listeners before `start(deviceIdentifier:)`. Start it for each device in `wearables.devices` and `devicesStream()`.
3. On `LaunchApp`:
   - call `VoiceStartCoordinator.shared.request(.metaInvocation)`, which prepares the Ray-Ban audio route and starts listening, and is idempotent
   - then `await launchApp.responseHandle.sendSuccess(actionOutput: nil)`
4. Physical test: say "Hey Meta, start AutoLoom Glasses" in each state (app closed, in the background, in the foreground) and record the exact phrase that works.

## Privacy

- The assistant name is stored in `UserDefaults` only.
- Invocation diagnostics keep the time, type, and outcome of the last 10 invocations, in memory. No wake audio is recorded or stored.
- The microphone is live only while a conversation is active and visible, and it respects mute and end-call.
