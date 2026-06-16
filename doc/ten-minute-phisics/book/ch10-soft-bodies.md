# Chapter 10 — Soft Bodies: Squish, Bounce, and Volume

A rigid body is an idealization. Real objects deform: rubber bands stretch, gel cubes squish, foam pillows compress and spring back. Simulating this behavior is the domain of *soft body dynamics*, and it is traditionally one of the most mathematically demanding areas of physics simulation. Finite element methods, constitutive models, implicit global solvers, and third-order tensor derivatives all appear in the standard treatment. This chapter takes a different path. By representing a soft body as a cloud of particles connected by simple constraints — the same framework introduced in the previous chapter for XPBD — we arrive at a simulation that is stable, fast, and surprisingly accurate, with very little code.

---

## Why Not Finite Elements?

The classical approach to soft body simulation borrows from structural engineering. It represents the object as a continuous deformable medium, describes deformation with vector-valued functions over the material's interior, and derives equations of motion by appealing to continuum mechanics. This yields *finite element methods* (FEM), which are powerful but carry heavy engineering baggage.

The difficulty is not just implementation complexity — though that is real. The deeper problem is a long list of failure modes that require specialist knowledge to handle:

- **Volume loss under stretch.** Popular linear elastic models shed volume as the object deforms, so a rubber band stretched to twice its length visibly thins in a physically incorrect way.
- **Inversion artifacts.** When elements flip inside out under large deformation, linear models produce severe visual artifacts and often require expensive recovery procedures.
- **Global solvers.** FEM requires assembling and solving large sparse matrices at every time step. The matrices can be non-symmetric, and handling both over-constrained and under-constrained configurations is non-trivial.
- **Stability under high damping.** Implicit integration helps with stiffness but introduces its own convergence and overshoot problems.

Each issue has known solutions, and entire research careers have been built on them. But if we are willing to think differently about what a material *is*, we can sidestep most of them at once.

Nature does not use continuous functions. Rubber, at the scale that matters, looks like a mass-spring network — long polymer chains that resist being pulled apart. Modeling materials as particles connected by constraints is not an approximation of FEM; it is an equally valid physical model at a different scale. And with the XPBD constraint solver from the previous chapter, that model becomes trivial to implement.

---

## Representing a Soft Body

The geometric foundation is a *tetrahedral mesh*: a solid 3D shape decomposed into tetrahedra in the same way that a surface mesh decomposes a 2D shape into triangles. Each tetrahedron fills a small region of the object's interior. A good tetrahedral mesh for physics uses *Delaunay tetrahedralization*, which maximizes the minimum angle of each tetrahedron and avoids numerically degenerate slivers.

From this mesh, the simulation constructs three things:

1. **One particle per vertex.** Each vertex becomes a point mass with a position, a velocity, and an inverse mass.
2. **One distance constraint per edge.** Edges are the connections between vertices. A distance constraint keeps a pair of particles at their rest separation, providing the material's resistance to stretching and compression along that edge.
3. **One volume constraint per tetrahedron.** Each tet has a rest volume. The volume constraint resists compression and expansion of that tet, acting as a kind of local incompressibility condition.

Together, these two constraint types approximate the behavior of a neo-Hookean elastic material — one that resists volume change much more strongly than shape change, which is characteristic of rubber and biological tissue. In controlled experiments comparing a discrete XPBD model against a continuous Hookean FEM model, the XPBD model actually shows *less* volume loss under extreme stretch. The simplicity is not a compromise; it is a different and often better physical model.

---

## The XPBD Constraint Solve

Both constraint types use the same XPBD formula introduced in Chapter 9. Given a constraint function $C$ whose value is zero when the constraint is exactly satisfied, and particles $i = 1 \ldots n$ participating in the constraint with inverse masses $w_i$, the position correction for each particle is:

$$\lambda = \frac{-C}{\sum_i w_i \|\nabla_i C\|^2 + \alpha / \Delta t^2}$$

$$\Delta \mathbf{x}_i = \lambda\, w_i\, \nabla_i C$$

