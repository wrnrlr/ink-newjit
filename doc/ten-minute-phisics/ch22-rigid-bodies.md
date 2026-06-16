# Chapter 22 — Rigid Body Simulation with Position-Based Dynamics

Simulating rigid bodies is the cornerstone of almost every interactive physics engine. A rigid body is an object that does not deform — every pair of points maintains a fixed distance. This constraint transforms the mathematics substantially. A free particle has three degrees of freedom; a rigid body in 3D has six: three translational and three rotational.

This chapter develops a complete rigid body simulator using Extended Position-Based Dynamics (XPBD). Rotations are represented by quaternions (from Chapter 7). The key insight: the center of mass behaves exactly like a particle; the rotational degrees of freedom can be integrated using a formula that mirrors the translational one almost line-for-line.

---

## The State of a Rigid Body

A free particle needs position and velocity. A rigid body needs four quantities:

| Translational | Rotational |
|---|---|
| position **x** | orientation quaternion **q** |
| linear velocity **v** | angular velocity **ω** |
| inverse mass $w = 1/m$ | inverse inertia tensor **I**⁻¹ |

The position **x** is the world-space location of the center of mass. The orientation **q** is a unit quaternion encoding how the body has been rotated from its reference pose. The angular velocity **ω** is a 3-vector: direction is the axis of rotation, magnitude is the angular speed in radians/second.

Inverse mass and inverse inertia are stored (not mass/inertia directly) so that static bodies are represented by $w = 0$ — infinite mass — without special-case logic.

A point **a** in local frame maps to world space:

$$\mathbf{a}' = \mathbf{x} + \mathbf{q} \otimes \mathbf{a}$$

In ink, using `qrotate` from Chapter 7:

```k
/ Rigid body state layout: (pos; vel; rot; omega; invM; invI; prevPos; prevRot)
/ pos, vel, prevPos: 3-vectors; rot, prevRot: quaternion (x;y;z;w)
/ omega: 3-vector (angular velocity); invM: scalar; invI: 3-vector (diagonal inertia)

/ Local to world: apply rotation then add position
localToWorld: {[body;a] (body@0) + qrotate[body@2; a]}

/ World to local: subtract position then inverse-rotate
worldToLocal: {[body;aw] qrotate[qconj body@2; aw - body@0]}
```

---

## Moment of Inertia Tensor

Newton's second law has a rotational analogue: $\boldsymbol{\tau} = \mathbf{I}\, \boldsymbol{\alpha}$. The scalar mass $m$ is replaced by the **moment of inertia tensor** **I**, a 3×3 symmetric matrix. Aligning the body's local frame with its principal axes makes **I** diagonal — three numbers $(I_x, I_y, I_z)$.

Principal moments for common shapes:

**Solid box** with half-dimensions $(a, b, c)$ and mass $m$:
$$I_x = \tfrac{1}{12}m(b^2+c^2), \quad I_y = \tfrac{1}{12}m(a^2+c^2), \quad I_z = \tfrac{1}{12}m(a^2+b^2)$$

**Solid sphere** of radius $r$ and mass $m$: $I_x = I_y = I_z = \tfrac{2}{5}mr^2$

```k
/ Compute inverse inertia for a box with half-extents (a;b;c) and mass m
boxInvI: {[a;b;c;m]
  (12.%(m*(b*b+c*c)); 12.%(m*(a*a+c*c)); 12.%(m*(a*a+b*b)))
}

/ Compute inverse inertia for a sphere of radius r and mass m
sphereInvI: {[r;m] 5.%(2.*m*r*r) * 1. 1. 1.}

/ Build a rigid body: type=0 box, type=1 sphere; size=(a;b;c) or (r;0;0)
mkBody: {[type;size;density;pos;vel;rot;omega]
  $[type=0;
    [a:size@0; b:size@1; c:size@2
     m: density*2.*a * 2.*b * 2.*c
     invM: 1.%m
     invI: boxInvI[a;b;c;m]];
    / sphere
    [r: size@0
     m: (4.%3.) * 3.14159 * r*r*r * density
     invM: 1.%m
     invI: sphereInvI[r;m]]]
  (pos; vel; rot; omega; invM; invI; pos; rot)   / prevPos=pos, prevRot=rot
}
```

---

## Integrating Orientation

The translational part of integration is unchanged — the center of mass is a particle:

$$\mathbf{v} \leftarrow \mathbf{v} + \mathbf{g} h, \qquad \mathbf{x} \leftarrow \mathbf{x} + \mathbf{v} h$$

For the rotational part: a body rotating at angular velocity **ω** advances by:

$$\mathbf{q} \leftarrow \mathbf{q} + \tfrac{1}{2} h \, [\omega_x, \omega_y, \omega_z, 0] \cdot \mathbf{q}$$

followed by normalization. The term $[\boldsymbol{\omega}, 0]$ is a pure quaternion formed from **ω** with $w = 0$.

