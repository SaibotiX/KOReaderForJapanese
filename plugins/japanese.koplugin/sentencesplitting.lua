--- Sentence splitting: read the book sentence by sentence with the volume keys.
--
-- While enabled, the page-turn keys (the volume buttons on Android) no longer
-- turn pages: the first press picks the current page's first sentence, speaks
-- it through VOICEVOX and shows it in a small popup right above the sentence
-- (below it when there is no room above; bottom of the screen when the
-- sentence cannot be located) — with furigana readings spliced in (toggleable)
-- and its translation underneath (Google Translate, toggleable, swapped in as
-- soon as it arrives; needs a network connection, unlike the audio, whose
-- engine may run on the device itself). Forward / back keys step to the next /
-- previous sentence; stepping past either end of the page turns it. A sentence
-- that runs across a page boundary is completed with the next page's
-- beginning, exactly like the auto reader.
--
-- Smoothness comes from working ahead: a single background subprocess keeps
-- the audio AND the translation of the next two sentences cached (WAVs in the
-- auto reader's sentence cache — the two features share files; translations
-- as small text files), so stepping forward is instant. The page-window word
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
-- background fetch gets roomier per-request timeouts and a longer hung-fetch
-- deadline; the user is never blocked on it (the popup shows immediately).
SentenceSplitting.SYNTH_BLOCK_TIMEOUT = 45
SentenceSplitting.SYNTH_TOTAL_TIMEOUT = 120
SentenceSplitting.FETCH_DEADLINE_S = 150
-- A second tap on the popup within this window means "double tap" (replay);
-- a lone tap toggles the translation once the window has passed. Detected
-- here rather than through GestureDetector's double_tap, which is usually
-- disabled globally because it would delay every page-turn tap.
SentenceSplitting.DOUBLE_TAP_S = 0.35

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
    local sents, last_incomplete = AutoReader.splitSentences(raw)
    local consumed = 0
    local carry_len = 0
    if last_incomplete and #sents > 0 and next_text and next_text ~= "" then
        local head, c = AutoReader.sentenceHead(next_text, AutoReader.HEAD_MAX_BYTES)
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
    local sents, last_incomplete = AutoReader.splitSentences(prev_text)
    if last_incomplete and #sents > 0 then
        local head, consumed = AutoReader.sentenceHead(text, AutoReader.HEAD_MAX_BYTES)
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

-- --------------------------------------------------------------- controller --

local Controller = {}
Controller.__index = Controller

