/ test/kkgold.k — byte-identity oracle for the dye compute-emitter consolidation.
/ Compiles one representative kernel through EVERY compute entry point and dumps
/ the full SPIR-V word list as text. Run before and after a dye.k refactor and
/ diff the outputs:  ink test/kkgold.k > /tmp/kk.txt   (see doc/design/kk.md §5.1)
/ Kernels are lifted from test/walk3.k, test/clothgpu.k and lib/nn.k so the dump
/ covers: element maps, uniform blocks, buffer gathers, in-place stores, atomic
/ scatter, multi-buffer kernels, and the rsum/rmax in-kernel loops.

2: "lib/dye.k"

/ This is a byte-identity oracle: pin the optimizer OFF so the dump lowers every
/ node and stays byte-stable across dye refactors (xOpt is default-on now; the
/ optimized path's correctness is covered by the numeric oracles instead).
xOpt:: 0

ck: {[nm;w] `0 0: nm,": ",(" "/$'w),"\n"}

ck["compute";  shader.compute[{[x] x*2.}]]
ck["computeU"; shader.computeU[{[x;u] (x*u[0])+u[1]}]]
ck["compute2"; shader.compute2[{[x;y] x+y*0.5}]]
ck["stencil";  shader.stencil[{[u;i] $[i<1.;0.;1.+.25*(u[i-1.]+u[i+1.])]}]]
ck["stencilU"; shader.stencilU[{[u;g;i] w:g[0]; b:w-1.5; r:floor[i%w]; c:i-r*w;
  $[(r<0.5)|(r>b)|(c<0.5)|(c>b); 0.; 1.+.25*(u[i-w]+u[i+w]+u[i-1.]+u[i+1.])]}]]
ck["stencilIP"; shader.stencilIP[{[u;g;i] w:g[0]; om:g[1]; par:g[2]; b:w-1.5;
  r:floor[i%w]; c:i-r*w;
  bnd:(r<0.5)|(r>b)|(c<0.5)|(c>b);
  mine:(mod[r+c;2.])=par;
  new:(u[i])+om*((1.+.25*(u[i-w]+u[i+w]+u[i-1.]+u[i+1.]))-u[i]);
  $[bnd; 0.; mine; new; u[i]]}]]
ck["scatter"; shader.scatter[{[acc; a; b; g; i] ok:$[i<g[0];1.;0.];
  x:scatterAdd[acc; a[i]; ok]; scatterAdd[acc; b[i]; ok]}]]
ck["kernel05"; gpu.kernel[{[p;v;prev;im;g;d]
  sdt:g[0]; ax:d mod 3; part:d div 3
  isY:$[ax=1;1.;0.]; free:$[(im[part])>0.;1.;0.]
  nv:(v[d])+isY*free*(-9.81*sdt)
  set[v; d; nv]
  set[prev; d; p[d]]
  np:(p[d])+sdt*nv
  set[p; d; $[ax=1; $[np<(-2.); -2.; np]; np]]}; 0; 5]]
ck["kernel12"; gpu.kernel[{[dp;p;g;d] set[p; d; (p[d])+(iget[dp;d])%1048576.]; iset[dp;d;0.]}; 1; 2]]
ck["kernel13"; gpu.kernel[{[dp;p;e;g;ee]
  sc:1048576.
  ne:`i$g[0]; sdt:g[1]; ok:$[ee<ne;1.;0.]
  base:7*ee
  pi:e[base]; pj:e[base+1]; l0:e[base+2]
  bi:3.*pi; bj:3.*pj
  dx:(p[bj])-p[bi]
  cx:ok*sc*dx*l0
  a0:scatterAdd[dp;bi;cx]; scatterAdd[dp;bj;0.-cx]}; 1; 3]]
ck["kernelRsum"; gpu.kernel[{[c;a;b;g;d]
  n:`i$g[1]; kk:`i$g[2]
  i:d div n; j:d mod n
  set[c; d; rsum[kk; {[k] (a[(i*kk)+k]) * b[(k*n)+j]}]]}; 0; 4]]
ck["kernelRmax"; gpu.kernel[{[mb;sb;x;g;i]
  n:`i$g[0]
  m: rmax[n; {[k] x[(i*n)+k]}]
  s: rsum[n; {[k] exp[(x[(i*n)+k]) - m]}]
  set[mb; i; m]; set[sb; i; s]}; 0; 4]]
/ shader.kernelI: the inferred-binding-table entry in the integer-index dialect
/ (Xidx=1). Pins int literals=i32, `div`/`mod` = integer ops, a gather, and a
/ store — so the integer dialect's kernelInfer path is byte-stable too.
ck["kernelInfer"; shader.kernelI[{[o;x;g;d] n:`i$g[0]; i:d div n; j:d mod n; set[o; d; (x[i])+x[j]]}]]

