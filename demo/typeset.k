/ demo/typeset.k — render every printable ASCII glyph from a font, via lib/canvas.k.
/
/ Build first:  zig build gpu && zig build font
/ Run:          ink demo/typeset.k
/
/ Migrated from gpu.tessellate + gpu.fill to the analytic Canvas/Slug text path: each
/ glyph is a single-char cnv.text at its grid cell — resolution-independent, antialiased,
/ holes (0 8 @ a b e …) handled by nonzero winding, no CPU tessellation.

2: "lib/canvas.k"

FONT:  (font.read "font/FiraCode-Regular.ttf") 0   / font.read → list of faces; take face 0

SZ:    28.                / glyph size in pixels
CODES: 32+!95            / printable ASCII: space (32) .. '~' (126)
IDX:   !#CODES

/ ── Layout ───────────────────────────────────────────────────────────────────
COLS:   16
MARGIN: 40.
CELLW:  44.
CELLH:  52.
ROWS:   1 + _ ((#CODES) - 1) % COLS

WINW: (MARGIN*2.) + CELLW*COLS
WINH: (MARGIN*2.) + CELLH*ROWS

/ Cell origins, vectorised (mod / % broadcast over the whole index vector — no each).
OXS: MARGIN + 6.  + CELLW * IDX mod COLS         / glyph left edge
OYS: MARGIN + SZ + 8. + CELLH * _ IDX % COLS      / glyph baseline

/ ── Colours ──────────────────────────────────────────────────────────────────
BG:   cnv.rgba[0.11; 0.11; 0.14; 1.]   / dark background
GRID: cnv.rgba[0.18; 0.18; 0.22; 1.]   / faint baseline rules
PENP: cnv.rgba[0.93; 0.92; 0.86; 1.]   / glyph ink

/ One glyph: pen to its cell origin, then a single-char analytic text draw. The lambda
/ reads only GLOBALS (FONT/SZ/PENP) — an inner lambda can't see a caller's locals.
drawGlyph: {[ox;oy;code] cnv.moveTo[ox;oy]; cnv.text[FONT; SZ; ,`c$code; PENP]}
/ One baseline rule (a thin filled rect) per row.
drawRule:  {[r] cnv.rect[MARGIN; (MARGIN + SZ + 8.) + CELLH*r; CELLW*COLS; 1.]; cnv.fill GRID}

run: {[props]
  cnv.new[]
  cnv.rect[0.; 0.; props`width; props`height]; cnv.fill BG   / background
  drawRule' !ROWS                                            / baseline rules
  drawGlyph'[OXS; OYS; CODES]                                / every glyph
  cnv.render[props`width; props`height]}

window.run[run; WINW,WINH]
