# Chapter 13 — From Surface to Volume: Writing a Tetrahedralizer

Soft-body simulation operates on volumes, not surfaces. A cloth drapes across a surface; a jelly cube squashes through its entire bulk. To simulate that bulk behavior faithfully, you need to fill the interior of a 3D object with a mesh of tetrahedra — the simplest convex polyhedra in three dimensions, analogous to triangles in 2D. This chapter builds a Blender plugin that takes any closed triangle-surface mesh and converts it into a tetrahedral volume mesh, ready for the soft-body solver developed in the preceding chapters. The algorithm used is incremental Delaunay tetrahedralization, implemented from scratch in Python and wired into Blender's add-on system so that the operation appears as a standard menu item.

---

## Why Tetrahedra?

A tetrahedron has four triangular faces, four vertices, and six edges. Every interior point of a convex object can be expressed as a weighted combination of the four corner vertices of the tetrahedron that contains it — this is called the barycentric coordinate of the point with respect to that tetrahedron. In a soft-body solver, the deformation of each tetrahedron is what drives the elastic forces that make the object resist compression and shear. Because the barycentric coordinates of an embedded point do not change when the mesh deforms, the high-resolution visual mesh from chapter 12 can be skinned onto the coarser tet mesh without ever revisiting the binding step.

A surface mesh carries no notion of interior. It is a shell. To simulate volumetric deformation, you need to decompose the interior into tetrahedra that share the vertices of the surface, then integrate elastic energy over those elements. This is the foundational preprocessing step for any finite-element soft-body solver.

---

## The Delaunay Condition

Not all tetrahedral decompositions of a point set are equal. A decomposition that produces long, flat, needle-like tetrahedra leads to poorly conditioned stiffness matrices and visible simulation artifacts. The **Delaunay mesh** is the canonical high-quality triangulation of a point set in any number of dimensions.

A mesh is a Delaunay mesh if the circumsphere of every tetrahedron contains only its four corner vertices — no other point in the mesh lies strictly inside. In 2D the equivalent statement is that the circumcircle of every triangle contains no other point. A Delaunay mesh maximizes the minimum angle of all its elements, which is exactly what you want for numerical stability.

When a tetrahedron fails the Delaunay condition — some other vertex has crept inside its circumsphere — it is said to be *violating*. The incremental algorithm continually repairs these violations as it inserts new points.

---

## Incremental Tetrahedralization

The incremental Delaunay algorithm builds the tet mesh one vertex at a time:

1. Construct a single large *super-tetrahedron* whose four vertices enclose all of the input vertices.
2. For each input vertex, find the tetrahedron that contains it.
3. Flood-fill outward from the containing tetrahedron to identify every neighboring tet whose circumsphere now contains the new point — the violating set.
4. Remove all violating tetrahedra. Their removal opens a star-shaped void in the mesh.
5. Fill the void by connecting each boundary face of the void to the new point, creating a fan of new tetrahedra.
6. Repair adjacency bookkeeping.
7. After all vertices are inserted, discard any tetrahedron that touches the original super-tetrahedron vertices, or whose centroid lies outside the input surface, or whose quality is below a minimum threshold.

The algorithm is elegant because the invariant it maintains — the Delaunay condition — is local. Checking whether a new point violates the circumsphere of a neighboring tet is a single dot-product test, and the set of violating tetrahedra is always connected, so a simple flood fill is sufficient to find all of them.

### Finding the Containing Tetrahedron

A naive search over all tetrahedra would make the whole algorithm quadratic in the number of vertices. The fast alternative is a ray walk:

1. Start from any known non-deleted tetrahedron (or better, the one found for the previous point — nearby points tend to land in the same neighborhood).
2. Compute the center of the current tetrahedron.
3. Cast a ray from the center toward the new point and determine which of the four faces it exits through.
4. Cross that face to the adjacent tetrahedron and repeat.

The walk terminates when the new point is found to lie inside the current tetrahedron — that is, when the parametric intersection time along the ray is greater than or equal to one. Because consecutive input vertices are often spatially coherent, the walk typically takes only one or two steps.

```python
while not found:
    center = (verts[id0] + verts[id1] + verts[id2] + verts[id3]) * 0.25

    minT = float('inf')
    minFaceNr = -1

    for j in range(4):
        n  = planesN[4 * tetNr + j]
        d  = planesD[4 * tetNr + j]
        hp = n.dot(p) - d       # signed distance: new point to face plane
        hc = n.dot(center) - d  # signed distance: tet center to face plane
        t  = hp - hc
        if t == 0:
            continue
        t = -hc / t             # parameter where ray center->p hits the plane
        if t >= 0.0 and t < minT:
            minT = t
            minFaceNr = j

    if minT >= 1.0:
        found = True            # p is inside this tet
    else:
        tetNr = neighbors[4 * tetNr + minFaceNr]
```

