--- Tiny anchored popup showing a tapped word's reading (Anki-style furigana).
--
-- Shown right above the tapped word (below it when there is no room, courtesy
-- of MovableContainer's anchor logic). Any tap dismisses it: a tap on the
-- popup itself additionally fires `tap_callback` (used to escalate to the full
-- Japanese word analysis); a tap elsewhere is passed through, so it can turn
-- the page or reveal the next word directly.
--
-- @module koplugin.furigana.readingpopup

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local MovableContainer = require("ui/widget/container/movablecontainer")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local Input = Device.input
local Screen = Device.screen

local ReadingPopup = InputContainer:extend{
    text = nil,         -- reading text, e.g. 食（た）べた; may be multi-line
                        -- (reading on the first line, translation below)
    anchor_box = nil,   -- Geom (screen) of the tapped word; nil centers the popup
    tap_callback = nil, -- called after closing when the popup body is tapped
    close_callback = nil, -- called when the popup is closed/replaced
}

function ReadingPopup:init()
    if Device:hasKeys() then
        self.key_events.Close = { { Input.group.Back } }
    end
    if Device:isTouchDevice() then
        local fullscreen = Geom:new{
            x = 0, y = 0,
            w = Screen:getWidth(),
            h = Screen:getHeight(),
        }
        self.ges_events = {
            TapDismiss = { GestureRange:new{ ges = "tap", range = fullscreen } },
            -- Also dismiss on swipe, passing it through (so a page-turn swipe
            -- doesn't leave a stale popup over the new page).
            SwipeDismiss = { GestureRange:new{ ges = "swipe", range = fullscreen } },
        }
    end
    local face = Font:getFace("cfont", G_reader_settings:readSetting("dict_font_size") or 20)
    local max_width = math.floor(Screen:getWidth() * 0.9)
    local content
    if self.text:find("\n", 1, true) then
        -- Multi-line (reading + translation): TextWidget renders one line
        -- only, so use a TextBoxWidget sized to the longest line to keep the
        -- bubble snug around the text.
        local widest = 0
        for line in self.text:gmatch("[^\n]+") do
            local w = TextWidget:new{ text = line, face = face }
            widest = math.max(widest, w:getSize().w)
            w:free()
        end
        local TextBoxWidget = require("ui/widget/textboxwidget")
        content = TextBoxWidget:new{
            text = self.text,
            face = face,
            width = math.min(widest, max_width),
        }
    else
        content = TextWidget:new{
            text = self.text,
            face = face,
            max_width = max_width,
        }
    end
    self.frame = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = Size.border.window,
        radius = Size.radius.window,
        padding = Size.padding.default,
        content,
    }
    self.movable = MovableContainer:new{
        unmovable = true, -- a furigana bubble is not a window to drag around
        anchor = self.anchor_box and function()
            return self.anchor_box
        end or nil,
        self.frame,
    }
    self[1] = CenterContainer:new{
        dimen = Screen:getSize(),
        self.movable,
    }
end

function ReadingPopup:onShow()
    UIManager:setDirty(self, function()
        return "ui", self.movable.dimen
    end)
    return true
end

function ReadingPopup:onCloseWidget()
    UIManager:setDirty(nil, function()
        return "ui", self.movable.dimen
    end)
    if self.close_callback then
        self.close_callback()
    end
end

function ReadingPopup:onClose()
    UIManager:close(self)
    return true
end

function ReadingPopup:onTapDismiss(_, ges)
    UIManager:close(self)
    if ges.pos and self.frame.dimen and ges.pos:intersectWith(self.frame.dimen) then
        if self.tap_callback then
            self.tap_callback()
        end
        return true
    end
    return false -- not ours: let the tap reach the page beneath
end

function ReadingPopup:onSwipeDismiss()
    UIManager:close(self)
    return false -- let the swipe reach the page beneath (page turn)
end

return ReadingPopup
