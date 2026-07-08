# An X100-style chunked/fused execution backend for Ink

**Status:** Increment 0 (SIMD kernels) shipped. Increment 1 (FusedMap) implemented — arithmetic
`+ - * & |` chains. Companion to the papers in `doc/papers/`
(`boncz_2005_x100.md`, `williams_2009_roofline.md`, `zukowski_2006_cache_compression.md`).

## FusedMap — measured outcome (Increment 1, implemented)

A maximal pointwise subtree of the type-closed dyadic ops (`+ - * & |`) collapses in the compiler
(`fuseMaps` pass in `compiler.zig`) into one `FusedMap` bytecode op carrying a postfix kernel
program (`tape.zig` `KOp`/`Kernel`); `fuse.zig` `fusedMap` evaluates it. Key implementation facts
learned the hard way:

- **An interpreted per-SIMD-register eval stack is a loss** — a runtime-indexed `[N]@Vector` stack
  spills to memory every op, so `a+b*c` ran *slower* than the already-SIMD materialized path
  (2877 vs 475 ms/1k). The fix is the real X100 shape: interpret over **cache-blocks** (256 elems),
  each `KOp` a tight SIMD loop over L1 scratch, dispatch amortized over the block.
- **Read vector leaves directly** (no copy into scratch) and **write the root op straight to the
  output** — only genuine intermediates get a scratch block. Without these, block interpreting still
  lost to materialized-SIMD.
- Fast `@Vector` path when all operands are same-type (f32 or i32) vectors/scalars; **exact
  dispatch replay fallback** otherwise, so results are byte-identical to the unfused chain (verified
  vs ngn/k incl. i32 wrap, mixed types, length errors, right-associativity).

Measured (1e6 f32, ms/1k, fusion off vs on):

| expression | SIMD-materialized | FusedMap | speedup |
|---|---|---|---|
| `a+b*c` (2 op) | 585 | 550 | 1.06× |
| `a+b*c+d` (3 op) | 730 | 700 | 1.04× |
| `(a+b)*(a-b)+c` (4 op, repeated leaves) | 1188 | 730 | **1.63×** |

Takeaway: once the leaf kernels are SIMD (Increment 0), fusion's win is **proportional to the
materialization it removes** — marginal for short chains that COW already handles well, but large
(1.6×+) for complex expressions with repeated subterms / long chains. It never regresses (the
root-to-output write closed the short-chain gap). The full register-fusion ceiling (~357 for
`a+b*c`) needs straight-line codegen (JIT) — deliberately out of scope; the block interpreter
captures the DRAM-traffic win without emitting machine code.

**Op coverage.** Fused: dyadic `+ - * & | %` and monadic `- (neg) sqr sqrt exp log sin cos`.
`%` and the transcendentals are float-only (`KOp.floatOnly`) — the kernel is flagged and i32
operands fall back to dispatch. The fuse threshold is `FUSE_MIN_OPS` (compiler.zig, default 2 —
single ops are already SIMD). Expanded-op measurements (1e6, ms/1k, off→on):

| expression | off | on | speedup |
|---|---|---|---|
| `a*a+b*b+c*c` (sum of squares) | 1055 | 750 | 1.41× |
| `sqrt a*a+b*b` (magnitude) | 920 | 742 | 1.24× |
| `a%b+c%a` (two divides) | 785 | 651 | 1.21× |
| `(sin a)+cos b` (compute-bound) | 644 | 588 | 1.10× |

The transcendental case gains least because it is compute-bound (Roofline: the ALU, not DRAM, is
the limit), exactly where fusion helps least.

**Comparison / boolean trees** now fuse too (`< > =` plus `&`/`|` combining them). The trick that
kept the kernel monomorphic: booleans flow as **0/1 in the numeric type T**, so `<` yields 0/1 and
`&`/`|` (already `Min`/`Max`) compute AND/OR on them — no separate bool eval stack. The compiler
marks `Kernel.result_bool` when the root is structurally boolean (a comparison, or `&`/`|` of two
boolean subtrees) and the runtime converts the final 0/1 block to a `B` column. Verified vs ngn/k
and fused-vs-off (incl. mixed `(a+b)<c` and bool feeding arithmetic `(a<b)+c`); output type is a
real `B`, not float 0/1. Measured (1e6 f32, off→on): `(a<b)&c<d` 1108→695 (1.59×),
`((a<b)&c<d)|(a>c)&b>d` 2630→1022 (2.57×); `(0<a)&a<9` ~break-even (bool masks are 1 byte, so a
one-column repeated tree has little materialization to remove). Bool-column `&`/`|` on `B` leaves
(not comparison-derived) still fall back — those hit the fast path only via comparisons.