### Flood-Fill for Violating Tetrahedra

Once the containing tetrahedron is found, the flood fill is a standard breadth-first (or depth-first) traversal of the tet adjacency graph, stopping whenever a neighbor's circumsphere does not contain the new point:

```python
stack = [tetNr]
violatingTets = []

while stack:
    t = stack.pop()
    if already_visited(t):
        continue
    mark_visited(t)
    violatingTets.append(t)

    for each neighbor n of t:
        c = getCircumCenter(verts[n.id0], verts[n.id1], verts[n.id2], verts[n.id3])
        r = (verts[n.id0] - c).magnitude
        if (p - c).magnitude < r:   # p is inside the circumsphere
            stack.append(n)
```

### Filling the Void

After collecting all violating tetrahedra, the algorithm iterates over them. For each face of a violating tet that borders a non-violating tet (or the boundary of the mesh), a new tetrahedron is created by connecting that face to the new point. At the end of the insertion step, adjacency between the newly created tetrahedra is repaired by sorting their shared edges and pairing them up.

---

## Two Problems with the Raw Result

Running the algorithm to completion produces a valid Delaunay tetrahedralization of the point set, but two issues remain before it is useful for simulation.

**Problem 1: Too many tetrahedra.** The algorithm fills the bounding super-tetrahedron, not just the object's interior. The solution is simple: after insertion, discard any tetrahedron whose centroid lies outside the original surface mesh.

**Problem 2: Non-conforming surface.** There is no guarantee that the faces of the tet mesh align with the triangles of the input surface. This *constrained Delaunay* problem is genuinely hard — a large body of research addresses it — and it is not solved here. The practical workaround is to keep both the tetrahedral connectivity and the original surface triangle indices. The surface triangles drive collision detection. Visual mesh embedding (chapter 12) still works correctly even when some surface vertices are not exactly shared by the tet mesh, because barycentric coordinates can be computed for any point inside any tetrahedron.

---

## Inside-Outside Testing

The inside test for a centroid uses ray casting against the surface mesh. For each candidate tet centroid, fire a ray in a canonical axis direction and check whether the closest intersection normal points in the same direction as the ray. If it does, the centroid is inside the surface (the normal faces outward, so agreement with the outgoing ray direction means you are looking out from inside). To make this robust against degenerate geometry, fire all six axis-aligned rays and use a majority vote:

```python
dirs = [
    Vector(( 1, 0, 0)), Vector((-1, 0, 0)),
    Vector(( 0, 1, 0)), Vector(( 0,-1, 0)),
    Vector(( 0, 0, 1)), Vector(( 0, 0,-1)),
]

def isInside(tree, p, minDist=0.0):
    numIn = 0
    for d in dirs:
        location, normal, index, distance = tree.ray_cast(p, d)
        if normal:
            if normal.dot(d) > 0.0:
                numIn += 1
            if minDist > 0.0 and distance < minDist:
                return False
    return numIn > 3
```

The `minDist` parameter serves a second purpose: when sampling interior points from a regular grid, a point that lies too close to the surface will produce numerically unreliable tetrahedra. Discarding any grid point within half a grid cell of the surface keeps the interior sampling clean.

---

## Tet Quality

Even with the Delaunay condition enforced, some tetrahedra in the final mesh may be nearly degenerate — very thin slivers with almost zero volume. These are numerically problematic in a solver and visually unattractive. The quality metric used here normalizes the volume of a tetrahedron by the cube of its root-mean-square edge length:

```python
def tetQuality(p0, p1, p2, p3):
    # six edge vectors
    d0, d1, d2 = p1-p0, p2-p0, p3-p0
    d3, d4, d5 = p2-p1, p3-p2, p1-p3

    ms  = (d0.length**2 + d1.length**2 + d2.length**2 +
           d3.length**2 + d4.length**2 + d5.length**2) / 6.0
    rms = math.sqrt(ms)

    vol = d0.dot(d1.cross(d2)) / 6.0
    return (12.0 / math.sqrt(2.0)) * vol / rms**3
    # returns 1.0 for a perfect regular tetrahedron
```

The result ranges from 0 (degenerate) to 1 (perfect regular tetrahedron). Any tet below the user-specified minimum quality threshold is dropped before the mesh is exported.

---

## Interior Sampling

The surface vertices alone may not provide enough points to fill the interior with well-shaped tetrahedra, especially for thick objects. The plugin optionally seeds additional points on a regular grid inside the bounding box. Each candidate grid point is tested with `isInside` before it is added to the vertex list:

