/ test/clothpull.k — readback-free GPU cloth: the SAME resident-buffer XPBD solver
/ as test/clothgpu.k, but rendered WITHOUT reading positions back to the host. A
/ small compute pass packs the solver's positions into a vec4[] resident buffer, and
/ an instanced vertex shader pulls each particle straight out of that buffer via
/ gl_InstanceIndex (DrawResident) — one quad per particle, no host round-trip at all.
/ Run:  ink test/clothpull.k
/
/ This is the pattern for large cloths: physics + render stay fully GPU-resident, so
/ the per-frame readback + CPU mesh-build (test/clothgpu.k) disappears.

2: "lib/dye.k"
2: "lib/gpu.k"
2: "lib/instancing.k"                    / UploadMesh, DrawResident, InstancedVertexShader
2: "lib/pbr.k"                           / PbrFragment

W::30; H::30; nP::W*H; nDof::3*nP
SDT::(1.%60.)%15.

/ ── solver kernels (identical to test/clothgpu.k) ─────────────────────────────
kInt::GpKernel[{[p;v;prev;im;g;d] sdt:g[0];ax:mod[d;3.];part:floor[d%3.];isY:$[ax=1.;1.;0.];free:$[(im[part])>0.;1.;0.];nv:(v[d])+isY*free*(-9.81*sdt);set[v;d;nv];set[prev;d;p[d]];np:(p[d])+sdt*nv;set[p;d;$[ax=1.;$[np<(-2.);-2.;np];np]]};0;5]
kCon::GpKernel[{[dp;p;e;g;ee] sc:1048576.;ne:g[0];sdt:g[1];ok:$[ee<ne;1.;0.];base:7.*ee;pi:e[base];pj:e[base+1.];l0:e[base+2.];al:e[base+3.];w0:e[base+4.];w1:e[base+5.];wt:e[base+6.];bi:3.*pi;bj:3.*pj;dx:(p[bj])-p[bi];dy:(p[bj+1.])-p[bi+1.];dz:(p[bj+2.])-p[bi+2.];ds:sqrt[(dx*dx)+(dy*dy)+dz*dz];safe:$[ds>0.0001;1.;0.];dsc:$[ds>0.0001;ds;0.0001];cc:ds-l0;lam:0.5*((cc*safe)%(wt+al%(sdt*sdt)));cx:ok*sc*(dx%dsc)*lam;cy:ok*sc*(dy%dsc)*lam;cz:ok*sc*(dz%dsc)*lam;a0:scatterAdd[dp;bi;cx*w0];a1:scatterAdd[dp;bi+1.;cy*w0];a2:scatterAdd[dp;bi+2.;cz*w0];b0:scatterAdd[dp;bj;(0.-cx)*w1];b1:scatterAdd[dp;bj+1.;(0.-cy)*w1];scatterAdd[dp;bj+2.;(0.-cz)*w1]};1;3]
kApp::GpKernel[{[dp;p;g;d] set[p;d;(p[d])+(iget[dp;d])%1048576.];iset[dp;d;0.]};1;2]
kVel::GpKernel[{[v;p;prev;im;g;d] sdt:g[0];damp:g[1];part:floor[d%3.];free:$[(im[part])>0.;1.;0.];set[v;d;damp*free*((p[d])-prev[d])%sdt]};0;5]
/ pack: for each particle write TWO vec4 slots — position (slot 0) and a smooth
/ surface normal (slot 1) computed from its grid neighbours (cross of the row/col
/ tangents). g[0]=W g[1]=H. gid = particle index. The normal is what makes the
/ pulled point cloud read as a shaded surface instead of a flat fill.
kPack::GpKernel[{[out;src;g;i]
  w:g[0]; hh:g[1]; col:mod[i;w]; rw:floor[i%w]
  l:$[col<0.5;i;i-1.]; r:$[col>w-1.5;i;i+1.]
  u:$[rw<0.5;i;i-w]; d:$[rw>hh-1.5;i;i+w]
  b:3.*i; px:src[b]; py:src[b+1.]; pz:src[b+2.]
  tux:(src[3.*r])-src[3.*l]; tuy:(src[(3.*r)+1.])-src[(3.*l)+1.]; tuz:(src[(3.*r)+2.])-src[(3.*l)+2.]
  tvx:(src[3.*d])-src[3.*u]; tvy:(src[(3.*d)+1.])-src[(3.*u)+1.]; tvz:(src[(3.*d)+2.])-src[(3.*u)+2.]
  nx:(tuy*tvz)-(tuz*tvy); ny:(tuz*tvx)-(tux*tvz); nz:(tux*tvy)-(tuy*tvx)
  nl:max[sqrt[(nx*nx)+(ny*ny)+(nz*nz)];0.0001]; o:8.*i   / max, not | (| is logical-or in shaders)
  a0:set[out;o;px]; a1:set[out;o+1.;py]; a2:set[out;o+2.;pz]; a3:set[out;o+3.;1.]
  b0:set[out;o+4.;nx%nl]; b1:set[out;o+5.;ny%nl]; b2:set[out;o+6.;nz%nl]; set[out;o+7.;0.]};0;3]

