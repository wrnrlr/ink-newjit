/ demo/slug.k — resolution-independent glyph rendering via lib/slug.k (Slug-style).
/
/ Build first:  zig build gpu
/ Run:          ink demo/slug.k
/ Snapshot:     INK_SNAP=1 ink demo/slug.k
/
/ Each glyph's outline is packed into a float curve texture and filled by a fragment
/ shader that computes analytic per-pixel coverage — NO tessellation, sharp at any
/ zoom, antialiased, with holes (counters) resolved by nonzero winding.

2: "lib/slug.k"
2: "lib/font.k"

FONT: (font.read "font/FiraCode-Regular.ttf") 0
LC: "eag8"                                   / glyphs with curves + holes
GIDS: {font.glyph[FONT; x]}' `i$LC
GDATA: {slug.glyph[FONT; x; 100.; 0.16]}' GIDS   / curve-texture data (host side)

/ Four glyph cells across the window (clip-space rects → slug.quad, stride 4).
QUADS: {[i] l:(-1.)+(i*0.5); slug.quad[l+0.02; (-0.62); (l+0.5)-0.02; 0.62]}' !4

pipe:: 0; VBS:: 0; TEX:: 0
/ One-time GPU setup: pipeline, a quad buffer per glyph, a curve texture per glyph.
/ Explicit calls (not an each) — buffer/texture creation inside a '/ / adverb is
/ eliminated like a draw, so an each would leave these empty.
initGpu: {[]
  pipe:: slug.pipe[]
  VBS:: (gpu.buffer[QUADS 0]; gpu.buffer[QUADS 1]; gpu.buffer[QUADS 2]; gpu.buffer[QUADS 3])
  TEX:: (,slug.upload GDATA 0; ,slug.upload GDATA 1; ,slug.upload GDATA 2; ,slug.upload GDATA 3)}
run: {[props]
  $[pipe=0; initGpu[]; 0]
  slug.draw[pipe; VBS 0; TEX 0]
  slug.draw[pipe; VBS 1; TEX 1]
  slug.draw[pipe; VBS 2; TEX 2]
  slug.draw[pipe; VBS 3; TEX 3]}

window.run[run; 520. 200.]
