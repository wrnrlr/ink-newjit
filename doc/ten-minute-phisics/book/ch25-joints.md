# Chapter 25 — Joints: Assembling Rigid Bodies into Machines

The rigid bodies we have simulated so far inhabit a world of collisions and free-fall. Each body is sovereign — it responds to gravity and contact forces, but nothing constrains how one body moves relative to another. Real mechanisms are different. A door is a rigid body, but its motion is shaped by a hinge that permits rotation around one axis and nothing else. A piston can only translate along its cylinder bore. The bones of a skeleton are linked at joints that admit some rotations and absolutely forbid others.

This chapter adds that layer of structure. We will implement the most important joint types — hinge, ball-and-socket, prismatic, and cylinder — using exactly the same XPBD framework developed for rigid body simulation in earlier chapters. Two primitive routines, one for linear corrections and one for angular corrections, turn out to be sufficient building blocks for every joint a mechanical engineer or game developer is likely to need. The result is a simulator that can handle pendulums, car steering linkages, robot arms, and articulated ragdolls, all with the stability guarantees that make XPBD well suited to interactive applications.


## Recap: XPBD for Rigid Bodies

A rigid body carries six degrees of freedom: position **x** and orientation **q**. Between the integration step and the velocity update, XPBD inserts a constraint-solving phase. Each constraint computes a correction vector and applies it immediately to the affected bodies before moving on to the next constraint. This is a *local solver* — it works one constraint at a time rather than assembling and inverting a large system.

Local solvers converge slowly in the traditional formulation. The key insight that makes them competitive is **substepping**: instead of iterating through all constraints multiple times per frame, take a smaller time step and solve each constraint only once per substep. The convergence is equivalent to a global solver at a fraction of the implementation complexity, and stability is unconditional — even infinite stiffness does not cause the simulation to blow up.

Each substep executes in three phases:

1. **Integrate.** Apply gravity to velocities, advance positions and orientations.
2. **Solve.** Run through all joints and compute XPBD corrections to positions and orientations.
3. **Update velocities.** Derive new velocities from the change in position and orientation over the substep.

After the velocity update, a fourth phase applies velocity-level corrections for damping and actuator forces. The main loop in code is compact:

```js
let sdt = this.dt / this.numSubSteps;

for (let subStep = 0; subStep < this.numSubSteps; subStep++) {
    for (let i = 0; i < this.rigidBodies.length; i++)
        this.rigidBodies[i].integrate(sdt, this.gravity);

    for (let i = 0; i < this.joints.length; i++)
        this.joints[i].solve(sdt);

    for (let i = 0; i < this.rigidBodies.length; i++)
        this.rigidBodies[i].updateVelocities(sdt);

    for (let i = 0; i < this.joints.length; i++) {
        this.joints[i].applyLinearDamping(sdt);
        this.joints[i].applyAngularDamping(sdt);
    }
}
```

The simulator uses 20 substeps per rendered frame. This is the magic number that makes joints look rigid even under large external forces and large mass ratios.


## Two Primitive Operations

Every joint, regardless of type, is built from two fundamental routines. Understanding these routines is the key to understanding the entire system.

**ApplyLinearCorrection** pulls or pushes two world-space attachment points **p₁** and **p₂** by a correction vector Δ**p**. It distributes that correction between the two bodies in proportion to their generalized inverse masses, and it simultaneously updates both the position and the orientation of each body, because moving an attachment point that is off-center inevitably induces a torque.

The scalar constraint magnitude and Lagrange multiplier are:

```
C  = |Δp|
n  = Δp / C
wᵢ = mᵢ⁻¹ + (rᵢ × n)ᵀ Iᵢ⁻¹ (rᵢ × n)
λ  = −C / (w₁ + w₂ + α/Δt²)
```

where **rᵢ** = **pᵢ** − **xᵢ** is the lever arm from the body's center of mass to the attachment point, and α is the *compliance* (the inverse of stiffness). Setting α = 0 gives an infinitely stiff constraint. The resulting corrections are:

