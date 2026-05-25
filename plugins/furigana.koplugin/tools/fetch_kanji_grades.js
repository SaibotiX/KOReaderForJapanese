#!/usr/bin/env node
'use strict';
// One-time: produce tools/kanji_grades.json mapping each kanji to its KANJIDIC2
// "grade" (1-6 = Kyoiku by school grade, 8 = remaining Joyo, 9-10 = Jinmeiyo).
// Kanji with no grade are omitted (treated as "rare/non-Joyo" by build_dict.js).
//
// Source: KANJIDIC2 by the Electronic Dictionary Research and Development Group
// (EDRDG), licensed CC BY-SA 4.0. https://www.edrdg.org/wiki/index.php/KANJIDIC_Project
const fs = require('fs');
const path = require('path');
const zlib = require('zlib');
const https = require('https');
const http = require('http');

const HERE = __dirname;
const GZ = process.env.KANJIDIC2_GZ || path.join(HERE, 'kanjidic2.xml.gz');
const OUT = path.join(HERE, 'kanji_grades.json');
const URL = 'http://www.edrdg.org/kanjidic/kanjidic2.xml.gz';

function download(url, dest) {
    return new Promise((resolve, reject) => {
        const mod = url.startsWith('https') ? https : http;
        const f = fs.createWriteStream(dest);
        mod.get(url, (res) => {
            if (res.statusCode !== 200) { reject(new Error('HTTP ' + res.statusCode)); return; }
            res.pipe(f);
            f.on('finish', () => f.close(resolve));
        }).on('error', reject);
    });
}

async function main() {
    if (!fs.existsSync(GZ)) {
        console.log('Downloading KANJIDIC2 from', URL);
        await download(URL, GZ);
    }
    const xml = zlib.gunzipSync(fs.readFileSync(GZ)).toString('utf8');

    const grades = {};
    let n = 0;
    // Each <character> block: pull <literal> and (optional) <grade>.
    const charRe = /<character>([\s\S]*?)<\/character>/g;
    let m;
    while ((m = charRe.exec(xml)) !== null) {
        const block = m[1];
        const lit = block.match(/<literal>(.*?)<\/literal>/);
        const grade = block.match(/<grade>(\d+)<\/grade>/);
        if (lit && grade) {
            grades[lit[1]] = parseInt(grade[1], 10);
            n++;
        }
    }
    fs.writeFileSync(OUT, JSON.stringify(grades));
    console.log('Wrote', n, 'graded kanji to', OUT);
    // quick sanity
    for (const k of ['人', '日', '本', '私', '東', '京', '物', '理', '鬱', '璧']) {
        console.log('  ', k, '->', grades[k] === undefined ? '(none)' : grades[k]);
    }
}

main().catch((e) => { console.error(e); process.exit(1); });
