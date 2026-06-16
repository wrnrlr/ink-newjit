# Chapter 12 — Mesh Skinning for Soft Bodies

A physically accurate soft-body simulation demands tetrahedral elements that fill the entire volume of an object. The problem is that the number of tetrahedra grows roughly in proportion to the cube of linear resolution — so a visually convincing surface mesh of 60,000 triangles produces something in the region of 300,000 tetrahedra when naively tetrahedralized. Simulating that many constrained elements in real time is impractical.

This chapter introduces a clean solution: decouple the simulation mesh from the render mesh. The physics engine works on a coarse tetrahedral mesh with perhaps 3,000 tetrahedra. The high-resolution visual surface is "skinned" to that coarse mesh — each visual vertex is expressed as a weighted combination of the surrounding simulation vertices. After each physics step, updating the full render mesh costs almost nothing.

---

## Two Paths to Complexity Reduction

When a simulation is too expensive, there are broadly two ways to reduce it without abandoning the underlying physics.

**Model reduction** decomposes the full system matrix into eigenmodes and retains only the $k$ most significant ones. This is mathematically elegant but becomes complex with collision handling and nonlinear materials.

**Surface embedding** — the approach developed here — reduces the simulation mesh directly:
1. Take the high-resolution visual mesh and decimate it to a coarser version.
2. Tetrahedralize that decimated surface to produce the coarse physics mesh.
3. For each visual vertex, compute how to reconstruct its position from the surrounding tet vertices.

Step 3 is what this chapter covers. Once the embedding is computed at startup, the per-frame skinning update is a simple weighted sum requiring no physics at all.

---

## Barycentric Coordinates

The embedding is built on **barycentric coordinates**. Given a tetrahedron with four vertices $\mathbf{p}_1, \mathbf{p}_2, \mathbf{p}_3, \mathbf{p}_4$, any point $\mathbf{v}$ in space can be written as:

$$\mathbf{v} = b_1 \mathbf{p}_1 + b_2 \mathbf{p}_2 + b_3 \mathbf{p}_3 + b_4 \mathbf{p}_4, \qquad b_1 + b_2 + b_3 + b_4 = 1$$

The four scalars $b_1, \ldots, b_4$ are the barycentric coordinates of $\mathbf{v}$. When all four are non-negative, $\mathbf{v}$ lies inside the tetrahedron. When some are negative, $\mathbf{v}$ is outside but the interpolation still works — it extrapolates from the nearest tet.

The key property for skinning: as the simulation deforms the tet — stretching it, rotating it, squashing it — the visual vertex follows automatically, reconstructed from the same weighted sum applied to the deformed tet vertices.

### Computing the Coordinates

To solve for $b_1, b_2, b_3, b_4$ given the tet vertices and a visual vertex $\mathbf{v}$, subtract $\mathbf{p}_4$ from all points to eliminate $b_4$ from the equation:

$$\mathbf{v} - \mathbf{p}_4 = b_1(\mathbf{p}_1 - \mathbf{p}_4) + b_2(\mathbf{p}_2 - \mathbf{p}_4) + b_3(\mathbf{p}_3 - \mathbf{p}_4)$$

Define the $3 \times 3$ matrix $P$ whose columns are the three edge vectors from $\mathbf{p}_4$:

$$P = [\mathbf{p}_1 - \mathbf{p}_4, \; \mathbf{p}_2 - \mathbf{p}_4, \; \mathbf{p}_3 - \mathbf{p}_4]$$

The first three coordinates follow directly by matrix inversion:

$$[b_1, b_2, b_3]^T = P^{-1}(\mathbf{v} - \mathbf{p}_4), \qquad b_4 = 1 - b_1 - b_2 - b_3$$

This is cheap: one $3 \times 3$ inverse per tetrahedron (computed once at startup) and one matrix-vector multiply per candidate visual vertex.

In ink, using the `mat3x3vec` and 3×3 inverse from `lib/lin.k` or `lib/svd.k`:

```k
/ Compute barycentric coordinates of v in tet (p1,p2,p3,p4)
/ Returns (b1,b2,b3,b4); b4 = 1 - b1 - b2 - b3
baryCoords: {[v;p1;p2;p3;p4]
  / Build P matrix: columns are edge vectors from p4
  P: (p1-p4; p2-p4; p3-p4)
  / Solve P * b = (v - p4) using PLU from lib/lin.k
  b3: pluSolve[P; v-p4]
  b4: 1. - (b3@0) - ((b3@1) + b3@2)
  (b3@0; b3@1; b3@2; b4)
}
```

### Barycentric Distance

Visual vertices do not always fall neatly inside one of the tets. To handle exterior vertices gracefully, define a **barycentric distance** from a point to a tetrahedron:

$$d = \max(-b_1, -b_2, -b_3, -b_4)$$

When $\mathbf{v}$ is inside the tet, all $b_i \geq 0$ and $d \leq 0$. When outside, $d > 0$ measures how far outside. Attaching each visual vertex to the tetrahedron with the smallest $d$ gives the best possible skinning for every vertex.

```k
/ Barycentric distance (>0 means outside)
baryDist: {[b] |/ neg b}    / max of negated coordinates
```

---

## Computing the Skinning Attachment

Before simulation begins, every visual vertex is matched to its best tetrahedron. The algorithm uses a spatial hash (from Chapter 11) to avoid an O(V·T) brute-force search.

