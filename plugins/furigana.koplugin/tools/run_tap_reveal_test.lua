-- Harness test for the tap-reveal flow in main.lua (revealAtPos /
-- getWordReadingDisplay / onTapReveal): guards, sentence-context offsets, the
-- native-ruby fallback, the annotate round-trip check, and popup wiring.
-- Stubs the KOReader runtime; pure Lua, no LuaJIT needed:
--   lua tools/run_tap_reveal_test.lua

local here = arg[0]:match("^(.*)/[^/]*$") or "."
package.path = here .. "/../?.lua;" .. package.path

-- ---------------------------------------------------------------- stubs --
local settings_store = {}
G_reader_settings = {
    readSetting = function(_, key, default)
        if settings_store[key] == nil and default ~= nil then settings_store[key] = default end
        return settings_store[key]
    end,
    saveSetting = function(_, key, value) settings_store[key] = value end,
    isTrue = function(_, key) return settings_store[key] == true end,
    nilOrTrue = function(_, key) return settings_store[key] ~= false end,
    flipNilOrTrue = function(_, key) settings_store[key] = settings_store[key] ~= false and false or nil end,
}

local gettext = setmetatable({}, { __call = function(_, s) return s end })
gettext.ngettext = function(s, p, n) return n == 1 and s or p end

local WidgetContainer = {}
function WidgetContainer:extend(o)
    o = o or {}
    setmetatable(o, { __index = self })
    return o
end

local shown = {} -- everything passed to UIManager:show
local popups = {} -- ReadingPopup instances constructed

local fake_fs = {} -- path -> "file"/"directory", for the lfs stub
local fetches = {} -- recorded voicevox.fetch calls
local fetch_result = { true, nil } -- scripted fetch outcome
local played = {} -- recorded audioplayer plays
local released = 0

