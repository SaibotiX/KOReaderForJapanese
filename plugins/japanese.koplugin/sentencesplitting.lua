--- Sentence splitting: read the book sentence by sentence with the volume keys.
--
-- While enabled, the page-turn keys (the volume buttons on Android) no longer
-- turn pages: each press steps to the next / previous sentence, marks its
-- first character with a faint (crengine-selection) cursor, and — per the
-- "On each step" toggles — speaks it through VOICEVOX and/or shows it in a
-- small popup right above the sentence (below it when there is no room;
-- bottom of the screen only when it cannot be located at all — shortened
-- prefixes and occurrence counting locate it through inline formatting).
-- The popup holds the sentence with furigana spliced in (toggleable; the
-- Japanese line itself can be hidden to leave only the translation) and its
-- translation underneath (local LLM server first when configured, Google
-- otherwise; swapped in as soon as it arrives). Text on the popup can be
-- hold-selected for a dictionary lookup. Stepping past either end of the
-- page turns it; a sentence that runs across a page boundary is completed
-- with the next page's beginning, exactly like the auto reader. A double
-- press of a stepping key runs that key's own configured action (media
-- volume, stop/start, replay, translation, furigana, popup on demand, or a
-- whole page turn — the two keys are configured independently); and the
-- highlight dialog's "Read sentences from here" starts at any sentence
-- (Controller:startAt).
--
-- Smoothness comes from working ahead: two independent background
-- subprocesses (one per server — VOICEVOX audio, local-LLM/Google
-- translation) keep the current sentence plus the next two cached (WAVs in
-- the auto reader's sentence cache — the two features share files;
-- translations as small text files), so stepping forward is instant. Both
-- lanes always serve the sentence the reader is on: work for a sentence that
-- was stepped past is killed, never queued through. The page-window word
-- precache is paused (fg.lock) while we hold the engine.
--
-- The heavy lifting is reused from the furigana plugin (sentence splitter,
-- VOICEVOX client, audio player, cache keying, ruby extraction); this module
-- resolves those through package.path, so it needs that plugin enabled.
--
-- The pure logic (page building, boundary carry, ruby display, stepping) is
-- unit-tested standalone:  lua tools/run_sentencesplitting_test.lua
--
-- @module koplugin.japanese.sentencesplitting

local AutoReader = require("autoreader") -- furigana plugin: pure sentence splitter
local Precache = require("precache")     -- furigana plugin: pure audio cache keying

local SentenceSplitting = {}

SentenceSplitting.LOOKAHEAD = 2          -- sentences precached ahead (audio + translation)
SentenceSplitting.POLL_S = 0.5           -- fetch-subprocess poll interval
SentenceSplitting.MAX_TRIES = 2          -- per WAV / per translation, then give up
SentenceSplitting.MAX_PAGE_SEEK = 5      -- pages scanned for text before giving up
SentenceSplitting.KEEP_TRANSLATIONS = 400 -- cached translation files kept on stop()
-- Whole sentences are bigger than the auto reader's clause chunks, so the
-- background fetches get roomier per-request timeouts and longer hung-fetch
-- deadlines; the user is never blocked on them (the popup shows immediately).
-- The translation lane's deadline covers a slow local-LLM generation plus
-- the Google fallback after it.
SentenceSplitting.SYNTH_BLOCK_TIMEOUT = 45
SentenceSplitting.SYNTH_TOTAL_TIMEOUT = 120
SentenceSplitting.FETCH_DEADLINE_S = 150
SentenceSplitting.TR_FETCH_DEADLINE_S = 180
-- A second tap on the popup within this window means "double tap" (replay);
-- a lone tap toggles the translation once the window has passed. Detected
-- here rather than through GestureDetector's double_tap, which is usually
-- disabled globally because it would delay every page-turn tap.
SentenceSplitting.DOUBLE_TAP_S = 0.35
-- Same idea for the stepping keys: with a double-press action configured
-- (see Controller:onDoublePress), a second press of the same key within this
-- window fires the action; the single step runs when the window passes.
-- With the action set to "none" (the default) there is no delay at all.
SentenceSplitting.DOUBLE_PRESS_S = 0.35

-- djb2 hash -> 8 hex chars, same as the furigana plugin's cache keying.
local function hash_str(s)
    local h = 5381
    for i = 1, #s do h = (h * 33 + s:byte(i)) % 4294967296 end
    return string.format("%08x", h)
end
SentenceSplitting.hash = hash_str

-- ------------------------------------------------------------- pure helpers --

