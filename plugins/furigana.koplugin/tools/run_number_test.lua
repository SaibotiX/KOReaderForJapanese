-- Verify multi-digit full-width numbers are read as whole Japanese numerals.
package.path = package.path .. ";./?.lua"
local Tokenizer = require("tokenizer")
local here = arg[0]:match("^(.*)/[^/]*$") or "."
local plugin_dir = here:match("^(.*)/tools$") or (here .. "/..")
local tok = Tokenizer.new(plugin_dir .. "/dict") -- default level = All

-- ascii digit string -> full-width UTF-8 (０-９)
local function fw(s)
    local t = {}
    for i = 1, #s do t[i] = string.char(0xEF, 0xBC, 0x90 + (s:byte(i) - 48)) end
    return table.concat(t)
end

local cases = {
    { "10", "じゅう" }, { "11", "じゅういち" }, { "20", "にじゅう" }, { "21", "にじゅういち" },
    { "100", "ひゃく" }, { "200", "にひゃく" }, { "300", "さんびゃく" }, { "600", "ろっぴゃく" },
    { "800", "はっぴゃく" }, { "1000", "せん" }, { "2000", "にせん" }, { "3000", "さんぜん" },
    { "8000", "はっせん" }, { "2023", "にせんにじゅうさん" }, { "10000", "いちまん" },
    { "12345", "いちまんにせんさんびゃくよんじゅうご" }, { "1000000", "ひゃくまん" },
    { "100000000", "いちおく" },
}

local fail = 0
for _, c in ipairs(cases) do
    local num, reading = c[1], c[2]
    local got = tok:annotate(fw(num))
    local want = "<ruby>" .. fw(num) .. "<rt>" .. reading .. "</rt></ruby>"
    if got == want then
        io.write("  OK  " .. num .. " -> " .. reading .. "\n")
    else
        fail = fail + 1
        io.write("  FAIL " .. num .. "\n    want: " .. want .. "\n    got : " .. got .. "\n")
    end
end

-- Leading-zero runs stay per-digit (not composed as a cardinal number).
do
    local got = tok:annotate(fw("007"))
    if got:find("ぜろ", 1, true) and got:find("<ruby>" .. fw("0"), 1, true) then
        io.write("  OK  007 stays per-digit\n")
    else
        fail = fail + 1
        io.write("  FAIL 007 should stay per-digit, got: " .. got .. "\n")
    end
end

io.write(fail == 0 and "\nnumbers: ALL OK\n" or ("\nnumbers: " .. fail .. " FAILED\n"))
os.exit(fail == 0 and 0 or 1)
