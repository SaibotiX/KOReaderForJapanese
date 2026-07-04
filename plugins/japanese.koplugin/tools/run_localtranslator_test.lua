-- Tests for localtranslator.lua (offline JA→EN through a local LLM server):
-- request-body building/escaping, reply parsing, and the translate flow with
-- an injected HTTP requester. Pure Lua, no KOReader or network needed:
--   lua tools/run_localtranslator_test.lua

local here = arg[0]:match("^(.*)/[^/]*$") or "."
package.path = here .. "/../?.lua;" .. package.path

package.preload["ltn12"] = function()
    return {
        source = { string = function(s) return { __body = s } end },
        sink = { table = function(t) return t end },
    }
end
package.preload["socketutil"] = function()
    return { set_timeout = function() end, reset_timeout = function() end }
end
-- A small real-enough JSON decoder for the reply parsing (the plugin's own
-- json_min is load-from-file only; KOReader provides "json" at runtime).
package.preload["json"] = function()
    return {
        decode = function(s)
            -- Only the shapes the tests feed: OpenAI chat replies, plain
            -- ("message") and streamed ("delta") chunks.
            local content = s:match('"content"%s*:%s*"(.-[^\\])"')
                or (s:find('"content"%s*:%s*""') and "")
            if s:find('"choices"') and content then
                content = content:gsub('\\"', '"'):gsub("\\n", "\n"):gsub("\\\\", "\\")
                local msg = { content = content }
                if s:find('"delta"') then
                    return { choices = { { delta = msg } } }
                end
                return { choices = { { message = msg } } }
            end
            if s:find('"delta"%s*:%s*{%s*}') or s:find('"delta":{"role"') then
                return { choices = { { delta = {} } } }
            end
            if s == "{}" then return {} end
            error("bad json")
        end,
    }
end

local LT = require("localtranslator")

local failures = 0
local function check(cond, msg)
    if cond then
        print("ok   - " .. msg)
    else
        failures = failures + 1
        print("FAIL - " .. msg)
    end
end

-- ------------------------------------------------------------- buildBody --

local body = LT.buildBody('猫が"好き"\nです。')
check(body:find('"content":"Translate to English."', 1, true) ~= nil,
    "buildBody carries the model's expected system prompt")
check(body:find('猫が\\"好き\\"\\u000A', 1, true) ~= nil
    or body:find('猫が\\"好き\\"', 1, true) ~= nil,
    "buildBody escapes quotes and control characters")
check(body:find('"max_tokens":' .. LT.MAX_TOKENS, 1, true) ~= nil
    and body:find('"stream":true', 1, true) ~= nil
    and body:find('"cache_prompt":true', 1, true) ~= nil,
    "buildBody sets bounded, streaming decoding with a warm prompt cache")
check(LT.buildBody("言葉", 512):find('"max_tokens":512', 1, true) ~= nil,
    "buildBody honors a max_tokens override (long selections)")

-- ------------------------------------------------------------ parseReply --

check(LT.parseReply('{"choices":[{"message":{"content":"I like cats."}}]}')
    == "I like cats.", "parseReply extracts the assistant message")
check(LT.parseReply("not json") == nil, "parseReply refuses garbage")
check(LT.parseReply("{}") == nil, "parseReply refuses replies without choices")

-- ------------------------------------------------------ parseStreamReply --

local sse = table.concat({
    'data: {"choices":[{"delta":{"role":"assistant"}}]}',
    'data: {"choices":[{"delta":{"content":"I like"}}]}',
    'data: {"choices":[{"delta":{"content":" cats."}}]}',
    "data: [DONE]",
}, "\n\n")
check(LT.parseStreamReply(sse) == "I like cats.",
    "parseStreamReply reassembles the streamed deltas")
check(LT.parseStreamReply('{"choices":[{"message":{"content":"plain"}}]}')
    == "plain", "parseStreamReply falls through to plain replies")
check(LT.parseStreamReply("data: not json\n\ndata: [DONE]") == nil,
    "parseStreamReply refuses an unparseable stream")

-- ------------------------------------------------------------- translate --

local function make_requester(responses)
    local r = { calls = {} }
    r.request = function(args)
        table.insert(r.calls, {
            url = args.url,
            method = args.method,
            headers = args.headers,
            body = args.source and args.source.__body,
        })
        local resp = table.remove(responses, 1)
        if not resp then return nil, "no scripted response" end
        if resp.transport_error then return nil, resp.transport_error end
        if args.sink then table.insert(args.sink, resp.body or "") end
        return 1, resp.code or 200
    end
    return r
end

local req = make_requester({
    { code = 200, body = '{"choices":[{"message":{"content":"  I like cats.\\n"}}]}' },
})
local tr, err = LT.translate({ url = "http://pc:8087/" }, "猫が好きです。", req)
check(tr == "I like cats.", "translate returns the trimmed translation: " .. tostring(err))

local sse_req = make_requester({
    { code = 200, body = 'data: {"choices":[{"delta":{"content":"Streamed"}}]}\n\n'
        .. 'data: {"choices":[{"delta":{"content":" reply."}}]}\n\ndata: [DONE]\n\n' },
})
local tr_sse, err_sse = LT.translate({ url = "http://pc:8087" }, "文。", sse_req)
check(tr_sse == "Streamed reply.",
    "translate reassembles a streamed reply: " .. tostring(err_sse))
check(req.calls[1].url == "http://pc:8087/v1/chat/completions"
    and req.calls[1].method == "POST"
    and req.calls[1].headers["Content-Type"] == "application/json",
    "translate POSTs to the OpenAI-compatible endpoint (trailing slash stripped)")
check(req.calls[1].body:find("猫が好きです。", 1, true) ~= nil,
    "the sentence travels in the request body")

local tr2, err2 = LT.translate({ url = "http://pc:8087" }, "言葉",
    make_requester({ { code = 503, body = "" } }))
check(tr2 == nil and err2 == "HTTP 503", "server errors are reported: " .. tostring(err2))

local tr3, err3 = LT.translate({ url = "http://pc:8087" }, "言葉",
    make_requester({ { transport_error = "connection refused" } }))
check(tr3 == nil and err3:find("connection refused") ~= nil,
    "transport errors are reported")

local tr4, err4 = LT.translate({ url = "" }, "言葉", make_requester({}))
check(tr4 == nil and err4:find("no local translation server") ~= nil,
    "an empty URL is rejected before any request")

local tr5, err5 = LT.translate({ url = "http://pc:8087" }, "言葉",
    make_requester({ { code = 200, body = '{"choices":[{"message":{"content":"   "}}]}' } }))
check(tr5 == nil and err5 == "empty translation",
    "a blank reply is treated as failure (callers fall back to Google)")

print(failures == 0 and "\nALL TESTS PASSED" or ("\n" .. failures .. " TEST(S) FAILED"))
os.exit(failures == 0 and 0 or 1)
