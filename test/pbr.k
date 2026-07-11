/ test/pbr.k — PBR scene: procedural sky + grass ground + brown box + shadow
/
/ One vertex shader + one fragment shader drive the whole scene. Each mesh
/ vertex carries its own material (rgb + roughness) and a "sun" factor in the
/ range 0..1, so ground, box and shadow are just the same shader fed different
/ per-vertex data rather than three near-identical shaders.
/
/ Vertex layout (stride 11): x y z  nx ny nz  r g b rough  lit
/
/ Controls:
/   WASD           — pan camera
/   Scroll         — zoom in/out
/   Right-drag X   — rotate scene (Y-axis)
/   Right-drag Y   — tilt scene (X-axis)
/
/ Run: zig build gpu && ink test/pbr.k

2: "lib/spirv.k"
2: "lib/dye.k"
2: "lib/gpu.k"
2: "lib/pbr.k"      / shared PBR renderer: pbrVtx + PbrFragment
2: "lib/camera.k"  / orbit camera (WASD pan, scroll zoom, right-drag rotate)

/ ── Sky shader ───────────────────────────────────────────────────────────────
skyWds: FragmentShader[[uv:`v2; out:`v4]; {[uv]
  t: uv[1]
  sr: mix[0.22; 0.88; t]; sg: mix[0.45; 0.68; t]; sb: mix[0.92; 0.35; t]
  px: uv[0]*10.0; py: uv[1]*5.0
  pi0: floor px; pi1: floor py; pf0: fract px; pf1: fract py
  p00: (pi0; pi1)
  h00: fract[sin[dot[p00; 127.1 311.7]]*43758.5]
  h10: fract[sin[dot[p00+1. 0.; 127.1 311.7]]*43758.5]
  h01: fract[sin[dot[p00+0. 1.; 127.1 311.7]]*43758.5]
  h11: fract[sin[dot[p00+1. 1.; 127.1 311.7]]*43758.5]
  ux: pf0*pf0*(3.0-(2.0*pf0)); uy: pf1*pf1*(3.0-(2.0*pf1))
  noise: mix[mix[h00;h10;ux]; mix[h01;h11;ux]; uy]
  cloudThr: 0.52+(t*0.25)
  cloudAmt: max[0.0; noise-cloudThr]*(1.0%(1.0-cloudThr))
  cld: cloudAmt*cloudAmt
  / mix[a;1;t] = a+t*(1-a); evaluation is right-to-left so no parens needed.
  / Encode linear→sRGB (0.4545 = 1/2.2) to match lib/pbr.k's PbrFragment output.
  r: pow[clamp[mix[sr; 1.0; cld]; 0.; 1.];0.4545]
  g: pow[clamp[mix[sg; 1.0; cld]; 0.; 1.];0.4545]
  b: pow[clamp[mix[sb; 1.0; cld]; 0.; 1.];0.4545]
  (r; g; b; 1.0)
}]

/ ── PBR renderer ──────────────────────────────────────────────────────────────
/ pbrVtx (isometric projection) and PbrFragment (Cook-Torrance) come from
/ lib/pbr.k; the scene below just feeds them per-vertex material + sun data.

/ ── Materials (r g b roughness sun) ───────────────────────────────────────────
grass:  0.13 0.42 0.07 0.90 1.   / lit grass ground
wood:   0.50 0.28 0.08 0.65 1.   / brown box
shadow: 0.13 0.42 0.07 0.90 0.   / grass colour, direct sun blocked

/ ── Geometry helpers ──────────────────────────────────────────────────────────
/ Each vertex = pos(3) , normal(3) , material(5)  →  stride 11.
mkFace: {[a;b;c;d;n;m] (a,n,m),(b,n,m),(c,n,m),(a,n,m),(c,n,m),(d,n,m)}
mkTri:  {[a;b;c;n;m]   (a,n,m),(b,n,m),(c,n,m)}
ry: {[v;ca;sa] ((ca*v[0])-(sa*v[2]); v[1]; (sa*v[0])+(ca*v[2]))}
rx: {[v;ca;sa] (v[0]; (ca*v[1])-(sa*v[2]); (sa*v[1])+(ca*v[2]))}
rp: {[v;yca;ysa;xca;xsa] rx[ry[v;yca;ysa];xca;xsa]}

up: 0. 1. 0.

/ Box corners — unit cube on y=0.  Name = x(L/R) y(D/U) z(B/F):
/   L/R = left(-x)/right(+x),  D/U = down(y0)/up(y1),  B/F = back(-z)/front(+z)
LDB:-0.5 0. -0.5; LDF:-0.5 0. 0.5; LUB:-0.5 1. -0.5; LUF:-0.5 1. 0.5
RDB: 0.5 0. -0.5; RDF: 0.5 0. 0.5; RUB: 0.5 1. -0.5; RUF: 0.5 1. 0.5

