/ test/walkgpu.k — the kk2 §2.4-4 acceptance: walk.k's Jacobi solver `f` compiled
/ VERBATIM to the GPU and iterated (ping-pong) to the f32 fixpoint. The energy at
/ the grid centre must land on 2887.34 (the biased Jacobi f32 fixpoint documented
/ in test/walk.k), matching the CPU relaxation.
/ Slow (~30k sweeps on 9604 cells) — run on demand:  INK_SNAP=0 ink test/walkgpu.k

2: "lib/kk.k"

N:100; h: N div 2
(r;c):1+!2#N-2; I:c+N*r
W:((-N),N,1,-1)+\:I
f:{@[x;I;:;1.+.25*+/x@W]}          / walk.k's f, unchanged
ctr: h+N*h

demo: {[]
  x0d: gpu.hold (N*N)#0.
  E: gpu.fetch kk.loop[f; x0d; 30000]
  v: E ctr
  `0 0: "walkgpu: E@center = ",($v),"  (target 2887.34)\n"
  `0 0: $[0.02 > abs v - 2887.34; "walkgpu: PASS\n"; "walkgpu: FAIL\n"]
  0}
gpu.computeRun[{[x] demo[]}]
