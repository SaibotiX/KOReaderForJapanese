-- Unit test for analysis.lua (the popup presenter): headword selection, POS
-- labelling, the conjugation path, and the copula-fragment fallback, plus
-- strip_html / window_text.  Uses a mock Deinflector and an inline POS table so
-- it runs under stock lua5.3 (no KOReader).  Exits non-zero on any failure.
--
-- Usage (from tools/):  lua5.3 run_analysis_test.lua

local here = arg[0]:match("^(.*)/[^/]*$") or "."
package.path = here .. "/?.lua;" .. here .. "/../?.lua;" .. package.path
-- Stub KOReader's gettext (identity) so analysis.lua loads standalone.
package.preload["gettext"] = function() return function(s) return s end end

local Conjugator = require("conjugator")
local json_min = require("json_min")
local PosDictFixture = require("posdict_fixture")
local Analysis = require("analysis")

Conjugator.configure(
    json_min.load_file(here .. "/../yomichan-deinflect.json"),
    PosDictFixture.new({
        classes = {
            ["食べる"] = { "v1" }, ["行く"] = { "v5" }, ["高い"] = { "adj-i" },
            ["できる"] = { "v1" }, ["静か"] = { "na", "adj-no" }, ["勉強"] = { "vs", "noun" },
        },
        common = {
            ["食べる"] = true, ["行く"] = true, ["高い"] = true,
            ["できる"] = true, ["静か"] = true,
        },
    }))

-- Mock Deinflector: returns the candidate list mapped for each surface.
local CANDS = {
    ["食べさせられました"] = {
        { term = "食べさせられました", reasons = {} },
        { term = "食べる", reasons = { "causative", "passive", "polite past" } },
    },
    ["行かなかった"] = {
        { term = "行かなかった", reasons = {} },
        { term = "行く", reasons = { "negative", "past" } },
    },
    ["高くない"] = {
        { term = "高くない", reasons = {} },
        { term = "高い", reasons = { "negative" } },
    },
    ["できます"] = {
        { term = "できます", reasons = {} },
        { term = "できる", reasons = { "polite" } },
    },
}
local mock = { deinflect = function(_, text)
    return CANDS[text] or { { term = text, reasons = {} } }
end }

local fails = 0
local function check(label, got, want)
    if got ~= want then
        fails = fails + 1
        io.write(string.format("FAIL %s\n  want: %s\n  got : %s\n", label, tostring(want), tostring(got)))
    end
end

local function case(surface, base, pos_label, conjugation)
    local r = Analysis.analyse(surface, mock)
    check(surface .. ".base", r.base, base)
    check(surface .. ".pos", r.pos_label, pos_label)
    check(surface .. ".conj", r.conjugation, conjugation)
end

-- Deinflector path: deepest dictionary headword + reason path.
case("食べさせられました", "食べる", "ichidan verb (ru-verb)", "causative · passive · polite past")
case("行かなかった", "行く", "godan verb (u-verb)", "negative · past")
case("高くない", "高い", "i-adjective", "negative")
case("できます", "できる", "ichidan verb (ru-verb)", "polite")
-- Copula-fragment fallback (deinflector returns nothing useful): conjugator
-- ladder recovers the na-adjective stem and the paradigm label.
case("静かじゃない", "静か", "na-adjective", "Non-past negative")

-- strip_html / window_text.
check("strip_html", Analysis.strip_html("<b>to eat</b><br>also: &amp; etc."), "to eat\nalso: & etc.")
-- Block-structured (StarDict "h"-type) entries must not collapse into a blob.
check("strip_html.blocks",
    Analysis.strip_html('<div class="m">①意味その一</div><div class="m">②意味その二</div><p>例文。</p>'),
    "①意味その一\n②意味その二\n例文。")
check("strip_html.list",
    Analysis.strip_html("<ol><li>to eat</li><li>to live on</li></ol>"),
    "• to eat\n• to live on")
-- <hr> dividers act as line breaks, in all their spellings.
check("strip_html.hr",
    Analysis.strip_html("意味その一<hr>意味その二"), "意味その一\n意味その二")
check("strip_html.hr_variants",
    Analysis.strip_html("first<HR>second<hr/>third<hr class=\"sep\" />fourth"),
    "first\nsecond\nthird\nfourth")
check("strip_html.hr_between_blocks",
    Analysis.strip_html("<div>意味</div><hr><div>例文</div>"), "意味\n例文")
-- &nbsp; (and friends) must decode, not show literally; indentation survives.
check("strip_html.nbsp",
    Analysis.strip_html("見出し<br>&nbsp;&nbsp;例文です&hellip;"),
    "見出し\n  例文です…")
