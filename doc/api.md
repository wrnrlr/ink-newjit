## Libraries

### Audio Library
- `audio.play "boop.wav"` - one-shot UI/SFX
- `audio.load "gun.wav"`a controllable voice
- `audio.start h`          (re)trigger it
- `audio.music "song.mp3"` streamed, looping background music
- `audio.pos[h; 3 0 -2]`   place it in 3D; move the listener
- `audio.listener 0 0 0` - with audio.listener each frame
- `audio.rec.start[]` - start the mic
- `s: audio.rec.read[]` - drain samples (call in your loop)
- `audio.save["take.wav"; audio.rec.channels[]; audio.rec.rate[]; s]`
- `clip: audio.decode "take.wav"` - load a file to a PCM dict

### Crypto Library
Thin bindings over Zig's `std.crypto` (`lib/crypto.k`, build `zig build crypto`).
Everything is bytes (C vectors), so primitives compose.
- Hashes: `crypto.md5` `sha1` `sha224` `sha256` `sha384` `sha512` `sha3256`
  `sha3512` `blake2b` `blake2b512` `blake3` — `msg → raw digest`
- MAC: `crypto.hmac[key;msg]` (SHA-256), `crypto.hmac512[key;msg]`
- KDF: `crypto.hkdf[salt;ikm;info]` (SHA-256), `crypto.hkdf512[…]`,
  `crypto.pbkdf2[password;salt;rounds]`
- AEAD (encrypt → `ct||tag`, decrypt → plaintext or error `'`):
  `crypto.encrypt`/`decrypt` (XChaCha20-Poly1305, key 32 / nonce 24),
  `crypto.aesEncrypt`/`aesDecrypt` (AES-256-GCM, key 32 / nonce 12)
- Ed25519: `crypto.keypair seed(32) → pub(32)||secret(64)`,
  `crypto.sign[secret;msg]`, `crypto.verify[public;sig;msg]`
- X25519: `crypto.x25519pub secret(32)`, `crypto.x25519[secret;public] → shared`
- Random & encoding: `crypto.random n`, `crypto.hex`/`unhex`, `crypto.b64`/`unb64`,
  `crypto.equal[a;b]` (constant-time)

### Compression Library
- `compress.deflate`/`inflate` — raw DEFLATE
- `compress.gzip`/`gunzip` — gzip container (RFC 1952)
- `compress.zlib`/`unzlib` — zlib container (RFC 1950)
- `compress.crc32 bytes`, `compress.adler32 bytes` — i32 checksums

ZIP archives via `std.zip` + flate (`lib/zip.k`, build `zig build zip`).
Store + deflate, non-encrypted, non-zip64.
- `zip.list "a.zip"` → table `[name;size;csize;method;crc]`
- `zip.read "a.zip"` → dict name→decompressed bytes
- `zip.entry["a.zip"; name]` → one entry's bytes (error if absent)
- `zip.write["out.zip"; names; datas]` → create archive → `1b`

### Data Library
- `csv.read`
- `csv.write`
- `json.read`
- `json.write`
- `parquet.read`
- `parquet.write`

### Image Library
- `image.read[path]`
- `image.write[path;img]`
- `image.scale[img;w;h]`

### Text Processing
- `regex`

### Graphics Library
Ink's GPU stack is three layers that load on demand:
`lib/gpu.k` (the native `libgpu.dylib` bindings — raw Vulkan via MoltenVK), `lib/dye.k`
(the **dye** shader compiler that turns ink lambdas into SPIR-V, backed by the
pure instruction stencils in `lib/spirv.k`), and a set of higher-level helpers
(`camera.k`, `pbr.k`, `font.k`, `color.k`).

#### Window & event loop (`lib/gpu.k`)
- `window.run[loop; cfg]` — open a window and call `loop[props]` every frame
  (blocking). `props` is a dict: `` `width`height`mx`my`time `` plus `` `events ``,
  a **table** of input events since the last frame. Event columns: `kind`
  (`` `text`key`mouse`scroll ``), `code`, `mods` (1=shift 2=ctrl 4=alt 8=super),
  `down` (1=press/0=release), `x`/`y`, `amt` (scroll delta). Track held keys
  yourself (see `camera.k`). Unused cells are nulls — filter them.
- `gpu.computeRun[fn]` — headless one-shot: create a device, call `fn` once, tear
  it down. Stash results in a global from inside `fn`.

