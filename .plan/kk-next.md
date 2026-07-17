# kk: next tasks (post-cleanup, 2026-07-17)

Self-contained brief for a fresh agent session. Read this, then skim
`doc/design/kk.md` (vision + roadmap) and `doc/design/kk2.md` (everything that
landed, with per-milestone status notes). CLAUDE.md / AGENT.md have the language
gotchas — the ones that actually bite are repeated per task below.

## STATUS (updated 2026-07-17, session 2)

DONE this session (all oracles green, 10/10 + spirv-val 20/20):
- **Task 1 (bits CPU backend)** — `lib/bits.k` interprets dye's neutral IR on the
  CPU; `test/kkbits.k` is the cross-backend oracle (bits CPU == gpu.kernel GPU on
  the exact nn kernel lambdas, 12/12). Remaining: regenerate test/nn.k's COMPOSITE
  FFN/MHSA/Conv references (multi-kernel host pipelines) from bits and delete the
  hand-written gref/sref/mref (single-kernel refs are already covered by kkbits).
- **Task 2 (fragmentIr fold-in)** — done; `shader.fragment` respects xOpt,
  `shader.fragmentIr` deleted, test/ir.k rewritten as xOpt=0-vs-1.
- **Task 5 (partial) — kk.freq** — tier-2 histogram via scatter-add; `test/kkgrp.k`.
  Remaining in Task 5: `kk.group` (compaction with per-bucket atomic cursors — needs
  the OLD value from the i32 scatter-add exposed) and radix sort.
- **Task 7 chores** — snap.sh glob fixed, kkgold integer-dialect dump pinned, docs.

Three VM/parser bugs found + logged in `.plan/triage.md` (worth fixing at the Zig
level): (1) `L[k]::expr` corrupts L when expr reads L (also inside a `'` each);
(2) amending a typed/null vector slot with an INTEGER collapses it; (3) a vector
literal with a decimal element after a bare int (`1 2 3.5`) errors.

