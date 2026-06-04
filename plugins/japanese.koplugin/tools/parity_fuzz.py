#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Large-scale parity fuzzer: prove the Lua port reproduces engine.py exactly.

Samples thousands of real JMdict surfaces (verbs/adjectives/na/nouns) plus
machine-generated inflected forms (so the analyze/deinflect ladder is exercised,
not just forward inflection), then writes the same three artifacts as
gen_expected.py but prefixed `fuzz_`:

  fuzz_samples.txt / fuzz_expected.lua / fuzz_pos_fixture.lua

run_fuzz.lua diffs the Lua conjugate_field against fuzz_expected.lua.  Any
mismatch is a port-fidelity bug.  Seeded, so runs are reproducible.

Usage (from tools/):  python3 parity_fuzz.py [n_dict] [n_inflected_bases]
"""

import os
import random
import sqlite3
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
CLI_DIR = os.path.normpath(os.path.join(HERE, "..", "..", "..", ".."))
sys.path.insert(0, CLI_DIR)

import engine  # noqa: E402

DB = os.path.join(CLI_DIR, "jmdict_pos.sqlite")
VERB_ADJ = {"v1", "v5", "vk", "vs", "vz", "adj-i", "adj-ix"}
OTHER = {"na", "noun", "pn", "prt", "adj-no"}
BAD_CHARS = set("「」『』【】\n\r\t ")


def usable(surface):
    return surface and not (BAD_CHARS & set(surface))


def main():
    n_dict = int(sys.argv[1]) if len(sys.argv) > 1 else 4000
    n_infl_bases = int(sys.argv[2]) if len(sys.argv) > 2 else 1200
    random.seed(20260603)

    con = sqlite3.connect(DB)
    conj, others = [], []
    for surface, classes in con.execute("SELECT surface, classes FROM pos"):
        if not usable(surface):
            continue
        cls = set(classes.split("|"))
        if cls & VERB_ADJ:
            conj.append(surface)
        elif cls & OTHER:
            others.append(surface)

    random.shuffle(conj)
    random.shuffle(others)
    dict_words = conj[:n_dict] + others[: n_dict // 4]

    # Inflected inputs: generate forms for a subset of conjugable words and feed
    # them back, so analyze()/deinflect() must recover the base and re-expand.
    inflected = []
    for base in conj[:n_infl_bases]:
        forms = [f for f, _ in engine.forms_for(engine.analyze(base)) if usable(f)]
        if forms:
            inflected.extend(random.sample(forms, min(3, len(forms))))

    samples = []
    seen = set()
    for tok in dict_words + inflected:
        if tok not in seen:
            seen.add(tok)
            samples.append(tok)

    # Spy on POS lookups so the Lua fixture is exact.
    rec_classes, rec_common = {}, {}
    oc, ok = engine.DICT.classes, engine.DICT.common

    def classes_spy(s):
        r = oc(s)
        if r:
            rec_classes[s] = r
        return r

    def common_spy(s):
        r = ok(s)
        if r:
            rec_common[s] = True
        return r

    engine.DICT.classes, engine.DICT.common = classes_spy, common_spy
    expected = [engine.conjugate_field("「" + tok + "」") for tok in samples]

    def lua_str(s):
        return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'

    with open(os.path.join(HERE, "fuzz_samples.txt"), "w", encoding="utf-8") as fh:
        fh.write("\n".join(samples) + "\n")
    with open(os.path.join(HERE, "fuzz_expected.lua"), "w", encoding="utf-8") as fh:
        fh.write("return {\n")
        for line in expected:
            fh.write("  " + lua_str(line) + ",\n")
        fh.write("}\n")
    with open(os.path.join(HERE, "fuzz_pos_fixture.lua"), "w", encoding="utf-8") as fh:
        fh.write("return {\n  classes = {\n")
        for s in sorted(rec_classes):
            fh.write("    [" + lua_str(s) + "] = { "
                     + ", ".join(lua_str(c) for c in rec_classes[s]) + " },\n")
        fh.write("  },\n  common = {\n")
        for s in sorted(rec_common):
            fh.write("    [" + lua_str(s) + "] = true,\n")
        fh.write("  },\n}\n")

    print("fuzz: {} samples ({} dict + {} inflected), {} class rows".format(
        len(samples), len(dict_words), len(inflected), len(rec_classes)))


if __name__ == "__main__":
    main()
