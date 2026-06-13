--- Silent background precache of tap-word audio for nearby pages.
--
-- Keeps the VOICEVOX audio of every word a tap could speak on the previous
-- two, current and next two pages synthesized ahead of time, so tapping a
-- word plays instantly. Page turns (debounced) re-target a background worker
-- subprocess; the WAVs land in cache/furigana/audio/precache/ and are deleted
-- again once their page leaves the window. main.lua's speakText() "promotes"
-- a precached file into the permanent audio cache when it is actually played,
-- so words the user listened to survive the pruning.
--
-- To get cache hits the worker must predict speakText()'s input exactly, so
-- it replicates japanese.koplugin's expandWord() scan over the page text:
-- from every Japanese character, the prefixes of 2..max_scan+1 characters
-- (expandWord never tries the single tapped character) are deinflected with
-- the Yomichan rules and batch-looked-up in sdcv; the longest prefix with a
-- dictionary hit is what a tap there would speak. Single kanji/katakana
-- characters are the fallback when nothing matches. Per-page word lists
-- ("manifests") are cached by page-text hash, so only pages entering the
-- window cost a deinflection+sdcv pass.
--
-- The worker pauses (lock file, see Controller:setForegroundFetch) while a
-- foreground fetch is running, keeping the engine free for the word the user
-- is actually waiting for.
--
-- The pure logic (candidate scan, want resolution, pruning, the worker loop)
-- takes all its dependencies via arguments and is unit-tested standalone:
--   lua tools/run_precache_test.lua
--
-- @module koplugin.furigana.precache

local Precache = {}

-- Precache priority: the page being read first, then forward (the likely
-- direction), then back.
Precache.WINDOW_DELTAS = { 0, 1, 2, -1, -2 }
Precache.DEBOUNCE_S = 2       -- settle time after the last page turn
Precache.SDCV_CHUNK = 400     -- terms per sdcv invocation (command-line length)
Precache.PAUSE_BASENAME = "fg.lock"
Precache.PAUSE_STALE_S = 180  -- ignore a pause lock this old (owner crashed)
-- One worker run synthesizes at most this many words, then exits and leaves
-- an "incomplete" flag so the controller spawns a fresh worker to continue.
-- Bounds the forked child's lifetime and memory (a long-lived fork slowly
-- copy-on-writes the parent heap — unkind to small devices) and yields the
-- engine regularly.
Precache.MAX_FETCH_PER_RUN = 100
Precache.INCOMPLETE_BASENAME = "incomplete.flag"
-- A run that died on a synthesis failure leaves this flag; the controller
-- retries after a delay (or immediately on the next page turn) instead of
-- treating the window as done.
Precache.RETRY_BASENAME = "retry.flag"
Precache.RETRY_DELAY_S = 60
-- Per-word synthesis timeouts for the background worker: a single word taking
-- this long means the engine is gone or overloaded — stop the run and retry
-- on a later page turn rather than hammering it (foreground fetches keep the
-- huge run-to-completion timeouts from voicevox.lua).
Precache.WORKER_BLOCK_TIMEOUT = 120
Precache.WORKER_TOTAL_TIMEOUT = 300

-- djb2 hash -> 8 hex chars, same as main.lua's hash_str.
local function hash_str(s)
    local h = 5381
    for i = 1, #s do h = (h * 33 + s:byte(i)) % 4294967296 end
    return string.format("%08x", h)
end
Precache.hash = hash_str

--- Cache key for one synthesized text. This is the single source of truth for
-- audio cache file names: main.lua's audioCachePathFor() uses it too, which is
-- what makes precached files findable by speakText().
function Precache.audioKey(url, speaker, text)
    return hash_str(("%s|%s|%s"):format(url, speaker, text))
end

-- Decode the UTF-8 codepoint starting at byte i. Returns cp, byte length.
local function utf8_at(s, i)
    local b = s:byte(i)
    if b < 0x80 then return b, 1 end
    if b < 0xC0 then return b, 1 end -- stray continuation byte: skip it
    if b < 0xE0 then
        return (b % 0x20) * 0x40 + ((s:byte(i + 1) or 0) % 0x40), 2
    end
    if b < 0xF0 then
        return (b % 0x10) * 0x1000 + ((s:byte(i + 1) or 0) % 0x40) * 0x40
            + ((s:byte(i + 2) or 0) % 0x40), 3
    end
    return (b % 0x08) * 0x40000 + ((s:byte(i + 1) or 0) % 0x40) * 0x1000
        + ((s:byte(i + 2) or 0) % 0x40) * 0x40 + ((s:byte(i + 3) or 0) % 0x40), 4
