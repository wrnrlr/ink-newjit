# Chapter 15 — Self-Collision: The Hardest Problem in Cloth Simulation

The cloth simulation developed in Chapter 14 produces convincing drape, fold, and stretch, but it has a silent flaw: the cloth passes through itself. Pull two corners toward each other and the fabric interpenetrates without resistance. For a hanging flag this is merely ugly; for a garment on a character it is completely unacceptable. Solving self-collision is what separates a cloth simulation that works on a test sphere from one that works in production.

Self-collision is considered one of the hardest open problems in real-time physics. This chapter explains why, then shows a practical combination of five techniques that together make self-collision robust enough for cloth at interactive frame rates.

---

## Why Self-Collision Is Uniquely Hard

Collision between a cloth particle and a static object — a floor, a sphere, a rigid body — is straightforward. The object has a well-defined inside and outside. When a particle ends up on the wrong side, the correction is obvious: push it back to the surface in the direction of the outward normal.

Self-collision has no such structure. After two patches of cloth interpenetrate, the configuration is globally ambiguous. Consider a piece of cloth that has folded so that one triangle pierces another. To separate them, you could push the top patch upward or the bottom patch downward — both corrections are locally valid. There is no geometric signal to indicate which is right. The problem is, in the formal sense, ill-posed.

The only way to resolve this ambiguity is to never let it arise. The entire self-collision strategy rests on a single principle: **start in a valid state and prevent any entanglement from ever occurring.** This shifts the problem from resolution to prevention, which is a much more tractable goal.

Two technical obstacles make prevention difficult.

The first is scale. A cloth mesh with 6,000 triangles has thousands of particles. A naive check of every pair is $O(n^2)$ — on the order of millions of distance evaluations per frame. At 60 fps with 10 substeps, that is simply not feasible.

The second is tunneling. A fast-moving particle can pass through a thin feature — another fold of cloth — between one substep and the next. No distance check at discrete time points will catch it, because the particle was outside before and outside after, even though it crossed through. Continuous collision detection can catch this, but swept-volume tests for thousands of deforming particle pairs are extremely expensive, and handling the rollback after detection is complicated.

The following five techniques address both obstacles together.

---

## Trick 1: Use Particles and a Spatial Hash

The first simplification is to treat cloth thickness as a physical property from the start. Each particle is modeled as a sphere of radius $r$. Two particles collide when the distance between their centers drops below $2r$. This is the simplest possible collision primitive: sphere versus sphere.

The sphere primitive makes the broad phase straightforward. Chapter 11 introduced a spatial hash that answers the query "find all particles within distance $d$ of particle $i$" in expected $O(1)$ time. The hash divides space into cells of side length roughly $2r$ and, for each particle, checks only the $3 \times 3 \times 3 = 27$ neighboring cells. For $n$ particles, building the hash is $O(n)$ and querying all pairs is $O(n)$ expected — far better than the $O(n^2)$ naive approach.

Using many small spheres instead of a few complex primitives is a general principle worth remembering. It keeps the narrow-phase test trivial and allows the data structure to stay simple and cache-friendly.

---

## Trick 2: Use Rest Distance to Prevent Jittering

Cloth particles that are close together in the rest configuration — adjacent on the mesh — will naturally have a small rest distance. If that rest distance is less than $2r$, the stretch constraint (which pushes them to their rest separation) and the collision constraint (which pushes them apart to $2r$) will fight each other at every substep, causing visible jittering.

The fix is to clip the collision distance from above by the rest distance:

$$d_\text{coll} = \min(2r,\ d_\text{rest})$$

where $d_\text{rest}$ is the Euclidean distance between the two particles in their rest configuration. This way, if two particles are "meant" to be close, the collision constraint targets that same closeness rather than a larger separation, and the two constraints agree.

Computing $d_\text{rest}$ for every pair in advance would require $O(n^2)$ memory. Instead, the rest positions are stored in a second array alongside the live positions. At collision time, $d_\text{rest}$ is computed on the fly from `restPos` with a single distance call.