- **Task 3 (interleaved placed tables + placed dicts)** — DONE. Interleaved table
  layout (one row-major buffer, 2 bindings not n+1; `gpu.tblLay` picks planar/il/auto
  — it AVOIDS the MAX_BIND limit rather than raising it, so no vk.zig bump). Placed
  dicts (ragged CSR named buffers, `gpu.holdD`; the one zig change = a `_m` monadic
  handler on the `9:` Place verb so `9: dict` reaches gpu.hold). Cloth edge table =
  the interleaved packed stride-7 buffer the raw edge kernel already reads (kkc 39/39).
  Remaining stretch: routing the edge kernel THROUGH kk.compile with (E`i) column
  syntax composed with gather+scatterAdd (unify raw-kernel emitter + table bindings)
  — not needed for the edge use case (interleaving covers it).

STILL OPEN: Task 4 (earth on vertex pulling — vk.zig pull pipeline uniforms+textures),
Task 6 (`n f/ d` recording + compile-on-apply caching). 4 is native-heavy; 6a is
design-gated.

## Where the codebase stands

Commits `1329398..9587c79` (2026-07-17) finished a large cleanup + the tier-1
compiler:

- **Layout**: `test/` = asserting/oracle-wired scripts only; `demo/` = window /
  visual / example scripts (`demo/data/` holds the earth textures). `bench/` =
  microbenches.
- **Namespaces**: `lib/spirv.k` (pure op stencils) → `lib/dye.k` (the shader/
  kernel compiler: `shader.*`, `gpu.kernel*`, the neutral IR) → `lib/gpu.k`
  (FFI bindings, window loop, resident buffers/pipelines, `mesh.*`, placed-array
  descriptors `gpu.hold/fetch/holdT`) → `lib/kk.k` (array-level surface:
  `kk.compile/loop/converge/reduce/scan/where`; loads dye+gpu itself; a bare
  `kk.*` reference autoloads it).
- **Deleted** (do not resurrect): lib/instancing.k, lib/draw.k, lib/layout.k,
  the 4 native instanced-draw stubs, `opF2i`, `shader.compute*` still exist but
  new code should use `shader.kernel` / `kk.compile`.
- **Dialect**: `gpu.kernel` / `shader.kernel` (+`F` float-atomic variants)
  compile the **integer-index dialect by default** (`Xidx=1`): thread index is
  i32, `d div n` / `d mod n` are integer ops, **int literals are i32 and float
  literals are f32** ("write what you mean": `3` is an index, `3.` is a float),
  `< > = ~` emit integer comparisons when the LEFT operand is i32, and `` `i$ ``
  / `` `f$ `` are the only conversions. Legacy f32 dialect: `kernelInfer[fn;fa;0]`
  / `compGpN[fn;nAcc;nBuf;fa;0]` (test/kkint.k pins legacy == default == CPU).
- **io verbs**: `9:` place / `8:` fetch are the canonical spelling
  (`E: 8: kk.loop[f; 9: x0; n]`). `9: table` → structured buffer (one resident
  buffer per column, `gpu.holdT`); `8:` on a `` `tbl `` descriptor reassembles
  the table. PARSE TRAP: `kk.sum 9: x` after a NAME makes `9:` dyadic — write
  `kk.sum[9: x]`.

## How to verify anything

```sh
time zig build                 # debug build (gpu ext: zig build gpu)
zig build test                 # unit tests
INK=zig-out/bin/ink sh test/oracles.sh   # THE oracle suite, 8 rungs
./zig-out/bin/ink test/nn.k    # GPU-vs-CPU maxerr for the nn stack
timeout 40 ./zig-out/bin/ink -snap 1 demo/<name>.k   # headless render → <name>-snap.png
```

The oracle ladder (kk2 §1): byte-identity (kkgold, pins `xOpt::0`) →
**spirv-val** (new rung in oracles.sh — validates every kkgold module dump;
it catches type errors MoltenVK silently tolerates, e.g. an OpIEqual fed a
float const; run it after ANY dialect/emitter change) → numeric parity
(kkc/kkred/kkint/walkgpu/nn maxerr) → pixels (`-snap` + Read the png; snapshot
*stats* are flip/black-blind — look at the image).

Universal k gotchas: lambdas do NOT close over parent scope (hoist helpers to
globals / prefixed-global compiler state); `$[]` branches are single
expressions; `x<=y` parses as `x<(=y)`; a bare op-glyph after a name is dyadic.

---

## Task 1 — `bits` v1: the CPU backend (kk.md §3.2, kk2 §4)  ← start here

**Context.** The neutral IR (`xOp/xTy/xArg/xVal` lists in lib/dye.k) and the
FusedMap KOp micro-ISA (src/runtime/tape.zig: Col/Add/…/Sqrt/Sin, postfix,
chunk-interpreted) are the same machine at two altitudes. Every kernel now
flows through the IR, and the integer-index flip means generated kernels use
i32 index math that a CPU interpreter can actually run. test/nn.k carries
~300 lines of HAND-WRITTEN CPU references (`gref`/`sref`/`mref`…) that exist
only to check the GPU kernels — they should be *generated* from the same
kernel lambdas.

**Do.**
1. `bits.compile[ir]` in a new `lib/bits.k` (or a dye.k section): lower the
   elementwise/select IR subset (param/const/arith/math/neg/select) to a
   `Kernel` postfix program per kk2 §4's IR→KOp table.
2. Wire-up v1: either a dedicated eval FFI (a small Zig hook that runs a KOp
   program over ink vectors) or install as a chunk kernel + FusedMap op.
   Simplest first: a pure-k interpreter of the postfix program is an acceptable
   v0 oracle before the Zig hook — correctness first, speed second.
3. First deliverable: generate test/nn.k's CPU references from the SAME kernel
   lambdas (`gemmK`, `smStatK`, …) and delete the hand-written refs. Loops
   (`rsum`/`ndo`) lower as plain k loops around the elementwise core in v1 —
   no in-kernel KOp loops needed.

**Gotchas.** KOp bool discipline is 0/1 f64 with `result_bool` at the root;
`bufidx` (gather) and `setb` (store) need either new KOps (`Gather`/`Store`)
or v1 can special-case them in the k driver loop. Keep the i32/f32 distinction:
the IR carries `xTy` — truncate on `f2s` exactly like the GPU does so the
cross-backend oracle is honest.

**Expected outcome.** `make qa` green with test/nn.k's references GENERATED
(hand-written gref/sref/mref deleted); `maxerr` becomes a permanent
cross-backend oracle (CPU-lowered vs GPU-lowered from ONE source). Stretch:
`bench/fused.k`-style timing showing the FusedMap path beats naïve
materialized k for at least one kernel.

## Task 2 — Fold `shader.fragmentIr` into `shader.fragment`

**Context.** kk2 §3 migrated every entry point onto the IR, but the fragment
path still has TWO public spellings: `shader.fragment` (lowers every node,
`xLowerSpirv` without fold/DCE) and `shader.fragmentIr` (fold + DCE), used
only by test/ir.k. Compute already runs the optimizer by default (`xOpt::1`).

**Do.** Make `shader.fragment` respect `xOpt` exactly like the compute path
(fold + value-root DCE when on), delete `shader.fragmentIr`, update test/ir.k
(its byte-identity check between the two spellings becomes an xOpt=0-vs-1
structural check like test/kkopt.k) and the kkgold fragment dumps (kkgold pins
`xOpt::0` in-file, so its dumps should be UNCHANGED — verify that first, it is
the whole point of the pin).

**Expected outcome.** One fragment entry point; kkgold byte-identical
(xOpt pinned 0); demos pixel-identical (`-snap` sphere/eyes/circle/earth);
test/ir.k rewritten and passing; `shader.fragmentIr` gone from dye.k and docs.

## Task 3 — Interleaved placed-table layout + placed dicts (kk2 §2.5 deferred)

**Context.** `9: table` places PLANAR (one buffer per column). Two gaps:
(a) `vk.zig MAX_BIND = 8` — a 7-column table + accumulator + params already
exceeds planar binding count; (b) ragged data (CSR: `[data: …; off: …]`,
lib/shp.k's convention) has no placement at all. Layout is a schedule choice
(Tiramisu L3), not semantics — the kernel source must not change.

**Do.**
1. Interleaved layout: `gpu.holdT` grows a layout tag (planar default;
   interleave when `#cols` would blow the binding budget, later a knob). ONE
   buffer, stride `nc`, field k of row d at `d*nc+k`. In dye, `xTableCol`
   already resolves a column to a bufp node — for interleaved it becomes
   bufidx[buf; (d*nc)+k] with nc/k baked (i32 consts; the integer dialect makes
   this exact). Cache key must carry the layout.
2. Placed dicts: `9: dict` (class `m` — note tables are `M` IN-FUNCTION) → a
   binding group of differing-length placements resolved by name; no
   equal-length constraint; start with the CSR pair (data;off).
3. Acceptance kernel: clothgpu's EDGE kernel expressed on a placed table
   (`E: 9: [[]i:ei; j:ej; l0:l0; al:al; w0:w0; w1:w1; wt:wt]`) — this was the
   motivating example and needs tables composed with gather/scatterAdd, which
   currently reject.

**Gotchas.** kkTable currently routes ONLY the elementwise slice — the
classifier must learn table-columns composed with gather/reduce/scatter.
Empty-typed-vector joins upcast to boxed L (use `0#\``). Werner's call:
planar stays the default for coalescing; interleaved wins when a thread reads
EVERY field of one row (the edge kernel).

**Expected outcome.** test/kkc.k gains: interleaved-vs-planar identical
results, a >8-column table that auto-interleaves, a CSR placed dict, and the
cloth edge kernel on a named-column table matching the packed-buffer sim
bit-for-bit (or the clothgpu drape invariant unchanged after migrating kCon to
the table form).

## Task 4 — earth.k on vertex pulling + instance index (kk.md §5-7/9)

**Context.** clothgpu + scene.k are pulled; earth.k still uses the attribute
path (`mesh.upload` + `mesh.drawGeomT`) because pull pipelines lack textures
and per-draw uniforms. Instancing was deleted as an API — the design says
instance id is an INDEX COMPUTATION (`inst: vid div NV`, see demo/scene.k) —
so what remains is making pulled draws first-class for textured/uniform cases.

**Do.**
1. `mesh.drawPullT[pipe; bufs; count; uni; texs]` (or extend drawPull): bind
   the uniform block + textures@group(1) for pull pipelines in vk.zig
   (`createPullPipeline`/`drawPull`) — the fragment side (fragmentTexN,
   sampler at binding nTex) is unchanged.
2. Port demo/earth.k: sphere mesh → resident buffer, vertex shader through
   `shader.vertexPull` (stride-8 pos/nor/uv reads at `8*vid`), keep its
   fragment shaders. Then decide with Werner whether the attribute mesh path
   (`mesh.compile/draw/drawU/upload/drawGeomT`) can retire (sword/pbr/typeset/
   eyes still use it).

**Expected outcome.** demo/earth.k renders pixel-identical via pulling
(compare `-snap` before/after visually, not by stats); scene.k unchanged;
doc/reference.md mesh section updated. Stretch: sword.k too (it is the
simplest textured+uniform mesh demo).

## Task 5 — Tier-2 group/histogram, then sort (kk.md §2 tier 2)

**Context.** Remaining tier-2 rows: `= d` (group) / `#'= d` (freq) via atomic
histogram — the CPU `freq` peephole on device — and grade/sort (radix), each
its own increment. `kk.where`/`kk.sums`/`kk.reduce` exist and are the building
blocks; scatter-add (i32 exact + f32 atomic) exists.

**Do (group first, sort only if group lands clean).**
1. `kk.freq[d; nbuckets]`: one scatter-add dispatch (`@[HB#0;I;+;1]` already
   compiles — this is mostly a kk.k wrapper + oracle over the existing path).
2. `kk.group[d]`: counts → `kk.sums` exclusive offsets → one scatter of each
   index into its bucket slot (the compaction trick with a cursor per bucket
   needs atomics: `pos = atomicAdd(cursor[b],1)` — the i32 scatter-add path
   returns the OLD value in `xLoSadd`'s `old` id; expose it).
3. Radix sort (stretch): 4-bit digits, histogram+scan+scatter per pass —
   every primitive now exists; the milestone is wiring + an oracle vs CPU `<`.

**Expected outcome.** test/spacial.k's spatial hash expressible on device
(`kk.group` over cell ids), oracle vs CPU `=`/`#'=` in a new test/kkgrp.k
wired into oracles.sh. Sort: `8: kk.sort[9: x]` matches CPU `x@<x` on f32
vectors (tolerating NaN policy documented).

## Task 6 — `n f/ d` recording + kernel compile-on-apply (kk.md incr 4 tail)

**Context.** The two remaining incr-4 items: (a) `n f/ d` on a placement
should RECORD n dispatches in one encoder (today you call `kk.loop[f;d;n]`
explicitly); (b) kk.compile caching is keyed per-call but application of a
compiled kernel to NEW placements of the same shape should skip
classification entirely (monomorphic call-site idea).

**Do.** (a) needs runtime support: the fold adverb on a descriptor-dict state
— either a VM hook when the fold state is a placed descriptor (dict with a
`gpu` key) or a k-level `f/` overload in kk.k; discuss the mechanism with
Werner before building (the VM route touches src/runtime/vm.zig dispatch).
(b) is pure kk.k: key the cache on (lambda source; shapes; placements) and
make `kk.compile` return a REUSABLE compiled object `(pipe; plan)` that
`kk.run[obj; args]` dispatches without re-parsing.

**Expected outcome.** `E: 8: (N*N) f/ 9: x0` — the kk.md §0 headline — runs
verbatim and matches kk.loop bit-for-bit (walkgpu oracle gains the spelling);
second `kk.compile` of the same lambda+shapes does zero CST work (assert cache
size + a timing check in kkc).

## Task 7 — chores (bundle with any of the above)

- `public/snap.sh` glob expects `name-snap-*.png` but a single `-snap t`
  writes `name-snap.png` → every demo "skipped". Fix the glob (`name-snap*.png`)
  and run `make docs-snap` to confirm captures (.plan/triage.md entry).
- `doc/design/dye.md` §mesh list and any remaining `mesh.drawT`/instancing
  mentions in docs (`grep -rn drawInstanced doc/`).
- kkgold's stencilU/stencilIP dumps still exercise the f32-index stencil
  emitters — fine (they are a separate dialect), but add one `shader.kernelI`
  dump so the integer dialect is byte-pinned too.

---

## Suggested order

1 (bits — biggest payoff, unblocked by the i32 flip) → 2 (fragmentIr fold-in,
small) → 3 (tables: interleaved + edge kernel) → 6b (compile-on-apply) →
4 (earth pull) → 5 (group/sort) → 6a (`f/` recording, needs a design call).
Task 7 rides along. Test and commit each independently; every commit must pass
`sh test/oracles.sh` (8/8) and `zig build test`, and any dye.k change gets the
spirv-val rung re-run. When an oracle intentionally changes (new dumps), state
which rung you dropped and why in the commit message — never drop two rungs.