```
Δxᵢ = ±λ n mᵢ⁻¹
Δqᵢ = ±½ λ [Iᵢ⁻¹(rᵢ × n), 0] qᵢ
```

**ApplyAngularCorrection** rotates two bodies toward alignment by a correction vector Δ**φ**. It does not need attachment points — pure rotational corrections depend only on orientations, not positions:

```
C  = |Δφ|
n  = Δφ / C
wᵢ = nᵀ Iᵢ⁻¹ n
λ  = −C / (w₁ + w₂ + α/Δt²)
Δqᵢ = ±½ λ [Iᵢ⁻¹ n, 0] qᵢ
```

In code, both routines are packaged into a single `applyCorrection` method on `RigidBody`. Whether the correction is positional or angular is controlled by whether an attachment point `pos` is supplied:

```js
applyCorrection(compliance, corr, pos, otherBody, otherPos, velocityLevel = false) {
    let C = corr.length();
    let normal = corr.clone().normalize();
    let w = this.getInverseMass(normal, pos);
    if (otherBody)
        w += otherBody.getInverseMass(normal, otherPos);
    let alpha = compliance / this.dt / this.dt;
    let lambda = -C / (w + alpha);
    normal.multiplyScalar(-lambda);
    this._applyCorrection(normal, pos, velocityLevel);
    if (otherBody) {
        normal.multiplyScalar(-1.0);
        otherBody._applyCorrection(normal, otherPos, velocityLevel);
    }
}
```

The `velocityLevel` flag reuses the same distribution logic for damping corrections applied after the velocity update step, avoiding code duplication.


## Four Building Blocks

On top of the two primitives we construct four building-block procedures. Every joint type in this chapter is a short list of calls to these four procedures.

**Attach(p₁, p₂, d_rest, α).** Pull the attachment points to within `d_rest` of each other. For a rigid connection set `d_rest = 0`. For a soft spring use a nonzero compliance α.

```
Δp = p₂ − p₁,   correction = n · (|Δp| − d_rest)
```

**RestrictToAxis(a, p₁, p₂, p_min, p_max, α).** Force attachment point **p₂** to lie on the axis **a** through **p₁**, with the offset along **a** clamped to [p_min, p_max]. The correction is the component of (p₂ − p₁) perpendicular to **a**, with the axial component clamped to zero if within limits.

**AlignAxes(a₁, a₂, α).** Rotate two bodies so that axis **a₁** on body 1 aligns with axis **a₂** on body 2. The angular correction vector is:

```
Δφ = −a₁ × a₂
```

This is a first-order approximation valid for small misalignments within a single substep. Substepping keeps the misalignment small enough that the approximation is accurate.

**LimitAngle(n, a₁, a₂, φ_min, φ_max, α).** Compute the signed angle φ between axes **a₁** and **a₂** around the rotation axis **n**. If φ is within [φ_min, φ_max], do nothing. Otherwise clamp φ to the nearest limit, compute the target direction **a₂'** by rotating **a₁** by the clamped angle, and apply an angular correction to drive **a₂** toward **a₂'**:

```js
getAngle(n, a, b) {
    const c = new THREE.Vector3().crossVectors(a, b);
    let phi = Math.asin(c.dot(n));
    if (a.dot(b) < 0.0) phi = Math.PI - phi;
    if (phi >  Math.PI) phi -= 2.0 * Math.PI;
    if (phi < -Math.PI) phi += 2.0 * Math.PI;
    return phi;
}

limitAngle(n, a, b, minAngle, maxAngle, compliance) {
    let phi = this.getAngle(n, a, b);
    if (minAngle <= phi && phi <= maxAngle) return;
    phi = Math.max(minAngle, Math.min(phi, maxAngle));
    let ra = a.clone().applyAxisAngle(n, phi);
    let corr = new THREE.Vector3().crossVectors(ra, b);
    this.body0.applyCorrection(compliance, corr, null, this.body1, null);
}
```