```python
if resolution > 0:
    h = max(bmax - bmin) / resolution
    for xi in range(...):
        for yi in range(...):
            for zi in range(...):
                p = bmin + Vector(xi, yi, zi) * h + jitter()
                if isInside(tree, p, minDist=0.5*h):
                    tetVerts.append(p)
```

A small random jitter is added to each grid point. This breaks the exact symmetry that can cause the Delaunay algorithm to encounter degenerate configurations where four or more points are co-spherical.

---

## The Blender Plugin

The plugin is registered as a standard Blender add-on. Once installed, it adds a *Add Tetrahedralization* entry to the `Add > Mesh` menu. Clicking it reads the currently selected object, runs the tetrahedralization, and creates a new mesh object in the scene.

The plugin offers four parameters:

- **Interior resolution** — number of grid divisions along the longest axis when seeding interior points. Zero disables interior sampling.
- **Min Tet Quality Exp** — minimum acceptable tet quality as a power of ten (e.g. −3 means 0.001). Tets below this threshold are discarded.
- **One Face Per Tet** — when enabled, each tetrahedron is represented as a single non-planar quad face in the Blender mesh. This is the most compact export format and the one expected by the soft-body solver. When disabled, each tet is shown as four triangular faces, which gives a clearer visual impression of the mesh structure.
- **Tet Scale** — when showing four faces per tet, scales each tet inward from its centroid so the tetrahedra appear as separate solids.

The registration boilerplate follows the standard Blender pattern:

```python
class Tetrahedralizer(bpy.types.Operator, AddObjectHelper):
    bl_idname  = "mesh.primitive_add_tets"
    bl_label   = "Add Tetrahedralization"
    bl_options = {'REGISTER', 'UNDO'}

    resolution:    IntProperty(name="Interior resolution", min=0, max=100, default=10)
    minQualityExp: IntProperty(name="Min Tet Quality Exp", min=-4, max=0, default=-3)
    oneFacePerTet: BoolProperty(name="One Face Per Tet", default=True)
    tetScale:      FloatProperty(name="Tet Scale", min=0.1, max=1.0, default=0.8)

    def execute(self, context):
        tetMesh = createTets(
            self.resolution,
            math.pow(10.0, self.minQualityExp),
            self.oneFacePerTet,
            self.tetScale
        )
        object_utils.object_data_add(context, tetMesh, operator=self)
        return {'FINISHED'}
```

The output mesh, when exported in one-face-per-tet mode, encodes the tetrahedral connectivity entirely in the quad faces: each quad's four vertex indices are the four vertices of one tetrahedron. The soft-body solver reads these indices directly.

---

## Using the Tet Mesh in Simulation

Once you have the tetrahedral mesh, the soft-body pipeline from chapters 10–12 can be applied directly. Each tetrahedron contributes elastic forces that resist changes in volume and shape. The skinning system from chapter 12 maps the high-resolution visual mesh onto the coarser tet mesh by computing barycentric coordinates for each visual vertex at rest, then interpolating from the deformed tet mesh at runtime.

The key insight is that the tet mesh does not need to be conforming — it does not need to reproduce the original surface triangles exactly. Collision detection uses the original surface mesh, which is independent of the tet connectivity. The tet mesh handles only the volumetric deformation. This separation of concerns allows both meshes to be tuned independently: a coarser tet mesh runs faster; a finer visual mesh looks better.

---

## Key Takeaways

- **Tetrahedral meshes are volumetric.** Surface meshes model shells; tet meshes model the full interior needed for finite-element elastic simulation.
- **The Delaunay condition** — no point lies inside the circumsphere of any tetrahedron — maximizes element quality by maximizing the minimum dihedral angle. It is enforced locally at every vertex insertion.
- **Incremental insertion** adds one vertex at a time, locates the containing tet via a ray walk, finds all violating tets via flood fill, removes them, and fills the resulting void with a fan of new tets centered at the new point.
- **Inside-outside testing** uses six axis-aligned ray casts against a BVH of the input surface and returns the majority vote, making it robust against near-degenerate surface geometry.
- **Interior sampling** on a jittered regular grid improves tet quality for thick objects, where the surface vertices alone are too sparse to produce well-shaped tetrahedra in the interior.
- **Non-conforming surfaces are acceptable.** Collision detection can use the original surface mesh independently of the tet connectivity, so the constraint that tet faces must match input triangles can be dropped without loss of simulation correctness.
- **Tet quality filtering** discards nearly degenerate elements before simulation, keeping the stiffness matrices well-conditioned and preventing solver instability.
