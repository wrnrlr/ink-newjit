# Chapter 6 — Pendulum Chains and Distance Constraints

A single pendulum is one of physics' oldest worked examples. Chain three of them together — each bob hanging from the one above — and you have one of physics' most famous demonstrations of chaos: a system so sensitive to initial conditions that even the most accurate simulation eventually diverges from the true trajectory. This chapter extends the Position-Based Dynamics (PBD) framework introduced in the previous chapter to handle chains of particles connected by distance constraints. The result is a simulation that handles cloth, rope, hair, and multi-body linkages using the same simple idea: after each integration step, move particles so that the constraints are satisfied.

## Hard Distance Constraints

A distance constraint between two particles demands that the distance between them remains fixed at some rest length $l_0$. This is conceptually a spring with infinite stiffness — the link neither stretches nor compresses, no matter what forces act on it. Such constraints are called *hard* constraints, in contrast to soft constraints that allow some compliance.

There are three classical approaches to enforcing hard constraints:

**Spring forces.** Model the link as a very stiff spring. This works in principle but requires tuning a stiffness parameter, and large stiffness values cause numerical instability — the spring oscillates at frequencies too high for the integrator to resolve.

**Constraint forces.** Solve for the internal forces that keep particle velocities perpendicular to the link direction. This is mathematically rigorous but non-trivial to implement, especially when multiple constraints are coupled. Drift — the slow accumulation of constraint violation over time — is an additional problem that must be addressed separately.

**Generalized coordinates.** Parameterize the configuration by angles rather than Cartesian positions, so the constraint is satisfied by construction. A simple double pendulum is manageable this way, but the equations grow in complexity quickly. For a triple pendulum the Lagrangian derivation fills several pages.

PBD takes a different route. Rather than working with forces or specialized coordinates, it works directly with positions: after each integration step, nudge the particles so that the constraint is satisfied, then derive the new velocities from how far the particles moved.

## The Correction Step

Let particles $\mathbf{p}_0$ and $\mathbf{p}_1$ be connected by a link of rest length $l_0$. After integration their current distance is:

$$l = \|\mathbf{p}_1 - \mathbf{p}_0\|$$

The constraint error is $\Delta l = l - l_0$. The unit vector along the link is:

$$\hat{\mathbf{n}} = \frac{\mathbf{p}_1 - \mathbf{p}_0}{l}$$

The correction needed to eliminate the error is to move the two particles toward or away from each other along $\hat{\mathbf{n}}$ by a total of $\Delta l$. When the particles have equal mass the correction is split evenly:

$$\mathbf{p}_0 \mathrel{+}= +\tfrac{1}{2}\,\Delta l\,\hat{\mathbf{n}}$$
$$\mathbf{p}_1 \mathrel{+}= -\tfrac{1}{2}\,\Delta l\,\hat{\mathbf{n}}$$

When the masses differ, the correction is distributed in proportion to the *inverse masses* $w_i = 1/m_i$:

$$\mathbf{p}_0 \mathrel{+}= +\frac{w_0}{w_0 + w_1}\,\Delta l\,\hat{\mathbf{n}}$$
$$\mathbf{p}_1 \mathrel{+}= -\frac{w_1}{w_0 + w_1}\,\Delta l\,\hat{\mathbf{n}}$$

The inverse-mass weighting is the natural choice: a heavy particle should move less. It also handles the wall-attachment case gracefully. To fix a particle in place — as with the pivot of a pendulum — simply set its mass to infinity, which makes $w_0 = 0$. The fixed particle receives no correction, and the full adjustment is applied to its neighbor.

In code, the correction magnitude for each particle folds the direction vector in:

```javascript
var dx = p.pos[i].x - p.pos[i-1].x;
var dy = p.pos[i].y - p.pos[i-1].y;
var d  = Math.sqrt(dx * dx + dy * dy);
var w0 = p.masses[i-1] > 0.0 ? 1.0 / p.masses[i-1] : 0.0;
var w1 = p.masses[i]   > 0.0 ? 1.0 / p.masses[i]   : 0.0;
var corr = (p.lengths[i] - d) / d / (w0 + w1);
p.pos[i-1].x -= w0 * corr * dx;
p.pos[i-1].y -= w0 * corr * dy;
p.pos[i].x   += w1 * corr * dx;
p.pos[i].y   += w1 * corr * dy;
```

The factor `(p.lengths[i] - d) / d` is the fractional length error. Dividing by `(w0 + w1)` distributes that error in the correct proportions, and multiplying by the unnormalized direction vector `(dx, dy)` simultaneously applies the direction and magnitude without an explicit normalize step.

## Extending PBD to Multiple Particles

A chain of $N$ masses connected by $N$ links (with the first link anchored to a fixed pivot) is exactly an N-pendulum. The PBD loop extends naturally: iterate over all particles for the integration step, then iterate over all links for the constraint step, then update velocities.

