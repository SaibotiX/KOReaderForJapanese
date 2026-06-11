-- Tests for voicevox.lua (word-audio): URL building/encoding and the
-- audio_query → synthesis → WAV-file flow, with an injected HTTP requester.
-- Pure Lua, no KOReader or network needed:
--   lua tools/run_voicevox_test.lua

local here = arg[0]:match("^(.*)/[^/]*$") or "."
package.path = here .. "/../?.lua;" .. package.path

-- ltn12/socketutil stubs (only what voicevox.lua touches).
package.preload["ltn12"] = function()
    return {
        source = { string = function(s) return { __body = s } end },
        sink = { table = function(t) return t end },
    }
end
package.preload["socketutil"] = function()
    return { set_timeout = function() end, reset_timeout = function() end }
end

local VoiceVox = require("voicevox")

local failures = 0
local function check(cond, msg)
    if cond then
        print("ok   - " .. msg)
    else
        failures = failures + 1
        print("FAIL - " .. msg)
    end
end

-- ------------------------------------------------------------- urlencode --

check(VoiceVox.urlencode("abc-123_~.") == "abc-123_~.",
    "urlencode keeps unreserved characters")
check(VoiceVox.urlencode("食べる") == "%E9%A3%9F%E3%81%B9%E3%82%8B",
    "urlencode percent-encodes UTF-8 bytes: " .. VoiceVox.urlencode("食べる"))
check(VoiceVox.urlencode("a b&c") == "a%20b%26c",
    "urlencode escapes spaces and ampersands")

-- --------------------------------------------------------------- fetch -----

-- A scripted requester: pops one response per request, records each request.
local function make_requester(responses)
    local r = { calls = {} }
    r.request = function(args)
        local body
        if args.source and args.source.__body then body = args.source.__body end
        table.insert(r.calls, {
            url = args.url, method = args.method, headers = args.headers, body = body,
        })
        local resp = table.remove(responses, 1)
        if not resp then return nil, "no scripted response" end
        if resp.transport_error then return nil, resp.transport_error end
        if args.sink then table.insert(args.sink, resp.body or "") end
        return 1, resp.code or 200
    end
    return r
end

local out = os.tmpname()
local opts = { url = "http://pc.local:50021/", speaker = 8 }

-- Happy path: query json passes through to synthesis; wav written.
local req = make_requester({
    { code = 200, body = '{"accent_phrases":[]}' },
    { code = 200, body = "RIFFwavbytes" },
})
local ok, err = VoiceVox.fetch(opts, "食べる", out, req)
check(ok == true, "fetch succeeds: " .. tostring(err))
check(#req.calls == 2, "exactly two requests (audio_query, synthesis)")
check(req.calls[1].url == "http://pc.local:50021/audio_query?speaker=8&text=%E9%A3%9F%E3%81%B9%E3%82%8B",
    "audio_query URL: trailing slash stripped, speaker + encoded text: " .. req.calls[1].url)
check(req.calls[1].method == "POST" and req.calls[1].body == nil
    and req.calls[1].headers["Content-Length"] == "0",
    "audio_query is an empty POST with Content-Length 0")
check(req.calls[2].url == "http://pc.local:50021/synthesis?speaker=8",
    "synthesis URL carries the speaker")
check(req.calls[2].body == '{"accent_phrases":[]}'
    and req.calls[2].headers["Content-Type"] == "application/json"
    and req.calls[2].headers["Content-Length"] == tostring(#'{"accent_phrases":[]}'),
    "synthesis POSTs the query JSON verbatim as application/json")
local f = io.open(out, "rb")
local written = f:read("*a")
f:close()
check(written == "RIFFwavbytes", "WAV bytes written to the output file")
os.remove(out)

-- Error paths.
local ok2, err2 = VoiceVox.fetch(opts, "言葉", out,
    make_requester({ { code = 422, body = "detail" } }))
check(ok2 == nil and err2:match("audio_query failed") and err2:match("HTTP 422"),
    "non-200 audio_query is reported: " .. tostring(err2))

local ok3, err3 = VoiceVox.fetch(opts, "言葉", out,
    make_requester({ { transport_error = "connection refused" } }))
check(ok3 == nil and err3:match("connection refused"),
    "transport errors are reported: " .. tostring(err3))

local ok4, err4 = VoiceVox.fetch(opts, "言葉", out, make_requester({
    { code = 200, body = '{"q":1}' },
    { code = 500, body = "" },
}))
check(ok4 == nil and err4:match("synthesis failed") and err4:match("HTTP 500"),
    "synthesis failure is reported: " .. tostring(err4))

local ok5, err5 = VoiceVox.fetch({ url = "" }, "言葉", out, make_requester({}))
check(ok5 == nil and err5:match("no VOICEVOX server URL"),
    "empty URL is rejected before any request")

-- Default speaker when unset/garbage.
local req6 = make_requester({
    { code = 200, body = "{}" },
    { code = 200, body = "RIFF" },
})
VoiceVox.fetch({ url = "http://x", speaker = "not a number" }, "詞", out, req6)
check(req6.calls[1].url:match("speaker=" .. VoiceVox.DEFAULT_SPEAKER),
    "non-numeric speaker falls back to the default")
os.remove(out)

print(failures == 0 and "\nALL TESTS PASSED" or ("\n" .. failures .. " TEST(S) FAILED"))
os.exit(failures == 0 and 0 or 1)
