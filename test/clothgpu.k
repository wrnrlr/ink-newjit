/ test/clothgpu.k — XPBD cloth entirely on the GPU, built on the compute stack:
/ gpu.kernelF (general n-buffer kernel with NATIVE f32-atomic accumulators), set/
/ iget/iset (buffer stores) and scatterAdd (atomic scatter). Positions/velocities
/ live in resident buffers across the whole sim; constraint corrections scatter-add
/ straight into an f32 accumulator via OpAtomicFAddEXT (kk2 §7) — no fixed-point
/ scaling, no velocity-jitter floor. Each frame the solver advances 15 substeps on
/ the GPU; positions are read back to build the render mesh, drawn with lib/pbr.k.
/ Run:  ink test/clothgpu.k  (INK_CLOTH_CHECK=1 … prints solver invariants headless.)
/ Requires a device with caps.atomicFadd (all Metal/MoltenVK targets have it); the
/ i32 fixed-point fallback (gpu.kernel + an SC scale) lives in this file's git history.
/
/ Layout: positions P, velocities V, prev PREV are interleaved 3*nP (P[3*p+axis]).
/ IM is per-particle inverse mass (0 = pinned). DP is an f32 correction accumulator
/ (3*nP). Each edge buffer packs 7 floats/edge: i j restlen alpha w0 w1 wt.

2: "lib/dye.k"
2: "lib/gpu.k"
2: "lib/pbr.k"                            / PbrFragment (Cook-Torrance) renderer

clothMat::0.18 0.28 0.62 0.75 1.         / blue cloth: rgb + roughness + sun-lit
vlen3:{sqrt[(sqr x)+(sqr y)+(sqr z)]}
cross3:{((x@1 2 0)*y@2 0 1)-(x@2 0 1)*y@1 2 0}
vnorm:{x%vlen3[x@0;x@1;x@2]|0.0001}

W::20; H::20; nP::W*H; nDof::3*nP        / 20x20 grid (matches test/cloth.k resolution)
SDT::(1.%60.)%15.                        / substep dt (60fps, 15 substeps)
/ Velocity damping per substep (1 = none). XPBD's v=(x-prev)/dt conserves energy, so
/ without this the cloth swings forever and the fixed-point noise keeps re-exciting it.
/ Lower = settles faster / stiffer; 0.995 settles in ~3s, ~0.999 stays loose longer.
DAMP::0.995

/ ── kernels ──────────────────────────────────────────────────────────────────
/ integrate: gravity on free particles (y axis), snapshot prev, advance p, floor.
kInt::gpu.kernel[{[p;v;prev;im;g;d]
  sdt:g[0]; ax:d mod 3; part:d div 3
  isY:$[ax=1;1.;0.]; free:$[(im[part])>0.;1.;0.]
  nv:(v[d])+isY*free*(-9.81*sdt)
  set[v; d; nv]
  set[prev; d; p[d]]
  np:(p[d])+sdt*nv
  set[p; d; $[ax=1; $[np<(-2.); -2.; np]; np]]}; 0; 5]

