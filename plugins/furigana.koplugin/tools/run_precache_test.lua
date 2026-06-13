-- Tests for precache.lua's pure logic: the expandWord-mirroring candidate
-- scan, want-set resolution, cache keying, manifests, and the worker loop
-- (manifest reuse, pruning, fetch order, pause/abort) against a temp dir.
-- Pure Lua, no KOReader runtime needed:
--   lua tools/run_precache_test.lua

local here = arg[0]:match("^(.*)/[^/]*$") or "."
package.path = here .. "/../?.lua;" .. package.path

local Precache = require("precache")

local failures = 0
local function check(cond, msg)
    if cond then
        print("ok   - " .. msg)
    else
        failures = failures + 1
        print("FAIL - " .. msg)
    end
end

-- ---------------------------------------------------------------- audioKey --

local function djb2(s)
    local h = 5381
    for i = 1, #s do h = (h * 33 + s:byte(i)) % 4294967296 end
    return string.format("%08x", h)
end

check(Precache.audioKey("http://x", 3, "食べる") == djb2("http://x|3|食べる"),
    "audioKey is djb2 of url|speaker|text (matches main.lua's cache keying)")
check(Precache.audioKey("http://x", 3, "a") ~= Precache.audioKey("http://x", 4, "a"),
    "audioKey distinguishes speakers")
check(table.concat(Precache.WINDOW_DELTAS, ",") == "0,1,2,-1,-2",
    "window priority is reading page first, then forward, then back")

-- ------------------------------------------------------------ codepoints --

check(Precache.isWordCp(0x98DF) and Precache.isWordCp(0x3042) and Precache.isWordCp(0x30A2),
    "kanji/hiragana/katakana are word codepoints")
check(not Precache.isWordCp(0x3002) and not Precache.isWordCp(0x30FB)
        and not Precache.isWordCp(0x41),
    "。/・/latin are not word codepoints (scan stops)")
local cp, len = Precache.utf8At("食べる", 1)
check(cp == 0x98DF and len == 3, "utf8At decodes a 3-byte kanji")

-- ---------------------------------------------------- collectCandidates --

-- Identity deinflector: every surface is its own (single) candidate term.
local function identity_deinflect(s) return { s } end

