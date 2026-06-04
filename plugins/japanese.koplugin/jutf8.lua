--- Minimal UTF-8 codepoint helpers for the conjugator.
-- engine.py (the Python reference) slices and measures strings by *codepoint*
-- (Python str semantics), while Lua strings are bytes.  These helpers reproduce
-- the codepoint-level operations the port needs (length, trailing-char removal,
-- last character, common-prefix length) so the Lua port ranks and slices
-- identically to Python.  Pure Lua: usable under stock luajit and KOReader.
--
-- @module koplugin.japanese.jutf8

local jutf8 = {}

--- Number of bytes in the UTF-8 character that starts with byte `b`.
local function char_bytes(b)
    if b < 0x80 then return 1
    elseif b < 0xE0 then return 2
    elseif b < 0xF0 then return 3
    else return 4 end
end

--- Split a UTF-8 string into an array of its characters (each a string).
-- @tparam string s
-- @treturn {string,...}
function jutf8.chars(s)
    local out, i, n = {}, 1, #s
    while i <= n do
        local w = char_bytes(s:byte(i))
        out[#out + 1] = s:sub(i, i + w - 1)
        i = i + w
    end
    return out
end

--- Codepoint length (mirrors Python len(str)).
function jutf8.len(s)
    local i, n, count = 1, #s, 0
    while i <= n do
        i = i + char_bytes(s:byte(i))
        count = count + 1
    end
    return count
end

--- Remove the last `n` codepoints (mirrors Python s[:-n]).  Returns "" when n
-- is at least the length of the string.
-- @tparam string s
-- @tparam int n number of trailing characters to drop (default 1)
function jutf8.chop(s, n)
    n = n or 1
    local chars = jutf8.chars(s)
    local keep = #chars - n
    if keep <= 0 then return "" end
    return table.concat(chars, "", 1, keep)
end

--- The last codepoint of the string (mirrors Python s[-1]); "" if empty.
function jutf8.last(s)
    local chars = jutf8.chars(s)
    return chars[#chars] or ""
end

--- Length of the common leading run of codepoints of a and b (mirrors the
-- reference _common_prefix_len, which zips Python strings codepoint-wise).
function jutf8.common_prefix_len(a, b)
    local ca, cb = jutf8.chars(a), jutf8.chars(b)
    local n = math.min(#ca, #cb)
    local i = 1
    while i <= n and ca[i] == cb[i] do i = i + 1 end
    return i - 1
end

return jutf8
