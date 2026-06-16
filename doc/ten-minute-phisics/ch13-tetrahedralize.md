# Chapter 13 — From Surface to Volume: Tetrahedralization

Soft-body simulation operates on volumes, not surfaces. A cloth drapes across a surface; a jelly cube squashes through its entire bulk. To simulate that bulk behavior faithfully, the interior of a 3D object must be filled with tetrahedra — the simplest convex polyhedra in 3D, analogous to triangles in 2D.

This chapter describes the incremental Delaunay tetrahedralization algorithm that converts any closed triangle-surface mesh into a tetrahedral volume mesh. The reference implementation is a Blender add-on written in Python; the chapter focuses on the algorithm so that the concepts are clear whether you use the Blender plugin, an external tool like TetGen, or roll your own.

---

## Why Tetrahedra?

A tetrahedron has four triangular faces, four vertices, and six edges. Every interior point can be expressed as a weighted combination of the four corner vertices — the **barycentric coordinates** of that point. In a soft-body solver, the deformation of each tetrahedron drives elastic forces. Because barycentric coordinates do not change when the mesh deforms, the high-resolution visual mesh from Chapter 12 can be skinned onto the coarser tet mesh without revisiting the binding step at runtime.

A surface mesh is a shell. To simulate volumetric deformation, you decompose the interior into tetrahedra that share the surface vertices, then integrate elastic energy over those elements. This is the foundational preprocessing step for any finite-element soft-body solver.

---

## The Delaunay Condition

Not all tetrahedral decompositions of a point set are equal. Long, flat needle-like tetrahedra lead to poorly conditioned solvers and visible artifacts. The **Delaunay mesh** is the canonical high-quality triangulation of a point set in any dimension.

A mesh is a Delaunay mesh if the circumsphere of every tetrahedron contains no other point in the mesh strictly inside. In 2D the equivalent is that the circumcircle of every triangle is empty of other points. A Delaunay mesh maximizes the minimum angle across all elements — exactly what you want for numerical stability.

When a tetrahedron fails the Delaunay condition — some other vertex has crept inside its circumsphere — it is *violating*. The incremental algorithm continually repairs these violations as it inserts new points.

### Circumsphere Test

The circumsphere test is the inner loop of the algorithm. Given four tet vertices $\mathbf{p}_1, \ldots, \mathbf{p}_4$ and a candidate point $\mathbf{q}$, construct the matrix:

$$M = \begin{bmatrix}
  p_1 - q & |p_1 - q|^2 \\
  p_2 - q & |p_2 - q|^2 \\
  p_3 - q & |p_3 - q|^2 \\
  p_4 - q & |p_4 - q|^2
\end{bmatrix}$$

If $\det(M) > 0$ (for a positively-oriented tet), then $\mathbf{q}$ lies inside the circumsphere. The sign of the determinant is all that matters, so no floating-point division is required.

---

## Incremental Tetrahedralization

The algorithm builds the tet mesh one vertex at a time:

1. Construct a single large **super-tetrahedron** whose four vertices enclose all input vertices.
2. For each input vertex: find the tet that contains it (via a ray walk), flood-fill outward to find all tets whose circumspheres contain the new point (the violating set), remove all violating tets (leaving a star-shaped void), fill the void by connecting each boundary face to the new point, and repair adjacency.
3. After all vertices are inserted, discard any tet that touches the super-tetrahedron vertices, whose centroid lies outside the surface, or whose quality is below a minimum threshold.

The algorithm is elegant because the Delaunay invariant is **local**: checking whether a new point violates a tet's circumsphere is one determinant evaluation, and the violating set is always connected so a simple flood fill finds all violating tets.

### Finding the Containing Tet

A naive search over all tets is quadratic. The fast alternative is a **ray walk**:

1. Start from any known non-deleted tet (or the one found for the previous point — consecutive points tend to land nearby).
2. For each of the four faces, compute where the ray from the tet center to the new point hits the face plane.
3. Follow the face with the smallest positive intersection parameter $t$ into the neighboring tet.
4. Stop when $t \geq 1$ — the new point is inside the current tet.

