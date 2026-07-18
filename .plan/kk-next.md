# kk: next tasks — handoff (updated 2026-07-18)

Self-contained brief for a fresh agent session. Read this, then skim
`doc/design/kk.md` (vision + roadmap) and `doc/design/kk2.md` (what landed, with
per-milestone status). CLAUDE.md / AGENT.md have the language gotchas; the ones
that actually bite are repeated per task below.

## State of the tree (all green)

`main` is clean. `zig build`, `zig build gpu`, `zig build test`, and the full
oracle suite all pass (10 rungs + spirv-val 20/20).

### Landed since this handoff was written (2026-07-18)

- **Task A — compile-on-apply caching (DONE).** `kk.compile` split into
  `kk.plan[fn;args]` (classify + compile ONCE → a reusable plan dict
  `[kind;pipe;…binding info]`, cached in `kkPlanCache`) and `kk.run[plan;args]`
  (dispatch fresh args, ZERO re-parse/re-classify). Key = lambda source + #inputs +
  each placement's signature (type/shape/layout/columns) + `kkScatForceI`. Every path
  (map/gather/gather-reduce/amend/scatter/planar+interleaved table/dict) split into
  `kkPlanX`/`kkRunX`. `test/kkc.k` (now 44 checks) asserts a repeat compile leaves
  `kkPlanMisses` and `#!kkCache` unchanged. Observability: `kkPlanMisses`.