```javascript
simulate(dt, gravity) {
    var p = this;

    // 1. Integrate velocities and positions
    for (var i = 1; i < p.masses.length; i++) {
        p.vel[i].y += dt * gravity;
        p.prevPos[i].x = p.pos[i].x;
        p.prevPos[i].y = p.pos[i].y;
        p.pos[i].x += p.vel[i].x * dt;
        p.pos[i].y += p.vel[i].y * dt;
    }

    // 2. Enforce distance constraints
    for (var i = 1; i < p.masses.length; i++) {
        var dx = p.pos[i].x - p.pos[i-1].x;
        var dy = p.pos[i].y - p.pos[i-1].y;
        var d  = Math.sqrt(dx * dx + dy * dy);
        var w0 = p.masses[i-1] > 0.0 ? 1.0 / p.masses[i-1] : 0.0;
        var w1 = p.masses[i]   > 0.0 ? 1.0 / p.masses[i]   : 0.0;
        var corr = (p.lengths[i] - d) / d / (w0 + w1);
        p.pos[i-1].x -= w0 * corr * dx;
        p.pos[i-1].y -= w0 * corr * dy;
        p.pos[i].x   += w1 * corr * dx;
        p.pos[i].y   += w1 * corr * dy;
    }

    // 3. Derive new velocities from displacement
    for (var i = 1; i < p.masses.length; i++) {
        p.vel[i].x = (p.pos[i].x - p.prevPos[i].x) / dt;
        p.vel[i].y = (p.pos[i].y - p.prevPos[i].y) / dt;
    }
}
```

The particle at index 0 is the fixed pivot. It has `mass = 0.0`, which makes its inverse weight zero in every constraint calculation — the anchor never moves. The rest of the chain is initialized by walking forward from the pivot, converting the given angles and link lengths into Cartesian positions:

```javascript
var x = 0.0, y = 0.0;
for (var i = 0; i < masses.length; i++) {
    x += lengths[i] * Math.sin(angles[i]);
    y += lengths[i] * -Math.cos(angles[i]);
    this.pos.push({ x, y });
    this.prevPos.push({ x, y });
    this.vel.push({ x: 0, y: 0 });
}
```

The chain configuration — its lengths, masses, and initial angles — is all stored in flat arrays. Because nothing in the algorithm assumes a particular length, the same code simulates a double, triple, or quintuple pendulum without modification. Extending the simulation to more bobs is as simple as appending entries to those arrays.

## Sub-stepping and Stability

One sub-step per frame produces a visibly damped system — the chain loses energy and settles faster than it should. This is not a fundamental flaw in the algorithm; it is a consequence of the large time step. Dividing the frame's time budget into many small sub-steps and running the full integrate-constrain-velocity loop each time restores accuracy:

```javascript
function simulate() {
    var sdt = scene.dt / scene.numSubSteps;
    for (var step = 0; step < scene.numSubSteps; step++)
        scene.pendulum.simulate(sdt, scene.gravity);
}
```

The improvement is dramatic. With five sub-steps, a rope or cloth simulation is convincing. With a hundred, a triple pendulum stays close to the reference trajectory for several seconds. For matching the chaotic path of a triple pendulum against an analytic reference over an extended run, ten thousand sub-steps were used — extreme, but the point was to isolate the method's accuracy rather than its performance.

## Accuracy: PBD vs. the Analytic Solution

The triple pendulum has no closed-form solution. To obtain a near-exact reference, one can derive the equations of motion from the Lagrangian and solve the resulting $3 \times 3$ linear system for the angular accelerations $\ddot{\theta}_1, \ddot{\theta}_2, \ddot{\theta}_3$ at each time step:

$$A \begin{pmatrix} \ddot{\theta}_1 \\ \ddot{\theta}_2 \\ \ddot{\theta}_3 \end{pmatrix} = \mathbf{b}$$

where the matrix $A$ and right-hand side $\mathbf{b}$ contain the current angles, angular velocities, link lengths, and masses. This linear system is then integrated with symplectic Euler using tiny time steps to produce a reference trajectory. Running PBD alongside this reference reveals a striking result: the two trajectories agree for a remarkably long time before chaos drives them apart.

This is worth emphasizing because it is often misunderstood. A competing method called XPBD fixes inaccuracies in PBD for *soft* constraints, where the stiffness parameter introduces errors. For *hard* constraints, PBD and XPBD are equally accurate. The divergence seen when comparing PBD against the analytic reference is not a bug — it is the inherent sensitivity of the chaotic system to tiny numerical differences. Any integrator, however sophisticated, will eventually diverge from the true trajectory of a triple pendulum.

The method also handles extreme mass ratios without special treatment. A chain with a 1:100 mass ratio between adjacent bobs runs stably with the same code, because the inverse-mass weighting automatically adjusts how much each particle moves during the correction step.

## Key Takeaways

- A **hard distance constraint** fixes the distance between two particles at a rest length $l_0$. It is the building block for ropes, cloth, hair, and rigid linkages.
- PBD enforces constraints by **directly correcting positions** after each integration step, then deriving velocities from the displacement. No force tuning or specialized coordinate systems are needed.
- Corrections are distributed by **inverse mass**: a particle with twice the mass receives half the displacement. Setting mass to infinity pins a particle in place.
- The algorithm generalizes to **chains of any length** without modification — adding more bobs means adding entries to the length, mass, and angle arrays.
- **Sub-stepping** is the primary knob for accuracy. A handful of sub-steps suffices for cloth or rope; hundreds are needed to track a chaotic pendulum for more than a few seconds.
- For hard constraints, PBD is **as accurate as XPBD**. Trajectory divergence in chaotic systems reflects the physics, not a flaw in the method.
