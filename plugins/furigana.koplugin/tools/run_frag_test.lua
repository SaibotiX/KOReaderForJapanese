-- Compare the Lua annotate_fragment against wrapper.py's annotate_html_fragment
-- (frag_expected.lua). Usage:
--   /tmp/LuaJIT-2.1/src/luajit tools/run_frag_test.lua
package.path = package.path .. ";./?.lua"

local Tokenizer = require("tokenizer")
local EpubAnnotator = require("epubannotator")

local here = arg[0]:match("^(.*)/[^/]*$") or "."
local plugin_dir = here:match("^(.*)/tools$") or (here .. "/..")

local fh = assert(io.open(here .. "/sample.xhtml", "rb"))
local markup = fh:read("*a"); fh:close()

local want = assert(loadfile(here .. "/frag_expected.lua"))()

local tok = Tokenizer.new(plugin_dir .. "/dict")
local got = EpubAnnotator.annotate_fragment(tok, markup)

if got == want then
    io.write("fragment test: OK (" .. #got .. " bytes)\n")
    os.exit(0)
else
    io.write("fragment test: MISMATCH\n")
    for k = 1, math.max(#got, #want) do
        if got:byte(k) ~= want:byte(k) then
            io.write(string.format("  first diff at byte %d\n  want: ...%s...\n  got : ...%s...\n",
                k, (want:sub(k - 20, k + 30)), (got:sub(k - 20, k + 30))))
            break
        end
    end
    os.exit(1)
end