### Void Filling

After collecting all violating tetrahedra, iterate over them. For each face of a violating tet that borders a non-violating tet (or the mesh boundary), create a new tet by connecting that face to the new point. Repair adjacency between the new tets by sorting their shared faces.

---

## Tet Quality

Even with the Delaunay condition enforced, some tets can be nearly degenerate — thin slivers with almost zero volume. The quality metric normalizes volume by the cube of the root-mean-square edge length:

$$Q = \frac{12}{\sqrt{2}} \cdot \frac{V}{\ell_\text{rms}^3}$$

A perfect regular tetrahedron has $Q = 1$. Degenerate tets approach 0.

```k
/ Tet quality metric: 1.0 for regular tet, 0.0 for degenerate
/ p1..p4: 3-vectors
tetQuality: {[p1;p2;p3;p4]
  / Six edge vectors
  d0:p2-p1; d1:p3-p1; d2:p4-p1
  d3:p3-p2; d4:p4-p3; d5:p1-p4
  / Mean square edge length
  ms: (+/d0*d0 + d1*d1 + d2*d2 + d3*d3 + d4*d4 + d5*d5) % 6.
  rms: sqrt ms
  vol: (dot3[cross3[d0;d1];d2]) % 6.
  (12. % sqrt 2.) * vol % rms*rms*rms
}
```

Verify on a regular tet with edge length 1 (vertices at `(0,0,0)`, `(1,0,0)`, `(0.5,sqrt(3)/2,0)`, `(0.5,sqrt(3)/6,sqrt(6)/3)`):

```k
p1: 0. 0. 0.
p2: 1. 0. 0.
p3: 0.5 0.8660 0.
p4: 0.5 0.2887 0.8165
tetQuality[p1;p2;p3;p4]  / → ~1.0
```

Tets below the minimum quality threshold (typically 0.001) are discarded before simulation.

---

## Inside-Outside Testing

Running the algorithm to completion produces a valid Delaunay tetrahedralization of the bounding super-tet, not just the object's interior. Discarding exterior tets requires an **inside-outside test** for each tet centroid.

The test uses ray casting against the input surface mesh. Fire a ray from the centroid in a canonical direction; if the nearest intersection normal points in the same direction as the ray, the point is inside (the normal faces outward, agreeing with an outgoing ray from inside). A single ray is unreliable near degenerate geometry, so fire all six axis-aligned rays and use majority vote:

```k
/ Inside-outside test for point p against surface triangle mesh
/ tris: list of triangles (p1,p2,p3); returns 1 if inside, 0 if outside
isInside: {[tris;p]
  dirs: (1. 0. 0.; -1. 0. 0.; 0. 1. 0.; 0. -1. 0.; 0. 0. 1.; 0. 0. -1.)
  numIn: +/ {[d]
    / Find nearest triangle hit in direction d
    ts: {[tri]
      n: cross3[tri@1 - tri@0; tri@2 - tri@0]
      nd: dot3[n;d]
      $[nd=0.; 0w;
        [t: dot3[n; tri@0 - p] % nd
         $[t>0.; t; 0w]]]
    }' tris
    minT: &/ts; idx: ts?minT
    $[minT=0w; 0;
      [tri: tris@idx
       n: cross3[tri@1 - tri@0; tri@2 - tri@0]
       $[dot3[n;d]>0.; 1; 0]]]
  }' dirs
  numIn > 3
}
```

The majority vote (more than 3 of 6 rays agree) makes the test robust against edge-grazing rays and near-degenerate surface patches.

---

## Interior Sampling

Surface vertices alone may not fill the interior with well-shaped tets, especially for thick objects. The plugin optionally seeds additional points on a jittered regular grid inside the bounding box:

1. Compute the bounding box of the surface mesh.
2. Divide it into a regular grid at spacing $h$.
3. Add a small random jitter to each grid point.
4. Keep only points that pass the inside-outside test and are at least $h/2$ from the surface.

