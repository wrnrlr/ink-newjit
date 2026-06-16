# Chapter 3 — Ball Collision Handling in 2D

Two balls rolling toward each other must bounce. That sentence hides a surprising amount of physics and linear algebra. This chapter builds a complete 2D billiard simulation from scratch: we derive the collision response equations, introduce just enough vector mathematics to handle the 2D case cleanly, and then implement a working multi-ball simulator. By the end you will have a reusable pattern for circle–circle collision that applies equally well to particles, projectiles, and rigid discs.

---

## The Physics of a Collision

When two balls collide, deformations propagate through the material and generate repulsive forces that drive the objects apart. For stiff bodies this happens over an extremely short time interval, so short that it is impractical to integrate the forces directly. Instead we jump straight to the result: we compute the post-collision velocities using a pair of equations derived from the conservation of momentum and the coefficient of restitution.

For a 1D collision between balls with masses $m_1$, $m_2$ and pre-collision speeds $v_1$, $v_2$, the post-collision speeds are:

$$v_1' = \frac{m_1 v_1 + m_2 v_2 - m_2 (v_1 - v_2)\,e}{m_1 + m_2}$$

$$v_2' = \frac{m_1 v_1 + m_2 v_2 - m_1 (v_2 - v_1)\,e}{m_1 + m_2}$$

The scalar $e$ is the **coefficient of restitution**. When $e = 1$ the collision is perfectly elastic: kinetic energy is conserved and the balls bounce away at full speed. When $e = 0$ the collision is completely inelastic: the balls stick together and move as one.

These formulas handle 1D, but billiard balls move in 2D. The key insight is that only the velocity component along the line connecting the two centres is affected by the collision — the perpendicular component passes through unchanged.

---

## Vector Mathematics

A 2D vector $\mathbf{v} = [v_x,\, v_y]$ is an arrow in the plane. In ink, 2D vectors are two-element float lists. The core operations are built-in array operations:

**Length** (Pythagorean theorem):

```k
len: {sqrt (x@0)*(x@0) + (x@1)*(x@1)}
```

Note the parentheses: in ink, all operators are right-to-left with equal precedence. `(x@0)*(x@0) + (x@1)*(x@1)` correctly evaluates as `(x@0)*(x@0) + ((x@1)*(x@1))` since multiplication is rightmost.

**Dot product** (scalar projection):

```k
dot2: {(x@0)*(y@0) + (x@1)*(y@1)}
```

---

## Detecting a Collision

Two circles of radii $r_1$ and $r_2$ overlap whenever the distance between their centres is less than $r_1 + r_2$.

In the multi-ball simulation, positions and velocities are stored as parallel arrays. The `applyCol` helper applies the collision response for one pair of balls:

```k
/ Apply elastic collision between balls i and j
/ s: (px;py;vx;vy;r;m)
applyCol: {[s;i;j;nx;ny;corr]
  px:s@0; py:s@1; vx:s@2; vy:s@3; r:s@4; m:s@5
  / Positional correction (push apart)
  px: @[@[px;i;-;nx*corr];j;+;nx*corr]
  py: @[@[py;i;-;ny*corr];j;+;ny*corr]
  / Project velocities onto collision normal
  v1n: (nx*(vx@i)) + ny*(vy@i)
  v2n: (nx*(vx@j)) + ny*(vy@j)
  m1: m@i; m2: m@j
  mt: m1+m2
  / Elastic collision: redistribute normal components
  p: (m1*v1n) + m2*v2n
  nv1: (p - m2*(v1n-v2n)) % mt
  nv2: (p - m1*(v2n-v1n)) % mt
  vx: @[@[vx;i;+;nx*(nv1-v1n)];j;+;nx*(nv2-v2n)]
  vy: @[@[vy;i;+;ny*(nv1-v1n)];j;+;ny*(nv2-v2n)]
  (px;py;vx;vy;r;m)
}

/ Check and resolve one pair (i;j)
collidePair: {[s;ij]
  px:s@0; py:s@1; r:s@4; m:s@5; vx:s@2; vy:s@3
  i:ij@0; j:ij@1
  dx:(px@j)-(px@i); dy:(py@j)-(py@i)
  d: sqrt (dx*dx)+dy*dy
  minD: (r@i)+(r@j)
  $[d<0.0001|d>minD; s;
    applyCol[s;i;j;dx%d;dy%d;(minD-d)*0.5]]
}
```

