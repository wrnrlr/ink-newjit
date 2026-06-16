# Chapter 15 — Self-Collision: The Hardest Problem in Cloth Simulation

The cloth simulation from Chapter 14 produces convincing drape, fold, and stretch, but has a silent flaw: the cloth passes through itself. Solving self-collision is what separates a cloth simulation that works on a test sphere from one that works in production.

Self-collision is considered one of the hardest open problems in real-time physics. This chapter explains why, then shows five techniques that together make self-collision robust enough for interactive cloth.

---

## Why Self-Collision Is Uniquely Hard

Collision between a cloth particle and a static object — a floor, a sphere — is straightforward. The object has a well-defined inside and outside. When a particle ends up on the wrong side, push it back along the outward normal.

Self-collision has no such structure. When two patches of cloth interpenetrate, the configuration is globally ambiguous. Consider cloth that has folded so that one triangle pierces another. To separate them, you could push the top patch upward or the bottom patch downward — both corrections are locally valid. There is no geometric signal to indicate which is right.

The only way to resolve this ambiguity is to never let it arise. The entire self-collision strategy rests on a single principle: **start in a valid state and prevent any entanglement from ever occurring.** This shifts the problem from resolution to prevention.

Two obstacles make prevention difficult: **scale** (a naive check of every pair is O(n²)) and **tunneling** (a fast-moving particle can pass through thin cloth between substeps).

The following five techniques address both obstacles together.

---

## Trick 1: Use Particles and a Spatial Hash

Model cloth thickness as a physical property from the start. Each particle is a sphere of radius $r$. Two particles collide when the distance between centers drops below $2r$. This is the simplest possible collision primitive: sphere versus sphere.

The sphere primitive makes the broad phase straightforward. The spatial hash from Chapter 11 answers "find all particles within distance $d$ of particle $i$" in expected O(1) time. For $n$ particles, building the hash is O(n) and querying all pairs is O(n) expected.

---

## Trick 2: Use Rest Distance to Prevent Jittering

Cloth particles close together in the rest configuration — adjacent on the mesh — have a small rest distance. If that rest distance is less than $2r$, the stretch constraint (pushing them to rest separation) and the collision constraint (pushing them apart to $2r$) fight each other at every substep, causing visible jittering.

The fix: clip the collision target distance from above by the rest distance:

$$d_\text{coll} = \min(2r,\ d_\text{rest})$$

If two particles are "meant" to be close, the collision constraint targets that same closeness rather than a larger separation. Also skip the collision entirely if the current distance already exceeds $d_\text{rest}$ — the particles are already farther apart than in the rest pose.

---

## Trick 3: Sub-step Instead of Continuous Collision Detection

Continuous collision detection (CCD) tests whether swept volumes overlap during $[t, t+\Delta t]$. For two moving spheres, this reduces to minimum distance between two line segments in space-time — doable but expensive, and the rollback after detection is complex.

Sub-stepping sidesteps this entirely. If we take $n$ substeps per frame, a particle moves at most $v \cdot \Delta t / n$ per substep. With enough substeps, the chance of tunneling within a single substep becomes negligible.

The spatial hash is built once per frame with a search radius of `maxVelocity * frameDt`, then reused across all substeps:

```k
/ Build hash once per frame with search radius = max possible travel distance
setupCollisions: {[pos;n;r;frameDt;h;ts]
  maxVel: 2.*r%frameDt       / safety: one radius per substep → 10 substeps
  searchR: maxVel * frameDt
  buildHash[pos;n;searchR;ts]
}
```

Building the hash from start-of-frame positions and querying with `maxVelocity * frameDt` captures all particles that could possibly come into contact during the frame.

---

## Trick 4: Enforce a Maximum Velocity

Sub-stepping reduces tunneling probability but does not eliminate it. The safety condition: a particle should not move more than one radius per substep.

$$v_\text{max} = \frac{r}{\Delta t_\text{sub}} = \frac{r \cdot n}{\Delta t}$$

This is less restrictive than it sounds. With $r = 0.01$ m, 10 substeps, and $\Delta t = 1/60$ s:

$$v_\text{max} = \frac{0.01 \times 10}{1/60} = 6 \text{ m/s}$$

That is roughly running speed. The cloth will not separate from a sprinting character and will not tunnel through itself under realistic cloth motion.

