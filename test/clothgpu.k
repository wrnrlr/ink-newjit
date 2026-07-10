/ test/clothgpu.k — XPBD cloth entirely on the GPU, built on the compute stack:
/ GpKernel (general n-buffer kernel), set/iget/iset (buffer stores) and scatterAdd
/ (atomic scatter). Positions/velocities live in resident buffers across the whole
/ sim; constraint corrections scatter-add (fixed point) into an i32 accumulator.
/ Each frame the solver advances 15 substeps on the GPU; positions are read back to
/ build the render mesh, drawn with lib/pbr.k. Run:  ink test/clothgpu.k
/ (INK_SNAP=0 ink test/clothgpu.k prints solver invariants headless — see EOF.)
/
/ Layout: positions P, velocities V, prev PREV are interleaved 3*nP (P[3*p+axis]).
/ IM is per-particle inverse mass (0 = pinned). DP is an i32 fixed-point accumulator
/ (3*nP). Each edge buffer packs 7 floats/edge: i j restlen alpha w0 w1 wt.

2: "lib/spirv.k"
2: "lib/gpu.k"
2: "lib/pbr.k"                            / PbrFragment (Cook-Torrance) renderer

clothMat::0.18 0.28 0.62 0.75 1.         / blue cloth: rgb + roughness + sun-lit
vlen3:{sqrt[(sqr x)+(sqr y)+(sqr z)]}
cross3:{((x@1 2 0)*y@2 0 1)-(x@2 0 1)*y@1 2 0}
vnorm:{x%vlen3[x@0;x@1;x@2]|0.0001}

W::10; H::10; nP::W*H; nDof::3*nP
SDT::(1.%60.)%15.                        / substep dt (60fps, 15 substeps)
SC::65536.                               / fixed-point scale

/ ── kernels ──────────────────────────────────────────────────────────────────
/ integrate: gravity on free particles (y axis), snapshot prev, advance p, floor.
kInt::GpKernel[{[p;v;prev;im;g;d]
  sdt:g[0]; ax:mod[d;3.]; part:floor[d%3.]
  isY:$[ax=1.;1.;0.]; free:$[(im[part])>0.;1.;0.]
  nv:(v[d])+isY*free*(-9.81*sdt)
  set[v; d; nv]
  set[prev; d; p[d]]
  np:(p[d])+sdt*nv
  set[p; d; $[ax=1.; $[np<(-2.); -2.; np]; np]]}; 0; 5]

/ constraint scatter: one thread per edge; XPBD correction scattered (± w0/w1) into
/ DP for both endpoints, all three axes. guard value 0 for over-dispatched threads.
kCon::GpKernel[{[dp;p;e;g;ee]
  sc:65536.
  ne:g[0]; sdt:g[1]; ok:$[ee<ne;1.;0.]
  base:7.*ee
  pi:e[base]; pj:e[base+1.]; l0:e[base+2.]; al:e[base+3.]; w0:e[base+4.]; w1:e[base+5.]; wt:e[base+6.]
  bi:3.*pi; bj:3.*pj
  dx:(p[bj])-p[bi]; dy:(p[bj+1.])-p[bi+1.]; dz:(p[bj+2.])-p[bi+2.]
  ds:sqrt[(dx*dx)+(dy*dy)+dz*dz]
  safe:$[ds>0.0001;1.;0.]; dsc:$[ds>0.0001;ds;0.0001]
  cc:ds-l0
  lam:0.5*((cc*safe)%(wt+al%(sdt*sdt)))
  cx:ok*sc*(dx%dsc)*lam; cy:ok*sc*(dy%dsc)*lam; cz:ok*sc*(dz%dsc)*lam
  a0:scatterAdd[dp;bi;cx*w0];      a1:scatterAdd[dp;bi+1.;cy*w0]; a2:scatterAdd[dp;bi+2.;cz*w0]
  b0:scatterAdd[dp;bj;(0.-cx)*w1]; b1:scatterAdd[dp;bj+1.;(0.-cy)*w1]; scatterAdd[dp;bj+2.;(0.-cz)*w1]}; 1; 3]

/ apply: fold the fixed-point accumulator into positions, then clear it.
kApp::GpKernel[{[dp;p;g;d] set[p; d; (p[d])+(iget[dp;d])%65536.]; iset[dp;d;0.]}; 1; 2]

