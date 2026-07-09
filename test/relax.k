/ test/relax.k — resident-buffer compute path (keep data on the GPU across
/ dispatches). Run headless:  INK_SNAP=0 ink test/relax.k
/
/ NewBuffer/ReadBuffer round-trip the host once; CompileCompute builds the
/ pipeline once; Dispatch runs it with no readback. Ping-pong is a plain k loop
/ over Dispatch swapping the in/out buffers — the pattern SOR / XPBD cloth want.

2: "lib/spirv.k"
2: "lib/gpu.k"

demo:{[]
  / (1) sanity: element-wise doubling through the resident path.
  pipe:CompileCompute[ComputeShader[{[x]x*2.}]; 2]
  a:NewBuffer[1. 2. 3. 4. 5.]
  b:NewBuffer[5#0.]
  Dispatch[pipe; (a;b); 5]
  `0 0:"double 1..5      -> "; `0 0:$ReadBuffer[b]; `0 0:"\n"

  / (2) ping-pong: iterate x <- (x+1)/2 from 0, 24 steps -> converges to 1.
  / The kernel is element-wise, but the point is the data never leaves the GPU:
  / one upload, 24 dispatches swapping A/B, one readback.
  relax::CompileCompute[ComputeShader[{[x](x+1.)*0.5}]; 2]
  A::NewBuffer[8#0.]; B::NewBuffer[8#0.]
  24 pong/0
  `0 0:"ping-pong ->1     -> "; `0 0:$ReadBuffer[A]; `0 0:"\n"
  0}

/ one relaxation step, alternating which buffer is read vs written (globals, so
/ the lambda can see A/B/relax — ink lambdas don't close over parent scope).
pong:{[i] $[0=i mod 2; Dispatch[relax;(A;B);8]; Dispatch[relax;(B;A);8]]; i+1}

gDone::0
go::{[] gDone::1; demo[]}
loop:{[props] $[gDone=0; go[]; 0]}
window.run[loop; 0]
