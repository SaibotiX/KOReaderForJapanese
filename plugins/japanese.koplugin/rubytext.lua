--- Interlinear ruby text: a Japanese sentence with its furigana readings
-- rendered ABOVE the annotated words (real ruby, like the book itself), the
-- whole thing wrapped to a maximum width.
--
-- Input is the plain sentence plus the annotator's ruby runs — byte offsets
-- into the plain string, exactly as readingextractor.parse produces them.
-- The text is broken into "atoms": an annotated run (base + reading) is one
-- unbreakable unit, unannotated stretches break per character (CJK) or per
-- word (Latin/digits), with simple kinsoku (closing punctuation and small
-- kana never start a line, an opening bracket never ends one).
--
-- Holds map back to byte offsets in the plain string, so the host can run
-- the same Yomichan-style word expansion a hold on the book page gets:
--  * `select_callback(text, duration, start_byte, is_single)` — start_byte
--    is 0-based into `plain`; is_single is true for a plain hold (one atom),
--    false for a hold+drag selection.
-- The layout/hit-test logic is pure (`RubyText.layout`) and unit-testable
-- with a stubbed measure function.
--
-- @module koplugin.japanese.rubytext

local Geom = require("ui/geometry")
local Precache = require("precache") -- furigana plugin: pure UTF-8 helpers
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local Widget = require("ui/widget/widget")

local RubyText = Widget:extend{
    plain = nil,       -- the sentence (UTF-8)
    runs = nil,        -- { { start = 0-based byte, len, base, reading } } or nil
    face = nil,        -- base text font face
    ruby_face = nil,   -- reading font face (smaller)
    max_width = nil,   -- wrap limit in pixels
    dialog = nil,      -- widget to mark dirty for selection feedback
    select_callback = nil, -- see module doc
}

-- Fraction of the reading's height tucked into the gap between it and its
-- base text: the two TextWidgets' paddings plus the kana descender leave a
-- visible moat otherwise. Only the reading-to-base distance shrinks — each
-- line's top (where the reading sits) keeps its position, so the spacing to
-- the previous line is unchanged.
RubyText.RUBY_TUCK = 0.25

-- ------------------------------------------------------------- pure layout --

local function is_ascii_wordish(b)
    return (b >= 0x30 and b <= 0x39) or (b >= 0x41 and b <= 0x5A)
        or (b >= 0x61 and b <= 0x7A) or b == 0x27 or b == 0x2D
end

-- Characters that must not START a line (closing punctuation, terminators,
-- small kana, the long-vowel mark) or must not END one (opening brackets).
local NO_START = {}
for c in ("。、！？…‥）」』〉》】，．・ーぁぃぅぇぉっゃゅょァィゥェォッャュョ"):gmatch("[%z\1-\127\194-\244][\128-\191]*") do
    NO_START[c] = true
end
local NO_END = {}
for c in ("「『（〈《【"):gmatch("[%z\1-\127\194-\244][\128-\191]*") do
    NO_END[c] = true
end

