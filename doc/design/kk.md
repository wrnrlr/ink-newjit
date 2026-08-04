# kk: idiomatic k → GPU (SPIR-V) and CPU (ink bytecode)

> **Phase 1 (increments 0–3) is DONE — see `doc/design/kk2.md`** for the
> recap, the techniques to keep (record-then-replay, opaque region nodes,
> the oracle ladder), and the phase-2 design: tier-1 rewrites / kk.compile
> (walk.k verbatim), fragment/vertex IR migration, bits, vertex pulling,
> subgroup reductions, float atomics. This file remains the original plan
> plus per-increment status notes.

Status: **design agreed; increment 1 (assembleCompute consolidation) DONE** —
`lib/dye.k`'s eight compute emitters are thin wrappers over `kAlloc`/`kAsm`
(~370 lines deleted). Oracle: `test/kkgold.k` dumps all 12 representative
modules; 9/12 byte-identical, the 3 `gpu.kernel nAcc=0` modules *improved*
(the old `compGpN` emitted dead i32 accumulator types/decorations/Device-scope
constant even with zero accumulators; the consolidated emitter gates them).
All 12 pass `spirv-val --target-env vulkan1.1`; `walk3`/`nn`/`clothgpu`/
`spirv.k` verified end-to-end (SOR 2887.48, nn maxerr ≤7.2e-7). Successor to `doc/design/dye.md`
(the dye split + neutral IR) and `doc/design/vulkan-migration.md` (the runtime that
makes it possible). Companion research: `doc/papers/baghdadi_2019_tiramisu.md`
(multi-layer IR), `doc/papers/copy-and-patch.md` (stencil codegen),
`doc/research/columnar-execution.md` (the CPU chunked backend),
`doc/research/type-system-and-jit.md` (the type lattice, reverted, to be revived).

## 0. Vision

dye is to ink what q is to k — but today it compiles a *dialect*: per-thread
lambdas (`{[u;g;i] …u[i-w]…}`), an entry-point zoo (`shader.stencil/U/IP`,
`shader.compute/2/U`, `shader.scatter`, `gpu.kernel`), and hand-managed buffers.
That is CUDA written in k syntax. The goal — **kk** — is that the *idiomatic* k
expression of an algorithm is the program for both targets:

```k
/ test/walk.k, verbatim — today CPU-only
W: ((-N),N,1,-1)+\:I
f: {@[x;I;:;1.+.25*+/x@W]}

/ kk: same f, GPU placement decides the target
E: 8: (N*N) f/ 9: (N*N)#0.       / upload, N dispatches in one encoder, read back
```

Three pillars get us there:

1. **A data layer** — placed arrays, io verbs `9:`/`8:`, bindings derived from
   free variables, an i32 index type. (Today Tiramisu's Layer 3 is answered by
   *choosing an entry-point name*; the CPU tape has no data ops at all.)
2. **A rewrite table** — k's own primitives (`'`, `@`, `@[…]`, `/`, `\`, `':`)
   lower to GPU compute primitives via peephole recognition on the neutral IR,
   exactly the mechanism already proven by the CPU compiler's intrinsic-alias /
   const-global / FusedMap passes.
3. **Two backends over one IR** — SPIR-V (exists) and ink bytecode
   (`bits`: the FusedMap KOp micro-ISA is the same machine at a different
   altitude; lowering elementwise IR→KInsn is a ~50-line walk).

The current per-thread `gpu.kernel` form **stays** as the escape hatch — kk's
assembly layer, for schedules the rewriter shouldn't guess (red-black in-place
races, hand-tuned fixed-point tricks).

## 1. The io-verb surface: `9:` place, `8:` fetch

The GPU is an io channel. `2:` loads *code* into the process; `9:` loads *data*
into the device. `9:` is already reserved in `Op1`/`Op2` (`operator.zig`) as a
stub; `8:` is a new (small) lexer/enum addition. `3:`–`7:` stay free.

| form | meaning | today's spelling |
|---|---|---|
| `9: x` | place: upload `x`, return a **placed array** `d` | `gpu.buffer[x]` |
| `d 9: x` | overwrite placement `d` with `x` (no realloc), returns `d` | `gpu.write[h;x]` |
| `8: d` | fetch: sync + read back (typed: f32→`F`, i32→`I`) | `gpu.read[h]` / `readI` |
| `n 8: d` | fetch first `n` elements (trims dispatch padding) | `n#gpu.read[h]` |

