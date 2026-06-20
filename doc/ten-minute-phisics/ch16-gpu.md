# Chapter 16 — Simulation on the GPU

The previous chapters built simulations that run on the CPU, processing every particle and constraint sequentially. For large simulations — a cloth with 500,000 particles and 1.5 million distance constraints — that is simply too much work for a single core at interactive rates. This chapter moves simulation onto the GPU, explains why that architecture is such a natural fit for physics, and shows how to write GPU kernels in ink.

---

## Why GPUs Are Ideal for Simulation

A modern GPU contains thousands of small compute cores. An RTX 3090 has more than 10,000 of them. Those cores excel at one task: running a single program on a very large number of independent inputs simultaneously. In graphics, that program is a pixel shader and the inputs are pixels on screen. In simulation, the same pattern appears naturally: apply one update rule to every particle, one constraint-solve rule to every constraint. The match is almost perfect.

The CPU has a handful of powerful cores — typically 8 to 32 — with deep pipelines, large caches, and sophisticated branch prediction. It dominates tasks that are sequential, branchy, or data-dependent. Simulation loops are rarely any of those things. The inner loop body is the same for every particle, data dependencies are local, and iteration order rarely matters.

The key concept is the **kernel**: a function that runs once per element, with a unique thread index identifying which element it owns. The programmer writes the kernel once; the hardware runs it in parallel across thousands of threads.

---

## GPU Compute in ink

Ink exposes GPU compute shaders through two functions in `lib/spirv.k`:

```k
2: "lib/spirv.k"
2: "lib/gpu.k"
```

- `compCompute[fn]` — compiles an ink lambda into a SPIR-V **1D map-over-buffer compute shader**. The function maps one `f32` element to one `f32` element. Generated shader uses workgroup size 64.
- `gpuCompute[spirv; input]` — runs the compiled compute shader on a float list `input`, returning a new float list of the same length.

```k
/ Double every element on the GPU
doubler: compCompute[{[x] x*2}]
result: gpuCompute[doubler; 1. 2. 3. 4. 5.]
result     / → 2. 4. 6. 8. 10.
```

```k
/ Apply a nonlinear mapping: position correction clamp
clampShader: compCompute[{[x] x&0.1 | -0.1}]  / clamp to [-0.1, 0.1]
```

The GPU stays resident on the device between `gpuCompute` calls — data is uploaded once and the kernel runs in parallel across all elements. Call from inside the `gpuRun` frame callback:

```k
handle: 0
simState: 0. 0. ... / particle data as flat float list

loop: {[props]
  simState:: gpuCompute[integrateKernel; simState]
  gpuFillShader[renderVerts; handle]   / draw result
}
gpuRun[loop; 0]
```

---

## Particle Integration on the GPU

The simplest per-particle operation — applying gravity and advancing positions — maps directly to a compute kernel. Represent all positions as a flat float list `[x0 y0 z0 x1 y1 z1 ...]` and all velocities in a parallel flat list:

```k
/ GPU kernel: apply gravity and advance position for one particle component
/ Layout: interleaved (pos, vel) pairs — one float per component
/ For a 3D particle at index i: positions at 3i, 3i+1, 3i+2
/ This processes one float; the caller decides the layout
gravDt: -9.81 * 1.%(60*10)   / one substep of gravity (pre-multiplied)

integrateY: compCompute[{[vy] vy + -0.163}]  / add grav*sdt to y-velocity component
```

For a multi-component per-particle kernel, the current `compCompute` API applies one function to one element. Batch the update across all components by running separate kernels per axis, or pack state as interleaved scalars:

```k
/ Interleaved layout: [x0 vx0 y0 vy0 z0 vz0 x1 vx1 ...]  (6 floats per particle)
/ Integrate y-component (index 2 mod 6 = y-pos, index 3 mod 6 = vy)
integrateAll: compCompute[{[x] x}]   / identity — illustrates per-element dispatch
```

In practice, complex multi-field kernels with multiple buffer bindings require writing raw SPIR-V or using a higher-level GPU framework. The `compCompute` API provides a simple entry point for parallel scalar transforms.

---

## Challenge 1: Multiple Threads Writing the Same Particle

Per-particle kernels are safe because each thread writes exactly one output slot. Constraint kernels break this. A distance constraint between particles $i$ and $j$ must write corrections to both `pos[i]` and `pos[j]` — and another constraint involving $j$ may do the same simultaneously.

Without synchronization, two threads can read the same old value, compute deltas, and write back independently, with one result overwriting the other. The simulation does not crash; it just drifts silently.

The fix is **atomic operations**: hardware-guaranteed read-modify-write that cannot be interrupted. In GLSL/SPIR-V compute shaders, `atomicAdd` provides this guarantee for integer buffers; for floats, common idioms use `atomicCompareAndSwap` loops.

---

## Challenge 2: Non-Deterministic Read-Write Ordering

Even with atomic writes, there is a subtler problem. The correction that constraint A computes for particle $i$ depends on the current position of $i$, which constraint B may have already atomically modified. The result changes frame-to-frame, producing jitter.

Two principled solutions:

### The Jacobi Solver

Accumulate all corrections into a separate buffer, then apply them all at once in a second pass:

```
1. Zero correction buffer: corr[i] = 0 for all i
2. Parallel over constraints: compute correction dP, atomic_add(corr[i], w0 * dP), atomic_add(corr[j], w1 * dP)
3. Parallel over particles: pos[i] += scale * corr[i]
```

Because all constraint threads read from `pos` (frozen during step 2) and write to `corr`, the computation is deterministic: thread scheduling order does not affect the result. The scale factor $s \approx 1/4$ prevents overshoot. This needs roughly 4x more substeps to match sequential quality, but the GPU's raw throughput absorbs that cost.

