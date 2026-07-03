#!/bin/sh
# Serve LiquidAI's LFM2-350M-ENJP-MT (offline Japanese→English translation)
# on the LAN through llama.cpp's llama-server, for japanese.koplugin's
# "Local translation server" (plugins/japanese.koplugin/localtranslator.lua).
#
# Usage:  tools/lfm2-translate-serve.sh [extra llama-server args]
# Then point KOReader at http://<this PC's LAN IP>:8087
# (the desktop emulator can use the default http://127.0.0.1:8087).
#
# Needs llama.cpp's llama-server on PATH (https://github.com/ggml-org/llama.cpp).
# The ~230 MB GGUF is downloaded once into ~/.cache/lfm2-translate.
# Stop with Ctrl-C. Override the port with LFM2_PORT, the model directory
# with LFM2_DIR.

MODEL_DIR="${LFM2_DIR:-$HOME/.cache/lfm2-translate}"
MODEL="$MODEL_DIR/LFM2-350M-ENJP-MT-Q4_K_M.gguf"
MODEL_URL="https://huggingface.co/LiquidAI/LFM2-350M-ENJP-MT-GGUF/resolve/main/LFM2-350M-ENJP-MT-Q4_K_M.gguf"
PORT="${LFM2_PORT:-8087}"

SERVER="$(command -v llama-server || true)"
if [ -z "$SERVER" ]; then
    echo "llama-server not found on PATH." >&2
    echo "Install llama.cpp (https://github.com/ggml-org/llama.cpp) first —" >&2
    echo "prebuilt releases include llama-server, or build with: cmake -B build && cmake --build build" >&2
    exit 1
fi

if [ ! -f "$MODEL" ]; then
    echo "Downloading LFM2-350M-ENJP-MT (Q4_K_M, ~230 MB) to $MODEL_DIR …"
    mkdir -p "$MODEL_DIR"
    if ! curl -L --fail -o "$MODEL.part" "$MODEL_URL"; then
        echo "Download failed." >&2
        rm -f "$MODEL.part"
        exit 1
    fi
    mv "$MODEL.part" "$MODEL"
fi

echo "LFM2 translation server on port $PORT (Ctrl-C to stop)"
# --host 0.0.0.0 makes it reachable from the e-reader over Wi-Fi.
exec "$SERVER" -m "$MODEL" --host 0.0.0.0 --port "$PORT" -c 4096 "$@"
