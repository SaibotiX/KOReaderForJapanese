--- Lexicon-free Japanese conjugation engine — pure-Lua port of engine.py.
--
-- This is a faithful 1:1 port of the Python reference (../../../../engine.py).
-- It is kept as a single module mirroring that single-file engine so the two
-- can be audited side by side; port fidelity against the Python engine is the
-- acceptance bar (see tools/run_test.lua).
--
-- Given a surface token it: classifies it (verb class / i-adjective / na-adj /
-- copula / passthrough) using an injected JMdict-derived POS table plus the
-- Yomichan deinflection ruleset; recovers the re-conjugable lemma (stripping
-- only *inflectional* endings, never the derivational causative/passive/
-- potential); and generates the full finite paradigm, each form labelled.
--
-- Dependencies are injected via configure(): a `rules` table (decoded
-- yomichan-deinflect.json) and a `posdict` object exposing
--   posdict:classes(surface) -> { class, ... }   (ordered coarse POS classes)
--   posdict:common(surface)  -> boolean           (JMdict priority/frequency)
-- so the module has no KOReader or SQLite dependency and runs under stock
-- luajit for the parity harness.
--
-- @module koplugin.japanese.conjugator

local jutf8 = require("jutf8")

local M = {}

-- Injected dependencies (see configure()).
local RULES = nil
local DICT = nil

--- Configure the engine with a decoded rules table and a posdict instance.
-- Must be called once before analyze/forms_for/conjugate_field.
function M.configure(rules, posdict)
    RULES = rules
    DICT = posdict
end

-- ---------------------------------------------------------------------------
-- Small helpers.
-- ---------------------------------------------------------------------------
local function contains(list, x)
    for _, v in ipairs(list) do
        if v == x then return true end
    end
    return false
end