/ constraint scatter: one thread per edge; XPBD correction scattered (± w0/w1) into
/ DP for both endpoints, all three axes. guard value 0 for over-dispatched threads.
/ Native f32 atomics (gpu.kernelF): corrections accumulate directly — no SC scale.
kCon::gpu.kernelF[{[dp;p;e;g;ee]
  ne:`i$g[0]; sdt:g[1]; ok:$[ee<ne;1.;0.]
  / clamp OOB threads onto edge 0 so every read is valid: with native f32 atomics a
  / garbage edge makes ds/lam inf and the ok=0 guard would form 0*inf = NaN (the i32
  / path hid this via f2s(NaN)→0). Reading a real edge keeps the math finite; ok=0
  / then zeroes the correction cleanly.
  eeC:$[ee<ne;ee;0]
  base:7*eeC
  pi:e[base]; pj:e[base+1]; l0:e[base+2]; al:e[base+3]; w0:e[base+4]; w1:e[base+5]; wt:e[base+6]
  bi:3.*pi; bj:3.*pj
  dx:(p[bj])-p[bi]; dy:(p[bj+1.])-p[bi+1.]; dz:(p[bj+2.])-p[bi+2.]
  ds:sqrt[(dx*dx)+(dy*dy)+dz*dz]
  safe:$[ds>0.0001;1.;0.]; dsc:$[ds>0.0001;ds;0.0001]
  cc:ds-l0
  lam:0.5*((cc*safe)%(wt+al%(sdt*sdt)))
  cx:ok*(dx%dsc)*lam; cy:ok*(dy%dsc)*lam; cz:ok*(dz%dsc)*lam
  a0:scatterAdd[dp;bi;cx*w0];      a1:scatterAdd[dp;bi+1.;cy*w0]; a2:scatterAdd[dp;bi+2.;cz*w0]
  b0:scatterAdd[dp;bj;(0.-cx)*w1]; b1:scatterAdd[dp;bj+1.;(0.-cy)*w1]; scatterAdd[dp;bj+2.;(0.-cz)*w1]}; 1; 3]

/ apply: fold the f32 accumulator into positions, then clear it (no /SC rescale).
kApp::gpu.kernelF[{[dp;p;g;d] set[p; d; (p[d])+iget[dp;d]]; iset[dp;d;0.]}; 1; 2]

/ velocity recovery with damping: v = damp*free*(p-prev)/dt.  g[1] = damping factor.
kVel::gpu.kernel[{[v;p;prev;im;g;d]
  sdt:g[0]; damp:g[1]; part:d div 3; free:$[(im[part])>0.;1.;0.]
  set[v; d; damp*free*((p[d])-prev[d])%sdt]}; 0; 5]

/ ── grid + edges (host side) ─────────────────────────────────────────────────
ii::!nP; col::ii mod W; row::ii div W
px0::(col%W-1)-0.5; py0::nP#1.; pz0::(row%H-1)-0.5   / flat sheet at y=1
im0::nP#1.; im0[0,W-1]:0.                             / pin the two top corners

dist::{[a;b] sqrt[+/(a-b)*a-b]}                       / distance between two 3-vectors (from packed arrays)
pos::{[k] (px0@k;py0@k;pz0@k)}
/ build a 7-float/edge buffer from parallel (i;j;alpha) lists
mkEdges::{[is;js;al]
  l0:{[a;b] dist[pos a; pos b]}'[is;js]
  w0:im0@is; w1:im0@js
  ,/+((0.+is);(0.+js);l0;al;w0;w1;w0+w1)}

/ horizontal, vertical, shear-diagonal, bend edges (cf. cloth.k)
hI::&col<W-1; hi::hI; hj::hI+1
vI::&row<H-1; vi::vI; vj::vI+W
dI::&(col<W-1)&row<H-1; di::dI; dj::dI+W+1
bI::&(col<W-1)&row<H-1; bi2::bI+1; bj2::bI+W
EH::mkEdges[hi;hj;(#hi)#0.]
EV::mkEdges[vi;vj;(#vi)#0.]
ED::mkEdges[di;dj;(#di)#0.]
EB::mkEdges[bi2;bj2;(#bi2)#1.]              / bend gets compliance alpha=1

/ ── render mesh: two triangles per grid cell (CCW → upward normals) ───────────
rc::!(H-1;W-1)
c00::(W*rc@0)+rc@1
triIds::,/+(c00;c00+W+1;c00+1;c00;c00+W;c00+W+1)   / (i00,i11,i01) (i00,i10,i11)
nTris::2*(H-1)*(W-1)
tris::(nTris;3)#triIds

/ VERTEX PULLING (kk2 §5): the vertex shader reads the RESIDENT position buffer P
/ and the triangle-index buffer straight off the device — no readback, no CPU mesh
/ build, no per-frame re-upload. Thread = vertex (3 per triangle); it looks up its
/ triangle's 3 particle indices, gathers their positions from P, computes the face
/ normal (cross of the two edges), and outputs this corner's projected clip position
/ + the standard PBR varyings. Material/lighting are constants (clothMat), baked in.
/ (Rasterizer cull is NONE, so the sheet shows from both sides with one draw.)
clothVtxPull:: shader.vertexPull[[wNor:`v3; wMat:`v4; wLit:`f32]; {[p; tri; vid]
  t:floor[vid%3.]                     / triangle id (3 verts per triangle)
  cor:vid-3.*t                        / corner 0/1/2
  b:3.*t
  i0:tri[b]; i1:tri[b+1.]; i2:tri[b+2.]
  a0:3.*i0; a1:3.*i1; a2:3.*i2
  x0:p[a0]; y0:p[a0+1.]; z0:p[a0+2.]
  x1:p[a1]; y1:p[a1+1.]; z1:p[a1+2.]
  x2:p[a2]; y2:p[a2+1.]; z2:p[a2+2.]
  ex1:x1-x0; ey1:y1-y0; ez1:z1-z0
  ex2:x2-x0; ey2:y2-y0; ez2:z2-z0
  cx:(ey1*ez2)-(ez1*ey2); cy:(ez1*ex2)-(ex1*ez2); cz:(ex1*ey2)-(ey1*ex2)
  lr:sqrt[(cx*cx)+(cy*cy)+(cz*cz)]; ln:$[lr<0.0001;0.0001;lr]   / |·| is OpLogicalOr in kernels — guard with select
  nx:cx%ln; ny:cy%ln; nz:cz%ln
  px:$[cor<0.5;x0; cor<1.5;x1; x2]
  py:$[cor<0.5;y0; cor<1.5;y1; y2]
  pz:$[cor<0.5;z0; cor<1.5;z1; z2]
  / cloth's isometric projection (matches the old clothVtx / test/cloth.k)
  c45:0.7071; s45:0.7071; c30:0.8165; s30:0.5774; sc:0.6
  qy0:(c45*px)+(s45*pz)
  qy2:(c45*pz)-(s45*px)
  ncy:py-1.0
  qx1:(c30*ncy)-(s30*qy2)
  qx2:(s30*ncy)+(c30*qy2)
  ((sc*qy0; sc*qx1; 0.5-(qx2*sc*0.5); 1.0); (nx;ny;nz); (0.18;0.28;0.62;0.75); 1.)}]

