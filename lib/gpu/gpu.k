/ lib/gpu/gpu.k — load GPU extension
/
/ Build first:  zig build gpu
/ Load with:    2: "lib/gpu/gpu.k"

so: "./zig-out/lib/libgpu.dylib"
gpuRun:  so 2: (`gpuRun;  2)   / (loop_fn; config) → 0 : blocking event loop
gpuFill: so 2: (`gpuFill; 2)   / (verts_F; frag_F) → 0 : draw triangles in frame
gpuTess: so 2: (`gpuTess; 1)   / pts_F → verts_F   : tessellate polygon

/ Solid-color fragment uniforms (44 floats matching fill.wgsl FragUniforms).
/ r,g,b,a in [0,1].  Returns a flat F vector.
gpuSolid: {[r;g;b;a]
  f: 11 4#0.
  f[0]: 1. 0 0 0; f[1]: 0 1. 0 0; f[2]: 0 0 1. 0  / scissor cols (identity)
  f[3]: 1. 0 0 0; f[4]: 0 1. 0 0; f[5]: 0 0 1. 0  / paint cols  (identity)
  f[6]: r,g,b,a                                     / inner color
  f[7]: r,g,b,a                                     / outer = inner → solid
  f[8]: 1e10 1e10 1. 1.                             / no scissor
  / f[9] = 0 → extent.x < 0.5 → solid branch in shader
  / f[10] = 0 → type=0, texType=0
  ,/f}                                              / flatten 11x4 → 44 floats
