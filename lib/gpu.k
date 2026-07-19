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
/ Device capability dict (query inside gpu.computeRun / window.run): api (1.2),
/ subgroup (lane count), and 0/1 flags sgArith sgBallot sgShuffle (subgroup ops →
/ whole-buffer reductions/scans), descIndex runtimeArray (bindless textures),
/ bda (buffer device address), f16, atomicFadd (native f32 scatter-add).
/ The kk compiler schedules around these — see doc/design/kk.md §4.
gpu.caps:    so 2: (`gpuCaps;      1)   / x → dict : device capability flags
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
gpu.free:   so 2: (`gpuBufferFree; 1)   / bufHandle → 0 : release a resident buffer eagerly (slot reused). No-op on an invalid/already-freed handle.
gpu.compileCompute: so 2: (`gpuComputeNew; 2) / (spirv_I; nbind) → pipeHandle : compile+cache a compute pipeline
/ Uniform buffers in compute (true UBO for constants, not a storage buffer):
/   p: gpu.compileComputeU[shader.computeU[{[x;u] (x*u[0])+u[1]}]; 2]  / storage@0,1 + uniform@2
/   u: gpu.uniform[3. 1. 0. 0.]                                        / a vec4 (scale;bias;…)
/   gpu.dispatch[p; (inBuf;outBuf;u); n]                              / u bound at binding 2
gpu.uniform:         so 2: (`gpuUniformNew;  1)   / F → bufHandle : resident UNIFORM buffer (pass a vec4)
gpu.uniformI:        so 2: (`gpuUniformNewI; 1)   / I → bufHandle : resident UNIFORM buffer of raw i32 words (shader bitcasts f32-lane→i32; exact counts to 2^31, no f32 2^24 cliff)
gpu.compileComputeU: so 2: (`gpuComputeNewU; 2)   / (spirv_I; nStorage) → pipe : storage@0..nStorage-1 + uniform@nStorage
gpu.dispatch:     so 2: (`gpuDispatch;   3)   / (pipeHandle; bufHandles_I; nThreads) → 0 : bind buffers @0..; dispatch; no readback
gpuDispatchLoop0: so 2: (`gpuDispatchLoop; 5) / (pipe; bufsA_I; bufsB_I; nThreads; reps) → 0 : reps passes in ONE encoder, A on even/B on odd
/ Batched iteration in one submit (no per-step host round-trip). Alternates two
/ bind configs: ping-pong Jacobi swaps buffers (a=(in;out;u) b=(out;in;u)); red-black
/ SOR swaps parity params (a=(state;pR) b=(state;pB)). Result is in whichever the
/ last pass wrote: even reps → a's output, odd reps → b's output.
gpu.dispatchLoop: {[pipe;bufsA;bufsB;nThreads;reps] gpuDispatchLoop0[pipe; `i$bufsA; `i$bufsB; nThreads; reps]}
/ Vertex pulling (kk2 §5) is the ONE mesh API: the vertex shader (shader.vertexPull)
/ reads RESIDENT storage buffers indexed by gl_VertexIndex — no vertex-input state.
/ mesh.compilePull builds the pipeline (nbuf storage buffers inferred from the shader);
/ mesh.drawPull binds resident buffer handles (in binding order) and draws `count`
/ vertices straight from the device.  e.g.  mesh.drawPull[p; (Pbuf;Nbuf); 3*nTri]
/ Per-frame data (uniforms) rides in a storage buffer overwritten with gpu.write; a
/ dynamic mesh is a resident buffer rewritten each frame. (The old attribute path —
/ mesh.compile/draw/drawU/upload/drawGeomT + shader.vertex/vertexU — was retired once
/ every demo moved to pulling; see lib/pbr.k, demo/*.k.)
mesh.compilePull: so 2: (`gpuMeshPull;  2)   / (vtx_I; frg_I) → handle : vertex-pull pipeline
gpuDrawPull0:     so 2: (`gpuDrawPull;  3)   / (pipe; bufHandles_I; count) → 0
gpuDrawPullT0:    so 2: (`gpuDrawPullT; 4)   / (pipe; bufHandles_I; count; texHandles_I) → 0
mesh.drawPull: {[pipe; bufs; count] gpuDrawPull0[pipe; `i$bufs; count]}
/ A vertex-pulled draw that also samples textures at @group(1) (fragmentTexN). texs =
/ gpuTexture handles, in binding order; the vertex shader still pulls geometry (and any
/ per-frame uniforms) from the resident storage buffers in `bufs`.
mesh.drawPullT: {[pipe; bufs; count; texs] gpuDrawPullT0[pipe; `i$bufs; count; `i$texs]}
gpuTexture0:   so 2: (`gpuTexture;  2)   / ((w;h;comp)_I; data_I) → texHandle : upload an image to a sampled GPU texture
/ Upload an image dict (`width`height`comp`data, e.g. from image.read) as a texture,
/ sampled at @group(1) by a shader.fragmentTexN fragment (image k = binding k).
texture.upload: {[img] w:img`width; h:img`height; c:img`comp; d:img`data; gpuTexture0[(w;h;c); d]}

/ ── Placed arrays: the 9:/8: io-verb targets (doc/design/kk.md §1) ────────────
/ The GPU is an io channel: 9: places data on the device, 8: fetches it back;
/ dispatches recorded in between only submit at the 8: sync point (vk.zig's
/ deferred submission). The descriptor is a dict [gpu:handle; t:type; n:count;
/ s:shape] — s is %x (the shape verb), the host side of the data layer: it
/ carries the row pitch 2-D stencils need and the dims kk.compile sizes
/ dispatches with (doc/design/kk2.md §8). Nested (rectangular) x flattens for
/ upload; 8: reshapes the readback to s.
/   d: 9: (N;N)#x upload (f32 for now), returns descriptor
/   d 9: x        overwrite d's buffer in place (no realloc), returns d
/   8: d          sync + read back, reshaped to s
/   n 8: d        first n elements flat (trims the ×64 dispatch padding)
/ Compile a kernel lambda straight to a cached compute pipeline: bindings are
/ inferred by shader.kernel (accumulator params first, LAST param = thread
/ index), nbind = (#params)-1 (published by dye as KKnb). Needs a live device:
/   p: gpu.pipeline[{[c;a;b;g;d] ... set[c;d;v]}]   / == compileCompute+counts
gpu.pipeline: {[fn] w: shader.kernel fn; gpu.compileCompute[w; KKnb]}

/ Flatten a (possibly nested, rectangular) value to a flat vector for upload:
/ converge-raze it if it's a general list, else leave it (a flat vector/atom is
/ already upload-ready). `,//` is monadic converge over raze — it fully flattens
/ any nesting depth (needs the triage #21 fix; before that only the 1-param
/ lambda spelling `{,/x}/` worked, forcing the per-step guard).
gpu.flat: {[x] $[`L~@x; ,//x; x]}
/ 9: x — a table (M) places as a structured buffer (gpu.holdT); a DICT (m) places
/ as a named binding group of DIFFERING-length buffers (gpu.holdD — no equal-length
/ constraint, e.g. a CSR pair [data:…; off:…]); anything else flattens to a plain
/ f32 placement.
gpu.hold:     {[x] $[`M~@x; gpu.holdT x; `m~@x; gpu.holdD x; gpu.holdA x]}
/ Placed dict (kk2 §2.5): each value is its own resident buffer, resolved by KEY.
/ Values may be ragged (CSR data/off) — no length constraint. The kernel indexes a
/ dict column as a gather source ((D`data)@i), never elementwise at the thread index.
gpu.holdD:    {[d] ks: !d; vs: d[ks]; ln: {#x}' vs; [keys: ks; hand: gpu.buffer' {0. + gpu.flat x}' vs; lens: ln; t: `dict; s: ln]}
gpu.fetchD:   {[dd] (dd`keys) ! {[h;n] n # gpu.read h}'[dd`hand; dd`lens]}
gpu.holdA:    {[x] f: gpu.flat x; [gpu: gpu.buffer[0.+f]; t: `f; n: #f; s: %x]}
gpu.holdInto: {[d;x] gpu.write[d`gpu; 0.+gpu.flat x]; d}
/ 8: d — a `tbl descriptor reads every column back and reassembles the table
/ (flip of the column dict); plain placements reshape to the recorded shape.
gpu.fetchT:   {[d] $[(d`lay)~`il; gpu.fetchTI d; gpu.fetchTP d]}
gpu.fetchTP:  {[d] + (d`cols) ! (d`n) #' gpu.read' d`hand}
/ interleaved: one buffer, stride nc. De-interleave = reshape to nr×nc (row-major,
/ so each row is one record) then flip → nc columns. (No inner-lambda gather — it
/ couldn't close over flat/nc/nr; the reshape does the same address math.)
gpu.fetchTI:  {[d] + (d`cols) ! + (d`n; d`nc) # gpu.read[d`hand]}
gpu.fetchA:   {[d] r: (d`n) # $[(d`t)~`i; gpu.readI d`gpu; gpu.read d`gpu]; $[1 < #d`s; (d`s)#r; r]}
gpu.fetch:    {[d] $[(d`t)~`tbl; gpu.fetchT d; (d`t)~`dict; gpu.fetchD d; gpu.fetchA d]}
/ gpu.drop d — free every resident buffer a placement descriptor owns (eager resident-buffer release):
/ a table/dict places one buffer per column/key (the `hand list); a plain placement one
/ buffer (`gpu). After a drop the descriptor is dead — don't 8: it. Returns 0.
gpu.drop:     {[d] $[`hand in !d; gpu.free' d`hand; `gpu in !d; gpu.free d`gpu; 0]; 0}
/ Place a k table as a STRUCTURED buffer (kk2 §2.5). Layout is a SCHEDULE choice
/ (Tiramisu L3), not semantics — the kernel source is identical either way:
/   planar (default):    one resident buffer per column, coalesced per-column reads.
/   interleaved (`il):   ONE buffer, row-major stride nc — an n-column table costs
/                        2 bindings (data+output) not n+1, so it fits MAX_BIND when
/                        a thread reads EVERY field of one row (the cloth edge kernel).
/ gpu.tblLay picks: `auto (interleave when #cols+1 > gpu.tblBudget=MAX_BIND), or a
/ forced `planar / `il. The descriptor carries `lay so kk.compile + 8: dispatch right.
gpu.tblLay::    `auto
gpu.tblBudget:: 8
gpu.holdT: {[t] cols: !t; nr: #t cols 0; nc: #cols
  il: $[gpu.tblLay~`il; 1; gpu.tblLay~`planar; 0; (nc + 1) > gpu.tblBudget]
  $[il; gpu.holdTI[t; cols; nr; nc]; gpu.holdTP[t; cols; nr; nc]]}
gpu.holdTP: {[t; cols; nr; nc] [cols: cols; hand: gpu.buffer' {0.+x}' t[cols]; n: nr; t: `tbl; s: ,nr; lay: `planar]}
gpu.holdTI: {[t; cols; nr; nc] flat: 0. + ,/ + {0. + x}' t[cols]; [cols: cols; hand: gpu.buffer flat; n: nr; t: `tbl; s: ,nr; lay: `il; nc: nc]}
gpu.fetchN:   {[n;d] n # gpu.read[d`gpu]}

/ Solid-color fragment uniforms (44 floats matching the built-in fill shader FragUniforms).
/ r,g,b,a in [0,1].  Returns a flat F vector.
gpu.solid: {[r;g;b;a] ,/(1. 0. 0. 0.;0. 1. 0. 0.;0. 0. 1. 0.;1. 0. 0. 0.;0. 1. 0. 0.;0. 0. 1. 0.;r,g,b,a;r,g,b,a;1e10 1e10 1. 1.;0. 0. 0. 0.;0. 0. 0. 0.)}
