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

2: "lib/gpu/spirv.k"
2: "lib/gpu/gpu.k"

/ ── Sky shader ───────────────────────────────────────────────────────────────
skyWds: FragmentShader[[uv:`v2; out:`v4]; {[uv]
  t: uv[1]
  sr: mix[0.22; 0.88; t]; sg: mix[0.45; 0.68; t]; sb: mix[0.92; 0.35; t]
  px: uv[0]*10.0; py: uv[1]*5.0
  pi0: floor[px]; pi1: floor[py]; pf0: fract[px]; pf1: fract[py]
  p00: (pi0; pi1)
  h00: fract[sin[dot[p00; (127.1;311.7)]]*43758.5]
  h10: fract[sin[dot[p00+(1.;0.); (127.1;311.7)]]*43758.5]
  h01: fract[sin[dot[p00+(0.;1.); (127.1;311.7)]]*43758.5]
  h11: fract[sin[dot[p00+(1.;1.); (127.1;311.7)]]*43758.5]
  ux: pf0*pf0*(3.0-(2.0*pf0)); uy: pf1*pf1*(3.0-(2.0*pf1))
  noise: mix[mix[h00;h10;ux]; mix[h01;h11;ux]; uy]
  cloudThr: 0.52+(t*0.25)
  cloudAmt: max[0.0; noise-cloudThr]*(1.0%(1.0-cloudThr))
  cld: cloudAmt*cloudAmt
  r: clamp[sr+(cld*(1.0-sr)); 0.; 1.]
  g: clamp[sg+(cld*(1.0-sg)); 0.; 1.]
  b: clamp[sb+(cld*(1.0-sb)); 0.; 1.]
  (r; g; b; 1.0)
}]

/ ── PBR fragment shader (Cook-Torrance) ───────────────────────────────────────
/ Material arrives per-vertex as wMat = (r; g; b; roughness) and wLit = sun
/ factor (1 = full sun, 0 = shadowed: ambient + sky-fill only).
PbrFragment: FragmentShader[[wNor:`v3; wMat:`v4; wLit:`f32; out:`v4]; {[wNor;wMat;wLit]
  ar: wMat[0]; ag: wMat[1]; ab: wMat[2]; rough: wMat[3]
  V: normalize[(0.5774; 0.5774; 0.5774)]
  L1: normalize[(0.5; 1.5; 0.3)]; H1: normalize[V+L1]
  N1L: max[0.0; dot[wNor; L1]]; N1V: max[0.0001; dot[wNor; V]]
  N1H: max[0.0; dot[wNor; H1]]; V1H: max[0.0; dot[V; H1]]
  a: rough*rough; a2: a*a
  dn: (N1H*N1H*(a2-1.0))+1.0
  D: a2%(3.14159*dn*dn)
  k: (rough+1.0)*(rough+1.0)%8.0
  Gl: N1L%((N1L*(1.0-k))+k); Gv: N1V%((N1V*(1.0-k))+k); G: Gl*Gv
  F1: 0.04+(0.96*pow[1.0-V1H; 5.0])
  dnom: (4.0*N1L*N1V)+0.001; spec: (D*G*F1)%dnom
  kd1: 1.0-F1
  d1r: kd1*ar%3.14159; d1g: kd1*ag%3.14159; d1b: kd1*ab%3.14159
  sun: N1L*2.0*wLit
  L2: normalize[(-0.3; 0.8; -0.6)]; N2L: max[0.0; dot[wNor; L2]]
  skyW: max[0.0; wNor[1]]; gndW: max[0.0; -1.0*wNor[1]]
  ambR: (skyW*0.06)+(gndW*0.10); ambG: (skyW*0.10)+(gndW*0.07); ambB: (skyW*0.18)+(gndW*0.03)
  fillR: N2L*ar*0.35%3.14159; fillG: N2L*ag*0.35%3.14159; fillB: N2L*ab*0.35%3.14159
  lr: clamp[(ar*ambR)+fillR+((spec+d1r)*sun); 0.; 1.]
  lg: clamp[(ag*ambG)+fillG+((spec+d1g)*sun); 0.; 1.]
  lb: clamp[(ab*ambB)+fillB+((spec+d1b)*sun); 0.; 1.]
  (lr; lg; lb; 1.0)
}]

/ ── Vertex shader ─────────────────────────────────────────────────────────────
/ Projects pos to clip space (isometric-ish) and passes normal + material through.
pbrVtx: VertexShader[[pos:`v3;nor:`v3;mat:`v4;lit:`f32]; [wNor:`v3;wMat:`v4;wLit:`f32]; {[pos;nor;mat;lit]
  c45:0.7071; s45:0.7071; c30:0.8165; s30:0.5774; sc:0.3
  py0:(c45*pos[0])+(s45*pos[2])
  py2:(c45*pos[2])-(s45*pos[0])
  px1:(c30*pos[1])-(s30*py2)
  px2:(s30*pos[1])+(c30*py2)
  ((sc*py0; sc*px1; 0.5-px2*0.001; 1.0); nor; mat; lit)
}]

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
camX:: 0.; camZ:: 0.; zoom:: 1.
rotCa:: 1.; rotSa:: 0.
xCa:: 1.; xSa:: 0.
lastMx:: 0.; lastMy:: 0.

pbrHandle:: 0; skyHandle:: 0

/ ── Window loop ───────────────────────────────────────────────────────────────
RunWindow[{[props]
  $[pbrHandle=0; pbrHandle:: CompileMesh[pbrVtx; PbrFragment]; 0]
  $[skyHandle=0; skyHandle:: CompileSpirV[skyWds; 0];      0]

  / Read inputs into locals first — `props`key` is only safe as a standalone
  / term (right-to-left parsing binds `props`key OP x` the wrong way otherwise).
  kw: props`kw; ka: props`ka; ks: props`ks; kd: props`kd
  scroll: props`scroll; rmb: props`rmb; mx: props`mx; my: props`my

  / Camera pan
  spd: 0.05%zoom
  da: kd-ka; ws: kw-ks
  camX:: camX+(spd*(da+ws)); camZ:: camZ+(spd*(da-ws))
  zoom:: 5.0&(0.3|zoom*(1.0+(scroll*0.1)))

  / Scene rotation: right-drag X → Y-axis, right-drag Y → X-axis
  dragging: rmb>0.
  dx: $[dragging; mx-lastMx; 0.]
  dy: $[dragging; my-lastMy; 0.]
  dSa: dx*0.003; dCa: 1.0-(dSa*dSa*0.5)
  nCa: (rotCa*dCa)-(rotSa*dSa); nSa: (rotSa*dCa)+(rotCa*dSa)
  $[dragging; rotCa:: nCa; 0]
  $[dragging; rotSa:: nSa; 0]
  dxSa: dy*0.003; dxCa: 1.0-(dxSa*dxSa*0.5)
  nxCa: (xCa*dxCa)-(xSa*dxSa); nxSa: (xSa*dxCa)+(xCa*dxSa)
  $[dragging; xCa:: nxCa; 0]
  $[dragging; xSa:: nxSa; 0]
  lastMx:: mx; lastMy:: my

  ca: rotCa; sa: rotSa; xca: xCa; xsa: xSa

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
