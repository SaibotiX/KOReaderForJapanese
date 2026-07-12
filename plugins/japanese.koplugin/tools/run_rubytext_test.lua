-- Tests for rubytext.lua: atom building (annotated runs vs per-character /
-- per-Latin-word gaps), line wrapping with kinsoku, hit-testing, and the
-- hold → byte-offset selection flow, against stubbed KOReader widgets.
-- Pure Lua:  lua tools/run_rubytext_test.lua

local here = arg[0]:match("^(.*)/[^/]*$") or "."
-- furigana.koplugin: rubytext reuses its pure precache helpers (utf8At)
package.path = here .. "/../?.lua;" .. here .. "/../../furigana.koplugin/?.lua;" .. package.path

local failures = 0
local function check(cond, msg)
    if cond then
        print("ok   - " .. msg)
    else
        failures = failures + 1
        print("FAIL - " .. msg)
    end
end

-- ----------------------------------------------------------------- stubs --

local function cp_count(s)
    local n = 0
    for _ in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do n = n + 1 end
    return n
end

-- Every codepoint is face.size pixels wide; height is face.size + 2.
local TextWidget = {}
TextWidget.__index = TextWidget
function TextWidget:new(o)
    o = setmetatable(o or {}, TextWidget)
    return o
end
function TextWidget:getSize()
    return { w = cp_count(self.text) * self.face.size, h = self.face.size + 2 }
end
function TextWidget:paintTo() end
function TextWidget:free() end

