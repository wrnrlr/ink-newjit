# Chapter 25 — Joint Constraints for Rigid Bodies

The rigid bodies from Chapter 22 live in a world of collisions and free-fall, each body sovereign. Real mechanisms are different. A door is a rigid body shaped by a hinge that permits rotation around one axis and nothing else. A piston can only translate along its bore. Skeleton bones are linked at joints that admit some rotations and forbid others.

This chapter adds that structure. Every joint type — hinge, ball-and-socket, prismatic, cylinder — reduces to two primitive operations: a linear correction (pull attachment points together) and an angular correction (rotate axes into alignment). The XPBD framework from Chapter 22 carries over unchanged.

---

## Attachment Frames

Before applying any constraint, we need to know where and in what orientation a joint connects to each body. Store this as an **attachment frame**: a local position and three local axes, all expressed in the body's own coordinate system. When the joint is created, transform the world-space setup point and axes into each body's local frame:

```k
/ Attachment frame: (localPos; axisA; axisB; axisC) — all in body local frame

/ Create attachment frame from world-space position and axes
mkFrame: {[body;wPos;wA;wB;wC]
  qc: qconj body@2
  (qrotate[qc; wPos - body@0];
   qrotate[qc; wA];
   qrotate[qc; wB];
   qrotate[qc; wC])
}

/ Transform attachment frame to world space
frameToWorld: {[body;frame]
  rot: body@2; pos: body@0
  (pos + qrotate[rot; frame@0];
   qrotate[rot; frame@1];
   qrotate[rot; frame@2];
   qrotate[rot; frame@3])
}
```

The local frame is set once at joint creation. As the body moves and rotates, `frameToWorld` recovers the current world-space geometry without any additional storage.

---

## Two Primitive Operations

### Linear Correction

Pull two world-space attachment points together. For each axis direction `n`, the scalar violation is `C = dot(p1-p0, n)` and the XPBD correction follows as in Chapter 22:

```k
/ Pull attachment point p0 (on b0) toward p1 (on b1)
/ alpha: compliance; sdt: substep size
applyLinearCorr: {[b0;b1;alpha;sdt;p0;p1]
  C: p1 - p0
  / Solve each component independently
  {[res;n]
    bb0:res@0; bb1:res@1
    c: +/ n*C
    $[abs(c)<1e-10; res;
      rbSolveConstraint[bb0;bb1;alpha;sdt;c;n;p0;p1]]
  }/ ((b0;b1)), (1. 0. 0.; 0. 1. 0.; 0. 0. 1.)
}
```

### Angular Correction

Rotate two bodies so that a vector `a0` (on body 0) aligns with a vector `a1` (on body 1). The misalignment axis is `cross3[a0;a1]`; its magnitude is `sin(θ) ≈ θ` for small angles. Substepping keeps angles small enough that the approximation is accurate.

```k
/ Rotate b0 and b1 so that world-space vector a0 aligns with a1
applyAngularCorr: {[b0;b1;alpha;sdt;a0;a1]
  n: cross3[a0;a1]   / misalignment axis, magnitude ≈ sin(angle)
  C: neg vlen n
  $[abs(C)<1e-10; (b0;b1);
    [n2: n % ((vlen n)|1e-10)
     rbSolveAngular[b0;b1;alpha;sdt;C;n2]]]
}

/ Angular-only XPBD: no attachment point, pure torque
rbSolveAngular: {[b0;b1;alpha;sdt;C;n]
  w0: rbInvMassAngular[b0;n]
  w1: rbInvMassAngular[b1;n]
  wt: w0+w1
  $[wt=0.; (b0;b1);
    [lam: (neg C) % wt+alpha%sdt*sdt
     b02: rbApplyAngularCorr[b0; n*lam]
     b12: rbApplyAngularCorr[b1; neg n*lam]
     (b02;b12)]]
}

/ Angular generalized inverse mass: n^T I^{-1} n
rbInvMassAngular: {[body;n]
  rot:body@2; invM:body@4; invI:body@5
  $[invM=0.; 0.;
    [nL: qrotate[qconj rot; n]
     +/ invI*nL*nL]]
}

/ Apply pure rotation correction (no position shift)
rbApplyAngularCorr: {[body;corr]
  rot:body@2; invM:body@4; invI:body@5
  $[invM=0.; body;
    [dOmL: invI * qrotate[qconj rot; corr]
     dOmW: qrotate[rot; dOmL]
     dq: qmul[(dOmW,0.); rot]
     rot2: qnorm rot + 0.5*dq
     @[body;2;:;rot2]]]
}
```