local stubs = {
    ["ui/widget/confirmbox"] = { new = function(_, o) return o end },
    ["datastorage"] = { getDataDir = function() return "/tmp/kofj_reveal" end },
    ["dispatcher"] = { registerAction = function() end },
    ["ui/event"] = { new = function(_, name, arg) return { name = name, arg = arg } end },
    ["ui/widget/infomessage"] = { new = function(_, o) o.__info = true; return o end },
    ["ui/trapper"] = {
        wrap = function(_, fn) return fn() end,
        info = function() return true end,
        reset = function() end,
        dismissableRunInSubprocess = function(_, task)
            local a, b = task()
            return true, a, b
        end,
    },
    ["ui/uimanager"] = {
        show = function(_, w) shown[#shown + 1] = w end,
        close = function() end,
        nextTick = function(_, fn) end,
        scheduleIn = function() end,
    },
    ["ui/widget/container/widgetcontainer"] = WidgetContainer,
    ["libs/libkoreader-lfs"] = {
        attributes = function(p, what)
            local mode = fake_fs[p]
            if not mode then return nil end
            if what == "mode" then return mode end
            return { mode = mode }
        end,
        dir = function() return function() end end,
    },
    ["logger"] = { dbg = function() end, info = function() end, warn = function() end, err = function() end },
    ["util"] = {
        makePath = function() end,
        trim = function(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end,
        cleanupSelectedText = function(s)
            return (s:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", ""))
        end,
        -- Kana/kanji both start with bytes 0xE3..0xE9 in UTF-8; good enough here.
        hasCJKChar = function(s) return s:find("[\227-\233]") ~= nil end,
    },
    ["gettext"] = gettext,
    ["ffi/util"] = { template = function(s) return s end },
    ["epubannotator"] = {},
    ["readingpopup"] = {
        new = function(_, o)
            o.__popup = true
            popups[#popups + 1] = o
            return o
        end,
    },
    ["voicevox"] = {
        DEFAULT_URL = "http://127.0.0.1:50021",
        DEFAULT_SPEAKER = 3,
        fetch = function(opts, word, out_path)
            fetches[#fetches + 1] = { opts = opts, word = word, out_path = out_path }
            return fetch_result[1], fetch_result[2]
        end,
    },
    ["audioplayer"] = {
        play = function(_, path)
            played[#played + 1] = path
            return true
        end,
        release = function() released = released + 1 end,
    },
}
for name, mod in pairs(stubs) do
    package.preload[name] = function() return mod end
end

-- ------------------------------------------------------------- run tests --
local failures = 0
local function check(cond, msg)
    if cond then
        print("ok   - " .. msg)
    else
        failures = failures + 1
        print("FAIL - " .. msg)
    end
end

local Furigana = require("main")

-- A fake tokenizer that wraps known words in ruby.
local RUBY = {
    ["黒かっ"] = "<ruby>黒かっ<rt>ぐろかっ</rt></ruby>",
    ["風"] = "<ruby>風<rt>かぜ</rt></ruby>",
    ["毎日"] = "<ruby>毎日<rt>まいにち</rt></ruby>",
    ["食べ"] = "<ruby>食べ<rt>たべ</rt></ruby>",
}
local fake_tok = {
    annotate = function(_, text)
        for base, ruby in pairs(RUBY) do
            text = text:gsub(base, ruby)
        end
        return text
    end,
}

-- A fake reader environment, reconfigured per scenario.
local doc = {
    file = "/books/novel.epub",
    word_queries = 0,
}
function doc:getWordFromPosition(pos, do_not_draw)
    self.word_queries = self.word_queries + 1
    assert(do_not_draw == true, "must not draw a selection")
    return self.word_at_pos
end
function doc:extendXPointersToSentenceSegment(pos0, pos1)
    return self.sentence
end
function doc:getTextFromXPointers(a, b)
    return self.prefix
end

local view = {
    screenToPageTransform = function(_, pos) pos.page = 7; return pos end,
    pageToScreenTransform = function(_, page, rect) return rect end,
}

local handled_events = {}
local furi = setmetatable({
    ui = {
        document = doc,
        view = view,
        rolling = true,
        handleEvent = function(_, ev) handled_events[#handled_events + 1] = ev end,
    },
    cache_dir = "/tmp/kofj_reveal/cache/furigana",
    _cached_tok = fake_tok, -- bypass the FFI dictionary load
}, { __index = Furigana })

-- 1) Full happy path: sentence context, popup anchored, reading shown.
doc.word_at_pos = { word = "黒かっ", pos0 = "xp0", pos1 = "xp1", sbox = { x = 10, y = 20, w = 30, h = 15 } }
doc.sentence = { text = "どす黒かった。", pos0 = "s0", pos1 = "s1" }
doc.prefix = "どす"
popups = {}
check(furi:revealAtPos({ x = 5, y = 6 }) == true, "reveal succeeds on a kanji word")
check(#popups == 1 and popups[1].text == "黒かっ（ぐろかっ）",
    "popup shows the token with its reading: " .. (popups[1] and popups[1].text or "?"))
check(popups[1].anchor_box and popups[1].anchor_box.x == 10 and popups[1].anchor_box.y == 20,
    "popup is anchored to the word's screen box")
popups[1].tap_callback()
check(#handled_events == 1 and handled_events[1].name == "ShowJapaneseAnalysis"
    and handled_events[1].arg.pos.x == 5,
    "tapping the popup escalates to the Japanese analysis at the tap position")

-- 2) Offset mismatch (native-ruby noise): falls back to the bare word.
doc.prefix = "どすXX" -- wrong length: sub() no longer lands on the word
popups = {}
check(furi:revealAtPos({ x = 5, y = 6 }) == true and popups[1]
    and popups[1].text == "黒かっ（ぐろかっ）",
    "offset mismatch falls back to tokenizing the bare word")
doc.prefix = "どす"

-- 3) Kana-only word: no reading, tap falls through.
doc.word_at_pos = { word = "ひらがな", pos0 = "xp0", pos1 = "xp1" }
doc.sentence = { text = "ひらがなです。", pos0 = "s0" }
doc.prefix = ""
check(furi:revealAtPos({ x = 5, y = 6 }) == false, "kana-only word: declines (no reading)")

-- 4) Non-CJK word: declines before touching the tokenizer.
doc.word_at_pos = { word = "hello", pos0 = "xp0", pos1 = "xp1" }
check(furi:revealAtPos({ x = 5, y = 6 }) == false, "latin word: declines")

-- 5) Annotate round-trip mismatch: gives up rather than show wrong offsets.
doc.word_at_pos = { word = "風", pos0 = "xp0", pos1 = "xp1" }
doc.sentence = { text = "風が吹く。", pos0 = "s0" }
doc.prefix = ""
local real_annotate = fake_tok.annotate
fake_tok.annotate = function(_, text) return text .. "!" end
check(furi:revealAtPos({ x = 5, y = 6 }) == false, "annotate round-trip mismatch: declines")
fake_tok.annotate = real_annotate

-- 6) Guards: annotated copy showing / paging document / tap-reveal disabled.
doc.file = furi.cache_dir .. "/abc.epub"
check(furi:revealAtPos({ x = 5, y = 6 }) == false, "annotated copy showing: declines")
doc.file = "/books/novel.epub"

furi.ui.rolling = nil
check(furi:revealAtPos({ x = 5, y = 6 }) == false, "paging document: declines")
furi.ui.rolling = true

settings_store["furigana_tap_reveal"] = false
local queries_before = doc.word_queries
check(furi:onTapReveal({ pos = { x = 5, y = 6 } }) == false
    and doc.word_queries == queries_before,
    "tap-reveal disabled: tap zone declines without looking anything up")
settings_store["furigana_tap_reveal"] = nil

-- 7) Dispatcher entry point shows a hint when no word was found.
doc.word_at_pos = nil
shown = {}
check(furi:onShowWordFurigana({ pos = { x = 5, y = 6 } }) == true
    and #shown == 1 and shown[1].__info,
    "gesture entry point shows a hint when there is no word under it")

