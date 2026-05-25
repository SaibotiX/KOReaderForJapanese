#!/usr/bin/env node
'use strict';
/*
 * Build-time converter: turns the kuromoji.js IPADIC dictionary into a compact,
 * LuaJIT-FFI-friendly form that the KOReader furigana plugin reads at runtime.
 *
 * We keep only what a furigana Viterbi tokenizer needs:
 *   - the double-array trie (base/check)              -> da_base.bin, da_check.bin
 *   - per-token left_id/right_id/word_cost            -> tokens.bin
 *   - per-token precomputed ruby HTML                 -> html.bin (+ offsets in tokens.bin)
 *   - the connection-cost matrix                      -> cc.bin
 *   - the target map (trie value -> token ids), CSR   -> tm_offset.bin, tm_values.bin
 *   - unknown-word data (char categories, unk tokens) -> unk_cat.bin, unk_tokens.bin, meta
 *
 * The 42 MB tid_pos POS/pronunciation data is dropped; only the reading (and the
 * ruby HTML derived from it) is kept. Per-token HTML is generated here using the
 * annotator's OWN wanakana + splitToken logic, so the runtime needs no Japanese
 * logic at all and the output matches bridge.js by construction.
 *
 * Usage:  node build_dict.js [OUT_DIR]
 *   ANNOTATOR_DIR env var overrides the path to japaneseFuriganaGenerator-main.
 */
const fs = require('fs');
const path = require('path');

const ANNOTATOR_DIR = process.env.ANNOTATOR_DIR ||
    '/home/zuckram/Desktop/CurrPC/Programming/japaneseFuriganaGenerator-main';
const OUT_DIR = process.argv[2] || path.join(__dirname, '..', 'dict');
const DICT_VERSION = 1;

// --- fetch shim so the browser-built kuromoji can read dict/*.dat.gz via fs ----
// (Copied from the annotator's bridge.js.)
global.fetch = function (url) {
    return new Promise((resolve, reject) => {
        try {
            const buf = fs.readFileSync(url);
            const ab = buf.buffer.slice(buf.byteOffset, buf.byteOffset + buf.byteLength);
            resolve({ ok: true, statusText: 'OK', arrayBuffer: () => Promise.resolve(ab) });
        } catch (e) { reject(e); }
    });
};

const wanakana = require(path.join(ANNOTATOR_DIR, 'scripts', 'wanakana.min.js'));
const kuromoji = require(path.join(ANNOTATOR_DIR, 'scripts', 'kuromoji', 'build', 'kuromoji.js'));

// --- splitToken: copied verbatim from bridge.js (which copied it from index.js) -
function splitToken(surfaceForm, readingHiragana) {
    let lastHiraganaIndex = null;
    let extractedHiraganaChunk = '';
    let outputHtml = '';

    [...surfaceForm].forEach((c, index) => {
        if (wanakana.isHiragana(c)) {
            if (lastHiraganaIndex == null || index == lastHiraganaIndex + 1) {
                extractedHiraganaChunk += c;
                lastHiraganaIndex = index;
            } else if (index > lastHiraganaIndex + 1) {
                return `<ruby>${surfaceForm}<rt>${readingHiragana}</rt></ruby>`;
            }
        }
    });

    const extractedHiraganaChunkStartIndex = surfaceForm.indexOf(extractedHiraganaChunk);

    if (extractedHiraganaChunkStartIndex === 0) {
        outputHtml += extractedHiraganaChunk;
        outputHtml += '<ruby>' + surfaceForm.substring(extractedHiraganaChunk.length) +
            '<rt>' + readingHiragana.replace(extractedHiraganaChunk, '') + '</rt></ruby>';
    } else if (
        extractedHiraganaChunkStartIndex > 0 &&
        extractedHiraganaChunkStartIndex + extractedHiraganaChunk.length < surfaceForm.length
    ) {
        const re = new RegExp(extractedHiraganaChunk + '.+', 'g');
        const re2 = new RegExp('.+' + extractedHiraganaChunk, 'g');
        const surfChunk1 = surfaceForm.substring(0, extractedHiraganaChunkStartIndex);
        const surfChunk2 = extractedHiraganaChunk;
        const surfChunk3 = surfaceForm.substring(surfChunk1.length + surfChunk2.length);

        outputHtml += '<ruby>' + surfChunk1 + '<rt>' + readingHiragana.replace(re, '') + '</rt></ruby>';
        outputHtml += surfChunk2;
        outputHtml += '<ruby>' + surfChunk3 + '<rt>' + readingHiragana.replace(re2, '') + '</rt></ruby>';
    } else {
        outputHtml += '<ruby>' + surfaceForm.replace(extractedHiraganaChunk, '') +
            '<rt>' + readingHiragana.replace(extractedHiraganaChunk, '') + '</rt></ruby>';
        outputHtml += extractedHiraganaChunk;
    }

    return outputHtml;
}

