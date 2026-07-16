# kk phase 2: the rewrite layer

Status: **design**. Follow-up to `doc/design/kk.md` (the kk plan, increments
0–3 now landed) and `doc/design/dye.md` (the dye split + neutral IR seam).
This document records what phase 1 delivered and the techniques that made it
work, then designs the next phase in enough detail that any session can start
from here instead of a blank page: the tier-1 rewrites (walk.k verbatim),
kernel compile-on-apply over placed arrays, the remaining IR unification,
`bits`, vertex pulling, and subgroup reductions.

## 1. Where we are (phase 1 recap)

Landed 2026-07-14/15, in order (each commit's oracle in parentheses):

| commit | what | oracle |
|---|---|---|
| `6321f2a` | kk design; 8 compute emitters → one `kAlloc`/`kAsm` assembler | kkgold 9/12 byte-identical, 3 improved (dead i32 types gated) |
| `a292312` | Vulkan cutover (Dawn deleted); dye emits **SPIR-V 1.4 natively** | spirv-val vulkan1.2 12/12; pixel/numeric parity |
| `58df043` | `gpu.caps` — M1 Pro reports **every** feature green | live query |
| `28d2f80` | `9:`/`8:` io verbs → `gpu.hold/holdInto/fetch/fetchN` | on-device roundtrip |
| `7ad2d26` | host-global **baking** in kernels; ReleaseFast ObjC link fix | kkgold; clothgpu SC demo |
| `1b412ca` | `shader.kernel[fn]` binding inference; `gpu.pipeline[fn]` | byte-identity vs explicit counts |
| `cfa8bd2` | **every compute body through the neutral IR** (kSeqIr) | kkgold 12/12 byte-identical |

The compute dialect now flows CST → typed SSA → SPIR-V through one seam. IR
ops: `param bufp const cons extract select arith math neg lnot f2s bufidx
igetb setb sadd isetb` + loop region nodes `rsum rmax ndo whileL` with
`kparam`/`lparam` phi placeholders. The per-thread `gpu.kernel` form remains
the escape hatch — kk's assembly layer.

**Techniques that worked — keep using them:**
- **Record-then-replay.** Every `newId[]` in a direct emitter gets a 1:1
  counterpart in an IR lowerer, in the same order; a loop node is emitted
  *before* its body so it lowers where the direct path called `loopOpen`.
  Byte-identity then holds by construction, and `test/kkgold.k` (12 module
  dumps, diffed as text) catches any slip instantly.
- **Opaque region nodes** beat a full block/phi CFG IR for structured loops:
  an `xRgn` owner column, main pass skips owned nodes, the loop's lowerer
  replays them inside its basic blocks. Nesting = save/restore of the phi
  globals. A real region IR is only needed if a backend ever wants to
  *transform* loop internals.
- **The oracle ladder**: byte-identity (refactors) → `spirv-val` (validity) →
  numeric parity (`nn` maxerr, SOR value, scatter counts) → pixels (snapshot
  coverage/brightest). Choose the strongest rung the change allows; a change
  that intentionally alters words (1.4 flip, future i32) drops one rung, never
  two.
- **k-in-k gotchas that bit** (beyond CLAUDE.md's list): `kVal *kF[…]` parses
  as kVal TIMES kF — a bare op-glyph after a name is dyadic, use `kF1`;
  `$[]` branches are single expressions → per-op helper lambdas; no closures →
  compiler state in prefixed globals, save/restore for reentrancy; dict
  literal `[k:v;…]` works as a lambda tail; ink has **no signal verb** — dye
  errors are stdout warnings + NaN bakes (see §8, open question).

## 2. Tier-1 rewrites: `walk.k` verbatim (increment 5)

The acceptance test is unchanged:

```k
W: ((-N),N,1,-1)+\:I
f: {@[x;I;:;1.+.25*+/x@W]}
E: 8: (N*N) f/ 9: (N*N)#0.
```

The key insight that keeps tier 1 *small*: the general lowering of `x@W`
needs **no pattern cleverness** — `W` is host data, so upload it and gather
through an index buffer: `u[w[i]]`. Affine-offset detection (`W: off+\:I` →
relative loads `u[i-N]`, no W buffer) is an *optimization* on top, not the
mechanism. walk.k's folded-domain solver (`K@ci+nr*Q`, an arbitrary
permutation) only works via the index buffer, so build that first and it
covers everything.

### 2.1 What `kk.compile[f; shapes]` does

Input: a whole-array lambda `f` plus the placements/shapes of its arguments.
Output: (pipeline; binding plan; dispatch size; schedule). Steps:

1. Parse f, classify each expression by the rewrite table (below). Anything
   outside the table → compile error naming the verb (no silent fallback).
2. Free names resolve as: placed array → storage binding; host numeric
   scalar → baked constant (exists); host numeric *vector* → auto-uploaded
   read-only buffer (new — this is how `W`, `I`, `Wr`, `denr` travel).
3. Emit ONE per-thread kernel body as IR, reusing the existing nodes:
   gathers → `bufidx`, amend stores → `setb`, amend-with-+ → `sadd`, small
   fixed-axis reductions → `rsum` region nodes.
4. Cache keyed by (lambda source hash; argument shapes/placements). Same
   monomorphic call-site idea as the CPU compiler's alias pass, on arrays.

### 2.2 The rewrite table, with lowering per row

Thread space = output elements unless a row says otherwise.

| k form | lowering (thread d) |
|---|---|
| `g' d` (each, g scalar-lambda) | `out[d] = g(u[d])` — inline g's body, param bound to the load |
| `g'[d;e]` (zip) | `out[d] = g(u[d], v[d])` |
| `d + e`, `sqrt d`, … (whole-array arith) | same as each: elementwise map over operand loads |
| `x @ w` (w placed/host vector) | `out[d] = u[wbuf[d]]` — index-buffer gather |
| `x @ W` (W a (k;n) matrix, e.g. `off+\:I`) | k gathers per thread: `u[wbuf[j*n+d]]`, j=0..k-1 |
| `+/ x @ W` (reduce over the small axis) | `rsum[k; {[j] u[wbuf[(j*n)+d]]}]` — one region node |
| `@[x;I;:;v]` | thread per element of **I**: `set[x; ibuf[d]; v-expr(d)]`; untouched positions untouched → in-place schedule (see 2.3) |
| `@[x;I;+;v]` | `scatterAdd[xacc; ibuf[d]; v-expr(d)]` — x must be an i32/fixed-point accumulator placement (or float-atomic when caps allow, §7) |
| `f'[n;d]` (stencil adverb) | `out[d] = f(u[d..d+n-1])` — n static relative loads; output length n-1 shorter (k semantics; host trims via the descriptor) |
| `f': d` (eachprior) | window-2 case of the above |
| `n g/ d` (iterate, buffer state) | **host schedule**: n dispatches recorded in one encoder (`gpu.dispatchLoop`), ping-pong per 2.3 |
| `n g/ x` (scalar state) | in-kernel `ndo` (exists) |
| `+/ {[j] e}' !k` | `rsum` region node — retires the `rsum` intrinsic name; `|/` → `rmax`, `&/`/`*/` need FMin/FMul variants (trivial: same loop, different combine) |

Out of scope for tier 1 (tier 2, needs scan/whole-buffer-reduce infra):
`+/ d` over the whole placement, `+\`, `&m` compaction, `=` group, sort.

### 2.3 The two schedule rules (never inferred beyond these)

- **Ping-pong**: `n g/ d` where g's body *gathers* from its argument (any
  `x@…` with non-identity index) → two buffers, alternate bindings per pass
  (`gpu.dispatchLoop` a/b configs — exists). If g only reads `x[d]`
  elementwise, in-place single-buffer is safe.
- **In-place**: `@[x;I;:;v]` *as the fold body's result* writes into x's own
  buffer only when the gather set and write set are provably disjoint per
  pass — which the compiler does NOT prove; it ping-pongs by default. The
  red-black/in-place schedule stays a per-thread escape-hatch choice
  (`shader.stencilIP` semantics). Honesty over cleverness.

### 2.4 Milestones (each independently testable)

1. **DONE (2026-07-16).** `+/{…}'!k` → `rsum` recognition inside existing
   kernels (`|/` → `rmax`); intrinsic names retired from new code (kept
   compiling — both spellings share `xRed`, so they are byte-identical by
   construction). Recognition lives in `xAppos`→`xApposAdv`→`xFoldEach`
   (lib/dye.k): a monadic apposit whose f is a `/`-term over `+`/`|` and whose
   argument is each-lambda-over-`!K`. Any other monadic adverbed verb warns +
   bakes NaN (no silent fallthrough to negate). Oracle: test/kkgold.k asserts
   gemm + softmax byte-identity across the two spellings (foldSum/foldMax
   lines), and the 12 gold dumps are unchanged. lib/nn.k fully migrated (15
   sites, all 12 kernels byte-identical; test/nn.k maxerr unchanged on GPU) —
   no other demo used the intrinsics.
2. **DONE (2026-07-16).** Elementwise `kk.compile[fn; descriptors]`: a whole-
   array lambda in implicit-param form (`{2.*x}`, `{x+y}`, `{(x+y)*z}`,
   `{sqrt x}`, `{$[x<y;y;x]}`) → dye's new `shader.map[fn; nIn]` (an N-input
   per-thread map, input k = binding k loaded at gid into x/y/z, body → out at
   binding nIn; generalises compCompute/compute2), dispatched over the
   placements (thread = element), returning an OUTPUT descriptor so
   `8: kk.compile[…]` reshapes like any placed array. Pipeline cached by
   (lambda source; #inputs); output buffer padded to the ×64 grid (descriptor
   n/s stay the real extent → 2-D shape round-trips). `kkClassify` enforces the
   subset — gather (`@`), amend, adverbs and non-math applies are rejected with
   the offending verb NAMED (no silent fallback). Oracle: test/kkc.k, GPU vs
   CPU bit-for-bit (sqrt at f32 tol) + cache-reuse + rejection (9/9). Gotchas
   (now in memory): `str in list` is CHAR-wise (a string is a char vector, not
   an atom) and `$[]` reads the non-empty result as true → string cache keys
   are false hits; use symbol keys. An inner lambda can't see a sibling local
   lambda (no closure) → hoist shared test helpers to globals.
