/ lib/font.k — font module (table-oriented ECS API)
/
/ Build first:  zig build font
/ Load with:    2: "lib/font.k"
/
/ ReadFont returns a dict per face (list of dicts for TTC collections).
/ All original keys are preserved for backward compatibility:
/
/   h           — internal handle (int); used by FontShape / FontOutline
/   name        — family name (C)
/   style       — style name  (C)
/   upm         — em square size (I, units per em)
/   nGlyphs     — total glyph count (I)
/   ascent  descent  lineGap — metrics in em units (I)
/   xHeight  capHeight       — em units, 0 if unavailable (I)
/   weight  — numeric weight 100-900 (I)
/   width   — numeric width  1-9 (I)
/   bold  italic  mono  variable — flags 0/1 (I)
/   adv         — advance widths per glyph in em units (I vector, length nGlyphs)
/   lsb         — left side bearings per glyph in em units (I vector, length nGlyphs)
/   cmap        — BMP codepoint→glyph map (I vector, length 65536; 0=unmapped)
/
/ ECS global registry: Fonts (list of font dicts)
/ Unicode data:        UnicodeData (dict of tables, loaded via LoadUnicode)

so: "./zig-out/lib/libfont.dylib"

/ ── FFI bindings ─────────────────────────────────────────────────────────────

readFont0:    so 2: (`ReadFont;    1)   / "path" → dict or L of dicts (TTC)
fontShape0:   so 2: (`FontShape;   2)   / raw dyadic: handle_i text_C → I glyph IDs
fontOutline0: so 2: (`FontOutline; 1)   / raw: F[handle;glyph;size] → L of F contours

/ ── ECS global registry ──────────────────────────────────────────────────────

Fonts: ()        / list of all loaded font dicts; grows with each ReadFont call
UnicodeData: ()  / unicode property tables; loaded lazily by LoadUnicode

/ Load a font file and register it in Fonts.
/ Returns the font dict (TTF/OTF) or list of dicts (TTC).
ReadFont: {[path]
  f: readFont0 path
  $[`m~@f; Fonts:: Fonts,,f; Fonts:: Fonts,f]
  f}

/ ── ECS query helpers ────────────────────────────────────────────────────────

/ Filter Fonts using a predicate function (predicate takes x=font, returns b).
FindFont: {[pred] Fonts@&pred'Fonts}

/ Find font(s) by family name (returns list).
/ Note: ink lambdas don't close over scope; use {(y`name)~x}[nm] pattern
/ (fixes x=nm as first positional; y=font_dict varies).
FontByName: {[nm] Fonts@&{(y`name)~x}[nm]'Fonts}

/ Find font(s) by family name AND style name (returns list).
FontByStyle: {[nm;st] Fonts@&({(y`name)~x}[nm]'Fonts)&({(y`style)~x}[st]'Fonts)}

/ ── Unicode data ─────────────────────────────────────────────────────────────

/ Load unicode property tables from pre-built binary (lib/data.kb).
/ After calling this, UnicodeData is a dict with named arrays.
LoadUnicode: {UnicodeData:: `bin @ 1: "lib/data.kb"}

/ ── Table constructors (k-side) ───────────────────────────────────────────────

/ hhea sub-dict: vertical metrics in em units
FontHhea: {[f] `ascent`descent`lineGap ! f`ascent`descent`lineGap}

/ OS/2 sub-dict: style and metric metadata
FontOs2: {[f] `weight`width`xHeight`capHeight`bold`italic`mono`variable ! f`weight`width`xHeight`capHeight`bold`italic`mono`variable}

/ name sub-dict: family and style strings
FontName: {[f] `family`style ! f`name`style}

/ hmtx dict: per-glyph metrics. Use +FontHmtx[f] to flip to table (M).
FontHmtx: {[f] `gid`adv`lsb ! (!f`nGlyphs; f`adv; f`lsb)}

/ ── Public API ───────────────────────────────────────────────────────────────

/ Map text to glyph IDs via tatfi (handles UTF-8; no ligatures yet).
/ f: font dict.  t: char array (UTF-8 text).  → I glyph IDs
FontShape: {[f;t] fontShape0[f`h; t]}

/ Codepoint→glyph lookup using the k-side cmap (BMP only, O(1)).
/ f: font dict.  cp: int codepoint.  → glyph ID (0 = unmapped/notdef)
FontCmapLookup: {[f;cp] f[`cmap][cp]}

/ Get glyph outline at a pixel size.
/ f: font dict.  g: glyph ID (int).  sz: size in pixels (float).
/ → L of F contours — pass each to Tessellate for triangles
FontOutline: {[f;g;sz] fontOutline0((0.+f`h),(0.+g),(0.+sz))}

/ ── Metric utilities ─────────────────────────────────────────────────────────

/ Scale factor from em units to pixels at a given size.
/ f: font dict.  sz: pixel size.  → float scale
FontScale: {[f;sz] sz%f`upm}

/ Pixel metrics at a given size.
/ f: font dict.  sz: pixel size.  → F[ascent; descent; lineGap]
FontMetrics: {[f;sz] (FontScale[f;sz]) * f[`ascent`descent`lineGap]}

/ Advance width for one glyph in pixels.
/ f: font dict.  sz: pixel size.  g: glyph ID.  → float
GlyphPx: {[f;sz;g] (FontScale[f;sz]) * f[`adv][g]}

/ Total pixel width of a glyph-ID list (no kerning).
/ f: font dict.  sz: pixel size.  gs: I glyph IDs.  → float
TextWidth: {[f;sz;gs] +/ (FontScale[f;sz]) * f[`adv][gs]}

/ ── Query helpers ────────────────────────────────────────────────────────────

IsBold:     {x`bold}
IsItalic:   {x`italic}
IsMono:     {x`mono}
IsVariable: {x`variable}

/ Display name string: "FamilyName StyleName"
FontDisplayName: {(x`name)," ",(x`style)}