**This is not a metaphor — it matches the driver.** The Vulkan backend
(`lib/gpu/vk.zig`) already *records* dispatches into one command buffer and
submits+waits only at readback ("deferred submission", proven necessary for
MoltenVK hazard tracking and 7× faster on the 22k-iteration solver). So the io
semantics are exact: `9:` opens/writes the channel, verbs on placed arrays
record work, `8:` is the sync point. `walk3.k`'s `gpu.dispatchLoop` ping-pong
becomes invisible: `(N*N) f/ 9: x0` records N passes; nothing runs until `8:`.

**The placed array value.**
- v1 (pure k, no runtime change): a dict `(gpu:handle; t:`f; n:count; s:shape)`
  produced by `gpu.hold`/consumed by `gpu.fetch` in `lib/gpu.k`; `9:`/`8:` sugar
  onto these once the verb wiring lands.
- v2 (runtime): a dedicated class so verb dispatch can see placement — `d+e` on
  placed arrays compiles+caches a kernel instead of erroring. Dispatch keyed by
  (lambda identity; operand shapes/placements) = the monomorphic call-site
  specialization from dye.md Phase 3, on arrays instead of names.

Shape lives in the descriptor. Consequences: `d@W` can type-check bounds,
2-D stencils know their pitch, `nnPad`-style guard logic moves into the runtime
(pad on upload, trim on `n 8:`), and **take/drop/reshape on placed arrays are
metadata edits** — zero kernels, zero copies (a view = handle + offset + shape +
strides). `clothgpu.k`'s hand-packed `P[3*p+axis]` becomes a `(nP;3)` shape.

**kk-only?** `9:`/`8:` are *host* verbs: inside a kk-compiled kernel they are a
compile error (no device round-trips inside kernels). At the ink top level they
are ordinary verbs wired (like `0:`/`1:`/`2:` in `io.zig`) to a registered
extension hook via the kabi registry, so the core stays GPU-free and the verbs
error cleanly when no device extension is loaded.

## 2. The rewrite table: k → compute primitives

Recognition happens on the **neutral IR** (dye.md Phase 3 seam), not the CST,
so one rewrite serves both backends. The CPU compiler already does this pattern
(FusedMap subtree recognition, `#'=`→`freq` peephole, `<=`/`>=` in dye).

### Tier 1 — direct lowerings (the walk.k set)

| k form | meaning | GPU lowering | notes |
|---|---|---|---|
| `f' d` | each over placed vector | 1 thread/elem (map) | today `shader.compute` |
| `f'[d;e]` | zip | 2-input map | today `shader.compute2` |
| `d @ I` | gather | per-thread indexed load | today `u[i]` intrinsic |
| `d @ W`, `W: off+\:I` | stencil gather | relative-offset loads | replaces `shader.stencil` |
| `f'[n;d]` | stencil adverb, sliding window n | static-offset gather | n is compile-time; output shrinks by n-1 (k semantics) |
| `f': d` | eachprior | window-2 gather | `-': d` = finite difference |
| `@[d;I;:;v]` | amend | thread-per-`I` scatter store | in-place schedule when target = fold state → replaces `stencilIP` |
| `@[d;I;+;v]` | amend-with-+ | `OpAtomicIAdd` | replaces `scatterAdd`; f32 via fixed-point or caps-gated float atomics (§4) |
| `+/ \|/ &/ */` over `!k` / small dim | fused index-reduce | in-kernel loop | exists as `rsum`/`rmax` — becomes recognition of `+/{…}'!k`, the intrinsic names retire |
| `n f/ d` (buffer state) | iterate | **host**: n dispatches, ONE encoder, auto ping-pong | exists as `gpu.dispatchLoop`; ping-pong inferred: fold state is the whole buffer and body gathers from it |
| `n f/ x` (scalar/vec state) | iterate | in-kernel loop | done (`compNdo`) |
| `f g/ x` (scalar state) | while | in-kernel loop | done (`compWhile`) |
| `x f\:/: y` / outer product | 2-D grid | thread = (i;j), 2-D dispatch | GEMM's shape; `+/x*y` inner recognized → the `nn.k` gemmK lowering |

