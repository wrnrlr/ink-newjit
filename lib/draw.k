/ lib/draw.k — 2D immediate-mode drawing
/
/ Requires:  2: "lib/gpu.k"   (gpuFill, gpuTess, gpu.solid)
/            2: "lib/font/font.k"  (fontOutline)

/ ── Shapes ───────────────────────────────────────────────────────────────────

/ Rectangle as 6 vertices (2 triangles), flat F array [x,y,u,v per vertex]
rectV: {[x;y;w;h]
  x2:x+w; y2:y+h
  x,y,.5,1.,x2,y,.5,1.,x2,y2,.5,1.,x,y,.5,1.,x2,y2,.5,1.,x,y2,.5,1.}

/ Draw a filled rectangle.
/ col: (r;g;b;a) in [0,1]
rect: {[x;y;w;h;col] gpuFill[rectV[x;y;w;h]; gpu.solid . col]}

/ ── Text ─────────────────────────────────────────────────────────────────────

/ Draw a single glyph at (ox, oy) offset, tessellating its outlines.
/ h: font handle   id: glyph ID   ox,oy: screen offset   size: px
/ frag: 44-float frag uniforms (use gpu.solid for solid color)
drawGlyph: {[h;id;ox;oy;size;frag]
  cs: fontOutline[(h; id; size)]   / list of contour F arrays
  tris: ,/{gpuTess x} cs           / gpu.tessellate each contour, concatenate
  n: (#tris) % 4                   / number of vertices
  v: n 4#tris                      / reshape to n×4 matrix
  v[;0]+:ox; v[;1]+:oy             / translate to screen position
  gpuFill[,/v; frag]}              / draw
