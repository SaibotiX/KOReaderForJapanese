--- Extract per-word readings from the tokenizer's annotated output.
--
-- The tokenizer turns plain text into the same text with
-- `<ruby>BASE<rt>READING</rt></ruby>` runs spliced in (BASE is the token's
-- annotated surface and may itself contain kana, e.g. 黒かっ→ぐろかっ;
-- okurigana outside the dictionary's ruby base stays plain). This module maps
-- those runs back to byte offsets in the plain text, so the reading of the
-- word at a known offset (e.g. the word under a tap) can be extracted.
--
-- Pure Lua with no KOReader dependencies, so it is unit-testable standalone:
--   lua tools/run_reading_extractor_test.lua
--
-- @module koplugin.furigana.readingextractor

local ReadingExtractor = {}

--- Parse annotated text into ruby runs with offsets into the plain text.
-- Returns:
--  * runs: array of { start = 0-based byte offset, len = #base in bytes,
--    base = token surface, reading = kana reading }, in text order;
--  * plain: the annotated text with all ruby markup stripped. Callers should
--    check it equals the original input — if not, offsets cannot be trusted.
function ReadingExtractor.parse(annotated)
    local runs = {}
    local plain = {}
    local plain_len = 0
    local pos = 1
    while true do
        local s, e, base, reading = annotated:find("<ruby>(.-)<rt>(.-)</rt></ruby>", pos)
        if not s then
            plain[#plain + 1] = annotated:sub(pos)
            break
        end
        local before = annotated:sub(pos, s - 1)
        plain[#plain + 1] = before
        plain_len = plain_len + #before
        runs[#runs + 1] = { start = plain_len, len = #base, base = base, reading = reading }
        plain[#plain + 1] = base
        plain_len = plain_len + #base
        pos = e + 1
    end
    return runs, table.concat(plain)
end

--- Build the display text for the word at byte range [word_start,
-- word_start+word_len) (0-based) of the plain text: the text of the region
-- covering both the word and every ruby run overlapping it, with each run's
-- reading inserted after its base, e.g. 食（た）べた or 高田平野（たかだへいや）.
-- Returns nil when no ruby run overlaps the word (kana-only word, or unknown
-- to the dictionary), i.e. there is no reading to show.
function ReadingExtractor.display(plain_text, runs, word_start, word_len, open, close)
    open, close = open or "（", close or "）"
    local word_end = word_start + word_len -- exclusive
    local overlapping = {}
    for _, r in ipairs(runs) do
        if r.start < word_end and (r.start + r.len) > word_start then
            overlapping[#overlapping + 1] = r
        end
    end
    if #overlapping == 0 then
        return nil
    end
    -- Cover the union of the word and its overlapping runs, so tapping any
    -- character of a token shows the whole token annotated (runs are in text
    -- order, so the first/last overlapping ones bound the union).
    local last = overlapping[#overlapping]
    local lo = math.min(word_start, overlapping[1].start)
    local hi = math.max(word_end, last.start + last.len)
    local out = {}
    local cur = lo
    for _, r in ipairs(overlapping) do
        if r.start > cur then
            out[#out + 1] = plain_text:sub(cur + 1, r.start)
        end
        out[#out + 1] = r.base .. open .. r.reading .. close
        cur = r.start + r.len
    end
    if cur < hi then
        out[#out + 1] = plain_text:sub(cur + 1, hi)
    end
    return table.concat(out)
end

return ReadingExtractor