```k
/ Generate interior sample points inside bounding box (bmin,bmax) on grid of size n
/ Returns flat float list of 3D positions
interiorSamples: {[bmin;bmax;n;tris]
  h: (|/bmax-bmin)%n
  pts: ,/ ,/ {[xi]
    ,/ {[yi]
      {[zi]
        p: bmin + h * (xi + 0.5 * (-1+2*rand 1.); yi + 0.5*(-1+2*rand 1.); zi + 0.5*(-1+2*rand 1.))
        $[isInside[tris;p]; ,p; ()]
      }' !n
    }' !n
  }' !n
  pts
}
```

The random jitter breaks the exact grid symmetry that can cause four or more points to be co-spherical — a degenerate configuration in the Delaunay algorithm.

---

## Data Format for the Soft-Body Solver

The tetrahedralization produces two arrays that feed directly into the soft-body solver from Chapters 10–12:

```k
/ Tet mesh data layout (output of tetrahedralization):
/ tetPos:  flat list of 3-vectors — one per simulation vertex
/ tetIds:  list of (v1;v2;v3;v4) index tuples — one per tetrahedron
/          (stored in Blender as quad faces in one-face-per-tet mode)

/ Extract tet mesh from Blender export (flat index arrays)
loadTetMesh: {[verts;quadFaces]
  / verts: (3n) float list of x,y,z
  / quadFaces: (4m) int list of v1,v2,v3,v4 per tet
  nVerts: (#verts)%3
  nTets: (#quadFaces)%4
  pos: {verts@(3*x + 0 1 2)}' !nVerts
  tetIds: {quadFaces@(4*x + 0 1 2 3)}' !nTets
  (pos; tetIds)
}
```

The Blender plugin's "One Face Per Tet" mode encodes tetrahedral connectivity as quad faces: each quad's four vertex indices are the four vertices of one tetrahedron. This is the most compact export format and is read directly by `buildSoftBody` from Chapter 10.

---

## Non-Conforming Surfaces Are Acceptable

There is no guarantee that the tet mesh faces align with the triangles of the input surface — the **constrained Delaunay** problem is genuinely hard. The practical workaround: keep both meshes and use them for different purposes.

- **Collision detection** uses the original surface triangles (independent of tet connectivity).
- **Elastic simulation** uses the tet mesh (independent of surface triangle layout).
- **Visual skinning** uses barycentric coordinates from the tet mesh to reconstruct visual vertex positions.

This separation of concerns allows both meshes to be tuned independently: a coarser tet mesh runs faster; a finer visual mesh looks better.

---

## Practical Workflow

1. Import or create a closed surface mesh in Blender.
2. Decimate to the desired coarseness (Mesh → Decimate modifier).
3. Install the tetrahedralization add-on and run *Add → Mesh → Add Tetrahedralization*.
4. Export the resulting mesh as a flat vertex/face array.
5. Load into ink with `loadTetMesh` and build the soft body with `buildSoftBody` from Chapter 10.

---

## Key Takeaways

- **Tet meshes are volumetric.** Surface meshes model shells; tet meshes model the full interior needed for finite-element elastic simulation.
- **The Delaunay condition** — no point lies inside the circumsphere of any tet — maximizes element quality by maximizing the minimum dihedral angle. It is enforced locally at every vertex insertion.
- **Incremental insertion** adds one vertex at a time: locate the containing tet via ray walk, find violating tets via flood fill, remove them, fill the star-shaped void with a new tet fan.
- **Inside-outside testing** uses six axis-aligned ray casts against the input surface and returns the majority vote, making it robust against near-degenerate geometry.
- **Interior sampling** on a jittered regular grid improves tet quality for thick objects where surface vertices are too sparse.
- **Tet quality** $Q = (12/\sqrt{2}) \cdot V / \ell_\text{rms}^3$ ranges from 0 (degenerate) to 1 (perfect regular tet). Filter out tets below a threshold (typically 0.001) before simulation.
- **Non-conforming surfaces are acceptable.** Collision detection and visual skinning use the original surface mesh independently of tet connectivity.