The scalar $\alpha$ is the *compliance*, the inverse of stiffness. Setting $\alpha = 0$ gives a perfectly rigid constraint that enforces $C = 0$ exactly. Positive compliance allows controlled softness. Crucially, this formula is stable at any compliance value, including zero, with no need for implicit integration or global matrix solves.

For performance, we use *substepping* rather than iterating the constraint solve multiple times within a single time step. Ten substeps per frame at a 60 Hz frame rate means each substep sees a time step of about 1.67 ms — small enough that a single pass through all constraints per substep converges well in practice.

---

## Distance Constraint

The distance constraint between particles at positions $\mathbf{x}_1$ and $\mathbf{x}_2$ with rest length $l_0$ is:

$$C = \|\mathbf{x}_2 - \mathbf{x}_1\| - l_0$$

The gradients with respect to the two positions are:

$$\nabla_1 C = -\frac{\mathbf{x}_2 - \mathbf{x}_1}{\|\mathbf{x}_2 - \mathbf{x}_1\|}, \qquad \nabla_2 C = \frac{\mathbf{x}_2 - \mathbf{x}_1}{\|\mathbf{x}_2 - \mathbf{x}_1\|}$$

Each gradient has unit length, so the denominator in the $\lambda$ formula simplifies to $(w_1 + w_2) + \alpha/\Delta t^2$. The code follows directly:

```javascript
solveEdges(compliance, dt) {
    var alpha = compliance / dt / dt;

    for (var i = 0; i < this.edgeLengths.length; i++) {
        var id0 = this.edgeIds[2 * i];
        var id1 = this.edgeIds[2 * i + 1];
        var w0  = this.invMass[id0];
        var w1  = this.invMass[id1];
        var w   = w0 + w1;
        if (w == 0.0) continue;

        vecSetDiff(this.grads, 0, this.pos, id0, this.pos, id1);
        var len = Math.sqrt(vecLengthSquared(this.grads, 0));
        if (len == 0.0) continue;

        vecScale(this.grads, 0, 1.0 / len);   // unit gradient
        var C = len - this.edgeLengths[i];
        var s = -C / (w + alpha);
        vecAdd(this.pos, id0, this.grads, 0,  s * w0);
        vecAdd(this.pos, id1, this.grads, 0, -s * w1);
    }
}
```

The two particles are nudged toward each other when the edge is too long, and apart when it is too short, weighted by their inverse masses. A particle with infinite mass (inverse mass zero) does not move — useful for pinned or static particles.

---

## Volume Constraint

The signed volume of a tetrahedron with vertices $\mathbf{x}_1, \mathbf{x}_2, \mathbf{x}_3, \mathbf{x}_4$ is:

$$V = \frac{1}{6}\bigl[(\mathbf{x}_2 - \mathbf{x}_1) \times (\mathbf{x}_3 - \mathbf{x}_1)\bigr] \cdot (\mathbf{x}_4 - \mathbf{x}_1)$$

The constraint function is $C = 6(V - V_\text{rest})$, scaled by six to clear the fraction and simplify the gradient expressions. The gradients of $6V$ with respect to each vertex are:

$$\nabla_1 C = (\mathbf{x}_4 - \mathbf{x}_2) \times (\mathbf{x}_3 - \mathbf{x}_2)$$
$$\nabla_2 C = (\mathbf{x}_3 - \mathbf{x}_1) \times (\mathbf{x}_4 - \mathbf{x}_1)$$
$$\nabla_3 C = (\mathbf{x}_4 - \mathbf{x}_1) \times (\mathbf{x}_2 - \mathbf{x}_1)$$
$$\nabla_4 C = (\mathbf{x}_2 - \mathbf{x}_1) \times (\mathbf{x}_3 - \mathbf{x}_1)$$

Each gradient points in the direction that maximally increases the volume when vertex $i$ moves, which geometrically is the direction normal to the face of the tetrahedron opposite vertex $i$. When the tetrahedron is too small, each vertex is pushed outward along its face normal; when it is too large, inward.

The implementation loops over the four vertices, computes the gradient for each using a fixed lookup table for which faces to cross-product, then accumulates $w_i \|\nabla_i C\|^2$ in the denominator:

```javascript
solveVolumes(compliance, dt) {
    var alpha = compliance / dt / dt;

    for (var i = 0; i < this.numTets; i++) {
        var w = 0.0;

        for (var j = 0; j < 4; j++) {
            var id0 = this.tetIds[4 * i + this.volIdOrder[j][0]];
            var id1 = this.tetIds[4 * i + this.volIdOrder[j][1]];
            var id2 = this.tetIds[4 * i + this.volIdOrder[j][2]];

            vecSetDiff(this.temp, 0, this.pos, id1, this.pos, id0);
            vecSetDiff(this.temp, 1, this.pos, id2, this.pos, id0);
            vecSetCross(this.grads, j, this.temp, 0, this.temp, 1);
            vecScale(this.grads, j, 1.0 / 6.0);

            w += this.invMass[this.tetIds[4 * i + j]] *
                 vecLengthSquared(this.grads, j);
        }
        if (w == 0.0) continue;

        var vol     = this.getTetVolume(i);
        var restVol = this.restVol[i];
        var C = vol - restVol;
        var s = -C / (w + alpha);

        for (var j = 0; j < 4; j++) {
            var id = this.tetIds[4 * i + j];
            vecAdd(this.pos, id, this.grads, j, s * this.invMass[id]);
        }
    }
}
```

The `volIdOrder` table records, for each of the four vertices, which other three vertices form the opposite face in the correct winding order. Setting `volCompliance = 0.0` gives a perfectly incompressible material. Raising it allows controlled squishiness.

---

## Mass Assignment

Mass is not uniform in the mesh. Each vertex belongs to multiple tetrahedra, and its mass should reflect the total material volume it represents. The initialization computes an inverse mass for each vertex by summing contributions from every tetrahedron it touches:

```javascript
initPhysics() {
    for (var i = 0; i < this.numTets; i++) {
        var vol = this.getTetVolume(i);
        this.restVol[i] = vol;
        var pInvMass = vol > 0.0 ? 1.0 / (vol / 4.0) : 0.0;
        for (var j = 0; j < 4; j++)
            this.invMass[this.tetIds[4 * i + j]] += pInvMass;
    }
    for (var i = 0; i < this.edgeLengths.length; i++) {
        var id0 = this.edgeIds[2 * i];
        var id1 = this.edgeIds[2 * i + 1];
        this.edgeLengths[i] = Math.sqrt(
            vecDistSquared(this.pos, id0, this.pos, id1));
    }
}
```

Each tetrahedron distributes its mass equally among its four vertices: a tet of volume $V$ contributes inverse mass $4/V$ to each vertex, so the contribution to $w_i = 1/m_i$ is $4/V$ per tet. Vertices at the center of the mesh, surrounded by many tetrahedra, accumulate more mass than vertices at the surface — the same way that interior material is denser in terms of how many constraints act on it.

---

## The Simulation Loop

The main loop follows the XPBD pattern exactly. Each frame is divided into substeps, and within each substep: apply forces, record previous positions, integrate positions, then solve constraints.

```javascript
function simulate() {
    var sdt = gPhysicsScene.dt / gPhysicsScene.numSubsteps;
    for (var step = 0; step < gPhysicsScene.numSubsteps; step++) {
        for (var i = 0; i < gPhysicsScene.objects.length; i++)
            gPhysicsScene.objects[i].preSolve(sdt, gPhysicsScene.gravity);
        for (var i = 0; i < gPhysicsScene.objects.length; i++)
            gPhysicsScene.objects[i].solve(sdt);
        for (var i = 0; i < gPhysicsScene.objects.length; i++)
            gPhysicsScene.objects[i].postSolve(sdt);
    }
}
```

The `preSolve` step applies gravity to each particle's velocity, saves the current position to `prevPos`, and advances the position by the velocity. Ground collision is handled here as well: if any particle drops below $y = 0$, its position is reset to the saved `prevPos` and its $y$-coordinate is clamped to zero. This effectively freezes the particle at the floor without introducing explicit collision forces.