The `@[array; index; op; value]` form of amend modifies one element of an array: `@[vx; i; +; delta]` adds `delta` to `vx@i`.

---

## Resolving the Overlap

When a collision is detected, the balls are already interpenetrating by an amount:

$$\delta = (r_1 + r_2) - d$$

The standard fix is **positional correction**: push each ball half the overlap distance along the collision normal before updating velocities. This is handled by `applyCol` above: `corr = (minD-d)*0.5` and each ball is displaced by `corr` along the unit normal.

---

## Computing the Collision Response

With the unit normal $\hat{\mathbf{n}}$ in hand, we project both velocities onto it. In the momentum formulation with restitution $e = 1$:

$$p = m_1 v_1 + m_2 v_2 \quad \text{(scalar momentum along } \hat{\mathbf{n}})$$

$$v_1' = \frac{p - m_2(v_1 - v_2)}{m_1 + m_2}, \qquad v_2' = \frac{p - m_1(v_2 - v_1)}{m_1 + m_2}$$

The change in each ball's normal velocity is applied as a vector impulse along $\hat{\mathbf{n}}$. The perpendicular components are untouched.

---

## Wall Collisions

Boundary collisions are vectorized over all balls simultaneously:

```k
/ Wall collision for all n balls at once
wallBounce: {[px;vx;r;hi]
  flip: (px<r) | px>(hi-r)
  vx2: vx * 1. - 2.*flip
  px2: r | px & (hi-r)
  (px2; vx2)
}
```

---

## The Simulation Loop

Each frame we advance every ball under gravity, check it against every other ball, then clamp it to the walls. Pairs are precomputed once:

```k
/ All unique pairs (i,j) with i<j, for n balls
pairs: {[n] a:!n*n; ri:a div n; ci:a mod n; k:&ri<ci; +(ri@k;ci@k)}

g: -10.
dt: 1.%60

step: {[s]
  px:s@0; py:s@1; vx:s@2; vy:s@3; r:s@4; m:s@5
  w:20.; h:15.; sdt:dt%10.
  / Gravity and integration
  vy: vy + g*sdt
  px: px+vx*sdt; py: py+vy*sdt
  / Wall bounces
  rx:(wallBounce[px;vx;r;w]); px:rx@0; vx:rx@1
  ry:(wallBounce[py;vy;r;h]); py:ry@0; vy:ry@1
  / Ball-ball collisions
  P: pairs #px
  s2: (px;py;vx;vy;r;m)
  collidePair/ (,s2),P
}
```

`collidePair/ (,s2),P` folds `collidePair` over all pairs, threading the updated state through each application. This correctly processes all $O(n^2)$ pairs in sequence.

---

## Benchmark

```k
/ 5 balls, 600 frames, 10 substeps
n: 5
px: 2. 5. 8. 11. 14.
py: 2. 4. 6. 4. 2.
vx: 3. -2. 1. -3. 2.
vy: 2. 3. -1. 2. -3.
r: 5#0.5
m: r*r*3.14159

\t 600 {10 step/ x}/ (px;py;vx;vy;r;m)
```

---

## Key Takeaways

- **Overlap detection** for two circles requires only a distance comparison: $d < r_1 + r_2$.
- **Positional correction** pushes balls apart by the overlap amount before updating velocities, preventing penetration from accumulating over time.
- **The dot product** reduces the 2D collision to a 1D problem by projecting velocities onto the collision normal $\hat{\mathbf{n}}$.
- **The 1D impulse formulas** give the new normal-direction speeds directly from masses, pre-collision speeds, and the coefficient of restitution $e$.
- **Only the normal component** of each velocity changes; the tangential component is unaffected by a frictionless collision.
- **Wall collisions** are vectorized: compute a boolean flip mask for all balls at once, apply it with array multiplication.
- **The `pairs` function** generates all unique pairs $(i,j)$ with $i < j$, and `collidePair/` folds the collision resolve over them in sequence.
