/ test/font.k — native sfnt font reader tests
/
/ Build first:  zig build font
/ Run:          ink test/font.k

2: "lib/font.k"

/ ── font.read always returns a LIST of face dicts ──────────────────────────────

faces: font.read "font/FiraCode-Regular.ttf"
`L ~ @faces
1 = #faces
`m ~ @faces 0
"font.read returns list-of-dicts ok"

f: faces 0

/ Single TTF → one-element list; keys are normalized table names.
`head`maxp`hhea`hmtx`loca`post`name`OS2`cmap in !f
"table keys present ok"

/ ── head (scalar dict) ───────────────────────────────────────────────────────

`m ~ @f`head
1950 = f[`head]`upm
0 < f[`head]`xMax
"head ok"

/ ── maxp / hhea ──────────────────────────────────────────────────────────────

2030 = f[`maxp]`numGlyphs
0 < f[`hhea]`ascent
0 > f[`hhea]`descent
"maxp / hhea ok"

/ ── hmtx (per-glyph columns, length numGlyphs) ───────────────────────────────

(f[`maxp]`numGlyphs) = #f[`hmtx]`adv
(f[`maxp]`numGlyphs) = #f[`hmtx]`lsb
0 < (f[`hmtx]`adv) 0
"hmtx ok"

/ ── loca (offsets, numGlyphs+1) ──────────────────────────────────────────────

(1 + f[`maxp]`numGlyphs) = #f`loca
"loca ok"

/ ── name (records → columns + decoded strings) ───────────────────────────────

"Fira Code"  ~ font.family f
"Regular"    ~ font.subfamily f
"Fira Code Regular" ~ font.fullName f
"name ok"

/ ── OS/2 ─────────────────────────────────────────────────────────────────────

400 = f[`OS2]`weightClass
10 = #f[`OS2]`panose
"OS2 ok"

/ ── cmap (best Unicode subtable → cp/gid) ────────────────────────────────────

0 < #(f`cmap)`cp
1 = font.glyph[f;65]        / 'A'
0 = font.glyph[f;0xFFFF]    / unmapped
"cmap ok"

/ ── metric helpers ───────────────────────────────────────────────────────────

1950 = font.upm f
(font.scale[f;48.]) ~ 48. % 1950
/ metrics = scale * (ascent; descent; lineGap) — a 3-vector, non-empty.
3 = #font.metrics[f;48.]
(font.metrics[f;48.]) ~ (font.scale[f;48.]) * f[`hhea]`ascent`descent`lineGap
"metrics ok"

/ ── TTC → multiple faces ─────────────────────────────────────────────────────

ttc: font.read "font/NotoSansCJK-Regular.ttc"
1 < #ttc
`m ~ @ttc 0
"ttc ok"

"all tests passed"
