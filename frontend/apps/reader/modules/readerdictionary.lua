local BD = require("ui/bidi")
local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local Device = require("device")
local DictQuickLookup = require("ui/widget/dictquicklookup")
local Event = require("ui/event")
local Geom = require("ui/geometry")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local InputDialog = require("ui/widget/inputdialog")
local JSON = require("json")
local KeyValuePage = require("ui/widget/keyvaluepage")
local LuaData = require("luadata")
local MultiConfirmBox = require("ui/widget/multiconfirmbox")
local NetworkMgr = require("ui/network/manager")
local Notification = require("ui/widget/notification")
local Presets = require("ui/presets")
local SortWidget = require("ui/widget/sortwidget")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local Utf8Proc = require("ffi/utf8proc")
local ffi = require("ffi")
local C = ffi.C
local ffiUtil  = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local time = require("ui/time")
local util  = require("util")
local _ = require("gettext")
local N_ = _.ngettext
local Input = Device.input
local T = ffiUtil.template
local android = Device:isAndroid() and require("android")

-- We'll store the list of available dictionaries as a module local
-- so we only have to look for them on the first :init()
local available_ifos = nil
local lookup_history = nil

local function getIfosInDir(path)
    -- Get all the .ifo under directory path.
    -- Don't walk into "res/" subdirectories, as per Stardict specs, they
    -- may contain possibly many resource files (image, audio files...)
    -- that could slow down our walk here.
    local ifos = {}
    local ok, iter, dir_obj = pcall(lfs.dir, path)
    if ok then
        for name in iter, dir_obj do
            if name ~= "." and name ~= ".." and name ~= "res" then
                local fullpath = path.."/"..name
                local attributes = lfs.attributes(fullpath)
                if attributes ~= nil then
                    if attributes.mode == "directory" then
                        local dirifos = getIfosInDir(fullpath) -- recurse
                        for _, ifo in pairs(dirifos) do
                            table.insert(ifos, ifo)
                        end
                    elseif fullpath:match("%.ifo$") then
                        table.insert(ifos, fullpath)
                    end
                end
            end
        end
    end
    return ifos
end

local ReaderDictionary = InputContainer:extend{
    data_dir = nil,
    lookup_msg = _("Searching dictionary for:\n%1"),
}

-- For a HTML dict, one can specify a specific stylesheet
-- in a file named as the .ifo with a .css extension
local function readDictionaryCss(path)
    local f = io.open(path, "r")
    if not f then
        return nil
    end

    local content = f:read("*all")
    f:close()
    return content
end

-- For a HTML dict, one can specify a function called on
-- the raw returned definition to "fix" the HTML if needed
-- (as MuPDF, used for rendering, is quite sensitive to the
-- HTML quality) in a file named as the .ifo with a .lua
-- extension, containing for example:
--    return function(html)
--        html = html:gsub("<hr>", "<hr/>")
--        return html
--    end
local function getDictionaryFixHtmlFunc(path)
    if lfs.attributes(path, "mode") == "file" then
        local ok, func = pcall(dofile, path)
        if ok and func then
            return func
        else
            logger.warn("Dict's user provided file failed:", func)
        end
    end
end