```k
/ Quaternion operations from ch07
qnorm: {x % sqrt +/ x*x}    / normalize
grav: 0. -9.81 0.

/ Integrate rigid body for one substep
rbIntegrate: {[body;sdt]
  pos:body@0; vel:body@1; rot:body@2; omega:body@3; invM:body@4
  $[invM=0.; body;   / static body
    [/ Save prev state
     prevPos: pos; prevRot: rot
     / Translational
     vel2: vel + grav*sdt
     pos2: pos + vel2*sdt
     / Rotational: q += 0.5*sdt * [omega,0] * q
     dq: qmul[(omega,0.); rot]    / pure quat [omega;0] multiplied by rot
     rot2: qnorm rot + 0.5*sdt*dq
     @[@[@[@[@[@[@[body;0;:;pos2];1;:;vel2];2;:;rot2];6;:;prevPos];7;:;prevRot]]]]
}
```

---

## Updating Velocities After the Solve

After constraints have moved the bodies, recompute velocities from actual displacements:

$$\mathbf{v} \leftarrow \frac{\mathbf{x} - \mathbf{x}_{\text{prev}}}{h}$$

For angular velocity: compute the rotation delta $\Delta\mathbf{q} = \mathbf{q} \cdot \mathbf{q}_{\text{prev}}^{-1}$, then extract $\boldsymbol{\omega}$:

$$\boldsymbol{\omega} = \frac{2}{h} (\Delta q_x, \Delta q_y, \Delta q_z), \quad \text{negate if } \Delta q_w < 0$$

```k
/ Update velocities from position/orientation change after solve
rbUpdateVel: {[body;sdt]
  pos:body@0; vel:body@1; rot:body@2; omega:body@3; invM:body@4
  prevPos:body@6; prevRot:body@7
  $[invM=0.; body;
    [vel2: (pos - prevPos) % sdt
     dq: qmul[rot; qconj prevRot]
     omega2: (2.%sdt) * 3#dq
     omega3: $[(dq@3)<0.; neg omega2; omega2]
     @[@[body;1;:;vel2];3;:;omega3]]]
}
```

---

## XPBD Constraint Solver for Rigid Bodies

### Generalized Inverse Mass

When a constraint pulls on a point **p** of body $i$ with force along direction **n**, the body responds both by translating (resisted by $m_i^{-1}$) and by rotating (resisted by **I**$_i^{-1}$):

$$w_i = m_i^{-1} + (\mathbf{r}_i \times \mathbf{n})^\mathsf{T} \mathbf{I}_i^{-1} (\mathbf{r}_i \times \mathbf{n})$$

where $\mathbf{r}_i = \mathbf{p}_i - \mathbf{x}_i$ is the vector from the center of mass to the attachment point. The inverse inertia **I**$_i^{-1}$ is diagonal (stored in local frame), so the computation requires rotating $\mathbf{r}_i \times \mathbf{n}$ to local frame first:

```k
/ Generalized inverse mass for body at attachment point worldPos in direction n
rbInvMass: {[body;n;worldPos]
  pos:body@0; rot:body@2; invM:body@4; invI:body@5
  $[invM=0.; 0.;
    [r: worldPos - pos
     rn: cross3[r;n]                   / r × n
     rnLocal: qrotate[qconj rot; rn]   / into local frame
     angTerm: +/ invI * rnLocal*rnLocal    / dot(rnLocal, I⁻¹ * rnLocal)
     invM + angTerm]]
}
```

### Applying the XPBD Correction

Given constraint violation $C$, direction **n**, and total generalized inverse mass $w$:

$$\lambda = -\frac{C}{w + \alpha/h^2}$$

Position correction for body $i$:

$$\mathbf{x}_i \leftarrow \mathbf{x}_i \pm \lambda w_i \mathbf{n}$$

Orientation correction:

$$\mathbf{q}_i \leftarrow \mathbf{q}_i + \tfrac{1}{2}\lambda \left[\mathbf{I}_i^{-1}(\mathbf{r}_i \times \mathbf{n}), 0\right] \cdot \mathbf{q}_i$$

```k
/ Apply position and orientation correction to one body
rbApplyCorr: {[body;corr;worldPos]
  pos:body@0; rot:body@2; invM:body@4; invI:body@5
  $[invM=0.; body;
    [/ Position correction
     pos2: pos + corr*invM
     / Orientation correction
     r: worldPos - pos
     dOmega: cross3[r;corr]               / r × corr
     dOmegaLocal: qrotate[qconj rot; dOmega]   / into local frame
     dOmegaScaled: invI * dOmegaLocal         / I⁻¹ * dOmega
     dOmegaWorld: qrotate[rot; dOmegaScaled]  / back to world frame
     dq: qmul[(dOmegaWorld,0.); rot]
     rot2: qnorm rot + 0.5*dq
     @[@[body;0;:;pos2];2;:;rot2]]]
}

/ Full XPBD correction: compute lambda, apply to both bodies
/ alpha: compliance; sdt: substep size; C: constraint violation (scalar)
/ n: constraint direction (unit vector); p0,p1: attachment world positions
rbSolveConstraint: {[b0;b1;alpha;sdt;C;n;p0;p1]
  w0: rbInvMass[b0;n;p0]
  w1: rbInvMass[b1;n;p1]
  wt: w0+w1
  $[wt=0.; (b0;b1);
    [alph: alpha%sdt*sdt
     lam: (neg C) % wt+alph
     corr: n*lam
     b02: rbApplyCorr[b0; corr; p0]
     b12: rbApplyCorr[b1; neg corr; p1]
     (b02; b12)]]
}
```

