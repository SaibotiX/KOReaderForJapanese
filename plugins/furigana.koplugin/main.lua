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
    self:redirectFileBrowserToOriginal()
    self:maybeAutoOpenAnnotated()
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
    for _, row in ipairs(rows) do
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
    for f in lfs.dir(self.cache_dir) do
        if f ~= "." and f ~= ".." then
            local p = self.cache_dir .. "/" .. f
            if lfs.attributes(p, "mode") == "file" and not keep[p] then
                files[#files + 1] = p
                total = total + (lfs.attributes(p, "size") or 0)
            end
        end
    end

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
                help_text = _("Delete cached annotated copies to free storage. The book you are currently reading with furigana is kept; everything else is removed and regenerated on demand."),
            },
        },
    }
end

return Furigana
