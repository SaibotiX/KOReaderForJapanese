--- Auto Reader: continuous VOICEVOX read-aloud with automatic page turns.
--
-- Starts at the top of the current page, splits the page text into sentences,
-- speaks them one after another and flips to the next page when its first
-- sentence starts, until the end of the book or until the user intervenes
-- (tap, manual page turn, menu toggle, closing the book).
--
-- Uninterrupted audio comes from working ahead: while a sentence plays, the
-- next ones are synthesized in a background subprocess (and a sentence that
-- runs across a page boundary is completed with the next page's beginning, so
-- nothing is cut off mid-sentence). Sentence WAVs are cached under
-- cache/furigana/audio/sentences/ and trimmed after each session, so
-- re-listening to recent pages is instant without the cache growing forever.
--
-- Advancing is driven by the WAV duration plus an "is it really finished?"
-- poll of the platform player; all waits run through UIManager:scheduleIn, so
-- the UI stays fully responsive.
--
-- The pure text logic (sentence splitting, page-boundary carry) is
-- unit-tested standalone:  lua tools/run_autoreader_test.lua
--
-- @module koplugin.furigana.autoreader

local Precache = require("precache") -- pure helpers only (utf8At, audioKey)

local AutoReader = {}

AutoReader.PREFETCH = 4           -- chunks synthesized ahead of playback
AutoReader.GAP_S = 0.3            -- pause after a whole sentence
AutoReader.CHUNK_GAP_S = 0.05     -- pause between chunks within one sentence
AutoReader.POLL_S = 0.3           -- fetch / still-playing poll interval
AutoReader.CHUNK_MIN_BYTES = 30   -- don't cut speech chunks smaller than this
AutoReader.MAX_SENT_BYTES = 300   -- hard cap per synthesized chunk
AutoReader.SENT_CAP_BYTES = 600   -- hard cap per split sentence (quoted
                                  -- dialogue can span several 。 units)
AutoReader.HEAD_MAX_BYTES = 600   -- page-boundary sentence completion limit
AutoReader.KEEP_SENTENCES = 120   -- cached chunk WAVs kept after a session
AutoReader.MAX_FETCH_TRIES = 2    -- per chunk, before marking it failed
AutoReader.FAIL_LIMIT = 4         -- consecutive failed chunks => stop (engine down)
-- A synthesis that runs longer than this is treated as hung: the subprocess
-- is killed and the chunk retried, so a stalled engine can never freeze the
-- whole session (chunks are small, so a healthy one is a few seconds at most).
AutoReader.FETCH_DEADLINE_S = 35
AutoReader.SYNTH_BLOCK_TIMEOUT = 15
AutoReader.SYNTH_TOTAL_TIMEOUT = 30

-- ---------------------------------------------------------------- sentences --

local TERMINATORS = {
    [0x3002] = true, -- 。
    [0xFF0E] = true, -- ．
    [0xFF01] = true, -- ！
    [0xFF1F] = true, -- ？
    [0x203C] = true, -- ‼
    [0x2047] = true, -- ⁇
    [0x2048] = true, -- ⁈
    [0x2049] = true, -- ⁉
    [0x2025] = true, -- ‥
    [0x2026] = true, -- …
}
local CLOSERS = {
    [0x300D] = true, -- 」
    [0x300F] = true, -- 』
    [0x3009] = true, -- 〉
    [0x300B] = true, -- 》
    [0x3011] = true, -- 】
    [0xFF09] = true, -- ）
    [0x0029] = true, -- )
    [0x0022] = true, -- "
    [0x0027] = true, -- '
    [0x2019] = true, -- ’
    [0x201D] = true, -- ”
}
-- Quotation brackets tracked as pairs: terminators inside 「…」/『…』 do not
-- end the sentence, so 「そうだ。行こう！」と言った。 stays one sentence
-- (the quote, its closing bracket, and the narration up to the next
-- terminator). Only these two unambiguous pairs are tracked — ASCII "quotes"
-- can't be paired reliably, and parentheses rarely hold full sentences.
local QUOTE_OPENERS = {
    [0x300C] = true, -- 「
    [0x300E] = true, -- 『
}
local QUOTE_CLOSERS = {
    [0x300D] = true, -- 」
    [0x300F] = true, -- 』
}
local COMMAS = {
    [0x3001] = true, -- 、
    [0xFF0C] = true, -- ，
    [0x002C] = true, -- ,
}

