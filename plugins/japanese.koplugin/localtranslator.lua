--- Offline JA→EN translation through a local LLM server.
--
-- Talks to any OpenAI-compatible chat endpoint; the intended engine is
-- llama.cpp's llama-server running LiquidAI's LFM2-350M-ENJP-MT — a
-- 350M-parameter model tuned exclusively for Japanese↔English translation
-- (~230 MB as Q4_K_M GGUF, LFM Open License v1.0, redistributable). It was
-- chosen over Bergamot/Argos/NLLB/ML Kit because it is the only option that
-- is simultaneously LLM-class in naturalness (what literary text needs),
-- small enough for an e-reader, permissively licensed, and servable over
-- localhost HTTP with the same companion pattern as VOICEVOX. Run it on the
-- PC with tools/lfm2-translate-serve.sh, or on the device via a companion
-- app serving 127.0.0.1.
--
-- translate() blocks on the network: call it inside a subprocess (the
-- sentence-splitting fetch worker does; so does the menu's test button).
-- The HTTP requester is injectable so the flow is unit-testable standalone:
--   lua tools/run_localtranslator_test.lua
--
-- @module koplugin.japanese.localtranslator

local LocalTranslator = {}

LocalTranslator.DEFAULT_URL = "http://127.0.0.1:8087"
-- The model card's recommended instruction and sampling.
LocalTranslator.SYSTEM_PROMPT = "Translate to English."
LocalTranslator.TEMPERATURE = 0.5
LocalTranslator.MIN_P = 0.1
LocalTranslator.REPEAT_PENALTY = 1.05
LocalTranslator.MAX_TOKENS = 256
-- The reply is streamed (SSE), which matters twice on weak hardware: tokens
-- trickle in continuously, so the block timeout only has to cover the first
-- token / gaps between tokens — a long generation no longer trips it midway
-- (non-streamed replies were one long silence up to the full generation
-- time); and when the caller's subprocess is killed (the sentence reader
-- preempting a stale sentence), the dropped connection makes llama-server
-- cancel the generation within a token instead of grinding through it while
-- the current sentence waits.
LocalTranslator.BLOCK_TIMEOUT = 30
LocalTranslator.TOTAL_TIMEOUT = 120

local function json_escape(s)
    s = s:gsub("\\", "\\\\"):gsub('"', '\\"')
    s = s:gsub("[%z\1-\31]", function(c)
        return string.format("\\u%04X", c:byte())
    end)
    return s
end

--- The chat-completions request body for one sentence (pure; tested).
-- `max_tokens` (optional) overrides the default cap — longer selections get
-- more room. cache_prompt keeps the shared system-prompt KV warm across
-- requests on llama-server.
function LocalTranslator.buildBody(text, max_tokens)
    return string.format(
        '{"messages":[{"role":"system","content":"%s"},{"role":"user","content":"%s"}],'
            .. '"temperature":%.2f,"min_p":%.2f,"repeat_penalty":%.2f,'
            .. '"max_tokens":%d,"cache_prompt":true,"stream":true}',
        json_escape(LocalTranslator.SYSTEM_PROMPT), json_escape(text),
        LocalTranslator.TEMPERATURE, LocalTranslator.MIN_P,
        LocalTranslator.REPEAT_PENALTY, max_tokens or LocalTranslator.MAX_TOKENS)
end

--- choices[1].message.content of a plain (non-streamed) OpenAI-style reply,
-- or nil.
function LocalTranslator.parseReply(body)
    local ok, JSON = pcall(require, "json")
    if not (ok and JSON and JSON.decode) then return nil end
    local ok2, t = pcall(JSON.decode, body)
    if not (ok2 and type(t) == "table") then return nil end
    local choice = type(t.choices) == "table" and t.choices[1]
    local content = type(choice) == "table" and type(choice.message) == "table"
        and choice.message.content
    if type(content) ~= "string" then return nil end
    return content
end

--- Reassemble the content of a streamed (SSE, "data: {…}" lines) reply;
-- bodies that are one plain JSON object (a server ignoring "stream", or an
-- error reply) fall through to parseReply. Returns nil when nothing
-- parseable is found.
function LocalTranslator.parseStreamReply(body)
    if not body:match("^%s*data:") then
        return LocalTranslator.parseReply(body)
    end
    local ok, JSON = pcall(require, "json")
    if not (ok and JSON and JSON.decode) then return nil end
    local parts = {}
    for line in body:gmatch("[^\r\n]+") do
        local payload = line:match("^data:%s*(.*)")
        if payload and payload ~= "" and payload ~= "[DONE]" then
            local ok2, t = pcall(JSON.decode, payload)
            if ok2 and type(t) == "table" then
                local choice = type(t.choices) == "table" and t.choices[1]
                -- Streamed chunks carry deltas; some servers put the full
                -- message in the last chunk instead.
                local msg = type(choice) == "table"
                    and (choice.delta or choice.message)
                local content = type(msg) == "table" and msg.content
                if type(content) == "string" then
                    parts[#parts + 1] = content
                end
            end
        end
    end
    if #parts == 0 then return nil end
    return table.concat(parts)
end

--- Translate `text` (JA) to English via the server at opts.url
-- (opts.max_tokens optionally widens the output cap for long selections).
-- Returns the translation, or nil and an error message.
function LocalTranslator.translate(opts, text, requester)
    requester = requester or require("socket.http")
    local ltn12 = require("ltn12")
    local socketutil = require("socketutil")

    local base = (opts and opts.url or ""):gsub("/+$", "")
    if base == "" then
        return nil, "no local translation server configured"
    end
    local body = LocalTranslator.buildBody(text, opts and opts.max_tokens)
    local sink = {}
    socketutil:set_timeout(LocalTranslator.BLOCK_TIMEOUT, LocalTranslator.TOTAL_TIMEOUT)
    local ok, res, code = pcall(requester.request, {
        url = base .. "/v1/chat/completions",
        method = "POST",
        headers = {
            ["Content-Type"] = "application/json",
            ["Content-Length"] = tostring(#body),
        },
        source = ltn12.source.string(body),
        sink = ltn12.sink.table(sink),
    })
    socketutil:reset_timeout()
    if not ok then
        return nil, tostring(res)
    end
    if not res then
        return nil, tostring(code)
    end
    if code ~= 200 then
        return nil, "HTTP " .. tostring(code)
    end
    local reply = LocalTranslator.parseStreamReply(table.concat(sink))
    if not reply then
        return nil, "unparseable server reply"
    end
    reply = reply:gsub("^%s+", ""):gsub("%s+$", "")
    if reply == "" then
        return nil, "empty translation"
    end
    return reply
end

return LocalTranslator
