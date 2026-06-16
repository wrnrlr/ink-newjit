# Chapter 9 — Extended Position-Based Dynamics

Every physics simulation must answer a basic question: when two objects overlap, what do you do about it? The answer determines the character of the entire simulation — its stability, its accuracy, and how naturally it handles objects that should be rigid versus objects that should be soft. This chapter introduces Position-Based Dynamics (PBD) and its extension XPBD, a framework that turns constraint satisfaction directly into a physics integrator. The result is unconditionally stable, free of the drift that plagues impulse-based methods, and — with XPBD — physically correct even when softness is involved.

---

## Three Ways to Enforce Constraints

Imagine two rigid bodies overlapping by a penetration depth $d$. You have three fundamentally different strategies.

**Force-based simulation** computes a separating force proportional to the penetration depth: $f = k d$. Those forces modify velocities, which eventually push the positions apart. The problem: you need the overlap to exist to generate the corrective force. Reaction is always one step behind, and large $k$ introduces numerical instability.

**Impulse-based simulation** detects penetration and immediately applies an impulse to make velocities separating. This sidesteps the stiffness problem, but working only in velocity space introduces *drift*: consistent velocities do not guarantee consistent positions. Stabilisation tricks (Baumgarte, pseudo-velocities) are needed over time.

**Position-based dynamics** goes one step further: detect the overlap, then fix the positions directly. Velocities are derived afterward from how far positions changed. There is no lag, no drift, and the simulation is unconditionally stable regardless of time-step size.

| Method | Mechanism | Main issues |
|--------|-----------|-------------|
| Force-based | $f = kd$ → velocity → position | Overlap required; reaction lag; stiffness hard to tune |
| Impulse-based | detect → impulse → velocity | Drift (consistent v does not imply consistent x) |
| **Position-based (PBD)** | detect → fix position → update v | Unconditionally stable; no drift |

---

## The PBD Algorithm

The PBD loop generalises the bead-on-wire idea from Chapter 5 to many particles and many constraints:

```
Δtₛ ← Δt / n    (substep size)

for each substep:
    for all particles i:
        vᵢ ← vᵢ + Δtₛ g    (apply gravity)
        pᵢ ← xᵢ             (save pre-solve position)
        xᵢ ← xᵢ + Δtₛ vᵢ   (integrate freely)

    for all constraints C:
        solve(C, Δtₛ)        (correct positions)

    for all particles i:
        vᵢ ← (xᵢ − pᵢ) / Δtₛ (recover velocity)
```

In ink, one substep for a soft body with parallel arrays:

```k
grav: 0. -9.81 0.
sdt: (1.%60)%10.          / 10 substeps per 60 Hz frame

/ Pre-solve: gravity + predict positions
preSolve: {[pos;vel;invM;n]
  vel2: {$[invM@x=0.; vel@x; (vel@x)+grav*sdt]} each !n
  prevPos: pos
  pos2: {pos@x + (vel2@x)*sdt} each !n
  (pos2;vel2;prevPos)
}

/ Post-solve: recover velocity from displacement
postSolve: {[pos;prevPos;invM;n]
  {$[invM@x=0.; vel@x; (pos@x - prevPos@x)%sdt]} each !n
}
```

---

## Constraint Functions and Gradients

To solve a general constraint, express it as a scalar function $C(\mathbf{x}_1, \ldots, \mathbf{x}_n) = 0$. The **constraint gradient** $\nabla_i C$ with respect to particle $i$ points in the direction that increases $C$ when particle $i$ moves, and its magnitude tells how fast $C$ changes per unit of movement.

For a distance constraint between $\mathbf{x}_1$ and $\mathbf{x}_2$ with rest length $l_0$:

$$C = |\mathbf{x}_2 - \mathbf{x}_1| - l_0$$

$$\nabla_1 C = -\frac{\mathbf{x}_2 - \mathbf{x}_1}{|\mathbf{x}_2 - \mathbf{x}_1|}, \qquad \nabla_2 C = \frac{\mathbf{x}_2 - \mathbf{x}_1}{|\mathbf{x}_2 - \mathbf{x}_1|}$$

Both gradients have unit length.

---

## Solving a General Constraint (PBD)

Given $C$ and its gradients, the Lagrange multiplier is:

$$\lambda = \frac{-C(\mathbf{x}_1, \ldots, \mathbf{x}_n)}{\sum_i w_i \, |\nabla_i C|^2}$$

The correction for particle $i$ is then:

$$\Delta \mathbf{x}_i = \lambda \, w_i \, \nabla_i C$$

where $w_i = 1/m_i$ is the inverse mass. A particle with $w_i = 0$ (infinite mass / pinned) receives no correction.

---

## XPBD: Physically Correct Softness

In original PBD, softness depends on time-step size — smaller time steps make constraints stiffer. XPBD fixes this with a single change: introduce a **compliance** parameter $\alpha = 1/\text{stiffness}$ and add it to the denominator, scaled by the substep size:

$$\lambda = \frac{-C}{\displaystyle\sum_i w_i \, |\nabla_i C|^2 + \alpha / \Delta t_s^2}$$

When $\alpha = 0$, this reduces to standard PBD. Positive $\alpha$ gives controlled softness with a direct physical interpretation in SI units (m/N for a length constraint). The time-step scaling ensures the physical behaviour does not change when you adjust the substep count.

---

## Distance Constraint in Ink

For a distance constraint, $|\nabla_i C| = 1$, so the denominator simplifies to $(w_1 + w_2) + \alpha/\Delta t_s^2$:

```k
/ XPBD distance constraint between particles i and j
/ pos: list of 3-vectors; invM: float list
solveEdge: {[pos;invM;i;j;l0;alpha;sdt]
  p0: pos@i; p1: pos@j
  w0: invM@i; w1: invM@j
  wt: w0+w1
  dx: p1 - p0
  d: sqrt +/ dx*dx
  n: dx % (d|0.0001)           / unit direction, guard zero length
  C: d - l0
  lam: C % wt + alpha%sdt*sdt  / note: alpha/dt² added to denominator
  pos2: @[@[pos; i; +; n*lam*w0]; j; -; n*lam*w1]
  pos2
}
```

**Parenthesization note:** `wt + alpha%sdt*sdt` evaluates right-to-left as `wt + (alpha%(sdt*sdt))` which is correct — `%` is division, so `alpha%sdt*sdt` = `alpha / (sdt*sdt)` = `α/Δt²`. ✓

Quick test — two particles at distance 2 with rest length 1:

```k
pos: (0. 0. 0.; 2. 0. 0.)
invM: 1. 1.
r: solveEdge[pos; invM; 0; 1; 1.; 0.; 0.01]
r / → (0.5 0.0 0.0; 1.5 0.0 0.0): pulled symmetrically to distance 1
```

---

## Volume Constraint in Ink

The signed volume of a tetrahedron $(\mathbf{x}_1, \mathbf{x}_2, \mathbf{x}_3, \mathbf{x}_4)$ scaled by 6:

$$6V = [(\mathbf{x}_2 - \mathbf{x}_1) \times (\mathbf{x}_3 - \mathbf{x}_1)] \cdot (\mathbf{x}_4 - \mathbf{x}_1)$$

The constraint $C = 6V - 6V_{\text{rest}}$ has gradients (one per vertex) pointing normal to the opposite face:

$$\nabla_1 C = (\mathbf{x}_4 - \mathbf{x}_2) \times (\mathbf{x}_3 - \mathbf{x}_2)$$
$$\nabla_2 C = (\mathbf{x}_3 - \mathbf{x}_1) \times (\mathbf{x}_4 - \mathbf{x}_1)$$
$$\nabla_3 C = (\mathbf{x}_4 - \mathbf{x}_1) \times (\mathbf{x}_2 - \mathbf{x}_1)$$
$$\nabla_4 C = (\mathbf{x}_2 - \mathbf{x}_1) \times (\mathbf{x}_3 - \mathbf{x}_1)$$

