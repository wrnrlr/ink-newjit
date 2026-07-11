/ test/stencil.k — the buffer-index intrinsic: gather-capable compute shaders.
/ Run headless:  INK_SNAP=0 ink test/stencil.k
/
/ StencilShader[{[u;i] ...}] compiles a compute kernel where `u` is the input
/ buffer, indexable at ANY computed offset (u[i-1], u[i+W]), and `i` is the
/ thread's flat index. That turns the element-wise ComputeShader (a map) into a
/ gather (a stencil), so Jacobi/SOR/PDE relaxations run on the resident-buffer
/ path from test/relax.k. Grid size + boundaries are baked into the kernel.

2: "lib/spirv.k"
2: "lib/dye.k"
2: "lib/gpu.k"

/ (1) 1D heat relaxation: ends pinned to 0 and 15, interior averages its two
/ neighbours -> converges to the linear ramp u[i]=i. Proves u[i-1], u[i+1], u[i].
heat::StencilShader[{[u;i] $[(i<0.5)|(i>14.5); u[i]; 0.5*(u[i-1.]+u[i+1.])]}]

/ (2) The walk.k energy solver on the GPU: 100x100 Jacobi. row=floor(i/100),
/ col=i-100*row; boundary cells stay 0; interior = 1 + .25*(4 neighbours).
walk::StencilShader[{[u;i] r:floor[i%100.]; c:i-r*100.;
  $[(r<0.5)|(r>98.5)|(c<0.5)|(c>98.5); 0.; 1.+.25*(u[i-100.]+u[i+100.]+u[i-1.]+u[i+1.])]}]

pH::0; pW::0
pong::{[k] $[0=k mod 2; Dispatch[pH;(A;B);16]; Dispatch[pH;(B;A);16]]; k+1}
step::{[k] $[0=k mod 2; Dispatch[pW;(A;B);10000]; Dispatch[pW;(B;A);10000]]; k+1}

demo::{[]
  / 1D ramp
  pH::CompileCompute[heat;2]
  A::NewBuffer[@[16#0.;15;:;15.]]; B::NewBuffer[16#0.]
  400 pong/0
  `0 0:"1D ramp        -> "; `0 0:$ReadBuffer[A]; `0 0:"\n"

  / 2D walk, benchmarked (`t is a microsecond clock)
  pW::CompileCompute[walk;2]
  A::NewBuffer[10000#0.]; B::NewBuffer[10000#0.]
  t0::`t@[]
  22000 step/0
  E::ReadBuffer[A]
  t1::`t@[]
  `0 0:"2D walk center -> "; `0 0:$E@5050
  `0 0:"  (22000 iters, "; `0 0:$(t1-t0)div 1000; `0 0:" ms)\n"
  0}

gDone::0
go::{[] gDone::1; demo[]}
loop:{[props] $[gDone=0; go[]; 0]}
window.run[loop; 0]
