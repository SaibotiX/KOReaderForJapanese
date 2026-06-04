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
function Analysis.strip_html(s)
    if not s or s == "" then return "" end
    s = s:gsub("<%s*[bB][rR]%s*/?>", "\n")
    s = s:gsub("<[^>]+>", "")
    s = s:gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"')
        :gsub("&#39;", "'"):gsub("&apos;", "'"):gsub("&amp;", "&")
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