---

## Four Building Blocks

| Building block | Removes | Primitive |
|---|---|---|
| Attach | 3 translation DOF | Linear |
| RestrictToAxis | 2 translation DOF | Linear (perp components) |
| AlignAxes | 2 angular DOF | Angular (cross of a-axes) |
| LimitAngle | 1 angular DOF (one-sided) | Angular |

### Attach

```k
/ Pull attachment points to coincide
constraintAttach: {[b0;b1;f0;f1;alpha;sdt]
  p0: (frameToWorld[b0;f0])@0
  p1: (frameToWorld[b1;f1])@0
  applyLinearCorr[b0;b1;alpha;sdt;p0;p1]
}
```

### AlignAxes (hinge: lock 2 angular DOF)

Aligning one axis pair constrains 2 angular DOF (the perpendicular pair follows automatically). This is the rotation lock for a hinge.

```k
/ Align b-axes of f0 and f1 (constrains 2 angular DOF)
constraintAlignB: {[b0;b1;f0;f1;alpha;sdt]
  fw0: frameToWorld[b0;f0]; fw1: frameToWorld[b1;f1]
  applyAngularCorr[b0;b1;alpha;sdt; fw0@2; fw1@2]
}

/ Align a-axes (locks torsion around b-axis — 1 more angular DOF)
constraintAlignA: {[b0;b1;f0;f1;alpha;sdt]
  fw0: frameToWorld[b0;f0]; fw1: frameToWorld[b1;f1]
  applyAngularCorr[b0;b1;alpha;sdt; fw0@1; fw1@1]
}
```

### LimitAngle

Compute the signed angle between `a` and `b` around axis `n`. If out of bounds, correct back to the nearest limit.

```k
/ Signed angle from a to b around axis n, full range [-pi, pi]
getAngle: {[n;a;b]
  cr: cross3[a;b]
  s: vlen cr; c: +/ a*b
  / atan2(sin, cos)
  theta: atan s % (c|1e-15)   / careful: atan(s/c), not full atan2
  / Adjust for quadrant
  theta2: $[c<0.; $[s>=0.; 3.14159-theta; neg 3.14159-theta]; theta]
  / Sign from cross product direction vs axis
  $[(+/ cr*n)<0.; neg theta2; theta2]
}

/ Rotate vector v by angle theta around unit axis ax (Rodrigues)
rotAroundAxis: {[v;ax;theta]
  ct:cos theta; st:sin theta
  ((v*ct) + (cross3[ax;v]*st)) + ax*(+/ax*v)*(1.-ct)
}

/ Constrain angle between a-axes (of f0, f1) around b-axis (of f0) to [minA, maxA]
constraintLimitAngle: {[b0;b1;f0;f1;minA;maxA;alpha;sdt]
  fw0: frameToWorld[b0;f0]; fw1: frameToWorld[b1;f1]
  n: fw0@2          / hinge axis = b-axis of frame 0
  a0: fw0@1; a1: fw1@1
  phi: getAngle[n;a0;a1]
  $[phi>=minA & phi<=maxA; (b0;b1);
    [phi2: minA|phi&maxA           / clamp to limits
     a0t: rotAroundAxis[a0;n;phi2]  / target direction for a1
     applyAngularCorr[b0;b1;alpha;sdt;a0t;a1]]]
}
```

---

## Joint Types

### Ball-and-Socket

Attachment point fixed; all rotations free.

```k
ballSocketJoint: {[b0;b1;f0;f1;alpha;sdt]
  constraintAttach[b0;b1;f0;f1;alpha;sdt]
}
```