#### 2D drawing
- `gpu.fill[verts; frag]` — draw triangles with the built-in shader. `verts` is a
  flat `F` of `[x,y,u,v]` per vertex; `frag` is a 44-float uniform block.
- `gpu.solid[r;g;b;a]` — build a solid-color `frag` block (channels in `[0,1]`).
- `gpu.tessellate[pts]` — triangulate a polygon `F` to a vertex buffer (NaN x/y
  pairs separate contours to cut holes).

#### Meshes & 3D
3-D meshes render exclusively by VERTEX PULLING — one pipeline API. (The old
attribute path — `mesh.compile`/`draw`/`drawU`/`upload`/`drawGeomT` with
`shader.vertex`/`vertexU` — was retired; geometry, per-frame uniforms and dynamic
meshes all ride in resident storage buffers instead.)
- `mesh.compilePull[vtx; frg]` / `mesh.drawPull[pipe; bufs; count]` — vertex
  pulling: the vertex shader (`shader.vertexPull`) reads resident storage
  buffers by `gl_VertexIndex`; instancing is an index computation
  (`inst: floor[vid % NV]`, see `demo/scene.k`). Per-frame uniforms ride in one
  of those storage buffers (overwrite it with `gpu.write`), so no uniform block
  is needed.
- `mesh.drawPullT[pipe; bufs; count; texs]` — a pulled draw that also samples
  textures at `@group(1)` (a `shader.fragmentTexN` fragment); `texs` = `gpuTexture`
  handles. `demo/earth.k` is fully pulled + textured this way.
- `lib/pbr.k` — a physically-based `pbrVtx` / `PbrFragment` shader pair;
  `lib/camera.k` — orbit camera (`CamNew`, `CamUpdate[c;props]`) folding one
  frame of input into a camera-state dict (WASD pan, scroll zoom, right-drag
  rotate/tilt).

#### Textures
- `texture.upload[img]` — upload an image dict (`` `width`height`comp`data ``,
  e.g. from `image.read`) as a sampled GPU texture. In a fragment shader,
  `sample[k; uv]` reads texture `k` (see `shader.fragmentTexN`).

#### Compute
- `gpu.runShader[spirv; in]` / `gpu.runShader2[spirv; in1; in2]` — one-shot
  compute with host round-trip.
- Resident buffers keep data on the GPU across dispatches (iterative solvers):
  `gpu.buffer[F]` → handle, `gpu.write[buf; F]`, `gpu.read[buf]` / `gpu.readI`,
  `gpu.uniform[vec4]`.
- `gpu.compileCompute[spirv; nbind]` / `gpu.compileComputeU[spirv; nStorage]`
  cache a pipeline; `gpu.dispatch[pipe; bufs; nThreads]` runs it with no
  readback. `gpu.dispatchLoop[pipe; bufsA; bufsB; nThreads; reps]` batches N
  ping-pong passes into a single encoder (Jacobi / red-black SOR).

