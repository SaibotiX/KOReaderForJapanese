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
    _pid = nil,  -- desktop: pid of the currently playing CLI player
}

-- Candidate CLI players, most common first.
AudioPlayer.PLAYERS = { "paplay", "aplay", "ffplay", "mpv", "afplay" }

--- Duration of a WAV file in seconds, from its header (pure; tested).
-- Returns nil when the file is not a parseable RIFF/WAVE.
function AudioPlayer.wavDurationSeconds(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local header = f:read(12)
    if not header or #header < 12
            or header:sub(1, 4) ~= "RIFF" or header:sub(9, 12) ~= "WAVE" then
        f:close()
        return nil
    end
    local function u32(s, i)
        local a, b, c, d = s:byte(i, i + 3)
        return a + b * 256 + c * 65536 + d * 16777216
    end
    local byte_rate, data_size
    while not (byte_rate and data_size) do
        local chunk = f:read(8)
        if not chunk or #chunk < 8 then break end
        local id, size = chunk:sub(1, 4), u32(chunk, 5)
        if id == "fmt " then
            local fmt = f:read(math.min(size, 16))
            if not fmt or #fmt < 12 then break end
            byte_rate = u32(fmt, 9)
            f:seek("cur", size - math.min(size, 16) + size % 2)
        else
            if id == "data" then data_size = size end
            f:seek("cur", size + size % 2) -- chunks are padded to even sizes
        end
    end
    f:close()
    if byte_rate and byte_rate > 0 and data_size then
        return data_size / byte_rate
    end
    return nil
end

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

--- Play a WAV file (non-blocking; stops whatever was still playing).
-- Returns true, or nil and an error message.
function AudioPlayer:play(path)
    if Device:isAndroid() then
        return self:_playAndroid(path)
    end
    local player = self:findPlayer()
    if not player then
        return nil, "no audio player found (looked for " .. table.concat(self.PLAYERS, "/") .. ")"
    end
    self:stop() -- one player at a time, like the Android path
    -- Capture the backgrounded player's pid so stop()/isPlaying() work.
    local p = io.popen(self.buildCommand(player, path) .. " echo $!", "r")
    if p then
        self._pid = p:read("*n")
        p:close()
    else
        os.execute(self.buildCommand(player, path))
    end
    return true
end

--- Whether the last play() is still audible.
function AudioPlayer:isPlaying()
    if Device:isAndroid() then
        return self:_isPlayingAndroid()
    end
    if not self._pid then return false end
    local r = os.execute(("kill -0 %d 2>/dev/null"):format(self._pid))
    if r == 0 or r == true then return true end
    self._pid = nil
    return false
end

--- Stop the current playback (no-op when nothing plays).
function AudioPlayer:stop()
    if Device:isAndroid() then
        self:release() -- releasing the MediaPlayer stops it
        return
    end
    if self._pid then
        os.execute(("kill %d 2>/dev/null"):format(self._pid))
        self._pid = nil
    end
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

function AudioPlayer:_isPlayingAndroid()
    if self._mp == nil then return false end
    local android = require("android")
    local playing = false
    local ok = pcall(function()
        android.jni:context(android.app.activity.vm, function(jni)
            if jni.callBooleanMethod then
                local v = jni:callBooleanMethod(AudioPlayer._mp, "isPlaying", "()Z")
                playing = not (v == nil or v == false or v == 0)
            else
                -- Launcher build without the boolean helper: raw JNI.
                local cls = jni.env[0].GetObjectClass(jni.env, AudioPlayer._mp)
                local mid = jni.env[0].GetMethodID(jni.env, cls, "isPlaying", "()Z")
                if mid ~= nil then
                    local v = jni.env[0].CallBooleanMethodA(jni.env, AudioPlayer._mp, mid, nil)
                    playing = (v ~= 0)
                end
                jni.env[0].DeleteLocalRef(jni.env, cls)
            end
        end)
    end)
    return ok and playing
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
