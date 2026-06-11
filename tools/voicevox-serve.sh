#!/bin/sh
# Serve the VOICEVOX engine bundled inside the installed VOICEVOX app
# (~/.voicevox/VOICEVOX.AppImage) on the LAN, for KOReader's furigana word
# audio (plugins/furigana.koplugin). No extraction needed: the AppImage is
# mounted and the engine started from the mount; everything is cleaned up
# when the engine exits.
#
# Usage:  tools/voicevox-serve.sh [extra engine args]   (stop with Ctrl-C)
# Then point KOReader at http://<this PC's LAN IP>:50021
# (the desktop emulator can use the default http://127.0.0.1:50021).
#
# Override the app location with VOICEVOX_APPIMAGE=/path/to/VOICEVOX.AppImage

APPIMAGE="${VOICEVOX_APPIMAGE:-$HOME/.voicevox/VOICEVOX.AppImage}"
if [ ! -x "$APPIMAGE" ]; then
    echo "VOICEVOX app not found at $APPIMAGE" >&2
    echo "Install it from https://voicevox.hiroshiba.jp/ or set VOICEVOX_APPIMAGE." >&2
    exit 1
fi

"$APPIMAGE" --appimage-mount | {
    read -r MNT || exit 1
    echo "VOICEVOX engine: $MNT/vv-engine/run (Ctrl-C to stop)"
    # --host 0.0.0.0 makes it reachable from the e-reader over Wi-Fi.
    exec "$MNT/vv-engine/run" --host 0.0.0.0 --port 50021 "$@"
}