end

-- A codepoint that can be part of a Japanese dictionary word, mirroring
-- japanese.koplugin's isPossibleJapaneseWord() (CJK minus punctuation): the
-- expansion scan starts on these and stops at anything else.
local function is_word_cp(cp)
    return (cp >= 0x3041 and cp <= 0x30FF and cp ~= 0x30FB) -- kana; ・ excluded
        or (cp >= 0x31F0 and cp <= 0x31FF)   -- katakana phonetic extensions
        or (cp >= 0xFF66 and cp <= 0xFF9F)   -- half-width katakana
        or cp == 0x3005 or cp == 0x3006 or cp == 0x3007 -- 々 〆 〇
        or (cp >= 0x4E00 and cp <= 0x9FFF)   -- CJK Unified Ideographs
        or (cp >= 0x3400 and cp <= 0x4DBF)   -- CJK Extension A
        or (cp >= 0xF900 and cp <= 0xFAFF)   -- CJK Compatibility Ideographs
        or (cp >= 0x20000 and cp <= 0x3134F) -- rare ideographs (planes 2-3)
end

-- Worth caching as a bare character: a tap with no dictionary match falls
-- back to speaking just the tapped character, which is a plausible word for
-- kanji and katakana but mostly grammar noise for hiragana / long-vowel and
-- iteration marks.
local function is_fallback_cp(cp)
    return is_word_cp(cp)
        and not (cp >= 0x3041 and cp <= 0x309F) -- hiragana
        and not (cp >= 0x30FC and cp <= 0x30FE) -- ー ヽ ヾ
end

-- Shared with autoreader.lua (sentence splitting walks the same codepoints).
Precache.utf8At = utf8_at
Precache.isWordCp = is_word_cp