/ ── Global state ──────────────────────────────────────────────────────────────
cam:: CamNew[]                  / orbit camera state (see lib/camera.k)

pbrHandle:: 0; skyHandle:: 0

/ ── Window loop ───────────────────────────────────────────────────────────────
window.run[{[props]
  $[pbrHandle=0; pbrHandle:: CompileMesh[pbrVtx; PbrFragment]; 0]
  $[skyHandle=0; skyHandle:: CompileSpirV[skyWds; 0];      0]

  / Fold one frame of input into the orbit camera, then read its pose
  cam:: CamUpdate[cam; props]
  ca: cam`rotCa; sa: cam`rotSa; xca: cam`xCa; xsa: cam`xSa
  zoom: cam`zoom; camX: cam`camX; camZ: cam`camZ

  / Ground plane ±8
  gndVerts: mkFace[rp[(-8.;0.;-8.);ca;sa;xca;xsa]; rp[(8.;0.;-8.);ca;sa;xca;xsa];
                   rp[(8.;0.;8.);ca;sa;xca;xsa]; rp[(-8.;0.;8.);ca;sa;xca;xsa];
                   rp[up;ca;sa;xca;xsa]; grass]

  / Box — pre-rotate all 8 corners + 5 face normals, then build faces
  rLDB: rp[LDB;ca;sa;xca;xsa]; rLDF: rp[LDF;ca;sa;xca;xsa]; rLUB: rp[LUB;ca;sa;xca;xsa]; rLUF: rp[LUF;ca;sa;xca;xsa]
  rRDB: rp[RDB;ca;sa;xca;xsa]; rRDF: rp[RDF;ca;sa;xca;xsa]; rRUB: rp[RUB;ca;sa;xca;xsa]; rRUF: rp[RUF;ca;sa;xca;xsa]
  nUp:    rp[up;ca;sa;xca;xsa]
  nFront: rp[(0.;0.;1.);ca;sa;xca;xsa]
  nBack:  rp[(0.;0.;-1.);ca;sa;xca;xsa]
  nRight: rp[(1.;0.;0.);ca;sa;xca;xsa]
  nLeft:  rp[(-1.;0.;0.);ca;sa;xca;xsa]
  boxVerts: (mkFace[rLUB;rRUB;rRUF;rLUF;nUp;wood]),(mkFace[rLDF;rRDF;rRUF;rLUF;nFront;wood]),(mkFace[rRDB;rLDB;rLUB;rRUB;nBack;wood]),(mkFace[rRDF;rRDB;rRUB;rRUF;nRight;wood]),(mkFace[rLDB;rLDF;rLUF;rLUB;nLeft;wood])

  / Shadow hex at y=0.001 — box footprint projected along L=normalize(0.5,1.5,0.3)
  sn: rp[up;ca;sa;xca;xsa]
  sc0: rp[(-0.167;0.001;-0.100);ca;sa;xca;xsa]
  sv0: rp[(-0.834;0.001;-0.700);ca;sa;xca;xsa]
  sv1: rp[(0.167;0.001;-0.700);ca;sa;xca;xsa]
  sv2: rp[(0.5;0.001;-0.5);ca;sa;xca;xsa]
  sv3: rp[(0.5;0.001;0.5);ca;sa;xca;xsa]
  sv4: rp[(-0.5;0.001;0.5);ca;sa;xca;xsa]
  sv5: rp[(-0.834;0.001;0.3);ca;sa;xca;xsa]
  shadVerts: (mkTri[sc0;sv0;sv1;sn;shadow]),(mkTri[sc0;sv1;sv2;sn;shadow]),(mkTri[sc0;sv2;sv3;sn;shadow]),(mkTri[sc0;sv3;sv4;sn;shadow]),(mkTri[sc0;sv4;sv5;sn;shadow]),(mkTri[sc0;sv5;sv0;sn;shadow])

  / Apply camera pan + zoom CPU-side (scale x y z, translate x z; leave normal+material)
  zMask: (zoom;zoom;zoom;1.;1.;1.;1.;1.;1.;1.;1.)
  cMask: (camX;0.;camZ;0.;0.;0.;0.;0.;0.;0.;0.)
  pan: {[v;zM;cM] n:#v; (n#zM)*(v-(n#cM))}
  tvg: pan[gndVerts;zMask;cMask]; tvb: pan[boxVerts;zMask;cMask]; tvs: pan[shadVerts;zMask;cMask]

  / Draw: sky → ground → shadow (on ground, blocked by box) → box
  w: props`width; h: props`height
  skyV: 0.,0.,0.,0., w,0.,1.,0., w,h,1.,1., 0.,0.,0.,0., w,h,1.,1., 0.,h,0.,1.
  DrawShader[skyV; skyHandle]
  DrawMesh[tvg; pbrHandle]
  DrawMesh[tvs; pbrHandle]
  DrawMesh[tvb; pbrHandle]
}; 0]