### Hinge Joint

Fixed point + rotation locked to one axis + optional angle limits.

```k
hingeJoint: {[b0;b1;f0;f1;minA;maxA;alpha;sdt]
  / Attach
  res: constraintAttach[b0;b1;f0;f1;alpha;sdt]
  b0:res@0; b1:res@1
  / Lock 2 angular DOF (align b-axes → hinge axis is shared a-axis)
  res2: constraintAlignB[b0;b1;f0;f1;alpha;sdt]
  b0:res2@0; b1:res2@1
  / Angle limits around hinge axis
  $[minA<maxA;
    constraintLimitAngle[b0;b1;f0;f1;minA;maxA;alpha;sdt];
    (b0;b1)]
}
```

### Servo / Motor

Drive the hinge angle to a specific target. Set `minA = maxA = targetAngle`:

```k
servoJoint: {[b0;b1;f0;f1;targetAngle;alpha;sdt]
  res: constraintAttach[b0;b1;f0;f1;alpha;sdt]
  b0:res@0; b1:res@1
  res2: constraintAlignB[b0;b1;f0;f1;alpha;sdt]
  b0:res2@0; b1:res2@1
  constraintLimitAngle[b0;b1;f0;f1;targetAngle;targetAngle;alpha;sdt]
}

/ Motor: advance target angle each substep, then servo to it
motorJoint: {[b0;b1;f0;f1;omega;maxAngle;alpha;sdt]
  / Advance target by omega*sdt, clamp to [-maxAngle, maxAngle]
  gMotorAngle:: (neg maxAngle)|gMotorAngle+omega*sdt & maxAngle
  servoJoint[b0;b1;f0;f1;gMotorAngle;alpha;sdt]
}
gMotorAngle: 0.
```

### Fixed (Weld) Joint

All 6 DOF locked.

```k
fixedJoint: {[b0;b1;f0;f1;alpha;sdt]
  res: constraintAttach[b0;b1;f0;f1;alpha;sdt]
  b0:res@0; b1:res@1
  res2: constraintAlignB[b0;b1;f0;f1;alpha;sdt]
  b0:res2@0; b1:res2@1
  constraintAlignA[b0;b1;f0;f1;alpha;sdt]
}
```

### Prismatic (Slide) Joint

Slide along one axis; no rotation. Lock all rotation and 2 of 3 translations.

```k
prismaticJoint: {[b0;b1;f0;f1;minDist;maxDist;alpha;sdt]
  / Full angular lock
  res: constraintAlignB[b0;b1;f0;f1;alpha;sdt]
  b0:res@0; b1:res@1
  res2: constraintAlignA[b0;b1;f0;f1;alpha;sdt]
  b0:res2@0; b1:res2@1

  / Lock perpendicular translations; allow only along a-axis (slide axis)
  fw0: frameToWorld[b0;f0]; fw1: frameToWorld[b1;f1]
  p0: fw0@0; p1: fw1@0
  slideAxis: fw0@1
  dp: p1-p0
  dpAlong: (+/dp*slideAxis)*slideAxis
  dpPerp: dp - dpAlong
  dist: +/ dp*slideAxis

  / Correct perpendicular offset
  res3: $[vlen(dpPerp)>1e-8;
           applyLinearCorr[b0;b1;alpha;sdt;p0;p0+dpPerp]; (b0;b1)]
  b0:res3@0; b1:res3@1

  / Clamp along-axis distance
  Calong: $[dist<minDist; dist-minDist; $[dist>maxDist; dist-maxDist; 0.]]
  $[abs(Calong)>1e-8;
    rbSolveConstraint[b0;b1;alpha;sdt;Calong;slideAxis;p0;p1];
    (b0;b1)]
}
```

### Cylinder Joint

Two DOF: slide along axis + rotate around it. Same as prismatic but without the torsion lock.

