/ test/sword.k — load a binary FBX model (lib/fbx.k) and render just the mesh.
/
/ The mesh comes from data/FBX/Sword.fbx: ReadFbx → fbx.trimesh gives a
/ (positions; triangles) pair, which is centred, scaled and flat-shaded into
/ the pbr vertex layout (stride 11: x y z  nx ny nz  r g b rough  lit).
/ All per-frame work (rotation, zoom, pan, normal recompute) is vectorised
/ over the whole mesh — no per-vertex loop.
/
/ Controls:
/   WASD           — pan camera
/   Scroll         — zoom in/out
/   Right-drag X   — rotate scene (Y-axis)
/   Right-drag Y   — tilt scene (X-axis)
/
/ Run: zig build gpu && ink test/sword.k

2: "lib/spirv.k"
2: "lib/gpu.k"
2: "lib/fbx.k"

/ ── PBR fragment shader (Cook-Torrance, from pbr.k) ───────────────────────────
PbrFragment: FragmentShader[[wNor:`v3; wMat:`v4; wLit:`f32; out:`v4]; {[wNor;wMat;wLit]
  ar: wMat[0]; ag: wMat[1]; ab: wMat[2]; rough: wMat[3]
  V: normalize 0.5774 0.5774 0.5774
  L1: normalize 0.5 1.5 0.3; H1: normalize V+L1
  N1L: max[0.0; dot[wNor; L1]]; N1V: max[0.0001; dot[wNor; V]]
  N1H: max[0.0; dot[wNor; H1]]; V1H: max[0.0; dot[V; H1]]
  a: sqr rough; a2: sqr a
  dn: (sqr[N1H]*(a2-1.0))+1.0
  D: a2%(3.14159*dn*dn)
  k: sqr[rough+1.0]%8.0
  Gl: N1L%((N1L*(1.0-k))+k); Gv: N1V%((N1V*(1.0-k))+k); G: Gl*Gv
  F1: 0.04+(0.96*pow[1.0-V1H; 5.0])
  dnom: (4.0*N1L*N1V)+0.001; spec: (D*G*F1)%dnom
  kd1: 1.0-F1
  d1r: kd1*ar%3.14159; d1g: kd1*ag%3.14159; d1b: kd1*ab%3.14159
  sun: N1L*2.0*wLit
  L2: normalize[-0.3 0.8 -0.6]; N2L: max[0.0; dot[wNor; L2]]
  skyW: max[0.0; wNor[1]]; gndW: max[0.0; -1.0*wNor[1]]
  ambR: (skyW*0.06)+(gndW*0.10); ambG: (skyW*0.10)+(gndW*0.07); ambB: (skyW*0.18)+(gndW*0.03)
  fillR: N2L*ar*0.35%3.14159; fillG: N2L*ag*0.35%3.14159; fillB: N2L*ab*0.35%3.14159
  lr: clamp[(ar*ambR)+fillR+((spec+d1r)*sun); 0.; 1.]
  lg: clamp[(ag*ambG)+fillG+((spec+d1g)*sun); 0.; 1.]
  lb: clamp[(ab*ambB)+fillB+((spec+d1b)*sun); 0.; 1.]
  (lr; lg; lb; 1.0)
}]

/ ── Vertex shader (isometric-ish projection, from pbr.k) ──────────────────────
pbrVtx: VertexShader[[pos:`v3;nor:`v3;mat:`v4;lit:`f32]; [wNor:`v3;wMat:`v4;wLit:`f32]; {[pos;nor;mat;lit]
  c45:0.7071; s45:0.7071; c30:0.8165; s30:0.5774; sc:0.3
  py0:(c45*pos[0])+(s45*pos[2])
  py2:(c45*pos[2])-(s45*pos[0])
  px1:(c30*pos[1])-(s30*py2)
  px2:(s30*pos[1])+(c30*py2)
  ((sc*py0; sc*px1; 0.5-px2*0.001; 1.0); nor; mat; lit)
}]

/ ── Material (r g b roughness) ────────────────────────────────────────────────
steel:: 0.62 0.64 0.68 0.35

/ ── Load the FBX mesh once and bake it into model space ───────────────────────
fbxMesh: {[path]
  t: ReadFbx path
  obj: *t@&({$[(x`name)~`Objects;1;0]}'t)
  geo: fbx.get[obj;`Geometry]
  `0 0:"loaded ",(fbx.uname (geo`props)@1)
  m: fbx.trimesh geo
  soup: (m@0)@,/m@1                 / triangle-soup positions (3 per triangle)
  col: +soup; xs: col@0; ys: col@1; zs: col@2
  cx: 0.5*(&/xs)+(|/xs); cy: 0.5*(&/ys)+(|/ys); cz: 0.5*(&/zs)+(|/zs)   / centre
  sca: 2.4%|/(((|/xs)-(&/xs));((|/ys)-(&/ys));((|/zs)-(&/zs)))
  +((sca*xs-cx); (sca*ys-cy); (sca*zs-cz))                              / centred/scaled soup×3
}
swBase:: fbxMesh "data/FBX/Sword.fbx"
swNT::   (#swBase) div 3                                   / triangle count
swMrep:: (#swBase) # ,steel,1.0                            / per-vertex (mat;lit)

/ ── Per-frame: rotate + zoom + pan, recompute flat normals, interleave ────────
swFrame: {[ca;sa;xca;xsa;zoom;cx;cz]
  col: +swBase; xs: col@0; ys: col@1; zs: col@2
  x1: (ca*xs)-(sa*zs); z1: (sa*xs)+(ca*zs)                 / rotate Y
  y2: (xca*ys)-(xsa*z1); z2: (xsa*ys)+(xca*z1)             / tilt X
  Pv: +((zoom*x1-cx); (zoom*y2); (zoom*z2-cz))             / zoom + pan  (soup×3)
  i0: 3*!swNT
  pa: +Pv@i0; pb: +Pv@i0+1; pc: +Pv@i0+2
  e1x: (pb@0)-(pa@0); e1y: (pb@1)-(pa@1); e1z: (pb@2)-(pa@2)
  e2x: (pc@0)-(pa@0); e2y: (pc@1)-(pa@1); e2z: (pc@2)-(pa@2)
  nx: (e1y*e2z)-(e1z*e2y); ny: (e1z*e2x)-(e1x*e2z); nz: (e1x*e2y)-(e1y*e2x)
  ln: sqrt 1e-9+(nx*nx)+(ny*ny)+(nz*nz)
  Ntri: +((nx%ln); (ny%ln); (nz%ln))
  Nsoup: Ntri@(!3*swNT) div 3                              / flat per-triangle normal
  ,/Pv,'Nsoup,'swMrep
}

/ ── Global state ──────────────────────────────────────────────────────────────
camX:: 0.; camZ:: 0.; zoom:: 1.
rotCa:: 0.92; rotSa:: 0.39                                 / start at a 3/4 view
xCa:: 0.97; xSa:: 0.26
lastMx:: 0.; lastMy:: 0.
swHandle:: 0

/ ── Window loop ───────────────────────────────────────────────────────────────
RunWindow[{[props]
  $[swHandle=0; swHandle:: CompileMesh[pbrVtx; PbrFragment]; 0]

  kw: props`kw; ka: props`ka; ks: props`ks; kd: props`kd
  scroll: props`scroll; rmb: props`rmb; mx: props`mx; my: props`my

  / Camera pan + zoom
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

  / Sword mesh (all per-vertex work vectorised in swFrame)
  tvs: swFrame[rotCa;rotSa;xCa;xSa;zoom;camX;camZ]
  DrawMesh[tvs; swHandle]
}; 0]
