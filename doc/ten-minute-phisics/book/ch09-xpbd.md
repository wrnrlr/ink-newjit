# Chapter 9 — Extended Position-Based Dynamics

Every physics simulation must answer a basic question: when two objects overlap, what do you do about it? The answer to that question determines the character of the entire simulation — its stability, its accuracy, and how naturally it handles objects that should be rigid versus objects that should be soft. This chapter introduces Position-Based Dynamics (PBD) and its extension XPBD, a framework that turns constraint satisfaction directly into a physics integrator. The result is unconditionally stable, free of the drift that plagues impulse-based methods, and — with XPBD — physically correct even when softness is involved.

## Three Ways to Enforce Constraints

Imagine two rigid bodies overlapping by a penetration depth d. You have three fundamentally different strategies for dealing with this situation.

**Force-based simulation** computes a separating force proportional to the penetration depth: f = k d, where k is called stiffness. Those forces modify velocities, which eventually push the positions apart. The approach has a serious problem: you need the overlap to exist in order to generate the corrective force. Reaction is always one step behind, and to make objects appear stiff you need a large k, which introduces numerical instability and overshooting. Small k makes everything squishy; large k breaks the solver. Setting k correctly to simulate a hard constraint is essentially impossible.

**Impulse-based simulation**, used in many rigid-body engines, detects penetration and immediately applies an impulse to make velocities separating. This sidesteps the stiffness problem — the velocity update is controlled and cannot overshoot. But working only in velocity space introduces *drift*: consistent velocities do not guarantee consistent positions. Positional constraints are satisfied only approximately, and additional stabilisation tricks (Baumgarte, pseudo-velocities) are needed to keep things from drifting apart over time.

**Position-based dynamics** goes one step further. Detect the overlap, then fix the positions directly. Velocities are derived afterward from how the positions changed. There is no lag, no drift, and — critically — the simulation is unconditionally stable regardless of the time-step size. The table below summarises the three approaches:

| Method | Mechanism | Main issues |
|--------|-----------|-------------|
| Force-based | f = kd → velocity → position | Overlap required; reaction lag; stiffness k is hard to tune |
| Impulse-based | detect → impulse → velocity | Drift (consistent v does not imply consistent x) |
| **Position-based (PBD)** | detect → fix position → update v | Unconditionally stable; no drift |

PBD is not merely a heuristic. It is closely related to implicit Euler integration — specifically, it corresponds to the first Newton iteration of a backward Euler step in variational form, solved with nonlinear Gauss-Seidel and initialised at the unconstrained inertial prediction. That description sounds complicated, but it points to something important: PBD has a rigorous physical foundation. Its only genuine weakness in the original formulation is that softness is handled incorrectly. XPBD fixes that.

## A Bead on a Wire

Before diving into the general framework, consider the simplest possible example: a bead constrained to lie on a wire. The bead has position **x** and velocity **v**. One simulation step proceeds in three stages.

1. **Integrate freely.** Store the old position as **p** ← **x**, then advance unconstrained: **x** ← **x** + Δt **v**. This is where the bead *would* end up if the wire did not exist. It is called the unconstrained or predicted position.

2. **Solve the constraint.** Project **x** onto the nearest point on the wire. This is the corrective step — purely geometric.

3. **Recover velocity.** **v** = (**x** − **p**) / Δt. The velocity is not integrated independently; it is *derived* from how far the position moved. This is what makes PBD an integrator and a solver simultaneously.

The elegance of this scheme is that stability is guaranteed by construction. No matter how large Δt is, the bead ends up on the wire. Energy may not be perfectly conserved, but the constraint is always satisfied.

## The PBD Algorithm

Generalising from a single bead to a collection of particles, the PBD loop looks like this:

```
Δtₛ ← Δt / n          // substep size

while simulating:
    for n substeps:
        for all particles i:
            vᵢ ← vᵢ + Δtₛ g       // apply gravity (and other external forces)
            pᵢ ← xᵢ               // store predicted position
            xᵢ ← xᵢ + Δtₛ vᵢ     // integrate freely

        for all constraints C:
            solve(C, Δtₛ)          // correct positions

        for all particles i:
            vᵢ ← (xᵢ − pᵢ) / Δtₛ // derive velocity from position change

solve(C, Δt):
    for all particles i of C:
        compute Δxᵢ
        xᵢ ← xᵢ + Δxᵢ
```

