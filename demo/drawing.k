/ demo/drawing.k — Immediate-mode 2D UI demo, drawn entirely with lib/canvas.k.
/
/ Migrated from the old gpu.fill + gpu.tessellate + gpu.drawShader path to the analytic
/ Canvas/Slug backend. Shows solid fills, alpha, a filled star polygon, and a soft
/ rounded-rect (a canvas boxGradient — the rounded-rect SDF is now a paint, no custom
/ shader needed). All resolution-independent and antialiased, no CPU tessellation.
/
/ Run: zig build gpu && ink demo/drawing.k

2: "lib/canvas.k"

WINW: 800.
WINH: 600.

/ Star polygon: n outer + n inner points, filled as one closed path from the current pen.
/ NB the vertex each takes x,y as ARGS (each-multi over 1_xs/1_ys) — an inner lambda can't
/ close over the local xs/ys (lambdas don't capture parent scope).
star: {[cx;cy;ro;ri;n;ao]
  m: n*2
  angs: ((2.*3.14159)%m)*(!m) + ao
  rs:   ,/(n#,ri,ro)                       / interleave ri ro ri ro … (length 2n)
  xs:   cx+rs*cos angs; ys: cy+rs*sin angs
  cnv.moveTo[xs 0; ys 0]
  {[x;y] cnv.lineTo[x;y]}'[1_xs; 1_ys]
  cnv.close[]}

scene: {[w;h;t]
  cnv.new[]

  / Background — deep blue
  cnv.rect[0.;0.;w;h]
  cnv.fill cnv.rgba[0.04;0.06;0.14;1.]

  / Animated horizontal bar (semi-transparent)
  by: h*0.1 + (h*0.05)*sin t
  cnv.rect[0.;by;w;h*0.15]
  cnv.fill cnv.rgba[0.15;0.25;0.55;0.6]

  / Three animated colour boxes
  bw: 120.; bh: 80.
  cnv.rect[w*0.1 + 30.*sin t;         h*0.35; bw; bh]; cnv.fill cnv.rgba[0.9;0.3;0.2;1.]
  cnv.rect[w*0.4 + 20.*sin[t*1.3+1.]; h*0.35; bw; bh]; cnv.fill cnv.rgba[0.2;0.8;0.3;1.]
  cnv.rect[w*0.7 + 25.*sin[t*0.7+2.]; h*0.35; bw; bh]; cnv.fill cnv.rgba[0.25;0.45;1.0;1.]

  / Spinning star
  star[w*0.5; h*0.72; 90.; 38.; 5; t*0.4]
  cnv.fill cnv.rgba[1.0;0.85;0.1;1.]

  / Soft rounded-rect in the lower-right — a boxGradient paint (white core → transparent)
  rx: w-200.; ry: h-160.; rw: 180.; rh: 140.
  cnv.rect[rx;ry;rw;rh]
  cnv.fill cnv.boxGradient[rx;ry;rw;rh; 24.; 40.; 1. 1. 1. 1.; 1. 1. 1. 0.]}

run: {[props]
  scene[props`width; props`height; props`time]
  cnv.render[props`width; props`height]}

window.run[run; WINW,WINH]
