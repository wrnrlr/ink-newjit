# Chapter 5 — Position-Based Dynamics: The Simplest Constraint Simulation

Many interesting physical systems are not free to move in any direction. A bead threaded onto a wire, the links of a chain, a robot arm's joints — all of these are *constrained*. Handling constraints correctly is one of the central challenges of physics simulation, and the literature offers a spectrum of methods ranging from elegant but mathematically demanding formulations to simple geometric tricks that work surprisingly well in practice. This chapter introduces **Position-Based Dynamics (PBD)**, the simplest of those tricks. By the end you will have a working simulation of a bead swinging on a circular wire, an understanding of why the method works, and a clear picture of where its costs and limits lie.

---

## Three Classical Approaches to Constraint Dynamics

To appreciate why PBD is appealing, it helps to survey the alternatives. Take the canonical introductory example: a bead constrained to slide along a circular wire.

**Spring forces.** The simplest implementation adds a stiff spring that pulls the bead back toward the wire whenever it strays. The problem is stiffness tuning. Large spring constants make the governing ordinary differential equation stiff, requiring very small time steps for numerical stability.

**Generalized coordinates.** Replace the Cartesian pair $(x, y)$ with a single angle $\alpha$. The bead can never leave the wire because the wire's geometry is baked into the coordinate system. This is exact, but the derivation grows rapidly in complexity as the system grows in size.

**Constraint forces.** Solve explicitly for the forces that keep the constraint satisfied. This has a subtle fragility: positional drift — the slow accumulation of constraint violation — requires a separate stabilization step.

---

## The PBD Insight: Just Move the Particle

PBD sidesteps all of this with a question so simple it sounds almost naive: if the bead is not on the wire, what is the most direct way to fix that?

Move it onto the wire.

The closest point on a circle of radius $r$ centered at $\mathbf{c}$ to any position $\mathbf{x}$ is:

$$\mathbf{x}_{\text{projected}} = \mathbf{c} + r \cdot \frac{\mathbf{x} - \mathbf{c}}{\|\mathbf{x} - \mathbf{c}\|}$$

---

## The PBD Algorithm

The complete per-step algorithm for a single constrained particle is:

1. **Predict.** Apply external forces to the velocity, then advance the position:
$$\mathbf{v} \leftarrow \mathbf{v} + \mathbf{g}\, \Delta t, \quad \mathbf{p} \leftarrow \mathbf{x}, \quad \mathbf{x} \leftarrow \mathbf{x} + \mathbf{v}\, \Delta t$$

2. **Project.** Move $\mathbf{x}$ to satisfy the constraint (snap to wire).

3. **Velocity update.** Derive the new velocity implicitly from the position change:
$$\mathbf{v} \leftarrow \frac{\mathbf{x} - \mathbf{p}}{\Delta t}$$

Step 3 is the key insight. Because the velocity is recomputed from the actual displacement — which includes the constraint correction — it automatically becomes tangential to the wire.

---

## Implementing the Bead on a Wire

The bead state is a 7-element list `(px; py; vx; vy; cx; cy; wr)` where `(cx, cy)` is the wire center and `wr` is the wire radius. The step function carries all state as a single tuple:

```k
grav: -10.
sdt: (1.%60)%100.            / substep size: 1/60s / 100 substeps

pbdStep: {[s]
  px:s@0; py:s@1; vx:s@2; vy:s@3
  cx: s@4; cy: s@5; wr: s@6
  / 1. Predict: apply gravity, advance position
  vy: vy + grav*sdt
  ppx: px; ppy: py
  px2: px + vx*sdt; py2: py + vy*sdt
  / 2. Project: snap to circle
  dx: px2-cx; dy: py2-cy
  d: sqrt (dx*dx)+dy*dy
  px3: $[d>0.; cx+dx*(wr%d); px2]
  py3: $[d>0.; cy+dy*(wr%d); py2]
  / 3. Recover velocity from displacement
  vx2: (px3-ppx)%sdt
  vy2: (py3-ppy)%sdt
  (px3;py3;vx2;vy2;cx;cy;wr)
}
```

Note the parentheses in `sqrt (dx*dx)+dy*dy`: in ink, all operators are right-to-left with equal precedence, so `sqrt dx*dx+dy*dy` would parse as `sqrt(dx*(dx+dy*dy))` — incorrect. The explicit `(dx*dx)` ensures the squared x-component is computed first.

The simulation loop calls `pbdStep` repeatedly using the n-do adverb:

```k
/ One frame: 100 substeps per 1/60s frame
oneFrame: {100 pbdStep/ x}

/ Bead at 45° on unit circle, 10 seconds = 600 frames
s0: (0.707; 0.707; 0.; 0.; 0.; 0.; 1.)
\t result: 600 oneFrame/ s0
/ Verify bead is still on the unit circle:
sqrt ((result@0)*(result@0)) + (result@1)*(result@1)
```

---

## Substepping for Accuracy

The energy loss stems from the large $\Delta t$ relative to the timescale of the constrained motion. The standard remedy in PBD is **substepping**: divide each display frame into $N$ substeps of size $\Delta t / N$ and run the full predict–project–update cycle at each substep.

The improvement is dramatic. With $N = 10$ substeps the energy loss is already much reduced; at $N = 100$ the motion is visually indistinguishable from the analytic solution; at $N = 1000$ the two agree to high precision.

The substep size appears only in `sdt`, so changing the substep count requires only updating that global:

```k
sdt: (1.%60)%1000.           / 1000 substeps for high accuracy
```

Nothing else in `pbdStep` changes.

---

## Convergence to the Analytic Solution

The analytic bead uses the exact equation of motion for a particle on a circle of radius $r$, parameterized by angle $\alpha$:

$$\dot{\omega} = -\frac{g}{r} \sin \alpha, \qquad \dot{\alpha} = \omega$$

The analytic reference in ink, integrated with symplectic Euler:

```k
analyticStep: {[s]
  alpha:s@0; omega:s@1; r:s@2
  acc: (grav%r) * sin alpha
  omega2: omega + acc*sdt
  alpha2: alpha + omega2*sdt
  (alpha2; omega2; r)
}

/ Run analytic alongside PBD and compare positions
s0pbd: (0.707; 0.707; 0.; 0.; 0.; 0.; 1.)
s0ana: (0.7854; 0.; 1.)                  / angle=pi/4, omega=0, r=1
result: 600 {100 pbdStep/ x}/ s0pbd
aresult: 600 {100 analyticStep/ x}/ s0ana
```

At $N = 1000$ substeps the two trajectories agree perfectly within floating-point precision.

---

## Recovering Constraint Forces

In PBD the constraint force can be recovered from the positional correction $\lambda$. Because $\lambda$ is a length correction applied over time $\Delta t$, the implied acceleration is $\lambda / \Delta t^2$, and for unit mass the force magnitude is:

$$F_{\text{constraint}} = \frac{|\lambda|}{\Delta t^2}$$

The correction length $\lambda = wr - d$ is computed inside `pbdStep`. At 1000 substeps, the recovered force matches the analytic normal force $F = \omega^2 r + g \cos\alpha$ to better than one part in a thousand.

---

## Multiple Beads and Collisions

The approach extends naturally to multiple constrained particles. With several beads on the same wire, each bead is projected independently onto the wire, and bead–bead collisions are resolved as a separate pass using the position-based collision method from Chapter 3.

```k
/ Multi-bead simulation: n beads on one circle
/ State: (px_list; py_list; vx_list; vy_list; cx; cy; wr)
multiPbdStep: {[s]
  px:s@0; py:s@1; vx:s@2; vy:s@3
  cx:s@4; cy:s@5; wr:s@6
  n: #px
  / Predict all beads
  vy: vy + grav*sdt
  ppx: px; ppy: py
  px2: px + vx*sdt; py2: py + vy*sdt
  / Project all beads onto circle (vectorized)
  dx: px2-cx; dy: py2-cy
  d: sqrt (dx*dx)+dy*dy
  px3: cx + dx*(wr%d)
  py3: cy + dy*(wr%d)
  / Recover velocities
  vx2: (px3-ppx)%sdt
  vy2: (py3-ppy)%sdt
  (px3;py3;vx2;vy2;cx;cy;wr)
}
```

The constraint projection for all beads is fully vectorized: `dx`, `dy`, `d`, `px3`, `py3` are all arrays of length $n$, updated simultaneously.

---

## Key Takeaways

- **PBD reduces constraints to geometry.** Rather than solving for forces, PBD moves particles directly to satisfy constraints, then recomputes velocity from the displacement. No calculus, no linearization, no drift.

- **Velocity must be recomputed, not carried forward.** Advancing velocity without correcting it for the projection leads to unbounded energy growth.

- **Substepping controls accuracy.** The method is first-order; energy conservation improves as $\Delta t$ shrinks. Dividing a $1/60\,\text{s}$ frame into 100 substeps is sufficient for most interactive applications.

- **Operator precedence in ink is right-to-left.** Always parenthesize products that appear inside sums: write `(a*a)+b*b`, never `a*a+b*b`.

- **The method generalizes cleanly.** Replacing the circle projection with any other geometric projection — a line, a surface, a distance constraint between two particles — requires no change to the surrounding algorithm.
