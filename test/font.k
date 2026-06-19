/ test/font.k — font module tests
/ Run: timeout 5s ./zig-out/bin/ink test/font.k

2: "lib/font.k"

/ ── Load font ────────────────────────────────────────────────────────────────

f: ReadFont "font/FiraCode-Regular.ttf"

/ Basic structure checks
`m ~ @f
`h`name`style`upm`nGlyphs`ascent`descent`lineGap`xHeight`capHeight`weight`width`bold`italic`mono`variable`adv`lsb ~ !f

/ Handle is a non-negative int
~(0 > f[`h])
"handle ok"

/ Name checks — FiraCode Regular
"Fira Code Regular" ~ FontDisplayName f
"name ok"

/ Em metrics — ascent positive, descent negative
0 < f[`ascent]
0 > f[`descent]
0 <: f[`upm]
"em metrics ok"

/ Per-glyph arrays are length nGlyphs
(f[`nGlyphs]) = #f[`adv]
(f[`nGlyphs]) = #f[`lsb]
"glyph array lengths ok"

/ Glyph 0 (.notdef) advance > 0 in most fonts
0 < f[`adv][0]
"notdef advance ok"

/ Pixel metrics at 48px
m: FontMetrics[f;48.]
3 = #m
0. < m[0]
0. > m[1]
"pixel metrics ok"

/ FontScale
s: FontScale[f;48.]
s ~ 48.%f[`upm]
"scale ok"

/ Shape text → glyph IDs
ids: FontShape[f;"Hi"]
2 = #ids
"shape count ok"
0 < ids[0]         / H is not .notdef
0 < ids[1]         / i is not .notdef
"glyph IDs ok"

/ GlyphPx — advance for 'H' glyph
w: GlyphPx[f;48.;ids[0]]
0. < w
"glyph pixel advance ok"

/ TextWidth
tw: TextWidth[f;48.;ids]
tw ~ w + GlyphPx[f;48.;ids[1]]
"text width ok"

/ Outline for 'H'
ol: FontOutline[f;ids[0];48.]
0 < #ol              / at least one contour
0 < #ol[0]           / at least one point
"outline ok"

/ Flags — FiraCode Regular: not bold, not italic, is mono
0 = IsBold f
0 = IsItalic f
1 = IsMono f
"flags ok"

/ ── TTC test ─────────────────────────────────────────────────────────────────

faces: ReadFont "font/NotoSansCJK-Regular.ttc"
1 < #faces           / TTC has multiple faces
`m ~ @faces[0]
"ttc ok"

"all tests passed"