- **Task B.1 — `kk.group` (DONE).** `kk.group[d; nb]` → CSR: counts (`kk.freq`),
  exclusive offsets (`kk.sums` − counts), and a permutation `perm` via per-bucket
  ATOMIC CURSORS (`pos = atomicAdd(cursor[b],1)`; the i32 scatter-add already returns
  the OLD value — `xLoSadd`'s `old`). Returns the perm placement with `off`/`cnt`
  sub-placements. `test/kkgrp.k` (now 25 checks) has an order-independent oracle.

### Task B.2 — radix sort — NOT DONE (correctness gate found; read before starting)

LSD radix needs a **STABLE** per-digit counting sort. `kk.group`'s atomic-cursor
scatter is deliberately NON-stable (threads race for cursor slots — fine for
grouping SETS, WRONG for a radix pass, which would then not sort). So radix cannot
just reuse the group scatter. Two viable stable scatters: (a) per-digit-value
`kk.where` compaction concatenated in digit order (stable, but R=16 whiles/pass —
heavy); (b) a multi-lane exclusive scan giving each element its stable local rank
within its digit, then `slot = off[digit]+rank`. Also: digit extraction needs
`div`/`mod`, which are NOT in the elementwise map subset (`kkEwOps`) — do it in a
RAW `gpu.kernel` (the integer dialect has `div`/`mod`). Scope the first cut to
NON-NEGATIVE integer-valued f32 keys (< 2^24); general float sort needs the
bit-flip key transform, and there are no bitwise/shift ops in the encoder yet
(only `opBitcast`) — document NaN/negative as out of scope until then.

Everything below is DONE:

- **kk tier-1 + tier-2 compiler**: elementwise, gather, scatter-add, amend,
  reduce/scan/where, in-kernel loops, placed tables (planar + interleaved) and
  placed dicts (CSR), `kk.freq` histogram.
- **`bits` CPU backend** (`lib/bits.k`): interprets dye's neutral IR on the CPU;
  `test/kkbits.k` is the cross-backend oracle (bits CPU == gpu.kernel GPU on the
  nn kernels).
- **Vertex pulling is the ONE mesh API**. The attribute path (`shader.vertex`/
  `vertexU`, `mesh.compile`/`draw`/`drawU`/`upload`/`drawGeomT`) is fully retired —
  k libs AND the native backend (~350 lines) removed. All demos pull:
  earth/sword/pbr/sphere/cloth (+ fill: eyes/drawing). Pull pipelines support
  textures @group(1) and per-frame uniforms (in a pulled storage buffer).
- **FFI supports arity 1..8** (was capped at 3). `src/ffi.zig` + `plugin.zig` +
  `call.zig`. The old arity-3 packed-handle workarounds (gpuDrawPullT,
  gpuDispatchLoop, AudioEncode) are unpacked to clean N-arg calls.
- **Three runtime/parser bugs fixed** (see `.plan/triage.md`): amend narrowing
  coercion (`@[1. 2.;0;:;3]` → `3. 2.` not `!type`; amend NEVER changes a target's
  type/shape, so widening float→int-vec stays `!type` by design), and mixed
  int/float vector literals (`1 2 3.5` now promotes). The "L[k]::expr aliasing"
  bug was a MISDIAGNOSIS of the coercion bug — no separate aliasing defect exists.

## How to verify anything

```sh
time zig build                 # debug host build
zig build gpu                  # the gpu ext (libgpu.dylib) — rebuild after any lib/gpu/*.zig edit
zig build test                 # unit tests (src/test.zig)
INK=zig-out/bin/ink sh test/oracles.sh   # THE oracle suite, all rungs
timeout 40 ./zig-out/bin/ink -snap 0.5 demo/<name>.k   # headless render → <name>-snap.png (Read it)
```

Oracle ladder: byte-identity (kkgold pins `xOpt::0`) → **spirv-val** (validates
every kkgold module dump — run after ANY dye.k/emitter change) → numeric parity
(kkc/kkred/kkint/kkbits/kkgrp/walkgpu/nn maxerr) → pixels (`-snap` + Read the png;
snapshot stats are flip/black-blind — LOOK at the image).

Universal k gotchas (these actually bit this session): lambdas do NOT close over
parent scope (hoist helpers to globals / prefixed-global state); `$[]` branches
are single expressions (a bracketed multi-stmt block HANGS the parser); `x<=y`
parses as `x<(=y)`; a bare op-glyph after a name is dyadic; `dict\`key` before an
operator misparses — bracket-apply it (`gpu.read[d\`gpu]`, not `gpu.read d\`gpu`);
`f' xs` over a bare named function can error — wrap `{f x}' xs`; the FFI is now
arity ≤ 8 (was 3). To print an F-vector from a script, join it: `","/$'v`.

---

## Task A — Task 6b: compile-on-apply caching (start here; pure kk.k, low risk)

**Context.** `kk.compile[fn; args]` (lib/kk.k) re-parses (`lamOf fn`) and
re-classifies the lambda on EVERY call, even when the pipeline is already cached
in `kkCache`. For a hot loop that re-invokes `kk.compile` with the same lambda +
shapes, that CST work is wasted (the monomorphic-call-site idea, kk.md incr 4).

**Do.** Key a classification cache on (lambda source; #inputs; placement shapes)
and return a REUSABLE compiled object `(pipe; plan)` that `kk.run[obj; args]`
dispatches without re-parsing. `kk.compile` stays the convenience entry (compile
+ run); `kk.plan`/`kk.run` is the split. Start with the elementwise `kkMap` path
(simplest), then extend to gather/scatter/table if clean.

**Gotchas.** The classifiers (kkClassify, kkGathSrc, kkTableColNames, …) read the
GLOBAL `Cst` set by `lamOf` — cache their RESULTS, not Cst. Cache key is a SYMBOL
(a string key makes every probe a false hit — `str in !dict` runs char-wise).

**Expected outcome.** `test/kkc.k` gains: second `kk.compile`/`kk.run` of the same
lambda+shapes does zero CST work (assert `#!kkCache` unchanged + a parse-count or
timing check). All oracles still green.

## Task B — Task 5 remainder: kk.group, then radix sort

**Context.** `kk.freq[d; nb]` (histogram) landed (`test/kkgrp.k`). Remaining:
`= d` (group) and grade/sort. Scatter-add (i32 exact + f32 atomic) exists; the
i32 path computes the OLD accumulator value but doesn't expose it.

**Do (group first).**
1. `kk.group[d]`: counts (`kk.freq`) → exclusive offsets (`kk.sums`) → one scatter
   of each index into its bucket slot using a per-bucket atomic cursor:
   `pos = atomicAdd(cursor[b], 1)`. Expose the OLD value the i32 scatter-add
   returns (it's in `xLoSadd`'s `old` id in lib/dye.k) so the cursor works.
2. Radix sort (stretch): 4-bit digits, histogram+scan+scatter per pass — every
   primitive exists; the milestone is wiring + an oracle vs CPU `<`.

**Expected outcome.** `test/spacial.k`'s spatial hash expressible on device
(`kk.group` over cell ids); oracle vs CPU `=`/`#'=` in a new `test/kkgrp.k` block
wired into oracles.sh. Sort: `8: kk.sort[9: x]` matches CPU `x@<x` (document NaN
policy).

## Task C — Task 1 remainder: generate nn.k's composite refs from bits (DRY)

**Context.** `test/nn.k` carries hand-written CPU references (`gref`/`sref`/`mref`
/`fref`/`cref`/…). The SINGLE-kernel ones (gemm, softmax, layernorm, linear,
activations) are already superseded by `test/kkbits.k` (bits CPU vs gpu GPU from
one source). The COMPOSITE ones (FfnBlock, Mhsa, ConvModule) are multi-kernel host
pipelines still hand-written.

**Do.** Reproduce the host chaining (like `SoftmaxR`'s two dispatches) using
`bits.run` per kernel from the SAME nn.k kernel lambdas, so the composite
references are GENERATED, then delete the hand-written `gref`/`sref`/`mref`/…. This
is DRY, not correctness (kkbits already pins the per-kernel math).

**Expected outcome.** `test/nn.k`'s references generated from one source; maxerr
stays a permanent cross-backend oracle; hand-written refs gone.

## Task D — Task 6a: `n f/ d` recording (design-gated — discuss first)

`(N*N) f/ 9: x0` should RECORD n dispatches in one encoder (today you call
`kk.loop[f;d;n]` explicitly). Needs runtime support: either a VM hook when the
fold state is a placed descriptor (dict with a `gpu` key — touches
src/runtime/vm.zig dispatch) or a k-level `f/` overload in kk.k. **Discuss the
mechanism before building.**

## Task E — Task 3 stretch: cloth edge kernel through kk.compile (ergonomics)

Route clothgpu's edge kernel THROUGH `kk.compile` with `(E\`i)`/`(E\`j)` column
syntax composed with gather + scatterAdd (unify the raw-kernel emitter with table
bindings). NOT needed functionally — interleaving already lets the existing raw
kernel read a placed edge table's packed buffer (kkc 39/39). Pure ergonomics.

---

## Suggested order

A (6b caching — clean, self-contained) → B (kk.group, then sort) → C (nn.k ref
generation) → D (`f/` recording, needs a design call) → E (ergonomics). Test and
commit each independently; every commit must pass `sh test/oracles.sh` and
`zig build test`, and any dye.k change gets the spirv-val rung re-run. When an
oracle intentionally changes (new dumps), state which rung you dropped and why in
the commit message — never drop two rungs silently.

## Ready-to-paste prompt for the next session

> Read `.plan/kk-next.md`. The tree is green (10 oracle rungs + spirv-val + unit
> tests). Start with Task A (kk.compile compile-on-apply caching — pure lib/kk.k):
> split `kk.compile` into `kk.plan`/`kk.run` so a repeat call with the same lambda
> + placement shapes does zero CST re-parse/re-classify work, add a cache-hit
> assertion to test/kkc.k, and keep every oracle green. Then move to Task B
> (`kk.group` via per-bucket atomic cursors, then radix sort). Build the gpu ext
> with `zig build gpu`, verify with `INK=zig-out/bin/ink sh test/oracles.sh`, and
> commit each task independently.
