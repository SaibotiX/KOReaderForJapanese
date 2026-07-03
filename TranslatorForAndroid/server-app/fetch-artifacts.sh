#!/usr/bin/env bash
# Stage the model artifact the translator server app bundles.
#
# Downloads (into ../artifacts, kept for reuse; also reuses a copy already
# fetched by tools/lfm2-translate-serve.sh into ~/.cache/lfm2-translate):
#   - LFM2-350M-ENJP-MT-Q4_K_M.gguf (~230 MB, LiquidAI, LFM Open License v1.0)
#
# Then places it where the Gradle build expects it:
#   app/src/main/assets/models/LFM2-350M-ENJP-MT-Q4_K_M.gguf
#
# Idempotent: skips downloads that already exist.
set -euo pipefail
cd "$(dirname "$0")"

MODEL=LFM2-350M-ENJP-MT-Q4_K_M.gguf
URL="https://huggingface.co/LiquidAI/LFM2-350M-ENJP-MT-GGUF/resolve/main/$MODEL"
ART=../artifacts
CACHE="$HOME/.cache/lfm2-translate/$MODEL"
mkdir -p "$ART"

if [ ! -s "$ART/$MODEL" ]; then
    if [ -s "$CACHE" ]; then
        echo "reusing $CACHE"
        cp -f "$CACHE" "$ART/$MODEL"
    else
        echo "downloading $MODEL (~230 MB)"
        curl -sSfL --retry 2 -o "$ART/$MODEL.part" "$URL"
        mv "$ART/$MODEL.part" "$ART/$MODEL"
    fi
fi

ASSETS=app/src/main/assets/models
mkdir -p "$ASSETS"
cp -f "$ART/$MODEL" "$ASSETS/$MODEL"

echo "done. assets:"
du -sh "$ASSETS/$MODEL"
