# Chapter 5 — Position-Based Dynamics: The Simplest Constraint Simulation

Many interesting physical systems are not free to move in any direction. A bead threaded onto a wire, the links of a chain, a robot arm's joints — all of these are *constrained*. Handling constraints correctly is one of the central challenges of physics simulation, and the literature offers a spectrum of methods ranging from elegant but mathematically demanding formulations to simple geometric tricks that work surprisingly well in practice. This chapter introduces **Position-Based Dynamics (PBD)**, the simplest of those tricks. By the end you will have a working simulation of a bead swinging on a circular wire, an understanding of why the method works, and a clear picture of where its costs and limits lie.

---

## Three Classical Approaches to Constraint Dynamics

To appreciate why PBD is appealing, it helps to survey the alternatives. Take the canonical introductory example: a bead constrained to slide along a circular wire. The bead has one degree of freedom (its arc position) rather than the two a free particle would have.

**Spring forces.** The simplest implementation adds a stiff spring that pulls the bead back toward the wire whenever it strays. This requires no special mathematics — just an extra force term. The problem is stiffness tuning. To keep the bead close to the wire the spring constant must be large, but large spring constants make the governing ordinary differential equation stiff, requiring very small time steps for numerical stability. In practice you spend most of your computational budget fighting the stiffness rather than simulating interesting motion.

**Generalized coordinates.** A cleaner approach is to change variables so that the constraint is satisfied by construction. For the bead on a circle, replace the Cartesian pair $(x, y)$ with a single angle $\alpha$. The bead can never leave the wire because the wire's geometry is baked into the coordinate system. This is the textbook treatment and it is exact, but the derivation grows rapidly in complexity as the system grows in size. Even for this one-degree-of-freedom example, the equations of motion require careful application of the Euler–Lagrange formalism, and the result involves trigonometric identities that are specific to the circular geometry. For a robot arm or an articulated character with dozens of joints, the symbolic derivation becomes impractical to carry out by hand.

**Constraint forces.** A third approach — used in many professional rigid-body solvers — is to solve explicitly for the forces that keep the constraint satisfied. These forces act perpendicular to the constraint surface and ensure that the velocity remains tangential to it. The mathematics is cleaner than generalized coordinates but still requires linearizing the constraint and solving a system of linear equations at each time step. It also has a subtle fragility: the method keeps the *velocity* constraint satisfied, but if the position constraint is ever violated — due to accumulated integration error — there is no built-in mechanism to correct it. A separate stabilization step (Baumgarte stabilization or the like) must be added to prevent drift.

---

## The PBD Insight: Just Move the Particle

PBD sidesteps all of this with a question so simple it sounds almost naive: if the bead is not on the wire, what is the most direct way to fix that?

Move it onto the wire.

The closest point on a circle to any exterior position $\mathbf{x}$ is simply the point on the circle in the direction from the center $\mathbf{c}$ to $\mathbf{x}$:

$$\mathbf{x}_{\text{projected}} = \mathbf{c} + r \cdot \frac{\mathbf{x} - \mathbf{c}}{\|\mathbf{x} - \mathbf{c}\|}$$

This position correction $\lambda$ (the signed radial error) is trivially computed:

$$\lambda = r - \|\mathbf{x} - \mathbf{c}\|$$

The projected position is then:

$$\mathbf{x} \leftarrow \mathbf{x} + \lambda \, \hat{\mathbf{d}}$$

where $\hat{\mathbf{d}}$ is the unit vector from $\mathbf{c}$ to $\mathbf{x}$.

Position projection alone, however, introduces a subtle error. If we move the particle without updating its velocity, the stored velocity no longer reflects how the position actually changed. On the next step, gravity will accelerate the particle along the old velocity direction while the projection pulls it back to the wire — the net effect is an ever-growing correction force, and energy explodes. The fix is to *recompute* the velocity from the position change rather than carrying it forward.

---

## The PBD Algorithm

The complete per-step algorithm for a single constrained particle is:

1. **Predict.** Apply external forces to the velocity, then advance the position:

