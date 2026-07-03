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

-- ---------------------------------------------------------- rubyDisplay --

check(SS.rubyDisplay("<ruby>漢字<rt>かんじ</rt></ruby>を書く。", "漢字を書く。")
    == "漢字（かんじ）を書く。", "rubyDisplay splices readings into the sentence")
check(SS.rubyDisplay("ひらがなだけ。", "ひらがなだけ。") == "ひらがなだけ。",
    "rubyDisplay returns kana-only sentences unchanged")
check(SS.rubyDisplay("<ruby>違<rt>ちが</rt></ruby>う", "別のテキスト") == nil,
    "rubyDisplay refuses a round-trip mismatch")

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
check(#popups == 1 and popups[1].text == "今日は晴（は）れ。",
    "first press shows the page's first sentence with furigana spliced in")
local a = popups[1].anchor_box
check(a ~= nil and a.x == 100 and a.y == 400 and a.w == 300 and a.h == 60,
    "the popup is anchored to the union of the sentence's line boxes")
check(find_calls[1] == "今日は晴れ。" and clear_calls >= 1,
    "the anchor search used the bare sentence text and cleared the selection")
check(ctrl:onKeyPress(fake_key("Home")) == nil, "unrelated keys are not consumed")

pump()
check(played[1] ~= nil and played[1]:match("%.wav$") ~= nil,
    "the first sentence's audio was synthesized and played")
check(#popups >= 2 and popups[#popups].text:find("EN:今日は晴れ。", 1, true) ~= nil,
    "the translation is swapped into the popup when it lands")
check(popups[#popups].text:find("晴（は）れ", 1, true) ~= nil,
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
check(popups[#popups].text:find("明日は雨が降るかもしれない。", 1, true) ~= nil
    and popups[#popups].text:find("EN:明日は", 1, true) ~= nil,
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
    and popups[#popups].text:find("EN:", 1, true) == nil
    and popups[#popups].text:find("明日は雨が降るかも", 1, true) ~= nil,
    "a single tap hides the translation line without replaying")
popups[#popups].on_frame_tap()
popups[#popups].on_frame_tap() -- second tap within the window
pump()
check(#played == played_before + 1, "a double tap replays the audio")
check(popups[#popups].text:find("EN:", 1, true) == nil,
    "a double tap does not toggle the translation")
popups[#popups].on_frame_tap()
pump()
check(popups[#popups].text:find("EN:明日は", 1, true) ~= nil,
    "a further single tap reveals the cached translation again")

-- third press: past the page's last sentence -> page flip, carry skipped
ctrl:onKeyPress(fake_key("LPgFwd"))
check(current_page == 2, "stepping past the last sentence turns the page")
check(ctrl.session ~= nil and ctrl.session.page == 2 and ctrl.session.idx == 1,
    "the session moved to the new page (self-caused flip kept it)")
check(popups[#popups].text:find("次の文。", 1, true) ~= nil,
    "the carried-over bytes are skipped: page 2 starts at its own sentence")
pump()

-- previous at the first sentence: back to page 1, its last sentence
ctrl:onKeyPress(fake_key("LPgBack"))
check(current_page == 1, "stepping back before the first sentence turns back")
check(ctrl.session.idx == 2
    and popups[#popups].text:find("明日は雨が降るかも", 1, true) ~= nil,
    "landing on the previous page's last sentence")
pump()

-- a page change we didn't cause resets the session
current_page = 3
plugin:onPageUpdate(3)
check(ctrl.session == nil, "manual navigation drops the session")
ctrl:onKeyPress(fake_key("LPgFwd"))
check(ctrl.session ~= nil and ctrl.session.page == 3
    and popups[#popups].text:find("三ページ目の文。", 1, true) ~= nil,
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
check(popups[#popups].text:find("EN:", 1, true) == nil,
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
    and popups[#popups].text:find("EN:", 1, true) ~= nil,
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
check(popups[#popups].text:find("EN:今日は晴れ。", 1, true) ~= nil,
    "translation is visible again on a fresh sentence (from cache)")
popups[#popups].on_frame_tap()
pump()
ctrl:onKeyPress(fake_key("LPgFwd"))
check(popups[#popups].text:find("EN:", 1, true) == nil,
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
check(popups[#popups].text:find("音声なしの文。", 1, true) ~= nil,
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
check(popups[#popups].text == "…",
    "JP line off: a placeholder holds the popup until the translation lands")
pump(500)
check(popups[#popups].text == "EN:日本語非表示の文。",
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
check(#popups > pops_b4 and popups[#popups].text:find("甲の文。", 1, true) ~= nil,
    "a lone press steps once the window passes")
pops_b4 = #popups
ctrl:onKeyPress(fake_key("LPgFwd"))
ctrl:onKeyPress(fake_key("LPgBack"))
check(#popups == pops_b4 + 1,
    "the other key flushes the held step immediately")
pump(500)
check(#popups == pops_b4 + 2,
    "…and then steps itself when its own window passes")
settings.language_japanese_sentence_doublepress = nil
plugin.onToggleSentenceSplitting = nil

-- ======================= start at a byte offset ===========================

pages[1] = "一文目。二文目。三文目。"
current_page = 1
ctrl:stop()
ctrl:startAt(#"一文目。" + 2) -- a byte inside the second sentence
check(ctrl.session ~= nil and ctrl.session.idx == 2
    and popups[#popups].text:find("二文目。", 1, true) ~= nil,
    "startAt lands on the sentence containing the byte offset")
pump()

-- ================= popup text selection → dictionary ======================

local dict_lookups = {}
ui.dictionary = {
    onLookupWord = function(_, word) dict_lookups[#dict_lookups + 1] = word end,
}
popups[#popups].on_text_select("  二文目 ")
check(dict_lookups[1] == "二文目",
    "text selected on the popup is cleaned and looked up in the dictionary")

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
check(popups[#popups].text:find("LOCAL:ローカル翻訳の文。", 1, true) ~= nil,
    "…and its translation lands in the popup")

local_fail = true
pages[3] = "フォールバックの文。"
current_page = 3
ctrl:stop()
ctrl:onKeyPress(fake_key("LPgFwd"))
pump(500)
check(popups[#popups].text:find("EN:フォールバックの文。", 1, true) ~= nil,
    "local server down: the Google fallback still translates")
local_fail = false

net.online = false
pages[3] = "オフラインローカルの文。"
current_page = 3
ctrl:stop()
ctrl:onKeyPress(fake_key("LPgFwd"))
pump(500)
check(popups[#popups].text:find("LOCAL:オフラインローカルの文。", 1, true) ~= nil,
    "offline with the local translator: translations keep working")
net.online = true
plugin.localTranslatorOpts = nil

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
