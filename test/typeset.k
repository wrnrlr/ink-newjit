/ test/typeset.k — render every printable ASCII glyph from a font.
/ Reuses the eyes.k GPU pipeline (gpu.tessellate + gpu.fill).
/
/ Build first:  zig build gpu && zig build font
/ Run:          ink test/typeset.k
/
/ Note: the `'` / `/` adverbs are used only to *compute* vertex data (a pure
/ operation). All drawing goes through a single explicit gpu.fill per layer,
/ because a gpu.fill issued from inside an adverb does not draw.

2: "lib/font.k"
2: "lib/gpu.k"

FONT:  (font.read "font/FiraCode-Regular.ttf") 0   / font.read → list of faces; take face 0

SZ:    28.                / glyph size in pixels
CODES: 32+!95             / printable ASCII: space (32) .. '~' (126)
IDS:   font.shape[FONT; `c$CODES]   / glyph IDs, one per char
IDX:   !#IDS

/ ── Layout ───────────────────────────────────────────────────────────────────
COLS:   16
MARGIN: 40.
CELLW:  44.
CELLH:  52.
ROWS:   1 + _ ((#IDS) - 1) % COLS

WINW: (MARGIN*2.) + CELLW*COLS
WINH: (MARGIN*2.) + CELLH*ROWS

cellOx: {[i] MARGIN + 6.  + CELLW * i mod COLS}    / glyph left edge
cellOy: {[i] MARGIN + SZ + 8. + CELLH * _ i % COLS}  / glyph baseline

/ ── Colors ───────────────────────────────────────────────────────────────────

BG:   gpu.solid[0.11; 0.11; 0.14; 1.]   / dark background
GRID: gpu.solid[0.18; 0.18; 0.22; 1.]   / faint baseline rules
PEN:  gpu.solid[0.93; 0.92; 0.86; 1.]   / glyph ink

/ ── Geometry ─────────────────────────────────────────────────────────────────

/ A rectangle as a tessellated quad (flat [x,y,u,v] triangles).
quad: {[x;y;w;h] gpu.tessellate (x,y, (x+w),y, (x+w),(y+h), x,(y+h))}

/ Translate a flat [x,y,u,v] vertex stream by (ox,oy): tile (ox,oy,0,0) and add.
shift: {[t;ox;oy] t + ((#t) # ox,oy,0.,0.)}

/ All triangles for one glyph cell, translated to its baseline. Empty for space.
/ Contours are packed into one buffer separated by NaN pairs so gpu.tessellate
/ resolves counters (the holes in 0,8,@,a,b,e,…) instead of filling them.
cellVerts: {[i]
  cs: font.outline[FONT; IDS@i; SZ]
  $[0=#cs; 0#0.; shift[gpu.tessellate (,/{x,0n,0n}'cs); cellOx i; cellOy i]]}

/ Baseline rule quads, one per row, concatenated.
ruleVerts: ,/{[r] quad[MARGIN; (MARGIN + SZ + 8.) + CELLH*r; CELLW*COLS; 1.]}' !ROWS

/ Every glyph's triangles concatenated into one buffer (computed once).
/ cellVerts is wrapped in {..x} — applying ' to a bare name misparses.
GLYPHS: ,/{cellVerts x}' IDX

/ ── Frame ────────────────────────────────────────────────────────────────────

Multiplane: gpu.fill@'

run: {[props]
  w: props`width; h: props`height
  gpu.fill[quad[0.;0.;w;h]; BG]      / background
  gpu.fill[ruleVerts;       GRID]    / baseline rules
  gpu.fill[GLYPHS;          PEN]}    / all glyphs in one draw

window.run[run; WINW,WINH]
