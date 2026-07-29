/
# pbr

A physically based (Cook-Torrance) shader pair for lit 3D meshes.

One vertex shader and one fragment shader render any mesh whose vertices carry
their own material, so ground, box, cloth and loaded models are all the same
pipeline fed different per-vertex data — rather than near-identical shaders.

Vertices are a flat stride-11 float vector: world position (3), normal (3),
material as rgb + roughness (4), and a sun factor (1) where 1 is full sun and 0
is shadowed (ambient and sky-fill only).  `PbrMat` builds the five-float
material+lit tail:

```k
grass:  PbrMat[0.13; 0.42; 0.07; 0.90; 1.]   / lit grass
shadow: PbrMat[0.13; 0.42; 0.07; 0.90; 0.]   / same colour, sun blocked

h:  mesh.compilePull[pbrVtx; PbrFragment]    / compile once
vb: gpu.buffer verts                         / then, per frame
mesh.drawPull[h; ,vb; (#verts) div 11]
```

Needs lib/spirv.k (`shader.fragment` / `shader.vertexPull`) and lib/gpu.k
(`mesh.compilePull`).

Pure k — loads on the first reference to any `pbr.*` name.
\

/ ── PBR fragment shader (Cook-Torrance) ──────────────────────────────────────
/ Material arrives per-vertex as wMat = (r; g; b; roughness) and wLit = sun
/ factor.  Key light L1 is the sun; L2 is a soft sky fill; ambient is a simple
/ sky/ground hemisphere term so shadowed faces still read.
PbrFragment: shader.fragment[[wNor:`v3; wMat:`v4; wLit:`f32; out:`v4]; {[wNor;wMat;wLit]
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
  / Linear HDR radiance, then tone-map + encode for display ────────────────────
  rawR: (ar*ambR)+fillR+((spec+d1r)*sun)
  rawG: (ag*ambG)+fillG+((spec+d1g)*sun)
  rawB: (ab*ambB)+fillB+((spec+d1b)*sun)
  / Reinhard tone-map tames blown speculars; then encode linear→sRGB by hand
  / because the swapchain is bgra8_unorm (no hardware gamma). 0.4545 = 1/2.2.
  lr: pow[clamp[rawR%(1.0+rawR);0.;1.];0.4545]
  lg: pow[clamp[rawG%(1.0+rawG);0.;1.];0.4545]
  lb: pow[clamp[rawB%(1.0+rawB);0.;1.];0.4545]
  (lr; lg; lb; 1.0)
}]

/ ── Vertex shader (isometric-ish projection, VERTEX PULLING) ──────────────────
/ Projects pos to clip space and passes normal + material + sun through. Geometry
/ lives in a resident storage buffer (stride 11) PULLED by gl_VertexIndex — no
/ vertex-input state. The near-flat depth term relies on painter-order draws /
/ mostly-convex meshes; self-occluding geometry (e.g. cloth) uses a stronger term.
pbrVtx: shader.vertexPull[[wNor:`v3;wMat:`v4;wLit:`f32]; {[vb;vid]
  b:11.*vid
  px:vb[b]; py:vb[b+1.]; pz:vb[b+2.]
  c45:0.7071; s45:0.7071; c30:0.8165; s30:0.5774; sc:0.3
  py0:(c45*px)+(s45*pz)
  py2:(c45*pz)-(s45*px)
  px1:(c30*py)-(s30*py2)
  px2:(s30*py)+(c30*py2)
  ((sc*py0; sc*px1; 0.5-px2*0.001; 1.0); (vb[b+3.];vb[b+4.];vb[b+5.]); (vb[b+6.];vb[b+7.];vb[b+8.];vb[b+9.]); vb[b+10.])
}]

/ Compile the standard pipeline with  mesh.compilePull[pbrVtx; PbrFragment]  and a
/ material+lit vertex tail with  r,g,b,rough,lit  (kept inline, not as helpers, to
/ spend fewer of the VM's 256 global slots — see doc/bug.md). Draw with a resident
/ stride-11 buffer:  vb: gpu.buffer verts;  mesh.drawPull[pipe; ,vb; (#verts) div 11].
