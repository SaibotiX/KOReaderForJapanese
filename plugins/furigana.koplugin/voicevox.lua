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

-- ------------------------------------------------------- loudness leveling --
-- VOICEVOX renders each request at whatever level the voice model produces:
-- consecutive sentences easily differ by several dB (short exclamations come
-- out hot, long flat clauses quiet). The engine has no loudness normalization
-- of its own (its volumeScale is just a fixed multiplier), so we level the
-- WAV ourselves right after synthesis: measure the speech RMS frame by frame
-- (pause/silence frames are excluded by a floor relative to the loudest
-- frame, so neither leading pauses nor an overall quiet clip skew it), scale
-- it to NORMALIZE_TARGET_DB, and soft-limit the few samples that would top
-- the peak ceiling — a lone hot peak no longer blocks the whole clip's gain
-- (that hard cap was why leveled sentences still came out uneven).
-- Pure Lua over the 16-bit PCM samples; fetches run in subprocesses, so the
-- UI never feels the extra pass.

-- Bump when the leveling behavior changes: it re-keys the audio caches (see
-- precache.audioKeyFor), so stale files leveled the old way are refetched
-- instead of played alongside newly leveled ones.
VoiceVox.NORMALIZE_VERSION = 2

VoiceVox.NORMALIZE_TARGET_DB = -20     -- speech RMS target, dBFS
VoiceVox.NORMALIZE_MAX_GAIN = 8.0      -- never amplify more (would raise hiss)
VoiceVox.NORMALIZE_MIN_GAIN = 0.25     -- nor attenuate more (bad measurement guard)
VoiceVox.NORMALIZE_PEAK = 0.95         -- post-gain peak ceiling, fraction of full scale
VoiceVox.NORMALIZE_KNEE = 0.8          -- soft limiting starts at this fraction of the ceiling
VoiceVox.NORMALIZE_FRAME = 1024        -- measurement frame, samples (~43 ms at 24 kHz)
VoiceVox.NORMALIZE_FRAME_FLOOR = 0.1   -- speech frame = RMS above this × the loudest frame
VoiceVox.NORMALIZE_SILENCE = 0.003     -- and above this fraction of full scale (digital silence)

--- The audio-cache key tag for these leveling settings: files leveled
-- differently (or not at all) must never share a cache slot.
-- opts.normalize == false means raw engine audio (fetch's convention;
-- nil counts as on).
function VoiceVox.cacheTag(opts)
    if opts and opts.normalize == false then return "" end
    return "n" .. tostring(VoiceVox.NORMALIZE_VERSION)
end

-- Locate the sample data of a plain 16-bit PCM RIFF/WAVE. Returns data_off
-- (1-based index of the first sample byte), data_size — or nil when `wav` is
-- anything else (compressed, 24-bit, truncated, not a WAV…).
local function pcm16_data_chunk(wav)
    if #wav < 44 or wav:sub(1, 4) ~= "RIFF" or wav:sub(9, 12) ~= "WAVE" then
        return nil
    end
    local function u16(i)
        local a, b = wav:byte(i, i + 1)
        return a + b * 256
    end
    local function u32(i)
        local a, b, c, d = wav:byte(i, i + 3)
        return a + b * 256 + c * 65536 + d * 16777216
    end
    local pos = 13
    local fmt_ok = false
    while pos + 8 <= #wav + 1 do
        local id = wav:sub(pos, pos + 3)
        local size = u32(pos + 4)
        if id == "fmt " then
            if size < 16 then return nil end
            if u16(pos + 8) ~= 1 or u16(pos + 22) ~= 16 then
                return nil -- not plain PCM / not 16-bit
            end
            fmt_ok = true
        elseif id == "data" then
            if not fmt_ok or pos + 7 + size > #wav then return nil end
            return pos + 8, size
        end
        pos = pos + 8 + size + (size % 2)
    end
    return nil
end

-- tanh for the soft limiter (LuaJIT has math.tanh, lua5.3 may not).
local function tanh(x)
    if x > 20 then return 1 end
    local e = math.exp(2 * x)
    return (e - 1) / (e + 1)
end

