/ test/kkgold.k — byte-identity oracle for the dye compute-emitter consolidation.
/ Compiles one representative kernel through EVERY compute entry point and dumps
/ the full SPIR-V word list as text. Run before and after a dye.k refactor and
/ diff the outputs:  ink test/kkgold.k > /tmp/kk.txt   (see doc/design/kk.md §5.1)
/ Kernels are lifted from test/walk3.k, test/clothgpu.k and lib/nn.k so the dump
/ covers: element maps, uniform blocks, buffer gathers, in-place stores, atomic
/ scatter, multi-buffer kernels, and the rsum/rmax in-kernel loops.

2: "lib/dye.k"

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
  sdt:g[0]; ax:mod[d;3.]; part:floor[d%3.]
  isY:$[ax=1.;1.;0.]; free:$[(im[part])>0.;1.;0.]
  nv:(v[d])+isY*free*(-9.81*sdt)
  set[v; d; nv]
  set[prev; d; p[d]]
  np:(p[d])+sdt*nv
  set[p; d; $[ax=1.; $[np<(-2.); -2.; np]; np]]}; 0; 5]]
ck["kernel12"; gpu.kernel[{[dp;p;g;d] set[p; d; (p[d])+(iget[dp;d])%1048576.]; iset[dp;d;0.]}; 1; 2]]
ck["kernel13"; gpu.kernel[{[dp;p;e;g;ee]
  sc:1048576.
  ne:g[0]; sdt:g[1]; ok:$[ee<ne;1.;0.]
  base:7.*ee
  pi:e[base]; pj:e[base+1.]; l0:e[base+2.]
  bi:3.*pi; bj:3.*pj
  dx:(p[bj])-p[bi]
  cx:ok*sc*dx*l0
  a0:scatterAdd[dp;bi;cx]; scatterAdd[dp;bj;0.-cx]}; 1; 3]]
ck["kernelRsum"; gpu.kernel[{[c;a;b;g;d]
  n:g[1]; kk:g[2]
  i:floor[d%n]; j:mod[d;n]
  set[c; d; rsum[kk; {[k] (a[(i*kk)+k]) * b[(k*n)+j]}]]}; 0; 4]]
ck["kernelRmax"; gpu.kernel[{[mb;sb;x;g;i]
  n:g[0]
  m: rmax[n; {[k] x[(i*n)+k]}]
  s: rsum[n; {[k] exp[(x[(i*n)+k]) - m]}]
  set[mb; i; m]; set[sb; i; s]}; 0; 4]]
