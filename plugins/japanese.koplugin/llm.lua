--- Optional LLM grammar-analysis client (OpenAI-compatible chat API).
--
-- Sends the tapped word to a user-configured chat-completions endpoint and
-- returns a structured grammar analysis.  Used only when the user has set an
-- endpoint + API key and the device is online; otherwise the section is omitted.
--
-- The networking lives in query(); everything else (prompt building, response
-- parsing, the conjugation-agreement check) is pure and unit-tested under stock
-- lua5.3 (see tools/run_llm_test.lua).  Works with any OpenAI-compatible server
-- (OpenAI, OpenRouter, Azure, a local Ollama/LM Studio, …).
--
-- @module koplugin.japanese.llm

local LLM = {}

-- The system prompt (the user's "Japanese Conjugation Master" brief, trimmed for
-- a reading popup).  It must keep the labelled fields so we can parse the
-- conjugation form back out for the agreement check.
LLM.SYSTEM_PROMPT = [[
You are a Japanese conjugation and grammar analyst. Given a Japanese word or
phrase, reply concisely (shown in a small e-reader popup) with these labelled
lines, in THIS exact order, and OMIT any line whose value would be "n/a", "none"
or unknown:

Word: <the exact input word/phrase>
Dictionary Form: <base/dictionary form, or "already dictionary form">
Conjugation Form: <the single most likely grammatical form, e.g. "causative-passive, polite, past">
Meaning: <natural English translation; note key nuances briefly>
Part of Speech: <noun / pronoun / particle / i-adjective / na-adjective / verb / adverb / expression / other>
Verb/Adjective Type: <ichidan (る-verb) / godan (う-verb) / irregular / i-adjective / na-adjective>
Stem: <verb/adjective stem>
Formality: <casual / polite / honorific / humble / literary / archaic>
JLPT: <N5–N1 if reasonably known>

Then these sections (omit any that do not apply), each labelled on its own line:
Conjugation Breakdown: a short step-by-step from the dictionary form to the input.
Usage Notes: 1–2 short notes (frequency, common contexts, key restrictions).
Examples: 2 natural Japanese sentences, each with an English translation.
Common Confusions: forms learners often confuse with this input.

Be precise. If multiple readings are possible, give the most likely first and
note the alternatives briefly. Do not use Markdown headings; keep it compact.
]]

