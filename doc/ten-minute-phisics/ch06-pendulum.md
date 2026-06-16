# Chapter 6 — Pendulum Chains and Distance Constraints

A single pendulum is one of physics' oldest worked examples. Chain three of them together — each bob hanging from the one above — and you have one of physics' most famous demonstrations of chaos: a system so sensitive to initial conditions that even the most accurate simulation eventually diverges from the true trajectory. This chapter extends the Position-Based Dynamics (PBD) framework introduced in the previous chapter to handle chains of particles connected by distance constraints. The result is a simulation that handles cloth, rope, hair, and multi-body linkages using the same simple idea: after each integration step, move particles so that the constraints are satisfied.

## Hard Distance Constraints

A distance constraint between two particles demands that the distance between them remains fixed at some rest length $l_0$. This is conceptually a spring with infinite stiffness — the link neither stretches nor compresses, no matter what forces act on it.

PBD takes a direct route. Rather than working with forces or specialized coordinates, it works directly with positions: after each integration step, nudge the particles so that the constraint is satisfied, then derive the new velocities from how far the particles moved.

## The Correction Step

Let particles $\mathbf{p}_0$ and $\mathbf{p}_1$ be connected by a link of rest length $l_0$. After integration their current distance is $l = \|\mathbf{p}_1 - \mathbf{p}_0\|$. The correction distributes the error in proportion to the *inverse masses* $w_i = 1/m_i$:

$$\mathbf{p}_0 \mathrel{+}= +\frac{w_0}{w_0 + w_1}\,\Delta l\,\hat{\mathbf{n}}$$
$$\mathbf{p}_1 \mathrel{+}= -\frac{w_1}{w_0 + w_1}\,\Delta l\,\hat{\mathbf{n}}$$

where $\Delta l = l - l_0$ is the constraint error and $\hat{\mathbf{n}} = (\mathbf{p}_1 - \mathbf{p}_0) / l$ is the unit link direction.

In ink, solving one distance constraint between particles $i$ and $i-1$:

```k
/ Apply distance constraint between consecutive bead pair i-1, i.
/ s: (px; py; vx; vy; invMass; lengths)  — all arrays
/ Returns updated s.
solveLink: {[s;i]
  px:s@0; py:s@1; invM:s@4; L:s@5
  dx: (px@i)-(px@(i-1))
  dy: (py@i)-(py@(i-1))
  d: sqrt (dx*dx)+dy*dy
  $[d=0.; s;
    [w0: invM@(i-1); w1: invM@i
     wt: w0+w1
     $[wt=0.; s;
       [corr: ((L@i)-d)%d%wt
        px2: @[@[px;i-1;-;w0*corr*dx];i;+;w1*corr*dx]
        py2: @[@[py;i-1;-;w0*corr*dy];i;+;w1*corr*dy]
        (px2;py2;s@2;s@3;invM;L)]]]]
}
```

The factor `(L@i-d)%d%wt` is the fractional length error divided by the total inverse-mass weight. Multiplying by the unnormalized direction vector `(dx, dy)` simultaneously applies the direction and magnitude without an explicit normalize step.

**Note on ink arithmetic:** in ink all operators are right-to-left with equal precedence. `w0*corr*dx` parses as `w0*(corr*dx)` which is correct since multiplication is associative. But `w0 + w1` is just a sum, and `(L@i)-d` is a difference — both fine as written.

## Extending PBD to Multiple Particles

A chain of $N$ masses connected by $N-1$ links (with the first particle anchored to a fixed pivot) is exactly an N-pendulum. The PBD loop extends naturally:

```k
grav: -10.

/ One substep of pendulum chain PBD
/ State: (px; py; vx; vy; invMass; restLengths)
pendStep: {[s;sdt]
  px:s@0; py:s@1; vx:s@2; vy:s@3; invM:s@4; L:s@5
  n: #px
  / 1. Integrate free particles (skip i=0, the fixed pivot)
  vy2: @[vy; 1+!n-1; +; (n-1)#grav*sdt]
  ppx: px; ppy: py
  px2: @[px; 1+!n-1; +; (1+!n-1) {(vy2@x)*sdt}' !n-1]
  py2: @[py; 1+!n-1; +; (1+!n-1) {(vy2@x)*sdt}' !n-1]
  s2: (px2;py2;vx;vy2;invM;L)
  / 2. Enforce distance constraints for links 1..n-1
  s3: solveLink/(,s2),1+!n-1
  / 3. Derive velocities from displacement
  px3:s3@0; py3:s3@1
  vx3: (px3-ppx)%sdt
  vy3: (py3-ppy)%sdt
  (px3;py3;vx3;vy3;invM;L)
}
```

The particle at index 0 is the fixed pivot — its `invMass = 0` ensures it never moves. The constraint loop `solveLink/(,s2),1+!n-1` folds over link indices 1 through $n-1$ in sequence.

## Initialization from Angles

A chain configuration can be initialized by walking forward from the pivot, converting given angles and link lengths into Cartesian positions:

```k
/ Build pendulum state from (lengths; masses; angles; pivot)
makePendulum: {[L;m;angles;pivx;pivy]
  n: #L
  / Cumulative positions from pivot
  xs: pivx + +\L * sin angles
  ys: pivy - +\L * cos angles
  px: pivx, xs
  py: pivy, ys
  invM: (1%m),~0.
  (px; py; n+1#0.; n+1#0.; invM; 0.,L)
}
```

`+\L * sin angles` is a running sum of `L[i] * sin(angles[i])` — the cumulative x-displacement from the pivot. The first particle (index 0) is the pivot itself with `invMass = 0`.

## Complete Simulation

```k
grav: -10.

pendStep: {[s;sdt]
  px:s@0; py:s@1; vx:s@2; vy:s@3; invM:s@4; L:s@5
  n: #px; free: 1+!n-1
  vy2: @[vy;free;+;(n-1)#grav*sdt]
  ppx: px; ppy: py
  px2: @[px;free;+;(vx@free)*sdt]
  py2: @[py;free;+;(vy2@free)*sdt]
  s2: (px2;py2;vx;vy2;invM;L)
  s3: solveLink/(,s2),free
  px3:s3@0; py3:s3@1
  vx3: (px3-ppx)%sdt
  vy3: (py3-ppy)%sdt
  (px3;py3;vx3;vy3;invM;L)
}

/ Triple pendulum: 3 equal-mass unit-length links
L: 1. 1. 1.
m: 1. 1. 1.
angles: 0.3 0.3 0.3
s0: makePendulum[L;m;angles;0.;5.]

sdt: (1.%60)%100.
\t result: 600 {100 pendStep[;sdt]/ x}/ s0
result@0            / final x-positions of all 4 particles
result@1            / final y-positions
```

## Sub-stepping and Stability

One sub-step per frame produces a visibly damped system. Dividing the frame's time budget into many small sub-steps and running the full integrate-constrain-velocity loop each time restores accuracy:

- 5 sub-steps: convincing rope or cloth simulation
- 100 sub-steps: triple pendulum stays close to reference trajectory for several seconds
- 10,000 sub-steps: precise enough to compare against Lagrangian reference

## Key Takeaways

- A **hard distance constraint** fixes the distance between two particles at a rest length $l_0$. It is the building block for ropes, cloth, hair, and rigid linkages.
- PBD enforces constraints by **directly correcting positions** after each integration step, then deriving velocities from the displacement. No force tuning or specialized coordinate systems are needed.
- Corrections are distributed by **inverse mass**: a particle with twice the mass receives half the displacement. Setting mass to infinity (invMass = 0) pins a particle in place.
- The algorithm generalizes to **chains of any length** without modification — adding more bobs means appending entries to the length, mass, and angle arrays.
- **Sub-stepping** is the primary knob for accuracy. A handful of sub-steps suffices for cloth or rope; hundreds are needed to track a chaotic pendulum for more than a few seconds.
- For hard constraints, PBD is **as accurate as XPBD**. Trajectory divergence in chaotic systems reflects the physics, not a flaw in the method.
