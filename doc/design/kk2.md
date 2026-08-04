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
  literal `(k:v;…)` works as a lambda tail; ink has **no signal verb** — dye
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
5. `@[x;I;+;v]` → `sadd` (spatial-hash histogram from `demo/spacial.k` as the
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
E: 9: ([]i:ei; j:ej; l0:l0; al:al; w0:w0; w1:w1; wt:w0+w1)
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
  (`(data: …; off: …)`, exactly lib/shp.k's CPU convention), state+params
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
  (9 checks). **Default flipped to 1 (on) 2026-07-16**: kk.compile now emits IR
  with real dead code (e.g. pruned table columns, unused `g[]` slots), so the
  optimizer earns its keep on every compile. kkgold pins `xOpt::0` in-file to
  keep its byte-diff oracle; correctness under the optimizer is guarded by the
  numeric-parity oracles (nn/kkc/walkgpu, all re-verified bit-identical / PASS)
  plus kkopt's safety asserts.
- **i32 index type — DONE 2026-07-16.** kk.compile-generated kernels keep index
  arithmetic in i32: the thread index `d` (GIrGid) is the gid bit-cast to i32
  (`kGidI`, no `u2f`→`f2s` round-trip), `xElem` indexes `buf[d]` directly, and
  the matrix gather-reduce address `(j*n)+d` is `OpIMul`/`OpIAdd` on i32 nodes
  (`j` = the raw i32 loop-counter phi via the new `kparami` op; `k`,`n` are i32
  consts). `dispBin` gained an `isi` (rty~`i32) guard emitting integer ops
  (IAdd/ISub/IMul, SDiv for `%`); f32 kernels are untouched (byte-identical).
  Only the *loaded* index value keeps its `f2s` (it's stored f32 in W). This
  kills the 2^24 exactness cliff on address math. spirv.k added opSdiv/opSrem/
  opBitcast. User-visible kernels (gpu.kernel/shader.*) keep the f32 thread
  index for compatibility — verified via kkgold byte-identity + nn bit-identity;
  kkc 22/22, walkgpu PASS.

- **Integer-index dialect (explicit) — DONE (2026-07-17).** `gpu.kernelI` /
  `shader.kernelI` (an `iidx` flag on `compGpN`/`kernelInfer`) give the user-facing
  kernel an **i32 thread index**; index arithmetic then stays integer end-to-end.
  The dialect gained: explicit casts `` `i$x `` (f32→i32, OpConvertFToS) / `` `f$x ``
  (i32→f32, OpConvertSToF) — the ONLY conversion, no auto-coercion (Werner's call:
  simplest, honest about truncation); the integer verbs `d div n` / `d mod n`
  (OpSDiv/OpSRem, added to `binRty`+`dispBin`) alongside the existing `d%n` (SDiv on
  i32) and `mod[d;n]`; an i32 fold counter (`+/{[k] e}'!K` binds `k` via `kparami`
  when in i-mode); and a centralized `xIdx` helper so EVERY index consumer (bufidx,
  set, iget, iset, scatterAdd, gather) takes an i32 index directly (no f2s) when the
  operand is already i32. So `{[c;a;b;g;d] n:`i$g[1]; kk:`i$g[2]; i:d div n; j:d mod
  n; set[c;d; +/{[k] a[(i*kk)+k]*b[(k*n)+j]}'!kk]}` compiles clean and matches the
  f32-index GEMM and the CPU bit-for-bit. All of this is gated on the `Xidx` flag
  (default 0), so the f32 dialect is **byte-identical** (kkgold) and all existing
  demos are untouched. Oracle: `test/kkint.k` (4/4: f32==CPU, i32==CPU, i32==f32,
  i32 transpose-scatter to a computed index). Also unblocks §4 CPU-runnability
  (integer indices run on the CPU interpreter; f32 indices don't).

- **DEFAULT FLIPPED (2026-07-17).** `gpu.kernel`/`shader.kernel` (and the `F`
  variants) now compile the integer-index dialect; `kernelI` remains as an alias
  and the legacy f32 dialect is reachable via `compGpN[fn;nAcc;nBuf;fa;0]` /
  `kernelInfer[fn;fa;0]` (test/kkint.k pins legacy==default==CPU on the GEMM).
  The dialect grew what migration actually needed: (i) **int literals stay i32**
  under Xidx (`d mod 3`, `(2*tp)+kt-1`, `$[ax=1;…]` — "write what you mean":
  3 is an index, 3. is a float); (ii) **integer comparisons** — `< > = ~` emit
  OpSLessThan/SGreaterThan/IEqual/INotEqual when the left operand is i32
  (spirv.k opSGT/opIEq/opINe); (iii) Xidx::0 resets in the fragment/vertex
  preludes so a kernel compile can't leak the dialect into the next shader.
  Migrated: lib/nn.k (14 kernels — div/mod decompositions, `` `i$g[k] `` bounds,
  lnStat keeps a float `nf` for the mean/var divides), test/clothgpu.k,
  demo/clothbench.k, test/kkgold.k + test/kkopt.k bodies (kkgold re-baselined).
  Oracles: all 7 + the full nn stack (nn/frontend/subsample/relpos/conformer/
  weights) pass; cloth drape and walkgpu E@center bit-identical to pre-flip.
  **New oracle rung: `spirv-val` over every kkgold dump** (wired into
  test/oracles.sh, skipped if not installed) — it immediately caught an
  `$[ax=1.;…]` float-vs-i32 compare that MoltenVK silently tolerated, exactly
  the class of bug numeric oracles can miss.

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

**DONE (2026-07-17) — mechanism + clothgpu port.**
- **`shader.vertexPull[varyTypes; fn]`** (dye): fn is a kernel-shaped
  `{[buf0;…; vid] (posV4; vary0;…)}` — the LAST param is `gl_VertexIndex`
  (BuiltIn **42**, loaded as i32 → f32 like the compute thread index), every
  other param is an f32 StorageBuffer read at that index (`buf[3.*vid]`). Reuses
  the compute `bufidx` IR for the body and the `shader.vertexU` output interface
  (gl_PerVertex block + varyings + `vstore` effect nodes). One new type-set (f32
  runtime-array storage types + an Input-i32 pointer) hand-assembled; the vertex
  execution model has no OpExecutionMode. spirv-val-clean (vulkan1.2) for
  0-buffer/N-buffer × 0/N-varying.
- **`createPullPipeline`/`drawPull` (vk.zig) + `gpuMeshPull`/`gpuDrawPull`
  (gpu_vk.zig) + `mesh.compilePull`/`mesh.drawPull` (gpu.k).** A graphics
  pipeline with EMPTY vertex-input state; `nbuf` storage buffers (inferred by
  counting StorageBuffer OpVariables in the vertex words) bound at set 0, VERTEX
  stage, via a per-frame descriptor pool (`pull_upool[FRAMES]`, reset in
  beginFrame). The draw is `vkCmdDraw(count,1,0,0)` — no vertex buffer. Pull draws
  record after meshes/geoms in the frame; `gpuRun` already `v.sync()`s the
  callback's compute before the frame, so the vertex shader reads the FINAL P.
  Smoke test: `demo/vpulltri.k` (a gradient triangle pulled from a resident buffer
  by gl_VertexIndex — renders, varyings interpolate).
- **clothgpu.k ported.** `clothVtxPull` reads the resident position buffer `P`
  and a resident triangle-index buffer, gathers its triangle's 3 particle
  positions, computes the face normal IN-SHADER (cross of the edges; `|·|` is
  OpLogicalOr in kernels, so the length floor uses a `$[…]` select not `|`),
  and outputs the projected clip position + PBR varyings (material/lighting baked
  constants). The `gpu.read[P]`→`buildMesh`→re-upload loop is DELETED —
  `mesh.drawPull[gPull; (P;Ptri); 3*nTris]` pulls straight from the device.
  Rasterizer cull NONE gives both sides from one draw (single-sided geometry).
  Verified: renders the blue cloth flat at frame 0 and correctly draped/folds-lit
  at frame 80; the headless sim invariant is untouched (oracle still PASS). GAP:
  double-sided per-side normals (the old 6-verts/tri) and `earth.k` + instancing
  (`gl_InstanceIndex`) not ported — single-sided is enough for the demo.

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

**DONE (2026-07-16) — device-enable + fallback reduce + device converge.**

- **Device-feature enable (the prerequisite).** `vk.zig` now chains the queried
  caps into `VkDeviceCreateInfo.pNext` at BOTH create sites (`init` headless +
  `initWindowed`): a `Features` struct bundles `VkPhysicalDeviceFeatures2` →
  `Vulkan12Features` (descriptorIndexing/runtimeDescriptorArray/bufferDeviceAddress/
  shaderFloat16) → `ShaderAtomicFloatFeaturesEXT` (shaderBufferFloat32AtomicAdd),
  each field gated on the matching `Caps` bool. `enabledFeatures(caps)` fills it;
  `feat.link()` re-wires the pNext self-pointers after the by-value return (Zig
  copies the struct, invalidating helper-local `&` pointers — the one trap here).
  `VK_EXT_shader_atomic_float` joins the enabled-extension list only when present.
  Subgroup arithmetic needs no enable (core 1.1). Verified: gpu.caps unchanged
  (all green), nn/kkc/walkgpu bit-identical — enabling regresses nothing, and §7
  float atomics + bindless can now actually be *used*, not just queried.
- **`shader.reduce[op]` + `kk.reduce` — the two-dispatch FALLBACK.** One fixed
  kernel (in@0, out@1, uniform vec4@2 = `(n; T; Kmax; _)`): thread `d` combines
  `in[d], in[d+T], …` over `Kmax` guarded steps via the existing `loopOpen`/
  `loopClose` scaffold (counter = k, state = accumulator), OOB steps clamp the
  index to 0 and `select` the identity so correctness never leans on padding.
  `op ∈ sum`max`min`prod` picks identity (`0`/`-1e30`/`1e30`/`1`) + combine
  (FAdd/FMax/FMin/FMul). Host runs it twice (`kk.reduce`): stage 1 = P=256
  grid-strided threads → P partials; stage 2 = T=1 on one thread → the scalar
  read back at `8:`. `kk.sum`/`max`/`min`/`prod` wrap it. Cached per op. Oracle:
  `test/kkred.k` (12 checks) vs CPU `+/`/`|/`/`&/`/`*/` — exact for integer/max/
  min, relative-tol for reordered float sums; all four ops spirv-val-clean
  (vulkan1.2). Limit: `n` travels as an f32 uniform → exact only to 2^24 elems.
- **Subgroup fast path — DONE (2026-07-17).** `shader.reduceSg[op; S]`: same
  grid-strided per-lane accumulate, but LocalSize = the subgroup size `S`, so ONE
  workgroup == ONE subgroup and a single `OpGroupNonUniformFAdd`/`FMax`/`FMin`/
  `FMul` (Reduce over the Subgroup(3) scope) folds the whole workgroup with NO
  shared memory and NO barriers — simpler than the Workgroup-storage-class +
  `OpControlBarrier` design the sketch assumed. `lane = gid mod S`, `wgId = gid
  div S` are EXACT (a 1-D workgroup's invocations are contiguous in gid), and lane
  0 stores `out[wgId]` under an `OpSelectionMerge`. New machinery: an `AKsg` flag
  (kAsm emits `OpCapability GroupNonUniformArithmetic` 63) and an `AKlsz` per-kernel
  LocalSize override (the exm LocalSize is `S`, not the sticky `wg=64`), plus the
  four group-op stencils + `opSelMrg` in spirv.k. Host `kkReduceSg` dispatches G·S
  threads → G partials, then folds G with one workgroup; `kk.reduce` picks it when
  `gpu.caps sgArith` (cached via `kkGetCaps`), `kkRedForceFb` forces the fallback.
  Oracle: kkred asserts `subgroup == fallback == CPU` (exact) + default-uses-sg;
  all four ops spirv-val-clean; kkgold byte-identical (capSG/AKlsz gated off for
  every existing kernel). Perf is the point but the reduce isn't a current
  bottleneck (per-call `8:` sync dominates a micro-bench); numeric contract is
  identical to the fallback either way.
- **`kk.converge[f; x0; tol; maxIter]` — device-side converge.** Ping-pongs the
  amend sweep in batches of `CVstride`=100 (even → always lands back in buffer A);
  every batch checkpoints A into `snap`, runs the batch on-device, then measures
  `|/abs(A-snap)` with `kk.compile[{abs[x-y]};…]` + `kk.max` (the whole-buffer
  reduce) and reads back ONE float; the while-adverb `cvCond cvBody/ (0; tol+1)`
  stops once maxΔ < tol or `maxIter` sweeps elapse. Shared context in `CV*`
  globals (no closures); terminal `(sweeps; maxΔ)` stashed in `CVlast`.
  ACCEPTANCE: walk.k's `f` verbatim on the 100×100 grid converges to
  E@center = **2887.3418** (bit-identical to the fixed-30k `kk.loop`) in **21300
  sweeps, tolerance-driven** (< the 60k cap; maxΔ→0.0), i.e. the solver now finds
  its own stopping point instead of a hard-coded sweep count. `test/kkred.k` adds
  a 20×20 converge==fixpoint + stopped-early check (14/14 total).

**DONE (2026-07-17) — first tier-2 primitives: prefix scan + compaction.**
- **`kk.scan[op; d]` / `kk.sums`/`maxs`/`mins` — inclusive `+\d`.** Three fixed
  kernels over P=256 CONTIGUOUS chunks (chunk = ceil(n/P)): `shader.scanBlock`
  (each thread scans its chunk locally into out + writes the chunk total),
  `shader.scanPartials` (thread d exclusive-scans the P totals by summing
  totals[0..d-1] — dispatch P, a multiple of wg, so d∈[0,P) with no overflow
  threads and no race), `shader.addOffset` (fold each chunk's offset back in). out
  is padded to P·chunk so the in-loop stores stay in-bounds and never race (chunks
  disjoint). op reuses `shader.reduce`'s identity+combine. Oracle `test/kkred.k`:
  exact vs CPU `+\`/`|\`/`&\` for int/max/min across chunk boundaries (n=1/256/257/
  1000), float total to rel-tol. All three spirv-val-clean.
- **`kk.where[mask]` — compaction (`&mask`).** Scan-then-scatter: inclusive-scan
  the 0/1 mask (kk.sums) for output positions + reduce it (kk.sum) for the true
  count (one-float readback), then `shader.compact` scatters each true index i into
  `out[incl[i]-1]`; false / over-dispatched threads scatter to a sentinel slot in
  out's padding (same trick as the atomic-scatter kernels). Returns a placement of
  the float indices, length = true count — mirrors CPU `&mask`. Value compaction
  `x@&mask` composes for FREE: `kk.compile[{x@y}; (x; kk.where mask)]` (the gather
  path). Oracle: where + value-compaction vs CPU, n>P, all-true/all-false edges.
  DEFERRED: `=` group (compaction-per-key) and sort (a full GPU radix/merge sort —
  its own increment); the subgroup fast paths for scan/reduce (perf only).

## 7. Float atomics

caps report `atomicFadd=1` on the M1 Pro: `@[x;I;+;v]` can lower to native
f32 `OpAtomicFAddEXT` (capability `AtomicFloat32AddEXT` + SPV_EXT_
shader_atomic_float_add) instead of the i32 fixed-point dance — clothgpu
loses `SC` entirely, and the velocity-jitter floor it causes. Keep the
fixed-point lowering as the caps=0 fallback. Needs the §6 device-enable
plumbing first — **DONE (§6): `shaderBufferFloat32AtomicAdd` is enabled +
the EXT is in the device extension list when `caps.atomicFadd`.**

**DONE (2026-07-17) — the `@[x;I;+;v]` (kk.compile) surface.** `opAtomicFAdd`
stencil (OpAtomicFAddEXT 6035, spirv.k) + `shader.scataddf`/`kScatAddF` (dye.k):
an all-f32 kernel (no i32 accumulator machinery) that adds the f32 value with NO
truncation, `kAllocScope` supplies the Device memory-scope const, and an `AKfa`
flag makes `kAsm` emit `OpCapability AtomicFloat32AddEXT` + `OpExtension
"SPV_EXT_shader_atomic_float_add"` (the SPIR-V ext name — distinct from the
`VK_EXT_shader_atomic_float` *device* ext; both string encodings verified by
spirv-dis). `kkScatAdd` (gpu.k) picks the path by caps: `kkUseFA` queries
`gpu.caps` once (cached in `kkFA`), uses `shader.scataddf` → `t:`f` result when
available, else the i32 `shader.scatadd` → `t:`i`; `kkScatForceI` forces the
integer path (exact histograms / fallback testing). Cache key carries `f`/`i`.
Oracle: `test/kkc.k` (23/23) — float-atomic counts vs `` `f$ `` CPU ref,
**weighted FLOAT accumulation bit-exact** vs `@[HB#0.;HI;+;HV]` (the thing the
i32 path could not do), and a forced-i32 fallback vs the int CPU ref;
`shader.scataddf` spirv-val-clean (vulkan1.2 + spv1.4). kkgold byte-identical
(the cap/ext words are gated on `AKfa`, zero-width when off).

**DONE (2026-07-17) — the `gpu.kernel` intrinsic surface + clothgpu.** Added a
float-accumulator kind to the general kernel path: `gpu.kernelF`/`shader.kernelF`
(`compGpN` gained an `fa` flag) type the `nAcc` accumulators as plain f32 buffers
(role `scatf`, no i32 machinery), `kAllocScope` supplies the Device scope const,
`AKfa` emits the cap/ext. `scatterAdd` on a `scatf` acc → a new `saddf` IR node →
`OpAtomicFAddEXT`; `iget`/`iset` on it are just an f32 `bufidx`/`setb` (no i2f/f2s
round-trip) — so ONE new node covers it. The i32 path is untouched and kkgold
byte-identical. `test/clothgpu.k` migrated: `kCon`/`kApp` use `gpu.kernelF`, `SC`
and the `%SC` rescale are GONE, `DP` is a genuine f32 accumulator. Headless drape
invariant (`INK_CLOTH_CHECK=1`, wired into `test/oracles.sh`): E@center-equivalent
`minY=0.0324` / `maxY=1.0` / no-NaN, matching the old i32+SC baseline (`0.0312`) to
~1e-3 — the fixed-point velocity-jitter floor is gone. SUBTLE BUG this exposed:
over-dispatched threads read OOB edge data → `ds`/`lam` go `inf`, and the `ok=0`
guard computed `0*inf = NaN`; the i32 path silently sanitised it (`f2s(NaN)→0`) but
native f32 propagates it — fixed by clamping OOB threads onto a valid edge so the
math stays finite before the guard zeroes it (a real correctness lesson for the
float path, now commented in clothgpu.k).

## 8. Decisions (reviewed 2026-07-15) + remaining questions

1. **Error signaling — LANDED 2026-07-16: err-values-with-messages, raised by
   monadic `!`.** `V.Err` is now a non-exhaustive `enum(u32)` whose value is a
   symbol-pool index; the 7 builtins (`domain length rank nyi memory type io`)
   are prefilled at fixed indices 16–22 (comptime-asserted against
   `builtin_symbols`), so all ~590 `.err = .x` sites compile unchanged and a
   user error is just any other interned symbol. Monadic `!` is the raising
   spelling: `` !`domain `` reproduces the builtin, `` !`whatever `` / `!"cannot
   bake FOO"` (symbol or string) an arbitrary one. The formatter resolves the
   index via the pool — identifier-shaped names print bare (`!domain`), messages
   quoted (`!"cannot bake FOO"`), both re-readable through monadic `!`. Marshal
   serializes err by *text* (name), not index, so it survives a fresh pool.
   `kkWarn` (kk.compile rejection), `xFoldBad`, and `xBakeBad` now signal errors
   instead of warning to stdout + baking NaN; the dye emitters latch the message
   in `xErr` and the module assemblers (`kAsm`/`buildMod`) return `!xErr`.
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
4. §6 device-feature enabling + whole-buffer reduce **DONE 2026-07-16** —
   feature-enable plumbing (both device-create sites), `shader.reduce`/`kk.reduce`
   two-dispatch fallback, and `kk.converge` (device-side tolerance converge, walk.k
   E@center=2887.3418 in 21300 tol-driven sweeps). Remaining §6 optimization: the
   subgroup `OpGroupNonUniformFAdd` fast path behind `gpu.caps sgArith`.
5. §5 vertex pulling (clothgpu readback deletion — the visible payoff)
6. §4 bits v1 via generated nn references (cross-backend oracle forever)
7. §7 float atomics (device-enable now landed), §6 subgroup fast path,
   §3 i32 indices, tier 2 scans/compaction

## 10. Post-phase-2 hardening (2026-07-19)

Three follow-ups from an architecture review — resident-buffer lifetime, encoder
residency, and the reduce/scan count cliff. Each is additive and oracle-guarded.

- **Resident-buffer lifetime.** `gpu.free[h]` (gpu_vk.zig `gpuBufferFree`) releases a
  resident buffer eagerly instead of waiting for device teardown: it tombstones the
  slot (`size=0`, so `resetRegistries` skips it and a double-free is a no-op) and puts
  the index on a free-list `g_bfree` that the next `gpuBufferNew` reuses — so placement
  churn (kk.compile output buffers, per-layer nn scratch, `kk.converge`'s per-batch |Δ|
  compiles) stays **bounded** instead of growing the registry unboundedly. `gpu.drop d`
  (lib/gpu.k) frees every buffer a placement descriptor owns (plain `gpu`, or a table/
  dict's `hand` list). Read/write/readI guard the tombstone.
- **Resident encoder (`EncoderR`, lib/nn.k).** The host composites (`FfnBlock`/
  `ConvModule`/`MhsaRel`/`ConformerBlock`) upload every weight and read the [T,D]
  activation back to the host between each conformer block — so a stacked encoder
  re-uploaded all weights and round-tripped once *per layer*. `EncoderR` uploads the
  weights ONCE (`nnHold`), keeps the activation resident across all blocks
  (`FfnBlockRB`/`MhsaRelRB`/`ConvModuleRB`/`ConformerBlockRB`), and frees each block's
  scratch with `gpu.free`. Same kernels + dispatch sizes as the host path, so it is
  **bit-identical** to `Encoder` (host round-trips are lossless f32 copies) — the
  oracle. `test/conformer.k` asserts `EncoderR ~ Encoder` and matches the CPU ref
  (maxerr 3.3e-7); `demo/asr.k` now drives the encoder through `EncoderR`.
- **Reduce/scan/compact count exactness.** These kernels carried their integer counts
  (`n`, stride, chunk, total) in an f32 uniform and `f2s`'d them — silently wrong past
  2^24. They now ship the raw i32 bits via `gpu.uniform` on an int vector (gpu_vk.zig `gpuUniformNewI`)
  and `opBitcast` the f32 lane back to i32 in the shader (compReduce/compReduceSg/
  compScanBlock/compAddOffset/compCompact) — **exact to 2^31**. `test/kkred.k` guards it
  with a `kk.max` over 2^24+51 elements (a count f32 rounds) whose max sits at the last
  index — found only if the count is exact — on both the subgroup and fallback paths.
  Small-n reductions stay bit-identical (kkred 33/33), and none of these kernels are in
  the kkgold byte-oracle so no dumps moved.

Still open from the review (larger increments, deferred): i32 index *buffers* for
gather/scatter (the count-uniform cliff is fixed here, but placement index vectors still
upload as f32); f16 storage for weights (`caps.f16` is green, unused); 2-D workgroups;
offscreen render targets + fragment-stage loops.

## 11. Workgroup shared memory (2026-07-19)

The compute dialect gained Workgroup-storage shared arrays + a real barrier — the ML
throughput primitive. A new entry point `gpu.kernelWG[fn; nAcc; nBuf; shSizes]` (dye.k
`compGpShared`) declares one or more Workgroup f32 arrays (`shSizes` = element counts) a
whole workgroup reads/writes cooperatively. New names/intrinsics in the body:

- `lid` — this thread's index within its workgroup (`gid mod wg`); `wgsz` — the
  workgroup size (LocalSize.x, the sticky `wg`).
- `lset[s;i;v]` / `lget[s;i]` — write/read shared array `s` (a literal index) at `i`
  (one-index `OpAccessChain` through a `Workgroup→f32` pointer; the variable IS the array).
- `barrier[]` — `OpControlBarrier` (Workgroup exec+mem scope, `WorkgroupMemory|
  AcquireRelease`): shared writes before it are visible to reads after it.

**IR mechanics.** `barrier` and `lset` are effect nodes (DCE roots, `xEffOps`); `lget` is a
value node. The whole thing rides on the IR's build-order lowering — the barrier lowers
at its build position between the stores before it and the loads after it, and inside a
loop it is owned by the loop node (`xRgn`) and replayed in the loop body by the loop's
lowerer, so barriers **inside** a `+/` fold work (the tiled GEMM uses two per tile). All
shared machinery is gated on `#SHvar>0`, so every existing kernel emits zero extra words
and stays byte-identical (kkgold). SPIR-V: an inline length const before each
`OpTypeArray`, a `Workgroup` pointer type, an un-decorated `OpVariable`, and the var in
the SPIR-V-1.4 entry-point interface (spirv.k gained `opBarrier`/`opArrTy`).

**Consumers / oracle (`test/kkwg.k`, wired into oracles.sh; both kernels also
spirv-val'd via kkgold dumps):**
- reverse-within-workgroup + broadcast — prove cooperative load, barrier sync,
  cross-thread read, `lid`, and per-workgroup shared isolation across 4 blocks.
- **tiled GEMM** — each workgroup shares one A row (needs `N%wg==0`, `K%wg==0`); the row
  tile is loaded once per K-tile into shared memory and reused by all `wg` threads (`wg`×
  fewer A global loads). Nested `+/` folds with barriers between tiles; bit-for-bit equal
  to nn.k's untiled `gemmK` on the test inputs (checked to 1e-4 tol for fractional data).

**2-D tiling + `GemmR` adoption (2026-07-19).** The follow-ups landed. A key realization:
2-D tiling needs no 2-D dispatch — a 1-D workgroup of 64 threads derives its 8×8 C-block
coordinates from the 1-D index (`wgId=d div wgsz`, `lr=lid div 8`, `lc=lid mod 8`,
`brow/bcol` from `wgId` and `n div 8`) and stores at a *computed* index (`row*n+col`). With
TWO shared arrays it loads an 8×8 tile of BOTH A and B per K-tile, so each A/B element is
fetched from global once per tile (8× fewer loads) — the real reuse win. Measured
end-to-end that is 1.7-2.5x, not 8x (bench/nnshapes.py at M=N=K=64/128/512): the cache
recovers much of the avoided traffic, so treat the load ratio as an upper bound. `nn.k`'s `gemm2dK`
does exactly this; `GemmR` dispatches it when `M,N,K` are all multiples of 8 (then `M*N` is
a multiple of 64, so the launch is exact — no over-dispatch), else falls back to the
per-element `gemmK`. The nn GEMM test (3×4×2) stays on `gemmK`, bit-identical. Verified
bit-for-bit vs `gemmK` on non-square dims (24×40×16) and correct at 512³ (64 barrier'd
tiles) — `test/kkwg.k` (5/5) covers both the direct kernel and the `Gemm` guard path.

Still open on this axis: f16 shared tiles + f16 storage (`caps.f16` green, unused — its own
precision increment: a `Tf16` type, `f32↔f16` conversions, half-width buffers); tiling
`Linear`'s transposed-B access pattern; and a compute-throughput bench harness (the current
`gpu.computeRun` micro-bench is dominated by ~2.1s device init + a 1024-dispatch/batch cap,
so wall-clock kernel timing isn't cleanly isolable — the tiling win here is architectural).
