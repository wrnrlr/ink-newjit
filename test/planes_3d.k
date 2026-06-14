/ test/planes_3d.k — 3 coordinate planes via SPIR-V copy-and-patch
/
/ Analytic ray-plane intersection (no ray-marching loop needed):
/   XZ plane (y=0) → red     tXZ = -ro.y / rd.y
/   YZ plane (x=0) → green   tYZ = -ro.x / rd.x
/   XY plane (z=0) → blue    tXY = -ro.z / rd.z
/ Pick closest positive hit, shade with simple Lambert + grid lines.
/ All logic compiled by compShader using $[cond;then;else].
/
/ Run: zig build gpu && ink test/planes_3d.k

2: "lib/gpu/spirv.k"
2: "lib/gpu/gpu.k"

plWds: compShader[{[uv]
  / Screen coords, y up
  sx: (uv[0]*2.0)-1.0
  sy: 1.0-uv[1]*2.0
  / Fixed camera
  roX: 2.8; roY: 1.8; roZ: 2.8
  / Forward toward origin, normalised
  fwL: sqrt[(roX*roX)+(roY*roY)+(roZ*roZ)]
  fwX: (0.0-roX)%fwL; fwY: (0.0-roY)%fwL; fwZ: (0.0-roZ)%fwL
  / Right = cross(fw, up=(0;1;0)): (fwZ;0;-fwX)
  rtX: fwZ; rtZ: 0.0-fwX
  rtL: sqrt[(rtX*rtX)+(rtZ*rtZ)]
  rtX: rtX%rtL; rtZ: rtZ%rtL
  / Up = cross(rt, fw)
  upX: 0.0-rtZ*fwY; upY: (rtZ*fwX)-(rtX*fwZ); upZ: rtX*fwY
  / Ray direction, focal 1.6
  rdX: (fwX*1.6)+(rtX*sx)+(upX*sy)
  rdY: (fwY*1.6)+(0.0*sx)+(upY*sy)
  rdZ: (fwZ*1.6)+(rtZ*sx)+(upZ*sy)
  rdL: sqrt[(rdX*rdX)+(rdY*rdY)+(rdZ*rdZ)]
  rdX: rdX%rdL; rdY: rdY%rdL; rdZ: rdZ%rdL
  / Avoid divide-by-zero with safe denominators
  eps: 0.00001
  sRdX: $[abs[rdX]>eps; rdX; eps]
  sRdY: $[abs[rdY]>eps; rdY; eps]
  sRdZ: $[abs[rdZ]>eps; rdZ; eps]
  / Analytic t for each coordinate plane
  tXZ: (0.0-roY)%sRdY
  tYZ: (0.0-roX)%sRdX
  tXY: (0.0-roZ)%sRdZ
  hXZ: tXZ > 0.001
  hYZ: tYZ > 0.001
  hXY: tXY > 0.001
  / Select smallest positive t among hit planes
  big: 999.0
  t1: $[hXZ; tXZ; big]
  t2: $[hYZ; tYZ; big]
  t3: $[hXY; tXY; big]
  tmin: min[min[t1;t2];t3]
  anyHit: tmin < 900.0
  / Which plane is closest
  isXZ: hXZ & ~(tXZ > tYZ) & ~(tXZ > tXY)
  isYZ: hYZ & ~isXZ & ~(tYZ > tXY)
  / Hit point
  hpX: roX+rdX*tmin; hpY: roY+rdY*tmin; hpZ: roZ+rdZ*tmin
  / Simple distance fade shading
  shade: max[0.25; 1.0-tmin*0.07]
  / Grid lines on the plane (fract gives distance to nearest grid line)
  gx: abs[fract[hpX]-0.5]
  gy: abs[fract[hpY]-0.5]
  gz: abs[fract[hpZ]-0.5]
  grid: 1.0 - 0.4*(1.0-smoothstep[0.0;0.04;min[min[gx;gy];gz]])
  sh: shade*grid
  / Plane colours
  pR: $[isXZ; sh; $[isYZ; sh*0.1; sh*0.1]]
  pG: $[isXZ; sh*0.15; $[isYZ; sh; sh*0.3]]
  pB: $[isXZ; sh*0.1; $[isYZ; sh*0.2; sh]]
  / Background
  oR: $[anyHit; pR; 0.05]
  oG: $[anyHit; pG; 0.05]
  oB: $[anyHit; pB; 0.08]
  (oR; oG; oB; 1.0)}; [`uv:`v2; `out:`v4]]

verts: 0. 0. 0. 0. 800. 0. 1. 0. 800. 600. 1. 1. 0. 0. 0. 0. 800. 600. 1. 1. 0. 600. 0. 1.

handle:: 0
loop: {[props]
  $[handle=0; handle:: gpuSpirv[plWds; 0]; 0]
  gpuFillShader[verts; handle]}

gpuRun[loop; 0]
