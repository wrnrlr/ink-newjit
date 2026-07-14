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

1. `+/{…}'!k` → `rsum` recognition inside existing kernels; retire the
   intrinsic names from new code (keep them compiling). Oracle: byte-identity
   of a hand-rewritten gemmK vs the `rsum[…]` spelling.
2. Elementwise `kk.compile`: `{2.*x}`, `{x+y}` over placements; dispatch =
   descriptor count; compare vs `8:`-fetched CPU result.
3. Index-buffer gather + `rsum`-over-W: walk.k's interior update expression.
4. Amend-scatter (`setb` thread-per-I) + masked write; then `n f/ d`
   ping-pong recording. **Acceptance: walk.k's `f` verbatim, E@center =
   2887.34 (Jacobi f32 fixpoint value), against the CPU run.**
5. `@[x;I;+;v]` → `sadd` (spatial-hash histogram from `test/spacial.k` as the
   demo).

## 3. Finish the IR unification (rest of increment 3)

- **Fragment**: add a `sample` IR node (4 ids: two loads, OpSampledImage,
  ImageSample — mirror `compSample`); `kSeqIr` grows an `oty` argument;
  fragment/fragmentTexN switch to it. Oracle: add fragment+vertex cases to
  kkgold *before* migrating (compile via the direct path, capture, migrate,
  diff).
- **Vertex(+U) and instancing**: outputs are compiled interleaved with their
  stores, so plain build-then-lower would permute ids. Add a `vstore` effect
  node (optional access-chain member + OpStore) so stores sit in the IR at
  their direct positions — same trick as `f2s`.
- Then **delete the direct comp\* walkers** (compNode/compSeq/compApply/…,
  ~250 lines) — single-pipeline dye.
- **Fold/DCE for compute**: make reachability multi-root (result + every
  effect node + loop nodes), then enable `xFold` behind a flag; oracle drops
  to numeric parity + spirv-val (byte-identity is intentionally broken by
  folding).
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
3. **rsum/rmax — DECIDED: full syntax is canonical.** `+/{[k] e}'!K` (and
   `|/…`) is the spelling everywhere — demos, libs, docs; `rsum`/`rmax`
   remain as documented equivalents (teaching code / spec of the lowering),
   not deprecated, but no new code uses them. Raises the priority of the
   §2.4-1 recognition, and lib/nn.k migrates to the full syntax once it
   lands.
4. **Shapes in descriptors — add `s` now.** `s` is the array's SHAPE, e.g.
   `(N;N)` for the walk.k grid or `(nP;3)` for cloth positions, alongside
   the flat count `n`. Placed via `9: (N;N)#x` (or a reshape on the
   descriptor). It's what lets 2-D stencils know their row pitch, `(k;n)`
   index matrices know k vs n, and kk.compile size dispatches and check
   conformance — the host side of the data layer.
5. **RNG** (walk.k's Monte-Carlo half; philox counter-based; `?` lowering) —
   still open: tier 2 or its own increment.

## 9. Suggested order

1. §2.4-1 rsum recognition (small, establishes the IR-rewrite pattern)
2. §3 fragment migration + fold/DCE roots (finishes the seam, deletes code)
3. §2.4-2..4 kk.compile through the walk.k acceptance (the headline)
4. §6 device-feature enabling + whole-buffer reduce (unlocks 7 and tier 2)
5. §5 vertex pulling (clothgpu readback deletion — the visible payoff)
6. §4 bits v1 via generated nn references (cross-backend oracle forever)
7. §7 float atomics, §3 i32 indices, tier 2 scans/compaction
