--- Popup for sentence splitting: the current sentence — with furigana as
-- real interlinear ruby (readings above the words, see rubytext.lua) — and
-- its translation, in a small bubble anchored right above the sentence being
-- read; below it when there is no room above (courtesy of MovableContainer's
-- anchor logic), and at the bottom of the screen when the sentence could not
-- be located on the page.
--
-- While it is shown it is the topmost window, so it receives the key events
-- itself: it binds the same key sequences that step sentences at the reader
-- level (the hijacked page-turn/volume keys) and forwards them to the
-- controller. Taps on the bubble go to the controller too (with an "on the
-- left edge" flag), which turns them into "toggle the translation" (single),
-- "replay the audio" (double) or "dismiss" (double on the left eighth).
--
-- Non-sticky, a tap or swipe anywhere else closes the bubble and passes
-- through. Sticky (the default), the bubble stays while taps, holds and
-- swipes act on the page beneath — menus, dictionary lookups and page turns
-- all keep working with the bubble up; only the left-edge double tap (or a
-- page change, which resets the session) dismisses it. The pass-through is
-- EXPLICIT: UIManager hands input only to the topmost window and then to
-- is_always_active widgets — never down the stack to the reader — so
-- onGesture/onKeyPress forward whatever the bubble doesn't consume to
-- `reader_ui` themselves (see those overrides).
--
-- A hold on the Japanese line is a dictionary lookup of the word at that
-- position (the controller runs the same Yomichan expansion a hold on the
-- book page gets); a hold on the translation line selects text the plain way.
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
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Input = Device.input
local Screen = Device.screen

local SentencePopup = InputContainer:extend{
    jp = nil,         -- Japanese line: a plain string, or { plain, runs } for
                      -- ruby (runs as produced by readingextractor.parse)
    tr = nil,         -- translation line (optional)
    ruby_scale = nil, -- ruby font size as a fraction of the base size
                      -- (default 0.42, crengine's own rt size; the controller
                      -- passes the current book's style-tweaked value)
    sticky = nil,     -- true: taps/swipes outside pass through WITHOUT closing
    reader_ui = nil,  -- the ReaderUI beneath: unconsumed input is forwarded
                      -- to it (UIManager itself never passes events down)
    anchor_box = nil, -- Geom (screen) of the sentence being read: the popup
                      -- pops up above it, or below when there is no room;
                      -- nil = bottom of the screen
    next_seq = nil,   -- key sequence for "next sentence" (from the hijacked binding)
    prev_seq = nil,   -- key sequence for "previous sentence"
    on_step = nil,    -- function(dir) — step to the next/previous sentence
    on_frame_tap = nil, -- function(is_left_zone) — every tap on the bubble body
    on_word_lookup = nil, -- function(plain, start_byte, text, is_single) —
                          -- hold on the Japanese line
    on_text_select = nil, -- function(text) — hold-selection on the translation
    close_callback = nil,
}

SentencePopup.DEFAULT_RUBY_SCALE = 0.42
-- The leftmost fraction of the bubble whose double tap dismisses it.
SentencePopup.CLOSE_ZONE_FRACTION = 1 / 8

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
        -- Holds are scoped to the bubble, so text selection on the page
        -- beneath keeps working; the zero rect stands in until first paint.
        local frame_range = function()
            return (self.frame and self.frame.dimen)
                or Geom:new{ x = 0, y = 0, w = 0, h = 0 }
        end
        local hold_pan_rate = G_reader_settings:readSetting("hold_pan_rate")
        if not hold_pan_rate then
            hold_pan_rate = Screen.low_pan_rate and 5.0 or 30.0
        end
        self.ges_events = {
            Tap = { GestureRange:new{ ges = "tap", range = fullscreen } },
            SwipeDismiss = { GestureRange:new{ ges = "swipe", range = fullscreen } },
            -- Hold + drag selects text on the bubble. The events propagate to
            -- whichever line sits under the finger: the Japanese RubyText
            -- (which reports word byte offsets through its select_callback)
            -- or the translation TextBoxWidget (plain selected text).
            HoldStartText = { GestureRange:new{ ges = "hold", range = frame_range } },
            HoldPanText = { GestureRange:new{ ges = "hold_pan", range = frame_range, rate = hold_pan_rate } },
            HoldReleaseText = {
                GestureRange:new{ ges = "hold_release", range = frame_range },
                args = function(text, hold_duration) -- luacheck: ignore 212
                    -- Reached only from the translation TextBoxWidget; the
                    -- ruby line calls its own select_callback instead.
                    if self.on_text_select then
                        self.on_text_select(text)
                    end
                end,
            },
        }
    end

    local base_size = G_reader_settings:readSetting("dict_font_size") or 20
    local face = Font:getFace("cfont", base_size)
    local max_width = math.floor(Screen:getWidth() * 0.9)

    -- The Japanese line: ruby-capable, also used for the bare sentence so a
    -- hold anywhere on it maps back to a byte offset for the dictionary.
    local jp_widget
    if self.jp then
        local RubyText = require("rubytext")
        local scale = self.ruby_scale or SentencePopup.DEFAULT_RUBY_SCALE
        local ruby_size = math.max(8, math.floor(base_size * scale + 0.5))
        local plain = type(self.jp) == "table" and self.jp.plain or self.jp
        local runs = type(self.jp) == "table" and self.jp.runs or nil
        jp_widget = RubyText:new{
            plain = plain,
            runs = runs,
            face = face,
            ruby_face = Font:getFace("cfont", ruby_size),
            max_width = max_width,
            dialog = self,
            select_callback = function(text, hold_duration, start_byte, is_single) -- luacheck: ignore 212
                if self.on_word_lookup then
                    self.on_word_lookup(plain, start_byte, text, is_single)
                end
            end,
        }
    end

    -- Sized to the longest line so the bubble stays snug around short
    -- sentences; the translation TextBoxWidget wraps anything longer.
    local tr_text = self.tr
    if not jp_widget and not tr_text then
        tr_text = "…" -- placeholder while the translation is on its way
    end
    local widest = jp_widget and jp_widget:getSize().w or 1
    if tr_text then
        for line in tr_text:gmatch("[^\n]+") do
            local w = TextWidget:new{ text = line, face = face }
            widest = math.max(widest, math.min(w:getSize().w, max_width))
            w:free()
        end
    end
    local content_width = math.min(math.max(widest, 1), max_width)

    local content = VerticalGroup:new{ align = "left" }
    if jp_widget then
        table.insert(content, jp_widget)
    end
    if tr_text then
        if jp_widget then
            table.insert(content, VerticalSpan:new{ width = Size.padding.small })
        end
        table.insert(content, TextBoxWidget:new{
            text = tr_text,
            face = face,
            width = content_width,
        })
    end

    self.frame = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = Size.border.window,
        radius = Size.radius.window,
        padding = Size.padding.default,
        content,
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

--- While shown we are the topmost window, and UIManager gives unconsumed
-- events to nobody else (only is_always_active widgets — the reader is not
-- one). So: whatever the bubble doesn't handle itself is forwarded to the
-- reader beneath, and taps, holds, swipes, menus and dictionary lookups on
-- the page work exactly as if the bubble were not there. A gesture ON the
-- bubble is never the page's, though — the bubble is opaque.
function SentencePopup:onGesture(ev)
    if InputContainer.onGesture(self, ev) then
        return true
    end
    local inside = ev and ev.pos and self.frame and self.frame.dimen
        and ev.pos:intersectWith(self.frame.dimen)
    if not inside and self.reader_ui then
        local Event = require("ui/event")
        return self.reader_ui:handleEvent(Event:new("Gesture", ev))
    end
    return true
end

--- Same for keys: the bound ones (stepping, Back) are ours, anything else
-- (menu/home/cursor keys on keyboard devices) acts on the reader.
function SentencePopup:onKeyPress(key)
    if InputContainer.onKeyPress(self, key) then
        return true
    end
    if self.reader_ui then
        local Event = require("ui/event")
        return self.reader_ui:handleEvent(Event:new("KeyPress", key))
    end
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
        if self.on_frame_tap then
            local zone = math.floor(self.frame.dimen.w * SentencePopup.CLOSE_ZONE_FRACTION)
            self.on_frame_tap(ges.pos.x < self.frame.dimen.x + zone)
        end
        return true
    end
    if not self.sticky then
        UIManager:close(self)
    end
    return false -- not ours: let the tap reach the page beneath
end

function SentencePopup:onSwipeDismiss()
    if not self.sticky then
        UIManager:close(self)
    end
    return false -- let the swipe reach the page beneath (page turn)
end

return SentencePopup
