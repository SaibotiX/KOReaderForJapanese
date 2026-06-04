--- Minimal JSON decoder (objects, arrays, strings, numbers, bool, null).
-- Used to load yomichan-deinflect.json into the natural nested-table form the
-- conjugator's forward-inflection code expects (mirroring Python's json.load),
-- without depending on KOReader's rapidjson — so conjugator.lua stays runnable
-- under stock luajit for the parity harness.  The rule file is plain UTF-8 with
-- no \u escapes, but standard escapes are handled for safety.
--
-- @module koplugin.japanese.json_min

local json_min = {}

local escapes = {
    ['"'] = '"', ['\\'] = '\\', ['/'] = '/', b = '\b',
    f = '\f', n = '\n', r = '\r', t = '\t',
}

local function skip_ws(s, i)
    local _, j = s:find("^[ \t\r\n]*", i)
    return j + 1
end

local parse_value  -- forward declaration

local function parse_string(s, i)
    -- i points at the opening quote.
    local buf, n = {}, #s
    i = i + 1
    while i <= n do
        local c = s:sub(i, i)
        if c == '"' then
            return table.concat(buf), i + 1
        elseif c == '\\' then
            local e = s:sub(i + 1, i + 1)
            if e == 'u' then
                local hex = s:sub(i + 2, i + 5)
                buf[#buf + 1] = string.char(tonumber(hex, 16) % 256)
                i = i + 6
            else
                buf[#buf + 1] = escapes[e] or e
                i = i + 2
            end
        else
            buf[#buf + 1] = c
            i = i + 1
        end
    end
    error("json_min: unterminated string")
end

local function parse_array(s, i)
    local arr = {}
    i = skip_ws(s, i + 1)
    if s:sub(i, i) == "]" then return arr, i + 1 end
    while true do
        local v
        v, i = parse_value(s, i)
        arr[#arr + 1] = v
        i = skip_ws(s, i)
        local c = s:sub(i, i)
        if c == "]" then return arr, i + 1 end
        i = skip_ws(s, i + 1) -- skip ','
    end
end

local function parse_object(s, i)
    local obj = {}
    i = skip_ws(s, i + 1)
    if s:sub(i, i) == "}" then return obj, i + 1 end
    while true do
        local key
        key, i = parse_string(s, i)
        i = skip_ws(s, i)
        i = skip_ws(s, i + 1) -- skip ':'
        local v
        v, i = parse_value(s, i)
        obj[key] = v
        i = skip_ws(s, i)
        local c = s:sub(i, i)
        if c == "}" then return obj, i + 1 end
        i = skip_ws(s, i + 1) -- skip ','
    end
end

function parse_value(s, i)
    i = skip_ws(s, i)
    local c = s:sub(i, i)
    if c == '"' then return parse_string(s, i)
    elseif c == "{" then return parse_object(s, i)
    elseif c == "[" then return parse_array(s, i)
    elseif c == "t" then return true, i + 4
    elseif c == "f" then return false, i + 5
    elseif c == "n" then return nil, i + 4
    else
        local num = s:match("^%-?%d+%.?%d*[eE]?[%+%-]?%d*", i)
        return tonumber(num), i + #num
    end
end

--- Decode a JSON string into Lua tables.
function json_min.decode(s)
    local v = parse_value(s, 1)
    return v
end

--- Read and decode a JSON file by path.
function json_min.load_file(path)
    local fh = assert(io.open(path, "rb"), "json_min: cannot open " .. path)
    local data = fh:read("*a")
    fh:close()
    return json_min.decode(data)
end

return json_min
