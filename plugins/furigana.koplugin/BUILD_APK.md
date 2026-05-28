# Building a KOReader Android APK with the furigana plugin (for Boox GO 7)

This guide builds a KOReader `.apk` that includes the `furigana.koplugin` and
installs it on a Boox GO 7 (2nd Gen). The Boox runs **Android (arm64)**, so the
build target is **`android-arm64`**.

> Important: the `koreader-master` folder you have now is a *source snapshot*, not
> a git checkout. It has **no `.git`** and its submodules (`koreader-base`,
> `platform/android/luajit-launcher`, fonts, …) are empty. KOReader **cannot be
> built from it**. You must build from a real git clone and copy the plugin in.

---

## 0. What you need

The build is heavy (multi-GB downloads, 20–60 min the first time, ~10–15 GB disk).
Pick **one** of two routes:

- **Docker route (recommended)** — only needs `git` + `docker`. Everything else
  (compilers, NDK, SDK, Java) lives in KOReader's prebuilt image.
- **Native route** — install the full toolchain on your Linux box yourself.

The Boox GO 7 (2nd Gen) is a 64-bit ARM device. If unsure, confirm with:
*Settings → About → (CPU/ABI)* — you want `arm64-v8a`. (If it ever shows 32-bit
only, build `android-arm` instead of `android-arm64`.)

---

## 1. Get a buildable KOReader tree

Clone the same KOReader you based this fork on (your fork if you have one online,
otherwise upstream), **with submodules**:

```bash
git clone --recursive https://github.com/koreader/koreader.git
cd koreader
```

If you cloned without `--recursive`:

```bash
git submodule update --init --recursive
```

> Tip: match the version your snapshot came from to avoid frontend/plugin API
> drift. If you have your fork on GitHub, clone that instead.

## 2. Add the plugin to the clone

Copy the whole plugin directory (including the generated `dict/`, ~36 MB) from
your snapshot into the clone:

```bash
cp -r /home/zuckram/Desktop/CurrPC/Programming/koreader-master/plugins/furigana.koplugin \
      koreader/plugins/
```

Then make the one-line menu-order edit so the toggle appears under the
search/dictionary menu tab. In `frontend/ui/elements/reader_menu_order.lua`, find
the `search = { … }` block and add `"furigana_annotation"` after
`"vocabbuilder"`:

```lua
    search = {
        "search_settings",
        "----------------------------",
        "dictionary_lookup",
        "dictionary_lookup_history",
        "vocabbuilder",
        "furigana_annotation",   -- <-- add this line
        "----------------------------",
        ...
    },
```

(That is the only change outside the plugin folder. Everything else is
self-contained in `plugins/furigana.koplugin/`.)

You do **not** need Node or Python for the APK build — the dictionary in `dict/`
is already generated and ships as-is inside the plugin.

## 3a. Build — Docker route (recommended)

Only `git` and `docker` required. Follow KOReader's virtual dev environment:
<https://github.com/koreader/virdevenv>. In short, you run the prebuilt image
with this repo mounted, then inside it:

```bash
./kodev fetch-thirdparty
./kodev release android-arm64
```

This route avoids installing the compilers/NDK/SDK/Java yourself.

## 3b. Build — Native route (Debian/Ubuntu)

Install the base toolchain (from `doc/Building.md`):

```bash
sudo apt install --no-install-recommends autoconf automake build-essential \
    ca-certificates cmake gcc-multilib gettext git libtool libtool-bin meson \
    nasm ninja-build patch pkg-config unzip wget
```

Plus the Android extras (from `doc/Building_targets.md`):

```bash
sudo apt install openjdk-17-jdk-headless p7zip-full
```

> The build auto-downloads a compatible **NDK r23c** and **SDK (API 28)** into
> `base/toolchain/` unless you point `ANDROID_NDK_HOME`/`ANDROID_SDK_ROOT` at your
> own installs.

Then, from the clone root:

```bash
./kodev fetch-thirdparty       # one-time: pulls thirdparty sources
./kodev release android-arm64  # builds the APK
```

## 4. Find the APK

After a successful build, look for the generated package in the project root:

```bash
ls -1 *.apk
# e.g. koreader-android-arm64-<version>.apk
```

## 4b. Sign the APK (REQUIRED — the build output is unsigned)

`./kodev release android-arm64` produces an **unsigned** APK. Android 11+ (the
Boox runs 13) rejects unsigned APKs with **"package appears to be invalid."** You
must sign it with a v2/v3 signature using the SDK build-tools the build already
downloaded (`base/toolchain/android-sdk-linux/build-tools/<ver>/`). You need a
JRE/JDK for `apksigner`/`keytool` (if you built via Docker, run these inside the
container or install `openjdk-17-jre-headless`, or use a portable JRE):

```bash
SDK=base/toolchain/android-sdk-linux
BT=$SDK/build-tools/34.0.0

# one-time: create a keystore (remember the password)
keytool -genkeypair -v -keystore furigana.keystore -alias kor \
    -keyalg RSA -keysize 2048 -validity 10000 \
    -storepass furigana -keypass furigana -dname "CN=KOReader Furigana"

# align, then sign (adds v1+v2+v3)
$BT/zipalign -p -f 4 koreader-android-arm64-*.apk koreader-aligned.apk
$BT/apksigner sign --ks furigana.keystore --ks-pass pass:furigana \
    --out koreader-signed.apk koreader-aligned.apk

# confirm v2/v3 = true
$BT/apksigner verify -v koreader-signed.apk
```

Install `koreader-signed.apk` (not the raw build output). Keep `furigana.keystore`
and reuse it for future builds, so reinstalls upgrade in place instead of clashing.

## 5. Install on the Boox GO 7

Either:

- **adb** (USB debugging on in Boox developer options):
  ```bash
  adb install -r koreader-android-arm64-*.apk
  ```
- **or** copy the `.apk` to the device and tap it in the Boox file manager
  (allow "install from unknown sources" when prompted).

If you already had KOReader installed from a different signing key, uninstall the
old one first (Android refuses to "upgrade" across signers).

## 6. Enable and use

1. Open KOReader → top menu → **Tools/gear → Plugin management** and make sure
   **Japanese furigana** is enabled (then restart KOReader if you just enabled it).
2. Open a Japanese **EPUB**.
3. Top menu → the **search/dictionary tab (magnifier)** → **Add furigana
   annotations**.
4. First run on a book takes a few seconds (it builds an annotated copy and
   caches it under KOReader's `cache/furigana/`). It then reopens the book with
   ruby readings, near your current page.
5. Tap the same item again (now check-marked) to switch back to the original.

The menu item only appears/enables when an EPUB is open.

---

## Notes & troubleshooting

- **Only EPUB is supported** (by design). The item is hidden/disabled for PDF, CBZ, etc.
- **Memory/time:** annotating a full novel uses ~35 MB RAM and some seconds of CPU
  on-device; the result is cached so re-toggling is instant.
- **Position after toggle is approximate the first time** (ruby insertion shifts
  the internal DOM slightly). Switching back to the original is exact.
- **Regenerating the dictionary** (only if you change the kuromoji data) needs
  Node + your annotator checkout, and the kanji-grade data for selective furigana:
  `node tools/fetch_kanji_grades.js` (once, downloads KANJIDIC2) then
  `node tools/build_dict.js`.
- **Selective furigana:** the **Furigana** menu has a *Reading level* submenu —
  annotate all kanji, or only kanji at/above a chosen Japanese school grade
  (KANJIDIC2 grades). Each level caches as a separate annotated copy.
- **Replace the book's own furigana:** a toggle in the **Furigana** menu. Off
  (default) keeps publisher ruby and only adds ours where missing; on strips the
  book's embedded ruby first so every reading is ours and obeys the level.
- **If ruby doesn't render**, check the EPUB really contained Japanese text and
  that KOReader's typography settings aren't hiding ruby.
- **Re-validating the engine** off-device (optional): see the scripts in
  `tools/` — `gen_expected.js` + `run_test.lua` (tokenizer) and
  `gen_frag_expected.py` + `run_frag_test.lua` (EPUB fragment), run with a
  locally built `luajit`.
```