--- The sentences of one page: `text` (after dropping `skip` bytes already
-- spoken for by the previous page's tail) split with the auto reader's rules,
-- the last sentence completed from `next_text` when it runs over the page
-- break. Returns sents, consumed_next (bytes of next_text used), carry_len
-- (bytes appended to the last sentence — its on-page part ends there, which
-- is what the popup anchor search needs).
function SentenceSplitting.buildPage(text, next_text, skip)
    local raw = text or ""
    if skip and skip > 0 then
        raw = raw:sub(skip + 1)
    end
    local sents, last_incomplete, open_depth = AutoReader.splitSentences(raw)
    local consumed = 0
    local carry_len = 0
    if last_incomplete and #sents > 0 and next_text and next_text ~= "" then
        local head, c = AutoReader.sentenceHead(next_text, AutoReader.HEAD_MAX_BYTES, open_depth)
        if head then
            if head ~= "" then
                sents[#sents] = sents[#sents] .. head
                carry_len = #head
            end
            consumed = c
        end
    end
    return sents, consumed, carry_len
end

--- How many bytes of `text` the previous page's spilled-over sentence
-- consumes — what buildPage() on the previous page would have carried. Lets a
-- page be entered from either direction with the same sentence boundaries.
function SentenceSplitting.computeSkip(prev_text, text)
    if not prev_text or prev_text == "" or not text or text == "" then return 0 end
    local sents, last_incomplete, open_depth = AutoReader.splitSentences(prev_text)
    if last_incomplete and #sents > 0 then
        local head, consumed = AutoReader.sentenceHead(text, AutoReader.HEAD_MAX_BYTES, open_depth)
        if head then return consumed end
    end
    return 0
end

--- The popup line for a sentence with furigana spliced in after each
-- annotated run, e.g. 私（わたし）は学校（がっこう）へ行（い）った。
-- `annotated` is the tokenizer's ruby HTML for `original`. Returns nil when
-- the annotation cannot be trusted (round-trip mismatch); the caller falls
-- back to the bare sentence.
function SentenceSplitting.rubyDisplay(annotated, original)
    local ReadingExtractor = require("readingextractor")
    local runs, plain = ReadingExtractor.parse(annotated)
    if plain ~= original then return nil end
    if #runs == 0 then return original end
    return ReadingExtractor.display(plain, runs, 0, #plain) or original
end

-- The first `n_chars` codepoints of a UTF-8 string.
local function utf8_prefix(s, n_chars)
    local i, count = 1, 0
    while i <= #s and count < n_chars do
        local _, len = Precache.utf8At(s, i)
        i = i + len
        count = count + 1
    end
    return s:sub(1, i - 1)
end

--- Progressively simpler search needles for locating a sentence on the page.
-- crengine's findText only matches within a single text node, so newlines and
-- inline formatting (bold, links, native ruby) inside the sentence break the
-- full-text search; shorter prefixes of the first line are much more likely
-- to sit in one node. Anchoring to the sentence's start is always right —
-- the popup only needs to know where the sentence begins.
function SentenceSplitting.anchorNeedles(sentence, carry_len)
    local s = sentence or ""
    if carry_len and carry_len > 0 then
        s = s:sub(1, #s - carry_len)
    end
    s = s:gsub("^%s+", ""):gsub("%s+$", "")
    local needles = {}
    local function add(n)
        n = n:gsub("^%s+", ""):gsub("%s+$", "")
        if n ~= "" and n ~= needles[#needles] then
            needles[#needles + 1] = n
        end
    end
    if s == "" then return needles end
    add(s)
    local first_line = s:match("^[^\n]+")
    if first_line then add(first_line) end
    local line = needles[#needles] or s
    for _, n_chars in ipairs({ 12, 6, 3 }) do
        add(utf8_prefix(line, n_chars))
    end
    return needles
end

--- Byte positions (1-based) of each sentence within the page text, found by
-- sequential plain search starting after the skipped carry head. Sentences
-- are verbatim substrings of the text (the splitter only trims and caps
-- them); the last one drops its carried-over completion first. A sentence
-- that cannot be located gets nil (the search continues after the previous
-- hit).
function SentenceSplitting.sentencePositions(text, sents, skip, carry_len)
    local out = {}
    local pos = (skip or 0) + 1
    for i = 1, #sents do
        local s = sents[i]
        if i == #sents and (carry_len or 0) > 0 then
            s = s:sub(1, #s - carry_len)
        end
        local st = s ~= "" and text:find(s, pos, true) or nil
        out[i] = st
        if st then pos = st + #s end
    end
    return out
end

--- Which (1-based, non-overlapping) occurrence of `needle` within `text`
-- is the one starting at (or right before) `sent_pos` — used to pick the
-- matching hit among several findText results when a shortened needle
-- appears earlier on the page too.
function SentenceSplitting.occurrenceIndex(text, needle, sent_pos)
    local count, from = 0, 1
    while true do
        local st = text:find(needle, from, true)
        if not st or st >= sent_pos then break end
        count = count + 1
        from = st + #needle
    end
    return count + 1
end

--- The index of the sentence containing byte position `byte_pos` of the page
-- text (the last sentence starting at or before it); 1 when it lies before
-- every located sentence. Used by "read sentences from here".
function SentenceSplitting.sentenceIndexAt(positions, sents, byte_pos)
    local best = 1
    for i = 1, #sents do
        local st = positions[i]
        if st then
            if st <= byte_pos then
                best = i
            else
                break
            end
        end
    end
    return best
end

-- --------------------------------------------------------------- controller --

local Controller = {}
Controller.__index = Controller

function SentenceSplitting.newController(plugin)
    local self = setmetatable({
        plugin = plugin,   -- the japanese.koplugin instance (for ui + tokenizer)
        session = nil,     -- { page, sents, idx, display, next_sents }
        token = 0,         -- bumped on every step/reset; stale results are dropped
        fetch_wav = nil,   -- in-flight audio subprocess { pid, started, text, out }
        fetch_tr = nil,    -- in-flight translation subprocess (same shape)
        wav_tries = {},    -- text -> attempts (given up after MAX_TRIES)
        tr_tries = {},
        key_seqs = nil,    -- { { seq, dir } } captured from the deactivated bindings
        tr_visible = true, -- session-level: a single tap on the popup flips it
        _zombies = {},     -- killed fetches awaiting collection
        _await_play = nil, -- sentence text whose audio should play the moment it lands
    }, Controller)
    self._poll_fn = function() self:pollFetch() end
    -- A lone popup tap, once the double-tap window has passed.
    self._tap_timeout_fn = function()
        self._tap_pending = false
        if self.popup then
            self:toggleTranslation()
        end
    end
    return self
end

function Controller:notify(text, timeout)
    local UIManager = require("ui/uimanager")
    local InfoMessage = require("ui/widget/infomessage")
    UIManager:show(InfoMessage:new{ text = text, timeout = timeout or 3 })
end

function Controller:furigana()
    return self.plugin.ui and self.plugin.ui.furigana
end

function Controller:curPage()
    local ok, page = pcall(function() return self.plugin.ui.document:getCurrentPage() end)
    return ok and page or nil
end

function Controller:pageCount()
    local ok, total = pcall(function() return self.plugin.ui.document:getPageCount() end)
    return ok and total or nil
end

function Controller:pageText(page)
    local furigana = self:furigana()
    if not (furigana and furigana.pageText and page and page >= 1) then return nil end
    local total = self:pageCount()
    if total and page > total then return nil end
    return furigana:pageText(page)
end

-- ------------------------------------------------------- per-step actions --
-- What a stepping key press does, besides moving the marker: any combination
-- of audio, popup, Japanese sentence line (with furigana), and translation
-- can be enabled — or none, which turns the keys into a pure sentence cursor
-- for skipping around.

function Controller:audioEnabled()
    return G_reader_settings:nilOrTrue("language_japanese_sentence_audio")
end

function Controller:popupEnabled()
    return G_reader_settings:nilOrTrue("language_japanese_sentence_popup")
end

--- Whether the popup shows the Japanese sentence itself; turned off, only the
-- translation line remains (e.g. reading practice with an English safety net).
function Controller:showJpEnabled()
    return G_reader_settings:nilOrTrue("language_japanese_sentence_show_jp")
end

function Controller:furiganaEnabled()
    return G_reader_settings:nilOrTrue("language_japanese_sentence_furigana")
end

function Controller:translateEnabled()
    return G_reader_settings:nilOrTrue("language_japanese_sentence_translate")
end

--- The configured double-press action for one stepping key ("none" = plain
-- stepping, no delay for that key). Each key (next / previous) has its own
-- action, so e.g. "replay" can sit on volume-up with volume-down left plain.
-- The pre-split single setting is honored as a fallback for both keys.
function Controller:doublePressAction(dir)
    local key = dir > 0 and "language_japanese_sentence_doublepress_next"
        or "language_japanese_sentence_doublepress_prev"
    return G_reader_settings:readSetting(key)
        or G_reader_settings:readSetting("language_japanese_sentence_doublepress")
        or "none"
end

--- The local LLM translator's opts (nil when disabled): translations then try
-- it before Google, and being offline no longer matters for them.
function Controller:localTranslatorOpts()
    if self.plugin.localTranslatorOpts then
        return self.plugin:localTranslatorOpts()
    end
    return nil
end

--- Whether the device has a network connection. Translations need one; the
-- audio often does not (the VOICEVOX engine may run on the device itself),
-- so this is what distinguishes "translation disabled" from "offline".
-- Errs on the side of true, so a failed check never blocks a fetch attempt.
function Controller:isOnline()
    local ok, NetworkMgr = pcall(require, "ui/network/manager")
    if not ok or not NetworkMgr.isConnected then return true end
    local ok2, connected = pcall(NetworkMgr.isConnected, NetworkMgr)
    return not ok2 or connected == true
end

function Controller:voicevoxOpts()
    local furigana = self:furigana()
    if furigana and furigana.voicevoxOpts then return furigana:voicevoxOpts() end
    return { url = "", speaker = 0 }
end

-- ------------------------------------------------------------------- caches --

function Controller:wavDir()
    -- The auto reader's sentence cache: same keying, interchangeable files,
    -- and its post-session pruning keeps the directory bounded.
    return self:furigana().cache_dir .. "/audio/sentences"
end

function Controller:trDir()
    if not self._tr_dir then
        local DataStorage = require("datastorage")
        self._tr_dir = DataStorage:getDataDir() .. "/cache/japanese_sentences"
    end
    return self._tr_dir
end

function Controller:ensureDir(dir)
    local lfs = require("libs/libkoreader-lfs")
    if lfs.attributes(dir, "mode") ~= "directory" then
        require("util").makePath(dir)
    end
end

--- Existing audio for `text` wherever it may already live (sentence cache,
-- permanent word cache, page precache); the sentence-cache path is the
-- synthesis target otherwise.
function Controller:wavFor(text)
    local lfs = require("libs/libkoreader-lfs")
    local opts = self:voicevoxOpts()
    local key = Precache.audioKeyFor(opts, text)
    local cache_dir = self:furigana().cache_dir
    local candidates = {
        self:wavDir() .. "/" .. key .. ".wav",
        cache_dir .. "/audio/" .. key .. ".wav",
        cache_dir .. "/audio/precache/" .. key .. ".wav",
    }
    for _, p in ipairs(candidates) do
        if lfs.attributes(p, "mode") == "file" then return p, true end
    end
    return candidates[1], false
end

function Controller:targetLang()
    local ok, Translator = pcall(require, "ui/translator")
    local lang = ok and Translator.getTargetLanguage and Translator:getTargetLanguage()
    return lang or "en"
end

function Controller:trPath(text)
    return self:trDir() .. "/" .. hash_str(self:targetLang() .. "|" .. text) .. ".txt"
end

function Controller:cachedTranslation(text)
    local fh = io.open(self:trPath(text), "r")
    if not fh then return nil end
    local tr = fh:read("*a")
    fh:close()
    tr = tr and tr:gsub("^%s+", ""):gsub("%s+$", "") or ""
    return tr ~= "" and tr or nil
end

--- Keep the newest `keep` files of `dir`, drop the rest (same policy as the
-- auto reader's sentence pruning).
function SentenceSplitting.pruneDir(dir, keep)
    local lfs = require("libs/libkoreader-lfs")
    if lfs.attributes(dir, "mode") ~= "directory" then return end
    local files = {}
    for f in lfs.dir(dir) do
        if f ~= "." and f ~= ".." then
            local path = dir .. "/" .. f
            local attr = lfs.attributes(path)
            if attr and attr.mode == "file" then
                files[#files + 1] = { path = path, mtime = attr.modification or 0 }
            end
        end
    end
    if #files <= keep then return end
    table.sort(files, function(a, b) return a.mtime > b.mtime end)
    for i = keep + 1, #files do
        os.remove(files[i].path)
    end
end

-- ------------------------------------------------------------ key hijacking --

--- While the feature is on, deactivate ReaderRolling's page-turn key bindings
-- (is_inactive, so KeyPress events fall through to the plugin) and remember
-- their key sequences: we step sentences on exactly the keys that would have
-- turned the page, whatever the device's layout. Touch page turns stay as
-- they are. Re-applied on top of any re-registration (e.g. a keyboard being
-- plugged in rebuilds the tables).
function Controller:applyKeys(enable)
    local rolling = self.plugin.ui and self.plugin.ui.rolling
    if not (rolling and rolling.key_events) then return end
    self.key_seqs = nil
    for name, dir in pairs({ GotoNextView = 1, GotoPrevView = -1 }) do
        local binding = rolling.key_events[name]
        if binding then
            binding.is_inactive = enable or nil
            if enable and binding[1] then
                self.key_seqs = self.key_seqs or {}
                self.key_seqs[#self.key_seqs + 1] = { seq = binding[1], dir = dir }
            end
        end
    end
    if enable and rolling.registerKeyEvents and not rolling._japanese_sentence_rke then
        rolling._japanese_sentence_rke = rolling.registerKeyEvents
        local ctrl = self
        rolling.registerKeyEvents = function(r, ...)
            r._japanese_sentence_rke(r, ...)
            if ctrl.plugin.isSentenceSplittingEnabled and ctrl.plugin:isSentenceSplittingEnabled() then
                ctrl:applyKeys(true)
            end
        end
    end
end

--- KeyPress handler (delegated from the plugin): a key that would have turned
-- the page steps a sentence instead. Returns true when consumed.
function Controller:onKeyPress(key)
    if not self.key_seqs then return end
    for _, entry in ipairs(self.key_seqs) do
        if key:match(entry.seq) then
            self:onStep(entry.dir)
            return true
        end
    end
end

--- The sequences the popup should bind (it is the top window while shown, so
-- it must handle the keys itself). dir 1 = next, -1 = previous.
function Controller:seqFor(dir)
    for _, entry in ipairs(self.key_seqs or {}) do
        if entry.dir == dir then return entry.seq end
    end
    return nil
end

-- ----------------------------------------------------------------- stepping --

function Controller:buildAt(page)
    local text = self:pageText(page) or ""
    local skip = page > 1 and SentenceSplitting.computeSkip(self:pageText(page - 1), text) or 0
    local sents, _, carry_len = SentenceSplitting.buildPage(text, self:pageText(page + 1) or "", skip)
    -- text/skip are kept for locating sentences on the page (anchor
    -- disambiguation, "read sentences from here").
    return { page = page, text = text, skip = skip, sents = sents, idx = 0, carry_len = carry_len }
end

--- Every stepping key press funnels through here (the reader-level KeyPress
-- and the popup's own bindings). With a double-press action configured on a
-- key, its first press is held back for DOUBLE_PRESS_S: a second press of the
-- same key within the window fires that key's action instead of two steps; a
-- press of the other key flushes the held step first. A key whose action is
-- "none" (the default) steps immediately, without any delay — the two keys
-- are fully independent.
function Controller:onStep(dir)
    local UIManager = require("ui/uimanager")
    if self._pending_step_dir == dir then
        UIManager:unschedule(self._pending_step_fn)
        self._pending_step_dir = nil
        return self:onDoublePress(dir)
    end
    if self._pending_step_dir ~= nil then
        -- The other key: the held press was a real (single) step.
        UIManager:unschedule(self._pending_step_fn)
        local held = self._pending_step_dir
        self._pending_step_dir = nil
        self:stepNow(held)
    end
    if self:doublePressAction(dir) == "none" then
        return self:stepNow(dir)
    end
    self._pending_step_dir = dir
    self._pending_step_fn = self._pending_step_fn or function()
        local d = self._pending_step_dir
        self._pending_step_dir = nil
        if d then self:stepNow(d) end
    end
    UIManager:scheduleIn(SentenceSplitting.DOUBLE_PRESS_S, self._pending_step_fn)
    return true
end

function Controller:cancelPendingStep()
    if self._pending_step_dir == nil then return end
    self._pending_step_dir = nil
    if self._pending_step_fn then
        require("ui/uimanager"):unschedule(self._pending_step_fn)
    end
end

--- One step: dir 1 = next sentence, -1 = previous. The first press of
-- either key starts at the current page's first sentence.
function Controller:stepNow(dir)
    local p = self.plugin
    if not (p.ui and p.ui.rolling and p.ui.document) then return false end
    local _ = require("gettext")
    local furigana = self:furigana()
    if not furigana then
        self:notify(_("Sentence splitting needs the Furigana plugin."))
        return true
    end
    if furigana.isShowingAnnotated and furigana:isShowingAnnotated() then
        self:notify(_("Sentence splitting works in the original book — turn 'Show furigana for current book' off first."))
        return true
    end
    -- While the auto reader speaks, a page key means "stop it" (like a tap).
    if furigana.autoreader and furigana.autoreader:isActive() then
        furigana.autoreader:stop(_("Auto reader stopped"))
        return true
    end

    local cur = self:curPage()
    if not cur then return true end
    if not self.session or self.session.page ~= cur then
        self.session = self:buildAt(cur)
    end
    local s = self.session
    if s.idx == 0 then
        if #s.sents == 0 then return self:seekPage(dir >= 0 and 1 or -1) end
        s.idx = 1
    elseif dir > 0 then
        if s.idx >= #s.sents then return self:seekPage(1) end
        s.idx = s.idx + 1
    else
        if s.idx <= 1 then return self:seekPage(-1) end
        s.idx = s.idx - 1
    end
    self:present()
    return true
end

--- A double press of a stepping key runs that key's own configured action.
-- dir is the key's direction, so direction-aware actions do the natural
-- thing (volume up/down, page forward/back).
function Controller:onDoublePress(dir)
    local action = self:doublePressAction(dir)
    if action == "volume" then
        self:adjustVolume(dir)
    elseif action == "toggle" then
        -- Stop/disable ↔ enable lives in the plugin (it owns the setting and
        -- the key bindings).
        if self.plugin.onToggleSentenceSplitting then
            self.plugin:onToggleSentenceSplitting()
        end
    elseif action == "replay" then
        self:replay()
    elseif action == "translation" then
        self:toggleTranslation()
    elseif action == "furigana" then
        self:toggleFurigana()
    elseif action == "popup" then
        self:togglePopupNow()
    elseif action == "page" then
        -- Jump a whole page without stepping through its sentences; the next
        -- single press starts at the new page's first sentence.
        self:reset()
        self:flip(dir)
    end
    return true
end

--- Double-press "furigana": flip the popup's furigana splicing and rebuild
-- the current display so the change shows immediately (on the popup when one
-- is up; otherwise the new choice simply applies from the next popup on).
function Controller:toggleFurigana()
    G_reader_settings:flipNilOrTrue("language_japanese_sentence_furigana")
    local s = self.session
    if not (s and s.idx > 0) then
        local _ = require("gettext")
        self:notify(self:furiganaEnabled() and _("Popup furigana on.")
            or _("Popup furigana off."), 2)
        return
    end
    local text = s.sents[s.idx]
    s.display = self:showJpEnabled()
        and (self:furiganaEnabled() and self:annotate(text) or text) or nil
    if self.popup then
        local tr = self:translateEnabled() and self.tr_visible
            and self:cachedTranslation(text) or nil
        self:showPopup(s.display, tr)
    end
end

--- Double-press "popup": summon the current sentence's bubble on demand —
-- even with the per-step popup switched off (pure-cursor reading with an
-- occasional peek) — or dismiss the one showing. Starts the session at the
-- page's first sentence when nothing is selected yet.
function Controller:togglePopupNow()
    local UIManager = require("ui/uimanager")
    if self.popup then
        UIManager:close(self.popup)
        self.popup = nil
        return
    end
    local s = self.session
    if not (s and s.idx > 0) then
        self:stepNow(1)
        s = self.session
        if not (s and s.idx > 0) or self.popup then
            return -- nothing to show, or the step already brought the popup up
        end
    end
    local text = s.sents[s.idx]
    if s.display == nil and self:showJpEnabled() then
        s.display = self:furiganaEnabled() and self:annotate(text) or text
    end
    local tr
    if self:translateEnabled() and self.tr_visible then
        tr = self:cachedTranslation(text)
    end
    self:showPopup(s.display, tr)
    if self:translateEnabled() and self.tr_visible and not tr then
        self:kickFetch() -- a shown popup makes its translation wanted
    end
end

--- Raise/lower the real media volume (double-press "volume" action):
-- Android's AudioManager, with the system volume UI shown. jint arguments
-- must cross the JNI varargs as int32_t cdata (plain Lua numbers would be
-- promoted to double and land in the wrong registers).
function Controller:adjustVolume(dir)
    local _ = require("gettext")
    local Device = require("device")
    if not Device:isAndroid() then
        self:notify(_("Volume control is only available on Android."), 2)
        return
    end
    local ok, err = pcall(function()
        local ffi = require("ffi")
        local android = require("android")
        android.jni:context(android.app.activity.vm, function(jni)
            local svc = jni.env[0].NewStringUTF(jni.env, "audio")
            local am = jni:callObjectMethod(android.app.activity.clazz,
                "getSystemService", "(Ljava/lang/String;)Ljava/lang/Object;", svc)
            jni.env[0].DeleteLocalRef(jni.env, svc)
            if am == nil then
                error("no AudioManager")
            end
            -- STREAM_MUSIC = 3; ADJUST_RAISE = 1 / ADJUST_LOWER = -1;
            -- FLAG_SHOW_UI = 1.
            jni:callVoidMethod(am, "adjustStreamVolume", "(III)V",
                ffi.new("int32_t", 3),
                ffi.new("int32_t", dir > 0 and 1 or -1),
                ffi.new("int32_t", 1))
            jni.env[0].DeleteLocalRef(jni.env, am)
        end)
    end)
    if not ok then
        local logger = require("logger")
        logger.warn("sentencesplitting: volume adjust failed:", err)
    end
end

--- Start reading at the sentence containing byte position `byte_pos` of the
-- current page's text (1-based, in the same extraction as pageText) — used by
-- the highlight dialog's "read sentences from here". Builds a fresh session
-- and presents that sentence. Returns true when something was presented.
function Controller:startAt(byte_pos)
    local cur = self:curPage()
    if not cur then return false end
    self.session = self:buildAt(cur)
    local s = self.session
    if #s.sents == 0 then
        self:notify(require("gettext")("No sentence found on this page."), 2)
        return false
    end
    local positions = SentenceSplitting.sentencePositions(s.text, s.sents, s.skip, s.carry_len)
    s.idx = SentenceSplitting.sentenceIndexAt(positions, s.sents, byte_pos or 1)
    self:present()
    return true
end

--- Step over a page boundary: flip, land on the first (going forward) or last
-- (going back) sentence of the first page that has any. Pages without
-- speakable text (images…) are skipped, up to MAX_PAGE_SEEK.
function Controller:seekPage(dir)
    local _ = require("gettext")
    local edge_msg = dir > 0 and _("End of book — no further sentence.")
        or _("Beginning of book — no previous sentence.")
    for _ = 1, SentenceSplitting.MAX_PAGE_SEEK do
        if not self:flip(dir) then
            self:notify(edge_msg, 2)
            return true
        end
        local page = self:curPage()
        self.session = self:buildAt(page)
        if #self.session.sents > 0 then
            self.session.idx = dir > 0 and 1 or #self.session.sents
            self:present()
            return true
        end
    end
    self:notify(_("No sentence found nearby."), 2)
    return true
end

--- Turn the view by one page; a flip we cause must not look like manual
-- navigation (which resets the session). Returns whether the page changed.
function Controller:flip(dir)
    local Event = require("ui/event")
    local before = self:curPage()
    self._self_turning = true
    self.plugin.ui:handleEvent(Event:new("GotoViewRel", dir))
    self._self_turning = false
    local now = self:curPage()
    return now ~= nil and now ~= before
end

--- Page changes we didn't cause are the user navigating: drop the session
-- (the next key press starts fresh on the new page).
function Controller:onPageUpdate(page)
    if self._self_turning then return end
    if self.session and page and page ~= self.session.page then
        self:reset()
    end
end

-- --------------------------------------------------------------- presenting --

--- Screen rectangle of the current sentence (the union of its rendered line
-- boxes), used to anchor the popup right above it, plus the xpointer of the
-- match's start (the marker sits there). The sentence is located with
-- crengine's text search, scoped to the current page (a page-spanning
-- sentence is looked up by its on-page part). crengine only matches within a
-- single text node, so when the full sentence can't be found in one piece
-- (newlines, inline formatting, native ruby) progressively shorter prefixes
-- are tried; a shortened needle occurring more than once on the page is
-- disambiguated by counting occurrences in the page text. Returns nil only
-- when nothing at all can be located — the popup then falls back to the
-- bottom of the screen.
function Controller:sentenceAnchor()
    local s = self.session
    local doc = self.plugin.ui.document
    if not (doc and doc.findText and doc.getScreenBoxesFromPositions) then return nil end
    local cur = self:curPage()
    local carry = s.idx == #s.sents and s.carry_len or 0
    local positions -- computed lazily, only when disambiguation is needed
    for _, needle in ipairs(SentenceSplitting.anchorNeedles(s.sents[s.idx], carry)) do
        -- origin 0, forward: search from the top of the current page.
        -- findText never moves the view, but it does set crengine's selection
        -- highlight — clear it before anything repaints.
        local ok, sel = pcall(doc.findText, doc, needle, 0, 0, false, cur, false, 16)
        pcall(doc.clearSelection, doc)
        if ok and type(sel) == "table" and sel[1] and sel[1].start then
            local hit = sel[1]
            if #sel > 1 and s.text and s.text ~= "" then
                -- Several hits on/after this page: ours is the occurrence at
                -- this sentence's own position in the page text.
                if positions == nil then
                    positions = SentenceSplitting.sentencePositions(
                        s.text, s.sents, s.skip, s.carry_len)
                end
                local sent_pos = positions[s.idx]
                if sent_pos then
                    local n = SentenceSplitting.occurrenceIndex(s.text, needle, sent_pos)
                    hit = sel[math.min(n, #sel)] or hit
                end
            end
            local ok_page, hit_page = pcall(doc.getPageFromXPointer, doc, hit.start)
            if ok_page and hit_page == cur then
                local ok_boxes, boxes = pcall(doc.getScreenBoxesFromPositions, doc,
                    hit.start, hit["end"], true)
                if ok_boxes and type(boxes) == "table" and boxes[1] then
                    -- The union of the line boxes: "above" clears the
                    -- sentence's first line and the below-fallback starts
                    -- past its last one.
                    local x0, y0, x1, y1
                    for _, b in ipairs(boxes) do
                        if b.w and b.h and b.h > 0 then
                            if not x0 or b.x < x0 then x0 = b.x end
                            if not y0 or b.y < y0 then y0 = b.y end
                            if not x1 or b.x + b.w > x1 then x1 = b.x + b.w end
                            if not y1 or b.y + b.h > y1 then y1 = b.y + b.h end
                        end
                    end
                    if x0 then
                        local Geom = require("ui/geometry")
                        return Geom:new{ x = x0, y = y0, w = x1 - x0, h = y1 - y0 },
                            hit.start
                    end
                end
            end
        end
    end
    return nil
end

-- ------------------------------------------------------------------ marker --

--- Faintly mark the current sentence's first character (crengine's native
-- text selection), so the reader always sees where the stepper sits — with
-- the popup and audio switched off this is the only feedback. The previous
-- marker is replaced; reset()/stop() clears it.
function Controller:setMarker(start_xp)
    local doc = self.plugin.ui and self.plugin.ui.document
    if not doc then return end
    pcall(doc.clearSelection, doc) -- previous marker (or stray selection) off
    local prev = self._marker_dimen
    local dimen
    if start_xp and doc.getNextVisibleChar and doc.getTextFromXPointers then
        local ok_next, xp_end = pcall(doc.getNextVisibleChar, doc, start_xp)
        if ok_next and xp_end and xp_end ~= start_xp then
            -- draw_selection = true: crengine renders its selection there.
            local drawn = pcall(doc.getTextFromXPointers, doc, start_xp, xp_end, true)
            if drawn and doc.getScreenBoxesFromPositions then
                local ok_b, boxes = pcall(doc.getScreenBoxesFromPositions, doc,
                    start_xp, xp_end, true)
                if ok_b and type(boxes) == "table" and boxes[1] and boxes[1].w then
                    local Geom = require("ui/geometry")
                    dimen = Geom:new{ x = boxes[1].x, y = boxes[1].y,
                        w = boxes[1].w, h = boxes[1].h }
                end
            end
        end
    end
    self._marker_dimen = dimen
    self:repaintMarker(prev, dimen)
end

function Controller:clearMarker()
    if not self._marker_dimen then return end
    local doc = self.plugin.ui and self.plugin.ui.document
    if doc then pcall(doc.clearSelection, doc) end
    local prev = self._marker_dimen
    self._marker_dimen = nil
    self:repaintMarker(prev, nil)
end

-- Repaint the spots the marker left and entered (crengine draws into the
-- page, so the reader view must redraw those regions). The ReaderUI window
-- itself must be marked dirty: setDirty(nil, …) only enqueues an e-ink
-- refresh of the stale framebuffer, so with popup and audio off (nothing
-- else repainting the stack) the marker never became visible.
function Controller:repaintMarker(a, b)
    local x0, y0, x1, y1
    for _, r in ipairs({ a, b }) do
        if r then
            if not x0 then
                x0, y0, x1, y1 = r.x, r.y, r.x + r.w, r.y + r.h
            else
                x0 = math.min(x0, r.x)
                y0 = math.min(y0, r.y)
                x1 = math.max(x1, r.x + r.w)
                y1 = math.max(y1, r.y + r.h)
            end
        end
    end
    if not x0 then return end
    local Geom = require("ui/geometry")
    local region = Geom:new{ x = x0, y = y0, w = x1 - x0, h = y1 - y0 }
    local UIManager = require("ui/uimanager")
    local readerui = self.plugin.ui and (self.plugin.ui.dialog or self.plugin.ui)
    UIManager:setDirty(readerui or "all", function()
        return "ui", region
    end)
end

--- Present the current sentence: always move the first-character marker; the
-- rest — popup (Japanese line with furigana, translation) and audio — runs
-- per the per-step action toggles. With everything off the keys are a pure
-- sentence cursor: the marker alone shows where the stepper sits, and
-- nothing is fetched.
function Controller:present()
    local s = self.session
    local text = s.sents[s.idx]
    self.token = self.token + 1
    self._await_play = nil
    self:cancelPendingTap() -- a tap on the previous popup must not fire here

    local ok_anchor, anchor, start_xp = pcall(self.sentenceAnchor, self)
    if not ok_anchor then
        anchor, start_xp = nil, nil
    end
    s.anchor = anchor
    self:setMarker(start_xp)

    local display
    if self:showJpEnabled() then
        display = self:furiganaEnabled() and self:annotate(text) or text
    end
    s.display = display -- nil when the Japanese line is switched off

    if self:popupEnabled() then
        local tr
        if self:translateEnabled() and self.tr_visible then
            tr = self:cachedTranslation(text)
            -- The audio may well come from an on-device engine, so being
            -- offline is not obvious: say once why the translation line
            -- stays missing (the local translator doesn't need a network).
            if not tr and not self._tr_notified and not self:isOnline()
                    and not self:localTranslatorOpts() then
                self._tr_notified = true
                self:notify(require("gettext")("No network — sentence translations are unavailable."), 3)
            end
        end
        self:showPopup(display, tr)
    elseif self.popup then
        require("ui/uimanager"):close(self.popup)
        self.popup = nil
    end

    if self:audioEnabled() then
        local wav, exists = self:wavFor(text)
        if exists then
            self:play(wav)
        else
            self._await_play = text
        end
    end
    self:kickFetch()
end

--- Splice furigana readings into `text` via the furigana plugin's cached
-- tokenizer; the bare sentence when anything is unavailable or untrustworthy.
function Controller:annotate(text)
    local tok = self.plugin.getFuriganaTokenizer and self.plugin:getFuriganaTokenizer()
    if not tok then return text end
    local ok, display = pcall(function()
        return SentenceSplitting.rubyDisplay(tok:annotate(text), text)
    end)
    return (ok and display) or text
end

function Controller:showPopup(display, tr)
    local UIManager = require("ui/uimanager")
    local SentencePopup = require("sentencepopup")
    if self.popup then
        UIManager:close(self.popup)
    end
    -- display may be nil (Japanese line switched off): translation-only
    -- popups are fine, and "…" stands in while the translation is still on
    -- its way.
    local text
    if display and tr then
        text = display .. "\n" .. tr
    else
        text = display or tr or "…"
    end
    local popup
    popup = SentencePopup:new{
        text = text,
        anchor_box = self.session and self.session.anchor or nil,
        next_seq = self:seqFor(1),
        prev_seq = self:seqFor(-1),
        on_step = function(dir) self:onStep(dir) end,
        on_frame_tap = function() self:onPopupTap() end,
        on_text_select = function(sel_text) self:lookupSelection(sel_text) end,
        close_callback = function()
            if self.popup == popup then self.popup = nil end
        end,
    }
    self.popup = popup
    self.popup_token = self.token
    self.popup_has_tr = tr ~= nil
    UIManager:show(popup)
end

--- Text selected (hold + drag) inside the popup: look it up in the
-- dictionary, like selecting text in the dictionary window itself does.
function Controller:lookupSelection(text)
    if type(text) ~= "string" or text == "" then return end
    local ui = self.plugin.ui
    if not (ui and ui.dictionary and ui.dictionary.onLookupWord) then return end
    local ok, cleaned = pcall(function()
        return require("util").cleanupSelectedText(text)
    end)
    ui.dictionary:onLookupWord(ok and cleaned or text, true)
end

function Controller:play(wav)
    self._await_play = nil
    local ok, AudioPlayer = pcall(require, "audioplayer")
    if not ok then return end
    pcall(function() AudioPlayer:stop() end)
    local played, err = AudioPlayer:play(wav)
    if not played then
        local T = require("ffi/util").template
        self:notify(T(require("gettext")("Audio playback failed: %1"), tostring(err)), 2)
    end
end

--- Every tap on the popup body lands here; a second one within the window
-- makes it a double tap. Single tap = show/hide the translation, double tap
-- = replay the audio.
function Controller:onPopupTap()
    local UIManager = require("ui/uimanager")
    if self._tap_pending then
        self:cancelPendingTap()
        self:replay()
    else
        self._tap_pending = true
        UIManager:unschedule(self._tap_timeout_fn)
        UIManager:scheduleIn(SentenceSplitting.DOUBLE_TAP_S, self._tap_timeout_fn)
    end
end

function Controller:cancelPendingTap()
    if not self._tap_pending then return end
    self._tap_pending = false
    require("ui/uimanager"):unschedule(self._tap_timeout_fn)
end

--- Single tap on the popup: flip the translation line. The choice sticks for
-- the session, so "reveal only when I'm stuck" reading works: hide it once,
-- later popups come without it, a tap brings the current sentence's back
-- (instantly when cached — the lookahead keeps fetching regardless).
function Controller:toggleTranslation()
    if not self:translateEnabled() then
        self:notify(require("gettext")("Sentence translation is disabled in the menu."), 2)
        return
    end
    self.tr_visible = not self.tr_visible
    local s = self.session
    if not (s and s.idx > 0) then return end
    local tr = self.tr_visible and self:cachedTranslation(s.sents[s.idx]) or nil
    self:showPopup(s.display, tr)
    if self.tr_visible and not tr then
        self:kickFetch() -- make sure it is on its way (pollFetch swaps it in)
    end
end

--- Double tap on the popup: hear the sentence again (or finally, if its
-- synthesis is still on the way). An explicit tap also earns a sentence
-- whose synthesis already failed a fresh set of attempts.
function Controller:replay()
    local s = self.session
    if not (s and s.idx > 0) then return end
    local wav, exists = self:wavFor(s.sents[s.idx])
    if exists then
        self:play(wav)
    else
        self.wav_tries[s.sents[s.idx]] = 0
        self._await_play = s.sents[s.idx]
        self:kickFetch()
    end
end

-- ----------------------------------------------------- fetching / prefetching --

--- The sentences the cache should hold right now: the current one plus the
-- next LOOKAHEAD, following into the next page when the current one runs out.
function Controller:lookaheadTexts()
    local s = self.session
    local out = { s.sents[s.idx] }
    for j = s.idx + 1, s.idx + SentenceSplitting.LOOKAHEAD do
        if s.sents[j] then
            out[#out + 1] = s.sents[j]
        else
            if not s.next_sents then
                local page = s.page + 1
                local text = self:pageText(page)
                if text and text ~= "" then
                    local skip = SentenceSplitting.computeSkip(self:pageText(s.page), text)
                    s.next_sents = SentenceSplitting.buildPage(text, self:pageText(page + 1) or "", skip)
                else
                    s.next_sents = {}
                end
            end
            local nxt = s.next_sents[j - #s.sents]
            if nxt then out[#out + 1] = nxt end
        end
    end
    return out
end

--- The most useful missing item per lane, current sentence first: one WAV
-- for the audio lane and one translation for the translation lane. nil when
-- that lane's window is fully cached (or the feature is off).
function Controller:wantedItems()
    local s = self.session
    if not (s and s.idx > 0) then return nil, nil end
    local lfs = require("libs/libkoreader-lfs")
    local opts = self:voicevoxOpts()
    -- Translations only matter while a popup can show them (the per-step
    -- popup, or one summoned on demand), and are only worth attempting online
    -- (the tries would just be burned) — unless the local translator is on:
    -- 127.0.0.1 doesn't need a network. Once the network is back, the next
    -- step resumes fetching.
    local want_tr = self:translateEnabled()
        and (self:popupEnabled() or self.popup ~= nil)
        and (self:isOnline() or self:localTranslatorOpts() ~= nil)
    -- Audio is prefetched only while the audio step-action is on; an explicit
    -- replay request (_await_play) is honored regardless.
    local want_audio = opts.url ~= "" and (self:audioEnabled() or self._await_play ~= nil)
    local wav_item, tr_item
    for _, text in ipairs(self:lookaheadTexts()) do
        if want_audio and not wav_item
                and (self:audioEnabled() or text == self._await_play)
                and (self.wav_tries[text] or 0) < SentenceSplitting.MAX_TRIES then
            local wav, exists = self:wavFor(text)
            if not exists then
                wav_item = { text = text, out = wav }
            end
        end
        if want_tr and not tr_item
                and (self.tr_tries[text] or 0) < SentenceSplitting.MAX_TRIES
                and lfs.attributes(self:trPath(text), "mode") ~= "file" then
            tr_item = { text = text, out = self:trPath(text) }
        end
        if wav_item and tr_item then break end
    end
    return wav_item, tr_item
end

--- Bring one fetch lane in line with its wanted item. An in-flight fetch for
-- anything else — a sentence that was stepped past before it finished — is
-- killed on the spot (its try is refunded: it did not fail, it was
-- abandoned), so each lane always works for the sentence the reader is
-- actually on, never through a backlog of skipped ones. Returns true when a
-- new fetch for `item` should be started.
function Controller:syncLane(lane, item, tries)
    local cur = self[lane]
    if cur then
        if item and item.text == cur.text then
            return false -- already fetching exactly this
        end
        local ffiutil = require("ffi/util")
        ffiutil.terminateSubProcess(cur.pid)
        self._zombies[#self._zombies + 1] = cur.pid
        tries[cur.text] = math.max(0, (tries[cur.text] or 1) - 1)
        self[lane] = nil
    end
    return item ~= nil
end

--- Keep both lanes busy with the most useful jobs. Audio (VOICEVOX) and
-- translation (local LLM / Google) talk to different servers, so they run as
-- two independent subprocesses and never queue behind each other — the
-- popup's translation does not wait for a synthesis and vice versa. Stepping
-- to a new sentence preempts stale work in either lane at once.
function Controller:kickFetch()
    local UIManager = require("ui/uimanager")
    local wav_item, tr_item = self:wantedItems()
    if self:syncLane("fetch_wav", wav_item, self.wav_tries) then
        self:startWavFetch(wav_item)
    end
    if self:syncLane("fetch_tr", tr_item, self.tr_tries) then
        self:startTrFetch(tr_item)
    end
    local busy = self.fetch_wav ~= nil or self.fetch_tr ~= nil
    self:setEnginePause(busy)
    if busy then
        UIManager:unschedule(self._poll_fn)
        UIManager:scheduleIn(SentenceSplitting.POLL_S, self._poll_fn)
    end
end

--- One WAV in a killable subprocess (lands atomically: tmp + rename).
function Controller:startWavFetch(item)
    local ffiutil = require("ffi/util")
    self:ensureDir(self:wavDir())
    self.wav_tries[item.text] = (self.wav_tries[item.text] or 0) + 1
    local vv = self:voicevoxOpts()
    local job = {
        text = item.text,
        out = item.out,
        opts = {
            url = vv.url,
            speaker = vv.speaker,
            normalize = vv.normalize,
            synth_block_timeout = SentenceSplitting.SYNTH_BLOCK_TIMEOUT,
            synth_total_timeout = SentenceSplitting.SYNTH_TOTAL_TIMEOUT,
        },
    }
    local pid = ffiutil.runInSubProcess(function(child_pid)
        local VoiceVox = require("voicevox")
        local tmp = job.out .. ".tmp" .. tostring(child_pid)
        if VoiceVox.fetch(job.opts, job.text, tmp) then
            os.rename(tmp, job.out)
        else
            os.remove(tmp)
        end
    end)
    if pid then
        self.fetch_wav = { pid = pid, started = os.time(), text = item.text, out = item.out }
    end
end

--- One translation in a killable subprocess. Killing it mid-request is what
-- makes preemption effective with the local LLM too: the dropped connection
-- makes llama-server abandon the stale generation (the client streams, so
-- the server notices within a token), freeing it for the current sentence.
function Controller:startTrFetch(item)
    local ffiutil = require("ffi/util")
    self:ensureDir(self:trDir())
    self.tr_tries[item.text] = (self.tr_tries[item.text] or 0) + 1
    local job = {
        text = item.text,
        out = item.out,
        lang = self:targetLang(),
        local_tr = self:localTranslatorOpts(), -- nil: Google only
    }
    local pid = ffiutil.runInSubProcess(function(child_pid)
        local tr
        if job.local_tr then
            -- The local LLM first (offline-capable, better literary
            -- register); Google only as the fallback.
            local ok, res = pcall(function()
                local LocalTranslator = require("localtranslator")
                return LocalTranslator.translate(job.local_tr, job.text)
            end)
            if ok and type(res) == "string" and res ~= "" then tr = res end
        end
        if not tr then
            local ok, res = pcall(function()
                local Translator = require("ui/translator")
                return Translator:translate(job.text, job.lang, "ja")
            end)
            if ok and type(res) == "string" and res ~= "" then tr = res end
        end
        if tr and tr ~= job.text then
            -- Lands atomically (tmp + rename), so a kill can't leave partial
            -- files.
            local tmp = job.out .. ".tmp" .. tostring(child_pid)
            local fh = io.open(tmp, "w")
            if fh then
                fh:write(tr)
                fh:close()
                os.rename(tmp, job.out)
            end
        end
    end)
    if pid then
        self.fetch_tr = { pid = pid, started = os.time(), text = item.text, out = item.out }
    end
end

--- Hold the furigana plugin's page-window precache worker off the engine
-- while our fetch runs (the lock is refreshed on every poll, released when we
-- go idle).
function Controller:setEnginePause(on)
    local furigana = self:furigana()
    local pre = furigana and furigana._precache
    if pre and pre.setForegroundFetch then
        pre:setForegroundFetch(on)
    end
end

function Controller:reapZombies()
    local ffiutil = require("ffi/util")
    if #self._zombies == 0 then return end
    local still = {}
    for _, z in ipairs(self._zombies) do
        if not ffiutil.isSubProcessDone(z) then still[#still + 1] = z end
    end
    self._zombies = still
end

function Controller:pollFetch()
    local UIManager = require("ui/uimanager")
    local ffiutil = require("ffi/util")
    local lfs = require("libs/libkoreader-lfs")
    self:reapZombies()
    if not (self.fetch_wav or self.fetch_tr) then
        if #self._zombies > 0 then
            UIManager:scheduleIn(2, self._poll_fn)
        end
        return
    end
    self:setEnginePause(true)

    -- Collect whichever lanes finished (killing a lane that overran its
    -- deadline — a hung server can't freeze the session; the tries cap stops
    -- us from hammering a dead one forever).
    local finished_wav, finished_tr
    for lane, deadline in pairs({
        fetch_wav = SentenceSplitting.FETCH_DEADLINE_S,
        fetch_tr = SentenceSplitting.TR_FETCH_DEADLINE_S,
    }) do
        local f = self[lane]
        if f then
            local done = ffiutil.isSubProcessDone(f.pid)
            if not done and os.time() - (f.started or 0) >= deadline then
                ffiutil.terminateSubProcess(f.pid)
                self._zombies[#self._zombies + 1] = f.pid
                done = true
            end
            if done then
                self[lane] = nil
                if lane == "fetch_wav" then finished_wav = f else finished_tr = f end
            end
        end
    end
    if not (finished_wav or finished_tr) then
        UIManager:scheduleIn(SentenceSplitting.POLL_S, self._poll_fn)
        return
    end

    local s = self.session
    if s and s.idx > 0 then
        local cur = s.sents[s.idx]
        -- The audio the user is actually waiting for: play it the moment it
        -- lands (or tell them once when it definitively failed).
        if finished_wav and self._await_play and finished_wav.text == self._await_play then
            if lfs.attributes(finished_wav.out, "mode") == "file" then
                if self._await_play == cur then
                    self:play(finished_wav.out)
                else
                    self._await_play = nil
                end
            elseif (self.wav_tries[finished_wav.text] or 0) >= SentenceSplitting.MAX_TRIES then
                self._await_play = nil
                self:notify(require("gettext")("VOICEVOX could not synthesize this sentence."), 2)
            end
        end
        -- The shown popup is still missing its translation: swap it in — or
        -- say once why it will never come (its retries are exhausted).
        if self.popup and self.popup_token == self.token and not self.popup_has_tr
                and self:translateEnabled() and self.tr_visible then
            local tr = self:cachedTranslation(cur)
            if tr then
                self:showPopup(s.display, tr)
            elseif not self._tr_notified
                    and (self.tr_tries[cur] or 0) >= SentenceSplitting.MAX_TRIES then
                self._tr_notified = true
                self:notify(require("gettext")("Sentence translation failed — check the network connection."), 3)
            end
        end
    end
    self:kickFetch()
    if not (self.fetch_wav or self.fetch_tr) and #self._zombies > 0 then
        UIManager:scheduleIn(2, self._poll_fn)
    end
end

-- ------------------------------------------------------------ reset / stop --

--- Drop the session (popup, in-flight fetch, playback); the toggle stays on,
-- so the next key press starts fresh at the current page.
function Controller:reset()
    local UIManager = require("ui/uimanager")
    local ffiutil = require("ffi/util")
    self.token = self.token + 1
    self._await_play = nil
    self:cancelPendingTap()
    self:cancelPendingStep()
    self:clearMarker()
    self.session = nil
    for _, lane in ipairs({ "fetch_wav", "fetch_tr" }) do
        local f = self[lane]
        if f then
            ffiutil.terminateSubProcess(f.pid)
            self._zombies[#self._zombies + 1] = f.pid
            self[lane] = nil
            UIManager:scheduleIn(2, self._poll_fn)
        end
    end
    if self.popup then
        UIManager:close(self.popup)
        self.popup = nil
    end
    local ok, AudioPlayer = pcall(require, "audioplayer")
    if ok then pcall(function() AudioPlayer:stop() end) end
    self:setEnginePause(false)
end

--- Feature turned off / document closing: also trim the caches.
function Controller:stop()
    self:reset()
    self._tr_notified = nil -- a fresh session may diagnose the network anew
    local furigana = self:furigana()
    if furigana then
        pcall(SentenceSplitting.pruneDir, self:wavDir(), AutoReader.KEEP_SENTENCES)
    end
    pcall(SentenceSplitting.pruneDir, self:trDir(), SentenceSplitting.KEEP_TRANSLATIONS)
end

return SentenceSplitting