local function is_space_cp(cp)
    return cp == 0x20 or cp == 0x09 or cp == 0x0D or cp == 0x3000
end

-- Something worth sending to the synthesizer: a Japanese word character or an
-- ASCII/full-width alphanumeric. Bare punctuation runs are dropped.
local function is_speakable_cp(cp)
    return Precache.isWordCp(cp)
        or (cp >= 0x30 and cp <= 0x39) or (cp >= 0x41 and cp <= 0x5A)
        or (cp >= 0x61 and cp <= 0x7A)
        or (cp >= 0xFF10 and cp <= 0xFF19) or (cp >= 0xFF21 and cp <= 0xFF3A)
        or (cp >= 0xFF41 and cp <= 0xFF5A)
end

local function has_speakable(s)
    local i = 1
    while i <= #s do
        local cp, len = Precache.utf8At(s, i)
        if is_speakable_cp(cp) then return true end
        i = i + len
    end
    return false
end

-- Trim ASCII whitespace and full-width spaces. The full-width space must be
-- matched as a literal, never inside a byte class: [%s　] would strip the
-- 0xE3/0x80 lead bytes off any kana or CJK punctuation that follows.
local function trim(s)
    while true do
        local t = s:gsub("^%s+", ""):gsub("^　", "")
        t = t:gsub("%s+$", ""):gsub("　$", "")
        if t == s then return s end
        s = t
    end
end

-- ASCII . ! ? terminate only when not followed by an alphanumeric, so "3.5"
-- and "U.S." stay whole.
local function ascii_terminates(text, next_i)
    local b = text:byte(next_i)
    if not b then return true end
    if (b >= 0x30 and b <= 0x39) or (b >= 0x41 and b <= 0x5A) or (b >= 0x61 and b <= 0x7A) then
        return false
    end
    return true
end

