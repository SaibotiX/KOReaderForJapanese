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

-- Bumped whenever the annotated-copy output changes in a way that must
-- invalidate previously generated copies (main.lua bakes it into the cache
-- key). 2: verified archive output — a write that failed midway (device out
-- of space) used to be kept silently, and such a truncated EPUB rendered as
-- a book cut off at its first picture. 3: HTML implied-end-tag ruby
-- (<ruby>来<rt>く</ruby>, no </rt> — how browsers and page savers emit it)
-- used to leak the skip/drop depth: strip_ruby discarded everything after
-- the document's first such <ruby> and annotate_fragment stopped annotating
-- there.
M.OUTPUT_VERSION = 3

-- Tags whose text content must not be annotated (matches wrapper.py
-- _SKIP_TAGS). Ruby-family tags are tracked separately (see ruby_event):
-- unlike these, their end tags may legally be omitted, so a bare depth
-- counter leaks on real-world HTML.
local SKIP_TAGS = {
    script = true, style = true, head = true,
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

-- ---------------------------------------------------------- ruby tracking --

-- HTML allows </rb>/<rt>/<rp>/<rtc> end tags to be omitted: the element is
-- closed implicitly by the next ruby-family start tag or by </ruby>.
-- Browsers — and page savers like SingleFile — really emit
-- `<ruby>来<rp>(<rt>く<rp>)</ruby>`, so ruby must be tracked with a stack
-- that applies those rules; counting opens against closes never returns to
-- zero on such markup.
local RUBY_FAMILY = { ruby = true, rb = true, rt = true, rp = true, rtc = true }
-- Elements holding the annotation (reading) itself; their text is what
-- strip_ruby discards. <ruby>/<rb> merely wrap base text.
local RUBY_ANNOT = { rt = true, rp = true, rtc = true }
-- What a start tag implicitly closes first. <rt>/<rp> nest inside <rtc>,
-- so they leave an open <rtc> alone; <rb>/<rtc> close any pending sibling.
local RUBY_IMPLIED_CLOSE = {
    ruby = {},
    rb  = { rb = true, rt = true, rp = true, rtc = true },
    rtc = { rb = true, rt = true, rp = true, rtc = true },
    rt  = { rb = true, rt = true, rp = true },
    rp  = { rb = true, rt = true, rp = true },
}
-- End tags of elements that cannot sit inside <ruby>: reaching one means
-- every open ruby-family element was implicitly closed (browsers pop them
-- the same way). Stop-loss so one unclosed <ruby> in broken markup can't
-- swallow the rest of the document.
local RUBY_BOUNDARY = {
    p = true, div = true, li = true, ul = true, ol = true, dl = true,
    dt = true, dd = true, td = true, th = true, tr = true, table = true,
    h1 = true, h2 = true, h3 = true, h4 = true, h5 = true, h6 = true,
    blockquote = true, section = true, article = true, aside = true,
    main = true, header = true, footer = true, figure = true,
    figcaption = true, pre = true, body = true, html = true,
}

local function ruby_stack_new()
    return { n = 0, annot = 0 } -- annot = open <rt>/<rp>/<rtc> count
end

local function ruby_push(st, name)
    st.n = st.n + 1; st[st.n] = name
    if RUBY_ANNOT[name] then st.annot = st.annot + 1 end
end

local function ruby_pop(st)
    local name = st[st.n]
    st[st.n] = nil; st.n = st.n - 1
    if RUBY_ANNOT[name] then st.annot = st.annot - 1 end
end

local function ruby_clear(st)
    while st.n > 0 do ruby_pop(st) end
end

-- Feed one ruby-family tag through the stack.
local function ruby_event(st, slash, name, selfclose)
    if slash == "/" then
        -- Close the nearest matching open element; everything above it on
        -- the stack closes implicitly with it. A </rb|rt|rp|rtc> never
        -- reaches past its <ruby>; a stray close tag is ignored.
        for k = st.n, 1, -1 do
            if st[k] == name then
                for _ = k, st.n do ruby_pop(st) end
                return
            end
            if st[k] == "ruby" then return end
        end
    else
        local implied = RUBY_IMPLIED_CLOSE[name]
        while st.n > 0 and implied[st[st.n]] do ruby_pop(st) end
        if not selfclose then ruby_push(st, name) end
    end
end

--- Annotate Japanese text nodes in an XHTML string, leaving markup untouched.
-- Faithful port of wrapper.py annotate_html_fragment.
-- @param tokenizer a furigana tokenizer with an :annotate(text) method
-- @param markup XHTML/HTML document text
-- @treturn string annotated markup
function M.annotate_fragment(tokenizer, markup)
    local out, on = {}, 0
    local skip_depth = 0 -- open <script>/<style>/<head>
    local ruby = ruby_stack_new() -- existing ruby is never re-annotated
    local i, len = 1, #markup

    local function skipping()
        return skip_depth > 0 or ruby.n > 0
    end

    while i <= len do
        local lt = markup:find("<", i, true)
        if not lt then
            -- trailing text node
            local part = markup:sub(i)
            if not skipping() and has_japanese(part) and not is_annotated(part) then
                part = tokenizer:annotate(part)
            end
            on = on + 1; out[on] = part
            break
        end
        if lt > i then
            local part = markup:sub(i, lt - 1)
            if not skipping() and has_japanese(part) and not is_annotated(part) then
                part = tokenizer:annotate(part)
            end
            on = on + 1; out[on] = part
        end
        local gt = markup:find(">", lt + 1, true)
        if not gt then
            -- stray '<' with no closing '>': treat the rest as a text node
            local part = markup:sub(lt)
            if not skipping() and has_japanese(part) and not is_annotated(part) then
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
            if RUBY_FAMILY[name] then
                ruby_event(ruby, slash, name, tag:sub(-2) == "/>")
            else
                if ruby.n > 0 and slash == "/" and RUBY_BOUNDARY[name] then
                    ruby_clear(ruby)
                end
                if SKIP_TAGS[name] and tag:sub(-2) ~= "/>" then
                    if slash == "/" then
                        skip_depth = skip_depth > 0 and skip_depth - 1 or 0
                    else
                        skip_depth = skip_depth + 1
                    end
                end
            end
        end
        i = gt + 1
    end

    return table.concat(out)
end

--- Remove embedded/publisher furigana, keeping the base text, so it can be
-- re-annotated from scratch. Drops <rt>/<rtc>/<rp> with their contents and
-- unwraps <ruby>/<rb>, leaving everything else untouched. Handles HTML
-- implied end tags (see ruby_event).
-- @param markup XHTML/HTML document text
-- @treturn string markup with ruby annotation removed
function M.strip_ruby(markup)
    local out, on = {}, 0
    local ruby = ruby_stack_new()
    local i, len = 1, #markup

    local function emit_text(s)
        if ruby.annot == 0 then on = on + 1; out[on] = s end
    end

    while i <= len do
        local lt = markup:find("<", i, true)
        if not lt then
            emit_text(markup:sub(i)); break
        end
        if lt > i then emit_text(markup:sub(i, lt - 1)) end
        local gt = markup:find(">", lt + 1, true)
        if not gt then
            emit_text(markup:sub(lt)); break
        end
        local tag = markup:sub(lt, gt)
        local slash, name = tag:match("^<%s*(/?)%s*([%a][%w_:%-]*)")
        if name then
            name = name:lower()
            if RUBY_FAMILY[name] then
                -- never emitted: annotation containers vanish with their
                -- contents, <ruby>/<rb> are unwrapped around the base text
                ruby_event(ruby, slash, name, tag:sub(-2) == "/>")
            else
                if ruby.n > 0 and slash == "/" and RUBY_BOUNDARY[name] then
                    ruby_clear(ruby)
                end
                if ruby.annot == 0 then
                    on = on + 1; out[on] = tag
                end
            end
        elseif ruby.annot == 0 then
            on = on + 1; out[on] = tag -- comment / declaration
        end
        i = gt + 1
    end
    return table.concat(out)
end

-- Best-effort charset sniff from a document head. Returns a lowercased charset
-- name, or nil if undeclared (caller then assumes UTF-8). Our tokenizer works on
-- UTF-8 bytes, so a non-UTF-8 standalone HTML (Shift-JIS, EUC-JP…) is refused.
local function detect_charset(data)
    if data:sub(1, 3) == "\239\187\191" then return "utf-8" end -- UTF-8 BOM
    local head = data:sub(1, 2048):lower()
    local cs = head:match("charset%s*=%s*[\"']?%s*([%w%-_]+)")        -- <meta charset=...>
        or head:match("encoding%s*=%s*[\"']%s*([%w%-_]+)")           -- <?xml encoding=...?>
    return cs
end

--- Annotate a standalone .html/.htm file (no archive), writing a new file.
-- @param tokenizer furigana tokenizer
-- @param src source .html path
-- @param dest destination .html path
-- @param progress_cb optional function(done, total, name); called once
-- @param replace_ruby strip the file's own ruby first if true
-- @treturn boolean ok
-- @treturn string|nil error message
function M.annotate_html_file(tokenizer, src, dest, progress_cb, replace_ruby)
    local fh = io.open(src, "rb")
    if not fh then return false, "could not open source HTML" end
    local data = fh:read("*a")
    fh:close()

    local cs = detect_charset(data)
    if cs and cs ~= "utf-8" and cs ~= "utf8" then
        return false, "unsupported text encoding '" .. cs .. "' — only UTF-8 HTML is supported"
    end

    if replace_ruby then data = M.strip_ruby(data) end
    data = M.annotate_fragment(tokenizer, data)
    if progress_cb then progress_cb(1, 1, src) end

    local out = io.open(dest, "wb")
    if not out then return false, "could not open destination file" end
    local ok_write = out:write(data)
    local ok_close = out:close()
    if not ok_write or ok_close == false then
        os.remove(dest)
        return false, "could not write the annotated file (storage full?)"
    end
    return true
end

-- ------------------------------------------------------------- EPUB rewrite --

local CONTENT_EXTS = { xhtml = true, html = true, htm = true }

-- Entries stored as-is instead of re-deflated: already-compressed media
-- gains nothing from another deflate pass, and images dominate the bytes of
-- illustrated books — skipping them saves minutes of device CPU per book.
local STORE_EXTS = {
    jpg = true, jpeg = true, png = true, gif = true, webp = true,
    mp3 = true, m4a = true, mp4 = true, ogg = true, woff = true, woff2 = true,
}

local function lower_ext(name)
    return (name:match("%.([%a%d]+)$") or ""):lower()
end

--- Annotate every content document in an EPUB and write a new EPUB.
-- @param tokenizer furigana tokenizer
-- @param src source .epub path
-- @param dest destination .epub path
-- @param progress_cb optional function(done, total, name) -> boolean; return
--        false to abort. Called once per content document.
-- @param replace_ruby if true, strip the book's own ruby before annotating so
--        only our furigana remains (governed by the tokenizer's level).
-- @treturn boolean ok
-- @treturn string|nil error message on failure
function M.annotate_epub(tokenizer, src, dest, progress_cb, replace_ruby)
    local Archiver = require("ffi/archiver")

    local reader = Archiver.Reader:new()
    if not reader:open(src) then
        return false, "could not open source EPUB"
    end

    -- Collect file entries; put mimetype first (required for a valid EPUB)
    -- and keep the archive order otherwise. table.sort is not stable, so the
    -- order is made explicit via ranks — a comparator that returns false for
    -- "equal" entries would let quicksort shuffle images and spine documents
    -- around arbitrarily.
    local files = {}
    for entry in reader:iterate() do
        if entry.mode == "file" then
            files[#files + 1] = entry.path
        end
    end
    local rank = {}
    for i, name in ipairs(files) do
        rank[name] = name == "mimetype" and 0 or i
    end
    table.sort(files, function(a, b) return rank[a] < rank[b] end)

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
            if CONTENT_EXTS[lower_ext(name)] then
                if replace_ruby then data = M.strip_ruby(data) end
                data = M.annotate_fragment(tokenizer, data)
                done = done + 1
                if progress_cb and progress_cb(done, total, name) == false then
                    error("aborted by user")
                end
            end
            local store = name == "mimetype" or STORE_EXTS[lower_ext(name)]
            if store then writer:setZipCompression("store") end
            local written = writer:addFileFromMemory(name, data, mtime)
            if store then writer:setZipCompression("deflate") end
            -- A failed write (device out of space, I/O error) must fail the
            -- whole run: it used to be ignored, and the truncated EPUB that
            -- resulted was kept — and cached — as if it were good, showing
            -- up as a book cut off at its first picture.
            if not written then
                error("could not write entry: " .. name
                    .. (writer.err and (" (" .. tostring(writer.err) .. ")") or ""))
            end
        end
    end)

    writer:close()
    reader:close()

    if not ok then
        os.remove(dest)
        return false, tostring(err)
    end

    -- Writer:close() flushes the archive's central directory without
    -- reporting errors, so prove the output is a complete, readable archive
    -- before anyone gets to open it: every source entry must be enumerable
    -- again. Cheap (headers only), and it turns any silent truncation left
    -- by the environment into a clean failure instead of a broken book.
    local check = Archiver.Reader:new()
    local readable = 0
    if check:open(dest) then
        for entry in check:iterate() do
            if entry.mode == "file" then readable = readable + 1 end
        end
        check:close()
    end
    if readable < #files then
        os.remove(dest)
        return false, string.format(
            "output verification failed (%d of %d entries readable — storage full?)",
            readable, #files)
    end
    return true
end

-- exposed for testing
M._has_japanese = has_japanese
M._is_annotated = is_annotated

return M