function ReaderDictionary:init()
    self._dict_buttons = {}
    self.disable_lookup_history = G_reader_settings:isTrue("disable_lookup_history")
    self.dicts_order = G_reader_settings:readSetting("dicts_order", {})
    self.dicts_disabled = G_reader_settings:readSetting("dicts_disabled", {})
    self.disable_fuzzy_search_fm = G_reader_settings:isTrue("disable_fuzzy_search")

    self.default_layout = {
        { "prev_dict", "highlight", "next_dict" },
        { "wikipedia",    "search",     "close" },
    }
    if Device:hasDPad() and Device:hasFewKeys() then
        table.insert(self.default_layout, 1, {"text_selection"})
    end

    if self.ui then
        self.ui.menu:registerToMainMenu(self)
    end
    self.data_dir = G_defaults:readSetting("STARDICT_DATA_DIR") or
        os.getenv("STARDICT_DATA_DIR") or
        DataStorage:getDataDir() .. "/data/dict"

    -- Show the "Searching..." InfoMessage after this delay
    self.lookup_msg_delay = 0.5
    -- Allow quick interruption or dismiss of search result window
    -- with tap if done before this delay. After this delay, the
    -- result window is shown and dismiss prevented for a few 100ms
    self.quick_dismiss_before_delay = time.s(3)

    -- Gather info about available dictionaries
    if not available_ifos then
        available_ifos = {}
        logger.dbg("Getting list of dictionaries")
        local ifo_files = getIfosInDir(self.data_dir)
        local dict_ext = self.data_dir.."_ext"
        if lfs.attributes(dict_ext, "mode") == "directory" then
            local extifos = getIfosInDir(dict_ext)
            for _, ifo in pairs(extifos) do
                table.insert(ifo_files, ifo)
            end
        end
        for _, ifo_file in pairs(ifo_files) do
            local f = io.open(ifo_file, "r")
            if f then
                local content = f:read("*all")
                f:close()
                local dictname = content:match("\nbookname=(.-)\r?\n")
                local is_html = content:find("sametypesequence=h", 1, true) ~= nil
                local lang_in, lang_out = content:match("lang=(%a+)-?(%a*)\r?\n?")
                -- sdcv won't use dict that don't have a bookname=
                if dictname then
                    table.insert(available_ifos, {
                        file = ifo_file,
                        name = dictname,
                        is_html = is_html,
                        css = readDictionaryCss(ifo_file:gsub("%.ifo$", ".css")),
                        fix_html_func = getDictionaryFixHtmlFunc(ifo_file:gsub("%.ifo$", ".lua")),
                        lang = lang_in and { lang_in = lang_in, lang_out = lang_out },
                    })
                end
            end
        end
        logger.dbg("found", #available_ifos, "dictionaries")
        self:sortAvailableIfos()
    end
    -- Prepare the -u options to give to sdcv the dictionary order and if some are disabled
    self:updateSdcvDictNamesOptions()

    if not lookup_history then
        lookup_history = LuaData:open(DataStorage:getSettingsDir() .. "/lookup_history.lua", "LookupHistory")
    end

    self.preset_obj = {
        presets = G_reader_settings:readSetting("dict_presets", {}),
        cycle_index = G_reader_settings:readSetting("dict_presets_cycle_index"),
        dispatcher_name = "load_dictionary_preset",
        saveCycleIndex = function(this)
            G_reader_settings:saveSetting("dict_presets_cycle_index", this.cycle_index)
        end,
        buildPreset = function() return self:buildPreset() end,
        loadPreset = function(preset) self:loadPreset(preset) end,
    }

    -- Dictionary collections: named bundles of dictionaries, each with its own
    -- ordered member list. When a collection is active, the matching gesture
    -- looks a word up using *only* that collection's dictionaries, in the
    -- collection's own order, as a true override: a member is searched
    -- regardless of its global enabled/disabled state or any per-book disable.
    -- A member is stored as an ordered array of dictionary names:
    --     dict_collections[name] = { "Dict A", "Dict C", "Dict B" }
    self.dict_collections = G_reader_settings:readSetting("dict_collections", {})
    self:migrateLegacyCollections()
    self.active_dict_collection = G_reader_settings:readSetting("dict_active_collection")
    if self.active_dict_collection and not self.dict_collections[self.active_dict_collection] then
        -- The active collection was deleted (or its settings got out of sync): drop it.
        self.active_dict_collection = nil
        G_reader_settings:delSetting("dict_active_collection")
    end
    self:refreshCollectionDictButtons()

    self:onDispatcherRegisterActions()
end

function ReaderDictionary:onDispatcherRegisterActions()
    -- Lazy require to avoid a circular dependency (dispatcher.lua requires us).
    local Dispatcher = require("dispatcher")
    -- category="arg" so the assigned gesture object (with its tap position) is
    -- passed to the event; ReaderHighlight:onLookupCollectionWord uses it to find
    -- the word under the gesture and look it up in the active collection.
    Dispatcher:registerAction("dictionary_collection_lookup",
        { category = "arg", event = "LookupCollectionWord", title = _("Look up word in dictionary collection"), general = true })
end

function ReaderDictionary:addToDictButtons(spec)
    if type(spec) ~= "table" or type(spec.id) ~= "string" then
        logger.warn("ReaderDictionary: addToDictButtons expects a table with a string 'id'")
        return
    end
    self._dict_buttons[spec.id] = spec
end

-- function ReaderDictionary:registerKeyEvents()
--     Now handled by hotkeys.koplugin:
--     onShowDictionaryLookup = { { "Alt", "D" }, { "Ctrl", "D" } }
-- end

function ReaderDictionary:sortAvailableIfos()
    table.sort(available_ifos, function(lifo, rifo)
        local lord = self.dicts_order[lifo.file]
        local rord = self.dicts_order[rifo.file]

        -- Both ifos without an explicit position -> lexical comparison
        if lord == rord then
            return ffiUtil.strcoll(lifo.name, rifo.name)
        end

        -- Ifos without an explicit position come last.
        return lord ~= nil and (rord == nil or lord < rord)
    end)
end


function ReaderDictionary:updateSdcvDictNamesOptions()
    -- We cannot tell sdcv which dictionaries to ignore, but we
    -- can tell it which dictionaries to use, by using multiple
    -- -u <dictname> options.
    -- The order of the -u options controls the dictionary order
    -- that sdcv uses to order its results.

    self.enabled_dict_names = {}

    -- First, insert any preferred dicts, even if globally disabled
    -- (this might allow enabling a dict only for a specific book,
    -- while keeping it disabled for all others)
    local preferred_names_already_in = {}
    if self.preferred_dictionaries then
        for _, name in ipairs(self.preferred_dictionaries) do
            table.insert(self.enabled_dict_names, name)
            preferred_names_already_in[name] = true
        end
    end

    local dicts_disabled = G_reader_settings:readSetting("dicts_disabled")
    for _, ifo in pairs(available_ifos) do
        if not dicts_disabled[ifo.file] and not preferred_names_already_in[ifo.name] then
            table.insert(self.enabled_dict_names, ifo.name)
        end
    end
end

-- Dictionary collections -------------------------------------------------------

function ReaderDictionary:saveCollections()
    -- Tables are saved by value, so re-save after any mutation.
    G_reader_settings:saveSetting("dict_collections", self.dict_collections)
    -- Any rename/delete/membership change must be reflected in the buttons
    -- the collections add to the dictionary window.
    self:refreshCollectionDictButtons()
end

-- Older builds stored each collection as a set ({ [name]=true }), which carries
-- no order. Convert any such collection to an ordered array (sorted by name, as
-- a stable starting point the user can then reorder in the editor).
function ReaderDictionary:migrateLegacyCollections()
    local migrated = false
    for name, members in pairs(self.dict_collections) do
        if type(members) == "table" and members[1] == nil and next(members) ~= nil then
            -- Non-empty table with no array part -> legacy set.
            local list = {}
            for dict_name in pairs(members) do
                table.insert(list, dict_name)
            end
            table.sort(list, function(a, b) return ffiUtil.strcoll(a, b) end)
            self.dict_collections[name] = list
            migrated = true
        end
    end
    if migrated then
        self:saveCollections()
    end
end

-- Rebuild the "Dictionary collections" submenu in place after a mutation.
-- TouchMenu:updateItems() only re-renders the current item_table; it does not
-- re-run sub_item_table_func, so the list (and the captured per-item counts)
-- would otherwise go stale. Regenerate the array first, like Presets does.
function ReaderDictionary:refreshCollectionsMenu(touchmenu_instance)
    if not touchmenu_instance then return end
    touchmenu_instance.item_table = self:genCollectionsMenuItemTable()
    touchmenu_instance:updateItems()
end

function ReaderDictionary:setActiveCollection(name)
    -- Pass nil to deactivate. Persisted, so it is remembered across restarts.
    self.active_dict_collection = name
    if name then
        G_reader_settings:saveSetting("dict_active_collection", name)
    else
        G_reader_settings:delSetting("dict_active_collection")
    end
end

--- Returns the ordered list of a collection's member dictionaries that are
-- still installed, or nil if no such collection exists. The returned list may
-- be empty (collection with no members, or none of them installed): that is a
-- distinct state from "no such collection" (no collection -> normal lookup;
-- empty -> look up nothing). Callers must check #dict_names to tell them apart.
-- The order is the collection's own saved order -- a true override of each
-- dictionary's global enabled/disabled state and of the global dictionary order.
function ReaderDictionary:getCollectionDictNames(collection_name)
    local members = collection_name and self.dict_collections[collection_name]
    if not members then
        return nil
    end
    local available_set = {}
    for _, ifo in ipairs(available_ifos) do
        available_set[ifo.name] = true
    end
    local dict_names = {}
    for _, dict_name in ipairs(members) do
        if available_set[dict_name] then
            table.insert(dict_names, dict_name)
        end
    end
    return dict_names
end

function ReaderDictionary:getSortedCollectionNames()
    local names = {}
    for name in pairs(self.dict_collections) do
        table.insert(names, name)
    end
    table.sort(names, function(a, b) return ffiUtil.strcoll(a, b) end)
    return names
end

function ReaderDictionary:toggleCollectionActive(name)
    if self.active_dict_collection == name then
        self:setActiveCollection(nil)
        Notification:notify(T(_("Dictionary collection deactivated: %1"), name))
    else
        self:setActiveCollection(name)
        Notification:notify(T(_("Dictionary collection activated: %1"), name))
    end
end

local DICT_COLLECTION_BUTTON_PREFIX = "dict_collection_"
local DICT_COLLECTION_BUTTONS_PER_ROW = 3

--- (Re)register one dictionary-window button per collection, so every
-- collection can be queried straight from the dictionary window: tapping a
-- collection's button looks the displayed word up again using only that
-- collection's dictionaries. A window whose results came from a collection
-- hides that collection's button and offers "All dictionaries" instead, to
-- broaden the lookup back out.
-- They are registered as transient ("conditional") buttons, appended below the
-- user's customizable button layout, so they are always available and never
-- saved into the layout settings. Called on init and after every collection
-- mutation (see :saveCollections).
function ReaderDictionary:refreshCollectionDictButtons()
    for id in pairs(self._dict_buttons) do
        if id:sub(1, #DICT_COLLECTION_BUTTON_PREFIX) == DICT_COLLECTION_BUTTON_PREFIX then
            self._dict_buttons[id] = nil
        end
    end
    local entries = {}
    for _, name in ipairs(self:getSortedCollectionNames()) do
        table.insert(entries, {
            text = name,
            show_func = function(dict_popup)
                -- Hide the collection the window's results came from:
                -- re-running the same restricted lookup would just reopen an
                -- identical window.
                return not dict_popup.is_wiki and dict_popup.source_collection ~= name
            end,
            callback = function(dict_popup)
                -- Look up the originally selected text (dict_popup.word), not
                -- the current result's headword (dict_popup.lookupword, which
                -- changes as you page through dictionaries).
                self:lookupWordInCollection(dict_popup.word or dict_popup.lookupword, true,
                    dict_popup.word_boxes, nil, nil, nil, name)
            end,
        })
    end
    if #entries == 0 then
        return -- no collections: keep the dictionary window unchanged
    end
    table.insert(entries, {
        text = _("All dictionaries"),
        show_func = function(dict_popup)
            -- Only useful as an escape hatch from a collection-restricted window.
            return not dict_popup.is_wiki and dict_popup.source_collection ~= nil
        end,
        callback = function(dict_popup)
            -- The originally selected text, not the current result's headword.
            self:onLookupWord(dict_popup.word or dict_popup.lookupword, true, dict_popup.word_boxes)
        end,
    })
    for i, entry in ipairs(entries) do
        local row = math.ceil(i / DICT_COLLECTION_BUTTONS_PER_ROW)
        self:addToDictButtons({
            -- Zero-padded so ffiUtil.orderedPairs keeps registration order.
            id = string.format("%s%02d", DICT_COLLECTION_BUTTON_PREFIX, i),
            text = entry.text,
            conditional = true,
            row_group = string.format("%srow_%02d", DICT_COLLECTION_BUTTON_PREFIX, row),
            show_func = entry.show_func,
            callback = entry.callback,
        })
    end
end

-- Builds the "Dictionary collections" submenu (under Dictionary settings).
function ReaderDictionary:genCollectionsMenuItemTable()
    local items = {}
    for _, name in ipairs(self:getSortedCollectionNames()) do
        local count = #self.dict_collections[name]
        items[#items + 1] = {
            text_func = function()
                return T(N_("%1 (%2 dictionary)", "%1 (%2 dictionaries)", count), name, count)
            end,
            checked_func = function()
                return self.active_dict_collection == name
            end,
            radio = true,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                self:toggleCollectionActive(name)
                if touchmenu_instance then touchmenu_instance:updateItems() end
            end,
            hold_callback = function(touchmenu_instance)
                self:showCollectionActionsDialog(name, touchmenu_instance)
            end,
        }
    end
    if #items > 0 then
        items[#items].separator = true
    end
    items[#items + 1] = {
        text = _("New collection"),
        keep_menu_open = true,
        callback = function(touchmenu_instance)
            self:promptNewCollection(touchmenu_instance)
        end,
        separator = true,
    }
    -- Per-feature search-mode toggle, independent of the main dictionary's fuzzy
    -- search option (see :lookupWordInCollection / :onLookupWord force_exact).
    items[#items + 1] = {
        text = _("Exact match only (no fuzzy results)"),
        help_text = _("When enabled, dictionary collection lookups return only exact (1-to-1) matches, with no fuzzy/approximate ('half') matches.\n\nThis applies to all collection lookups and is independent of the main dictionary's fuzzy search setting."),
        checked_func = function()
            return G_reader_settings:isTrue("dict_collection_exact_search")
        end,
        callback = function()
            G_reader_settings:flipNilOrFalse("dict_collection_exact_search")
        end,
    }
    return items
end

function ReaderDictionary:promptNewCollection(touchmenu_instance)
    local input_dialog
    input_dialog = InputDialog:new{
        title = _("New dictionary collection"),
        input = "",
        input_hint = _("Collection name"),
        buttons = {{
            {
                text = _("Cancel"),
                id = "close",
                callback = function() UIManager:close(input_dialog) end,
            },
            {
                text = _("Create"),
                is_enter_default = true,
                callback = function()
                    local name = util.trim(input_dialog:getInputText() or "")
                    if name == "" then return end
                    if self.dict_collections[name] then
                        UIManager:show(InfoMessage:new{
                            text = T(_("A collection named '%1' already exists."), name),
                        })
                        return
                    end
                    UIManager:close(input_dialog)
                    self.dict_collections[name] = {}
                    self:saveCollections()
                    -- Open the editor right away so the new collection gets members.
                    self:showCollectionEditor(name, function()
                        self:refreshCollectionsMenu(touchmenu_instance)
                    end)
                end,
            },
        }},
    }
    UIManager:show(input_dialog)
    input_dialog:onShowKeyboard()
end

function ReaderDictionary:promptRenameCollection(name, touchmenu_instance)
    local input_dialog
    input_dialog = InputDialog:new{
        title = _("Rename collection"),
        input = name,
        buttons = {{
            {
                text = _("Cancel"),
                id = "close",
                callback = function() UIManager:close(input_dialog) end,
            },
            {
                text = _("Rename"),
                is_enter_default = true,
                callback = function()
                    local new_name = util.trim(input_dialog:getInputText() or "")
                    if new_name == "" or new_name == name then
                        UIManager:close(input_dialog)
                        return
                    end
                    if self.dict_collections[new_name] then
                        UIManager:show(InfoMessage:new{
                            text = T(_("A collection named '%1' already exists."), new_name),
                        })
                        return
                    end
                    UIManager:close(input_dialog)
                    self.dict_collections[new_name] = self.dict_collections[name]
                    self.dict_collections[name] = nil
                    if self.active_dict_collection == name then
                        self:setActiveCollection(new_name)
                    end
                    self:saveCollections()
                    self:refreshCollectionsMenu(touchmenu_instance)
                end,
            },
        }},
    }
    UIManager:show(input_dialog)
    input_dialog:onShowKeyboard()
end

function ReaderDictionary:deleteCollection(name, touchmenu_instance)
    UIManager:show(ConfirmBox:new{
        text = T(_("Delete dictionary collection '%1'?"), name),
        ok_text = _("Delete"),
        ok_callback = function()
            self.dict_collections[name] = nil
            if self.active_dict_collection == name then
                self:setActiveCollection(nil)
            end
            self:saveCollections()
            self:refreshCollectionsMenu(touchmenu_instance)
        end,
    })
end

-- Pick and order the member dictionaries of a collection. The SortWidget lets
-- the user both toggle membership and arrange the order; that order is the
-- collection's own lookup priority (see :getCollectionDictNames).
function ReaderDictionary:showCollectionEditor(name, done_callback)
    local members = self.dict_collections[name] or {}
    local selected = {}
    for _, dict_name in ipairs(members) do
        selected[dict_name] = true
    end

    -- Show current members first (in their saved order), then the remaining
    -- installed dictionaries (in global order), so members can be reordered and
    -- non-members toggled in the same widget. Drop members no longer installed.
    local sort_items = {}
    local seen = {}
    local function addItem(dict_name)
        if seen[dict_name] then return end
        seen[dict_name] = true
        local item = { text = dict_name, dict_name = dict_name }
        item.callback = function()
            selected[item.dict_name] = (not selected[item.dict_name]) or nil
        end
        item.checked_func = function()
            return selected[item.dict_name] == true
        end
        table.insert(sort_items, item)
    end
    local available_set = {}
    for _, ifo in ipairs(available_ifos) do
        available_set[ifo.name] = true
    end
    for _, dict_name in ipairs(members) do
        if available_set[dict_name] then
            addItem(dict_name)
        end
    end
    for _, ifo in ipairs(available_ifos) do
        addItem(ifo.name)
    end

    local sort_widget = SortWidget:new{
        title = T(_("Dictionaries in collection: %1"), name),
        item_table = sort_items,
        callback = function()
            -- Persist the checked dictionaries in the user-arranged order.
            local new_members = {}
            for _, item in ipairs(sort_items) do
                if selected[item.dict_name] then
                    table.insert(new_members, item.dict_name)
                end
            end
            self.dict_collections[name] = new_members
            self:saveCollections()
            if done_callback then done_callback() end
        end,
    }
    UIManager:show(sort_widget)
end

function ReaderDictionary:showCollectionActionsDialog(name, touchmenu_instance)
    local dialog
    dialog = ButtonDialog:new{
        title = name,
        title_align = "center",
        shrink_unneeded_width = true,
        buttons = {
            {{
                text = _("Edit dictionaries"),
                callback = function()
                    UIManager:close(dialog)
                    self:showCollectionEditor(name, function()
                        self:refreshCollectionsMenu(touchmenu_instance)
                    end)
                end,
            }},
            {{
                text = _("Rename"),
                callback = function()
                    UIManager:close(dialog)
                    self:promptRenameCollection(name, touchmenu_instance)
                end,
            }},
            {{
                text = _("Delete"),
                callback = function()
                    UIManager:close(dialog)
                    self:deleteCollection(name, touchmenu_instance)
                end,
            }},
        },
    }
    UIManager:show(dialog)
end

-- Dispatcher action: quick picker to activate/deactivate a collection.
function ReaderDictionary:addToMainMenu(menu_items)
    local is_docless = self.ui == nil or self.ui.document == nil
    menu_items.search_settings = { -- submenu with Dict, Wiki, Translation settings
        text = _("Settings"),
    }
    menu_items.dictionary_lookup = {
        text = _("Dictionary lookup"),
        callback = function()
            self:onShowDictionaryLookup()
        end,
    }
    menu_items.dictionary_lookup_history = {
        text = _("Dictionary lookup history"),
        enabled_func = function()
            return lookup_history:has("lookup_history")
        end,
        callback = function()
            local lookup_history_table = lookup_history:readSetting("lookup_history")
            local kv_pairs = {}
            local previous_title
            for i = #lookup_history_table, 1, -1 do
                local value = lookup_history_table[i]
                if value.book_title ~= previous_title then
                    table.insert(kv_pairs, { value.book_title..":", "" })
                end
                previous_title = value.book_title
                table.insert(kv_pairs, {
                    os.date("%Y-%m-%d %H:%M:%S", value.time),
                    value.word,
                    callback = function()
                        -- Word had been cleaned before being added to history
                        self:onLookupWord(value.word, true)
                    end
                })
            end
            UIManager:show(KeyValuePage:new{
                title = _("Dictionary lookup history"),
                value_overflow_align = "right",
                kv_pairs = kv_pairs,
            })
        end,
    }
    menu_items.dictionary_settings = {
        text = _("Dictionary settings"),
        sub_item_table = {
            {
                keep_menu_open = true,
                text_func = function()
                    local nb_available, nb_enabled, nb_disabled = self:getNumberOfDictionaries()
                    local nb_str = nb_available
                    if nb_disabled > 0 then
                        nb_str = nb_enabled .. "/" .. nb_available
                    end
                    return T(_("Manage dictionaries: %1"), nb_str)
                end,
                enabled_func = function()
                    return self:getNumberOfDictionaries() > 0
                end,
                callback = function(touchmenu_instance)
                    self:showDictionariesMenu(function()
                        if touchmenu_instance then touchmenu_instance:updateItems() end
                    end)
                end,
            },
            {
                text = _("Dictionary presets"),
                help_text = _("This feature allows you to organize dictionaries into presets (for example, by language). You can quickly switch between these presets to change which dictionaries are used for lookups.\n\nNote: presets only store dictionaries, no other settings."),
                sub_item_table_func = function()
                    return Presets.genPresetMenuItemTable(self.preset_obj, _("Create new preset from enabled dictionaries"),
                        function() return self.enabled_dict_names and #self.enabled_dict_names > 0 end)
                end,
            },
            {
                text_func = function()
                    if self.active_dict_collection then
                        return T(_("Dictionary collections: %1"), self.active_dict_collection)
                    end
                    return _("Dictionary collections")
                end,
                help_text = _("Collections are named bundles of dictionaries, each with its own order. Each collection gets its own button in the dictionary lookup window: tapping it looks the word up again using only that collection's dictionaries, in the collection's own order. This is a true override: a collection's dictionaries are always searched, even ones disabled globally or disabled for the current book, and every other dictionary is suppressed. A normal long-press keeps looking up words in all enabled dictionaries, as usual.\n\nYou can also activate one collection here and assign the 'Look up word in dictionary collection' gesture in 'Taps and gestures' to look a word up in the active collection directly. Unlike presets, collections never change which dictionaries are enabled."),
                sub_item_table_func = function()
                    return self:genCollectionsMenuItemTable()
                end,
            },
            {
                text = _("Download dictionaries"),
                sub_item_table_func = function() return self:_genDownloadDictionariesMenu() end,
                separator = true,
            },
            {
                text_func = function()
                    local text = _("Enable fuzzy search")
                    if G_reader_settings:nilOrFalse("disable_fuzzy_search") then
                        text = text .. "   ★"
                    end
                    return text
                end,
                checked_func = function()
                    if self.ui.doc_settings then
                        return not self.disable_fuzzy_search
                    end
                    return not self.disable_fuzzy_search_fm
                end,
                callback = function()
                    if self.ui.doc_settings then
                        self.disable_fuzzy_search = not self.disable_fuzzy_search
                        self.ui.doc_settings:saveSetting("disable_fuzzy_search", self.disable_fuzzy_search)
                    else
                        self.disable_fuzzy_search_fm = not self.disable_fuzzy_search_fm
                    end
                end,
                hold_callback = function(touchmenu_instance)
                    self:toggleFuzzyDefault(touchmenu_instance)
                end,
                separator = true,
            },
            {
                text = _("Dictionary lookup history"),
                checked_func = function()
                    return not self.disable_lookup_history
                end,
                sub_item_table = {
                    {
                        text = _("Enable dictionary lookup history"),
                        checked_func = function()
                            return not self.disable_lookup_history
                        end,
                        callback = function()
                            self.disable_lookup_history = not self.disable_lookup_history
                            G_reader_settings:saveSetting("disable_lookup_history", self.disable_lookup_history)
                        end,
                    },
                    {
                        text = _("Clean dictionary lookup history"),
                        enabled_func = function()
                            return lookup_history:has("lookup_history")
                        end,
                        keep_menu_open = true,
                        callback = function(touchmenu_instance)
                            UIManager:show(ConfirmBox:new{
                                text = _("Clean dictionary lookup history?"),
                                ok_text = _("Clean"),
                                ok_callback = function()
                                    -- empty data table to replace current one
                                    lookup_history:reset{}
                                    touchmenu_instance:updateItems()
                                end,
                            })
                        end,
                    },
                },
                separator = true,
            },
            { -- setting used by dictquicklookup
                text = _("Large window"),
                checked_func = function()
                    return G_reader_settings:isTrue("dict_largewindow")
                end,
                callback = function()
                    G_reader_settings:flipNilOrFalse("dict_largewindow")
                end,
            },
            { -- setting used by dictquicklookup
                text = _("Justify text"),
                checked_func = function()
                    return G_reader_settings:nilOrTrue("dict_justify")
                end,
                callback = function()
                    G_reader_settings:flipNilOrTrue("dict_justify")
                end,
            },
            { -- setting used by dictquicklookup
                text_func = function()
                    local font_size = G_reader_settings:readSetting("dict_font_size") or 20
                    return T(_("Font size: %1"), font_size)
                end,
                callback = function(touchmenu_instance)
                    local SpinWidget = require("ui/widget/spinwidget")
                    local font_size = G_reader_settings:readSetting("dict_font_size") or 20
                    local items_font = SpinWidget:new{
                        value = font_size,
                        value_min = 8,
                        value_max = 32,
                        default_value = 20,
                        title_text = _("Dictionary font size"),
                        callback = function(spin)
                            G_reader_settings:saveSetting("dict_font_size", spin.value)
                            if touchmenu_instance then touchmenu_instance:updateItems() end
                        end,
                    }
                    UIManager:show(items_font)
                end,
                keep_menu_open = true,
            }
        }
    }
    table.insert(menu_items.dictionary_settings.sub_item_table, {
        text = _("Customize buttons"),
        sub_item_table_func = function()
            return self:_genCustomizeButtonsMenu()
        end,
    })
    if not is_docless then
        table.insert(menu_items.dictionary_settings.sub_item_table, 2, {
            keep_menu_open = true,
            text = _("Set dictionary priority for this book"),
            help_text = _("This feature enables you to specify dictionary priorities on a per-book basis. Results from higher-priority dictionaries will be displayed first when looking up words. Only dictionaries that are currently active can be selected and prioritized."),
            enabled_func = function()
                -- we allow to use preferred dictionaries even if no dictionaries are enabled globally (see self:updateSdcvDictNamesOptions)
                return #self.enabled_dict_names > 1 or #self.preferred_dictionaries > 0
            end,
            callback = function(touchmenu_instance)
                self:showPreferredDictsDialog(touchmenu_instance)
            end,
        })
    end
    if Device:canExternalDictLookup() then
        local function genExternalDictItems()
            local items_table = {}
            for i, v in ipairs(Device:getExternalDictLookupList()) do
                local setting = v[1]
                local dict_name = v[2]
                local is_enabled = v[3]
                table.insert(items_table, {
                    text = dict_name,
                    checked_func = function()
                        return setting == G_reader_settings:readSetting("external_dict_lookup_method")
                    end,
                    enabled_func = function()
                        return is_enabled == true
                    end,
                    callback = function()
                        G_reader_settings:saveSetting("external_dict_lookup_method", v[1])
                    end,
                })
            end
            return items_table
        end
        table.insert(menu_items.dictionary_settings.sub_item_table, 1, {
            text = _("Use external dictionary"),
            checked_func = function()
                return G_reader_settings:isTrue("external_dict_lookup")
            end,
            callback = function()
                G_reader_settings:flipNilOrFalse("external_dict_lookup")
            end,
        })
        table.insert(menu_items.dictionary_settings.sub_item_table, 2, {
            text_func = function()
                local display_name = _("none")
                local ext_id = G_reader_settings:readSetting("external_dict_lookup_method")
                for i, v in ipairs(Device:getExternalDictLookupList()) do
                    if v[1] == ext_id then
                        display_name = v[2]
                        break
                    end
                end
                return T(_("Dictionary: %1"), display_name)
            end,
            enabled_func = function()
                return G_reader_settings:isTrue("external_dict_lookup")
            end,
            sub_item_table = genExternalDictItems(),
            separator = true,
        })
    end
end

function ReaderDictionary:_genCustomizeButtonsMenu()
    local customize_buttons_menu = {}
    local available_options = {
        { text = _("Previous result"), id = "prev_dict" },
        { text = _("Highlight"),       id = "highlight" },
        { text = _("Next result"),     id = "next_dict" },
        { text = _("Wikipedia"),       id = "wikipedia" },
        { text = _("Search"),          id = "search" },
        { text = _("Close"),           id = "close" },
        { text = _("Translate"),       id = "translate" },
    }
    if Device:hasDPad() then
        table.insert(available_options, { text = _("Text selection"), id = "text_selection" })
    end

    for _, spec in ffiUtil.orderedPairs(self._dict_buttons) do
        if not spec.conditional and spec.menu_text then
            table.insert(available_options, { text = spec.menu_text, id = spec.id })
        end
        if not spec.conditional and not DictQuickLookup.layoutContainsButtonId(self.default_layout, spec.id) then
            local i = spec.insert_first and 1 or (#self.default_layout + 1)
            table.insert(self.default_layout, i, { spec.id })
        end
    end

    -- This function return the config from settings.
    local function getDictConfig()
        local config = util.tableDeepCopy(G_reader_settings:readSetting("dict_button_config"))
        if not config then
            config = {
                layout = self.default_layout,
                order = {},
                row_count = {}
            }
            for i = 1, #self.default_layout do
                config.row_count[i] = #self.default_layout[i]
            end
        end

        if #config.order == 0 then
            for _, row in ipairs(self.default_layout) do
                for _, id in ipairs(row) do
                    table.insert(config.order, id)
                end
            end
        end

        local in_order = {}
        for _, id in ipairs(config.order) do
            in_order[id] = true
        end
        for _, opt in ipairs(available_options) do
            if not in_order[opt.id] then
                table.insert(config.order, opt.id)
            end
        end

        return config
    end

    -- This helper regenerates the layout based on the given config, and saves it in settings.
    local function regenLayout(override_config, override_selected)
        local config = override_config or getDictConfig()

        local selected_ids = override_selected
        if not selected_ids then
            selected_ids = {}
            for _, row in ipairs(config.layout) do
                for _, id in ipairs(row) do
                    selected_ids[id] = true
                end
            end
        end

        local new_layout = {}
        local current_row = {}
        local row_idx = 1
        local max_in_row = config.row_count[row_idx] or 3

        for _, id in ipairs(config.order) do
            if selected_ids[id] then
                if #current_row >= max_in_row then
                    table.insert(new_layout, current_row)
                    current_row = {}
                    row_idx = row_idx + 1
                    max_in_row = config.row_count[row_idx] or 3
                end
                table.insert(current_row, id)
            end
        end
        if #current_row > 0 then
            table.insert(new_layout, current_row)
        end

        local new_row_count = {}
        for i = 1, #new_layout do
            new_row_count[i] = config.row_count[i] or 3
        end
        config.row_count = new_row_count

        config.layout = new_layout
        G_reader_settings:saveSetting("dict_button_config", config)
    end

    local rebuildRowMenu -- forward declaration for recursive use in genRowMenu
    -- This function generates dynamically the row submenu, according to the current config.
    local function genRowMenu()
        local config = getDictConfig()
        local layout_rows = config.layout
        for i = 1, #layout_rows do
            table.insert(customize_buttons_menu, {
                text_func = function()
                    return T(_("Max buttons in row %1: %2"), i, config.row_count[i] or 3)
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    local SpinWidget = require("ui/widget/spinwidget")
                    UIManager:show(SpinWidget:new{
                        value = config.row_count[i] or 3,
                        value_min = 1,
                        value_max = 4,
                        default_value = self.default_layout[i] and #self.default_layout[i] or 3,
                        title_text = T(_("Max buttons in row %1"), i),
                        callback = function(spin)
                            config.row_count[i] = spin.value
                            regenLayout(config)
                            rebuildRowMenu()
                            if touchmenu_instance then touchmenu_instance:updateItems() end
                        end,
                    })
                end,
                separator = i == #layout_rows,
            })
        end

        table.insert(customize_buttons_menu, {
            text = _("Test button layout"),
            keep_menu_open = true,
            callback = function()
                local preview_word = "lorem"
                local preview_definition = "Lorem ipsum dolor sit amet, consectetur adipiscing elit. " ..
                _("This is a mock definition used to preview dictionary button positions.") .. "\n\n" ..
                _("Tip: Place the Previous/Next buttons in the same row with two other buttons (4 total) to make them shrink and save space.")
                self:showDict(preview_word, {
                    {
                        dict = _("Layout preview"),
                        word = preview_word,
                        definition = preview_definition,
                    },
                })
            end,
        })
    end

    -- This rebuillds the row menu based on changes in the layout.
    local row_menu_start_idx = #customize_buttons_menu + 1
    function rebuildRowMenu()
        while #customize_buttons_menu >= row_menu_start_idx do
            table.remove(customize_buttons_menu)
        end
        genRowMenu()
    end

    table.insert(customize_buttons_menu, {
        text = _("Sort and toggle buttons"),
        keep_menu_open = true,
        separator = true,
        callback = function(touchmenu_instance)
            local config = getDictConfig()
            local selected_ids = {}
            for _, row in ipairs(config.layout) do
                for _, id in ipairs(row) do
                    selected_ids[id] = true
                end
            end

            local sort_items = {}
            local local_selected = util.tableDeepCopy(selected_ids)

            for _, id in ipairs(config.order) do
                for _, opt in ipairs(available_options) do
                    if opt.id == id then
                        table.insert(sort_items, {
                            text = opt.text,
                            id = opt.id,
                            checked_func = function() return local_selected[opt.id] end,
                            callback = function() local_selected[opt.id] = not local_selected[opt.id] end,
                        })
                        break
                    end
                end
            end

            UIManager:show(SortWidget:new{
                title = _("Sort and toggle buttons"),
                item_table = sort_items,
                callback = function()
                    local new_order = {}

                    for _, item in ipairs(sort_items) do
                        table.insert(new_order, item.id)
                    end

                    config.order = new_order
                    regenLayout(config, local_selected)
                    rebuildRowMenu()
                    if touchmenu_instance then touchmenu_instance:updateItems() end
                end
            })
        end,
        hold_callback = function(touchmenu_instance)
             UIManager:show(ConfirmBox:new{
                text = _("Would you like to reset the button layout?"),
                ok_text = _("Reset"),
                ok_callback = function()
                    G_reader_settings:delSetting("dict_button_config")
                    rebuildRowMenu()
                    if touchmenu_instance then touchmenu_instance:updateItems() end
                end,
             })
        end,
    })
    row_menu_start_idx = #customize_buttons_menu + 1
    genRowMenu()
    return customize_buttons_menu
end

function ReaderDictionary:showPreferredDictsDialog(touchmenu_instance)
    local dialog
    local buttons = {}
    local disabled_buttons = {}  -- store disabled dict buttons separately
    local update_sdcv = true

    local function saveAndRefresh()
        self:onSaveSettings()
        if update_sdcv then self:updateSdcvDictNamesOptions() end
        UIManager:close(dialog)
        if #self.enabled_dict_names == 0 then
            -- This is an edge case where we have a preferred dictionary but no globally enabled ones.
            -- If we un-prefer said dict, we would end up with an empty dialog, so close up shop and go home.
            touchmenu_instance:updateItems()
            return
        end
        self:showPreferredDictsDialog(touchmenu_instance)
    end

    local function makeButtonEntry(dict, is_enabled)
        local is_preferred = false
        local pref_num = 0
        for i, pref_dict in ipairs(self.preferred_dictionaries) do
            if pref_dict == dict then
                is_preferred = true
                pref_num = i
                break
            end
        end

        local button_text = dict
        if is_preferred and is_enabled then
            -- Add circled number (U+2460...2473) at start
            local symbol = util.unicodeCodepointToUtf8(0x245F + (pref_num < 20 and pref_num or 20))
            button_text = symbol .. " " .. button_text
        elseif not is_enabled then
            -- Add circled x (U+2297) at start for disabled dictionaries
            button_text = "⊗ " .. button_text
        end

        return {
            {
                align = "left",
                text = button_text,
                callback = function()
                    if not is_enabled then return end -- No toggle for disabled dicts
                    if is_preferred then
                        for i, pref_dict in ipairs(self.preferred_dictionaries) do
                            if pref_dict == dict then
                                table.remove(self.preferred_dictionaries, i)
                                break
                            end
                        end
                    else
                        table.insert(self.preferred_dictionaries, dict)
                    end
                    saveAndRefresh()
                end,
                hold_callback = function()
                    if not is_enabled then -- re-enable dictionary
                        self.doc_disabled_dicts[dict] = nil
                    else -- disable dictionary for this book
                        self.doc_disabled_dicts[dict] = true
                    end
                    update_sdcv = false
                    saveAndRefresh()
                end,
            }
        }
    end

    -- Process enabled dictionaries first.
    for _, dict in ipairs(self.enabled_dict_names) do
        if not self.doc_disabled_dicts[dict] then
            table.insert(buttons, makeButtonEntry(dict, true))
        else
            table.insert(disabled_buttons, makeButtonEntry(dict, false))
        end
    end

    -- Append disabled dictionaries at the bottom of the list.
    for _, btn in ipairs(disabled_buttons) do
        table.insert(buttons, btn)
    end

    table.insert(buttons, {
        {
            text = _("Reset"),
            callback = function()
                self.doc_disabled_dicts = {}
                self.preferred_dictionaries = {}
                saveAndRefresh()
            end,
        }
    })

    dialog = ButtonDialog:new{
        title = _("Select preferred dictionaries"),
        title_align = "center",
        shrink_unneeded_width = true,
        buttons = buttons,
    }
    UIManager:show(dialog)
end

-- opts (optional table) restricts/configures the lookup; used by collection
-- lookups (see :lookupWordInCollection). Supported fields:
--   dict_names: explicit, already-filtered list of dictionary names to search,
--     instead of all enabled ones.
--   skip_doc_disabled: don't apply the per-book "disabled for this book" list
--     to the dictionaries searched (collections are a true override of every
--     dictionary-suppression mechanism).
--   force_exact: force exact (1-to-1) matching, no fuzzy/approximate results,
--     regardless of the main fuzzy-search setting (used by the collection
--     "Exact match only" option, which is independent of it).
--   source_collection: name of the collection this lookup is restricted to;
--     passed through to the result window so its buttons can adapt.
function ReaderDictionary:onLookupWord(word, is_sane, boxes, highlight, link, dict_close_callback, opts)
    opts = opts or {}
    logger.dbg("dict lookup word:", word, boxes)
    -- escape quotes and other funny characters in word
    word = self:cleanSelection(word, is_sane)
    logger.dbg("dict stripped word:", word)
    -- (If word ends up empty, we still do the lookup, which will give us
    -- a window with no result. This will ensure the normal cleanup of the
    -- highlight when closing this "no result" window, which is easier than
    -- trying to do it here if we were skipping the lookup.)

    self.highlight = highlight
    local disable_fuzzy_search
    if opts.force_exact then
        -- Collection "Exact match only": override fuzzy regardless of the main
        -- per-document / file-manager fuzzy setting.
        disable_fuzzy_search = true
    elseif self.ui.doc_settings then
        disable_fuzzy_search = self.disable_fuzzy_search
    else
        disable_fuzzy_search = self.disable_fuzzy_search_fm
    end

    -- Default to all enabled dictionaries (normal long-press lookup). A caller
    -- such as a collection lookup may pass an explicit, already-filtered list
    -- of names to restrict the lookup instead.
    local dict_names = opts.dict_names or self.enabled_dict_names

    -- Wrapped through Trapper, as we may be using Trapper:dismissablePopen() in it
    Trapper:wrap(function()
        self:stardictLookup(word, dict_names, not disable_fuzzy_search, boxes, link, dict_close_callback, opts)
    end)
    return true
end

--- Look up a word using only the given dictionary collection (default: the
-- active one). The single restricted-lookup entry point, used by the
-- "Look up word in dictionary collection" gesture and by the per-collection
-- buttons in the dictionary window. skip_doc_disabled=true makes it a true
-- override: the collection's members are searched even if disabled globally or
-- for this book. With no such collection (e.g. none active), it gracefully
-- behaves like a normal lookup; with a collection that has no installed
-- members, it looks up nothing and tells the user why.
function ReaderDictionary:lookupWordInCollection(word, is_sane, boxes, highlight, link, dict_close_callback, collection_name)
    collection_name = collection_name or self.active_dict_collection
    local dict_names = self:getCollectionDictNames(collection_name)
    if not dict_names then
        return self:onLookupWord(word, is_sane, boxes, highlight, link, dict_close_callback)
    end
    if #dict_names == 0 then
        UIManager:show(InfoMessage:new{
            text = T(_("Dictionary collection '%1' has no installed dictionaries.\nAdd some in: Dictionary settings → Dictionary collections."), collection_name),
            timeout = 2,
        })
        return true
    end
    return self:onLookupWord(word, is_sane, boxes, highlight, link, dict_close_callback, {
        dict_names = dict_names,
        skip_doc_disabled = true,
        -- Independent of the main dictionary's fuzzy setting (see the "Exact
        -- match only" toggle in the Dictionary collections submenu).
        force_exact = G_reader_settings:isTrue("dict_collection_exact_search"),
        source_collection = collection_name,
    })
end

function ReaderDictionary:onHtmlDictionaryLinkTapped(dictionary, link)
    if not link.uri then
        return
    end

    -- The protocol is either "bword" or there is no protocol, only the word.
    -- https://github.com/koreader/koreader/issues/3588#issuecomment-357088125
    local url_prefix = "bword://"
    local word
    if link.uri:sub(1,url_prefix:len()) == url_prefix then
        word = link.uri:sub(url_prefix:len() + 1)
    elseif link.uri:find("://") then
        return
    else
        word = link.uri
    end

    if word == "" then
        return
    end

    local link_box = Geom:new{
        x = link.x0,
        y = link.y0,
        w = math.abs(link.x1 - link.x0),
        h = math.abs(link.y1 - link.y0),
    }

    -- Only the first dictionary window stores the highlight, this way the highlight
    -- is only removed when there are no more dictionary windows open.
    self.highlight = nil

    -- Wrapped through Trapper, as we may be using Trapper:dismissablePopen() in it
    Trapper:wrap(function()
        self:stardictLookup(word, {dictionary}, false, {link_box}, nil)
    end)
end

--- Gets number of available, enabled, and disabled dictionaries
-- @treturn int nb_available
-- @treturn int nb_enabled
-- @treturn int nb_disabled
function ReaderDictionary:getNumberOfDictionaries()
    local nb_available = #available_ifos
    local nb_enabled = 0
    local nb_disabled = 0
    for _, ifo in pairs(available_ifos) do
        if self.dicts_disabled[ifo.file] then
            nb_disabled = nb_disabled + 1
        else
            nb_enabled = nb_enabled + 1
        end
    end
    return nb_available, nb_enabled, nb_disabled
end

function ReaderDictionary:_genDownloadDictionariesMenu()
    local downloadable_dicts = require("ui/data/dictionaries")
    local IsoLanguage = require("ui/data/isolanguage")
    local languages = {}

    for i = 1, #downloadable_dicts do
        local dict = downloadable_dicts[i]
        if not dict.ifo_lang then
            -- this only needs to happen the first time this function is called
            local ifo_in = IsoLanguage:getBCPLanguageTag(dict.lang_in)
            local ifo_out = IsoLanguage:getBCPLanguageTag(dict.lang_out)
            dict.ifo_lang = ("%s-%s"):format(ifo_in, ifo_out)
            dict.lang_in = IsoLanguage:getLocalizedLanguage(dict.lang_in)
            dict.lang_out = IsoLanguage:getLocalizedLanguage(dict.lang_out)
        end
        local dict_lang_in = dict.lang_in
        local dict_lang_out = dict.lang_out
        if not languages[dict_lang_in] then
            languages[dict_lang_in] = {}
        end
        table.insert(languages[dict_lang_in], dict)
        if not languages[dict_lang_out] then
            languages[dict_lang_out] = {}
        end
        table.insert(languages[dict_lang_out], dict)
    end

    -- remove duplicates
    for lang_key,lang in pairs(languages) do
        local hash = {}
        local res = {}
        for k,v in ipairs(lang) do
           if not hash[v.name] then
               res[#res+1] = v
               hash[v.name] = true
           end
        end
        languages[lang_key] = res
    end

    local menu_items = {}
    for lang_key, available_langs in ffiUtil.orderedPairs(languages) do
        table.insert(menu_items, {
            keep_menu_open = true,
            text = lang_key,
            callback = function()
                self:showDownload(available_langs)
            end
        })
    end

    return menu_items
end

function ReaderDictionary:showDictionariesMenu(changed_callback)
    -- Work on local copy, save to settings only when SortWidget is closed with the accept button
    local dicts_disabled = util.tableDeepCopy(self.dicts_disabled)

    local sort_items = {}
    for _, ifo in pairs(available_ifos) do
        table.insert(sort_items, {
            text = ifo.name,
            callback = function()
                if dicts_disabled[ifo.file] then
                    dicts_disabled[ifo.file] = nil
                else
                    dicts_disabled[ifo.file] = true
                end
            end,
            checked_func = function()
                return not dicts_disabled[ifo.file]
            end,
            ifo = ifo,
        })
    end

    local sort_widget = SortWidget:new{
        title = _("Manage installed dictionaries"),
        item_table = sort_items,
        callback = function()
            -- Update both references to point to that new object
            self.dicts_disabled = dicts_disabled
            G_reader_settings:saveSetting("dicts_disabled", self.dicts_disabled)

            -- Write back the sorted items array to dicts_order
            local dicts_order = {}
            for i, sort_item in ipairs(sort_items) do
                dicts_order[sort_item.ifo.file] = i
            end
            self.dicts_order = dicts_order
            G_reader_settings:saveSetting("dicts_order", self.dicts_order)

            self:sortAvailableIfos()

            self:updateSdcvDictNamesOptions()

            UIManager:setDirty(nil, "ui")
            changed_callback()
        end
    }
    UIManager:show(sort_widget)
end

local function dictDirsEmpty(dict_dirs)
    for _, dict_dir in ipairs(dict_dirs) do
        if not util.isEmptyDir(dict_dir) then
            return false
        end
    end
    return true
end

local function getAvailableIfoByName(dictionary_name)
    for _, ifo in ipairs(available_ifos) do
        if ifo.name == dictionary_name then
            return ifo
        end
    end

    return nil
end

local function tidyMarkup(results)
    local cdata_tag = "<!%[CDATA%[(.-)%]%]>"
    local format_escape = "&[29Ib%+]{(.-)}"
    for _, result in ipairs(results) do
        local ifo = getAvailableIfoByName(result.dict)
        if ifo and ifo.lang then
            result.ifo_lang = ifo.lang
        end
        if ifo and ifo.is_html then
            local dict_path = util.splitFilePathName(ifo.file)
            result.is_html = ifo.is_html
            result.css = ifo.css
            if ifo.fix_html_func then
                local ok, fixed_definition = pcall(ifo.fix_html_func, result.definition, dict_path)
                if ok then
                    result.definition = fixed_definition
                else
                    logger.warn("Dict's user provided function failed:", fixed_definition)
                end
            end

            local res_dir = dict_path .. "res"
            if lfs.attributes(res_dir, "mode") == "directory" then
                result.dictionary_resource_directory = res_dir
            end
        else
            local def = result.definition
            -- preserve the <br> tag for line break
            def = def:gsub("<[bB][rR] ?/?>", "\n")
            -- parse CDATA text in XML
            if def:find(cdata_tag) then
                def = def:gsub(cdata_tag, "%1")
                -- ignore format strings
                while def:find(format_escape) do
                    def = def:gsub(format_escape, "%1")
                end
            end
            -- convert any htmlentities (&gt;, &quot;...)
            def = util.htmlEntitiesToUtf8(def)
            -- ignore all markup tags
            def = def:gsub("%b<>", "")
            -- strip all leading empty lines/spaces
            def = def:gsub("^%s+", "")
            result.definition = def
        end
    end
    return results
end

function ReaderDictionary:cleanSelection(text, is_sane)
    -- Will be used by ReaderWikipedia too
    if not text then
        return ""
    end
    -- crengine does now a much better job at finding word boundaries, but
    -- some cleanup is still needed for selection we get from other engines
    -- (example: pdf selection "qu’autrefois," will be cleaned to "autrefois")
    --
    -- Replace no-break space with regular space
    text = text:gsub("\u{00A0}", ' ')
    -- Trim any space at start or end
    text = text:gsub("^%s+", "")
    text = text:gsub("%s+$", "")
    if not is_sane then
        -- Replace extended quote (included in the general puncturation range)
        -- with plain ascii quote (for french words like "aujourd’hui")
        text = text:gsub("\u{2019}", "'") -- Right single quotation mark
        -- Strip punctuation characters around selection
        text = util.stripPunctuation(text)
        -- Note: although it seems innocuous to use a character class [·|↑] to perform a single gsub,
        --       doing so will cause byte corruption in some languages (e.g. Greek).
        -- In some dictionaries, both interpuncts and pipes are used to delimiter syllables.
        text = text:gsub("·", "") -- interpunct
        text = text:gsub("|", "") -- pipe
        text = text:gsub("↑", "") -- and up arrow, used in some dictionaries to indicate related words
        text = text:gsub("ˈ", "") -- primary stress mark, used in phonetic transcriptions to indicate a stressed syllable
        text = text:gsub("ˌ", "") -- secondary stress mark, used in phonetic transcriptions to indicate a weaker stressed syllable
        -- Strip some common english grammatical construct
        text = text:gsub("'s$", '') -- english possessive
        -- Strip some common french grammatical constructs
        text = text:gsub("^[LSDMNTlsdmnt]'", '') -- french l' s' t'...
        text = text:gsub("^[Qq][Uu]'", '') -- french qu'
        -- There may be a need to remove some (all?) diacritical marks
        -- https://en.wikipedia.org/wiki/Combining_character#Unicode_ranges
        -- see discussion at https://github.com/koreader/koreader/issues/1649
        -- Commented for now, will have to be checked by people who read
        -- languages and texts that use them.
        -- text = text:gsub("\204[\128-\191]", '') -- U+0300 to U+033F
        -- text = text:gsub("\205[\128-\175]", '') -- U+0340 to U+036F
        -- Trim any space now at start or end after above changes
        text = text:gsub("^%s+", "")
        text = text:gsub("%s+$", "")
    end
    return text
end

function ReaderDictionary:showLookupInfo(word, show_delay)
    local text = T(self.lookup_msg, word)
    self.lookup_progress_msg = InfoMessage:new{
        text = text,
        show_delay = show_delay,
    }
    UIManager:show(self.lookup_progress_msg)
end

function ReaderDictionary:dismissLookupInfo()
    if self.lookup_progress_msg then
        UIManager:close(self.lookup_progress_msg)
    end
    self.lookup_progress_msg = nil
end

function ReaderDictionary:onShowDictionaryLookup()
    local buttons = {}
    local preset_names = Presets.getPresets(self.preset_obj)
    if preset_names and #preset_names > 0 then
        table.insert(buttons, {
            {
                text = _("Search with preset"),
                callback = function()
                    local text = self.dictionary_lookup_dialog:getInputText()
                    if text == "" or text:match("^%s*$") then return end
                    self:showSearchWithPresetDialog(preset_names, self.dictionary_lookup_dialog, text)
                end,
            }
        })
    end

    table.insert(buttons, {
        {
            text = _("Cancel"),
            id = "close",
            callback = function()
                UIManager:close(self.dictionary_lookup_dialog)
            end,
        },
        {
            text = _("Search dictionary"),
            is_enter_default = true,
            callback = function()
                if self.dictionary_lookup_dialog:getInputText() == "" then return end
                UIManager:close(self.dictionary_lookup_dialog)
                -- Trust that input text does not need any cleaning (allows querying for "-suffix")
                self:onLookupWord(self.dictionary_lookup_dialog:getInputText(), true)
            end,
        },
    })

    self.dictionary_lookup_dialog = InputDialog:new{
        title = _("Enter a word or phrase to look up"),
        input = "",
        input_type = "text",
        buttons = buttons,
    }
    UIManager:show(self.dictionary_lookup_dialog)
    self.dictionary_lookup_dialog:onShowKeyboard()
    return true
end

function ReaderDictionary:showSearchWithPresetDialog(preset_names, input_dialog, word, boxes, link, dict_close_callback)
    if not preset_names then
        preset_names = Presets.getPresets(self.preset_obj)
    end
    local current_dict_state = self:buildPreset()
    local button_dialog, buttons = nil, {}
    for _, preset_name in ipairs(preset_names) do
        table.insert(buttons, {
            {
                align = "left",
                text = preset_name,
                callback = function()
                    self:loadPreset(self.preset_obj.presets[preset_name], true)
                    UIManager:close(button_dialog)
                    UIManager:close(input_dialog)
                    self:onLookupWord(word, true, boxes, self.highlight, link,
                        function()
                            self:loadPreset(current_dict_state, true)
                            if dict_close_callback then dict_close_callback() end
                        end
                    )
                end,
            }
        })
    end
    button_dialog = ButtonDialog:new{
        buttons = buttons,
        shrink_unneeded_width = true,
    }
    if input_dialog then input_dialog:onCloseKeyboard() end
    UIManager:show(button_dialog)
end

function ReaderDictionary:rawSdcv(words, dict_names, fuzzy_search, lookup_progress_msg)
    -- Allow for two sdcv calls : one in the classic data/dict, and
    -- another one in data/dict_ext if it exists
    -- We could put in data/dict_ext dictionaries with a great number of words
    -- but poor definitions as a fall back. If these were in data/dict,
    -- they would prevent fuzzy searches in other dictories with better
    -- definitions, and masks such results. This way, we can get both.
    local dict_dirs = {self.data_dir}
    local dict_ext = self.data_dir.."_ext"
    if lfs.attributes(dict_ext, "mode") == "directory" then
        table.insert(dict_dirs, dict_ext)
    end
    -- early exit if no dictionaries
    if dictDirsEmpty(dict_dirs) then
        return false, nil
    end
    local all_results = {}
    local lookup_cancelled = false
    for _, dict_dir in ipairs(dict_dirs) do
        if lookup_cancelled then
            break -- don't do any more lookup on additional dict_dirs
        end

        local args = {
            android and (android.nativeLibraryDir .. "/libsdcv.so") or "./sdcv",
            "--utf8-input",
            "--utf8-output",
            "--json-output",
            "--non-interactive",
            "--data-dir", dict_dir,
        }
        if not fuzzy_search then
            table.insert(args, "--exact-search")
        end
        if dict_names then
            for _, opt in pairs(dict_names) do
                table.insert(args, "-u")
                table.insert(args, opt)
            end
        end
        table.insert(args, "--") -- prevent words starting with a "-" to be interpreted as a sdcv option
        util.arrayAppend(args, words)

        local cmd = util.shell_escape(args)
        -- cmd = "sleep 7 ; " .. cmd     -- uncomment to simulate long lookup time

        -- Some sdcv lookups, when using fuzzy search with many dictionaries
        -- and a really bad selected text, can take up to 10 seconds.
        -- It is nice to be able to cancel it when noticing wrong text was
        -- selected.
        -- Because sdcv starts outputting its output only at the end when it has
        -- done its work, we can use Trapper:dismissablePopen() to cancel it as
        -- long as we are waiting for output.
        -- When fuzzy search is enabled, we have a lookup_progress_msg that can
        -- be used to catch a tap and trigger cancellation.
        -- When fuzzy search is disabled, we provide false instead so an
        -- invisible non-event-forwarding TrapWidget is used to catch a tap
        -- and trigger cancellation (invisible so there's no need for repaint
        -- and refresh with the usually fast non-fuzzy search lookups).
        -- We must ensure we will have some output to be readable (if no
        -- definition found, sdcv will output some message on stderr, and
        -- let stdout empty) by appending an "echo":
        cmd = cmd .. "; echo"
        -- NOTE: Bionic doesn't support rpath, but does honor LD_LIBRARY_PATH...
        --       Give it a shove so it can actually find the STL.
        if android then
            C.setenv("LD_LIBRARY_PATH", android.nativeLibraryDir, 1)
        end
        local completed, results_str = Trapper:dismissablePopen(cmd, lookup_progress_msg)
        if android then
            -- NOTE: It's unset by default, so this is perfectly fine.
            C.unsetenv("LD_LIBRARY_PATH")
        end
        lookup_cancelled = not completed
        if results_str and results_str ~= "\n" then -- \n is when lookup was cancelled
            -- sdcv can return multiple results if we passed multiple words to
            -- the cmdline. In this case, the lookup results for each word are
            -- newline separated. The JSON output doesn't contain raw newlines
            -- so it's safe to split. Ideally luajson would support jsonl but
            -- unfortunately it doesn't and it also seems to decode the last
            -- object rather than the first one if there are multiple.
            local result_word_idx = 0
            for _, entry_str in ipairs(util.splitToArray(results_str, "\n")) do
                result_word_idx = result_word_idx + 1
                local ok, results = pcall(JSON.decode, entry_str)
                if not ok or not results then
                    logger.warn("JSON data cannot be decoded", results)
                    -- Need to insert an empty table so that the word entries
                    -- match up to the result entries (so that callers can
                    -- batch lookups to reduce the cost of bulk lookups while
                    -- still being able to figure out which lookup came from
                    -- which word).
                    results = {}
                end
                if all_results[result_word_idx] then
                    util.arrayAppend(all_results[result_word_idx], results)
                else
                    table.insert(all_results, results)
                end
            end
            if result_word_idx ~= #words then
                logger.warn("sdcv returned a different number of results than the number of words")
            end
        end
    end
    return lookup_cancelled, all_results
end

function ReaderDictionary:startSdcv(word, dict_names, fuzzy_search, force_exact)
    local words = {word}
    -- If a word starts with a capital letter, add lowercase version to words array.
    if not fuzzy_search then
        local lowercased = Utf8Proc.lowercase(word, false)
        if word ~= lowercased then
            table.insert(words, lowercased)
        end
    end

    -- force_exact (collection "Exact match only") wants strict 1-to-1 matches, so
    -- skip the language plugins' deinflected/alternative form candidates -- those
    -- are what turn e.g. "shimasu" into extra hits for "suru"/"su". (The
    -- lowercase variant above is kept: it is still a 1-to-1 match of the same
    -- word, and dropping it would make capitalized selections miss real entries.)
    if not force_exact and self.ui.languagesupport and self.ui.languagesupport:hasActiveLanguagePlugins() then
        -- Get any other candidates from any language-specific plugins we have.
        -- We prefer the originally selected word first (in case there is a
        -- dictionary entry for whatever text the user selected).
        local candidates = self.ui.languagesupport:extraDictionaryFormCandidates(word)
        if candidates then
            util.arrayAppend(words, candidates)
        end
    end

    -- If every word contains a CJK character, every word candidate is
    -- (probably) a CJK word. We don't want fuzzy searching in this case
    -- because sdcv cannot handle CJK text properly when fuzzy searching (with
    -- Japanese, it returns hundreds of useless results).
    local shouldnt_fuzzy_search = true
    for _, w in ipairs(words) do
        if not util.hasCJKChar(w) then
            shouldnt_fuzzy_search = false
            break
        end
    end
    if shouldnt_fuzzy_search then
        logger.dbg("disabling fuzzy searching for all-CJK word search:", words)
        fuzzy_search = false
    end

    local lookup_cancelled, results = self:rawSdcv(words, dict_names, fuzzy_search, self.lookup_progress_msg or false)
    if results == nil then -- no dictionaries found
        return {
            {
                dict = "",
                word = word,
                definition = _([[No dictionaries installed. Please search for "Dictionary support" in the KOReader Wiki to get more information about installing new dictionaries.]]),
            }
        }
    else -- flatten any possible results
        local flat_results = {}
        local seen_results = {}
        -- Flatten the array, removing any duplicates we may have gotten (sdcv
        -- may do multiple queries, in fixed mode then in fuzzy mode, and the
        -- language-specific plugin may have also returned multiple equivalent
        -- results).
        local h
        for _, term_results in ipairs(results) do
            for _, r in ipairs(term_results) do
                h = r.dict .. r.word .. r.definition
                if seen_results[h] == nil then
                    table.insert(flat_results, r)
                    seen_results[h] = true
                end
            end
        end
        results = flat_results
    end
    if #results == 0 then -- no results found
        -- dummy results
        results = {
            {
                dict = _("Not available"),
                word = word,
                definition = lookup_cancelled and _("Dictionary lookup interrupted.") or _("No results."),
                no_result = true,
                lookup_cancelled = lookup_cancelled,
            }
        }
    end
    if lookup_cancelled then
        -- Also put this as a k/v into the results array: when using dict_ext,
        -- we may get results from the 1st lookup, and have interrupted the 2nd.
        results.lookup_cancelled = true
    end
    return results
end

-- opts: see ReaderDictionary:onLookupWord (skip_doc_disabled, force_exact,
-- source_collection are used here; dict_names was already resolved by then).
function ReaderDictionary:stardictLookup(word, dict_names, fuzzy_search, boxes, link, dict_close_callback, opts)
    opts = opts or {}
    local book_title = self.ui.doc_props and self.ui.doc_props.display_title or _("Dictionary lookup")

    -- Event for plugin to catch lookup with book title
    self.ui:handleEvent(Event:new("WordLookedUp", word, book_title))
    if not self.disable_lookup_history then
        lookup_history:addTableItem("lookup_history", {
            book_title = book_title,
            time = os.time(),
            word = word,
        })
    end

    if Device:canExternalDictLookup() and G_reader_settings:isTrue("external_dict_lookup") then
        Device:doExternalDictLookup(word, G_reader_settings:readSetting("external_dict_lookup_method"), function()
            if self.highlight then
                local clear_id = self.highlight:getClearId()
                UIManager:scheduleIn(G_defaults:readSetting("DELAY_CLEAR_HIGHLIGHT_S"), function()
                    self.highlight:clear(clear_id)
                end)
            end

            if dict_close_callback then
                dict_close_callback()
            end
        end)
        return
    end

    -- Before starting the search, remove any dictionaries that were disabled for
    -- *this* book. Collection lookups pass skip_doc_disabled to bypass this, so a
    -- collection is a true override of the per-book disable too.
    if dict_names and not opts.skip_doc_disabled and self.doc_disabled_dicts then
        local filtered_names = {}
        for _, name in ipairs(dict_names) do
            if not self.doc_disabled_dicts[name] then
                table.insert(filtered_names, name)
            end
        end
        dict_names = filtered_names
    end

    -- If the user disabled all the dictionaries, go away.
    if dict_names and #dict_names == 0 then
        -- Dummy result
        local nope = {
            {
                dict = _("Not available"),
                word = word,
                definition = _("There are no enabled dictionaries.\nPlease check the 'Dictionary settings' menu."),
                no_result = true,
                lookup_cancelled = false,
            }
        }
        self:showDict(word, nope, boxes, link, dict_close_callback, opts.source_collection)
        return
    end

    self:showLookupInfo(word, self.lookup_msg_delay)

    self._lookup_start_time = UIManager:getTime()
    local results = self:startSdcv(word, dict_names, fuzzy_search, opts.force_exact)
    local function lookupCancelled()
        if self.highlight then
            self.highlight:clear()
        end
        if dict_close_callback then
            dict_close_callback()
        end
    end
    if results and results.lookup_cancelled
        and (time.now() - self._lookup_start_time) <= self.quick_dismiss_before_delay then
        -- If interrupted quickly just after launch, don't display anything
        -- (this might help avoiding refreshes and the need to dismiss
        -- after accidental long-press when holding a device).
        lookupCancelled()
        return
    end
    -- Intercept "No results" to offer alternative search methods (e.g., fuzzy search to non-fussy people)
    if results and results[1].no_result then
        local handled = self:showNoResultsDialog(word, dict_names, fuzzy_search, boxes, link, dict_close_callback, lookupCancelled, opts)
        if handled then return end
    end

    self:showDict(word, tidyMarkup(results), boxes, link, dict_close_callback, opts.source_collection)
end

function ReaderDictionary:showDict(word, results, boxes, link, dict_close_callback, source_collection)
    if results and results[1] then
        logger.dbg("showing quick lookup window", #DictQuickLookup.window_list+1, ":", word, results)
        self.dict_window = DictQuickLookup:new{
            ui = self.ui,
            highlight = self.highlight,
            dialog = self.dialog,
            -- original lookup word
            word = word,
            -- selected link, if any
            selected_link = link,
            results = results,
            word_boxes = boxes,
            preferred_dictionaries = self.preferred_dictionaries,
            -- differentiate between dict and wiki
            is_wiki = self.is_wiki,
            -- collection the lookup was restricted to, if any
            source_collection = source_collection,
            refresh_callback = function()
                if self.view then
                    -- update info in footer (time, battery, etc)
                    self.view.footer:onUpdateFooter()
                end
            end,
            html_dictionary_link_tapped_callback = function(dictionary, html_link)
                self:onHtmlDictionaryLinkTapped(dictionary, html_link)
            end,
            dict_close_callback = dict_close_callback,
        }
        if self.lookup_progress_msg then
            -- If we have a lookup InfoMessage that ended up being displayed, make
            -- it *not* refresh on close if it is hidden by our DictQuickLookup
            -- to avoid refreshes competition and possible glitches
            local msg_dimen = self.lookup_progress_msg:getVisibleArea()
            if msg_dimen then -- not invisible
                local dict_dimen = self.dict_window:getInitialVisibleArea()
                if dict_dimen and dict_dimen:contains(msg_dimen) then
                    self.lookup_progress_msg.no_refresh_on_close = true
                end
            end
        end
    end

    self:dismissLookupInfo()
    if results and results[1] then
        UIManager:show(self.dict_window)
        if not results.lookup_cancelled and self._lookup_start_time
            and (time.now() - self._lookup_start_time) > self.quick_dismiss_before_delay then
            -- If the search took more than a few seconds to be done, discard
            -- queued and upcoming input events to avoid a voluntary dismissal
            -- (because the user felt the result would not come) to kill the
            -- result that finally came and is about to be displayed
            Input:inhibitInputUntil(true)
        end
    end
end

function ReaderDictionary:showNoResultsDialog(word, dict_names, fuzzy_search, boxes, link, dict_close_callback, lookupCancelled, opts)
    self:dismissLookupInfo() -- Close the "Searching..." message
    -- Keep any collection restriction on retries, but not force_exact: the
    -- whole point of the retry is the user explicitly asking for fuzzy results.
    local retry_opts = opts and {
        skip_doc_disabled = opts.skip_doc_disabled,
        source_collection = opts.source_collection,
    } or nil
    local preset_names = Presets.getPresets(self.preset_obj)
    local has_presets = preset_names and #preset_names > 0
    if fuzzy_search and not has_presets then return false end -- fall through to showing empty results

    local preset_button = has_presets and {
        text = _("Search with preset"),
        callback = function(dialog)
            local new_word = dialog:getInputText()
            if new_word == "" or new_word:match("^%s*$") then return end
            self:showSearchWithPresetDialog(preset_names, dialog, new_word, boxes, link, dict_close_callback)
        end,
    } or nil

    -- Determine the primary action based on what's available
    local description, primary_action
    if not fuzzy_search then
        description = _("Would you like to use fuzzy search?")
        primary_action = {
            text = _("Fuzzy search"),
            is_enter_default = true,
            callback = function(dialog)
                local new_word = dialog:getInputText()
                if new_word == "" then return end
                UIManager:close(dialog)
                -- Re-run the lookup with the (possibly edited) word and fuzzy enabled.
                self:stardictLookup(new_word, dict_names, true, boxes, link, dict_close_callback, retry_opts)
            end,
        }
    elseif has_presets then
        description = _("Would you like to search with a preset?")
        primary_action = preset_button
        primary_action.is_enter_default = true
    end

    local buttons = {}
    -- Add preset button as an additional option (when fuzzy is the primary action)
    if not fuzzy_search and has_presets then
        table.insert(buttons, { preset_button })
    end
    table.insert(buttons, {
        {
            text = _("Cancel"),
            id = "close",
            callback = function(dialog)
                UIManager:close(dialog)
                UIManager:scheduleIn(G_defaults:readSetting("DELAY_CLEAR_HIGHLIGHT_S"), function() lookupCancelled() end)
            end,
        },
        primary_action,
    })
    local dialog
    dialog = InputDialog:new{
        title = _("No results found"),
        input = word, -- Pre-fills the dialog with the selected word
        input_type = "text",
        description = description,
        buttons = buttons,
    }

    -- Wire up callbacks with the dialog instance
    for _, row in ipairs(buttons) do
        for _, button in ipairs(row) do
            if button.callback then
                local original_callback = button.callback
                button.callback = function()
                    original_callback(dialog)
                end
            end
        end
    end
    UIManager:show(dialog)
    dialog:onShowKeyboard()
    return true
end

function ReaderDictionary:showDownload(downloadable_dicts)
    local kv_pairs = {}
    for dummy, dict in ipairs(downloadable_dicts) do
        table.insert(kv_pairs, {dict.name, "",
            callback = function()
                local connect_callback = function()
                    self:downloadDictionaryPrep(dict)
                end
                NetworkMgr:runWhenOnline(connect_callback)
            end})
        local lang
        if dict.lang_in == dict.lang_out then
            lang = string.format("    %s", dict.lang_in)
        else
            lang = string.format("    %s–%s", dict.lang_in, dict.lang_out)
        end
        table.insert(kv_pairs, {lang, ""})
        table.insert(kv_pairs, {"    ".._("License"), dict.license})
        table.insert(kv_pairs, {"    ".._("Entries"), dict.entries, separator = true})
    end
    self.download_window = KeyValuePage:new{
        title = _("Tap dictionary name to download"),
        kv_pairs = kv_pairs,
    }
    UIManager:show(self.download_window)
end

function ReaderDictionary:downloadDictionaryPrep(dict, size)
    local dummy, filename = util.splitFilePathName(dict.url)
    local download_location = string.format("%s/%s", self.data_dir, filename)

    if lfs.attributes(download_location) then
        UIManager:show(ConfirmBox:new{
            text =  _("File already exists. Overwrite?"),
            ok_text =  _("Overwrite"),
            ok_callback = function()
                self:downloadDictionary(dict, download_location)
            end,
        })
    else
        self:downloadDictionary(dict, download_location)
    end
end

function ReaderDictionary:downloadDictionary(dict, download_location, continue)
    continue = continue or false
    local socket = require("socket")
    local socketutil = require("socketutil")
    local http = socket.http
    local ltn12 = require("ltn12")

    if not continue then
        local file_size
        -- Skip body & code args
        socketutil:set_timeout()
        local headers = socket.skip(2, http.request{
            method  = "HEAD",
            url     = dict.url,
            --redirect = true,
        })
        socketutil:reset_timeout()
        --logger.dbg(headers)
        file_size = headers and headers["content-length"]

        if file_size then
            UIManager:show(ConfirmBox:new{
                text =  T(_("Dictionary filesize is %1 (%2 bytes). Continue with download?"), util.getFriendlySize(file_size), util.getFormattedSize(file_size)),
                ok_text =  _("Download"),
                ok_callback = function()
                    -- call ourselves with continue = true
                    self:downloadDictionary(dict, download_location, true)
                end,
            })
            return
        else
            logger.dbg("ReaderDictionary: Request failed; response headers:", headers)
            UIManager:show(InfoMessage:new{
                text = _("Failed to fetch dictionary. Are you online?"),
                --timeout = 3,
            })
            return false
        end
    else
        UIManager:nextTick(function()
            UIManager:show(InfoMessage:new{
                text = _("Downloading…"),
                timeout = 3,
            })
        end)
    end

    socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
    local code, headers, status = socket.skip(1, http.request{
        url     = dict.url,
        sink    = ltn12.sink.file(io.open(download_location, "w")),
    })
    socketutil:reset_timeout()
    if code == 200 then
        logger.dbg("file downloaded to", download_location)
    else
        logger.dbg("ReaderDictionary: Request failed:", status or code)
        logger.dbg("ReaderDictionary: Response headers:", headers)
        UIManager:show(InfoMessage:new{
            text = _("Could not save file to:\n") .. BD.filepath(download_location),
            --timeout = 3,
        })
        return false
    end

    -- stable target directory is needed so we can look through the folder later
    local dict_path = self.data_dir .. "/" .. dict.name
    util.makePath(dict_path)
    local ok, error = Device:unpackArchive(download_location, dict_path, true)

    if ok then
        if dict.ifo_lang then
            self:extendIfoWithLanguage(dict_path, dict.ifo_lang)
        end
        available_ifos = false
        self:init()
        UIManager:show(InfoMessage:new{
            text = _("Dictionary downloaded:\n") .. dict.name,
        })
        return true
    else
        UIManager:show(InfoMessage:new{
            text = _("Dictionary failed to download:\n") .. string.format("%s\n%s", dict.name, error),
        })
        return false
    end
end

function ReaderDictionary:extendIfoWithLanguage(dictionary_location, ifo_lang)
    local function cb(path, filename)
        if util.getFileNameSuffix(filename) == "ifo" then
            local fmt_string = "lang=%s"
            local f = io.open(path, "a+")
            if f then
                local ifo = f:read("a*")
                if ifo[#ifo] ~= "\n" then
                    fmt_string = "\n" .. fmt_string
                end
                f:write(fmt_string:format(ifo_lang))
                f:close()
            end
        end
    end
    util.findFiles(dictionary_location, cb)
end

function ReaderDictionary:onReadSettings(config)
    self.preferred_dictionaries = config:readSetting("preferred_dictionaries") or {}
    if #self.preferred_dictionaries == 0 then
        -- Legacy setting, when only one dict could be set as default/first to show
        local default_dictionary = config:readSetting("default_dictionary")
        if default_dictionary then
            table.insert(self.preferred_dictionaries, default_dictionary)
            config:delSetting("default_dictionary")
        end
    end
    if #self.preferred_dictionaries > 0 then
        self:updateSdcvDictNamesOptions()
    end
    if config:has("disable_fuzzy_search") then
        self.disable_fuzzy_search = config:isTrue("disable_fuzzy_search")
    else
        self.disable_fuzzy_search = G_reader_settings:isTrue("disable_fuzzy_search")
    end
    -- Disabled dictionary list for this book
    self.doc_disabled_dicts = config:readSetting("disabled_dicts") or {}
end

function ReaderDictionary:onSaveSettings()
    if self.ui.doc_settings then
        self.ui.doc_settings:saveSetting("preferred_dictionaries", next(self.preferred_dictionaries) and self.preferred_dictionaries or nil)
        self.ui.doc_settings:saveSetting("disabled_dicts", next(self.doc_disabled_dicts) and self.doc_disabled_dicts or nil)
    end
end

function ReaderDictionary:onTogglePreferredDict(dict)
    if not self.preferred_dictionaries then
        -- Invoked from FileManager: no preferred dict to manage
        return true
    end
    local removed = false
    for idx, name in ipairs(self.preferred_dictionaries) do
        if dict == name then
            removed = true
            table.remove(self.preferred_dictionaries, idx)
            break
        end
    end
    if not removed then -- insert it as first
        table.insert(self.preferred_dictionaries, 1, dict)
    end
    UIManager:show(InfoMessage:new{
        text = removed and T(_("%1 is no longer a preferred dictionary for this document."), dict)
                        or T(_("%1 is now the preferred dictionary for this document."), dict),
        timeout = 2,
    })
    self:updateSdcvDictNamesOptions()
    return true
end

function ReaderDictionary:toggleFuzzyDefault(touchmenu_instance)
    local disable_fuzzy_search = G_reader_settings:isTrue("disable_fuzzy_search")
    UIManager:show(MultiConfirmBox:new{
        text = T(
            disable_fuzzy_search
            and _([[
Would you like to enable or disable fuzzy search by default?

Fuzzy search can match epuisante, épuisante and épuisantes to épuisant, even if only the latter has an entry in the dictionary. It can be disabled to improve performance, but it might be worthwhile to look into disabling unneeded dictionaries before disabling fuzzy search.

The current default (★) is disabled.]])
            or _([[
Would you like to enable or disable fuzzy search by default?

Fuzzy search can match epuisante, épuisante and épuisantes to épuisant, even if only the latter has an entry in the dictionary. It can be disabled to improve performance, but it might be worthwhile to look into disabling unneeded dictionaries before disabling fuzzy search.

The current default (★) is enabled.]])
        ),
        choice1_text_func =  function()
            return disable_fuzzy_search and _("Disable (★)") or _("Disable")
        end,
        choice1_callback = function()
            G_reader_settings:makeTrue("disable_fuzzy_search")
            touchmenu_instance:updateItems()
        end,
        choice2_text_func = function()
            return disable_fuzzy_search and _("Enable") or _("Enable (★)")
        end,
        choice2_callback = function()
            G_reader_settings:makeFalse("disable_fuzzy_search")
            touchmenu_instance:updateItems()
        end,
    })
end

function ReaderDictionary:buildPreset()
    local preset = { enabled_dict_names = {} } -- Only store the names of enabled dictionaries.
    for _, name in ipairs(self.enabled_dict_names) do
        preset.enabled_dict_names[name] = true
    end
    return preset
end

function ReaderDictionary:loadPreset(preset, skip_notification)
    if not preset.enabled_dict_names then return end
    -- build a list of currently available dictionary names for validation
    local available_dict_names = {}
    for _, ifo in ipairs(available_ifos) do
        available_dict_names[ifo.name] = true
    end
    -- Only enable dictionaries from the preset that are still available, and re-build self.dicts_disabled
    -- to make sure dicts added after the creation of the preset, are disabled as well.
    local dicts_disabled, valid_enabled_names = {}, {}
    for _, ifo in ipairs(available_ifos) do
        if preset.enabled_dict_names[ifo.name] then
            table.insert(valid_enabled_names, ifo.name)
        else
            dicts_disabled[ifo.file] = true
        end
    end
    -- update both settings and save
    self.dicts_disabled = dicts_disabled
    self.enabled_dict_names = valid_enabled_names
    G_reader_settings:saveSetting("dicts_disabled", self.dicts_disabled)
    self:onSaveSettings()
    self:updateSdcvDictNamesOptions()
    -- Show a message if any dictionaries from the preset are missing.
    if not skip_notification and util.tableSize(preset.enabled_dict_names) > #valid_enabled_names then
        local missing_dicts = {}
        for preset_name, _ in pairs(preset.enabled_dict_names) do
            if not available_dict_names[preset_name] then
                table.insert(missing_dicts, preset_name)
            end
        end
        UIManager:show(InfoMessage:new{
            text = _("Some dictionaries from this preset have been deleted or are no longer available:") .. "\n\n• " .. table.concat(missing_dicts, "\n• "),
        })
    end
end

function ReaderDictionary:onCycleDictionaryPresets()
    return Presets.cycleThroughPresets(self.preset_obj, true)
end

function ReaderDictionary:onLoadDictionaryPreset(preset_name)
    return Presets.onLoadPreset(self.preset_obj, preset_name, true)
end

function ReaderDictionary.getPresets() -- for Dispatcher
    local dict_config = {
        presets = G_reader_settings:readSetting("dict_presets", {})
    }
    return Presets.getPresets(dict_config)
end

return ReaderDictionary