```k
cylinderJoint: {[b0;b1;f0;f1;minDist;maxDist;alpha;sdt]
  / Lock 2 angular DOF (free to spin around slide axis)
  res: constraintAlignB[b0;b1;f0;f1;alpha;sdt]
  b0:res@0; b1:res@1
  / Lock perpendicular translations + clamp axial distance
  fw0: frameToWorld[b0;f0]; fw1: frameToWorld[b1;f1]
  p0: fw0@0; p1: fw1@0
  slideAxis: fw0@1
  dp: p1-p0
  dpAlong: (+/dp*slideAxis)*slideAxis
  dpPerp: dp-dpAlong
  res2: $[vlen(dpPerp)>1e-8;
           applyLinearCorr[b0;b1;alpha;sdt;p0;p0+dpPerp]; (b0;b1)]
  b0:res2@0; b1:res2@1
  dist: +/ dp*slideAxis
  Calong: $[dist<minDist; dist-minDist; $[dist>maxDist; dist-maxDist; 0.]]
  $[abs(Calong)>1e-8;
    rbSolveConstraint[b0;b1;alpha;sdt;Calong;slideAxis;p0;p1];
    (b0;b1)]
}
```

---

## Joint Summary Table

| Joint | Linear DOF fixed | Angular DOF fixed | Building blocks |
|---|---|---|---|
| Ball-and-socket | 3 | 0 | Attach |
| Hinge | 3 | 2 | Attach + AlignB |
| Hinge+limits | 3 | 2+limit | Attach + AlignB + LimitAngle |
| Servo | 3 | 3 (driven) | Attach + AlignB + LimitAngle (bilateral) |
| Fixed | 3 | 3 | Attach + AlignB + AlignA |
| Prismatic | 2+limit | 3 | AlignB + AlignA + perp linear |
| Cylinder | 2+limit | 2 | AlignB + perp linear |

---

## Velocity-Level Corrections (Damping)

After `rbUpdateVel`, add velocity corrections for controlled damping. The same generalized inverse mass distributes the impulse — passing velocity change instead of position change to `rbSolveConstraint` with `alpha=0`:

```k
/ Linear damping: damp relative velocity at attachment points along their separation axis
dampLinear: {[b0;b1;f0;f1;kd;sdt]
  p0: (frameToWorld[b0;f0])@0
  p1: (frameToWorld[b1;f1])@0
  / Velocity at attachment point: v + omega x r
  vel0: (b0@1) + cross3[(b0@3); p0-b0@0]
  vel1: (b1@1) + cross3[(b1@3); p1-b1@0]
  n: (p1-p0); ln: vlen n
  $[ln<1e-10; (b0;b1);
    [n2: n%ln
     dv: +/ (vel1-vel0)*n2
     / Clamp: coefficient in [0,1] (cannot reverse velocity)
     c: dv * (kd*sdt & 1.)
     rbSolveConstraint[b0;b1;0.;sdt;c;n2;p0;p1]]]
}

/ Angular damping along hinge axis
dampAngular: {[b0;b1;f0;f1;axis;kd;sdt]
  / Relative angular velocity along axis
  relOm: (b1@3) - b0@3
  dOm: (+/ relOm*axis) * (kd*sdt & 1.)
  $[abs(dOm)<1e-10; (b0;b1);
    rbSolveAngular[b0;b1;0.;sdt;dOm;axis]]
}
```

The `kd*sdt & 1.` clamp (`&` = min in ink) is crucial: a coefficient of 1.0 removes relative velocity exactly (critical damping); above 1.0 the correction would reverse velocity, which is unphysical. This bound gives unconditional stability regardless of the damping coefficient or time step size.

---

## The Full Substep Loop