-- 8) Yomichan-style word expansion via the Japanese plugin: crengine returns
-- only the tapped character; the deinflection scan grows it to the full word,
-- and the popup covers that whole word.
doc.word_at_pos = { word = "食", pos0 = "xp0", pos1 = "xp1", sbox = { x = 1, y = 2, w = 3, h = 4 } }
doc.sentence = { text = "毎日食べた。", pos0 = "s0" }
doc.prefix = "毎日"
local expand_calls = {}
furi.ui.japanese = {
    expandWord = function(_, w)
        -- snapshot: revealAtPos overwrites w.word with the expansion afterwards
        expand_calls[#expand_calls + 1] = { word = w.word, pos0 = w.pos0 }
        return "食べた"
    end,
}
popups = {}
check(furi:revealAtPos({ x = 5, y = 6 }) == true and popups[1]
    and popups[1].text == "食べ（たべ）た",
    "expanded word: popup covers the whole word, not just the tapped character: "
        .. (popups[1] and popups[1].text or "?"))
check(#expand_calls == 1 and expand_calls[1].word == "食" and expand_calls[1].pos0 == "xp0",
    "expansion gets the crengine word box (tap position) to scan from")

-- 9) Expansion failure degrades to the crengine word (token overlap only).
doc.word_at_pos = { word = "食", pos0 = "xp0", pos1 = "xp1" }
furi.ui.japanese = { expandWord = function() error("boom") end }
popups = {}
check(furi:revealAtPos({ x = 5, y = 6 }) == true and popups[1]
    and popups[1].text == "食べ（たべ）",
    "expansion error: falls back to the tapped character's token")

-- 10) Without the Japanese plugin nothing changes (token overlap behavior).
furi.ui.japanese = nil
popups = {}
check(furi:revealAtPos({ x = 5, y = 6 }) == true and popups[1]
    and popups[1].text == "食べ（たべ）",
    "no Japanese plugin: tapped character's token is still shown")

-- 11) Word audio (VOICEVOX) -------------------------------------------------
doc.word_at_pos = { word = "食", pos0 = "xp0", pos1 = "xp1" }
furi.ui.japanese = { expandWord = function() return "食べた" end }

-- Both toggles off: the tap zone declines without looking anything up.
settings_store["furigana_tap_reveal"] = false
settings_store["furigana_tap_audio"] = nil
local q_before = doc.word_queries
check(furi:onTapReveal({ pos = { x = 5, y = 6 } }) == false and doc.word_queries == q_before,
    "popup and audio both off: tap declines untouched")