Deferred: `abs` (int branch not `@Vector`-safe); the shared-leaf restriction (a value used twice
in the tree bails rather than emitting a Dup).

This note sketches what it would take to add MonetDB/X100-style **vectorized (batch-at-a-time)
execution** to Ink's runtime: process pointwise verb chains over cache-sized chunks with adjacent
verbs **fused**, instead of materializing a full column to DRAM after every verb.

---

## 1. Where Ink is today

Ink is already *column-at-a-time*, which is the good half of X100. A dyadic verb dispatches once
over a whole array:

```
vm.zig:   .Apply2 => vm.doApply(2, call2)   →   dispatch.dispatch2(vm, op, x, y)
verbs.zig: pub const @"N+N" = _N_N(.@"+", calc.AddOp);   // one specialization per (K,K)
```

and the elementwise kernel is a monomorphized scalar loop (`primitive/verb/helper.zig`,
`kernelVec2`):

```zig
// materializing path (both inputs read-only)
const out = N(R).init(vm.alloc, vx.ptr.len) catch return V{ .err = .memory };
for (vx.slice(), vy.slice(), out.slice()) |xv, yv, *r| r.* = Impl.f(cast(xv), cast(yv));
```

with a copy-on-write fast path that reuses an `rc==1` input buffer in place. Two problems, both of
which X100 was built to fix:

1. **Whole-column granularity.** `N(R).init(len)` allocates a full-length result. For a multi-MB
   column the working set blows past L1/L2, so every op is a DRAM round-trip. This is the exact
   MonetDB "materialize between operators" cost the X100 paper measures.
2. **No fusion.** `a+b*c` runs as `t1 = b*c` (full temp) then `t2 = a+t1` (full temp). Two columns
   written to and re-read from DRAM; arithmetic intensity ≈ 1 flop / 12 bytes → firmly
   memory-bound on the roofline (`williams_2009_roofline.md`).

The COW-in-place path is a partial, single-op version of the fix: it avoids one allocation when a
temporary is dead. Fusion generalizes it — keep the *whole chain's* intermediates in registers.

## 1.5. Measured baseline & the SIMD reality check

Two things were verified empirically (Zig 0.16, `-Doptimize=ReleaseFast`), not assumed.

**The scalar kernels do not auto-vectorize.** The `helper.zig` loop shape
(`for (xs, ys, rs) |x, y, *r| r.* = f(x, y)`) compiles to *scalar* code on both targets:

| loop form | native arm64 | x86_64 baseline |
|---|---|---|
| plain scalar (as written today) | `fadd s0` — 0 NEON | `addss`, unrolled ×4 — no `addps` |
| same + `noalias` pointers | still 0 NEON — aliasing is *not* the blocker | — |
| explicit `@Vector(4, f32)` | `ldr q` / `fadd.4s` / `str q` | packed SSE |

LLVM's loop vectorizer simply does not fire for this shape in Zig's pipeline, even with
`noalias`. The **only** hand-written SIMD in the tree today is `primitive/derived/reduce.zig`
(the `+/` reductions). Everything through `kernelVec`/`kernelVec2` — `+ - * < >` on columns — is
scalar in the shipped binary. Conclusion: **explicit `@Vector` is required**; Increment 0 is
mandatory, not a nice-to-have, and FusedMap's chunk loop must be explicit `@Vector`.

(Note on distribution: `make build` targets the native CPU; `make all` cross-builds with
`-Dtarget=` → *baseline* per arch. x86_64 baseline = SSE2 only, so no AVX in distributed x86
binaries unless a `-mcpu` is set. arm64 baseline always has 128-bit NEON. Either way the point
above stands — without `@Vector` there is no SIMD at all.)

**The gap to ngn/k is modest (release build).** `bench/fused.k`, 1e6 f32, ms per 1000 iters —
**must be measured against a `make release` binary; a debug binary inflates this ~15×**:

| expression | ink (release) | ngn/k | ink / ngn |
|---|---|---|---|
| `a+b` (1 op) | 490 | 387 | 1.27× |
| `a+b*c` (2 ops) | 1023 | 642 | 1.59× |
| `(a+b)*(a-b)+c` (4 ops) | 2095 | 1455 | 1.44× |

So the motivation is *not* a huge gap to a competitor — it's the ceiling on Ink's own kernels,
measured directly with a throwaway Zig spike (static 1e6 f32, ReleaseFast):

