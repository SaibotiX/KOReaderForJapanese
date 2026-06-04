-- Parity harness: run the Lua conjugator over samples.txt and compare each
-- line's conjugate_field output to the Python reference (expected.lua, produced
-- by gen_expected.py).  POS data comes from pos_fixture.lua via posdict_fixture,
-- so no SQLite binding is needed.
--
-- Usage (from anywhere; regenerate expected first with gen_expected.py):
--   luajit tools/run_test.lua
--
-- Exits non-zero if any line differs.

local here = arg[0]:match("^(.*)/[^/]*$") or "."
-- Resolve both the tools dir (fixtures) and the plugin dir (engine modules).
package.path = here .. "/?.lua;" .. here .. "/../?.lua;" .. package.path

local Conjugator = require("conjugator")
local json_min = require("json_min")
local PosDictFixture = require("posdict_fixture")

local rules = json_min.load_file(here .. "/../yomichan-deinflect.json")
local posdict = PosDictFixture.new(here .. "/pos_fixture.lua")
Conjugator.configure(rules, posdict)

local function read_lines(path)
    local fh = assert(io.open(path, "rb"))
    local data = fh:read("*a"); fh:close()
    data = data:gsub("\n$", "")
    local out = {}
    for line in (data .. "\n"):gmatch("(.-)\n") do
        if line ~= "" then out[#out + 1] = line end
    end
    return out
end

local function field(line)
    -- A line already containing 「 is a full field; otherwise wrap one token.
    if line:find("「", 1, true) then return line end
    return "「" .. line .. "」"
end

local samples = read_lines(here .. "/samples.txt")
local expected = assert(loadfile(here .. "/expected.lua"))()

local pass, fail = 0, 0
for i = 1, #samples do
    local got = Conjugator.conjugate_field(field(samples[i]))
    local want = expected[i]
    if got == want then
        pass = pass + 1
    else
        fail = fail + 1
        io.write(string.format(
            "MISMATCH line %d\n  input: %s\n  want : %s\n  got  : %s\n",
            i, samples[i], tostring(want), tostring(got)))
    end
end

io.write(string.format("\n%d passed, %d failed\n", pass, fail))
os.exit(fail == 0 and 0 or 1)