/ velocity recovery: v = free*(p-prev)/dt.
kVel::GpKernel[{[v;p;prev;im;g;d]
  sdt:g[0]; part:floor[d%3.]; free:$[(im[part])>0.;1.;0.]
  set[v; d; free*((p[d])-prev[d])%sdt]}; 0; 5]

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

/ Cloth's own projection (matches test/cloth.k) → standard PBR varyings.
clothVtx:: VertexShader[[pos:`v3;nor:`v3;mat:`v4;lit:`f32]; [wNor:`v3;wMat:`v4;wLit:`f32]; {[pos;nor;mat;lit]
  c45:0.7071; s45:0.7071; c30:0.8165; s30:0.5774; sc:0.6
  py0:(c45*pos[0])+(s45*pos[2])
  py2:(c45*pos[2])-(s45*pos[0])
  cy:pos[1]-1.0
  px1:(c30*cy)-(s30*py2)
  px2:(s30*cy)+(c30*py2)
  ((sc*py0;sc*px1;0.5-(px2*sc*0.5);1.0);nor;mat;lit)}]

/ Build the double-sided per-face-normal vertex buffer from a flat position readback.
/ The accessor Pv and the readback gR are GLOBAL so the per-triangle lambda can see
/ them — ink lambdas don't close over a parent's locals (that silently mis-meshes).
gR::0
Pv::{[k] (gR@3*k;gR@(3*k)+1;gR@(3*k)+2)}
buildMesh::{[R] gR::R;
  ,/ {[t] p0:Pv t@0; p1:Pv t@1; p2:Pv t@2
    nor:vnorm cross3[p1-p0;p2-p0]; nf:0.-nor; m:clothMat
    ((p0,nor,m),(p1,nor,m),(p2,nor,m)),(p0,nf,m),(p2,nf,m),(p1,nf,m)}'tris}

/ ── GPU sim state (created once on the first frame) ───────────────────────────
gReady::0; gMesh::0
pInt::0; pCon::0; pApp::0; pVel::0
P::0; V::0; PREV::0; IM::0; DP::0; G::0
cons::(); onePass::0; substep::0

initGpu::{[]
  pInt::CompileCompute[kInt;5]; pCon::CompileCompute[kCon;4]
  pApp::CompileCompute[kApp;3]; pVel::CompileCompute[kVel;5]
  P::NewBuffer[,/+(px0;py0;pz0)]; V::NewBuffer[nDof#0.]; PREV::NewBuffer[nDof#0.]
  IM::NewBuffer[im0]; DP::NewBuffer[nDof#0.]
  bH:NewBuffer[EH]; bV:NewBuffer[EV]; bD:NewBuffer[ED]; bB:NewBuffer[EB]
  G::NewBuffer[SDT,0.,0.,0.]
  GH:NewBuffer[(0.+(#hi)),SDT,0.,0.]; GV:NewBuffer[(0.+(#vi)),SDT,0.,0.]
  GD:NewBuffer[(0.+(#di)),SDT,0.,0.]; GB:NewBuffer[(0.+(#bi2)),SDT,0.,0.]
  cons::((bH;GH);(bV;GV);(bD;GD);(bB;GB))
  gReady::1}

/ one constraint type: scatter corrections into DP, then fold DP into positions.
onePass::{[cg] Dispatch[pCon; (DP;P;cg 0;cg 1); nP]; Dispatch[pApp; (DP;P;G); nDof]}
substep::{[s]
  Dispatch[pInt; (P;V;PREV;IM;G); nDof]
  onePass'cons
  Dispatch[pVel; (V;P;PREV;IM;G); nDof]
  s+1}

loop::{[props]
  $[gReady=0; initGpu[]; 0]
  $[gMesh=0; gMesh::CompileMesh[clothVtx; PbrFragment]; 0]
  15 substep/0                          / 15 substeps this frame
  DrawMesh[buildMesh[ReadBuffer[P]]; gMesh]}
window.run[loop; 0]

/
Headless invariant check (no window) — run with INK_SNAP=0:
  initGpu[]; (15*40) substep/0
  R:ReadBuffer[P]; yv:R@1+3*ii
  minY:&/yv                              / drape height (pinned corners stay at 1)
\
