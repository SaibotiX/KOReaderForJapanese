--[[--
Japanese furigana plugin.

Adds an on-demand "Add furigana annotations" toggle (under the dictionary/search
menu tab) for Japanese EPUBs. When enabled it generates a ruby-annotated copy of
the current book entirely on-device (no Node/Python needed) and reopens it at the
same reading position; toggling again returns to the original.

The heavy lifting lives in:
  - tokenizer.lua     : LuaJIT port of kuromoji's Viterbi tokenizer
  - epubannotator.lua : EPUB read/annotate/write
  - dict/             : compact dictionary built by tools/build_dict.js

@module koplugin.furigana
]]

local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local Dispatcher = require("dispatcher")
local Event = require("ui/event")
local InfoMessage = require("ui/widget/infomessage")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")
local N_ = _.ngettext
local T = require("ffi/util").template

local EpubAnnotator = require("epubannotator")
local ReadingExtractor = require("readingextractor")

local Furigana = WidgetContainer:extend{
    name = "furigana",
}

-- djb2 hash -> 8 hex chars; just needs to be stable and collision-resistant
-- enough to key cache files by source path.
local function hash_str(s)
    local h = 5381
    for i = 1, #s do h = (h * 33 + s:byte(i)) % 4294967296 end
    return string.format("%08x", h)
end

function Furigana:init()
    self.cache_dir = DataStorage:getDataDir() .. "/cache/furigana"
    if lfs.attributes(self.cache_dir, "mode") ~= "directory" then
        util.makePath(self.cache_dir)
    end
    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    end
    self:onDispatcherRegisterActions()
    self:registerSpeakButtons()
    self:redirectFileBrowserToOriginal()
    self:maybeAutoOpenAnnotated()
end

--- Add "Speak" entries to the text-selection (highlight) dialog and to the
-- dictionary window, both synthesizing the text through VOICEVOX (see
-- :speakText). Available whenever the selection/word contains Japanese,
-- independently of the tap-audio toggle.
function Furigana:registerSpeakButtons()
    if self.ui and self.ui.highlight and self.ui.highlight.addToHighlightDialog then
        -- "12_search" is kept last in the dialog; "12_a..." sorts just before it.
        self.ui.highlight:addToHighlightDialog("12_a_voicevox_speak", function(this)
            return {
                text = _("Speak (VOICEVOX)"),
                show_in_highlight_dialog_func = function()
                    return this.selected_text and this.selected_text.text
                        and util.hasCJKChar(this.selected_text.text) or false
                end,
                callback = function()
                    local text = util.cleanupSelectedText(this.selected_text.text)
                    this:onClose()
                    self:speakText(text)
                end,
            }
        end)
    end
    if self.ui and self.ui.dictionary and self.ui.dictionary.addToDictButtons then
        self.ui.dictionary:addToDictButtons({
            id = "furigana_speak",
            text = _("Speak (JA)"),
            conditional = true,
            -- Shares a transient row with japanese.koplugin's "Analyse (JA)".
            row_group = "ja_word_actions",
            show_func = function(dict_popup)
                if dict_popup.is_wiki then return false end
                local w = dict_popup.word or dict_popup.lookupword
                return w ~= nil and util.hasCJKChar(w)
            end,
            callback = function(dict_popup)
                -- The original selection (the form as written in the book),
                -- not the displayed headword.
                self:speakText(dict_popup.word or dict_popup.lookupword)
            end,
        })
    end
end

function Furigana:onDispatcherRegisterActions()
    Dispatcher:registerAction("furigana_reveal_word", {
        category = "arg",
        event = "ShowWordFurigana",
        title = _("Show furigana for word"),
        reader = true,
    })
    Dispatcher:registerAction("furigana_autoread_toggle", {
        category = "none",
        event = "ToggleAutoRead",
        title = _("Auto reader (VOICEVOX)"),
        reader = true,
    })
end

-- On opening a plain book, if it was last read with furigana, reopen the cached
-- annotated copy automatically.
function Furigana:maybeAutoOpenAnnotated()
    if not (self.ui and self.ui.document) then return end
    if self:isShowingAnnotated() then return end
    if not self:isAutoOpenEnabled() then return end
    if not self:isSupportedDoc() then return end
    local src = self.ui.document.file
    local annotated = self:getAutoMap()[src]
    if not annotated then return end
    if lfs.attributes(annotated, "mode") == "file" then
        UIManager:nextTick(function() self:switchTo(annotated) end)
    else
        self:forgetAuto(src) -- cached copy is gone; drop stale state
    end
end

