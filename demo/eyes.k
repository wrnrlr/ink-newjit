/ demo/eyes.k — GPU eyes demo (mouse tracking), drawn with the Canvas/Slug API.
/ Build GPU lib first:  zig build gpu
/ Run:                  ink demo/eyes.k
/
/ Migrated from the old gpu.fill + gpu.tessellate path to lib/canvas.k: each eye is a
/ few analytic ellipse fills (cnv.ellipse) — resolution-independent and antialiased,
/ no CPU tessellation. Coordinates are framebuffer pixels (props`width/`height), which
/ is exactly what cnv.render maps 1:1, so no DPI scale is needed.

2: "lib/canvas.k"

/ Fill a solid-colour ellipse via the canvas scene buffer.
fillEllipse: {[cx;cy;rx;ry;r;g;b] cnv.ellipse[cx;cy;rx;ry]; cnv.fill cnv.rgba[r;g;b;1.]}

drawEye: {[ex;ey;er;mx;my]
  br: er * 0.35
  ry: er * 0.75
  dx: mx - ex; dy: my - ey
  d: (sqrt (dx*dx) + dy*dy) | 0.001
  maxd: 0.7 * (er*ry*d) % sqrt (sqr(ry*dx)) + sqr(er*dy)
  offset: d & maxd
  px: ex + dx * offset % d
  py: ey + dy * offset % d
  fillEllipse[ex; ey; er; ry;  0.95; 0.94; 0.90]
  fillEllipse[px; py; br; br;  0.22; 0.18; 0.15]
  fillEllipse[px; py; br*0.3; br*0.3; 0.05; 0.04; 0.06]}

run: {[props]
  w: props`width; h: props`height
  mx: props`mx;   my: props`my
  er: (w & h) % 6.
  cnv.new[]
  fillEllipse[w%2.; h%2.; w; h; 0.08; 0.08; 0.10]         / full-bleed dark backdrop
  drawEye[(w%2.) - er*1.5; h%2.; er; mx; my]
  drawEye[(w%2.) + er*1.5; h%2.; er; mx; my]
  cnv.render[w; h]}

window.run[run; 800. 600.]
