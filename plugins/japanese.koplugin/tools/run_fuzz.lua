-- Large-scale parity runner: diff the Lua conjugator against the Python engine
-- over the fuzz sample set produced by parity_fuzz.py.  Exits non-zero (and
-- prints up to 40 mismatches) if any line differs.
--
-- Usage (from tools/):  lua5.3 run_fuzz.lua   (run parity_fuzz.py first)

local here = arg[0]:match("^(.*)/[^/]*$") or "."
package.path = here .. "/?.lua;" .. here .. "/../?.lua;" .. package.path

local Conjugator = require("conjugator")
local json_min = require("json_min")
local PosDictFixture = require("posdict_fixture")

Conjugator.configure(
    json_min.load_file(here .. "/../yomichan-deinflect.json"),
    PosDictFixture.new(here .. "/fuzz_pos_fixture.lua"))

local function read_lines(path)
    local fh = assert(io.open(path, "rb"))
    local data = fh:read("*a"); fh:close()
    local out = {}
    for line in (data:gsub("\n$", "") .. "\n"):gmatch("(.-)\n") do
        if line ~= "" then out[#out + 1] = line end
    end
    return out
end

local samples = read_lines(here .. "/fuzz_samples.txt")
local expected = assert(loadfile(here .. "/fuzz_expected.lua"))()

local pass, fail, shown = 0, 0, 0
for i = 1, #samples do
    local got = Conjugator.conjugate_field("「" .. samples[i] .. "」")
    if got == expected[i] then
        pass = pass + 1
    else
        fail = fail + 1
        if shown < 40 then
            shown = shown + 1
            io.write(string.format("MISMATCH [%s]\n  want: %s\n  got : %s\n",
                samples[i], tostring(expected[i]), tostring(got)))
        end
    end
end

io.write(string.format("\n%d passed, %d failed (of %d)\n", pass, fail, #samples))
os.exit(fail == 0 and 0 or 1)
