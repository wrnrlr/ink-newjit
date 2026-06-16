# Chapter 12 — Mesh Skinning for Soft Bodies

A physically accurate soft-body simulation demands tetrahedral elements that fill the entire volume of an object. The problem is that the number of tetrahedra grows roughly in proportion to the cube of linear resolution — so a visually convincing surface mesh of 60,000 triangles, when naively tetrahedralized, produces something in the region of 300,000 tetrahedra. Simulating that many constrained elements in real time is impractical.

This chapter introduces a clean solution: decouple the simulation mesh from the render mesh. The physics engine works on a coarse tetrahedral mesh with perhaps 3,000 tetrahedra. The high-resolution visual surface — the mesh the viewer actually sees — is "skinned" to that coarse mesh, meaning each visual vertex is expressed as a weighted combination of the surrounding simulation vertices. After each physics step, updating the full render mesh costs almost nothing. The result is a factor of roughly 100x in simulation speed with no perceptible loss of visual fidelity for the kinds of motion a soft body exhibits.

---

## Two Paths to Complexity Reduction

When a simulation is too expensive, there are broadly two ways to reduce it without abandoning the underlying physics.

The first is **model reduction**. Here you start with the full high-resolution system matrix, decompose it into eigenmodes — the natural deformation patterns of the object — and then retain only the k most significant modes. The simulation then operates entirely in that low-dimensional space. This approach is mathematically elegant and provably optimal in the sense that you keep exactly the deformation patterns that matter most. The catch is that the eigendecomposition is non-trivial for nonlinear materials and becomes significantly more complex when collision handling is involved.

The second approach, and the one developed here, is **surface embedding**. Rather than reducing the simulation mathematics, we reduce the simulation mesh directly. The steps are:

1. Take the high-resolution visual mesh and produce a decimated, feature-aware version of it (a tool like Blender's decimate modifier works well for this).
2. Tetrahedralize that decimated surface to produce the coarse physics mesh.
3. Embed the original visual mesh inside the coarse volumetric mesh and compute, for each visual vertex, how to reconstruct its position from the surrounding tet vertices.

Step 3 is what this chapter covers. Once the embedding is computed — which happens once at startup — the per-frame skinning update is a simple weighted sum requiring no physics at all.

---

## Barycentric Coordinates

The embedding is built on **barycentric coordinates**, a classical construction in computational geometry. Given a tetrahedron with four vertices **p**₁, **p**₂, **p**₃, **p**₄, any point **v** in space can be written as:

> **v** = b₁·**p**₁ + b₂·**p**₂ + b₃·**p**₃ + b₄·**p**₄

The four scalars b₁…b₄ are the barycentric coordinates of **v** with respect to that tetrahedron. They always sum to one:

> b₁ + b₂ + b₃ + b₄ = 1

When all four coordinates are non-negative, **v** lies inside (or on the boundary of) the tetrahedron. When any coordinate is negative, **v** is outside, but the interpolation still works — it simply extrapolates from the nearest tet.

The key property for skinning is that the coordinates are constant in the reference frame of the tetrahedron. As the simulation deforms the tet — stretching it, rotating it, squashing it — the visual vertex follows automatically, reconstructed from the same weighted sum applied to the deformed tet vertices.

### Computing the Coordinates

To solve for b₁, b₂, b₃, b₄ given the tet vertices and a visual vertex **v**, start by subtracting **p**₄ from all points. This eliminates b₄ from the equation because **p**₄ − **p**₄ = 0:

> **v** − **p**₄ = b₁(**p**₁ − **p**₄) + b₂(**p**₂ − **p**₄) + b₃(**p**₃ − **p**₄)

Define the 3×3 matrix **P** whose columns are the three edge vectors from **p**₄:

> **P** = [**p**₁ − **p**₄,  **p**₂ − **p**₄,  **p**₃ − **p**₄]

Then the first three coordinates follow directly by matrix inversion:

> [b₁, b₂, b₃]ᵀ = **P**⁻¹ (**v** − **p**₄)

And the fourth:

> b₄ = 1 − b₁ − b₂ − b₃

This is cheap: one 3×3 inverse per tetrahedron (computed once at startup) and one matrix-vector multiply per candidate visual vertex.

### Barycentric Distance

Visual vertices do not always fall neatly inside one of the tets. Surface vertices near concavities or near the border of the coarse mesh may fall outside every tetrahedron. To handle this gracefully, define a **barycentric distance** from a point to a tetrahedron as:

> d = max(−b₁, −b₂, −b₃, −b₄)

When **v** is inside the tet, all bᵢ ≥ 0 and d ≤ 0. When **v** is outside, at least one bᵢ is negative, and d measures how far outside. Attaching each visual vertex to the tetrahedron with the smallest d — even if d > 0 — gives the best possible skinning for every vertex, whether interior or exterior.

---

## Computing the Skinning Attachment

Before simulation begins, every visual vertex must be matched to its best tetrahedron and its barycentric coordinates stored. A brute-force search over all pairs of visual vertices and tetrahedra would be O(V·T), which is too slow for large meshes. The trick is to use a spatial hash.

Hash all visual vertices by their 3D position into a grid. Then iterate over tetrahedra: for each tet, compute a bounding sphere, query the hash for all visual vertices that fall within that sphere, and for each candidate, compute and store the barycentric coordinates if they improve on the current best attachment.

```javascript
computeSkinningInfo(visVerts) {
    var hash = new Hash(0.05, this.numVisVerts);
    hash.create(visVerts);

    this.skinningInfo.fill(-1.0);
    var minDist = new Float32Array(this.numVisVerts);
    minDist.fill(Number.MAX_VALUE);
    var border = 0.05;

    var tetCenter = new Float32Array(3);
    var mat = new Float32Array(9);
    var bary = new Float32Array(4);

    for (var i = 0; i < this.numTets; i++) {
        // Compute bounding sphere of this tetrahedron
        tetCenter.fill(0.0);
        for (var j = 0; j < 4; j++)
            vecAdd(tetCenter, 0, this.pos, this.tetIds[4 * i + j], 0.25);

        var rMax = 0.0;
        for (var j = 0; j < 4; j++) {
            var r2 = vecDistSquared(tetCenter, 0, this.pos, this.tetIds[4 * i + j]);
            rMax = Math.max(rMax, Math.sqrt(r2));
        }
        rMax += border;

        hash.query(tetCenter, 0, rMax);

        // Build P matrix and invert it once for this tet
        var id0 = this.tetIds[4 * i],     id1 = this.tetIds[4 * i + 1];
        var id2 = this.tetIds[4 * i + 2], id3 = this.tetIds[4 * i + 3];

        vecSetDiff(mat, 0, this.pos, id0, this.pos, id3);
        vecSetDiff(mat, 1, this.pos, id1, this.pos, id3);
        vecSetDiff(mat, 2, this.pos, id2, this.pos, id3);
        matSetInverse(mat);

        for (var j = 0; j < hash.querySize; j++) {
            var id = hash.queryIds[j];

            // Skip if already found a containing tet
            if (minDist[id] <= 0.0) continue;

            // Skip if outside the bounding sphere
            if (vecDistSquared(visVerts, id, tetCenter, 0) > rMax * rMax) continue;

            // Compute barycentric coords: b = P^{-1} (v - p4)
            vecSetDiff(bary, 0, visVerts, id, this.pos, id3);
            matSetMult(mat, bary, 0, bary, 0);
            bary[3] = 1.0 - bary[0] - bary[1] - bary[2];

            // Barycentric distance: how far outside (negative = inside)
            var dist = 0.0;
            for (var k = 0; k < 4; k++)
                dist = Math.max(dist, -bary[k]);

            // Keep the best (smallest distance) attachment
            if (dist < minDist[id]) {
                minDist[id] = dist;
                this.skinningInfo[4 * id]     = i;       // tet index
                this.skinningInfo[4 * id + 1] = bary[0];
                this.skinningInfo[4 * id + 2] = bary[1];
                this.skinningInfo[4 * id + 3] = bary[2]; // b3 = 1 - b0 - b1 - b2
            }
        }
    }
}
```

A few implementation details are worth noting. The bounding sphere is computed as the circumscribed sphere of the tet center plus a small border. The border exists because we want to catch visual vertices that lie just outside every tet — we want to attach them to the nearest tet, not leave them unattached. The matrix **P** is inverted once per tet and reused for every candidate vertex, keeping the per-vertex cost to a single matrix-vector multiply.

The `skinningInfo` array stores four floats per visual vertex: the tet index followed by b₁, b₂, b₃. The fourth coordinate b₄ is not stored because it is always `1 − b₁ − b₂ − b₃` and is reconstructed on the fly.

---

## Updating the Visual Mesh

Once the skinning attachment is computed, updating the visual mesh after each simulation step is straightforward:

```javascript
updateVisMesh() {
    const positions = this.visMesh.geometry.attributes.position.array;
    var nr = 0;
    for (let i = 0; i < this.numVisVerts; i++) {
        var tetNr = this.skinningInfo[nr++] * 4;
        if (tetNr < 0) { nr += 3; continue; }

        var b0 = this.skinningInfo[nr++];
        var b1 = this.skinningInfo[nr++];
        var b2 = this.skinningInfo[nr++];
        var b3 = 1.0 - b0 - b1 - b2;

        var id0 = this.tetIds[tetNr++], id1 = this.tetIds[tetNr++];
        var id2 = this.tetIds[tetNr++], id3 = this.tetIds[tetNr++];

        vecSetZero(positions, i);
        vecAdd(positions, i, this.pos, id0, b0);
        vecAdd(positions, i, this.pos, id1, b1);
        vecAdd(positions, i, this.pos, id2, b2);
        vecAdd(positions, i, this.pos, id3, b3);
    }
    this.visMesh.geometry.computeVertexNormals();
    this.visMesh.geometry.attributes.position.needsUpdate = true;
}
```

This is a pure weighted-sum kernel. For each of the 60,000 visual vertices we do four scalar multiplications and additions — no constraints, no matrix solves, no iteration. The cost is proportional to the visual vertex count, not the simulation vertex count, and the constant factor is very small. Vertex normals are recomputed from the new positions, which is necessary for correct shading.

---

## The Performance Argument

The physics simulation scales roughly as O(T · S) per frame, where T is the number of tetrahedra and S is the number of solver substeps. Replacing 300,000 tetrahedra with 3,000 is a 100x reduction in T, which translates directly to a 100x reduction in constraint solve time — the dominant cost. The skinning update adds a term proportional to the visual vertex count, but this term has a very small constant: it is data-parallel, cache-friendly, and requires no synchronization.

Crucially, the coarse mesh still captures all the large-scale deformation modes of the object. The visual mesh rides along faithfully because the barycentric interpolation is linear — it respects rigid-body motion exactly, so a rotating or translating tet produces exactly the correct motion in every attached visual vertex. Stretching and shear are also captured exactly. The only motions the coarse mesh cannot represent are high-frequency surface ripples with wavelengths smaller than the tet spacing, but for a soft body those modes are not dynamically interesting — they would either be filtered out by material stiffness or would require an unrealistically stiff constraint to resolve.

The same simulation framework from Chapter 10 (XPBD soft bodies) operates unchanged underneath. The coarse mesh benefits from the same unbreakable, substep-based integration — the skinning layer is purely a rendering concern and has no effect on simulation stability.

---

## Practical Setup

The workflow in practice:

1. Start with the high-resolution visual mesh (the asset as authored, with full detail).
2. Decimate it to a low-polygon proxy (roughly 100x fewer triangles). Feature-aware decimation tools preserve sharp edges and important silhouettes.
3. Tetrahedralize the proxy to produce the simulation mesh. Chapter 13 covers this step.
4. At application startup, call `computeSkinningInfo` to attach every visual vertex to its nearest tet and store the barycentric coordinates.
5. Each frame: run the physics on the coarse mesh, then call `updateVisMesh` to push the result to the GPU.

The attachment computation is fast enough to run at startup without a noticeable load time even for large meshes, because the spatial hash bounds the work to a small neighborhood per tet rather than a global search.

---

## Key Takeaways

- **Decouple physics from rendering.** The simulation mesh and the render mesh serve different purposes. The simulation mesh must be compatible with the physics solver; the render mesh must look good. There is no reason they must be the same.

- **Barycentric coordinates are the right tool.** They express any point as a linear combination of tet vertices, they are unique, they are invariant under affine deformation of the tet, and they generalize naturally to points outside the tet (at the cost of mild extrapolation artifacts).

- **Attachment is a one-time precomputation.** Using a spatial hash, every visual vertex can be matched to its best tetrahedron in time proportional to the total number of visual vertices plus the number of tets, with a small constant. This is fast enough to absorb at scene load time.

- **The per-frame skinning update is trivially cheap.** Four multiplies and adds per visual vertex, no branch, no iteration. On modern hardware this is memory-bandwidth-limited, not compute-limited.

- **100x is not an exaggeration.** Dropping from 300,000 to 3,000 simulation tetrahedra reduces solver time by that factor, and the overhead of the skinning pass does not come close to recovering it. The same visual quality is maintained because soft-body dynamics do not excite the high-frequency modes that the coarse mesh omits.
