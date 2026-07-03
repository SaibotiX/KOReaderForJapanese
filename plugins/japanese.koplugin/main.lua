--- Japanese language support for KOReader, modelled after Yomichan.
-- This plugin extends KOReader's built-in dictionary and selection system to
-- support Yomichan-style deinflection and text scanning, allowing for one-tap
-- searches of inflected verbs and multi-character words and phrases. As such,
-- this plugin removes the need for synonym-based deinflection rules for
-- StarDict-converted Japanese dictionaries.
--
-- @module koplugin.japanese
-- @alias Japanese

-- Copyright (C) 2021 Aleksa Sarai <cyphar@cyphar.com>
-- Licensed under the GPLv3 or later.
--
-- The deinflection logic is heavily modelled after Yomichan
-- <https://github.com/FooSoft/yomichan>, up to and including the deinflection
-- table. The way we try to find candidate words is also fairly similar (the
-- naive approach), though because dictionary lookups are quite expensive (we
-- have to call sdcv each time) we batch as many candidates as possible
-- together in order to reduce the impact we have on text selection.

local Analysis = require("analysis")
local Conjugator = require("conjugator")
local Deinflector = require("deinflector")
local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local AnalysisViewer = require("analysisviewer")
local LLM = require("llm")
local LanguageSupport = require("languagesupport")
local PosDict = require("posdict")
local ReaderDictionary = require("apps/reader/modules/readerdictionary")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local json_min = require("json_min")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")
local N_ = _.ngettext
local T = require("ffi/util").template

local SingleInstanceDeinflector = Deinflector:new {}

-- The conjugator's rules + POS database are shared process-wide and loaded once.
local conjugator_configured = false

local Japanese = WidgetContainer:extend {
    name = "japanese",
    pretty_name = "Japanese",
}

-- Yomichan uses 10 characters as the default look-ahead, but crengine's
-- getNextVisibleChar counts furigana if any are present, so use a higher
-- threshold to be able to look-ahead an equivalent number of characters.
local DEFAULT_TEXT_SCAN_LENGTH = 20

function Japanese:init()
    self.deinflector = SingleInstanceDeinflector
    self.dictionary = (self.ui and self.ui.dictionary) or ReaderDictionary:new()
    self.max_scan_length = G_reader_settings:readSetting("language_japanese_text_scan_length") or
    DEFAULT_TEXT_SCAN_LENGTH
    LanguageSupport:registerPlugin(self)
    -- Single tap on a word opens the analysis (default on; see onTapAnalyse).
    self.tap_to_analyse = G_reader_settings:nilOrTrue("language_japanese_tap_to_analyse")
    if self.ui and self.ui.dictionary and self.ui.dictionary.addToDictButtons then
        self:registerDictButton()
    end
    self:registerSentenceStartButton()
end

function Japanese:supportsLanguage(language_code)
    return language_code == "ja" or language_code == "jpn"
end

--- Called from @{languagesupport.extraDictionaryFormCandidates} for Japanese
-- text. Tries to find and return any possible deinflections for the given text.
-- @param args arguments from language support
-- @treturn {string,...} extra dictionary form candiadates found (or nil)
-- @see languagesupport.extraDictionaryFormCandidates
-- @see languagesupport.registerPlugin
function Japanese:onWordLookup(args)
    local text = args.text

    -- If there are no CJK characters in the text, there's nothing to do.
    if not util.hasCJKChar(text) then
        return
    end

    --- @todo Try to repeatedly reduce the text and deinflect the shortened text
    --       to provide more candidates. This is particularly needed because
    --       JMDict has a habit of creating entries for compounds or phrases
    --       that do not exist in monolingual dictionaries (even in 大辞林 or
    --       広辞苑) and our onWordSelection expansion accepts any dictionary's
    --       largest entry. Unfortunately doing this nicely requires a bit of
    --       extra work to be efficient (since we need to remove the last
    --       character in the string).

    local results = self.deinflector:deinflect(text)
    logger.dbg("japanese.koplugin: deinflection of", text, "results:", results)

    --- @todo Pass up the reasons list (formatted Yomichan style) to the
    --       dictionary pop-up so you can get some more information about the
    --       inflection. But this would require adding some kind of tag
    --       metadata that we have to pass through from the lookup to the
    --       dictionary pop-up.

    local candidates = {}
    for i, result in ipairs(results) do
        candidates[i] = result.term
    end
    return candidates
end

-- @todo Switch this to utf8proc_category or something similar.
local JAPANESE_PUNCTUATION = "「」『』【】〘〙〖〗・･、､,。｡.！!？?　 \n"

local function isPossibleJapaneseWord(str)
    for c in str:gmatch(util.UTF8_CHAR_PATTERN) do
        if not util.isCJKChar(c) or JAPANESE_PUNCTUATION:find(c) ~= nil then
            return false
        end
    end
    return true
end