--- Scan `text` the way a tap would: for every Japanese character, collect the
-- prefixes a tap there would try (2..max_scan+1 characters, stopping at
-- punctuation or end of text), each with its deinflected candidate terms.
-- `deinflect(surface)` must return an array of candidate dictionary forms.
-- Returns positions = { { char, cp, prefixes = { {surface, terms} } } } and a
-- deduped array of every term (for one batched dictionary lookup).
function Precache.collectCandidates(text, deinflect, max_scan)
    max_scan = max_scan or 20
    local offs, cps = {}, {} -- byte offset / codepoint per character
    local i = 1
    while i <= #text do
        local cp, len = utf8_at(text, i)
        offs[#offs + 1] = i
        cps[#cps + 1] = cp
        i = i + len
    end
    offs[#offs + 1] = #text + 1 -- sentinel: end of the last character
    local positions = {}
    local terms, terms_seen = {}, {}
    for ci = 1, #cps do
        if is_word_cp(cps[ci]) then
            local prefixes = {}
            for clen = 2, max_scan + 1 do
                local last = ci + clen - 1
                if last > #cps or not is_word_cp(cps[last]) then break end
                local surface = text:sub(offs[ci], offs[last + 1] - 1)
                local cand_terms = deinflect(surface)
                prefixes[#prefixes + 1] = { surface = surface, terms = cand_terms }
                for _, t in ipairs(cand_terms) do
                    if not terms_seen[t] then
                        terms_seen[t] = true
                        terms[#terms + 1] = t
                    end
                end
            end
            positions[#positions + 1] = {
                char = text:sub(offs[ci], offs[ci + 1] - 1),
                cp = cps[ci],
                prefixes = prefixes,
            }
        end
    end
    return positions, terms
end

--- Resolve what a tap on each position would speak, given the set of terms
-- that had dictionary hits: the longest prefix with any hit (expandWord keeps
-- the last match found, i.e. the longest), else the bare character when it is
-- a plausible word on its own. Returns a deduped array of want words.
function Precache.resolveWants(positions, hits)
    local wants, seen = {}, {}
    local function add(w)
        if not seen[w] then
            seen[w] = true
            wants[#wants + 1] = w
        end
    end
    for _, p in ipairs(positions) do
        local best
        for _, pref in ipairs(p.prefixes) do
            for _, t in ipairs(pref.terms) do
                if hits[t] then
                    best = pref.surface
                    break
                end
            end
        end
        if best then
            add(best)
        elseif is_fallback_cp(p.cp) then
            add(p.char)
        end
    end
    return wants
end

--- The full want computation for one page text.
-- deps: { deinflect = fn(s)->{terms}, lookup = fn({terms})->{term=true}, max_scan }
function Precache.computeWantList(text, deps)
    local positions, terms = Precache.collectCandidates(text, deps.deinflect, deps.max_scan)
    local hits = deps.lookup(terms) or {}
    return Precache.resolveWants(positions, hits)
end

-- ---------------------------------------------------------------- manifests --
-- One "want_<pagetexthash>.list" file per page, one want word per line. The
-- words depend only on the page text and the installed dictionaries — not on
-- the engine URL or speaker — so manifests survive speaker changes.

function Precache.manifestName(page_hash)
    return "want_" .. page_hash .. ".list"
end

function Precache.readManifest(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local words = {}
    for line in f:lines() do
        if line ~= "" then words[#words + 1] = line end
    end
    f:close()
    return words
end

function Precache.writeManifest(path, words, tmp_suffix)
    local tmp = path .. (tmp_suffix or ".tmp")
    local f = io.open(tmp, "w")
    if not f then return false end
    f:write(table.concat(words, "\n"))
    f:close()
    return os.rename(tmp, path) and true or false
end

-- ------------------------------------------------------------------- worker --

--- Worker body: compute the window's want lists (manifest-cached), prune
-- whatever fell out of the window, then synthesize what's missing, current
-- page first. Runs in a forked subprocess in production, inline in tests;
-- everything it touches comes through cfg:
--   pages         { { text, hash } } in priority order
--   opts          VoiceVox opts (url, speaker, synth_*_timeout)
--   audio_dir     the permanent audio cache (promoted/tapped words)
--   precache_dir  the managed window cache this worker owns
--   deinflect / lookup / max_scan   see computeWantList
--   fetch         fn(opts, text, out_path) -> ok, err
--   fs            { exists, list, remove, rename, mkdir }
--   pause_active  optional fn() -> bool (foreground fetch in progress)
--   abort         optional fn() -> bool (parent gone / told us to stop)
--   sleep         fn(seconds), used while paused
--   tmp_suffix    unique temp-file suffix (worker pid)
-- Returns true, n_fetched — or nil and a reason.
function Precache.runWorker(cfg)
    local fs = cfg.fs
    local function aborted()
        return cfg.abort and cfg.abort()
    end
    fs.mkdir(cfg.precache_dir)

    -- 1) The window's want set: key -> text, keys in priority order.
    local window_manifests = {}
    local want, order = {}, {}
    for _, page in ipairs(cfg.pages) do
        local mname = Precache.manifestName(page.hash)
        window_manifests[mname] = true
        local mpath = cfg.precache_dir .. "/" .. mname
        local words = Precache.readManifest(mpath)
        if not words then
            words = Precache.computeWantList(page.text, cfg)
            Precache.writeManifest(mpath, words, cfg.tmp_suffix)
        end
        for _, w in ipairs(words) do
            local key = Precache.audioKey(cfg.opts.url, cfg.opts.speaker, w)
            if want[key] == nil then
                want[key] = w
                order[#order + 1] = key
            end
        end
        if aborted() then return nil, "aborted" end
    end

    -- 2) Prune: delete precached audio and manifests that are no longer in
    -- the window, and any temp leftovers (only one worker ever runs).
    for _, name in ipairs(fs.list(cfg.precache_dir)) do
        local keep
        if name == Precache.PAUSE_BASENAME or name == Precache.INCOMPLETE_BASENAME
                or name == Precache.RETRY_BASENAME then
            keep = true
        elseif name:match("^want_.*%.list$") then
            keep = window_manifests[name]
        elseif name:match("^%x+%.wav$") then
            keep = want[name:sub(1, -5)] ~= nil
        end
        if not keep then
            fs.remove(cfg.precache_dir .. "/" .. name)
        end
    end

    -- 3) Synthesize what's missing (skipping words already in the permanent
    -- cache), pausing while a foreground fetch owns the engine, and exiting
    -- early once this run's fetch budget is spent.
    local fetched = 0
    local incomplete = false
    local max_fetch = cfg.max_fetch or Precache.MAX_FETCH_PER_RUN
    for _, key in ipairs(order) do
        while cfg.pause_active and cfg.pause_active() do
            if aborted() then return nil, "aborted" end
            cfg.sleep(0.5)
        end
        if aborted() then return nil, "aborted" end
        local final = cfg.precache_dir .. "/" .. key .. ".wav"
        if not fs.exists(final) and not fs.exists(cfg.audio_dir .. "/" .. key .. ".wav") then
            if fetched >= max_fetch then
                incomplete = true
                break
            end
            local tmp = final .. (cfg.tmp_suffix or ".tmp")
            local ok, err = cfg.fetch(cfg.opts, want[key], tmp)
            if not ok then
                fs.remove(tmp)
                -- Engine unreachable/overloaded: give up quietly, but flag
                -- the run as failed so the controller retries this window
                -- later instead of considering it done.
                local f = io.open(cfg.precache_dir .. "/" .. Precache.RETRY_BASENAME, "w")
                if f then f:close() end
                return nil, "fetch failed for \"" .. tostring(want[key]) .. "\": " .. tostring(err)
            end
            fs.rename(tmp, final)
            fetched = fetched + 1
        end
    end
    -- The incomplete flag tells the controller to spawn a fresh worker for
    -- the rest; a clean end (full or budget-stopped) clears any failure flag.
    local flag = cfg.precache_dir .. "/" .. Precache.INCOMPLETE_BASENAME
    if incomplete then
        local f = io.open(flag, "w")
        if f then f:close() end
    else
        fs.remove(flag)
    end
    fs.remove(cfg.precache_dir .. "/" .. Precache.RETRY_BASENAME)
    return true, fetched, incomplete
end

-- --------------------------------------------------------------- controller --
-- Parent-side: debounce page turns, capture the window's page texts, spawn or
-- re-target the worker, reap it, and expose the foreground-fetch pause lock.
-- Created lazily by main.lua, torn down on document close.

local Controller = {}
Controller.__index = Controller

function Precache.newController(plugin)
    local self = setmetatable({
        plugin = plugin,
        pid = nil,       -- live worker
        sig = nil,       -- window signature the live worker is filling
        done_sig = nil,  -- window signature already completed
        _zombies = {},
    }, Controller)
    self._kick_fn = function() self:kick() end
    self._reap_fn = function() self:reap() end
    return self
end

function Controller:precacheDir()
    return self.plugin.cache_dir .. "/audio/precache"
end

function Controller:pauseLockPath()
    return self:precacheDir() .. "/" .. Precache.PAUSE_BASENAME
end

--- Pause/resume the worker around a foreground fetch (lock file; the worker
-- checks it between two synthesis requests). Also refreshed by the auto
-- reader for as long as it is running.
function Controller:setForegroundFetch(active)
    local path = self:pauseLockPath()
    if active then
        local lfs = require("libs/libkoreader-lfs")
        if lfs.attributes(self:precacheDir(), "mode") ~= "directory" then
            require("util").makePath(self:precacheDir())
        end
        local f = io.open(path, "w")
        if f then
            f:write(tostring(os.time()))
            f:close()
        end
    else
        os.remove(path)
    end
end

--- Debounced kick: page turns can come in bursts while the reader skims.
function Controller:schedule()
    local UIManager = require("ui/uimanager")
    UIManager:unschedule(self._kick_fn)
    UIManager:scheduleIn(Precache.DEBOUNCE_S, self._kick_fn)
end

-- All the conditions under which precaching makes sense: the feature (and tap
-- audio) on, a rolling original (un-annotated) document, and the Japanese
-- plugin + dictionary available for the expansion scan.
function Controller:enabled()
    local p = self.plugin
    return p:isTapAudioEnabled() and p:isPrecacheEnabled()
        and p.ui and p.ui.rolling and p.ui.document
        and not p:isShowingAnnotated()
        and p.ui.japanese and p.ui.japanese.deinflector
        and p.ui.dictionary and p.ui.dictionary.rawSdcv
end

--- The text of one rendered page (main.lua's shared helper).
function Controller:pageText(page)
    return self.plugin:pageText(page)
end

--- The window around the current page, in precache priority order, plus its
-- signature (page-text hashes + everything the cache keys depend on).
function Controller:captureWindow()
    local p = self.plugin
    local doc = p.ui.document
    local ok, cur, total = pcall(function()
        return doc:getCurrentPage(), doc:getPageCount()
    end)
    if not ok or not cur or not total or total < 1 then return nil end
    local util = require("util")
    local opts = p:voicevoxOpts()
    local pages, seen = {}, {}
    local sig = ("%s|%s"):format(opts.url, opts.speaker)
    for _, delta in ipairs(Precache.WINDOW_DELTAS) do
        local pg = cur + delta
        if pg >= 1 and pg <= total and not seen[pg] then
            seen[pg] = true
            local text = self:pageText(pg)
            if text and text ~= "" and util.hasCJKChar(text) then
                local h = hash_str(text)
                pages[#pages + 1] = { text = text, hash = h }
                sig = sig .. "|" .. h
            end
        end
    end
    return pages, sig
end

function Controller:kick()
    local UIManager = require("ui/uimanager")
    local ffiutil = require("ffi/util")
    UIManager:unschedule(self._kick_fn)
    if not self:enabled() then
        self:stop()
        return
    end
    -- While the auto reader is speaking, the engine belongs to it; its stop
    -- re-schedules us.
    if self.plugin.autoreader and self.plugin.autoreader:isActive() then return end
    if self.pid and not ffiutil.isSubProcessDone(self.pid) then
        -- A worker is busy. Let it finish its bounded run even when the
        -- window has moved on: killing it mid-run throws away the manifest
        -- (sdcv) work it is doing, and with quick page turns that livelocked
        -- into computing the same manifests over and over without ever
        -- fetching ("precache stopped making files"). reap() re-kicks when
        -- it exits and we re-target then.
        return
    elseif self.pid then -- finished on its own, not reaped yet
        table.insert(self._zombies, self.pid)
        self.pid = nil
        self.done_sig = self.sig
        self.sig = nil
    end
    local pages, sig = self:captureWindow()
    if not pages or #pages == 0 then return end
    if sig == self.done_sig then return end -- window already fully cached
    self.sig = sig
    self.pid = self:spawn(pages)
    if not self.pid then self.sig = nil end
    self:scheduleReap()
end

--- Forget completed work and stop any running worker (cache cleared,
-- speaker/url changed — its output would be for the old cache keys). The
-- caller re-schedules.
function Controller:invalidate()
    self.done_sig = nil
    if self.pid then
        local ffiutil = require("ffi/util")
        ffiutil.terminateSubProcess(self.pid)
        table.insert(self._zombies, self.pid)
        self.pid, self.sig = nil, nil
        self:scheduleReap()
    end
end

function Controller:spawn(pages)
    local p = self.plugin
    local ffiutil = require("ffi/util")
    local lfs = require("libs/libkoreader-lfs")
    local logger = require("logger")
    local VoiceVox = require("voicevox")
    local ffi = require("ffi")
    pcall(ffi.cdef, "int getppid(void);")

    local japanese = p.ui.japanese
    local dictionary = p.ui.dictionary
    local opts = p:voicevoxOpts()
    opts.synth_block_timeout = Precache.WORKER_BLOCK_TIMEOUT
    opts.synth_total_timeout = Precache.WORKER_TOTAL_TIMEOUT
    local pause_path = self:pauseLockPath()

    -- Warm the deinflection rules once in the parent: every forked worker
    -- then inherits them parsed instead of re-reading the JSON per page turn.
    if not self._warmed then
        pcall(japanese.deinflector.deinflect, japanese.deinflector, "食べた")
        self._warmed = true
    end

    local cfg = {
        pages = pages,
        opts = opts,
        audio_dir = p.cache_dir .. "/audio",
        precache_dir = self:precacheDir(),
        max_scan = japanese.max_scan_length or 20,
        deinflect = function(s)
            local ok, res = pcall(japanese.deinflector.deinflect, japanese.deinflector, s)
            if not ok or type(res) ~= "table" then return {} end
            local out = {}
            for _, r in ipairs(res) do
                if type(r) == "table" and type(r.term) == "string" then
                    out[#out + 1] = r.term
                end
            end
            return out
        end,
        lookup = function(terms)
            -- Chunked batch lookup; in this (non-coroutine) subprocess
            -- rawSdcv degrades to a plain blocking popen, which is fine.
            local hits = {}
            for i = 1, #terms, Precache.SDCV_CHUNK do
                local chunk = {}
                for j = i, math.min(i + Precache.SDCV_CHUNK - 1, #terms) do
                    chunk[#chunk + 1] = terms[j]
                end
                local ok, cancelled, results = pcall(dictionary.rawSdcv, dictionary, chunk, nil, false)
                if ok and not cancelled and type(results) == "table" then
                    for j, r in ipairs(results) do
                        if type(r) == "table" and #r > 0 then
                            hits[chunk[j]] = true
                        end
                    end
                end
            end
            return hits
        end,
        fetch = function(o, text, out)
            return VoiceVox.fetch(o, text, out)
        end,
        fs = {
            exists = function(path) return lfs.attributes(path, "mode") == "file" end,
            list = function(dir)
                local out = {}
                if lfs.attributes(dir, "mode") ~= "directory" then return out end
                for f in lfs.dir(dir) do
                    if f ~= "." and f ~= ".." then out[#out + 1] = f end
                end
                return out
            end,
            remove = function(path) return os.remove(path) end,
            rename = function(a, b) return os.rename(a, b) end,
            mkdir = function(dir)
                if lfs.attributes(dir, "mode") ~= "directory" then
                    require("util").makePath(dir)
                end
            end,
        },
        pause_active = function()
            local attr = lfs.attributes(pause_path)
            if not attr then return false end
            return os.time() - (attr.modification or 0) <= Precache.PAUSE_STALE_S
        end,
        abort = function()
            -- Orphaned (KOReader quit/crashed without killing us): stop.
            local ok, ppid = pcall(function() return ffi.C.getppid() end)
            return ok and ppid == 1
        end,
        sleep = function(s) ffiutil.usleep(s * 1000000) end,
    }

    local pid = ffiutil.runInSubProcess(function(child_pid)
        cfg.tmp_suffix = ".tmp" .. tostring(child_pid)
        local ok, n, incomplete = Precache.runWorker(cfg)
        -- info-level on purpose: these lines are the breadcrumbs in
        -- crash.log when something around audio goes wrong on-device.
        if not ok then
            if n ~= "aborted" then
                logger.warn("furigana precache: worker stopped:", n)
            end
        elseif incomplete then
            logger.info("furigana precache: fetched", n, "words, budget spent, more pending")
        elseif n > 0 then
            logger.info("furigana precache: window complete,", n, "words fetched")
        end
    end)
    if not pid then
        logger.warn("furigana precache: could not fork worker")
        return nil
    end
    logger.info("furigana precache: worker", pid, "started for", #pages, "pages")
    return pid
end

--- Collect finished/killed workers so they don't linger as zombies; when the
-- current worker has finished, decide how to continue: straight away for a
-- budget-stopped run, after a delay for a failed one, and re-target in any
-- case (the reader may have moved on while it ran).
function Controller:reap()
    local UIManager = require("ui/uimanager")
    local ffiutil = require("ffi/util")
    if self.pid and ffiutil.isSubProcessDone(self.pid) then
        self.pid = nil
        self.done_sig = self.sig
        self.sig = nil
        local lfs = require("libs/libkoreader-lfs")
        local pre = self:precacheDir()
        if lfs.attributes(pre .. "/" .. Precache.INCOMPLETE_BASENAME, "mode") == "file" then
            self.done_sig = nil -- budget spent: a fresh worker continues
            self:schedule()
        elseif lfs.attributes(pre .. "/" .. Precache.RETRY_BASENAME, "mode") == "file" then
            -- A synthesis failed (engine busy/down): don't mark the window
            -- done; retry after a pause (a page turn retries sooner anyway).
            os.remove(pre .. "/" .. Precache.RETRY_BASENAME)
            self.done_sig = nil
            UIManager:unschedule(self._kick_fn)
            UIManager:scheduleIn(Precache.RETRY_DELAY_S, self._kick_fn)
        else
            -- Completed. Re-kick: if the window moved while we ran, the next
            -- worker targets the new one (no-op otherwise, thanks done_sig).
            self:schedule()
        end
    end
    local still = {}
    for _, z in ipairs(self._zombies) do
        if not ffiutil.isSubProcessDone(z) then still[#still + 1] = z end
    end
    self._zombies = still
    if self.pid or #self._zombies > 0 then
        self:scheduleReap()
    end
end

function Controller:scheduleReap()
    local UIManager = require("ui/uimanager")
    UIManager:unschedule(self._reap_fn)
    UIManager:scheduleIn(2, self._reap_fn)
end

--- Stop the worker (document closing, feature toggled off…). Keeps cached
-- files on disk: the next kick decides what is still wanted.
function Controller:stop()
    local UIManager = require("ui/uimanager")
    local ffiutil = require("ffi/util")
    UIManager:unschedule(self._kick_fn)
    if self.pid then
        ffiutil.terminateSubProcess(self.pid)
        table.insert(self._zombies, self.pid)
        self.pid, self.sig = nil, nil
        self:scheduleReap()
    end
end

return Precache