check("strip_html.numeric_entities",
    Analysis.strip_html("&#12354;&#x3042; &#65;"), "ああ A")
check("strip_html.amp_once", Analysis.strip_html("&amp;lt;tag&amp;gt;"), "&lt;tag&gt;")
-- Ruby readings become parentheses, <rp> fallbacks are dropped.
check("strip_html.ruby",
    Analysis.strip_html("<ruby>食<rp>(</rp><rt>た</rt><rp>)</rp></ruby>べる"),
    "食（た）べる")
-- Invisible blocks vanish; plain-text definitions keep their own newlines.
check("strip_html.style",
    Analysis.strip_html("<style>div { color: red; }</style>meaning"), "meaning")
check("strip_html.plain_text",
    Analysis.strip_html("first line\nsecond line"), "first line\nsecond line")
check("strip_html.html_compact",
    Analysis.strip_html("<p>one</p>\n\n\n<p>two</p>"), "one\ntwo")
check("strip_html.plain_blank_lines",
    Analysis.strip_html("one\n\n\n\ntwo"), "one\n\ntwo")

-- furigana_label: extract the kana reading from the furigana plugin's ruby HTML.
check("furigana.kanji", Analysis.furigana_label("食べる", "<ruby>食<rt>た</rt></ruby>べる"), "食べる (たべる)")
check("furigana.multi", Analysis.furigana_label("食べ物",
    "<ruby>食<rt>た</rt></ruby>べ<ruby>物<rt>もの</rt></ruby>"), "食べ物 (たべもの)")
check("furigana.no_reading", Analysis.furigana_label("たべる", "たべる"), "たべる")
check("furigana.empty", Analysis.furigana_label("本", ""), "本")
local result_for_wt = { surface = "食べました", base = "食べる",
    pos_label = "ichidan verb (ru-verb)", conjugation = "polite past",
    translate = "食べる → to eat", ai = "AI grammar breakdown…" }
local defs = { { dict = "JMdictA", definition = "to eat (A)" },
    { dict = "JMdictB", definition = "to eat (B)" } }
-- Default order: dictionaries, then Google Translate, then AI.
local pages = Analysis.build_pages(result_for_wt, defs)
check("pages.count", #pages, 4)
check("pages.1_dict_id", pages[1].id, "JMdictA")
check("pages.1_dict_title", pages[1].title, "JMdictA")
check("pages.3_translate_id", pages[3].id, Analysis.TRANSLATE_ID)
check("pages.3_translate_title", pages[3].title, "Google Translate")
check("pages.4_ai_id", pages[4].id, Analysis.AI_ID)

-- window_text: header fields + this page's section, with its position.
local wt = Analysis.window_text(result_for_wt, pages[1], 1, 4)
check("window_text.has_base", wt:find("Dictionary form: 食べる", 1, true) ~= nil, true)
check("window_text.has_conj", wt:find("Conjugation: polite past", 1, true) ~= nil, true)
check("window_text.has_heading", wt:find("JMdictA (1/4):", 1, true) ~= nil, true)
check("window_text.has_body", wt:find("to eat (A)", 1, true) ~= nil, true)
check("window_text.no_ai_on_dict", wt:find("AI analysis", 1, true), nil)

-- Custom order: AI, Google Translate, JMdictB, JMdictA.
local custom = { Analysis.AI_ID, Analysis.TRANSLATE_ID, "JMdictB", "JMdictA" }
local po = Analysis.build_pages(result_for_wt, defs, custom)
check("order.custom", table.concat({ po[1].id, po[2].id, po[3].id, po[4].id }, ","),
    Analysis.AI_ID .. "," .. Analysis.TRANSLATE_ID .. ",JMdictB,JMdictA")
-- Partial order: only AI listed → AI first, the rest keep default order.
local pp = Analysis.build_pages(result_for_wt, defs, { Analysis.AI_ID })
check("order.partial", table.concat({ pp[1].id, pp[2].id, pp[3].id, pp[4].id }, ","),
    Analysis.AI_ID .. ",JMdictA,JMdictB," .. Analysis.TRANSLATE_ID)

-- No dictionaries → a placeholder dict page, still followed by Translate/AI.
local pages2 = Analysis.build_pages(result_for_wt, {})
check("pages.empty_defs_count", #pages2, 3)
check("pages.empty_defs_dict", pages2[1].title, "Dictionary")

io.write(fails == 0 and "\nanalysis: all checks passed\n" or ("\nanalysis: " .. fails .. " FAILED\n"))
os.exit(fails == 0 and 0 or 1)
