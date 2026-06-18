/ test/pbr.k — PBR scene: procedural sky + grass ground + brown box + shadow
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

/ ── Fragment shaders ─────────────────────────────────────────────────────────

groundFrag: FragmentShader[[wPos:`v3;wNor:`v3; out:`v4]; {[wPos;wNor]
  ar: 0.13; ag: 0.42; ab: 0.07; rough: 0.90
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
  sun: N1L*2.0
  L2: normalize[(-0.3; 0.8; -0.6)]; N2L: max[0.0; dot[wNor; L2]]
  skyW: max[0.0; wNor[1]]; gndW: max[0.0; -1.0*wNor[1]]
  ambR: (skyW*0.06)+(gndW*0.10); ambG: (skyW*0.10)+(gndW*0.07); ambB: (skyW*0.18)+(gndW*0.03)
  fillR: N2L*ar*0.35%3.14159; fillG: N2L*ag*0.35%3.14159; fillB: N2L*ab*0.35%3.14159
  lr: clamp[(ar*ambR)+fillR+((spec+d1r)*sun); 0.; 1.]
  lg: clamp[(ag*ambG)+fillG+((spec+d1g)*sun); 0.; 1.]
  lb: clamp[(ab*ambB)+fillB+((spec+d1b)*sun); 0.; 1.]
  (lr; lg; lb; 1.0)
}]

boxFrag: FragmentShader[[wPos:`v3;wNor:`v3; out:`v4]; {[wPos;wNor]
  ar: 0.50; ag: 0.28; ab: 0.08; rough: 0.65
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
  sun: N1L*2.0
  L2: normalize[(-0.3; 0.8; -0.6)]; N2L: max[0.0; dot[wNor; L2]]
  skyW: max[0.0; wNor[1]]; gndW: max[0.0; -1.0*wNor[1]]
  ambR: (skyW*0.06)+(gndW*0.10); ambG: (skyW*0.10)+(gndW*0.07); ambB: (skyW*0.18)+(gndW*0.03)
  fillR: N2L*ar*0.35%3.14159; fillG: N2L*ag*0.35%3.14159; fillB: N2L*ab*0.35%3.14159
  lr: clamp[(ar*ambR)+fillR+((spec+d1r)*sun); 0.; 1.]
  lg: clamp[(ag*ambG)+fillG+((spec+d1g)*sun); 0.; 1.]
  lb: clamp[(ab*ambB)+fillB+((spec+d1b)*sun); 0.; 1.]
  (lr; lg; lb; 1.0)
}]