### Graph Coloring

Partition constraints so that no two constraints in the same **color class** share a particle. Within a color, constraints are fully independent — they read and write disjoint memory — so the kernel is deterministic and race-free. Process each color as a separate GPU dispatch; this restores full Gauss-Seidel quality with no scale factor.

The greedy coloring algorithm:

```k
/ Greedy graph coloring of constraints
/ constraintIds: list of (i;j) pairs (the constraint graph edges)
/ Returns: list of color-class index lists
colorConstraints: {[constraintIds;nParticles]
  nC: #constraintIds
  colored: nC # -1      / -1 = uncolored
  colors: ()
  {
    / Each iteration: build one color class
    marked: nParticles # 0
    class: ()
    {[ci]
      $[colored@ci >= 0; 0;   / already colored
        [c: constraintIds@ci
         $[(marked@(c@0))|(marked@(c@1)); 0;  / shares a particle
           [class:: class,ci
            colored:: @[@[colored;ci;:;#colors];(c@0);:;1];(c@1);:;1]
            marked:: @[@[marked;(c@0);:;1];(c@1);:;1]]]
    }' !nC
    colors:: colors,,class
  } over {0<+/colored<0} / repeat until all colored
  colors
}
```

For a regular cloth mesh with only horizontal and vertical stretch constraints, the result is exactly four color classes — one for each axis direction in two interleaved passes.

---

## The Full GPU Simulation Loop

The complete simulation step, with hybrid solver (graph coloring for large constraint sets, Jacobi for the tail):

```k
/ GPU simulation setup (one-time)
/ integrateSpirv: compiled integrate kernel
/ constraintColorSpirv: list of compiled constraint kernels per color
/ jacobiSpirv: compiled Jacobi accumulation kernel
/ applySpirv: compiled correction-application kernel

gpuSimSetup: {[n;intFn;cFn;jFn;aFn]
  (compCompute[intFn]; {compCompute[cFn]}' !4; compCompute[jFn]; compCompute[aFn])
}

/ One simulation frame (inside gpuRun callback)
gpuSimFrame: {[setup;posGpu;velGpu;numSubsteps;sdt]
  intK: setup@0; colorKs: setup@1; jacobiK: setup@2; applyK: setup@3
  {[step]
    / Integration: gravity + position update (per-particle)
    posGpu:: gpuCompute[intK; posGpu]
    / Constraint solve: graph-coloring passes then Jacobi
    {[k] posGpu:: gpuCompute[k; posGpu]}' colorKs
    / Jacobi pass: accumulate, then apply
    corr: gpuCompute[jacobiK; posGpu]
    posGpu:: gpuCompute[applyK; posGpu + 0.25 * corr]
  }' !numSubsteps
  posGpu
}
```

---

## Counting the Math

A 500 × 500 cloth has 250,001 particles, 500,000 triangles, and ~1.5 million distance constraints. At 30 substeps per frame:

- **Per-substep integration:** 250,001 vector operations
- **Per-substep constraint solve:** 1.5 million distance evaluations and corrections
- **Total per frame:** ~45 million constraint solves

On a GPU with 10,000 cores processing in groups of 64, this is ~7,000 dispatch batches per substep — easily done in a few milliseconds. On a CPU, the same workload at sequential execution would take two to three orders of magnitude longer.

---

## Surface Normals on the GPU

Rendering a lit cloth requires per-vertex normals. Each vertex accumulates area-weighted normals from all adjacent triangles — the same fan-accumulation race condition as constraint solving, solved the same way via atomic adds:

```k
/ Normal accumulation kernel (one thread per triangle)
/ In SPIR-V: read 3 positions, compute cross product, atomic_add to 3 normal slots
normalKernel: compCompute[{[x] x}]   / placeholder — actual kernel requires multi-buffer SPIR-V

/ Normalize kernel (one thread per vertex)
normalizeKernel: compCompute[{[x] x}]   / placeholder
```

The two-pass pattern (accumulate in parallel, normalize in parallel) replaces a sequential CPU loop over every triangle. Adding contributions in different orders produces the same sum because addition is commutative — adding atomically ensures no contribution is lost.

---

## What ink's GPU API Can Do Today

The `compCompute` API compiles a single-element scalar function. For physics, this is directly useful for:

- **Scalar per-element transforms**: clamping velocities, applying gravity to a single component, normalizing scalar fields.
- **Temperature, pressure, and density fields** in grid-based simulations (Chapters 17–21), where each cell needs the same update applied independently.

For multi-field particle updates (reading positions and writing to velocities simultaneously) or constraint solves that write to two particles, raw SPIR-V with multiple buffer bindings is required. The compiler infrastructure in `lib/spirv.k` can be extended to support multi-input kernels, following the same SPIR-V patterns the current compiler uses.

---

## Key Takeaways

- **GPU parallelism** is a natural fit for simulation: the same program applied to thousands of independent elements is exactly what GPUs are designed for.
- **Data residency matters**: keep all simulation arrays on the GPU and copy only positions and normals back to the CPU each frame.
- **Ink's `compCompute`** compiles a scalar ink lambda to a SPIR-V 1D map kernel. Simple per-element transforms (gravity, clamping, field updates) run on the GPU with no GLSL required.
- **Atomic operations** prevent lost updates when multiple threads correct the same particle.
- **The Jacobi solver** restores determinism by accumulating all corrections into a scratch buffer. It requires scale factor $s \approx 1/4$ and converges more slowly than Gauss-Seidel.
- **Graph coloring** partitions constraints into independent sets solved with full Gauss-Seidel quality on the GPU, one color per kernel dispatch. Regular cloth needs four colors.
- **Hybrid solvers** use graph coloring for large stiff constraint sets and a single Jacobi pass for the tail, reducing kernel launches without degrading quality.