local Widget = {}
function Widget:extend(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    return o
end
function Widget:new(o)
    o = self:extend(o)
    if o._init then o:_init() end
    if o.init then o:init() end
    return o
end

local stubs = {
    ["ui/geometry"] = { new = function(_, o) return o end },
    ["ui/widget/textwidget"] = TextWidget,
    ["ui/widget/widget"] = Widget,
    ["ui/uimanager"] = { getTime = function() return 0 end, setDirty = function() end },
    ["ui/time"] = { now = function() return 0 end },
}
for name, mod in pairs(stubs) do
    package.preload[name] = function() return mod end
end

local RubyText = require("rubytext")

local base_face = { size = 10 }
local ruby_face = { size = 5 }

-- --------------------------------------------------------------- buildAtoms --

local plain = "私は学校へ行った。"
local runs = {
    { start = 0, len = 3, base = "私", reading = "わたし" },
    { start = #"私は", len = #"学校", base = "学校", reading = "がっこう" },
    { start = #"私は学校へ", len = 3, base = "行", reading = "い" },
}
local atoms = RubyText.buildAtoms(plain, runs)
check(#atoms == 8, "annotated runs + per-char gaps: 8 atoms, got " .. #atoms)
check(atoms[1].text == "私" and atoms[1].rt == "わたし" and atoms[1].start == 0 and atoms[1].len == 3,
    "the first atom is the annotated 私 run")
check(atoms[2].text == "は" and atoms[2].rt == nil and atoms[2].start == 3,
    "gap characters become their own atoms")
check(atoms[3].text == "学校" and atoms[3].rt == "がっこう",
    "a multi-character run stays one unbreakable atom")
check(atoms[8].text == "。" and atoms[8].no_start == true,
    "closing punctuation is flagged no_start (kinsoku)")

local latin = RubyText.buildAtoms("TVを見る", {})
check(#latin == 4 and latin[1].text == "TV" and latin[1].start == 0 and latin[1].len == 2
        and latin[2].text == "を" and latin[2].start == 2,
    "Latin/digit stretches group into word atoms with byte offsets")

local mal = RubyText.buildAtoms("あい", { { start = 100, len = 3, base = "x", reading = "y" } })
check(#mal == 2 and mal[1].text == "あ",
    "a malformed run (offsets beyond the text) is ignored")

-- ------------------------------------------------------------------ layout --

local function measure(text, is_ruby)
    local face = is_ruby and ruby_face or base_face
    return cp_count(text) * face.size, face.size + 2
end

-- Widths: 私=max(10, 15)=15 は=10 学校=max(20,20)=20 へ=10 行=max(10,5)=10
-- っ=10 た=10 。=10 → total 95.
local lines, max_w, base_h, rt_h = RubyText.layout(atoms, 100, measure)
check(#lines == 1 and max_w == 95 and base_h == 12 and rt_h == 7,
    "everything fits on one line at width 100: w=" .. max_w)

lines, max_w = RubyText.layout(atoms, 50, measure)
check(#lines == 2 and #lines[1] == 3 and lines[1][3].text == "学校",
    "wrapping at width 50 breaks after 学校")
check(lines[2][1].text == "へ" and lines[2][1].x == 0,
    "the second line restarts at x=0")

-- Kinsoku: at width 45 the 。 would start line 3 — it must overflow line 2
-- instead.
lines = RubyText.layout(atoms, 45, measure)
check(#lines == 2 and lines[2][#lines[2]].text == "。",
    "no_start punctuation overflows its line instead of starting a new one")

-- An opening bracket never ends a line: it is pulled down to the next.
local q_atoms = RubyText.buildAtoms("だ。「あい」", {})
lines = RubyText.layout(q_atoms, 30, measure)
check(#lines == 2 and lines[1][#lines[1]].text == "。" and lines[2][1].text == "「",
    "an opening bracket at the wrap point moves to the next line")

-- Pulling the sole atom off a line must not strand an empty line mid-block.
local pull_atoms = RubyText.buildAtoms("あい「う", {})
lines = RubyText.layout(pull_atoms, 15, measure)
check(#lines == 3 and #lines[3] == 2
        and lines[3][1].text == "「" and lines[3][2].text == "う",
    "a pulled-down lone opening bracket reuses its line (no empty line)")

-- ------------------------------------------------------------------ atomAt --

lines = RubyText.layout(atoms, 50, measure)
local line_h = 12 + 7
local hit = RubyText.atomAt(lines, line_h, 16, 5)
check(hit and hit.text == "は", "atomAt finds the atom under x=16 on line 1")
hit = RubyText.atomAt(lines, line_h, 5, line_h + 3)
check(hit and hit.text == "へ", "atomAt maps y to the second line")
hit = RubyText.atomAt(lines, line_h, 9999, 5)
check(hit and hit.text == "学校", "x beyond the line snaps to its last atom")

-- ------------------------------------------- widget: hold → byte offsets --

local selections = {}
local w = RubyText:new{
    plain = "私は行く",
    runs = { { start = 0, len = 3, base = "私", reading = "わたし" } },
    face = base_face,
    ruby_face = ruby_face,
    max_width = 200,
    select_callback = function(text, duration, start_byte, is_single)
        selections[#selections + 1] = { text = text, start_byte = start_byte, single = is_single }
    end,
}
-- line height: base 12 + rt 7, minus the tuck (floor(7 * 0.25) = 1) that
-- pulls the reading closer to its word
check(w:getSize().w == 45 and w:getSize().h == 18,
    "widget size: 私(15)+は(10)+行(10)+く(10) wide, one tucked ruby line high: h="
        .. w:getSize().h)
w:paintTo({ invertRect = function() end }, 0, 0)
check(w.dimen and w.dimen.w == 45, "paintTo records the widget's screen rect")

-- single hold on the annotated atom
check(w:onHoldStartText(nil, { pos = { x = 5, y = 5 } }) == true, "hold inside is taken")
w:onHoldReleaseText(nil, { pos = { x = 5, y = 5 } })
check(#selections == 1 and selections[1].text == "私"
        and selections[1].start_byte == 0 and selections[1].single == true,
    "a plain hold reports the atom's text and 0-based byte offset")

-- hold + drag across atoms
w:onHoldStartText(nil, { pos = { x = 5, y = 5 } })
w:onHoldPanText(nil, { pos = { x = 28, y = 5 } })
w:onHoldReleaseText(nil, { pos = { x = 28, y = 5 } })
check(#selections == 2 and selections[2].text == "私は行"
        and selections[2].start_byte == 0 and selections[2].single == false,
    "a drag selection spans the atoms and keeps byte offsets: "
        .. tostring(selections[2] and selections[2].text))

-- a hold outside is declined so siblings can take it
check(w:onHoldStartText(nil, { pos = { x = 500, y = 5 } }) == false,
    "a hold outside the widget is declined")

print(failures == 0 and "ALL TESTS PASSED" or (failures .. " TEST(S) FAILED"))
os.exit(failures == 0 and 0 or 1)
