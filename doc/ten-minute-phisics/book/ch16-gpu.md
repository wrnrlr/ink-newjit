# Chapter 16 — Simulation on the GPU

The previous chapters built a cloth simulator that runs on the CPU, walking through every particle and every constraint one at a time. It works, but it cannot scale. A cloth with 500,000 particles and 1.5 million distance constraints is simply too much work for a single core to handle at interactive rates. To get there we need a different kind of processor — one that was designed from the beginning to run the same program on millions of inputs at once. This chapter moves the simulation onto the GPU, explains why that architecture is such a natural fit for physics, and confronts the two concurrency problems that arise the moment multiple threads try to touch the same particle simultaneously.

---

## Why GPUs Are Ideal for Simulation

A modern GPU contains thousands of small compute cores. An RTX 3090, for example, has more than 10,000 of them. Those cores are not general-purpose: they excel at one specific task — running a single program on a very large number of independent inputs simultaneously. In graphics, that program is a pixel shader, and the inputs are the pixels on screen. In simulation, the same pattern appears naturally: we want to apply one update rule to every particle, and one constraint-solve rule to every constraint. The match is almost perfect.

The CPU, by contrast, has a handful of powerful cores — typically 8 to 32 — with deep pipelines, large caches, and sophisticated branch prediction. It dominates tasks that are sequential, branchy, or data-dependent. Simulation loops are rarely any of those things. The inner loop body is the same for every particle, the data dependencies are local, and the order of iteration rarely matters. Shifting that work to the GPU yields speedups that can exceed one hundred times for large simulations.

The key concept is the **kernel**: a function that runs once per element, with a unique thread index identifying which element it owns. On the GPU, each thread executes the kernel for exactly one element, and thousands of those threads run in parallel. The programmer writes the kernel once; the hardware handles the scheduling.

---

## CPU and GPU Memory Are Separate

One important hardware fact shapes everything that follows: the GPU has its own memory, distinct from the system RAM attached to the CPU. Before any GPU computation can begin, data must be transferred from host memory (CPU-side) to device memory (GPU-side). After the simulation step, results must be transferred back — at minimum the particle positions, so the renderer can draw the current frame.

These transfers happen over the PCIe bus and are relatively slow, so the goal is to minimize them. For a running simulation the pattern is:

1. Upload initial data once at startup.
2. Each frame: run all kernels entirely on the GPU.
3. Copy only the positions (and normals, for rendering) back to the CPU.

Everything else — previous positions, inverse masses, constraint IDs, rest lengths — stays on the GPU for the duration.

---

## NVIDIA Warp: GPU Kernels in Python

Writing GPU code traditionally means writing CUDA C++, which requires a separate compilation step and a steeper learning curve. NVIDIA's **Warp** library removes that barrier by letting you write GPU kernels as ordinary Python functions decorated with `@wp.kernel`. Warp compiles them to CUDA at runtime.

Allocating arrays on the GPU looks like this:

```python
import warp as wp

wp.init()

self.pos     = wp.array(pos, dtype=wp.vec3, device="cuda")
self.prevPos = wp.array(pos, dtype=wp.vec3, device="cuda")
self.vel     = wp.array(vel, dtype=wp.vec3, device="cuda")
self.hostPos = wp.array(pos, dtype=wp.vec3, device="cpu")
```

The `device="cuda"` argument places the array in GPU memory. `device="cpu"` keeps it in system RAM. The `hostPos` buffer is the destination for the copy-back step at the end of each frame.

Writing a kernel follows a fixed pattern. Here is the velocity-update step from position-based dynamics:

```python
@wp.kernel
def updateVel(dt: float,
              prevPos: wp.array(dtype=wp.vec3),
              pos:     wp.array(dtype=wp.vec3),
              vel:     wp.array(dtype=wp.vec3)):
    pNr = wp.tid()   # thread id == particle index
    vel[pNr] = (pos[pNr] - prevPos[pNr]) / dt
```

`wp.tid()` returns the thread's unique index, which we treat as the particle number. The kernel body is exactly what the CPU loop body would be — the GPU just runs it for all particles at once. Launching the kernel and copying results back:

```python
wp.launch(kernel=updateVel,
          inputs=[dt, self.prevPos, self.pos, self.vel],
          dim=self.numParticles,
          device="cuda")

wp.copy(self.hostPos, self.pos)
```

The `dim` argument tells Warp how many threads to launch — one per particle. The GPU schedules them across its cores, batches them into *warps* (groups of 32 threads that execute in lockstep on the same core), and runs as many batches in parallel as the hardware allows. If there are more threads than cores, each core handles multiple batches sequentially, but the programmer never sees this complexity.

---

## Challenge 1: Multiple Threads Writing the Same Particle

Per-particle kernels are safe because each thread writes to exactly one slot in the output array, and no two threads share a slot. Constraint kernels break this assumption.

