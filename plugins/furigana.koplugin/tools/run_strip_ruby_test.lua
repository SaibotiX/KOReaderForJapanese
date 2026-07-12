-- Tests for epubannotator.lua's ruby handling: strip_ruby and
-- annotate_fragment's skip tracking against HTML implied end tags
-- (`<ruby>来<rp>(<rt>く<rp>)</ruby>` — no </rt>/</rp>, how browsers and
-- SingleFile page saves emit ruby). A leak here used to truncate the
-- annotated copy at the document's first <ruby>. Pure Lua, no KOReader or
-- LuaJIT needed:
--   lua tools/run_strip_ruby_test.lua

local here = arg[0]:match("^(.*)/[^/]*$") or "."
package.path = here .. "/../?.lua;" .. package.path
local EA = require("epubannotator")

local failures = 0
local function check(cond, msg)
    if cond then
        print("ok   - " .. msg)
    else
        failures = failures + 1
        print("FAIL - " .. msg)
    end
end

local function eq(got, want, msg)
    if got == want then
        print("ok   - " .. msg)
    else
        failures = failures + 1
        print("FAIL - " .. msg)
        print("       want: " .. want)
        print("       got : " .. got)
    end
end

-- Tokenizer stub: brackets whatever text node it is offered, so the output
-- shows exactly which regions were (not) annotated.
local tok = { annotate = function(_, s) return "[" .. s .. "]" end }

-- ------------------------------------------------------------ strip_ruby --

eq(EA.strip_ruby("<ruby>漢<rp>(</rp><rt>かん</rt><rp>)</rp></ruby>字"),
    "漢字", "strip: balanced ruby with rp")

eq(EA.strip_ruby("<ruby><rb>漢</rb><rt>かん</rt></ruby>は"),
    "漢は", "strip: balanced ruby with rb")

-- The SingleFile/browser serialization that used to swallow the rest of the
-- document: no </rt>/</rp>, attributes on <rp>, markup inside the reading.
eq(EA.strip_ruby("<ruby><span lang=ja>来</span><rp class=sf-hidden><rt>"
        .. "<span lang=ja>く</span><rp class=sf-hidden></ruby>"
        .. "<span lang=ja>る</span><p>後</p>"),
    "<span lang=ja>来</span><span lang=ja>る</span><p>後</p>",
    "strip: implied end tags — content after </ruby> survives")

eq(EA.strip_ruby("<ruby>来<rt>く</ruby>る　→　<ruby>来て<rt>きて</ruby>で"),
    "来る　→　来てで", "strip: consecutive implied-end rubies")

eq(EA.strip_ruby("<ruby>漢<rtc><rt>かん<rt>カン</rtc></ruby>後"),
    "漢後", "strip: <rt> inside <rtc> leaves the <rtc> open")

eq(EA.strip_ruby("<ruby>漢<rt/></ruby>後"),
    "漢後", "strip: self-closing <rt/> opens nothing")

eq(EA.strip_ruby("a</rt>b</ruby>c"),
    "abc", "strip: stray close tags are ignored, text kept")

eq(EA.strip_ruby("<p><ruby>漢<rt>かん</p><p>次</p>"),
    "<p>漢</p><p>次</p>",
    "strip: a block end tag closes a dangling ruby (stop-loss)")

eq(EA.strip_ruby("<ruby>漢<rt><span>かん</span></ruby>後"),
    "漢後", "strip: non-ruby markup inside the reading is dropped with it")

eq(EA.strip_ruby("<RUBY>漢<RT>かん</RUBY>後"),
    "漢後", "strip: tag names are case-insensitive")

-- ---------------------------------------------------- annotate_fragment --

eq(EA.annotate_fragment(tok, "<ruby>漢<rt>かん</rt></ruby>の本"),
    "<ruby>漢<rt>かん</rt></ruby>[の本]",
    "fragment: balanced ruby skipped, following text annotated")

eq(EA.annotate_fragment(tok,
        "<ruby>来<rp class=x><rt>く<rp class=x></ruby>る<p>後の文</p>"),
    "<ruby>来<rp class=x><rt>く<rp class=x></ruby>[る]<p>[後の文]</p>",
    "fragment: implied end tags — annotation resumes after </ruby>")

eq(EA.annotate_fragment(tok, "<ruby>漢<rt>かん</p>次の文"),
    "<ruby>漢<rt>かん</p>[次の文]",
    "fragment: a block end tag closes a dangling ruby (stop-loss)")

eq(EA.annotate_fragment(tok, "<style>本文{}</style>語"),
    "<style>本文{}</style>[語]",
    "fragment: <style> content still skipped")

eq(EA.annotate_fragment(tok, "<head><title>日本語</title></head>語"),
    "<head><title>日本語</title></head>[語]",
    "fragment: <head> content still skipped")

-- -------------------------------------------------------- html_to_text --
-- Flattening crengine's page HTML to the reading-free plain text the
-- annotated-copy sentence reader works on (after strip_ruby).

eq(EA.html_to_text("<p>一文目。</p><p>二文目。</p>"),
    "一文目。\n二文目。",
    "to_text: block boundaries become newlines")

eq(EA.html_to_text(EA.strip_ruby(
        "<p><ruby>私<rt>わたし</rt></ruby>は<ruby>学校<rt>がっこう</rt></ruby>へ行く。</p>")),
    "私は学校へ行く。",
    "to_text after strip_ruby: readings are gone, base text is whole")

eq(EA.html_to_text('<p class="x">前<span>中</span>後</p>'),
    "前中後",
    "to_text: inline tags vanish without breaking the text")

eq(EA.html_to_text("一行目<br/>二行目"),
    "一行目\n二行目",
    "to_text: <br> breaks the line")

eq(EA.html_to_text("<p>A&amp;B &lt;3 &#x3042;&#12356;</p>"),
    "A&B <3 あい",
    "to_text: named and numeric entities are decoded")

eq(EA.html_to_text("<p>読\194\173点</p>"),
    "読点",
    "to_text: soft hyphens (crengine hyphenation) are removed")

eq(EA.html_to_text("<style>p { color: red }</style><p>本文。</p>"),
    "本文。",
    "to_text: <style> content is skipped")

eq(EA.html_to_text("<DocFragment><body><p>　段落。</p></body></DocFragment>"),
    "　段落。",
    "to_text: crengine wrappers break blocks; the ideographic indent is kept")

eq(EA.html_to_text("<p>  a  \n  b  </p>"),
    "a\nb",
    "to_text: ASCII whitespace runs collapse, newlines stay single")

-- ----------------------------------------------------------------------

if failures > 0 then
    print(failures .. " failure(s)")
    os.exit(1)
end
print("all ok")
