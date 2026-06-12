--- On-device analysis presenter for a tapped Japanese word.
--
-- Bridges the two engines this plugin already has:
--  * the Yomichan Deinflector (surface -> dictionary headword + the ordered
--    inflection reason path, e.g. {causative, passive, polite past}); and
--  * the ported conjugator (POS classification of the headword and the full
--    labelled paradigm table).
--
-- analyse() returns a plain table; building the KeyValuePage rows (to_kv_pairs)
-- is also pure data, so all KOReader widget/IO work stays in main.lua.
--
-- @module koplugin.japanese.analysis

local Conjugator = require("conjugator")
local _ = require("gettext")

local Analysis = {}

-- Plain-English word-type labels (translatable).
local function pos_label(a)
    local k = a.kind
    if k == "verb" then
        local by_pos = {
            v5 = _("godan verb (u-verb)"),
            v1 = _("ichidan verb (ru-verb)"),
            vs = _("suru verb (する)"),
            vk = _("kuru verb (来る, irregular)"),
            vz = _("zuru verb (ずる)"),
        }
        local label = by_pos[a.pos] or _("verb")
        if a.aru_polite then label = label .. _(" (honorific)") end
        return label
    elseif k == "iadj" then
        return a.irregular and _("i-adjective (irregular いい→よい)") or _("i-adjective")
    elseif k == "na" then
        return a.noun and _("noun + copula") or _("na-adjective")
    elseif k == "copula" then
        return _("copula (だ/です)")
    else
        return a.func and _("particle / pronoun (non-conjugating)")
            or _("noun / non-conjugating")
    end
end

-- The dictionary (base) form to display for an analysis.
local function base_of(a)
    if a.kind == "verb" or a.kind == "iadj" then return a.base end
    if a.kind == "na" then return a.stem end
    if a.kind == "copula" then return "だ" end
    return a.base or ""
end

-- Rank a deinflector candidate that is a real dictionary word.  Lower is better:
-- common word first, then the deepest reduction (most reasons = closest to the
-- true dictionary form), then verb > i-adj > na > noun, then the longer term.
local KIND_RANK = { verb = 0, iadj = 1, na = 2, copula = 3, passthrough = 4 }
local function candidate_score(term, cs, reasons)
    return {
        Conjugator.is_common(term) and 0 or 1,
        -#reasons,
        KIND_RANK[cs.kind] or 9,
        -require("jutf8").len(term),
    }
end

