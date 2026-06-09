/ test/gpu_eyes.k — GPU eyes demo (mouse tracking)
/ Build GPU lib first:  zig build gpu
/ Run:                  ink test/gpu_eyes.k

2: "lib/gpu/gpu.k"

pi: 3.14159265359

/ Flat [x0;y0;x1;y1;...] polygon for an ellipse (n segments)
ellipsePts: {[cx;cy;rx;ry;n]
  t: (2. * pi % n) * !n
  xs: cx + rx * cos t
  ys: cy + ry * sin t
  pts: (2*n)#0.
  pts[2*!n]: xs
  pts[1+2*!n]: ys
  pts}

/ Fill a solid-color ellipse
fillEllipse: {[cx;cy;rx;ry;r;g;b]
  gpuFill[gpuTess ellipsePts[cx;cy;rx;ry;64]; gpuSolid[r;g;b;1.]]}

drawEye: {[ex;ey;er;mx;my]
  br: er * 0.35
  ry: er * 0.75
  dx: mx - ex; dy: my - ey
  d: (sqrt (dx*dx) + dy*dy) | 0.001
  maxd: 0.7 * (er*ry*d) % sqrt (sqr(ry*dx)) + sqr(er*dy)
  offset: d & maxd
  px: ex + dx * offset % d
  py: ey + dy * offset % d
  fillEllipse[ex; ey; er;    ry; 0.95; 0.94; 0.90]
  fillEllipse[px; py; br*0.7; br*0.7; 0.22; 0.18; 0.15]
  fillEllipse[px; py; br*0.3; br*0.3; 0.05; 0.04; 0.06]}

loop: {[props]
  w: props`width; h: props`height
  mx: props`mx;   my: props`my
  er: (w & h) % 6
  / background
  fillEllipse[w%2; h%2; w; h; 0.08; 0.08; 0.10]
  / left and right eye
  drawEye[(w%2) - er*1.5; h%2; er; mx; my]
  drawEye[(w%2) + er*1.5; h%2; er; mx; my]}

gpuRun[loop; 800. 600.]