For each tetrahedron:
1. Compute the bounding sphere of the tet plus a small border.
2. Query the spatial hash for all visual vertices within that sphere.
3. For each candidate, compute barycentric coordinates and store if this tet improves the attachment.

```k
/ Compute skinning info: for each visual vertex, find best tet and bary coords
/ visPos: flat visual positions; tetPos: sim positions; tetIds: tet index list
computeSkinning: {[visPos;nVis;tetPos;tetIds;h;ts]
  / Build spatial hash of visual vertices
  buildHash[visPos;nVis;h;ts]

  / For each visual vertex: initial attachment = (tetIdx=-1; dist=inf)
  skinInfo: nVis # , (-1; 0. 0. 0. 0.)   / (tetIdx; b1 b2 b3 b4)
  bestDist: nVis # 0w                     / initial dist = infinity

  {[ti]
    t: tetIds@ti
    p1:tetPos@(t@0); p2:tetPos@(t@1); p3:tetPos@(t@2); p4:tetPos@(t@3)
    / Tet center and bounding radius
    ctr: (p1+p2+p3+p4)%4.
    rMax: 0.05 + |/ {sqrt +/ x*x}' (p1-ctr; p2-ctr; p3-ctr; p4-ctr)
    / Query visual vertices near this tet
    candidates: ?queryNeighbors[visPos;0;rMax;h;ts]  / using tet center
    / Check each candidate
    {[vi]
      v: visPos@vi    / this would need separate 3D position extraction
      b: baryCoords[v;p1;p2;p3;p4]
      d: baryDist[b]
      / Update if this tet is better
      bestDist:: $[d < bestDist@vi; @[bestDist;vi;:;d]; bestDist]
      skinInfo:: $[d < bestDist@vi; @[skinInfo;vi;:;(ti;b)]; skinInfo]
    }' candidates
  }' !#tetIds

  skinInfo
}
```

---

## Per-Frame Skinning Update

Once the skinning attachment is computed, updating the visual mesh after each simulation step is a pure weighted sum — one of the cheapest operations in the entire pipeline:

```k
/ Update visual positions from current sim positions (vectorized per visual vertex)
/ skinInfo: list of (tetIdx; b1 b2 b3 b4) per visual vertex
/ tetPos: current simulation positions (list of 3-vectors)
/ tetIds: list of (v1 v2 v3 v4) per tet

updateVisMesh: {[skinInfo;tetPos;tetIds]
  {[si]
    ti: si@0; b: si@1     / tet index and barycentric coords
    $[ti<0; 0. 0. 0.;     / unattached vertex: leave at origin
      [t: tetIds@ti
       p1:tetPos@(t@0); p2:tetPos@(t@1); p3:tetPos@(t@2); p4:tetPos@(t@3)
       (p1*(b@0)) + (p2*(b@1)) + (p3*(b@2)) + p4*(b@3)]]
  }' skinInfo
}
```

The inner expression `(p1*(b@0)) + (p2*(b@1)) + (p3*(b@2)) + p4*(b@3)` is the weighted sum of four 3-vectors — the barycentric reconstruction. The extra parens around `(p1*(b@0))` etc. protect the products from right-to-left mis-association.

For 60,000 visual vertices, this update costs roughly four multiplications and additions per vertex — a trivial cost compared to the constraint solve.

---

## The Performance Argument

The physics simulation scales as O(T × S) per frame, where T is the number of tetrahedra and S is the substep count. Replacing 300,000 tetrahedra with 3,000 is a 100x reduction in T, directly reducing the constraint solve time by 100x. The skinning update adds a term proportional to the visual vertex count, but its constant factor is tiny: data-parallel, cache-friendly, no synchronization.

The coarse mesh captures all large-scale deformation modes. The visual mesh rides along faithfully because barycentric interpolation is linear — it respects rigid-body motion exactly, so a rotating or translating tet produces exactly the correct motion in every attached visual vertex. Stretching and shear are captured exactly. The only modes the coarse mesh cannot represent are high-frequency surface ripples with wavelengths smaller than the tet spacing — those modes are not dynamically interesting for a bulk elastic material.

---

## Practical Workflow

1. Create or import a high-resolution visual mesh.
2. Decimate it (Blender: Mesh → Decimate modifier) to a coarser surface.
3. Tetrahedralize the decimated surface using the Blender plugin from Chapter 13.
4. Export both meshes (positions + tetrahedral connectivity).
5. At startup: call `computeSkinning` once to bind visual vertices to tets.
6. Each frame: run XPBD soft body (Chapter 10), then call `updateVisMesh`.

---

## Key Takeaways

- **Decouple simulation from rendering.** Run physics on a coarse tet mesh (hundreds or thousands of tets); render with a fine visual mesh (tens of thousands of triangles).
- **Barycentric coordinates** express each visual vertex as a weighted combination of its host tet's four vertices. The weights are constant in the material frame — they do not change as the object deforms.
- **Barycentric distance** $\max(-b_i)$ measures how far a point is outside a tet. Attach each visual vertex to the tet that minimizes this distance.
- **The skinning update** is a pure weighted sum: four scalar multiplications and additions per visual vertex, with no physics.
- **100x speedup** from using a coarse tet mesh vs a fine one, with no perceptible loss of visual quality for bulk elastic deformation modes.