--- Called from @{languagesupport.improveWordSelection} for Japanese text.
-- Tries to expand the word selection defined by args.
-- @param args arguments from language support
-- @treturn {pos0,pos1} the new selection range (or nil)
-- @see languagesupport.improveWordSelection
-- @see languagesupport.registerPlugin
function Japanese:onWordSelection(args)
    local callbacks = args.callbacks
    local current_text = args.text

    -- If the initial selection contains only non-CJK characters, then there's
    -- no point trying to expand it because no Japanese words mix CJK and
    -- non-CJK characters (there are non-CJK words in Japanese -- CM, NG, TKG
    -- and their full-width equivalents for instance -- but they are selected
    -- by crengine correctly already and are full words by themselves).
    if current_text ~= "" and not util.hasCJKChar(current_text) then
        return
    end

    -- We reset the end of the range to pos0+1 because crengine will select
    -- half-width katakana (ｶﾀｶﾅ) in strange ways that often overshoots the
    -- end of words.
    local pos0, pos1 = args.pos0, callbacks.get_next_char_pos(args.pos0)

    -- We try to advance the end position until we hit a word.
    --
    -- Unfortunately it's possible for the complete word to be longer than the
    -- first match (obvious examples include 読み込む or similar compound verbs
    -- where it would be less than ideal to match 読み as the full word, but
    -- there are more subtle kana-only cases as well) so we need to keep
    -- looking forward, but unfortunately there isn't a great endpoint defined
    -- either (aside from punctuation). So we just copy Yomichan and set a hard
    -- limit (20 characters) and stop early if we ever hit punctuation. We then
    -- select the longest word present in one of the user's installed
    -- dictionaries (after deinflection).

    local all_candidates = {}
    local all_words = {}

    local current_end = pos1
    local num_expansions = 0
    repeat
        -- Move to the next character.
        current_end = callbacks.get_next_char_pos(current_end)
        current_text = callbacks.get_text_in_range(pos0, current_end)
        num_expansions = num_expansions + 1

        -- If the text could not be a complete Japanese word (i.e. it contains
        -- a punctuation or some other special character), quit early. We test
        -- the whole string rather than the last character because finding the
        -- last character requires a linear walk through the string anyway, and
        -- get_next_char_pos() skips over newlines.
        if not isPossibleJapaneseWord(current_text) then
            logger.dbg("japanese.koplugin: stopping expansion at", current_text,
                "because in contains non-word characters")
            break
        end

        -- Get the selection and try to deinflect it.
        local candidates = self.deinflector:deinflect(current_text)
        local terms = {}
        for _, candidate in ipairs(candidates) do
            table.insert(terms, candidate.term)
        end

        -- Add the candidates to the set of words to attempt.
        for _, term in ipairs(terms) do
            table.insert(all_candidates, {
                pos0 = pos0,
                pos1 = current_end,
                text = term,
            })
            table.insert(all_words, term)
        end
    until current_end == nil or num_expansions >= self.max_scan_length
    logger.dbg("japanese.koplugin: attempted", num_expansions, "expansions up to", current_text)

    -- Calling sdcv is fairly expensive, so reduce the cost by trying every
    -- candidate in one shot and then picking the longest one which gave us a
    -- result.
    --- @todo Given there is a limit to how many command-line arguments you can
    --       pass, we should split up the candidate list if it's too long.
    local best_word
    local cancelled, all_results = self.dictionary:rawSdcv(all_words)
    if not cancelled and all_results ~= nil then
        for i, term_results in ipairs(all_results) do
            if #term_results ~= 0 then
                best_word = all_candidates[i]
            end
        end
    end
    if best_word ~= nil then
        return { best_word.pos0, best_word.pos1 }
    end
end

--- Lazily load the conjugation engine (Yomichan rules + POS SQLite) on first
-- use, so opening a book is not slowed by parsing the rules and opening the
-- ~34 MB database.  Returns whether the engine is ready.
function Japanese:ensureEngine()
    if conjugator_configured then return true end
    local ok, err = pcall(function()
        local rules = json_min.load_file(self.path .. "/yomichan-deinflect.json")
        local posdict = PosDict.new(self.path .. "/jmdict_pos.sqlite")
        Conjugator.configure(rules, posdict)
    end)
    if not ok then
        logger.err("japanese.koplugin: conjugator init failed:", err)
        return false
    end
    conjugator_configured = true
    return true
end

--- The furigana plugin's tokenizer (lazy, cached), set to annotate every kanji
-- so we get a full reading.  nil when the furigana plugin is unavailable.
-- Prefers the furigana plugin's own cached instance (also used by its
-- tap-reveal popups), so the ~35 MB dictionary is loaded only once.
function Japanese:getFuriganaTokenizer()
    if self._furigana_tried then return self._furigana_tok end
    self._furigana_tried = true
    local furigana = self.ui and self.ui.furigana
    if furigana and (furigana.getCachedTokenizer or furigana.getTokenizer) then
        local ok, tok = pcall(function()
            local t
            if furigana.getCachedTokenizer then
                t = furigana:getCachedTokenizer() -- already min_grade 1
            else
                t = furigana:getTokenizer()
            end
            if t.setMinGrade then t:setMinGrade(1) end -- annotate all kanji
            return t
        end)
        if ok then self._furigana_tok = tok end
    end
    return self._furigana_tok
end

--- Annotate a word as "word (reading)" via the furigana plugin, when enabled and
-- available; otherwise return the word unchanged.
function Japanese:furiganaAnnotate(word)
    if not word or word == "" then return word end
    if not G_reader_settings:nilOrTrue("language_japanese_furigana") then return word end
    if not util.hasCJKChar(word) then return word end
    local tok = self:getFuriganaTokenizer()
    if not tok then return word end
    local ok, ruby = pcall(function() return tok:annotate(word) end)
    if not ok or type(ruby) ~= "string" then return word end
    return Analysis.furigana_label(word, ruby)
end