## Attachment Frames

Before applying any building block, we need to know where and in what orientation a joint attaches to each body. This information is stored as an **attachment frame**: a local position `localPos` and a local orientation `localRot` expressed in the body's own coordinate system. At the beginning of each constraint-solve step, these local frames are transformed into world space using the body's current position and quaternion:

```js
updateGlobalFrames() {
    this.globalPos0.copy(this.localPos0)
        .applyQuaternion(this.body0.rot)
        .add(this.body0.pos);
    this.globalRot0.multiplyQuaternions(this.body0.rot, this.localRot0);

    this.globalPos1.copy(this.localPos1)
        .applyQuaternion(this.body1.rot)
        .add(this.body1.pos);
    this.globalRot1.multiplyQuaternions(this.body1.rot, this.localRot1);
}
```

When a joint is created, the two local frames are computed from a single global frame position and orientation provided at setup time. This is the natural way to specify a joint: you place it where the hinge pin goes in the assembled configuration, and the simulator works backwards to compute the body-relative offsets.


## Joint Types

With the building blocks in place, implementing specific joint types is straightforward.

### Hinge Joint

A hinge constrains two bodies so that they share one point in space and can only rotate around one common axis. In the attachment frame convention, the x-axis of the frame is the hinge axis.

```
solve hinge:
  Attach(p₁, p₂, 0, 0)           // merge attachment points
  AlignAxes(a₁_x, a₂_x, 0)       // align hinge axes
  LimitAngle(a₁_x, a₁_y, a₂_y, φ_min, φ_max, 0)   // joint limits
```

The `AlignAxes` call removes five degrees of freedom; only rotation around the shared hinge axis remains. The `LimitAngle` call then optionally clamps that remaining rotation to a user-specified range, using the perpendicular y-axis of each frame to measure the current angle around the hinge.

### Servo and Motor

A servo is a hinge that drives the angle to a specific target φ_target. The limit angles are set to `[φ_target, φ_target]` — a range of zero forces the angle to be exactly that value. A compliance parameter lets the servo be soft, mimicking a torque-limited actuator.

A velocity motor advances the target angle each substep by ω · Δt:

```js
if (this.type == Joint.TYPES.MOTOR) {
    let aAngle = Math.min(Math.max(this.velocity * dt, -1.0), 1.0);
    this.targetAngle += aAngle;
}
```

The one-line clamp is not just defensive coding. It guarantees that the motor cannot request an angular correction larger than a full radian per substep, which keeps the constraint solver from overshooting even at very high commanded velocities.

### Ball-and-Socket Joint

A ball-and-socket joint shares a point between two bodies and permits all three rotations, subject to optional cone (swing) and twist limits. There is no axis-alignment step, because we want the bodies to rotate freely relative to each other. Instead:

```
solve ball:
  Attach(p₁, p₂, 0, 0)
  LimitAngle(n_swing, a₁_x, a₂_x, 0, φ_swing_max, 0)    // swing cone
  LimitAngle(n_twist, a₁_y, a₂_y, φ_twist_min, φ_twist_max, 0)  // twist
```

For the swing limit the rotation axis **n** is computed as the cross product of the two main axes. For the twist limit it is the average of the two main axes, and the angle is measured between the secondary axes projected perpendicular to **n**:

```js
// twist limit
n.addVectors(a0, a1).normalize();
a0.addScaledVector(n, -n.dot(a0)).normalize();
a1.addScaledVector(n, -n.dot(a1)).normalize();
this.limitAngle(n, a0, a1, this.twistMin, this.twistMax, hardCompliance);
```

### Prismatic Joint

A prismatic joint locks all three rotations and two of the three translations, leaving one translational degree of freedom along a slide axis. It is the mechanical equivalent of a drawer or a piston rod.

