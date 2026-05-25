#!/usr/bin/env node
'use strict';
// Generate a large, adversarial corpus by concatenating random dictionary
// surfaces (and occasional punctuation). Ambiguous boundaries heavily exercise
// the Viterbi path selection and connection costs. Writes samples_stress.txt.
const fs = require('fs');
const path = require('path');

const ANNOTATOR_DIR = process.env.ANNOTATOR_DIR ||
    '/home/zuckram/Desktop/CurrPC/Programming/japaneseFuriganaGenerator-main';
const OUT = process.argv[2] || path.join(__dirname, 'samples_stress.txt');
const NLINES = parseInt(process.argv[3] || '3000', 10);

global.fetch = function (url) {
    return new Promise((resolve, reject) => {
        try {
            const buf = fs.readFileSync(url);
            const ab = buf.buffer.slice(buf.byteOffset, buf.byteOffset + buf.byteLength);
            resolve({ ok: true, statusText: 'OK', arrayBuffer: () => Promise.resolve(ab) });
        } catch (e) { reject(e); }
    });
};
const kuromoji = require(path.join(ANNOTATOR_DIR, 'scripts', 'kuromoji', 'build', 'kuromoji.js'));

// Deterministic PRNG so runs are reproducible.
let seed = 0x2545F491;
function rnd() { seed ^= seed << 13; seed ^= seed >>> 17; seed ^= seed << 5; return (seed >>> 0) / 0xFFFFFFFF; }
function pick(a) { return a[Math.floor(rnd() * a.length)]; }

kuromoji.builder({ dicPath: path.join(ANNOTATOR_DIR, 'scripts', 'kuromoji', 'dict') })
    .build((err, tok) => {
        if (err) throw err;
        const tid = tok.token_info_dictionary;
        const posBuf = tid.pos_buffer.buffer;
        const targetMap = tid.target_map;
        const surfaces = [];
        const seen = new Set();
        for (const k of Object.keys(targetMap)) {
            for (const off of targetMap[k]) {
                // read the dictionary record's pos_id then the surface (field 0)
                const dictBuf = tid.dictionary.buffer;
                const posId = dictBuf[off + 6] + (dictBuf[off + 7] << 8) +
                    (dictBuf[off + 8] << 16) + (dictBuf[off + 9] * 0x1000000);
                let end = posId; while (end < posBuf.length && posBuf[end] !== 0) end++;
                const s = Buffer.from(posBuf.subarray(posId, end)).toString('utf8').split(',')[0];
                if (s && !seen.has(s) && s.length <= 6) { seen.add(s); surfaces.push(s); }
            }
            if (surfaces.length > 60000) break;
        }
        const punct = ['', '', '', '、', '。', ' ', '「', '」'];
        const lines = [];
        for (let i = 0; i < NLINES; i++) {
            const n = 5 + Math.floor(rnd() * 16);
            let line = '';
            for (let j = 0; j < n; j++) {
                line += pick(surfaces);
                if (rnd() < 0.15) line += pick(punct);
            }
            lines.push(line);
        }
        fs.writeFileSync(OUT, lines.join('\n') + '\n');
        console.log('Wrote', NLINES, 'stress lines (', surfaces.length, 'distinct surfaces ) to', OUT);
    });
