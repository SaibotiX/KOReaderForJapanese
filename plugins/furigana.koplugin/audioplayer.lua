--- Tiny platform audio player for the tap-reveal word audio.
--
-- Android: drives android.media.MediaPlayer through the launcher's JNI
-- bindings (android.jni). One player instance is kept as a JNI global ref;
-- starting a new word releases the previous player first, so a new tap
-- interrupts the old audio and at most one native player is ever alive.
-- Elsewhere (emulator/desktop): shells out to the first available CLI player
-- (paplay/aplay/ffplay/mpv/afplay), in the background.
--
-- @module koplugin.furigana.audioplayer

local Device = require("device")
local logger = require("logger")

local AudioPlayer = {
    _mp = nil,   -- Android: JNI global ref to the current MediaPlayer
    _cmd = nil,  -- desktop: detected player binary (false = none found)
}

-- Candidate CLI players, most common first.
AudioPlayer.PLAYERS = { "paplay", "aplay", "ffplay", "mpv", "afplay" }

--- The background-play shell command for a given player binary (pure; tested).
function AudioPlayer.buildCommand(player, path)
    local quoted = "'" .. path:gsub("'", "'\\''") .. "'"
    if player == "ffplay" then
        return ("ffplay -nodisp -autoexit -loglevel quiet %s >/dev/null 2>&1 &"):format(quoted)
    elseif player == "mpv" then
        return ("mpv --no-video --really-quiet %s >/dev/null 2>&1 &"):format(quoted)
    elseif player == "aplay" then
        return ("aplay -q %s >/dev/null 2>&1 &"):format(quoted)
    end
    return ("%s %s >/dev/null 2>&1 &"):format(player, quoted)
end

-- Whether `player` exists on PATH (split out so tests can stub it).
function AudioPlayer._probe(player)
    local r = os.execute(("command -v %s >/dev/null 2>&1"):format(player))
    return r == 0 or r == true -- LuaJIT returns the status, lua5.3+ a boolean
end

function AudioPlayer:findPlayer()
    if self._cmd ~= nil then
        return self._cmd
    end
    for _, player in ipairs(self.PLAYERS) do
        if self._probe(player) then
            self._cmd = player
            return player
        end
    end
    self._cmd = false
    return false
end

--- Play a WAV file (non-blocking). Returns true, or nil and an error message.
function AudioPlayer:play(path)
    if Device:isAndroid() then
        return self:_playAndroid(path)
    end
    local player = self:findPlayer()
    if not player then
        return nil, "no audio player found (looked for " .. table.concat(self.PLAYERS, "/") .. ")"
    end
    os.execute(self.buildCommand(player, path))
    return true
end

function AudioPlayer:_playAndroid(path)
    local android = require("android")
    local ok, err = pcall(function()
        android.jni:context(android.app.activity.vm, function(jni)
            -- Stop & release the previous word's player, if any.
            if AudioPlayer._mp ~= nil then
                pcall(jni.callVoidMethod, jni, AudioPlayer._mp, "release", "()V")
                jni.env[0].DeleteGlobalRef(jni.env, AudioPlayer._mp)
                AudioPlayer._mp = nil
            end
            local uri_str = jni.env[0].NewStringUTF(jni.env, "file://" .. path)
            local uri = jni:callStaticObjectMethod("android/net/Uri", "parse",
                "(Ljava/lang/String;)Landroid/net/Uri;", uri_str)
            -- MediaPlayer.create() prepares the (local, small) file synchronously.
            local mp = jni:callStaticObjectMethod("android/media/MediaPlayer", "create",
                "(Landroid/content/Context;Landroid/net/Uri;)Landroid/media/MediaPlayer;",
                android.app.activity.clazz, uri)
            jni.env[0].DeleteLocalRef(jni.env, uri_str)
            if uri ~= nil then
                jni.env[0].DeleteLocalRef(jni.env, uri)
            end
            if mp == nil then
                error("MediaPlayer.create returned null")
            end
            jni:callVoidMethod(mp, "start", "()V")
            AudioPlayer._mp = jni.env[0].NewGlobalRef(jni.env, mp)
            jni.env[0].DeleteLocalRef(jni.env, mp)
        end)
    end)
    if not ok then
        logger.err("furigana audioplayer: JNI playback failed:", err)
        return nil, tostring(err)
    end
    return true
end

--- Release the kept Android player (called when the document closes).
function AudioPlayer:release()
    if self._mp == nil then
        return
    end
    if not Device:isAndroid() then
        self._mp = nil
        return
    end
    local android = require("android")
    pcall(function()
        android.jni:context(android.app.activity.vm, function(jni)
            pcall(jni.callVoidMethod, jni, AudioPlayer._mp, "release", "()V")
            jni.env[0].DeleteGlobalRef(jni.env, AudioPlayer._mp)
        end)
    end)
    self._mp = nil
end

return AudioPlayer