```
solve prismatic:
  RestrictToAxis(a₁_x, p₁, p₂, d_min, d_max, 0)   // constrain to slide axis
  AlignAxes(a₁_x, a₂_x, 0)                         // lock rotations
  LimitAngle(a₁_x, a₁_y, a₂_y, 0, 0, 0)           // prevent torsion
```

### Cylinder Joint

A cylinder joint is like a prismatic joint but allows rotation around the slide axis in addition to translation along it — two degrees of freedom in total. The implementation is identical to prismatic except that the torsion limit is relaxed to [φ_twist_min, φ_twist_max] instead of [0, 0].


## The Joint Summary Table

| Type | DOF | Positional step | Orientation step |
|------|-----|-----------------|------------------|
| Fixed | 0 | Attach | AlignFrames (full quaternion) |
| Hinge | 1 rot | Attach | AlignAxes + LimitAngle |
| Servo | 0 (driven) | Attach | AlignAxes + LimitAngle to target |
| Motor | 0 (driven) | Attach | AlignAxes + advancing target |
| Ball-and-socket | 3 rot | Attach | LimitAngle (swing) + LimitAngle (twist) |
| Prismatic | 1 trans | RestrictToAxis | AlignAxes + LimitAngle (torsion) |
| Cylinder | 2 | RestrictToAxis | AlignAxes + LimitAngle (twist range) |

Every entry in this table is a handful of lines of code on top of the same two primitive operations.


## Velocity-Level Corrections: Damping and Forces

Position-based solvers naturally introduce some numerical damping as an artifact of the constraint solve. For realistic mechanical systems we often want explicit, controllable damping.

XPBD handles this in a separate pass after `updateVelocities`. The same distribution machinery — generalized inverse mass, correction proportional to it — applies, but now the corrections are to velocity rather than position. Passing `velocityLevel = true` to `applyCorrection` switches it into this mode.

**Linear damping** along a given direction removes relative velocity at the attachment points along that direction:

```js
applyLinearDamping(dt) {
    let dVel = this.body0.getVelocityAt(this.globalPos0);
    if (this.body1 != null)
        dVel.sub(this.body1.getVelocityAt(this.globalPos1));
    let n = new THREE.Vector3()
        .subVectors(this.globalPos1, this.globalPos0).normalize();
    n.multiplyScalar(-dVel.dot(n));
    n.multiplyScalar(Math.min(this.linearDampingCoeff * dt, 1.0));
    this.body0.applyCorrection(0.0, n, this.globalPos0, this.body1, this.globalPos1, true);
}
```

The `Math.min(..., 1.0)` clamp is crucial: a value of 1.0 removes the relative velocity entirely (critical damping), and allowing values above 1.0 would reverse the velocity, which is unphysical. This unconditional stability is something traditional solvers struggle to guarantee without careful step-size selection.

**Angular damping** along the hinge axis removes the relative angular velocity component around that axis, leaving motion in other directions unaffected:

```js
applyAngularDamping(dt) {
    let dOmega = this.body0.omega.clone();
    if (this.body1 != null) dOmega.sub(this.body1.omega);
    if (this.type == Joint.TYPES.HINGE) {
        let n = new THREE.Vector3(1.0, 0.0, 0.0).applyQuaternion(this.globalRot0);
        n.multiplyScalar(dOmega.dot(n));
        dOmega.copy(n);
    }
    dOmega.multiplyScalar(-Math.min(this.angularDampingCoeff * dt, 1.0));
    this.body0.applyCorrection(0.0, dOmega, null, this.body1, null, true);
}
```

Applying forces and torques follows the same pattern. A force **f** along axis **a** becomes a linear velocity correction of magnitude `|f| · Δt / (m₁⁻¹ + m₂⁻¹)`, and a torque τ around **a** becomes an angular velocity correction of magnitude `τ · Δt / (n^T I⁻¹ n)`. Dividing by Δt in the correction step rather than multiplying by it in an impulse formulation is a minor but important detail — it ensures that the energy input is independent of the substep size.


## Scene Import from Blender

