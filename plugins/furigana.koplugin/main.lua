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

local DataStorage = require("datastorage")
local InfoMessage = require("ui/widget/infomessage")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")
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
end

-- ----------------------------------------------------------------- helpers --

function Furigana:isEpub()
    local doc = self.ui and self.ui.document
    if not doc then return false end
    if doc.info and doc.info.has_pages then return false end -- paged formats (pdf/djvu/cbz)
    local file = doc.file or ""
    return file:lower():match("%.epub$") ~= nil
end

function Furigana:isShowingAnnotated()
    local file = (self.ui and self.ui.document and self.ui.document.file) or ""
    return file:sub(1, #self.cache_dir) == self.cache_dir
end

-- Cache path for the annotated copy of `src`, keyed by path + size + mtime + dict
-- version, so it is regenerated if the book or the dictionary changes.
function Furigana:annotatedPathFor(src)
    local attr = lfs.attributes(src)
    local size = attr and attr.size or 0
    local mtime = attr and attr.modification or 0
    local dict_version = self:getDictVersion()
    local key = hash_str(src) .. "_" .. size .. "_" .. mtime .. "_v" .. dict_version
    return self.cache_dir .. "/" .. key .. ".epub"
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
    return Tokenizer.new(self.path .. "/dict")
end

-- ------------------------------------------------------------------- toggle --

-- Reopen `path` in place, restoring the current reading position.
function Furigana:switchTo(path)
    local saved_xp
    if self.ui and self.ui.rolling then
        saved_xp = self.ui.rolling:getBookLocation()
    end
    self.ui:switchDocument(path, false, function(new_ui)
        if saved_xp and new_ui and new_ui.rolling then
            -- The annotated DOM differs slightly (ruby inserted), so the xpointer
            -- may resolve to a nearby position rather than the exact spot.
            pcall(function() new_ui.rolling:onGotoXPointer(saved_xp) end)
        end
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
        local ok, err = EpubAnnotator.annotate_epub(tok, src, tmp, function(done, total)
            local go_on = Trapper:info(T(_("Adding furigana… %1 / %2"), done, total))
            if not go_on then aborted = true; return false end
            return true
        end)
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
        -- Defer the document switch until after this coroutine unwinds.
        UIManager:nextTick(function() self:switchTo(annotated) end)
    end)
end

function Furigana:onToggleFurigana(touchmenu_instance)
    if not self:isEpub() then return end
    if touchmenu_instance then touchmenu_instance:closeMenu() end

    if self:isShowingAnnotated() then
        -- Turn off: return to the original book.
        local src = self:readOriginalPath(self.ui.document.file)
        if src and lfs.attributes(src, "mode") == "file" then
            self:switchTo(src)
        else
            UIManager:show(InfoMessage:new{ text = _("Could not find the original book to switch back to.") })
        end
        return
    end

    -- Turn on.
    local src = self.ui.document.file
    local annotated = self:annotatedPathFor(src)
    if lfs.attributes(annotated, "mode") == "file" then
        self:switchTo(annotated) -- cached: instant
    else
        self:generateThenSwitch(src, annotated)
    end
end

-- --------------------------------------------------------------------- menu --

function Furigana:addToMainMenu(menu_items)
    menu_items.furigana_annotation = {
        text = _("Add furigana annotations"),
        sorting_hint = "search",
        enabled_func = function() return self:isEpub() end,
        checked_func = function() return self:isShowingAnnotated() end,
        callback = function(touchmenu_instance)
            self:onToggleFurigana(touchmenu_instance)
        end,
        help_text = _([[Generate furigana (ruby) readings for the current Japanese EPUB and reopen it with the readings shown.

The readings are generated on-device; the first run on a book may take a little while, after which the result is cached. Toggle again to return to the original book.]]),
    }
end

return Furigana
