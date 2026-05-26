--[[--
Pure-LuaJIT furigana tokenizer.

A faithful port of kuromoji.js's Viterbi tokenization (the parts the furigana
annotator relies on), reading the compact dictionary produced by
tools/build_dict.js. Per-token ruby HTML is precomputed at build time, so this
module contains no Japanese-language logic: it builds a Viterbi lattice, picks
the lowest-cost path, and emits each token's precomputed HTML (or, for unknown
words, the surface text verbatim) — matching bridge.js's output by construction.

This file deliberately depends only on LuaJIT (ffi/bit) and io, so it can be
unit-tested with a stock luajit outside KOReader.

@module furigana.tokenizer
]]

local ffi = require("ffi")
local bit = require("bit")

local band, bor, lshift, rshift = bit.band, bit.bor, bit.lshift, bit.rshift

ffi.cdef[[
struct furi_tok { uint32_t html_off; uint16_t html_len; int16_t left; int16_t right; int16_t cost; uint8_t grade; uint8_t pad; };
struct furi_unk { int16_t left; int16_t right; int16_t cost; };
]]

local ROOT_ID = 0
local TERM_CODE = 0
local NOT_FOUND = -1

local Tokenizer = {}
Tokenizer.__index = Tokenizer

-- ------------------------------------------------------------------ helpers --

local function read_file(path)
    local fh = assert(io.open(path, "rb"), "cannot open " .. path)
    local data = fh:read("*a")
    fh:close()
    return data
end

