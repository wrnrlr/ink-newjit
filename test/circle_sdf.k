/ test/circle_sdf.k — Shadertoy-style circle SDF via SPIR-V compiler
/
/ Demonstrates:
/   - smoothstep[edge0; edge1; x]   3-arg GLSL built-in via compFnCall
/   - sqrt[expr]                    explicit function call form
/   - Local variable binding in shader lambda (d: ...; ...)
/   - Animated circle using time packed in ViewUniforms._pad[0]
/
/ The shader draws a white circle with smooth anti-aliased edge.
/ The circle pulses slightly using time (packed by gpuRun into u_view._pad[0]).
/ To read time, the vertex shader passes it through a varying or the user
/ recompiles the quad each frame — here we keep it simple (static size).
/
/ Run: zig build gpu && ink test/circle_sdf.k

2: "lib/gpu/spirv.k"
2: "lib/gpu/gpu.k"

/ Circle SDF fragment shader.
/ uv in [0,1]x[0,1] from fill.wgsl vertex stage.
/ Maps uv to centred [-1,1] space, computes signed distance to unit circle.
/ smoothstep gives a 1px anti-aliased edge.
/ Output: white on black, v4 rgba.
/
/ Without local variables the SDF is computed 3× (GPU CSE handles it):
/   d = sqrt((ux*ux)+(uy*uy)) - 0.45
/   c = smoothstep[0.015; -0.015; d]
/   → (c; c; c; 1.0)
/
/ With local variable support (compSeq) we write it cleanly once:
/   d: sqrt[(ux*ux)+(uy*uy)] - 0.45
/   c: smoothstep[0.015; -0.015; d]
/   (c; c; c; 1.0)

spirvWds: compShader[{[uv]
  ux: uv[0]*2.0-1.0
  uy: uv[1]*2.0-1.0
  d: sqrt[(ux*ux)+(uy*uy)]-0.45
  c: smoothstep[0.015;-0.015;d]
  (c; c; c; 1.0)}; [`uv:`v2; `out:`v4]]

/ Full-screen quad [x y u v] × 6 vertices for an 800×600 window
verts: 0. 0. 0. 0. 800. 0. 1. 0. 800. 600. 1. 1. 0. 0. 0. 0. 800. 600. 1. 1. 0. 600. 0. 1.

handle:: 0
loop: {[props]
  $[handle=0; handle:: gpuSpirv[spirvWds; 0]; 0]
  gpuFillShader[verts; handle]}

gpuRun[loop; 0]
