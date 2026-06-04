--- SQLite-backed JMdict POS lookup — KOReader port of engine.py's PosDict.
--
-- Wraps the bundled jmdict_pos.sqlite (schema:
--   pos(surface TEXT PRIMARY KEY, classes TEXT, common INTEGER))
-- and exposes the two methods the conjugator depends on:
--   classes(surface) -> { class, ... }   ordered coarse POS classes ("|" split)
--   common(surface)  -> boolean           JMdict priority/frequency flag
--
-- Degrades gracefully (returns {} / false) when the database is missing or a
-- column is absent, exactly like the Python reference.  This is the only module
-- that touches SQLite, so the rest of the engine stays pure-Lua and testable.
--
-- @module koplugin.japanese.posdict

local SQ3 = require("lua-ljsqlite3/init")
local logger = require("logger")

local PosDict = {}
PosDict.__index = PosDict

--- Open the POS database at `path`.  Returns a PosDict whose connection may be
-- nil (in which case lookups degrade to empty results).
function PosDict.new(path)
    local self = setmetatable({ conn = nil, classes_stmt = nil, common_stmt = nil }, PosDict)
    local ok, conn = pcall(SQ3.open, path, "ro")
    if not ok or conn == nil then
        logger.warn("japanese.koplugin posdict: could not open POS db at", path, conn)
        return self
    end
    self.conn = conn
    self.classes_stmt = conn:prepare("SELECT classes FROM pos WHERE surface = ?")
    -- The common column may be absent in an older DB; probe once.
    local ok_common, stmt = pcall(function()
        return conn:prepare("SELECT common FROM pos WHERE surface = ?")
    end)
    self.common_stmt = ok_common and stmt or nil
    return self
end

--- Ordered list of coarse POS classes for `surface` (empty when unknown).
function PosDict:classes(surface)
    if not self.classes_stmt then return {} end
    local stmt = self.classes_stmt
    stmt:reset()
    stmt:bind(surface)
    local row = stmt:step()
    if not row or not row[1] then return {} end
    local out = {}
    for c in tostring(row[1]):gmatch("[^|]+") do out[#out + 1] = c end
    return out
end

--- True if `surface` carries a JMdict priority tag (a common word).
function PosDict:common(surface)
    if not self.common_stmt then return false end
    local stmt = self.common_stmt
    stmt:reset()
    stmt:bind(surface)
    local row = stmt:step()
    return row ~= nil and tonumber(row[1]) ~= nil and tonumber(row[1]) ~= 0
end

--- Release database resources.
function PosDict:close()
    if self.classes_stmt then self.classes_stmt:close() end
    if self.common_stmt then self.common_stmt:close() end
    if self.conn then self.conn:close() end
    self.conn, self.classes_stmt, self.common_stmt = nil, nil, nil
end

return PosDict
