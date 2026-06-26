/ test/ecs_compute.k — offload element-wise ECS systems to the GPU compute path.
/ An archetype column is a flat f32 vector = a compute-shader buffer, so a per-entity
/ system can run on the GPU via ComputeShader (k -> SPIR-V) + RunShader.
/   timeout 6s ./zig-out/bin/ink test/ecs_compute.k   (opens a window; prints results)

2: "lib/gpu.k"
2: "lib/spirv.k"
2: "lib/ecs.k"

/ archetype: id + x-position + y-velocity
Particle:: Archetype `id`px`vy!(0;0.;0.)
Particle:: aPush[Particle; `id`px`vy!(0; 10.; 1.)]
Particle:: aPush[Particle; `id`px`vy!(1; 20.; 2.)]
Particle:: aPush[Particle; `id`px`vy!(2; 30.; 3.)]
Particle:: aPush[Particle; `id`px`vy!(3; 40.; 4.)]

/ element-wise kernels (constants baked in) — compiled to SPIR-V once
gravK: {[vy] vy + (-0.5)}        / gravity: vy += -0.5 per step
dampK: {[px] px * 0.9}           / drag:    px *= 0.9 per step
gGrav:: 0; gDamp:: 0

gReady:: 0
runOnce: {[]
  gGrav:: ComputeShader gravK
  gDamp:: ComputeShader dampK
  `0 0: "before  — vy / px:"
  `0 0: $Particle`vy
  `0 0: $Particle`px

  / offload BOTH columns to the GPU in one call (ecsOffloadAll), 3 steps
  Particle:: ecsOffloadAll[Particle; `vy`px; (gGrav;gDamp)]
  Particle:: ecsOffloadAll[Particle; `vy`px; (gGrav;gDamp)]
  Particle:: ecsOffloadAll[Particle; `vy`px; (gGrav;gDamp)]

  `0 0: "after 3 GPU steps — vy (expect -0.5 0.5 1.5 2.5):"
  `0 0: $Particle`vy
  `0 0: "after 3 GPU steps — px (expect 10/20/30/40 * 0.9^3 = 7.29 14.58 21.87 29.16):"
  `0 0: $Particle`px

  / CPU cross-check of the velocity column
  `0 0: "CPU vy (vy - 1.5):"
  `0 0: $(0.+1 2 3 4)-1.5
  gReady:: 1
  0
}
RunWindow[{[props] $[gReady=0; runOnce[]; 0]}; 0]