/ ── GPU sim state (created once on the first frame) ───────────────────────────
gReady::0; gPull::0
pInt::0; pCon::0; pApp::0; pVel::0
P::0; V::0; PREV::0; IM::0; DP::0; G::0; Ptri::0
cons::(); onePass::0; substep::0

initGpu::{[]
  $[(gpu.caps[0])`atomicFadd; 0; `0 0: "clothgpu: device lacks atomicFadd (need VK_EXT_shader_atomic_float)\n"]
  pInt::gpu.compileCompute[kInt;5]; pCon::gpu.compileCompute[kCon;4]
  pApp::gpu.compileCompute[kApp;3]; pVel::gpu.compileCompute[kVel;5]
  P::gpu.buffer[,/+(px0;py0;pz0)]; V::gpu.buffer[nDof#0.]; PREV::gpu.buffer[nDof#0.]
  IM::gpu.buffer[im0]; DP::gpu.buffer[nDof#0.]
  Ptri::gpu.buffer[`f$ ,/tris]                            / resident triangle indices (vertex-pull source)
  bH:gpu.buffer[EH]; bV:gpu.buffer[EV]; bD:gpu.buffer[ED]; bB:gpu.buffer[EB]
  G::gpu.buffer[SDT,DAMP,0.,0.]                            / g[0]=sdt, g[1]=damping
  GH:gpu.buffer[(0.+(#hi)),SDT,0.,0.]; GV:gpu.buffer[(0.+(#vi)),SDT,0.,0.]
  GD:gpu.buffer[(0.+(#di)),SDT,0.,0.]; GB:gpu.buffer[(0.+(#bi2)),SDT,0.,0.]
  cons::((bH;GH);(bV;GV);(bD;GD);(bB;GB))
  gReady::1}

/ one constraint type: scatter corrections into DP, then fold DP into positions.
onePass::{[cg] gpu.dispatch[pCon; (DP;P;cg 0;cg 1); nP]; gpu.dispatch[pApp; (DP;P;G); nDof]}
substep::{[s]
  gpu.dispatch[pInt; (P;V;PREV;IM;G); nDof]
  onePass'cons
  gpu.dispatch[pVel; (V;P;PREV;IM;G); nDof]
  s+1}

loop::{[props]
  $[gReady=0; initGpu[]; 0]
  $[gPull=0; gPull::mesh.compilePull[clothVtxPull; PbrFragment]; 0]
  15 substep/0                          / 15 substeps this frame (gpuRun syncs before the draw)
  mesh.drawPull[gPull; (P; Ptri); 3*nTris]}   / pull straight from resident P — no readback

/ Headless invariant check (no window): drive the solver on a headless device and
/ assert the drape is physical — pinned corners stay at y=1, the sheet hangs to a
/ sane height, and (critically for the native-f32-atomic path) NO cell went NaN.
/ Gated on INK_CLOTH_CHECK (the oracle harness sets it) so INK_SNAP still snapshots.
clothHeadless::{[]
  gpu.computeRun[{[x]
    initGpu[]
    (15*40) substep/0
    R:gpu.read[P]; yv:R@1+3*ii
    minY:&/yv; maxY:|/yv; finite:&/yv=yv     / NaN≠NaN → finite=0 if any NaN
    ok:finite & (maxY~1.) & (minY>0.02) & minY<0.06
    `0 0: "clothgpu: minY=",($minY),"  maxY=",($maxY),"  ",$[ok;"PASS";"FAIL"],"\n"}]}
/ (`env`-key membership: `in` on symbols errors, and a missing key indexes to an
/ error value, so test presence by counting matches in the key vector.)
$[0 < +/ (!`env[]) = `s$"INK_CLOTH_CHECK"; clothHeadless[]; window.run[loop; 0]]
