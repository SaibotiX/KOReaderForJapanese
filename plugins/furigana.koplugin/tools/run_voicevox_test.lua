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
local timeout_calls = {}
package.preload["socketutil"] = function()
    return {
        set_timeout = function(_, block, total)
            timeout_calls[#timeout_calls + 1] = { block, total }
        end,
        reset_timeout = function() end,
    }
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

-- Timeouts: audio_query stays snappy (it is the reachability check), while
-- synthesis must be allowed to run to completion — the engine computes the
-- whole WAV before sending a byte, so an idle socket is NOT a dead one.
check(#timeout_calls == 2
        and timeout_calls[1][1] == VoiceVox.QUERY_BLOCK_TIMEOUT
        and timeout_calls[1][2] == VoiceVox.QUERY_TOTAL_TIMEOUT,
    "audio_query uses the short reachability timeouts")
check(timeout_calls[2][1] == VoiceVox.SYNTH_BLOCK_TIMEOUT
        and timeout_calls[2][2] == VoiceVox.SYNTH_TOTAL_TIMEOUT,
    "synthesis uses the huge run-to-completion timeouts")
check(VoiceVox.SYNTH_BLOCK_TIMEOUT >= 600,
    "synthesis block timeout is at least 10 minutes (no premature 'timeout' error)")

-- Background workers may override the synthesis timeouts per request.
timeout_calls = {}
VoiceVox.fetch({ url = "http://x", speaker = 1,
    synth_block_timeout = 33, synth_total_timeout = 99 }, "詞", out, make_requester({
    { code = 200, body = "{}" },
    { code = 200, body = "RIFF" },
}))
check(timeout_calls[2][1] == 33 and timeout_calls[2][2] == 99,
    "opts can override the synthesis timeouts (precache worker)")
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

-- --------------------------------------------------- loudness normalization --
-- The engine renders each request at a different level; normalizeLoudness
-- scales the 16-bit PCM so the speech RMS sits at NORMALIZE_TARGET_DB
-- (-20 dBFS => 3276.8 in sample units), without ever clipping a peak.

local function u16le(v) return string.char(v % 256, math.floor(v / 256) % 256) end
local function u32le(v)
    return string.char(v % 256, math.floor(v / 256) % 256,
        math.floor(v / 65536) % 256, math.floor(v / 16777216) % 256)
end
local function make_wav(samples)
    local data = {}
    for _, s in ipairs(samples) do
        data[#data + 1] = u16le(s < 0 and s + 65536 or s)
    end
    data = table.concat(data)
    local fmt = u16le(1) .. u16le(1) .. u32le(24000) .. u32le(48000) .. u16le(2) .. u16le(16)
    return "RIFF" .. u32le(4 + 8 + #fmt + 8 + #data) .. "WAVE"
        .. "fmt " .. u32le(#fmt) .. fmt .. "data" .. u32le(#data) .. data
end
local function samples_of(wav)
    local out2 = {}
    for i = 45, #wav - 1, 2 do
        local a, b = wav:byte(i, i + 1)
        local s = a + b * 256
        out2[#out2 + 1] = s >= 32768 and s - 65536 or s
    end
    return out2
end

local quiet = {}
for i = 1, 200 do quiet[i] = (i % 2 == 0) and 1000 or -1000 end
local quiet_wav = make_wav(quiet)
local norm = VoiceVox.normalizeLoudness(quiet_wav)
check(norm ~= nil and #norm == #quiet_wav,
    "quiet audio is rewritten at the same byte length")
local ns = samples_of(norm)
check(ns[1] == -3277 and ns[2] == 3277,
    "quiet speech is boosted to the target level: " .. tostring(ns[2]))

local loud = {}
for i = 1, 200 do loud[i] = (i % 2 == 0) and 20000 or -20000 end
ns = samples_of(VoiceVox.normalizeLoudness(make_wav(loud)))
check(ns[1] == -5000 and ns[2] == 5000,
    "very loud speech is attenuated (down to the min-gain clamp): " .. tostring(ns[2]))

local sparse = {}
for i = 1, 100 do sparse[i] = 0 end
sparse[50], sparse[51] = 16384, -16384
ns = samples_of(VoiceVox.normalizeLoudness(make_wav(sparse)))
check(ns[1] == 0 and ns[49] == 0, "silence stays silent")
check(ns[50] == 4096 and ns[51] == -4096,
    "the gain is measured on the speech only, pauses don't skew it: " .. tostring(ns[50]))

local peaky = {}
for i = 1, 200 do peaky[i] = (i % 2 == 0) and 2000 or -2000 end
peaky[100] = 30000
ns = samples_of(VoiceVox.normalizeLoudness(make_wav(peaky)))
local max_s = 0
for _, s in ipairs(ns) do
    if s < 0 then s = -s end
    if s > max_s then max_s = s end
end
check(max_s <= math.floor(VoiceVox.NORMALIZE_PEAK * 32767) + 1,
    "a hot peak caps the gain so nothing clips: max " .. max_s)

local at_target = {}
for i = 1, 200 do at_target[i] = (i % 2 == 0) and 3277 or -3277 end
check(VoiceVox.normalizeLoudness(make_wav(at_target)) == nil,
    "audio already at the target level is not rewritten")

check(VoiceVox.normalizeLoudness("RIFFwavbytes") == nil,
    "non-PCM bytes are refused (caller keeps the original)")

-- fetch() levels what it writes; opts.normalize = false keeps the raw audio.
local req7 = make_requester({
    { code = 200, body = "{}" },
    { code = 200, body = quiet_wav },
})
VoiceVox.fetch({ url = "http://x", speaker = 1 }, "静か", out, req7)
local f7 = io.open(out, "rb")
local written7 = f7:read("*a")
f7:close()
check(written7 ~= quiet_wav and samples_of(written7)[2] == 3277,
    "fetch writes loudness-leveled audio by default")

local req8 = make_requester({
    { code = 200, body = "{}" },
    { code = 200, body = quiet_wav },
})
VoiceVox.fetch({ url = "http://x", speaker = 1, normalize = false }, "静か", out, req8)
f7 = io.open(out, "rb")
written7 = f7:read("*a")
f7:close()
check(written7 == quiet_wav, "opts.normalize = false writes the raw engine audio")
os.remove(out)

print(failures == 0 and "\nALL TESTS PASSED" or ("\n" .. failures .. " TEST(S) FAILED"))
os.exit(failures == 0 and 0 or 1)
