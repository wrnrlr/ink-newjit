# Tropical / max-plus methods in the Ink compiler

**Status:** Experiment 1 (Task 1, phase 0) **run and measured** — see [Results](#results).
Tasks 2–4 specified, not started. Companion to `doc/research/columnar-execution.md`
(roofline / cost-model honesty) and `doc/design/kk.md` §2 "Scheduling decisions".

Harness: `bench/tropical.k` (generated kernels) + `bench/tropical.py` (driver, fitting).
Raw data reproducible with `python3 bench/tropical.py --reps 2 --json out.json`.

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

### Phase 1 (next)

1. Attach the symbolic triple `(bytes, ops, dispatches)` to the plan dict built by
   `kkPlanBuild` (lib/kk.k:56). Every path already knows its binding count and element
   count; this is bookkeeping, not analysis.
2. Calibrate `L`, `BW`, `F` **once per device** from `gpu.caps` plus a short probe, cached
   like `kkCaps` (lib/kk.k:414).
3. Expose `kk.cost[plan; args]` → the three monomials plus which one dominates. First
   consumer is a diagnostic, not a decision: `kk.why` telling the user why their kernel is
   slow. That is shippable on its own and needs no optimiser.
4. Only then: use it to choose between two legal plans, and gate that on the vertex
   caveat above.

---

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

Both are in `.plan/triage.md` with repros. Both were found *because* the experiment forced
unusual kernel shapes, which is an argument for keeping this harness around.

- **Chained-op cliff.** A kk elementwise chain is correct to 27 ops, **silently wrong at
  exactly 28** (returns ~2× the right answer), and fails to compile from 29. Silent
  miscompilation, not a diagnostic. This is what caps the FMA family's intensity and
  forced the `sin` family into the experiment.
- **`$lambda` drops parentheses out of a list.** `kk.plan` re-parses `$fn`, so a
  parenthesised body stored in a list compiles to a *different expression* on the GPU —
  right-to-left re-association, no error. All `bench/tropical.k` chains are paren-free to
  dodge it.

Also worth noting, not yet filed as bugs:

- A `kk.plan` cached in one `gpu.computeRun` and reused in the next returns **zeros** —
  the plan cache holds pipeline handles from a destroyed device and is not keyed on it.
- `kk` maps lambda parameters positionally to `x`/`y`/`z`; a lambda with differently-named
  params (`{[a] a+a}`) compiles and returns zeros instead of being rejected.

## 8. Reproducing

```sh
zig build && zig build gpu
python3 bench/tropical.py --quick            # 3 sizes x 4 kernels, ~1 min
python3 bench/tropical.py --reps 2 --json /tmp/trop.json   # full 80-point grid, ~6 min
```

`bench/tropical.k` was generated (unrolled chains + a `$[...]` family selector) and is
checked in as plain text — extend it by editing the chain bodies and the `KS`/`FAM`
tables directly. Keep chains ≤27 ops and parenthesis-free until §7's two bugs are fixed.
