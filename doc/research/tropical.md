# Tropical / max-plus methods in the Ink compiler

**Status: CLOSED — negative result.** A three-monomial max-plus cost model is a decent
regime classifier on uniform kernel shapes and **cannot rank schedules on real ones**.
Task 1 phase 2 (using cost to choose plans) was dropped; Tasks 2-4 were never started
and should not be. `kk.cost`/`kk.why` and the synthetic `bench/tropical.*` harness have
been REMOVED from the tree. This document is kept as the record of what was measured
and what it cost, because the negative result is the useful part.

What the work produced, and it was not the cost model:

- **Four VM correctness fixes** (`.plan/triage.md` #24), including a swallowed
  `StackOverflow` that returned a plausible wrong number instead of an error, and an
  unwind path that left `vm.current_chunk` pointing at an abandoned callee. Chain-length
  cap went from 27 ops to 300.
- **A 4-7.4x speedup** in `lib/nn.k`'s resident GPU ops: `gpuBufferWrite` drained the
  queue (`vkQueueSubmit` + `vkQueueWaitIdle`) on every call, defeating the deferred
  batching the resident-buffer design is built on.
- **Two silent-zero defects fixed** in kk (`.plan/triage.md` #25).
- **A reliable in-process benchmark harness** (`bench/nnshapes.*`), after the
  subprocess-timing approach was shown to be wrong four different ways.
- **One retracted bug report** (#23) that turned out to be a broken test generator.
- **A flaky oracle traced to a real bug**: `test/kkint.k`'s `transI` had no
  over-dispatch guard, so 52 stray threads wrote back into the live output range and
  the check passed only ~5 runs in 6.
- **A second unconditional drain** in `gpuBufferFree`, now fixed (`.plan/triage.md` #26)
  — worth only 1.03x, because consecutive frees share one drain; the value in that fix
  turned out to be the uninitialised `Vk` fields it exposed.

End-to-end payoff of the one drain that IS fixed: **2.04x on an MHSA block** (T=64,
D=256, interleaved best-of over 3 rounds). Microbenchmarks showed 4-7.4x; the smaller
end-to-end figure is the honest one.

The method that produced all of it: demand that the compiler predict its own
performance, then chase every residual. The max-plus formalism supplied the discipline
of asking "which monomial should dominate here, and does it?" — not a usable ranker.

A caution recorded here because it invalidated a chunk of the work: **affine arithmetic
chains are folded away by the Metal compiler.** `0.0001+1.0001*(...)` composed K times
is still `a*x+b`, so a 256-op chain measured identically to a 1-op chain while
`spirv-dis` confirmed dye emitted all 256 operations. Any benchmark that simulates
compute load with affine arithmetic is measuring nothing.

---

## 0. Scope

The useful content here is **idempotent / max-plus algebra**, not tropical algebraic
geometry. Enumerative geometry, mirror symmetry and Berkovich spaces have no bearing on
this compiler and are out of scope. What survives is one structural claim worth testing:

> A kernel's runtime is closer to `max(memory, compute, launch)` than to their sum, so
> the cost domain is a max-plus semiring, and the set of configurations where two
> resources tie — the point at which the optimiser's answer changes — is the **tropical
> hypersurface** of the cost polynomial.

That is a falsifiable claim about real hardware, and it is what Experiment 1 tests.

Note what this is *not* proposing. `doc/design/kk.md:150` and `:336` commit kk to
schedules that are **never inferred** — ping-pong vs in-place is an explicit escape
hatch, not a solver's output. Nothing here changes that. The polyhedral-style question
("which schedules are legal?") stays where it is; this is only about the cost landscape
over schedules that are already legal.

## 1. Why this repo is a good host

Three assets that most compilers do not have:

- **One neutral IR, two backends.** `lib/dye.k` lowers it to SPIR-V; `lib/bits.k`
  interprets the same `xOp` nodes on the CPU. A cost model is a *third* interpreter over
  the same IR, and `lib/bits.k` (183 lines) is the template.
- **A plan cache keyed on shapes.** `kk.plan` (lib/kk.k:52) already produces a reusable
  plan dict per (lambda source, input count, placement signature). That dict is the
  natural carrier for a symbolic cost expression.
- **A working oracle ladder.** `test/oracles.sh`, `make bench`, `-snap`. Cost-model
  claims can be checked against measurement instead of asserted.

Against that: **ink has no cost model at all today.** `doc/design/kk.md:344` says every
scheduling default is measured against the dumb path via `make bench`. So there is no
heuristic to beat, and "did this help?" has no incumbent baseline. Greenfield cuts both
ways.

---

## 2. Task 1 — tropical cost polynomials over `kk.plan`

Attach to each plan a symbolic cost, a tropical polynomial in the problem parameters:

```
T(N, K) = max( L , N·(bytes/elem)/BW , N·w(K)/F )
```

three monomials — launch, memory, compute — combined with max-plus `⊕ = max`,
`⊗ = +`. Two schedules are cost-equivalent exactly where their polynomials tie, and the
tie locus is the tropical hypersurface. In log coordinates `(log N, log K)` the three
monomials are planes and the hypersurface is the familiar tripod: three rays meeting at a
vertex, one ray per pairwise tie. **The roofline ridge point is a tropical vertex.** That
is not an analogy; it is the same object.

### Phase 0 (done): does the piecewise-linear form describe real hardware?

Before any of this touches the compiler, the form has to survive contact with a GPU.

**Method.** One elementwise kk kernel, one input buffer, one output buffer reused across
all `R` dispatches so memory stays fixed and `R` adds only work. Two kernel families:

| family | body | ops/elem | why |
|---|---|---|---|
| `f` | `0.0001+1.0001*…x` (K unrolled FMAs) | K | pure arithmetic ray |
| `s` | `sin sin … x` (K chained) | ≈24K | the FMA chain **cannot reach the ridge** (see below) |

Per-dispatch time comes from running each configuration at `R` and `4R` dispatches in
separate processes and differencing — process start-up, device creation, the upload and
the readback all cancel. Each point is the min of 2 runs. Grid: N = 2^10…2^24 × K =
1,2,4,8,16 × 2 families = 80 points.

The second family is not decoration. An elementwise map moves 8 bytes/element, and the
chain length is capped at 27 ops by a compiler bug (§6), so the FMA family tops out at
~4 flop/byte against a machine balance of ~25 — **it can never cross the ridge.** A `sin`
costs ~12–24 FMAs, which buys the missing order of magnitude inside the same op budget.

### Results

Per-dispatch time, µs, M1 Pro (MoltenVK, Vulkan 1.2):

```
              2^10   2^12   2^14   2^16   2^18   2^20   2^22   2^24
  f1          34.7   34.3   32.9   36.0   36.5   57.1   177.6   806.7
  f16         34.3   33.3   33.5   34.5   37.4   48.5   174.0   865.0
  s1          35.5   33.5   34.2   32.9   36.4   57.7   181.4   853.0
  s16         37.8   32.6   32.8   44.8   78.7  162.7   522.6  1943.2
```

**Finding 1 — the piecewise-linear form is real, and sharp.** Every one of the ten
kernels sits on a flat launch plateau of 32.5–33.7 µs (spread ±2%) out to 2^18, then
turns onto a linear ray. A constant term and a linear term meeting at a corner is
precisely the max-plus shape; nothing here is smooth.

**Finding 2 — the vertex is where the model says, and moves as the model says.** Fitting
only the floor `L` and the ray slope per kernel and intersecting them:

| kernel | L (µs) | slope (µs/Melem) | predicted vertex N* | measured knee |
|---|---|---|---|---|
| f1  | 32.9 | 48.1 | 684 k (2^19.4) | 2^20 |
| f16 | 33.3 | 51.6 | 646 k (2^19.3) | 2^20 |
| s1  | 32.9 | 50.8 | 648 k (2^19.3) | 2^20 |
| s4  | 33.1 | 53.9 | 615 k (2^19.2) | 2^18 |
| s8  | 33.3 | 70.0 | 476 k (2^18.9) | 2^18 |
| s16 | 32.6 | 115.8 | 281 k (2^18.1) | 2^16–2^18 |

Every prediction lands within the octave-spaced sampling grid, and the vertex slides left
monotonically as arithmetic intensity rises — the ridge migrating across the tripod. The
`f` family's slope moves only 48.1 → 51.6 µs/Melem across a **16× arithmetic increase**
(memory-bound throughout, as predicted from its intensity), while the `s` family's slope
more than doubles, 50.8 → 115.8. Those are the two rays.

**Finding 3 — max is not more accurate than sum; it is more *identifiable*.** Fitting all
80 points globally (objective: RMS log error):

| model | params | RMS | median | 90th | max | fitted constants |
|---|---|---|---|---|---|---|
| `max(a,b,c)` | 4 | 15.4% | 6.0% | 18.8% | 46.7% | L=35.5 µs, BW=**164 GB/s**, F=**2.36 Tflop/s**, sin=12×FMA |
| `a+b+c` | 4 | 15.0% | 6.9% | 23.4% | 54.2% | L=32.4 µs, BW=**236 GB/s**, F=**6.64 Tflop/s**, sin=15×FMA |
| p-norm, p fitted | 5 | 11.2% | 4.2% | 16.5% | 34.1% | L=34.6 µs, BW=188 GB/s, F=9.04 Tflop/s, sin=34×FMA, **p=1.67** |

Max and sum are statistically indistinguishable on accuracy. The difference is in what
the parameters mean. **Only the max fit recovers physical machine constants** — 164 GB/s
and 2.36 Tflop/s are believable for an M1 Pro. The sum model buys identical accuracy by
inflating peak bandwidth to 236 GB/s, *above the physical bus*, because adding
contributions that actually overlap forces the peaks up to compensate. The 5-parameter
p-norm wins on error and loses all interpretability (9 Tflop/s).

This reframes the case for tropical cost models. It is not "max predicts better". It is:

> A max-plus cost model is the one whose fitted coefficients are identifiable as
> machine constants — which is what a compiler actually needs, because it must know
> *which resource is the bottleneck*, not merely the predicted time.

**Finding 4 — the model is worst exactly on its own tropical hypersurface.** Bucketing
the 80 points by how close they sit to the tie locus (ratio of second-largest to largest
monomial; 1.0 = exactly on the hypersurface):

| 2nd/1st monomial | points | mean abs. error |
|---|---|---|
| 0.00–0.25 (one term dominates) | 49 | 5.4% |
| 0.25–0.50 | 16 | 12.0% |
| 0.50–0.75 | 11 | 14.5% |
| 0.75–1.00 (on the tie locus) | 4 | **23.3%** |

Monotone, and 4.3× worse on the tie locus than far from it. This is the central
limitation and it is intrinsic, not a fitting artifact: real hardware *overlaps* memory
and compute where they are balanced, which a hard `max` cannot express (the fitted
p=1.67 is measuring exactly that overlap).

The consequence for the programme is specific and slightly uncomfortable:

> A tropical cost model is cheap, interpretable and accurate for **classifying regimes**
> — telling you a kernel is launch-bound, or that a fusion moved it off the memory ray.
> It is least reliable for **breaking ties**, which is the decision you most wanted it
> for. Any optimiser built on this must smooth near the vertex (p-norm, p≈1.7) or accept
> ~25% error precisely where two schedules are close.

That is a usable result either way — a regime classifier is worth having, and it is
honest about what it cannot do.

### Phase 1 (built, then REMOVED): `kk.cost` / `kk.why`

*Kept below as the record of what was built and why it did not survive Finding 6.*

Every plan constructor now records a static cost **shape** — `bpe` bytes/element, `ope`
weighted flops/element, `nd` dispatches, and `cx` (`` `exact `` or `` `coarse ``) marking
how trustworthy the byte accounting is for that path. `bpe` is per-path and real, not a
guess: a planar table charges only the columns the body reads, an interleaved one charges
the whole packed row, a gather charges source + index + output. `ope` is read off the CST
once in `kkPlanBuild`, before the pipe builders re-parse and clobber `Cst`.

`kk.cost[plan; n]` evaluates the three monomials; `kk.why[fn; args]` runs the kernel once
(so the extent is the true one for every plan kind) and prints the breakdown:

```
kk.why  {sin sin … x}
  plan     `map n=4194304 bytes/elem=8 flops/elem=384 (`exact)
  launch   36 us  (5%)
  memory   205 us  (30%)
  compute  682 us  (100%)
  => `compute-bound, 682 us, runner-up at 30% of it
```

Against measurement: 205 µs predicted vs 178 µs measured for the cheap kernel at 2^22
(+15%), 682 vs 523 for `sin`×16 (+31%). For a three-constant model with no per-kernel
tuning that is fine — and note the design decision that falls out of Finding 4: **the
model reports its own reliability.** `tie` (runner-up / winner) is the normalised
distance to the tropical hypersurface, and `kk.why` prints a warning past 0.75, where
Experiment 1 measured ~25% error. A cost model that says "I am in the regime where I am
wrong" is more useful than one that is silently confident.

`kk.calibrate[L; bytes_per_us; flops_per_us]` replaces the constants;
`python3 bench/tropical.py --calibrate` fits this machine and prints the line to paste.

**A caveat that only surfaced on the second calibration run.** Refitting independently
gave L = 35.8 µs and BW = 179 GB/s (vs 35.5 and 164 — reproducible), but F = 0.75 Tflop/s
with sin = 4× FMA, against the first fit's 2.36 Tflop/s with sin = 12×. Those are not in
conflict: the *products* agree to 5% (0.188 vs 0.197). **F and the op-weight table are
only jointly identifiable**, because no kernel in the grid is compute-bound with a
*known* flop count — the FMA family, the one whose arithmetic we know exactly, cannot
reach the ridge while chains are capped at 27 ops by §7's bug. So Finding 3's claim needs
qualifying: max recovers `L` and `BW` as physical constants; `F` is pinned only up to the
op weights, and the two must be recalibrated together or not at all. Fixing the
chain-length bug would close this directly, which makes it the highest-value follow-up.

### Phase 2 (next)

Use the cost to *choose*, not just report — the obvious first case is planar vs
interleaved table layout, where `bpe` already differs by construction and the decision is
currently made at placement time by hand. Gate it on `tie`: fall back to the existing
default whenever the two candidate plans land near the hypersurface, since that is
precisely where the model cannot tell them apart.

---

## 2b. Experiment 2 — real kernel shapes (lib/nn.k)

Experiment 1 measured ONE shape (elementwise map) very thoroughly: same 8 bytes/element
and one dispatch at every point, with only arithmetic varying. That is a weak test.
Experiment 2 runs eight of `lib/nn.k`'s production kernels — the ones the Parakeet
pipeline executes — over shapes the elementwise grid says nothing about: reductions per
output, shared-memory tiling, and multi-dispatch ops.
Harness `bench/nnshapes.k` + `bench/nnshapes.py`; model comparison `bench/nnfit.py`.

**Everything below is ReleaseFast.** Experiments run during development were built with a
plain `zig build`, which is DEBUG — the mistake this repo's notes explicitly warn about.
Re-measuring changed the picture materially at the cheap end (elementwise agreement went
from ~0.7x to ~1.0x) while leaving the launch floor alone (38.7us Release vs 36-45us
Debug — it is genuine Vulkan descriptor/recording cost, not interpreter overhead).

### Finding 5 — the model is excellent on uniform shapes and poor on real ones

| kernel | model / measured |
|---|---|
| silu, gelu (elementwise) | 0.82-1.02x |
| gemm, gemmt (launch-bound) | 0.88-0.93x |
| gemm S=512 | **5.49x** (model far too slow) |
| attnctx S=128/512 | 2.38x / 3.90x (too slow) |
| attnsc | 0.42-0.58x (too fast) |
| softmax, layernorm | 0.43-0.72x (too fast) |

Median error 53% over 36 points (51% on the stall-free subset), against ~3% for
Experiment 1 — and note the direction of travel: every harness improvement has made
the model look WORSE, because the earlier noise was flattering it. The failures are systematic and go in BOTH directions: too optimistic
where access is strided or serial, too pessimistic where there is cache reuse. Fitting
an occupancy floor `max(threads, P)` recovers nothing (P fits to 1-3); fitting a reuse
divisor for GEMM helps that kernel (5.8x) and cuts the worst case but not the median.

### Finding 6 — the model cannot rank two schedules for the same computation

This is the result that matters, because ranking schedules is the whole point of a
compiler cost model. Plain vs 8x8-tiled GEMM: identical flops, ~8x different analytic
traffic, and `lib/nn.k` chooses between them today with a hand-written 8-alignment test.

| S | predicted speedup | measured |
|---|---|---|
| 64 | 7.59x | **1.74x** |
| 128 | 7.79x | 1.71x |
| 512 | 7.95x | 2.46x |

Off by 3-4.5x (in-process timing; earlier Debug and subprocess runs put it anywhere
from 0.68x to 2.4x, which is its own comment on those harnesses). The hardware cache
already recovers most of what tiling buys, and the model has no notion of a cache. **Task 1 phase 2 — using kk.cost to choose
between plans — should be dropped, not deferred.** A three-monomial max-plus model is a
serviceable regime classifier on uniform shapes and is not fit to pick schedules.

### Finding 7 — the residuals located a real performance bug

The first Experiment 2 run showed the params-writing ops (softmax, layernorm, attnsc,
attnctx) running 3-10x slower than their kernels could account for, while ops without a
params write matched the model. The split was not by shape but by INVOCATION: those four
call `gpu.write` on a small params buffer every invocation, and `gpuBufferWrite` called
`v.sync()` unconditionally — `vkQueueSubmit` + `vkQueueWaitIdle`. Every call drained the
queue, defeating the deferred batching the resident-buffer design is built on.

Fixed in `lib/gpu/vk.zig` + `gpu_vk.zig`: track which buffers the current unsubmitted
batch references and drain only on a real conflict; and when the bytes already match
what the buffer holds, skip the write entirely (the dims are constant across calls, so
a `vkQueueWaitIdle` becomes a `memcmp`). Same-build ReleaseFast A/B:

| op | pre-fix | post-fix | speedup |
|---|---|---|---|
| softmax S=64 | 698.7us | 172.4us | 4.05x |
| softmax S=1024 | 727.7us | 181.6us | 4.01x |
| layernorm S=64 | 668.7us | 154.6us | 4.33x |
| attnsc S=64 | 625.6us | 84.4us | **7.41x** |
| attnctx S=64 | 490.1us | 68.9us | **7.11x** |

Same build, same session, revert-and-restore of that one hunk, timed IN-PROCESS.
An earlier subprocess-timed version of this A/B reported 2.7-5.2x — it UNDERSTATED
the win, because whole-process wall time buries a per-call stall under start-up and
device-creation noise. Residual wrapper overhead versus a hoisted params write is now
1.00-1.09x, i.e. the drain is gone rather than merely reduced.

### What Experiment 2 says about the programme

The tropical framing has paid for itself, but as a **forcing function for measurement**
rather than as a predictor. Demanding that the compiler predict its own performance, and
then chasing every residual, produced four VM correctness fixes and a 2.7-5.2x speedup in
shipped code. The max-plus formalism contributed the discipline of asking "which
monomial should dominate here, and does it?" — not a usable schedule ranker.

## 3. Task 2 — max-plus critical path over the dispatch DAG

Textbook max-plus, applied to workloads that already exist: the Parakeet ASR pipeline in
`lib/nn.k`, `test/clothgpu.k`, and `kk.loop`/`kk.converge`'s recorded dispatch chains.
Node cost from Task 1, edge from buffer dependency; earliest-start / latest-finish is a
max-plus matrix closure (Kleene star). Deliverable is a slack report per dispatch.

The open question is not correctness — it is whether the answer ever changes a decision
(dispatch merging, encoder ordering, where a barrier is redundant) or only reports
numbers. Worth one week to find out, and it composes with Task 4 (the closure is a
one-liner in the tropical library).

## 4. Task 3 — cost interpretation as a third IR backend

Abstract interpretation over the neutral IR into the max-plus semiring instead of into
values: `bits.run` already walks `xOp` nodes, so "run this kernel for its cost rather than
its result" is a variant interpreter. `test/kkbits.k` stays the structural check that both
interpreters see the same program.

This is the most elegant framing and the least urgent — Task 1 phase 1 gets a working cost
model without it. Do it when there are two consumers.

## 5. Task 4 — `lib/tropical.k`

The lowest-risk item and the substrate for Task 2. k's `&`/`|` are already min/max on
floats and `+/` is the fold, so min-plus matrix product is a one-liner, and it runs on the
GPU through `kk.compile` unchanged. Contents: min-plus/max-plus matmul, Kleene star,
all-pairs shortest path, critical path, and the max-plus linear systems used for
discrete-event scheduling. This will work; the only question is whether it is interesting.
It also makes a good demo, and it lets the compiler compute its own schedules in its own
language.

---

## 6. Rejected

- **Register pressure as a max-plus problem.** dye emits SSA SPIR-V; the driver allocates
  registers. There is no live-range problem in this compiler to reformulate.
- **Instruction selection / expression covering as a semiring DP.** `src/compiler/` is a
  tree walker with DCE and constant folding, not a covering DP. Nothing to generalise.
- **Tropical dependence analysis; sparse polyhedra.** Directly contradicts kk's "schedules
  are never inferred" commitment (`doc/design/kk.md:150`), and there is no polyhedral
  engine here to improve on.
- **Piecewise-linear schedule spaces / autotuning.** The tunable space is roughly four
  knobs (workgroup size, planar vs interleaved, ping-pong vs in-place, FusedMap chunk
  size). A grid sweep exhausts it; it does not need geometry.

## 7. Bugs found while building the harness

The experiment forced kernel shapes nobody had written before, and that flushed out four
runtime defects — one of which was silently corrupting numeric results. Full write-up in
`.plan/triage.md` #24 and #23.

**The chain-length cliff was never an emitter bug.** `spirv-dis` on the modules at 27, 28
and 29 ops showed all three valid with exactly the right `OpFAdd`/`OpFMul` counts. The
real causes, in the order they surfaced:

1. `FRAMES_MAX = 64` — `kkClassify` walks the CST by recursion, once per operator, so a
   28-op expression exhausted the VM call stack. Now 4096.
2. `callLambdaAndRun` did `runUntil(...) catch {}` then `pop()` — a `StackOverflow`
   became a **plausible-looking wrong number** instead of an error. That is the whole
   explanation for "silently wrong at exactly 28". Now returns an error value.
3. Neither the old `catch {}` nor the first fix restored `vm.current_chunk` on unwind, so
   the caller resumed against the abandoned callee's chunk and the VM panicked with an
   out-of-bounds constant index far from the real fault.
4. `STACK_MAX = 2048` was the next wall; past it the emitter silently produced a
   167-word stub kernel. Now 16384.

**Result: the cap went from 27 ops to 300**, GPU matching CPU at 27/28/32/64/100/128/200/
300, with every oracle rung still green (including `kkgold` byte-identity and
`spirv-val`). This directly unblocks the science — see below.

Still open: **`$lambda` drops parentheses out of a list**, and `kk.plan` re-parses `$fn`,
so a parenthesised body stored in a list compiles to a *different* expression on the GPU
with no error. All `bench/tropical.k` chains stay paren-free to dodge it. Also unfiled: a
plan cached across `gpu.computeRun` sessions returns zeros (cache not keyed on device),
and a lambda whose params are not named `x`/`y`/`z` returns zeros instead of being
rejected.

### What the fix bought the experiment

With chains capped at 27 ops the FMA family could only reach ~4 flop/byte against a ~25
machine balance, so it never crossed the ridge — which is exactly why `F` was identifiable
only as a product with the transcendental weight (§2, Finding 3's caveat). At 256 ops the
FMA family reaches **64 flop/byte**, comfortably past the ridge, with an exactly known
flop count. The grid is now 12 kernels (FMA K = 1…256, sin K = 1,4,16) and `F` is measured
directly rather than inferred, with the sin chains demoted to an independent cross-check
on the op weight.

## 8. Reproducing

The synthetic harness (`bench/tropical.*`), the cost model (`kk.cost`/`kk.why`) and
`test/kkcost.k` were all REMOVED when this line of work closed — the commands that used
them are gone with them. What survives and still runs:

```sh
zig build -Doptimize=ReleaseFast && zig build gpu -Doptimize=ReleaseFast
python3 bench/nnshapes.py --quick      # lib/nn.k's real kernels, in-process timing
python3 bench/nnshapes.py --reps 3     # full grid + wrapper-vs-hoisted + tiled GEMM
INK=zig-out/bin/ink sh test/oracles.sh
```

**Benchmark on a ReleaseFast build.** A plain `zig build` is Debug, and every number in
this document was initially taken that way. It left the launch floor alone (38.7us vs
36-45us) but distorted the cheap end badly — elementwise agreement moved from ~0.7x to
~1.0x on re-measurement.

**Time in-process.** `` `t[] `` (src/runtime/syms.zig) is a microsecond CLOCK_MONOTONIC
counter that works inside a lambda, so the timed region can sit inside `gpu.computeRun`
around the dispatch loop alone. Differencing whole-subprocess wall times charges every
point with process start-up, device creation, allocation, upload and readback; porting
away from it took reproducibility from ~80% to ~1% and removed a 65% inflation.
