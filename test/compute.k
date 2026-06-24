/ compute.k — element-wise GPU compute via SPIR-V lowering.
/
/ Demonstrates the data-parallel ECS lowering path: a per-element column map
/ {[x] ...} is compiled to a SPIR-V compute shader (ComputeShader) once, then
/ dispatched on a float column each frame with RunShader. Reads binding 0,
/ writes binding 1, workgroup size 64.
/
/   echo | timeout 6s ./zig-out/bin/ink test/compute.k

2: "lib/gpu.k"
2: "lib/spirv.k"

/ A couple of element-wise kernels (the shared shader expr-compiler handles
/ arithmetic and the GLSL math builtins: sqrt, sin, cos, abs, min, max, …).
doubleIt: {[x] x*2.}
poly:     {[x] (x*x)+(2.*x)+1.}          / (x+1)^2
wave:     {[x] (sin[x]*0.5)+0.5}

gReady:: 0
gDbl:: 0; gPoly:: 0; gWave:: 0          / cached compiled shaders

demo: {[]
  / compile once (cache the SPIR-V binaries)
  gDbl::  ComputeShader[doubleIt]
  gPoly:: ComputeShader[poly]
  gWave:: ComputeShader[wave]
  `0 0: "double 1..5 -> "
  `0 0: $RunShader[gDbl;  1. 2. 3. 4. 5.]
  `0 0: "poly   0..4 -> "
  `0 0: $RunShader[gPoly; 0. 1. 2. 3. 4.]
  `0 0: "wave   ->       "
  `0 0: $RunShader[gWave; 0. 1.5708 3.14159 4.71239]
  gReady:: 1
  0
}

RunWindow[{[props] $[gReady=0; demo[]; 0]}; 0]
