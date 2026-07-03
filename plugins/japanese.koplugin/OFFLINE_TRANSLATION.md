# Offline JA→EN translation

`localtranslator.lua` translates sentences through a **local LLM server**
instead of Google: any OpenAI-compatible `/v1/chat/completions` endpoint
works; the intended engine is **llama.cpp's `llama-server` running LiquidAI's
LFM2-350M-ENJP-MT** — a 350M-parameter model tuned exclusively for
Japanese↔English translation (Q4_K_M GGUF ≈ 230 MB, LFM Open License v1.0,
redistributable). When *Japanese → Local translation server* is enabled,
every sentence translation (sentence reader popup) tries this server first
and falls back to Google.

## Why this engine (evaluated mid-2026)

| Option | ja→en quality | Feasibility on an e-reader | Verdict |
|---|---|---|---|
| **LFM2-350M-ENJP-MT** (llama.cpp) | LLM-class register — what literary text needs; JA↔EN-specialized | 230–380 MB, llama.cpp runs everywhere, HTTP server built in | **chosen** |
| Bergamot / Mozilla `jaen` (Marian) | FLORES BLEU 25.4–25.9 / COMET 0.863 — best *classic* open MT, but stiff on fiction | 44–60 MB, proven on Android arm64 (Firefox, F-Droid offline-translator) | fallback |
| NLLB-600M ONNX (RTranslator recipe) | BLEU 23.0 — below Bergamot; weights CC-BY-**NC** | ~1 GB disk, ~1.3 GB RAM — heavy for 4 GB devices | no |
| Argos Translate (CTranslate2) | BLEU 16.3 — worst measured; CTranslate2 has no Android build | — | no |
| Sugoi v4 (fairseq/CT2) | Best classic MT *for fiction* (VNTL 60.9 % vs Google 53.9 %) | JParaCrawl license is research-only, non-redistributable | no (user-supplied PC server at most) |
| Google ML Kit | Offline packs = Google's weakest tier, "casual translations" | Requires Google Play services; proprietary | no |

Context: on visual-novel/literary text even Google's *online* translator only
reaches ~54 % on the VNTL benchmark — classic sentence-level MT plateaus
there, which is why the LLM-based specialist model is worth its size.

## Using it today (PC on the LAN)

```sh
tools/lfm2-translate-serve.sh     # downloads the 230 MB GGUF once, serves :8087
```

Needs `llama-server` (llama.cpp) on PATH. Then, on the device:
*Japanese → Local translation server → Server* = `http://<PC IP>:8087`,
enable *Use the local translator*, and run *Test translation*. The desktop
emulator works with the default `http://127.0.0.1:8087`.

## Fully on-device: TranslatorForAndroid

`TranslatorForAndroid/server-app` (same pattern as VoiceVoxForAndroid) is a
companion APK whose foreground service execs an arm64 build of `llama-server`
(shipped as `libllamaserver.so`) on `127.0.0.1:8087` with the GGUF bundled in
the APK. Build with `./build-native.sh && ./fetch-artifacts.sh && ./build.sh`
(see its README). The KOReader side only ever sees the HTTP endpoint, so the
default URL works out of the box with the app installed. Desktop smoke test
(2026-07-03, llama.cpp b9867, x64): natural literary translations at
0.4–0.8 s/sentence; expect a handful of seconds per sentence on e-reader
CPUs — hidden by the sentence reader's 2-ahead background prefetch.

If LFM2's prose quality disappoints on real novels, the drop-in fallback is a
Bergamot companion server with Mozilla's `jaen` base model (60 MB, MPL-2.0,
proven on Android) — same HTTP-behind-localhost shape, different engine.