The substep count n deserves special attention. When constraints remain stretchy, the usual remedy is to run multiple *iterations* of the constraint loop within a single time step. That works, but there is a better alternative: use multiple *substeps* instead, each with a smaller Δtₛ = Δt/n, and within each substep solve each constraint only once. The convergence rate of substeps dramatically outpaces iterations for the same computational budget. This observation made many earlier convergence accelerations — hierarchical PBD, long-range attachments — largely obsolete. There is also a practical benefit: with only one iteration per substep, XPBD does not require tracking accumulated Lagrange multipliers across iterations.

## Constraint Functions and Gradients

To solve a general constraint, we need a common language for describing constraints. A **constraint function** C(**x**₁, …, **x**n) maps the positions of all participating particles to a scalar. The constraint is satisfied exactly when C = 0.

For a distance constraint between particles **x**₁ and **x**₂ with rest distance l₀:

$$C_\text{dist}(\mathbf{x}_1, \mathbf{x}_2) = |\mathbf{x}_2 - \mathbf{x}_1| - l_0$$

This is zero when the particles are at the right distance, positive when too far apart, and negative when too close.

Now comes the key concept: the **constraint gradient** ∇Cᵢ with respect to particle i. It is a vector with two properties:

- Its *direction* points toward where C increases most rapidly when **x**ᵢ is moved.
- Its *length* tells you how much C changes per unit of movement of **x**ᵢ.

For the distance constraint, consider moving particle 1 to maximally increase the distance between the two particles. The answer is obvious: move it away from particle 2, along the line connecting them. The gradient length is 1 because moving particle 1 by one unit changes the distance by exactly one unit. Therefore:

$$\nabla_1 C_\text{dist} = \frac{\mathbf{x}_1 - \mathbf{x}_2}{|\mathbf{x}_1 - \mathbf{x}_2|}$$

$$\nabla_2 C_\text{dist} = \frac{\mathbf{x}_2 - \mathbf{x}_1}{|\mathbf{x}_2 - \mathbf{x}_1|}$$

## Solving a General Constraint (PBD)

Given C and its gradients, PBD computes a scalar Lagrange multiplier λ and then applies a correction to each particle proportional to its gradient and inverse mass.

Let wᵢ = 1/mᵢ be the inverse mass of particle i. The Lagrange multiplier is:

$$\lambda = \frac{-C(\mathbf{x}_1, \ldots, \mathbf{x}_n)}{\sum_i w_i \, |\nabla_i C|^2}$$

The correction for particle i is then:

$$\Delta \mathbf{x}_i = \lambda \, w_i \, \nabla_i C$$

The negative sign in λ ensures we move in the direction that *reduces* C toward zero. The inverse masses in the denominator distribute the correction correctly: a particle with infinite mass (w = 0) receives no correction at all, behaving as a fixed anchor.

To verify these formulas, substitute the distance constraint gradients. With |∇₁C| = |∇₂C| = 1:

$$\lambda = \frac{-(l - l_0)}{w_1 + w_2}$$

$$\Delta \mathbf{x}_1 = \frac{w_1}{w_1 + w_2} \cdot (l - l_0) \cdot \frac{\mathbf{x}_2 - \mathbf{x}_1}{|\mathbf{x}_2 - \mathbf{x}_1|}$$

$$\Delta \mathbf{x}_2 = -\frac{w_2}{w_1 + w_2} \cdot (l - l_0) \cdot \frac{\mathbf{x}_2 - \mathbf{x}_1}{|\mathbf{x}_2 - \mathbf{x}_1|}$$

This matches the intuitive result: the total error (l − l₀) is split between the two particles in proportion to their inverse masses. A heavier particle moves less.

## XPBD: Physically Correct Softness