/ ── render: instanced vertex shader pulls the particle position from @group(0) ─
/ Each instance = one particle; uPos is its vec4 (from the resident PK buffer). The
/ quad's per-vertex `pos` is a screen-space corner offset (a little square dot).
ptVtx:: InstancedVertexShader[[pos:`v3]; [wNor:`v3;wMat:`v4;wLit:`f32]; `uPos`uNor; {[pos]
  X:uPos[0]; Y:uPos[1]; Z:uPos[2]
  c45:0.7071; s45:0.7071; c30:0.8165; s30:0.5774; sc:0.6
  py0:(c45*X)+(s45*Z); py2:(c45*Z)-(s45*X)
  cy:Y-1.0; px1:(c30*cy)-(s30*py2); px2:(s30*cy)+(c30*py2)
  ((((sc*py0)+(0.012*pos[0])); ((sc*px1)+(0.012*pos[1])); 0.5-(px2*sc*0.5); 1.0); (uNor[0];uNor[1];uNor[2]); (0.25;0.45;0.9;0.6); 1.)}]

/ a small quad (two triangles) in the xy-plane — the per-particle dot
quad:: ,/((-1.;-1.;0.);(1.;-1.;0.);(1.;1.;0.);(-1.;-1.;0.);(1.;1.;0.);(-1.;1.;0.))

/ ── grid + edges (host, once) ─────────────────────────────────────────────────
ii::!nP; col::ii mod W; row::ii div W
px0::(col%W-1)-0.5; py0::nP#1.; pz0::(row%H-1)-0.5
im0::nP#1.; im0[0,W-1]:0.
dist::{[a;b] sqrt[+/(a-b)*a-b]}; pos::{[k] (px0@k;py0@k;pz0@k)}
mkE::{[is;js;al] l0:{[a;b]dist[pos a;pos b]}'[is;js]; ,/+((0.+is);(0.+js);l0;al;im0@is;im0@js;(im0@is)+im0@js)}
hi::&col<W-1; vi::&row<H-1; di::&(col<W-1)&row<H-1

gReady::0; gGeom::0
initGpu::{[]
  pInt::CompileCompute[kInt;5]; pCon::CompileCompute[kCon;4]; pApp::CompileCompute[kApp;3]; pVel::CompileCompute[kVel;5]; pPack::CompileCompute[kPack;3]
  P::NewBuffer[,/+(px0;py0;pz0)]; V::NewBuffer[nDof#0.]; PREV::NewBuffer[nDof#0.]; IM::NewBuffer[im0]; DP::NewBuffer[nDof#0.]
  PK::NewBuffer[(8*nP)#0.]                                / 2×vec4[] (position + normal) for the vertex pull
  GN::NewBuffer[(0.+W),(0.+H),0.,0.]                      / pack params: grid dims
  bH::NewBuffer[mkE[hi;hi+1;(#hi)#0.]]; bV::NewBuffer[mkE[vi;vi+W;(#vi)#0.]]; bD::NewBuffer[mkE[di;di+W+1;(#di)#0.]]; bB::NewBuffer[mkE[di+1;di+W;(#di)#1.]]
  G::NewBuffer[SDT,0.995,0.,0.]; GH::NewBuffer[(0.+(#hi)),SDT,0.,0.]; GV::NewBuffer[(0.+(#vi)),SDT,0.,0.]; GD::NewBuffer[(0.+(#di)),SDT,0.,0.]; GB::NewBuffer[(0.+(#di)),SDT,0.,0.]
  cons::((bH;GH);(bV;GV);(bD;GD);(bB;GB))
  gGeom::UploadMesh[quad; CompileMesh[ptVtx; PbrFragment]]  / upload the dot quad once
  gReady::1}

onePass::{[cg] Dispatch[pCon;(DP;P;cg 0;cg 1);nP]; Dispatch[pApp;(DP;P;G);nDof]}
substep::{[s] Dispatch[pInt;(P;V;PREV;IM;G);nDof]; onePass'cons; Dispatch[pVel;(V;P;PREV;IM;G);nDof]; s+1}

loop::{[props]
  $[gReady=0; initGpu[]; 0]
  15 substep/0
  Dispatch[pPack; (PK;P;GN); nP]           / pack positions + normals → 2×vec4[]  (on GPU)
  DrawResident[gGeom; nP; PK]              / draw nP dots, pulled from PK — NO readback
}
window.run[loop; 0]
