# Changelog

## 2026-07-26
- **Syntax highlighting in `demo/edit.k`, driven by `parse` itself.** The editor is
  rebuilt on two new libraries and the Iosevka font.
  - **`lib/syntax.k` — configurable highlighting.** A highlighter is a function
    `codepoints → role index per codepoint`; a THEME maps each role
    (`num str sym bool dyad mono over scan assign bracket cond …`) to an rgba from
    `lib/color.k`'s Tailwind/OKLCh palette. Both halves swap: register another
    language with `syn.reg[name;fn]`, hand `syn.setTheme` another role→colour dict
    (`syn.themeDark` / `syn.themeLight` ship, matching the Zed extension's colours).
    `syn.runs` collapses the role vector into the runs a renderer draws.
  - **The ink highlighter has no lexer of its own.** `parse` returns the CST as a
    column table with CODEPOINT ranges, so a highlight is "paint each node's range,
    let children overwrite their parents" — whatever a container still owns is
    exactly its own punctuation (a call's `[`/`]`, an assignment's `:`, a fold's
    `/`). Valence comes from the tree, so `+` is purple in `1+2` and the rest falls
    out: `*` monadic in `*1 2 3`, `@` red in `@[x;i;:;v]`. `parse` tolerates
    half-typed source, so this re-runs on every keystroke; no second parser, no LSP
    round trip (and so no UTF-16 offsets). `syn.enc`/`syn.dec` bridge UTF-8 source
    text and codepoints.
  - **Adverbs are coloured by ARITY, not by glyph.** An adverb taking one left
    argument (`+/1 2 3` fold, `f'x` each, `24 60 60\n` encode) is an ordinary
    adverb; the DIGRAM forms that take two (seeded fold `10+/`, zip `x f'`, stencil
    `3 f'`, n-do `5 f/`, while `f f/`, seeded eachprior `10-':`, eachright `x f/:`)
    get their own colour — any of `' / \` can be either. In the CST that is exactly
    "the term sits in the dyadic verb slot", so it reads straight off `field`. The
    verb underneath follows: only plain Each applies its verb monadically, so `#`
    is dyadic in the zip `2 3#'"ab"` but monadic in `#'x`.
  - **`lib/rope.k` — a SumTree rope.** Text lives in a B-tree of ~64-codepoint
    chunks, each node carrying a `(codepoints; newlines)` summary, so offset→row,
    row→offset and line fetch are O(log n) descents. A leaf-local edit rewrites one
    chunk and pushes a summary delta up the parent chain; an edit that would
    over/underflow a leaf re-chunks and rebuilds bottom-up from the leaf list
    (O(#leaves), vectorised, re-using untouched chunks by reference).
  - **The editor**: Iosevka (a TTC — `font.read` returns every face), line-number
    gutter, current-line highlight, wheel scrolling, page up/down, sticky-column
    vertical motion, a status bar, `cmd+shift+=`/`cmd+shift+-` to change the font
    size, and `cmd+shift+T` (or F1) to flip the theme live.
  - **`slug.SCCAP` 262144 → 1048576 floats.** The old scene buffer stopped a text
    editor at ~600 glyphs — half a screen — and truncated silently; `sceneFlush`
    now clamps to capacity instead of overrunning.
- **Canvas text is ~125× cheaper per frame** (~310 ms → ~2.5 ms for a screenful of
  1392 glyphs), which is what made typing in the editor feel laggy. Two causes, both
  fixed in `lib/canvas.k` + `lib/slug.k`:
  - **A persistent glyph cache.** A glyph's banded curve data depends only on
    (face; size; gid), never on colour or position, so it is built once and reused
    instead of re-extracting the outline (`font.quads`) and re-binning it every frame.
    Face and size resolve to registry indices ONCE per `cnv.text` call, packed with the
    gid into an int cache key. The registries are keyed by face NAME: `?` cannot look up
    a face value (given a non-atomic right argument it vectorises over it instead of
    matching it whole) and `~` on two faces deep-compares the whole font, ~2 ms a go.
    Bounded, with a frame-start sweep, so animating text size recycles rather than leaks.
  - **`slug.addFillN`** appends a whole batch of pre-banded fills in ONE join. Adding
    a screenful of glyphs one at a time re-copied the accumulator each time — quadratic,
    ~170 ms of the old cost.
  Text now records less per glyph too: the clip-baked paint block is built once per
  `cnv.text` call rather than per glyph (`TXCOL`/`TXCLM`/`TXCLE`/`TXFACE`/`TXSZ` are gone).
- **`demo/edit.k` lays out in framebuffer pixels.** `props`width/height/mx/my` are
  framebuffer px and `props`dpr` is the ratio, so sizes written straight into draw calls
  came out half-size on a retina display. Layout constants are now logical points scaled
  by `dpr` each frame (as `lib/ui.k` already did).
  - Tests: `test/rope.k` (59 assertions) and `test/syntax.k` (51, pinning the role
    of every codepoint of each sample line); both wired into `make test`.

## 2026-07-21
- **Canvas/Slug 2D renderer → ONE analytic backend.** Fills, gradients, clips,
  strokes, text, and image paint all render through the Slug scene buffer
  (`lib/slug.k` + `lib/canvas.k`); tessellation is retired from the canvas path.
  Design/gotchas: `doc/design/canvas-slug.md`.
  - **Gradients + clip in the fill shader.** Each fill packs its 44-float NanoVG
    paint block (linear/radial/box gradient or solid, with the active clip baked in)
    into the scene buffer; the fragment evaluates `scissorMask` + the rounded-rect
    gradient SDF at its screen position and folds paint × coverage into the alpha.
  - **Strokes via Slug.** A stroke becomes a fill outline: each vertex offset ±½-width
    along its miter bisector (`canvas.miterContour`). Open paths → a ribbon (butt
    caps); closed paths → an annulus (two contours). Then it's a normal fill.
  - **Image paint.** `cnv.image[img;x;y;w;h;rgba]` (img = `cnv.loadImg[path]`) samples
    an image texture × analytic coverage × clip. Enabler: `shader.fragmentBufTex` —
    a dye fragment that reads both storage buffers and a texture.
  - **CFF/OTF fonts.** `font.quads` now works for PostScript (CFF) outlines: the
    native charstring interpreter gained a quads mode (each cubic split to 2
    quadratics, exported `cffQuads`), so OTF text renders analytically like glyf.
  - **Scene-buffer compaction.** An indexed band layout (per-band `(offset,count)` +
    a packed curve pool, no `slugMPB` padding) shrinks a fill ~10× — a 250+-glyph
    paragraph now fits (was capped at ~85 fills).
  - **Double-buffered scene/quad-pool** (parity-cycled, in lockstep with the GPU
    frame) removes the FRAMES-in-flight write-vs-read data race — no engine change.
  - **Robustness:** independent-aspect band normalisation (flat shapes spread across
    all bands instead of truncating), and the pull pipeline's depth compare relaxed
    to `LESS_OR_EQUAL` so overlapping coplanar 2D quads (packed glyphs) all pass.

## 2026-07-16
- **`kk.compile` placed tables** (kk2 §2.5, the last §2 milestone): `gpu.holdT[t]`
  places a k table as a structured buffer — one resident buffer per column
  (planar/splayed) — and `kk.compile` binds only the columns a kernel actually
  reads. A column access `(t`c)` (an apposit var+symbol) resolves to that column's
  buffer, element-loaded at the thread index (`xTableCol`; `shader.table`). Binding
  inference (`kkTableColNames`) prunes unreferenced columns — the kdb splayed
  property on the device. Since `t`c` on the CPU already IS the column, the same
  lambda runs both sides. Verified in test/kkc.k (22/22): column arithmetic vs CPU
  + a pruning check. Deferred: interleaved layout, placed dicts (ragged CSR), and
  tables composed with gather/reduce/scatter. **This completes the kk2 §2 roadmap
  (gather, matrix-reduce, amend, scatter-add, tables) on top of the walk.k
  headline.**
- **`kk.compile` scatter-add `@[x;I;+;v]`** (kk2 §2.4-5): compiles to
  `shader.scatadd` — one thread per index, `acc[I[d]] += i32(v)` via `OpAtomicIAdd`
  (`kScatAdd`) so duplicate buckets accumulate race-free. acc is an i32 accumulator
  (zero-inited); I is padded with a sentinel into acc's padding tail; v is a
  constant (baked) or a single value vector. Result descriptor is tagged `t:`i` and
  `gpu.fetch` reads it via `gpu.readI`. Verified in test/kkc.k with count, skewed,
  and weighted histograms vs CPU `@[…;+;…]` (19/19). Deferred: float fixed-point
  scaling and paired/multi-value scatters.
- **`kk.compile` amend-scatter + ping-pong iterate — walk.k acceptance met**
  (kk2 §2.4-4): `@[x;I;:;v]` compiles to `shader.amend` — one thread per interior
  index, the value expr (`1.+.25*+/x@W`) computed through the gather-reduce IR and
  scattered to `out[I[d]]` (`kScatStore`); I is padded with a sentinel index into
  out's padding so over-dispatched threads can't clobber, and out starts as a copy
  of x so boundary cells carry through. **`kk.loop[f; x0; niter]`** ping-pongs two
  buffers via `gpu.dispatchLoop` (one encoder, barriers handled). walk.k's
  `f:{@[x;I;:;1.+.25*+/x@W]}` compiles **verbatim** and 30k sweeps on the 100×100
  grid converge to **E@center = 2887.3418** — the documented Jacobi f32 fixpoint
  (test/walkgpu.k PASS; small-grid checks in test/kkc.k, 17/17). This is the
  headline increment-5 acceptance. (walk.k's `f/` converge → fixed-count `n f/`
  here; true device-side converge is tier-2.)
- **`kk.compile` host-vector auto-upload** (kk2 §2.4-3, milestone 3 core
  complete): a `+/x@W` gather operand that isn't a param (x/y/z) is treated as a
  host global — `kkResolve`/`kkUpload` reads its value and `gpu.hold`s it
  read-only, taking the `(k;n)` shape from the value. So **walk.k's
  `1.+.25*+/x@W` with `W` a host global compiles and matches the CPU bit-for-bit**
  (test/kkc.k 14/14). Gotcha: `gpu.hold . nm` parses `.` as dyadic (name on its
  left) → applies to the symbol, not its value; take the value in its own
  statement first. Minor remaining gap: single gather `x@w` still needs both
  operands passed as placements (auto-upload is wired only through the matrix
  path, which is what walk.k uses).
- **`kk.compile` matrix gather-reduce: `+/x@W` → walk.k interior** (kk2 §2.4-3,
  milestone 3's core done): `xApposAdv` now recognises a `/`-fold over an
  `@`-transit and emits a real `rsum`/`rmax` region node whose body gathers
  `x[W[(j*n)+d]]` (`xRedGather`); `k`,`n` come from W's `(k;n)` descriptor shape,
  baked into the kernel (cache key carries them), output length = n. kk.compile
  branches to the matrix path on `kkIsMatReduce[]`. **walk.k's interior update
  `1.+.25*+/x@W` compiles and matches the CPU bit-for-bit** (test/kkc.k, 13/13);
  `|/x@W` (max) works too. Two traps fixed: joining `` `x`y `` with an empty INT
  vector `!0` upcasts to a boxed list and breaks the env dict (use `0#\``), and
  the rsum path needs `kAlloc` with `hasLoop=1` for its loop constants. Remaining
  in milestone 3: host-vector free-name auto-upload (W/I as host globals).
- **`kk.compile` gather: `x@y` → index-buffer gather** (kk2 §2.4-3, milestone 3
  starts): a param used as the LEFT of `@` is a gather SOURCE (a whole buffer,
  indexed); every other param is an index that's auto-loaded at the thread index
  d, so `kk.compile[{x@y}; (data;idx)]` computes `out[d] = data[idx[d]]` and
  returns a descriptor. New dye machinery: an `elem` env role (a bare buffer name
  means buf[d] — `xVarE`/`xElem`), `@` lowering to a nested buffer index
  (`xGather`), and a gather kernel builder `shader.gmap[fn; bufNames; elemNames]`.
  Verified in test/kkc.k against CPU `data@idx`. (Host-vector auto-upload of free
  names + the `+/x@W` matrix reduce — the rest of milestone 3 — are next.) Fixed
  an empty-typed-vector trap found here: `f'(!0)` yields a general-list `()`, and
  `&()` then `v@…` spuriously returns one element, so a no-`@` body looked like a
  gather — the has-`@` scan now guards the empty case.
- **`kk.compile` — elementwise whole-array lambdas on placements** (kk2 §2.4-2,
  increment 5 starts): `kk.compile[fn; descriptors]` takes a whole-array lambda
  in implicit-param form (`{2.*x}`, `{x+y}`, `{(x+y)*z}`, `{sqrt x}`,
  `{$[x<y;y;x]}`), compiles it to a per-thread map (dye's new
  `shader.map[fn; nIn]`, generalising compCompute/compute2 to N inputs), runs
  it over the placed arrays (one thread per element), and returns an OUTPUT
  descriptor — so `8: kk.compile[{2.*x}; ,a]` reshapes like any placed array.
  Pipeline cached by (lambda source; #inputs); output padded to the ×64 grid
  (descriptor n/s stay real → 2-D shapes round-trip). A subset classifier
  (`kkClassify`) rejects gather/amend/adverbs/non-math applies, NAMING the
  offending verb (no silent fallback — those forms are later milestones).
  Oracle test/kkc.k: GPU vs CPU bit-for-bit (sqrt at f32 tol), cache reuse, and
  rejection (9/9). Fixed a latent trap this surfaced: `str in list` runs
  char-wise (a string is a char vector), so string dict keys give false `$[]`
  hits — kk uses symbol cache keys.
- **Fragment/vertex compile through the neutral IR; direct `comp*` walker
  deleted** (kk2 §3, the seam finished): `shader.fragment`/`fragmentTexN` now
  go through `kSeqIr`, and `shader.vertex`/`vertexU` through `xSeqEnv` + a new
  `vstore` effect node that pins each output store (gl_Position through the
  gl_PerVertex block member, varyings direct) at its build position — so
  lowering in build order reproduces the id sequence exactly. Added a `sample`
  IR node (image+sampler loads → OpSampledImage → ImageSample) and a `consc`
  node (vector-literal OpConstantComposite) so the fragment subset is fully
  covered. With every entry point on the IR, the ~376-line direct expression/
  loop/seq walker (`compNode`/`compSeq`/`compApply`/`compRsum`/… + `dispUn`/
  `splat`/`compVar`/`compSeqEnv`) is removed — single-pipeline dye (1498→1122
  lines). Oracle: 7 new fragment/vertex/texture cases added to test/kkgold.k
  and captured BEFORE the migration; all byte-identical after, and each passes
  spirv-val vulkan1.2. test/spirv.k 85/85, test/ir.k 7/7, test/nn.k GPU maxerr
  unchanged, planes.k renders (30% non-black).
- **Compute/vertex const-fold + multi-root DCE** (kk2 §3, finishes the seam):
  new `xOpt` flag (default 0 = lower every node, byte-identical). `xOpt=1`
  runs `xFold` then keeps only nodes reachable from a multi-root set — the
  value result **plus every store** (setb/sadd/isetb/vstore) **plus every loop
  and its result phi(s)** — so stores never get culled and loop bodies (reached
  only via `xVal`, not `xArg`) keep the top-level values they read; `xLoRegion`
  now gates owned nodes on `xRe` too, giving intra-loop DCE. Verified: with
  xOpt on, the whole nn suite is **bit-identical** GPU output (semantics
  preserved), all 19 kkgold modules stay spirv-val-clean, and it's genuinely
  effective (a dead `g[1]` load and a `0.5*0.5` const both vanish) while the two
  atomic scatters / loop phis survive. New oracle test/kkopt.k (9 checks).
  Still TODO in §3: i32 index arithmetic.
- **`+/{[k] e}'!K` is the canonical in-kernel reduction spelling** (kk2
  §2.4-1/§8-3): dye recognizes fold-over-each-over-enumerate (`+/` → rsum
  region node, `|/` → rmax) in xAppos→xFoldEach and lowers it through the
  shared xRed builder — byte-identical to the intrinsic `rsum[K;{[k] e}]`/
  `rmax[…]` spelling by construction (no range materialised). The intrinsic
  names stay as documented equivalents; any other monadic adverbed verb in a
  kernel now warns + bakes NaN instead of silently compiling as negate.
  test/kkgold.k asserts the two spellings' byte-identity for gemm + softmax
  (12 gold dumps unchanged); lib/nn.k migrated to the full syntax (15 sites,
  all 12 kernels byte-identical; test/nn.k GPU maxerr unchanged).

## 2026-07-15
- **Monadic `%` = Shape** (the glyph was free since sqrt moved to the
  prelude; dyad stays divide): rectangular extent as an int vector, ragged
  lists stop at the first non-uniform level (`%(1 2;3 4;5 6)`→`3 2`,
  `%(1 2;3 4 5)`→`,2`, atoms→`!0`); inverse of reshape. New
  src/primitive/verb/shape.zig + unit tests. Placed-array descriptors gain
  `s: %x` — `9:` flattens nested rectangular input for upload and `8:`
  reshapes the readback, so `8: 9: (N;N)#x` round-trips (kk2.md §8-4).
- **Compute bodies compile through the neutral IR** (kk incr 3, the seam
  migration): kSeqIr builds typed SSA for every compute entry point and
  lowers it in build order. New IR ops: bufidx/igetb loads, setb/sadd/isetb
  effects, f2s conversions, bufp binding refs, and rsum/rmax/ndo/whileL as
  opaque region nodes (xRgn owner column; loop lowerers replay their owned
  nodes inside loopOpen/loopClose blocks; nesting via saved RK* phi globals).
  All 12 kkgold modules byte-identical to the retired direct path; golden,
  walk3, nn, clothgpu, baking, inference, fragment-IR all verified. The
  second backend (bits → FusedMap) and IR-level rewrites now have the full
  compute dialect to target.
- **Binding inference: `shader.kernel[fn]` + `gpu.pipeline[fn]`** (kk incr 3,
  bindings-from-the-lambda): params passed to scatterAdd/iget/iset are i32
  accumulators (must come first; warned otherwise), the last param is the
  thread index, the rest are f32 buffers. Byte-identical to
  `gpu.kernel[fn;nAcc;nBuf]` with the right counts. `gpu.pipeline[fn]`
  compiles lambda→SPIR-V→cached pipeline in one call (nbind published as
  KKnb). New gotcha documented in code: `kVal *kF[…]` is kVal TIMES kF
  (noun-adjacency); use kF1.
- **Host-global baking in kernels** (kk increment 3, first slice): a name in a
  dye kernel that isn't a param/local now resolves to the HOST global's current
  value, baked as an f32 constant at kernel-compile time — "host globals are
  invisible inside shaders" is gone, and with it the keep-in-sync-by-comment
  literals (clothgpu.k's `SC` now referenced directly in kCon/kApp). Unknown or
  non-scalar names warn and bake NaN (loud, since ink has no signal verb).
  Both compiler paths (compVar + IR xVar).
- **Fix: ReleaseFast GPU builds crashed at vkCreateInstance** — the release
  link dead-stripped static MoltenVK's ObjC selector metadata
  (`+[NSProcessInfo processInfo]: unrecognized selector`). `link_gc_sections =
  false` on libgpu.dylib (and `--no-gc-sections` in `ink bundle`'s link).
  Debug builds only worked because they don't gc sections.

## 2026-07-14
- **`9:`/`8:` io verbs** (kk increment 4, verb surface): the GPU is an io
  channel — `9: x` places (upload → descriptor `[gpu;t;n]`), `d 9: x`
  overwrites in place, `8: d` fetches, `n 8: d` fetches n. Implemented as
  `io.zig` trampolines to `gpu.hold`/`holdInto`/`fetch`/`fetchN` (new, in
  lib/gpu.k); `8:` added to the grammar (`9:` was a reserved stub); `!io`
  when lib/gpu.k isn't loaded.
- **`gpu.caps`** (completes kk increment 0): device capability dict from the
  live Vulkan device (`Vk.queryCaps` → `gpuCaps` FFI). M1 Pro/MoltenVK reports
  ALL of: subgroup arithmetic (32 lanes), descriptor indexing + runtime
  descriptor arrays, buffer device address, f16, and VK_EXT_shader_atomic_float
  f32 add — so subgroup reductions, bindless, and native float scatter-add are
  all on the table (features still need enabling at device creation to use).
- **Vulkan cutover** (kk increment 0 / migration Phase 5): Dawn/WebGPU backend
  deleted (`lib/gpu/gpu.zig`, `render.zig`, `fill.wgsl`, `blit.wgsl`,
  `patches/`, zon deps, `gpuWgsl`); raw Vulkan/MoltenVK (`gpu_vk.zig`) is the
  only backend; `zig build static` merges gpu+MoltenVK+GLFW into
  `libgpu-bundle.a` (11MB, was ~20MB). Run `make install` to refresh the stale
  Dawn dylib under `~/.ink`.
- **SPIR-V 1.4 native** (kk increment 2 / migration Phase 6): dye.k emits
  version `0x00010400` with the full-interface `OpEntryPoint` rule in all four
  assemblers (compute `kAsm`, fragment `buildMod`, `shader.vertexU`,
  `lib/instancing.k`); the `INK_SPV14`/`maybeBump` live transform is removed.
  12/12 kkgold modules pass `spirv-val --target-env vulkan1.2`; golden +
  walk3/nn/sphere/circle/eyes/earth/clothgpu all verified.
- **kk design** (`doc/design/kk.md`): plan for compiling idiomatic k to both
  SPIR-V and ink bytecode — io verbs `9:` (place on GPU) / `8:` (fetch), the
  k-primitive→compute rewrite table (each/gather/amend/fold/scan tiers), placed
  arrays as the data layer, SPIR-V 1.4 flip + caps-gated bindless, and the
  IR→FusedMap CPU backend (`bits`).
- **dye consolidation** (kk increment 1): the eight compute emitters in
  `lib/dye.k` (`shader.compute{,U,2}`, `shader.stencil{,U,IP}`,
  `shader.scatter`, `gpu.kernel`) are now thin wrappers over one shared
  prologue/assembler (`kAlloc`/`kGidX`/`kGidF`/`kElem`/`kStore`/`kAsm`);
  ~370 lines deleted, one `hdr:` site remains (prereq for the SPIR-V 1.4 flip).
  `gpu.kernel` with no accumulators no longer emits dead i32 types/constants.
  Oracle: `test/kkgold.k` module dumps (9/12 byte-identical, 3 improved),
  `spirv-val` on all, `walk3`/`nn`/`clothgpu`/`spirv.k` end-to-end.
