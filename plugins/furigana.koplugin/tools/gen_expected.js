#!/usr/bin/env node
'use strict';
// Ground truth: annotate each line of samples.txt with the real bridge.js
// (via its --serve JSON-lines protocol) and write expected.lua (returns an
// array of strings) for the luajit comparison harness to consume.
const fs = require('fs');
const path = require('path');
const { spawn } = require('child_process');

const ANNOTATOR_DIR = process.env.ANNOTATOR_DIR ||
    '/home/zuckram/Desktop/CurrPC/Programming/japaneseFuriganaGenerator-main';
const BRIDGE = path.join(ANNOTATOR_DIR, 'bridge.js');
const samplesPath = process.argv[2] || path.join(__dirname, 'samples.txt');
const outPath = process.argv[3] || path.join(__dirname, 'expected.lua');

// Match the build's kana-ruby cleanup (build_dict.js) so the ground truth
// reflects our intended output, not the original annotator's empty-base ruby.
function isAllKana(s) {
    if (s === "") return true;
    for (const ch of s) {
        const c = ch.codePointAt(0);
        const kana = (c >= 0x3040 && c <= 0x309F) || (c >= 0x30A0 && c <= 0x30FF) ||
            (c >= 0xFF66 && c <= 0xFF9F);
        if (!kana) return false;
    }
    return true;
}
function unwrapKanaRuby(html) {
    return html.replace(/<ruby>(.*?)<rt>.*?<\/rt><\/ruby>/g,
        (m, base) => (isAllKana(base) ? base : m));
}

// Lua double-quoted string literal; non-ASCII left as-is (file is written UTF-8,
// Lua treats it as a byte string).
function luaStr(s) {
    let out = '"';
    for (const ch of s) {
        const c = ch.codePointAt(0);
        if (ch === '"') out += '\\"';
        else if (ch === '\\') out += '\\\\';
        else if (ch === '\n') out += '\\n';
        else if (ch === '\r') out += '\\r';
        else if (c < 0x20) out += '\\' + c;
        else out += ch;
    }
    return out + '"';
}

const fullText = fs.readFileSync(samplesPath, 'utf8').replace(/\n$/, '');
const lines = fullText.split('\n');
// One request per line, plus a final request with the whole multi-line block to
// validate newline handling end-to-end.
const requests = lines.concat([fullText]);

const proc = spawn('node', [BRIDGE, '--serve'], { cwd: ANNOTATOR_DIR });
const results = [];
// readline decodes UTF-8 across chunk boundaries correctly (a naive
// chunk.toString('utf8') corrupts multibyte chars split between chunks).
const rl = require('readline').createInterface({ input: proc.stdout });
rl.on('line', (line) => {
        if (line === '') return;
        const resp = JSON.parse(line);
        if (!resp.ok) { console.error('bridge error:', resp.error); process.exit(1); }
        results.push(unwrapKanaRuby(resp.html));
        if (results.length === requests.length) {
            const block = results.pop(); // last one is the whole-block result
            const lua = 'return {\n' + results.map((r) => '  ' + luaStr(r) + ',').join('\n') + '\n}\n';
            fs.writeFileSync(outPath, lua);
            const blockPath = outPath.replace(/\.lua$/, '_block.lua');
            fs.writeFileSync(blockPath, 'return ' + luaStr(block) + '\n');
            console.log('Wrote', results.length, 'expected results (+block) to', outPath);
            proc.stdin.end();
            proc.kill();
            process.exit(0);
        }
});
proc.stderr.on('data', (d) => process.stderr.write(d));
for (const req of requests) proc.stdin.write(JSON.stringify(req) + '\n');