```k
/ One physics substep: integrate → solve joints → update velocities → damp
rbSubstep: {[bodies;joints;sdt]
  / Integrate
  bodies2: rbIntegrate[;sdt]' bodies   / from ch22

  / Solve all joints (sequential; each writes back to bodies2)
  gBodies:: bodies2
  {[j]
    res: solveJoint[gBodies;j;sdt]
    gBodies:: @[@[gBodies; j@0; :; res@0]; j@1; :; res@1]
  }' joints

  / Update velocities
  bodies3: rbUpdateVel[;sdt]' gBodies   / from ch22

  / Velocity-level damping
  gBodies:: bodies3
  {[j]
    fw0: frameToWorld[gBodies@(j@0); j@2]
    axis: fw0@1
    res: dampLinear[gBodies@(j@0); gBodies@(j@1); j@2; j@3; j@4; sdt]
    b0:res@0; b1:res@1
    res2: dampAngular[b0;b1;j@2;j@3;axis;j@5;sdt]
    gBodies:: @[@[gBodies;j@0;:;res2@0];j@1;:;res2@1]
  }' joints

  gBodies
}
gBodies: ()

/ Joint descriptor: (i0; i1; frame0; frame1; linDamp; angDamp; type; ...)
solveJoint: {[bodies;j;sdt]
  b0: bodies@(j@0); b1: bodies@(j@1)
  f0: j@2; f1: j@3; tp: j@6
  $[tp=`ballsocket; ballSocketJoint[b0;b1;f0;f1;0.;sdt];
    $[tp=`hinge;     hingeJoint[b0;b1;f0;f1;j@7;j@8;0.;sdt];
    $[tp=`servo;     servoJoint[b0;b1;f0;f1;j@7;0.;sdt];
    $[tp=`fixed;     fixedJoint[b0;b1;f0;f1;0.;sdt];
      (b0;b1)]]]]
}
```

---

## Example: Triple Pendulum

Three boxes linked by hinges. The simulation runs 20 substeps/frame — the magic number that keeps joints looking rigid under large external loads and 200:1 mass ratios.

```k
/ Build N-body pendulum chain
buildPendulum: {[n;sdt]
  siz: 0.1 0.3 0.1
  bods: {[i]
    mkBody[0; siz; 800.; (0.; neg i*0.6; 0.); 0. 0. 0.; 0. 0. 0. 1.; 0. 0. 0.]
  }' !n
  / Fix first body
  bods2: @[bods; 0; ; @[bods@0; 4; :; 0.]]

  / Hinge joints: bottom of i → top of i+1, axis = x
  jnts: {[i]
    wp: 0. (neg i*0.6+0.15) 0.   / world hinge point
    f0: mkFrame[bods2@i; wp; 1. 0. 0.; 0. 1. 0.; 0. 0. 1.]
    f1: mkFrame[bods2@(i+1); wp; 1. 0. 0.; 0. 1. 0.; 0. 0. 1.]
    (i; i+1; f0; f1; 0.01; 0.01; `hinge; neg 1.5708; 1.5708)
  }' !n-1

  (bods2; jnts)
}

p: buildPendulum[3; 1.%60]
bodies: p@0; joints: p@1

/ Simulate 60 frames × 20 substeps
bodies2: {rbSubstep[bodies; joints; 1.%1200.]}/ !1200
```

---

## Key Takeaways

- Every joint reduces to two primitive operations: **linear correction** (move attachment points together) and **angular correction** (rotate misaligned axes into alignment).
- **Attachment frames** (local position + local axes per body) are computed once at joint creation and transformed to world space each substep. They cleanly separate joint geometry from body motion.
- Four building blocks — **Attach**, **AlignB**, **AlignA**, **LimitAngle** — cover all standard joint types. A ball-and-socket is one call; a hinge is two; a weld is three.
- **LimitAngle with minA = maxA** is a bilateral constraint — used for servo/motor joints to drive the angle to a specific target.
- Velocity-level **damping** uses the same generalized inverse mass distribution as position corrections. The `kd*sdt & 1.` clamp guarantees unconditional stability: the correction never reverses the relative velocity it targets.
- **Substepping** (20 substeps/frame is typical) is the stability mechanism. Each substep solves each constraint once; convergence grows with the number of substeps, not iterations. Large mass ratios and stiff joints are both handled gracefully.
- XPBD unifies the entire series: particles, soft bodies, fluids, rigid bodies, and joints all use the same scalar violation → generalized inverse mass → scaled correction pipeline.
