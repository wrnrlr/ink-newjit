/ test/drive_home.k — "Drive Home" atmosphere via SPIR-V copy-and-patch
/
/ Inspired by BigWings / Martijn Steinrucken. Translates the core visual
/ elements into ink, compiled with FragmentShader (no loops, no helper fns):
/   - Night sky gradient with star-field noise
/   - Wet road with specular reflection stripe
/   - 2 analytic bokeh headlights (on-coming)
/   - 2 analytic tail lights (ahead)
/
/ Bokeh: a soft disc based on distance from the light ray to the pixel ray.
/ Road: rays pointing downward hit y=0 plane; a specular lane gives the wet
/ reflection look.
/
/ Note: the original uses for-loops for many lights; this is a static
/ 4-light version compiled entirely by the SPIR-V copy-and-patch compiler.
/
/ Run: zig build gpu && ink test/drive_home.k

2: "lib/spirv.k"
2: "lib/dye.k"
2: "lib/gpu.k"

dhWds: FragmentShader[`uv`out!`v2`v4; {[uv]
  / Screen coords, y up, aspect corrected (assume 4:3)
  sx: (uv[0]-0.5)*2.0*(4.0%3.0)
  sy: (0.5-uv[1])*2.0
  / Camera: looking down the road (z+), slight tilt
  rdX: sx; rdY: sy-0.15; rdZ: 1.5
  rdL: sqrt[(sqr rdX)+(sqr rdY)+(sqr rdZ)]
  rdX: rdX%rdL; rdY: rdY%rdL; rdZ: rdZ%rdL
  roX: 0.0; roY: 0.15; roZ: 0.0
  / ── Sky ──────────────────────────────────────────────────────────────────
  / Horizon blend: rdY > 0 → sky, rdY <= 0 → road
  skyFrac: max[rdY; 0.0]
  / Night sky: dark blue-grey to very dark near horizon
  skR: skyFrac*0.06
  skG: skyFrac*0.05
  skB: (skyFrac*0.12)+0.03
  / Simple star noise: hash of direction
  hv: sin[(rdX*127.1)+(rdY*311.7)+(rdZ*74.7)]*43758.5
  star: max[fract[hv]-0.992; 0.0]*120.0*skyFrac
  skR: skR+star; skG: skG+star; skB: skB+star
  / ── Road (y=0 plane) ────────────────────────────────────────────────────
  eps: 0.0001
  sRdY: $[rdY < (0.0-eps); rdY; 0.0-eps]
  tRd: (0.0-roY)%sRdY
  hitRoad: (rdY < 0.0-eps) & (tRd > 0.0)
  rpX: roX+rdX*tRd; rpZ: roZ+rdZ*tRd
  / Road surface: dark grey, faint lane markings
  lane: abs[fract[rpZ*0.1]-0.5]
  roadBase: 0.04 + 0.02*(1.0-smoothstep[0.0;0.05;lane])
  / Wet specular lane (white strip down centre)
  spec: smoothstep[0.04;0.0;abs[rpX]]
  roadR: roadBase + spec*0.18
  roadG: roadBase + spec*0.15
  roadB: roadBase + spec*0.25
  / ── Analytic bokeh helper (distance from ray to point light) ─────────────
  / dist = length(cross(lp - ro, rd))   cross in 2D: only need magnitude
  / cross(a, b) magnitude for 3-vectors = sqrt(|a×b|²)
  / For efficiency: use ||(lp-ro) - dot(lp-ro,rd)*rd||
  / Head light 1: left lane, coming toward camera
  h1X: 0.0-0.35; h1Y: 0.12; h1Z: 8.0
  o1X: h1X-roX; o1Y: h1Y-roY; o1Z: h1Z-roZ
  d1: (o1X*rdX)+(o1Y*rdY)+(o1Z*rdZ)
  c1X: o1X-rdX*d1; c1Y: o1Y-rdY*d1; c1Z: o1Z-rdZ*d1
  bk1: smoothstep[0.08;0.0;sqrt[(sqr c1X)+(sqr c1Y)+(sqr c1Z)]]
  / Head light 2: right lane
  h2X: 0.35; h2Y: 0.12; h2Z: 8.0
  o2X: h2X-roX; o2Y: h2Y-roY; o2Z: h2Z-roZ
  d2: (o2X*rdX)+(o2Y*rdY)+(o2Z*rdZ)
  c2X: o2X-rdX*d2; c2Y: o2Y-rdY*d2; c2Z: o2Z-rdZ*d2
  bk2: smoothstep[0.08;0.0;sqrt[(sqr c2X)+(sqr c2Y)+(sqr c2Z)]]
  / Tail light 1: slightly ahead, red
  t1X: 0.0-0.2; t1Y: 0.1; t1Z: 3.0
  ot1X: t1X-roX; ot1Y: t1Y-roY; ot1Z: t1Z-roZ
  dt1: (ot1X*rdX)+(ot1Y*rdY)+(ot1Z*rdZ)
  ct1X: ot1X-rdX*dt1; ct1Y: ot1Y-rdY*dt1; ct1Z: ot1Z-rdZ*dt1
  bkt1: smoothstep[0.05;0.0;sqrt[(sqr ct1X)+(sqr ct1Y)+(sqr ct1Z)]]
  / Tail light 2
  t2X: 0.2; t2Y: 0.1; t2Z: 3.0
  ot2X: t2X-roX; ot2Y: t2Y-roY; ot2Z: t2Z-roZ
  dt2: (ot2X*rdX)+(ot2Y*rdY)+(ot2Z*rdZ)
  ct2X: ot2X-rdX*dt2; ct2Y: ot2Y-rdY*dt2; ct2Z: ot2Z-rdZ*dt2
  bkt2: smoothstep[0.05;0.0;sqrt[(sqr ct2X)+(sqr ct2Y)+(sqr ct2Z)]]
  / ── Composite ────────────────────────────────────────────────────────────
  baseR: $[hitRoad; roadR; skR]
  baseG: $[hitRoad; roadG; skG]
  baseB: $[hitRoad; roadB; skB]
  / Add white headlights (bloom)
  lR: (bk1*0.9)+(bk2*0.9)
  lG: (bk1*0.9)+(bk2*0.9)
  lB: (bk1*1.0)+(bk2*1.0)
  / Add red tail lights
  lR: lR+(bkt1*1.0)+(bkt2*1.0)
  lG: lG+(bkt1*0.08)+(bkt2*0.08)
  lB: lB+(bkt1*0.08)+(bkt2*0.08)
  oR: pow[clamp[baseR+lR;0.0;1.0]; 0.4545]
  oG: pow[clamp[baseG+lG;0.0;1.0]; 0.4545]
  oB: pow[clamp[baseB+lB;0.0;1.0]; 0.4545]
  (oR; oG; oB; 1.0)}]

verts: 0. 0. 0. 0. 800. 0. 1. 0. 800. 600. 1. 1. 0. 0. 0. 0. 800. 600. 1. 1. 0. 600. 0. 1.

handle:: 0
loop: {[props]
  $[handle=0; handle:: CompileSpirV[dhWds; 0]; 0]
  DrawShader[verts; handle]}

window.run[loop; 0]