The collision constraint also checks whether the current distance already exceeds $d_\text{rest}$. If it does, the particles are farther apart than they were in the rest pose, and no collision correction is applied — only when the current separation is less than $d_\text{rest}$ (or $2r$, whichever is smaller) does the constraint activate.

---

## Trick 3: Sub-step Instead of Continuous Collision Detection

Continuous collision detection (CCD) tests whether the swept volumes of two moving objects overlap during the interval $[t, t + \Delta t]$. For two moving spheres, this reduces to finding the minimum distance between two line segments in 4D space-time — doable, but expensive, and the rollback required after a hit is even more involved.

Sub-stepping sidesteps this entirely. If we take $n$ substeps per frame, a particle moves at most $v \cdot \Delta t / n$ per substep. With enough substeps, the chance that a particle tunnels through a feature within a single substep becomes negligible. The spatial hash is built once per frame (not once per substep, which would be prohibitively expensive) and then reused across all substeps:

```javascript
// Once per frame
this.hash.create(this.pos);
var maxTravelDist = maxVelocity * frameDt;
this.hash.queryAll(this.pos, maxTravelDist);

// Then n substeps, reusing the precomputed neighbor lists
for (var step = 0; step < numSubSteps; step++) {
    integrateParticles(dt);
    solveConstraints(dt);
    solveCollisions(dt);
    updateVelocities(dt);
}
```

Building the hash from positions at the start of the frame and querying with a search radius of `maxVelocity * frameDt` ensures that all particles that could possibly come into contact during the frame are captured in the neighbor lists. The neighbor lists remain valid throughout the substep loop because no particle can travel farther than this distance.

---

## Trick 4: Enforce a Maximum Velocity

Sub-stepping reduces the chance of tunneling, but does not eliminate it. A particle moving at an extreme velocity can still leap across a thin fold in one substep. The remedy is to cap particle velocities directly.

The safety condition is simple: a particle should not move more than one radius per substep. If the substep duration is $\Delta t_\text{sub} = \Delta t / n$, then:

$$v_\text{max} = \frac{r}{\Delta t_\text{sub}} = \frac{r \cdot n}{\Delta t}$$

This limit is less restrictive than it might appear. With $r = 0.01$ m, $n = 10$ substeps, and $\Delta t = 1/60$ s:

$$v_\text{max} = \frac{0.01 \times 10}{1/60} = 6 \text{ m/s}$$

That is roughly the running speed of a human character. The cloth will not separate from a sprinting character, and it will not tunnel through itself during any motion a cloth garment would realistically experience. The velocity cap is enforced each substep before the position update:

```javascript
var v = Math.sqrt(vecLengthSquared(this.vel, i));
var maxV = 0.2 * this.thickness / dt;
if (v > maxV) {
    vecScale(this.vel, i, maxV / v);
}
```

Note the factor of `0.2` — a conservative safety margin below the theoretical limit, accounting for the fact that multiple constraints can combine to produce larger position changes than any single one.

---

## Trick 5: Unconditionally Stable Cloth-Cloth Friction

When two cloth particles collide, it is not enough to push them apart. Without friction, they would slide past each other freely even after the separation is corrected. With standard explicit friction (apply a tangential impulse proportional to the relative tangential velocity), the damping force can overshoot, reversing the relative velocity instead of zeroing it — which leads to oscillation.

The stable approach averages the velocities of the two particles after collision. Let $\mathbf{x}_1, \mathbf{p}_1$ and $\mathbf{x}_2, \mathbf{p}_2$ be the current and previous positions of the two particles. Within XPBD, the implicit velocity of each particle is $(\mathbf{x}_i - \mathbf{p}_i) / h$, where $h$ is the substep duration. The average velocity is:

$$\mathbf{v}_\text{avg} = \frac{(\mathbf{x}_1 - \mathbf{p}_1) + (\mathbf{x}_2 - \mathbf{p}_2)}{2h}$$