shadowFrag: FragmentShader[[wPos:`v3;wNor:`v3; out:`v4]; {[wPos;wNor]
  ar: 0.13; ag: 0.42; ab: 0.07
  L2: normalize[(-0.3; 0.8; -0.6)]; N2L: max[0.0; dot[wNor; L2]]
  skyW: max[0.0; wNor[1]]; gndW: max[0.0; -1.0*wNor[1]]
  ambR: (skyW*0.06)+(gndW*0.10); ambG: (skyW*0.10)+(gndW*0.07); ambB: (skyW*0.18)+(gndW*0.03)
  fillR: N2L*ar*0.35%3.14159; fillG: N2L*ag*0.35%3.14159; fillB: N2L*ab*0.35%3.14159
  lr: clamp[(ar*ambR)+fillR; 0.; 1.]
  lg: clamp[(ag*ambG)+fillG; 0.; 1.]
  lb: clamp[(ab*ambB)+fillB; 0.; 1.]
  (lr; lg; lb; 1.0)
}]

/ ── Geometry helpers ──────────────────────────────────────────────────────────
mkFace: {[a;b;c;d;n] (a,n),(b,n),(c,n),(a,n),(c,n),(d,n)}
mkTri:  {[a;b;c;n]   (a,n),(b,n),(c,n)}
ry: {[v;ca;sa] ((ca*v[0])-(sa*v[2]); v[1]; (sa*v[0])+(ca*v[2]))}
rx: {[v;ca;sa] (v[0]; (ca*v[1])-(sa*v[2]); (sa*v[1])+(ca*v[2]))}
rp: {[v;yca;ysa;xca;xsa] rx[ry[v;yca;ysa];xca;xsa]}

nup: (0.;1.;0.)

/ Box corners — unit cube sitting on y=0
p000:(-0.5;0.;-0.5); p001:(-0.5;0.;0.5); p010:(-0.5;1.;-0.5); p011:(-0.5;1.;0.5)
p100:(0.5;0.;-0.5);  p101:(0.5;0.;0.5);  p110:(0.5;1.;-0.5);  p111:(0.5;1.;0.5)

/ ── Vertex shader ─────────────────────────────────────────────────────────────
pbrVtx: VertexShader[[pos:`v3;nor:`v3]; [wPos:`v3;wNor:`v3]; {[pos;nor]
  c45:0.7071; s45:0.7071; c30:0.8165; s30:0.5774; sc:0.3
  py0:(c45*pos[0])+(s45*pos[2])
  py2:(c45*pos[2])-(s45*pos[0])
  px1:(c30*pos[1])-(s30*py2)
  px2:(s30*pos[1])+(c30*py2)
  ((sc*py0; sc*px1; 0.5-px2*0.001; 1.0); pos; nor)
}]

/ ── Global state ──────────────────────────────────────────────────────────────
camX:: 0.; camZ:: 0.; zoom:: 1.
rotCa:: 1.; rotSa:: 0.
xCa:: 1.; xSa:: 0.
lastMx:: 0.; lastMy:: 0.

groundHandle:: 0; boxHandle:: 0; shadowHandle:: 0; skyHandle:: 0

/ ── Window loop ───────────────────────────────────────────────────────────────
RunWindow[{[props]
  $[groundHandle=0; groundHandle:: CompileMesh[pbrVtx; groundFrag]; 0]
  $[boxHandle=0;    boxHandle::    CompileMesh[pbrVtx; boxFrag];    0]
  $[shadowHandle=0; shadowHandle:: CompileMesh[pbrVtx; shadowFrag]; 0]
  $[skyHandle=0;    skyHandle::    CompileSpirV[skyWds; 0];         0]

  / Camera pan
  spd: 0.05%zoom
  da: props[`kd]-props[`ka]; ws: props[`kw]-props[`ks]
  camX:: camX+(spd*(da+ws)); camZ:: camZ+(spd*(da-ws))
  zoom:: 5.0&(0.3|zoom*(1.0+(props[`scroll]*0.1)))

  / Scene rotation: right-drag X → Y-axis, right-drag Y → X-axis
  dx: $[props[`rmb]>0.; props[`mx]-lastMx; 0.]
  dy: $[props[`rmb]>0.; props[`my]-lastMy; 0.]
  dSa: dx*0.003; dCa: 1.0-(dSa*dSa*0.5)
  nCa: (rotCa*dCa)-(rotSa*dSa); nSa: (rotSa*dCa)+(rotCa*dSa)
  $[props[`rmb]>0.; rotCa:: nCa; 0]
  $[props[`rmb]>0.; rotSa:: nSa; 0]
  dxSa: dy*0.003; dxCa: 1.0-(dxSa*dxSa*0.5)
  nxCa: (xCa*dxCa)-(xSa*dxSa); nxSa: (xSa*dxCa)+(xCa*dxSa)
  $[props[`rmb]>0.; xCa:: nxCa; 0]
  $[props[`rmb]>0.; xSa:: nxSa; 0]
  lastMx:: props[`mx]; lastMy:: props[`my]

  ca: rotCa; sa: rotSa; xca: xCa; xsa: xSa

  / Ground plane ±8
  gndVerts: mkFace[rp[(-8.;0.;-8.);ca;sa;xca;xsa]; rp[(8.;0.;-8.);ca;sa;xca;xsa];
                   rp[(8.;0.;8.);ca;sa;xca;xsa]; rp[(-8.;0.;8.);ca;sa;xca;xsa];
                   rp[nup;ca;sa;xca;xsa]]

  / Box — pre-rotate all 8 corners + 5 normals, then build faces with mkFace (5 args)
  rp000: rp[p000;ca;sa;xca;xsa]; rp001: rp[p001;ca;sa;xca;xsa]
  rp010: rp[p010;ca;sa;xca;xsa]; rp011: rp[p011;ca;sa;xca;xsa]
  rp100: rp[p100;ca;sa;xca;xsa]; rp101: rp[p101;ca;sa;xca;xsa]
  rp110: rp[p110;ca;sa;xca;xsa]; rp111: rp[p111;ca;sa;xca;xsa]
  nTop: rp[nup;ca;sa;xca;xsa]
  nFrt: rp[(0.;0.;1.);ca;sa;xca;xsa]
  nBck: rp[(0.;0.;-1.);ca;sa;xca;xsa]
  nRgt: rp[(1.;0.;0.);ca;sa;xca;xsa]
  nLft: rp[(-1.;0.;0.);ca;sa;xca;xsa]
  boxVerts: (mkFace[rp010;rp110;rp111;rp011;nTop]),(mkFace[rp001;rp101;rp111;rp011;nFrt]),(mkFace[rp100;rp000;rp010;rp110;nBck]),(mkFace[rp101;rp100;rp110;rp111;nRgt]),(mkFace[rp000;rp001;rp011;rp010;nLft])

  / Shadow hex at y=0.001 — box footprint projected along L=normalize(0.5,1.5,0.3)
  sn: rp[nup;ca;sa;xca;xsa]
  sc0: rp[(-0.167;0.001;-0.100);ca;sa;xca;xsa]
  sv0: rp[(-0.834;0.001;-0.700);ca;sa;xca;xsa]
  sv1: rp[(0.167;0.001;-0.700);ca;sa;xca;xsa]
  sv2: rp[(0.5;0.001;-0.5);ca;sa;xca;xsa]
  sv3: rp[(0.5;0.001;0.5);ca;sa;xca;xsa]
  sv4: rp[(-0.5;0.001;0.5);ca;sa;xca;xsa]
  sv5: rp[(-0.834;0.001;0.3);ca;sa;xca;xsa]
  shadVerts: (mkTri[sc0;sv0;sv1;sn]),(mkTri[sc0;sv1;sv2;sn]),(mkTri[sc0;sv2;sv3;sn]),(mkTri[sc0;sv3;sv4;sn]),(mkTri[sc0;sv4;sv5;sn]),(mkTri[sc0;sv5;sv0;sn])

  / Apply camera pan + zoom CPU-side
  ng: #gndVerts; nb: #boxVerts; ns: #shadVerts
  tvg: (ng#(zoom;zoom;zoom;1.;1.;1.))*(gndVerts-(ng#(camX;0.;camZ;0.;0.;0.)))
  tvb: (nb#(zoom;zoom;zoom;1.;1.;1.))*(boxVerts-(nb#(camX;0.;camZ;0.;0.;0.)))
  tvs: (ns#(zoom;zoom;zoom;1.;1.;1.))*(shadVerts-(ns#(camX;0.;camZ;0.;0.;0.)))

  / Draw: sky → ground → shadow (on ground, blocked by box) → box
  w: props[`width]; h: props[`height]
  skyV: 0.,0.,0.,0., w,0.,1.,0., w,h,1.,1., 0.,0.,0.,0., w,h,1.,1., 0.,h,0.,1.
  DrawShader[skyV; skyHandle]
  DrawMesh[tvg; groundHandle]
  DrawMesh[tvs; shadowHandle]
  DrawMesh[tvb; boxHandle]
}; 0]