local function tuple_lt(a, b)
    for i = 1, math.max(#a, #b) do
        if a[i] ~= b[i] then return (a[i] or -math.huge) < (b[i] or -math.huge) end
    end
    return false
end

-- Find the best dictionary headword among the deinflector's candidates.
-- Returns term, classification(analysis), reasons — or nil if none is a real
-- dictionary word.
local function pick_headword(deinflect_results)
    local best
    for _, r in ipairs(deinflect_results) do
        local cs = Conjugator.classify_surface(r.term, true)
        if cs ~= nil then
            local score = candidate_score(r.term, cs, r.reasons or {})
            if best == nil or tuple_lt(score, best.score) then
                best = { term = r.term, cs = cs, reasons = r.reasons or {}, score = score }
            end
        end
    end
    return best
end

-- The conjugation label of `surface` relative to `analysis`, found by scanning
-- the generated paradigm (used when the deinflector gives no reason path, e.g.
-- copula fragments recovered by the conjugator ladder).
local function label_in_paradigm(surface, analysis)
    for _, fl in ipairs(Conjugator.forms_for(analysis, false, {})) do
        if fl[1] == surface then return fl[2] end
    end
    return nil
end

--- Analyse a tapped surface form.
-- @tparam string surface the tapped/selected text
-- @param deinflector a Deinflector instance (or nil to use the ladder only)
-- @treturn table { surface, base, pos_label, conjugation, analysis, is_conjugating }
function Analysis.analyse(surface, deinflector)
    local headword
    if deinflector then
        local results = deinflector:deinflect(surface)
        headword = pick_headword(results)
    end

    local analysis, base, reasons
    if headword then
        analysis = headword.cs
        base = headword.term
        reasons = headword.reasons
    else
        analysis = Conjugator.analyze(surface)
        base = base_of(analysis)
        reasons = {}
    end

    -- Conjugation description: the deinflector reason path if any, else the
    -- paradigm label of the surface, else "dictionary form".
    local conjugation
    if #reasons > 0 then
        conjugation = table.concat(reasons, " · ")
    else
        conjugation = label_in_paradigm(surface, analysis)
            or (surface == base and _("dictionary form") or _("—"))
    end

    return {
        surface = surface,
        base = base,
        pos_label = pos_label(analysis),
        conjugation = conjugation,
        analysis = analysis,
        is_conjugating = (analysis.kind ~= "passthrough"),
    }
end

--- Reduce a StarDict/sdcv definition to readable plain text for a TextViewer
-- (strip tags, turn <br> into newlines, decode the common entities).
-- Encode a Unicode codepoint as UTF-8 (for numeric character references;
-- stock LuaJIT has no utf8.char).
local function utf8_char(cp)
    if not cp or cp >= 0x110000 then return "" end
    if cp < 0x80 then
        return string.char(cp)
    elseif cp < 0x800 then
        return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40)
    elseif cp < 0x10000 then
        return string.char(0xE0 + math.floor(cp / 0x1000),
            0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
    end
    return string.char(0xF0 + math.floor(cp / 0x40000),
        0x80 + math.floor(cp / 0x1000) % 0x40,
        0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
end

-- Common named entities seen in StarDict definitions. &nbsp; becomes a plain
-- space (runs of them are how many dictionaries indent, and we don't collapse
-- horizontal whitespace below, so indentation survives). Decoded in a single
-- gsub pass, so "&amp;lt;" correctly yields "&lt;" without double-decoding.
local NAMED_ENTITIES = {
    nbsp = " ", amp = "&", lt = "<", gt = ">", quot = '"', apos = "'",
    hellip = "…", mdash = "—", ndash = "–", middot = "·", bull = "•",
    lsquo = "‘", rsquo = "’", ldquo = "“", rdquo = "”", deg = "°", copy = "©",
}

-- Tags whose boundaries break the text flow: stripping them must leave a
-- newline behind, or structured (HTML-type) dictionary entries collapse into
-- one solid blob.
local BLOCK_TAGS = {
    p = true, div = true, ul = true, ol = true, dl = true, dt = true, dd = true,
    table = true, tr = true, blockquote = true, pre = true, section = true,
    article = true, header = true, footer = true,
    h1 = true, h2 = true, h3 = true, h4 = true, h5 = true, h6 = true,
}

--- Convert a dictionary definition (plain text or StarDict "h"-type HTML) to
-- readable plain text: block tags become line breaks, list items bullets,
-- ruby readings parentheses; entities (named and numeric) are decoded in
-- either case. HTML entries are rendered compactly (no blank lines: adjacent
-- block boundaries fold into one break); plain-text entries pass through with
-- their own line structure intact.
function Analysis.strip_html(s)
    if not s or s == "" then return "" end
    s = s:gsub("\r\n?", "\n")
    local is_html = s:find("<%s*/?%s*%a[^>]*>") ~= nil
    if is_html then
        -- Drop comments and invisible style/script blocks wholesale.
        s = s:gsub("<!%-%-.-%-%->", "")
        s = s:gsub("<%s*[sS][tT][yY][lL][eE][^>]*>.-<%s*/%s*[sS][tT][yY][lL][eE]%s*>", "")
        s = s:gsub("<%s*[sS][cC][rR][iI][pP][tT][^>]*>.-<%s*/%s*[sS][cC][rR][iI][pP][tT]%s*>", "")
        -- Ruby annotations: keep the reading, parenthesized after its base;
        -- drop <rp> fallback parentheses (they would double up).
        s = s:gsub("<%s*[rR][pP][^>]*>.-<%s*/%s*[rR][pP]%s*>", "")
        s = s:gsub("<%s*[rR][tT][^>]*>(.-)<%s*/%s*[rR][tT]%s*>", "（%1）")
        -- All remaining tags in one pass: structural ones leave breaks or
        -- bullets behind, inline ones vanish.
        s = s:gsub("<%s*(/?)%s*([%a][%w]*)[^>]*>", function(slash, name)
            local n = name:lower()
            if n == "br" or n == "hr" then return "\n" end
            if n == "li" then return slash == "/" and "" or "\n• " end
            if BLOCK_TAGS[n] then return "\n" end
            return ""
        end)
    end
    -- Entities: numeric first, then named (&amp; among them; single pass, so
    -- its output is never re-decoded). Plain-text dictionaries carry these too.
    s = s:gsub("&#[xX](%x+);", function(h) return utf8_char(tonumber(h, 16)) end)
    s = s:gsub("&#(%d+);", function(d) return utf8_char(tonumber(d)) end)
    s = s:gsub("&(%a+);", NAMED_ENTITIES)
    -- Tidy whitespace. Horizontal runs are kept (indentation), trailing
    -- spaces before a break are not.
    s = s:gsub("[ \t]+\n", "\n")
    if is_html then
        -- Fold newline runs (e.g. from </div><div>) into single line breaks:
        -- senses read best single-spaced in the popup.
        local prev
        repeat
            prev = s
            s = s:gsub("\n[ \t]*\n", "\n")
        until s == prev
    else
        -- Plain text: keep deliberate blank lines, just cap them at one.
        s = s:gsub("\n\n\n+", "\n\n")
    end
    s = s:gsub("^%s+", ""):gsub("%s+$", "")
    return s
end

-- A thin divider between the header fields and the page's section.
local SEP = "\n────────────────────\n"

-- Stable page ids for the non-dictionary pages (dictionary pages use their
-- dictionary name as the id), used by the user-configurable page order.
Analysis.AI_ID = "::ai"
Analysis.TRANSLATE_ID = "::translate"

-- Reorder pages in place by `order` (a list of page ids); pages whose id is not
-- listed keep their default relative position, after the listed ones.
local function sort_pages(pages, order)
    local rank = {}
    for i, id in ipairs(order) do rank[id] = i end
    local big = #order + 1
    for i, p in ipairs(pages) do p._i = i end
    table.sort(pages, function(a, b)
        local ra, rb = rank[a.id] or big, rank[b.id] or big
        if ra ~= rb then return ra < rb end
        return a._i < b._i -- stable for ties / unlisted
    end)
    for _, p in ipairs(pages) do p._i = nil end
end

--- Build the navigable pages for one analysis: each matching dictionary (id =
-- dictionary name), then (when present) a Google Translate page and an AI page —
-- so those results are their own entries rather than repeated under every
-- dictionary.  Each page is { id, title, body }.  When `order` (a list of page
-- ids) is given the pages are arranged accordingly.  Pure data → unit-tested.
function Analysis.build_pages(result, defs, order)
    local pages = {}
    for _, entry in ipairs(defs) do
        local name = (entry.dict and entry.dict ~= "") and entry.dict or _("Dictionary")
        pages[#pages + 1] = { id = entry.dict or "", title = name, body = entry.definition or "" }
    end
    if #defs == 0 then
        pages[#pages + 1] = { id = "", title = _("Dictionary"),
            body = _("(no dictionary entry found for the dictionary form)") }
    end
    if result.translate and result.translate ~= "" then
        pages[#pages + 1] = { id = Analysis.TRANSLATE_ID, title = _("Google Translate"),
            body = result.translate }
    end
    if result.ai and result.ai ~= "" then
        pages[#pages + 1] = { id = Analysis.AI_ID, title = _("AI analysis"), body = result.ai }
    end
    if order and #order > 0 then sort_pages(pages, order) end
    return pages
end

--- The TextViewer body for one page: the fixed header fields (Word, Dictionary
-- form, Type, Conjugation) then this page's section (with its position), divided
-- by separators.
-- @tparam table result an analyse() result
-- @tparam table page a { id, title, body } page from build_pages
-- @tparam int idx 1-based position of this page
-- @tparam int total number of pages
function Analysis.window_text(result, page, idx, total)
    local heading = page.title
    if total and total > 1 then heading = heading .. " (" .. idx .. "/" .. total .. ")" end
    return table.concat({
        _("Word") .. ": " .. (result.surface_display or result.surface),
        _("Dictionary form") .. ": " .. (result.base_display or result.base),
        _("Type") .. ": " .. result.pos_label,
        _("Conjugation") .. ": " .. result.conjugation,
        heading .. ":\n" .. page.body,
    }, SEP)
end

--- Build a "word (reading)" label from the furigana plugin's ruby HTML
-- (e.g. `<ruby>食<rt>た</rt></ruby>べる`), extracting the kana reading.  Returns
-- the word unchanged when there is no reading (no kanji) or it equals the word.
-- Pure → unit-tested.
function Analysis.furigana_label(word, ruby_html)
    if type(ruby_html) ~= "string" or ruby_html == "" then return word end
    local reading = ruby_html:gsub("<ruby>.-<rt>(.-)</rt></ruby>", "%1"):gsub("<[^>]+>", "")
    reading = reading:gsub("%s+", "")
    if reading ~= "" and reading ~= word then
        return word .. " (" .. reading .. ")"
    end
    return word
end

return Analysis