// Per-token output, exactly matching bridge.js's annotate() decision for one token.
function tokenHtml(surface, readingKatakana) {
    if (readingKatakana === undefined) return surface;
    const readingHiragana = wanakana.toHiragana(readingKatakana);
    if (surface !== readingHiragana && surface !== readingKatakana) {
        return splitToken(surface, readingHiragana);
    }
    return surface;
}

function ensureDir(d) { fs.mkdirSync(d, { recursive: true }); }
function writeRawTypedArray(file, typedArray) {
    const buf = Buffer.from(typedArray.buffer, typedArray.byteOffset, typedArray.byteLength);
    fs.writeFileSync(file, buf);
    return buf.length;
}

function build(tok) {
    ensureDir(OUT_DIR);

    const tid = tok.token_info_dictionary;
    const dictBuf = tid.dictionary.buffer;   // Uint8Array, 10-byte records
    const posBuf = tid.pos_buffer.buffer;     // Uint8Array, null-terminated UTF-8 strings
    const targetMap = tid.target_map;         // { trieValue : [byteOffset, ...] }

    const getShort = (i) => {
        let v = dictBuf[i] | (dictBuf[i + 1] << 8);
        if (v & 0x8000) v = v - 0x10000;
        return v;
    };
    const getInt = (i) =>
        dictBuf[i] + (dictBuf[i + 1] << 8) + (dictBuf[i + 2] << 16) + (dictBuf[i + 3] * 0x1000000);
    const getPosString = (off) => {
        let end = off;
        while (end < posBuf.length && posBuf[end] !== 0) end++;
        return Buffer.from(posBuf.subarray(off, end)).toString('utf8');
    };

    // --- double array trie ---------------------------------------------------
    const base = tok.viterbi_builder.trie.bc.getBaseBuffer();   // Int32Array
    const check = tok.viterbi_builder.trie.bc.getCheckBuffer(); // Int32Array
    const baseBytes = writeRawTypedArray(path.join(OUT_DIR, 'da_base.bin'), base);
    const checkBytes = writeRawTypedArray(path.join(OUT_DIR, 'da_check.bin'), check);

    // --- connection costs ----------------------------------------------------
    const cc = tok.viterbi_searcher.connection_costs.buffer;    // Int16Array (incl 2 header ints)
    writeRawTypedArray(path.join(OUT_DIR, 'cc.bin'), cc);
    const ccFwd = cc[0], ccBwd = cc[1];

    // --- dense token table + target map (CSR) --------------------------------
    let maxV = 0;
    for (const k of Object.keys(targetMap)) { const v = +k; if (v > maxV) maxV = v; }

    const offToDense = new Map();
    const denseOffsets = [];
    const tmOffset = new Int32Array(maxV + 2);
    const tmValues = [];
    for (let v = 0; v <= maxV; v++) {
        tmOffset[v] = tmValues.length;
        const vals = targetMap[v];
        if (vals) {
            for (const off of vals) {
                let d = offToDense.get(off);
                if (d === undefined) { d = denseOffsets.length; offToDense.set(off, d); denseOffsets.push(off); }
                tmValues.push(d);
            }
        }
    }
    tmOffset[maxV + 1] = tmValues.length;
    writeRawTypedArray(path.join(OUT_DIR, 'tm_offset.bin'), tmOffset);
    writeRawTypedArray(path.join(OUT_DIR, 'tm_values.bin'), Int32Array.from(tmValues));

    // tokens.bin: naturally-aligned 12-byte records, matching the Lua cdef
    //   struct { uint32_t html_off; uint16_t html_len; int16_t left; int16_t right; int16_t cost; }
    // Field order puts the uint32 at offset 0 so every field is naturally aligned
    // (critical to avoid unaligned reads / SIGBUS on ARM).
    const N = denseOffsets.length;
    const REC = 12;
    const tokRec = Buffer.alloc(N * REC);
    const htmlParts = [];
    let htmlCursor = 0;
    for (let d = 0; d < N; d++) {
        const off = denseOffsets[d];
        const left = getShort(off), right = getShort(off + 2), cost = getShort(off + 4);
        const posId = getInt(off + 6);
        const parts = getPosString(posId).split(',');
        const surface = parts[0];
        const reading = parts.length > 8 ? parts[8] : undefined;
        const html = Buffer.from(tokenHtml(surface, reading), 'utf8');
        if (html.length > 0xFFFF) throw new Error('token html too long: ' + html.length);
        const base2 = d * REC;
        tokRec.writeUInt32LE(htmlCursor, base2);
        tokRec.writeUInt16LE(html.length, base2 + 4);
        tokRec.writeInt16LE(left, base2 + 6);
        tokRec.writeInt16LE(right, base2 + 8);
        tokRec.writeInt16LE(cost, base2 + 10);
        htmlParts.push(html);
        htmlCursor += html.length;
    }
    fs.writeFileSync(path.join(OUT_DIR, 'tokens.bin'), tokRec);
    fs.writeFileSync(path.join(OUT_DIR, 'html.bin'), Buffer.concat(htmlParts));

    // --- unknown word handling ----------------------------------------------
    const unk = tok.unknown_dictionary;
    const unkDict = unk.dictionary.buffer; // Uint8Array
    const unkGetShort = (i) => { let v = unkDict[i] | (unkDict[i + 1] << 8); if (v & 0x8000) v = v - 0x10000; return v; };
    const unkTargetMap = unk.target_map;   // { classId : [byteOffset, ...] }
    const charDef = unk.character_definition;
    const catMap = charDef.character_category_map; // Uint8Array(65536): codepoint -> classId
    const invMap = charDef.invoke_definition_map.map; // [CharacterClass]

    writeRawTypedArray(path.join(OUT_DIR, 'unk_cat.bin'), catMap);

    const unkOffToDense = new Map();
    const unkDenseOffsets = [];
    const unkClasses = {}; // classId -> { name, always, grouping, token_ids:[...] }
    let defaultClassId = 0;
    for (let i = 0; i < invMap.length; i++) {
        const cc2 = invMap[i];
        if (cc2 && cc2.class_name === 'DEFAULT') defaultClassId = cc2.class_id;
    }
    for (const k of Object.keys(unkTargetMap)) {
        const classId = +k;
        const cclass = invMap[classId];
        const ids = [];
        for (const off of unkTargetMap[k]) {
            let d = unkOffToDense.get(off);
            if (d === undefined) { d = unkDenseOffsets.length; unkOffToDense.set(off, d); unkDenseOffsets.push(off); }
            ids.push(d);
        }
        unkClasses[classId] = {
            name: cclass ? cclass.class_name : ('CLASS' + classId),
            always: cclass && cclass.is_always_invoke ? 1 : 0,
            grouping: cclass && cclass.is_grouping ? 1 : 0,
            token_ids: ids,
        };
    }
    const UN = unkDenseOffsets.length;
    const unkRec = Buffer.alloc(UN * 6); // int16 left,right,cost
    for (let d = 0; d < UN; d++) {
        const off = unkDenseOffsets[d];
        unkRec.writeInt16LE(unkGetShort(off), d * 6);
        unkRec.writeInt16LE(unkGetShort(off + 2), d * 6 + 2);
        unkRec.writeInt16LE(unkGetShort(off + 4), d * 6 + 4);
    }
    fs.writeFileSync(path.join(OUT_DIR, 'unk_tokens.bin'), unkRec);

    // --- meta.lua ------------------------------------------------------------
    const lua = [];
    lua.push('-- Generated by tools/build_dict.js. Do not edit by hand.');
    lua.push('return {');
    lua.push('  version = ' + DICT_VERSION + ',');
    lua.push('  base_len = ' + (baseBytes / 4) + ',');
    lua.push('  check_len = ' + (checkBytes / 4) + ',');
    lua.push('  cc_forward = ' + ccFwd + ',');
    lua.push('  cc_backward = ' + ccBwd + ',');
    lua.push('  token_count = ' + N + ',');
    lua.push('  max_trie_value = ' + maxV + ',');
    lua.push('  tm_values_count = ' + tmValues.length + ',');
    lua.push('  unk_token_count = ' + UN + ',');
    lua.push('  default_class_id = ' + defaultClassId + ',');
    lua.push('  unk_classes = {');
    for (const classId of Object.keys(unkClasses).map(Number).sort((a, b) => a - b)) {
        const c = unkClasses[classId];
        lua.push('    [' + classId + '] = { name = ' + JSON.stringify(c.name) +
            ', always = ' + c.always + ', grouping = ' + c.grouping +
            ', token_ids = {' + c.token_ids.join(',') + '} },');
    }
    lua.push('  },');
    lua.push('}');
    fs.writeFileSync(path.join(OUT_DIR, 'meta.lua'), lua.join('\n') + '\n');

    // --- report --------------------------------------------------------------
    const mb = (b) => (b / 1048576).toFixed(2) + ' MB';
    console.log('Dictionary written to', OUT_DIR);
    console.log('  da_base.bin   ', mb(baseBytes), '(' + (baseBytes / 4) + ' int32)');
    console.log('  da_check.bin  ', mb(checkBytes));
    console.log('  cc.bin        ', mb(cc.byteLength), ccFwd + 'x' + ccBwd);
    console.log('  tokens.bin    ', mb(tokRec.length), N + ' tokens');
    console.log('  html.bin      ', mb(htmlCursor));
    console.log('  tm_offset.bin ', mb(tmOffset.byteLength));
    console.log('  tm_values.bin ', mb(tmValues.length * 4));
    console.log('  unk_cat.bin   ', mb(catMap.byteLength));
    console.log('  unk_tokens.bin', mb(unkRec.length), UN + ' unk tokens');
    console.log('  unk classes   ', Object.keys(unkClasses).length, 'default=' + defaultClassId);
}

kuromoji.builder({ dicPath: path.join(ANNOTATOR_DIR, 'scripts', 'kuromoji', 'dict') })
    .build((err, tokenizer) => {
        if (err) { console.error('Failed to build kuromoji tokenizer:', err); process.exit(1); }
        build(tokenizer);
    });