Acceptance test for tier 1: `walk.k`'s `f:{@[x;I;:;1.+.25*+/x@W]}` compiles and
matches the CPU result; `walk3.k` reduces to placements + the CPU functions.

### Tier 2 — need scan/reduction infrastructure

| k form | GPU lowering | unlocks |
|---|---|---|
| `+/ d` (whole placed buffer) | two-stage reduce: workgroup partials → second dispatch (subgroup ops when caps allow, §4) | loss functions, dot products, convergence tests without readback |
| `+\ d`, `*\`, `\|\`, `&\` | workgroup scan + block-offset pass (Blelloch / decoupled lookback) | prefix sums — the workhorse below |
| `& m` / `d @ & m` | scan + scatter (stream compaction) | filtering, particle culling |
| `= d` (group) / `#'= d` | histogram via atomic add (the CPU `freq` peephole, on device) | binning, spatial hashing (`demo/spacial.k` on GPU) |
| `f g/ d` (buffer state) | host loop, device-side `\|/abs Δ` reduction, readback test every k iters | tolerance-based solvers instead of walk.k's 21k-iteration bit-fixpoint |
| `n f\ d` | n dispatches, each writing row i of an (n;#d) buffer | trajectories, animation baking |
| `? n` (deal/rand) | counter-based RNG (philox) intrinsic | walk.k's Monte-Carlo half on device |

### Tier 3 — deferred (each is its own project)

Grade/sort (`< >` on buffers — radix sort), `?` find/distinct (hash tables),
general dict/table ops. Not needed by any current demo.

### Scheduling decisions (Tiramisu Layer 2), made explicit

- in-kernel loop vs multi-dispatch: by fold-state placement (scalar → kernel,
  buffer → dispatches).
- ping-pong vs in-place: ping-pong is the sound default; in-place (`stencilIP`
  semantics, red-black) requires the per-thread escape hatch or a future
  `!schedule`-style annotation. **Never inferred.**
- baked constant vs uniform: `:`-bound global → folded into the module
  (per-shape specialization, recompile on change); `::`-bound → params/uniform
  buffer. This reuses the CPU compiler's exact `const_globals` soundness rule
  (`collectMutated`) and kills the "keep host and kernel literals in sync"
  comment-contract in `clothgpu.k` (`SC`, grid dims, `DAMP`).
- OOB policy: **clamp**, documented (Metal clamps stores anyway); correctness
  tool is the amend mask (interior-only `I`), which walk.k already uses. CPU
  `0N` semantics differ — kk documents placed-array indexing as clamping on
  both targets when the expression is kk-compiled.

## 3. Backends

### 3.1 SPIR-V (exists — consolidate, then extend)

The eight compute emitters in `lib/dye.k` share one body compiler and differ
only in a hand-rolled binding table + ~50 duplicated lines of module assembly.
Increment 1 replaces them with **one general emitter** parameterized by a
binding spec (nAcc i32 bindings, nBuf f32 bindings, optional uniform block,
optional auto-store of the result to a designated binding, optional loop
constants), and re-expresses all eight entry points as thin wrappers. After
this there is exactly **one** `hdr:` site — which makes the 1.4 flip (§4) a
one-line change plus one interface-list rule.

Next, the neutral IR grows what dye.md item A specifies: effect ops
(`store`, `atomicAdd`), `load`/`gather` ops carrying the binding, `i32` as a
first-class scalar type (indices stop being f32; `div`/`mod` on them emit
`OpSDiv`/`OpSRem`; the 2^24 exactness cliff disappears), and loops as opaque
macro nodes expanded by the existing `loopOpen`/`loopClose` scaffold. Then the
compute path migrates onto the IR and the rewrite table targets IR patterns.

### 3.2 `bits` — ink bytecode (the CPU backend is nearly free)

The neutral IR (`xOp`: const/cons/extract/arith/math/select) and the FusedMap
KOp micro-ISA (`tape.zig`: Col/Add/…/Sqrt/Sin, postfix, chunk-interpreted) are
the same machine at two altitudes. `bits.compile[ir]` v1 = lower the
elementwise/select subset to a `Kernel` postfix program and emit one `FusedMap`
— executed by the already-benchmarked X100 chunk interpreter (1.2–2.6× over
materialized). Gather/Store/Select KOps extend the micro-ISA when tier-1 lands
(this is also step 3 of `columnar-execution.md` — fused map feeding reduction).

Immediate dividend: `test/nn.k`'s ~300 lines of hand-written CPU references
(`gref`/`sref`/`mref`/…) become *generated* — same kernel source, two
lowerings, `maxerr` is the continuous cross-backend oracle.

### 3.3 Types

Revive only the cheap parts of the reverted type system
(`type-system-and-jit.md` §2–4): the `Ty` lattice with `Dim.symbolic` and the
transfer tables. Its own §11 said "pick the consumer first" — kk is consumer
(c). No JIT, no typed dispatch; inference feeds dye's i32/f32 choice, shape
checking of gathers, and binding derivation.

## 4. SPIR-V 1.4+, bindless, and what the Vulkan migration already bought

**Status check (verified in tree):** the runtime is raw Vulkan via direct
MoltenVK link at `apiVersion = 1.2` (`vk.zig`); Dawn's Tint reader — the thing
that pinned us to SPIR-V 1.3 — is out of the SPIR-V path entirely, though Dawn
is still the *default* backend in `build.zig` (Phase 5 cutover pending).
SPIR-V 1.4 is **already proven live**: `INK_SPV14=1` → `vk.maybeBump` rewrites
every module (version word `0x00010400` + `OpEntryPoint` interface expanded to
all non-Function globals) and the full nn/conformer stack ran bit-identical
(migration doc Phase 6 ✅). A bare version bump without the interface expansion
is invalid — MoltenVK silently miscomputes — so the flip must land *after* the
emitter consolidation puts the entry-point assembly in one place.

**So: nothing blocks 1.4.** The plan:
1. Phase-5 cutover (make `vulkan` the default, delete Dawn/zgpu/`gpuWgsl`).
2. Increment 1 consolidation (one `hdr:` site, one interface-list builder).
3. Flip dye to emit 1.4 natively; fold `maybeBump`'s interface rule into
   `assembleCompute`; drop the env flag. Re-run `test/spirv.k` golden with the
   new version word.

**What 1.4 itself buys is modest** (composite `OpSelect`, `OpCopyLogical`,
entry-point-lists-everything). The real prizes are *feature*-gated, not
version-gated, and Vulkan 1.2 puts them in reach — but every one of them must
be **queried, not assumed** (MoltenVK caps vary by Metal version/hardware):

| capability | Vulkan gate | what kk gets | MoltenVK status |
|---|---|---|---|
| subgroup ops (`OpGroupNonUniform*`) | 1.1 core, query `VkPhysicalDeviceSubgroupProperties` | `+/ \|/` reductions and `+\` scans at hardware speed (tier 2) | Apple silicon simdgroups — expected yes; **query** |
| descriptor indexing / `RuntimeDescriptorArray` | 1.2 core *feature bits* | dynamic `sample[k;uv]`, texture arrays — bindless textures | via Metal argument buffers; partial — **query** |
| buffer device address (`PhysicalStorageBuffer64`) | 1.2 feature `bufferDeviceAddress` | buffers as 64-bit pointers: one address table = fully bindless buffers, binding tables disappear | supported on Apple silicon in recent MoltenVK — **query** |
| float atomics (`VK_EXT_shader_atomic_float`) | extension | native f32 `@[d;I;+;v]` (drop the fixed-point SC dance in clothgpu) | partial on Metal — **query**; keep fixed-point fallback |

**Action:** ✅ `gpu.caps` landed (2026-07-14) — `Vk.queryCaps` chains
`VkPhysicalDeviceVulkan12Features` + subgroup properties + (extension-gated)
`VkPhysicalDeviceShaderAtomicFloatFeaturesEXT`; exposed as a k dict. Measured
on the M1 Pro / MoltenVK:

```
(api:1.2;subgroup:32;sgArith:1;sgBallot:1;sgShuffle:1;descIndex:1;runtimeArray:1;bda:1;f16:1;atomicFadd:1)
```

**Every capability in the table is present** — subgroup reductions/scans,
bindless textures (descriptor indexing + runtime arrays), bindless buffers
(BDA), f16, and native f32 atomic-add (clothgpu's fixed-point `SC` dance can
go). Caveat for the lowering work: these are *supported* bits; each feature
must also be **enabled** in `VkDeviceCreateInfo.pNext` at device creation
before shaders may use it. Order of attack: subgroup reductions first
(biggest kk win), then float atomics, then descriptor indexing / BDA.

**Vertex pulling needs none of the above** — storage buffers in the vertex
stage are base Vulkan. The vertex shader becomes a kernel-shaped function of
`(buffers…; vid)` returning `(pos; varyings…)`; the attribute/stride/location
machinery and the `mesh.draw{,U,T,Geom*,Instanced*}` combinatorics collapse to
`(pipeline; buffers; count)`. Instancing (still stubbed in the Vulkan backend,
deferred as unverifiable) is *subsumed*: instance id = `i div vertsPerInstance`
or a second index buffer — no `VkVertexInputRate` machinery to port.
`clothgpu.k`'s per-frame `8:`→rebuild→re-upload round-trip disappears: the
render shader pulls straight from the sim's resident `P`; normals become one
more kernel. Bindless textures ride behind the caps query.

## 5. Roadmap

Each increment independently shippable; oracle in parentheses.

0. ✅ **Vulkan cutover** (2026-07-14) — Dawn/zgpu/zpool/`gpuWgsl`/WGSL files
   deleted; vulkan is the only backend; static bundle = gpu+MoltenVK+GLFW.
   Verified: walk3/nn numerics + sphere/circle/eyes/earth/clothgpu snapshots
   identical (sphere 49.0%, brightest 158,173,188 = the Dawn-era values).
   Still open from this step: the `gpu.caps` query.
1. ✅ **`assembleCompute` consolidation** (2026-07-14) — see Status above.
2. ✅ **SPIR-V 1.4 native** (2026-07-14) — version word `0x00010400` + the
   full-interface `OpEntryPoint` rule in all four assemblers (`kAsm` lists
   gid+bindings+uniform; `buildMod` adds textures+sampler; `vertexU` adds the
   uniform block; `instancing.k` adds its SSBO). `maybeBump`/`INK_SPV14`
   deleted from the backend. (golden at 1.4; 12/12 modules
   `spirv-val --target-env vulkan1.2`; full demo suite re-verified.)
3. **IR data ops + i32 + opaque loops**; compute path onto the IR; bindings
   derived from free variables (`gpu.kernel` infers its table; entry points
   become aliases). (record-then-replay byte-oracle where no optimization
   fires; demos.) ◐ **Host-global baking DONE** (2026-07-15): a kernel name
   that isn't a param/local bakes the host global's current numeric-scalar
   value as an f32 constant (both compVar and IR xVar paths; unknown/non-
   scalar warns + bakes NaN). clothgpu.k's `SC` is the demo — the keep-in-sync
   literals are gone. Note this is bake-at-compile-time semantics (recompile
   to update), simpler than the CPU compiler's `:`-vs-`::` rule — kernels are
   compiled explicitly, so "current value at compile" is the natural contract.
   ◐ **Binding inference DONE** (2026-07-15): `shader.kernel[fn]` derives the
   table from the lambda (scatterAdd/iget/iset first-args → accumulators,
   last param → thread index, rest → buffers; byte-identical to explicit
   `gpu.kernel[fn;nAcc;nBuf]`), and `gpu.pipeline[fn]` goes lambda→pipeline
   in one call.
   ✅ **COMPUTE PATH ON THE IR** (2026-07-15): every compute body now builds
   the neutral IR and lowers it (`kSeqIr`). The IR gained loads (`bufidx`,
   `igetb`), effects (`setb`, `sadd`, `isetb`), explicit `f2s` conversion
   nodes (placed where the direct path allocated its OpConvertFToS ids — the
   1:1 id-order discipline), binding refs (`bufp`), and **loops as opaque
   region nodes** (`rsum`/`rmax`/`ndo`/`whileL` + `kparam`/`lparam`): body
   nodes carry an owner in `xRgn`, the main pass skips them, and the loop's
   lowerer replays them inside its basic blocks via the loopOpen/loopClose
   scaffold (phi ids travel through save/restored RK* globals, so nesting
   works). Oracle: all 12 kkgold modules **byte-identical** to the direct
   path; spirv.k golden, walk3/nn/clothgpu numerics, baking, inference and
   the fragment-IR twin all green. Prologue/epilogue (gid, elem loads,
   auto-store) stay direct by design. Still open in incr 3: fold/DCE for
   compute (flip once oracles move to numeric parity), fragment/vertex onto
   the same path (then delete the direct comp* walkers), i32 index type.
4. **Placed arrays + `9:`/`8:`** — ◐ verb surface DONE (2026-07-14): `8:`
   added to the grammar (`9:` was reserved), both wired as thin trampolines in
   `io.zig` (`callGlobal` → `Call.apply`) to `gpu.hold`/`holdInto`/`fetch`/
   `fetchN` in lib/gpu.k; descriptor = `(gpu:handle;t;n)`; `!io` when gpu.k
   isn't loaded, so the core stays GPU-free. Verified: upload/fetch/overwrite/
   trimmed-fetch roundtrip on-device. ◐ ADOPTED (2026-07-17): the kk oracles
   (kkc/kkred/walkgpu) now spell placement/fetch with the verbs (`E: 8:
   kk.loop[f; 9: x0; n]`), monadic `9:` on a TABLE routes to gpu.holdT (a new
   `_M` dispatch entry) and `8:` on a `tbl` descriptor reassembles the table;
   unit-tested `!io`/`!type` behavior without the device lib (src/test.zig).
   Parse note: `f 9: x` after a name is DYADIC — write `f[9: x]`.
   REMAINING: `n f/ d` → dispatchLoop recording, kernel compile-on-apply.
5. **kk tier 1 rewrites** — each/zip/gather/amend/amend-+/fold-over-iota,
   stencil adverb, eachprior. (`walk.k`'s `f` verbatim on GPU == CPU result;
   `clothgpu` kernels rewritten in array form.)
6. **`bits` v1** — IR→FusedMap lowering; nn CPU references generated.
   (nn maxerr CPU-vs-GPU from one source.)
7. **Vertex pulling** — kernel-shaped vertex shaders, retained-buffer draws;
   port `clothgpu.k` (readback deleted) + `earth.k`; retire attribute path +
   instancing stubs. (pixel parity vs current renders.)
8. **Tier 2** — whole-buffer reduce, scan, compaction, group/histogram;
   subgroup path behind `gpu.caps`. (CPU parity on the same expressions.)
9. **Bindless** — descriptor indexing / BDA, caps-gated; dynamic `sample[k]`.

## 6. Risks

- **Race semantics**: ping-pong inferred only for the sound case; in-place
  stays explicit (escape hatch). Never silently pick a racy schedule.
- **Numeric drift** CPU vs GPU (f32 contraction order in reductions): the
  cross-backend oracle uses tolerances (`maxerr`), not bit-equality; bit-golden
  only for same-target refactors.
- **MoltenVK caps** vary by hardware/Metal version — everything in §4's table
  is behind `gpu.caps`; fixed-point and two-pass fallbacks stay.
- **Rewrite-table scope creep**: tier 1 is the walk.k set, nothing more, until
  it ships end to end. Tier 3 is explicitly out.
- **Cost model honesty** (`columnar-execution.md` lesson): every scheduling
  default gets measured against the dumb path via `make bench` before it
  becomes default.
- **Benchmark validity — the arithmetic may not be there.** A synthetic compute
  load written as an affine chain (`c0 + c1*(c0 + c1*(... x)))`) is still `a*x+b`,
  and the Metal compiler folds it to a single FMA. A 256-op chain measured
  *identically* to a 1-op chain while `spirv-dis` confirmed dye had emitted all 256
  operations, so an entire intensity sweep measured nothing. Chained transcendentals
  (`sin`, `sqrt`) survive folding; affine chains do not. Verified 2026-07-27; the
  harness that fell for it (`bench/tropical.k`) was deleted. The CPU benchmarks in
  `bench/` are unaffected — a discarded top-level expression is NOT eliminated
  (`\t:1000 a+b` at n=1e6 costs 347ms, at n=10 costs 0ms).
