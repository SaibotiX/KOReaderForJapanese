#!/usr/bin/env bash
# Build the APK. Works both on the host and inside the KOReader build
# container (where the repo is mounted at /home/ko/koreader): the Android SDK
# always sits at <repo>/base/toolchain/android-sdk-linux, so local.properties
# is regenerated from this script's own location on every run.
#
# Prereqs (once): ./build-native.sh (llama-server) and ./fetch-artifacts.sh
# (the GGUF model).
#
# Usage: ./build.sh [gradle args]   (default: assembleRelease)
set -euo pipefail
cd "$(dirname "$0")"

SDK="$(cd ../../base/toolchain/android-sdk-linux && pwd)"
echo "sdk.dir=$SDK" > local.properties

for staged in app/src/main/jniLibs/arm64-v8a/libllamaserver.so \
              app/src/main/assets/models/LFM2-350M-ENJP-MT-Q4_K_M.gguf; do
    if [ ! -s "$staged" ]; then
        echo "missing $staged — run ./build-native.sh and ./fetch-artifacts.sh first" >&2
        exit 1
    fi
done

# AGP 7.4 needs JDK 11–19; prefer 17 when the default JVM is something else.
if [ -z "${JAVA_HOME:-}" ] && [ -d /usr/lib/jvm/java-17-openjdk-amd64 ]; then
    export JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64
fi

GRADLE=../artifacts/tools/gradle-7.6.4/bin/gradle
if [ ! -x "$GRADLE" ]; then
    # Reuse the VOICEVOX app's staged Gradle when present.
    VVG=../../VoiceVoxForAndroid/artifacts/tools/gradle-7.6.4/bin/gradle
    if [ -x "$VVG" ]; then
        GRADLE=$VVG
    else
        echo "staged Gradle missing; fetching gradle-7.6.4" >&2
        mkdir -p ../artifacts/tools
        curl -sSfL -o ../artifacts/tools/gradle-7.6.4-bin.zip \
            https://services.gradle.org/distributions/gradle-7.6.4-bin.zip
        unzip -qo ../artifacts/tools/gradle-7.6.4-bin.zip -d ../artifacts/tools
    fi
fi

exec "$GRADLE" "${@:-assembleRelease}"