A car steering linkage or a robot arm is not something you want to specify in code. The simulation reads its scene from a JSON file exported by Blender, where each object has a `simType` property that identifies it as a rigid body or a specific joint type:

```js
if (simType === 'HingeJoint') {
    let swingMin = props.swingMin ?? -Number.MAX_VALUE;
    let swingMax = props.swingMax ?? Number.MAX_VALUE;
    let hasTargetAngle = props.targetAngle !== undefined;
    joint.initHingeJoint(swingMin, swingMax, hasTargetAngle,
                         props.targetAngle ?? 0.0,
                         props.targetAngleCompliance ?? 0.0,
                         props.damping ?? 0.0);
}
```

The joint's world-space position and orientation are read from the Blender object's transform, and `setFrames` converts them to body-relative coordinates. The Blender exporter therefore becomes the authoring interface: an artist or engineer sets up the mechanical structure visually, assigns simulation properties through Blender's custom properties panel, exports JSON, and the simulator picks it up unchanged.

This round-trip is more than a workflow convenience. It separates concerns cleanly: the simulation code knows nothing about the specific geometry of a steering mechanism; it only knows joint types and their parameters. Adding a new vehicle is adding a new JSON file.


## What the Demos Reveal

The demonstration scenes reveal properties of the algorithm that are hard to appreciate from equations alone.

A **triple pendulum** shows numerical damping under control. Position-based dynamics with substepping introduces very little artificial energy loss. The third segment — the lightest and fastest-moving — resolves cleanly even when its period is much shorter than the frame time, because substepping samples the fast motion at the substep rate rather than the frame rate.

A **200:1 mass ratio** test connects a heavy box to light rods through joints. Traditional methods often fail or require special mass-ratio handling in this regime. XPBD handles it because the inverse-mass weighting in both the linear and angular correction routines automatically allocates corrections to the lighter body, which moves easily, rather than fighting against the heavy one.

The **damped hinge** demo illustrates the stability of the clamped damping coefficient. Dragging the damping slider from zero to very large values never destabilizes the simulation. The clamp to [0, 1] on the effective damping fraction ensures that no correction can more than cancel the velocity it targets.


## Key Takeaways

This final chapter closes a long arc. We started with a sphere falling under gravity and colliding with a floor — a few lines of integration and a one-dimensional constraint. We end with articulated rigid body assemblies: cars, robots, pendulums with arbitrary depth, structures with extreme mass ratios.

The journey from chapter one to chapter twenty-five traces a single consistent design philosophy:

- **XPBD as a unifying framework.** Every constraint in this series — distance, volume, contact, and now joint — reduces to the same two operations: compute a scalar violation, compute a generalized inverse mass, apply a scaled correction. The framework works at the position level and the velocity level interchangeably.

- **Substepping over iteration.** Running one constraint pass per small substep consistently outperforms running many passes per large step. The stability radius grows with the number of substeps, not the number of iterations, and the convergence quality is the same.

- **Compliance as a physical quantity.** Setting α = 0 gives a hard constraint. Setting α = 1/k gives a spring of stiffness k. The same solver handles both without branching. This collapses the traditional distinction between rigid joints and soft springs into one continuous parameter.

- **Unconditional stability from clamping.** The single most important numerical trick in the entire series is the `min(..., 1.0)` applied to damping coefficients and the normalization of quaternions after every orientation update. These two operations, costing almost nothing, prevent the runaway energy amplification that plagues force-based methods at large time steps.

- **Separation of mechanism and solver.** Joint types are assemblies of building blocks, not special-case code. Adding a new joint type — a constant-velocity joint, a worm gear, a rack and pinion — requires only identifying which combination of `Attach`, `RestrictToAxis`, `AlignAxes`, and `LimitAngle` expresses the desired degrees of freedom.

The method described here is not a toy. It is the same approach used in real-time physics engines powering games and robotics simulations. The implementation fits in a few hundred lines of readable code with no external dependencies beyond a 3D math library. That is the promise XPBD made in chapter nine, and this chapter delivers on it.
