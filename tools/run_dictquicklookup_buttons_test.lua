-- Standalone harness test for DictQuickLookup's plugin-button assembly:
--   * populatePluginButtons: conditional row grouping, dedup against the
--     effective layout (base_layout), show_func gating, non-conditional
--     auto-add to default_layout.
--   * buildButtonLayout: transient rows must NOT leak into the session-shared
--     default layout (the old wiki-window bug).
-- Usage (plain lua 5.x, no KOReader build needed):
--   lua tools/run_dictquicklookup_buttons_test.lua

local here = arg[0]:match("^(.*)/[^/]*$") or "."
local ROOT = here .. "/.."

local settings_store = {}
G_reader_settings = {
    readSetting = function(_, key, default)
        if settings_store[key] == nil and default ~= nil then settings_store[key] = default end
        return settings_store[key]
    end,
    saveSetting = function(_, key, value) settings_store[key] = value end,
    isTrue = function(_, key) return settings_store[key] == true end,
    nilOrTrue = function(_, key) return settings_store[key] ~= false end,
    hasNot = function(_, key) return settings_store[key] == nil end,
}

local gettext = setmetatable({}, { __call = function(_, s) return s end })
gettext.ngettext = function(s, p, n) return n == 1 and s or p end
gettext.pgettext = function(_, s) return s end

local InputContainer = {}
function InputContainer:extend(o)
    o = o or {}
    setmetatable(o, { __index = self })
    return o
end

local function deepcopy(t)
    if type(t) ~= "table" then return t end
    local copy = {}
    for k, v in pairs(t) do copy[k] = deepcopy(v) end
    return copy
end

