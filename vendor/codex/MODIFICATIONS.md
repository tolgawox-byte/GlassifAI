# Changes to the vendored OpenAI Codex source

This directory holds OpenAI Codex `rust-v0.149.0` under the Apache License 2.0 (`LICENSE`, `NOTICE`). As section 4(b) of the license asks, this file lists every file changed from that release. Each changed file also carries a notice at its top.

Checked on 2026-10-13 with `diff -r` against the pristine `rust-v0.149.0` source. Only these two files differ; every other file is byte-identical, including the realtime call and sideband code (`codex-api`).

| File | Change | Why |
|---|---|---|
| `codex-rs/http-client/src/custom_ca.rs` | On iOS, `maybe_build_rustls_client_config_with_env` always builds a rustls configuration, even without a configured CA bundle. `build_rustls_client_config` adds the Mozilla roots from `webpki-roots` when the platform store yields no certificates. | On iOS, `rustls-native-certs` finds no system roots, so TLS to the realtime service would have no trust anchors. |
| `codex-rs/http-client/Cargo.toml` | Adds the `webpki-roots` dependency. | Used by the change above. |

Both changes come from the original GlassifAI port (commit `d5fa48f`, "Launch GlassifAI"). AutoLoom only added the notices.