--- Split a chunk into speakable sentences. A sentence ends at a terminator
-- (。！？… etc., plus any directly following terminators/closing quotes) or a
-- newline (paragraph boundary). Terminators inside 「…」/『…』 quotation
-- brackets do not end the sentence: a quote runs to its closing bracket and
-- on to the next terminator, so dialogue plus its narration stays one unit.
-- A newline still cuts regardless (and resets the quote state), so a stray
-- unclosed bracket can never glue paragraphs together. Over-long sentences
-- are re-split at commas (or hard-cut) to keep single units sane.
-- `init_depth` (optional) is the quote depth carried in from preceding text
-- (page-boundary continuation).
-- Returns sentences (array of strings), last_incomplete (true when the text
-- ran out mid-sentence — the caller may complete it from the next page), and
-- the quote depth still open at the end of the text.
function AutoReader.splitSentences(text, init_depth)
    local sents = {}
    local last_incomplete = false
    local function push(s, incomplete)
        s = trim(s)
        if s == "" or not has_speakable(s) then return end
        for _, piece in ipairs(AutoReader.capLength(s, AutoReader.SENT_CAP_BYTES)) do
            sents[#sents + 1] = piece
        end
        last_incomplete = incomplete or false
    end
    local depth = init_depth or 0
    local i, start = 1, 1
    local len = #text
    while i <= len do
        local cp, clen = Precache.utf8At(text, i)
        local nxt = i + clen
        if cp == 0x0A then
            push(text:sub(start, i - 1), false)
            start = nxt
            depth = 0
        elseif QUOTE_OPENERS[cp] then
            depth = depth + 1
        elseif QUOTE_CLOSERS[cp] then
            depth = depth > 0 and depth - 1 or 0
        elseif depth == 0 and (TERMINATORS[cp]
            or ((cp == 0x2E or cp == 0x21 or cp == 0x3F) and ascii_terminates(text, nxt))) then
            -- consume any run of further terminators and closing quotes
            local j = nxt
            while j <= len do
                local cp2, l2 = Precache.utf8At(text, j)
                if TERMINATORS[cp2] or CLOSERS[cp2]
                    or cp2 == 0x2E or cp2 == 0x21 or cp2 == 0x3F then
                    j = j + l2
                else
                    break
                end
            end
            push(text:sub(start, j - 1), false)
            start = j
            nxt = j
        end
        i = nxt
    end
    if start <= len then
        push(text:sub(start, len), true)
    end
    return sents, last_incomplete, depth
end

--- Re-split an over-long sentence at its last comma (、，,) before `max`
-- bytes, falling back to a character boundary. Returns an array of pieces.
function AutoReader.capLength(s, max)
    local pieces = {}
    while #s > max do
        local i, last_comma, last_boundary = 1, nil, 1
        while i <= #s do
            local cp, clen = Precache.utf8At(s, i)
            if i + clen - 1 > max then break end
            if COMMAS[cp] then last_comma = i + clen - 1 end
            last_boundary = i + clen - 1
            i = i + clen
        end
        local cut = last_comma or last_boundary
        if cut <= 0 then break end
        local piece = trim(s:sub(1, cut))
        if piece ~= "" then pieces[#pieces + 1] = piece end
        s = trim(s:sub(cut + 1))
        if s == "" then return pieces end
    end
    if s ~= "" then pieces[#pieces + 1] = s end
    return pieces
end

--- The head of `text` up to and including its first sentence end (terminator
-- run or newline), used to complete a page-spanning sentence with the next
-- page's beginning. `init_depth` (optional) is the quote depth left open by
-- the sentence being completed, so a quote split across the page break is
-- still carried through its closing 」 and on to the real sentence end.
-- Returns head (maybe ""), consumed_bytes — or nil when no sentence end is
-- found within max_bytes (then nothing is carried).
function AutoReader.sentenceHead(text, max_bytes, init_depth)
    max_bytes = max_bytes or AutoReader.HEAD_MAX_BYTES
    local depth = init_depth or 0
    local i = 1
    local len = #text
    while i <= len and i <= max_bytes do
        local cp, clen = Precache.utf8At(text, i)
        local nxt = i + clen
        if cp == 0x0A then
            return trim(text:sub(1, i - 1)), nxt - 1
        end
        if QUOTE_OPENERS[cp] then
            depth = depth + 1
        elseif QUOTE_CLOSERS[cp] then
            depth = depth > 0 and depth - 1 or 0
        elseif depth == 0 and (TERMINATORS[cp]
            or ((cp == 0x2E or cp == 0x21 or cp == 0x3F) and ascii_terminates(text, nxt))) then
            local j = nxt
            while j <= len do
                local cp2, l2 = Precache.utf8At(text, j)
                if TERMINATORS[cp2] or CLOSERS[cp2]
                    or cp2 == 0x2E or cp2 == 0x21 or cp2 == 0x3F then
                    j = j + l2
                else
                    break
                end
            end
            return trim(text:sub(1, j - 1)), j - 1
        end
        i = nxt
    end
    return nil
end

--- Split one sentence into clause-sized speech chunks. We break after a comma
-- (、，,) once the running chunk has reached CHUNK_MIN_BYTES, and hard-split
-- any comma-less run that grows past MAX_SENT_BYTES. Smaller chunks are what
-- make continuous reading smooth: the first audio starts sooner, and each
-- chunk synthesizes fast enough that the prefetch stays ahead of playback
-- instead of draining the buffer on one big sentence. A trailing fragment
-- below the minimum is merged back into the previous chunk so we never emit a
-- one- or two-character utterance. Returns an array of chunk strings (just the
-- sentence itself when it is already short).
function AutoReader.chunkSentence(s)
    local chunks = {}
    local function flush(piece)
        piece = trim(piece)
        if piece == "" then return end
        if has_speakable(piece) then
            chunks[#chunks + 1] = piece
        elseif #chunks > 0 then
            -- punctuation/space only: keep it attached to the previous chunk
            chunks[#chunks] = trim(chunks[#chunks] .. piece)
        end
    end
    local i, start = 1, 1
    local len = #s
    while i <= len do
        local cp, clen = Precache.utf8At(s, i)
        local nxt = i + clen
        local cur_bytes = nxt - start
        if (COMMAS[cp] and cur_bytes >= AutoReader.CHUNK_MIN_BYTES)
                or cur_bytes >= AutoReader.MAX_SENT_BYTES then
            flush(s:sub(start, nxt - 1))
            start = nxt
        end
        i = nxt
    end
    if start <= len then
        local tail = s:sub(start, len)
        if #chunks > 0 and #trim(tail) < AutoReader.CHUNK_MIN_BYTES then
            chunks[#chunks] = trim(chunks[#chunks] .. tail) -- merge a tiny tail
        else
            flush(tail)
        end
    end
    if #chunks == 0 then chunks[1] = trim(s) end
    return chunks
end

--- Rough speech duration estimate (seconds) when the WAV header can't be
-- parsed: Japanese runs ≈ 7 morae/second and a CJK char is ~3 UTF-8 bytes.
function AutoReader.estimateDuration(text)
    return math.min(30, math.max(1, #text / 21))
end

-- --------------------------------------------------------------- controller --

local Controller = {}
Controller.__index = Controller

function AutoReader.newController(plugin)
    local self = setmetatable({
        plugin = plugin,
        active = false,
        entries = nil,     -- { { text, page, wav, status, tries } }
        idx = 1,
        cur_page = nil,    -- page currently displayed (as far as we steered it)
        build_page = nil,  -- last page whose sentences were built
        carry_skip = nil,  -- page -> bytes consumed by the previous page's tail
        no_more = false,
        fetch = nil,       -- { idx, pid, final, started } single in-flight synthesis
        playing_idx = nil,
        consecutive_fails = 0,
        _poll_waits = 0,
        _zombies = {},     -- killed fetches awaiting collection
    }, Controller)
    self._tick_fn = function() self:tick() end
    self._advance_fn = function() self:advance() end
    self._fetch_poll_fn = function() self:pollFetch() end
    return self
end

function Controller:isActive()
    return self.active
end

function Controller:notify(text, timeout)
    local UIManager = require("ui/uimanager")
    local InfoMessage = require("ui/widget/infomessage")
    UIManager:show(InfoMessage:new{ text = text, timeout = timeout or 3 })
end

function Controller:sentencesDir()
    return self.plugin.cache_dir .. "/audio/sentences"
end

--- Existing audio for `text` wherever it may already live (sentence cache,
-- permanent word cache, page precache); falls back to the sentence-cache
-- path as the synthesis target.
function Controller:wavFor(text)
    local lfs = require("libs/libkoreader-lfs")
    local opts = self.opts
    local key = Precache.audioKeyFor(opts, text)
    local candidates = {
        self:sentencesDir() .. "/" .. key .. ".wav",
        self.plugin.cache_dir .. "/audio/" .. key .. ".wav",
        self.plugin.cache_dir .. "/audio/precache/" .. key .. ".wav",
    }
    for _, p in ipairs(candidates) do
        if lfs.attributes(p, "mode") == "file" then return p, true end
    end
    return candidates[1], false
end

-- ------------------------------------------------------------ start / stop --

function Controller:toggle()
    if self.active then
        self:stop(require("gettext")("Auto reader stopped"))
    else
        self:start()
    end
end

function Controller:start()
    local _ = require("gettext")
    local UIManager = require("ui/uimanager")
    local p = self.plugin
    if self.active then return end
    if not (p.ui and p.ui.rolling and p.ui.document) then
        self:notify(_("Auto reader works in EPUB/HTML books only."))
        return
    end
    if p:isShowingAnnotated() then
        -- Extracted text of an annotated copy interleaves the ruby readings,
        -- which would be read out twice.
        self:notify(_("Auto reader works in the original book — turn 'Show furigana for current book' off first."))
        return
    end
    self.opts = p:voicevoxOpts()
    if not self.opts.url or self.opts.url == "" then
        self:notify(_("Configure the VOICEVOX server URL first."))
        return
    end

    self.active = true
    self.entries = {}
    self.idx = 1
    self.playing_idx = nil
    self.no_more = false
    self.build_page = nil
    self.carry_skip = {}
    self.consecutive_fails = 0
    local ok_page, cur = pcall(function() return p.ui.document:getCurrentPage() end)
    self.cur_page = ok_page and cur or 1
    self.start_page = self.cur_page

    UIManager:preventStandby()
    self._standby_held = true
    self:keepScreenOn(true)
    -- The engine is ours for the whole session: park the page-window precache
    -- worker (lock refreshed on every poll/sentence) AND stop any precache
    -- subprocess that is mid-synthesis right now, so it can't hold the engine
    -- and make the first sentence wait.
    if p._precache then
        p._precache:setForegroundFetch(true)
        if p._precache.stop then p._precache:stop() end
    end

    self:notify(_("Auto reader started — tap the page to stop."), 2)
    self:tick()
end

--- Stop reading. `msg` (optional) is shown briefly; cleanup is idempotent.
function Controller:stop(msg)
    if not self.active then return end
    local UIManager = require("ui/uimanager")
    local ffiutil = require("ffi/util")
    self.active = false
    UIManager:unschedule(self._tick_fn)
    UIManager:unschedule(self._advance_fn)
    UIManager:unschedule(self._fetch_poll_fn)
    if self.fetch then
        ffiutil.terminateSubProcess(self.fetch.pid)
        -- collect it once it's gone (poll keeps rescheduling itself)
        self._zombies[#self._zombies + 1] = self.fetch.pid
        self.fetch = nil
        UIManager:scheduleIn(2, self._fetch_poll_fn)
    end
    local ok, AudioPlayer = pcall(require, "audioplayer")
    if ok then AudioPlayer:stop() end
    if self._standby_held then
        UIManager:allowStandby()
        self._standby_held = false
    end
    self:keepScreenOn(false)
    if self.plugin._precache then
        self.plugin._precache:setForegroundFetch(false)
    end
    self.plugin:precacheSchedule() -- give the page window its engine back
    self:pruneSentences()
    if msg then self:notify(msg, 2) end
end

--- Keep the screen awake on Android while reading aloud (scheduled callbacks
-- die with the app when the device sleeps). Saves and restores the user's
-- timeout; no-op elsewhere (eink standby is handled via preventStandby).
function Controller:keepScreenOn(enable)
    local Device = require("device")
    if not Device:isAndroid() then return end
    pcall(function()
        local android = require("android")
        local ffi = require("ffi")
        if enable then
            self._saved_timeout = android.timeout.get()
            android.timeout.set(ffi.C.AKEEP_SCREEN_ON_ENABLED)
        elseif self._saved_timeout ~= nil then
            android.timeout.set(self._saved_timeout)
            self._saved_timeout = nil
        end
    end)
end

--- Trim the sentence cache after a session: keep the most recent WAVs so
-- re-reading nearby pages stays instant, drop the rest.
function Controller:pruneSentences()
    local lfs = require("libs/libkoreader-lfs")
    local dir = self:sentencesDir()
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
    if #files <= AutoReader.KEEP_SENTENCES then return end
    table.sort(files, function(a, b) return a.mtime > b.mtime end)
    for i = AutoReader.KEEP_SENTENCES + 1, #files do
        os.remove(files[i].path)
    end
end

-- -------------------------------------------------------- external triggers --

--- Page changes we didn't cause are the user navigating: stop reading.
function Controller:onPageUpdate(page)
    if not self.active or self._self_turning then return end
    if page and self.cur_page and page ~= self.cur_page then
        self:stop(require("gettext")("Auto reader stopped"))
    end
end

-- ------------------------------------------------------------------ entries --

--- Build the sentence list of the next unbuilt page and append its entries.
-- Returns false when there are no more pages.
function Controller:buildNextPage()
    local p = self.plugin
    local doc = p.ui.document
    local ok, total = pcall(function() return doc:getPageCount() end)
    if not ok or not total then
        self.no_more = true
        return false
    end
    local page = (self.build_page or (self.start_page - 1)) + 1
    if page > total then
        self.no_more = true
        return false
    end
    self.build_page = page
    local raw = p:pageText(page) or ""
    local skip = self.carry_skip[page]
    if skip and skip > 0 then
        raw = raw:sub(skip + 1)
    end
    local sents, last_incomplete, open_depth = AutoReader.splitSentences(raw)
    -- Complete a sentence that runs over the page break with the next page's
    -- beginning, and remember how much of that page is already spoken for.
    if last_incomplete and #sents > 0 and page + 1 <= total then
        local nxt = p:pageText(page + 1)
        if nxt and nxt ~= "" then
            local head, consumed = AutoReader.sentenceHead(nxt, AutoReader.HEAD_MAX_BYTES, open_depth)
            if head then
                if head ~= "" then
                    sents[#sents] = sents[#sents] .. head
                end
                self.carry_skip[page + 1] = consumed
            end
        end
    end
    -- Each sentence is synthesized as one or more clause-sized chunks; all
    -- chunks of a sentence belong to the page the sentence started on.
    for _, s in ipairs(sents) do
        local chunks = AutoReader.chunkSentence(s)
        for ci, c in ipairs(chunks) do
            self.entries[#self.entries + 1] = {
                text = c, page = page, tries = 0,
                sentence_end = (ci == #chunks),
            }
        end
    end
    return true
end

function Controller:ensureEntries(through_idx)
    while #self.entries < through_idx and not self.no_more do
        if not self:buildNextPage() then break end
    end
end

-- --------------------------------------------------------------- the engine --

--- The driver: make sure the current sentence's audio exists, steer the view
-- to its page, play it. Every wait (synthesis, playback) re-enters here.
function Controller:tick()
    if not self.active then return end
    self:ensureEntries(self.idx)
    local e = self.entries[self.idx]
    if not e then
        self:stop(require("gettext")("Auto reader: end of book."))
        return
    end
    if self.playing_idx == self.idx then return end -- already audible
    if e.status == "failed" then
        -- One bad chunk shouldn't end the session: skip it and read on. Only
        -- a run of failures (engine actually down) stops us.
        self.consecutive_fails = self.consecutive_fails + 1
        if self.consecutive_fails >= AutoReader.FAIL_LIMIT then
            local T = require("ffi/util").template
            local _ = require("gettext")
            self:stop(T(_("Auto reader stopped: VOICEVOX could not synthesize:\n%1"),
                e.text:sub(1, 80)))
            return
        end
        self.idx = self.idx + 1
        return self:tick()
    end
    local wav, exists = self:wavFor(e.text)
    if not exists then
        self:requestFetch(self.idx)
        return -- pollFetch ticks again once it lands
    end
    e.wav = wav
    self:flipTo(e.page)
    if not self.active then return end
    self:playCurrent()
end

--- Steer the displayed page forward to `page` (the sentence we are about to
-- speak); a flip we cause must not look like manual navigation.
function Controller:flipTo(page)
    local Event = require("ui/event")
    local p = self.plugin
    for _ = 1, 8 do
        if not self.cur_page or self.cur_page >= page then return end
        self._self_turning = true
        p.ui:handleEvent(Event:new("GotoViewRel", 1))
        self._self_turning = false
        local ok, now = pcall(function() return p.ui.document:getCurrentPage() end)
        if not ok or not now or now == self.cur_page then
            -- Cannot advance (very end of the book?): finish gracefully.
            self:stop(require("gettext")("Auto reader: end of book."))
            return
        end
        self.cur_page = now
    end
end

function Controller:playCurrent()
    local UIManager = require("ui/uimanager")
    local AudioPlayer = require("audioplayer")
    local T = require("ffi/util").template
    local _ = require("gettext")
    local e = self.entries[self.idx]
    local ok, err = AudioPlayer:play(e.wav)
    if not ok then
        self:stop(T(_("Auto reader: audio playback failed: %1"), tostring(err)))
        return
    end
    self.playing_idx = self.idx
    self.consecutive_fails = 0 -- we got audio out: the engine is alive
    self._poll_waits = 0
    local duration = AudioPlayer.wavDurationSeconds(e.wav)
        or AutoReader.estimateDuration(e.text)
    -- A short gap within a sentence (the comma already gives a natural pause),
    -- a slightly longer breath after a full sentence.
    local gap = e.sentence_end and AutoReader.GAP_S or AutoReader.CHUNK_GAP_S
    UIManager:unschedule(self._advance_fn)
    UIManager:scheduleIn(duration + gap, self._advance_fn)
    self:refreshEngineLock()
    self:prefetch()
end

--- After a sentence's nominal duration: wait out the player if it is still
-- audible (slow start, paused system…), then move on.
function Controller:advance()
    if not self.active then return end
    local UIManager = require("ui/uimanager")
    local AudioPlayer = require("audioplayer")
    if AudioPlayer:isPlaying() and self._poll_waits < 200 then
        self._poll_waits = self._poll_waits + 1
        UIManager:scheduleIn(AutoReader.POLL_S, self._advance_fn)
        return
    end
    self.playing_idx = nil
    self.idx = self.idx + 1
    self:refreshEngineLock()
    self:tick()
end

--- Refresh the precache pause lock so its staleness window never elapses
-- while we are reading.
function Controller:refreshEngineLock()
    if self.plugin._precache then
        self.plugin._precache:setForegroundFetch(true)
    end
end

-- ---------------------------------------------------------------- synthesis --

--- Synthesize entry `i`'s sentence in a background subprocess (one at a time;
-- the subprocess writes <final>.tmp<pid> and renames, so a kill can't leave a
-- half-written WAV behind).
function Controller:requestFetch(i)
    if self.fetch then return end
    local UIManager = require("ui/uimanager")
    local ffiutil = require("ffi/util")
    local lfs = require("libs/libkoreader-lfs")
    local e = self.entries[i]
    if not e or e.status == "failed" then return end
    local dir = self:sentencesDir()
    if lfs.attributes(dir, "mode") ~= "directory" then
        require("util").makePath(dir)
    end
    local final = self:wavFor(e.text)
    -- Bounded per-chunk timeouts (chunks are small): a slow/hung engine fails
    -- fast and the chunk is retried, instead of inheriting voicevox.lua's
    -- run-to-completion defaults and stalling the session.
    local opts = {
        url = self.opts.url,
        speaker = self.opts.speaker,
        normalize = self.opts.normalize,
        synth_block_timeout = AutoReader.SYNTH_BLOCK_TIMEOUT,
        synth_total_timeout = AutoReader.SYNTH_TOTAL_TIMEOUT,
    }
    local text = e.text
    e.tries = e.tries + 1
    local pid = ffiutil.runInSubProcess(function(child_pid)
        local VoiceVox = require("voicevox")
        local tmp = final .. ".tmp" .. tostring(child_pid)
        local ok = VoiceVox.fetch(opts, text, tmp)
        if ok then
            os.rename(tmp, final)
        else
            os.remove(tmp)
        end
    end)
    if not pid then
        self:stop(require("gettext")("Auto reader: could not start the synthesis process."))
        return
    end
    self.fetch = { idx = i, pid = pid, final = final, started = os.time() }
    UIManager:unschedule(self._fetch_poll_fn)
    UIManager:scheduleIn(AutoReader.POLL_S, self._fetch_poll_fn)
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
        -- Keep collecting killed fetches from a stopped session.
        if #self._zombies > 0 then
            UIManager:scheduleIn(2, self._fetch_poll_fn)
        end
        return
    end
    -- Hold the precache off the engine for as long as we are waiting, so a
    -- long synthesis isn't joined by a precache request (the staleness window
    -- would otherwise lapse mid-fetch).
    self:refreshEngineLock()

    local done = ffiutil.isSubProcessDone(self.fetch.pid)
    if not done then
        if os.time() - (self.fetch.started or 0) < AutoReader.FETCH_DEADLINE_S then
            UIManager:scheduleIn(AutoReader.POLL_S, self._fetch_poll_fn)
            return
        end
        -- Hung synthesis: kill it and treat this attempt as a failure.
        ffiutil.terminateSubProcess(self.fetch.pid)
        self._zombies[#self._zombies + 1] = self.fetch.pid
    end

    local fetch = self.fetch
    self.fetch = nil
    if not self.active then return end
    local e = self.entries[fetch.idx]
    local landed = lfs.attributes(fetch.final, "mode") == "file"
    if not landed and e and e.tries >= AutoReader.MAX_FETCH_TRIES then
        e.status = "failed" -- tick() skips it (or stops after FAIL_LIMIT)
    end
    if fetch.idx == self.idx then
        self:tick()       -- we were waiting for exactly this chunk
    else
        self:prefetch()   -- keep working ahead
    end
end

--- Keep the next PREFETCH sentences synthesized while the current one plays.
function Controller:prefetch()
    if not self.active or self.fetch then return end
    self:ensureEntries(self.idx + AutoReader.PREFETCH)
    for j = self.idx, math.min(self.idx + AutoReader.PREFETCH, #self.entries) do
        local e = self.entries[j]
        if e and e.status ~= "failed" then
            local _, exists = self:wavFor(e.text)
            if not exists then
                self:requestFetch(j)
                return
            end
        end
    end
end

return AutoReader