$$\mathbf{v} \leftarrow \mathbf{v} + \mathbf{g} \, \Delta t$$
$$\mathbf{p} \leftarrow \mathbf{x} \quad \text{(save previous position)}$$
$$\mathbf{x} \leftarrow \mathbf{x} + \mathbf{v} \, \Delta t$$

2. **Project.** Move $\mathbf{x}$ to satisfy the constraint (snap to wire).

3. **Velocity update.** Derive the new velocity implicitly from the position change:

$$\mathbf{v} \leftarrow \frac{\mathbf{x} - \mathbf{p}}{\Delta t}$$

Step 3 is the key insight. Because the velocity is recomputed from the actual displacement — which includes the constraint correction — it automatically becomes tangential to the wire. No explicit force computation is needed.

---

## Implementing the Bead on a Wire

The `Bead` class captures the algorithm directly. Each bead stores its current position, previous position, and velocity.

```javascript
class Bead {
    constructor(radius, mass, pos) {
        this.radius = radius;
        this.mass = mass;
        this.pos = pos.clone();
        this.prevPos = pos.clone();
        this.vel = new Vector2();
    }

    startStep(dt, gravity) {
        this.vel.add(gravity, dt);       // v += g * dt
        this.prevPos.set(this.pos);      // save x
        this.pos.add(this.vel, dt);      // x += v * dt
    }

    keepOnWire(center, radius) {
        var dir = new Vector2();
        dir.subtractVectors(this.pos, center);
        var len = dir.length();
        if (len == 0.0) return;
        dir.scale(1.0 / len);
        var lambda = physicsScene.wireRadius - len;  // signed radial error
        this.pos.add(dir, lambda);                   // project onto wire
        return lambda;
    }

    endStep(dt) {
        this.vel.subtractVectors(this.pos, this.prevPos);
        this.vel.scale(1.0 / dt);       // v = (x - p) / dt
    }
}
```

The simulation loop calls these three methods in order each frame:

```javascript
physicsScene.bead.startStep(dt, physicsScene.gravity);
physicsScene.bead.keepOnWire(physicsScene.wireCenter, physicsScene.wireRadius);
physicsScene.bead.endStep(dt);
```

Running this at a single step per frame ($\Delta t = 1/60\,\text{s}$) produces a bead that swings plausibly on the wire but slowly loses energy over time. This is not a bug in the constraint logic — it is a property of implicit integration, which the velocity recomputation step resembles. For many applications (games, interactive tools) this mild damping is harmless or even desirable, since real objects are damped anyway. But for accuracy-critical work, we need more.

---

## Substepping for Accuracy

The energy loss stems from the large $\Delta t$ relative to the timescale of the constrained motion. The standard remedy in PBD is **substepping**: divide each display frame into $N$ substeps of size $\Delta t / N$ and run the full predict–project–update cycle at each substep.

```javascript
function simulate() {
    var sdt = physicsScene.dt / physicsScene.numSteps;

    for (var step = 0; step < physicsScene.numSteps; step++) {
        physicsScene.bead.startStep(sdt, physicsScene.gravity);
        physicsScene.bead.keepOnWire(physicsScene.wireCenter, physicsScene.wireRadius);
        physicsScene.bead.endStep(sdt);
    }
}
```

Nothing else changes — the substep size `sdt` is passed uniformly to all three methods. At $N = 10$ substeps the energy loss is already much reduced; at $N = 100$ the motion is visually indistinguishable from the analytic solution; at $N = 1000$ the two agree to high precision.

---

## Convergence to the Analytic Solution

To verify correctness, we can run a reference simulation alongside the PBD bead. The analytic bead uses the exact equation of motion for a particle constrained to a circle of radius $r$, parameterized by angle $\alpha$:

$$\dot{\omega} = -\frac{g}{r} \sin \alpha, \qquad \dot{\alpha} = \omega$$

Integrating these two equations with a small $\Delta t$ via symplectic Euler gives a reference trajectory that is independent of the PBD projection logic.