Consider five distance constraints over four particles. Constraints 2, 3, and 5 all involve particle 2 — so three threads will try to add a position correction to `pos[2]` at the same moment. Without any synchronization, a thread can read the old value, compute a delta, and write it back, only to have another thread overwrite that result with its own stale-read delta. One or more corrections are silently lost. The simulation does not crash; it just drifts, which is worse.

The fix is an **atomic add**: a hardware-guaranteed read-modify-write that cannot be interrupted by another thread.

```python
wp.atomic_add(pos, id0,  w0 * dP)
wp.atomic_sub(pos, id1,  w1 * dP)
```

Atomic operations serialize conflicting accesses automatically. In the common case where no two threads hit the same address, they cost nothing extra. In the rare case of a conflict, one thread waits while the other completes. For a cloth mesh with thousands of constraints, conflicts are frequent enough that atomics alone are not sufficient — which leads to the second challenge.

---

## Challenge 2: Non-Deterministic Read-Write Ordering

Even with atomic adds, there is a subtler problem. The correction that constraint 3 computes for particle 2 depends on the *current position* of particle 2. But constraint 2 may have already atomically modified that position while constraint 3 was reading it — or it may not have, depending on which thread executed first. The result of the solve changes each frame, producing jitter.

There are two principled solutions.

### The Jacobi Solver

Instead of applying corrections directly to positions during the solve, accumulate them into a separate correction buffer `d`:

```
initialize d[i] = 0 for all particles

for each constraint c (all in parallel):
    compute dP
    atomic_add(d[id0],  w0 * dP)
    atomic_sub(d[id1],  w1 * dP)

for each particle i (all in parallel):
    pos[i] = pos[i] + s * d[i]
```

Because all constraint threads read from `pos`, which is frozen during the solve, the computation is deterministic: each thread sees the same snapshot of positions regardless of scheduling order. The correction buffer accumulates, and only after all constraints have finished does a second kernel apply the corrections.

The cost is convergence speed. Gauss-Seidel (the CPU sequential method) propagates a correction made to one particle immediately into the next constraint that uses it, so information travels fast. Jacobi uses positions from the start of the iteration, so information propagates one hop per substep. To avoid overshoot, the scale factor $s$ must be less than 1 — in practice around $\frac{1}{4}$. This means you need roughly four times as many substeps to match Gauss-Seidel quality, though the GPU's raw throughput can absorb that cost. One further drawback: momentum is not conserved unless the scaling is carefully matched to the local constraint valence, and that matching is difficult to get right for irregular meshes.

### Graph Coloring

The more principled solution is to partition constraints so that no two constraints in the same *color class* share a particle. Within a color class, all constraints are independent — they read and write disjoint memory locations — so the kernel is both deterministic and race-free. Processing each color class as a separate GPU launch restores full Gauss-Seidel quality without any magic scale factor.

Finding the partition is a classic graph-coloring problem. The constraint graph has one node per constraint and one edge between two constraints that share a particle. We want to color the nodes so that adjacent nodes (sharing-a-particle constraints) get different colors, using as few colors as possible.

Optimal coloring is NP-hard in general, but a simple **greedy algorithm** works well in practice:

```
colors = []
while unmarked constraints remain:
    S = new empty set
    clear particle marks
    for each unmarked constraint c:
        if none of c's particles are marked:
            add c to S
            mark c
            mark all of c's particles
    colors.append(S)
```

Each iteration of the outer loop produces one color class. For a regular cloth mesh with only horizontal and vertical stretch constraints, the result is exactly four colors — one for each of the two axis directions times two interleaved passes:

- Pass 0: horizontal constraints between columns 0–1, 2–3, 4–5, ...
- Pass 1: horizontal constraints between columns 1–2, 3–4, 5–6, ...
- Pass 2: vertical constraints between rows 0–1, 2–3, ...
- Pass 3: vertical constraints between rows 1–2, 3–4, ...

For an irregular tetrahedral mesh the number of colors grows with the maximum constraint valence of any single particle — but the GPU handles many color classes efficiently because each launch is still massively parallel.

### The Hybrid Approach

In practice, the greedy algorithm produces a small number of large independent sets followed by a long tail of small sets. The large sets are processed with graph coloring (full Gauss-Seidel quality, no scale factor). The tail is batched together and solved once with Jacobi. This hybrid trades a small amount of accuracy on the tail constraints for fewer GPU kernel launches. For cloth, shear and bending constraints are good candidates for the Jacobi tail because they do not need to be as stiff as the stretch constraints.

---

## The Cloth Simulation Loop

The full simulation step, with the hybrid solver, looks like this:

```python
def simulate(self):
    dt = timeStep / numSubsteps

    for step in range(numSubsteps):

        # Integration and collision
        wp.launch(kernel=self.integrate,
                  inputs=[dt, gravity, self.invMass,
                          self.prevPos, self.pos, self.vel,
                          self.sphereCenter, self.sphereRadius],
                  dim=self.numParticles, device="cuda")

        # Constraint solve passes
        firstConstraint = 0
        for passNr in range(len(self.passSizes)):
            numConstraints = self.passSizes[passNr]
            if self.passIndependent[passNr]:
                # Graph-coloring pass: write directly to pos
                wp.launch(kernel=self.solveDistanceConstraints,
                          inputs=[0, firstConstraint, self.invMass,
                                  self.pos, self.corr,
                                  self.distConstIds, self.constRestLengths],
                          dim=numConstraints, device="cuda")
            else:
                # Jacobi pass: accumulate into corr, then apply
                self.corr.zero_()
                wp.launch(kernel=self.solveDistanceConstraints,
                          inputs=[1, firstConstraint, self.invMass,
                                  self.pos, self.corr,
                                  self.distConstIds, self.constRestLengths],
                          dim=numConstraints, device="cuda")
                wp.launch(kernel=self.addCorrections,
                          inputs=[self.pos, self.corr, jacobiScale],
                          dim=self.numParticles, device="cuda")
            firstConstraint += numConstraints

        # Velocity update
        wp.launch(kernel=self.updateVel,
                  inputs=[dt, self.prevPos, self.pos, self.vel],
                  dim=self.numParticles, device="cuda")

    # Copy positions to CPU for rendering
    wp.copy(self.hostPos, self.pos)
```

The `solveType` flag in the kernel distinguishes graph-coloring passes (which write atomically into `pos` directly) from Jacobi passes (which accumulate into `corr`). The constraint index arrays are pre-sorted so that each pass covers a contiguous slice, identified by `firstConstraint` and `numConstraints`. The loop advances `firstConstraint` by `numConstraints` at the end of each pass.

At 30 substeps per frame on a 500 × 500 cloth (250,001 particles, 1.5 million constraints), this loop solves roughly 1.35 billion distance constraints per second on a single GPU — something no CPU could approach.

---

## Surface Normals on the GPU

Rendering a lit cloth requires per-vertex normals. Each vertex accumulates the area-weighted normals of all its adjacent triangles — a classic fan accumulation that, on the GPU, faces the same race condition as constraint solving. The solution is the same: atomic adds.

```python
@wp.kernel
def addNormals(pos, triIds, normals):
    triNr = wp.tid()
    id0 = triIds[3 * triNr]
    id1 = triIds[3 * triNr + 1]
    id2 = triIds[3 * triNr + 2]
    n = wp.cross(pos[id1] - pos[id0], pos[id2] - pos[id0])
    wp.atomic_add(normals, id0, n)
    wp.atomic_add(normals, id1, n)
    wp.atomic_add(normals, id2, n)
```

A second kernel then normalizes each accumulated normal to unit length. These two kernels replace what would have been a sequential CPU loop over every triangle. Here the race condition is harmless in the weak sense — adding contributions in a different order produces the same final sum because floating-point addition is commutative modulo rounding — but atomic adds ensure no contribution is lost.

---

## What the Numbers Show

A 500 × 500 cloth has 250,001 particles, 500,000 triangles, and roughly 1.5 million distance constraints. On a GPU, the simulation runs at 30 frames per second with 30 substeps per frame. On a CPU, the same workload would be roughly two to three orders of magnitude slower at comparable settings.

The speedup does not come from the GPU being faster clock-for-clock — it is not. It comes from the fact that the GPU exposes thousands of cores to a workload that is embarrassingly parallel. The simulation author is not a passive beneficiary of this: the graph coloring, the Jacobi fallback, and the careful data layout (constraint IDs sorted by pass, all arrays resident on the device) are engineering choices that make the workload suit the hardware. Simulation on the GPU is not just "run the CPU code on a different chip." It requires rethinking which operations happen when, and in what order threads are allowed to interfere.

---

## Key Takeaways

- **GPU parallelism** is a natural fit for simulation: both graphics shaders and physics kernels apply a single program to a large collection of independent elements.
- **Data residency matters**: keep all simulation arrays on the GPU and copy only the minimum required (positions, normals) back to the CPU each frame.
- **NVIDIA Warp** lets you write CUDA kernels as decorated Python functions, lowering the barrier to GPU simulation without sacrificing performance.
- **Atomic operations** prevent lost updates when multiple threads correct the same particle, but they do not by themselves make the solve deterministic.
- **The Jacobi solver** restores determinism by accumulating all corrections into a scratch buffer and applying them in a separate pass. It requires a scale factor $s \lesssim \tfrac{1}{4}$ to prevent overshoot, and converges more slowly than Gauss-Seidel.
- **Graph coloring** partitions constraints into independent sets that can be solved in full Gauss-Seidel style on the GPU, one color per kernel launch, with no scale factor and no convergence penalty. Regular cloth needs four colors; irregular meshes need more.
- **Hybrid solvers** use graph coloring for the large, stiff constraint sets and a single Jacobi pass for the small tail, reducing kernel launches without meaningfully degrading quality.
- At scale, a GPU cloth solver can process more than **one billion constraint solves per second** — a throughput no CPU can match.
