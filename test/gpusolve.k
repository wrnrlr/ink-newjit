/ test/gpusolve.k — resident-buffer GPU solvers built on the stencil + scatter
/ intrinsics. Run headless:  INK_SNAP=0 ink test/gpusolve.k
/
/ Demonstrates the follow-up compute stack:
/   1. uniforms      — grid size read from a params buffer (shader.stencilU), so one
/                      pipeline serves any N.
/   2. multi-dispatch — gpu.dispatchLoop records N passes into ONE encoder+submit (no
/                      per-step host round-trip), alternating two bind configs.
/   3. red-black SOR — in-place (shader.stencilIP) + parity params swapped per pass;
/                      the fastest walk.k solver, on the GPU.
/   4. atomic scatter — shader.scatter + scatterAdd: edge-parallel scatter-add onto
/                      shared nodes via OpAtomicIAdd (the XPBD cloth pattern).

2: "lib/dye.k"
2: "lib/gpu.k"

/ walk.k energy solve; N from the params uniform g[0] (nothing baked).
jac::shader.stencilU[{[u;g;i] w:g[0]; b:w-1.5; r:floor[i%w]; c:i-r*w;
  $[(r<0.5)|(r>b)|(c<0.5)|(c>b); 0.; 1.+.25*(u[i-w]+u[i+w]+u[i-1.]+u[i+1.])]}]

/ same solve as in-place red-black SOR; params g=[N; omega; parity].
sor::shader.stencilIP[{[u;g;i] w:g[0]; om:g[1]; par:g[2]; b:w-1.5;
  r:floor[i%w]; c:i-r*w;
  bnd:(r<0.5)|(r>b)|(c<0.5)|(c>b);
  mine:(mod[r+c;2.])=par;
  new:(u[i])+om*((1.+.25*(u[i-w]+u[i+w]+u[i-1.]+u[i+1.]))-u[i]);
  $[bnd; 0.; mine; new; u[i]]}]

/ edge-parallel atomic scatter; guard value to 0 for over-dispatched threads.
deg::shader.scatter[{[acc; a; b; g; i] ok:$[i<g[0];1.;0.];
  x:scatterAdd[acc; a[i]; ok]; scatterAdd[acc; b[i]; ok]}]

demo::{[]
  / 1+2: batched Jacobi ping-pong, one submit, N via uniform
  pj::gpu.compileCompute[jac;3]
  G::gpu.buffer[100. 0. 0. 0.]
  A::gpu.buffer[10000#0.]; B::gpu.buffer[10000#0.]
  t0::`t@[]
  gpu.dispatchLoop[pj; (A;B;G); (B;A;G); 10000; 22000]
  cj::(gpu.read[A])@5050; t1::`t@[]
  `0 0:"batched Jacobi   center="; `0 0:$cj; `0 0:"  ("; `0 0:$(t1-t0)div 1000; `0 0:" ms)\n"

  / 3: GPU red-black SOR (in-place, parity params swapped per pass)
  ps::gpu.compileCompute[sor;2]
  S::gpu.buffer[10000#0.]
  PR::gpu.buffer[100. 1.939 0.]; PB::gpu.buffer[100. 1.939 1.]
  t2::`t@[]
  gpu.dispatchLoop[ps; (S;PR); (S;PB); 10000; 800]
  cs::(gpu.read[S])@5050; t3::`t@[]
  `0 0:"red-black SOR    center="; `0 0:$cs; `0 0:"  ("; `0 0:$(t3-t2)div 1000; `0 0:" ms, true 2887.48)\n"

  / 4: atomic scatter — node degrees of a path graph 0-1-2-3-4
  pd::gpu.compileCompute[deg;4]
  EA::gpu.buffer[0. 1. 2. 3.]; EB::gpu.buffer[1. 2. 3. 4.]; GE::gpu.buffer[4. 0. 0. 0.]
  D::gpu.buffer[5#0.]
  gpu.dispatch[pd; (D;EA;EB;GE); 4]
  `0 0:"scatter degrees      -> "; `0 0:$gpu.readI[D]; `0 0:"  (expect 1 2 2 2 1)\n"
  0}

gDone::0
go::{[] gDone::1; demo[]}
loop:{[props] $[gDone=0; go[]; 0]}
window.run[loop; 0]
