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
gpuSolid: {[r;g;b;a] ,/(1. 0. 0. 0.;0. 1. 0. 0.;0. 0. 1. 0.;1. 0. 0. 0.;0. 1. 0. 0.;0. 0. 1. 0.;r,g,b,a;r,g,b,a;1e10 1e10 1. 1.;0. 0. 0. 0.;0. 0. 0. 0.)}
