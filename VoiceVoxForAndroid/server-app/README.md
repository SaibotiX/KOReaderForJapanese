# VOICEVOX Server for Android (e-ink companion app)

A self-contained Android APK that runs the VOICEVOX engine **on the device
itself**, so KOReader's `furigana.koplugin` word/selection audio works fully
offline — no laptop, no Wi-Fi.

It wraps the official [voicevox_core](https://github.com/VOICEVOX/voicevox_core)
0.16.4 Android library (Rust core via the Java API AAR, CPU inference through
VOICEVOX's ONNX Runtime build) behind a tiny HTTP server that speaks the
VOICEVOX-ENGINE REST dialect on port **50021**:

| route | purpose |
|---|---|
| `POST /audio_query?speaker=N&text=…` | synthesis parameters (JSON) |
| `POST /synthesis?speaker=N` (JSON body) | WAV bytes |
| `GET /speakers` | loaded voices + style ids |
| `GET /version` | core version |
| `GET /` | human-readable status page |

That is exactly the two-step flow `plugins/furigana.koplugin/voicevox.lua`
performs, and the plugin's default server URL is already
`http://127.0.0.1:50021` — so on-device, **no KOReader configuration is
needed** (if you previously set the URL to your PC, point it back to
`http://127.0.0.1:50021` under Furigana → Word audio → Server).

Bundled voices (from `0.vvm`): 四国めたん (styles 2/0/6/4), ずんだもん
(3/1/7/5 — style 3 is the plugin default), 春日部つむぎ (8), 雨晴はう (10).
All other VOICEVOX voices can be added without rebuilding — see
[SPEAKERS.md](SPEAKERS.md) for the full id list. Models are scanned at start
but **loaded into RAM lazily** on first use (at most 2 stay resident, LRU),
so having all ~25 model files on the device is fine; switching to a voice
whose model isn't resident just costs a few extra seconds once.

## Build

Everything is fetched/staged by script; the Android SDK already lives in this
repo at `base/toolchain/android-sdk-linux` (referenced via `local.properties`).

```sh
./fetch-artifacts.sh        # downloads + stages AAR, ONNX Runtime, dict, 0.vvm
./build.sh                  # regenerates local.properties, runs gradle assembleRelease
# → app/build/outputs/apk/release/app-release.apk  (~100 MB)
```

`build.sh` works both on the host and inside the KOReader build container
(repo mounted at `/home/ko/koreader`): it derives `sdk.dir` from its own
location and prefers JDK 17 (AGP 7.4 needs JDK 11–19).

The release build is signed with the dev keystore at `signing/voicevox.keystore`
(checked in next to the project, passwords in `app/build.gradle`), so APKs from
any build environment — host or container — upgrade each other in place.
Uninstall first if the device ever had a differently-signed build.

### Desktop smoke test (no device needed)

```sh
desktop-test/run.sh
```

Compiles the same `CoreHolder` + `EngineHttpServer` sources against the
desktop voicevox_core jar, starts the server on :50121, and replays the exact
KOReader client flow (audio_query → synthesis), validating the WAV.

## Install & first run

```sh
adb install -r app/build/outputs/apk/release/app-release.apk
```

1. Open **VOICEVOX Server**, tap **Start server**. First start extracts the
   dictionary + voice model (~160 MB) and loads the engine; later starts are
   much faster. The notification shows progress and then
   "running on http://127.0.0.1:50021".
2. Tap **Disable battery optimization…** and allow it — Boox devices kill
   background apps aggressively. On Boox, also whitelist the app in any
   "freeze"/app-keeper settings if present.
3. "Start automatically after boot" is on by default; the engine then comes
   up by itself after a reboot.
4. In KOReader, tap a word / use "Speak (VOICEVOX)" as usual.

A word synthesis takes roughly 1–3 s on tablet-class arm64 CPUs. The engine
holds ~0.5 GB RAM while running; stop the server from the notification when
you don't need it.

## Adding / removing voices

Three ways, pick one (style ids: [SPEAKERS.md](SPEAKERS.md), or
`GET /speakers` / the app screen once installed):

1. **`./push-voices.sh all`** (or e.g. `./push-voices.sh 3 12`) — downloads
   the models and `adb push`es them to `/sdcard/voicevox/vvms/`. No rebuild;
   survives reinstalls. Grant the app's storage permission once (asked at
   first launch) and restart the server.
2. **Any file manager on the device** — copy `.vvm` files from the
   [voicevox_vvm release](https://github.com/VOICEVOX/voicevox_vvm/releases/tag/0.16.4)
   into `/sdcard/voicevox/vvms/` and restart the server.
3. **Bake into the APK**: `./fetch-artifacts.sh --all-voices` before building
   bundles all talk models (≈1.5 GB APK + the same again extracted — usually
   option 1 is the better deal for device storage).

## Licenses

VOICEVOX voice models and ONNX Runtime terms are bundled into the app
(`files/legal/` on device, `app/src/main/assets/legal/` here). In short:
embedding and redistribution in an app are allowed; **generated audio must be
credited**, e.g. 「VOICEVOX:ずんだもん」, and each character's own terms apply.
voicevox_core itself is MIT.