#### The dye shader compiler (`lib/dye.k`)
`dye` compiles ink lambdas to SPIR-V word lists (int lists) you feed to the
pipeline builders above. Types are symbols like `` `f32`v3`v4 ``.
- **Fragment:** `shader.fragment[ioTypes; fn]`, `shader.fragmentTex[ioTypes; fn]`
  / `shader.fragmentTexN[ioTypes; nTex; fn]` (sampled textures). All paths compile
  through the neutral IR and const-fold + DCE when `xOpt=1` (the default).
- **Vertex:** `shader.vertexPull[varyTypes; fn]` — a kernel-shaped
  `{[buf0;…; vid] (posV4; vary0;…)}`: the last param is `gl_VertexIndex`, every
  other is a resident storage buffer read at that index (geometry + any uniforms).
- **Compute:** `shader.kernel[fn]` — the general kernel with the binding table
  INFERRED from the lambda (params fed to `scatterAdd`/`iget`/`iset` are i32
  accumulators and must come first; the LAST param is the thread index; the
  rest are f32 buffers). `gpu.pipeline[fn]` compiles lambda → SPIR-V → cached
  pipeline in one call. Explicit forms remain: `gpu.kernel[fn;nAcc;nBuf]`,
  `shader.compute` / `shader.computeU` / `shader.compute2`.
- **Stencil/scatter kernels:** `shader.stencil` / `shader.stencilU` /
  `shader.stencilIP` and `shader.scatter` — buffer-gather + in-kernel bounded
  loops for GPU-resident numerics (the basis of `lib/nn.k`).

- **CPU backend (`lib/bits.k`):** `bits.run[fn; nAcc; nBuf; bufs; count]` runs the
  SAME kernel lambda on the CPU by interpreting dye's neutral IR node-for-node
  (returns the mutated buffer list). One source, two lowerings — the basis of the
  `test/kkbits.k` cross-backend oracle (bits CPU vs `gpu.kernel` GPU). v1 covers the
  scalar compute subset (elementwise/select/gather + `rsum`/`rmax`/`ndo`/`whileL`).

The shader dialect adds vector literals, monadic math names, and `<=`/`>=`
peephole support on top of ink; extra GPU builtins include `pow min max dot
cross step mod clamp mix smoothstep floor fract sign tanh length normalize`.
A name that is not a param or local resolves to the HOST global's current
numeric-scalar value, baked in as a constant at kernel-compile time
(recompile to pick up changes; unknown names warn and bake NaN).
Gotchas: `|` is logical-or (not max) in shaders — use `max[0.;x]` for ReLU;
there is no `>=`, use `~(a<b)`. See `doc/design/dye.md` and `doc/design/kk.md`.

#### Fonts & color
- `lib/font.k` — native sfnt reader. `font.read "path"` → list of face dicts
  (keyed by table name). `font.scale[f;sz]`, `font.metrics[f;sz]`,
  `font.glyph[f;cp]` (codepoint → gid), `font.shape[f;s]` (string → gids),
  `font.outline[f;gid;sz]` / `font.outlines` → flat `F` contours to tessellate,
  `font.family`/`subfamily`/`fullName`.
- `lib/color.k` — `hsl2rgb`, `pct2rgb`, and the full OKLCH Tailwind palette as
  named constants (`Red500`, `Amber300`, …), each an `[r,g,b,a]` vector.

### Network Library
HTTP client over Zig's `std.http.Client` (`lib/http.k`, build `zig build http`).
For web/JSON APIs: https (TLS), redirects and gzip/deflate/zstd response
decompression are automatic.  Every call returns a dict `[status; headers; body]`
(`status` i, `headers` dict of lowercased name→value, `body` C) or an error `'`
if the request could not be completed.
- `http.get url`, `http.del url`, `http.head url`
- `http.post[url; body]`, `http.put[url; body]`, `http.patch[url; body]`
  (default `content-type: application/json`)
- `http.request[method; url; headers; body]` — headers are flat C name/value
  pairs `("accept";"application/json";…)`; `http.raw (method;url;headers;body)`
  is the underlying primitive
- Decode a JSON response with `json.parse r`body`
- Streaming: `http.stream[method; url; headers; body; {[line]…}]` calls the
  callback with each response line (newline stripped) as it arrives and returns
  `[status; headers]`.  Used for Server-Sent Events / LLM token streams.

### LLM Library
Chat + streaming for Anthropic and xAI (Grok) over the http + json modules
(`lib/llm.k`, pure k — no build step).  Keys come from the environment
(`ANTHROPIC_API_KEY`, `XAI_API_KEY`).  Streaming is built in: `llm.ask` prints
tokens live as they arrive and returns the full assistant text.
- `llm.anthropic model` / `llm.grok model` → a provider config dict
- `llm.ask[cfg; prompt]` — one-shot; streams live, returns the text
- `llm.turn[cfg; history; text]` (alias `llm.say`) — multi-turn; returns the
  history extended with the user + assistant turns (start from `()`)
- `llm.stream[cfg; messages]` — lower level; `messages` is a list of
  `[role;content]` dicts (`llm.msg[role;text]`)
- Agent (buffered tool-use loop, both providers): `llm.agent[cfg; tools; task]`.
  A tool is `llm.tool[name; desc; params; fn]` where `params` is a JSON-schema
  object (`llm.obj[properties; required]`, `llm.prop[type; desc]`) and `fn` is a
  k lambda `inputDict → resultString`.  The loop runs the model, dispatches any
  tool calls to your `fn`s, feeds results back, and returns the final text.
  `json.list` (a non-columnarising `json.parse`) makes the response arrays
  navigate as lists.