local generic = setmetatable({}, { __index = function() return function() end end })
local stubs = {
    ["ui/bidi"] = { mirroredUILayout = function() return false end },
    ["ffi/blitbuffer"] = generic,
    ["ui/widget/buttondialog"] = generic,
    ["ui/widget/buttontable"] = generic,
    ["ui/widget/container/centercontainer"] = generic,
    ["device"] = {
        isTouchDevice = function() return false end,
        hasKeys = function() return false end,
        hasDPad = function() return false end,
        input = {},
        screen = { getWidth = function() return 600 end, getHeight = function() return 800 end },
    },
    ["ui/geometry"] = generic,
    ["ui/event"] = { new = function(_, ...) return { ... } end },
    ["ui/font"] = { getFace = function() return {} end },
    ["ui/widget/container/framecontainer"] = generic,
    ["ui/gesturerange"] = generic,
    ["ui/widget/iconbutton"] = generic,
    ["ui/widget/container/inputcontainer"] = InputContainer,
    ["ui/widget/inputdialog"] = generic,
    ["optmath"] = generic,
    ["ui/widget/container/movablecontainer"] = generic,
    ["ui/widget/overlapgroup"] = generic,
    ["ui/widget/scrollhtmlwidget"] = generic,
    ["ui/widget/scrolltextwidget"] = generic,
    ["ui/size"] = { border = { window = 2 }, padding = { default = 5 } },
    ["ui/widget/textwidget"] = generic,
    ["ui/widget/titlebar"] = generic,
    ["ui/translator"] = generic,
    ["ui/presets"] = { getPresets = function() return {} end },
    ["ui/uimanager"] = generic,
    ["ui/widget/verticalgroup"] = generic,
    ["ui/widget/verticalspan"] = generic,
    ["ui/widget/container/widgetcontainer"] = generic,
    ["apps/filemanager/filemanagerutil"] = { getHomeFolder = function() return "/tmp" end },
    ["libs/libkoreader-lfs"] = generic,
    ["logger"] = { dbg = function() end, info = function() end, warn = function() end, err = function() end },
    ["util"] = { tableDeepCopy = deepcopy },
    ["gettext"] = gettext,
    ["ffi/util"] = {
        template = function(str, ...) return str end,
        orderedPairs = function(t)
            local keys = {}
            for k in pairs(t) do keys[#keys + 1] = k end
            table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
            local i = 0
            return function()
                i = i + 1
                if keys[i] ~= nil then return keys[i], t[keys[i]] end
            end
        end,
    },
    ["ui/time"] = { s = function(n) return n end, now = function() return 0 end },
}
for name, mod in pairs(stubs) do
    package.preload[name] = function() return mod end
end

local failures = 0
local function check(cond, msg)
    if cond then
        print("ok   - " .. msg)
    else
        failures = failures + 1
        print("FAIL - " .. msg)
    end
end

local DictQuickLookup = assert(loadfile(ROOT .. "/frontend/ui/widget/dictquicklookup.lua"))()

local dict_buttons = {
    -- conditional, own row
    japanese_analyse = {
        id = "japanese_analyse",
        text = "Analyse (JA)",
        conditional = true,
        show_func = function(popup) return not popup.is_wiki end,
        callback = function() end,
    },
    -- conditional, shared row group (like the collection buttons)
    dict_collection_01 = {
        id = "dict_collection_01", text = "JP", conditional = true,
        row_group = "dict_collection_row_01", callback = function() end,
    },
    dict_collection_02 = {
        id = "dict_collection_02", text = "Mono", conditional = true,
        row_group = "dict_collection_row_01", callback = function() end,
    },
    -- conditional but hidden by show_func
    hidden_one = {
        id = "hidden_one", text = "Hidden", conditional = true,
        show_func = function() return false end, callback = function() end,
    },
    -- non-conditional with insert_first (like vocabbuilder's button)
    vocabulary = {
        id = "vocabulary", text = "Add to vocabulary builder",
        menu_text = "Vocabulary builder", insert_first = true, callback = function() end,
    },
}

local function make_popup(o)
    o.ui = { dictionary = { _dict_buttons = dict_buttons, default_layout = o.shared_default_layout } }
    return setmetatable(o, { __index = DictQuickLookup })
end

-- 1) populatePluginButtons: grouping, gating, dedup ------------------------
local popup = make_popup{ is_wiki = false }
local pool, default_layout, extra_layout = {}, { { "close" } }, {}
popup:populatePluginButtons(pool, default_layout, extra_layout, default_layout)

check(pool.japanese_analyse and pool.dict_collection_01 and pool.vocabulary,
    "shown specs are added to the button pool")
check(pool.hidden_one == nil, "show_func=false specs stay out of the pool")
local function find_row(layout, id)
    for _, row in ipairs(layout) do
        for _, bid in ipairs(row) do
            if bid == id then return row end
        end
    end
end
local coll_row = find_row(extra_layout, "dict_collection_01")
check(coll_row and #coll_row == 2 and coll_row[2] == "dict_collection_02",
    "row_group puts both collection buttons in one transient row")
local ja_row = find_row(extra_layout, "japanese_analyse")
check(ja_row and #ja_row == 1, "ungrouped conditional button gets its own transient row")
check(default_layout[1][1] == "vocabulary",
    "non-conditional insert_first button is auto-added to the top of the default layout")

-- 2) dedup: a conditional id already placed in the effective layout --------
popup = make_popup{ is_wiki = false }
pool, extra_layout = {}, {}
local saved_layout = { { "close", "japanese_analyse" } } -- old saved config
popup:populatePluginButtons(pool, nil, extra_layout, saved_layout)
check(pool.japanese_analyse ~= nil, "dedup: spec still populates the pool (saved layout can render it)")
check(find_row(extra_layout, "japanese_analyse") == nil,
    "dedup: no duplicate transient row when the id is already in the saved layout")
check(find_row(extra_layout, "dict_collection_01") ~= nil,
    "dedup: other conditional buttons are unaffected")

-- 3) buildButtonLayout must not mutate the shared default layout (wiki bug)
local shared_default = { { "prev_dict", "highlight", "next_dict" }, { "wikipedia", "search", "close" } }
popup = make_popup{ is_wiki = true, is_wiki_fullpage = false, shared_default_layout = shared_default, width = 600 }
popup._getButtonPool = function()
    -- minimal pool: only ids referenced by the layouts/specs above
    local mk = function(id) return { id = id, text = id, callback = function() end } end
    return {
        prev_dict = mk("prev_dict"), highlight = mk("highlight"), next_dict = mk("next_dict"),
        wikipedia = mk("wikipedia"), search = mk("search"), close = mk("close"),
        save = mk("save"), link = mk("link"),
        japanese_analyse = mk("japanese_analyse"),
        dict_collection_01 = mk("dict_collection_01"), dict_collection_02 = mk("dict_collection_02"),
        vocabulary = mk("vocabulary"),
    }
end
local layout = popup:buildButtonLayout()
-- The one-time, idempotent auto-add of *non-conditional* plugin buttons
-- (vocabulary) into the default layout is intended upstream behaviour; what
-- must never happen is transient (conditional/extra) rows leaking into it.
check(find_row(shared_default, "japanese_analyse") == nil
    and find_row(shared_default, "dict_collection_01") == nil,
    "wiki window: transient rows don't leak into the shared default layout")
local function layout_has_button(built, id)
    for _, row in ipairs(built) do
        for _, btn in ipairs(row) do
            if btn.id == id then return true end
        end
    end
    return false
end
check(layout_has_button(layout, "dict_collection_01"),
    "wiki window itself still gets the transient rows appended")

-- run it twice more: previously each wiki window grew the shared layout by
-- its transient rows, unboundedly
local rows_after_first = #shared_default
popup:buildButtonLayout()
popup:buildButtonLayout()
check(#shared_default == rows_after_first,
    "repeated wiki windows: shared default layout does not keep growing")

print(failures == 0 and "\nALL TESTS PASSED" or ("\n" .. failures .. " TEST(S) FAILED"))
os.exit(failures == 0 and 0 or 1)