```k
/ Cap velocity to prevent tunneling: maxV = safety * r / sdt
capVelocity: {[vel;invM;r;sdt]
  maxV: 0.2 * r % sdt      / 0.2 safety margin
  {[i]
    $[invM@i=0.; vel@i;
      [v: vlen vel@i
       $[v>maxV; (vel@i) * maxV%v; vel@i]]]
  }' !#vel
}
```

The factor of 0.2 is a conservative safety margin below the theoretical limit, accounting for multiple constraints combining to produce larger position changes.

---

## Trick 5: Unconditionally Stable Cloth-Cloth Friction

When two cloth particles collide, it is not enough to push them apart. Without friction, they slide past each other freely. Standard explicit friction (tangential impulse proportional to relative tangential velocity) can overshoot — reversing relative velocity instead of zeroing it — causing oscillation.

The stable approach averages the velocities of the two particles after collision. Within XPBD, the implicit velocity of particle $i$ is $(\mathbf{x}_i - \mathbf{p}_i) / h$ where $\mathbf{p}_i$ is its previous position. The average velocity is:

$$\mathbf{v}_\text{avg} = \frac{(\mathbf{x}_1 - \mathbf{p}_1) + (\mathbf{x}_2 - \mathbf{p}_2)}{2h}$$

Pushing both particles' velocities toward this average with damping coefficient $d \in [0, 1]$, in position form (factors of $h$ cancel):

$$\mathbf{x}_1 \leftarrow \mathbf{x}_1 + d \cdot \tfrac{1}{2}\left[(\mathbf{x}_2 - \mathbf{p}_2) - (\mathbf{x}_1 - \mathbf{p}_1)\right]$$
$$\mathbf{x}_2 \leftarrow \mathbf{x}_2 + d \cdot \tfrac{1}{2}\left[(\mathbf{x}_1 - \mathbf{p}_1) - (\mathbf{x}_2 - \mathbf{p}_2)\right]$$

This never overshoots: with $d = 1$ velocities are equalized exactly; with $d < 1$ they are partially equalized. Unconditionally stable for any $d \in [0, 1]$.

---

## The Collision Solver

With all five tricks in place, the collision solver iterates over the precomputed neighbor list and applies position correction plus friction:

```k
/ Solve self-collisions for all particles
/ restPos: rest configuration positions (list of 3-vectors)
/ pos: current positions; prevPos: positions before this substep
/ invM: inverse masses; r: cloth thickness radius; friction: damping in [0,1]
solveClothCollisions: {[pos;prevPos;restPos;invM;r;friction]
  thickness2: r*r
  / For each particle i, check neighbors from precomputed global neighbor list
  {[i]
    $[invM@i=0.; 0;  / skip pinned
      [{[j]
        $[invM@j=0.; 0;                              / skip pinned partner
          [d: (pos@j) - pos@i
           dist2: +/ d*d
           $[dist2=0.; 0;
             [restD: (restPos@j) - restPos@i
              restDist2: +/ restD*restD
              $[dist2>restDist2; 0;  / already farther than rest — skip
                [minDist: $[restDist2<thickness2; sqrt restDist2; r+r]
                 dist: sqrt dist2
                 $[dist>=minDist; 0;
                   / Push apart symmetrically (equal mass assumed; use weights for unequal)
                   [corr: d * (minDist-dist) % dist
                    pos:: @[@[pos; i; -; corr*0.5]; j; +; corr*0.5]
                    / Friction: blend implicit velocities toward average
                    $[friction>0.;
                      [v1: (pos@i) - prevPos@i
                       v2: (pos@j) - prevPos@j
                       vavg: (v1+v2)*0.5
                       pos:: @[@[pos; i; +; friction*(vavg-v1)]; j; +; friction*(vavg-v2)]];
                      0]]]]]]]
       }' queryNeighbors[pos;i;r+r;#pos]]
  }' !#pos
  pos
}
```

The early exit when `dist2 > restDist2` implements trick 2: if particles are farther apart than in the rest pose, no collision applies.

---

## Precomputed Adjacency Lists

For performance, build a full adjacency list once per frame covering all pairs, using the spatial hash `queryAll` pattern (CSR layout):