Pushing both particles' velocities toward this average — with a damping coefficient $d \in [0, 1]$ — in position form:

$$\mathbf{x}_1 \leftarrow \mathbf{x}_1 + d \cdot (\mathbf{v}_\text{avg} - \mathbf{v}_1) \cdot h$$
$$\mathbf{x}_2 \leftarrow \mathbf{x}_2 + d \cdot (\mathbf{v}_\text{avg} - \mathbf{v}_2) \cdot h$$

The factors of $h$ cancel, so the correction depends only on position differences:

$$\mathbf{x}_1 \leftarrow \mathbf{x}_1 + d \cdot \tfrac{1}{2}\left[(\mathbf{x}_2 - \mathbf{p}_2) - (\mathbf{x}_1 - \mathbf{p}_1)\right]$$
$$\mathbf{x}_2 \leftarrow \mathbf{x}_2 + d \cdot \tfrac{1}{2}\left[(\mathbf{x}_1 - \mathbf{p}_1) - (\mathbf{x}_2 - \mathbf{p}_2)\right]$$

This never overshoots: with $d = 1$ the velocities are equalized exactly; with $d < 1$ they are partially equalized. The scheme is unconditionally stable for any $d \in [0, 1]$. To give $d$ a physical interpretation, set $d = \text{clamp}(h \cdot d_\text{physical}, 0, 1)$, where $d_\text{physical}$ is a friction coefficient in units of $\text{s}^{-1}$.

---

## The Collision Solver in Full

With all five tricks in place, the `solveCollisions` method is compact. For each particle, it iterates over the precomputed neighbor list from the spatial hash and applies the position correction followed by the friction update:

```javascript
solveCollisions(dt) {
    var thickness2 = this.thickness * this.thickness;

    for (var i = 0; i < this.numParticles; i++) {
        if (this.invMass[i] == 0.0) continue;
        var id0 = i;
        var first = this.hash.firstAdjId[i];
        var last  = this.hash.firstAdjId[i + 1];

        for (var j = first; j < last; j++) {
            var id1 = this.hash.adjIds[j];
            if (this.invMass[id1] == 0.0) continue;

            vecSetDiff(this.vecs, 0, this.pos, id1, this.pos, id0);
            var dist2 = vecLengthSquared(this.vecs, 0);
            if (dist2 > thickness2 || dist2 == 0.0) continue;

            var restDist2 = vecDistSquared(this.restPos, id0, this.restPos, id1);
            if (dist2 > restDist2) continue;

            var minDist = this.thickness;
            if (restDist2 < thickness2)
                minDist = Math.sqrt(restDist2);

            // Push particles apart
            var dist = Math.sqrt(dist2);
            vecScale(this.vecs, 0, (minDist - dist) / dist);
            vecAdd(this.pos, id0, this.vecs, 0, -0.5);
            vecAdd(this.pos, id1, this.vecs, 0,  0.5);

            // Friction: blend velocities toward their average
            vecSetDiff(this.vecs, 0, this.pos, id0, this.prevPos, id0);
            vecSetDiff(this.vecs, 1, this.pos, id1, this.prevPos, id1);
            vecSetSum(this.vecs, 2, this.vecs, 0, this.vecs, 1, 0.5);
            vecSetDiff(this.vecs, 0, this.vecs, 2, this.vecs, 0);
            vecSetDiff(this.vecs, 1, this.vecs, 2, this.vecs, 1);

            var friction = 0.0;  // set > 0 to enable tangential damping
            vecAdd(this.pos, id0, this.vecs, 0, friction);
            vecAdd(this.pos, id1, this.vecs, 1, friction);
        }
    }
}
```

Several details deserve attention. The early exit `if (dist2 > restDist2) continue` implements trick 2: if the particles are farther apart than they are in the rest pose, no collision is relevant. The variable `minDist` starts at `thickness` but is reduced to `Math.sqrt(restDist2)` when the rest distance is smaller than the cloth thickness — this is the clipping formula $d_\text{coll} = \min(2r, d_\text{rest})$ from trick 2. The position corrections use equal weights of $\pm 0.5$ because both particles have equal inverse mass in this example; a general implementation would weight them by $w_0 / (w_0 + w_1)$ and $w_1 / (w_0 + w_1)$ respectively.

