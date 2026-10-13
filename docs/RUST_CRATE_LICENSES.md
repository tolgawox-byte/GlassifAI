# Rust crate licenses (native bridge)

Every package in `native/GlassifAICodexBridge/Cargo.lock`, with the license its crates.io release declares (crates.io API, read 2026-10-13). This is a **superset** of what the iOS static library contains: the lockfile also lists build-time crates and crates for other platforms (Windows, Linux).

Full license texts per crate are not reproduced here yet; that needs `cargo about` (or equivalent) in CI (`JARVIS_IMPLEMENTATION_PLAN.md` 1.16).

## Summary

- 553 crates.io packages, 19 path or git packages (the vendored Codex crates and two openai-oss forks of tungstenite and tokio-tungstenite; their licenses are in `vendor/codex` and the forks' repositories).
- Packages with no license in the crates.io answer: 0.

| Declared license | Packages |
|---|---|
| `MIT OR Apache-2.0` | 293 |
| `MIT` | 95 |
| `MIT/Apache-2.0` | 28 |
| `Apache-2.0 OR MIT` | 25 |
| `Unicode-3.0` | 25 |
| `Apache-2.0 WITH LLVM-exception OR Apache-2.0 OR MIT` | 14 |
| `Apache-2.0` | 12 |
| `Unlicense OR MIT` | 8 |
| `Apache-2.0/MIT` | 5 |
| `Zlib` | 5 |
| `MIT OR Apache-2.0 OR Zlib` | 4 |
| `Zlib OR Apache-2.0 OR MIT` | 3 |
| `Apache-2.0 OR ISC OR MIT` | 3 |
| `ISC` | 3 |
| `BSD-2-Clause` | 2 |
| `BSL-1.0` | 2 |
| `CC0-1.0 OR MIT-0 OR Apache-2.0` | 2 |
| `Unlicense/MIT` | 2 |
| `BSD-3-Clause OR Apache-2.0` | 2 |
| `MIT OR Apache-2.0 OR LGPL-2.1-or-later` | 2 |
| `BSD-2-Clause OR Apache-2.0 OR MIT` | 2 |
| `0BSD OR MIT OR Apache-2.0` | 1 |
| `ISC AND (Apache-2.0 OR ISC)` | 1 |
| `ISC AND (Apache-2.0 OR ISC) AND Apache-2.0 AND MIT AND BSD-3-Clause AND (Apache-2.0 OR ISC OR MIT) AND (Apache-2.0 OR ISC OR MIT-0)` | 1 |
| `CC0-1.0 OR Apache-2.0 OR Apache-2.0 WITH LLVM-exception` | 1 |
| `(Apache-2.0 OR MIT) AND BSD-3-Clause` | 1 |
| `Apache-2.0 / MIT` | 1 |
| `MIT AND BSD-3-Clause` | 1 |
| `MIT OR Zlib OR Apache-2.0` | 1 |
| `(MIT OR Apache-2.0) AND Apache-2.0` | 1 |
| `MPL-2.0` | 1 |
| `Apache-2.0 AND ISC` | 1 |
| `Apache-2.0 OR BSL-1.0` | 1 |
| `Apache-2.0 OR BSD-3-Clause` | 1 |
| `BSD-3-Clause` | 1 |
| `(MIT OR Apache-2.0) AND Unicode-3.0` | 1 |
| `CDLA-Permissive-2.0` | 1 |

## Needs attention

| Package | License | Note |
|---|---|---|
| `fixed_decimal 0.7.2` | `Unicode-3.0` | Unicode license: keep the notice. |
| `icu_collections 2.2.0` | `Unicode-3.0` | Unicode license: keep the notice. |
| `icu_decimal 2.2.0` | `Unicode-3.0` | Unicode license: keep the notice. |
| `icu_decimal_data 2.2.0` | `Unicode-3.0` | Unicode license: keep the notice. |
| `icu_locale 2.2.0` | `Unicode-3.0` | Unicode license: keep the notice. |
| `icu_locale_core 2.2.0` | `Unicode-3.0` | Unicode license: keep the notice. |
| `icu_locale_data 2.2.0` | `Unicode-3.0` | Unicode license: keep the notice. |
| `icu_normalizer 2.2.0` | `Unicode-3.0` | Unicode license: keep the notice. |
| `icu_normalizer_data 2.2.0` | `Unicode-3.0` | Unicode license: keep the notice. |
| `icu_plurals 2.2.0` | `Unicode-3.0` | Unicode license: keep the notice. |
| `icu_plurals_data 2.2.0` | `Unicode-3.0` | Unicode license: keep the notice. |
| `icu_properties 2.2.0` | `Unicode-3.0` | Unicode license: keep the notice. |
| `icu_properties_data 2.2.0` | `Unicode-3.0` | Unicode license: keep the notice. |
| `icu_provider 2.2.0` | `Unicode-3.0` | Unicode license: keep the notice. |
| `litemap 0.8.1` | `Unicode-3.0` | Unicode license: keep the notice. |
| `option-ext 0.2.0` | `MPL-2.0` | MPL-2.0: file-level copyleft. Unmodified files from crates.io; keep the source available and the notice. |
| `potential_utf 0.1.4` | `Unicode-3.0` | Unicode license: keep the notice. |
| `r-efi 5.3.0` | `MIT OR Apache-2.0 OR LGPL-2.1-or-later` | Copyleft option offered alongside permissive ones: use a permissive option. |
| `r-efi 6.0.0` | `MIT OR Apache-2.0 OR LGPL-2.1-or-later` | Copyleft option offered alongside permissive ones: use a permissive option. |
| `tinystr 0.8.3` | `Unicode-3.0` | Unicode license: keep the notice. |
| `unicode-ident 1.0.22` | `(MIT OR Apache-2.0) AND Unicode-3.0` | Unicode license: keep the notice. |
| `writeable 0.6.2` | `Unicode-3.0` | Unicode license: keep the notice. |
| `yoke 0.8.2` | `Unicode-3.0` | Unicode license: keep the notice. |
| `yoke-derive 0.8.2` | `Unicode-3.0` | Unicode license: keep the notice. |
| `zerofrom 0.1.6` | `Unicode-3.0` | Unicode license: keep the notice. |
| `zerofrom-derive 0.1.6` | `Unicode-3.0` | Unicode license: keep the notice. |
| `zerotrie 0.2.4` | `Unicode-3.0` | Unicode license: keep the notice. |
| `zerovec 0.11.6` | `Unicode-3.0` | Unicode license: keep the notice. |
| `zerovec-derive 0.11.3` | `Unicode-3.0` | Unicode license: keep the notice. |

## All packages

| Package | License | Repository |
|---|---|---|
| `Inflector 0.11.4` | `BSD-2-Clause` |  |
| `adler2 2.0.1` | `0BSD OR MIT OR Apache-2.0` |  |
| `ahash 0.8.12` | `MIT OR Apache-2.0` |  |
| `aho-corasick 1.1.4` | `Unlicense OR MIT` |  |
| `allocative 0.3.6` | `Apache-2.0` |  |
| `allocative_derive 0.3.6` | `Apache-2.0` |  |
| `allocator-api2 0.2.21` | `MIT OR Apache-2.0` |  |
| `android_system_properties 0.1.5` | `MIT/Apache-2.0` |  |
| `annotate-snippets 0.9.2` | `Apache-2.0/MIT` |  |
| `anstream 0.6.21` | `MIT OR Apache-2.0` |  |
| `anstyle 1.0.13` | `MIT OR Apache-2.0` |  |
| `anstyle-parse 0.2.7` | `MIT OR Apache-2.0` |  |
| `anstyle-query 1.1.5` | `MIT OR Apache-2.0` |  |
| `anstyle-wincon 3.0.11` | `MIT OR Apache-2.0` |  |
| `anyhow 1.0.103` | `MIT OR Apache-2.0` |  |
| `arrayref 0.3.9` | `BSD-2-Clause` |  |
| `arrayvec 0.7.6` | `MIT OR Apache-2.0` |  |
| `asn1-rs 0.7.1` | `MIT OR Apache-2.0` |  |
| `asn1-rs-derive 0.6.0` | `MIT OR Apache-2.0` |  |
| `asn1-rs-impl 0.2.0` | `MIT/Apache-2.0` |  |
| `async-channel 2.5.0` | `Apache-2.0 OR MIT` |  |
| `async-trait 0.1.89` | `MIT OR Apache-2.0` |  |
| `asynk-strim 0.1.5` | `MIT OR Apache-2.0` |  |
| `atomic 0.5.3` | `Apache-2.0/MIT` |  |
| `atomic-polyfill 1.0.3` | `MIT OR Apache-2.0` |  |
| `atomic-waker 1.1.2` | `Apache-2.0 OR MIT` |  |
| `autocfg 1.5.0` | `Apache-2.0 OR MIT` |  |
| `aws-lc-rs 1.16.2` | `ISC AND (Apache-2.0 OR ISC)` |  |
| `aws-lc-sys 0.39.0` | `ISC AND (Apache-2.0 OR ISC) AND Apache-2.0 AND MIT AND BSD-3-Clause AND (Apache-2.0 OR ISC OR MIT) AND (Apache-2.0 OR ISC OR MIT-0)` |  |
| `base64 0.22.1` | `MIT OR Apache-2.0` |  |
| `beef 0.5.2` | `MIT OR Apache-2.0` |  |
| `bit-set 0.8.0` | `Apache-2.0 OR MIT` |  |
| `bit-vec 0.8.0` | `Apache-2.0 OR MIT` |  |
| `bitflags 1.3.2` | `MIT/Apache-2.0` |  |
| `bitflags 2.13.1` | `MIT OR Apache-2.0` |  |
| `blake3 1.8.2` | `CC0-1.0 OR Apache-2.0 OR Apache-2.0 WITH LLVM-exception` |  |
| `block-buffer 0.10.4` | `MIT OR Apache-2.0` |  |
| `borsh 1.6.0` | `MIT OR Apache-2.0` |  |
| `bstr 1.12.1` | `MIT OR Apache-2.0` |  |
| `bumpalo 3.19.1` | `MIT OR Apache-2.0` |  |
| `bytemuck 1.25.0` | `Zlib OR Apache-2.0 OR MIT` |  |
| `bytemuck_derive 1.10.2` | `Zlib OR Apache-2.0 OR MIT` |  |
| `byteorder 1.5.0` | `Unlicense OR MIT` |  |
| `byteorder-lite 0.1.0` | `Unlicense OR MIT` |  |
| `bytes 1.11.1` | `MIT` |  |
| `cc 1.2.55` | `MIT OR Apache-2.0` |  |
| `cfg-if 1.0.4` | `MIT OR Apache-2.0` |  |
| `cfg_aliases 0.1.1` | `MIT` |  |
| `cfg_aliases 0.2.1` | `MIT` |  |
| `chardetng 0.1.17` | `Apache-2.0 OR MIT` |  |
| `chrono 0.4.43` | `MIT OR Apache-2.0` |  |
| `clap 4.5.58` | `MIT OR Apache-2.0` |  |
| `clap_builder 4.5.58` | `MIT OR Apache-2.0` |  |
| `clap_derive 4.5.55` | `MIT OR Apache-2.0` |  |
| `clap_lex 1.0.0` | `MIT OR Apache-2.0` |  |
| `clipboard-win 5.4.1` | `BSL-1.0` |  |
| `cmake 0.1.57` | `MIT OR Apache-2.0` |  |
| `cmp_any 0.8.1` | `MIT OR Apache-2.0` |  |
| `cobs 0.3.0` | `MIT OR Apache-2.0` |  |
| `color_quant 1.1.0` | `MIT` |  |
| `colorchoice 1.0.4` | `MIT OR Apache-2.0` |  |
| `concurrent-queue 2.5.0` | `Apache-2.0 OR MIT` |  |
| `const_format 0.2.35` | `Zlib` |  |
| `const_format_proc_macros 0.2.34` | `Zlib` |  |
| `constant_time_eq 0.3.1` | `CC0-1.0 OR MIT-0 OR Apache-2.0` |  |
| `convert_case 0.6.0` | `MIT` |  |
| `cookie 0.18.1` | `MIT OR Apache-2.0` |  |
| `cookie_store 0.22.1` | `MIT OR Apache-2.0` |  |
| `core-foundation 0.10.1` | `MIT OR Apache-2.0` |  |
| `core-foundation 0.9.4` | `MIT OR Apache-2.0` |  |
| `core-foundation-sys 0.8.7` | `MIT OR Apache-2.0` |  |
| `cpufeatures 0.2.17` | `MIT OR Apache-2.0` |  |
| `crc 3.4.0` | `MIT OR Apache-2.0` |  |
| `crc-catalog 2.4.0` | `MIT OR Apache-2.0` |  |
| `crc32fast 1.5.0` | `MIT OR Apache-2.0` |  |
| `critical-section 1.2.0` | `MIT OR Apache-2.0` |  |
| `crossbeam-channel 0.5.15` | `MIT OR Apache-2.0` |  |
| `crossbeam-deque 0.8.6` | `MIT OR Apache-2.0` |  |
| `crossbeam-epoch 0.9.20` | `MIT OR Apache-2.0` |  |
| `crossbeam-utils 0.8.21` | `MIT OR Apache-2.0` |  |
| `crypto-common 0.1.7` | `MIT OR Apache-2.0` |  |
| `csv 1.4.0` | `Unlicense/MIT` |  |
| `csv-core 0.1.13` | `Unlicense/MIT` |  |
| `ctor 1.0.6` | `Apache-2.0 OR MIT` |  |
| `darling 0.21.3` | `MIT` |  |
| `darling_core 0.21.3` | `MIT` |  |
| `darling_macro 0.21.3` | `MIT` |  |
| `dashmap 6.1.0` | `MIT` |  |
| `data-encoding 2.10.0` | `MIT` |  |
| `debugserver-types 0.5.0` | `MIT` |  |
| `der-parser 10.0.0` | `MIT OR Apache-2.0` |  |
| `deranged 0.5.5` | `MIT OR Apache-2.0` |  |
| `derivative 2.2.0` | `MIT/Apache-2.0` |  |
| `derive_more 1.0.0` | `MIT` |  |
| `derive_more-impl 1.0.0` | `MIT` |  |
| `digest 0.10.7` | `MIT OR Apache-2.0` |  |
| `dirs 6.0.0` | `MIT OR Apache-2.0` |  |
| `dirs-sys 0.5.0` | `MIT OR Apache-2.0` |  |
| `display_container 0.9.0` | `MIT OR Apache-2.0` |  |
| `displaydoc 0.2.5` | `MIT OR Apache-2.0` |  |
| `document-features 0.2.12` | `MIT OR Apache-2.0` |  |
| `dunce 1.0.5` | `CC0-1.0 OR MIT-0 OR Apache-2.0` |  |
| `dupe 0.9.1` | `MIT OR Apache-2.0` |  |
| `dupe_derive 0.9.1` | `MIT OR Apache-2.0` |  |
| `dyn-clone 1.0.20` | `MIT OR Apache-2.0` |  |
| `either 1.15.0` | `MIT OR Apache-2.0` |  |
| `embedded-io 0.4.0` | `MIT OR Apache-2.0` |  |
| `embedded-io 0.6.1` | `MIT OR Apache-2.0` |  |
| `encoding_rs 0.8.35` | `(Apache-2.0 OR MIT) AND BSD-3-Clause` |  |
| `endian-type 0.1.2` | `MIT` |  |
| `endian-type 0.2.0` | `MIT` |  |
| `enum-as-inner 0.6.1` | `MIT/Apache-2.0` |  |
| `enumflags2 0.7.12` | `MIT OR Apache-2.0` |  |
| `enumflags2_derive 0.7.12` | `MIT OR Apache-2.0` |  |
| `env_filter 1.0.0` | `MIT OR Apache-2.0` |  |
| `env_logger 0.11.9` | `MIT OR Apache-2.0` |  |
| `equivalent 1.0.2` | `Apache-2.0 OR MIT` |  |
| `erased-serde 0.3.31` | `MIT OR Apache-2.0` |  |
| `erased-serde 0.4.10` | `MIT OR Apache-2.0` |  |
| `errno 0.3.14` | `MIT OR Apache-2.0` |  |
| `error-code 3.3.2` | `BSL-1.0` |  |
| `event-listener 5.4.1` | `Apache-2.0 OR MIT` |  |
| `event-listener-strategy 0.5.4` | `Apache-2.0 OR MIT` |  |
| `eventsource-stream 0.2.3` | `MIT OR Apache-2.0` |  |
| `fancy-regex 0.16.2` | `MIT` |  |
| `fastrand 2.3.0` | `Apache-2.0 OR MIT` |  |
| `fd-lock 4.0.4` | `MIT OR Apache-2.0` |  |
| `fdeflate 0.3.7` | `MIT OR Apache-2.0` |  |
| `find-msvc-tools 0.1.9` | `MIT OR Apache-2.0` |  |
| `fixed_decimal 0.7.2` | `Unicode-3.0` |  |
| `flate2 1.1.8` | `MIT OR Apache-2.0` |  |
| `fluent-uri 0.1.4` | `MIT` |  |
| `flume 0.12.0` | `Apache-2.0/MIT` |  |
| `fnv 1.0.7` | `Apache-2.0 / MIT` |  |
| `foldhash 0.1.5` | `Zlib` |  |
| `foldhash 0.2.0` | `Zlib` |  |
| `foreign-types 0.3.2` | `MIT/Apache-2.0` |  |
| `foreign-types-shared 0.1.1` | `MIT/Apache-2.0` |  |
| `form_urlencoded 1.2.2` | `MIT OR Apache-2.0` |  |
| `fs_extra 1.3.0` | `MIT` |  |
| `futures 0.3.31` | `MIT OR Apache-2.0` |  |
| `futures-channel 0.3.32` | `MIT OR Apache-2.0` |  |
| `futures-core 0.3.32` | `MIT OR Apache-2.0` |  |
| `futures-executor 0.3.32` | `MIT OR Apache-2.0` |  |
| `futures-io 0.3.32` | `MIT OR Apache-2.0` |  |
| `futures-macro 0.3.32` | `MIT OR Apache-2.0` |  |
| `futures-sink 0.3.32` | `MIT OR Apache-2.0` |  |
| `futures-task 0.3.32` | `MIT OR Apache-2.0` |  |
| `futures-util 0.3.32` | `MIT OR Apache-2.0` |  |
| `fxhash 0.2.1` | `Apache-2.0/MIT` |  |
| `generator 0.8.8` | `MIT/Apache-2.0` |  |
| `generic-array 0.14.7` | `MIT` |  |
| `getrandom 0.2.17` | `MIT OR Apache-2.0` |  |
| `getrandom 0.3.4` | `MIT OR Apache-2.0` |  |
| `getrandom 0.4.2` | `MIT OR Apache-2.0` |  |
| `gif 0.14.1` | `MIT OR Apache-2.0` |  |
| `globset 0.4.18` | `Unlicense OR MIT` |  |
| `h2 0.4.16` | `MIT` |  |
| `hash32 0.2.1` | `MIT OR Apache-2.0` |  |
| `hashbrown 0.12.3` | `MIT OR Apache-2.0` |  |
| `hashbrown 0.14.5` | `MIT OR Apache-2.0` |  |
| `hashbrown 0.15.5` | `MIT OR Apache-2.0` |  |
| `hashbrown 0.16.1` | `MIT OR Apache-2.0` |  |
| `hashbrown 0.17.1` | `MIT OR Apache-2.0` |  |
| `headers 0.4.1` | `MIT` |  |
| `headers-core 0.3.0` | `MIT` |  |
| `heapless 0.7.17` | `MIT OR Apache-2.0` |  |
| `heck 0.5.0` | `MIT OR Apache-2.0` |  |
| `hex 0.4.3` | `MIT OR Apache-2.0` |  |
| `hickory-proto 0.25.2` | `MIT OR Apache-2.0` |  |
| `hickory-resolver 0.25.2` | `MIT OR Apache-2.0` |  |
| `home 0.5.12` | `MIT OR Apache-2.0` |  |
| `http 1.4.0` | `MIT OR Apache-2.0` |  |
| `http-body 1.0.1` | `MIT` |  |
| `http-body-util 0.1.3` | `MIT` |  |
| `http-range-header 0.4.2` | `MIT` |  |
| `httparse 1.10.1` | `MIT OR Apache-2.0` |  |
| `httpdate 1.0.3` | `MIT OR Apache-2.0` |  |
| `hyper 1.8.1` | `MIT` |  |
| `hyper-rustls 0.27.7` | `Apache-2.0 OR ISC OR MIT` |  |
| `hyper-tls 0.6.0` | `MIT/Apache-2.0` |  |
| `hyper-util 0.1.20` | `MIT` |  |
| `iana-time-zone 0.1.65` | `MIT OR Apache-2.0` |  |
| `iana-time-zone-haiku 0.1.2` | `MIT OR Apache-2.0` |  |
| `icu_collections 2.2.0` | `Unicode-3.0` |  |
| `icu_decimal 2.2.0` | `Unicode-3.0` |  |
| `icu_decimal_data 2.2.0` | `Unicode-3.0` |  |
| `icu_locale 2.2.0` | `Unicode-3.0` |  |
| `icu_locale_core 2.2.0` | `Unicode-3.0` |  |
| `icu_locale_data 2.2.0` | `Unicode-3.0` |  |
| `icu_normalizer 2.2.0` | `Unicode-3.0` |  |
| `icu_normalizer_data 2.2.0` | `Unicode-3.0` |  |
| `icu_plurals 2.2.0` | `Unicode-3.0` |  |
| `icu_plurals_data 2.2.0` | `Unicode-3.0` |  |
| `icu_properties 2.2.0` | `Unicode-3.0` |  |
| `icu_properties_data 2.2.0` | `Unicode-3.0` |  |
| `icu_provider 2.2.0` | `Unicode-3.0` |  |
| `id-arena 2.3.0` | `MIT/Apache-2.0` |  |
| `ident_case 1.0.1` | `MIT/Apache-2.0` |  |
| `idna 1.1.0` | `MIT OR Apache-2.0` |  |
| `idna_adapter 1.2.1` | `Apache-2.0 OR MIT` |  |
| `image 0.25.9` | `MIT OR Apache-2.0` |  |
| `image-webp 0.2.4` | `MIT OR Apache-2.0` |  |
| `indenter 0.3.4` | `MIT OR Apache-2.0` |  |
| `indexmap 1.9.3` | `Apache-2.0 OR MIT` |  |
| `indexmap 2.14.0` | `Apache-2.0 OR MIT` |  |
| `inventory 0.3.24` | `MIT OR Apache-2.0` |  |
| `ipconfig 0.3.2` | `MIT/Apache-2.0` |  |
| `ipnet 2.11.0` | `MIT OR Apache-2.0` |  |
| `iri-string 0.7.10` | `MIT OR Apache-2.0` |  |
| `is_terminal_polyfill 1.70.2` | `MIT OR Apache-2.0` |  |
| `itertools 0.14.0` | `MIT OR Apache-2.0` |  |
| `itoa 1.0.17` | `MIT OR Apache-2.0` |  |
| `jobserver 0.1.34` | `MIT OR Apache-2.0` |  |
| `js-sys 0.3.85` | `MIT OR Apache-2.0` |  |
| `landlock 0.4.4` | `MIT OR Apache-2.0` |  |
| `lazy_static 1.5.0` | `MIT OR Apache-2.0` |  |
| `leb128fmt 0.1.0` | `MIT OR Apache-2.0` |  |
| `libc 0.2.186` | `MIT OR Apache-2.0` |  |
| `libredox 0.1.12` | `MIT` |  |
| `link-section 0.17.2` | `Apache-2.0 OR MIT` |  |
| `linktime-proc-macro 0.1.0` | `Apache-2.0 OR MIT` |  |
| `linux-raw-sys 0.12.1` | `Apache-2.0 WITH LLVM-exception OR Apache-2.0 OR MIT` |  |
| `litemap 0.8.1` | `Unicode-3.0` |  |
| `litrs 1.0.0` | `MIT OR Apache-2.0` |  |
| `lock_api 0.4.14` | `MIT OR Apache-2.0` |  |
| `lock_free_hashtable 0.1.4` | `MIT OR Apache-2.0` |  |
| `log 0.4.29` | `MIT OR Apache-2.0` |  |
| `logos 0.15.1` | `MIT OR Apache-2.0` |  |
| `logos-codegen 0.15.1` | `MIT OR Apache-2.0` |  |
| `logos-derive 0.15.1` | `MIT OR Apache-2.0` |  |
| `loom 0.7.2` | `MIT` |  |
| `lru 0.18.2` | `MIT` |  |
| `lru-slab 0.1.2` | `MIT OR Apache-2.0 OR Zlib` |  |
| `lsp-types 0.97.0` | `MIT` |  |
| `maplit 1.0.2` | `MIT/Apache-2.0` |  |
| `matchers 0.2.0` | `MIT` |  |
| `matchit 0.9.1` | `MIT AND BSD-3-Clause` |  |
| `md5 0.8.0` | `Apache-2.0/MIT` |  |
| `memchr 2.8.1` | `Unlicense OR MIT` |  |
| `memoffset 0.9.1` | `MIT` |  |
| `mime 0.3.17` | `MIT OR Apache-2.0` |  |
| `mime_guess 2.0.5` | `MIT` |  |
| `minimal-lexical 0.2.1` | `MIT/Apache-2.0` |  |
| `miniz_oxide 0.8.9` | `MIT OR Zlib OR Apache-2.0` |  |
| `mio 1.2.0` | `MIT` |  |
| `moka 0.12.13` | `(MIT OR Apache-2.0) AND Apache-2.0` |  |
| `moxcms 0.7.11` | `BSD-3-Clause OR Apache-2.0` |  |
| `multimap 0.10.1` | `MIT OR Apache-2.0` |  |
| `native-tls 0.2.14` | `MIT OR Apache-2.0` |  |
| `nibble_vec 0.1.0` | `MIT` |  |
| `nix 0.28.0` | `MIT` |  |
| `nom 7.1.3` | `MIT` |  |
| `nom 8.0.0` | `MIT` |  |
| `nu-ansi-term 0.50.3` | `MIT` |  |
| `num-bigint 0.4.6` | `MIT OR Apache-2.0` |  |
| `num-conv 0.2.0` | `MIT OR Apache-2.0` |  |
| `num-integer 0.1.46` | `MIT OR Apache-2.0` |  |
| `num-traits 0.2.19` | `MIT OR Apache-2.0` |  |
| `oid-registry 0.8.1` | `MIT OR Apache-2.0` |  |
| `once_cell 1.21.4` | `MIT OR Apache-2.0` |  |
| `once_cell_polyfill 1.70.2` | `MIT OR Apache-2.0` |  |
| `openssl 0.10.75` | `Apache-2.0` |  |
| `openssl-macros 0.1.1` | `MIT/Apache-2.0` |  |
| `openssl-probe 0.1.6` | `MIT/Apache-2.0` |  |
| `openssl-probe 0.2.1` | `MIT OR Apache-2.0` |  |
| `openssl-sys 0.9.111` | `MIT` |  |
| `opentelemetry 0.31.0` | `Apache-2.0` |  |
| `option-ext 0.2.0` | `MPL-2.0` |  |
| `pagable 0.4.1` | `Apache-2.0` |  |
| `pagable_derive 0.4.1` | `Apache-2.0` |  |
| `parking 2.2.1` | `Apache-2.0 OR MIT` |  |
| `parking_lot 0.12.5` | `MIT OR Apache-2.0` |  |
| `parking_lot_core 0.9.12` | `MIT OR Apache-2.0` |  |
| `paste 1.0.15` | `MIT OR Apache-2.0` |  |
| `pem 3.0.6` | `MIT` |  |
| `percent-encoding 2.3.2` | `MIT OR Apache-2.0` |  |
| `pin-project-lite 0.2.16` | `Apache-2.0 OR MIT` |  |
| `pin-utils 0.1.0` | `MIT OR Apache-2.0` |  |
| `pkg-config 0.3.32` | `MIT OR Apache-2.0` |  |
| `png 0.18.0` | `MIT OR Apache-2.0` |  |
| `portable-atomic 1.13.1` | `Apache-2.0 OR MIT` |  |
| `postcard 1.1.3` | `MIT OR Apache-2.0` |  |
| `potential_utf 0.1.4` | `Unicode-3.0` |  |
| `powerfmt 0.2.0` | `MIT OR Apache-2.0` |  |
| `ppv-lite86 0.2.21` | `MIT OR Apache-2.0` |  |
| `prettyplease 0.2.37` | `MIT OR Apache-2.0` |  |
| `proc-macro-crate 3.4.0` | `MIT OR Apache-2.0` |  |
| `proc-macro2 1.0.106` | `MIT OR Apache-2.0` |  |
| `psl 2.1.184` | `MIT/Apache-2.0` |  |
| `psl-types 2.0.11` | `MIT/Apache-2.0` |  |
| `publicsuffix 2.3.0` | `MIT/Apache-2.0` |  |
| `pxfm 0.1.27` | `BSD-3-Clause OR Apache-2.0` |  |
| `quick-error 2.0.1` | `MIT/Apache-2.0` |  |
| `quick-xml 0.41.0` | `MIT` |  |
| `quickcheck 1.1.0` | `Unlicense OR MIT` |  |
| `quinn 0.11.9` | `MIT OR Apache-2.0` |  |
| `quinn-proto 0.11.14` | `MIT OR Apache-2.0` |  |
| `quinn-udp 0.5.14` | `MIT OR Apache-2.0` |  |
| `quote 1.0.45` | `MIT OR Apache-2.0` |  |
| `r-efi 5.3.0` | `MIT OR Apache-2.0 OR LGPL-2.1-or-later` |  |
| `r-efi 6.0.0` | `MIT OR Apache-2.0 OR LGPL-2.1-or-later` |  |
| `radix_trie 0.2.1` | `MIT` |  |
| `radix_trie 0.3.0` | `MIT` |  |
| `rama-core 0.3.0-alpha.4` | `MIT OR Apache-2.0` |  |
| `rama-dns 0.3.0-alpha.4` | `MIT OR Apache-2.0` |  |
| `rama-error 0.3.0-alpha.4` | `MIT OR Apache-2.0` |  |
| `rama-http 0.3.0-alpha.4` | `MIT OR Apache-2.0` |  |
| `rama-http-backend 0.3.0-alpha.4` | `MIT OR Apache-2.0` |  |
| `rama-http-core 0.3.0-alpha.4` | `MIT OR Apache-2.0` |  |
| `rama-http-headers 0.3.0-alpha.4` | `MIT OR Apache-2.0` |  |
| `rama-http-types 0.3.0-alpha.4` | `MIT OR Apache-2.0` |  |
| `rama-macros 0.3.0-alpha.4` | `MIT OR Apache-2.0` |  |
| `rama-net 0.3.0-alpha.4` | `MIT OR Apache-2.0` |  |
| `rama-socks5 0.3.0-alpha.4` | `MIT OR Apache-2.0` |  |
| `rama-tcp 0.3.0-alpha.4` | `MIT OR Apache-2.0` |  |
| `rama-tls-rustls 0.3.0-alpha.4` | `MIT OR Apache-2.0` |  |
| `rama-udp 0.3.0-alpha.4` | `MIT OR Apache-2.0` |  |
| `rama-unix 0.3.0-alpha.4` | `MIT OR Apache-2.0` |  |
| `rama-utils 0.3.0-alpha.4` | `MIT OR Apache-2.0` |  |
| `rand 0.10.1` | `MIT OR Apache-2.0` |  |
| `rand 0.9.3` | `MIT OR Apache-2.0` |  |
| `rand_chacha 0.9.0` | `MIT OR Apache-2.0` |  |
| `rand_core 0.10.1` | `MIT OR Apache-2.0` |  |
| `rand_core 0.9.5` | `MIT OR Apache-2.0` |  |
| `rayon-core 1.13.0` | `MIT OR Apache-2.0` |  |
| `rcgen 0.14.7` | `MIT OR Apache-2.0` |  |
| `redox_syscall 0.5.18` | `MIT` |  |
| `redox_users 0.5.2` | `MIT` |  |
| `ref-cast 1.0.25` | `MIT OR Apache-2.0` |  |
| `ref-cast-impl 1.0.25` | `MIT OR Apache-2.0` |  |
| `regex 1.12.3` | `MIT OR Apache-2.0` |  |
| `regex-automata 0.4.13` | `MIT OR Apache-2.0` |  |
| `regex-lite 0.1.8` | `MIT OR Apache-2.0` |  |
| `regex-syntax 0.8.8` | `MIT OR Apache-2.0` |  |
| `reqwest 0.12.28` | `MIT OR Apache-2.0` |  |
| `resolv-conf 0.7.6` | `MIT OR Apache-2.0` |  |
| `ring 0.17.14` | `Apache-2.0 AND ISC` |  |
| `rustc-hash 2.1.1` | `Apache-2.0 OR MIT` |  |
| `rustc_version 0.4.1` | `MIT OR Apache-2.0` |  |
| `rusticata-macros 4.1.0` | `MIT/Apache-2.0` |  |
| `rustix 1.1.4` | `Apache-2.0 WITH LLVM-exception OR Apache-2.0 OR MIT` |  |
| `rustls 0.23.36` | `Apache-2.0 OR ISC OR MIT` |  |
| `rustls-native-certs 0.8.3` | `Apache-2.0 OR ISC OR MIT` |  |
| `rustls-pki-types 1.14.0` | `MIT OR Apache-2.0` |  |
| `rustls-webpki 0.103.13` | `ISC` |  |
| `rustversion 1.0.22` | `MIT OR Apache-2.0` |  |
| `rustyline 14.0.0` | `MIT` |  |
| `ryu 1.0.22` | `Apache-2.0 OR BSL-1.0` |  |
| `schannel 0.1.28` | `MIT` |  |
| `schemafy 0.5.2` | `MIT` |  |
| `schemafy_core 0.5.2` | `MIT` |  |
| `schemafy_lib 0.5.2` | `MIT` |  |
| `schemars 0.8.22` | `MIT` |  |
| `schemars 0.9.0` | `MIT` |  |
| `schemars 1.2.1` | `MIT` |  |
| `schemars_derive 0.8.22` | `MIT` |  |
| `scoped-tls 1.0.1` | `MIT/Apache-2.0` |  |
| `scopeguard 1.2.0` | `MIT OR Apache-2.0` |  |
| `seccompiler 0.5.0` | `Apache-2.0 OR BSD-3-Clause` |  |
| `security-framework 2.11.1` | `MIT OR Apache-2.0` |  |
| `security-framework 3.5.1` | `MIT OR Apache-2.0` |  |
| `security-framework-sys 2.15.0` | `MIT OR Apache-2.0` |  |
| `semver 1.0.27` | `MIT OR Apache-2.0` |  |
| `sequence_trie 0.3.6` | `MIT/Apache-2.0` |  |
| `serde 1.0.228` | `MIT OR Apache-2.0` |  |
| `serde_core 1.0.228` | `MIT OR Apache-2.0` |  |
| `serde_derive 1.0.228` | `MIT OR Apache-2.0` |  |
| `serde_derive_internals 0.29.1` | `MIT OR Apache-2.0` |  |
| `serde_html_form 0.3.2` | `MIT` |  |
| `serde_json 1.0.149` | `MIT OR Apache-2.0` |  |
| `serde_repr 0.1.20` | `MIT OR Apache-2.0` |  |
| `serde_urlencoded 0.7.1` | `MIT/Apache-2.0` |  |
| `serde_with 3.17.0` | `MIT OR Apache-2.0` |  |
| `serde_with_macros 3.17.0` | `MIT OR Apache-2.0` |  |
| `sha1 0.10.6` | `MIT OR Apache-2.0` |  |
| `sha2 0.10.9` | `MIT OR Apache-2.0` |  |
| `sharded-slab 0.1.7` | `MIT` |  |
| `shlex 1.3.0` | `MIT OR Apache-2.0` |  |
| `signal-hook-registry 1.4.8` | `MIT OR Apache-2.0` |  |
| `simd-adler32 0.3.8` | `MIT` |  |
| `slab 0.4.12` | `MIT` |  |
| `smallvec 1.15.1` | `MIT OR Apache-2.0` |  |
| `smol_str 0.3.5` | `MIT OR Apache-2.0` |  |
| `socket2 0.5.10` | `MIT OR Apache-2.0` |  |
| `socket2 0.6.3` | `MIT OR Apache-2.0` |  |
| `sorted_vector_map 0.2.1` | `MIT OR Apache-2.0` |  |
| `spin 0.9.8` | `MIT` |  |
| `stable_deref_trait 1.2.1` | `MIT OR Apache-2.0` |  |
| `starlark 0.14.2` | `Apache-2.0` |  |
| `starlark_derive 0.14.2` | `Apache-2.0` |  |
| `starlark_map 0.14.2` | `Apache-2.0` |  |
| `starlark_syntax 0.14.2` | `Apache-2.0` |  |
| `static_assertions 1.1.0` | `MIT OR Apache-2.0` |  |
| `static_interner 0.1.2` | `MIT OR Apache-2.0` |  |
| `strong_hash 0.1.0` | `MIT OR Apache-2.0` |  |
| `strong_hash_derive 0.1.0` | `MIT OR Apache-2.0` |  |
| `strsim 0.10.0` | `MIT` |  |
| `strsim 0.11.1` | `MIT` |  |
| `strum 0.27.2` | `MIT` |  |
| `strum_macros 0.28.0` | `MIT` |  |
| `subtle 2.6.1` | `BSD-3-Clause` |  |
| `syn 1.0.109` | `MIT OR Apache-2.0` |  |
| `syn 2.0.117` | `MIT OR Apache-2.0` |  |
| `sync_wrapper 1.0.2` | `Apache-2.0` |  |
| `synstructure 0.13.2` | `MIT` |  |
| `sys-locale 0.3.2` | `MIT OR Apache-2.0` |  |
| `system-configuration 0.7.0` | `MIT OR Apache-2.0` |  |
| `system-configuration-sys 0.6.0` | `MIT OR Apache-2.0` |  |
| `tagptr 0.2.0` | `MIT/Apache-2.0` |  |
| `take_mut 0.2.2` | `MIT` |  |
| `tempfile 3.27.0` | `MIT OR Apache-2.0` |  |
| `termcolor 1.4.1` | `Unlicense OR MIT` |  |
| `textwrap 0.11.0` | `MIT` |  |
| `thiserror 2.0.18` | `MIT OR Apache-2.0` |  |
| `thiserror-impl 2.0.18` | `MIT OR Apache-2.0` |  |
| `thread_local 1.1.9` | `MIT OR Apache-2.0` |  |
| `time 0.3.47` | `MIT OR Apache-2.0` |  |
| `time-core 0.1.8` | `MIT OR Apache-2.0` |  |
| `time-macros 0.2.27` | `MIT OR Apache-2.0` |  |
| `tinystr 0.8.3` | `Unicode-3.0` |  |
| `tinyvec 1.10.0` | `Zlib OR Apache-2.0 OR MIT` |  |
| `tinyvec_macros 0.1.1` | `MIT OR Apache-2.0 OR Zlib` |  |
| `tokio 1.52.3` | `MIT` |  |
| `tokio-graceful 0.2.2` | `MIT OR Apache-2.0` |  |
| `tokio-macros 2.7.0` | `MIT` |  |
| `tokio-native-tls 0.3.1` | `MIT` |  |
| `tokio-rustls 0.26.4` | `MIT OR Apache-2.0` |  |
| `tokio-stream 0.1.18` | `MIT` |  |
| `tokio-test 0.4.5` | `MIT` |  |
| `tokio-util 0.7.18` | `MIT` |  |
| `toml_datetime 0.7.5+spec-1.1.0` | `MIT OR Apache-2.0` |  |
| `toml_edit 0.23.10+spec-1.0.0` | `MIT OR Apache-2.0` |  |
| `toml_parser 1.0.6+spec-1.1.0` | `MIT OR Apache-2.0` |  |
| `tower 0.5.3` | `MIT` |  |
| `tower-http 0.6.8` | `MIT` |  |
| `tower-layer 0.3.3` | `MIT` |  |
| `tower-service 0.3.3` | `MIT` |  |
| `tracing 0.1.44` | `MIT` |  |
| `tracing-attributes 0.1.31` | `MIT` |  |
| `tracing-core 0.1.36` | `MIT` |  |
| `tracing-log 0.2.0` | `MIT` |  |
| `tracing-opentelemetry 0.32.1` | `MIT` |  |
| `tracing-subscriber 0.3.22` | `MIT` |  |
| `triomphe 0.1.15` | `MIT OR Apache-2.0` |  |
| `try-lock 0.2.5` | `MIT` |  |
| `ts-rs 11.1.0` | `MIT` |  |
| `ts-rs-macros 11.1.0` | `MIT` |  |
| `typeid 1.0.3` | `MIT OR Apache-2.0` |  |
| `typenum 1.20.0` | `MIT OR Apache-2.0` |  |
| `unicase 2.9.0` | `MIT OR Apache-2.0` |  |
| `unicode-ident 1.0.22` | `(MIT OR Apache-2.0) AND Unicode-3.0` |  |
| `unicode-segmentation 1.12.0` | `MIT OR Apache-2.0` |  |
| `unicode-width 0.1.14` | `MIT OR Apache-2.0` |  |
| `unicode-xid 0.2.6` | `MIT OR Apache-2.0` |  |
| `untrusted 0.7.1` | `ISC` |  |
| `untrusted 0.9.0` | `ISC` |  |
| `url 2.5.8` | `MIT OR Apache-2.0` |  |
| `urlencoding 2.1.3` | `MIT` |  |
| `utf-8 0.7.6` | `MIT OR Apache-2.0` |  |
| `utf8_iter 1.0.4` | `Apache-2.0 OR MIT` |  |
| `utf8parse 0.2.2` | `Apache-2.0 OR MIT` |  |
| `uuid 1.20.0` | `Apache-2.0 OR MIT` |  |
| `valuable 0.1.1` | `MIT` |  |
| `vcpkg 0.2.15` | `MIT/Apache-2.0` |  |
| `version_check 0.9.5` | `MIT/Apache-2.0` |  |
| `want 0.3.1` | `MIT` |  |
| `wasi 0.11.1+wasi-snapshot-preview1` | `Apache-2.0 WITH LLVM-exception OR Apache-2.0 OR MIT` |  |
| `wasip2 1.0.2+wasi-0.2.9` | `Apache-2.0 WITH LLVM-exception OR Apache-2.0 OR MIT` |  |
| `wasip3 0.4.0+wasi-0.3.0-rc-2026-01-06` | `Apache-2.0 WITH LLVM-exception OR Apache-2.0 OR MIT` |  |
| `wasm-bindgen 0.2.108` | `MIT OR Apache-2.0` |  |
| `wasm-bindgen-futures 0.4.58` | `MIT OR Apache-2.0` |  |
| `wasm-bindgen-macro 0.2.108` | `MIT OR Apache-2.0` |  |
| `wasm-bindgen-macro-support 0.2.108` | `MIT OR Apache-2.0` |  |
| `wasm-bindgen-shared 0.2.108` | `MIT OR Apache-2.0` |  |
| `wasm-encoder 0.244.0` | `Apache-2.0 WITH LLVM-exception OR Apache-2.0 OR MIT` |  |
| `wasm-metadata 0.244.0` | `Apache-2.0 WITH LLVM-exception OR Apache-2.0 OR MIT` |  |
| `wasm-streams 0.4.2` | `MIT OR Apache-2.0` |  |
| `wasmparser 0.244.0` | `Apache-2.0 WITH LLVM-exception OR Apache-2.0 OR MIT` |  |
| `web-sys 0.3.85` | `MIT OR Apache-2.0` |  |
| `web-time 1.1.0` | `MIT OR Apache-2.0` |  |
| `webpki-roots 1.0.5` | `CDLA-Permissive-2.0` |  |
| `weezl 0.1.12` | `MIT OR Apache-2.0` |  |
| `widestring 1.2.1` | `MIT OR Apache-2.0` |  |
| `wildcard 0.3.0` | `Apache-2.0` |  |
| `wildmatch 2.6.1` | `MIT` |  |
| `winapi-util 0.1.11` | `Unlicense OR MIT` |  |
| `windows-core 0.62.2` | `MIT OR Apache-2.0` |  |
| `windows-implement 0.60.2` | `MIT OR Apache-2.0` |  |
| `windows-interface 0.59.3` | `MIT OR Apache-2.0` |  |
| `windows-link 0.2.1` | `MIT OR Apache-2.0` |  |
| `windows-registry 0.6.1` | `MIT OR Apache-2.0` |  |
| `windows-result 0.4.1` | `MIT OR Apache-2.0` |  |
| `windows-strings 0.5.1` | `MIT OR Apache-2.0` |  |
| `windows-sys 0.48.0` | `MIT OR Apache-2.0` |  |
| `windows-sys 0.52.0` | `MIT OR Apache-2.0` |  |
| `windows-sys 0.59.0` | `MIT OR Apache-2.0` |  |
| `windows-sys 0.60.2` | `MIT OR Apache-2.0` |  |
| `windows-sys 0.61.2` | `MIT OR Apache-2.0` |  |
| `windows-targets 0.48.5` | `MIT OR Apache-2.0` |  |
| `windows-targets 0.52.6` | `MIT OR Apache-2.0` |  |
| `windows-targets 0.53.5` | `MIT OR Apache-2.0` |  |
| `windows_aarch64_gnullvm 0.48.5` | `MIT OR Apache-2.0` |  |
| `windows_aarch64_gnullvm 0.52.6` | `MIT OR Apache-2.0` |  |
| `windows_aarch64_gnullvm 0.53.1` | `MIT OR Apache-2.0` |  |
| `windows_aarch64_msvc 0.48.5` | `MIT OR Apache-2.0` |  |
| `windows_aarch64_msvc 0.52.6` | `MIT OR Apache-2.0` |  |
| `windows_aarch64_msvc 0.53.1` | `MIT OR Apache-2.0` |  |
| `windows_i686_gnu 0.48.5` | `MIT OR Apache-2.0` |  |
| `windows_i686_gnu 0.52.6` | `MIT OR Apache-2.0` |  |
| `windows_i686_gnu 0.53.1` | `MIT OR Apache-2.0` |  |
| `windows_i686_gnullvm 0.52.6` | `MIT OR Apache-2.0` |  |
| `windows_i686_gnullvm 0.53.1` | `MIT OR Apache-2.0` |  |
| `windows_i686_msvc 0.48.5` | `MIT OR Apache-2.0` |  |
| `windows_i686_msvc 0.52.6` | `MIT OR Apache-2.0` |  |
| `windows_i686_msvc 0.53.1` | `MIT OR Apache-2.0` |  |
| `windows_x86_64_gnu 0.48.5` | `MIT OR Apache-2.0` |  |
| `windows_x86_64_gnu 0.52.6` | `MIT OR Apache-2.0` |  |
| `windows_x86_64_gnu 0.53.1` | `MIT OR Apache-2.0` |  |
| `windows_x86_64_gnullvm 0.48.5` | `MIT OR Apache-2.0` |  |
| `windows_x86_64_gnullvm 0.52.6` | `MIT OR Apache-2.0` |  |
| `windows_x86_64_gnullvm 0.53.1` | `MIT OR Apache-2.0` |  |
| `windows_x86_64_msvc 0.48.5` | `MIT OR Apache-2.0` |  |
| `windows_x86_64_msvc 0.52.6` | `MIT OR Apache-2.0` |  |
| `windows_x86_64_msvc 0.53.1` | `MIT OR Apache-2.0` |  |
| `winnow 0.7.14` | `MIT` |  |
| `winreg 0.50.0` | `MIT` |  |
| `wit-bindgen 0.51.0` | `Apache-2.0 WITH LLVM-exception OR Apache-2.0 OR MIT` |  |
| `wit-bindgen-core 0.51.0` | `Apache-2.0 WITH LLVM-exception OR Apache-2.0 OR MIT` |  |
| `wit-bindgen-rust 0.51.0` | `Apache-2.0 WITH LLVM-exception OR Apache-2.0 OR MIT` |  |
| `wit-bindgen-rust-macro 0.51.0` | `Apache-2.0 WITH LLVM-exception OR Apache-2.0 OR MIT` |  |
| `wit-component 0.244.0` | `Apache-2.0 WITH LLVM-exception OR Apache-2.0 OR MIT` |  |
| `wit-parser 0.244.0` | `Apache-2.0 WITH LLVM-exception OR Apache-2.0 OR MIT` |  |
| `writeable 0.6.2` | `Unicode-3.0` |  |
| `x509-parser 0.18.1` | `MIT OR Apache-2.0` |  |
| `yasna 0.5.2` | `MIT OR Apache-2.0` |  |
| `yoke 0.8.2` | `Unicode-3.0` |  |
| `yoke-derive 0.8.2` | `Unicode-3.0` |  |
| `zerocopy 0.8.37` | `BSD-2-Clause OR Apache-2.0 OR MIT` |  |
| `zerocopy-derive 0.8.37` | `BSD-2-Clause OR Apache-2.0 OR MIT` |  |
| `zerofrom 0.1.6` | `Unicode-3.0` |  |
| `zerofrom-derive 0.1.6` | `Unicode-3.0` |  |
| `zeroize 1.8.2` | `Apache-2.0 OR MIT` |  |
| `zerotrie 0.2.4` | `Unicode-3.0` |  |
| `zerovec 0.11.6` | `Unicode-3.0` |  |
| `zerovec-derive 0.11.3` | `Unicode-3.0` |  |
| `zlib-rs 0.5.5` | `Zlib` |  |
| `zmij 1.0.19` | `MIT` |  |
| `zstd 0.13.3` | `MIT` |  |
| `zstd-safe 7.2.4` | `MIT OR Apache-2.0` |  |
| `zstd-sys 2.0.16+zstd.1.5.7` | `MIT/Apache-2.0` |  |
| `zune-core 0.5.1` | `MIT OR Apache-2.0 OR Zlib` |  |
| `zune-jpeg 0.5.12` | `MIT OR Apache-2.0 OR Zlib` |  |

## Path and git packages

| Package | Source |
|---|---|
| `codex-api 0.149.0` | `path` |
| `codex-async-utils 0.149.0` | `path` |
| `codex-client 0.149.0` | `path` |
| `codex-execpolicy 0.149.0` | `path` |
| `codex-extension-items 0.149.0` | `path` |
| `codex-http-client 0.149.0` | `path` |
| `codex-network-proxy 0.149.0` | `path` |
| `codex-protocol 0.149.0` | `path` |
| `codex-utils-absolute-path 0.149.0` | `path` |
| `codex-utils-cache 0.149.0` | `path` |
| `codex-utils-home-dir 0.149.0` | `path` |
| `codex-utils-image 0.149.0` | `path` |
| `codex-utils-path-uri 0.149.0` | `path` |
| `codex-utils-rustls-provider 0.149.0` | `path` |
| `codex-utils-string 0.149.0` | `path` |
| `codex-websocket-client 0.149.0` | `path` |
| `glassifai-codex-bridge 0.1.0` | `path` |
| `tokio-tungstenite 0.28.0` | `git+https://github.com/openai-oss-forks/tokio-tungstenite?rev=0e5b2d73aa18dd9f0a50ee9ff199d5aef7594186#0e5b2d73aa18dd9f0a50ee9ff199d5aef7594186` |
| `tungstenite 0.27.0` | `git+https://github.com/openai-oss-forks/tungstenite-rs?rev=4fffad30fe373adbdcffab9545e9e9bf4f2fc19f#4fffad30fe373adbdcffab9545e9e9bf4f2fc19f` |