--- Split plain text + ruby runs into unbreakable display atoms, in order.
-- Each atom: { text, rt (reading or nil), start (0-based byte), len,
-- no_start, no_end }.
function RubyText.buildAtoms(plain, runs)
    local atoms = {}
    local function add_gap(from0, to0) -- 0-based byte range [from0, to0)
        local i = from0 + 1
        while i <= to0 do
            local b = plain:byte(i)
            local j = i
            if b and is_ascii_wordish(b) then
                repeat j = j + 1 until j > to0 or not is_ascii_wordish(plain:byte(j))
            else
                local _, len = Precache.utf8At(plain, i)
                j = i + len
                if j > to0 + 1 then j = to0 + 1 end
            end
            local text = plain:sub(i, j - 1)
            atoms[#atoms + 1] = {
                text = text, start = i - 1, len = j - i,
                no_start = NO_START[text] or nil,
                no_end = NO_END[text] or nil,
            }
            i = j
        end
    end
    local pos0 = 0
    for _, r in ipairs(runs or {}) do
        -- ignore malformed/overlapping runs rather than derail the layout
        if r.start >= pos0 and r.start + r.len <= #plain and r.len > 0 then
            add_gap(pos0, r.start)
            atoms[#atoms + 1] = {
                text = r.base or plain:sub(r.start + 1, r.start + r.len),
                rt = r.reading,
                start = r.start, len = r.len,
            }
            pos0 = r.start + r.len
        end
    end
    add_gap(pos0, #plain)
    return atoms
end

--- Wrap measured atoms into lines of at most `max_width`.
-- `measure(text, is_ruby)` must return width, height in pixels.
-- Returns lines (arrays of atoms, each atom gaining .x/.w/.base_w),
-- max_line_w, base_h, rt_h (0 when no atom carries a reading).
function RubyText.layout(atoms, max_width, measure)
    local base_h, rt_h = 0, 0
    for _, a in ipairs(atoms) do
        local w, h = measure(a.text, false)
        a.base_w = w
        a.w = w
        if h > base_h then base_h = h end
        if a.rt and a.rt ~= "" then
            local rw, rh = measure(a.rt, true)
            a.rt_w = rw
            if rw > a.w then a.w = rw end
            if rh > rt_h then rt_h = rh end
        end
    end
    local lines = { {} }
    local x = 0
    local max_line_w = 0
    for _, a in ipairs(atoms) do
        local line = lines[#lines]
        -- kinsoku: closing punctuation may overflow the line rather than
        -- open the next one
        if x + a.w > max_width and #line > 0 and not a.no_start then
            -- an opening bracket must not stay behind at the line end:
            -- pull it down with us
            local pulled
            if line[#line] and line[#line].no_end then
                pulled = table.remove(line)
                x = x - pulled.w
            end
            -- only close a line that still has content: pulling the sole
            -- atom off a line must not leave an empty line mid-block
            if #line > 0 then
                if x > max_line_w then max_line_w = x end
                lines[#lines + 1] = {}
                line = lines[#lines]
            end
            x = 0
            if pulled then
                pulled.x = x
                x = x + pulled.w
                line[#line + 1] = pulled
            end
        end
        a.x = x
        x = x + a.w
        line[#line + 1] = a
    end
    if x > max_line_w then max_line_w = x end
    if #lines[#lines] == 0 then table.remove(lines) end
    return lines, max_line_w, base_h, rt_h
end

--- The atom (and its line) at pixel position (x, y) relative to the widget's
-- top-left; nearest atom of the hit line when x falls in a gap or beyond.
function RubyText.atomAt(lines, line_h, x, y)
    if #lines == 0 then return nil end
    local li = math.floor(y / line_h) + 1
    if li < 1 then li = 1 end
    if li > #lines then li = #lines end
    local line = lines[li]
    if #line == 0 then return nil end
    for _, a in ipairs(line) do
        if x >= a.x and x < a.x + a.w then return a end
    end
    return x < line[1].x and line[1] or line[#line]
end

-- ----------------------------------------------------------------- widget --

function RubyText:init()
    self.runs = self.runs or {}
    self._atoms = RubyText.buildAtoms(self.plain or "", self.runs)
    self._measure_cache = {} -- one TextWidget per unique (text, ruby) pair
    local function measure(text, is_ruby)
        local key = (is_ruby and "r\0" or "b\0") .. text
        local w = self._measure_cache[key]
        if not w then
            w = TextWidget:new{
                text = text,
                face = is_ruby and self.ruby_face or self.face,
            }
            self._measure_cache[key] = w
        end
        local size = w:getSize()
        return size.w, size.h
    end
    self._lines, self._w, self._base_h, self._rt_h =
        RubyText.layout(self._atoms, self.max_width, measure)
    self._tuck = self._rt_h > 0
        and math.floor(self._rt_h * RubyText.RUBY_TUCK) or 0
    self._line_h = self._base_h + self._rt_h - self._tuck
    self._h = #self._lines * self._line_h
    -- Resolve each atom's widgets once (paintTo repaints on every selection
    -- tick) and index the atoms for hit-testing.
    self._by_idx = {}
    local n = 0
    for _, line in ipairs(self._lines) do
        for _, a in ipairs(line) do
            n = n + 1
            a._idx = n
            self._by_idx[n] = a
            a._bw = self._measure_cache["b\0" .. a.text]
            if a.rt and a.rt ~= "" then
                a._rw = self._measure_cache["r\0" .. a.rt]
            end
        end
    end
end

function RubyText:getSize()
    return Geom:new{ w = math.min(self._w, self.max_width), h = self._h }
end

function RubyText:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self:getSize().w, h = self._h }
    for li, line in ipairs(self._lines) do
        local ly = y + (li - 1) * self._line_h
        for _, a in ipairs(line) do
            if a._bw then
                a._bw:paintTo(bb, x + a.x + math.floor((a.w - a.base_w) / 2),
                    ly + self._rt_h - self._tuck)
            end
            if a._rw then
                a._rw:paintTo(bb, x + a.x + math.floor((a.w - (a.rt_w or 0)) / 2), ly)
            end
            if self._sel_a and a._idx >= self._sel_a and a._idx <= self._sel_b then
                bb:invertRect(x + a.x, ly, a.w, self._line_h)
            end
        end
    end
end

function RubyText:free()
    for _, w in pairs(self._measure_cache or {}) do
        w:free()
    end
    self._measure_cache = {}
end

-- TextWidgets hold native (xtext/glyph) resources: release them when the
-- hosting window closes, like TextBoxWidget does for itself.
RubyText.onCloseWidget = RubyText.free

-- --------------------------------------------------------------- gestures --
-- The hosting widget declares the Hold* gesture events (like the dictionary
-- window does for TextBoxWidget); they propagate here. A hold outside our
-- area is declined so a sibling (e.g. the translation line) can take it.

function RubyText:_atomIndexAt(ges_pos)
    if not self.dimen then return nil end
    local x = ges_pos.x - self.dimen.x
    local y = ges_pos.y - self.dimen.y
    if x < 0 or x >= self.dimen.w or y < 0 or y >= self._h then return nil end
    local a = RubyText.atomAt(self._lines, self._line_h, x, y)
    return a and a._idx or nil
end

function RubyText:_setSelection(a, b)
    if a and b and a > b then a, b = b, a end
    if self._sel_a == a and self._sel_b == b then return end
    self._sel_a, self._sel_b = a, b
    if self.dialog then
        UIManager:setDirty(self.dialog, "ui", self.dimen)
    end
end

function RubyText:onHoldStartText(_, ges)
    local idx = self:_atomIndexAt(ges.pos)
    if not idx then
        return false -- not ours: let a sibling widget take it
    end
    self._hold_start_idx = idx
    self._hold_start_time = UIManager:getTime()
    self:_setSelection(idx, idx)
    return true
end

function RubyText:onHoldPanText(_, ges)
    if not self._hold_start_idx then return false end
    local idx = self:_atomIndexAt(ges.pos)
    if idx then
        self:_setSelection(self._hold_start_idx, idx)
    end
    return true
end

function RubyText:onHoldReleaseText(_, ges)
    if not self._hold_start_idx then return false end
    local start_idx = self._hold_start_idx
    self._hold_start_idx = nil
    local end_idx = self:_atomIndexAt(ges.pos) or start_idx
    local time = require("ui/time")
    local duration = self._hold_start_time
        and (time.now() - self._hold_start_time) or 0
    if start_idx > end_idx then
        start_idx, end_idx = end_idx, start_idx
    end
    local a, b = self._by_idx[start_idx], self._by_idx[end_idx]
    self:_setSelection(nil, nil)
    if not (a and b) then return true end
    local from = a.start
    local to = b.start + b.len -- exclusive
    local text = self.plain:sub(from + 1, to)
    if self.select_callback and text ~= "" then
        self.select_callback(text, duration, from, start_idx == end_idx)
    end
    return true
end

return RubyText
