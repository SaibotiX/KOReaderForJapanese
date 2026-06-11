-- Standalone harness test for the dictionary-collection buttons & lookup
-- plumbing in frontend/apps/reader/modules/readerdictionary.lua.
-- Usage (plain lua 5.x, no KOReader build needed):
--   lua tools/run_dict_collections_test.lua
--
-- Stubs the KOReader runtime (settings, widgets, lfs, ...) just enough to
-- run init() against a fake dictionary dir, then checks:
--   * getCollectionDictNames (order kept, uninstalled dropped, nil for unknown)
--   * refreshCollectionDictButtons (ids, row chunking, show_func behaviour,
--     wipe & re-register on saveCollections)
--   * lookupWordInCollection (guards, opts threading into stardictLookup)
--   * button callbacks (restricted re-lookup of the popup's word)

local here = arg[0]:match("^(.*)/[^/]*$") or "."
local ROOT = here .. "/.."

local TMP = os.tmpname()
os.remove(TMP)
os.execute("mkdir -p '" .. TMP .. "/dict'")
local function write_ifo(name)
    local f = assert(io.open(TMP .. "/dict/" .. name .. ".ifo", "w"))
    f:write("StarDict's dict ifo file\nversion=3.0.0\nbookname=" .. name .. "\n")
    f:close()
end
write_ifo("Dict A")
write_ifo("Dict B")
write_ifo("Dict C")

-- ---------------------------------------------------------------- stubs --
local SHOWN = {} -- widgets passed to UIManager:show

local settings_store = {}
local function mksettings(store)
    return {
        readSetting = function(_, key, default)
            if store[key] == nil and default ~= nil then store[key] = default end
            return store[key]
        end,
        saveSetting = function(_, key, value) store[key] = value end,
        delSetting = function(_, key) store[key] = nil end,
        isTrue = function(_, key) return store[key] == true end,
        nilOrTrue = function(_, key) return store[key] ~= false end,
        nilOrFalse = function(_, key) return store[key] ~= true end,
        flipNilOrFalse = function(_, key) store[key] = store[key] ~= true end,
        has = function(_, key) return store[key] ~= nil end,
        hasNot = function(_, key) return store[key] == nil end,
    }
end
G_reader_settings = mksettings(settings_store)
G_defaults = mksettings({ STARDICT_DATA_DIR = TMP .. "/dict" })

local function class_stub()
    local c = {}
    c.new = function(self, o)
        o = o or {}
        o.__stub_class = self
        return setmetatable(o, { __index = self })
    end
    return c
end

local gettext = setmetatable({}, { __call = function(_, s) return s end })
gettext.ngettext = function(s, p, n) return n == 1 and s or p end
gettext.pgettext = function(_, s) return s end

local lfs = {}
function lfs.dir(path)
    local p = io.popen("ls -a '" .. path .. "' 2>/dev/null")
    local out = p and p:read("*a") or ""
    if p then p:close() end
    local entries = {}
    for line in out:gmatch("[^\n]+") do entries[#entries + 1] = line end
    local i = 0
    return function()
        i = i + 1
        return entries[i]
    end
end
function lfs.attributes(path, what)
    local p = io.popen("if [ -d '" .. path .. "' ]; then echo directory; elif [ -e '" .. path .. "' ]; then echo file; fi 2>/dev/null")
    local out = p and p:read("*a") or ""
    if p then p:close() end
    local mode = out:match("(%a+)")
    if not mode then return nil end
    if what == "mode" then return mode end
    return { mode = mode }
end

local ffiutil = {
    strcoll = function(a, b) return a < b end,
    template = function(str, ...)
        local args = { ... }
        return (str:gsub("%%(%d)", function(d) return tostring(args[tonumber(d)]) end))
    end,
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
}

local InputContainer = {}
function InputContainer:extend(o)
    o = o or {}
    setmetatable(o, { __index = self })
    return o
end

local InfoMessage = {}
function InfoMessage:new(o)
    o = o or {}
    o.__is_infomessage = true
    return setmetatable(o, { __index = self })
end

local stubs = {
    ["ui/bidi"] = {},
    ["ui/widget/buttondialog"] = class_stub(),
    ["ui/widget/confirmbox"] = class_stub(),
    ["datastorage"] = {
        getDataDir = function() return TMP end,
        getSettingsDir = function() return TMP end,
    },
    ["device"] = {
        isAndroid = function() return false end,
        hasDPad = function() return false end,
        hasFewKeys = function() return false end,
        canExternalDictLookup = function() return false end,
        input = {},
        screen = {},
    },
    ["ui/widget/dictquicklookup"] = {
        window_list = {},
        layoutContainsButtonId = function() return false end,
    },
    ["ui/event"] = { new = function(_, ...) return { ... } end },
    ["ui/geometry"] = class_stub(),
    ["ui/widget/infomessage"] = InfoMessage,
    ["ui/widget/container/inputcontainer"] = InputContainer,
    ["ui/widget/inputdialog"] = class_stub(),
    ["json"] = { decode = function() return {} end },
    ["ui/widget/keyvaluepage"] = class_stub(),
    ["luadata"] = {
        open = function()
            return {
                has = function() return false end,
                readSetting = function() return nil end,
                addTableItem = function() end,
            }
        end,
    },
    ["ui/widget/multiconfirmbox"] = class_stub(),
    ["ui/network/manager"] = { runWhenOnline = function() end },
    ["ui/widget/notification"] = { notify = function() end },
    ["ui/presets"] = { getPresets = function() return {} end },
    ["ui/widget/sortwidget"] = class_stub(),
    ["ui/trapper"] = { wrap = function(_, fn) return fn() end },
    ["ui/uimanager"] = {
        show = function(_, w) SHOWN[#SHOWN + 1] = w end,
        close = function() end,
        scheduleIn = function() end,
        nextTick = function() end,
        unschedule = function() end,
        getTime = function() return 0 end,
    },
    ["ffi/utf8proc"] = { lowercase = function(w) return w end },
    ["ffi"] = { C = {} },
    ["ffi/util"] = ffiutil,
    ["libs/libkoreader-lfs"] = lfs,
    ["logger"] = { dbg = function() end, info = function() end, warn = function() end, err = function() end },
    ["ui/time"] = { s = function(n) return n end, now = function() return 0 end },
    ["util"] = { trim = function(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end },
    ["gettext"] = gettext,
    ["dispatcher"] = { registerAction = function() end },
}
for name, mod in pairs(stubs) do
    package.preload[name] = function() return mod end
end

-- ------------------------------------------------------------ run tests --
local failures = 0
local function check(cond, msg)
    if cond then
        print("ok   - " .. msg)
    else
        failures = failures + 1
        print("FAIL - " .. msg)
    end
end
local function eq_list(a, b)
    if #a ~= #b then return false end
    for i = 1, #a do
        if a[i] ~= b[i] then return false end
    end
    return true
end

local ReaderDictionary = assert(loadfile(ROOT .. "/frontend/apps/reader/modules/readerdictionary.lua"))()

local rd = setmetatable({
    ui = { menu = { registerToMainMenu = function() end } },
}, { __index = ReaderDictionary })
rd:init()

check(eq_list(rd.enabled_dict_names, { "Dict A", "Dict B", "Dict C" }),
    "init found the fake dictionaries: " .. table.concat(rd.enabled_dict_names, ", "))

-- Collections: "JP" has an uninstalled ghost member, "Empty" has none.
rd.dict_collections["JP"] = { "Dict C", "Dict A", "Ghost Dict" }
rd.dict_collections["Empty"] = {}
rd.dict_collections["Mono"] = { "Dict B" }
rd:saveCollections()

-- getCollectionDictNames
check(eq_list(rd:getCollectionDictNames("JP"), { "Dict C", "Dict A" }),
    "getCollectionDictNames keeps order, drops uninstalled members")
check(eq_list(rd:getCollectionDictNames("Empty"), {}),
    "getCollectionDictNames returns empty list for empty collection")
check(rd:getCollectionDictNames("Nope") == nil,
    "getCollectionDictNames returns nil for unknown collection")
check(rd:getCollectionDictNames(nil) == nil,
    "getCollectionDictNames returns nil for nil name")

-- Button registration: 3 collections + "All dictionaries" = 4 buttons in 2 rows
local ids = {}
for id, spec in pairs(rd._dict_buttons) do
    if id:match("^dict_collection_") then ids[#ids + 1] = id end
end
table.sort(ids)
check(eq_list(ids, { "dict_collection_01", "dict_collection_02", "dict_collection_03", "dict_collection_04" }),
    "one button per collection plus All dictionaries: " .. table.concat(ids, ", "))
local b1 = rd._dict_buttons["dict_collection_01"] -- "Empty" (sorted first)
local b2 = rd._dict_buttons["dict_collection_02"] -- "JP"
local b3 = rd._dict_buttons["dict_collection_03"] -- "Mono"
local b4 = rd._dict_buttons["dict_collection_04"] -- "All dictionaries"
check(b1.text == "Empty" and b2.text == "JP" and b3.text == "Mono" and b4.text == "All dictionaries",
    "buttons are sorted by collection name with All dictionaries last")
check(b1.conditional and b2.conditional and b3.conditional and b4.conditional,
    "buttons are transient (conditional)")
check(b1.row_group == b2.row_group and b2.row_group == b3.row_group and b4.row_group ~= b1.row_group,
    "rows chunked by 3: " .. b1.row_group .. " / " .. b4.row_group)

-- show_func behaviour
local popup_normal = { is_wiki = false, source_collection = nil }
local popup_from_jp = { is_wiki = false, source_collection = "JP" }
local popup_wiki = { is_wiki = true }
check(b2.show_func(popup_normal) and not b4.show_func(popup_normal),
    "normal popup: collection buttons shown, All dictionaries hidden")
check(not b2.show_func(popup_from_jp) and b3.show_func(popup_from_jp) and b4.show_func(popup_from_jp),
    "JP-restricted popup: JP hidden, others + All dictionaries shown")
check(not (b2.show_func(popup_wiki) or b4.show_func(popup_wiki)),
    "wiki popup: no collection buttons")

-- lookupWordInCollection plumbing: record stardictLookup invocations
local recorded
rd.stardictLookup = function(self, word, dict_names, fuzzy_search, boxes, link, dict_close_callback, opts)
    recorded = { word = word, dict_names = dict_names, fuzzy_search = fuzzy_search,
                 boxes = boxes, opts = opts or {} }
end

recorded, SHOWN = nil, {}
rd:lookupWordInCollection("食べる", true, { "box" }, nil, nil, nil, "JP")
check(recorded and recorded.word == "食べる", "collection lookup reaches stardictLookup")
check(recorded and eq_list(recorded.dict_names, { "Dict C", "Dict A" }),
    "collection lookup restricted to the collection's installed members, in order")
check(recorded and recorded.opts.skip_doc_disabled == true,
    "collection lookup overrides per-book disabled dicts")
check(recorded and recorded.opts.source_collection == "JP",
    "source collection threaded through for the result window")
check(recorded and recorded.opts.force_exact == false and recorded.fuzzy_search == true,
    "exact-match off: fuzzy behaviour unchanged")

settings_store["dict_collection_exact_search"] = true
recorded = nil
rd:lookupWordInCollection("食べる", true, nil, nil, nil, nil, "JP")
check(recorded and recorded.opts.force_exact == true and recorded.fuzzy_search == false,
    "exact-match on: force_exact set and fuzzy disabled")
settings_store["dict_collection_exact_search"] = nil

recorded, SHOWN = nil, {}
rd:lookupWordInCollection("言葉", true, nil, nil, nil, nil, "Empty")
check(recorded == nil, "empty collection: no lookup is run")
check(#SHOWN == 1 and SHOWN[1].__is_infomessage and SHOWN[1].text:match("Empty"),
    "empty collection: user is told the collection has no installed dictionaries")

recorded, SHOWN = nil, {}
rd.active_dict_collection = nil
rd:lookupWordInCollection("言葉", true, nil, nil, nil, nil, nil)
check(recorded and eq_list(recorded.dict_names, { "Dict A", "Dict B", "Dict C" })
    and recorded.opts.source_collection == nil,
    "no collection given or active: graceful fallback to a normal lookup")

rd.active_dict_collection = "Mono"
recorded = nil
rd:lookupWordInCollection("言葉", true, nil, nil, nil, nil, nil)
check(recorded and eq_list(recorded.dict_names, { "Dict B" })
    and recorded.opts.source_collection == "Mono",
    "no explicit collection: falls back to the active one")

-- Button callback: looks up the popup's displayed word in the collection
recorded = nil
b2.callback({ lookupword = "走る", word = "走った", word_boxes = { "wb" } })
check(recorded and recorded.word == "走る" and eq_list(recorded.dict_names, { "Dict C", "Dict A" })
    and recorded.boxes and recorded.boxes[1] == "wb",
    "collection button re-queries the displayed word in that collection")

-- "All dictionaries" callback: normal lookup with all enabled dicts
recorded = nil
b4.callback({ lookupword = "走る", word = "走った", word_boxes = nil, source_collection = "JP" })
check(recorded and recorded.word == "走る" and eq_list(recorded.dict_names, { "Dict A", "Dict B", "Dict C" })
    and recorded.opts.source_collection == nil,
    "All dictionaries button broadens back to a normal lookup")

-- Mutations re-register buttons (wipe + rebuild)
rd.dict_collections["Empty"] = nil
rd.dict_collections["Mono"] = nil
rd:saveCollections()
local count = 0
for id in pairs(rd._dict_buttons) do
    if id:match("^dict_collection_") then count = count + 1 end
end
check(count == 2 and rd._dict_buttons["dict_collection_01"].text == "JP"
    and rd._dict_buttons["dict_collection_02"].text == "All dictionaries",
    "deleting collections wipes and re-registers the buttons")

rd.dict_collections = {}
rd:saveCollections()
count = 0
for id in pairs(rd._dict_buttons) do
    if id:match("^dict_collection_") then count = count + 1 end
end
check(count == 0, "no collections: no buttons at all (not even All dictionaries)")

os.execute("rm -rf '" .. TMP .. "'")
print(failures == 0 and "\nALL TESTS PASSED" or ("\n" .. failures .. " TEST(S) FAILED"))
os.exit(failures == 0 and 0 or 1)