-- When the open document is one of our annotated copies (living in the cache
-- dir), make "leaving" the book return to the ORIGINAL book's folder instead of
-- the cache directory. KOReader's Home / file-browser actions pass the current
-- file's path to showFileManager, so we swap a cache path for the original on
-- this reader instance only.
function Furigana:redirectFileBrowserToOriginal()
    if not (self.ui and self.ui.document and self:isShowingAnnotated()) then return end
    if self.ui._furigana_fm_patched then return end
    local src = self:readOriginalPath(self.ui.document.file)
    if not src then return end

    local ui = self.ui
    local cache_prefix = self.cache_dir
    local orig_show = ui.showFileManager
    ui._furigana_fm_patched = true
    ui.showFileManager = function(this, file, selected_files)
        if file and file:sub(1, #cache_prefix) == cache_prefix then
            file = src -- open the original's folder (and highlight it)
        end
        return orig_show(this, file, selected_files)
    end
    -- Also cover the no-argument path (some back gestures).
    if ui.setLastDirForFileBrowser then
        local dir = src:match("(.*)/")
        if dir then ui:setLastDirForFileBrowser(dir) end
    end
end

-- ----------------------------------------------------------------- helpers --

-- Supported = a crengine reflowable document we can rewrite: EPUB or standalone
-- HTML. (Paged formats — PDF/DjVu/CBZ — are excluded.)
function Furigana:isSupportedDoc()
    local doc = self.ui and self.ui.document
    if not doc then return false end
    if doc.info and doc.info.has_pages then return false end
    local file = (doc.file or ""):lower()
    return file:match("%.epub$") ~= nil or file:match("%.html?$") ~= nil
end

-- "epub" or "html" — the format of the annotated copy for a given source.
local function annotated_ext(src)
    return src:lower():match("%.epub$") and "epub" or "html"
end

function Furigana:isShowingAnnotated()
    local file = (self.ui and self.ui.document and self.ui.document.file) or ""
    return file:sub(1, #self.cache_dir) == self.cache_dir
end

-- Cache path for the annotated copy of `src`, keyed by path + size + mtime + dict
-- version + furigana level, so it is regenerated if the book, the dictionary, or
-- the selected level changes (each level caches separately).
function Furigana:annotatedPathFor(src)
    local attr = lfs.attributes(src)
    local size = attr and attr.size or 0
    local mtime = attr and attr.modification or 0
    local dict_version = self:getDictVersion()
    local key = hash_str(src) .. "_" .. size .. "_" .. mtime
        .. "_v" .. dict_version .. "_g" .. self:getMinGrade()
        .. "_r" .. (self:getReplaceRuby() and 1 or 0)
    return self.cache_dir .. "/" .. key .. "." .. annotated_ext(src)
end

-- Selective-furigana level: annotate a word only if its hardest kanji's grade is
-- >= this value. 1 = annotate every kanji word (default).
function Furigana:getMinGrade()
    return G_reader_settings:readSetting("furigana_min_grade") or 1
end

-- When true, strip the book's own embedded furigana before annotating, so only
-- our readings remain (and the level setting governs every kanji).
function Furigana:getReplaceRuby()
    return G_reader_settings:isTrue("furigana_replace_native_ruby")
end

-- "Sticky furigana": remember, per original book, the annotated copy last read,
-- so opening the plain book reopens its furigana version automatically. Cleared
-- when the user turns furigana off for that book.
function Furigana:isAutoOpenEnabled()
    return G_reader_settings:nilOrTrue("furigana_auto_open_enabled")
end

function Furigana:getAutoMap()
    return G_reader_settings:readSetting("furigana_auto_map") or {}
end

function Furigana:rememberAuto(src, annotated)
    local m = self:getAutoMap()
    m[src] = annotated
    G_reader_settings:saveSetting("furigana_auto_map", m)
end

function Furigana:forgetAuto(src)
    local m = self:getAutoMap()
    if m[src] ~= nil then
        m[src] = nil
        G_reader_settings:saveSetting("furigana_auto_map", m)
    end
end

function Furigana:getDictVersion()
    if self._dict_version then return self._dict_version end
    local ok, meta = pcall(function() return dofile(self.path .. "/dict/meta.lua") end)
    self._dict_version = (ok and meta and meta.version) or 0
    return self._dict_version
end

-- We remember each annotated copy's source path in a sibling .src file so the
-- toggle can switch back to the original even after a fresh launch.
function Furigana:srcSidecarPath(annotated_path)
    return annotated_path .. ".src"
end

function Furigana:writeOriginalPath(annotated_path, src)
    local fh = io.open(self:srcSidecarPath(annotated_path), "w")
    if fh then fh:write(src); fh:close() end
end

function Furigana:readOriginalPath(annotated_path)
    local fh = io.open(self:srcSidecarPath(annotated_path), "r")
    if not fh then return nil end
    local src = fh:read("*a")
    fh:close()
    return src and src:gsub("%s+$", "") or nil
end

function Furigana:getTokenizer()
    -- Loaded on demand and dropped after use (the FFI dictionary is ~35 MB).
    local Tokenizer = require("tokenizer")
    return Tokenizer.new(self.path .. "/dict", self:getMinGrade())
end

--- Tokenizer kept loaded for per-word use (tap-reveal popups, and the Japanese
-- plugin's reading labels), with every kanji annotated regardless of the
-- whole-book reading level: the user explicitly asked for this word's reading.
-- Held until the reader instance is torn down (document close/switch).
function Furigana:getCachedTokenizer()
    if not self._cached_tok then
        local tok = self:getTokenizer()
        if tok.setMinGrade then tok:setMinGrade(1) end
        self._cached_tok = tok
    end
    return self._cached_tok
end

-- --------------------------------------------------------------- tap reveal --
-- Anki-style on-demand furigana: tap a word in the (un-annotated) book and a
-- small popup with just that word's reading appears above it. The popup is
-- generated on the fly from the tokenizer — the book file is never touched, so
-- this works without generating the annotated copy.

--- What a short tap on a word displays: "popup" (the reading popup, default),
-- "dict" (the dictionary window, optionally restricted to one dictionary),
-- "translate" (the built-in Google-Translate window) or "none" (nothing —
-- tap audio may still play). Installs from before this mode existed only
-- stored the popup on/off toggle; honor it as the default.
function Furigana:getTapDisplayMode()
    local mode = G_reader_settings:readSetting("furigana_tap_display")
    if mode == nil then
        mode = G_reader_settings:readSetting("furigana_tap_reveal") == false
            and "none" or "popup"
    end
    return mode
end

--- The single dictionary the "dict" tap mode looks the word up in
-- (nil = all enabled dictionaries).
function Furigana:getTapDictName()
    return G_reader_settings:readSetting("furigana_tap_dict")
end

--- Register the whole-screen single-tap zone once the reader is ready. It runs
-- before the Japanese plugin's analysis tap (and the page-turn taps), and
-- declines (returns false) when it has nothing to show, letting the tap fall
-- through to those.
function Furigana:onReaderReady()
    self:precacheSchedule() -- initial window fill for the opened position
    if self._reveal_zone_registered then return end
    if not (self.ui and self.ui.registerTouchZones and self.ui.rolling) then return end
    self.ui:registerTouchZones({
        {
            id = "furigana_reveal_tap",
            ges = "tap",
            screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 },
            overrides = {
                "japanese_analyse_tap",
                "readerhighlight_tap",
                "tap_top_left_corner", "tap_top_right_corner",
                "tap_left_bottom_corner", "tap_right_bottom_corner",
                "tap_forward", "tap_backward",
            },
            handler = function(ges) return self:onTapReveal(ges) end,
        },
    })
    self._reveal_zone_registered = true
end

function Furigana:onTapReveal(ges)
    -- While the auto reader speaks, a tap anywhere is "stop reading".
    if self.autoreader and self.autoreader:isActive() then
        self.autoreader:stop(_("Auto reader stopped"))
        return true
    end
    if self:getTapDisplayMode() == "none" and not self:isTapAudioEnabled() then
        return false
    end
    return self:revealAtPos(ges and ges.pos) or false
end

--- Gesture-bound entry point ("Show furigana for word", category="arg": the
-- bound gesture's object, with its position, is passed through). An explicit
-- gesture always shows the popup, even when the single-tap toggle is off.
function Furigana:onShowWordFurigana(ges)
    if type(ges) == "table" and ges.pos and self:revealAtPos(ges.pos, true) then
        return true
    end
    UIManager:show(InfoMessage:new{
        text = _("Tap on a Japanese word to show its reading."),
        timeout = 2,
    })
    return true
end

--- Reveal the word at screen position `pos`: a reading popup anchored above
-- it, its VOICEVOX audio, or both — per the two independent toggles
-- (want_popup forces the popup, used by the explicit gesture). Returns true
-- when the tap did something (false: nothing Japanese there, or both features
-- idle, so a tap can fall through to other handlers).
function Furigana:revealAtPos(screen_pos, want_popup)
    if not (screen_pos and self.ui and self.ui.document and self.ui.view) then return false end
    if not self.ui.rolling then return false end -- crengine/EPUB only
    -- In an annotated copy the readings are already visible (and the extracted
    -- text would interleave them, confusing the tokenizer).
    if self:isShowingAnnotated() then return false end
    -- Copy the point: screenToPageTransform mutates it (adds .page).
    local pos = self.ui.view:screenToPageTransform({ x = screen_pos.x, y = screen_pos.y })
    if not pos then return false end
    local ok, word = pcall(self.ui.document.getWordFromPosition, self.ui.document, pos, true)
    if not (ok and word and word.word and word.word ~= "" and word.pos0 and word.pos1) then
        return false
    end
    if not util.hasCJKChar(word.word) then return false end
    -- crengine's CJK "word" is often just the tapped character: grow it to the
    -- full dictionary word, so popup and audio cover the whole word.
    word.word = self:expandTappedWord(word)

    -- Start the audio first (when enabled): the popup's first-time tokenizer
    -- load must not delay it. Audio also covers kana-only words, which have
    -- no reading to show.
    local audio_started = false
    if self:isTapAudioEnabled() then
        audio_started = self:speakText(word.word) or false
    end

    -- What to display for the word: the reading popup (default, optionally
    -- with a translation line), a dictionary window, the translator window,
    -- or nothing. The explicit gesture always means the popup (with the
    -- translation when that flavor is configured).
    local mode = self:getTapDisplayMode()
    if want_popup and mode ~= "popup_translate" then
        mode = "popup"
    end
    if mode == "dict" then
        return self:showTapDict(word, pos) or audio_started
    elseif mode == "translate" then
        return self:showTapTranslation(word) or audio_started
    elseif mode ~= "popup" and mode ~= "popup_translate" then -- "none"
        return audio_started
    end

    local display = self:getWordReadingDisplay(word)
    if not display then
        if mode == "popup_translate" then
            -- Kana-only words have no reading to add, but the translation
            -- line still makes the popup worth showing.
            display = word.word
        else
            return audio_started
        end
    end

    if mode == "popup_translate" then
        local cached = self._tap_translations and self._tap_translations[word.word]
        if cached then
            self:showReadingPopup(display .. "\n" .. cached, word, pos, screen_pos)
        else
            -- Reading first (instant), translation swapped in when it lands.
            self:showReadingPopup(display, word, pos, screen_pos)
            self:fetchTranslationForPopup(display, word, pos, screen_pos)
        end
    else
        self:showReadingPopup(display, word, pos, screen_pos)
    end
    return true
end

--- Show the small anchored popup for a word, replacing whichever reading
-- popup is currently up (taps replace popups naturally; the translation
-- update swaps them programmatically).
function Furigana:showReadingPopup(text, word, pos, screen_pos)
    local ReadingPopup = require("readingpopup")
    if self._reading_popup then
        UIManager:close(self._reading_popup)
    end
    local popup
    popup = ReadingPopup:new{
        text = text,
        anchor_box = word.sbox and self.ui.view:pageToScreenTransform(pos.page, word.sbox),
        tap_callback = function()
            -- Tap on the popup: escalate to the full word analysis
            -- (handled by japanese.koplugin; a no-op without it).
            self.ui:handleEvent(Event:new("ShowJapaneseAnalysis",
                { pos = { x = screen_pos.x, y = screen_pos.y } }))
        end,
        close_callback = function()
            if self._reading_popup == popup then
                self._reading_popup = nil
            end
        end,
    }
    self._reading_popup = popup
    UIManager:show(popup)
end

--- Fetch the word's English translation in a dismissable background
-- subprocess and swap the reading popup for a two-line version (reading on
-- top, bare translation underneath). Results are kept for the session, so a
-- word is only ever fetched once. A tap while fetching dismisses the wait
-- (it usually replaces the popup anyway), leaving the reading-only popup.
function Furigana:fetchTranslationForPopup(display, word, pos, screen_pos)
    local text = word.word
    Trapper:wrap(function()
        local Translator = require("ui/translator")
        local completed, translated = Trapper:dismissableRunInSubprocess(function()
            -- Target pinned to English (the popup shows just the bare
            -- translation line); source pinned to Japanese — auto-detection
            -- misfires on single words.
            local ok, res = pcall(Translator.translate, Translator, text, "en", "ja")
            return (ok and type(res) == "string") and res or ""
        end, nil, true) -- invisible trap; plain-string result
        if not completed or not translated then return end
        translated = util.trim(translated)
        if translated == "" or translated == text then return end
        self._tap_translations = self._tap_translations or {}
        self._tap_translations[text] = translated
        -- Only swap if this word's reading popup is still the one showing.
        if self._reading_popup and self._reading_popup.text == display then
            self:showReadingPopup(display .. "\n" .. translated, word, pos, screen_pos)
        end
    end)
end

--- Tap mode "dict": open the dictionary window for the expanded word,
-- restricted to the chosen dictionary (when one is set). Positioned next to
-- the word like a normal lookup. Returns true when the lookup was started.
function Furigana:showTapDict(word, pos)
    local dictionary = self.ui and self.ui.dictionary
    if not (dictionary and dictionary.onLookupWord) then return false end
    local boxes
    if word.sbox and pos and self.ui.view then
        local sb = self.ui.view:pageToScreenTransform(pos.page, word.sbox)
        if sb then boxes = { sb } end
    end
    local opts
    local dict_name = self:getTapDictName()
    if dict_name then
        opts = { dict_names = { dict_name } }
    end
    local ok = pcall(dictionary.onLookupWord, dictionary,
        word.word, false, boxes, nil, nil, nil, opts)
    return ok
end

--- Tap mode "translate": the built-in translator (Google Translate; needs
-- network) on the expanded word, in its detailed view.
function Furigana:showTapTranslation(word)
    local ok, Translator = pcall(require, "ui/translator")
    if not ok then return false end
    return pcall(Translator.showTranslation, Translator, word.word, true) and true
end

--- Expand the tapped (often single-character) crengine word to the full
-- dictionary word, exactly the way the Japanese plugin's lookups do: scan
-- forward from the tap, deinflect each candidate with the Yomichan rules
-- (yomichan-deinflect.json) and keep the longest form found in the user's
-- dictionaries (one batched sdcv call). Word start is the tapped character,
-- like in Yomichan. Returns the crengine word unchanged when the Japanese
-- plugin is unavailable or nothing matches (expandWord falls back itself).
function Furigana:expandTappedWord(word)
    local japanese = self.ui and self.ui.japanese
    if not (japanese and japanese.expandWord) then return word.word end
    local ok, expanded = pcall(japanese.expandWord, japanese, word)
    if ok and type(expanded) == "string" and expanded ~= "" then
        return expanded
    end
    return word.word
end

--- The popup text for a tapped word: its token(s) with readings spliced in,
-- e.g. 食（た）べた. Returns nil when there is nothing to show.
function Furigana:getWordReadingDisplay(word)
    local ok_tok, tok = pcall(function() return self:getCachedTokenizer() end)
    if not ok_tok or not tok then
        logger.err("furigana: reveal: could not load the dictionary:", tok)
        return nil
    end
    local doc = self.ui.document
    -- Tokenize the whole sentence, so the Viterbi sees the same context the
    -- whole-book annotator would (same segmentation, same readings).
    local text, word_off
    local ok_sent, sent = pcall(doc.extendXPointersToSentenceSegment, doc, word.pos0, word.pos1)
    if ok_sent and sent and sent.text and sent.text ~= "" and sent.pos0 then
        local ok_prefix, prefix = pcall(doc.getTextFromXPointers, doc, sent.pos0, word.pos0)
        if ok_prefix and prefix then
            text = sent.text
            word_off = #prefix
        end
    end
    -- The computed offset must land exactly on the tapped word. It may not in
    -- books with native ruby (crengine's extracted text interleaves the rt
    -- readings); fall back to tokenizing the bare word without context.
    if not (text and word_off and text:sub(word_off + 1, word_off + #word.word) == word.word) then
        text = word.word
        word_off = 0
    end
    local runs, plain = ReadingExtractor.parse(tok:annotate(text))
    if plain ~= text then
        -- The tokenizer must give the plain text back unchanged, or the run
        -- offsets cannot be trusted.
        logger.warn("furigana: reveal: annotate round-trip mismatch")
        return nil
    end
    return ReadingExtractor.display(plain, runs, word_off, #word.word)
end

-- --------------------------------------------------------------- word audio --
-- Optional VOICEVOX audio for the tapped word: the word is synthesized by a
-- self-hosted VOICEVOX engine (configure its URL in the menu), cached as a
-- WAV under the furigana cache, and played through the platform player
-- (Android MediaPlayer via JNI; a CLI player on the emulator/desktop).
-- Fully independent of the reading popup: enable either one, both, or neither.

function Furigana:isTapAudioEnabled()
    return G_reader_settings:isTrue("furigana_tap_audio")
end

function Furigana:voicevoxOpts()
    local VoiceVox = require("voicevox")
    return {
        url = G_reader_settings:readSetting("furigana_voicevox_url") or VoiceVox.DEFAULT_URL,
        speaker = G_reader_settings:readSetting("furigana_voicevox_speaker") or VoiceVox.DEFAULT_SPEAKER,
        -- Level the loudness of newly synthesized audio (the engine renders
        -- each request at whatever volume the voice model happens to produce;
        -- see voicevox.lua's normalizeLoudness).
        normalize = G_reader_settings:nilOrTrue("furigana_voicevox_normalize"),
    }
end

function Furigana:audioCachePathFor(opts, text)
    -- Keyed through precache.lua so background-precached files (same keying)
    -- are interchangeable with foreground-fetched ones.
    local key = require("precache").audioKey(opts.url, opts.speaker, text)
    return self.cache_dir .. "/audio/" .. key .. ".wav"
end

-- Where the background precache worker would have put this text's audio.
function Furigana:precachedAudioPathFor(opts, text)
    local key = require("precache").audioKey(opts.url, opts.speaker, text)
    return self.cache_dir .. "/audio/precache/" .. key .. ".wav"
end

-- ------------------------------------------------------------ audio precache --
-- Keep the words of the two previous, current and two next pages synthesized
-- ahead of time (background subprocess; see precache.lua), so tap audio plays
-- instantly. Stale pages' files are pruned automatically by the worker.

function Furigana:isPrecacheEnabled()
    return G_reader_settings:nilOrTrue("furigana_audio_precache")
end

function Furigana:getPrecache()
    if not self._precache then
        self._precache = require("precache").newController(self)
    end
    return self._precache
end

--- (Re-)target the precache window at the current page, debounced; called on
-- every page turn and whenever a setting it depends on changes.
function Furigana:precacheSchedule()
    if not (self:isTapAudioEnabled() and self:isPrecacheEnabled()) then return end
    if not (self.ui and self.ui.rolling and self.ui.document) then return end
    if self:isShowingAnnotated() then return end
    self:getPrecache():schedule()
end

function Furigana:onPageUpdate(page)
    if self.autoreader then
        self.autoreader:onPageUpdate(page) -- manual navigation stops it
    end
    self:precacheSchedule()
end

--- The text of one rendered page (page top to next page top; the last page
-- walks to the end of the book). Shared by the precache window capture and
-- the auto reader. Returns nil when it can't be had.
function Furigana:pageText(page)
    local doc = self.ui and self.ui.document
    if not doc then return nil end
    local ok, text = pcall(function()
        local xp0 = doc:getPageXPointer(page)
        if not xp0 then return nil end
        if page + 1 <= doc:getPageCount() then
            local xp1 = doc:getPageXPointer(page + 1)
            if xp1 then return doc:getTextFromXPointers(xp0, xp1) end
        end
        local e = xp0
        for _ = 1, 800 do
            local nxt = doc:getNextVisibleChar(e)
            if not nxt or nxt == e then break end
            e = nxt
        end
        if e ~= xp0 then return doc:getTextFromXPointers(xp0, e) end
        return nil
    end)
    return ok and text or nil
end

-- -------------------------------------------------------------- auto reader --
-- Continuous read-aloud with automatic page turns (see autoreader.lua).

function Furigana:getAutoReader()
    if not self.autoreader then
        self.autoreader = require("autoreader").newController(self)
    end
    return self.autoreader
end

function Furigana:onToggleAutoRead()
    self:getAutoReader():toggle()
    return true
end

function Furigana:playAudioFile(path)
    local AudioPlayer = require("audioplayer")
    local ok, err = AudioPlayer:play(path)
    if not ok then
        UIManager:show(InfoMessage:new{
            text = T(_("Audio playback failed: %1"), tostring(err)),
            timeout = 3,
        })
    end
    return ok
end

--- Speak `text` (a word, sentence, or any selection) through VOICEVOX:
-- cached text plays immediately; otherwise the WAV is fetched in a
-- dismissable subprocess (a new tap dismisses the wait and takes over),
-- cached, then played. Returns true when playback was started or scheduled —
-- callers treat that as "the tap did something". Not gated on the tap-audio
-- toggle: the highlight-dialog and dictionary-window Speak buttons work
-- independently of it.
function Furigana:speakText(text)
    if not (text and text ~= "") then return false end
    local opts = self:voicevoxOpts()
    if opts.url == "" then return false end
    local path = self:audioCachePathFor(opts, text)
    if lfs.attributes(path, "mode") == "file" then
        self:playAudioFile(path)
        return true
    end
    local audio_dir = self.cache_dir .. "/audio"
    if lfs.attributes(audio_dir, "mode") ~= "directory" then
        util.makePath(audio_dir)
    end
    -- A precached word plays just as instantly; promote it into the permanent
    -- cache so the window pruning can no longer delete it (the user showed
    -- actual interest in this word).
    local pre = self:precachedAudioPathFor(opts, text)
    if lfs.attributes(pre, "mode") == "file" and os.rename(pre, path) then
        self:playAudioFile(path)
        return true
    end
    local tmp = path .. ".tmp"
    Trapper:wrap(function()
        local VoiceVox = require("voicevox")
        -- Words come back fast and a new tap should silently take over, so
        -- they get the invisible trap. Sentence/paragraph selections can
        -- legitimately take minutes on a slow (on-device) engine — show a
        -- visible "working…" trap so the wait is deliberate, not a hang;
        -- synthesis itself runs to completion (no socket timeout, see
        -- voicevox.lua), and tapping the trap is the way to cancel.
        local trap_widget = #text > 36
            and _("Generating audio… (tap to cancel)") or nil
        -- Hold the precache worker off the engine while the user is waiting
        -- for this very word.
        if self._precache then self._precache:setForegroundFetch(true) end
        local completed, ok, err = Trapper:dismissableRunInSubprocess(function()
            -- The subprocess writes the file itself; only simple values cross
            -- the process boundary.
            local fetched, ferr = VoiceVox.fetch(opts, text, tmp)
            return fetched == true, ferr and tostring(ferr) or nil
        end, trap_widget) -- nil: invisible trap widget, any tap dismisses
        if self._precache then self._precache:setForegroundFetch(false) end
        if not completed then
            os.remove(tmp)
            return
        end
        if not ok then
            os.remove(tmp)
            UIManager:show(InfoMessage:new{
                text = T(_("VOICEVOX request failed: %1"), tostring(err or "unknown error")),
                timeout = 3,
            })
            return
        end
        os.rename(tmp, path)
        self:playAudioFile(path)
    end)
    return true
end

function Furigana:promptVoicevoxUrl(touchmenu_instance)
    local InputDialog = require("ui/widget/inputdialog")
    local dialog
    dialog = InputDialog:new{
        title = _("VOICEVOX server URL"),
        input = self:voicevoxOpts().url,
        input_hint = "http://192.168.x.x:50021",
        buttons = {{
            {
                text = _("Cancel"),
                id = "close",
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = _("Save"),
                is_enter_default = true,
                callback = function()
                    local url = util.trim(dialog:getInputText() or "")
                    G_reader_settings:saveSetting("furigana_voicevox_url", url ~= "" and url or nil)
                    UIManager:close(dialog)
                    -- New server, new cache keys: re-target the precache.
                    if self._precache then self._precache:invalidate() end
                    self:precacheSchedule()
                    if touchmenu_instance then touchmenu_instance:updateItems() end
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Furigana:onCloseDocument()
    if self.autoreader then
        self.autoreader:stop() -- silent; also releases standby/screen holds
    end
    if self._precache then
        self._precache:stop()
    end
    -- Drop the kept Android MediaPlayer; audioplayer is package.loaded-cached,
    -- so it outlives this plugin instance.
    local ok, AudioPlayer = pcall(require, "audioplayer")
    if ok and AudioPlayer.release then
        AudioPlayer:release()
    end
end

-- ------------------------------------------------------------------- toggle --

-- Block-level HTML tags that visually break the text flow. crengine's text
-- search runs within a block, so the marker must not span across one or it
-- won't be findable in the target.
local FURI_BLOCK_TAGS = {
    p = true, br = true, div = true, li = true, td = true, tr = true,
    h1 = true, h2 = true, h3 = true, h4 = true, h5 = true, h6 = true,
    blockquote = true, hr = true, section = true, article = true,
    aside = true, pre = true,
}

-- Truncate `html` just before the first block-level tag that follows any text
-- content (leading wrapper tags are ignored). Keeps the marker inside one
-- paragraph/line.
local function clip_to_first_block(html)
    local i, got_text, len = 1, false, #html
    while i <= len do
        local lt = html:find("<", i, true)
        if not lt then return html end
        if lt > i then got_text = true end
        local gt = html:find(">", lt + 1, true)
        if not gt then return html end
        if got_text then
            local name = html:sub(lt, gt):match("^<%s*/?%s*([%a][%w]*)")
            if name and FURI_BLOCK_TAGS[name:lower()] then
                return html:sub(1, lt - 1)
            end
        end
        i = gt + 1
    end
    return html
end

-- crengine's text search only ever matches WITHIN a single text node (it walks
-- node by node, searching each node's text in isolation). The annotated copy
-- wraps every annotated word's base in its own <ruby> node, so a page's base
-- text is split across many tiny nodes there and a multi-word marker can never
-- match. The helpers below find runs of text that annotation leaves contiguous,
-- so we still have something searchable in the annotated copy.

-- A codepoint that annotation isolates into its own <ruby> base text node:
-- kanji, the 々 iteration mark, or a full-width digit (which gets a number
-- reading). A search anchor must not span any of these. Everything else (kana,
-- latin, punctuation…) is emitted as plain, contiguous text.
local function cp_in_ruby_base(cp)
    return (cp >= 0x4E00 and cp <= 0x9FFF)   -- CJK Unified Ideographs
        or (cp >= 0x3400 and cp <= 0x4DBF)   -- CJK Extension A
        or (cp >= 0xF900 and cp <= 0xFAFF)   -- CJK Compatibility Ideographs
        or cp == 0x3005                      -- 々 (kanji iteration mark)
        or (cp >= 0xFF10 and cp <= 0xFF19)   -- full-width digits ０-９
end

-- "Wordish" = a kana or Latin letter; used to keep anchors distinctive rather
-- than runs of bare punctuation/whitespace.
local function cp_is_wordish(cp)
    return (cp >= 0x3040 and cp <= 0x30FF)   -- hiragana + katakana
        or (cp >= 0xFF66 and cp <= 0xFF9F)   -- half-width katakana
        or (cp >= 0x41 and cp <= 0x5A) or (cp >= 0x61 and cp <= 0x7A) -- A-Z a-z
end

-- Split clean base text into the maximal runs that annotation keeps as a single
-- contiguous text node (runs free of any ruby-base codepoint). Each such run is
-- a candidate "anchor" that crengine can still find in the annotated copy.
-- Returns { { s = text, cps = codepoint_count, off = start_codepoint_index } },
-- keeping only reasonably distinctive runs (>= 4 chars, >= 2 wordish).
local function safe_anchors(s)
    local runs = {}
    local i, len, cp_idx = 1, #s, 0
    local start_byte, start_cp, run_cps, run_word = nil, 0, 0, 0
    local function close(byte_end)
        if start_byte and run_cps >= 4 and run_word >= 2 then
            local text = (s:sub(start_byte, byte_end):gsub("^%s+", ""):gsub("%s+$", ""))
            if #text > 0 then
                runs[#runs + 1] = { s = text, cps = run_cps, off = start_cp }
            end
        end
        start_byte, run_cps, run_word = nil, 0, 0
    end
    while i <= len do
        local b = s:byte(i)
        local cp, size
        if b < 0x80 then cp, size = b, 1
        elseif b < 0xE0 then cp, size = (b % 0x20) * 0x40 + ((s:byte(i + 1) or 0) % 0x40), 2
        elseif b < 0xF0 then cp, size = (b % 0x10) * 0x1000
            + ((s:byte(i + 1) or 0) % 0x40) * 0x40 + ((s:byte(i + 2) or 0) % 0x40), 3
        else cp, size = -1, 4 end
        if cp < 0 or cp_in_ruby_base(cp) then
            close(i - 1)
        else
            if not start_byte then start_byte, start_cp = i, cp_idx end
            run_cps = run_cps + 1
            if cp_is_wordish(cp) then run_word = run_word + 1 end
        end
        i = i + size
        cp_idx = cp_idx + 1
    end
    close(len)
    return runs
end

-- Anchor-search tuning (the fallback used when the whole-page marker can't match
-- because the target's base text is broken up by <ruby>). Only consider runs
-- starting within this many characters of the page top (so the match lands on
-- the right page); a run of at least this many characters is "distinctive"
-- enough to rarely recur; try at most this many anchors; and cap hits per anchor
-- (matching KOReader's own findall cap — each hit costs a selection-geometry
-- pass, and a distinctive anchor rarely recurs that many times anyway).
local ANCHOR_WINDOW_CP = 120
local ANCHOR_GOOD_CP = 6
local ANCHOR_MAX_TRY = 4
local ANCHOR_MAX_HITS = 5000

-- Anchors worth trying: distinctive runs (>= ANCHOR_GOOD_CP chars) first so
-- recurrences stay rare, and within each group the earliest (nearest the page
-- top) first so the restored position stays on the right page.
local function ordered_anchors(marker)
    local runs = safe_anchors(marker or "")
    local near = {}
    for _, r in ipairs(runs) do
        if r.off <= ANCHOR_WINDOW_CP then near[#near + 1] = r end
    end
    if #near == 0 then near = runs end -- page top is all kanji; use what we have
    table.sort(near, function(a, b)
        local ga, gb = a.cps >= ANCHOR_GOOD_CP, b.cps >= ANCHOR_GOOD_CP
        if ga ~= gb then return ga end -- distinctive runs first,
        return a.off < b.off           -- then earliest (nearest the page top)
    end)
    return near
end

-- Reading position as a 0..1 fraction of the book. Page counts differ between
-- the original and an annotated copy (and between levels), but the fraction is
-- approximately preserved because ruby is added throughout — close enough to
-- pick, among several text matches, the one nearest where the reader actually is.
local function book_fraction(doc)
    if not doc then return nil end
    local ok, frac = pcall(function()
        local total = doc:getPageCount()
        local cur = doc:getCurrentPage()
        if total and total > 0 and cur then return cur / total end
        return nil
    end)
    return ok and frac or nil
end

-- Fraction of the book at which an xpointer sits, in the given document.
local function xp_fraction(doc, xp)
    local ok, frac = pcall(function()
        local total = doc:getPageCount()
        local pg = doc:getPageFromXPointer(xp)
        if total and total > 0 and pg then return pg / total end
        return nil
    end)
    return ok and frac or nil
end

-- Capture a marker of clean base text starting at the current top-of-page,
-- regardless of whether the source is plain or already annotated. Uses
-- getHTMLFromXPointers + clip-to-block + strip_ruby + tag-strip so any
-- publisher/our furigana readings are removed and the marker stays inside one
-- paragraph (so crengine's search can find it whole in the new document).
function Furigana:capturePageMarker()
    if not (self.ui and self.ui.rolling and self.ui.document) then return nil end
    local doc = self.ui.document
    if not doc.getHTMLFromXPointers then return nil end
    local ok, marker = pcall(function()
        local top_xp = self.ui.rolling:getBookLocation()
        if not top_xp then return nil end
        local end_xp = top_xp
        -- Grab a generous window. On an annotated source, getNextVisibleChar
        -- counts the ruby <rt> reading characters too, so this shrinks after
        -- strip_ruby; clip_to_first_block also caps it at the paragraph end.
        for _ = 1, 400 do
            local nxt = doc:getNextVisibleChar(end_xp)
            if not nxt or nxt == end_xp then break end
            end_xp = nxt
        end
        if end_xp == top_xp then return nil end
        local html = doc:getHTMLFromXPointers(top_xp, end_xp, 0x1001)
        if not html or html == "" then return nil end
        html = clip_to_first_block(html)        -- never cross a block boundary
        html = EpubAnnotator.strip_ruby(html)
        local text = (html:gsub("<[^>]*>", "")) -- drop remaining tags
        -- Decode the common named entities so the marker matches crengine's
        -- rendered text on the target side.
        text = text:gsub("&nbsp;", " "):gsub("&amp;", "&"):gsub("&lt;", "<")
                   :gsub("&gt;", ">"):gsub("&quot;", '"'):gsub("&apos;", "'")
        text = util.cleanupSelectedText(text)
        text = (text:gsub("[\r\n]+", " "):gsub("%s%s+", " "))
        text = (text:gsub("^%s+", ""):gsub("%s+$", ""))
        if #text < 8 then return nil end           -- too short to be unique
        if #text > 600 then text = text:sub(1, 600) end -- search efficiently
        return text
    end)
    if ok then return marker end
    logger.dbg("furigana: capturePageMarker failed:", marker)
    return nil
end

-- How far (in book fraction) the best match may sit from the reader's position
-- before we treat the jump as low-confidence and offer a manual chooser. Ruby
-- drift between copies is typically < 5%; a chapters-apart mismatch is >> 10%.
local FURI_CONFIDENT_FRAC = 0.10

-- Among several marker/anchor matches, return the one whose position (as a book
-- fraction) is closest to where the reader was, plus that distance. This is what
-- avoids jumps to page 1 / an earlier chapter when the searched text recurs.
-- Without a source fraction we can't compare, so fall back to document order.
function Furigana:pickNearestMatch(doc, results, source_frac)
    if not source_frac then return results[1], nil end
    local best, best_d
    for _, r in ipairs(results) do
        local f = xp_fraction(doc, r.start)
        if f then
            local d = math.abs(f - source_frac)
            if not best_d or d < best_d then best, best_d = r, d end
        end
    end
    return best or results[1], best_d
end

-- Find the reader's previous position in the new document and jump there.
--
-- Because crengine search only matches within a single text node, and the
-- annotated copy splits each annotated word into its own <ruby> base node, the
-- whole-page marker can be found when the target keeps that text contiguous
-- (typically annotated -> original) but NOT in the annotated copy. So we:
--   1. try the whole marker (exact: it pins the page top), and failing that,
--   2. search for the most distinctive contiguous run of search-safe text near
--      the page top (an "anchor"), which annotation leaves intact.
-- In both cases, when the text recurs we pick the occurrence nearest the
-- reader's previous position, and offer a manual chooser when unsure.
function Furigana:restorePosition(new_ui, marker, fallback_xp, source_frac)
    if not (new_ui and new_ui.rolling and new_ui.document) then return end
    local doc = new_ui.document

    local function search(pattern, max_hits)
        if not (pattern and doc.findAllText) then return nil end
        -- pattern, case_insensitive, nb_context_words, max_hits, regex
        local ok, res = pcall(function()
            return doc:findAllText(pattern, false, 0, max_hits, false)
        end)
        if ok and type(res) == "table" and res[1] then return res end
        return nil
    end

    local best, best_d, best_results

    -- 1) Whole-page marker (exact when the target keeps the base text contiguous).
    local results = search(marker, 1000)
    if results then
        best, best_d = self:pickNearestMatch(doc, results, source_frac)
        best_results = results
    else
        -- 2) Annotated target: match a contiguous safe-text anchor near the top,
        --    trying the most distinctive ones until one lands confidently.
        local tried = 0
        for _, a in ipairs(ordered_anchors(marker)) do
            local res = search(a.s, ANCHOR_MAX_HITS)
            if res then
                local b, d = self:pickNearestMatch(doc, res, source_frac)
                d = d or math.huge
                if b and (best == nil or d < best_d) then
                    best, best_d, best_results = b, d, res
                end
                if best_d and best_d <= FURI_CONFIDENT_FRAC then break end
            end
            tried = tried + 1
            if tried >= ANCHOR_MAX_TRY then break end
        end
    end

    if not best then
        if fallback_xp then pcall(function() new_ui.rolling:onGotoXPointer(fallback_xp) end) end
        return
    end

    pcall(function() new_ui.rolling:onGotoXPointer(best.start) end)

    -- A single match in the whole book is unambiguous; otherwise offer the
    -- chooser unless we placed the jump confidently by reading position.
    local single = best_results and #best_results == 1
    local confident = source_frac and best_d and best_d ~= math.huge
        and best_d <= FURI_CONFIDENT_FRAC
    if not single and not confident then
        self:showMatchChooser(new_ui, best_results, source_frac)
    end
end

-- Show all marker matches (nearest to the reader's position first); tap to jump.
function Furigana:showMatchChooser(new_ui, results, source_frac)
    local KeyValuePage = require("ui/widget/keyvaluepage")
    local doc = new_ui.document

    local rows = {}
    for _, r in ipairs(results) do
        rows[#rows + 1] = { r = r, page = doc:getPageFromXPointer(r.start) or 0,
                            f = xp_fraction(doc, r.start) }
    end
    if source_frac then
        table.sort(rows, function(a, b)
            local da = a.f and math.abs(a.f - source_frac) or math.huge
            local db = b.f and math.abs(b.f - source_frac) or math.huge
            return da < db
        end)
    else
        table.sort(rows, function(a, b) return a.page < b.page end)
    end

    local kv = {}
    -- numeric loop: "for _, row" would shadow gettext's _ for the T(_(...))
    for i = 1, #rows do
        local row = rows[i]
        local snippet = ""
        local ok, s = pcall(function() return doc:getTextFromXPointers(row.r.start, row.r["end"], false) end)
        if ok and s then snippet = s:gsub("[\r\n]+", " "):sub(1, 40) end
        kv[#kv + 1] = {
            T(_("Page %1"), row.page),
            snippet,
            callback = function()
                pcall(function() new_ui.rolling:onGotoXPointer(row.r.start) end)
            end,
        }
    end
    UIManager:show(KeyValuePage:new{
        title = T(N_("Furigana: %1 possible position — tap to choose",
                     "Furigana: %1 possible positions — tap to choose", #results), #results),
        kv_pairs = kv,
    })
end

-- Reopen `path` in place, restoring the current reading position.
function Furigana:switchTo(path)
    local saved_xp, marker, source_frac
    if self.ui and self.ui.rolling then
        saved_xp = self.ui.rolling:getBookLocation()
        marker = self:capturePageMarker()
        source_frac = book_fraction(self.ui.document) -- measured in the source doc
    end
    self.ui:switchDocument(path, false, function(new_ui)
        self:restorePosition(new_ui, marker, saved_xp, source_frac)
    end)
end

function Furigana:generateThenSwitch(src, annotated)
    Trapper:wrap(function()
        Trapper:info(_("Loading Japanese dictionary…"))
        local ok_tok, tok = pcall(function() return self:getTokenizer() end)
        if not ok_tok or not tok then
            Trapper:reset()
            logger.err("furigana: failed to load dictionary:", tok)
            UIManager:show(InfoMessage:new{ text = _("Could not load the furigana dictionary.") })
            return
        end

        local tmp = annotated .. ".tmp"
        local aborted = false
        local progress = function(done, total)
            local go_on = Trapper:info(T(_("Adding furigana… %1 / %2"), done, total))
            if not go_on then aborted = true; return false end
            return true
        end
        local ok, err
        if annotated_ext(src) == "epub" then
            ok, err = EpubAnnotator.annotate_epub(tok, src, tmp, progress, self:getReplaceRuby())
        else
            ok, err = EpubAnnotator.annotate_html_file(tok, src, tmp, progress, self:getReplaceRuby())
        end
        Trapper:reset()
        tok = nil -- allow the dictionary to be collected

        if aborted then
            os.remove(tmp)
            return
        end
        if not ok then
            os.remove(tmp)
            logger.err("furigana: annotation failed:", err)
            UIManager:show(InfoMessage:new{ text = T(_("Furigana generation failed:\n%1"), tostring(err)) })
            return
        end

        os.rename(tmp, annotated)
        self:writeOriginalPath(annotated, src)
        self:rememberAuto(src, annotated) -- sticky furigana for this book
        -- Defer the document switch until after this coroutine unwinds.
        UIManager:nextTick(function() self:switchTo(annotated) end)
    end)
end

-- Open (or generate) the annotated copy of `src` at the current level.
function Furigana:openAnnotated(src)
    local annotated = self:annotatedPathFor(src)
    if lfs.attributes(annotated, "mode") == "file" then
        self:rememberAuto(src, annotated) -- sticky furigana for this book
        self:switchTo(annotated) -- cached: instant
    else
        self:generateThenSwitch(src, annotated)
    end
end

-- The original book path, whether we're currently viewing the original or an
-- annotated copy (read from the .src sidecar in the latter case).
function Furigana:currentSourcePath()
    if self:isShowingAnnotated() then
        return self:readOriginalPath(self.ui.document.file)
    end
    return self.ui.document.file
end

function Furigana:onToggleFurigana(touchmenu_instance)
    if not self:isSupportedDoc() then return end
    if touchmenu_instance then touchmenu_instance:closeMenu() end

    if self:isShowingAnnotated() then
        -- Turn off: return to the original book and stop auto-reopening it.
        local src = self:readOriginalPath(self.ui.document.file)
        if src and lfs.attributes(src, "mode") == "file" then
            self:forgetAuto(src)
            self:switchTo(src)
        else
            UIManager:show(InfoMessage:new{ text = _("Could not find the original book to switch back to.") })
        end
        return
    end

    self:openAnnotated(self.ui.document.file)
end

function Furigana:onToggleAutoOpen(touchmenu_instance)
    G_reader_settings:saveSetting("furigana_auto_open_enabled", not self:isAutoOpenEnabled())
    if touchmenu_instance then touchmenu_instance:updateItems() end
end

-- Change the selective level. If a furigana copy is currently showing, switch to
-- the copy for the new level (generating it if needed); otherwise just store it.
function Furigana:onSetMinGrade(min_grade, touchmenu_instance)
    G_reader_settings:saveSetting("furigana_min_grade", min_grade)
    if touchmenu_instance then touchmenu_instance:updateItems() end
    if self:isShowingAnnotated() then
        local src = self:readOriginalPath(self.ui.document.file)
        if src and lfs.attributes(src, "mode") == "file" then
            if touchmenu_instance then touchmenu_instance:closeMenu() end
            self:openAnnotated(src)
        end
    end
end

-- Toggle "replace the book's own furigana". Regenerates if currently showing.
function Furigana:onToggleReplaceRuby(touchmenu_instance)
    G_reader_settings:flipNilOrFalse("furigana_replace_native_ruby")
    if touchmenu_instance then touchmenu_instance:updateItems() end
    if self:isShowingAnnotated() then
        local src = self:readOriginalPath(self.ui.document.file)
        if src and lfs.attributes(src, "mode") == "file" then
            if touchmenu_instance then touchmenu_instance:closeMenu() end
            self:openAnnotated(src)
        end
    end
end

-- Delete cached annotated copies (and their .src/.tmp siblings) to free storage.
-- Keeps the currently-open annotated copy (and its sidecar) so the toggle still
-- works while reading it.
function Furigana:clearCache()
    local keep = {}
    if self:isShowingAnnotated() then
        local cur = self.ui.document.file
        keep[cur] = true
        keep[self:srcSidecarPath(cur)] = true
    end

    local files, total = {}, 0
    local function collect(dir)
        if lfs.attributes(dir, "mode") ~= "directory" then return end
        for f in lfs.dir(dir) do
            if f ~= "." and f ~= ".." then
                local p = dir .. "/" .. f
                if lfs.attributes(p, "mode") == "file" and not keep[p] then
                    files[#files + 1] = p
                    total = total + (lfs.attributes(p, "size") or 0)
                end
            end
        end
    end
    collect(self.cache_dir)
    collect(self.cache_dir .. "/audio") -- cached VOICEVOX word audio
    collect(self.cache_dir .. "/audio/precache") -- precached window audio
    collect(self.cache_dir .. "/audio/sentences") -- auto-reader sentence audio

    if #files == 0 then
        UIManager:show(InfoMessage:new{ text = _("The furigana cache is already empty.") })
        return
    end

    local mb = string.format("%.1f", total / 1048576)
    UIManager:show(ConfirmBox:new{
        text = T(N_("Delete %1 cached furigana file (%2 MB)?",
                    "Delete %1 cached furigana files (%2 MB)?", #files), #files, mb),
        ok_text = _("Delete"),
        ok_callback = function()
            local removed = 0
            for _, p in ipairs(files) do
                if os.remove(p) then removed = removed + 1 end
            end
            if self._precache then
                self._precache:invalidate()
                self:precacheSchedule()
            end
            UIManager:show(InfoMessage:new{
                text = T(N_("Deleted %1 file.", "Deleted %1 files.", removed), removed),
            })
        end,
    })
end

-- --------------------------------------------------------------------- menu --

-- Selective-furigana levels. Annotate a word only if its hardest kanji's grade
-- is >= `g`. Higher level => fewer readings (only harder kanji).
local GRADE_LEVELS = {
    { g = 1, text = _("All kanji") },
    { g = 2, text = _("School grade 2 and above") },
    { g = 3, text = _("School grade 3 and above") },
    { g = 4, text = _("School grade 4 and above") },
    { g = 5, text = _("School grade 5 and above") },
    { g = 6, text = _("School grade 6 and above") },
    { g = 7, text = _("Secondary-school Jōyō and above") },
    { g = 8, text = _("Jinmeiyō and rarer") },
    { g = 9, text = _("Non-Jōyō kanji only") },
}

-- Tap display modes (what a short tap on a word shows).
local TAP_MODES = {
    { mode = "popup", text = _("Reading popup"),
      help = _("A small popup with the word's reading right above it, like tapping a word in Anki. Tap the popup to open the full analysis.") },
    { mode = "popup_translate", text = _("Reading popup + translation"),
      help = _("The reading popup, with the word's English translation (Google Translate; needs a network connection) added underneath. The reading appears immediately; the translation line follows as soon as it arrives and is remembered for the session.") },
    { mode = "dict", text = _("Dictionary entry"),
      help = _("Look the word up like a normal dictionary lookup — in the single dictionary chosen below, or in all of them.") },
    { mode = "translate", text = _("Translation"),
      help = _("Show the word in the built-in translator (Google Translate; needs a network connection).") },
    { mode = "none", text = _("Nothing"),
      help = _("Show nothing. With word audio enabled, a tap only speaks the word.") },
}

function Furigana:genTapModeItems()
    local items = {}
    for _, m in ipairs(TAP_MODES) do
        local mode = m.mode
        items[#items + 1] = {
            text = m.text,
            checked_func = function() return self:getTapDisplayMode() == mode end,
            radio = true,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                G_reader_settings:saveSetting("furigana_tap_display", mode)
                if touchmenu_instance then touchmenu_instance:updateItems() end
            end,
            help_text = m.help,
        }
    end
    items[#items].separator = true
    items[#items + 1] = {
        text_func = function()
            return T(_("Dictionary: %1"), self:getTapDictName() or _("all dictionaries"))
        end,
        enabled_func = function() return self:getTapDisplayMode() == "dict" end,
        sub_item_table_func = function() return self:genTapDictItems() end,
        help_text = _("Which dictionary the 'Dictionary entry' tap mode uses."),
    }
    return items
end

function Furigana:genTapDictItems()
    local items = {
        {
            text = _("All dictionaries"),
            checked_func = function() return self:getTapDictName() == nil end,
            radio = true,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                G_reader_settings:delSetting("furigana_tap_dict")
                if touchmenu_instance then touchmenu_instance:updateItems() end
            end,
        },
    }
    local names = (self.ui and self.ui.dictionary and self.ui.dictionary.enabled_dict_names) or {}
    for _, name in ipairs(names) do
        local n = name
        items[#items + 1] = {
            text = n,
            checked_func = function() return self:getTapDictName() == n end,
            radio = true,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                G_reader_settings:saveSetting("furigana_tap_dict", n)
                if touchmenu_instance then touchmenu_instance:updateItems() end
            end,
        }
    end
    return items
end

function Furigana:genLevelItems()
    local items = {}
    for _, lvl in ipairs(GRADE_LEVELS) do
        local g = lvl.g
        items[#items + 1] = {
            text = lvl.text,
            checked_func = function() return self:getMinGrade() == g end,
            radio = true,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                self:onSetMinGrade(g, touchmenu_instance)
            end,
        }
    end
    return items
end

function Furigana:addToMainMenu(menu_items)
    menu_items.furigana_annotation = {
        text = _("Furigana"),
        sorting_hint = "search",
        sub_item_table = {
            {
                text = _("Show furigana for current book"),
                enabled_func = function() return self:isSupportedDoc() end,
                checked_func = function() return self:isShowingAnnotated() end,
                callback = function(touchmenu_instance)
                    self:onToggleFurigana(touchmenu_instance)
                end,
                help_text = _([[Generate furigana (ruby) readings for the current Japanese EPUB and reopen it with the readings shown.

The readings are generated on-device; the first run on a book may take a little while, after which the result is cached. Toggle again to return to the original book.]]),
            },
            {
                text_func = function()
                    -- numeric loop: "for _, m" would shadow gettext's _
                    local mode = self:getTapDisplayMode()
                    for i = 1, #TAP_MODES do
                        if TAP_MODES[i].mode == mode then
                            return T(_("On word tap show: %1"), TAP_MODES[i].text:lower())
                        end
                    end
                    return _("On word tap show…")
                end,
                sub_item_table_func = function() return self:genTapModeItems() end,
                help_text = _([[What tapping a Japanese word shows, without annotating the whole book: a small popup with its reading (like tapping a word in Anki), its entry from a dictionary of your choice, the built-in translator, or nothing. Word audio (below) plays in addition, independently of this choice.

Showing something on tap takes priority over the Japanese plugin's 'Tap a word to analyse it'; choose 'Nothing' (and disable tap audio) to get that back on single tap. 'Show furigana for word' can also be bound to any gesture.]]),
            },
            {
                text = _("Word audio (VOICEVOX)"),
                help_text = _([[Speak the tapped word using a self-hosted VOICEVOX engine (https://voicevox.hiroshiba.jp/). Run the engine on your PC and point the server URL at it; the device must reach it over the network (same Wi-Fi).

Works together with or independently of the reading popup: enable either one, both, or neither. Each word is fetched once and cached.]]),
                sub_item_table = {
                    {
                        text = _("Tap a word to hear it"),
                        checked_func = function() return self:isTapAudioEnabled() end,
                        keep_menu_open = true,
                        callback = function(touchmenu_instance)
                            G_reader_settings:flipNilOrFalse("furigana_tap_audio")
                            if self:isTapAudioEnabled() then
                                self:precacheSchedule()
                            elseif self._precache then
                                self._precache:stop()
                            end
                            if touchmenu_instance then touchmenu_instance:updateItems() end
                        end,
                        help_text = _([[Play the tapped word's audio. With the reading popup also enabled, you get both; with it disabled, tapping only speaks the word.

Audio is fetched from the configured VOICEVOX server on first use and cached. Tapping elsewhere while audio is still loading cancels it and reveals the new word instead.]]),
                    },
                    {
                        text = _("Precache nearby pages"),
                        checked_func = function() return self:isPrecacheEnabled() end,
                        enabled_func = function() return self:isTapAudioEnabled() end,
                        keep_menu_open = true,
                        callback = function(touchmenu_instance)
                            G_reader_settings:flipNilOrTrue("furigana_audio_precache")
                            if self:isTapAudioEnabled() and self:isPrecacheEnabled() then
                                self:precacheSchedule()
                            elseif self._precache then
                                self._precache:stop()
                            end
                            if touchmenu_instance then touchmenu_instance:updateItems() end
                        end,
                        help_text = _([[Quietly prepare the audio of every word on the two previous, the current and the two next pages in the background, so tapped words play instantly. Audio of pages you move away from is deleted again automatically; words you actually played are kept.

Needs the Japanese plugin and your dictionaries (to predict the words a tap would speak), and works in the original book, like tap audio itself.]]),
                    },
                    {
                        text_func = function()
                            return T(_("Server: %1"), self:voicevoxOpts().url)
                        end,
                        keep_menu_open = true,
                        callback = function(touchmenu_instance)
                            self:promptVoicevoxUrl(touchmenu_instance)
                        end,
                        help_text = _("The VOICEVOX engine's base URL, e.g. http://192.168.1.10:50021 (the engine listens on port 50021 by default)."),
                    },
                    {
                        text_func = function()
                            return T(_("Speaker ID: %1"), self:voicevoxOpts().speaker)
                        end,
                        keep_menu_open = true,
                        callback = function(touchmenu_instance)
                            local SpinWidget = require("ui/widget/spinwidget")
                            local VoiceVox = require("voicevox")
                            UIManager:show(SpinWidget:new{
                                title_text = _("VOICEVOX speaker ID"),
                                info_text = _("The voice/style id, as listed by the engine's /speakers endpoint. 3 = ずんだもん (normal)."),
                                value = tonumber(self:voicevoxOpts().speaker) or VoiceVox.DEFAULT_SPEAKER,
                                value_min = 0,
                                value_max = 999,
                                value_step = 1,
                                value_hold_step = 10,
                                default_value = VoiceVox.DEFAULT_SPEAKER,
                                callback = function(spin)
                                    G_reader_settings:saveSetting("furigana_voicevox_speaker", spin.value)
                                    -- New voice, new cache keys: re-target the precache.
                                    if self._precache then self._precache:invalidate() end
                                    self:precacheSchedule()
                                    if touchmenu_instance then touchmenu_instance:updateItems() end
                                end,
                            })
                        end,
                    },
                    {
                        text = _("Normalize audio volume"),
                        checked_func = function()
                            return G_reader_settings:nilOrTrue("furigana_voicevox_normalize")
                        end,
                        keep_menu_open = true,
                        callback = function(touchmenu_instance)
                            G_reader_settings:flipNilOrTrue("furigana_voicevox_normalize")
                            if touchmenu_instance then touchmenu_instance:updateItems() end
                        end,
                        help_text = _([[Level the loudness of the synthesized audio. VOICEVOX renders every request at whatever volume the voice model happens to produce, so consecutive words and sentences can come out noticeably louder or quieter than each other; this scales each newly fetched clip to the same speech level (peaks are never clipped).

Applies to audio fetched from now on — already-cached audio keeps its old level until it is re-fetched (clear the furigana cache to renew everything at once).]]),
                    },
                    {
                        text_func = function()
                            return (self.autoreader and self.autoreader:isActive())
                                and _("Stop auto reader") or _("Auto reader (read aloud)")
                        end,
                        enabled_func = function()
                            return self.ui ~= nil and self.ui.rolling ~= nil
                                and not self:isShowingAnnotated()
                        end,
                        callback = function(touchmenu_instance)
                            if touchmenu_instance then touchmenu_instance:closeMenu() end
                            self:getAutoReader():toggle()
                        end,
                        help_text = _([[Read the book aloud through VOICEVOX: starting at the top of the current page, every sentence is spoken in order, pages turn by themselves, and upcoming sentences are synthesized while one is playing, so the audio flows without interruptions.

Tap the page (or turn it yourself) to stop. Works in the original (un-annotated) book. 'Auto reader (VOICEVOX)' can also be bound to a gesture.]]),
                    },
                    {
                        text = _("Test audio (食べる)"),
                        keep_menu_open = true,
                        callback = function() self:speakText("食べる") end,
                        help_text = _("Fetch and play a sample word from the configured server, to check the connection and the chosen speaker."),
                    },
                },
            },
            {
                text = _("Reading level"),
                sub_item_table_func = function() return self:genLevelItems() end,
                help_text = _([[Choose which kanji get furigana, by Japanese school grade. "All kanji" annotates everything; higher levels show readings only for harder/less common kanji.

Changing the level regenerates the annotated copy (cached per level).]]),
            },
            {
                text = _("Replace the book's own furigana"),
                checked_func = function() return self:getReplaceRuby() end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    self:onToggleReplaceRuby(touchmenu_instance)
                end,
                help_text = _([[Some books ship with their own furigana. By default we keep it and only add readings where it is missing.

Enable this to strip the book's embedded furigana first, so every reading is ours and obeys the reading-level setting (uniform style, no publisher readings on easy kanji).]]),
            },
            {
                text = _("Reopen furigana version automatically"),
                checked_func = function() return self:isAutoOpenEnabled() end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    self:onToggleAutoOpen(touchmenu_instance)
                end,
                help_text = _("When you open a book that you last read with furigana, automatically reopen the furigana version. Turning furigana off for a book stops this until you turn it on again."),
            },
            {
                text = _("Clear furigana cache"),
                keep_menu_open = true,
                separator = true,
                callback = function() self:clearCache() end,
                help_text = _("Delete cached annotated copies and cached word audio to free storage. The book you are currently reading with furigana is kept; everything else is removed and regenerated on demand."),
            },
        },
    }
end

return Furigana
