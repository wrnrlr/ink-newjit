/ test/relax.k — resident-buffer compute path (keep data on the GPU across
/ dispatches). Run headless:  INK_SNAP=0 ink test/relax.k
/
/ gpu.buffer/gpu.read round-trip the host once; gpu.compileCompute builds the
/ pipeline once; gpu.dispatch runs it with no readback. Ping-pong is a plain k loop
/ over gpu.dispatch swapping the in/out buffers — the pattern SOR / XPBD cloth want.

2: "lib/dye.k"
2: "lib/gpu.k"

demo:{[]
  / (1) sanity: element-wise doubling through the resident path.
  pipe:gpu.compileCompute[shader.compute[{[x]x*2.}]; 2]
  a:gpu.buffer[1. 2. 3. 4. 5.]
  b:gpu.buffer[5#0.]
  gpu.dispatch[pipe; (a;b); 5]
  `0 0:"double 1..5      -> "; `0 0:$gpu.read[b]; `0 0:"\n"

  / (2) ping-pong: iterate x <- (x+1)/2 from 0, 24 steps -> converges to 1.
  / The kernel is element-wise, but the point is the data never leaves the GPU:
  / one upload, 24 dispatches swapping A/B, one readback.
  relax::gpu.compileCompute[shader.compute[{[x](x+1.)*0.5}]; 2]
  A::gpu.buffer[8#0.]; B::gpu.buffer[8#0.]
  24 pong/0
  `0 0:"ping-pong ->1     -> "; `0 0:$gpu.read[A]; `0 0:"\n"
  0}

/ one relaxation step, alternating which buffer is read vs written (globals, so
/ the lambda can see A/B/relax — ink lambdas don't close over parent scope).
pong:{[i] $[0=i mod 2; gpu.dispatch[relax;(A;B);8]; gpu.dispatch[relax;(B;A);8]]; i+1}

gDone::0
go::{[] gDone::1; demo[]}
loop:{[props] $[gDone=0; go[]; 0]}
window.run[loop; 0]
