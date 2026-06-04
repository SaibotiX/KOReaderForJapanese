-- Unit test for llm.lua's pure logic (no network): config check, message/body
-- building, response parsing, and the conjugation-agreement check (task 4).
-- Runs under stock lua5.3.  Exits non-zero on any failure.
--
-- Usage (from tools/):  lua5.3 run_llm_test.lua

local here = arg[0]:match("^(.*)/[^/]*$") or "."
package.path = here .. "/?.lua;" .. here .. "/../?.lua;" .. package.path

local LLM = require("llm")

local fails = 0
local function check(label, got, want)
    if got ~= want then
        fails = fails + 1
        io.write(string.format("FAIL %s\n  want: %s\n  got : %s\n", label, tostring(want), tostring(got)))
    end
end

-- is_configured
check("cfg.empty", LLM.is_configured({}), false)
check("cfg.no_key", LLM.is_configured({ endpoint = "https://x/v1" }), false)
check("cfg.ok", LLM.is_configured({ endpoint = "https://x/v1", api_key = "k" }), true)

-- build_messages / build_body
local msgs = LLM.build_messages("食べた")
check("messages.system", msgs[1].role, "system")
check("messages.user_role", msgs[2].role, "user")
check("messages.user_content", msgs[2].content, "食べた")
local body = LLM.build_body({ model = "" }, "食べた")
check("body.default_model", body.model, "gpt-4o-mini")
check("body.has_messages", #body.messages, 2)

-- parse_response
check("parse.ok", LLM.parse_response({ choices = { { message = { content = "hello" } } } }), "hello")
check("parse.none", LLM.parse_response({}), nil)
local _, perr = LLM.parse_response({ error = { message = "bad key" } })
check("parse.error_msg", perr, "bad key")

-- Provider support (Gemini vs OpenAI-compatible)
check("cfg.gemini_key_only", LLM.is_configured({ provider = "gemini", api_key = "k" }), true)
check("cfg.gemini_no_key", LLM.is_configured({ provider = "gemini" }), false)
check("model_for.gemini_default", LLM.model_for({ provider = "gemini" }), "gemini-2.0-flash")
check("model_for.openai_default", LLM.model_for({ provider = "openai" }), "gpt-4o-mini")
check("model_for.custom", LLM.model_for({ provider = "gemini", model = "gemini-1.5-flash" }), "gemini-1.5-flash")

local g_url, g_headers, g_body = LLM.build_request(
    { provider = "gemini", api_key = "KEY", model = "gemini-2.0-flash" }, "食べた")
check("gemini.url", g_url,
    "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent")
-- Regression: a stale (OpenAI) endpoint setting must NOT corrupt the Gemini URL.
local s_url = LLM.build_request({ provider = "gemini", api_key = "K", model = "gemini-2.0-flash",
    endpoint = "https://api.openai.com/v1/chat/completions" }, "x")
check("gemini.ignores_stale_endpoint", s_url,
    "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent")
check("gemini.auth_header", g_headers["x-goog-api-key"], "KEY")
check("gemini.has_system", g_body.systemInstruction.parts[1].text ~= nil, true)
check("gemini.user_text", g_body.contents[1].parts[1].text, "食べた")

local o_url, o_headers, o_body = LLM.build_request(
    { provider = "openai", endpoint = "https://x/v1/chat/completions", api_key = "KEY" }, "食べた")
check("openai.url", o_url, "https://x/v1/chat/completions")
check("openai.auth_header", o_headers["Authorization"], "Bearer KEY")
check("openai.user_msg", o_body.messages[2].content, "食べた")

-- parse_response per provider shape
check("parse.gemini", LLM.parse_response(
    { candidates = { { content = { parts = { { text = "G" } } } } } }, "gemini"), "G")
check("parse.openai_explicit", LLM.parse_response(
    { choices = { { message = { content = "O" } } } }, "openai"), "O")

-- strip_na: drop labelled n/a / none lines; keep real values and non-labelled lines.
local na_out = LLM.strip_na(table.concat({
    "Word: 食べる",
    "Verb/Adjective Type: n/a",
    "Meaning: to eat",
    "Stem: None",
    "Conjugation Breakdown: 食べる → 食べさせる → …",
}, "\n"))
check("strip_na.keeps_word", na_out:find("Word: 食べる", 1, true) ~= nil, true)
check("strip_na.keeps_meaning", na_out:find("Meaning: to eat", 1, true) ~= nil, true)
check("strip_na.drops_type", na_out:find("Verb/Adjective Type", 1, true), nil)
check("strip_na.drops_none_stem", na_out:find("Stem:", 1, true), nil)
check("strip_na.keeps_breakdown", na_out:find("Conjugation Breakdown", 1, true) ~= nil, true)

io.write(fails == 0 and "\nllm: all checks passed\n" or ("\nllm: " .. fails .. " FAILED\n"))
os.exit(fails == 0 and 0 or 1)
