/ test/demo.k — UV-gradient visual demo + compute shader verification
/
/ What you see: a full-screen quad where each pixel is colored by its texture
/ coordinates: red = uv.x (left→right), green = uv.y (top→bottom), blue = 0.5.
/
/ On the first frame the compute shader {[x] x*2} is applied to 1..8; the
/ result (2 4 6 8 10 12 14 16 as f32) is stored in `computeResult` for
/ inspection.
/
/ Run:  zig build gpu && ink test/demo.k

2: "lib/gpu/spirv.k"
2: "lib/gpu/gpu.k"

/ ── Compile SPIR-V shaders ──────────────────────────────────────────────────
spirvWds:   FragmentShader[`uv`out!`v2`v4; {[uv] (uv[0]; uv[1]; 0.5; 1.0)}]
computeWds: compCompute[{[x] x*2}]

/ ── Full-screen quad vertices: [x, y, u, v] for 800x600 window ──────────────
verts: 0. 0. 0. 0. 800. 0. 1. 0. 800. 600. 1. 1. 0. 0. 0. 0. 800. 600. 1. 1. 0. 600. 0. 1.

/ ── Frame callback ────────────────────────────────────────────────────────────
handle::        0
computeResult:: ()
loop: {[props]
  $[handle=0; handle:: CompileSpirV[spirvWds; 0]; 0]
  $[0=#computeResult
    computeResult:: RunShader[computeWds; 1. 2. 3. 4. 5. 6. 7. 8.]
    0]
  DrawShader[verts; handle]}

RunWindow[loop; 0]
