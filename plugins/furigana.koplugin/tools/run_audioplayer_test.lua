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

-- play() uses the detected player and backgrounds the command
AudioPlayer._cmd = "aplay"
local executed
local real_execute = os.execute
os.execute = function(cmd) executed = cmd; return true end -- luacheck: ignore
local ok2 = AudioPlayer:play("/tmp/word.wav")
os.execute = real_execute -- luacheck: ignore
check(ok2 == true and executed == AudioPlayer.buildCommand("aplay", "/tmp/word.wav"),
    "play executes the built player command")

-- release() on non-Android just clears the handle
AudioPlayer._mp = "sentinel"
AudioPlayer:release()
check(AudioPlayer._mp == nil, "release clears the kept player handle")

print(failures == 0 and "\nALL TESTS PASSED" or ("\n" .. failures .. " TEST(S) FAILED"))
os.exit(failures == 0 and 0 or 1)
