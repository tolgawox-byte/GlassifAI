# Privacy and permissions

AutoLoom Media Glasses is an independent app by AutoLoom Media, built on the MIT-licensed GlassifAI project. It is not made, endorsed, or supported by OpenAI, ChatGPT, Meta, Ray-Ban, or EssilorLuxottica.

## iOS permissions

| Permission | Why | When it is used |
|---|---|---|
| Microphone | Your voice conversation with the assistant | Only while a conversation is active (the call button is red) |
| Camera (iPhone) | Answer questions about what you see | Only when the camera source is **iPhone**; frames stay on the phone until a question needs one |
| Bluetooth | Meta glasses connection (DAT) and glasses audio (HFP) | While the glasses are the camera and/or the audio route |
| Meta glasses camera | Granted in the Meta AI app for this app | Only when the camera source is **Ray-Ban** |
| Background audio / Bluetooth / external accessory | Keep a call and the glasses link alive with the screen locked | During an active conversation |

Denied permissions degrade gracefully: without the camera the assistant still talks, searches, and reasons; without the microphone you can type questions.

## Data flow

| Data | Leaves the iPhone? | Where to | Stored? |
|---|---|---|---|
| Microphone audio | Yes, streamed during a conversation | OpenAI (ChatGPT realtime voice) | Not by this app |
| Camera preview | **No** | — | No |
| One camera frame (JPEG) per visual question | Yes, only when a question needs to see | OpenAI (Codex Responses, `store: false`) | Not by this app; the in-memory frame is replaced continuously and cleared when the source changes |
| Typed questions, delegated requests, conversation context | Yes, as part of your requests | OpenAI | In memory for the current app session only |
| Web searches | Yes | OpenAI's search (hosted tool or backend search endpoint) on your account | Source cards in memory only |
| ChatGPT tokens | Only to OpenAI | auth.openai.com / chatgpt.com | iOS Keychain, `AfterFirstUnlockThisDeviceOnly` |
| On-device memory (opt-in) | Only as context inside your own requests while enabled | OpenAI | `Application Support/AutoLoom/memory.json` with complete file protection |
| Diagnostics | Only if you copy and share the report yourself | — | In memory; sanitized |

The app has no AutoLoom backend and no analytics, and it never uploads anything to AutoLoom, Supabase, Vercel, or any other service.

## Security controls

- **Secrets:** Keychain only; never in logs, diagnostics, or the repository.
- **Logs:** `LogSanitizer` removes bearer tokens, JWTs, `*_token` values, API keys, email addresses, long blobs, and `data:` image/audio payloads. Raw images and audio are never logged.
- **Untrusted content:** text from web pages, images, QR codes, and signs is wrapped as `<untrusted_content>`. Models are told to treat it as information only, so embedded "instructions" can't change the task or trigger actions.
- **SSRF:** the app never fetches web pages itself; search runs server-side. Every URL the app shows or opens must pass `URLSafety`, which blocks:
  - `localhost`, `.local`, `.internal`, and single-label hosts
  - private, link-local, CGNAT, and multicast IPv4/IPv6 ranges, including cloud metadata `169.254.169.254`
  - numeric-obfuscated hosts, credentials in URLs, non-web schemes, and unusual ports
- **Actions:** the app cannot send email or messages, create calendar events, delete files, push code, deploy, or buy anything. Such requests are declined. Any future action must need explicit on-screen confirmation; a spoken "yes" alone will never count.
- **Stale results:** every task carries a session, turn, and task ID. Results from cancelled, superseded, or earlier-session tasks are discarded, never spoken.

## Deleting data

- **Settings → Memory → Delete all memory**, or swipe to delete single items.
- **Settings → Privacy → Delete all local data** clears on-device memory, conversation context, sources, diagnostics, and the cached camera frame.
- **Settings → ChatGPT account → Disconnect ChatGPT** removes the tokens from the Keychain.
- Deleting the app removes everything above.

## Known risks

- Voice and model access use private Codex endpoints (see `CAPABILITIES.md`). They can change or stop working, and using them is subject to OpenAI's terms for your account.
- The realtime call sends a static attestation header inherited from upstream GlassifAI. It works today, but OpenAI may reject it in the future.
- Meta DAT use is governed by the Meta Wearables Developer Terms and Acceptable Use Policy.
