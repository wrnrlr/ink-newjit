# Chapter 22 — Rigid Body Simulation with Position-Based Dynamics

Simulating rigid bodies is the cornerstone of almost every interactive physics engine. A rigid body is an object that does not deform — every pair of points on the body maintains a fixed distance. This constraint, simple as it sounds, transforms the mathematics substantially. A free particle has three degrees of freedom; a rigid body in three dimensions has six: three translational and three rotational. The rotational degrees of freedom introduce new state variables, new inertia quantities, and new integration equations, and they must be handled with some care if the simulation is to remain stable and physically plausible.

This chapter develops a complete rigid body simulator from first principles using Extended Position-Based Dynamics (XPBD). The approach is deliberately accessible: rotations are represented by quaternions, but you do not need to understand quaternion algebra to follow the derivation. The key insight is that the center of mass of a rigid body behaves exactly like a particle — we already know how to simulate that — and the rotational degrees of freedom can be integrated using a formula that mirrors the translational one almost line-for-line. Connecting two bodies with a distance constraint then follows from a straightforward generalization of the particle distance constraint from Chapter 5.

---

## The State of a Rigid Body

A free particle needs only two quantities to describe its state: position **x** and velocity **v**. A rigid body needs four:

| Translational | Rotational |
|---|---|
| position **x** | orientation quaternion **q** |
| linear velocity **v** | angular velocity **ω** |
| inverse mass $w = 1/m$ | moment of inertia tensor **I** |

The position **x** is the world-space location of the body's center of mass. The orientation **q** is a unit quaternion that encodes how the body has been rotated away from its reference pose. The linear velocity **v** is the velocity of the center of mass. The angular velocity **ω** is a three-dimensional vector whose direction is the current axis of rotation and whose magnitude is the rotation speed in radians per second.

The inverse mass $w = 1/m$ is stored rather than the mass directly, because static (immovable) objects are represented by $w = 0$ — the inverse of infinite mass — without any special-case logic.

Each body defines a *local frame* whose origin is at the center of mass and whose axes are aligned with the body's principal dimensions. A point **a** in the local frame maps to a world-space point **a'** via the rigid transform:

$$\mathbf{a}' = \mathbf{x} + \mathbf{q} \otimes \mathbf{a}$$

where $\otimes$ denotes the quaternion rotation operation (rotating the vector **a** by **q**). The inverse transform is:

$$\mathbf{a} = \mathbf{q}^{-1} \otimes (\mathbf{a}' - \mathbf{x})$$

These two operations — local-to-world and world-to-local — are the only quaternion primitives the rest of the code needs to call. In practice they are one-liners using whichever quaternion library you have at hand.

---

## The Moment of Inertia Tensor

Newton's second law has a rotational analogue. For linear motion:

$$\mathbf{F} = m \mathbf{a}$$

The corresponding law for rotation is:

$$\boldsymbol{\tau} = \mathbf{I} \, \boldsymbol{\alpha}$$

Here $\boldsymbol{\tau}$ is the *torque* — the rotational equivalent of force, computed as $\mathbf{r} \times \mathbf{F}$ where **r** is the vector from the center of mass to the point where **F** is applied — and $\boldsymbol{\alpha}$ is the angular acceleration. The scalar mass $m$ is replaced by the *moment of inertia tensor* **I**, a 3×3 symmetric matrix. Just as a large mass resists linear acceleration, a large moment of inertia resists angular acceleration. But unlike scalar mass, the resistance depends on direction: a cylinder is easy to spin about its long axis and harder to spin about a perpendicular axis.

In a general pose the full 3×3 tensor **I** has off-diagonal terms. If, however, we align the body's local frame with its principal axes — the natural symmetry axes of the shape — the tensor becomes diagonal:

$$\mathbf{I} = \begin{pmatrix} I_x & 0 & 0 \\ 0 & I_y & 0 \\ 0 & 0 & I_z \end{pmatrix}$$

This diagonal form can be stored as a plain three-vector $(I_x, I_y, I_z)$, which is what the code does. The principal moments for common shapes are tabulated on any physics reference sheet; here are the two shapes used in the demo:

**Solid box** with half-dimensions $(a, b, c)$ and mass $m$:

$$I_x = \tfrac{1}{12} m (b^2 + c^2), \quad I_y = \tfrac{1}{12} m (a^2 + c^2), \quad I_z = \tfrac{1}{12} m (a^2 + b^2)$$

**Solid sphere** of radius $r$ and mass $m$:

$$I_x = I_y = I_z = \tfrac{2}{5} m r^2$$

In the code both `invMass` and `invInertia` store the *inverses* of these quantities for the same reason as before: a zero inverse denotes an infinite (immovable) quantity.

```javascript
if (type == "box") {
    mass = density * size.x * size.y * size.z;
    this.invMass = 1.0 / mass;
    let Ix = 1.0/12.0 * mass * (size.y*size.y + size.z*size.z);
    let Iy = 1.0/12.0 * mass * (size.x*size.x + size.z*size.z);
    let Iz = 1.0/12.0 * mass * (size.x*size.x + size.y*size.y);
    this.invInertia.set(1.0/Ix, 1.0/Iy, 1.0/Iz);
}
else if (type == "sphere") {
    mass = 4.0/3.0 * Math.PI * size.x*size.x*size.x * density;
    this.invMass = 1.0 / mass;
    let I = 2.0/5.0 * mass * size.x*size.x;
    this.invInertia.set(1.0/I, 1.0/I, 1.0/I);
}
```

---

## Integrating Orientation

The integration loop for a rigid body mirrors the particle loop. For the translational part nothing changes at all — the center of mass is a particle:

$$\mathbf{v} \leftarrow \mathbf{v} + \mathbf{g} \, h, \qquad \mathbf{x} \leftarrow \mathbf{x} + \mathbf{v} \, h$$

where $h$ is the substep size. The rotational part requires one additional idea: how to advance a quaternion given an angular velocity.

If the body is rotating at angular velocity **ω**, then after a small time $h$ the orientation changes by a rotation of angle $|\boldsymbol{\omega}| h$ about the axis $\hat{\boldsymbol{\omega}}$. For small $h$ this can be approximated by the quaternion derivative formula:

$$\mathbf{q} \leftarrow \mathbf{q} + \tfrac{1}{2} h \, [\omega_x, \omega_y, \omega_z, 0] \cdot \mathbf{q}$$

followed by normalization. The term $[\omega_x, \omega_y, \omega_z, 0]$ is a pure quaternion formed from **ω** with $w = 0$, and the product is ordinary quaternion multiplication. This is the quaternion equivalent of $\mathbf{x} \leftarrow \mathbf{x} + \mathbf{v} h$.

The complete integration step is:

```javascript
integrate(dt, gravity) {
    if (this.invMass == 0.0) return;

    // translational
    this.prevPos.copy(this.pos);
    this.vel.addScaledVector(gravity, dt);
    this.pos.addScaledVector(this.vel, dt);

    // rotational
    this.prevRot.copy(this.rot);
    this.dRot.set(this.omega.x, this.omega.y, this.omega.z, 0.0);
    this.dRot.multiply(this.rot);
    this.rot.x += 0.5 * dt * this.dRot.x;
    this.rot.y += 0.5 * dt * this.dRot.y;
    this.rot.z += 0.5 * dt * this.dRot.z;
    this.rot.w += 0.5 * dt * this.dRot.w;
    this.rot.normalize();
    this.invRot.copy(this.rot);
    this.invRot.invert();
}
```

The current orientation and its inverse are both maintained; the inverse is needed for the world-to-local transform. Note that the check `invMass == 0.0` skips integration entirely for static bodies, which is both efficient and correct.

---

## Updating Velocities After the Solve

After the constraint solver has moved the bodies, we recompute both velocities from the actual position and orientation changes, just as PBD does for particles. The translational update is identical to the particle case:

$$\mathbf{v} \leftarrow \frac{\mathbf{x} - \mathbf{x}_{\text{prev}}}{h}$$

For the angular velocity we compute the quaternion that rotates from the pre-solve orientation $\mathbf{q}_{\text{prev}}$ to the post-solve orientation **q**:

$$\Delta\mathbf{q} = \mathbf{q} \cdot \mathbf{q}_{\text{prev}}^{-1}$$

The angular velocity is then extracted from the vector part of $\Delta\mathbf{q}$:

$$\boldsymbol{\omega} = \frac{2}{h} \begin{pmatrix} \Delta q_x \\ \Delta q_y \\ \Delta q_z \end{pmatrix}$$

One subtlety: quaternions represent rotations with a sign ambiguity — $\mathbf{q}$ and $-\mathbf{q}$ encode the same rotation. If the scalar part $\Delta q_w$ is negative, the vector part has the wrong sign and must be negated.

```javascript
updateVelocities() {
    if (this.invMass == 0.0) return;

    // translational
    this.vel.subVectors(this.pos, this.prevPos);
    this.vel.multiplyScalar(1.0 / this.dt);

    // rotational
    this.prevRot.invert();
    this.dRot.multiplyQuaternions(this.rot, this.prevRot);
    this.omega.set(
        this.dRot.x * 2.0 / this.dt,
        this.dRot.y * 2.0 / this.dt,
        this.dRot.z * 2.0 / this.dt
    );
    if (this.dRot.w < 0.0)
        this.omega.negate();
}
```

---

## XPBD Constraint Solver for Rigid Bodies

The particle distance constraint from Chapter 5 computes a correction vector and splits it between two particles proportional to their inverse masses. Extending this to rigid bodies requires two additional steps: computing a *generalized inverse mass* that accounts for rotational resistance, and applying an orientation correction alongside the position correction.

### Generalized Inverse Mass

When a constraint pulls on a point **p** of body $i$ with force along direction **n**, the body responds both by translating (resisted by $m_i^{-1}$) and by rotating (resisted by **I**$_i^{-1}$). The combined resistance is the *generalized inverse mass*:

$$w_i = m_i^{-1} + (\mathbf{r}_i \times \mathbf{n})^\mathsf{T} \, \mathbf{I}_i^{-1} \, (\mathbf{r}_i \times \mathbf{n})$$

where $\mathbf{r}_i = \mathbf{p}_i - \mathbf{x}_i$ is the vector from the center of mass to the attachment point. The cross product $\mathbf{r}_i \times \mathbf{n}$ is the angular impulse direction; projecting it through the inverse inertia tensor gives the angular compliance. Because we store the inertia tensor in the body's local frame, this computation must be carried out there: rotate $\mathbf{r}_i \times \mathbf{n}$ into local space, multiply component-wise by `invInertia`, and the dot product with itself gives the scalar term.

```javascript
getInverseMass(normal, pos) {
    if (this.invMass == 0.0) return 0.0;

    let rn = normal.clone();
    rn.subVectors(pos, this.pos);   // r = p - x
    rn.cross(normal);               // r × n
    rn.applyQuaternion(this.invRot); // into local frame

    let w = rn.x*rn.x * this.invInertia.x
          + rn.y*rn.y * this.invInertia.y
          + rn.z*rn.z * this.invInertia.z;

    return w + this.invMass;
}
```

### The XPBD Update

Given a scalar constraint violation $C$, a constraint direction **n**, and the total generalized inverse mass $w = w_1 + w_2$, the XPBD Lagrange multiplier is:

$$\lambda = -\frac{C}{w + \tilde{\alpha}}$$

where $\tilde{\alpha} = \alpha / h^2$ is the compliance $\alpha$ scaled by the squared substep size. Setting $\alpha = 0$ recovers rigid (infinite stiffness) constraints; larger $\alpha$ yields softer springs with a physically meaningful stiffness of $1/\alpha$.

The position correction applied to body $i$ is:

$$\mathbf{x}_i \leftarrow \mathbf{x}_i \pm \lambda w_i \mathbf{n}$$

The sign is positive for body 1 and negative for body 2 (or vice versa depending on sign convention). The orientation correction is:

$$\mathbf{q}_i \leftarrow \mathbf{q}_i + \tfrac{1}{2} \lambda \, [\mathbf{I}_i^{-1}(\mathbf{r}_i \times \mathbf{n}), \, 0] \cdot \mathbf{q}_i$$

again followed by normalization. The angular correction vector $\mathbf{I}_i^{-1}(\mathbf{r}_i \times \mathbf{n})$ must be rotated back to world space before the quaternion product is formed.

```javascript
_applyCorrection(corr, pos) {
    if (this.invMass == 0.0) return;

    // position correction
    this.pos.addScaledVector(corr, this.invMass);

    // orientation correction
    let dOmega = new THREE.Vector3();
    dOmega.subVectors(pos, this.pos);
    dOmega.cross(corr);
    dOmega.applyQuaternion(this.invRot);     // into local frame
    dOmega.multiply(this.invInertia);         // I⁻¹ (r × corr)
    dOmega.applyQuaternion(this.rot);         // back to world frame

    this.dRot.set(dOmega.x, dOmega.y, dOmega.z, 0.0);
    this.dRot.multiply(this.rot);
    this.rot.x += 0.5 * this.dRot.x;
    this.rot.y += 0.5 * this.dRot.y;
    this.rot.z += 0.5 * this.dRot.z;
    this.rot.w += 0.5 * this.dRot.w;
    this.rot.normalize();
    this.invRot.copy(this.rot);
    this.invRot.invert();
}
```

### Applying a Full Distance Constraint

The `applyCorrection` method on the body orchestrates the whole XPBD calculation and delegates to `_applyCorrection` for each body:

```javascript
applyCorrection(compliance, corr, pos, otherBody, otherPos) {
    let C = corr.length();
    if (C == 0.0) return;
    let normal = corr.clone().normalize();

    let w = this.getInverseMass(normal, pos);
    if (otherBody != undefined)
        w += otherBody.getInverseMass(normal, otherPos);
    if (w == 0.0) return;

    let alpha  = compliance / this.dt / this.dt;
    let lambda = -C / (w + alpha);
    normal.multiplyScalar(-lambda);

    this._applyCorrection(normal, pos);
    if (otherBody != undefined) {
        normal.multiplyScalar(-1.0);
        otherBody._applyCorrection(normal, otherPos);
    }
    return lambda / this.dt / this.dt;  // constraint force magnitude
}
```

The return value $\lambda / h^2$ is the constraint force magnitude — exactly analogous to the $\lambda / \Delta t^2$ formula from Chapter 5. This allows the simulation to annotate each constraint with its current tension, which the demo renders as a floating label next to each link in the chain scene.

---

## The Distance Constraint Between Bodies

The `DistanceConstraint` class wraps the above machinery into a reusable constraint that keeps two attachment points a fixed distance apart. Each attachment point is stored in the *local frame* of its body; at solve time the points are rotated into world space using the bodies' current orientations.

```javascript
solve() {
    this.body0.localToWorld(this.localPos0, this.worldPos0);
    if (this.body1 != undefined)
        this.body1.localToWorld(this.localPos1, this.worldPos1);

    this.corr.subVectors(this.worldPos1, this.worldPos0);
    let distance = this.corr.length();
    this.corr.normalize();
    if (this.unilateral && distance < this.distance)
        return;
    this.corr.multiplyScalar(distance - this.distance);

    this.body0.applyCorrection(
        this.compliance, this.corr, this.worldPos0,
        this.body1,      this.worldPos1
    );
}
```

The `unilateral` flag makes the constraint one-sided: active only when the distance exceeds the rest length. This is used for the crib-mobile demo, where the strings can go slack but cannot push.

---

## The Simulation Loop

The full simulator follows the same substep structure as the particle PBD from Chapter 5. A `numSubSteps` of 10 is typical; each substep runs integrate, solve all constraints, update velocities in that order.

```javascript
simulate() {
    let sdt = this.dt / this.numSubSteps;

    for (let sub = 0; sub < this.numSubSteps; sub++) {
        for (let body of this.rigidBodies)
            body.integrate(sdt, this.gravity);

        for (let c of this.distanceConstraints)
            c.solve();
        if (this.dragConstraint)
            this.dragConstraint.solve();

        for (let body of this.rigidBodies)
            body.updateVelocities(sdt);
    }

    for (let body of this.rigidBodies)
        body.updateMeshes();
}
```

The mesh update is done once per display frame after all substeps complete, not once per substep. This keeps the rendering cost constant regardless of how many substeps are used.

---

## Mouse Interaction via a Dynamic Constraint

Mouse dragging is implemented with the same distance-constraint machinery, just with one endpoint fixed to the mouse cursor rather than to another body.

On mouse-down the code casts a ray into the scene. When it hits a body, it records the intersection point **p** in the body's local frame as **r**, and the ray distance $d$. A zero-rest-length distance constraint is created between the body's attachment point and a world-space "anchor" at the intersection.

On mouse-move the anchor is updated by advancing along the camera ray to depth $d$:

$$\mathbf{p}_{\text{anchor}} = \mathbf{o}_{\text{ray}} + d \, \hat{\mathbf{d}}_{\text{ray}}$$

The constraint solver pulls the body's attachment point toward the anchor each substep. Since the rest length is zero, the body tends to follow the mouse cursor, with a softness controlled by `dragCompliance`. On mouse-up the constraint is simply removed.

This is a nice illustration of a general principle: constraints are not just physical joints. Any desired relationship between objects or between an object and an external reference point can be expressed as a constraint and plugged directly into the XPBD loop with no changes to the surrounding machinery.

---

## Key Takeaways

- **Rigid body state pairs translational and rotational quantities.** Position pairs with orientation (quaternion), linear velocity with angular velocity, inverse mass with inverse inertia tensor. The code for each pair is structurally parallel.

- **The quaternion integration formula mirrors the Euler step.** Advancing **q** by $\frac{1}{2} h [\boldsymbol{\omega}, 0] \cdot \mathbf{q}$ (followed by normalization) is the rotational analogue of advancing **x** by $\mathbf{v} h$. No special quaternion theory is required.

- **Velocities are always recomputed from displacements, never propagated.** After constraints move the bodies, both **v** and **ω** are derived from $(\mathbf{x} - \mathbf{x}_{\text{prev}}) / h$ and from $\Delta\mathbf{q}$. This is the PBD principle applied to both translational and rotational degrees of freedom.

- **Generalized inverse mass unifies translation and rotation in one scalar.** The expression $w_i = m_i^{-1} + (\mathbf{r}_i \times \mathbf{n})^\mathsf{T} \mathbf{I}_i^{-1} (\mathbf{r}_i \times \mathbf{n})$ captures both the linear and angular response to a constraint impulse in a single number. It makes the XPBD multiplier formula identical to the particle case.

- **Inertia tensor computations live in local space.** The diagonal principal-axis tensor avoids full matrix algebra. Any expression involving **I**$^{-1}$ first rotates its argument into local space, multiplies component-wise, then rotates back.

- **XPBD compliance gives physical stiffness with time-step independence.** Setting compliance $\alpha$ to zero gives a rigid constraint; larger $\alpha$ yields a spring of stiffness $1/\alpha$, and the behavior does not change as the substep size changes. This is the key difference from the unscaled position correction of plain PBD.

- **The same machinery handles joints, soft connections, and mouse interaction.** Any constraint between two points on two bodies — or between a body point and a world-space anchor — slots into the same `applyCorrection` interface. The distance constraint shown here is the simplest example; the chapters that follow extend it to angular constraints, contact constraints, and articulated joints.
