-- Tests for readingextractor.lua (tap-reveal furigana popups): parsing the
-- tokenizer's annotated output into offset-mapped ruby runs, and building the
-- per-word display text. Pure Lua, no KOReader or LuaJIT needed:
--   lua tools/run_reading_extractor_test.lua

local here = arg[0]:match("^(.*)/[^/]*$") or "."
package.path = here .. "/../?.lua;" .. package.path
local RE = require("readingextractor")

local failures = 0
local function check(cond, msg)
    if cond then
        print("ok   - " .. msg)
    else
        failures = failures + 1
        print("FAIL - " .. msg)
    end
end

-- Byte offset (0-based) of `needle` in `hay`, for readable test setup.
local function offset_of(hay, needle)
    local s = hay:find(needle, 1, true)
    assert(s, "test setup: needle not found")
    return s - 1
end

-- ----------------------------------------------------------------- parse --

-- Mirrors the real tokenizer output shape (see tools/expected_stress.lua):
-- token-surface bases, okurigana outside, plain kana between runs.
local plain = "どす黒かった一陣の風が食べた。"
local annotated = "どす<ruby>黒かっ<rt>ぐろかっ</rt></ruby>た<ruby>一<rt>いち</rt></ruby><ruby>陣<rt>じん</rt></ruby>の<ruby>風<rt>かぜ</rt></ruby>が<ruby>食<rt>た</rt></ruby>べた。"

local runs, parsed_plain = RE.parse(annotated)
check(parsed_plain == plain, "parse strips ruby markup back to the plain text")
check(#runs == 5, "parse finds all ruby runs: " .. #runs)
check(runs[1].base == "黒かっ" and runs[1].reading == "ぐろかっ",
    "run bases/readings captured (incl. kana inside the base)")
check(runs[1].start == offset_of(plain, "黒かっ") and runs[1].len == #"黒かっ",
    "run offsets index into the plain text")
check(runs[4].start == offset_of(plain, "風"),
    "offsets stay correct after several runs")

local no_ruby_runs, no_ruby_plain = RE.parse("ひらがなだけ")
check(#no_ruby_runs == 0 and no_ruby_plain == "ひらがなだけ",
    "text without ruby parses to zero runs, unchanged")

-- --------------------------------------------------------------- display --

local function disp(word)
    return RE.display(plain, runs, offset_of(plain, word), #word)
end

check(disp("風") == "風（かぜ）", "single-token word: base（reading）")
check(disp("黒") == "黒かっ（ぐろかっ）",
    "tapping part of a token expands to the whole token")
check(disp("食べた") == "食（た）べた",
    "okurigana outside the ruby base is kept plain")
check(disp("一陣") == "一（いち）陣（じん）",
    "word spanning two runs shows both readings")
check(disp("どす") == nil, "kana-only word: no reading to show")
check(disp("。") == nil, "punctuation: no reading to show")

-- Word range straddling a run boundary plus trailing kana.
local off = offset_of(plain, "黒かった")
check(RE.display(plain, runs, off, #"黒かった") == "黒かっ（ぐろかっ）た",
    "union of word and run covers trailing plain text")

-- Custom brackets.
check(RE.display(plain, runs, offset_of(plain, "風"), #"風", "(", ")") == "風(かぜ)",
    "bracket characters are configurable")

-- Number tokens (full-width digits get merged-number readings).
local num_annotated = "<ruby>２０２４<rt>にせんにじゅうよん</rt></ruby>年"
local num_runs, num_plain = RE.parse(num_annotated)
check(num_plain == "２０２４年" and
    RE.display(num_plain, num_runs, 0, #"２０２４") == "２０２４（にせんにじゅうよん）",
    "number ruby runs work like any other run")

print(failures == 0 and "\nALL TESTS PASSED" or ("\n" .. failures .. " TEST(S) FAILED"))
os.exit(failures == 0 and 0 or 1)
