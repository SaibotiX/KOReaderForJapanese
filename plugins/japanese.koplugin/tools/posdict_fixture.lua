--- Test-only POS lookup backed by a generated Lua table (pos_fixture.lua),
-- standing in for posdict.lua's SQLite so the parity harness runs under stock
-- luajit with no SQLite binding.  Implements the same classes()/common()
-- interface the conjugator depends on, returning identical data to the Python
-- engine for the sample set (misses degrade to {} / false, exactly as the real
-- database does).
--
-- @module koplugin.japanese.tools.posdict_fixture

local PosDictFixture = {}
PosDictFixture.__index = PosDictFixture

--- @param source a fixture table { classes=..., common=... } or a path to load.
function PosDictFixture.new(source)
    local data = source
    if type(source) == "string" then
        data = assert(loadfile(source))()
    end
    return setmetatable({
        classes_map = data.classes or {},
        common_map = data.common or {},
    }, PosDictFixture)
end

function PosDictFixture:classes(surface)
    return self.classes_map[surface] or {}
end

function PosDictFixture:common(surface)
    return self.common_map[surface] == true
end

return PosDictFixture
