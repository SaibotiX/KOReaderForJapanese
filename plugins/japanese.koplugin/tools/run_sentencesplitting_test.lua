-- Tests for sentencesplitting.lua: page building / boundary carry / ruby
-- display (pure), and the controller's step→popup→fetch→play pipeline against
-- a stubbed KOReader runtime (scheduler pumped manually, subprocesses run
-- inline, real files under /tmp). Reuses the furigana plugin's real splitter
-- and reading extractor, so the cross-plugin integration is what's tested.
-- Pure Lua:  lua tools/run_sentencesplitting_test.lua

local here = arg[0]:match("^(.*)/[^/]*$") or "."
package.path = here .. "/../?.lua;" .. here .. "/../../furigana.koplugin/?.lua;" .. package.path

local failures = 0
local function check(cond, msg)
    if cond then
        print("ok   - " .. msg)
    else
        failures = failures + 1
        print("FAIL - " .. msg)
    end
end

local TMP = "/tmp/japanese_sentencesplitting_test"
os.execute("rm -rf '" .. TMP .. "' && mkdir -p '" .. TMP .. "'")

-- ----------------------------------------------------------------- stubs --

local settings = {}
G_reader_settings = { -- luacheck: ignore
    readSetting = function(_, k) return settings[k] end,
    saveSetting = function(_, k, v) settings[k] = v end,
    delSetting = function(_, k) settings[k] = nil end,
    isTrue = function(_, k) return settings[k] == true end,
    nilOrTrue = function(_, k) return settings[k] ~= false end,
    flipNilOrTrue = function(self, k)
        if self:nilOrTrue(k) then
            settings[k] = false
        else
            settings[k] = nil
        end
    end,
}

