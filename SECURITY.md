# Security policy

## Reporting a vulnerability

Please do not put the details of a vulnerability in a public issue.

- When GitHub's private vulnerability reporting is enabled for this repository (the owner turns it on in Settings → Code security), use it.
- Until then, open an issue titled "Security contact request" with no details; the owner will reply with a private channel.

Include the affected commit, reproduction steps, impact, and any suggested mitigation.

Do not include access tokens, refresh tokens, device codes, account identifiers, camera frames, or other private user data in a report.

## Scope

High-priority reports include credential disclosure, insecure Keychain handling, unintended camera persistence, authentication bypass, sideband session confusion, or network traffic sent anywhere other than the documented providers.

The private ChatGPT realtime transport is an upstream compatibility risk, not by itself a GlassifAI vulnerability. Reports showing that GlassifAI exposes credentials or weakens transport security remain in scope.
