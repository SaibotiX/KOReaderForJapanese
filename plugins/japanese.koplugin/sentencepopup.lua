--- Popup for sentence splitting: the current sentence (with furigana spliced
-- in) and its translation, in a small bubble anchored right above the
-- sentence being read — below it when there is no room above (courtesy of
-- MovableContainer's anchor logic), and at the bottom of the screen when the
-- sentence could not be located on the page.
--
-- While it is shown it is the topmost window, so it receives the key events
-- itself: it binds the same key sequences that step sentences at the reader
-- level (the hijacked page-turn/volume keys) and forwards them to the
-- controller. Taps on the bubble go to the controller too, which turns them
-- into "toggle the translation" (single) or "replay the audio" (double); a
-- tap or swipe anywhere else closes the bubble and passes through, so page
-- turns and word taps keep working underneath.
--
-- @module koplugin.japanese.sentencepopup

local Blitbuffer = require("ffi/blitbuffer")
local BottomContainer = require("ui/widget/container/bottomcontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local MovableContainer = require("ui/widget/container/movablecontainer")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local Input = Device.input
local Screen = Device.screen

local SentencePopup = InputContainer:extend{
    text = nil,       -- sentence on the first line, translation below (optional)
    anchor_box = nil, -- Geom (screen) of the sentence being read: the popup
                      -- pops up above it, or below when there is no room;
                      -- nil = bottom of the screen
    next_seq = nil,   -- key sequence for "next sentence" (from the hijacked binding)
    prev_seq = nil,   -- key sequence for "previous sentence"
    on_step = nil,    -- function(dir) — step to the next/previous sentence
    on_frame_tap = nil, -- every tap on the bubble body (the controller
                        -- decides single = toggle translation / double = replay)
    close_callback = nil,
}

function SentencePopup:init()
    if Device:hasKeys() then
        self.key_events.Close = { { Input.group.Back } }
        self.key_events.StepNext = { self.next_seq or { Input.group.PgFwd } }
        self.key_events.StepPrev = { self.prev_seq or { Input.group.PgBack } }
    end
    if Device:isTouchDevice() then
        local fullscreen = Geom:new{
            x = 0, y = 0,
            w = Screen:getWidth(),
            h = Screen:getHeight(),
        }
        self.ges_events = {
            Tap = { GestureRange:new{ ges = "tap", range = fullscreen } },
            SwipeDismiss = { GestureRange:new{ ges = "swipe", range = fullscreen } },
        }
    end
    local face = Font:getFace("cfont", G_reader_settings:readSetting("dict_font_size") or 20)
    local max_width = math.floor(Screen:getWidth() * 0.9)
    -- Sized to the longest line so the bubble stays snug around short
    -- sentences; TextBoxWidget wraps anything longer.
    local widest = 0
    for line in self.text:gmatch("[^\n]+") do
        local w = TextWidget:new{ text = line, face = face }
        widest = math.max(widest, w:getSize().w)
        w:free()
    end
    self.frame = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = Size.border.window,
        radius = Size.radius.window,
        padding = Size.padding.default,
        TextBoxWidget:new{
            text = self.text,
            face = face,
            width = math.min(math.max(widest, 1), max_width),
        },
    }
    if self.anchor_box then
        self.movable = MovableContainer:new{
            unmovable = true, -- a subtitle bubble is not a window to drag around
            anchor = function()
                return self.anchor_box
            end,
            self.frame,
        }
        self[1] = CenterContainer:new{
            dimen = Screen:getSize(),
            self.movable,
        }
    else
        self[1] = BottomContainer:new{
            dimen = Geom:new{
                x = 0, y = 0,
                w = Screen:getWidth(),
                h = Screen:getHeight() - Size.margin.default * 4,
            },
            self.frame,
        }
    end
end

function SentencePopup:region()
    return (self.movable and self.movable.dimen) or self.frame.dimen
end

function SentencePopup:onShow()
    UIManager:setDirty(self, function()
        return "ui", self:region()
    end)
    return true
end

function SentencePopup:onCloseWidget()
    UIManager:setDirty(nil, function()
        return "ui", self:region()
    end)
    if self.close_callback then
        self.close_callback()
    end
end

function SentencePopup:onClose()
    UIManager:close(self)
    return true
end

function SentencePopup:onStepNext()
    if self.on_step then self.on_step(1) end
    return true
end

function SentencePopup:onStepPrev()
    if self.on_step then self.on_step(-1) end
    return true
end

function SentencePopup:onTap(_, ges)
    if ges.pos and self.frame.dimen and ges.pos:intersectWith(self.frame.dimen) then
        if self.on_frame_tap then self.on_frame_tap() end
        return true
    end
    UIManager:close(self)
    return false -- not ours: let the tap reach the page beneath
end

function SentencePopup:onSwipeDismiss()
    UIManager:close(self)
    return false -- let the swipe reach the page beneath (page turn)
end

return SentencePopup
