/ test/fill_demo.k — Immediate mode UI demo using the fill shader
/
/ Demonstrates FillFrame + gpuSolid + tessellate for 2D UI rendering.
/ Also shows a k-compiled SPIR-V "fill" variant: a rounded-rect SDF shader
/ that produces soft, anti-aliased filled rectangles without tesselation.
/
/ Layout:
/   - Animated solid-colored rectangles (FillFrame + gpuSolid)
/   - tessellated polygon (star shape via tessellate)
/   - SPIR-V rounded-rect SDF overlay
/
/ Run: zig build gpu && ink test/fill_demo.k

2: "lib/spirv.k"
2: "lib/dye.k"
2: "lib/gpu.k"

/ ── SPIR-V rounded-rect SDF shader ──────────────────────────────────────────
/ uv in [0,1]x[0,1], draws a soft white rounded rectangle in the centre.
/ Useful as a primitive for custom UI elements drawn via DrawShader.
rrSdf: FragmentShader[`uv`out!`v2`v4; {[uv]
  px: (uv[0]*2.0)-1.0
  py: (uv[1]*2.0)-1.0
  / Rounded rect SDF: box half-size 0.6x0.7, radius 0.15
  qx: (abs[px]-0.6)+0.15
  qy: (abs[py]-0.7)+0.15
  mx: max[qx;0.0]
  my: max[qy;0.0]
  d: (sqrt[(sqr mx)+(sqr my)] + min[max[qx;qy]; 0.0]) - 0.15
  c: smoothstep[0.02; -0.02; d]
  (c; c*0.9; c*0.7; c)}]

/ ── Vertex helpers ───────────────────────────────────────────────────────────
/ rect[x;y;w;h] → 6 vertices [x y u v ...]
rect: {[x;y;w;h] ,/(x,y,0.,0.; (x+w),y,1.,0.; (x+w),(y+h),1.,1.; x,y,0.,0.; (x+w),(y+h),1.,1.; x,(y+h),0.,1.)}

/ fullQuad[w;h] → 6 vertices for full-screen quad
fullQuad: {[w;h] rect[0.;0.;w;h]}

/ ── Star polygon (10 points alternating inner/outer radius) ──────────────────
starPts: {[cx;cy;ro;ri;n]
  ks:    !n*2
  angs:  (2.*3.14159 % (n*2)) * ks - 3.14159%2
  rads:  ri, ro
  rads:  ,/(rads)' !n*2   / interleave ri ro ri ro ...
  ,/((cx + rads*cos angs),' (cy + rads*sin angs))}

/ ── Main render loop ─────────────────────────────────────────────────────────
rrHandle:: 0

loop: {[props]
  w: props[`width]
  h: props[`height]
  t: props[`time]

  / Background — deep blue
  FillFrame[fullQuad[w;h]; gpuSolid[0.04;0.06;0.14;1.]]

  / Animated horizontal bar
  by: h*0.1 + (h*0.05)*sin t
  FillFrame[rect[0.;by;w;h*0.15]; gpuSolid[0.15;0.25;0.55;0.6]]

  / Three animated color boxes
  bw: 120.
  bh: 80.
  bx0: w*0.1 + 30.*sin t
  bx1: w*0.4 + 20.*sin[t*1.3+1.]
  bx2: w*0.7 + 25.*sin[t*0.7+2.]
  FillFrame[rect[bx0; h*0.35; bw; bh]; gpuSolid[0.9; 0.3; 0.2; 1.]]
  FillFrame[rect[bx1; h*0.35; bw; bh]; gpuSolid[0.2; 0.8; 0.3; 1.]]
  FillFrame[rect[bx2; h*0.35; bw; bh]; gpuSolid[0.25; 0.45; 1.0; 1.]]

  / Spinning star — tessellated polygon
  cx: w*0.5; cy: h*0.72
  ao: t*0.4
  / outer 5 and inner 5 points
  n: 5
  ks: !n*2
  angs: (2.*3.14159%(n*2))*ks + ao
  ro: 90.; ri: 38.
  rs: ,/((ri,ro)' !n*2)
  pts: ,/((cx+rs*cos angs),' (cy+rs*sin angs))
  starVerts: tessellate[pts]
  FillFrame[starVerts; gpuSolid[1.0;0.85;0.1;1.]]

  / SPIR-V rounded-rect in lower-right corner
  $[rrHandle=0; rrHandle:: CompileSpirV[rrSdf; 0]; 0]
  DrawShader[rect[w-200.;h-160.;180.;140.]; rrHandle]

  0}

window.run[loop; 0]
