# Provider security

## Credentials

- API keys live only in the iOS **Keychain**, service `com.autoloom.providers`, account = provider, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`: never synced or backed up to another device, readable after the first unlock (the assistant also answers through the glasses with the phone locked). The stricter `WhenUnlocked` class would break locked-phone requests.
- Never in UserDefaults, files, logs, diagnostics, crash text or commits. A card shows at most `••••` + the last four characters.
- A key is saved only after its first test succeeds; a refused key is not kept.
- **Disconnect** deletes the key from the Keychain, clears its models, health and pins; the router falls back at once and the app keeps working.
- Error texts come from the provider's `error.message`, sanitized (`LogSanitizer`) and shortened; a unit test checks the key never appears in an error.
- Gemini's key goes in the `x-goog-api-key` header, never in the URL.

## What leaves the phone

Each provider gets the minimum for one job (`AutoLoomAgentOrchestrator.Context`): the request, a camera image only for visual roles, at most five relevant memories, the recent conversation summary, and the current entities. Research providers never receive images. The whole memory database, contacts, notes, captures and dealer data are never sent. Memory stays AutoLoom's (on the phone); providers do not own or store it.

## Untrusted content

Camera text (OCR), web results, documents and other agents' findings are wrapped with `UntrustedContent.wrap` and every specialist prompt says such text is information, never an instruction. They cannot change tool permissions, prompts, credentials or memory policy. Providers never execute actions; only the native executor does, after the confirmation each action needs. Media commands and actions run only from the user's own words.

## Diagnostics

Routing diagnostics record intent, strategy, roles, providers, models, latency, result and fallback. They never contain prompts, answers, images or keys. No chain-of-thought is shown or logged; `<think>` blocks from reasoning models are removed before anything is displayed or spoken.

## Not done

No scraping, no browser-cookie or session reuse, no unofficial sign-in for any provider. Paid providers are never enabled automatically (see `COST_CONTROLS.md`).
