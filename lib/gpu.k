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
/ Vertex pulling (kk2 §5): the vertex shader (shader.vertexPull) reads RESIDENT
/ storage buffers indexed by gl_VertexIndex — no vertex buffer, no per-frame upload.
/ mesh.compilePull builds the pipeline (nbuf storage buffers inferred from the shader);
/ mesh.drawPull binds resident buffer handles (in binding order) and draws `count`
/ vertices straight from the device.  e.g.  mesh.drawPull[p; (Pbuf;Nbuf); 3*nTri]
mesh.compilePull: so 2: (`gpuMeshPull;  2)   / (vtx_I; frg_I) → handle : vertex-pull pipeline
gpuDrawPull0:     so 2: (`gpuDrawPull;  3)   / (pipe; bufHandles_I; count) → 0
mesh.drawPull: {[pipe; bufs; count] gpuDrawPull0[pipe; `i$bufs; count]}
mesh.drawU:    so 2: (`gpuDrawMeshU; 3)   / (verts_F; handle; uni_F) → 0 : draw mesh + per-draw uniform block (8 vec4 slots; see shader.vertexU)
gpuTexture0:   so 2: (`gpuTexture;  2)   / ((w;h;comp)_I; data_I) → texHandle : upload an image to a sampled GPU texture
/ Textured draws are retained-only: mesh.upload the geometry to a persistent
/ buffer once, then mesh.drawGeomT it each frame with only the uniform+textures
/ (see shader.fragmentTexN; image k = binding k, sample[k;uv]).
mesh.upload:    so 2: (`gpuUploadMesh; 2)  / (verts_F; meshHandle) → geomHandle : geometry → persistent vertex buffer
gpuDrawGeomT0: so 2: (`gpuDrawGeomT;  3)  / (geom; uni_F; texHandles_I) → 0 : draw retained geom + uniform + textures
mesh.drawGeomT: {[geom; uni; texs] gpuDrawGeomT0[geom; uni; texs]}
/ Upload an image dict (`width`height`comp`data, e.g. from image.read) as a texture.
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
gpu.hold:     {[x] f: gpu.flat x; [gpu: gpu.buffer[0.+f]; t: `f; n: #f; s: %x]}
gpu.holdInto: {[d;x] gpu.write[d`gpu; 0.+gpu.flat x]; d}
gpu.fetch:    {[d] r: (d`n) # $[(d`t)~`i; gpu.readI d`gpu; gpu.read d`gpu]; $[1 < #d`s; (d`s)#r; r]}
/ Place a k table as a STRUCTURED buffer (kk2 §2.5): one resident buffer per column
/ (planar/splayed layout), the descriptor carrying the column names + handles so
/ kk.compile can bind only the columns a kernel reads. `t`c` on the CPU already IS
/ the column, so the same lambda runs host-side unchanged.
gpu.holdT: {[t] cols: !t; nr: #t cols 0; [cols: cols; hand: gpu.buffer' {0.+x}' t[cols]; n: nr; t: `tbl; s: ,nr]}
gpu.fetchN:   {[n;d] n # gpu.read[d`gpu]}

/ ── kk.compile — idiomatic whole-array lambda on placements (kk2 §2, incr 5) ──
/ Milestone 2 (elementwise): kk.compile[fn; descriptors] compiles a whole-array
/ lambda in implicit-param form ({2.*x}, {x+y}, {(x+y)*z}) to a per-thread map
/ (dye's shader.map), dispatches it over the placements (one thread per element),
/ and returns an OUTPUT descriptor — so `8: kk.compile[{2.*x}; ,a]` reshapes the
/ result exactly like any placed array. The pipeline is cached by (lambda source;
/ #inputs); the output buffer is padded to the ×64 grid so stray stores land in
/ padding (descriptor n/s stay the real extent). Non-elementwise bodies (gather,
/ amend, adverbs) are rejected by kkClassify with the offending verb named — the
/ later milestones (index-buffer gather, scatter, stencil) will accept them.
kkPad: {[n] 64 * 1 | `i$ (n+63) div 64}
kkCache:: ()!()
kkMiss: {[fn;nIn;key] p: gpu.compileCompute[shader.map[fn;nIn]; nIn+1]; kkCache[key]:: p; p}
/ Reject: signal an error (monadic ! on the message string) instead of warning to
/ stdout + returning !0 — kk.compile now fails loudly like any primitive.
kkWarn: {[bad;nIn] !"kk.compile: ",$[3<nIn; "more than 3 inputs unsupported"; "unsupported verb/kind ",$bad]," (elementwise subset: arith/math over x/y/z)"}
/ Key is a SYMBOL, not a string: `str in !dict` runs char-wise (a string is a char
/ vector, not an atom) and `$[]` reads the resulting non-empty vector as true — so
/ a string key makes every cache probe a false hit. Symbols are atoms → scalar in.
kkRun: {[fn;args;nIn]
  key:  `$ ($fn),"|",($nIn)
  pipe: $[key in !kkCache; kkCache key; kkMiss[fn;nIn;key]]
  a0: args 0; n: a0`n; sh: a0`s
  ob: gpu.buffer[(kkPad n)#0.]
  ih: {[d] d`gpu}' args
  gpu.dispatch[pipe; ih,ob; n]
  [gpu: ob; t: `f; n: n; s: sh]}
/ ── Gather path (kk2 §2.4-3): x@y → out[d] = x[y[d]] ─────────────────────────
/ A param used as the LEFT of @ is a gather SOURCE (`buf, indexed); every other
/ param is an `elem index (auto-loaded at d). All args are placements passed
/ positionally as x/y/z; the output length = the first index's length. Pipeline
/ cached by (source|g|#inputs). (Host-vector auto-upload of free names + the
/ +/x@W matrix reduce are the next sub-steps; here both operands are placed.)
kkGMiss: {[fn;bufN;elemN;nb;key] p: gpu.compileCompute[shader.gmap[fn;bufN;elemN]; nb+1]; kkCache[key]:: p; p}
kkGath: {[fn;args;nIn]
  src:   kkGathSrc[]                        / names left-of-@ (Cst set by kk.compile's lamOf)
  pn:    nIn # `x`y`z
  bufN:  pn @ & pn in src
  elemN: pn @ & ~ pn in src
  na:    pn ! args                          / param name → its descriptor
  nb:    #args
  key:   `$ ($fn),"|g|",($nIn)
  pipe:  $[key in !kkCache; kkCache key; kkGMiss[fn;bufN;elemN;nb;key]]
  i0:    na elemN 0                         / the primary index vector → output extent
  n:     i0`n
  ob:    gpu.buffer[(kkPad n)#0.]
  / Index the dict in kkGath's scope FIRST, then map handles — the inner lambda
  / can't close over `na` (ink lambdas don't capture parent locals).
  bufH:  {[d] d`gpu}' na bufN
  elemH: {[d] d`gpu}' na elemN
  gpu.dispatch[pipe; bufH,elemH,ob; n]
  [gpu: ob; t: `f; n: n; s: i0`s]}

/ +/x@W matrix gather-reduce: src (left-of-@) and mat (the k×n index matrix, right-
/ of-@) are both `buf; k,n come from mat's descriptor shape and are baked into the
/ kernel (GRk/GRn → xRedGather), so the cache key carries them. Output length = n.
/ elemNames must be an empty SYMBOL vector (0#`), not !0: joining `x`y with an
/ empty INT vector upcasts to a boxed general list and breaks the env dict lookup.
kkGMMiss: {[fn;ops;k;n;key] GRk::k; GRn::n; p: gpu.compileCompute[shader.gmap[fn;ops;0#`]; (#ops)+1]; kkCache[key]:: p; p}
/ Resolve a gather operand NAME → its device descriptor: a param (x/y/z) reads the
/ passed placement; any other name is a host global numeric vector/matrix that gets
/ auto-uploaded read-only (kk2 §2.1-2), so walk.k's `W`,`I` can travel as globals.
/ `. nm` is the value of the global named nm; gpu.hold flattens+records its shape.
/ `gpu.hold . nm` would parse `.` as DYADIC (gpu.hold on its left) → apply, not
/ value; take the value in its own statement so `.` is monadic, then upload.
kkUpload: {[nm] v: . nm; gpu.hold v}
kkResolve: {[nm;na;pn] $[nm in pn; na nm; kkUpload nm]}
kkGathMat: {[fn;args;nIn]
  ops: kkMatOperands[]                      / (srcName; matName), both `buf
  pn:  nIn # `x`y`z
  na:  pn ! args
  / two operands, unrolled — an each-lambda here couldn't see na/pn (no closure).
  sd:  kkResolve[ops 0; na; pn]
  md:  kkResolve[ops 1; na; pn]
  descs: (sd; md)                           / descriptors for (src; mat)
  msh: md`s                                 / the matrix's (k;n) shape
  k:   msh 0; n: msh 1
  GRk:: k; GRn:: n
  key: `$ ($fn),"|m|",($k),"|",($n)
  pipe: $[key in !kkCache; kkCache key; kkGMMiss[fn;ops;k;n;key]]
  ob:  gpu.buffer[(kkPad n)#0.]
  bufH: {[d] d`gpu}' descs                  / (src; mat) handles in binding order
  gpu.dispatch[pipe; bufH,ob; n]
  [gpu: ob; t: `f; n: n; s: ,n]}
/ Amend-scatter @[x;I;:;v]: one thread per interior index; out[I[d]] = v (v reads
/ x through the neighbour matrix W). I is padded to the ×64 grid with a sentinel
/ index (= full length) that lands in out's padding, so over-dispatched threads
/ don't clobber a live cell. Output = a COPY of x with the I positions rewritten
/ (a single Jacobi step); iterate with kk.loop for the ping-pong solve.
kkAMiss: {[fn;src;mat;idx;k;n;key] GRk::k; GRn::n; p: gpu.compileCompute[shader.amend[fn;src;mat;idx]; 4]; kkCache[key]:: p; p}
/ Prep the padded I buffer + a fresh out buffer that copies xbuf and reserves a
/ sentinel-padding tail. Returns (idBuf; outBuf; xn). n=#I, xn=full length.
kkAmendBufs: {[idxName; xbuf; xn; n]
  iv:  . idxName
  idBuf: gpu.buffer[(`f$ iv) , (kkPad[n] - n) # `f$ xn]
  outBuf: gpu.buffer[(gpu.read xbuf) , 64 # 0.]
  (idBuf; outBuf)}
kkAmendPipe: {[fn;srcName;matName;idxName;k;n]
  key: `$ ($fn),"|a|",($k),"|",($n)
  $[key in !kkCache; kkCache key; kkAMiss[fn;srcName;matName;idxName;k;n;key]]}
kkAmend: {[fn;args;nIn]
  info: kkAmendInfo[]                       / (srcName; idxName)
  srcName: info 0; idxName: info 1
  matName: (kkMatOperands[]) 1              / W from the inner x@W gather
  pn: nIn # `x`y`z
  na: pn ! args
  sd: kkResolve[srcName; na; pn]            / x0 placement (full array)
  md: kkResolve[matName; na; pn]            / W host global (k;n)
  msh: md`s; k: msh 0; n: msh 1
  GRk:: k; GRn:: n
  pipe: kkAmendPipe[fn;srcName;matName;idxName;k;n]
  xn: sd`n
  bufs: kkAmendBufs[idxName; sd`gpu; xn; n]
  idBuf: bufs 0; out: bufs 1
  gpu.dispatch[pipe; (sd`gpu; md`gpu; idBuf; out); n]
  [gpu: out; t:`f; n: xn; s: sd`s]}

/ Scatter-add @[x;I;+;v]: one thread per index; acc[I[d]] += v atomically. x is
/ expected zero-initialised; I is padded with a sentinel into acc's padding tail so
/ over-dispatched threads add harmlessly. v is a constant or a single value vector
/ (bindings after acc,I). n=#I threads.
/ TWO lowerings (§7): when gpu.caps reports atomicFadd (native f32 buffer atomics),
/ acc is an f32 accumulator hit by OpAtomicFAddEXT → the value adds WITHOUT integer
/ truncation (weighted float accumulation, no fixed-point scaling), result tagged
/ `f (gpu.fetch reads floats). When caps=0 (or kkScatForceI is set), the i32
/ fixed-point path is used and the result is tagged `i (gpu.readI). Set kkScatForceI
/ to force the integer path (exact integer histograms / testing the fallback).
kkScatForceI:: 0                          / 1 → always use the i32 path
kkFA:: -1                                 / cached caps.atomicFadd (−1 = not yet queried)
kkQFA:  {[] kkFA:: `i$ (gpu.caps[0])`atomicFadd; kkFA}
kkUseFA: {[] $[kkScatForceI; 0; kkFA > -1; kkFA; kkQFA[]]}
kkSMiss: {[fn;vbn;fa;key] p: gpu.compileCompute[$[fa; shader.scataddf[fn;vbn]; shader.scatadd[fn;vbn]]; 2 + #vbn]; kkCache[key]:: p; p}
kkIvals: {[idxName; idd; pn] $[idxName in pn; gpu.read idd`gpu; `f$ . idxName]}
kkScatAdd: {[fn;args;nIn]
  info: kkScatInfo[]; accName: info 0; idxName: info 1
  vbn: kkScatVbufs[accName; idxName]        / value-vector operand names in v (0 or 1)
  pn: nIn # `x`y`z
  na: pn ! args
  ad: kkResolve[accName; na; pn]            / accumulator placement (zero-inited)
  idd: kkResolve[idxName; na; pn]           / I index
  n: idd`n; an: ad`n
  GRk:: 0; GRn:: n
  fa: kkUseFA[]                             / native f32 atomics available (and not forced off)?
  key: `$ ($fn),"|s|",($#vbn),$[fa;"f";"i"]
  pipe: $[key in !kkCache; kkCache key; kkSMiss[fn;vbn;fa;key]]
  ivals: kkIvals[idxName; idd; pn]
  idBuf: gpu.buffer[ivals , (kkPad[n] - n) # `f$ an]     / sentinel = an → acc padding
  acc: gpu.buffer[(an + 64) # 0.]           / accumulator (zeros) + slack; f32 or i32 by fa
  vHnd: $[0=#vbn; !0; ,(kkResolve[vbn 0; na; pn])`gpu]
  gpu.dispatch[pipe; (acc; idBuf), vHnd; n]
  [gpu: acc; t:$[fa;`f;`i]; n: an; s: ad`s]}
/ kk.loop[f; x0; niter] — iterate an amend `f:{@[x;I;:;v]}` niter times on the GPU
/ with a ping-pong: two full-size buffers, each pass reads one and writes the other
/ (Jacobi needs the previous sweep's values). Runs in ONE encoder (gpu.dispatchLoop,
/ no per-step host sync). Both buffers start as a copy of x0 so the non-interior
/ (boundary) cells carry through unchanged. Returns the result descriptor.
kk.loop: {[f; x0; niter]
  lamOf f
  info: kkAmendInfo[]; srcName: info 0; idxName: info 1
  matName: (kkMatOperands[]) 1
  md: kkUpload matName                      / W (k;n) host global
  msh: md`s; k: msh 0; n: msh 1
  GRk:: k; GRn:: n
  pipe: kkAmendPipe[f;srcName;matName;idxName;k;n]
  xn: x0`n
  x0v: (gpu.read x0`gpu) , 64 # 0.          / initial state + sentinel padding
  A: gpu.buffer[x0v]; B: gpu.buffer[x0v]
  iv: . idxName
  idBuf: gpu.buffer[(`f$ iv) , (kkPad[n] - n) # `f$ xn]
  gpu.dispatchLoop[pipe; (A;md`gpu;idBuf;B); (B;md`gpu;idBuf;A); n; niter]
  / pass 0 (config A) writes B, pass 1 (config B) writes A, … → odd niter lands in
  / B, even in A (verified against a single f-step).
  res: $[0 = niter mod 2; A; B]
  [gpu: res; t:`f; n: xn; s: x0`s]}

/ kk.converge[f; x0; tol; maxIter] — device-side converge (kk2 §6): iterate the
/ amend sweep `f` in batches on the GPU, and every CVstride sweeps measure the
/ change `|/abs(new-old)` with the whole-buffer reduce; stop once it drops below
/ `tol` (or `maxIter` sweeps elapse). This replaces walk.k's bit-fixpoint grind
/ (`f/`, a fixed 30k `kk.loop`) with a tolerance the solver decides — the device
/ does the sweeps AND the max-abs-diff reduce; the host only reads one float per
/ batch (periodic readback). CVstride is even, so a batch always lands back in A.
/ State carried through the while-adverb is (sweepsDone; lastMaxDiff); the shared
/ context lives in CV* globals (ink lambdas don't close over kk.converge's locals).
CVa:: 0; CVsnap:: 0; CVpipe:: 0; CVca:: (); CVcb:: (); CVn:: 0
CVstride:: 100; CVtol:: 0.; CVmax:: 0; CVcur:: (); CVsnp:: (); CVxn:: 0; CVs:: ()
cvCond: {[s] ((s 1) > CVtol) & (s 0) < CVmax}
cvBody: {[s]
  gpu.write[CVsnap; gpu.read CVa]                 / checkpoint current state
  gpu.dispatchLoop[CVpipe; CVca; CVcb; CVn; CVstride]   / CVstride sweeps → back in A
  dd: kk.compile[{abs[x-y]}; (CVcur; CVsnp)]      / elementwise |Δ| over the batch
  ((s 0) + CVstride; kk.max dd)}                  / (sweepsDone; maxΔ)
kk.converge: {[f; x0; tol; maxIter]
  lamOf f
  info: kkAmendInfo[]; srcName: info 0; idxName: info 1
  matName: (kkMatOperands[]) 1
  md0: kkUpload matName                      / W (k;n) host global
  msh: md0`s; k: msh 0; n: msh 1
  GRk:: k; GRn:: n
  pipe: kkAmendPipe[f;srcName;matName;idxName;k;n]
  xn: x0`n
  x0v: (gpu.read x0`gpu) , 64 # 0.
  A: gpu.buffer[x0v]; B: gpu.buffer[x0v]; snap: gpu.buffer[x0v]
  iv: . idxName
  idBuf: gpu.buffer[(`f$ iv) , (kkPad[n] - n) # `f$ xn]
  CVa:: A; CVsnap:: snap; CVpipe:: pipe; CVn:: n
  CVca:: (A; md0`gpu; idBuf; B); CVcb:: (B; md0`gpu; idBuf; A)
  CVtol:: tol; CVmax:: maxIter; CVxn:: xn; CVs:: x0`s
  CVcur:: [gpu: A; t: `f; n: xn; s: x0`s]
  CVsnp:: [gpu: snap; t: `f; n: xn; s: x0`s]
  fin: cvCond cvBody/ (0; tol + 1.)               / while maxΔ>tol & sweeps<maxIter
  CVlast:: fin                                    / (sweepsDone; finalMaxΔ) — observability
  [gpu: A; t: `f; n: xn; s: x0`s]}
/ Placed-table map: bind only the columns the body reads (kk2 §2.5). The referenced
/ column names come from the CST (kkTableColNames); their handles are looked up by
/ position in the table descriptor. Output is a plain f-array descriptor.
kkTMiss: {[fn;tn;cn;nc;key] p: gpu.compileCompute[shader.table[fn;tn;cn]; nc+1]; kkCache[key]:: p; p}
kkTable: {[fn;args;nIn]
  td: args 0
  cn: kkTableColNames[]                      / distinct columns actually read
  tn: kkTableName[]
  nc: #cn
  key: `$ ($fn),"|t|",(","/$'cn)
  pipe: $[key in !kkCache; kkCache key; kkTMiss[fn;tn;cn;nc;key]]
  n: td`n
  colH: (td`hand) (td`cols) ? cn             / handles for the referenced columns
  ob: gpu.buffer[(kkPad n)#0.]
  gpu.dispatch[pipe; colH, ob; n]
  [gpu: ob; t:`f; n: n; s: ,n]}
kk.compile: {[fn; args]
  nIn: #args
  lamOf fn                                  / set Cst for the gather scan / classify
  isTbl: $[0<nIn; `tbl ~ (args 0)`t; 0]
  $[isTbl;           kkTable[fn;args;nIn]
    kkIsScatAdd[];   kkScatAdd[fn;args;nIn]
    kkIsAmend[];     kkAmend[fn;args;nIn]
    kkIsMatReduce[]; kkGathMat[fn;args;nIn]
    kkHasAt[];       kkGath[fn;args;nIn]
    kkMap[fn;args;nIn]]}
kkMap: {[fn;args;nIn]
  bad: kkClassify fn
  $[(bad~`) & ~3<nIn; kkRun[fn;args;nIn]; kkWarn[bad;nIn]]}

/ ── Whole-buffer reduce (kk2 §6): +/d over a placement → a host scalar ─────────
/ Two-stage fallback (dye's shader.reduce): stage 1 dispatches P grid-strided
/ threads → P partials; stage 2 folds the P partials on one thread → the scalar,
/ read back at 8:. op ∈ `sum`max`min`prod (identity+combine baked into the kernel).
/ P (partial count) is a multiple of the 64-wide workgroup. n is passed through the
/ uniform as an f32, so this is exact only up to 2^24 elements (the usual f32 cliff).
/ Float reduction reorders the sum, so the result matches CPU +/ to a relative
/ tolerance, not bit-for-bit (integer/exact reductions do match).
kkRedP:: 256
kkRedMiss: {[op;key] p: gpu.compileComputeU[shader.reduce[op]; 2]; kkCache[key]:: p; p}
kkRedPipe: {[op]
  key: `$ "reduce|",$op
  $[key in !kkCache; kkCache key; kkRedMiss[op;key]]}
/ Two-dispatch FALLBACK reduce (grid-strided serial per thread).
kkReduceFb: {[op; d]
  pipe: kkRedPipe op
  n: d`n
  P: kkRedP
  km: 1 | `i$ (n + P - 1) div P
  part: gpu.buffer[P # 0.]
  u1: gpu.uniform[(`f$n; `f$P; `f$km; 0.)]
  gpu.dispatch[pipe; (d`gpu; part; u1); P]
  res: gpu.buffer[64 # 0.]
  u2: gpu.uniform[(`f$P; 1.; `f$P; 0.)]
  gpu.dispatch[pipe; (part; res; u2); 1]
  *gpu.read res}
/ Subgroup fast path (§6): stage 1 dispatches G workgroups × S (subgroup) lanes and
/ folds each workgroup with one OpGroupNonUniformFAdd → G partials; stage 2 folds the
/ G partials with a single workgroup. Same numeric contract as the fallback (reordered
/ float sums → CPU parity to a tolerance). Selected when gpu.caps sgArith is set.
kkRedSgMiss: {[op;S;key] p: gpu.compileComputeU[shader.reduceSg[op;S]; 2]; kkCache[key]:: p; p}
kkRedSgPipe: {[op;S] key: `$ "reduceSg|",($op),"|",($S); $[key in !kkCache; kkCache key; kkRedSgMiss[op;S;key]]}
kkReduceSg: {[op; d; S]
  pipe: kkRedSgPipe[op; S]
  n: d`n
  G: kkRedP                                / workgroups (partials)
  T1: G*S                                  / stage-1 total threads (grid-stride span)
  km1: 1 | `i$ (n + T1 - 1) div T1
  part: gpu.buffer[G # 0.]
  u1: gpu.uniform[(`f$n; `f$T1; `f$km1; 0.)]
  gpu.dispatch[pipe; (d`gpu; part; u1); T1]     / T1 threads, LocalSize S → G workgroups
  res: gpu.buffer[64 # 0.]
  km2: 1 | `i$ (G + S - 1) div S
  u2: gpu.uniform[(`f$G; `f$S; `f$km2; 0.)]
  gpu.dispatch[pipe; (part; res; u2); S]        / S threads → one workgroup → scalar
  *gpu.read res}
/ Cache the device caps once (needs a live device — queried on first reduce).
kkCaps:: ()
kkGetCaps: {[] $[0=#kkCaps; kkCaps:: gpu.caps[0]; 0]; kkCaps}
kkRedForceFb:: 0                            / force the fallback (test both paths)
kk.reduce: {[op; d]
  c: kkGetCaps[]
  $[(~kkRedForceFb) & c`sgArith; kkReduceSg[op; d; c`subgroup]; kkReduceFb[op; d]]}
kk.sum:  {[d] kk.reduce[`sum;  d]}
kk.max:  {[d] kk.reduce[`max;  d]}
kk.min:  {[d] kk.reduce[`min;  d]}
kk.prod: {[d] kk.reduce[`prod; d]}

/ ── Prefix scan +\d (kk2 tier-2): inclusive running combine over a placement ────
/ Three dispatches over P=256 contiguous chunks (chunk = ceil(n/P)): scanBlock does
/ each chunk's local scan + total, scanPartials exclusive-scans the P totals, and
/ addOffset folds each chunk's offset back in. out is padded to P*chunk (stores stay
/ in-bounds, chunks disjoint). Returns a placement (like the input); op selects the
/ running combine. As with kk.reduce, n rides an f32 uniform (exact to 2^24); float
/ scans reorder within a chunk so results match CPU +\ to a relative tolerance.
kkScanBMiss: {[op;key] p: gpu.compileComputeU[shader.scanBlock[op]; 3]; kkCache[key]:: p; p}
kkScanPMiss: {[op;key] p: gpu.compileCompute[shader.scanPartials[op]; 2]; kkCache[key]:: p; p}
kkScanAMiss: {[op;key] p: gpu.compileComputeU[shader.addOffset[op]; 2]; kkCache[key]:: p; p}
kkScanPipe: {[which;op;miss] key: `$ which,"|",$op; $[key in !kkCache; kkCache key; miss[op;key]]}
kk.scan: {[op; d]
  n: d`n
  P: kkRedP
  ck: 1 | `i$ (n + P - 1) div P
  m: P*ck
  pB: kkScanPipe["scanB";op;kkScanBMiss]
  pP: kkScanPipe["scanP";op;kkScanPMiss]
  pA: kkScanPipe["scanA";op;kkScanAMiss]
  ob: gpu.buffer[m # 0.]
  bt: gpu.buffer[P # 0.]
  bo: gpu.buffer[P # 0.]
  u1: gpu.uniform[(`f$n; `f$ck; 0.; 0.)]
  gpu.dispatch[pB; (d`gpu; ob; bt; u1); P]
  gpu.dispatch[pP; (bt; bo); P]
  u2: gpu.uniform[(`f$ck; 0.; 0.; 0.)]
  gpu.dispatch[pA; (ob; bo; u2); P]
  [gpu: ob; t: `f; n: n; s: d`s]}
kk.sums:  {[d] kk.scan[`sum; d]}
kk.maxs:  {[d] kk.scan[`max; d]}
kk.mins:  {[d] kk.scan[`min; d]}

/ ── Compaction &mask (kk2 tier-2): indices where the mask is true ─────────────
/ The monadic `&` (Where) on a placed 0/1 mask: inclusive-scan the mask for output
/ positions, reduce it for the true count, then one scatter dispatch writes each true
/ index into its slot (shader.compact). Returns a placement of the (float) indices,
/ length = true count — so `kk.where mask` mirrors `&mask` on the CPU. Value
/ compaction `x@&mask` composes for free: kk.compile[{x@y}; (x; kk.where mask)].
kkWhereMiss: {[key] p: gpu.compileComputeU[shader.compact[]; 3]; kkCache[key]:: p; p}
kk.where: {[d]
  n: d`n
  incl: kk.sums d                                / inclusive prefix scan of the mask
  total: `i$ kk.sum d                            / count of trues (syncs → incl is final)
  pipe: $[`compact in !kkCache; kkCache `compact; kkWhereMiss[`compact]]
  ob: gpu.buffer[(total + 64) # 0.]              / true-count elements + sentinel slack
  u:  gpu.uniform[(`f$n; `f$total; 0.; 0.)]
  gpu.dispatch[pipe; (d`gpu; incl`gpu; ob; u); n]
  [gpu: ob; t: `f; n: total; s: ,total]}

/ Solid-color fragment uniforms (44 floats matching the built-in fill shader FragUniforms).
/ r,g,b,a in [0,1].  Returns a flat F vector.
gpu.solid: {[r;g;b;a] ,/(1. 0. 0. 0.;0. 1. 0. 0.;0. 0. 1. 0.;1. 0. 0. 0.;0. 1. 0. 0.;0. 0. 1. 0.;r,g,b,a;r,g,b,a;1e10 1e10 1. 1.;0. 0. 0. 0.;0. 0. 0. 0.)}
