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
/ Headless one-shot compute: no window, no event loop. Creates a GPU device,
/ calls fn once (write it {[x] …}; x is an ignored placeholder), then tears the
/ device down. Like window.run, stash results in a global from inside fn:
/   gpu.computeRun[{[x] out:: gpu.runShader[shader.compute[{[v] v*2.}]; 1. 2. 3.]}]
/   out   / -> 2. 4. 6.
gpu.computeRun: so 2: (`gpuComputeRun; 1)   / fn → 0 : headless compute, no window
gpu.fill:    so 2: (`gpuFill;      2)   / (verts_F; frag_F) → 0 : draw triangles with built-in shader
gpu.tessellate:   so 2: (`gpuTess;      1)   / pts_F → verts_F   : gpu.tessellate polygon
gpu.compileSpirv: so 2: (`gpuSpirv;     2)   / (spirv_I; 0) → handle : compile SPIR-V fragment shader
gpu.drawShader:   so 2: (`gpuFillShader;2)   / (verts_F; handle) → 0 : draw triangles with custom SPIR-V shader
gpu.runShader:    so 2: (`gpuCompute;   2)   / (spirv_I; input_F) → output_F : run compute shader
gpu.runShader2:   so 2: (`gpuCompute2;  3)   / (spirv_I; in1_F; in2_F) → output_F : 2-input compute
/ Resident compute: keep data on the GPU across dispatches (iterative solvers).
/ gpu.buffer/gpu.read round-trip once; gpu.dispatch runs a cached pipeline with no
/ readback, so ping-pong is a plain k loop over gpu.dispatch (see test/relax.k).
gpu.buffer:    so 2: (`gpuBufferNew;  1)   / F → bufHandle : alloc+upload a resident storage buffer
gpu.write:  so 2: (`gpuBufferWrite;2)   / (bufHandle; F) → 0 : overwrite a resident buffer
gpu.read:   so 2: (`gpuBufferRead; 1)   / bufHandle → F : read a resident buffer back to host
gpu.readI:  so 2: (`gpuBufferReadI;1)   / bufHandle → I : read a resident buffer back as ints (atomic accumulators)
gpu.compileCompute: so 2: (`gpuComputeNew; 2) / (spirv_I; nbind) → pipeHandle : compile+cache a compute pipeline
/ Uniform buffers in compute (true UBO for constants, not a storage buffer):
/   p: gpu.compileComputeU[shader.computeU[{[x;u] (x*u[0])+u[1]}]; 2]  / storage@0,1 + uniform@2
/   u: gpu.uniform[3. 1. 0. 0.]                                        / a vec4 (scale;bias;…)
/   gpu.dispatch[p; (inBuf;outBuf;u); n]                              / u bound at binding 2
gpu.uniform:         so 2: (`gpuUniformNew;  1)   / F → bufHandle : resident UNIFORM buffer (pass a vec4)
gpu.compileComputeU: so 2: (`gpuComputeNewU; 2)   / (spirv_I; nStorage) → pipe : storage@0..nStorage-1 + uniform@nStorage
gpu.dispatch:     so 2: (`gpuDispatch;   3)   / (pipeHandle; bufHandles_I; nThreads) → 0 : bind buffers @0..; dispatch; no readback
gpuDispatchLoop0: so 2: (`gpuDispatchLoop; 3) / (pipe; (nThreads,bufsA,bufsB)_I; reps) → 0 : reps passes in ONE encoder, A on even/B on odd
/ Batched iteration in one submit (no per-step host round-trip). Alternates two
/ bind configs: ping-pong Jacobi swaps buffers (a=(in;out;u) b=(out;in;u)); red-black
/ SOR swaps parity params (a=(state;pR) b=(state;pB)). Result is in whichever the
/ last pass wrote: even reps → a's output, odd reps → b's output.
gpu.dispatchLoop: {[pipe;bufsA;bufsB;nThreads;reps] gpuDispatchLoop0[pipe; nThreads,bufsA,bufsB; reps]}
mesh.compile:  so 2: (`gpuMesh;      2)   / (vtx_I; frg_I) → handle : compile vertex+fragment SPIR-V mesh pipeline
mesh.draw:     so 2: (`gpuDrawMesh;  2)   / (verts_F; handle) → 0 : draw mesh; vertex stride follows the shader's declared inputs
mesh.drawU:    so 2: (`gpuDrawMeshU; 3)   / (verts_F; handle; uni_F) → 0 : draw mesh + per-draw uniform block (8 vec4 slots; see shader.vertexU)
gpuDrawMeshT0: so 2: (`gpuDrawMeshT; 3)  / (verts_F; (handle,texHandles)_I; uni_F) → 0 : draw mesh + uniform + textures@group(1)
gpuTexture0:   so 2: (`gpuTexture;  2)   / ((w;h;comp)_I; data_I) → texHandle : upload an image to a sampled GPU texture
/ Draw a mesh with a per-draw uniform block AND textures (see shader.fragmentTexN).
/ texs is an int vector of gpuTexture handles: image k = binding k (sample[k;uv]).
mesh.drawT: {[verts; handle; uni; texs] gpuDrawMeshT0[verts; handle,texs; uni]}
/ Retained (upload-once) counterpart: mesh.upload the geometry to a persistent
/ buffer, then mesh.drawGeomT it each frame with only the uniform+textures — the vertex
/ data is never re-uploaded.  mesh.upload also lives in lib/instancing.k.
mesh.upload:    so 2: (`gpuUploadMesh; 2)  / (verts_F; meshHandle) → geomHandle : geometry → persistent vertex buffer
gpuDrawGeomT0: so 2: (`gpuDrawGeomT;  3)  / (geom; uni_F; texHandles_I) → 0 : draw retained geom + uniform + textures
mesh.drawGeomT: {[geom; uni; texs] gpuDrawGeomT0[geom; uni; texs]}
/ Upload an image dict (`width`height`comp`data, e.g. from image.read) as a texture.
texture.upload: {[img] w:img`width; h:img`height; c:img`comp; d:img`data; gpuTexture0[(w;h;c); d]}
/ mesh.upload / mesh.drawInstanced (retained geometry + instancing) live in lib/instancing.k

/ Solid-color fragment uniforms (44 floats matching fill.wgsl FragUniforms).
/ r,g,b,a in [0,1].  Returns a flat F vector.
gpu.solid: {[r;g;b;a] ,/(1. 0. 0. 0.;0. 1. 0. 0.;0. 0. 1. 0.;1. 0. 0. 0.;0. 1. 0. 0.;0. 0. 1. 0.;r,g,b,a;r,g,b,a;1e10 1e10 1. 1.;0. 0. 0. 0.;0. 0. 0. 0.)}