```javascript
preSolve(dt, gravity) {
    for (var i = 0; i < this.numParticles; i++) {
        if (this.invMass[i] == 0.0) continue;
        vecAdd(this.vel, i, gravity, 0, dt);
        vecCopy(this.prevPos, i, this.pos, i);
        vecAdd(this.pos, i, this.vel, i, dt);
        if (this.pos[3 * i + 1] < 0.0) {
            vecCopy(this.pos, i, this.prevPos, i);
            this.pos[3 * i + 1] = 0.0;
        }
    }
}
```

After the constraint solve, `postSolve` recovers the velocity from the displacement that occurred during the substep:

```javascript
postSolve(dt) {
    for (var i = 0; i < this.numParticles; i++) {
        if (this.invMass[i] == 0.0) continue;
        vecSetDiff(this.vel, i, this.pos, i, this.prevPos, i, 1.0 / dt);
    }
    this.updateMeshes();
}
```

This velocity recovery is what gives the simulation its bounce: when constraints push particles away from each other or away from the floor, the displacement between `prevPos` and `pos` translates directly into outgoing velocity.

---

## Flat Arrays for Performance

One implementation detail that matters at scale is memory layout. Rather than allocating one JavaScript object per particle, all positions, velocities, and previous positions live in flat `Float32Array` buffers, with coordinates packed as consecutive triplets:

```javascript
this.pos     = new Float32Array(tetMesh.verts);
this.prevPos = tetMesh.verts.slice();
this.vel     = new Float32Array(3 * this.numParticles);
```

The index of particle $i$'s $x$-coordinate is $3i$, its $y$-coordinate is $3i+1$, and its $z$-coordinate is $3i+2$. Every vector operation receives both the array and the particle number, and computes the byte offset internally. This is why the vector functions have signatures like `vecAdd(a, anr, b, bnr, scale)` rather than operating on objects.

The payoff is significant. Because the Three.js renderer stores vertex positions in the same packed format, the `pos` buffer can be shared directly with the GPU — `this.surfaceMesh.geometry.attributes.position.needsUpdate = true` is all it takes to upload the new positions for rendering. With ten thousand tetrahedra, the simulation runs at interactive frame rates without any special optimization.

---

## Interactive Behavior

The demo includes a grabber that lets the user drag the soft body around. When a grab begins, the nearest particle is identified by brute-force search, and its inverse mass is set to zero, making it immovable. The constraint solver then propagates the constraint violations caused by the locked particle through the rest of the mesh. When the grab is released, the original inverse mass is restored and the thrown velocity is injected:

```javascript
endGrab(pos, vel) {
    if (this.grabId >= 0) {
        this.invMass[this.grabId] = this.grabInvMass;
        vecCopy(this.vel, this.grabId, [vel.x, vel.y, vel.z], 0);
    }
    this.grabId = -1;
}
```

No matter how aggressively the object is dragged or squashed, the simulation remains stable. Setting compliance to zero means the volume constraints are hard constraints: the object can deform but it cannot lose volume. Clamping a bunny mesh to half its height with a single button press, then releasing it, sends it bouncing off the ground in a physically plausible way — all from distance and volume constraints acting locally on each particle and tetrahedron.

---

## Key Takeaways

- **Tetrahedral meshes** decompose a solid 3D object into tetrahedra. One particle per vertex, one distance constraint per edge, and one volume constraint per tetrahedron are sufficient to simulate elastic behavior.
- **Distance constraints** resist edge stretching and compression. They are the primary source of shear stiffness in the material.
- **Volume constraints** resist compression and expansion of each tetrahedron. Setting their compliance to zero produces a near-incompressible material that conserves volume even under extreme deformation.
- **Compliance** $\alpha = 1/k$ is the inverse of stiffness. Setting $\alpha = 0$ enforces a constraint exactly; positive $\alpha$ allows controlled elasticity. XPBD remains stable at any compliance value.
- **Substepping** — running multiple constraint passes per rendered frame at a smaller time step — replaces the need for iteration within a single step, keeping the implementation simple while achieving good convergence.
- **Flat Float32Array buffers** for positions and velocities eliminate per-particle object overhead and allow the position buffer to be shared directly with the GPU renderer.
- The XPBD soft body approach **matches or exceeds** standard Hookean FEM models for volume conservation under large stretch, despite being far simpler to implement. The discrete particle model is not an approximation; it is an equally valid physical description of elastic materials.