3. Index-buffer gather + `rsum`-over-W: walk.k's interior update expression.
   **DONE (2026-07-16), except host-vector auto-upload.** (i) Single gather
   `x@y` → `out[d]=data[idx[d]]`: a param left-of-`@` is a gather SOURCE (`buf,
   indexed), other params are `elem indices auto-loaded at d. dye grew an `elem`
   role (`xVarE`/`xElem`: a bare buffer name → buf[d]), `@`→nested buffer-index
   (`xGather`), and `shader.gmap[fn; bufNames; elemNames]`. (ii) `+/x@W` /
   `|/x@W` matrix gather-reduce: `xApposAdv` recognises a `/`-fold over an
   `@`-transit and emits a real `rsum`/`rmax` region node whose body is
   `x[W[(j*n)+d]]` (`xRedGather`); `k`,`n` come from W's descriptor shape, baked
   via `GRk`/`GRn` (cache key carries them), output length = n. kk.compile
   branches `kkIsMatReduce[]` → `kkGathMat` → both operands `buf`. (iii)
   **Host-vector free-name auto-upload:** a gather operand that ISN'T a param
   (x/y/z) is a host global — `kkResolve`/`kkUpload` reads its value (`. nm`) and
   `gpu.hold`s it read-only, taking the `(k;n)` shape from the value (§2.1-2). So
   **walk.k's `1.+.25*+/x@W` with `W` a host global compiles and matches the CPU
   bit-for-bit** (test/kkc.k, 14/14). MINOR GAP: single gather `x@w` still needs
   both operands passed as placements (auto-upload is wired only through the
   matrix-reduce path `kkGathMat`, which is what walk.k uses). Gotchas found:
   `f'(!0)` (each over an empty TYPED vector) → general-list `()`, `&()`/`v@…`
   spuriously yields one element (guard empty); joining `` `x`y `` with `!0`
   (empty INT vec) upcasts to boxed `L (breaks the env dict) — use `0#\``; the
   rsum path needs `kAlloc[…;hasLoop=1]` for loop consts; `gpu.hold . nm` parses
   `.` as DYADIC (name on its left) — take the value in its own statement.
4. Amend-scatter (`setb` thread-per-I) + masked write; then `n f/ d`
   ping-pong recording. **Acceptance: walk.k's `f` verbatim, E@center =
   2887.34 (Jacobi f32 fixpoint value), against the CPU run.**
   **DONE (2026-07-16). ACCEPTANCE MET: E@center = 2887.3418.** (i) Amend
   `@[x;I;:;v]` → `shader.amend`: one thread per interior index d; the value
   expr (arg 3 of the `@`-apply, e.g. `1.+.25*+/x@W`) compiles through the
   gather-reduce IR reading x/W as buffers, then `kScatStore` writes
   `out[I[d]] = v`. Detected by `kkIsAmend[]` (an `@`-apply whose 3rd arg is the
   `:` verb). I is padded to the ×64 grid with a sentinel index (= full length)
   that lands in out's padding, so over-dispatched threads don't clobber a live
   cell; out starts as a copy of x so non-interior (boundary) cells carry
   through. (ii) **`kk.loop[f; x0; niter]`** ping-pongs two full-size buffers
   through `gpu.dispatchLoop` (one encoder, barriers handled) — each sweep reads
   one buffer and writes the other; result buffer chosen by `niter` parity.
   walk.k's `f:{@[x;I;:;1.+.25*+/x@W]}` compiles **verbatim**; 30k sweeps on the
   100×100 grid converge to E@center = 2887.3418 (test/walkgpu.k). Small-grid
   single-sweep + ping-pong checks in test/kkc.k (17/17). NOTE: walk.k's literal
   spelling is `f/` (converge-to-fixpoint); `kk.loop` is the fixed-count `n f/`
   form — true device-side converge (tolerance + periodic readback) is §6/tier-2.
5. `@[x;I;+;v]` → `sadd` (spatial-hash histogram from `test/spacial.k` as the
   demo). **DONE (2026-07-16).** `@[x;I;+;v]` → `shader.scatadd`: one thread per
   index d, `acc[I[d]] += i32(v)` via `OpAtomicIAdd` (`kScatAdd`) so duplicate
   buckets accumulate race-free. acc is an i32 accumulator (binding 0, expected
   zero-inited); I (binding 1) is padded with a sentinel into acc's padding tail;
   v is a constant (baked) or a single value vector (`elem`, binding 2). Detected
   by `kkIsScatAdd[]` (an `@`-apply whose 3rd arg is `+`); the result descriptor
   is tagged `t:`i` and `gpu.fetch` reads it via `gpu.readI`. Oracle: test/kkc.k
   count + skewed + weighted histograms vs CPU `@[…;+;…]` (19/19). Deferred:
   float fixed-point scaling (weighted float accum) and paired/multi-value
   scatters (spacial.k's `@[px;k;+;(…),…]`).
6. Placed tables (§2.5): clothgpu's edge kernel on named columns.
   **DONE (2026-07-16), elementwise slice.** `gpu.holdT[t]` places a k table as a
   structured buffer — one resident buffer per column (planar/splayed), the
   descriptor carrying `cols`+`hand`. `kk.compile` detects a table arg
   (`t:`tbl`) → `kkTable` → `shader.table`: a column read `(t`c)` (an apposit
   var+symbol, bound to a `table env entry = a col→bufp dict) element-loads that
   column at the thread index (`xTableCol`/`xIsTableCol` in xAppos). Binding
   inference (`kkTableColNames`) passes only the columns the body mentions, so
   dead columns cost nothing — the kdb splayed-column property on the device.
   The CPU form `t`c` already IS the column, so the same lambda runs both sides.
   Oracle: test/kkc.k column arithmetic `(x`px)+(x`vx)`, `((x`px)*(x`vy))+(x`py)`
   vs CPU + a 3-of-4 pruning check (22/22). Deferred: interleaved layout (the
   MAX_BIND=8 knob), placed dicts (ragged CSR), and tables composed with
   gather/reduce/scatter (clothgpu's edge kernel).

### 2.5 Placed tables ("colored arrays") — structured buffers as k tables

Werner's proposal (2026-07-16): a table — k's native SoA, named equal-length
columns `` `px`py`vx`vy `` — is the kk representation of a *structured* GPU
buffer. Kernels then read named fields:

```k
/ today (clothgpu.k): 7-float packed records, layout in a comment
pi:e[base]; pj:e[base+1.]; l0:e[base+2.]; al:e[base+3.]; …
/ placed table: self-documenting, no stride arithmetic
E: 9: [[]i:ei; j:ej; l0:l0; al:al; w0:w0; w1:w1; wt:w0+w1]
… (E`l0) + (E`al) % sdt*sdt …
```

- **Placement**: `9: table` → a descriptor whose `gpu` is a dict of column
  handles (or one handle + layout tag, below); `t`/`n`/`s` per column.
- **Kernel lowering**: a column select `` t`c `` is just a buffer reference —
  the existing `bufp`/`bufidx` IR nodes; nothing new in the IR.
- **Binding inference prunes columns**: only columns the kernel body mentions
  are bound (and, for host tables, uploaded) — dead columns cost nothing.
  This is the kdb splayed-column property carried onto the device.
- **Layout is a schedule choice (Tiramisu L3), not semantics.** Planar
  (buffer per column) is the default: simplest, and best coalescing for the
  array-language access pattern (each thread touches few fields across many
  rows). Interleaved (ONE buffer, stride = #cols, field k at `d*nc+k` — "we
  know how many columns, so indexing is linear") wins when a thread touches
  *every* field of one row (the cloth edge kernel), and keeps binding count
  down — relevant because `vk.zig` `MAX_BIND = 8`, which a 7-column table
  plus accumulator plus params already exceeds in planar form. v1: planar,
  interleave when #bindings would exceed the cap; later a per-kernel knob.
- **Placed dicts** (the companion idea): a dict of placed arrays of
  *differing* lengths as one named binding group — CSR ragged data
  (`[data: …; off: …]`, exactly lib/shp.k's CPU convention), state+params
  pairs. Same name-resolution machinery, no equal-length constraint.
- **Tensors are NOT tables.** Shapes (`%x`/`s`) and columns are orthogonal
  axes that compose: dense homogeneous dims (NN weights, grids) stay shaped
  placed arrays; heterogeneous per-row records are tables; ragged is a CSR
  dict. A vector field is 3 scalar columns (`px`py`pz`), pure k style.
- **CPU symmetry is free**: `` t`px `` on a real table already IS the column
  vector, so `` a`px + b`vy `` runs on the CPU today unchanged — only the GPU
  lowering is new work. (CPU columnar *layout* optimization: deferred, per
  Werner.)

## 3. Finish the seam: fragment/vertex on the IR, delete the direct path (increment 4)

- **Fragment — DONE (2026-07-16).** Added a `sample` IR node (two loads,
  OpSampledImage, ImageSample) and a `consc` node (vector-literal
  OpConstantComposite — the fragment subset needed it, compute never had vec
  literals); `kSeqIr` grew an `oty` argument; `shader.fragment`/`fragmentTexN`
  switch to it. Oracle: 7 fragment/vertex/texture cases added to test/kkgold.k
  and captured via the direct path BEFORE migrating; byte-identical after +
  spirv-val vulkan1.2 on all.
- **Vertex(+U) — DONE (2026-07-16).** Outputs are compiled interleaved with
  their stores, so plain build-then-lower would permute ids. Added a `vstore`
  effect node (xVal=`` `pos `` → gl_Position through the gl_PerVertex block
  member via a fresh access-chain id allocated at the node's build position;
  else a varying output var id, stored directly) so stores sit in the IR at
  their direct positions — same trick as `f2s`. Body prefix walked by
  `xSeqEnv` (mirror of the retired compSeqEnv). Instancing: still stubbed,
  folds into §5 vertex-pulling.
- **Deleted the direct comp\* walkers — DONE (2026-07-16).** With every entry
  point on the IR, removed ~376 lines: `compNode`/`compSeq`/`compSeqTail`/
  `compApply`/`compList`/`compCond`/`compFnCall`/`compVecLit`/`compLit`/
  `compVar`+`kBake`/`compLeGe`/`compTrans*`/`compAppos`/`compApplyIdx`/
  `compBufIdx`/`compScatterAdd`/`compSet`/`compIget`/`compIset`/`compRsum`/
  `compRmax`/`compNdo`/`compWhile`/`compAdverb`/`compSample`/`compSeqEnv`, plus
  the now-orphaned `dispUn`/`splat`/`mathFns1`. Live helpers kept (they moved
  onto the IR path): `dispBin`, `isBuf`, `loopOpen`/`loopClose`, `constId`,
  `loadOnePair`, the `RC*` loop-const globals. dye is now single-pipeline
  (1498→1122 lines). Verified: kkgold byte-identical, spirv.k 85/85, ir.k 7/7,
  nn.k GPU maxerr unchanged, planes.k renders.
- **Fold/DCE for compute — DONE (2026-07-16).** Added the `xOpt` flag
  (default 0 = lower every node → byte-identical, keeps the kkgold diff oracle;
  1 = optimize). `xLowerC` runs `xFold` then `xReachC`, a multi-root reach
  whose roots = the value result(s) + every effect node (setb/sadd/isetb/
  vstore) + every loop node AND its result phi(s) (rsum/rmax/ndo → accumulator/
  state; whileL → cond + body). Seeding the loop *results* makes the single
  high→low xArg sweep descend into owned loop bodies and mark the top-level
  values they read (e.g. a `base` computed before the loop) — otherwise those
  get culled; `xLoRegion` gates owned nodes on `xRe` too, so dead nodes inside
  loop bodies are pruned as well. Oracle (as designed, dropped one rung):
  test/nn.k GPU output **bit-identical** with xOpt on (semantics preserved
  across GEMM/softmax/LN/attention/conv), all 19 kkgold modules spirv-val-clean
  under xOpt, and it's effective (a dead `g[1]` load + a `0.5*0.5` const both
  vanish) while stores/atomics/phis survive. New structural oracle test/kkopt.k
  (9 checks). Default stays 0 so kkgold byte-identity still guards refactors;
  flip xOpt when kk.compile starts generating IR with real dead code.
- **i32 index type**: `f2s` results and loop counters already are i32; the
  step is letting index *arithmetic* stay integer (OpIAdd/OpSDiv/OpSRem on
  `i32-typed nodes) instead of round-tripping through f32, killing the 2^24
  exactness cliff and the `floor[d%3.]` idiom (becomes `d div 3` / `d mod 3`).
  User-visible kernel semantics keep f32 thread index for compatibility;
  kk.compile-generated kernels use i32 indices from day one.

## 4. `bits` v1: the CPU backend (increment 6)

Lower the elementwise IR subset to a FusedMap `Kernel` (tape.zig):

| IR | KOp |
|---|---|
| `param` | `Col` (operand index) |
| `const` | splat (needs a `Const` KOp or a synthetic scalar column) |
| `arith` + - * % | Add/Sub/Mul/Div |
| `arith` < > = & \| | Lt/Gt/Eq/Min/Max (0/1 discipline, `result_bool` at root) |
| `math` sqrt/exp/log/sin/cos, `neg`, sqr | existing monadic KOps |
| `select` | needs a `Select` KOp (@select over three lanes) |
| `bufidx` | needs a `Gather` KOp (indexed load from an operand column) |

Wire-up: a `bits.compile[…]` entry in dye returns `(kcode; ncol; …)`; a small
Zig hook installs it as a chunk kernel + `FusedMap` op (or v1 runs it through
a dedicated eval FFI). First deliverable needs no new KOps at all: generate
`test/nn.k`'s CPU reference implementations from the same kernel lambdas and
delete the ~300 hand-written `gref`/`sref`/`mref` lines — maxerr becomes the
permanent cross-backend oracle. Loops lower as plain k loops around FusedMap
calls in v1 (no in-kernel KOp loops).

## 5. Vertex pulling (increment 7)

A vertex shader becomes a kernel-shaped function of `(buffers…; vid)`
returning `(pos_v4; varyings…)` — storage-buffer reads indexed by
`gl_VertexIndex` (base Vulkan, no caps needed). Plan:
1. `shader.vertexPull[varyTypes; fn]`: reuse `kAlloc`-style binding
   allocation + the vertex module interface (gl_PerVertex block, varyings);
   body through `kSeqIr` with a `vid` param (Input i32 builtin 42 →
   VertexIndex 5? — check: BuiltIn VertexIndex = 42 in decoration terms is
   `BuiltIn 42`… verify against the spec table when implementing).
2. `mesh.compilePull[vtx; frag]` + `mesh.drawPull[pipe; buffer-dict; count]` —
   no vertex-input state, no stride derivation.
3. Port `clothgpu.k`: render pulls straight from the resident `P`; per-face
   normals become one more compute kernel; the per-frame
   `8:`→buildMesh→re-upload loop is deleted. Then `earth.k`.
4. Instance index the same way (`gl_InstanceIndex`) — subsumes the stubbed
   instancing exports; delete them.

## 6. Whole-buffer reductions (increment 8, tier 2 gateway)

`+/ d` on a placement: two-stage — workgroup partials into a small buffer,
second dispatch folds partials (host reads one float at `8:`). With
`gpu.caps` sgArith=1, stage 1 uses `OpGroupNonUniformFAdd` (subgroup 32) +
one shared-memory hop; fallback is a plain strided loop (rsum) per workgroup.
**Prerequisite for both descriptor-indexing/atomic-float/subgroup work: the
features must be ENABLED at device creation** (`VkPhysicalDeviceVulkan12
Features` / atomic-float EXT chained into `VkDeviceCreateInfo.pNext` in
`vk.zig` — today we only *query*). Do the enable plumbing once, gated on the
same caps struct. This unlocks tolerance-based `g f/ d` (device-side `|/abs
Δ` + periodic readback) replacing bit-fixpoint grinds.

## 7. Float atomics

caps report `atomicFadd=1` on the M1 Pro: `@[x;I;+;v]` can lower to native
f32 `OpAtomicFAddEXT` (capability `AtomicFloat32AddEXT` + SPV_EXT_
shader_atomic_float_add) instead of the i32 fixed-point dance — clothgpu
loses `SC` entirely, and the velocity-jitter floor it causes. Keep the
fixed-point lowering as the caps=0 fallback. Needs the §6 device-enable
plumbing first.

## 8. Decisions (reviewed 2026-07-15) + remaining questions

1. **Error signaling — DECIDED: quoted-symbol errors, `` `"msg" ``.** User
   errors carry a quoted symbol as their name — signaling `` `"cannot bake
   FOO" `` produces an err-class value that prints `` !"cannot bake FOO" ``
   and aborts evaluation like `!type` does, so dye/kk compile errors become
   real errors instead of the current warn+bake-NaN. Micro-decision still
   open: the raising *spelling* (a small `signal`-style prelude name backed
   by an Op1 is the least grammar-invasive candidate). Replaces `kBakeBad`/
   `xBakeBad` and every future kk.compile error path.
2. **Placed-array v2 — DEFERRED indefinitely.** The only thing it buys is
   sugar: `d+e` on two placements silently compiling a kernel requires the
   runtime to dispatch verbs on a new placement class. Explicit compilation
   (`kk.compile` / `gpu.pipeline`) plus the `9:`/`8:` io verbs cover the
   whole roadmap without it; revisit only if the sugar is ever actually
   missed.
3. **rsum/rmax — DECIDED: full syntax is canonical. LANDED 2026-07-16.**
   `+/{[k] e}'!K` (and `|/…`) is the spelling everywhere — demos, libs, docs;
   `rsum`/`rmax` remain as documented equivalents (teaching code / spec of
   the lowering), not deprecated, but no new code uses them. §2.4-1
   recognition landed and lib/nn.k is migrated (see §2.4-1).
4. **Shapes — DONE (2026-07-15): monadic `%` is the Shape verb** (Werner's
   call: the glyph was free — ink moved sqrt to the prelude, so the ngn/k
   monadic-% meaning was vacated; the dyad stays divide). `%x` = rectangular
   extent as an int vector, APL-rho semantics with the k twist that ragged
   lists stop at the first non-uniform level: `%5`→`!0`, `%1 2 3`→`,3`,
   `%(1 2;3 4;5 6)`→`3 2`, `%(1 2;3 4 5)`→`,2`; `(%m)#,/m ~ m`. Implemented
   in `src/primitive/verb/shape.zig` + unit tests. Descriptors record
   `s: %x` at `9:`/`gpu.hold` (nested rectangular input flattens for
   upload) and `8:` reshapes the readback to `s` — so `8: 9: (N;N)#x`
   round-trips the matrix. This is what gives 2-D stencils their row pitch,
   `(k;n)` index matrices their k-vs-n, and kk.compile its dispatch sizes.
5. **RNG** (walk.k's Monte-Carlo half; philox counter-based; `?` lowering) —
   still open: tier 2 or its own increment.

## 9. Suggested order

1. ~~§2.4-1 rsum recognition~~ **DONE 2026-07-16** (established the IR-rewrite pattern)
2. §3 **DONE 2026-07-16** — fragment/vertex migration + delete direct walkers
   (single-pipeline dye, −376 lines) + multi-root fold/DCE (xOpt flag). Only
   i32 index arithmetic remains from the §3 grab-bag (folds into incr 5)
3. §2.4-2..4 kk.compile through the walk.k acceptance (the headline)
4. §6 device-feature enabling + whole-buffer reduce (unlocks 7 and tier 2)
5. §5 vertex pulling (clothgpu readback deletion — the visible payoff)
6. §4 bits v1 via generated nn references (cross-backend oracle forever)
7. §7 float atomics, §3 i32 indices, tier 2 scans/compaction