--- Rewrite `wav` so its speech sits at the target loudness. Returns the
-- leveled bytes (same length), or nil when the input is not plain 16-bit PCM,
-- contains no speech, or is close enough already — callers then keep the
-- original bytes, so this can never lose audio.
function VoiceVox.normalizeLoudness(wav)
    local data_off, data_size = pcm16_data_chunk(wav)
    if not data_off or data_size < 2 then return nil end
    data_size = data_size - (data_size % 2)
    local last = data_off + data_size - 1
    -- Pass 1: per-frame mean square (the byte chunks ARE the frames).
    local frame_bytes = VoiceVox.NORMALIZE_FRAME * 2
    local frames = {}
    local peak = 0
    local i = data_off
    while i <= last do
        local hi = math.min(i + frame_bytes - 1, last)
        local bytes = { wav:byte(i, hi) }
        local sum_sq, n = 0, 0
        for j = 1, #bytes, 2 do
            local s = bytes[j] + bytes[j + 1] * 256
            if s >= 32768 then s = s - 65536 end
            local a = s < 0 and -s or s
            if a > peak then peak = a end
            sum_sq = sum_sq + s * s
            n = n + 1
        end
        if n > 0 then frames[#frames + 1] = sum_sq / n end
        i = hi + 1
    end
    if peak == 0 or #frames == 0 then return nil end
    -- Pass 2: the speech level = mean power of the frames that hold speech.
    -- The floor is relative to the clip's own loudest frame, so a quiet
    -- render is measured on its (quiet) speech instead of being skewed by a
    -- fixed threshold; an absolute floor still drops digital silence.
    local max_ms = 0
    for _, ms in ipairs(frames) do
        if ms > max_ms then max_ms = ms end
    end
    local rel = VoiceVox.NORMALIZE_FRAME_FLOOR
    local silence = 32768 * VoiceVox.NORMALIZE_SILENCE
    local floor_ms = math.max(max_ms * rel * rel, silence * silence)
    local sum_ms, n_active = 0, 0
    for _, ms in ipairs(frames) do
        if ms >= floor_ms then
            sum_ms = sum_ms + ms
            n_active = n_active + 1
        end
    end
    if n_active == 0 then return nil end
    local rms = math.sqrt(sum_ms / n_active)
    local gain = 32768 * 10 ^ (VoiceVox.NORMALIZE_TARGET_DB / 20) / rms
    if gain > VoiceVox.NORMALIZE_MAX_GAIN then gain = VoiceVox.NORMALIZE_MAX_GAIN end
    if gain < VoiceVox.NORMALIZE_MIN_GAIN then gain = VoiceVox.NORMALIZE_MIN_GAIN end
    if gain > 0.97 and gain < 1.03 then return nil end -- close enough already
    -- Rewrite with the full gain; the few samples that would top the ceiling
    -- are squashed into the knee..ceiling band instead of capping the gain
    -- (so one hot peak can't keep the whole clip quiet) or clipping.
    local ceiling = VoiceVox.NORMALIZE_PEAK * 32767
    local knee = VoiceVox.NORMALIZE_KNEE * ceiling
    local band = ceiling - knee
    local char = string.char
    local floor_ = math.floor
    local out = { wav:sub(1, data_off - 1) }
    i = data_off
    while i <= last do
        local hi = math.min(i + frame_bytes - 1, last)
        local bytes = { wav:byte(i, hi) }
        local piece = {}
        for j = 1, #bytes, 2 do
            local s = bytes[j] + bytes[j + 1] * 256
            if s >= 32768 then s = s - 65536 end
            local x = s * gain
            if x > knee then
                x = knee + band * tanh((x - knee) / band)
            elseif x < -knee then
                x = -(knee + band * tanh((-x - knee) / band))
            end
            s = floor_(x + 0.5)
            if s > 32767 then s = 32767 elseif s < -32768 then s = -32768 end
            if s < 0 then s = s + 65536 end
            piece[#piece + 1] = char(s % 256, (s - s % 256) / 256)
        end
        out[#out + 1] = table.concat(piece)
        i = hi + 1
    end
    out[#out + 1] = wav:sub(data_off + data_size)
    return table.concat(out)
end

--- Synthesize `text` into a WAV file at `out_path`.
-- opts: { url = engine base URL, speaker = numeric speaker/style id,
-- normalize = false to skip loudness leveling (default: level it),
-- synth_block_timeout / synth_total_timeout = per-request overrides }.
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

    if opts.normalize ~= false then
        local leveled = VoiceVox.normalizeLoudness(wav)
        if leveled then wav = leveled end
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
