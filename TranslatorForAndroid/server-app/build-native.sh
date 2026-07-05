#!/usr/bin/env bash
# Cross-compile llama.cpp's llama-server for Android arm64 with the repo's
# NDK (base/toolchain/android-ndk-r23c) and stage it as
# app/src/main/jniLibs/arm64-v8a/libllamaserver.so (executables can only be
# exec'd from the APK's native lib dir, so the binary ships as a "lib").
#
# Works on the host and inside the KOReader build container (needs cmake +
# a C/C++ host toolchain for nothing — the NDK brings its own clang).
#
# Usage: ./build-native.sh          (pinned LLAMA_CPP_TAG below)
#        LLAMA_CPP_TAG=b9999 ./build-native.sh
set -euo pipefail
cd "$(dirname "$0")"

LLAMA_CPP_TAG="${LLAMA_CPP_TAG:-b9867}"
NDK="$(cd ../../base/toolchain/android-ndk-r23c && pwd)"
SRC=../native/llama.cpp
BUILD=../native/build-android-arm64

if ! command -v cmake >/dev/null; then
    echo "cmake not found — run inside the KOReader build container, e.g.:" >&2
    echo "  docker exec <container> bash -c 'cd /home/ko/koreader/TranslatorForAndroid/server-app && ./build-native.sh'" >&2
    exit 1
fi

if [ ! -d "$SRC/.git" ]; then
    echo "cloning llama.cpp $LLAMA_CPP_TAG"
    mkdir -p ../native
    git clone --depth 1 --branch "$LLAMA_CPP_TAG" \
        https://github.com/ggml-org/llama.cpp "$SRC"
else
    echo "using existing $SRC ($(git -C "$SRC" describe --tags --always))"
fi

# armv8-a baseline on purpose: dotprod/i8mm builds SIGILL on the A73/A53-class
# cores common in e-readers. 16 KB max-page-size future-proofs Android 15+.
# android-28: llama.cpp's vendored subprocess.h needs posix_spawn_file_actions,
# which Android's libc only exports from API 28 (the app's minSdk matches).
# LLAMA_BUILD_UI=OFF: no embedded web UI (needs a network fetch at configure
# time and is dead weight behind 127.0.0.1).
# CMAKE_*_FLAGS_RELEASE must be passed explicitly: the NDK's legacy
# android.toolchain.cmake replaces CMake's Release default (-O3 -DNDEBUG)
# with just -DNDEBUG, so ggml silently built at -O0 — ~15x slower inference
# (a sentence translation took minutes instead of seconds). The toolchain
# prepends its -DNDEBUG to whatever is passed here.
cmake -S "$SRC" -B "$BUILD" \
    -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake" \
    -DANDROID_ABI=arm64-v8a \
    -DANDROID_PLATFORM=android-28 \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_FLAGS_RELEASE="-O3" \
    -DCMAKE_CXX_FLAGS_RELEASE="-O3" \
    -DBUILD_SHARED_LIBS=OFF \
    -DGGML_NATIVE=OFF \
    -DGGML_OPENMP=OFF \
    -DLLAMA_CURL=OFF \
    -DLLAMA_BUILD_TESTS=OFF \
    -DLLAMA_BUILD_EXAMPLES=OFF \
    -DLLAMA_BUILD_TOOLS=ON \
    -DLLAMA_BUILD_SERVER=ON \
    -DLLAMA_BUILD_UI=OFF \
    -DCMAKE_EXE_LINKER_FLAGS="-Wl,-z,max-page-size=16384"
cmake --build "$BUILD" --target llama-server -j"$(nproc)"

JNI=app/src/main/jniLibs/arm64-v8a
mkdir -p "$JNI"
cp -f "$BUILD/bin/llama-server" "$JNI/libllamaserver.so"
# The NDK toolchain compiles with -g even in Release: strip the debug info.
"$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-strip" \
    --strip-unneeded "$JNI/libllamaserver.so" || true
echo "staged $JNI/libllamaserver.so:"
file "$JNI/libllamaserver.so" 2>/dev/null || true
du -h "$JNI/libllamaserver.so"