```k
cross3: {[a;b]
  (((a@1)*(b@2))-(b@1)*(a@2)
   ((a@2)*(b@0))-(b@2)*(a@0)
   ((a@0)*(b@1))-(b@0)*(a@1))
}
dot3: {+/ x*y}
tetVol6: {[p1;p2;p3;p4] dot3[cross3[p2-p1; p3-p1]; p4-p1]}

/ XPBD volume constraint for one tetrahedron
/ pos: list of 3-vectors; indices i1..i4 are the four tet vertices
solveVol: {[pos;invM;i1;i2;i3;i4;rv6;alpha;sdt]
  p1:pos@i1; p2:pos@i2; p3:pos@i3; p4:pos@i4
  g1: cross3[p4-p2; p3-p2]
  g2: cross3[p3-p1; p4-p1]
  g3: cross3[p4-p1; p2-p1]
  g4: cross3[p2-p1; p3-p1]
  w1:invM@i1; w2:invM@i2; w3:invM@i3; w4:invM@i4
  / denominator: sum of wᵢ|∇ᵢC|², plus compliance
  denom: (w1*(+/g1*g1)) + (w2*(+/g2*g2)) + (w3*(+/g3*g3)) + w4*(+/g4*g4)
  C: tetVol6[p1;p2;p3;p4] - rv6
  lam: C % denom + alpha%sdt*sdt
  pos2: @[pos; i1; -; g1*lam*w1]
  pos3: @[pos2; i2; -; g2*lam*w2]
  pos4: @[pos3; i3; -; g3*lam*w3]
  @[pos4; i4; -; g4*lam*w4]
}
```

The denominator uses `(wᵢ*(+/gᵢ*gᵢ))` — the extra parentheses around each `wᵢ*|∇ᵢC|²` product prevent right-to-left mis-association in the subsequent additions.

---

## Substepping vs. Iterations

A critical insight from XPBD: **substepping outperforms iterating** the constraint solver. For the same compute budget, running $n$ substeps with one solver pass each converges far faster than running one step with $n$ iterations. This holds because each substep uses a smaller $\Delta t_s = \Delta t / n$, and the compliance term $\alpha/\Delta t_s^2$ grows with $n$, making constraints effectively stiffer per pass while maintaining physically correct behaviour.

With only one solver pass per substep, XPBD also eliminates the need to track accumulated Lagrange multipliers across iterations — the state is simply the particle positions.

```k
/ Full XPBD step for soft body: preSolve → solve edges → solve vols → postSolve
xpbdStep: {[s]
  pos:s@0; vel:s@1; invM:s@2; edges:s@3; tets:s@4
  n: #pos
  / Pre-solve: apply gravity, record prev positions, advance
  vel2: {[i] $[invM@i=0.; vel@i; (vel@i)+grav*sdt]} each !n
  prevPos: pos
  pos2: {[i] pos@i + (vel2@i)*sdt} each !n
  / Solve all edge constraints
  pos3: {[p;e] solveEdge[p; invM; e@0; e@1; e@2; edgeAlpha; sdt]}/ (pos2,;),edges
  / Solve all volume constraints
  pos4: {[p;t] solveVol[p; invM; t@0; t@1; t@2; t@3; t@4; volAlpha; sdt]}/ (pos3,;),tets
  / Post-solve: recover velocity
  vel3: {[i] $[invM@i=0.; vel2@i; (pos4@i - prevPos@i)%sdt]} each !n
  (pos4; vel3; invM; edges; tets)
}
```

---

## Key Takeaways

- **Position-based methods** correct positions directly, eliminating both the reaction lag of force-based simulation and the drift of impulse-based simulation. The simulation is unconditionally stable.

- **Any constraint** can be expressed as a scalar function $C(\mathbf{x}_1, \ldots, \mathbf{x}_n) = 0$. The gradient $\nabla_i C$ encodes both the correction direction and magnitude for each particle.

- **The PBD update:** $\lambda = -C / \sum_i w_i |\nabla_i C|^2$ and $\Delta\mathbf{x}_i = \lambda w_i \nabla_i C$. Inverse masses distribute corrections by movability.

- **XPBD** adds $\alpha/\Delta t_s^2$ to the denominator. This single change gives softness a physical unit, makes it time-step independent, and recovers hard PBD when $\alpha = 0$.

- **Substeps outperform iterations.** For a fixed compute budget, $n$ substeps with one pass each converges far faster than one step with $n$ passes.

- **The `+/ x*x` idiom** computes $|\mathbf{v}|^2$ correctly for any length vector, side-stepping right-to-left precedence issues.

- **The two formulas** ($\lambda$ and $\Delta\mathbf{x}_i$) handle every constraint type. Switching from a distance spring to a volume-preserving soft body requires only different $C$ and its gradients.
