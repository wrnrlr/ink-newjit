/ test/gpusolve.k — resident-buffer GPU solvers built on the stencil + scatter
/ intrinsics. Run headless:  INK_SNAP=0 ink test/gpusolve.k
/
/ Demonstrates the follow-up compute stack:
/   1. uniforms      — grid size read from a params buffer (StencilShaderU), so one
/                      pipeline serves any N.
/   2. multi-dispatch — DispatchLoop records N passes into ONE encoder+submit (no
/                      per-step host round-trip), alternating two bind configs.
/   3. red-black SOR — in-place (StencilShaderIP) + parity params swapped per pass;
/                      the fastest walk.k solver, on the GPU.
/   4. atomic scatter — StencilScatter + scatterAdd: edge-parallel scatter-add onto
/                      shared nodes via OpAtomicIAdd (the XPBD cloth pattern).

2: "lib/spirv.k"
2: "lib/gpu.k"

/ walk.k energy solve; N from the params uniform g[0] (nothing baked).
jac::StencilShaderU[{[u;g;i] w:g[0]; b:w-1.5; r:floor[i%w]; c:i-r*w;
  $[(r<0.5)|(r>b)|(c<0.5)|(c>b); 0.; 1.+.25*(u[i-w]+u[i+w]+u[i-1.]+u[i+1.])]}]

/ same solve as in-place red-black SOR; params g=[N; omega; parity].
sor::StencilShaderIP[{[u;g;i] w:g[0]; om:g[1]; par:g[2]; b:w-1.5;
  r:floor[i%w]; c:i-r*w;
  bnd:(r<0.5)|(r>b)|(c<0.5)|(c>b);
  mine:(mod[r+c;2.])=par;
  new:(u[i])+om*((1.+.25*(u[i-w]+u[i+w]+u[i-1.]+u[i+1.]))-u[i]);
  $[bnd; 0.; mine; new; u[i]]}]

/ edge-parallel atomic scatter; guard value to 0 for over-dispatched threads.
deg::StencilScatter[{[acc; a; b; g; i] ok:$[i<g[0];1.;0.];
  x:scatterAdd[acc; a[i]; ok]; scatterAdd[acc; b[i]; ok]}]

demo::{[]
  / 1+2: batched Jacobi ping-pong, one submit, N via uniform
  pj::CompileCompute[jac;3]
  G::NewBuffer[100. 0. 0. 0.]
  A::NewBuffer[10000#0.]; B::NewBuffer[10000#0.]
  t0::`t@[]
  DispatchLoop[pj; (A;B;G); (B;A;G); 10000; 22000]
  cj::(ReadBuffer[A])@5050; t1::`t@[]
  `0 0:"batched Jacobi   center="; `0 0:$cj; `0 0:"  ("; `0 0:$(t1-t0)div 1000; `0 0:" ms)\n"

  / 3: GPU red-black SOR (in-place, parity params swapped per pass)
  ps::CompileCompute[sor;2]
  S::NewBuffer[10000#0.]
  PR::NewBuffer[100. 1.939 0.]; PB::NewBuffer[100. 1.939 1.]
  t2::`t@[]
  DispatchLoop[ps; (S;PR); (S;PB); 10000; 800]
  cs::(ReadBuffer[S])@5050; t3::`t@[]
  `0 0:"red-black SOR    center="; `0 0:$cs; `0 0:"  ("; `0 0:$(t3-t2)div 1000; `0 0:" ms, true 2887.48)\n"

  / 4: atomic scatter — node degrees of a path graph 0-1-2-3-4
  pd::CompileCompute[deg;4]
  EA::NewBuffer[0. 1. 2. 3.]; EB::NewBuffer[1. 2. 3. 4.]; GE::NewBuffer[4. 0. 0. 0.]
  D::NewBuffer[5#0.]
  Dispatch[pd; (D;EA;EB;GE); 4]
  `0 0:"scatter degrees      -> "; `0 0:$ReadBufferI[D]; `0 0:"  (expect 1 2 2 2 1)\n"
  0}

gDone::0
go::{[] gDone::1; demo[]}
loop:{[props] $[gDone=0; go[]; 0]}
window.run[loop; 0]
