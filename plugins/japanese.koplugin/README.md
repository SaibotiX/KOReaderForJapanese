## Japanese Support Plugin for KOReader ##

This plugin is heavily based on Yomichan's design, and makes use of Yomichan's
deinflection data, but was written specifically for KOReader. There are two
major features implemented by this plugin:

 1. Verb deinflection (aka deconjugation) support, based on Yomichan's very
    elegant rule-matching suffix replacement system using Yomichan's data.

 2. Text segmentation support without needing MeCab or any other binary helper,
    by re-using the users' installed dictionaries to exhaustively try every
    length of text and select the longest match which is present in the
    dictionary. This is similar to how Yomichan does MeCab-less segmentation.

    On paper this plugin should also be work with Chinese text if the user has
    Chinese dictionaries installed, though that is not its primary intended
    use-case.

The backbone of this plugin is the included `yomichan-deinflect.json`. This
file is copied verbatim from [Yomichan's `ext/data/deinflect.json`][yomichan-deinflect.json]
and can be updated when necessary by simply getting a newer copy.

Note that Yomichan and KOReader use the same license (GPL-3.0-or-later) so any
theoretical licensing problems are a non-issue.

[yomichan-deinflect.json]: https://github.com/FooSoft/yomichan/blob/21.9.30.0/ext/data/deinflect.json

## Word analysis (dictionary form, POS, conjugation & translation) ##

A third feature analyses a word with a **single tap** and shows a compact window
(fields divided by thin separators) with:

 * **Word** — the surface form you tapped (with its reading in brackets, e.g.
   `食べる (たべる)`, when the Furigana plugin is available — toggleable);
 * **Dictionary form** — the base form, recovered from whatever inflected surface
   was tapped (e.g. `食べさせられました` → `食べる`), also furigana-annotated;
 * **Type** — what kind of word it is in plain English: verb class (godan/う-verb,
   ichidan/る-verb, する-verb, 来る, ずる-verb), i-adjective (incl. the いい→よい
   irregular), na-adjective, the copula, a noun, or a non-conjugating
   particle/pronoun;
 * **Conjugation** — the inflection path from the base to the surface
   (e.g. *causative · passive · polite past*);
 * **Dictionary entry** — the dictionary form looked up in your **installed
   dictionaries** (via `sdcv`);
 * **Translation** *(optional, online)* — see below; and
 * **AI analysis** *(optional, online)* — see below.

The first four (Word, Dictionary form, Type, Conjugation) are a fixed header
shown on every page. The rest are **separate pages** you page through: each
matching dictionary, the Translation page, and the AI page — so those results get
their own entry instead of being repeated under every dictionary. Their order is
configurable (see *Page order* below).

**Navigating & scrolling.** Page through entries with the on-screen **Prev/Next**
buttons or a **horizontal swipe**. Long content scrolls with the **volume / page
keys** or a **vertical swipe**; at the bottom/top edge the volume keys move to the
**next / previous page** (like the main dictionary popup).

**Page order.** *Menu → Japanese → Analysis page order* opens a reorder list
(move up/down) of **AI analysis**, **Google Translate**, and each dictionary; the
chosen order is saved on the device and applied to every lookup. Dictionaries
appear in the list once they have been seen in a lookup. Sources you do not place
keep their default position, after the ones you do.

**Translation (optional, online).** *Menu → Japanese → Translate base +
conjugated form* shows **Google translations** of both the dictionary form and
the form you tapped (e.g. `食べる → to eat` and `食べさせられました → I was made to
eat`), so you can see how the conjugation changes the meaning. Shown as its own
page; omitted when offline.

**AI grammar analysis (optional, online).** *Menu → Japanese → AI grammar
analysis* lets you enable an LLM and pick a **provider**: **OpenAI-compatible**
(set endpoint, key, model) or **Google Gemini** (just set the API key — its free
tier works; endpoint is automatic, default model `gemini-2.0-flash`). When
enabled **and** online, the tapped word is sent for a concise grammar breakdown,
shown as its own page. The fields are ordered **Word, Dictionary Form,
Conjugation, Meaning**, then the rest (part of speech, type, stem, formality,
JLPT) and the sections (conjugation breakdown, usage notes, examples, common
confusions); any field whose value would be *n/a* is omitted. The query runs in a
dismissable subprocess (the UI never freezes); offline or unconfigured, the page
is omitted.

### How to invoke

Three ways. The first two look up the word **under the tap** (no selection is
drawn and no menu pops up, so dismissing the window returns you straight to
reading):

 1. **Whole-screen single tap** (default on). A single tap on a Japanese word
    opens the window; tapping a margin / blank area still turns the page. Toggle
    under *Menu → Japanese → “Tap a word to analyse it”*. (KOReader has no
    whole-screen single-tap slot in the Gestures menu — single tap is reserved
    for page-turning — so this toggle is how you get it. Handy if, like the
    author, you turn pages with hardware keys.)
 2. **Bind it to a gesture.** *Menu → Taps and gestures → Gesture manager* →
    pick a gesture (e.g. **double tap**, or a **tap corner**) → assign
    **“Analyse Japanese word”**. It is a `category="arg"` Dispatcher action, so
    the bound gesture’s tap position is passed through and the word under it is
    analysed (exactly like the built-in *Follow nearest link*). If no position is
    available, it falls back to the current text selection.
 3. **From the dictionary popup.** A normal dictionary lookup popup gains an
    **“Analyse (JA)”** button (for CJK words) that opens this same analysis for
    the looked-up word.

If a tap ever seems to do nothing, any error is now shown as a message (rather
than failing silently); make sure the toggle is enabled and that **“Analyse
Japanese word”** appears in the Gesture manager (which confirms the plugin is
receiving events).

### Modules

The classification/conjugation logic is a faithful Lua port of the standalone
Python engine in `cli-version/engine.py` (precision-over-coverage, lexicon-free,
JMdict-backed):

 * `conjugator.lua` — **pure-Lua port of `engine.py`**: the forward-inflection
   primitive, inflectional-only deinflection, the classification precedence
   ladder (godan/ichidan resolution, na-adj/copula/noun detection, the
   `ようだ/そうだ/みたい` auxiliaries, v5aru honorifics, the `common`-flag
   tiebreak), and the labelled paradigm builders. No KOReader/SQLite imports, so
   it runs under stock `lua`/`luajit` for the parity harness. POS data and rules
   are injected via `configure(rules, posdict)`.
 * `posdict.lua` — SQLite (`lua-ljsqlite3`) lookup over the bundled
   `jmdict_pos.sqlite` (`surface → coarse POS classes`, plus a `common`
   frequency flag); the only module that touches SQLite.
 * `analysis.lua` — the presenter: pairs the existing **Deinflector**
   (surface → dictionary headword + reason path) with `conjugator` (POS
   classification); `build_pages` splits the result into navigable pages (each
   dictionary, then Translation, then AI) and `window_text` renders one page
   (`strip_html` cleans definitions).
 * `analysisviewer.lua` — a `TextViewer` subclass adding page navigation, used
   when there is more than one page (volume/page keys + horizontal swipe → change
   page, scrolling first and only changing at the top/bottom edge; vertical swipe
   → scroll).
 * `llm.lua` — the optional AI client (OpenAI-compatible **or** Google Gemini).
   Networking is isolated in `query()`; provider request building and response
   parsing are pure and unit-tested.
 * `jutf8.lua`, `json_min.lua` — small pure-Lua helpers (codepoint-level string
   ops; a minimal JSON decoder for the rules, avoiding a `rapidjson` dependency
   in the testable core).
 * `jmdict_pos.sqlite` — the bundled POS database (~34 MB, JMdict-derived).

`main.lua` wires the single-tap touch zone (`onReaderReady` →
`setupAnalyseTouchZone` → `onTapAnalyse`), the dictionary lookup
(`lookupDefinitions` via `rawSdcv`), the optional online Google translation
(`queryTranslate`) and AI query (`queryAI`) — both gated on online and run in a
`Trapper` subprocess — the paged `AnalysisViewer` window (`showAnalysisWindow`),
the gesture action, an "Analyse (JA)" button in the dictionary popup
(`registerDictButton`), and the menu (toggles + AI settings). The engine (rules +
POS DB) is loaded lazily on first use.

### Testing (parity vs. the Python reference)

Port fidelity against `engine.py` is the acceptance bar. The harnesses in
`tools/` diff the Lua port against the Python engine (runs under stock `lua5.3`
or `luajit`):

```sh
cd tools
# 1. curated acceptance set:
python3 gen_expected.py   &&  lua5.3 run_test.lua          # 61 passed, 0 failed
# 2. large random + inflected fuzz (thousands of real JMdict words):
python3 parity_fuzz.py    &&  lua5.3 run_fuzz.lua          # 7121 passed, 0 failed
# 3. presenter unit test (headword pick, POS, conjugation path, formatting):
lua5.3 run_analysis_test.lua                               # analysis: all checks passed
# 4. LLM logic unit test (response parse + conjugation-agreement check; no network):
lua5.3 run_llm_test.lua                                    # llm: all checks passed
```

The `*_pos_fixture.lua` files are dumps of exactly the JMdict POS rows the Python
engine touched, so the Lua side classifies against identical data without SQLite.
The curated set covers the acceptance cases (`食べさせられました`, `行かなかった`,
`高くない`, `静かじゃない`, `来られた`, `勉強しました`, `できます`, `よさそう`,
a plain noun and a particle) plus the documented edge cases.

## Sentence splitting (read with the volume keys) ##

A fourth feature turns the **volume / page-turn keys** into a
sentence-by-sentence reader: *Menu → Japanese → Sentence splitting (volume
keys)*. While enabled the keys no longer turn pages (tapping still does): the
first press picks the current page's **first sentence**, speaks it through
**VOICEVOX** (the server configured under *Furigana → Word audio*) and shows
it in a small popup **right above the sentence being read** (below it when
there is no room above; at the bottom of the screen when the sentence cannot
be located on the page) together with its **Google translation** — with each
word's reading **spliced in as furigana** (`私（わたし）は行（い）く。`;
furigana and translation each have their own toggle in the submenu). Forward
= next sentence, back = previous one; stepping past either end of the page
turns it, and a sentence that runs across a page boundary is completed with
the next page's beginning (the same splitter as the Furigana plugin's auto
reader, so nothing is read twice or cut off).

