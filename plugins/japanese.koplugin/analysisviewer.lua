--- TextViewer subclass that adds page navigation to the analysis window.
--
-- The window's pages are the matching dictionaries, then (optionally) the
-- Translation page and the AI page.  When there is more than one page
-- (nav_enabled), it mirrors the main dictionary popup:
--   * volume / page keys (PgFwd / PgBack) scroll the content, and at the bottom/
--     top edge move to the next / previous page;
--   * horizontal swipe (west / east)       → next / previous page;
--   * vertical swipe (north / south)        → scroll the (possibly long) content.
-- The on-screen Prev/Next buttons still work.  With a single page it falls back
-- to the stock TextViewer behaviour (keys / swipe scroll).
--
-- @module koplugin.japanese.analysisviewer

local BD = require("ui/bidi")
local Device = require("device")
local TextViewer = require("ui/widget/textviewer")
local Input = Device.input

local AnalysisViewer = TextViewer:extend {
    on_change_page = nil, -- function(delta) — called to switch page
    nav_enabled = false,  -- only repurpose keys/swipe when several pages exist
}

function AnalysisViewer:init()
    TextViewer.init(self)
    if self.nav_enabled and Device:hasKeys() and self.scroll_text_w then
        -- Repurpose the volume/page keys (we scroll-or-change-page ourselves, so
        -- long content still scrolls — see onJpNextPage/onJpPrevPage).
        self.scroll_text_w.key_events.ScrollDown = nil
        self.scroll_text_w.key_events.ScrollUp = nil
        self.key_events.JpNextPage = { { Input.group.PgFwd } }
        self.key_events.JpPrevPage = { { Input.group.PgBack } }
    end
end

-- Volume/page keys scroll the content first; only at the bottom/top edge do they
-- move to the next/previous page (uses ScrollTextWidget's own boundary check, so
-- long content still scrolls).
function AnalysisViewer:onJpNextPage()
    local tw = self.scroll_text_w and self.scroll_text_w.text_widget
    if tw and tw.virtual_line_num + tw:getVisLineCount() <= #tw.vertical_string_list then
        self.scroll_text_w:scrollText(1)
        return true
    end
    if self.on_change_page then self.on_change_page(1) end
    return true
end

function AnalysisViewer:onJpPrevPage()
    local tw = self.scroll_text_w and self.scroll_text_w.text_widget
    if tw and tw.virtual_line_num > 1 then
        self.scroll_text_w:scrollText(-1)
        return true
    end
    if self.on_change_page then self.on_change_page(-1) end
    return true
end

function AnalysisViewer:onSwipe(arg, ges)
    if self.nav_enabled and self.on_change_page and self.textw
            and ges.pos:intersectWith(self.textw.dimen) then
        local direction = BD.flipDirectionIfMirroredUILayout(ges.direction)
        if direction == "west" then
            self.on_change_page(1)
            return true
        elseif direction == "east" then
            self.on_change_page(-1)
            return true
        elseif direction == "north" then
            self.scroll_text_w:scrollText(1)
            return true
        elseif direction == "south" then
            self.scroll_text_w:scrollText(-1)
            return true
        end
    end
    return TextViewer.onSwipe(self, arg, ges)
end

return AnalysisViewer