--- True if `s` ends with any of the given suffixes.
local function ends_any(s, suffixes)
    for _, suf in ipairs(suffixes) do
        if suf ~= "" and s:sub(-#suf) == suf then return true end
    end
    return false
end

--- Lexicographic comparison of two numeric tuples (mirrors Python tuple <).
local function tuple_lt(a, b)
    local n = math.max(#a, #b)
    for i = 1, n do
        local x, y = a[i], b[i]
        if x ~= y then return (x or -math.huge) < (y or -math.huge) end
    end
    return false
end

-- Forward declarations for the interdependent function cluster.
local normalise_vz, classify_surface, choose_verb_pos, v5aru_polite_base
local deinflect, stem_copula, copula_rest, _analyze
local verb_forms, iadj_forms, copula_forms, derived_stems, v1_core
local masu_stem, i_past_neg, question_particle_forms
local self_label, original_label

-- ---------------------------------------------------------------------------
-- Forward-inflection primitive driven by the Yomichan rule set (base -> form).
-- ---------------------------------------------------------------------------
local function json_matches(base, pos, group)
    local rules = RULES[group] or {}
    local out = {}
    for idx, rule in ipairs(rules) do
        if contains(rule.rulesOut, pos) then
            local ko = rule.kanaOut
            local stem
            if ko == "" then
                stem = base
            elseif base:sub(-#ko) == ko then
                stem = base:sub(1, #base - #ko)
            end
            if stem ~= nil then
                out[#out + 1] = { form = stem .. rule.kanaIn, len = jutf8.len(ko), idx = idx }
            end
        end
    end
    table.sort(out, function(a, b)
        if a.len ~= b.len then return a.len > b.len end
        return a.idx < b.idx
    end)
    return out
end

local function jone(base, pos, group)
    local m = json_matches(base, pos, group)
    return m[1] and m[1].form or nil
end

local function jtop(base, pos, group)
    local m = json_matches(base, pos, group)
    if not m[1] then return {} end
    local best = m[1].len
    local seen, out = {}, {}
    for _, e in ipairs(m) do
        if e.len == best and not seen[e.form] then
            seen[e.form] = true
            out[#out + 1] = e.form
        end
    end
    return out
end

-- ---------------------------------------------------------------------------
-- Classification data.
-- ---------------------------------------------------------------------------
local PRODUCTIVE_V1_ENDINGS = { "させる", "られる", "せる", "れる", "える", "いる" }

local COPULA_EXACT = {}
for _, w in ipairs({
    "だ", "です", "だった", "でした",
    "じゃない", "ではない", "じゃないです", "ではないです",
    "じゃありません", "ではありません",
    "じゃなかった", "ではなかった", "じゃなかったです", "ではなかったです",
    "じゃありませんでした", "ではありませんでした",
}) do COPULA_EXACT[w] = true end

-- Longest first (matches the reference ordering).
local STRONG_COPULA_SUF = {
    "ではありませんでした", "じゃありませんでした",
    "ではなかったです", "じゃなかったです",
    "ではありません", "じゃありません",
    "ではないです", "じゃないです",
    "ではなかった", "じゃなかった",
    "でした", "だった", "ではない", "じゃない", "です",
}

-- Inflectional groups only (tense / politeness / negation / te / conditional);
-- derivational groups are deliberately absent so させられる survives.
local INFLECT_GROUPS = {
    "negative", "past", "-te", "-tara", "polite", "polite negative",
    "polite past", "polite past negative", "volitional", "polite volitional",
    "-ba", "-tari", "adv",
}

local V5ARU_SUFFIXES = { "っしゃる", "なさる", "くださる", "下さる", "ござる" }
local AUX_NA_STEMS = { "よう", "そう", "みたい" }
local V5ARU_POLITE_SUFFIXES = {
    "いませんでした", "いましょう", "いまして", "いました",
    "いません", "います", "い",
}

local _COPULA_REST = nil
copula_rest = function()
    if _COPULA_REST == nil then
        _COPULA_REST = {}
        for _, fl in ipairs(copula_forms("", "na", true, false, {})) do
            _COPULA_REST[fl[1]] = true
        end
    end
    return _COPULA_REST
end

v5aru_polite_base = function(token)
    for _, suf in ipairs(V5ARU_POLITE_SUFFIXES) do
        if token:sub(-#suf) == suf and jutf8.len(token) > jutf8.len(suf) then
            local base = token:sub(1, #token - #suf) .. "る"
            if ends_any(base, V5ARU_SUFFIXES) then return base end
        end
    end
    return nil
end

choose_verb_pos = function(classes, surface)
    if contains(classes, "vk") then return "vk" end
    if contains(classes, "vz") then return "vz" end
    if contains(classes, "vs") and (surface:sub(-#"する") == "する" or surface:sub(-#"ずる") == "ずる") then
        return "vs"
    end
    if surface:sub(-#"できる") == "できる" then return "v1" end
    local has1, has5 = contains(classes, "v1"), contains(classes, "v5")
    if has1 and has5 then
        if surface:sub(-#"える") == "える" or surface:sub(-#"いる") == "いる" then return "v1" end
        return "v5"
    end
    if has1 then return "v1" end
    if has5 then return "v5" end
    return nil
end

normalise_vz = function(base, pos)
    if pos == "vz" and base:sub(-#"ずる") == "ずる" then
        return jutf8.chop(base, 2) .. "じる", "v1"
    end
    return base, pos
end

classify_surface = function(surface, dict_only)
    local cls = DICT:classes(surface)
    if #cls > 0 then
        local conjugable = contains(cls, "v1") or contains(cls, "v5") or contains(cls, "vk")
            or contains(cls, "vs") or contains(cls, "vz") or contains(cls, "adj-i")
            or contains(cls, "adj-ix")
        if contains(cls, "prt") and not conjugable then
            return { kind = "passthrough", base = surface, dict = true, func = true }
        end
        local pos = choose_verb_pos(cls, surface)
        if pos then
            local base
            base, pos = normalise_vz(surface, pos)
            local a = { kind = "verb", base = base, pos = pos, dict = true }
            if pos == "v5" and ends_any(base, V5ARU_SUFFIXES) then a.aru_polite = true end
            return a
        end
        if contains(cls, "adj-ix") then
            return { kind = "iadj", base = surface, irregular = true, dict = true }
        end
        if contains(cls, "adj-i") then
            return { kind = "iadj", base = surface, irregular = false, dict = true }
        end
        if contains(cls, "na") then
            return { kind = "na", stem = surface, dict = true, allow_no = contains(cls, "adj-no") }
        end
        return { kind = "passthrough", base = surface, dict = true, func = contains(cls, "pn") }
    end

    if dict_only then return nil end

    if surface:sub(-#"する") == "する" and jutf8.len(surface) > 2 then
        return { kind = "verb", base = surface, pos = "vs", dict = false }
    end
    if (surface:sub(-#"くる") == "くる" or surface:sub(-#"来る") == "来る") and jutf8.len(surface) > 2 then
        return { kind = "verb", base = surface, pos = "vk", dict = false }
    end
    if ends_any(surface, PRODUCTIVE_V1_ENDINGS) then
        return { kind = "verb", base = surface, pos = "v1", dict = false }
    end
    return nil
end

deinflect = function(token, max_depth)
    max_depth = max_depth or 4
    local best = { [token] = { 0, 0 } }
    local order = { token }
    local frontier = { { token, 0, 0 } }
    while #frontier > 0 do
        local cur = table.remove(frontier)
        local term, d, fki = cur[1], cur[2], cur[3]
        if d < max_depth then
            for _, group in ipairs(INFLECT_GROUPS) do
                for _, rule in ipairs(RULES[group] or {}) do
                    local ki = rule.kanaIn
                    if ki ~= "" and term:sub(-#ki) == ki then
                        local lemma = term:sub(1, #term - #ki) .. rule.kanaOut
                        if lemma ~= "" then
                            local nf = (d == 0) and jutf8.len(ki) or fki
                            local cb = best[lemma]
                            if cb == nil or d + 1 < cb[1] or (d + 1 == cb[1] and nf > cb[2]) then
                                if cb == nil then order[#order + 1] = lemma end
                                best[lemma] = { d + 1, nf }
                                frontier[#frontier + 1] = { lemma, d + 1, nf }
                            end
                        end
                    end
                end
            end
        end
    end
    local out = {}
    for _, l in ipairs(order) do
        out[#out + 1] = { l, best[l][1], best[l][2] }
    end
    return out
end

stem_copula = function(stem)
    if stem == "" then return { kind = "copula", stem = "" } end
    local sc = classify_surface(stem, true)
    if sc and sc.kind == "iadj" then
        return { kind = "iadj", base = stem, irregular = sc.irregular or false }
    end
    if sc and sc.kind == "na" then
        return { kind = "na", stem = stem, allow_no = sc.allow_no or false }
    end
    return { kind = "na", stem = stem, noun = true }
end

_analyze = function(token)
    -- 0) a single kana is always a particle / ending fragment.
    if jutf8.len(token) <= 1 then return { kind = "passthrough", base = token } end

    -- 0.5) na-like auxiliaries (ようだ, そうだ, みたい) and their copula-inflected forms.
    for _, stem in ipairs(AUX_NA_STEMS) do
        if token == stem or (token:sub(1, #stem) == stem and copula_rest()[token:sub(#stem + 1)]) then
            return { kind = "na", stem = stem }
        end
    end

    -- 0.6) irregular v5aru honorific polite (なさいます -> なさる).
    local aru_base = v5aru_polite_base(token)
    if aru_base then
        return { kind = "verb", base = aru_base, pos = "v5", dict = true, aru_polite = true }
    end

    -- 1) the bare copula itself.
    if COPULA_EXACT[token] then return { kind = "copula", stem = "" } end

    -- 2) the token is already a conjugable verb — keep it, don't deinflect.
    local av = classify_surface(token, false)
    if av and av.kind == "verb" then return av end

    -- 2.5) a dictionary particle or pronoun — never deinflect into a homograph verb.
    if av and av.func then return av end

    -- 3) it inflectionally deinflects to a dictionary word.
    local cands = deinflect(token)
    local best = nil
    for _, cand in ipairs(cands) do
        local lemma, depth, fki = cand[1], cand[2], cand[3]
        if depth ~= 0 then
            local c = classify_surface(lemma, true)
            if c and (c.kind == "verb" or c.kind == "iadj") then
                local spec = jutf8.len(token) - jutf8.common_prefix_len(token, lemma)
                local score = {
                    DICT:common(lemma) and 0 or 1,
                    -fki,
                    -spec,
                    (c.kind == "verb") and 0 or 1,
                    -jutf8.len(lemma),
                    depth,
                }
                if best == nil or tuple_lt(score, best.score) then
                    best = { score = score, c = c }
                end
            end
        end
    end
    if best then return best.c end

    -- 4) the token is itself a dictionary adjective / na-adjective.
    if av and (av.kind == "iadj" or av.kind == "na") then return av end

    -- 5) a "<stem> + copula" fragment.
    for _, suf in ipairs(STRONG_COPULA_SUF) do
        if token:sub(-#suf) == suf then return stem_copula(token:sub(1, #token - #suf)) end
    end

    -- 6) a deeper morphological guess.
    local guess = nil
    for _, cand in ipairs(cands) do
        local lemma, depth, fki = cand[1], cand[2], cand[3]
        if depth ~= 0 then
            local c = classify_surface(lemma, false)
            if c and c.kind == "verb" then
                local key = { fki, depth }
                if guess == nil or tuple_lt(guess.key, key) then
                    guess = { key = key, c = c }
                end
            end
        end
    end
    if guess then return guess.c end

    -- 7) nothing conjugable — pass through unchanged.
    return { kind = "passthrough", base = token }
end

--- Classify a token and return an analysis table (always non-nil).
function M.analyze(token)
    local a = _analyze(token)
    a.input = token
    return a
end

-- Expose the surface classifier for the on-device popup (classify a deinflected
-- dictionary headword without re-running the full ladder).
function M.classify_surface(surface, dict_only)
    return classify_surface(surface, dict_only)
end

-- Expose the JMdict common/frequency flag for the popup's headword ranking.
function M.is_common(surface)
    return DICT ~= nil and DICT:common(surface) or false
end

-- ---------------------------------------------------------------------------
-- Paradigm builders.  Each returns a list of { form, label } pairs.
-- ---------------------------------------------------------------------------
v1_core = function(stem, prefix)
    if stem:sub(-#"る") ~= "る" then return {} end
    local s = jutf8.chop(stem, 1)
    return {
        { stem, prefix },
        { s .. "ない", prefix .. " negative" },
        { s .. "た", prefix .. " past" },
        { s .. "なかった", prefix .. " past negative" },
        { s .. "て", prefix .. " te-form" },
        { s .. "ます", prefix .. " polite" },
        { s .. "ません", prefix .. " polite negative" },
        { s .. "ました", prefix .. " polite past" },
        { s .. "ませんでした", prefix .. " polite past negative" },
        { s .. "れば", prefix .. " ba conditional" },
        { s .. "たら", prefix .. " tara conditional" },
    }
end

derived_stems = function(base, pos)
    local out = {}
    if base == "ある" then return out end
    if pos == "v5" then
        out[#out + 1] = { "potential", { jone(base, "v5", "potential") } }
        out[#out + 1] = { "passive", { jone(base, "v5", "passive") } }
        local caus = jone(base, "v5", "causative")
        out[#out + 1] = { "causative", { caus } }
        local cp = {}
        if caus then cp[#cp + 1] = jutf8.chop(caus, 1) .. "られる" end
        local short = jone(base, "v5", "causative passive")
        if short then cp[#cp + 1] = short end
        out[#out + 1] = { "causative-passive", cp }
    elseif pos == "v1" then
        local s = jutf8.chop(base, 1)
        out[#out + 1] = { "potential", { s .. "られる", s .. "れる" } }
        out[#out + 1] = { "passive", { s .. "られる" } }
        out[#out + 1] = { "causative", { s .. "させる" } }
        out[#out + 1] = { "causative-passive", { s .. "させられる" } }
    elseif pos == "vk" then
        local k = jutf8.chop(base, 1)
        if k:sub(-#"く") == "く" then k = jutf8.chop(k, 1) .. "こ" end
        out[#out + 1] = { "potential", { k .. "られる", k .. "れる" } }
        out[#out + 1] = { "passive", { k .. "られる" } }
        out[#out + 1] = { "causative", { k .. "させる" } }
        out[#out + 1] = { "causative-passive", { k .. "させられる" } }
    elseif pos == "vs" then
        local p = jutf8.chop(base, 2)
        out[#out + 1] = { "potential", { p .. "できる" } }
        out[#out + 1] = { "passive", { p .. "される" } }
        out[#out + 1] = { "causative", { p .. "させる" } }
        out[#out + 1] = { "causative-passive", { p .. "させられる" } }
    end
    return out
end

local DERIVED_LABELS = {
    potential = "Potential", passive = "Passive",
    causative = "Causative", ["causative-passive"] = "Causative-passive",
}

-- Sentence-ending / connective particles, mapped to an English role.
local PARTICLE_ROLE = {
    ["でしょうか"] = "polite question", ["でしょう"] = "conjecture", ["でしょ"] = "conjecture",
    ["かしら"] = "wondering", ["かな"] = "wondering", ["っけ"] = "recalling",
    ["よね"] = "confirmation", ["んで"] = "reason", ["ので"] = "reason", ["から"] = "reason",
    ["けれど"] = "contrast", ["けど"] = "contrast", ["もん"] = "explanatory",
    ["もの"] = "explanatory", ["の"] = "explanatory",
    ["か"] = "question", ["ね"] = "confirmation", ["よ"] = "emphasis", ["さ"] = "assertion",
    ["わ"] = "emphasis", ["ぞ"] = "emphasis", ["ぜ"] = "emphasis", ["し"] = "listing",
}
M.PARTICLE_ROLE = PARTICLE_ROLE

local PARTICLE_TAILS = {}
for k in pairs(PARTICLE_ROLE) do PARTICLE_TAILS[#PARTICLE_TAILS + 1] = k end
table.sort(PARTICLE_TAILS, function(a, b)
    local la, lb = jutf8.len(a), jutf8.len(b)
    if la ~= lb then return la > lb end
    return a < b
end)

question_particle_forms = function(core, questions, particles, extra)
    local out = {}
    if questions then
        for _, fl in ipairs(core) do
            if fl[1] and fl[1] ~= "" then out[#out + 1] = { fl[1] .. "か", fl[2] .. " question" } end
        end
        for _, fl in ipairs(extra or {}) do
            if fl[1] and fl[1] ~= "" then out[#out + 1] = { fl[1], fl[2] } end
        end
    end
    for _, p in ipairs(particles or {}) do
        local role = PARTICLE_ROLE[p] or p
        for _, fl in ipairs(core) do
            if fl[1] and fl[1] ~= "" then out[#out + 1] = { fl[1] .. p, fl[2] .. " " .. role } end
        end
    end
    return out
end

masu_stem = function(base, pos)
    if pos == "vs" then return jutf8.chop(base, 2) .. "し" end
    if base == "ある" then return "あり" end
    return jone(base, pos, "masu stem")
end

i_past_neg = function(neg_form)
    if neg_form and neg_form:sub(-#"い") == "い" then return jutf8.chop(neg_form, 1) .. "かった" end
    return neg_form
end

verb_forms = function(base, pos, lexical, aru_polite, questions, particles)
    if lexical == nil then lexical = true end
    local out = {}
    local aru = (base == "ある")
    local neg = aru and "ない" or jone(base, pos, "negative")
    local function add(form, label)
        if form and form ~= "" then out[#out + 1] = { form, label } end
    end

    local past = jone(base, pos, "past")
    add(base, "Non-past")
    add(neg, "Non-past negative")
    add(past, "Past")
    add(i_past_neg(neg), "Past negative")
    add(jone(base, pos, "-te"), "Te-form")
    add(jone(base, pos, "-tara"), "Tara conditional")
    add(jone(base, pos, "-ba"), "Ba conditional")
    add(jone(base, pos, "volitional"), "Volitional")
    add(base .. "と", "To conditional")
    add(base .. "なら", "Nara conditional")
    add(base .. "な", "Prohibitive")
    local masu = aru_polite and (jutf8.chop(base, 1) .. "い") or masu_stem(base, pos)
    add(masu, "Masu stem")

    local polite, polite_neg, polite_past, polite_past_neg
    if aru_polite then
        polite, polite_neg = masu .. "ます", masu .. "ません"
        polite_past, polite_past_neg = masu .. "ました", masu .. "ませんでした"
        add(masu, "Imperative")
        add(masu .. "ましょう", "Polite volitional")
        add(masu .. "まして", "Polite te-form")
    else
        for _, f in ipairs(jtop(base, pos, "imperative")) do add(f, "Imperative") end
        polite = jone(base, pos, "polite")
        polite_neg = jone(base, pos, "polite negative")
        polite_past = jone(base, pos, "polite past")
        polite_past_neg = jone(base, pos, "polite past negative")
        add(jone(base, pos, "polite volitional"), "Polite volitional")
        if masu then add(masu .. "まして", "Polite te-form") end
    end
    add(polite, "Polite")
    add(polite_neg, "Polite negative")
    add(polite_past, "Polite past")
    add(polite_past_neg, "Polite past negative")

    -- progressive ている / contracted てる
    local te = jone(base, pos, "-te")
    if te then
        local base_te = (te:sub(-#"て") == "て" or te:sub(-#"で") == "で") and jutf8.chop(te, 1) or te
        local tail = jutf8.last(te)
        add(te .. "いる", "Progressive")
        add(te .. "いた", "Progressive past")
        add(te .. "います", "Progressive polite")
        add(te .. "いました", "Progressive polite past")
        add(te .. "いない", "Progressive negative")
        add(base_te .. tail .. "る", "Contracted progressive")
    end

    -- honorific / humble (lexical regular verbs only)
    if lexical and masu and (pos == "v5" or pos == "v1") and not aru and not aru_polite then
        add("お" .. masu .. "になる", "Honorific")
        add("お" .. masu .. "になります", "Honorific polite")
        add("お" .. masu .. "する", "Humble")
        add("お" .. masu .. "します", "Humble polite")
        add("お" .. masu .. "いたす", "Courteous humble")
        add("お" .. masu .. "いたします", "Courteous humble polite")
    end

    -- derived stems, each with its own core forms
    if lexical and not aru and not aru_polite then
        for _, kf in ipairs(derived_stems(base, pos)) do
            local key, forms = kf[1], kf[2]
            for _, stem in ipairs(forms) do
                if stem and stem ~= "" then
                    for _, e in ipairs(v1_core(stem, DERIVED_LABELS[key])) do out[#out + 1] = e end
                end
            end
        end
    end

    -- question (か) and sentence-particle forms
    local core = {
        { base, "Non-past" }, { past, "Past" },
        { polite, "Polite" }, { polite_past, "Polite past" },
    }
    local extra = polite_neg and { { polite_neg .. "か", "Invitation" } } or {}
    for _, e in ipairs(question_particle_forms(core, questions, particles, extra)) do out[#out + 1] = e end

    return out
end

iadj_forms = function(base, irregular, questions, particles)
    if base:sub(-#"い") ~= "い" then return { { base, "Non-past" } } end
    local stem
    if irregular and base:sub(-#"いい") == "いい" then
        stem = jutf8.chop(base, 2) .. "よ"
    else
        stem = jutf8.chop(base, 1)
    end
    local sou = (irregular or base == "よい" or base == "ない") and "さそう" or "そう"
    local out = {
        { base, "Non-past" },
        { stem .. "くない", "Non-past negative" },
        { stem .. "かった", "Past" },
        { stem .. "くなかった", "Past negative" },
        { stem .. "くて", "Te-form" },
        { stem .. "く", "Adverbial" },
        { stem .. "ければ", "Ba conditional" },
        { stem .. "かったら", "Tara conditional" },
        { base .. "です", "Polite" },
        { stem .. "くないです", "Polite negative" },
        { stem .. "かったです", "Polite past" },
        { stem .. "くなかったです", "Polite past negative" },
        { stem .. "くありません", "Formal polite negative" },
        { stem .. "くありませんでした", "Formal polite past negative" },
        { base .. "と", "To conditional" },
        { base .. "なら", "Nara conditional" },
        { stem .. "さ", "Nominalisation" },
        { stem .. sou, "Appearance" },
        { stem .. "すぎる", "Excessive" },
    }
    if irregular then out[#out + 1] = { stem .. "い", "Alternative non-past" } end

    local core = {
        { base, "Non-past" }, { stem .. "かった", "Past" },
        { base .. "です", "Polite" }, { stem .. "かったです", "Polite past" },
    }
    for _, e in ipairs(question_particle_forms(core, questions, particles, {})) do out[#out + 1] = e end
    return out
end

copula_forms = function(stem, kind, allow_no, questions, particles)
    if kind == "copula" then stem = "" end
    local out = {}
    if kind == "na" and stem ~= "" then out[#out + 1] = { stem, "Non-past" } end
    local base_rows = {
        { "だ", "Plain non-past" }, { "です", "Polite" },
        { "だった", "Past" }, { "でした", "Polite past" },
        { "じゃない", "Non-past negative" }, { "ではない", "Formal non-past negative" },
        { "じゃないです", "Polite negative" }, { "ではないです", "Formal polite negative" },
        { "じゃありません", "Polite negative" }, { "ではありません", "Formal polite negative" },
        { "じゃなかった", "Past negative" }, { "ではなかった", "Formal past negative" },
        { "じゃなかったです", "Polite past negative" }, { "ではなかったです", "Formal polite past negative" },
        { "じゃありませんでした", "Polite past negative" }, { "ではありませんでした", "Formal polite past negative" },
        { "で", "Te-form" }, { "でして", "Polite te-form" },
        { "ならば", "Ba conditional" }, { "だったら", "Tara conditional" },
        { "だと", "To conditional" }, { "なら", "Nara conditional" },
        { "でいらっしゃいます", "Honorific" }, { "でございます", "Courteous" },
    }
    for _, r in ipairs(base_rows) do out[#out + 1] = { stem .. r[1], r[2] } end
    if kind == "na" then
        out[#out + 1] = { stem .. "な", "Attributive na" }
        out[#out + 1] = { stem .. "に", "Adverbial" }
        out[#out + 1] = { stem .. "さ", "Nominalisation" }
        out[#out + 1] = { stem .. "そう", "Appearance" }
        out[#out + 1] = { stem .. "すぎる", "Excessive" }
        if allow_no then out[#out + 1] = { stem .. "の", "Attributive no" } end
    elseif kind == "noun" then
        out[#out + 1] = { stem .. "の", "Attributive no" }
    end

    local core = {
        { stem, "Non-past" }, { stem .. "だった", "Past" },
        { stem .. "です", "Polite" }, { stem .. "でした", "Polite past" },
    }
    for _, e in ipairs(question_particle_forms(core, questions, particles, {})) do out[#out + 1] = e end
    return out
end

--- [(form, label)] generated for one analysis (empty for passthrough).
function M.forms_for(analysis, questions, particles)
    particles = particles or {}
    local k = analysis.kind
    if k == "verb" then
        local base, pos = analysis.base, analysis.pos
        local lexical = not (pos == "v1" and not analysis.dict)
        return verb_forms(base, pos, lexical, analysis.aru_polite or false, questions, particles)
    elseif k == "iadj" then
        return iadj_forms(analysis.base, analysis.irregular or false, questions, particles)
    elseif k == "na" then
        return copula_forms(analysis.stem, analysis.noun and "noun" or "na",
            analysis.allow_no or false, questions, particles)
    elseif k == "copula" then
        return copula_forms(analysis.stem or "", "copula", false, questions, particles)
    end
    return {}
end

-- ---------------------------------------------------------------------------
-- Field-level entry point.
-- ---------------------------------------------------------------------------
-- Conjugation-ending teaching fragments that are also valid inflections of some
-- real word: kept verbatim (not expanded) but still labelled.
local DEFAULT_STOPLIST = {
    ["ます"] = "Polite", ["ません"] = "Polite negative", ["ました"] = "Polite past",
    ["ませんでした"] = "Polite past negative", ["まして"] = "Polite te-form",
    ["ましょう"] = "Polite volitional",
    ["ないです"] = "Polite negative", ["かったです"] = "Polite past",
    ["なかったです"] = "Polite past negative",
    ["たり"] = "Representative listing", ["だり"] = "Representative listing",
    ["だったり"] = "Representative listing", ["かったり"] = "Representative listing",
    ["ぼう"] = "Volitional", ["ろう"] = "Volitional", ["とう"] = "Volitional",
    ["のう"] = "Volitional", ["ごう"] = "Volitional", ["おう"] = "Volitional",
    ["だろう"] = "Conjecture", ["でしょう"] = "Polite conjecture",
    ["であろう"] = "Formal conjecture", ["かろう"] = "Conjecture",
    ["かった"] = "Past",
    ["によって"] = "By means of", ["ないで"] = "Without doing",
    ["だったら"] = "Conditional", ["かったら"] = "Conditional",
    ["んだ"] = "Explanatory", ["んだら"] = "Conditional",
    ["なよう"] = "Like", ["のよう"] = "Like", ["しかない"] = "Only",
    ["になった"] = "Became", ["である"] = "Copula (formal)",
}
M.DEFAULT_STOPLIST = DEFAULT_STOPLIST

local TOKEN_PATTERN = "「(.-)」"

function M.parse_tokens(text)
    local out = {}
    for m in text:gmatch(TOKEN_PATTERN) do out[#out + 1] = m end
    return out
end

self_label = function(form)
    local a = M.analyze(form)
    if a.kind == "passthrough" then return nil end
    for _, fl in ipairs(M.forms_for(a, false, {})) do
        if fl[1] == form then return fl[2] end
    end
    return nil
end

original_label = function(token, label_of)
    if label_of[token] then return label_of[token] end
    if DEFAULT_STOPLIST[token] then return DEFAULT_STOPLIST[token] end
    local lab = self_label(token)
    if lab then return lab end
    for _, p in ipairs(PARTICLE_TAILS) do
        if token:sub(-#p) == p and jutf8.len(token) > jutf8.len(p) then
            local core = token:sub(1, #token - #p)
            local core_lab = label_of[core] or self_label(core)
            if core_lab then return core_lab .. " " .. PARTICLE_ROLE[p] end
        end
    end
    return nil
end

--- Return the deduped 「form (label)」 string: original tokens first, then the
-- remaining generated forms.  Mirrors engine.conjugate_field.
function M.conjugate_field(text, stoplist, questions, particles)
    if questions == nil then questions = true end
    particles = particles or {}
    local stop = {}
    for k in pairs(DEFAULT_STOPLIST) do stop[k] = true end
    for _, k in ipairs(stoplist or {}) do stop[k] = true end
    local tokens = M.parse_tokens(text)

    local label_of, gen_order = {}, {}
    for _, tok in ipairs(tokens) do
        if not stop[tok] then
            for _, fl in ipairs(M.forms_for(M.analyze(tok), questions, particles)) do
                local form, label = fl[1], fl[2]
                if form and form ~= "" and label_of[form] == nil then
                    label_of[form] = label
                    gen_order[#gen_order + 1] = form
                end
            end
        end
    end

    local out, seen = {}, {}
    for _, tok in ipairs(tokens) do
        if not seen[tok] then
            seen[tok] = true
            local label = original_label(tok, label_of)
            out[#out + 1] = label and (tok .. " (" .. label .. ")") or tok
        end
    end
    for _, form in ipairs(gen_order) do
        if not seen[form] then
            seen[form] = true
            local label = label_of[form]
            out[#out + 1] = label and (form .. " (" .. label .. ")") or form
        end
    end

    local parts = {}
    for _, x in ipairs(out) do parts[#parts + 1] = "「" .. x .. "」" end
    return table.concat(parts)
end

return M