---

## Distance Constraint Between Bodies

The most fundamental constraint keeps two attachment points a fixed distance apart. Attachment points are stored in local frames; at solve time they are rotated to world space:

```k
/ Rigid body distance constraint
/ bodies: list of body tuples; i,j: body indices
/ localA: attachment in body i's local frame; localB: attachment in body j's local frame
/ restLen: rest distance; alpha: compliance; unilateral: only active when d > restLen
rbDistConstraint: {[bodies;sdt;i;j;localA;localB;restLen;alpha;unilateral]
  b0: bodies@i; b1: bodies@j
  / Transform attachment points to world space
  p0: localToWorld[b0;localA]
  p1: localToWorld[b1;localB]
  / Compute constraint
  dx: p1 - p0; d: vlen dx
  $[d=0.; bodies;
    [C: d - restLen
     $[unilateral & C<0.; bodies;
       [n: dx%d
        res: rbSolveConstraint[b0;b1;alpha;sdt;C;n;p0;p1]
        @[@[bodies;i;:;res@0];j;:;res@1]]]]]
}
```

---

## The Full Simulation Loop

```k
/ Rigid body simulation: one frame = numSubsteps substeps
rbSimFrame: {[bodies;constraints;sdt;numSubsteps]
  {[sub]
    / Integrate all bodies
    bodies:: rbIntegrate[;sdt]' bodies

    / Solve all constraints
    {[c]
      / c: (i; j; localA; localB; restLen; alpha; unilateral)
      bodies:: rbDistConstraint[bodies;sdt;c@0;c@1;c@2;c@3;c@4;c@5;c@6]
    }' constraints

    / Update velocities from displacements
    bodies:: rbUpdateVel[;sdt]' bodies
  }' !numSubsteps
  bodies
}
```

---

## Example: Chain of Linked Bodies

```k
/ Build a chain of N boxes linked by distance constraints
/ Each link is a box hanging from the previous
buildChain: {[n;boxH;density;dt]
  / Create n bodies hanging vertically
  bods: {[i]
    pos: 0. (neg i*boxH*2.) 0.
    mkBody[0; (0.1;boxH;0.1); density; pos; 0. 0. 0.; 0. 0. 0. 1.; 0. 0. 0.]
  }' !n
  / First body is static (invM=0)
  bods2: @[bods; 0; ; @[bods@0; 4; :; 0.]]

  / Create constraints: each link connects bottom of one box to top of next
  consts: {[i]
    (i; i+1;                   / body indices
     0. (neg boxH) 0.;         / bottom of body i (local)
     0. boxH 0.;               / top of body i+1 (local)
     0.;                       / rest distance = 0 (touching)
     0.;                       / hard constraint
     0)                        / bilateral
  }' !n-1

  (bods2; consts)
}

/ Run chain simulation
chain: buildChain[5; 0.15; 1000.; 1.%60]
bodies: chain@0; constraints: chain@1
bodies2: rbSimFrame[bodies;constraints;1.%(60*10);10]
```

---

## Key Takeaways

- **Rigid body state pairs translational and rotational quantities.** Position pairs with orientation quaternion, linear velocity with angular velocity, inverse mass with diagonal inverse inertia. Each pair is structurally parallel.
- **Quaternion integration mirrors the Euler step.** Advancing **q** by $\frac{1}{2}h[\boldsymbol{\omega},0]\cdot\mathbf{q}$ followed by normalization is the rotational analogue of advancing **x** by $\mathbf{v}h$.
- **Velocities are always recomputed from displacements.** After constraints move bodies, both **v** and **ω** are derived from position/orientation change divided by $h$.
- **Generalized inverse mass** unifies translation and rotation in one scalar: $w_i = m_i^{-1} + (\mathbf{r}_i \times \mathbf{n})^\mathsf{T}\mathbf{I}_i^{-1}(\mathbf{r}_i \times \mathbf{n})$. The XPBD multiplier formula is identical to the particle case.
- **Inertia tensor computations live in local space.** The diagonal principal-axis tensor avoids full matrix algebra: rotate into local space, multiply element-wise by `invI`, rotate back.
- **XPBD compliance** $\alpha$ gives physical stiffness with time-step independence. Zero compliance gives a rigid constraint; larger $\alpha$ gives a spring of stiffness $1/\alpha$.
- **The same machinery handles joints, soft connections, and mouse interaction.** Any constraint between two points on two bodies slots into `rbSolveConstraint`. The distance constraint shown here is the simplest example; angular constraints and contact constraints follow the same pattern.
