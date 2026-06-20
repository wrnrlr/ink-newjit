/ lib/gpu.k — load GPU extension
/
/ Build first:  zig build gpu
/ Load with:    2: "lib/gpu.k"

so: "./zig-out/lib/libgpu.dylib"
RunWindow:    so 2: (`gpuRun;       2)   / (loop_fn; config) → 0 : blocking event loop
FillFrame:    so 2: (`gpuFill;      2)   / (verts_F; frag_F) → 0 : draw triangles with built-in shader
Tessellate:   so 2: (`gpuTess;      1)   / pts_F → verts_F   : tessellate polygon
CompileSpirV: so 2: (`gpuSpirv;     2)   / (spirv_I; 0) → handle : compile SPIR-V fragment shader
DrawShader:   so 2: (`gpuFillShader;2)   / (verts_F; handle) → 0 : draw triangles with custom SPIR-V shader
RunShader:    so 2: (`gpuCompute;   2)   / (spirv_I; input_F) → output_F : run compute shader
CompileWgsl:  so 2: (`gpuWgsl;      1)   / wgsl_src_C → handle : compile WGSL render shader
CompileMesh:  so 2: (`gpuMesh;      2)   / (vtx_I; frg_I) → handle : compile vertex+fragment SPIR-V mesh pipeline
DrawMesh:     so 2: (`gpuDrawMesh;  2)   / (verts_F; handle) → 0 : draw mesh; vertex stride follows the shader's declared inputs

/ Solid-color fragment uniforms (44 floats matching fill.wgsl FragUniforms).
/ r,g,b,a in [0,1].  Returns a flat F vector.
gpuSolid: {[r;g;b;a] ,/(1. 0. 0. 0.;0. 1. 0. 0.;0. 0. 1. 0.;1. 0. 0. 0.;0. 1. 0. 0.;0. 0. 1. 0.;r,g,b,a;r,g,b,a;1e10 1e10 1. 1.;0. 0. 0. 0.;0. 0. 0. 0.)}
