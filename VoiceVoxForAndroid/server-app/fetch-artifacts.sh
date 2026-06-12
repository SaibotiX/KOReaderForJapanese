#!/usr/bin/env bash
# Stage all binary artifacts the VOICEVOX server app needs.
#
# Downloads (into ../artifacts, kept for reuse):
#   - java_packages.zip            voicevox_core 0.16.4 Java API maven repo (AAR)
#   - voicevox_onnxruntime android-arm64 + linux-x64 1.17.3
#   - open_jtalk_dic_utf_8-1.11.tar.gz
#   - 0.vvm + TERMS.txt + README.txt from VOICEVOX/voicevox_vvm 0.16.4
#     (0.vvm = 四国めたん 0/2/4/6, ずんだもん 1/3/5/7, 春日部つむぎ 8, 雨晴はう 10)
#
# Then unpacks them into the places the Gradle build expects:
#   local-maven/                                  maven repo with the AAR
#   app/src/main/assets/open_jtalk_dic_utf_8-1.11 dictionary
#   app/src/main/assets/vvms/0.vvm                voice model(s) baked into the APK
#   app/src/main/assets/legal/                    license/terms texts
#   app/src/main/jniLibs/arm64-v8a/libvoicevox_onnxruntime.so
#
# Idempotent: skips downloads that already exist.
#
# By default only 0.vvm is baked into the APK; with --all-voices every talk
# model 0..24 is staged into the assets (~1.5 GB APK — usually you want
# ./push-voices.sh instead, which copies models to /sdcard/voicevox/vvms
# without a rebuild).

set -euo pipefail
cd "$(dirname "$0")"

CORE_VER=0.16.4
ORT_VER=1.17.3
ART=../artifacts
VOICES="0"
[ "${1:-}" = "--all-voices" ] && VOICES=$(seq 0 24)
mkdir -p "$ART"

fetch() { # url -> file in $ART
    local url=$1 out="$ART/$(basename "$1")"
    if [ ! -s "$out" ]; then
        echo "downloading $(basename "$url")"
        curl -sSfL --retry 2 -o "$out" "$url"
    fi
}

fetch "https://github.com/VOICEVOX/voicevox_core/releases/download/$CORE_VER/java_packages.zip"
fetch "https://github.com/VOICEVOX/onnxruntime-builder/releases/download/voicevox_onnxruntime-$ORT_VER/voicevox_onnxruntime-android-arm64-$ORT_VER.tgz"
fetch "https://github.com/VOICEVOX/onnxruntime-builder/releases/download/voicevox_onnxruntime-$ORT_VER/voicevox_onnxruntime-linux-x64-$ORT_VER.tgz"
fetch "https://github.com/r9y9/open_jtalk/releases/download/v1.11.1/open_jtalk_dic_utf_8-1.11.tar.gz"
for n in $VOICES; do
    fetch "https://github.com/VOICEVOX/voicevox_vvm/releases/download/$CORE_VER/$n.vvm"
done
fetch "https://github.com/VOICEVOX/voicevox_vvm/releases/download/$CORE_VER/TERMS.txt"
fetch "https://github.com/VOICEVOX/voicevox_vvm/releases/download/$CORE_VER/README.txt"

echo "staging local-maven/"
rm -rf local-maven && mkdir -p local-maven
unzip -qo "$ART/java_packages.zip" -d local-maven

echo "staging assets"
ASSETS=app/src/main/assets
mkdir -p "$ASSETS/vvms" "$ASSETS/legal"
rm -rf "$ASSETS/open_jtalk_dic_utf_8-1.11"
tar -xzf "$ART/open_jtalk_dic_utf_8-1.11.tar.gz" -C "$ASSETS"
for n in $VOICES; do
    cp -f "$ART/$n.vvm" "$ASSETS/vvms/$n.vvm"
done
cp -f "$ART/TERMS.txt" "$ASSETS/legal/VOICEVOX_MODEL_TERMS.txt"
cp -f "$ART/README.txt" "$ASSETS/legal/VOICEVOX_MODEL_README.txt"

echo "staging jniLibs"
JNI=app/src/main/jniLibs/arm64-v8a
mkdir -p "$JNI"
tar -xzf "$ART/voicevox_onnxruntime-android-arm64-$ORT_VER.tgz" -C "$ART" \
    "voicevox_onnxruntime-android-arm64-$ORT_VER/lib/libvoicevox_onnxruntime.so" \
    "voicevox_onnxruntime-android-arm64-$ORT_VER/TERMS.txt"
cp -f "$ART/voicevox_onnxruntime-android-arm64-$ORT_VER/lib/libvoicevox_onnxruntime.so" "$JNI/"
cp -f "$ART/voicevox_onnxruntime-android-arm64-$ORT_VER/TERMS.txt" "$ASSETS/legal/VOICEVOX_ONNXRUNTIME_TERMS.txt"

echo "done. assets:"
du -sh "$ASSETS"/* "$JNI"/* local-maven
