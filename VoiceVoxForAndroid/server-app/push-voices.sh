#!/usr/bin/env bash
# Download VOICEVOX talk voice models and push them onto the device at
# /sdcard/voicevox/vvms/ via adb. No APK rebuild needed: the server scans that
# folder on every start, and it survives app reinstalls. Models are loaded
# into RAM lazily on first use, so pushing all of them is fine.
#
# Usage:
#   ./push-voices.sh all        # every talk model 0..24 (~1.5 GB on device)
#   ./push-voices.sh 1 5 13     # just these models (see SPEAKERS.md for ids)
set -euo pipefail
cd "$(dirname "$0")"

ART=../artifacts
CORE_VER=0.16.4
DEST=/sdcard/voicevox/vvms
ADB=$(command -v adb || true)
[ -n "$ADB" ] || ADB="$(cd ../../base/toolchain/android-sdk-linux && pwd)/platform-tools/adb"

[ $# -ge 1 ] || { echo "usage: $0 all | <vvm numbers…>" >&2; exit 1; }
if [ "$1" = "all" ]; then
    set -- $(seq 0 24)
fi

"$ADB" shell mkdir -p "$DEST"
for n in "$@"; do
    f="$ART/$n.vvm"
    if [ ! -s "$f" ]; then
        echo "downloading $n.vvm"
        curl -sSfL --retry 3 -o "$f" \
            "https://github.com/VOICEVOX/voicevox_vvm/releases/download/$CORE_VER/$n.vvm"
    fi
    "$ADB" push "$f" "$DEST/$n.vvm"
done
echo "done — restart the server in the VOICEVOX Server app (grant storage access once)"