--- Drop labelled lines whose value is "n/a"/"none"/unknown (safety net in case
-- the model includes them anyway).  Pure → unit-tested.
function LLM.strip_na(text)
    if type(text) ~= "string" then return text end
    local out = {}
    for line in (text .. "\n"):gmatch("(.-)\n") do
        local value = line:match("^[^:]+:%s*(.-)%s*$")
        local v = value and value:lower()
        if not (v == "n/a" or v == "n/a." or v == "none" or v == "unknown" or v == "-") then
            out[#out + 1] = line
        end
    end
    return (table.concat(out, "\n"):gsub("%s+$", ""))
end

-- Default model per provider (both have free/cheap tiers).
local DEFAULT_MODEL = { openai = "gpt-4o-mini", gemini = "gemini-2.0-flash" }
local GEMINI_BASE = "https://generativelanguage.googleapis.com/v1beta/models/"

--- The model to use (the configured one, else the provider default).
function LLM.model_for(opts)
    if opts.model and opts.model ~= "" then return opts.model end
    return DEFAULT_MODEL[opts.provider or "openai"] or DEFAULT_MODEL.openai
end

--- Whether the LLM section can run (key set; OpenAI also needs an endpoint —
-- Gemini derives its endpoint from the model).
function LLM.is_configured(opts)
    if opts == nil then return false end
    if not (type(opts.api_key) == "string" and opts.api_key ~= "") then return false end
    if (opts.provider or "openai") == "gemini" then return true end
    return type(opts.endpoint) == "string" and opts.endpoint ~= ""
end

--- Chat messages for a surface form.
function LLM.build_messages(surface)
    return {
        { role = "system", content = LLM.SYSTEM_PROMPT },
        { role = "user", content = surface },
    }
end

--- The OpenAI-compatible request body table (encoded to JSON by query()).
function LLM.build_body(opts, surface)
    return {
        model = LLM.model_for(opts),
        messages = LLM.build_messages(surface),
        temperature = 0.2,
        max_tokens = 800,
        stream = false,
    }
end

--- Build the provider-specific request: url, headers, body table.
function LLM.build_request(opts, surface)
    if (opts.provider or "openai") == "gemini" then
        -- Always derive the Gemini URL from the model; ignore the shared (OpenAI)
        -- endpoint setting, which would otherwise corrupt the path and 404.
        return GEMINI_BASE .. LLM.model_for(opts) .. ":generateContent",
            {
                ["Content-Type"] = "application/json",
                ["x-goog-api-key"] = opts.api_key,
            },
            {
                systemInstruction = { parts = { { text = LLM.SYSTEM_PROMPT } } },
                contents = { { parts = { { text = surface } } } },
                generationConfig = { temperature = 0.2, maxOutputTokens = 800 },
            }
    end
    return opts.endpoint,
        {
            ["Content-Type"] = "application/json",
            ["Authorization"] = "Bearer " .. opts.api_key,
        },
        LLM.build_body(opts, surface)
end

--- Extract the assistant text from a decoded response (OpenAI or Gemini shape).
function LLM.parse_response(decoded, provider)
    if type(decoded) ~= "table" then return nil end
    if (provider or "openai") == "gemini" then
        local c = decoded.candidates
        if type(c) == "table" and c[1] and c[1].content and c[1].content.parts
                and c[1].content.parts[1] then
            return c[1].content.parts[1].text
        end
    else
        local choices = decoded.choices
        if type(choices) == "table" and choices[1] and choices[1].message then
            return choices[1].message.content
        end
    end
    -- Both shapes surface errors as {error={message=...}}.
    if type(decoded.error) == "table" then return nil, decoded.error.message end
    return nil
end

--- Query the configured endpoint.  Returns ai_text, or nil + error string.
-- Networking only; lazy-requires KOReader modules so the rest stays testable.
function LLM.query(opts, surface)
    local rapidjson = require("rapidjson")
    local ltn12 = require("ltn12")
    local socketutil = require("socketutil")
    local logger = require("logger")

    local url, headers, body_table = LLM.build_request(opts, surface)
    local body = rapidjson.encode(body_table)
    headers["Content-Length"] = tostring(#body)
    local sink = {}
    local requester = url:match("^https://") and require("ssl.https") or require("socket.http")
    -- Generous timeouts: a non-streaming LLM can take a while to generate before
    -- it sends the response (block = max wait for data, total = overall cap).
    socketutil:set_timeout(90, 120)
    -- Table-form request returns (1, code, headers, status) on success, or
    -- (nil, errmsg) on a network failure (body is written to the sink).
    local ok, res, code = pcall(requester.request, {
        url = url,
        method = "POST",
        headers = headers,
        source = ltn12.source.string(body),
        sink = ltn12.sink.table(sink),
    })
    socketutil:reset_timeout()
    if not ok then
        logger.err("japanese.koplugin llm: request error:", res)
        return nil, tostring(res)
    end
    if res == nil then
        return nil, tostring(code) -- network failure: code holds the message
    end
    if code ~= 200 then
        -- Surface the server's error message (Gemini/OpenAI return a JSON error)
        -- so misconfiguration (wrong model, bad key, …) is visible to the user.
        local raw = table.concat(sink)
        local ok_d, decoded = pcall(rapidjson.decode, raw)
        local msg = ok_d and type(decoded) == "table" and decoded.error and decoded.error.message
        return nil, "HTTP " .. tostring(code)
            .. (msg and (": " .. msg) or (raw ~= "" and (": " .. raw:sub(1, 300)) or ""))
    end
    local ok2, decoded = pcall(rapidjson.decode, table.concat(sink))
    if not ok2 then
        return nil, "invalid JSON response"
    end
    return LLM.parse_response(decoded, opts.provider)
end

return LLM