| kernel | ms/1k | speedup vs scalar-materialized |
|---|---|---|
| `a+b` scalar | ~340 | — |
| `a+b` `@Vector` | ~108 | **3.2×** |
| `a+b*c` scalar, 2 passes *(current Ink model)* | ~666 | 1.0× |
| `a+b*c` `@Vector`, 2 passes | ~333 | 2.0× (SIMD only) |
| `a+b*c` scalar, fused 1 pass | ~436 | 1.5× (fusion only) |
| `a+b*c` `@Vector` + fused | ~210 | **3.2×** (both) |

Key facts this establishes: (a) scalar `a+b` runs at ~35 GB/s — *issue-bound*, not
bandwidth-bound — so SIMD is a real ~3× win, not a wash (it lifts throughput to ~111 GB/s, near
the memory ceiling); (b) SIMD and fusion are **independent and compound** (2.0× × 1.5× ≈ 3.2×);
(c) the fusion factor is exactly the memory-traffic ratio (24 MB → 16 MB = 1.5×), so it is
predictable and applies only to chains ≥2 ops. The fused+SIMD `a+b*c` (210) also beats ngn/k
(642). These are kernel ceilings; Ink's per-call overhead (result alloc + dispatch ≈ 30% of
`a+b`) will shave the end-to-end SIMD win somewhat, while fusion *additionally* removes an alloc +
dispatch per intermediate. Any implementation must beat the "current Ink model" row to justify
its code.

## 2. The target

Process pointwise expressions in **chunks of ~1024 elements** (4 KB for f32/i32 — one L1 line
budget), running the entire fused verb chain on a chunk while it stays in registers/L1, and
writing each output element exactly once:

```
for each chunk c of the columns:
  load a[c], b[c], c[c]                       // into registers / L1 scratch
  compute r[c] = a[c] + b[c] * c[c]           // fused, no intermediate stores to DRAM
  store r[c]                                  // one write
```

Result: intermediates never touch DRAM, arithmetic intensity rises by the chain length, and the
inner loop is branch-free and `@Vector`-friendly. On the roofline this walks the kernel up toward
the compute ceiling instead of leaving it pinned to the bandwidth line.

## 3. Two increments (ship independently)

### Increment 0 — SIMD the existing kernels (local, no architecture change) — ✅ LANDED

Done. `src/primitive/verb/helper.zig` gained `@Vector(8, T)` loops (`vmap1`/`vmap2`/`vmapSV`/
`vmapVS`) used by `kernelVec`/`dyadKernel`, gated by `simd`: op marked `pub const simd` in
`calc.zig` (vector-safe — the `.int`-branch ops were made vector-transparent via `eint()`),
result kind == cast kind (`R==C`, so no bool/compare results yet), and i32/f32-backed operands
(bool/u32 vectors fall back to scalar). Results are bit-identical to the scalar path because the
same op body runs on vector operands; verified incl. i32 overflow wrap (vector body == scalar
tail) and mixed int/float. rc==1 in-place fast path preserved.

Measured (`bench/fused.k`, 1e6 f32, ms/1k):

| | a+b | a+b*c | 4-op |
|---|---|---|---|
| ink scalar (before) | 490 | 1023 | 2095 |
| **ink SIMD (now)** | **~325** | **~475** | **~968** |
| ngn/k | 381 | 632 | 1399 |
| speedup | 1.5× | 2.15× | 2.16× |

Flipped ink from 1.3–1.6× *slower* than ngn/k to 1.2–1.4× *faster*. The single-op 1.5× (vs the
~3× kernel ceiling in §1.5) is the fixed per-call result-alloc + dispatch overhead, as predicted.
It does **not** remove the per-verb DRAM round-trip on multi-op chains — that is Increment 1.

**Extended** (same increment): the vmap helpers are now result-type-generic (`vmap*` take an `R`
param and store `[]R`), so the `simd` marker covers three op families:
- arithmetic `+ - * % & | neg sqr sqrt exp log sin cos` (R==C, i32/f32);
- comparisons `< > =` (R==bool — `CmpR` makes the op return a bool-vector on vector operands;
  `@Vector(8,bool)` stores correctly to `[]bool`, verified). char/symbol/u32 stay scalar via the
  `simdT` gate, so symbol/char `=` is untouched;
- boolean `& |` on `B` columns (C==R==bool; `@select`-based since `and`/`or` are scalar-only).

Verified on real workloads: `walk.k` (value iteration + `(0<x)&x<9` masks) 78→55 / 151→117 ms
with identical results; `earth.k` and `edit.k` render bit-valid PNGs headless (the mesh build's
seam comparisons + `-1.0|1.0&Y` clamps hit the new paths). Still scalar: `mod`/`div`/`abs`, and
monadic bool (`~`).

