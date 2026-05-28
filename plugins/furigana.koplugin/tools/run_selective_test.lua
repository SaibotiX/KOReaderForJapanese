-- Selective-furigana checks: verify the min_grade threshold drops easy-kanji
-- ruby while keeping harder kanji, and that ruby count is monotonic in the level.
package.path = package.path .. ";./?.lua"
local Tokenizer = require("tokenizer")

local here = arg[0]:match("^(.*)/[^/]*$") or "."
local plugin_dir = here:match("^(.*)/tools$") or (here .. "/..")
local tok = Tokenizer.new(plugin_dir .. "/dict")

local function ruby_count(s)
    local n = 0
    for _ in s:gmatch("<ruby>") do n = n + 1 end
    return n
end

local function has_ruby(text, mg)
    tok:setMinGrade(mg)
    return ruby_count(tok:annotate(text)) > 0
end

local fail = 0
local function check(desc, cond)
    if cond then io.write("  OK  " .. desc .. "\n")
    else fail = fail + 1; io.write("  FAIL " .. desc .. "\n") end
end

io.write("== per-word grade gating ==\n")
-- 本 (ほん): Kyoiku grade 1 -> annotated only at level 1
check("本 ruby at level 1",      has_ruby("本", 1))
check("本 plain at level 2",     not has_ruby("本", 2))
-- 私 (わたし): grade 6 -> annotated up to level 6, plain at 7
check("私 ruby at level 6",      has_ruby("私", 6))
check("私 plain at level 7",     not has_ruby("私", 7))
-- 誰 (だれ): general Joyo (KANJIDIC grade 8 -> normalized 7) -> ruby up to 7
check("誰 ruby at level 7",      has_ruby("誰", 7))
check("誰 plain at level 8",     not has_ruby("誰", 8))

io.write("== numbers/letters only at 'All' (grade 1) ==\n")
check("ＡＢＣ ruby at level 1",   has_ruby("ＡＢＣ", 1))
check("ＡＢＣ plain at level 2",  not has_ruby("ＡＢＣ", 2))
check("１２３ ruby at level 1",   has_ruby("１２３", 1))
check("１２３ plain at level 2",  not has_ruby("１２３", 2))

io.write("== all-kana (chōonpu) never annotated ==\n")
check("すごいなー plain at level 1", not has_ruby("すごいなー", 1))
check("はあー plain at level 1",     not has_ruby("はあー", 1))
check("あー plain at level 1",       not has_ruby("あー", 1))

io.write("== monotonic ruby count over sample lines ==\n")
local samples = {}
do
    local fh = assert(io.open(here .. "/samples.txt", "rb"))
    local data = fh:read("*a"); fh:close()
    for line in (data:gsub("\n$", "") .. "\n"):gmatch("(.-)\n") do samples[#samples + 1] = line end
end
local prev
for mg = 1, 9 do
    tok:setMinGrade(mg)
    local total = 0
    for _, s in ipairs(samples) do total = total + ruby_count(tok:annotate(s)) end
    io.write(string.format("  level %d: %d ruby\n", mg, total))
    if prev and total > prev then fail = fail + 1; io.write("  FAIL not monotonic at level " .. mg .. "\n") end
    prev = total
end

io.write(fail == 0 and "\nselective: ALL OK\n" or ("\nselective: " .. fail .. " FAILED\n"))
os.exit(fail == 0 and 0 or 1)