The translation needs a **network connection** — the audio may not (the
VOICEVOX engine can run on the device itself), so with Wi-Fi off you still
get speech but no translation. Because that asymmetry is easy to miss, the
feature says so once per session ("No network — sentence translations are
unavailable", or "Sentence translation failed" when online attempts keep
failing); previously cached translations keep showing offline.

Smoothness comes from working ahead: one background subprocess keeps the audio
**and** the translation of the **next two sentences** cached (WAVs in the auto
reader's sentence cache — the two features share files; translations as small
text files under `cache/japanese_sentences/`), so stepping forward is instant.
The popup swaps the translation in as soon as it arrives. A **single tap** on
the popup **shows/hides the translation** (the choice sticks for the session,
so you can read "translation only when I'm stuck" — it keeps being prefetched,
so revealing is instant); a **double tap replays the sentence's audio**; a tap
anywhere else passes through (word lookups and page turns keep working).
*"Japanese sentence splitting"* can also be bound to a gesture to toggle the
feature.

Needs the **Furigana plugin** enabled (it provides the sentence splitter, the
VOICEVOX client, the tokenizer and the audio caches). On Android the volume
keys must not be ignored (KOReader's device settings) — the default when
volume-key page turning is in use.

 * `sentencesplitting.lua` — pure page building / boundary carry / ruby
   display, plus the controller: ReaderRolling's page-turn key bindings are
   deactivated (`is_inactive`) while the feature is on and their exact key
   sequences are reused for stepping; the popup anchor is found with
   crengine's `findText` scoped to the current page (a page-spanning sentence
   by its on-page part; the selection highlight it sets is cleared at once);
   a single fetch subprocess with capped retries and a hung-fetch deadline
   keeps the lookahead warm and pauses the word-audio precache (`fg.lock`)
   while it holds the engine.
 * `sentencepopup.lua` — the popup bubble, anchored above/below the sentence
   via MovableContainer's anchor logic (bottom of the screen without an
   anchor); while shown it is the topmost window, so it binds the same key
   sequences itself and forwards them to the controller.

```sh
lua5.3 tools/run_sentencesplitting_test.lua               # ALL TESTS PASSED
```
