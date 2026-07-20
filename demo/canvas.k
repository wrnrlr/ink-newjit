/ demo/canvas.k — the Canvas ops-table API (lib/canvas.k), Phase 0.
/
/ Build first:  zig build gpu
/ Run:          ink demo/canvas.k
/ Snapshot:     INK_SNAP=1 ink demo/canvas.k   (writes demo/canvas-snap.png)
/
/ Shows the whole Phase-0 story: an immediate-mode path API that RECORDS into a
/ retained ops table (cnv.scene[]), each draw carrying its own 2×3 transform, then
/ one CPU render pass that flattens the quads and issues the fills. save/restore
/ nest transforms; fill takes a paint, stroke takes paint+width; text fills glyph
/ outlines (one draw per glyph) at a pixel size from the current pen.

2: "lib/canvas.k"

FONT: (font.read "font/FiraCode-Regular.ttf") 0

WINW: 640.
WINH: 360.

RED: cnv.rgba[0.90; 0.30; 0.24; 1.]
GRN: cnv.rgba[0.30; 0.80; 0.45; 1.]
YEL: cnv.rgba[0.95; 0.80; 0.20; 1.]
/ raw rgba 4-vectors for the gradient constructors (they take colours, not blocks)
CTOP: 0.10 0.11 0.17 1.
CBOT: 0.17 0.13 0.22 1.
CHOT: 0.98 0.55 0.15 1.
CCOOL: 0.20 0.35 0.85 1.

/ A centred square [-r..r] as a closed path in LOCAL space.
square: {[r] cnv.moveTo[(-r);(-r)]; cnv.lineTo[r;(-r)]; cnv.lineTo[r;r]; cnv.lineTo[(-r);r]; cnv.close[]}
/ An axis-aligned rectangle as a closed path.
rectPath: {[x;y;w;h] cnv.moveTo[x;y]; cnv.lineTo[x+w;y]; cnv.lineTo[x+w;y+h]; cnv.lineTo[x;y+h]; cnv.close[]}

scene: {[t]
  cnv.new[]

  / background — a vertical linear gradient across the whole window
  rectPath[0.;0.;WINW;WINH]
  cnv.fill cnv.linearGradient[0.;0.;0.;WINH; CTOP; CBOT]

  / red square, translated + rotated about its own centre (per-draw transform)
  cnv.save[]; cnv.translate[130.;110.]; cnv.rotate[t]
    square 46.
    cnv.fill RED
  cnv.restore[]

  / radial-gradient square — the gradient is defined in LOCAL space, so it rides
  / through the translate+scale (paintMat = inverse(CTM ∘ gradXform)).
  cnv.save[]; cnv.translate[330.;110.]; cnv.scale[1.6;1.1]
    square 34.
    cnv.fill cnv.radialGradient[0.;0.;3.;40.; CHOT; CCOOL]
  cnv.restore[]

  / yellow triangle via quad + cubic curves, nested under a translate
  cnv.save[]; cnv.translate[500.;110.]
    cnv.moveTo[(-50.);40.]; cnv.quadTo[0.;(-80.);50.;40.]; cnv.close[]
    cnv.fill YEL
  cnv.restore[]

  / clipped gradient bar — the fill spans wide but the clip crops it to a window
  cnv.save[]
    cnv.clip[150.;158.;340.;26.]
    rectPath[40.;150.;560.;42.]
    cnv.fill cnv.linearGradient[40.;0.;600.;0.; CHOT; CCOOL]
  cnv.restore[]

  / green stroked zig-zag, width 10
  cnv.save[]; cnv.translate[80.;210.]
    cnv.moveTo[0.;0.]; cnv.lineTo[120.;60.]; cnv.lineTo[240.;0.]; cnv.lineTo[360.;60.]; cnv.lineTo[480.;0.]
    cnv.stroke[GRN; 10.]
  cnv.restore[]

  / text — filled glyph outlines, positioned + slanted by the per-draw transform
  cnv.save[]; cnv.translate[40.;320.]
    cnv.moveTo[0.;0.]
    cnv.text[FONT; 44.; "Canvas in ink"; YEL]
  cnv.restore[]}

run: {[props]
  scene props`time
  cnv.render[]}

window.run[run; WINW,WINH]