--- Look up English definitions for the dictionary form across the user's
-- installed dictionaries (sdcv).  Returns a list of { dict, definition }.
function Japanese:lookupDefinitions(base)
    local defs = {}
    if not (base and base ~= "" and self.dictionary and self.dictionary.rawSdcv) then
        return defs
    end
    local ok, cancelled, all_results = pcall(self.dictionary.rawSdcv, self.dictionary, { base })
    if not ok or cancelled or type(all_results) ~= "table" then
        return defs
    end
    local entries = all_results[1]
    if type(entries) ~= "table" then return defs end
    for _, e in ipairs(entries) do
        if type(e) == "table" and not e.no_result and e.definition then
            defs[#defs + 1] = { dict = e.dict or "", definition = Analysis.strip_html(e.definition) }
        end
    end
    self:recordKnownDicts(defs)
    return defs
end

--- Remember dictionary names seen in lookups so they can be ordered in the
-- page-order config even before re-querying.
function Japanese:recordKnownDicts(defs)
    local known = G_reader_settings:readSetting("language_japanese_known_dicts") or {}
    local seen = {}
    for _, n in ipairs(known) do seen[n] = true end
    local changed = false
    for _, e in ipairs(defs) do
        if e.dict and e.dict ~= "" and not seen[e.dict] then
            known[#known + 1] = e.dict
            seen[e.dict] = true
            changed = true
        end
    end
    if changed then G_reader_settings:saveSetting("language_japanese_known_dicts", known) end
end

--- The on-device reorder UI (SortWidget) for the analysis page order: AI, Google
-- Translate, and each known dictionary, moved up/down and saved.
function Japanese:showPageOrderConfig()
    local SortWidget = require("ui/widget/sortwidget")
    local labels = {
        [Analysis.AI_ID] = _("AI analysis"),
        [Analysis.TRANSLATE_ID] = _("Google Translate"),
    }
    local items, seen = {}, {}
    local function add(id)
        if id == nil or id == "" or seen[id] then return end
        seen[id] = true
        items[#items + 1] = { text = labels[id] or id, id = id }
    end
    -- Saved order first (preserved), then AI / Translate, then known dictionaries.
    for _, id in ipairs(G_reader_settings:readSetting("language_japanese_page_order") or {}) do add(id) end
    add(Analysis.AI_ID)
    add(Analysis.TRANSLATE_ID)
    for _, n in ipairs(G_reader_settings:readSetting("language_japanese_known_dicts") or {}) do add(n) end
    if self.ui and self.ui.dictionary and type(self.ui.dictionary.enabled_dict_names) == "table" then
        for _, n in ipairs(self.ui.dictionary.enabled_dict_names) do add(n) end
    end
    UIManager:show(SortWidget:new {
        title = _("Analysis page order"),
        item_table = items,
        callback = function()
            local order = {}
            for _, it in ipairs(items) do order[#order + 1] = it.id end
            G_reader_settings:saveSetting("language_japanese_page_order", order)
        end,
    })
end

--- Present the analysis, optional AI section, and (browsable) dictionary
-- definitions in one window.  With several dictionaries, the Prev/Next buttons,
-- the volume/page keys and a horizontal swipe page through them (see
-- AnalysisViewer); long content scrolls (vertical swipe / scroll bar).
function Japanese:showAnalysisWindow(result, defs)
    local title = result.surface
    if result.base ~= "" and result.base ~= result.surface then
        title = result.surface .. " → " .. result.base
    end
    local pages = Analysis.build_pages(result, defs,
        G_reader_settings:readSetting("language_japanese_page_order"))
    local total = #pages
    local idx = 1
    local viewer, change
    local function render()
        local buttons = {}
        if total > 1 then
            table.insert(buttons, {
                { text = "◂ " .. _("Prev"), callback = function() change(-1) end },
                { text = _("Next") .. " ▸", callback = function() change(1) end },
            })
        end
        if self.ui and self.ui.dictionary then
            -- Bridge to the main dictionary window (with its own collection and
            -- analysis buttons), so the analysis window is never a dead end.
            table.insert(buttons, {
                {
                    text = _("Look up in dictionary"),
                    callback = function()
                        UIManager:close(viewer)
                        local lookup_word = result.base ~= "" and result.base or result.surface
                        self.ui.dictionary:onLookupWord(lookup_word, true)
                    end,
                },
            })
        end
        viewer = AnalysisViewer:new {
            title = title,
            text = Analysis.window_text(result, pages[idx], idx, total),
            buttons_table = #buttons > 0 and buttons or nil,
            add_default_buttons = true,
            nav_enabled = total > 1,
            on_change_page = function(delta) change(delta) end,
        }
        UIManager:show(viewer)
    end
    change = function(delta)
        idx = (idx - 1 + delta) % total + 1
        UIManager:close(viewer)
        render()
    end
    render()
end

--- Analyse `text` and present the result (dictionary form, part of speech,
-- conjugation path, optional AI grammar analysis, and dictionary translations).
-- Any failure is surfaced rather than silently doing nothing.
function Japanese:showAnalysis(text)
    if not text or text == "" then return end
    text = util.cleanupSelectedText(text)
    if not util.hasCJKChar(text) then return end
    if not self:ensureEngine() then
        UIManager:show(InfoMessage:new { text = _("Japanese conjugation engine could not be loaded.") })
        return
    end
    local function run()
        local result, defs
        local ok, err = pcall(function()
            result = Analysis.analyse(text, self.deinflector)
            defs = self:lookupDefinitions(result.base)
        end)
        if not ok then
            logger.err("japanese.koplugin: analysis failed:", err)
            UIManager:show(InfoMessage:new { text = T(_("Japanese analysis failed: %1"), tostring(err)) })
            return
        end
        result.surface_display = self:furiganaAnnotate(result.surface)
        result.base_display = self:furiganaAnnotate(result.base)
        local tr_text, tr_err = self:queryTranslate(result.base, result.surface)
        result.translate = tr_text or (tr_err and T(_("(translation failed: %1)"), tr_err))
        local ai_text, ai_err = self:queryAI(result.surface)
        result.ai = ai_text or (ai_err and T(_("(AI request failed: %1)"), ai_err))
        self:showAnalysisWindow(result, defs)
    end
    -- Online lookups (translate / AI) need a Trapper coroutine for the
    -- dismissable subprocess; without them, run directly.
    if self:aiEnabled() or self:translateEnabled() then
        require("ui/trapper"):wrap(run)
    else
        run()
    end
end

--- Whether the optional AI grammar analysis is enabled and fully configured.
function Japanese:aiEnabled()
    return G_reader_settings:isTrue("language_japanese_ai_enabled")
        and LLM.is_configured(self:aiOpts())
end

function Japanese:aiOpts()
    return {
        provider = G_reader_settings:readSetting("language_japanese_ai_provider") or "openai",
        endpoint = G_reader_settings:readSetting("language_japanese_ai_endpoint") or "",
        api_key = G_reader_settings:readSetting("language_japanese_ai_key") or "",
        model = G_reader_settings:readSetting("language_japanese_ai_model") or "",
    }
end

--- Query the configured LLM for the surface form — only when online.  Runs in a
-- dismissable subprocess so the UI never freezes.  Returns the text or nil.
function Japanese:queryAI(surface)
    if not self:aiEnabled() then return nil end
    if not require("ui/network/manager"):isConnected() then return nil end
    local Trapper = require("ui/trapper")
    local opts = self:aiOpts()
    local completed, ok_flag, payload = Trapper:dismissableRunInSubprocess(function()
        local text, err = LLM.query(opts, surface)
        if text and text ~= "" then return true, text end
        return false, tostring(err or "no response")
    end, _("Querying AI…"))
    if not completed then return nil end          -- dismissed by the user
    if ok_flag then return LLM.strip_na(payload) end -- success → AI text (n/a lines dropped)
    return nil, payload                            -- failure → error message (shown)
end

--- Test the AI configuration: send a sample word and show the raw response or
-- the exact error (e.g. Gemini's "model not found" 404), to help debugging.
function Japanese:testAiConnection()
    if not LLM.is_configured(self:aiOpts()) then
        UIManager:show(InfoMessage:new { text = _("Configure the AI provider and API key (and endpoint/model) first.") })
        return
    end
    if not require("ui/network/manager"):isConnected() then
        UIManager:show(InfoMessage:new { text = _("Not online — connect to Wi-Fi to test the AI.") })
        return
    end
    local opts = self:aiOpts()
    require("ui/trapper"):wrap(function()
        local Trapper = require("ui/trapper")
        local completed, ok_flag, payload = Trapper:dismissableRunInSubprocess(function()
            local text, err = LLM.query(opts, "食べる")
            if text and text ~= "" then return true, text end
            return false, tostring(err or "no response")
        end, _("Testing AI connection…"))
        if not completed then return end
        UIManager:show(InfoMessage:new {
            text = ok_flag and (_("AI OK. Sample response:\n\n") .. payload:sub(1, 600))
                or (_("AI request failed:\n\n") .. payload),
        })
    end)
end

--- Whether the optional Google translation section is enabled.
function Japanese:translateEnabled()
    return G_reader_settings:isTrue("language_japanese_translate_enabled")
end

--- Google-translate the base and tapped forms (online) in a dismissable
-- subprocess.  Returns a "form → translation" block (base, plus the surface form
-- when it differs) or nil.
function Japanese:queryTranslate(base, surface)
    if not self:translateEnabled() then return nil end
    if not require("ui/network/manager"):isConnected() then return nil end
    local Trapper = require("ui/trapper")
    local completed, base_tr, surf_tr = Trapper:dismissableRunInSubprocess(function()
        local Translator = require("ui/translator")
        local bt = Translator:translate(base, "en", "ja") or ""
        local st = (surface ~= base) and (Translator:translate(surface, "en", "ja") or "") or ""
        return bt, st
    end, _("Translating…"))
    if not completed then return nil end
    local lines = {}
    if type(base_tr) == "string" and base_tr ~= "" then
        lines[#lines + 1] = base .. " → " .. base_tr
    end
    if type(surf_tr) == "string" and surf_tr ~= "" and surface ~= base then
        lines[#lines + 1] = surface .. " → " .. surf_tr
    end
    if #lines == 0 then return nil, _("no translation returned") end
    return table.concat(lines, "\n")
end

--- Gesture-bound entry point.  Registered as a `category="arg"` action, so when
-- bound to a tap/gesture it receives the gesture object (with `.pos`) and we
-- analyse the word under it; otherwise we fall back to the current selection.
function Japanese:onShowJapaneseAnalysis(ges)
    if type(ges) == "table" and ges.pos and self:analyseAtPos(ges.pos) then
        return true
    end
    local selected = self.ui and self.ui.highlight and self.ui.highlight.selected_text
    if selected and selected.text and selected.text ~= "" then
        self:showAnalysis(selected.text)
    else
        UIManager:show(InfoMessage:new { text = _("Tap on a Japanese word to analyse it.") })
    end
    return true
end

--- Register the gesture-bindable "Analyse Japanese word" action.  category="arg"
-- means a bound gesture's object (carrying the tap position) is passed through,
-- so it works as a tap-on-word lookup from the Gestures menu (like "Follow
-- nearest link").
function Japanese:onDispatcherRegisterActions()
    Dispatcher:registerAction("japanese_analyze_word", {
        category = "arg",
        event = "ShowJapaneseAnalysis",
        arg = { pos = { x = 0, y = 0 } },
        title = _("Analyse Japanese word"),
        reader = true,
    })
    Dispatcher:registerAction("japanese_sentence_splitting", {
        category = "none",
        event = "ToggleSentenceSplitting",
        title = _("Japanese sentence splitting (volume keys)"),
        reader = true,
    })
end

--- Register the single-tap touch zone once the reader (view/document) is
-- ready, and repurpose the page-turn keys when sentence splitting is on.
function Japanese:onReaderReady()
    self:setupAnalyseTouchZone()
    if self:isSentenceSplittingEnabled() and self.ui and self.ui.rolling then
        local ctrl = self:getSentenceSplit()
        if ctrl then ctrl:applyKeys(true) end
    end
end

--- A high-priority "tap" zone: it analyses the word under the tap and otherwise
-- declines (returns false), letting the tap fall through to the normal
-- page-turn / highlight handling.
function Japanese:setupAnalyseTouchZone()
    if self._tap_zone_registered then return end
    if not (self.ui and self.ui.registerTouchZones) then return end
    self.ui:registerTouchZones({
        {
            id = "japanese_analyse_tap",
            ges = "tap",
            screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 },
            overrides = {
                "readerhighlight_tap",
                "tap_top_left_corner", "tap_top_right_corner",
                "tap_left_bottom_corner", "tap_right_bottom_corner",
                "tap_forward", "tap_backward",
            },
            handler = function(ges) return self:onTapAnalyse(ges) end,
        },
    })
    self._tap_zone_registered = true
    logger.info("japanese.koplugin: registered whole-screen single-tap analysis zone")
end

--- Analyse the Japanese word at a screen position (from a tap or a bound
-- gesture).  Returns true if a Japanese word was found and the window shown.
-- No selection is painted (getWordFromPosition with do_not_draw_selection=true).
function Japanese:analyseAtPos(screen_pos)
    if not (screen_pos and self.ui.document and self.ui.view) then return false end
    if self.ui.paging then return false end -- crengine/EPUB only
    -- Copy the point: screenToPageTransform mutates it (adds .page).
    local pos = self.ui.view:screenToPageTransform({ x = screen_pos.x, y = screen_pos.y })
    local ok, word = pcall(self.ui.document.getWordFromPosition, self.ui.document, pos, true)
    if not (ok and word and word.word and word.word ~= "") then return false end
    if not util.hasCJKChar(word.word) then return false end
    self:showAnalysis(self:expandWord(word))
    return true
end

--- Whole-screen single-tap handler.  Returns false (so the tap still turns the
-- page) when the feature is off or no Japanese word is under the tap.
function Japanese:onTapAnalyse(ges)
    if not self.tap_to_analyse then return false end
    return self:analyseAtPos(ges and ges.pos) or false
end

--- Expand a tapped word to the full Japanese token, reusing onWordSelection's
-- dictionary-validated forward scan but with non-drawing callbacks (so no
-- selection is painted).  Falls back to the raw tapped word.
function Japanese:expandWord(word)
    if not (word.pos0 and word.pos1 and self.ui.document) then return word.word end
    local doc = self.ui.document
    local callbacks = {
        get_prev_char_pos = function(p) return doc:getPrevVisibleChar(p) end,
        get_next_char_pos = function(p) return doc:getNextVisibleChar(p) end,
        get_text_in_range = function(a, b) return doc:getTextFromXPointers(a, b) end,
    }
    local ok, range = pcall(self.onWordSelection, self, {
        text = word.word, pos0 = word.pos0, pos1 = word.pos1, callbacks = callbacks,
    })
    if ok and type(range) == "table" and range[1] and range[2] then
        local ok2, expanded = pcall(function() return doc:getTextFromXPointers(range[1], range[2]) end)
        if ok2 and expanded and expanded ~= "" then
            return util.cleanupSelectedText(expanded)
        end
    end
    return word.word
end

-- ------------------------------------------------------- sentence splitting --
-- Read the book sentence by sentence with the volume/page-turn keys: each
-- press speaks the sentence through VOICEVOX and shows it (optionally with
-- furigana) plus its translation in a bottom popup, with the next sentences'
-- audio and translation precached. While enabled, the keys step sentences
-- instead of turning pages (see sentencesplitting.lua).

function Japanese:isSentenceSplittingEnabled()
    return G_reader_settings:isTrue("language_japanese_sentence_splitting")
end

--- The lazy sentence-splitting controller; nil (logged once) when the
-- furigana plugin — which provides the splitter, the VOICEVOX client and the
-- caches — is unavailable.
function Japanese:getSentenceSplit()
    if self._sentence_split == nil then
        local ok, ctrl = pcall(function()
            return require("sentencesplitting").newController(self)
        end)
        if not ok then
            logger.warn("japanese.koplugin: sentence splitting unavailable:", ctrl)
        end
        self._sentence_split = ok and ctrl or false
    end
    return self._sentence_split or nil
end

--- Enable/disable sentence splitting: saves the setting and immediately
-- repurposes/restores the page-turn keys in the open reader.
function Japanese:setSentenceSplitting(on)
    if on and not self:getSentenceSplit() then
        UIManager:show(InfoMessage:new{
            text = _("Sentence splitting needs the Furigana plugin (it provides the sentence splitter and VOICEVOX audio)."),
        })
        return
    end
    G_reader_settings:saveSetting("language_japanese_sentence_splitting", on)
    local ctrl = self:getSentenceSplit()
    if ctrl then
        ctrl:applyKeys(on)
        if not on then ctrl:stop() end
    end
end

--- Gesture/dispatcher-bound toggle ("Japanese sentence splitting").
function Japanese:onToggleSentenceSplitting()
    local on = not self:isSentenceSplittingEnabled()
    self:setSentenceSplitting(on)
    if self:isSentenceSplittingEnabled() == on then
        UIManager:show(InfoMessage:new{
            text = on and _("Sentence splitting on — press a volume/page key to read the first sentence.")
                or _("Sentence splitting off — the keys turn pages again."),
            timeout = 2,
        })
    end
    return true
end

--- Page-turn key presses reach us only while ReaderRolling's own bindings
-- are deactivated (sentence splitting on, see applyKeys): step sentences.
function Japanese:onKeyPress(key)
    if not (self._sentence_split and self:isSentenceSplittingEnabled()
            and self.ui and self.ui.rolling) then
        return
    end
    return self._sentence_split:onKeyPress(key)
end

--- Manual navigation drops the sentence session (self-caused flips don't).
function Japanese:onPageUpdate(page)
    if self._sentence_split then
        self._sentence_split:onPageUpdate(page)
    end
end

function Japanese:onCloseDocument()
    if self._sentence_split then
        self._sentence_split:stop()
    end
end

--- The double-press action picker (radio submenu).
function Japanese:genDoublePressMenu()
    local choices = {
        { id = "none", text = _("Nothing (step immediately, no delay)") },
        { id = "volume", text = _("Media volume up / down (Android)") },
        { id = "toggle", text = _("Stop / start sentence reading") },
        { id = "replay", text = _("Replay the sentence audio") },
        { id = "translation", text = _("Show / hide the translation") },
        { id = "page", text = _("Turn a whole page forward / back") },
    }
    local items = {}
    for _, choice in ipairs(choices) do
        items[#items + 1] = {
            text = choice.text,
            radio = true,
            checked_func = function()
                return (G_reader_settings:readSetting("language_japanese_sentence_doublepress") or "none")
                    == choice.id
            end,
            callback = function()
                G_reader_settings:saveSetting("language_japanese_sentence_doublepress",
                    choice.id ~= "none" and choice.id or nil)
            end,
        }
    end
    return items
end

-- ------------------------------------------------------- local translation --
-- Offline JA→EN through a local OpenAI-compatible LLM server — llama.cpp
-- serving LiquidAI's LFM2-350M-ENJP-MT (a 350M-parameter model tuned solely
-- for JA↔EN translation; ~230 MB, redistributable license, llama-server
-- speaks the API out of the box). Run it on the PC with
-- tools/lfm2-translate-serve.sh, or on the device once a companion app à la
-- VoiceVoxForAndroid serves it on 127.0.0.1. When enabled, every sentence
-- translation tries this server first and only falls back to Google.

function Japanese:isLocalTranslateEnabled()
    return G_reader_settings:isTrue("language_japanese_local_translate")
end

--- The local-translator opts for fetch jobs; nil when the feature is off
-- (callers then go straight to Google).
function Japanese:localTranslatorOpts()
    if not self:isLocalTranslateEnabled() then return nil end
    local LocalTranslator = require("localtranslator")
    return {
        url = G_reader_settings:readSetting("language_japanese_local_tr_url")
            or LocalTranslator.DEFAULT_URL,
    }
end

--- Send a sample sentence to the configured server and show the translation
-- or the exact error.
function Japanese:testLocalTranslator()
    local LocalTranslator = require("localtranslator")
    local opts = {
        url = G_reader_settings:readSetting("language_japanese_local_tr_url")
            or LocalTranslator.DEFAULT_URL,
    }
    require("ui/trapper"):wrap(function()
        local Trapper = require("ui/trapper")
        local completed, ok_flag, payload = Trapper:dismissableRunInSubprocess(function()
            local tr, err = LocalTranslator.translate(opts, "猫が好きです。")
            if tr then return true, tr end
            return false, tostring(err or "no reply")
        end, _("Testing the local translator…"))
        if not completed then return end
        UIManager:show(InfoMessage:new{
            text = ok_flag and (_("Local translator OK:\n\n猫が好きです。 →\n") .. payload)
                or (_("Local translation failed:\n\n") .. payload),
        })
    end)
end

function Japanese:genLocalTranslatorMenu()
    local LocalTranslator_url = function()
        local ok, LocalTranslator = pcall(require, "localtranslator")
        return G_reader_settings:readSetting("language_japanese_local_tr_url")
            or (ok and LocalTranslator.DEFAULT_URL) or ""
    end
    return {
        text = _("Local translation server (offline)"),
        help_text = _([[
Translate sentences through a local LLM server instead of Google: llama.cpp's llama-server running LiquidAI's LFM2-350M-ENJP-MT, a small model tuned purely for Japanese→English (much more natural on fiction than classic offline translators).

On the PC, run tools/lfm2-translate-serve.sh (downloads the ~230 MB model on first use) and point the URL at it, e.g. http://192.168.1.10:8087. When enabled, sentence translations try this server first and fall back to Google; with the server on the device itself, translations work fully offline.]]),
        sub_item_table = {
            {
                text = _("Use the local translator"),
                checked_func = function() return self:isLocalTranslateEnabled() end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    G_reader_settings:saveSetting("language_japanese_local_translate",
                        not self:isLocalTranslateEnabled())
                    if touchmenu_instance then touchmenu_instance:updateItems() end
                end,
            },
            {
                text_func = function()
                    return T(_("Server: %1"), LocalTranslator_url())
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    self:promptText(_("Local translation server URL"),
                        "language_japanese_local_tr_url", touchmenu_instance)
                end,
                help_text = _("The llama-server base URL (its OpenAI-compatible /v1/chat/completions endpoint is used)."),
            },
            {
                text = _("Test translation (猫が好きです)"),
                keep_menu_open = true,
                callback = function() self:testLocalTranslator() end,
            },
        },
    }
end

-- ------------------------------------------------ read sentences from here --

--- Register the "Read sentences from here" entry in the text-selection
-- (highlight) dialog: long-press text, pick it, and the sentence reader
-- starts at the sentence the selection begins in (enabling the feature if
-- it was off).
function Japanese:registerSentenceStartButton()
    if not (self.ui and self.ui.highlight and self.ui.highlight.addToHighlightDialog) then return end
    self.ui.highlight:addToHighlightDialog("12_b_read_sentences", function(this)
        return {
            text = _("Read sentences from here"),
            show_in_highlight_dialog_func = function()
                return self.ui.rolling ~= nil
                    and this.selected_text ~= nil and this.selected_text.pos0 ~= nil
                    and util.hasCJKChar(this.selected_text.text or "")
            end,
            callback = function()
                local pos0 = this.selected_text.pos0
                this:onClose()
                self:startSentencesAt(pos0)
            end,
        }
    end)
end

--- Start the sentence reader at the sentence containing xpointer `pos0` (the
-- start of a text selection). The byte offset within the page text is
-- computed with the same extraction pageText() uses, so the sentence indices
-- line up.
function Japanese:startSentencesAt(pos0)
    if not self:isSentenceSplittingEnabled() then
        self:setSentenceSplitting(true)
    end
    local ctrl = self:getSentenceSplit()
    if not (ctrl and self:isSentenceSplittingEnabled()) then return end
    local ok, byte_pos = pcall(function()
        local doc = self.ui.document
        local page = doc:getCurrentPage()
        local xp0 = doc:getPageXPointer(page)
        local prefix = doc:getTextFromXPointers(xp0, pos0) or ""
        return #prefix + 1
    end)
    ctrl:startAt(ok and byte_pos or 1)
end

--- Add an "Analyse (JA)" button to the dictionary lookup popup, so the whole
-- analysis (dictionary form, type, conjugation, dictionary entry, translation,
-- AI) is available from a normal lookup too.  Shown only for CJK words.
-- Registered as a transient ("conditional") button so it is always present,
-- regardless of the user's customized persistent button layout.
function Japanese:registerDictButton()
    self.ui.dictionary:addToDictButtons({
        id = "japanese_analyse",
        text = _("Analyse (JA)"),
        conditional = true,
        -- Shares a transient row with the furigana plugin's "Speak (JA)".
        row_group = "ja_word_actions",
        show_func = function(dict_popup)
            if dict_popup.is_wiki then return false end
            -- Gate on the originally selected text (dict_popup.word), the same
            -- text the callback analyses -- not the current result's headword
            -- (dict_popup.lookupword, which changes as you page dictionaries).
            local w = dict_popup.word or dict_popup.lookupword
            return w ~= nil and util.hasCJKChar(w)
        end,
        callback = function(dict_popup)
            self:showAnalysis(dict_popup.word or dict_popup.lookupword)
        end,
    })
end

--- Prompt for a text setting via an input dialog, then refresh the menu.
function Japanese:promptText(title, setting_key, touchmenu_instance, is_password)
    local InputDialog = require("ui/widget/inputdialog")
    local dialog
    dialog = InputDialog:new {
        title = title,
        input = G_reader_settings:readSetting(setting_key) or "",
        text_type = is_password and "password" or nil,
        buttons = { {
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            {
                text = _("Save"),
                is_enter_default = true,
                callback = function()
                    G_reader_settings:saveSetting(setting_key, dialog:getInputText())
                    UIManager:close(dialog)
                    if touchmenu_instance then touchmenu_instance:updateItems() end
                end,
            },
        } },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

--- The "AI grammar analysis" submenu (enable + provider + endpoint/key/model).
function Japanese:genAiMenu()
    local function provider()
        return G_reader_settings:readSetting("language_japanese_ai_provider") or "openai"
    end
    local function set_provider(name)
        G_reader_settings:saveSetting("language_japanese_ai_provider", name)
        G_reader_settings:delSetting("language_japanese_ai_model") -- use the new provider's default
    end
    return {
        text = _("AI grammar analysis (online)"),
        help_text = _("When enabled and online, query an OpenAI-compatible or Google Gemini LLM for a grammar breakdown, shown between Conjugation and the dictionary entry. Needs an API key (Gemini's free tier works); hidden when offline or unconfigured."),
        sub_item_table = {
            {
                text = _("Enable AI analysis"),
                checked_func = function() return G_reader_settings:isTrue("language_japanese_ai_enabled") end,
                callback = function(touchmenu_instance)
                    local on = G_reader_settings:isTrue("language_japanese_ai_enabled")
                    G_reader_settings:saveSetting("language_japanese_ai_enabled", not on)
                    if touchmenu_instance then touchmenu_instance:updateItems() end
                end,
            },
            {
                text_func = function()
                    return T(_("Provider: %1"), provider() == "gemini"
                        and _("Google Gemini") or _("OpenAI-compatible"))
                end,
                sub_item_table = {
                    {
                        text = _("OpenAI-compatible"),
                        radio = true,
                        checked_func = function() return provider() ~= "gemini" end,
                        callback = function() set_provider("openai") end,
                    },
                    {
                        text = _("Google Gemini (free tier)"),
                        radio = true,
                        checked_func = function() return provider() == "gemini" end,
                        callback = function() set_provider("gemini") end,
                    },
                },
            },
            {
                text_func = function()
                    if provider() == "gemini" then return _("Endpoint: automatic for Gemini") end
                    local v = G_reader_settings:readSetting("language_japanese_ai_endpoint")
                    return T(_("Endpoint: %1"), (v and v ~= "") and v or _("(not set)"))
                end,
                enabled_func = function() return provider() ~= "gemini" end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    self:promptText(_("API endpoint (chat-completions URL)"),
                        "language_japanese_ai_endpoint", touchmenu_instance)
                end,
            },
            {
                text_func = function()
                    local v = G_reader_settings:readSetting("language_japanese_ai_key")
                    return T(_("API key: %1"), (v and v ~= "") and "••••••" or _("(not set)"))
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    self:promptText(_("API key"), "language_japanese_ai_key", touchmenu_instance, true)
                end,
            },
            {
                text_func = function()
                    local v = G_reader_settings:readSetting("language_japanese_ai_model")
                    local default = provider() == "gemini" and "gemini-2.0-flash" or "gpt-4o-mini"
                    return T(_("Model: %1"), (v and v ~= "") and v or default)
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    self:promptText(_("Model name"), "language_japanese_ai_model", touchmenu_instance)
                end,
            },
            {
                text = _("Test connection"),
                keep_menu_open = true,
                help_text = _("Send a sample word to the configured AI and show the response or the exact error."),
                callback = function() self:testAiConnection() end,
            },
        },
    }
end

function Japanese:genMenuItem()
    local sub_item_table = {
        -- self.max_scan_length configuration
        {
            text_func = function()
                return T(N_("Text scan length: %1 character", "Text scan length: %1 characters", self.max_scan_length),
                    self.max_scan_length)
            end,
            help_text = _(
            "Number of characters to look ahead when trying to expand tap-and-hold word selection in documents."),
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                local SpinWidget = require("ui/widget/spinwidget")
                local Screen = require("device").screen
                local items = SpinWidget:new {
                    title_text = _("Text scan length"),
                    info_text = T(_([[
The maximum number of characters to look ahead when trying to expand tap-and-hold word selection in documents.
Larger values allow longer phrases to be selected automatically, but with the trade-off that selections may become slower.

Default value: %1]]), DEFAULT_TEXT_SCAN_LENGTH),
                    width = math.floor(Screen:getWidth() * 0.75),
                    value = self.max_scan_length,
                    value_min = 0,
                    value_max = 1000,
                    value_step = 1,
                    value_hold_step = 10,
                    ok_text = _("Set scan length"),
                    default_value = DEFAULT_TEXT_SCAN_LENGTH,
                    callback = function(spin)
                        self.max_scan_length = spin.value
                        G_reader_settings:saveSetting("language_japanese_text_scan_length", self.max_scan_length)
                        if touchmenu_instance then touchmenu_instance:updateItems() end
                    end,
                }
                UIManager:show(items)
            end,
        },
    }
    -- self.deinflector configuration
    util.arrayAppend(sub_item_table, self.deinflector:genMenuItems())

    -- Word analysis: the single-tap toggle and how to invoke it.
    table.insert(sub_item_table, {
        text = _("Tap a word to analyse it"),
        checked_func = function() return self.tap_to_analyse end,
        help_text = _([[
When enabled, a single tap on a Japanese word shows its dictionary form, part of speech, how it is conjugated, and its English translation from your installed dictionaries. Tapping a margin or blank area still turns the page.

You can also bind “Analyse Japanese word” to a gesture under Gestures.]]),
        callback = function(touchmenu_instance)
            self.tap_to_analyse = not self.tap_to_analyse
            G_reader_settings:saveSetting("language_japanese_tap_to_analyse", self.tap_to_analyse)
            if touchmenu_instance then touchmenu_instance:updateItems() end
        end,
    })

    -- Furigana on the Word / Dictionary form header fields (via furigana plugin).
    table.insert(sub_item_table, {
        text = _("Furigana on Word & Dictionary form"),
        checked_func = function() return G_reader_settings:nilOrTrue("language_japanese_furigana") end,
        help_text = _("Show the reading in brackets after the Word and Dictionary form, e.g. 食べる (たべる). Uses the Furigana plugin's dictionary (first use loads it, which takes a moment); has no effect if that plugin is unavailable."),
        callback = function(touchmenu_instance)
            local on = G_reader_settings:nilOrTrue("language_japanese_furigana")
            G_reader_settings:saveSetting("language_japanese_furigana", not on)
            if touchmenu_instance then touchmenu_instance:updateItems() end
        end,
    })

    -- Optional Google translation of the base + conjugated form (online).
    table.insert(sub_item_table, {
        text = _("Google Translate: base + conjugated form (online)"),
        checked_func = function() return G_reader_settings:isTrue("language_japanese_translate_enabled") end,
        help_text = _("Standalone toggle (not the AI). When enabled and online, show Google translations of both the dictionary form and the form you tapped, between Conjugation and the dictionary entry. Tick to enable, untick to disable."),
        callback = function(touchmenu_instance)
            local on = G_reader_settings:isTrue("language_japanese_translate_enabled")
            G_reader_settings:saveSetting("language_japanese_translate_enabled", not on)
            if touchmenu_instance then touchmenu_instance:updateItems() end
        end,
    })

    -- Sentence splitting: volume keys step the book sentence by sentence,
    -- with a marker plus any combination of audio / popup / translation.
    table.insert(sub_item_table, {
        text = _("Sentence splitting (volume keys)"),
        help_text = _([[
Read the book sentence by sentence with the volume/page-turn keys. Each press moves a faint marker onto the sentence's first character and — per the "On each step" toggles — speaks it through VOICEVOX, and/or shows it (with furigana) and its translation in a popup right above the sentence. Audio and translation of the next two sentences are prepared in the background, so stepping forward is smooth.

While enabled, the keys step sentences instead of turning pages (tapping still turns them). Tap the popup to show/hide the translation, double-tap to replay the audio; hold text on the popup to look it up in the dictionary. You can also long-press text on the page and choose 'Read sentences from here'. Needs the Furigana plugin.]]),
        sub_item_table = {
            {
                text = _("Volume keys read sentences"),
                checked_func = function() return self:isSentenceSplittingEnabled() end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    self:setSentenceSplitting(not self:isSentenceSplittingEnabled())
                    if touchmenu_instance then touchmenu_instance:updateItems() end
                end,
                help_text = _("Repurpose the volume/page-turn keys: forward = next sentence, back = previous sentence. Turn off to get page turning back. Can also be toggled by binding 'Japanese sentence splitting' to a gesture."),
                separator = true,
            },
            {
                text = _("On each step: play audio (VOICEVOX)"),
                checked_func = function() return G_reader_settings:nilOrTrue("language_japanese_sentence_audio") end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    G_reader_settings:flipNilOrTrue("language_japanese_sentence_audio")
                    if touchmenu_instance then touchmenu_instance:updateItems() end
                end,
                help_text = _("Speak each sentence when you step onto it (configure the engine under Furigana → Word audio). Off: stepping stays silent — a double tap on the popup still plays the sentence on demand."),
            },
            {
                text = _("On each step: show the popup"),
                checked_func = function() return G_reader_settings:nilOrTrue("language_japanese_sentence_popup") end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    G_reader_settings:flipNilOrTrue("language_japanese_sentence_popup")
                    if touchmenu_instance then touchmenu_instance:updateItems() end
                end,
                help_text = _("Show the sentence bubble on each step. With this and the audio off, the keys become a pure sentence cursor: only the marker moves, nothing plays or is fetched — for skipping to where you want to resume."),
            },
            {
                text = _("Popup: show the Japanese sentence"),
                checked_func = function() return G_reader_settings:nilOrTrue("language_japanese_sentence_show_jp") end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    G_reader_settings:flipNilOrTrue("language_japanese_sentence_show_jp")
                    if touchmenu_instance then touchmenu_instance:updateItems() end
                end,
                help_text = _("Show the sentence itself in the popup. Off (with translation on), only the English line appears — the Japanese stays on the page, marked by the cursor."),
            },
            {
                text = _("Popup: furigana on the sentence"),
                checked_func = function() return G_reader_settings:nilOrTrue("language_japanese_sentence_furigana") end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    G_reader_settings:flipNilOrTrue("language_japanese_sentence_furigana")
                    if touchmenu_instance then touchmenu_instance:updateItems() end
                end,
                help_text = _("Splice each word's reading into the sentence shown in the popup, e.g. 私（わたし）は行（い）く。 Uses the Furigana plugin's dictionary (the first sentence loads it, which takes a moment)."),
            },
            {
                text = _("Popup: show the translation"),
                checked_func = function() return G_reader_settings:nilOrTrue("language_japanese_sentence_translate") end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    G_reader_settings:flipNilOrTrue("language_japanese_sentence_translate")
                    if touchmenu_instance then touchmenu_instance:updateItems() end
                end,
                help_text = _("Show the sentence's translation under it in the popup (it appears as soon as it arrives and is cached). Uses the local translation server when configured, Google otherwise (which needs a network connection — the audio does not)."),
                separator = true,
            },
            {
                text_func = function()
                    local labels = {
                        none = _("nothing (step immediately)"),
                        volume = _("volume up/down"),
                        toggle = _("stop/start sentence reading"),
                        replay = _("replay the sentence audio"),
                        translation = _("show/hide the translation"),
                        page = _("turn a whole page"),
                    }
                    local action = G_reader_settings:readSetting("language_japanese_sentence_doublepress") or "none"
                    return T(_("Double press: %1"), labels[action] or action)
                end,
                help_text = _([[What a quick double press of a stepping key does. The key's direction matters where it can: double volume-up raises the media volume / turns forward, double volume-down lowers it / turns back.

Any choice other than 'nothing' delays single steps slightly (the double-press window).]]),
                sub_item_table_func = function()
                    return self:genDoublePressMenu()
                end,
            },
        },
    })

    -- Offline translation through a local LLM server (llama.cpp +
    -- LFM2-350M-ENJP-MT); preferred over Google wherever sentences are
    -- translated when enabled.
    table.insert(sub_item_table, self:genLocalTranslatorMenu())

    -- Order of the analysis pages (AI / Google Translate / dictionaries).
    table.insert(sub_item_table, {
        text = _("Analysis page order"),
        keep_menu_open = true,
        help_text = _("Set the order of the analysis pages: AI, Google Translate, and each dictionary (move up/down). Dictionaries appear here once seen in a lookup."),
        callback = function() self:showPageOrderConfig() end,
    })

    -- Optional AI grammar analysis (online; OpenAI-compatible or Google Gemini).
    table.insert(sub_item_table, self:genAiMenu())

    return {
        text = _("Japanese"),
        sub_item_table = sub_item_table,
    }
end

return Japanese