local queue = {}
local infos = {}   -- InfoMessages shown
local UIManager = {
    scheduleIn = function(_, t, fn) queue[#queue + 1] = fn end,
    unschedule = function(_, fn)
        for i = #queue, 1, -1 do
            if queue[i] == fn then table.remove(queue, i) end
        end
    end,
    show = function(_, w)
        if w and w.text and not w.on_step then infos[#infos + 1] = w.text end
    end,
    close = function(_, w)
        if w and w.close_callback then w.close_callback() end
    end,
    nextTick = function(_, fn) queue[#queue + 1] = fn end,
    setDirty = function() end,
}
local function pump(max)
    for _ = 1, max or 200 do
        local fn = table.remove(queue, 1)
        if not fn then return end
        fn()
    end
end

local gettext = setmetatable({}, { __call = function(_, s) return s end })
gettext.ngettext = function(s, p, n) return n == 1 and s or p end

local played = {}
local player_stops = 0
local vv_fail = false
local tr_fail = false
local fetched_texts = {}
local tr_calls = {}
local net = { online = true }

local find_calls = {}     -- findText patterns, in order
local clear_calls = 0     -- clearSelection invocations
local find_fail = false   -- findText returns nothing
local find_hit_page = nil -- page of the hit (nil: the current page)

local popups = {} -- every SentencePopup the controller created

-- The popup receives structured jp ({ plain, runs } or a plain string) + tr;
-- flatten to the old combined text for compact asserts: readings back in
-- parentheses, translation on the second line, "…" when both are missing.
local function popup_text(o)
    local jp = o.jp
    if type(jp) == "table" then
        local ReadingExtractor = require("readingextractor")
        jp = ReadingExtractor.display(jp.plain, jp.runs, 0, #jp.plain) or jp.plain
    end
    if jp and o.tr then return jp .. "\n" .. o.tr end
    return jp or o.tr or "…"
end

local subprocess_pid = 100
local stubs = {
    ["ui/uimanager"] = UIManager,
    ["gettext"] = gettext,
    ["ui/event"] = { new = function(_, name, arg) return { name = name, arg = arg } end },
    ["ui/widget/infomessage"] = { new = function(_, o) return o end },
    ["device"] = { isAndroid = function() return false end },
    ["logger"] = { dbg = function() end, info = function() end, warn = function() end, err = function() end },
    ["util"] = {
        makePath = function(d) os.execute("mkdir -p '" .. d .. "'") end,
        cleanupSelectedText = function(s)
            return (s:gsub("^%s+", ""):gsub("%s+$", ""))
        end,
    },
    ["datastorage"] = { getDataDir = function() return TMP end },
    ["ffi/util"] = {
        template = function(s, a) return (s:gsub("%%1", tostring(a or ""))) end,
        runInSubProcess = function(fn)
            subprocess_pid = subprocess_pid + 1
            fn(subprocess_pid) -- inline "fork"
            return subprocess_pid
        end,
        isSubProcessDone = function() return true end,
        terminateSubProcess = function() end,
        usleep = function() end,
    },
    ["libs/libkoreader-lfs"] = {
        attributes = function(p, what)
            local r = os.execute("test -d '" .. p .. "'")
            if r == 0 or r == true then
                if what == "mode" then return "directory" end
                return { mode = "directory" }
            end
            local f = io.open(p, "r")
            if f then
                f:close()
                if what == "mode" then return "file" end
                return { mode = "file", modification = os.time() }
            end
            return nil
        end,
        dir = function(d)
            local lines = {}
            local p = io.popen("ls -a '" .. d .. "' 2>/dev/null")
            if p then
                for l in p:lines() do lines[#lines + 1] = l end
                p:close()
            end
            local i = 0
            return function() i = i + 1 return lines[i] end
        end,
    },
    ["audioplayer"] = {
        play = function(_, path) played[#played + 1] = path; return true end,
        isPlaying = function() return false end,
        stop = function() player_stops = player_stops + 1 end,
        wavDurationSeconds = function() return 0.5 end,
    },
    ["voicevox"] = {
        fetch = function(opts, text, out)
            fetched_texts[#fetched_texts + 1] = text
            if vv_fail then return nil, "boom" end
            local f = io.open(out, "w")
            f:write("RIFF" .. text)
            f:close()
            return true
        end,
    },
    ["ui/translator"] = {
        getTargetLanguage = function() return "en" end,
        translate = function(_, text, target, source)
            tr_calls[#tr_calls + 1] = { text = text, target = target, source = source }
            if tr_fail then return nil end
            return "EN:" .. text
        end,
    },
    ["ui/geometry"] = { new = function(_, o) return o end },
    ["ui/network/manager"] = {
        isConnected = function() return net.online end,
    },
    ["sentencepopup"] = {
        new = function(_, o)
            popups[#popups + 1] = o
            return o
        end,
    },
}
for name, mod in pairs(stubs) do
    package.preload[name] = function() return mod end
end

local SS = require("sentencesplitting")

-- ------------------------------------------------- buildPage / computeSkip --

local page1 = "今日は晴れ。明日は雨が降るかも"
local page2 = "しれない。次の文。そして三つ目。"
local page3 = "三ページ目の文。"

local sents, consumed = SS.buildPage(page1, page2, 0)
check(#sents == 2 and sents[1] == "今日は晴れ。"
    and sents[2] == "明日は雨が降るかもしれない。",
    "page-spanning sentence completed from the next page")
check(consumed == #"しれない。", "carry consumed the completing head's bytes")

check(SS.computeSkip(page1, page2) == #"しれない。",
    "computeSkip mirrors what the previous page's tail consumed")
check(SS.computeSkip("完結した文。", page2) == 0,
    "no skip after a page that ends on a sentence boundary")

local sents2 = SS.buildPage(page2, page3, SS.computeSkip(page1, page2))
check(#sents2 == 2 and sents2[1] == "次の文。" and sents2[2] == "そして三つ目。",
    "carried bytes are not spoken again on the next page")

-- Quotes across the page break: the 。 inside the still-open 「…」 on the
-- next page must not end the carried completion early.
local q1 = "彼は「もう帰る。"
local q2 = "また明日。」と言った。残りの文。"
local q_sents = SS.buildPage(q1, q2, 0)
check(#q_sents == 1 and q_sents[1] == "彼は「もう帰る。また明日。」と言った。",
    "a quote spanning the page break is completed through its 」: " .. tostring(q_sents[1]))
check(SS.computeSkip(q1, q2) == #"また明日。」と言った。",
    "computeSkip carries the quote depth into the next page's head")

-- The complementary case (regression): a page ending in a CLOSED quote is a
-- complete sentence. It used to count as incomplete (its terminator sits
-- inside the brackets), so the NEXT page's first quote was glued onto it:
-- 「文一。」+「文二。」 became one block.
local c1 = "彼は言った。「文一。」"
local c2 = "「文二。」\nそれから帰った。"
local c_sents, c_consumed = SS.buildPage(c1, c2, 0)
check(#c_sents == 2 and c_sents[2] == "「文一。」" and c_consumed == 0,
    "a page ending in a closed quote does not swallow the next page's quote: "
        .. table.concat(c_sents, "|"))
check(SS.computeSkip(c1, c2) == 0,
    "computeSkip carries nothing over a closed-quote page end")
local c2_sents = SS.buildPage(c2, "", 0)
check(#c2_sents == 2 and c2_sents[1] == "「文二。」",
    "the next page keeps its own dialogue line: " .. table.concat(c2_sents, "|"))

-- Same with the 。 omitted before 」 (common in fiction).
local b_sents, b_consumed = SS.buildPage("彼は言った。「文一」", "「文二」\n続き。", 0)
check(#b_sents == 2 and b_sents[2] == "「文一」" and b_consumed == 0,
    "a terminator-less closed quote at the page end stays its own sentence: "
        .. table.concat(b_sents, "|"))

-- ------------------------------------------------------------- rubyRuns --

local rr = SS.rubyRuns("<ruby>漢字<rt>かんじ</rt></ruby>を書く。", "漢字を書く。")
check(type(rr) == "table" and #rr == 1 and rr[1].base == "漢字"
    and rr[1].reading == "かんじ" and rr[1].start == 0 and rr[1].len == #"漢字",
    "rubyRuns maps the tokenizer's ruby back to plain-text offsets")
rr = SS.rubyRuns("ひらがなだけ。", "ひらがなだけ。")
check(type(rr) == "table" and #rr == 0,
    "rubyRuns returns empty runs for kana-only sentences")
check(SS.rubyRuns("<ruby>違<rt>ちが</rt></ruby>う", "別のテキスト") == nil,
    "rubyRuns refuses a round-trip mismatch")

-- -------------------------------------------------------- rubySizeFromCss --

check(SS.rubySizeFromCss("rt, rubyBox[T=rt] { font-size: 50% !important; }") == 50,
    "rubySizeFromCss reads the Ruby style tweak's rt size")
check(SS.rubySizeFromCss("p, li { font-size: 60%; }") == nil,
    "rubySizeFromCss ignores css that does not target rt")
check(SS.rubySizeFromCss("rt { color: gray; }") == nil,
    "rubySizeFromCss ignores rt rules without a font-size")
check(SS.rubySizeFromCss("article { font-size: 80%; } rt { font-size: 45% }") == 45,
    "rubySizeFromCss is not fooled by selectors merely containing 'rt'")
check(SS.rubySizeFromCss("rt { font-size: 87.5% }") == 87.5,
    "rubySizeFromCss reads decimal percentages whole (not the trailing '5%')")
check(SS.rubySizeFromCss("rt { font-size: 0.6em }") == 60,
    "rubySizeFromCss understands em units")

-- ------------------------------------------------------------- controller --

local pages = { page1, page2, page3 }
local current_page = 1
local doc = {
    getCurrentPage = function() return current_page end,
    getPageCount = function() return #pages end,
    findText = function(_, pattern)
        find_calls[#find_calls + 1] = pattern
        if find_fail then return nil end
        return { { start = "xp_hit_start", ["end"] = "xp_hit_end" } }, 1
    end,
    clearSelection = function() clear_calls = clear_calls + 1 end,
    getPageFromXPointer = function() return find_hit_page or current_page end,
    getScreenBoxesFromPositions = function()
        return {
            { x = 100, y = 400, w = 300, h = 30 },
            { x = 100, y = 430, w = 200, h = 30 },
        }
    end,
}
local fg_locks = {}
local plugin, ctrl
local ui
ui = {
    document = doc,
    rolling = {
        key_events = {
            GotoNextView = { { { "RPgFwd", "LPgFwd", "Right" } }, event = "GotoViewRel", args = 1 },
            GotoPrevView = { { { "RPgBack", "LPgBack", "Left" } }, event = "GotoViewRel", args = -1 },
        },
        registerKeyEvents = function() end,
    },
    handleEvent = function(_, ev)
        if ev.name == "GotoViewRel" then
            local target = current_page + ev.arg
            if target >= 1 and target <= #pages then
                current_page = target
                plugin:onPageUpdate(current_page) -- ReaderUI would broadcast this
            end
        end
    end,
}
ui.furigana = {
    cache_dir = TMP .. "/furigana",
    pageText = function(_, page) return pages[page] end,
    voicevoxOpts = function() return { url = "http://vv", speaker = 3 } end,
    isShowingAnnotated = function() return false end,
    _precache = {
        setForegroundFetch = function(_, on) fg_locks[#fg_locks + 1] = on end,
    },
}
local fake_tok = {
    annotate = function(_, text)
        return (text:gsub("晴れ", "<ruby>晴<rt>は</rt></ruby>れ"))
    end,
}
plugin = {
    ui = ui,
    getFuriganaTokenizer = function() return fake_tok end,
    isSentenceSplittingEnabled = function() return settings.language_japanese_sentence_splitting == true end,
    onPageUpdate = function(_, page) if ctrl then ctrl:onPageUpdate(page) end end,
}
settings.language_japanese_sentence_splitting = true

ctrl = SS.newController(plugin)

-- key hijack
ctrl:applyKeys(true)
check(ui.rolling.key_events.GotoNextView.is_inactive == true
    and ui.rolling.key_events.GotoPrevView.is_inactive == true,
    "applyKeys(true) deactivates the page-turn bindings")
check(ctrl:seqFor(1) ~= nil and ctrl:seqFor(-1) ~= nil,
    "the hijacked key sequences are captured for the popup")

local function fake_key(name)
    return {
        match = function(_, seq)
            local function contains(t)
                for _, v in ipairs(t) do
                    if type(v) == "table" then
                        if contains(v) then return true end
                    elseif v == name then
                        return true
                    end
                end
                return false
            end
            return contains(seq)
        end,
    }
end

-- first press: first sentence of the current page (furigana on by default)
check(ctrl:onKeyPress(fake_key("LPgFwd")) == true, "a hijacked key press is consumed")
check(#popups == 1 and popup_text(popups[1]) == "今日は晴（は）れ。",
    "first press shows the page's first sentence with furigana spliced in")
check(type(popups[1].jp) == "table" and popups[1].jp.plain == "今日は晴れ。"
        and popups[1].jp.runs[1].base == "晴" and popups[1].jp.runs[1].reading == "は"
        and popups[1].jp.runs[1].start == #"今日は",
    "the popup receives the plain sentence plus its ruby runs (interlinear display)")
check(popups[1].sticky == true, "the popup is sticky by default")
check(popups[1].ruby_scale == 0.42,
    "without Ruby style tweaks the popup uses crengine's 42% rt size")
local a = popups[1].anchor_box
check(a ~= nil and a.x == 100 and a.y == 400 and a.w == 300 and a.h == 60,
    "the popup is anchored to the union of the sentence's line boxes")
check(find_calls[1] == "今日は晴れ。" and clear_calls >= 1,
    "the anchor search used the bare sentence text and cleared the selection")
check(ctrl:onKeyPress(fake_key("Home")) == nil, "unrelated keys are not consumed")

pump()
check(played[1] ~= nil and played[1]:match("%.wav$") ~= nil,
    "the first sentence's audio was synthesized and played")
check(#popups >= 2 and popup_text(popups[#popups]):find("EN:今日は晴れ。", 1, true) ~= nil,
    "the translation is swapped into the popup when it lands")
check(popup_text(popups[#popups]):find("晴（は）れ", 1, true) ~= nil,
    "the swapped popup keeps the furigana display")
check(popups[#popups].anchor_box ~= nil and popups[#popups].anchor_box.y == 400,
    "the translation swap keeps the sentence anchor")

-- lookahead: audio + translation of the next two sentences (crossing into
-- page 2) were prepared in the background
local function contains_text(list, needle)
    for _, t in ipairs(list) do
        if (type(t) == "table" and t.text or t) == needle then return true end
    end
    return false
end
check(contains_text(fetched_texts, "明日は雨が降るかもしれない。")
    and contains_text(fetched_texts, "次の文。"),
    "audio of the next two sentences (across the page break) was precached")
check(contains_text(tr_calls, "次の文。"), "their translations were precached too")
check(fg_locks[1] == true and fg_locks[#fg_locks] == false,
    "the word-precache worker was paused while fetching and released after")

-- second press: precached sentence plays and shows instantly
local played_before = #played
local fetches_before = #fetched_texts
ctrl:onKeyPress(fake_key("LPgFwd"))
check(popup_text(popups[#popups]):find("明日は雨が降るかもしれない。", 1, true) ~= nil
    and popup_text(popups[#popups]):find("EN:明日は", 1, true) ~= nil,
    "second press shows sentence 2 with its cached translation at once")
check(find_calls[#find_calls] == "明日は雨が降るかも",
    "a page-spanning sentence is located by its on-page part only")
check(#played == played_before + 1, "cached audio plays without waiting")
pump()
check(#fetched_texts >= fetches_before, "pump settles with no error")

-- single tap on the popup hides the translation; double tap replays
local pops_before = #popups
played_before = #played
popups[#popups].on_frame_tap()
pump() -- the double-tap window elapses: it was a single tap
check(#played == played_before and #popups == pops_before + 1
    and popup_text(popups[#popups]):find("EN:", 1, true) == nil
    and popup_text(popups[#popups]):find("明日は雨が降るかも", 1, true) ~= nil,
    "a single tap hides the translation line without replaying")
popups[#popups].on_frame_tap()
popups[#popups].on_frame_tap() -- second tap within the window
pump()
check(#played == played_before + 1, "a double tap replays the audio")
check(popup_text(popups[#popups]):find("EN:", 1, true) == nil,
    "a double tap does not toggle the translation")
popups[#popups].on_frame_tap()
pump()
check(popup_text(popups[#popups]):find("EN:明日は", 1, true) ~= nil,
    "a further single tap reveals the cached translation again")

-- third press: past the page's last sentence -> page flip, carry skipped
ctrl:onKeyPress(fake_key("LPgFwd"))
check(current_page == 2, "stepping past the last sentence turns the page")
check(ctrl.session ~= nil and ctrl.session.page == 2 and ctrl.session.idx == 1,
    "the session moved to the new page (self-caused flip kept it)")
check(popup_text(popups[#popups]):find("次の文。", 1, true) ~= nil,
    "the carried-over bytes are skipped: page 2 starts at its own sentence")
pump()

-- previous at the first sentence: back to page 1, its last sentence
ctrl:onKeyPress(fake_key("LPgBack"))
check(current_page == 1, "stepping back before the first sentence turns back")
check(ctrl.session.idx == 2
    and popup_text(popups[#popups]):find("明日は雨が降るかも", 1, true) ~= nil,
    "landing on the previous page's last sentence")
pump()

-- a page change we didn't cause resets the session
current_page = 3
plugin:onPageUpdate(3)
check(ctrl.session == nil, "manual navigation drops the session")
ctrl:onKeyPress(fake_key("LPgFwd"))
check(ctrl.session ~= nil and ctrl.session.page == 3
    and popup_text(popups[#popups]):find("三ページ目の文。", 1, true) ~= nil,
    "the next press starts fresh on the new page")
pump()

-- synthesis failure: capped retries, one notification, no infinite loop
vv_fail = true
pages[3] = "失敗する文。"
current_page = 3
ctrl:reset() -- drop the session so the replaced page text is picked up
infos = {}
ctrl:onKeyPress(fake_key("LPgFwd"))
pump(500)
local notified = false
for _, t in ipairs(infos) do
    if t:find("could not synthesize", 1, true) then notified = true end
end
check(notified, "a definitively failed synthesis notifies once")
vv_fail = false

-- anchor lookup failures fall back to the bottom popup
find_fail = true
current_page = 1
plugin:onPageUpdate(1) -- leave page 3: session drops, fresh start below
ctrl:onKeyPress(fake_key("LPgFwd"))
check(popups[#popups].anchor_box == nil,
    "an unfindable sentence falls back to the bottom popup")
pump()
find_fail = false

-- a match beyond the current page is not this page's sentence
find_hit_page = 99
ctrl:reset()
ctrl:onKeyPress(fake_key("LPgFwd"))
check(popups[#popups].anchor_box == nil,
    "a match beyond the current page is not used as anchor")
pump()
find_hit_page = nil

-- translation toggle off: nothing fetched, nothing shown (even when cached)
settings.language_japanese_sentence_translate = false
ctrl:reset()
local tr_before = #tr_calls
ctrl:onKeyPress(fake_key("LPgFwd"))
pump()
check(popup_text(popups[#popups]):find("EN:", 1, true) == nil,
    "translation toggle off: the popup shows no translation line")
check(#tr_calls == tr_before, "translation toggle off: no translation is fetched")
infos = {}
popups[#popups].on_frame_tap()
pump()
local disabled_note = false
for _, t in ipairs(infos) do
    if t:find("disabled in the menu", 1, true) then disabled_note = true end
end
check(disabled_note, "tapping the popup while translation is off explains itself")
settings.language_japanese_sentence_translate = nil -- back to the default (on)

-- offline: translation fetches are skipped (tries not burned), said once
net.online = false
pages[3] = "新しい文章です。"
current_page = 3
ctrl:reset()
infos = {}
tr_before = #tr_calls
ctrl:onKeyPress(fake_key("LPgFwd"))
pump()
check(#tr_calls == tr_before, "offline: no translation fetch is attempted")
local offline_notes = 0
for _, t in ipairs(infos) do
    if t:find("No network", 1, true) then offline_notes = offline_notes + 1 end
end
check(offline_notes == 1, "offline: announced exactly once")
ctrl:onKeyPress(fake_key("LPgBack")) -- steps back to page 2's cached sentence
pump()
offline_notes = 0
for _, t in ipairs(infos) do
    if t:find("No network", 1, true) then offline_notes = offline_notes + 1 end
end
check(offline_notes == 1
    and popup_text(popups[#popups]):find("EN:", 1, true) ~= nil,
    "offline: cached translations still show, without renewed nagging")
net.online = true

-- a translation that keeps failing while online is announced once
tr_fail = true
pages[3] = "翻訳失敗の文。"
current_page = 3
ctrl:stop() -- also clears the "already notified" flag
infos = {}
ctrl:onKeyPress(fake_key("LPgFwd"))
pump(500)
local fail_notes = 0
for _, t in ipairs(infos) do
    if t:find("translation failed", 1, true) then fail_notes = fail_notes + 1 end
end
check(fail_notes == 1, "an exhausted online translation is announced once")
tr_fail = false

-- the tap toggle is a session preference: it sticks across sentences
current_page = 1
plugin:onPageUpdate(1)
ctrl:onKeyPress(fake_key("LPgFwd"))
check(popup_text(popups[#popups]):find("EN:今日は晴れ。", 1, true) ~= nil,
    "translation is visible again on a fresh sentence (from cache)")
popups[#popups].on_frame_tap()
pump()
ctrl:onKeyPress(fake_key("LPgFwd"))
check(popup_text(popups[#popups]):find("EN:", 1, true) == nil,
    "the hidden choice persists to the following sentence")
pump()

-- ================== pure helpers: anchoring & positions ===================

local needles = SS.anchorNeedles("最初の行です。\n二行目のテキスト。", 0)
check(needles[1] == "最初の行です。\n二行目のテキスト。" and needles[2] == "最初の行です。",
    "anchorNeedles: full sentence first, then the first line")
check(#needles == 4 and needles[#needles] == "最初の",
    "anchorNeedles: progressively shorter first-line prefixes, down to 3 chars")
check(#SS.anchorNeedles("あ", 0) == 1 and SS.anchorNeedles("あ", 0)[1] == "あ",
    "anchorNeedles: a short sentence yields just itself")
check(SS.anchorNeedles("ページ跨ぎの文です続き", #"続き")[1] == "ページ跨ぎの文です",
    "anchorNeedles: the carried-over completion is trimmed first")

-- Annotated-copy needles: node-safe pieces only (crengine text search cannot
-- cross the text-node boundaries <ruby> introduces around kanji).
local an = SS.anchorNeedlesAnnotated("そして学校へ行った。", 0)
check(an[1] == "そして" and an[#an] == "そ",
    "annotated needles: the leading kana run, then the first character: "
        .. table.concat(an, "|"))
an = SS.anchorNeedlesAnnotated("学校へ行った。", 0,
    { { start = 0, len = #"学校", base = "学校", reading = "がっこう" } })
check(an[1] == "学校" and an[#an] == "学",
    "annotated needles: a kanji-led sentence uses its first run's base text: "
        .. table.concat(an, "|"))
an = SS.anchorNeedlesAnnotated("学校へ行った。", 0, nil)
check(#an == 1 and an[1] == "学",
    "annotated needles: without runs a kanji-led sentence falls to its first char")
an = SS.anchorNeedlesAnnotated("そして学校へ行った跡が続く", #"跡が続く")
check(an[1] == "そして", "annotated needles: the carried completion is trimmed first")

local rt_sel = {
    { start = "/body/p[1]/ruby[2]/rt/text().0" },
    { start = "/body/p[1]/ruby[2]/text().0" },
    { start = "/body/p[2]/text().4" },
    { start = "/body/p[3]/ruby/rtc/rt/text().1" },
}
local kept = SS.filterRtHits(rt_sel)
check(#kept == 2 and kept[1].start == "/body/p[1]/ruby[2]/text().0"
        and kept[2].start == "/body/p[2]/text().4",
    "filterRtHits drops hits inside rt/rtc readings, keeps base-text hits")

local ptext = "犬。猫。犬。"
local psents = { "犬。", "猫。", "犬。" }
local pos_list = SS.sentencePositions(ptext, psents, 0, 0)
check(pos_list[1] == 1 and pos_list[2] == #"犬。" + 1 and pos_list[3] == #"犬。猫。" + 1,
    "sentencePositions: sequential find locates repeated sentences in order")
check(SS.occurrenceIndex(ptext, "犬。", pos_list[3]) == 2
    and SS.occurrenceIndex(ptext, "犬。", 1) == 1,
    "occurrenceIndex counts non-overlapping earlier occurrences")
check(SS.sentenceIndexAt(pos_list, psents, 1) == 1
    and SS.sentenceIndexAt(pos_list, psents, pos_list[2]) == 2
    and SS.sentenceIndexAt(pos_list, psents, #ptext) == 3,
    "sentenceIndexAt maps byte offsets to their sentence")
local pos_skip = SS.sentencePositions("XX犬。猫。", { "犬。", "猫。" }, 2, 0)
check(pos_skip[1] == 3 and pos_skip[2] == 3 + #"犬。",
    "sentencePositions starts searching after the skipped carry head")

-- ===================== marker on the first character ======================

local marker_draws = {}
local orig_findText = doc.findText
local orig_boxes = doc.getScreenBoxesFromPositions
doc.getNextVisibleChar = function(_, xp) return xp .. "+" end
doc.getTextFromXPointers = function(_, a, b, draw)
    if draw then marker_draws[#marker_draws + 1] = { a, b } end
    return ""
end

pages[1] = page1
current_page = 1
ctrl:reset()
marker_draws = {}
ctrl:onKeyPress(fake_key("LPgFwd"))
check(#marker_draws >= 1 and marker_draws[#marker_draws][1] == "xp_hit_start"
    and marker_draws[#marker_draws][2] == "xp_hit_start+",
    "each step draws the marker on the sentence's first character")
check(ctrl._marker_dimen ~= nil, "the marker region is remembered for repaint")
pump()
ctrl:reset()
check(ctrl._marker_dimen == nil, "reset clears the marker")

-- ================== anchor fallback & disambiguation ======================

-- The full sentence can't be found in one piece (inline formatting): a
-- shortened prefix still anchors the popup.
local fmt_sent = "書式の入った長い文章です。"
pages[1] = fmt_sent .. "残り。"
doc.findText = function(_, pattern)
    find_calls[#find_calls + 1] = pattern
    if pattern == fmt_sent then return nil end
    return { { start = "xp_hit_start", ["end"] = "xp_hit_end" } }, 1
end
current_page = 1
ctrl:reset()
ctrl:onKeyPress(fake_key("LPgFwd"))
check(popups[#popups].anchor_box ~= nil,
    "an unfindable full sentence falls back to a prefix anchor (no bottom popup)")
check(find_calls[#find_calls] ~= fmt_sent,
    "…found via a shortened needle: " .. tostring(find_calls[#find_calls]))
pump()

-- A shortened needle occurring twice on the page anchors by occurrence.
pages[1] = "犬が好き。犬が好きだ。"
doc.findText = function(_, pattern)
    find_calls[#find_calls + 1] = pattern
    if pattern ~= "犬が好" then return nil end
    return {
        { start = "xp_first", ["end"] = "xp_first_end" },
        { start = "xp_second", ["end"] = "xp_second_end" },
    }, 2
end
local box_y = { xp_first = 100, xp_second = 300 }
doc.getScreenBoxesFromPositions = function(_, s0)
    return { { x = 50, y = box_y[s0] or 400, w = 200, h = 30 } }
end
current_page = 1
ctrl:reset()
ctrl:onKeyPress(fake_key("LPgFwd"))
check(popups[#popups].anchor_box.y == 100,
    "repeated needle: sentence 1 anchors at the first hit")
ctrl:onKeyPress(fake_key("LPgFwd"))
check(popups[#popups].anchor_box.y == 300,
    "repeated needle: sentence 2 anchors at its own (second) occurrence")
pump()
doc.findText = orig_findText
doc.getScreenBoxesFromPositions = orig_boxes

-- ====================== annotated furigana copy ===========================
-- pageText (stubbed here; the real one strips the ruby readings) is already
-- plain: stepping must work — the old guard refused annotated copies — and
-- the anchor search must use node-safe needles and skip hits inside <rt>.

ui.furigana.isShowingAnnotated = function() return true end
pages[1] = "今日は晴れ。明日も晴れ。"
current_page = 1
ctrl:stop()
find_calls = {}
local box_ranges = {}
local prev_boxes_fn = doc.getScreenBoxesFromPositions
doc.getScreenBoxesFromPositions = function(_, s0, s1)
    box_ranges[#box_ranges + 1] = { s0, s1 }
    return { { x = 100, y = 400, w = 300, h = 30 } }
end
ctrl:onKeyPress(fake_key("LPgFwd"))
check(ctrl.session ~= nil and ctrl.session.idx == 1 and ctrl.popup ~= nil,
    "annotated copy: stepping works (the original-book guard is gone)")
-- 今日は晴れ。 starts with the kanji 今; the fake tokenizer only annotates
-- 晴れ (a run that does not start the sentence), so the node-safe ladder is
-- just the first character.
check(find_calls[1] == "今",
    "annotated copy: the anchor search used a node-safe needle: "
        .. tostring(find_calls[1]))
-- The measured box extends from the 1-char needle to the sentence's end:
-- 5 more base characters plus the は reading = 6 visible-char steps, so the
-- popup clears the furigana above a leading kanji and never sits on the
-- sentence's remaining lines.
check(box_ranges[1] ~= nil
        and box_ranges[1][2] == "xp_hit_end" .. string.rep("+", 6),
    "annotated copy: the anchor box covers the whole sentence, readings included: "
        .. tostring(box_ranges[1] and box_ranges[1][2]))
pump()

-- A needle that first matches inside a reading: the rt hit is skipped and
-- the base-text hit anchors (without the filter the rt hit — on "page 99" —
-- would be rejected and the popup would fall to the bottom).
local orig_page_from_xp = doc.getPageFromXPointer
doc.findText = function(_, pattern)
    find_calls[#find_calls + 1] = pattern
    return {
        { start = "/body/p/ruby/rt/text().0", ["end"] = "xp_rt_end" },
        { start = "/body/p/text().2", ["end"] = "xp_base_end" },
    }, 2
end
doc.getPageFromXPointer = function(_, xp)
    return (type(xp) == "string" and xp:find("/rt/", 1, true)) and 99 or current_page
end
ctrl:stop()
ctrl:onKeyPress(fake_key("LPgFwd"))
check(popups[#popups].anchor_box ~= nil,
    "annotated copy: hits inside <rt> readings are skipped, base text anchors")
pump()
doc.findText = orig_findText
doc.getPageFromXPointer = orig_page_from_xp
doc.getScreenBoxesFromPositions = prev_boxes_fn
ui.furigana.isShowingAnnotated = function() return false end
ctrl:stop()

-- ======================= per-step action toggles ==========================

ctrl.tr_visible = true -- earlier scenarios hid the translation line

-- Audio off: stepping is silent and fetches nothing; an explicit double tap
-- still fetches and plays on demand.
settings.language_japanese_sentence_audio = false
pages[3] = "音声なしの文。"
current_page = 3
ctrl:stop()
local fetches_b4 = #fetched_texts
played_before = #played
ctrl:onKeyPress(fake_key("LPgFwd"))
pump(500)
check(#fetched_texts == fetches_b4 and #played == played_before,
    "audio toggled off: nothing is synthesized or played on step")
check(popup_text(popups[#popups]):find("音声なしの文。", 1, true) ~= nil,
    "…while the popup still shows")
popups[#popups].on_frame_tap()
popups[#popups].on_frame_tap()
pump(500)
check(#fetched_texts > fetches_b4 and #played > played_before,
    "audio off: a double tap still fetches and plays on demand")
settings.language_japanese_sentence_audio = nil

-- Japanese line off: only the translation shows in the popup.
settings.language_japanese_sentence_show_jp = false
pages[3] = "日本語非表示の文。"
current_page = 3
ctrl:stop()
ctrl:onKeyPress(fake_key("LPgFwd"))
check(popup_text(popups[#popups]) == "…",
    "JP line off: a placeholder holds the popup until the translation lands")
pump(500)
check(popup_text(popups[#popups]) == "EN:日本語非表示の文。",
    "JP line off: only the translation appears in the popup")
settings.language_japanese_sentence_show_jp = nil

-- Popup off: no bubble, but the marker still moves; with audio also off the
-- keys are a pure cursor and nothing at all is fetched.
settings.language_japanese_sentence_popup = false
pages[3] = "ポップアップなしの文。"
current_page = 3
ctrl:stop()
local pops_b4 = #popups
marker_draws = {}
ctrl:onKeyPress(fake_key("LPgFwd"))
pump(500)
check(#popups == pops_b4, "popup toggled off: no bubble is shown")
check(#marker_draws >= 1, "…but the marker still moves")
settings.language_japanese_sentence_audio = false
pages[3] = "カーソルのみの文。"
current_page = 3
ctrl:stop()
fetches_b4 = #fetched_texts
local tr_b4 = #tr_calls
ctrl:onKeyPress(fake_key("LPgFwd"))
pump(500)
check(#fetched_texts == fetches_b4 and #tr_calls == tr_b4,
    "pure cursor (popup+audio off): nothing is fetched at all")
settings.language_japanese_sentence_audio = nil
settings.language_japanese_sentence_popup = nil

-- ========================== double press ==================================

-- The pre-split single setting still works as a fallback for both keys.
settings.language_japanese_sentence_doublepress = "toggle"
local toggles = 0
plugin.onToggleSentenceSplitting = function() toggles = toggles + 1 end
pages[3] = "甲の文。乙の文。丙の文。"
current_page = 3
ctrl:stop()
pops_b4 = #popups
ctrl:onKeyPress(fake_key("LPgFwd"))
check(#popups == pops_b4,
    "with a double-press action configured, a single press is held back")
ctrl:onKeyPress(fake_key("LPgFwd"))
check(toggles == 1 and #popups == pops_b4,
    "a second press within the window fires the action instead of stepping")
pump(500)
check(#popups == pops_b4, "…and the held step never runs")
ctrl:onKeyPress(fake_key("LPgFwd"))
pump(500) -- the double-press window elapses
check(#popups > pops_b4 and popup_text(popups[#popups]):find("甲の文。", 1, true) ~= nil,
    "a lone press steps once the window passes")
pops_b4 = #popups
ctrl:onKeyPress(fake_key("LPgFwd"))
ctrl:onKeyPress(fake_key("LPgBack"))
check(#popups == pops_b4 + 1,
    "the other key flushes the held step immediately")
pump(500)
check(#popups == pops_b4 + 2,
    "…and then steps itself when its own window passes")
ctrl:onKeyPress(fake_key("LPgBack"))
ctrl:onKeyPress(fake_key("LPgBack"))
check(toggles == 2, "the legacy single setting applies to both keys")
pump(500)
settings.language_japanese_sentence_doublepress = nil
plugin.onToggleSentenceSplitting = nil

-- Per-key actions: each key has its own, and a key set to "none" steps
-- with no delay even while the other key has an action.
settings.language_japanese_sentence_doublepress_next = "replay"
pages[3] = "個別キーの文。次の文。"
current_page = 3
ctrl:stop()
ctrl:onKeyPress(fake_key("LPgFwd"))
pump(500) -- held (next key has an action), steps after the window
check(popup_text(popups[#popups]):find("個別キーの文。", 1, true) ~= nil,
    "per-key: the action key steps after its window")
pops_b4 = #popups
played_before = #played
ctrl:onKeyPress(fake_key("LPgFwd"))
ctrl:onKeyPress(fake_key("LPgFwd"))
pump(500)
check(#played == played_before + 1 and #popups == pops_b4,
    "per-key: double press on the next key replays instead of stepping")
pops_b4 = #popups
ctrl:onKeyPress(fake_key("LPgBack")) -- prev key has no action
check(#popups == pops_b4 + 1,
    "per-key: the plain key steps immediately (no double-press window)")
pump(500)
settings.language_japanese_sentence_doublepress_next = nil

-- "furigana" action: flips the popup's readings in place.
settings.language_japanese_sentence_doublepress_prev = "furigana"
pages[1] = page1
current_page = 1
ctrl:stop()
ctrl:onKeyPress(fake_key("LPgFwd")) -- next key plain: steps instantly
check(popup_text(popups[#popups]):find("晴（は）れ", 1, true) ~= nil,
    "furigana action: the sentence starts with readings on")
ctrl:onKeyPress(fake_key("LPgBack"))
ctrl:onKeyPress(fake_key("LPgBack"))
pump(500)
check(settings.language_japanese_sentence_furigana == false
        and popup_text(popups[#popups]):find("晴（は）れ", 1, true) == nil
        and popup_text(popups[#popups]):find("今日は晴れ。", 1, true) ~= nil,
    "double press flips the furigana off and refreshes the shown popup")
ctrl:onKeyPress(fake_key("LPgBack"))
ctrl:onKeyPress(fake_key("LPgBack"))
pump(500)
check(settings.language_japanese_sentence_furigana == nil
        and popup_text(popups[#popups]):find("晴（は）れ", 1, true) ~= nil,
    "a further double press brings the readings back")
settings.language_japanese_sentence_doublepress_prev = nil

-- "popup" action: summons the bubble on demand while the per-step popup is
-- off, and dismisses it again.
settings.language_japanese_sentence_popup = false
settings.language_japanese_sentence_doublepress_next = "popup"
pages[3] = "要求ポップアップの文。"
current_page = 3
ctrl:stop()
ctrl:onKeyPress(fake_key("LPgBack")) -- prev key plain: steps instantly
pops_b4 = #popups
check(ctrl.popup == nil, "per-step popup off: stepping shows no bubble")
ctrl:onKeyPress(fake_key("LPgFwd"))
ctrl:onKeyPress(fake_key("LPgFwd"))
check(ctrl.popup ~= nil and #popups == pops_b4 + 1
        and popup_text(popups[#popups]):find("要求ポップアップの文。", 1, true) ~= nil,
    "double press summons the current sentence's popup on demand")
pump(500)
check(popup_text(popups[#popups]):find("EN:要求ポップアップの文。", 1, true) ~= nil,
    "…and its translation is fetched and swapped in even in cursor mode")
ctrl:onKeyPress(fake_key("LPgFwd"))
ctrl:onKeyPress(fake_key("LPgFwd"))
pump(500)
check(ctrl.popup == nil, "a second double press dismisses the summoned popup")
settings.language_japanese_sentence_doublepress_next = nil
settings.language_japanese_sentence_popup = nil

-- ======================= start at a byte offset ===========================

pages[1] = "一文目。二文目。三文目。"
current_page = 1
ctrl:stop()
ctrl:startAt(#"一文目。" + 2) -- a byte inside the second sentence
check(ctrl.session ~= nil and ctrl.session.idx == 2
    and popup_text(popups[#popups]):find("二文目。", 1, true) ~= nil,
    "startAt lands on the sentence containing the byte offset")
pump()

-- ================= popup text selection → dictionary ======================

local dict_lookups = {}
ui.dictionary = {
    onLookupWord = function(_, word, is_sane)
        dict_lookups[#dict_lookups + 1] = { word = word, is_sane = is_sane }
    end,
}
popups[#popups].on_text_select("  二文目 ")
check(dict_lookups[1] ~= nil and dict_lookups[1].word == "二文目",
    "text selected on the popup's translation line is cleaned and looked up")

-- ============ hold on the Japanese line: page-equivalent lookup ===========
-- A single hold runs the Yomichan expansion on the plain sentence at the
-- held byte offset (deinflect every prefix, one batched sdcv, keep the
-- longest hit), then a normal (is_sane=false) lookup — same as the page.

local sdcv_batches = {}
local sdcv_hits = {} -- term -> true means the "dictionary" knows it
plugin.deinflector = {
    deinflect = function(_, surface)
        -- surface itself, plus a fake deinflection for た-forms
        local cands = { { term = surface } }
        local stem = surface:match("^(.-)た$")
        if stem and stem ~= "" then cands[#cands + 1] = { term = stem .. "る" } end
        return cands
    end,
}
plugin.dictionary = {
    rawSdcv = function(_, words)
        sdcv_batches[#sdcv_batches + 1] = words
        local results = {}
        for i, w in ipairs(words) do
            results[i] = sdcv_hits[w] and { { definition = "def of " .. w } } or {}
        end
        return false, results
    end,
}
plugin.max_scan_length = 20

-- 晴れた at offset of 晴: candidates 晴れ / 晴れた (+ deinflected 晴れる);
-- the dictionary knows 晴れる, so the surface 晴れた wins (longest hit).
sdcv_hits = { ["晴れる"] = true }
dict_lookups = {}
local hold_plain = "今日は晴れた。"
popups[#popups].on_word_lookup(hold_plain, #"今日は", "晴", true)
check(#sdcv_batches == 1 and #dict_lookups == 1
        and dict_lookups[1].word == "晴れた" and dict_lookups[1].is_sane == false,
    "a hold expands to the longest dictionary-known surface, like on the page: "
        .. tostring(dict_lookups[1] and dict_lookups[1].word))

-- No dictionary hit at all: fall back to the held atom's own text.
sdcv_hits = {}
dict_lookups = {}
popups[#popups].on_word_lookup(hold_plain, #"今日は", "晴", true)
check(#dict_lookups == 1 and dict_lookups[1].word == "晴"
        and dict_lookups[1].is_sane == false,
    "with no dictionary hit the held word itself is looked up")

-- The scan stops at punctuation: a hold on the last word before 。 can only
-- try up to it.
sdcv_hits = { ["れた"] = true }
dict_lookups = {}
sdcv_batches = {}
popups[#popups].on_word_lookup(hold_plain, #"今日は晴", "れ", true)
local scanned_past_end = false
for _, w in ipairs(sdcv_batches[1] or {}) do
    if w:find("。", 1, true) then scanned_past_end = true end
end
check(not scanned_past_end and dict_lookups[1] and dict_lookups[1].word == "れた",
    "the expansion scan stops at sentence punctuation")

-- A dragged (multi-atom) selection skips the expansion and is looked up as
-- selected.
dict_lookups = {}
sdcv_batches = {}
popups[#popups].on_word_lookup(hold_plain, 0, " 今日は晴れた ", false)
check(#sdcv_batches == 0 and dict_lookups[1]
        and dict_lookups[1].word == "今日は晴れた" and dict_lookups[1].is_sane == false,
    "a dragged selection is cleaned and looked up without expansion")

-- ================= ruby size follows the style tweaks =====================

ui.styletweak = {
    enabled = true, -- the master "Enable style tweaks" switch
    tweaks_by_id = {
        ruby_font_size_larger = { css = "rt, rubyBox[T=rt] { font-size: 50% !important; }" },
        some_other = { css = "p { font-size: 80%; }" },
    },
    isTweakEnabled = function(_, id) return id == "ruby_font_size_larger" end,
}
pages[1] = "一文目。二文目。三文目。"
current_page = 1
ctrl:stop()
ctrl:onKeyPress(fake_key("LPgFwd"))
check(popups[#popups].ruby_scale == 0.5,
    "with 'Larger ruby text size' enabled the popup ruby follows it (50%)")
-- The master switch off = the book renders default ruby; so does the popup.
ui.styletweak.enabled = false
ctrl:stop()
ctrl:onKeyPress(fake_key("LPgFwd"))
check(popups[#popups].ruby_scale == 0.42,
    "with the master style-tweaks switch off the popup keeps the 42% default")
ui.styletweak = nil
pump()

-- ============== double tap on the left eighth dismisses ===================

ctrl:onKeyPress(fake_key("LPgFwd"))
check(ctrl.popup ~= nil, "a popup is up")
played_before = #played
popups[#popups].on_frame_tap(true)
popups[#popups].on_frame_tap(true)
check(ctrl.popup == nil and #played == played_before,
    "a double tap on the left eighth dismisses the popup without replaying")
ctrl:onKeyPress(fake_key("LPgFwd"))
played_before = #played
popups[#popups].on_frame_tap(true)
popups[#popups].on_frame_tap(false) -- second tap elsewhere: a normal double tap
pump()
check(ctrl.popup ~= nil and #played == played_before + 1,
    "left + elsewhere still counts as a replay double tap")
pump()

-- ======================= local translator first ===========================

local local_calls = {}
local local_fail = false
package.preload["localtranslator"] = function()
    return {
        translate = function(opts, text)
            local_calls[#local_calls + 1] = { url = opts.url, text = text }
            if local_fail then return nil, "down" end
            return "LOCAL:" .. text
        end,
    }
end
plugin.localTranslatorOpts = function()
    return { url = "http://loc:8087" }
end
pages[3] = "ローカル翻訳の文。"
current_page = 3
ctrl:stop()
local tr_google_b4 = #tr_calls
ctrl:onKeyPress(fake_key("LPgFwd"))
pump(500)
check(#local_calls >= 1 and local_calls[1].url == "http://loc:8087",
    "the local translator is tried first for sentence translations")
check(#tr_calls == tr_google_b4, "…Google is not called when it succeeds")
check(popup_text(popups[#popups]):find("LOCAL:ローカル翻訳の文。", 1, true) ~= nil,
    "…and its translation lands in the popup")

local_fail = true
pages[3] = "フォールバックの文。"
current_page = 3
ctrl:stop()
ctrl:onKeyPress(fake_key("LPgFwd"))
pump(500)
check(popup_text(popups[#popups]):find("EN:フォールバックの文。", 1, true) ~= nil,
    "local server down: the Google fallback still translates")
local_fail = false

net.online = false
pages[3] = "オフラインローカルの文。"
current_page = 3
ctrl:stop()
ctrl:onKeyPress(fake_key("LPgFwd"))
pump(500)
check(popup_text(popups[#popups]):find("LOCAL:オフラインローカルの文。", 1, true) ~= nil,
    "offline with the local translator: translations keep working")
net.online = true
plugin.localTranslatorOpts = nil

-- ================== stale fetches are preempted ===========================
-- Make subprocesses hang (their work runs only when released), so a step
-- onto a new sentence finds the previous sentence's fetches still in flight.
local ffistub = stubs["ffi/util"]
local orig_run = ffistub.runInSubProcess
local orig_done = ffistub.isSubProcessDone
local orig_term = ffistub.terminateSubProcess
local pending_procs = {} -- pid -> deferred subprocess body
local killed = {}
ffistub.runInSubProcess = function(fn)
    subprocess_pid = subprocess_pid + 1
    pending_procs[subprocess_pid] = fn
    return subprocess_pid
end
ffistub.isSubProcessDone = function(pid) return pending_procs[pid] == nil end
ffistub.terminateSubProcess = function(pid)
    killed[#killed + 1] = pid
    pending_procs[pid] = nil -- killed: its work never lands
end

pages[1] = "早い文。二番目の文。三番目の文。"
current_page = 1
ctrl:stop()
ctrl:onKeyPress(fake_key("LPgFwd"))
check(ctrl.fetch_wav ~= nil and ctrl.fetch_wav.text == "早い文。"
        and ctrl.fetch_tr ~= nil and ctrl.fetch_tr.text == "早い文。",
    "audio and translation fetch in parallel lanes, current sentence first")
ctrl:onKeyPress(fake_key("LPgFwd")) -- step on before anything landed
check(ctrl.fetch_wav ~= nil and ctrl.fetch_wav.text == "二番目の文。"
        and ctrl.fetch_tr ~= nil and ctrl.fetch_tr.text == "二番目の文。",
    "stepping preempts the stale fetches: both lanes serve the new sentence")
check(#killed == 2, "the skipped sentence's subprocesses were killed")
check((ctrl.wav_tries["早い文。"] or 0) == 0 and (ctrl.tr_tries["早い文。"] or 0) == 0,
    "the aborted sentence's tries were refunded (abandoned, not failed)")
-- Release the in-flight work and let the lookahead drain.
for _ = 1, 30 do
    local pid, fn = next(pending_procs)
    if not pid then break end
    fn(pid)
    pending_procs[pid] = nil
    pump(500)
end
check(popup_text(popups[#popups]):find("EN:二番目の文。", 1, true) ~= nil,
    "the current sentence's translation lands (never queued behind stale work)")
ctrl:stop()
ffistub.runInSubProcess = orig_run
ffistub.isSubProcessDone = orig_done
ffistub.terminateSubProcess = orig_term

-- toggle off restores the keys
ctrl:applyKeys(false)
check(ui.rolling.key_events.GotoNextView.is_inactive == nil
    and ui.rolling.key_events.GotoPrevView.is_inactive == nil,
    "applyKeys(false) reactivates the page-turn bindings")

-- stop() prunes the translation cache to the keep limit
local tr_dir = TMP .. "/cache/japanese_sentences"
os.execute("mkdir -p '" .. tr_dir .. "'")
for i = 1, SS.KEEP_TRANSLATIONS + 25 do
    local f = io.open(tr_dir .. "/extra" .. i .. ".txt", "w")
    f:write("x")
    f:close()
end
ctrl:stop()
local count = 0
local p = io.popen("ls '" .. tr_dir .. "' | wc -l")
count = tonumber(p:read("*a"))
p:close()
check(count == SS.KEEP_TRANSLATIONS,
    "stop() trims the translation cache to KEEP_TRANSLATIONS files")
check(ctrl.popup == nil and ctrl.session == nil, "stop() clears popup and session")

-- ------------------------------------------------------------------ report --

print(failures == 0 and "ALL TESTS PASSED" or (failures .. " TEST(S) FAILED"))
os.exit(failures == 0 and 0 or 1)
