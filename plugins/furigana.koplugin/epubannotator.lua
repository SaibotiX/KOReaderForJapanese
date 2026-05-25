--[[--
EPUB furigana annotator.

A Lua port of the annotator's wrapper.py `annotate_epub` / `annotate_html_fragment`:
walk an EPUB's content documents, inject `<ruby>` furigana into Japanese text
nodes (leaving tags, <script>/<style>/<head> and existing ruby untouched), and
write a new, valid EPUB.

`annotate_fragment` is pure Lua (depends only on a tokenizer instance) so it can
be unit-tested outside KOReader. `annotate_epub` uses KOReader's ffi/archiver.

@module furigana.epubannotator
]]

local M = {}

-- Tags whose text content must not be annotated (matches wrapper.py _SKIP_TAGS).
local SKIP_TAGS = {
    script = true, style = true, head = true,
    ruby = true, rt = true, rp = true, rb = true, rtc = true,
}

-- Japanese Unicode ranges (matches wrapper.py has_japanese).
local function has_japanese(s)
    local i, len = 1, #s
    while i <= len do
        local b = s:byte(i)
        local cp, size
        if b < 0x80 then cp, size = b, 1
        elseif b < 0xE0 then
            cp = (b % 0x20) * 0x40 + ((s:byte(i + 1) or 0) % 0x40); size = 2
        elseif b < 0xF0 then
            cp = (b % 0x10) * 0x1000 + ((s:byte(i + 1) or 0) % 0x40) * 0x40
               + ((s:byte(i + 2) or 0) % 0x40); size = 3
        else
            size = 4 -- supplementary planes are outside wrapper.py's ranges
            cp = -1
        end
        if cp >= 0 then
            if (cp >= 0x3040 and cp <= 0x309F)   -- Hiragana
            or (cp >= 0x30A0 and cp <= 0x30FF)   -- Katakana
            or (cp >= 0x4E00 and cp <= 0x9FFF)   -- CJK Unified
            or (cp >= 0x3400 and cp <= 0x4DBF)   -- CJK Ext A
            or (cp >= 0xF900 and cp <= 0xFAFF)   -- CJK Compatibility
            then return true end
        end
        i = i + size
    end
    return false
end

local function is_annotated(s)
    return s:find("<ruby>", 1, true) ~= nil and s:find("<rt>", 1, true) ~= nil
end

--- Annotate Japanese text nodes in an XHTML string, leaving markup untouched.
-- Faithful port of wrapper.py annotate_html_fragment.
-- @param tokenizer a furigana tokenizer with an :annotate(text) method
-- @param markup XHTML/HTML document text
-- @treturn string annotated markup
function M.annotate_fragment(tokenizer, markup)
    local out, on = {}, 0
    local skip_depth = 0
    local i, len = 1, #markup

    while i <= len do
        local lt = markup:find("<", i, true)
        if not lt then
            -- trailing text node
            local part = markup:sub(i)
            if skip_depth == 0 and has_japanese(part) and not is_annotated(part) then
                part = tokenizer:annotate(part)
            end
            on = on + 1; out[on] = part
            break
        end
        if lt > i then
            local part = markup:sub(i, lt - 1)
            if skip_depth == 0 and has_japanese(part) and not is_annotated(part) then
                part = tokenizer:annotate(part)
            end
            on = on + 1; out[on] = part
        end
        local gt = markup:find(">", lt + 1, true)
        if not gt then
            -- stray '<' with no closing '>': treat the rest as a text node
            local part = markup:sub(lt)
            if skip_depth == 0 and has_japanese(part) and not is_annotated(part) then
                part = tokenizer:annotate(part)
            end
            on = on + 1; out[on] = part
            break
        end
        local tag = markup:sub(lt, gt)
        on = on + 1; out[on] = tag -- emit tag/comment/declaration verbatim

        local slash, name = tag:match("^<%s*(/?)%s*([%a][%w_:%-]*)")
        if name then
            name = name:lower()
            if SKIP_TAGS[name] and tag:sub(-2) ~= "/>" then
                if slash == "/" then
                    skip_depth = skip_depth > 0 and skip_depth - 1 or 0
                else
                    skip_depth = skip_depth + 1
                end
            end
        end
        i = gt + 1
    end

    return table.concat(out)
end

-- ------------------------------------------------------------- EPUB rewrite --

local CONTENT_EXTS = { xhtml = true, html = true, htm = true }

local function lower_ext(name)
    return (name:match("%.([%a%d]+)$") or ""):lower()
end

--- Annotate every content document in an EPUB and write a new EPUB.
-- @param tokenizer furigana tokenizer
-- @param src source .epub path
-- @param dest destination .epub path
-- @param progress_cb optional function(done, total, name) -> boolean; return
--        false to abort. Called once per content document.
-- @treturn boolean ok
-- @treturn string|nil error message on failure
function M.annotate_epub(tokenizer, src, dest, progress_cb)
    local Archiver = require("ffi/archiver")

    local reader = Archiver.Reader:new()
    if not reader:open(src) then
        return false, "could not open source EPUB"
    end

    -- Collect file entries; put mimetype first (required for a valid EPUB).
    local files = {}
    for entry in reader:iterate() do
        if entry.mode == "file" then
            files[#files + 1] = entry.path
        end
    end
    table.sort(files, function(a, b)
        if a == "mimetype" then return true end
        if b == "mimetype" then return false end
        return false -- otherwise keep input order (stable enough for crengine)
    end)

    local total = 0
    for _, name in ipairs(files) do
        if CONTENT_EXTS[lower_ext(name)] then total = total + 1 end
    end

    local writer = Archiver.Writer:new{}
    if not writer:open(dest, "epub") then
        reader:close()
        return false, "could not open destination EPUB"
    end

    local mtime = os.time()
    local done = 0
    local ok, err = pcall(function()
        for _, name in ipairs(files) do
            local data = reader:extractToMemory(name)
            if data == nil then
                error("could not read entry: " .. name)
            end
            if name == "mimetype" then
                writer:setZipCompression("store")
                writer:addFileFromMemory(name, data, mtime)
                writer:setZipCompression("deflate")
            else
                if CONTENT_EXTS[lower_ext(name)] then
                    data = M.annotate_fragment(tokenizer, data)
                    done = done + 1
                    if progress_cb and progress_cb(done, total, name) == false then
                        error("aborted by user")
                    end
                end
                writer:addFileFromMemory(name, data, mtime)
            end
        end
    end)

    writer:close()
    reader:close()

    if not ok then
        os.remove(dest)
        return false, tostring(err)
    end
    return true
end

-- exposed for testing
M._has_japanese = has_japanese
M._is_annotated = is_annotated

return M