In original PBD, making a constraint soft is done by scaling the correction vectors by a stiffness factor k ∈ [0, 1]. Setting k = 1 gives a hard constraint; smaller values give softer behaviour. This is simple to implement but has a fatal flaw: the effective stiffness depends on the time-step size. Use a smaller time step and the constraint becomes stiffer, regardless of what you set k to. Softness cannot be specified in physically meaningful units.

XPBD (eXtended Position-Based Dynamics) fixes this with a single change. Introduce a **compliance** parameter α = 1/stiffness and add it to the denominator of λ, scaled by the substep size:

$$\lambda = \frac{-C(\mathbf{x}_1, \ldots, \mathbf{x}_n)}{\displaystyle\sum_i w_i \, |\nabla_i C|^2 + \frac{\alpha}{\Delta t_s^2}}$$

The correction formula Δ**x**ᵢ = λ wᵢ ∇Cᵢ remains unchanged.

When α = 0, the α/Δtₛ² term vanishes and the equation reduces exactly to standard PBD — a hard constraint. As α increases, the constraint becomes softer and the compliance has a direct physical interpretation in units of inverse stiffness (m/N for a length constraint). The time-step scaling in the denominator ensures that the physical behaviour does not change when you adjust the substep size.

## A Worked Example: Volume Conservation

The general framework handles constraints far beyond simple distances. For soft-body simulation, a fundamental constraint is that a tetrahedral element should preserve its volume.

Label the four vertices **x**₁, **x**₂, **x**₃, **x**₄ with rest volume V₀. The constraint function is:

$$C = 6(V - V_0) = [(\mathbf{x}_2 - \mathbf{x}_1) \times (\mathbf{x}_3 - \mathbf{x}_1)] \cdot (\mathbf{x}_4 - \mathbf{x}_1) - 6V_0$$

The factor of 6 is a bookkeeping convenience that simplifies the gradients. To find ∇₄C, ask: in which direction should **x**₄ move to maximally increase the volume of the tetrahedron? The answer is perpendicular to the opposite face — the base triangle formed by **x**₁, **x**₂, **x**₃. A cross product computes exactly this normal, and it happens to have the right length too. Applying this reasoning to all four vertices (using the right-hand rule) gives:

$$\nabla_1 C = (\mathbf{x}_4 - \mathbf{x}_2) \times (\mathbf{x}_3 - \mathbf{x}_2)$$
$$\nabla_2 C = (\mathbf{x}_3 - \mathbf{x}_1) \times (\mathbf{x}_4 - \mathbf{x}_1)$$
$$\nabla_3 C = (\mathbf{x}_4 - \mathbf{x}_1) \times (\mathbf{x}_2 - \mathbf{x}_1)$$
$$\nabla_4 C = (\mathbf{x}_2 - \mathbf{x}_1) \times (\mathbf{x}_3 - \mathbf{x}_1)$$

Plug these into the general λ formula (with or without α depending on how stiff the material should be) and apply Δ**x**ᵢ = λ wᵢ ∇Cᵢ to each vertex. That is the complete soft-body element update — no finite-element stiffness matrices, no linear solves, just geometry and the two formulas above.

## Key Takeaways

- **Position-based methods** correct positions directly, eliminating both the reaction lag of force-based simulation and the drift of impulse-based simulation. The simulation is unconditionally stable.

- **Any constraint** can be expressed as a scalar function C(**x**₁, …, **x**n) = 0. The constraint gradient ∇Cᵢ encodes both the correction direction and magnitude for each particle.

- **The PBD update** computes a Lagrange multiplier λ = −C / Σ(wᵢ |∇Cᵢ|²) and applies Δ**x**ᵢ = λ wᵢ ∇Cᵢ. Inverse masses distribute corrections in proportion to how movable each particle is.

- **XPBD** adds a compliance term α/Δtₛ² to the denominator of λ. This single change gives softness a physical unit, makes it time-step independent, and recovers hard PBD when α = 0.

- **Substeps outperform iterations.** For a fixed compute budget, running n substeps with one solver pass each converges far faster than running one step with n solver iterations.

- **The same two formulas** — λ and Δ**x**ᵢ — handle every constraint type. Switching from a distance spring to a volume-preserving soft body requires only a different C and its gradients.