-- 私は学校へ行った。
local positions, terms = Precache.collectCandidates("私は学校へ行った。", identity_deinflect, 20)
check(#positions == 8, "every Japanese char is a scan position (8, 。 excluded): " .. #positions)
check(positions[1].char == "私" and positions[1].prefixes[1].surface == "私は",
    "prefixes start at two characters (expandWord never tries the bare char)")
local last_pos = positions[#positions]
check(last_pos.char == "た" and #last_pos.prefixes == 0,
    "final char before 。 has no prefixes (scan would hit punctuation)")
local seen_terms = {}
for _, t in ipairs(terms) do
    check(not seen_terms[t], "terms are deduped: " .. t)
    seen_terms[t] = true
end
check(seen_terms["学校"] and seen_terms["私は学校"],
    "candidate terms include all scanned prefixes")

-- max_scan caps the prefix length at max_scan+1 characters.
local pos2 = Precache.collectCandidates("あいうえおかきくけこ", identity_deinflect, 3)
check(#pos2[1].prefixes == 3 and pos2[1].prefixes[3].surface == "あいうえ",
    "max_scan=3 tries prefixes of 2..4 characters")

-- ------------------------------------------------------------ resolveWants --

local wants = Precache.resolveWants(positions, { ["学校"] = true })
local wset = {}
for _, w in ipairs(wants) do wset[w] = true end
check(wset["学校"], "dictionary hit: the matching surface is wanted")
check(wset["私"] and wset["校"] and wset["行"],
    "no-hit kanji positions fall back to the bare character")
check(not wset["は"] and not wset["へ"] and not wset["っ"] and not wset["た"],
    "no-hit hiragana positions are not cached bare")
check(#wants == 4, "wants are exactly {学校,私,校,行}: " .. table.concat(wants, ","))

-- Longest hit wins (expandWord keeps the last match).
local pos3 = Precache.collectCandidates("食べていた", identity_deinflect, 20)
local wants3 = Precache.resolveWants(pos3, { ["食べ"] = true, ["食べてい"] = true })
check(wants3[1] == "食べてい",
    "longest matching prefix wins: " .. wants3[1])

-- Katakana fallback is kept, the prolonged-sound mark is not.
local pos4 = Precache.collectCandidates("東京タワー。", identity_deinflect, 20)
local wants4 = Precache.resolveWants(pos4, { ["東京"] = true })
local w4 = table.concat(wants4, ",")
check(w4 == "東京,京,タ,ワ",
    "katakana falls back bare, ー does not: " .. w4)

-- computeWantList wires scan + lookup together (and lookup sees the terms).
local looked_up
local wl = Precache.computeWantList("東京タワー。", {
    deinflect = identity_deinflect,
    lookup = function(t) looked_up = #t; return { ["東京"] = true } end,
    max_scan = 20,
})
check(table.concat(wl, ",") == "東京,京,タ,ワ" and looked_up and looked_up > 0,
    "computeWantList resolves through the injected lookup")

-- -------------------------------------------------------------- manifests --

local mpath = os.tmpname()
check(Precache.writeManifest(mpath, { "学校", "私" }, ".tmpX") == true
        and table.concat(Precache.readManifest(mpath), ",") == "学校,私",
    "manifest write/read round-trips")
check(Precache.writeManifest(mpath, {}, ".tmpX") == true
        and #Precache.readManifest(mpath) == 0,
    "an empty manifest reads back as empty (not nil): computed, nothing wanted")
os.remove(mpath)
check(Precache.readManifest(mpath) == nil, "a missing manifest reads as nil")

-- -------------------------------------------------------------- runWorker --

-- Real temp dirs + a tiny fs implementation (plain Lua: ls via popen).
local root = os.tmpname()
os.remove(root)
os.execute("mkdir -p '" .. root .. "'")
local audio_dir = root .. "/audio"
local pre_dir = audio_dir .. "/precache"
os.execute("mkdir -p '" .. pre_dir .. "'")

local function exists(p)
    local f = io.open(p, "r")
    if f then f:close() return true end
    return false
end
local function write_file(p, content)
    local f = io.open(p, "w")
    f:write(content or "x")
    f:close()
end
local fs = {
    exists = exists,
    list = function(dir)
        local out = {}
        local p = io.popen("ls -a '" .. dir .. "' 2>/dev/null")
        if p then
            for line in p:lines() do
                if line ~= "." and line ~= ".." then out[#out + 1] = line end
            end
            p:close()
        end
        return out
    end,
    remove = os.remove,
    rename = os.rename,
    mkdir = function(dir) os.execute("mkdir -p '" .. dir .. "'") end,
}

local opts = { url = "http://x", speaker = 3 }
local page_a = { text = "私は学校へ行った。", hash = Precache.hash("私は学校へ行った。") }
local page_b = { text = "東京タワー。", hash = Precache.hash("東京タワー。") }
local function key(text) return Precache.audioKey(opts.url, opts.speaker, text) end

-- Pre-state: one wanted word already precached, one already in the permanent
-- cache, plus junk that must be pruned.
write_file(pre_dir .. "/" .. key("学校") .. ".wav")
write_file(audio_dir .. "/" .. key("東京") .. ".wav")
write_file(pre_dir .. "/" .. key("古い言葉") .. ".wav") -- not wanted anymore
write_file(pre_dir .. "/want_deadbeef.list", "古い言葉")  -- stale manifest
write_file(pre_dir .. "/leftover.tmp999")                 -- dead worker's temp

local deinflect_calls = 0
local fetched = {}
local pauses = 0
local slept = 0
local cfg = {
    pages = { page_a, page_b },
    opts = opts,
    audio_dir = audio_dir,
    precache_dir = pre_dir,
    max_scan = 20,
    deinflect = function(s) deinflect_calls = deinflect_calls + 1; return { s } end,
    lookup = function() return { ["学校"] = true, ["東京"] = true } end,
    fetch = function(_, text, out)
        fetched[#fetched + 1] = text
        write_file(out, "RIFF" .. text)
        return true
    end,
    fs = fs,
    pause_active = function()
        if pauses < 2 then pauses = pauses + 1; return true end
        return false
    end,
    sleep = function() slept = slept + 1 end,
    tmp_suffix = ".tmp42",
}

local ok, n = Precache.runWorker(cfg)
check(ok == true and n == 6, "worker run succeeds and fetches the 6 missing words: " .. tostring(n))
check(table.concat(fetched, ",") == "私,校,行,京,タ,ワ",
    "fetch order follows page priority, skipping already-cached words: " .. table.concat(fetched, ","))
check(slept == 2, "worker waited out the foreground-fetch pause")
check(not exists(pre_dir .. "/" .. key("古い言葉") .. ".wav"),
    "precached audio that left the window is deleted")
check(not exists(pre_dir .. "/want_deadbeef.list"), "stale manifests are deleted")
check(not exists(pre_dir .. "/leftover.tmp999"), "dead workers' temp files are deleted")
check(exists(pre_dir .. "/" .. key("学校") .. ".wav"),
    "still-wanted precached audio survives the pruning")
check(exists(pre_dir .. "/" .. key("私") .. ".wav") and exists(pre_dir .. "/" .. key("ワ") .. ".wav"),
    "fetched audio lands under its cache key")
check(exists(pre_dir .. "/" .. Precache.manifestName(page_a.hash))
        and exists(pre_dir .. "/" .. Precache.manifestName(page_b.hash)),
    "both pages' manifests are written")

-- Second run over the same window: manifests are reused (no deinflection),
-- nothing is missing (no fetches).
deinflect_calls, fetched = 0, {}
local ok2, n2 = Precache.runWorker(cfg)
check(ok2 == true and n2 == 0 and deinflect_calls == 0 and #fetched == 0,
    "unchanged window: manifests reused, nothing recomputed or refetched")

-- The pause lock itself survives pruning.
write_file(pre_dir .. "/" .. Precache.PAUSE_BASENAME)
Precache.runWorker(cfg)
check(exists(pre_dir .. "/" .. Precache.PAUSE_BASENAME),
    "the foreground pause lock is never pruned")

-- Bounded runs: the per-run fetch budget stops the worker early, leaves the
-- incomplete flag (which pruning must not eat), and a follow-up run picks up
-- where it left off and clears the flag.
os.execute("rm -rf '" .. root .. "/audio'")
os.execute("mkdir -p '" .. pre_dir .. "'")
fetched = {}
cfg.max_fetch = 2
local okb, nb, incb = Precache.runWorker(cfg)
check(okb == true and nb == 2 and incb == true,
    "fetch budget stops the run early and reports incomplete")
check(exists(pre_dir .. "/" .. Precache.INCOMPLETE_BASENAME),
    "an early-stopped run leaves the incomplete flag for the controller")
cfg.max_fetch = nil
fetched = {}
local okc, nc, incc = Precache.runWorker(cfg)
check(okc == true and nc == 6 and not incc,
    "the follow-up run fetches the remaining words: " .. tostring(nc))
check(not exists(pre_dir .. "/" .. Precache.INCOMPLETE_BASENAME),
    "a completed run clears the incomplete flag")

-- Abort: stop between pages/fetches.
local ok3, why = Precache.runWorker({
    pages = { page_a },
    opts = opts,
    audio_dir = audio_dir,
    precache_dir = pre_dir,
    max_scan = 20,
    deinflect = identity_deinflect,
    lookup = function() return {} end,
    fetch = function() error("must not fetch") end,
    fs = fs,
    abort = function() return true end,
    sleep = function() end,
})
check(ok3 == nil and why == "aborted", "abort stops the run before any fetch")

-- Fetch failure: give up with the word in the reason; the .tmp is removed.
os.execute("rm -rf '" .. pre_dir .. "'")
os.execute("mkdir -p '" .. pre_dir .. "'")
local ok4, why4 = Precache.runWorker({
    pages = { page_b },
    opts = opts,
    audio_dir = audio_dir,
    precache_dir = pre_dir,
    max_scan = 20,
    deinflect = identity_deinflect,
    lookup = function() return { ["東京"] = true } end,
    fetch = function() return nil, "connection refused" end,
    fs = fs,
    sleep = function() end,
    tmp_suffix = ".tmp43",
})
-- (東京 is still in the permanent audio cache from above, so the first word
-- actually fetched — and failing — is 京.)
check(ok4 == nil and why4:match("京") and why4:match("connection refused"),
    "fetch failure aborts the run with a useful reason: " .. tostring(why4))
check(exists(pre_dir .. "/" .. Precache.RETRY_BASENAME),
    "a failed run leaves the retry flag (the window is NOT done)")
local leftovers = fs.list(pre_dir)
local only_expected = true
for _, n in ipairs(leftovers) do
    if not (n:match("^want_") or n == Precache.RETRY_BASENAME) then only_expected = false end
end
check(#leftovers == 2 and only_expected,
    "failed fetch leaves no .tmp or .wav behind (manifest + retry flag only)")

-- A later successful run clears the retry flag again.
local ok5 = Precache.runWorker({
    pages = { page_b },
    opts = opts,
    audio_dir = audio_dir,
    precache_dir = pre_dir,
    max_scan = 20,
    deinflect = identity_deinflect,
    lookup = function() return { ["東京"] = true } end,
    fetch = function(_, text, out) write_file(out, "RIFF" .. text) return true end,
    fs = fs,
    sleep = function() end,
    tmp_suffix = ".tmp44",
})
check(ok5 == true and not exists(pre_dir .. "/" .. Precache.RETRY_BASENAME),
    "a clean run clears the retry flag")

os.execute("rm -rf '" .. root .. "'")

print(failures == 0 and "\nALL TESTS PASSED" or ("\n" .. failures .. " TEST(S) FAILED"))
os.exit(failures == 0 and 0 or 1)
