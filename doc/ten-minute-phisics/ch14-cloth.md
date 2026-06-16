# Chapter 14 — The Secret of Cloth Simulation

Cloth is one of the most visually compelling things a physics engine can simulate and, for a long time, one of the most computationally treacherous. Waving flags, falling capes, and draped fabric all demand that a mesh of thousands of triangles move convincingly in real time. This chapter reveals a surprisingly simple principle at the heart of cloth simulation and shows how XPBD — the constraint-based method introduced in Chapter 9 — turns that principle into a fast, stable, and parameter-light implementation.

---

## The Secret: Cloth Only Bends

The key insight is this: real cloth barely stretches. Pick up a shirt, a pair of jeans, a curtain, or a tarpaulin and pull it lengthwise. It resists immediately and strongly. Under ordinary gravity, a typical fabric elongates by somewhere between zero and five percent, and only under quite large loads. More importantly, the force-versus-elongation curve is nearly vertical in that range: a small additional stretch requires a very large additional force. Cloth reaches its stretch limit fast and stays there.

This has a practical consequence for simulation. Too much stretching is a glaring visual artifact — cloth that sags and droops like taffy looks wrong to every viewer. Too little stretching, by contrast, is essentially unnoticeable. The tolerance for under-stretching is effectively infinite; the tolerance for over-stretching is nearly zero.

The logical conclusion is bold: **model cloth as an infinitely stiff material in the stretch direction.** Do not try to tune a spring stiffness to match fabric; simply forbid elongation entirely.

The immediate objection is numerical. In a force-based simulation, infinite stiffness means infinite forces, which means numerical explosion. Explicit integrators blow up at the first substep. Implicit integrators require solving a poorly conditioned linear system. Neither option is pleasant.

The solution, as with soft bodies and joints, is XPBD. Infinite stiffness corresponds directly to **zero compliance** in the XPBD framework. A zero-compliance distance constraint enforces its target length exactly within the substep, with no spring constant to tune and no risk of explosion. The constraint solver handles stiffness the right way: by position correction, not by force.

---

## Mesh Setup

A cloth mesh is a triangulated surface. Every vertex becomes a particle with a position, a previous position, a velocity, and an inverse mass. Every edge of the triangulation becomes a distance constraint that holds the two endpoint particles at their rest separation.

Particle masses are set proportional to the area of the triangles that surround each vertex. Specifically, for each triangle with area $A$, each of its three vertices receives an inverse mass contribution of $1/(A/3)$. Summing these contributions across all triangles gives each vertex an inverse mass roughly proportional to $1/(\text{local area})$, so denser regions of the mesh are heavier per unit area and respond to forces consistently with the physical material.

Two corner particles at the top of the cloth are fixed in place by setting their inverse mass to zero. They act as attachment points — the cloth hangs from them under gravity.

```javascript
for (var i = 0; i < numTris; i++) {
    var id0 = triIds[3 * i], id1 = triIds[3 * i + 1], id2 = triIds[3 * i + 2];
    vecSetDiff(e0, 0, this.pos, id1, this.pos, id0);
    vecSetDiff(e1, 0, this.pos, id2, this.pos, id0);
    vecSetCross(c, 0, e0, 0, e1, 0);
    var A = 0.5 * Math.sqrt(vecLengthSquared(c, 0));
    var pInvMass = A > 0.0 ? 1.0 / (A / 3.0) : 0.0;
    this.invMass[id0] += pInvMass;
    this.invMass[id1] += pInvMass;
    this.invMass[id2] += pInvMass;
}
```

After mass assignment, the code pins the top-left and top-right corners by zeroing their inverse masses. Any particle with `invMass == 0` is treated as static by every subsequent step.

---

## Two Kinds of Constraints

Once the mesh is set up, two families of constraints govern the cloth's behavior.

### Stretch Constraints

Every edge in the triangulation gets a zero-compliance distance constraint. These constraints enforce the rest length of the edge exactly, preventing the fabric from stretching or compressing along any triangle edge. This includes both the edges that run along the grid directions (analogous to warp and weft threads) and the diagonal edges that hold the triangulation together against shear forces. By covering all triangle edges, the constraint set resists stretch in every in-plane direction simultaneously.

The rest length for each edge is simply the Euclidean distance between its two endpoint particles in the initial configuration.

### Bending Constraints

Stretch constraints alone produce a cloth that can fold completely flat with zero resistance — like a sheet of paper that has been cut into triangles. Real fabric resists bending: it takes effort to fold a shirt crisply, and cloth naturally relaxes to a curved, low-energy shape rather than collapsing.

Bending resistance comes from pairs of adjacent triangles. When two triangles share an edge, they form a hinge. Bending that hinge away from flat brings the two *non-shared* vertices — one from each triangle — closer together or pushes them farther apart. A distance constraint between these two opposite vertices therefore resists the bending.