function SentenceSplitting.newController(plugin)
    local self = setmetatable({
        plugin = plugin,   -- the japanese.koplugin instance (for ui + tokenizer)
        session = nil,     -- { page, sents, idx, display, next_sents }
        token = 0,         -- bumped on every step/reset; stale results are dropped
        fetch = nil,       -- single in-flight subprocess { pid, started, wav_text, wav_out }
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

function Controller:furiganaEnabled()
    return G_reader_settings:nilOrTrue("language_japanese_sentence_furigana")
end

function Controller:translateEnabled()
    return G_reader_settings:nilOrTrue("language_japanese_sentence_translate")
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
    local key = Precache.audioKey(opts.url, opts.speaker, text)
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
    return { page = page, sents = sents, idx = 0, carry_len = carry_len }
end

--- One key press: dir 1 = next sentence, -1 = previous. The first press of
-- either key starts at the current page's first sentence.
function Controller:onStep(dir)
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
-- boxes), used to anchor the popup right above it. The sentence is located
-- with crengine's text search, scoped to the current page (a page-spanning
-- sentence is looked up by its on-page part). Returns nil when the text can't
-- be found in one piece — crengine's search matches within a single text
-- node, so inline formatting inside the sentence breaks it — and the popup
-- then falls back to the bottom of the screen.
function Controller:sentenceAnchor()
    local s = self.session
    local doc = self.plugin.ui.document
    if not (doc and doc.findText and doc.getScreenBoxesFromPositions) then return nil end
    local needle = s.sents[s.idx]
    if s.idx == #s.sents and (s.carry_len or 0) > 0 then
        needle = needle:sub(1, #needle - s.carry_len)
    end
    needle = needle:gsub("^%s+", ""):gsub("%s+$", "")
    if needle == "" then return nil end
    local cur = self:curPage()
    -- origin 0, forward: search from the top of the current page. findText
    -- never moves the view, but it does set crengine's selection highlight —
    -- clear it before anything repaints.
    local ok, sel = pcall(doc.findText, doc, needle, 0, 0, false, cur, false, 8)
    pcall(doc.clearSelection, doc)
    if not (ok and type(sel) == "table" and sel[1] and sel[1].start) then return nil end
    local ok_page, hit_page = pcall(doc.getPageFromXPointer, doc, sel[1].start)
    if not ok_page or hit_page ~= cur then return nil end -- found beyond this page only
    local ok_boxes, boxes = pcall(doc.getScreenBoxesFromPositions, doc,
        sel[1].start, sel[1]["end"], true)
    if not (ok_boxes and type(boxes) == "table" and boxes[1]) then return nil end
    -- The union of the line boxes: "above" clears the sentence's first line
    -- and the below-fallback starts past its last one.
    local x0, y0, x1, y1
    for _, b in ipairs(boxes) do
        if b.w and b.h and b.h > 0 then
            if not x0 or b.x < x0 then x0 = b.x end
            if not y0 or b.y < y0 then y0 = b.y end
            if not x1 or b.x + b.w > x1 then x1 = b.x + b.w end
            if not y1 or b.y + b.h > y1 then y1 = b.y + b.h end
        end
    end
    if not x0 then return nil end
    local Geom = require("ui/geometry")
    return Geom:new{ x = x0, y = y0, w = x1 - x0, h = y1 - y0 }
end

--- Show the current sentence: popup anchored above it (furigana per toggle,
-- translation when cached), audio (cached plays at once, otherwise fetched
-- with priority), and keep the lookahead warm.
function Controller:present()
    local s = self.session
    local text = s.sents[s.idx]
    self.token = self.token + 1
    self._await_play = nil
    self:cancelPendingTap() -- a tap on the previous popup must not fire here
    local display = text
    if self:furiganaEnabled() then
        display = self:annotate(text)
    end
    s.display = display
    local ok_anchor, anchor = pcall(self.sentenceAnchor, self)
    s.anchor = ok_anchor and anchor or nil
    local tr
    if self:translateEnabled() and self.tr_visible then
        tr = self:cachedTranslation(text)
        -- The audio may well come from an on-device engine, so being offline
        -- is not obvious: say once why the translation line stays missing.
        if not tr and not self._tr_notified and not self:isOnline() then
            self._tr_notified = true
            self:notify(require("gettext")("No network — sentence translations are unavailable."), 3)
        end
    end
    self:showPopup(display, tr)
    local wav, exists = self:wavFor(text)
    if exists then
        self:play(wav)
    else
        self._await_play = text
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
    local popup
    popup = SentencePopup:new{
        text = tr and (display .. "\n" .. tr) or display,
        anchor_box = self.session and self.session.anchor or nil,
        next_seq = self:seqFor(1),
        prev_seq = self:seqFor(-1),
        on_step = function(dir) self:onStep(dir) end,
        on_frame_tap = function() self:onPopupTap() end,
        close_callback = function()
            if self.popup == popup then self.popup = nil end
        end,
    }
    self.popup = popup
    self.popup_token = self.token
    self.popup_has_tr = tr ~= nil
    UIManager:show(popup)
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

--- What is still missing: at most one WAV per job (the engine synthesizes
-- serially anyway; the current sentence always wins) and every missing
-- translation. nil when the window is fully cached.
function Controller:wants()
    local s = self.session
    if not (s and s.idx > 0) then return nil end
    local lfs = require("libs/libkoreader-lfs")
    local opts = self:voicevoxOpts()
    -- Translations are only worth attempting online (the tries would just be
    -- burned); once the network is back, the next step resumes fetching.
    local want_tr = self:translateEnabled() and self:isOnline()
    local w = { translations = {} }
    for i, text in ipairs(self:lookaheadTexts()) do
        if opts.url ~= "" and not w.wav and (self.wav_tries[text] or 0) < SentenceSplitting.MAX_TRIES then
            local wav, exists = self:wavFor(text)
            if not exists then
                w.wav = { text = text, out = wav, current = (i == 1) }
            end
        end
        if want_tr and (self.tr_tries[text] or 0) < SentenceSplitting.MAX_TRIES
                and lfs.attributes(self:trPath(text), "mode") ~= "file" then
            w.translations[#w.translations + 1] = { text = text, out = self:trPath(text) }
        end
    end
    if not w.wav and #w.translations == 0 then return nil end
    return w
end

--- Keep exactly one fetch subprocess busy with the most useful job. A stale
-- background fetch is killed when the user is now waiting for a different
-- sentence's audio.
function Controller:kickFetch()
    local UIManager = require("ui/uimanager")
    local ffiutil = require("ffi/util")
    local w = self:wants()
    if not w then
        if not self.fetch then self:setEnginePause(false) end
        return
    end
    if self.fetch then
        if w.wav and w.wav.current and self.fetch.wav_text ~= w.wav.text then
            ffiutil.terminateSubProcess(self.fetch.pid)
            self._zombies[#self._zombies + 1] = self.fetch.pid
            self.fetch = nil
        else
            return -- busy; its completion re-enters here
        end
    end

    self:ensureDir(self:trDir())
    if w.wav then
        self:ensureDir(self:wavDir())
        self.wav_tries[w.wav.text] = (self.wav_tries[w.wav.text] or 0) + 1
    end
    for _, t in ipairs(w.translations) do
        self.tr_tries[t.text] = (self.tr_tries[t.text] or 0) + 1
    end

    local vv = self:voicevoxOpts()
    local job = {
        wav = w.wav,
        translations = w.translations,
        lang = self:targetLang(),
        opts = {
            url = vv.url,
            speaker = vv.speaker,
            normalize = vv.normalize,
            synth_block_timeout = SentenceSplitting.SYNTH_BLOCK_TIMEOUT,
            synth_total_timeout = SentenceSplitting.SYNTH_TOTAL_TIMEOUT,
        },
    }
    local pid = ffiutil.runInSubProcess(function(child_pid)
        -- Translations first (small, fast), then the one WAV; each lands
        -- atomically (tmp + rename), so a kill can't leave partial files.
        for _, t in ipairs(job.translations) do
            local ok, tr = pcall(function()
                local Translator = require("ui/translator")
                return Translator:translate(t.text, job.lang, "ja")
            end)
            if ok and type(tr) == "string" and tr ~= "" and tr ~= t.text then
                local tmp = t.out .. ".tmp" .. tostring(child_pid)
                local fh = io.open(tmp, "w")
                if fh then
                    fh:write(tr)
                    fh:close()
                    os.rename(tmp, t.out)
                end
            end
        end
        if job.wav then
            local VoiceVox = require("voicevox")
            local tmp = job.wav.out .. ".tmp" .. tostring(child_pid)
            if VoiceVox.fetch(job.opts, job.wav.text, tmp) then
                os.rename(tmp, job.wav.out)
            else
                os.remove(tmp)
            end
        end
    end)
    if not pid then return end
    self.fetch = {
        pid = pid,
        started = os.time(),
        wav_text = w.wav and w.wav.text,
        wav_out = w.wav and w.wav.out,
    }
    self:setEnginePause(true)
    UIManager:unschedule(self._poll_fn)
    UIManager:scheduleIn(SentenceSplitting.POLL_S, self._poll_fn)
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
    if not self.fetch then
        if #self._zombies > 0 then
            UIManager:scheduleIn(2, self._poll_fn)
        end
        return
    end
    self:setEnginePause(true)

    if not ffiutil.isSubProcessDone(self.fetch.pid) then
        if os.time() - (self.fetch.started or 0) < SentenceSplitting.FETCH_DEADLINE_S then
            UIManager:scheduleIn(SentenceSplitting.POLL_S, self._poll_fn)
            return
        end
        -- Hung synthesis (engine gone?): kill it; the tries cap stops us from
        -- hammering a dead server forever.
        ffiutil.terminateSubProcess(self.fetch.pid)
        self._zombies[#self._zombies + 1] = self.fetch.pid
    end

    local fetch = self.fetch
    self.fetch = nil
    local s = self.session
    if s and s.idx > 0 then
        local cur = s.sents[s.idx]
        -- The audio the user is actually waiting for: play it the moment it
        -- lands (or tell them once when it definitively failed).
        if self._await_play and fetch.wav_text == self._await_play then
            if fetch.wav_out and lfs.attributes(fetch.wav_out, "mode") == "file" then
                if self._await_play == cur then
                    self:play(fetch.wav_out)
                else
                    self._await_play = nil
                end
            elseif (self.wav_tries[fetch.wav_text] or 0) >= SentenceSplitting.MAX_TRIES then
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
    self.session = nil
    if self.fetch then
        ffiutil.terminateSubProcess(self.fetch.pid)
        self._zombies[#self._zombies + 1] = self.fetch.pid
        self.fetch = nil
        UIManager:scheduleIn(2, self._poll_fn)
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
