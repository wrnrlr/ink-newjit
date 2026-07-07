/ lib/gpu.k — load GPU extension
/
/ Build first:  zig build gpu
/ Load with:    2: "lib/gpu.k"

so: "./zig-out/lib/libgpu.dylib"
/ window.run calls loop_fn(props) each frame. props is a dict:
/   width height mx my time     — framebuffer size, cursor pos (px), seconds
/   events                      — a TABLE of every input event since last frame
/                                 (one row each; use it directly, no flip). Columns:
/                                   kind  `text `key `mouse `scroll   (symbol)
/                                   code  text=codepoint key=GLFW-keycode mouse=button
/                                   mods  modifier bits (1=shift 2=ctrl 4=alt 8=super)
/                                   down  1=press/repeat 0=release (key/mouse); else 0N
/                                   x y   cursor px at event time
/                                   amt   scroll wheel delta (else 0n)
/                                 unused cells are 0N/0n nulls — filter them.
/ For held keys/buttons, track down/up events yourself (see lib/camera.k).
window.run:    so 2: (`gpuRun;       2)   / (loop_fn; config) → 0 : blocking event loop
FillFrame:    so 2: (`gpuFill;      2)   / (verts_F; frag_F) → 0 : draw triangles with built-in shader
tessellate:   so 2: (`gpuTess;      1)   / pts_F → verts_F   : tessellate polygon
CompileSpirV: so 2: (`gpuSpirv;     2)   / (spirv_I; 0) → handle : compile SPIR-V fragment shader
DrawShader:   so 2: (`gpuFillShader;2)   / (verts_F; handle) → 0 : draw triangles with custom SPIR-V shader
RunShader:    so 2: (`gpuCompute;   2)   / (spirv_I; input_F) → output_F : run compute shader
RunShader2:   so 2: (`gpuCompute2;  3)   / (spirv_I; in1_F; in2_F) → output_F : 2-input compute
CompileMesh:  so 2: (`gpuMesh;      2)   / (vtx_I; frg_I) → handle : compile vertex+fragment SPIR-V mesh pipeline
DrawMesh:     so 2: (`gpuDrawMesh;  2)   / (verts_F; handle) → 0 : draw mesh; vertex stride follows the shader's declared inputs
DrawMeshU:    so 2: (`gpuDrawMeshU; 3)   / (verts_F; handle; uni_F) → 0 : draw mesh + per-draw uniform block (8 vec4 slots; see VertexShaderU)
gpuDrawMeshT0: so 2: (`gpuDrawMeshT; 3)  / (verts_F; (handle;texHandle)_I; uni_F) → 0 : draw mesh + uniform + texture@group(1)
gpuTexture0:   so 2: (`gpuTexture;  2)   / ((w;h;comp)_I; data_I) → texHandle : upload an image to a sampled GPU texture
/ Draw a mesh with a per-draw uniform block AND a texture (see FragmentShaderTex).
DrawMeshT: {[verts; handle; uni; tex] gpuDrawMeshT0[verts; (handle;tex); uni]}
/ Retained (upload-once) counterpart: UploadMesh the geometry to a persistent
/ buffer, then DrawGeomT it each frame with only the uniform+texture — the vertex
/ data is never re-uploaded.  UploadMesh also lives in lib/instancing.k.
UploadMesh:    so 2: (`gpuUploadMesh; 2)  / (verts_F; meshHandle) → geomHandle : geometry → persistent vertex buffer
gpuDrawGeomT0: so 2: (`gpuDrawGeomT;  3)  / (geom; uni_F; texHandle) → 0 : draw retained geom + uniform + texture
DrawGeomT: {[geom; uni; tex] gpuDrawGeomT0[geom; uni; tex]}
/ Upload an image dict (`width`height`comp`data, e.g. from image.read) as a texture.
Texture: {[img] w:img`width; h:img`height; c:img`comp; d:img`data; gpuTexture0[(w;h;c); d]}
/ UploadMesh / DrawInstanced (retained geometry + instancing) live in lib/instancing.k

/ Solid-color fragment uniforms (44 floats matching fill.wgsl FragUniforms).
/ r,g,b,a in [0,1].  Returns a flat F vector.
gpuSolid: {[r;g;b;a] ,/(1. 0. 0. 0.;0. 1. 0. 0.;0. 0. 1. 0.;1. 0. 0. 0.;0. 1. 0. 0.;0. 0. 1. 0.;r,g,b,a;r,g,b,a;1e10 1e10 1. 1.;0. 0. 0. 0.;0. 0. 0. 0.)}
