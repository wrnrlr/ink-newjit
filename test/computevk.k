/ computevk.k — headless compute on the Vulkan/MoltenVK backend (migration Phase 2).
/ Run: zig build gpu -Dgpu-backend=vulkan && echo | ./zig-out/bin/ink test/computevk.k
2: "lib/gpu.k"
2: "lib/dye.k"

gpu.computeRun[{[x]
  / 1. one-shot element-wise map (create in/out, dispatch, readback)
  r1:: gpu.runShader[shader.compute[{[v] v*2.}]; 1. 2. 3. 4. 5.]

  / 2. resident buffer + cached pipeline + bare dispatch (no per-call readback)
  p::  gpu.compileCompute[shader.compute[{[v] (v*v)+1.}]; 2]
  a::  gpu.buffer[0. 1. 2. 3. 4.]
  b::  gpu.buffer[0. 0. 0. 0. 0.]
  gpu.dispatch[p; a,b; 5]
  r2:: gpu.read[b]

  / 3. two-input map
  r3:: gpu.runShader2[shader.compute2[{[u;v] u+v}]; 1. 2. 3.; 10. 20. 30.]

  / 4. ping-pong dispatchLoop: y=x+1 applied 4 times over a,b -> 0..4 + 4
  q::  gpu.compileCompute[shader.compute[{[v] v+1.}]; 2]
  gpu.dispatchLoop[q; a,b; b,a; 5; 4]
  r4:: gpu.read[a]                 / 4 reps, last write lands in a

  / 5. uniform buffer: y = x*s + t (s=3,t=1) -> 3x+1  (distinct descriptor path)
  u::  gpu.uniform[3. 1. 0. 0.]
  pu:: gpu.compileComputeU[shader.computeU[{[v;c] (v*c[0])+c[1]}]; 2]
  c0:: gpu.buffer[1. 2. 3. 4. 5.]
  c1:: gpu.buffer[0. 0. 0. 0. 0.]
  gpu.dispatch[pu; c0,c1,u; 5]
  r5:: gpu.read[c1]
  0
}]

`0 0: "1 one-shot  x*2  : ",$r1
`0 0: "2 resident  x^2+1: ",$r2
`0 0: "3 compute2  u+v  : ",$r3
`0 0: "4 ping-pong x+4  : ",$r4
`0 0: "5 uniform   3x+1 : ",$r5
