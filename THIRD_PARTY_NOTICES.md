# Third-party notices

GlassifAI’s original application code and branding are released under the MIT License in [`LICENSE`](LICENSE). Third-party components retain their own licenses and terms.

- **Meta Wearables Device Access Toolkit and camera-access sample code** — governed by the [Meta Wearables Developer Terms](https://wearables.developer.meta.com/terms) and [Acceptable Use Policy](https://wearables.developer.meta.com/acceptable-use-policy). The upstream notices are preserved in [`NOTICE`](NOTICE).
- **OpenAI Codex** — Apache License 2.0. The pinned source, its license and its NOTICE are preserved under [`vendor/codex`](vendor/codex); the NOTICE and license texts also ship in the app's license file.
- **LiveKit WebRTC XCFramework** (`livekit/webrtc-xcframework` 144.7559.11, `46f2af8`).
  - The packaging repository is under the MIT License ("Copyright (c) 2021 WebRTC SDKs").
  - The binary (download checksum `07c5caf7…` matches the package) carries **WebRTC's BSD 3-Clause license** and its patent grant.
  - WebRTC bundles further components. Their texts were taken at the revisions pinned in WebRTC's DEPS for branch 7559:
    - **BoringSSL** `b94d71f8` and **Abseil**: Apache License 2.0 (BoringSSL is no longer OpenSSL/ISC at this revision);
    - **libsrtp** `a52756ac`, **Opus**, **libvpx** `9a7674e1` (with its patent grant), **libyuv** `4825d9b2` and **CRC32C** `d3d60ac6`: BSD-style licenses.
  - The full texts ship in the app (`ios/GlassifAI/Runtime/AutoLoomThirdPartyLicenses.txt`, Settings → Licenses → Full license texts), as the BSD licenses require for binaries.
  - Not listed yet: components WebRTC may also link (dav1d, libaom, libjpeg-turbo), and the Rust crates of the native bridge. Both are tracked in `JARVIS_IMPLEMENTATION_PLAN.md` 1.16.
- **QR Code generator library** by Project Nayuki — MIT License. Used by the JARVIS PC Companion (`pc-companion/src/vendor/qrcodegen.ts`, from commit `3c6d0b3`) to draw the pairing QR code; adapted from TypeScript namespaces to module syntax, algorithm unchanged. Copyright (c) Project Nayuki; the full MIT notice is kept at the top of that file.

AutoLoom Media Glasses is a modified version of GlassifAI. The GlassifAI MIT License and its copyright notice (Marco Iannello) are retained in [`LICENSE`](LICENSE) and shown in the app under Settings → Licenses. The AutoLoom Media name, the source logo (`assets/brand/LOGO 2.png`), and the app icon, brand mark, and launch assets derived from it are AutoLoom Media brand assets and are not licensed under the MIT License.

Integrations that ship no third-party code in this repository:
- **Meta Wearables DAT 0.5.0**: a Swift package fetched at build time under Meta's terms (above).
- **Apple frameworks**: Vision (OCR), Speech, EventKit, and App Intents are part of iOS.
- **Voices and sounds**: nothing is bundled. The live voice is ChatGPT's realtime voice; "Jarvis Style" is instructions plus one of ChatGPT's own voices, not a recording or a clone. The connection chimes are tones generated in code at run time. The offline announcement uses an Apple system voice already installed on the iPhone (`AVSpeechSynthesizer`). No voice model, film audio or dialogue is downloaded or included.
- **OpenClaw**: the optional agent gateway adapter talks to the user's own OpenClaw installation over its documented HTTP API. No OpenClaw code is included.

No third-party trademark rights are granted by the GlassifAI MIT License. ChatGPT and OpenAI are trademarks of OpenAI; Meta and Ray-Ban Meta are trademarks of their respective owners. GlassifAI is an independent project and is not affiliated with or endorsed by OpenAI or Meta.