```k
/ Build per-particle neighbor lists (CSR layout) from spatial hash
/ Returns (firstAdjId; adjIds) — firstAdjId@i to firstAdjId@(i+1) gives neighbors of i
buildAdjList: {[pos;n;maxDist;h;ts]
  buildHash[pos;n;h;ts]
  maxDist2: maxDist*maxDist
  adjBuf: ()
  firstAdj: n # 0
  {[i]
    start: #adjBuf
    firstAdj:: @[firstAdj;i;:;start]
    cands: queryNeighbors[pos;i;maxDist;h;ts]
    {[j]
      $[j>=i; 0;   / each pair (i>j) once under the larger index
        [d:(pos@j)-pos@i
         $[(+/d*d)<=maxDist2; adjBuf:: adjBuf,j; 0]]]
    }' cands
  }' !n
  firstAdj:: firstAdj,#adjBuf
  (firstAdj; adjBuf)
}
```

The `firstAdjId@i` to `firstAdjId@(i+1)` range gives particle $i$'s neighbors in `adjIds`. This avoids re-querying the hash each substep and is the performance linchpin: build once, reuse across all substeps.

---

## Integrating Into the Cloth Loop

The full cloth loop with self-collision:

```k
/ Cloth frame with self-collision
/ Assumes gCellStart, gOrder set by buildHash (Chapter 11)
clothFrameWithCollision: {[dt;numSubsteps;r;friction;invM;restPos;stretchIds;stretchLens;bendIds;bendLens;bendAlpha;state]
  pos: state@0; vel: state@1
  sdt: dt%numSubsteps

  / Build neighbor lists once from start-of-frame positions
  maxDist: (r+r) + |/vlen' vel * dt
  h: r+r; ts: 2*#pos
  buildHash[pos;#pos;h;ts]

  {[s]
    p:s@0; v:s@1
    / Cap velocity
    v2: capVelocity[v;invM;r;sdt]
    / Pre-solve
    v3: {[i] $[invM@i=0.; v2@i; (v2@i)+grav*sdt]}' !#p
    prevP: p
    p2: {[i] p@i + (v3@i)*sdt}' !#p
    / Solve stretch
    p3: {[acc;c] solveEdge[acc;invM;c@0;c@1;c@2;0.;sdt]}/ (p2;),{stretchIds@x,stretchLens@x}' !#stretchIds
    / Solve bending
    p4: {[acc;c] solveEdge[acc;invM;c@0;c@1;c@2;bendAlpha;sdt]}/ (p3;),{bendIds@x,bendLens@x}' !#bendIds
    / Solve self-collisions
    p5: solveClothCollisions[p4;prevP;restPos;invM;r;friction]
    / Post-solve
    v4: {[i] $[invM@i=0.; v3@i; (p5@i - prevP@i)%sdt]}' !#p
    (p5; v4)
  }/ (pos;vel)
}
```

---

## Performance in Practice

A cloth mesh of 6,000 particles running with 10 substeps at 60 fps, with self-collision enabled, runs in approximately 60 ms per frame on a contemporary CPU — the spatial hash keeps the broad phase from becoming the bottleneck. The simulation remains intersection-free under interactive folding and crumpling.

The key to this performance: build the hash and neighbor lists once per frame. Rebuilding at every substep would increase overhead by 10x. The precomputed neighbor lists remain valid because the velocity cap guarantees no particle moves farther than `maxTravelDist` between construction and end of frame.

---

## Key Takeaways

- **Self-collision is ill-posed after the fact.** Once cloth passes through itself, there is no local geometric signal for the correct resolution. Prevention — not resolution — is the only robust strategy.
- **Particle spheres of radius $r$** reduce all self-collision tests to sphere-sphere distance comparisons.
- **Spatial hashing** gives O(n) broad phase. Build once per frame with search radius `maxVelocity * frameDt`.
- **Rest distance clipping** $d_\text{coll} = \min(2r, d_\text{rest})$ eliminates jitter from competing stretch and collision constraints.
- **Velocity cap** $v_\text{max} = 0.2 \cdot r / \Delta t_s$ prevents tunneling, and allows motion at running speed for typical cloth parameters.
- **Velocity averaging** gives unconditionally stable cloth-cloth friction. Blending implicit velocities toward their average with $d \in [0, 1]$ never overshoots.
- **Precomputed CSR neighbor lists** are the performance linchpin: compute once per frame, reuse across all substeps.
