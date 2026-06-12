#!/usr/bin/env bash
# End-to-end test of the server code on this PC (no Android needed):
# compiles CoreHolder + EngineHttpServer against the desktop voicevox_core jar,
# starts the server with three voice models, then exercises the exact HTTP
# flow KOReader's furigana.koplugin/voicevox.lua performs (audio_query ->
# synthesis), including the lazy-load + LRU-eviction path (MAX_LOADED_MODELS=2,
# so the third model evicts the first, and re-using the first reloads it).
# Requires fetch-artifacts.sh to have run.
set -euo pipefail
cd "$(dirname "$0")"

ART=../../artifacts
PORT=50121
CORE_VER=0.16.4
CORE_JAR=../local-maven/jp/hiroshiba/voicevoxcore/voicevoxcore/$CORE_VER/voicevoxcore-$CORE_VER.jar

mkdir -p libs work out
fetch_jar() {
    [ -s "libs/$(basename "$1")" ] || curl -sSfL -o "libs/$(basename "$1")" "$1"
}
fetch_jar https://repo1.maven.org/maven2/com/google/code/gson/gson/2.10.1/gson-2.10.1.jar
fetch_jar https://repo1.maven.org/maven2/org/nanohttpd/nanohttpd/2.3.1/nanohttpd-2.3.1.jar
fetch_jar https://repo1.maven.org/maven2/jakarta/validation/jakarta.validation-api/3.0.2/jakarta.validation-api-3.0.2.jar
fetch_jar https://repo1.maven.org/maven2/jakarta/annotation/jakarta.annotation-api/2.1.1/jakarta.annotation-api-2.1.1.jar

[ -d work/open_jtalk_dic_utf_8-1.11 ] || tar -xzf "$ART/open_jtalk_dic_utf_8-1.11.tar.gz" -C work
[ -d work/voicevox_onnxruntime-linux-x64-1.17.3 ] || tar -xzf "$ART/voicevox_onnxruntime-linux-x64-1.17.3.tgz" -C work
mkdir -p work/vvms
for n in 0 1 2; do
    if [ ! -s "$ART/$n.vvm" ]; then
        echo "downloading $n.vvm"
        curl -sSfL --retry 3 -o "$ART/$n.vvm" \
            "https://github.com/VOICEVOX/voicevox_vvm/releases/download/$CORE_VER/$n.vvm"
    fi
    cp -f "$ART/$n.vvm" work/vvms/
done

CP="$CORE_JAR:libs/*"
javac -cp "$CP" -d out \
    ../app/src/main/java/com/saibotix/voicevoxserver/CoreHolder.java \
    ../app/src/main/java/com/saibotix/voicevoxserver/EngineHttpServer.java \
    src/DesktopMain.java

java -cp "out:$CP" DesktopMain \
    work/open_jtalk_dic_utf_8-1.11 work/vvms \
    "$(realpath work/voicevox_onnxruntime-linux-x64-1.17.3/lib/libvoicevox_onnxruntime.so)" \
    $PORT > work/server.log 2>&1 &
SERVER_PID=$!
trap 'kill $SERVER_PID 2>/dev/null || true' EXIT

echo "waiting for engine…"
for i in $(seq 1 60); do
    grep -q READY work/server.log && break
    kill -0 $SERVER_PID 2>/dev/null || { echo "server died:"; cat work/server.log; exit 1; }
    sleep 1
done
grep -q READY work/server.log || { echo "engine never became ready:"; cat work/server.log; exit 1; }

BASE=http://127.0.0.1:$PORT
echo "GET /version  -> $(curl -sf $BASE/version)"
curl -sf $BASE/speakers | python3 -c "
import json, sys
speakers = json.load(sys.stdin)
styles = sum(len(c['styles']) for c in speakers)
print(f'GET /speakers -> {len(speakers)} speakers, {styles} styles')
# 0.vvm alone has 4 speakers / 10 styles; 1.vvm + 2.vvm add 2 speakers / 5 styles
assert len(speakers) == 6 and styles == 15, 'expected the union of three model files'
"

# The exact two-step flow from voicevox.lua.
synth() { # style_id text
    local enc
    enc=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$2")
    curl -sf -X POST "$BASE/audio_query?speaker=$1&text=$enc" -o work/query.json
    curl -sf -X POST -H 'Content-Type: application/json' --data-binary @work/query.json \
        "$BASE/synthesis?speaker=$1" -o work/out.wav
    python3 -c "
import wave
w = wave.open('work/out.wav')
dur = w.getnframes() / w.getframerate()
print(f'  style $1 -> WAV ok: {w.getframerate()} Hz, {dur:.2f} s')
assert dur > 0.3, 'suspiciously short audio'
"
}

style_from() { # vvm file -> first style id in it
    unzip -p "work/vvms/$1" metas.json | python3 -c \
        "import json,sys; print(json.load(sys.stdin)[0]['styles'][0]['id'])"
}
S1=$(style_from 1.vvm)
S2=$(style_from 2.vvm)

echo "lazy load + eviction (cap 2): styles 3 (0.vvm), $S1 (1.vvm), $S2 (2.vvm), 3 again"
synth 3 "こんにちは、ずんだもんなのだ"
synth "$S1" "音声モデルを順番に読み込みます"
synth "$S2" "三つ目のモデルで最初のモデルが解放されます"
synth 3 "また戻ってきたのだ"

grep -q "unloaded" work/server.log || { echo "FAIL: no eviction happened"; exit 1; }
echo "  (server log confirms LRU eviction + reload)"

# unknown style id must give a clean 400, not a 500
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/audio_query?speaker=9999&text=test")
[ "$code" = 400 ] || { echo "FAIL: unknown style returned HTTP $code"; exit 1; }
echo "unknown style id -> HTTP 400 with detail"

echo "PASS — lazy multi-model server matches what furigana.koplugin/voicevox.lua expects"
