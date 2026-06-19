/ lib/font.k — font module
/
/ Build first:  zig build font
/ Load with:    2: "lib/font.k"
/
/ ReadFont returns a dict per face (list of dicts for TTC collections):
/
/   h       — internal handle (int); used by FontShape / FontOutline
/   name    — family name (C)
/   style   — style name  (C)
/   upm     — em square size (I, units per em)
/   nGlyphs — total glyph count (I)
/   ascent  descent  lineGap — metrics in em units (I)
/   xHeight  capHeight       — em units, 0 if unavailable (I)
/   weight  — numeric weight 100-900 (I)
/   width   — numeric width  1-9 (I)
/   bold  italic  mono  variable — flags 0/1 (I)
/   adv     — advance widths per glyph in em units (I vector, length nGlyphs)
/   lsb     — left side bearings per glyph in em units (I vector, length nGlyphs)

so: "./zig-out/lib/libfont.dylib"

/ ── FFI bindings ─────────────────────────────────────────────────────────────

ReadFont:     so 2: (`ReadFont;    1)   / "path" → dict or L of dicts (TTC)
fontShape0:   so 2: (`FontShape;   2)   / raw dyadic: handle_i text_C → I glyph IDs
fontOutline0: so 2: (`FontOutline; 1)   / raw: F[handle;glyph;size] → L of F contours

/ ── Public API ───────────────────────────────────────────────────────────────

/ Map text to glyph IDs.
/ f: font dict.  t: char array (UTF-8 text).  → I glyph IDs
FontShape: {[f;t] fontShape0[f`h; t]}

/ Get glyph outline at a pixel size.
/ f: font dict.  g: glyph ID (int).  sz: size in pixels (float).
/ → L of F contours — pass each to Tessellate for triangles
FontOutline: {[f;g;sz] fontOutline0(f`h,g,sz)}

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
TextWidth: {[f;sz;gs] +/ GlyphPx[f;sz]'gs}

/ ── Query helpers ────────────────────────────────────────────────────────────

/ Style flags
IsBold:     {x`bold}
IsItalic:   {x`italic}
IsMono:     {x`mono}
IsVariable: {x`variable}

/ Display name string: "FamilyName StyleName"
FontDisplayName: {(x`name)," ",(x`style)}
