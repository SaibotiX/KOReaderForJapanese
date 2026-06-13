-- Tests for audioplayer.lua's desktop path: player command building/quoting
-- and PATH detection. (The Android JNI MediaPlayer path needs a device.)
-- Pure Lua: lua tools/run_audioplayer_test.lua

local here = arg[0]:match("^(.*)/[^/]*$") or "."
package.path = here .. "/../?.lua;" .. package.path

package.preload["device"] = function()
    return { isAndroid = function() return false end }
end
package.preload["logger"] = function()
    return { dbg = function() end, info = function() end, warn = function() end, err = function() end }
end

local AudioPlayer = require("audioplayer")

local failures = 0
local function check(cond, msg)
    if cond then
        print("ok   - " .. msg)
    else
        failures = failures + 1
        print("FAIL - " .. msg)
    end
end

-- ---------------------------------------------------------- buildCommand --

check(AudioPlayer.buildCommand("aplay", "/tmp/word.wav")
        == "aplay -q '/tmp/word.wav' >/dev/null 2>&1 &",
    "aplay command is quiet and backgrounded")
check(AudioPlayer.buildCommand("ffplay", "/tmp/word.wav"):find("-nodisp -autoexit", 1, true) ~= nil,
    "ffplay gets no-display/auto-exit flags")
check(AudioPlayer.buildCommand("mpv", "/tmp/word.wav"):find("--no-video", 1, true) ~= nil,
    "mpv gets the no-video flag")
check(AudioPlayer.buildCommand("paplay", "/tmp/it's.wav")
        == "paplay '/tmp/it'\\''s.wav' >/dev/null 2>&1 &",
    "paths with apostrophes are shell-quoted")

-- ------------------------------------------------------------ findPlayer --

local probed = {}
AudioPlayer._probe = function(player)
    probed[#probed + 1] = player
    return player == "ffplay" -- pretend only ffplay exists
end

AudioPlayer._cmd = nil
check(AudioPlayer:findPlayer() == "ffplay", "first available player is picked")
check(probed[1] == "paplay" and probed[2] == "aplay" and probed[3] == "ffplay",
    "players are probed in preference order")
probed = {}
check(AudioPlayer:findPlayer() == "ffplay" and #probed == 0,
    "detection result is cached")

AudioPlayer._probe = function() return false end
AudioPlayer._cmd = nil
check(AudioPlayer:findPlayer() == false, "no player found is remembered as false")

local ok, err = AudioPlayer:play("/tmp/word.wav")
check(ok == nil and err:match("no audio player found"),
    "play without any player returns a clear error")

-- play() backgrounds the built command and captures the player's pid so it
-- can be stopped / watched (auto reader).
AudioPlayer._cmd = "aplay"
local executed = {}
local popened
local real_execute = os.execute
local real_popen = io.popen
os.execute = function(cmd) executed[#executed + 1] = cmd; return true end -- luacheck: ignore
io.popen = function(cmd) -- luacheck: ignore
    popened = cmd
    return {
        read = function() return 4242 end,
        close = function() end,
    }
end
local ok2 = AudioPlayer:play("/tmp/word.wav")
check(ok2 == true
        and popened == AudioPlayer.buildCommand("aplay", "/tmp/word.wav") .. " echo $!"
        and AudioPlayer._pid == 4242,
    "play backgrounds the built command and records the player pid")

-- isPlaying() probes the recorded pid; stop() kills it and forgets it.
local alive = true
os.execute = function(cmd) -- luacheck: ignore
    executed[#executed + 1] = cmd
    if cmd:match("^kill %-0 ") then return alive and true or nil end
    return true
end
check(AudioPlayer:isPlaying() == true, "isPlaying: true while the pid is alive")
AudioPlayer:stop()
check(executed[#executed] == "kill 4242 2>/dev/null" and AudioPlayer._pid == nil,
    "stop kills the recorded pid and forgets it")
check(AudioPlayer:isPlaying() == false, "isPlaying: false after stop")
AudioPlayer._pid = 4242
alive = false
check(AudioPlayer:isPlaying() == false and AudioPlayer._pid == nil,
    "isPlaying: a dead pid is detected and forgotten")
os.execute = real_execute -- luacheck: ignore
io.popen = real_popen -- luacheck: ignore

-- release() on non-Android just clears the handle
AudioPlayer._mp = "sentinel"
AudioPlayer:release()
check(AudioPlayer._mp == nil, "release clears the kept player handle")

-- ------------------------------------------------------ wavDurationSeconds --

local function u32le(n)
    return string.char(n % 256, math.floor(n / 256) % 256,
        math.floor(n / 65536) % 256, math.floor(n / 16777216) % 256)
end
local function u16le(n)
    return string.char(n % 256, math.floor(n / 256) % 256)
end
-- A minimal RIFF/WAVE: 44100 Hz, mono, 16-bit -> byte rate 88200.
local function make_wav(data_bytes, extra_chunk_first)
    local fmt = u16le(1) .. u16le(1) .. u32le(44100) .. u32le(88200) .. u16le(2) .. u16le(16)
    local chunks = ""
    if extra_chunk_first then
        chunks = chunks .. "LIST" .. u32le(4) .. "INFO" -- chunk to skip over
    end
    chunks = chunks .. "fmt " .. u32le(#fmt) .. fmt
    chunks = chunks .. "data" .. u32le(data_bytes) .. string.rep("\0", data_bytes)
    return "RIFF" .. u32le(4 + #chunks) .. "WAVE" .. chunks
end

local wav_path = os.tmpname()
local function write_file(path, bytes)
    local f = io.open(path, "wb")
    f:write(bytes)
    f:close()
end

write_file(wav_path, make_wav(88200))
check(AudioPlayer.wavDurationSeconds(wav_path) == 1.0,
    "wav duration: one second of 44.1k mono 16-bit")
write_file(wav_path, make_wav(22050, true))
check(AudioPlayer.wavDurationSeconds(wav_path) == 0.25,
    "wav duration: leading non-fmt chunks are skipped")
write_file(wav_path, "not a wav at all")
check(AudioPlayer.wavDurationSeconds(wav_path) == nil,
    "wav duration: non-RIFF data gives nil")
write_file(wav_path, "RIFF" .. u32le(4) .. "WAVE")
check(AudioPlayer.wavDurationSeconds(wav_path) == nil,
    "wav duration: missing chunks give nil")
os.remove(wav_path)
check(AudioPlayer.wavDurationSeconds(wav_path) == nil,
    "wav duration: missing file gives nil")

print(failures == 0 and "\nALL TESTS PASSED" or ("\n" .. failures .. " TEST(S) FAILED"))
os.exit(failures == 0 and 0 or 1)