-- Copy a binary file into a freshly allocated, naturally aligned ffi array of
-- `ctype` (e.g. "int32_t"). Returns the array and its element count. The Lua
-- string is dropped afterwards so only the ffi array stays resident.
local function load_array(path, ctype, elem_size)
    local data = read_file(path)
    assert(#data % elem_size == 0, "bad size for " .. path)
    local n = #data / elem_size
    local arr = ffi.new(ctype .. "[?]", n)
    ffi.copy(arr, data, #data)
    return arr, n
end

-- Decode a UTF-8 string into 1-indexed arrays of codepoints and their UTF-16
-- widths (1 for BMP, 2 for supplementary — mirrors JS string .length units).
local function utf8_decode(s)
    local cps, w16, n = {}, {}, 0
    local i, len = 1, #s
    while i <= len do
        local b = s:byte(i)
        local cp, size
        if b < 0x80 then cp, size = b, 1
        elseif b < 0xE0 then
            cp = bor(lshift(band(b, 0x1F), 6), band(s:byte(i + 1) or 0, 0x3F))
            size = 2
        elseif b < 0xF0 then
            cp = bor(lshift(band(b, 0x0F), 12),
                     bor(lshift(band(s:byte(i + 1) or 0, 0x3F), 6),
                         band(s:byte(i + 2) or 0, 0x3F)))
            size = 3
        else
            cp = bor(lshift(band(b, 0x07), 18),
                     bor(lshift(band(s:byte(i + 1) or 0, 0x3F), 12),
                         bor(lshift(band(s:byte(i + 2) or 0, 0x3F), 6),
                             band(s:byte(i + 3) or 0, 0x3F))))
            size = 4
        end
        n = n + 1
        cps[n] = cp
        w16[n] = cp < 0x10000 and 1 or 2
        i = i + size
    end
    return cps, w16, n
end

-- Append the UTF-8 bytes of codepoint `cp` to byte array `out` (1-indexed),
-- returning the new length.
local function utf8_encode_into(out, k, cp)
    if cp < 0x80 then
        out[k + 1] = cp; return k + 1
    elseif cp < 0x800 then
        out[k + 1] = bor(0xC0, rshift(cp, 6))
        out[k + 2] = bor(0x80, band(cp, 0x3F))
        return k + 2
    elseif cp < 0x10000 then
        out[k + 1] = bor(0xE0, rshift(cp, 12))
        out[k + 2] = bor(0x80, band(rshift(cp, 6), 0x3F))
        out[k + 3] = bor(0x80, band(cp, 0x3F))
        return k + 3
    else
        out[k + 1] = bor(0xF0, rshift(cp, 18))
        out[k + 2] = bor(0x80, band(rshift(cp, 12), 0x3F))
        out[k + 3] = bor(0x80, band(rshift(cp, 6), 0x3F))
        out[k + 4] = bor(0x80, band(cp, 0x3F))
        return k + 4
    end
end

-- Encode codepoints cps[from .. from+count-1] back to a UTF-8 string.
local function encode_range(cps, from, count)
    local buf, k = {}, 0
    for i = from, from + count - 1 do k = utf8_encode_into(buf, k, cps[i]) end
    return string.char(unpack(buf, 1, k))
end

-- Split keeping empty fields (Lua has no built-in); mirrors JS str.split("\n").
local function split_lines(s)
    local out, n, start = {}, 0, 1
    while true do
        local i = s:find("\n", start, true)
        if not i then
            n = n + 1; out[n] = s:sub(start); break
        end
        n = n + 1; out[n] = s:sub(start, i - 1)
        start = i + 1
    end
    return out
end

-- ------------------------------------------------------------------- loader --

--- Load a dictionary directory produced by tools/build_dict.js.
-- @param dict_dir path to the dict directory
-- @param min_grade selective-furigana threshold: annotate a word only if its
--   hardest-kanji grade is >= min_grade (1 = annotate everything, the default).
function Tokenizer.new(dict_dir, min_grade)
    local self = setmetatable({}, Tokenizer)
    self.min_grade = min_grade or 1
    local sep = dict_dir:sub(-1) == "/" and "" or "/"
    local function p(name) return dict_dir .. sep .. name end

    self.meta = assert(loadfile(p("meta.lua")))()
    local m = self.meta

    self.base = load_array(p("da_base.bin"), "int32_t", 4)
    self.base_len = m.base_len
    self.check = load_array(p("da_check.bin"), "int32_t", 4)
    self.check_len = m.check_len

    self.cc = load_array(p("cc.bin"), "int16_t", 2)
    self.cc_backward = m.cc_backward

    do
        local data = read_file(p("tokens.bin"))
        local n = m.token_count
        local rec = ffi.sizeof("struct furi_tok")
        assert(#data == n * rec, "tokens.bin size mismatch")
        local arr = ffi.new("struct furi_tok[?]", n)
        ffi.copy(arr, data, n * rec)
        self.tokens = arr
    end
    self.html = read_file(p("html.bin")) -- kept as a Lua string; we sub() out of it

    self.tm_offset = load_array(p("tm_offset.bin"), "int32_t", 4)
    self.tm_values = load_array(p("tm_values.bin"), "int32_t", 4)
    self.max_trie_value = m.max_trie_value

    self.unk_cat = load_array(p("unk_cat.bin"), "uint8_t", 1)
    do
        local data = read_file(p("unk_tokens.bin"))
        local n = m.unk_token_count
        local arr = ffi.new("struct furi_unk[?]", n)
        ffi.copy(arr, data, n * 6)
        self.unk_tokens = arr
    end
    self.unk_classes = m.unk_classes
    self.default_class_id = m.default_class_id

    return self
end

--- Set the selective-furigana threshold (1 = annotate all kanji words).
function Tokenizer:setMinGrade(min_grade)
    self.min_grade = min_grade or 1
end

-- -------------------------------------------------------------- double array --

function Tokenizer:getBase(i)
    if i >= self.base_len then return -i + 1 end
    return self.base[i]
end

function Tokenizer:getCheck(i)
    if i >= self.check_len then return -i - 1 end
    return self.check[i]
end

-- Returns child node id, or NOT_FOUND. `parent` is always >= 0.
function Tokenizer:traverse(parent, code)
    local child = self:getBase(parent) + code
    if child < 0 then return NOT_FOUND end
    if self:getCheck(child) == parent then return child end
    return NOT_FOUND
end

-- Common-prefix search starting at codepoint index `pos` (1-indexed) within the
-- sentence codepoint array `cps`/`w16`, up to `hi`. Returns a list of matches,
-- each { len16 = <UTF-16 length of matched key>, v = <trie value> }, in the
-- order kuromoji would produce them (shortest first).
function Tokenizer:commonPrefixSearch(cps, w16, pos, hi, bytebuf)
    local parent = ROOT_ID
    local results, rn = {}, 0
    local utf16 = 0
    for cp = pos, hi do
        local nb = utf8_encode_into(bytebuf, 0, cps[cp]) -- bytes 1..nb
        for bi = 1, nb do
            local child = self:traverse(parent, bytebuf[bi])
            if child == NOT_FOUND then
                return results
            end
            parent = child
            local grand = self:traverse(child, TERM_CODE)
            if grand ~= NOT_FOUND then
                local base = self:getBase(grand)
                if base <= 0 and bi == nb then -- leaf, on a codepoint boundary
                    rn = rn + 1
                    results[rn] = { len16 = utf16 + w16[cp], v = -base - 1, ncp = cp - pos + 1 }
                end
            end
        end
        utf16 = utf16 + w16[cp]
    end
    return results
end

-- ------------------------------------------------------------- unknown words --

function Tokenizer:lookupClassId(cp)
    if cp < 0x10000 then return self.unk_cat[cp] end
    return self.default_class_id
end

-- --------------------------------------------------------------------- build --

-- Build the lattice for one sentence (codepoints cps[lo..hi]) and return the
-- best path as an ordered list of nodes. Each node: { token=<dense id> or
-- surface=<string>, cost, start_pos, length, left_id, right_id }.
function Tokenizer:tokenizeSentence(cps, w16, lo, hi)
    local nodes_end_at = {}   -- pos -> array of nodes ending at pos
    local eos_pos = 1
    -- BOS
    nodes_end_at[0] = { { type = "BOS", cost = 0, start_pos = 0, length = 0,
                          left_id = 0, right_id = 0, shortest_cost = 0 } }

    local function append(node)
        local last_pos = node.start_pos + node.length - 1
        if eos_pos < last_pos then eos_pos = last_pos end
        local arr = nodes_end_at[last_pos]
        if not arr then arr = {}; nodes_end_at[last_pos] = arr end
        arr[#arr + 1] = node
    end

    -- Position is expressed relative to the sentence start (1-based char index),
    -- matching kuromoji's `pos+1` start positions over a 0-based loop.
    local bytebuf = {}
    local rel = 0
    for cp = lo, hi do
        rel = rel + 1 -- rel == (kuromoji pos) + 1
        local vocab = self:commonPrefixSearch(cps, w16, cp, hi, bytebuf)
        for n = 1, #vocab do
            local v = vocab[n].v
            if v >= 0 and v <= self.max_trie_value then
                local start = self.tm_offset[v]
                local stop = self.tm_offset[v + 1]
                for idx = start, stop - 1 do
                    local d = self.tm_values[idx]
                    local t = self.tokens[d]
                    append({
                        type = "KNOWN", token = d,
                        cost = t.cost, start_pos = rel, length = vocab[n].len16,
                        left_id = t.left, right_id = t.right,
                        cp_start = cp, cp_count = vocab[n].ncp,
                        shortest_cost = math.huge,
                    })
                end
            end
        end

        -- Unknown word processing
        local head_class_id = self:lookupClassId(cps[cp])
        local head_class = self.unk_classes[head_class_id]
        if head_class and (#vocab == 0 or head_class.always == 1) then
            -- kuromoji quirk: an ungrouped unknown node keeps its length as
            -- SurrogateAwareString.length (codepoint count == 1 for the single
            -- head char, even for a surrogate pair). Only once grouping appends
            -- characters does `key` become a plain string whose .length is in
            -- UTF-16 units. Replicate exactly, or surrogate-pair kanji shift the
            -- lattice and drop the following word.
            local len16 = w16[cp]
            local end_cp = cp
            local grouped = false
            if head_class.grouping == 1 and cp < hi then
                for k = cp + 1, hi do
                    local nc = self.unk_classes[self:lookupClassId(cps[k])]
                    if not nc or nc.name ~= head_class.name then break end
                    len16 = len16 + w16[k]
                    end_cp = k
                    grouped = true
                end
            end
            local node_length = grouped and len16 or 1
            -- surface text of the unknown run
            local sbytes, sk = {}, 0
            for k = cp, end_cp do sk = utf8_encode_into(sbytes, sk, cps[k]) end
            local surface = string.char(unpack(sbytes, 1, sk))
            local ids = head_class.token_ids
            for j = 1, #ids do
                local u = self.unk_tokens[ids[j]]
                append({
                    type = "UNKNOWN", surface = surface,
                    cost = u.cost, start_pos = rel, length = node_length,
                    left_id = u.left, right_id = u.right,
                    shortest_cost = math.huge,
                })
            end
        end
    end

    -- appendEos
    eos_pos = eos_pos + 1
    local eos_index = 0
    for k in pairs(nodes_end_at) do if k >= eos_index then eos_index = k + 1 end end
    nodes_end_at[eos_index] = { { type = "EOS", cost = 0, start_pos = eos_pos,
                                  length = 0, left_id = 0, right_id = 0,
                                  shortest_cost = math.huge } }

    -- forward
    local cc, bwd = self.cc, self.cc_backward
    for i = 1, eos_pos do
        local nodes = nodes_end_at[i]
        if nodes then
            for j = 1, #nodes do
                local node = nodes[j]
                local prev_nodes = nodes_end_at[node.start_pos - 1]
                if prev_nodes then
                    local best_cost = math.huge
                    local best_prev
                    for k = 1, #prev_nodes do
                        local pn = prev_nodes[k]
                        -- cc.get(prev.right_id, node.left_id) with +2 header offset
                        local edge = cc[pn.right_id * bwd + node.left_id + 2]
                        local c = pn.shortest_cost + edge + node.cost
                        if c < best_cost then best_cost = c; best_prev = pn end
                    end
                    node.prev = best_prev
                    node.shortest_cost = best_cost
                end
            end
        end
    end

    -- backward
    local eos = nodes_end_at[eos_index][1]
    local path, pn = {}, eos.prev
    if not pn then return {} end
    while pn.type ~= "BOS" do
        path[#path + 1] = pn
        if not pn.prev then return {} end
        pn = pn.prev
    end
    -- reverse
    local rev, m = {}, #path
    for i = 1, m do rev[i] = path[m - i + 1] end
    return rev
end

-- ----------------------------------------------------------- public surface --

local function is_punct(cp) return cp == 0x3001 or cp == 0x3002 end -- 、。

-- Tokenize one line and return its furigana HTML.
function Tokenizer:tokenizeLine(line)
    if line == "" then return "" end
    local cps, w16, n = utf8_decode(line)
    if n == 0 then return "" end

    local out, on = {}, 0
    local lo = 1
    while lo <= n do
        -- splitByPunctuation: sentence ends at the first 、/。 (inclusive)
        local hi = n
        for i = lo, n do if is_punct(cps[i]) then hi = i; break end end

        local path = self:tokenizeSentence(cps, w16, lo, hi)
        for i = 1, #path do
            local node = path[i]
            if node.type == "KNOWN" then
                local t = self.tokens[node.token]
                on = on + 1
                if t.grade > 0 and t.grade < self.min_grade then
                    -- ruby candidate below the selective threshold: plain surface
                    out[on] = encode_range(cps, node.cp_start, node.cp_count)
                else
                    local off = tonumber(t.html_off)
                    out[on] = self.html:sub(off + 1, off + tonumber(t.html_len))
                end
            elseif node.type == "UNKNOWN" then
                on = on + 1
                out[on] = node.surface
            end
        end
        lo = hi + 1
    end
    return table.concat(out)
end

--- Annotate a UTF-8 text block, returning the same block with furigana ruby
-- markup injected. Mirrors bridge.js annotate(): split on newlines, tokenize
-- each line, rejoin with newlines.
function Tokenizer:annotate(text)
    local lines = split_lines(text)
    for i = 1, #lines do
        lines[i] = self:tokenizeLine(lines[i])
    end
    return table.concat(lines, "\n")
end

return Tokenizer
