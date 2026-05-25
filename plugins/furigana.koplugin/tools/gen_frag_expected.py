#!/usr/bin/env python3
"""Ground truth for the EPUB fragment annotator: run the annotator's own
wrapper.annotate_html_fragment over sample.xhtml and write frag_expected.lua
(a Lua file returning the annotated string)."""
import os
import sys

ANNOTATOR_DIR = os.environ.get(
    "ANNOTATOR_DIR",
    "/home/zuckram/Desktop/CurrPC/Programming/japaneseFuriganaGenerator-main",
)
sys.path.insert(0, ANNOTATOR_DIR)
import wrapper  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
src = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "sample.xhtml")
out = sys.argv[2] if len(sys.argv) > 2 else os.path.join(HERE, "frag_expected.lua")


def lua_str(s):
    res = ['"']
    for ch in s:
        if ch == '"':
            res.append('\\"')
        elif ch == "\\":
            res.append("\\\\")
        elif ch == "\n":
            res.append("\\n")
        elif ch == "\r":
            res.append("\\r")
        elif ord(ch) < 0x20:
            res.append("\\%d" % ord(ch))
        else:
            res.append(ch)
    res.append('"')
    return "".join(res)


with open(src, "r", encoding="utf-8") as fh:
    markup = fh.read()

bridge = wrapper.Bridge()
try:
    annotated = wrapper.annotate_html_fragment(bridge, markup)
finally:
    bridge.close()

with open(out, "w", encoding="utf-8") as fh:
    fh.write("return " + lua_str(annotated) + "\n")
print("Wrote", out, "(%d bytes)" % len(annotated.encode("utf-8")))