-- Audio only: fetch with the expanded word, play the cached wav, no popup.
settings_store["furigana_tap_audio"] = true
popups, fetches, played = {}, {}, {}
check(furi:revealAtPos({ x = 5, y = 6 }) == true, "audio only: tap is consumed")
check(#popups == 0, "audio only: no popup")
check(#fetches == 1 and fetches[1].word == "食べた"
    and fetches[1].opts.url == "http://127.0.0.1:50021" and fetches[1].opts.speaker == 3,
    "audio only: VOICEVOX queried with the expanded word and configured opts")
local cache_path = furi:audioCachePathFor(furi:voicevoxOpts(), "食べた")
check(fetches[1].out_path == cache_path .. ".tmp" and #played == 1 and played[1] == cache_path,
    "fetched to a .tmp then played from the cache path")

-- Cache hit: plays immediately, no fetch.
fake_fs[cache_path] = "file"
fetches, played = {}, {}
check(furi:revealAtPos({ x = 5, y = 6 }) == true and #fetches == 0
    and #played == 1 and played[1] == cache_path,
    "cached word: plays immediately without fetching")
fake_fs[cache_path] = nil

-- Kana-only word: no reading popup possible, but audio still speaks it.
doc.word_at_pos = { word = "ひらがな", pos0 = "xp0", pos1 = "xp1" }
furi.ui.japanese = nil
fetches, popups = {}, {}
check(furi:revealAtPos({ x = 5, y = 6 }) == true and #fetches == 1
    and fetches[1].word == "ひらがな" and #popups == 0,
    "kana-only word with audio on: spoken, no popup")

-- Both on: popup and audio together.
settings_store["furigana_tap_reveal"] = nil -- default on
doc.word_at_pos = { word = "風", pos0 = "xp0", pos1 = "xp1" }
doc.sentence = { text = "風が吹く。", pos0 = "s0" }
doc.prefix = ""
popups, fetches = {}, {}
check(furi:revealAtPos({ x = 5, y = 6 }) == true and #popups == 1
    and popups[1].text == "風（かぜ）" and #fetches == 1 and fetches[1].word == "風",
    "popup and audio both enabled: both happen")

-- Fetch failure: error message, nothing played (the reading popup still shows).
fetch_result = { false, "connection refused" }
fetches, played, shown = {}, {}, {}
local revealed = furi:revealAtPos({ x = 5, y = 6 })
local error_shown = false
for _, w in ipairs(shown) do
    if w.__info and w.text:match("VOICEVOX") then error_shown = true end
end
check(revealed == true and #played == 0 and error_shown,
    "fetch failure: user is told, nothing plays")
fetch_result = { true, nil }

-- Explicit gesture forces the popup even with the single-tap toggle off.
settings_store["furigana_tap_reveal"] = false
settings_store["furigana_tap_audio"] = nil
popups = {}
check(furi:onShowWordFurigana({ pos = { x = 5, y = 6 } }) == true and #popups == 1,
    "explicit gesture shows the popup despite the tap toggle being off")
settings_store["furigana_tap_reveal"] = nil

-- Closing the document releases the kept player.
released = 0
furi:onCloseDocument()
check(released == 1, "closing the document releases the audio player")

-- 12) Speak buttons (highlight dialog + dictionary window) -------------------
local highlight_items = {}
local dict_specs = {}
furi.ui.highlight = {
    addToHighlightDialog = function(_, idx, fn) highlight_items[idx] = fn end,
}
furi.ui.dictionary = {
    addToDictButtons = function(_, spec) dict_specs[spec.id] = spec end,
}
furi:registerSpeakButtons()

-- Highlight dialog entry: shown for Japanese selections, speaks cleaned text.
local item_fn = highlight_items["12_a_voicevox_speak"]
check(item_fn ~= nil, "a Speak entry is registered in the highlight dialog")
local closed = 0
local this = {
    selected_text = { text = "  毎日\n食べた。 " },
    onClose = function() closed = closed + 1 end,
}
local item = item_fn(this)
check(item.show_in_highlight_dialog_func() == true,
    "highlight dialog: shown for a Japanese selection")
-- Audio toggle is off here: the Speak button must work regardless.
settings_store["furigana_tap_audio"] = nil
fetches = {}
item.callback()
check(closed == 1 and #fetches == 1 and fetches[1].word == "毎日 食べた。",
    "highlight dialog Speak: closes the dialog and speaks the cleaned selection: "
        .. (fetches[1] and fetches[1].word or "?"))
this.selected_text.text = "english only"
check(item_fn(this).show_in_highlight_dialog_func() == false,
    "highlight dialog: hidden for non-Japanese selections")

-- Dictionary window button: conditional, shares the analyse row, speaks the
-- originally selected form.
local spec = dict_specs["furigana_speak"]
check(spec ~= nil and spec.conditional == true and spec.row_group == "ja_word_actions",
    "dictionary Speak button is transient and shares the JA actions row")
check(spec.show_func({ is_wiki = true, word = "食べた" }) == false,
    "dictionary Speak: hidden on wiki windows")
check(spec.show_func({ word = "hello" }) == false,
    "dictionary Speak: hidden for non-Japanese words")
check(spec.show_func({ word = "食べた" }) == true,
    "dictionary Speak: shown for Japanese words")
fetches = {}
spec.callback({ word = "食べた", lookupword = "食べる" })
check(#fetches == 1 and fetches[1].word == "食べた",
    "dictionary Speak: speaks the selected form, not the headword")

print(failures == 0 and "\nALL TESTS PASSED" or ("\n" .. failures .. " TEST(S) FAILED"))
os.exit(failures == 0 and 0 or 1)
