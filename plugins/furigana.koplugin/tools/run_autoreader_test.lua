-- Tests for autoreader.lua: sentence splitting / page-boundary carry (pure),
-- and the controller's play→advance→flip→stop pipeline against a stubbed
-- KOReader runtime (scheduler pumped manually, subprocesses run inline).
-- Pure Lua:  lua tools/run_autoreader_test.lua

local here = arg[0]:match("^(.*)/[^/]*$") or "."
package.path = here .. "/../?.lua;" .. package.path

local failures = 0
local function check(cond, msg)
    if cond then
        print("ok   - " .. msg)
    else
        failures = failures + 1
        print("FAIL - " .. msg)
    end
end

-- ----------------------------------------------------------------- stubs --

local queue = {}   -- scheduled callbacks, FIFO (delays ignored)
local shown = {}   -- InfoMessages
local standby = { prevented = 0, allowed = 0 }
local UIManager = {
    scheduleIn = function(_, t, fn) queue[#queue + 1] = fn end,
    unschedule = function(_, fn)
        for i = #queue, 1, -1 do
            if queue[i] == fn then table.remove(queue, i) end
        end
    end,
    show = function(_, w) shown[#shown + 1] = w end,
    nextTick = function(_, fn) queue[#queue + 1] = fn end,
    preventStandby = function() standby.prevented = standby.prevented + 1 end,
    allowStandby = function() standby.allowed = standby.allowed + 1 end,
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

local played = {}          -- wav paths handed to the player
local player_stopped = 0
local fetch_results = nil  -- nil: succeed; false: fail
local fetched_texts = {}

local subprocess_pid = 100
local stubs = {
    ["ui/uimanager"] = UIManager,
    ["gettext"] = gettext,
    ["ui/event"] = { new = function(_, name, arg) return { name = name, arg = arg } end },
    ["ui/widget/infomessage"] = { new = function(_, o) return o end },
    ["device"] = { isAndroid = function() return false end },
    ["logger"] = { dbg = function() end, info = function() end, warn = function() end, err = function() end },
    ["util"] = { makePath = function(d) os.execute("mkdir -p '" .. d .. "'") end },
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
        stop = function() player_stopped = player_stopped + 1 end,
        wavDurationSeconds = function() return 0.5 end,
    },
    ["voicevox"] = {
        fetch = function(opts, text, out)
            fetched_texts[#fetched_texts + 1] = text
            if fetch_results == false then return nil, "boom" end
            local f = io.open(out, "w")
            f:write("RIFF" .. text)
            f:close()
            return true
        end,
    },
}
for name, mod in pairs(stubs) do
    package.preload[name] = function() return mod end
end

local AutoReader = require("autoreader")
local Precache = require("precache")

-- ---------------------------------------------------------- splitSentences --

local sents, incomplete = AutoReader.splitSentences("今日は晴れ。明日は雨。")
check(#sents == 2 and sents[1] == "今日は晴れ。" and sents[2] == "明日は雨。" and not incomplete,
    "plain sentences split at 。")

sents = AutoReader.splitSentences("「やめろ！」と叫んだ。")
check(#sents == 1 and sents[1] == "「やめろ！」と叫んだ。",
    "a quote runs through its 」 and on to the sentence end: " .. table.concat(sents, "|"))

sents = AutoReader.splitSentences("「こんにちは。元気？」と彼は言った。次の文。")
check(#sents == 2 and sents[1] == "「こんにちは。元気？」と彼は言った。"
        and sents[2] == "次の文。",
    "terminators inside 「…」 do not split the sentence: " .. table.concat(sents, "|"))

sents = AutoReader.splitSentences("彼は『まさか。噓だろ。』とつぶやいた。")
check(#sents == 1 and sents[1] == "彼は『まさか。噓だろ。』とつぶやいた。",
    "『…』 is tracked like 「…」: " .. table.concat(sents, "|"))

sents = AutoReader.splitSentences("「外だ。『中よ。』まだ外。」おわり。")
check(#sents == 1 and sents[1] == "「外だ。『中よ。』まだ外。」おわり。",
    "nested quotes keep their depth: " .. table.concat(sents, "|"))

sents = AutoReader.splitSentences("「あいさつ。」")
check(#sents == 1 and sents[1] == "「あいさつ。」",
    "a quote that is the whole sentence stays one unit: " .. table.concat(sents, "|"))

-- Closed quotes as complete sentences (the page-boundary merge fix): a
-- terminator-closed quote ends the sentence before another opening quote, a
-- newline, or the end of the text — but never before continuing narration.
local _, closed_incomplete = AutoReader.splitSentences("「あいさつ。」")
check(closed_incomplete == false,
    "a terminator-closed quote ending the text is complete (no page carry)")

local _, bare_incomplete = AutoReader.splitSentences("「あいさつ」")
check(bare_incomplete == false,
    "a closed quote ending the text is complete even without 。 before 」")

sents = AutoReader.splitSentences("「文一。」「文二。」")
check(#sents == 2 and sents[1] == "「文一。」" and sents[2] == "「文二。」",
    "back-to-back terminator-closed quotes split apart: " .. table.concat(sents, "|"))

sents = AutoReader.splitSentences("「あ。」　「い。」")
check(#sents == 2 and sents[1] == "「あ。」" and sents[2] == "「い。」",
    "an ideographic space between closed quotes is looked through: " .. table.concat(sents, "|"))

sents = AutoReader.splitSentences("彼の言う「自由」「平等」は建前だ。")
check(#sents == 1 and sents[1] == "彼の言う「自由」「平等」は建前だ。",
    "quotes without an inner terminator never split mid-sentence: " .. table.concat(sents, "|"))

sents = AutoReader.splitSentences("「外だ。『中よ。』」「次。」")
check(#sents == 2 and sents[1] == "「外だ。『中よ。』」" and sents[2] == "「次。」",
    "piled-up closers scan back to the terminator: " .. table.concat(sents, "|"))

sents = AutoReader.splitSentences("「そうだ」と言った。")
check(#sents == 1 and sents[1] == "「そうだ」と言った。",
    "a terminator-less quote before narration keeps the sentence whole: " .. table.concat(sents, "|"))

local q_sents, q_incomplete = AutoReader.splitSentences("「開いたまま\n次の段落。")
check(#q_sents == 2 and q_sents[1] == "「開いたまま" and q_sents[2] == "次の段落。"
        and not q_incomplete,
    "a newline still splits (and resets) an unclosed quote: " .. table.concat(q_sents, "|"))

local _, q_open_incomplete, q_depth = AutoReader.splitSentences("彼は「こんにちは。")
check(q_open_incomplete == true and q_depth == 1,
    "text ending inside a quote is incomplete with its open depth reported")

sents = AutoReader.splitSentences("閉じ」だけ。次。")
check(#sents == 2 and sents[1] == "閉じ」だけ。" and sents[2] == "次。",
    "a stray closing 」 without an opener does not suppress sentence ends")

sents = AutoReader.splitSentences("そうだ……。それで？")
check(#sents == 2 and sents[1] == "そうだ……。" and sents[2] == "それで？",
    "terminator runs (……。) are consumed whole: " .. table.concat(sents, "|"))

sents, incomplete = AutoReader.splitSentences("一行目\n二行目。")
check(#sents == 2 and sents[1] == "一行目" and not incomplete,
    "newlines (paragraph ends) terminate sentences")

sents, incomplete = AutoReader.splitSentences("これは途中")
check(#sents == 1 and sents[1] == "これは途中" and incomplete == true,
    "text running out mid-sentence is flagged incomplete")

sents = AutoReader.splitSentences("3.5キロ走った。")
check(#sents == 1 and sents[1] == "3.5キロ走った。",
    "ASCII decimal points do not split: " .. table.concat(sents, "|"))

sents = AutoReader.splitSentences("OK. そうだ。")
check(#sents == 2 and sents[1] == "OK." and sents[2] == "そうだ。",
    "ASCII sentence end before a space splits")

sents = AutoReader.splitSentences("※※※\nテスト。")
check(#sents == 1 and sents[1] == "テスト。",
    "punctuation-only lines are dropped (nothing to speak)")

sents = AutoReader.splitSentences("　全角空白で始まる。")
check(sents[1] == "全角空白で始まる。", "full-width spaces are trimmed")

-- capLength: over-long sentences re-split at a comma.
local long = ("あ"):rep(50) .. "、" .. ("い"):rep(70)
local pieces = AutoReader.capLength(long, 300)
check(#pieces == 2 and pieces[1] == ("あ"):rep(50) .. "、" and pieces[2] == ("い"):rep(70),
    "capLength splits at the last comma before the limit")
pieces = AutoReader.capLength(("う"):rep(120), 300)
check(#pieces == 2 and pieces[1] == ("う"):rep(100) and pieces[2] == ("う"):rep(20),
    "capLength hard-cuts at a character boundary when there is no comma")

-- ----------------------------------------------------------- chunkSentence --

-- A short sentence stays a single chunk (nothing to gain from splitting).
local ch = AutoReader.chunkSentence("今日はいい天気。")
check(#ch == 1 and ch[1] == "今日はいい天気。",
    "short sentence is one chunk: " .. table.concat(ch, "|"))

-- A long sentence is broken after commas (each clause ≥ CHUNK_MIN_BYTES).
ch = AutoReader.chunkSentence("今日はとても天気がよくて、みんなで公園に集まって、お弁当を食べました。")
check(#ch == 3
        and ch[1] == "今日はとても天気がよくて、"
        and ch[2] == "みんなで公園に集まって、"
        and ch[3] == "お弁当を食べました。",
    "long sentence is split into clause chunks at commas: " .. table.concat(ch, "|"))

-- A comma too early to be worth a chunk does not fragment the sentence.
ch = AutoReader.chunkSentence("あ、" .. ("か"):rep(20) .. "。")
check(#ch == 1, "a comma before CHUNK_MIN_BYTES does not split: " .. table.concat(ch, "|"))

-- A tiny trailing clause is merged back into the previous chunk.
ch = AutoReader.chunkSentence(("か"):rep(15) .. "、" .. "ね。")
check(#ch == 1 and ch[1] == ("か"):rep(15) .. "、ね。",
    "a sub-minimum tail is merged into the previous chunk: " .. table.concat(ch, "|"))

-- Concatenated, the chunks preserve the sentence exactly (no dropped chars).
local original = "はじめましてこんにちは、よろしくお願いいたします、それではまた会いましょう。"
ch = AutoReader.chunkSentence(original)
check(table.concat(ch) == original and #ch >= 2,
    "chunks reassemble to the original sentence: " .. table.concat(ch, "|"))

-- ------------------------------------------------------------ sentenceHead --

local head, consumed = AutoReader.sentenceHead("途中」。残り")
check(head == "途中」。" and consumed == 12,
    "sentenceHead returns the first sentence end (closers included): "
        .. tostring(head) .. "/" .. tostring(consumed))
head, consumed = AutoReader.sentenceHead("続き\n新段落。")
check(head == "続き" and consumed == 7,
    "sentenceHead stops at a paragraph break and consumes the newline")
check(AutoReader.sentenceHead("まだまだ続く", 6) == nil,
    "sentenceHead gives nil when no sentence end is in range")
-- A sentence cut inside a 「…」 carries its open depth into the next page:
-- the 。 inside the still-open quote must not end the head early.
head = AutoReader.sentenceHead("元気？」と言った。続き。", nil, 1)
check(head == "元気？」と言った。",
    "sentenceHead honors carried-in quote depth: " .. tostring(head))
head, consumed = AutoReader.sentenceHead("そうだ。」「おい。」と続けた。", nil, 1)
check(head == "そうだ。」" and consumed == #"そうだ。」",
    "a carried quote completed by 。」 stops before the next quote: " .. tostring(head))
head = AutoReader.sentenceHead("」と言った。次。", nil, 1)
check(head == "」と言った。",
    "a bare leading closer keeps scanning (its terminator sat on the previous page): "
        .. tostring(head))
head, consumed = AutoReader.sentenceHead("逃げろ」", nil, 1)
check(head == "逃げろ」" and consumed == #"逃げろ」",
    "a carried quote closing bare at the very end of the text completes there: "
        .. tostring(head))
head = AutoReader.sentenceHead("逃げろ」と続く", nil, 1)
check(head == nil,
    "…but not when text continues after the bare closer (no sentence end yet)")
head = AutoReader.sentenceHead("元気？」と言った。続き。", nil, 0)
check(head == "元気？」",
    "…without carried depth the same head ends right after the closer: "
        .. tostring(head))

check(AutoReader.estimateDuration("") >= 1 and AutoReader.estimateDuration(("あ"):rep(1000)) <= 30,
    "duration estimate is clamped to sane bounds")

-- -------------------------------------------------------------- controller --

local root = os.tmpname()
os.remove(root)
os.execute("mkdir -p '" .. root .. "'")

-- A two-page book whose page-1 text ends mid-sentence.
local pages = {
    [1] = "今日はいい天気。明日は",
    [2] = "雨になる。終わり。",
}
local doc = { cur = 1 }
function doc:getCurrentPage() return self.cur end
function doc:getPageCount() return 2 end

local flips = 0
local presched = 0
local fg_locks = {}
local plugin
local controller
plugin = {
    cache_dir = root,
    autoreader = nil,
    _precache = {
        setForegroundFetch = function(_, active) fg_locks[#fg_locks + 1] = active end,
    },
    precacheSchedule = function() presched = presched + 1 end,
    isShowingAnnotated = function() return false end,
    voicevoxOpts = function() return { url = "http://x", speaker = 3 } end,
    pageText = function(_, page) return pages[page] end,
    ui = {
        rolling = {},
        document = doc,
        handleEvent = function(_, ev)
            if ev.name == "GotoViewRel" then
                flips = flips + 1
                doc.cur = doc.cur + 1
                -- mimic the PageUpdate cascade a real turn produces
                controller:onPageUpdate(doc.cur)
            end
        end,
    },
}

controller = AutoReader.newController(plugin)
check(controller:isActive() == false, "controller starts inactive")

controller:start()
check(controller:isActive() == true and standby.prevented == 1,
    "start activates and holds off standby")
pump()
check(controller:isActive() == false, "reading ran to the end of the book and stopped")

local texts = {}
for _, p in ipairs(played) do
    texts[#texts + 1] = p
end
check(#played == 3, "three sentences were played: " .. #played)
local key1 = Precache.audioKey("http://x", 3, "今日はいい天気。")
local key2 = Precache.audioKey("http://x", 3, "明日は雨になる。")
local key3 = Precache.audioKey("http://x", 3, "終わり。")
check(played[1] and played[1]:match(key1 .. "%.wav$") ~= nil,
    "first sentence: page 1's first sentence")
check(played[2] and played[2]:match(key2 .. "%.wav$") ~= nil,
    "page-spanning sentence is completed with the next page's beginning")
check(played[3] and played[3]:match(key3 .. "%.wav$") ~= nil,
    "page 2 continues after the carried text, not from its top")
check(flips == 1 and doc.cur == 2, "exactly one automatic page turn happened")
check(standby.allowed == 1 and player_stopped >= 1 and presched >= 1,
    "stop releases standby, stops audio, re-kicks the precache")
check(fg_locks[1] == true and fg_locks[#fg_locks] == false,
    "the precache pause lock is held during the session and released after")
local end_msg = false
for _, w in ipairs(shown) do
    if type(w.text) == "string" and w.text:match("end of book") then end_msg = true end
end
check(end_msg, "the user is told the book is finished")

-- Cached sentences: a fresh session over the same pages refetches nothing.
doc.cur = 1
played, fetched_texts, shown = {}, {}, {}
controller:start()
pump()
check(#played == 3 and #fetched_texts == 0,
    "second session reuses the cached sentence audio (no synthesis)")

-- Manual navigation stops the session.
doc.cur = 1
played, shown = {}, {}
controller:start()
controller:onPageUpdate(5) -- user jumped somewhere
check(controller:isActive() == false, "a page change we did not cause stops the reader")
pump() -- drain

-- A single chunk that won't synthesize is skipped; reading continues.
os.execute("rm -rf '" .. root .. "/audio'")
pages = { [1] = "一つ目。二つ目。三つ目。", [2] = "" }
doc.cur = 1
played, fetched_texts, shown = {}, {}, {}
local fail_only = Precache.audioKey("http://x", 3, "二つ目。")
fetch_results = nil
local real_fetch = stubs["voicevox"].fetch
stubs["voicevox"].fetch = function(opts, text, out)
    fetched_texts[#fetched_texts + 1] = text
    if text == "二つ目。" then return nil, "boom" end -- only this chunk fails
    local f = io.open(out, "w"); f:write("RIFF" .. text); f:close()
    return true
end
controller:start()
pump()
check(controller:isActive() == false and #played == 2,
    "a single failing chunk is skipped; the other two still play: " .. #played)
local skipped_key_played = false
for _, p in ipairs(played) do
    if p:match(fail_only .. "%.wav$") then skipped_key_played = true end
end
check(not skipped_key_played, "the failing chunk is not among the played audio")
stubs["voicevox"].fetch = real_fetch

-- Engine down (every chunk fails): retried, skipped, then the session stops
-- after FAIL_LIMIT consecutive failures with a message — it does not stall.
os.execute("rm -rf '" .. root .. "/audio'")
pages = { [1] = "一つ目。二つ目。三つ目。四つ目。五つ目。", [2] = "" }
doc.cur = 1
fetch_results = false
played, fetched_texts, shown = {}, {}, {}
controller:start()
pump()
check(controller:isActive() == false and #played == 0,
    "engine down: nothing plays and the session ends")
check(#fetched_texts == AutoReader.FAIL_LIMIT * AutoReader.MAX_FETCH_TRIES,
    "each chunk retried then skipped, stopping after FAIL_LIMIT consecutive fails: "
        .. #fetched_texts .. " attempts")
local fail_msg = false
for _, w in ipairs(shown) do
    if type(w.text) == "string" and w.text:match("could not synthesize") then fail_msg = true end
end
check(fail_msg, "the user is told synthesis failed")
fetch_results = nil
pages = { [1] = "今日はいい天気。明日は", [2] = "雨になる。終わり。" }

-- Annotated copies work too now: the plugin's pageText strips the readings,
-- so start() no longer refuses them.
plugin.isShowingAnnotated = function() return true end
shown = {}
controller:start()
check(controller:isActive() == true,
    "annotated copy: the auto reader starts (pageText is reading-free)")
controller:stop()
plugin.isShowingAnnotated = function() return false end

os.execute("rm -rf '" .. root .. "'")

print(failures == 0 and "\nALL TESTS PASSED" or ("\n" .. failures .. " TEST(S) FAILED"))
os.exit(failures == 0 and 0 or 1)