```javascript
class AnalyticBead {
    constructor(radius, beadRadius, mass, angle) {
        this.radius = radius;
        this.angle = angle;
        this.omega = 0.0;
    }
    simulate(dt, gravity) {
        var acc = -gravity / this.radius * Math.sin(this.angle);
        this.omega += acc * dt;
        this.angle += this.omega * dt;
        var centrifugalForce = this.omega * this.omega * this.radius;
        return centrifugalForce + Math.cos(this.angle) * Math.abs(gravity);
    }
    getPos() {
        return new Vector2(
            Math.sin(this.angle) * this.radius,
           -Math.cos(this.angle) * this.radius);
    }
}
```

With $N = 1$ substep the PBD bead drifts visibly behind the analytic reference. With $N = 10$ they track closely. With $N = 1000$ they agree perfectly within floating-point precision. This is the hallmark of a consistent numerical method: the error shrinks as $\Delta t \to 0$, and in the limit the simulation converges to the true solution.

The implication is significant. PBD required no calculus beyond basic geometry, no trigonometry, no linearization, no tuning of spring constants, and no drift-stabilization scheme — yet it converges to the same answer as methods that require all of those things.

---

## Recovering Constraint Forces

A common objection to position-based methods is that they deal in displacements rather than forces, so the constraint force — the normal force exerted by the wire on the bead — is not directly available. This matters for applications where the force drives some other computation (fracture, wear, motor torque).

In PBD the constraint force can be recovered from the positional correction $\lambda$. Because $\lambda$ is a length correction applied over a time $\Delta t$, the implied acceleration is $\lambda / \Delta t^2$, and for unit mass the force magnitude is:

$$F_{\text{constraint}} = \frac{|\lambda|}{\Delta t^2}$$

For the bead-on-circle problem the analytic normal force is the sum of the centrifugal force and the radial component of gravity:

$$F_{\text{analytic}} = \omega^2 r + g \cos \alpha$$

At $N = 1000$ substeps the two quantities agree to better than one part in a thousand. The position-based correction implicitly encodes the correct force; we just have to divide by $\Delta t^2$ to retrieve it.

---

## Multiple Beads and Collisions

The approach extends naturally to multiple constrained particles. With several beads on the same wire, each bead is projected independently onto the wire, and bead–bead collisions are resolved as a separate pass using the position-based collision method from the previous chapter. The simulation loop becomes:

```javascript
for (var step = 0; step < physicsScene.numSteps; step++) {
    for (var i = 0; i < beads.length; i++)
        beads[i].startStep(sdt, physicsScene.gravity);

    for (var i = 0; i < beads.length; i++)
        beads[i].keepOnWire(physicsScene.wireCenter, physicsScene.wireRadius);

    for (var i = 0; i < beads.length; i++)
        beads[i].endStep(sdt);

    for (var i = 0; i < beads.length; i++)
        for (var j = 0; j < i; j++)
            handleBeadBeadCollision(beads[i], beads[j]);
}
```

The constraint projection and the collision resolution are both geometric corrections applied to positions; both are followed by the same velocity recomputation in `endStep`. This uniformity is one of PBD's structural advantages — adding new constraint types means writing a new projection function, not deriving new equations of motion.

---

## Key Takeaways

- **PBD reduces constraints to geometry.** Rather than solving for forces, PBD moves particles directly to satisfy constraints, then recomputes velocity from the displacement. No calculus, no linearization, no drift.

- **Velocity must be recomputed, not carried forward.** Advancing velocity without correcting it for the projection leads to unbounded energy growth. The recomputation $\mathbf{v} = (\mathbf{x} - \mathbf{p}) / \Delta t$ is the step that makes the method physically coherent.

- **Substepping controls accuracy.** The method is first-order; energy conservation improves as $\Delta t$ shrinks. Dividing a $1/60\,\text{s}$ frame into 10–100 substeps is sufficient for most interactive applications.

- **Convergence is provable by comparison.** Running PBD alongside an analytic or high-accuracy reference solver at decreasing substep sizes confirms that the method converges to the correct solution.

- **Constraint forces are recoverable.** The correction magnitude $\lambda$ divided by $\Delta t^2$ gives the constraint force, matching analytic predictions at small substep sizes.

- **The method generalizes cleanly.** Replacing `keepOnWire` with any other geometric projection — a line, a surface, a distance constraint between two particles — requires no change to the surrounding algorithm. This generality makes PBD the natural foundation for the soft-body and cloth simulations that follow in subsequent chapters.