This approach is called the **diagonal distance constraint** for bending. It is simple and cheap to evaluate, though it has a known weakness: when the cloth is already flat, the diagonal distance is at its maximum and the constraint gradient is nearly zero, so it exerts little corrective force. For a cloth that starts flat and remains roughly flat, this weakness is minor in practice. A more expensive alternative — the dihedral angle constraint, which directly measures the angle between the two triangle normals — does not share this weakness, but it requires more computation and is left for a later chapter.

The bending constraint carries a compliance parameter $\alpha$. Unlike the stretch constraint, which uses zero compliance (perfect rigidity), the bending constraint is intentionally soft. A high compliance value produces floppy, drapey fabric; a low compliance value produces stiff canvas. This single scalar is the only tunable physical parameter in the entire simulation.

---

## Finding Triangle Neighbors

To build the bending constraint list, we need to know which pairs of triangles share an edge. Given an arbitrary triangle mesh, this is not immediately obvious. The implementation solves it with a sort.

Each triangle has three edges. We assign each edge a **global edge number**:

$$\text{globalEdgeNr} = 3 \times \text{triangleIndex} + \text{localEdgeIndex}$$

where `localEdgeIndex` is 0, 1, or 2 within the triangle. We then build an array of records, one per edge, each storing the sorted vertex indices of that edge (smaller index first) and the global edge number:

```javascript
for (var i = 0; i < numTris; i++) {
    for (var j = 0; j < 3; j++) {
        var id0 = triIds[3 * i + j];
        var id1 = triIds[3 * i + (j + 1) % 3];
        edges.push({
            id0: Math.min(id0, id1),
            id1: Math.max(id0, id1),
            edgeNr: 3 * i + j
        });
    }
}
```

Sorting this array by `(id0, id1)` groups shared edges together: an interior edge belongs to exactly two triangles and therefore produces two records with identical vertex pairs. After sorting, we scan the array and wherever two consecutive records have the same `(id0, id1)` pair, we record each as the other's neighbor:

```javascript
edges.sort((a, b) => ((a.id0 < b.id0) || (a.id0 == b.id0 && a.id1 < b.id1)) ? -1 : 1);

var nr = 0;
while (nr < edges.length) {
    var e0 = edges[nr++];
    if (nr < edges.length) {
        var e1 = edges[nr];
        if (e0.id0 == e1.id0 && e0.id1 == e1.id1) {
            neighbors[e0.edgeNr] = e1.edgeNr;
            neighbors[e1.edgeNr] = e0.edgeNr;
        }
        nr++;
    }
}
```

Edges with no neighbor (boundary edges) remain at the sentinel value of $-1$. The result is a flat array, `neighbors`, parallel to the edge list: for any global edge number $k$, `neighbors[k]` gives the global edge number of the triangle on the other side, or $-1$ if there is none.

With this neighbor table in hand, building the bending constraint list is straightforward. For each interior edge, we collect all four relevant particle indices: the two shared vertices ($p_1$, $p_2$) and the two opposite vertices ($p_3$, $p_4$, one from each triangle):

```javascript
if (n >= 0) {
    var ni = Math.floor(n / 3);
    var nj = n % 3;
    var id2 = mesh.faceTriIds[3 * i + (j + 2) % 3];
    var id3 = mesh.faceTriIds[3 * ni + (nj + 2) % 3];
    triPairIds.push(id0, id1, id2, id3);
}
```

The bending constraint itself only uses $p_3$ and $p_4$ (indices `id2` and `id3` here), but storing all four indices is forward-compatible with a future dihedral angle implementation that needs all four.

---

## The XPBD Simulation Loop

The per-frame loop follows the standard XPBD pattern with 15 substeps per frame at 60 fps:

1. **Pre-solve**: apply gravity to all free particles, save current positions as previous positions, integrate positions with velocity, resolve floor collisions.
2. **Solve**: process all stretch constraints, then all bending constraints.
3. **Post-solve**: recompute velocities from position differences.

```javascript
function simulate() {
    var sdt = gPhysicsScene.dt / gPhysicsScene.numSubsteps;
    for (var step = 0; step < gPhysicsScene.numSubsteps; step++) {
        for (var i = 0; i < objects.length; i++) objects[i].preSolve(sdt, gravity);
        for (var i = 0; i < objects.length; i++) objects[i].solve(sdt);
        for (var i = 0; i < objects.length; i++) objects[i].postSolve(sdt);
    }
}
```

The pre-solve and post-solve steps are identical to those used for soft bodies. Only the constraint solving differs.

### Solving a Distance Constraint

Both the stretch and bending constraints reduce to the same code path — a distance constraint between two particles. The XPBD formula for a distance constraint is:

$$\Delta\mathbf{x}_0 = +\frac{w_0}{w_0 + w_1 + \tilde{\alpha}} \cdot (|\mathbf{x}_1 - \mathbf{x}_0| - L_0) \cdot \hat{\mathbf{n}}$$
$$\Delta\mathbf{x}_1 = -\frac{w_1}{w_0 + w_1 + \tilde{\alpha}} \cdot (|\mathbf{x}_1 - \mathbf{x}_0| - L_0) \cdot \hat{\mathbf{n}}$$

where $w_0 = 1/m_0$ and $w_1 = 1/m_1$ are the inverse masses, $L_0$ is the rest length, $\hat{\mathbf{n}}$ is the unit vector from $\mathbf{x}_0$ to $\mathbf{x}_1$, and $\tilde{\alpha} = \alpha / \Delta t^2$ is the compliance scaled by the substep duration.

```javascript
solveStretching(compliance, dt) {
    var alpha = compliance / dt / dt;

    for (var i = 0; i < this.stretchingLengths.length; i++) {
        var id0 = this.stretchingIds[2 * i];
        var id1 = this.stretchingIds[2 * i + 1];
        var w0 = this.invMass[id0], w1 = this.invMass[id1];
        var w = w0 + w1;
        if (w == 0.0) continue;

        vecSetDiff(this.grads, 0, this.pos, id0, this.pos, id1);
        var len = Math.sqrt(vecLengthSquared(this.grads, 0));
        if (len == 0.0) continue;
        vecScale(this.grads, 0, 1.0 / len);

        var C = len - this.stretchingLengths[i];
        var s = -C / (w + alpha);
        vecAdd(this.pos, id0, this.grads, 0,  s * w0);
        vecAdd(this.pos, id1, this.grads, 0, -s * w1);
    }
}
```

The bending solver is character-for-character identical, except it reads its particle indices from `bendingIds` (offsetting by 2 to access $p_3$ and $p_4$) and uses a non-zero compliance value. There is no special bending formula — bending resistance, in this implementation, is just a distance constraint between the opposite vertices with a chosen softness.

### Why Zero Compliance Works

Setting `stretchingCompliance = 0` makes $\tilde{\alpha} = 0$, which means the denominator in the position correction is simply $w_0 + w_1$. The constraint violation $C = \text{len} - L_0$ is corrected fully in a single pass: the two particles are pushed exactly back to their rest distance. This is the position-based dynamics limit: constraints satisfied by projection rather than by force.

With 15 substeps per frame, even a complex mesh of 6,000 triangles converges quickly. Each substep propagates the corrections through the mesh, and by the end of the frame the cloth is effectively inextensible. The simulation remains unconditionally stable regardless of the substep size because there are no spring forces — only bounded positional corrections.

---

## What the Parameters Actually Control

Once the mesh and constraints are in place, the physical character of the cloth is determined by only two things:

**Bending compliance $\alpha$**: the single free parameter. A value of zero gives stiff, resistant fabric (canvas, cardboard). A value of 10 or higher gives soft, drapey fabric (silk, chiffon). Intermediate values cover denim, cotton, and most everyday materials. Crucially, no amount of compliance in the bending constraints can cause the simulation to become unstable — unlike spring stiffness in explicit integrators.

**Substep count**: more substeps produce a stiffer-looking cloth at the cost of more CPU time. Fifteen substeps at 60 fps is enough for a well-behaved mesh of a few thousand triangles.

Everything else — stretch resistance, shear resistance, mass distribution — is determined automatically by the mesh geometry and the zero-compliance constraint setup.

---

## Key Takeaways

- **Cloth barely stretches in reality.** Modeling it as infinitely stiff in the stretch direction is physically accurate and visually correct — viewers never notice too little stretch, but always notice too much.
- **Zero-compliance distance constraints** implement infinite stretch stiffness within XPBD without numerical explosion. Setting `compliance = 0` is not a special case; it falls out naturally from the XPBD formulation.
- **Bending resistance** is modeled as a distance constraint between the two vertices that are not shared by a pair of adjacent triangles. It is soft by design, with a single compliance parameter $\alpha$ that controls the fabric's drape.
- **Triangle neighbor finding** reduces to sorting an edge list by vertex indices and scanning for consecutive duplicate pairs. The result is a neighbor array indexed by global edge number.
- **The solver for bending and stretch is the same function** — a standard XPBD distance constraint solve. Bending is not a fundamentally different computation; it is just a constraint applied to a different pair of particles with a non-zero compliance.
- **Substepping provides convergence.** With 15 substeps per frame, the corrections propagate through the mesh far enough each frame to produce convincing inextensibility with no tuning required.
- The entire cloth system has **one tunable parameter**: bending compliance. Everything else is derived from the geometry.
