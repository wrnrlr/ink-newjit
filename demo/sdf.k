/ demo/sdf.k — Shadertoy-style circle SDF via SPIR-V compiler
/
/ Demonstrates:
/   - smoothstep[edge0; edge1; x]   3-arg GLSL built-in
/   - sqr x                         monadic square (x*x) in shader
/   - sqrt[expr]                    explicit function call form
/   - Local variable binding in shader lambda
/
/ Run: zig build gpu && ink demo/sdf.k

2: "lib/dye.k"
2: "lib/gpu.k"

/ Circle SDF fragment shader.
/ uv in [0,1]x[0,1] from fill.wgsl vertex stage.
/ Maps uv to centred [-1,1] space, computes signed distance to unit circle.
/ smoothstep gives a 1px anti-aliased edge.
/ Output: white on black, v4 rgba.

spirvWds: shader.fragment[(uv:`v2; out:`v4); {[uv]
  ux:((uv[0]*2.0)-1.0)*4.0%3.0
  uy:(uv[1]*2.0)-1.0
  d:sqrt[(sqr ux)+(sqr uy)]-0.45
  c:smoothstep[0.015;-0.015;d]
  (c;c;c;1.0)
}]

/ Full-screen quad [x y u v] × 6 vertices for an 800×600 window
verts: 0. 0. 0. 0. 800. 0. 1. 0. 800. 600. 1. 1. 0. 0. 0. 0. 800. 600. 1. 1. 0. 600. 0. 1.

handle::0
loop: {[props]
  $[handle=0;handle::gpu.compileSpirv[spirvWds;0];0]
  gpu.drawShader[verts;handle]}

window.run[loop; 0]
