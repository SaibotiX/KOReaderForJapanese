# JA Translator Server (Android)

Self-contained Android app that serves **offline Japanese→English
translation** on `127.0.0.1:8087` for KOReader's japanese.koplugin
(*Japanese → Local translation server*). It runs llama.cpp's `llama-server`
(cross-compiled for arm64, shipped as `libllamaserver.so` and exec'd from the
APK's native lib dir — the same trick KOReader uses for `libsdcv.so`) with
LiquidAI's **LFM2-350M-ENJP-MT** bundled in the APK (~230 MB GGUF, extracted
to the app's files dir on first start).

Because `llama-server` already speaks the OpenAI-compatible HTTP API, the app
itself is tiny: a foreground service that extracts the model, execs the
binary, health-checks it, restarts it if it dies, plus a one-screen activity
(start/stop, boot autostart, battery-optimization exemption — Boox kills
background apps eagerly).

## Build

```sh
./build-native.sh      # cross-compile llama-server (needs cmake — use the
                       # KOReader build container if the host has none:
                       # docker exec <ctr> bash -c 'cd /home/ko/koreader/TranslatorForAndroid/server-app && ./build-native.sh'
./fetch-artifacts.sh   # stage the GGUF (reuses ~/.cache/lfm2-translate)
./build.sh             # assembleRelease → app/build/outputs/apk/release/
```

The SDK is taken from `<repo>/base/toolchain/android-sdk-linux`, the NDK from
`<repo>/base/toolchain/android-ndk-r23c`; a dev keystore is committed under
`signing/` so rebuilds upgrade in place on-device.

Docker Desktop caveat: its VM file share can serve *stale* content for files
edited in place on the host (new files propagate fine). After editing a build
script, either restart the container or copy the script to a new name before
running it inside the container — and verify with
`docker exec <ctr> grep <your change> <file>`.

`build-native.sh` pins a llama.cpp release tag and targets plain **armv8-a**
on purpose: dotprod/i8mm-optimized builds SIGILL on the A73/A53-class cores
common in e-readers. If your device is newer, rebuild with e.g.
`-DGGML_CPU_ARM_ARCH=armv8.2-a+dotprod` for a solid speedup.

It also passes `-DCMAKE_C_FLAGS_RELEASE`/`-DCMAKE_CXX_FLAGS_RELEASE="-O3"`
**explicitly**: the NDK's legacy `android.toolchain.cmake` replaces CMake's
Release defaults (`-O3 -DNDEBUG`) with just `-DNDEBUG`, so without this ggml
compiles at `-O0` — inference runs ~15x slower and a one-sentence
translation takes minutes instead of seconds (shipped as v0.1.0; fixed in
v0.1.1).

## Performance / quality knobs

There is no gradual quality-vs-speed dial in LLM inference — a generation
either runs or it doesn't. The levers that do exist here:

- **Quantization** (build-time): the bundled GGUF is Q4_K_M. On these
  NEON-only cores a Q4_0 swap buys almost nothing: llama.cpp's fast
  "repacked" Q4_0 kernels require dotprod, which A73/A53 lack — so Q4_K_M's
  better quality is free. On a dotprod-capable device, rebuild with the arch
  flag above *and* consider Q4_0 for the repack path.
- **`max_tokens`** (KOReader side, `localtranslator.lua`): caps runaway
  generations; normal sentences stop at EOS well before it.
- **Threads**: already pinned to the big-core cluster (see below).

The service launches the engine with `-t <number of big cores>` (cores whose
`cpuinfo_max_freq` equals the fastest core's). llama.cpp splits each matmul
evenly across its threads and synchronizes per op, so on big.LITTLE SoCs
running on all cores makes every token wait for the slowest little core; the
big cluster alone is noticeably faster. Uniform-core devices fall back to
llama-server's own default.

## Use

1. Install the APK, open it, *Start server* (first start copies the model —
   takes a moment), and *Disable battery optimization*.
2. In KOReader: *Japanese → Local translation server* — the default URL
   `http://127.0.0.1:8087` already matches; enable *Use the local
   translator* and run *Test translation*.
3. Sentence-reader translations now work fully offline; Google is only used
   as a fallback if this server is unreachable.

Licenses: llama.cpp MIT; LFM2-350M-ENJP-MT under the LFM Open License v1.0
(redistribution permitted). See `plugins/japanese.koplugin/OFFLINE_TRANSLATION.md`
for why this engine was chosen over Bergamot / Argos / NLLB / ML Kit.