### Increment 1 — fuse pointwise chains (the real X100 win)

Detect maximal **pointwise expression trees** at compile time and lower each to a single chunked,
fused loop. This is where the DRAM round-trips disappear.

## 4. What is fusible

A node is *pointwise* if its output element `i` depends only on input element `i` (plus scalars):

- **Fusible:** monadic/dyadic arithmetic & math (`+ - * % ! | &` min/max, `neg sqrt exp log sin cos
  abs sqr`), comparisons (`< > =` → `B`), logical `& |`, ternary select, scalar broadcast.
  These are exactly the `makeDyad`/`monadKernel` verbs in `primitive/verb/calc.zig` + `verbs.zig`.
- **Fusion boundary (materialize, then maybe start a new chunk pipeline):** anything that changes
  length or reads across elements — reductions/scans (`+/`, `+\`, `reduce.zig`), `reshape`,
  `reverse`, index/`@`, `where`/`select` (data-dependent output size), `take`/`drop`, sort, joins,
  dict/table ops, and any verb whose result kind isn't a per-element function of the inputs.

All operands of a fused region must share length (or be scalars broadcast in). A scalar operand
becomes a splat register, not a loaded stream.

## 5. Implementation strategy

Two ways to realize the fused loop; recommend **B** for Ink.

**A. Pull-based vector iterator (X100's actual engine).** Each operator becomes a `next() ?Chunk`
that pulls chunks from its children. Clean, but it means an operator-tree object model at runtime
and per-chunk virtual dispatch — a poor fit for Ink's flat stack-bytecode VM.

**B. Compiler-fused kernel op (recommended).** The existing compiler (`runtime/compiler.zig`,
already does DCE + constant folding over the IR) recognizes a maximal pointwise subtree and emits
**one** new bytecode instruction that carries a tiny "kernel program" — the linearized pointwise
ops of that subtree. The VM has one new executor that runs the kernel program over chunks. No
runtime object model; it stays in the flat-tape spirit of `tape.zig`.

### 5.1 New opcode

```zig
// tape.zig OpCode
FusedMap,   // operand: u16 index into chunk.kernels; inputs/const come from the stack
```

`instrSize`: `FusedMap` = 3 bytes (opcode + u16). A parallel `chunk.kernels: ArrayList(Kernel)`
stores the programs (like `constants`).

### 5.2 The kernel program

A `Kernel` is a flat list of micro-ops over a small register file of chunk-wide lanes. It is a
*second, tiny* tape — deliberately not the main VM tape — whose only job is per-element math:

```zig
pub const KOp = enum(u8) { LoadCol, LoadScalar, Add, Sub, Mul, Div, Min, Max,
                           Lt, Gt, Eq, Neg, Sqrt, Exp, Log, Abs, Select, Store };

pub const KInsn = struct { op: KOp, a: u8, b: u8, dst: u8 };  // register indices

pub const Kernel = struct {
  code: []KInsn,
  ncol: u8,      // number of input columns pulled from the VM stack
  nreg: u8,      // scratch registers needed (one @Vector each per chunk)
  rtype: K,      // result kind (i.e. f32 vs i32 vs bool) — from resultKind2
};
```

The compiler builds this by a post-order walk of the pointwise subtree: leaves that are columns →
`LoadCol`, scalar leaves → `LoadScalar` (splat), interior verbs → the matching `KOp`, root →
`Store`. Type promotion (`helper.Upcast2`) is resolved at compile time into the `KOp` choice and
`rtype`, so the kernel is monomorphic — same principle as `_N_N`.

### 5.3 The chunk executor

```zig
const CHUNK = 1024;   // 4 KB per f32/i32 stream — one L1 budget

fn runFusedMap(vm: *VM, k: *const Kernel, cols: []const V) V {
  const n = commonLen(cols);                       // all equal, checked at compile-fusion time
  const out = N(kbacking(k.rtype)).init(vm.alloc, n) catch return V{ .err = .memory };
  var base: usize = 0;
  while (base < n) : (base += CHUNK) {
    const w = @min(CHUNK, n - base);
    // interpret k.code once per chunk over a small register file of @Vector lanes;
    // LoadCol reads cols[a][base..base+w], Store writes out[base..base+w].
    runChunk(k, cols, out, base, w);
  }
  return promote/wrap(out, k.rtype);
}
```

`runChunk` is where SIMD lives: iterate the chunk in `@Vector(W, T)` steps with a scalar tail,
executing the ~handful of `KInsn` per lane-group. The kernel program is tiny and hot, so it stays
in i-cache; the data chunk stays in L1. This is X100's "one dispatch, cache-resident vector,
branch-free loop," realized as a mini-interpreter rather than a JIT.

### 5.4 Refcounting / COW / in-place

Preserve the current fast path at the *region* level: if any input column has `rc==1` and matches
`rtype`, reuse its buffer as `out` (write the final `Store` into it) and skip the allocation —
the natural generalization of `kernelVec2`'s in-place branch. Dead intermediate columns simply
never exist, so no rc bookkeeping for them at all.

### 5.5 Semantics to preserve

- **0N / overflow:** Ink integer add wraps (`+%`), mul saturates to `0N`
  (`feedback_ink_i32_f32_parser_quirks`) — the `KOp`s must match `calc.zig`'s `AddOp`/`MulOp`
  exactly, including the wrap-vs-null asymmetry. Reuse the same `Op.f` bodies to guarantee parity.
- **Type errors:** must surface identically to the unfused path. Validate operand kinds at
  fusion time in the compiler; if a fused op could produce `.err`, either exclude it from fusion
  or thread an error lane out of `runChunk`.
- **Broadcast:** scalar ⊕ vector and vector ⊕ scalar already exist in `kernelVec2`; `LoadScalar`
  is the splat form.
- **Equivalence:** the fused result must be bit-identical to the sequential verb evaluation.
  Golden test: run every fusible expression both ways and `~`-compare (the CST/GPU tests already
  use this pattern — `project_parse_cst_table`).

## 6. Files touched

- `runtime/compiler.zig` — new pass: detect maximal pointwise subtrees over the IR, build a
  `Kernel`, replace the subtree's `Apply1/Apply2` sequence with one `FusedMap`. Sits after
  constant folding, before final lowering.
- `runtime/tape.zig` — `FusedMap` opcode, `Kernel`/`KInsn`/`KOp`, `chunk.kernels`, `instrSize`.
- `runtime/vm.zig` — decode `FusedMap`, pull `ncol` operands off the stack, call `runFusedMap`.
- `runtime/fuse.zig` (new) — `runFusedMap` / `runChunk` and the `@Vector` inner loops.
- Reuse `primitive/verb/calc.zig` op bodies inside `KOp` dispatch so semantics can't drift.

## 7. Sequencing and what to measure

1. Increment 0 (SIMD kernels) — immediate, low-risk, gives the SIMD ceiling.
2. Increment 1 (`FusedMap`) on arithmetic/comparison chains only — the bulk of the win.
3. Extend fusible set to `select`/logical, then to feeding a **reduction** directly from a fused
   map (`+/(a*b)` → fused multiply-accumulate, no temp at all — the highest-value fusion).
4. Only *then* consider compressed chunks: decode a PFOR/FastLanes chunk into the scratch tile at
   the top of `runChunk` (`zukowski_2006_cache_compression.md`, `afroozeh_2023_fastlanes.md`).
   Same 1024 chunk = same loop nest.

Measure per workload, not in aggregate: (a) DRAM bytes moved (should drop by ~chain-length for
fused expressions), (b) IPC / cycles from perf counters, (c) L1/L2 miss rate, and place each on
the roofline for the target CPU before and after. If a kernel was already compute-bound, fusion
won't help it — the model tells you which ones to expect wins on.

Harness: `make bench` (runs `bench/bench.sh`; needs `make build` + ngn/k at `~/.k/k`).
`bench/fused.k <N>` is the elementwise-chain benchmark added for this work — the baseline table in
§1.5 came from it. Re-run it after Increment 0 and after Increment 1; both must beat the "ink
(today)" column, and the multi-op rows must improve *more* than the single-op row (that delta is
the fusion win, distinct from the SIMD win).

## 8. Non-goals / risks

- **Not a JIT.** This is a chunked mini-interpreter, deliberately. A true codegen JIT
  (copy-and-patch / TPDE, see `doc/papers/`) is a separate, larger step; the type-system+JIT
  prototype was built and reverted once already (`project_type_inference`,
  `doc/research/type-system-and-jit.md`). Fused chunking gets most of the memory-bandwidth win
  without emitting machine code.
- **Fusion-region detection is the tricky part** — getting the boundary set exactly right
  (esp. verbs that *look* pointwise but can error or change type) and guaranteeing bit-identical
  results. Keep the fusible set small and grow it behind golden tests.
- **Chunk size is a tuning knob**, not a constant to guess once — 1024 is the X100 default; verify
  against L1 size and element width on the target.
