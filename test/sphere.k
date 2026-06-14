/ test/sphere_phong.k — Sphere with Phong shading via SPIR-V copy-and-patch
/
/ Analytic ray-sphere intersection + two-light Phong, fully compiled by
/ compShader. No loops, no helper functions — everything is inlined into
/ one shader lambda using local bindings and $[cond;then;else].
/
/ Run: zig build gpu && ink test/sphere_phong.k

2: "lib/gpu/spirv.k"
2: "lib/gpu/gpu.k"

sphWds: compShader[{[uv]
  / Map uv → centred screen coords, y up, aspect corrected
  sx: ((uv[0]*2.0)-1.0)*(4.0%3.0)
  sy: 1.0-uv[1]*2.0
  / Fixed camera at (3; 2; -4)
  roX: 3.0; roY: 2.0; roZ: 0.0-4.0
  / Forward toward origin, normalised
  fwL: sqrt[(roX*roX)+(roY*roY)+(roZ*roZ)]
  fwX: (0.0-roX)%fwL
  fwY: (0.0-roY)%fwL
  fwZ: (0.0-roZ)%fwL
  / Right = cross(fw, world-up=(0;1;0)): (fwZ;0;-fwX), then normalise
  rtX: fwZ; rtZ: 0.0-fwX
  rtL: sqrt[(rtX*rtX)+(rtZ*rtZ)]
  rtX: rtX%rtL; rtZ: rtZ%rtL
  / Up = cross(fw, rt)
  upX: fwY*rtZ
  upY: (fwZ*rtX)-(fwX*rtZ)
  upZ: 0.0-fwY*rtX
  / Ray direction (focal length 2.0)
  rdX: (fwX*2.0)+(rtX*sx)+(upX*sy)
  rdY: (fwY*2.0)+(0.0*sx)+(upY*sy)
  rdZ: (fwZ*2.0)+(rtZ*sx)+(upZ*sy)
  rdL: sqrt[(rdX*rdX)+(rdY*rdY)+(rdZ*rdZ)]
  rdX: rdX%rdL; rdY: rdY%rdL; rdZ: rdZ%rdL
  / Ray-sphere intersection: sphere at origin, r=1
  / b = dot(ro,rd), c = dot(ro,ro)-1, disc = b^2-c
  b:    (roX*rdX)+(roY*rdY)+(roZ*rdZ)
  roro: (roX*roX)+(roY*roY)+(roZ*roZ)
  c:    roro - 1.0
  disc: (b*b)-c
  t:    (0.0-b)-sqrt[abs[disc]]
  hit:  (disc > 0.0) & (t > 0.0)
  / Hit position and outward normal
  hpX: roX + rdX*t; hpY: roY + rdY*t; hpZ: roZ + rdZ*t
  hpL: sqrt[(hpX*hpX)+(hpY*hpY)+(hpZ*hpZ)]
  nX: hpX%hpL; nY: hpY%hpL; nZ: hpZ%hpL
  / View vector
  vX: 0.0-rdX; vY: 0.0-rdY; vZ: 0.0-rdZ
  / Light 1: warm, from above-right
  l1X: 3.0-hpX; l1Y: 4.0-hpY; l1Z: 2.0-hpZ
  l1L: sqrt[(l1X*l1X)+(l1Y*l1Y)+(l1Z*l1Z)]
  l1X: l1X%l1L; l1Y: l1Y%l1L; l1Z: l1Z%l1L
  diff1: max[(nX*l1X)+(nY*l1Y)+(nZ*l1Z); 0.0]
  / Specular: reflect L1 about N, then dot with V
  r1dot: (nX*l1X)+(nY*l1Y)+(nZ*l1Z)
  r1X: l1X - nX*(r1dot*2.0); r1Y: l1Y - nY*(r1dot*2.0); r1Z: l1Z - nZ*(r1dot*2.0)
  spec1: pow[max[(r1X*vX)+(r1Y*vY)+(r1Z*vZ); 0.0]; 32.0]
  / Light 2: cool, from left
  l2X: (0.0-3.0)-hpX; l2Y: 2.0-hpY; l2Z: (0.0-2.0)-hpZ
  l2L: sqrt[(l2X*l2X)+(l2Y*l2Y)+(l2Z*l2Z)]
  l2X: l2X%l2L; l2Y: l2Y%l2L; l2Z: l2Z%l2L
  diff2: max[(nX*l2X)+(nY*l2Y)+(nZ*l2Z); 0.0]
  / Sphere albedo (terracotta)
  aR: 0.85; aG: 0.35; aB: 0.2
  / Combine: ambient + warm diffuse/spec + cool diffuse
  sR: (aR*0.12)+(aR*diff1*1.2)+(0.6*spec1)+(aR*0.4*diff2*0.8)
  sG: (aG*0.12)+(aG*diff1*1.2)+(0.6*spec1)+(aG*0.4*diff2*0.8)
  sB: (aB*0.12)+(aB*diff1*1.2)+(0.6*spec1)+(aB*0.4*diff2*0.8)
  / Fresnel edge glow
  vdotn: max[(vX*nX)+(vY*nY)+(vZ*nZ); 0.0]
  fres: pow[1.0-vdotn; 3.0]
  sR: sR + fres*0.4; sG: sG + fres*0.5; sB: sB + fres*1.0
  / Background: dark blue-grey
  oR: $[hit; sR; 0.06]
  oG: $[hit; sG; 0.06]
  oB: $[hit; sB; 0.12]
  / Gamma correction (approx)
  gR: pow[clamp[oR;0.0;1.0]; 0.4545]
  gG: pow[clamp[oG;0.0;1.0]; 0.4545]
  gB: pow[clamp[oB;0.0;1.0]; 0.4545]
  (gR; gG; gB; 1.0)}; [`uv:`v2; `out:`v4]]

verts: 0. 0. 0. 0. 800. 0. 1. 0. 800. 600. 1. 1. 0. 0. 0. 0. 800. 600. 1. 1. 0. 600. 0. 1.

handle:: 0
loop: {[props]
  $[handle=0; handle:: gpuSpirv[sphWds; 0]; 0]
  gpuFillShader[verts; handle]}

gpuRun[loop; 0]
