-- Validation harness: run the Lua tokenizer over samples.txt and compare each
-- line's output to bridge.js ground truth (tools/expected.lua).
--
-- Usage (from the plugin dir):
--   luajit tools/run_test.lua
--
-- Exits non-zero if any line differs.

package.path = package.path .. ";./?.lua"

local Tokenizer = require("tokenizer")

local here = arg[0]:match("^(.*)/[^/]*$") or "."
local plugin_dir = here:match("^(.*)/tools$") or (here .. "/..")

local samples_path = arg[1] or (here .. "/samples.txt")
local expected_path = arg[2] or (here .. "/expected.lua")
local expected_block_path = arg[3] or (here .. "/expected_block.lua")

local function read_lines(path)
    local fh = assert(io.open(path, "rb"))
    local data = fh:read("*a"); fh:close()
    data = data:gsub("\n$", "")
    local out, n = {}, 0
    for line in (data .. "\n"):gmatch("(.-)\n") do n = n + 1; out[n] = line end
    return out
end

-- We now compose multi-digit numbers (２０００ -> にせん) where bridge.js reads
-- digit-by-digit. Normalize both sides by unwrapping any ruby whose base is all
-- full-width digits, so number rendering doesn't break tokenization parity (a
-- dedicated test checks the readings).
local function is_fw_digits(s)
    return s ~= "" and (s:gsub("\239\188[\144-\153]", "")) == ""
end
local function norm(s)
    return (s:gsub("<ruby>([^<]*)<rt>.-</rt></ruby>", function(base)
        if is_fw_digits(base) then return base end
        return nil
    end))
end

local samples = read_lines(samples_path)
local expected = assert(loadfile(expected_path))()

local tok = Tokenizer.new(plugin_dir .. "/dict")

local pass, fail = 0, 0
for i = 1, #samples do
    local got = tok:annotate(samples[i])
    local want = expected[i]
    if norm(got) == norm(want) then
        pass = pass + 1
    else
        fail = fail + 1
        io.write(string.format("MISMATCH line %d\n  input: %s\n  want : %s\n  got  : %s\n",
            i, samples[i], tostring(want), got))
    end
end

-- Multi-line block test: annotate the whole file as one block (exercises the
-- newline-preserving path in annotate()).
do
    local fh = assert(io.open(samples_path, "rb"))
    local full = fh:read("*a"); fh:close()
    full = full:gsub("\n$", "")
    local want = assert(loadfile(expected_block_path))()
    local got = tok:annotate(full)
    if norm(got) == norm(want) then
        pass = pass + 1
        io.write("block test: OK\n")
    else
        fail = fail + 1
        io.write("block test: MISMATCH\n")
        -- show first differing byte for debugging
        for k = 1, math.max(#got, #want) do
            if got:byte(k) ~= want:byte(k) then
                io.write(string.format("  first diff at byte %d\n  want: ...%s...\n  got : ...%s...\n",
                    k, want:sub(k - 10, k + 20), got:sub(k - 10, k + 20)))
                break
            end
        end
    end
end

io.write(string.format("\n%d passed, %d failed\n", pass, fail))
os.exit(fail == 0 and 0 or 1)