---

## The Hash's `queryAll` Method

The `Hash` class from Chapter 11 gains one new method for this use case. Rather than returning candidates for a single query particle, `queryAll` builds a compact adjacency list covering all pairs across the entire cloth in one pass:

```javascript
queryAll(pos, maxDist) {
    var num = 0;
    var maxDist2 = maxDist * maxDist;

    for (var i = 0; i < this.maxNumObjects; i++) {
        this.firstAdjId[i] = num;
        this.query(pos, i, maxDist);

        for (var j = 0; j < this.querySize; j++) {
            var id1 = this.queryIds[j];
            if (id1 >= i) continue;                    // avoid duplicate pairs
            if (vecDistSquared(pos, i, pos, id1) > maxDist2) continue;
            this.adjIds[num++] = id1;
        }
    }
    this.firstAdjId[this.maxNumObjects] = num;
}
```

The adjacency list is stored as two flat arrays: `firstAdjId[i]` gives the start index and `firstAdjId[i+1]` gives the end index of particle $i$'s neighbor range in `adjIds`. This is a standard compressed sparse row (CSR) layout. It avoids any per-pair memory allocation and is highly cache-friendly during the substep loop.

The guard `if (id1 >= i) continue` ensures each pair $(i, j)$ with $i > j$ appears exactly once. Because the outer loop visits $i$ in increasing order and the inner loop filters to $\text{id1} < i$, each unordered pair is recorded under the larger of its two indices.

The search radius passed to `queryAll` is `maxVelocity * frameDt` — the maximum distance any particle can travel over the entire frame. This ensures that even particles which are not yet in contact at the start of the frame will be in the neighbor list if they could come into contact by the end.

---

## Performance in Practice

A cloth mesh of 12,000 triangles (roughly 6,000 particles) running with 10 substeps at 60 fps takes approximately 60 ms per frame on a contemporary CPU in this JavaScript implementation. The simulation remains intersection-free under interactive manipulation — the cloth can be grabbed and folded, crumpled against itself, and released, all without tunneling or entanglement.

The key to this performance is building the spatial hash and neighbor lists only once per frame. If the hash were rebuilt at every substep, the overhead would increase by a factor of 10. The precomputed neighbor lists remain valid because the velocity cap guarantees no particle moves farther than `maxTravelDist` between the hash construction and the end of the frame.

---

## Key Takeaways

- **Self-collision is ill-posed after the fact.** Once cloth passes through itself, there is no local geometric signal to indicate the correct resolution. The only reliable strategy is to prevent penetration from ever occurring.
- **Represent thickness as sphere radius $r$.** Treating each particle as a sphere of radius $r$ reduces all self-collision narrow-phase tests to sphere-sphere distance comparisons — the simplest possible primitive.
- **Spatial hashing gives $O(n)$ broad phase.** Building the hash once per frame and querying a search radius of `maxVelocity * frameDt` captures all potentially colliding pairs without any per-substep rebuild cost.
- **Use rest distance to set the collision target.** When two particles are closer in their rest pose than $2r$, targeting $d_\text{coll} = \min(2r, d_\text{rest})$ eliminates the jitter caused by competing stretch and collision constraints.
- **The velocity cap $v_\text{max} = r \cdot n / \Delta t$ prevents tunneling.** It is less restrictive than it sounds — for reasonable cloth parameters it allows motion at running speed while guaranteeing at most one radius of travel per substep.
- **Velocity averaging gives unconditionally stable friction.** Blending the implicit velocities of two colliding particles toward their average with coefficient $d \in [0, 1]$ never overshoots and requires no timestep tuning.
- **The precomputed CSR neighbor list is the performance linchpin.** Computing it once per frame and reusing it across all substeps is what makes the approach fast enough for interactive use.
