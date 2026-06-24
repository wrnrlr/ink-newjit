/ test/ecs_compute2.k — TWO-input compute offload: real movement integration on
/ the GPU. A kernel {[px;vx] px+vx*dt} reads two archetype columns (binding 0 + 2)
/ and writes one (binding 1).
/   timeout 6s ./zig-out/bin/ink test/ecs_compute2.k

2: "lib/gpu.k"
2: "lib/spirv.k"
2: "lib/ecs.k"

/ archetype: id + 2D position + 2D velocity
Movers:: ecsArch `id`px`py`vx`vy!(0;0.;0.;0.;0.)
Movers:: ecsSpawn[Movers; `id`px`py`vx`vy!(0; 0.; 0.; 1.; 10.)]
Movers:: ecsSpawn[Movers; `id`px`py`vx`vy!(1; 0.; 0.; 2.; 20.)]
Movers:: ecsSpawn[Movers; `id`px`py`vx`vy!(2; 0.; 0.; 3.; 30.)]
Movers:: ecsSpawn[Movers; `id`px`py`vx`vy!(3; 0.; 0.; 4.; 40.)]

/ two-input integration kernels (dt = 0.5), compiled to SPIR-V once
moveX: {[px;vx] px + vx*0.5}
moveY: {[py;vy] py + vy*0.5}
gMX:: 0; gMY:: 0

gReady:: 0
runOnce: {[]
  gMX:: ComputeShader2 moveX
  gMY:: ComputeShader2 moveY
  `0 0: "before — px / py:"
  `0 0: $Movers`px
  `0 0: $Movers`py

  / integrate position from velocity, 3 steps, all on the GPU
  Movers:: ecsOffload2[Movers; `px; `px; `vx; gMX]
  Movers:: ecsOffload2[Movers; `py; `py; `vy; gMY]
  Movers:: ecsOffload2[Movers; `px; `px; `vx; gMX]
  Movers:: ecsOffload2[Movers; `py; `py; `vy; gMY]
  Movers:: ecsOffload2[Movers; `px; `px; `vx; gMX]
  Movers:: ecsOffload2[Movers; `py; `py; `vy; gMY]

  `0 0: "after 3 GPU steps — px (expect vx*1.5 = 1.5 3 4.5 6):"
  `0 0: $Movers`px
  `0 0: "after 3 GPU steps — py (expect vy*1.5 = 15 30 45 60):"
  `0 0: $Movers`py
  `0 0: "CPU px (vx*1.5):"
  `0 0: $1.5*0.+1 2 3 4
  gReady:: 1
  0
}
RunWindow[{[props] $[gReady=0; runOnce[]; 0]}; 0]
