--- Minimal VOICEVOX Engine client (https://voicevox.hiroshiba.jp/).
--
-- Talks to a self-hosted VOICEVOX engine (the user runs it on their PC or
-- wherever; default port 50021) with the standard two-step REST flow:
--   POST {base}/audio_query?speaker=N&text=...  -> synthesis parameters (JSON)
--   POST {base}/synthesis?speaker=N (JSON body) -> WAV bytes
-- The JSON is passed through verbatim, so no JSON parsing is needed.
--
-- fetch() blocks on the network: call it inside
-- Trapper:dismissableRunInSubprocess (see main.lua's playWordAudio).
-- The HTTP requester is injectable so the flow is unit-testable standalone:
--   lua tools/run_voicevox_test.lua
--
-- @module koplugin.furigana.voicevox

local VoiceVox = {}

VoiceVox.DEFAULT_URL = "http://127.0.0.1:50021"
VoiceVox.DEFAULT_SPEAKER = 3 -- ずんだもん (ノーマル), the engine's default poster child

-- audio_query is near-instant on any healthy engine, so it doubles as the
-- reachability check: keep it snappy so a dead/wrong server fails fast.
VoiceVox.QUERY_BLOCK_TIMEOUT = 20
VoiceVox.QUERY_TOTAL_TIMEOUT = 60
-- synthesis computes the whole WAV before sending the first byte, so on slow
-- (on-device) engines a long sentence/paragraph easily exceeds any "normal"
-- socket timeout while the connection sits idle. Once audio_query proved the
-- server alive, let synthesis run to completion: these are deliberately huge
-- (the fetch runs in a dismissable/background subprocess, so a stuck job can
-- always be cancelled by the user or its owner).
VoiceVox.SYNTH_BLOCK_TIMEOUT = 600
VoiceVox.SYNTH_TOTAL_TIMEOUT = 3600

--- Percent-encode a UTF-8 string for use in a query parameter.
function VoiceVox.urlencode(s)
    return (s:gsub("[^%w%-%._~]", function(c)
        return string.format("%%%02X", c:byte())
    end))
end

--- Synthesize `text` into a WAV file at `out_path`.
-- opts: { url = engine base URL, speaker = numeric speaker/style id }.
-- Returns true on success, or nil and an error message.
function VoiceVox.fetch(opts, text, out_path, requester)
    requester = requester or require("socket.http")
    local ltn12 = require("ltn12")
    local socketutil = require("socketutil")

    local base = (opts and opts.url or ""):gsub("/+$", "")
    if base == "" then
        return nil, "no VOICEVOX server URL configured"
    end
    local speaker = tonumber(opts.speaker) or VoiceVox.DEFAULT_SPEAKER

    local function post(url, body, block_timeout, total_timeout)
        local sink = {}
        local headers = { ["Content-Length"] = tostring(body and #body or 0) }
        if body then
            headers["Content-Type"] = "application/json"
        end
        socketutil:set_timeout(block_timeout, total_timeout)
        -- Table-form request returns (1, code, headers, status) on success,
        -- or (nil, error_message) on transport errors.
        local ok, res, code = pcall(requester.request, {
            url = url,
            method = "POST",
            headers = headers,
            source = body and ltn12.source.string(body) or nil,
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
        return table.concat(sink)
    end

    local query_url = ("%s/audio_query?speaker=%d&text=%s"):format(
        base, speaker, VoiceVox.urlencode(text))
    local query_json, qerr = post(query_url, nil,
        VoiceVox.QUERY_BLOCK_TIMEOUT, VoiceVox.QUERY_TOTAL_TIMEOUT)
    if not query_json or query_json == "" then
        return nil, "audio_query failed: " .. tostring(qerr or "empty response")
    end

    local wav, serr = post(("%s/synthesis?speaker=%d"):format(base, speaker), query_json,
        opts.synth_block_timeout or VoiceVox.SYNTH_BLOCK_TIMEOUT,
        opts.synth_total_timeout or VoiceVox.SYNTH_TOTAL_TIMEOUT)
    if not wav or wav == "" then
        return nil, "synthesis failed: " .. tostring(serr or "empty response")
    end

    local f = io.open(out_path, "wb")
    if not f then
        return nil, "cannot write " .. out_path
    end
    f:write(wav)
    f:close()
    return true
end

return VoiceVox