/ kk2 §2.4-1: the canonical full syntax  +/{[k] e}'!K  (and |/… → rmax) must
/ lower to the SAME words as the intrinsic rsum/rmax spelling above — assert
/ byte-identity of the two spellings for the gemm and softmax kernels.
fr: gpu.kernel[{[c;a;b;g;d]
  n:`i$g[1]; kk:`i$g[2]
  i:d div n; j:d mod n
  set[c; d; +/{[k] (a[(i*kk)+k]) * b[(k*n)+j]}'!kk]}; 0; 4]
gr: gpu.kernel[{[c;a;b;g;d]
  n:`i$g[1]; kk:`i$g[2]
  i:d div n; j:d mod n
  set[c; d; rsum[kk; {[k] (a[(i*kk)+k]) * b[(k*n)+j]}]]}; 0; 4]
fm: gpu.kernel[{[mb;sb;x;g;i]
  n:`i$g[0]
  m: |/{[k] x[(i*n)+k]}'!n
  s: +/{[k] exp[(x[(i*n)+k]) - m]}'!n
  set[mb; i; m]; set[sb; i; s]}; 0; 4]
gm: gpu.kernel[{[mb;sb;x;g;i]
  n:`i$g[0]
  m: rmax[n; {[k] x[(i*n)+k]}]
  s: rsum[n; {[k] exp[(x[(i*n)+k]) - m]}]
  set[mb; i; m]; set[sb; i; s]}; 0; 4]
`0 0: "foldSum: ",($[fr~gr; "identical"; "MISMATCH"]),"\n"
`0 0: "foldMax: ",($[fm~gm; "identical"; "MISMATCH"]),"\n"

/ ── Fragment / vertex gold (kk2 §3: captured BEFORE the IR migration) ─────────
/ Bodies lifted from test/planes.k, test/pbr.k, test/sword.k and test/earth.k so
/ the dump covers: math built-ins, vector literals + OpConstantComposite, splat
/ broadcasting, composite extract, chained $[] with the <=/>= peepholes, bool
/ ops, texture sampling, varyings, uniform blocks, and the no-varying vertex.
ck["fragPlanes"; shader.fragment[[nor:`v3; out:`v4]; {[nor]
  amb: 0.15
  ld: normalize 0.6 0.8 0.4
  br: amb+smoothstep[0.0;0.1;dot[nor;ld]]
  (nor[0]*br; nor[1]*br; nor[2]*br; 1.0)}]]
ck["fragSky"; shader.fragment[[uv:`v2; out:`v4]; {[uv]
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
  r: pow[clamp[mix[sr; 1.0; cld]; 0.; 1.];0.4545]
  g: pow[clamp[mix[sg; 1.0; cld]; 0.; 1.];0.4545]
  b: pow[clamp[mix[sb; 1.0; cld]; 0.; 1.];0.4545]
  (r; g; b; 1.0)}]]
ck["fragCond"; shader.fragment[[uv:`v2; out:`f32]; {[uv]
  a: uv+0.5
  ok: (uv[0]<0.9) & ~(uv[1]>0.8)
  $[uv[0]<=uv[1]; a[0]; uv[0]>=0.75; fract[sin[dot[uv; 127.1 311.7]]*43758.5]; ok; 0.5; 0.0]}]]
ck["fragTex"; shader.fragmentTexN[[uv:`v2; out:`v4]; 2; {[uv]
  c0: sample[0; uv]
  c1: sample[1; uv]
  (mix[c0[0];c1[0];0.5]; c0[1]; c1[2]; 1.0)}]]
/ Vertex shaders are vertex-PULLED now (shader.vertexPull): geometry rides a stride-N
/ storage buffer read at N*vid, and uniforms ride a second buffer (uCam/uPan → ub).
ck["vtxPlanes"; shader.vertexPull[[vNor:`v3]; {[vb;vid]
  b:6.*vid; px:vb[b]; py:vb[b+1.]; pz:vb[b+2.]
  c45:0.7071; s45:0.7071; c30:0.8165; s30:0.5774; sc:0.5
  py0: (c45*px)+(s45*pz)
  py2: (c45*pz)-(s45*px)
  px1: (c30*py)-(s30*py2)
  px2: (s30*py)+(c30*py2)
  ((sc*py0; sc*px1; 0.5-px2*sc*0.5; 1.0); (vb[b+3.];vb[b+4.];vb[b+5.]))}]]
ck["vtxBare"; shader.vertexPull[()!(); {[vb;vid] b:3.*vid; (vb[b];vb[b+1.];vb[b+2.];1.0)}]]
ck["vtxSword"; shader.vertexPull[[wNor:`v3;wMat:`v4;wLit:`f32]; {[vb;ub;vid]
  b:11.*vid; px:vb[b]; py:vb[b+1.]; pz:vb[b+2.]; nx:vb[b+3.]; ny:vb[b+4.]; nz:vb[b+5.]
  ca:ub[0.]; sa:ub[1.]; xca:ub[2.]; xsa:ub[3.]
  zoom:ub[4.]; cx:ub[5.]; cz:ub[6.]
  c45:0.7071; s45:0.7071; c30:0.8165; s30:0.5774; sc:0.3
  x1:(ca*px)-(sa*pz); z1:(sa*px)+(ca*pz)
  y2:(xca*py)-(xsa*z1); z2:(xsa*py)+(xca*z1)
  X:(zoom*x1)-cx; Y:zoom*y2; Z:(zoom*z2)-cz
  py0:(c45*X)+(s45*Z); py2:(c45*Z)-(s45*X)
  px1:(c30*Y)-(s30*py2); px2:(s30*Y)+(c30*py2)
  nx1:(ca*nx)-(sa*nz); nz1:(sa*nx)+(ca*nz)
  ny2:(xca*ny)-(xsa*nz1); nz2:(xsa*ny)+(xca*nz1)
  ((sc*py0; sc*px1; 0.5-px2*0.001; 1.0); (nx1;ny2;nz2); (vb[b+6.];vb[b+7.];vb[b+8.];vb[b+9.]); vb[b+10.])}]]
