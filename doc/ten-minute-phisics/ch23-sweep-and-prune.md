# Chapter 23 — Broad Phase Collision Detection with Sweep and Prune

A physics simulation with a few dozen objects can afford to test every pair for collision on every frame — the brute-force approach is simple, correct, and fast enough. Scale the scene to ten thousand objects and the arithmetic changes dramatically: the number of pairs grows as $\frac{n(n-1)}{2}$, so ten thousand objects produce roughly fifty million candidate pairs per frame. Even when each individual test is cheap, fifty million of them is not. This chapter addresses that problem with **Sweep and Prune (SAP)**, one of the oldest and most practical broad-phase algorithms in collision detection. The core idea is beautifully simple: sort the objects along one axis, and use that order to skip enormous numbers of tests that could never produce a collision.

---

## The Two-Phase Approach to Collision Detection

Collision detection is conventionally split into two phases that operate at very different levels of geometric precision.

The **broad phase** works with simplified stand-ins for the real objects. For each body in the scene we compute an **axis-aligned bounding box (AABB)** — the smallest box with sides parallel to the coordinate axes that contains the object completely. Two objects cannot be colliding unless their AABBs overlap, so the broad phase produces a list of *candidate pairs*: pairs whose bounding boxes do overlap. This test is fast and conservative. Conservative means it may admit pairs that are not actually colliding, but it never misses a pair that is.

The **narrow phase** then takes only those candidate pairs and subjects them to a precise, geometry-aware test. For a scene of spheres this test is a single distance comparison. For meshes it may involve GJK, EPA, or separating-axis tests. The narrow phase can be expensive per pair, but if the broad phase has done its job, the number of pairs it must process is small.

The division of labor is what makes large scenes tractable. The broad phase processes every object but does almost no work per object. The narrow phase does real work but sees only a tiny fraction of all pairs.

---

## Why Brute Force Fails at Scale

The naive broad phase simply tests every pair of AABBs:

```javascript
function bruteForceCollisions(spheres) {
    for (let i = 0; i < spheres.length; i++) {
        for (let j = i + 1; j < spheres.length; j++) {
            solveCollision(spheres[i], spheres[j]);
        }
    }
}
```

For $n$ objects this performs $\frac{n(n-1)}{2}$ tests, which is $O(n^2)$. The numbers are sobering:

| Objects $n$ | Pairs tested |
|-------------|-------------|
| 100 | 4,950 |
| 1,000 | 499,500 |
| 10,000 | 49,995,000 |

At 10,000 objects we are testing fifty million pairs per frame. Even if each test costs only a few nanoseconds the cumulative cost dominates the simulation. A faster approach is not a luxury — it is a requirement.

---

## Sweep and Prune

Sweep and Prune exploits a simple geometric fact: if two AABBs do not overlap along any one axis, they cannot overlap in 3D space. We can therefore use a single axis as an early rejection filter.

**Choose a sweep axis.** Project every AABB onto one axis — conventionally the $x$-axis, though choosing the axis along which the scene extent is greatest tends to maximize the number of early rejections. Along this axis each box defines an interval $[\ell_i,\, r_i]$, where $\ell_i$ is the left (minimum) coordinate of box $i$ and $r_i$ is its right (maximum) coordinate.

**Sort by left edge.** Arrange the boxes in ascending order of $\ell_i$. Call this the *sorted list*.

**Sweep through the sorted list.** For each box $i$, scan forward through boxes $j > i$ in sorted order. Because the list is sorted by left edge, $\ell_j \geq \ell_i$ for all $j > i$. The moment we find a box $j$ for which $\ell_j > r_i$, we know that box $j$ — and every box after it — starts to the right of where box $i$ ends. None of them can overlap box $i$ on the sweep axis, so we break out of the inner loop immediately.

Every pair that survives this filter has overlapping intervals on the sweep axis. That is a necessary but not sufficient condition for a true AABB overlap: we still need to verify the remaining axes (the $y$-axis in 2D, $y$ and $z$ in 3D). That check is fast and is performed inside `solveCollision`.

The complete algorithm in ten lines:

```javascript
function sweepAndPruneCollisions(bodies) {
    const sortedBodies = bodies.sort((a, b) => a.left - b.left);

    for (let i = 0; i < sortedBodies.length; i++) {
        const body1 = sortedBodies[i];

        for (let j = i + 1; j < sortedBodies.length; j++) {
            const body2 = sortedBodies[j];

            if (body2.left > body1.right)
                break;

            if (body2.bounds.overlap(body1.bounds))
                solveCollision(body1, body2);
        }
    }
}
```

The elegance here is real. The algorithm has no data structures beyond a sorted array, no hash tables, no grids. The early `break` is the entire acceleration: it turns what would be a full $O(n^2)$ inner loop into one that terminates as soon as the sweep axis separates the objects.

---

## Complexity Analysis

Sorting $n$ boxes costs $O(n \log n)$. For $n = 10{,}000$ that is roughly $10{,}000 \times 13 \approx 130{,}000$ comparisons — three orders of magnitude fewer than the brute-force fifty million.

The inner loop cost depends on the scene configuration. In the best case — all objects well separated — each inner loop terminates after one step, giving $O(n)$ total inner-loop work and an overall cost of $O(n \log n)$. In the worst case — all boxes stacked at the same position — the inner loop never breaks early and we are back to $O(n^2)$. For typical simulations, where objects are distributed across the scene and most pairs are spatially separated, the performance is close to the best case.

The dependence on configuration is worth emphasizing. SAP is not universally $O(n \log n)$: it is $O(n \log n + k)$ where $k$ is the number of overlapping pairs on the sweep axis. For a scene where every object overlaps every other object on the chosen axis, $k = O(n^2)$ and SAP offers no benefit over brute force. In practice, for scenes where objects are reasonably distributed, $k$ grows much more slowly than $n^2$.

---

## Incremental Updates for Moving Objects

Re-sorting the entire array from scratch each frame costs $O(n \log n)$ regardless of how much the objects have moved. In a simulation where objects move smoothly, the sorted order changes very little between frames — most objects stay near their previous positions in the sorted list, and only a few elements need to move. This observation motivates an incremental approach.

Instead of sorting from scratch, maintain the sorted array across frames and use **insertion sort** to repair it each step. Insertion sort is generally $O(n^2)$, but its inner loop terminates immediately when an element is already in the correct position. For nearly-sorted data — exactly the case for smoothly moving objects — insertion sort degenerates to $O(n)$: it makes one pass through the array, performs a small number of swaps near the positions that actually moved, and finishes.

A more sophisticated variant tracks events: when a left edge overtakes a right edge (a new pair begins overlapping) or a right edge falls behind a left edge (an existing pair stops overlapping), the event is enqueued for processing. This event-driven approach maintains the active set of overlapping pairs incrementally with $O(1)$ work per edge crossing, reducing the total per-frame cost to $O(n + s)$ where $s$ is the number of edge-crossing events that occurred since the last frame.

For the demo accompanying this chapter — five thousand bouncing spheres — the simpler re-sort approach is used. At that scale a full sort takes only a fraction of a millisecond and the simplicity of the implementation is worth more than the incremental optimization.

---

## Two-Axis Filtering for Spheres

The basic SAP filters on one axis and then delegates to `solveCollision` for the full overlap test. For spheres in 2D we can squeeze out a cheap second filter before reaching the more expensive distance computation. After confirming that two spheres overlap on the $x$-axis, we check whether their $y$-coordinate separation is small enough that a collision is possible:

```javascript
function sweepAndPruneCollisions(spheres) {
    const sortedSpheres = spheres.sort((a, b) => a.left - b.left);

    for (let i = 0; i < sortedSpheres.length; i++) {
        const sphere1 = sortedSpheres[i];

        for (let j = i + 1; j < sortedSpheres.length; j++) {
            const sphere2 = sortedSpheres[j];

            if (sphere2.left > sphere1.right)
                break;

            if (Math.abs(sphere1.y - sphere2.y) <= sphere1.radius + sphere2.radius)
                solveCollision(sphere1, sphere2);
        }
    }
}
```

The `Math.abs` test is a cheap axis-aligned bounding interval check on $y$. It eliminates pairs that are far apart vertically even though their $x$-projections overlap. Only pairs that pass both axis checks are forwarded to `solveCollision`, which computes the true Euclidean distance and applies the collision impulse. This layered filtering keeps the narrow-phase call count low without adding any real complexity.

---

## Sweep and Prune vs Spatial Hashing

SAP is not the only broad-phase algorithm worth knowing. **Spatial hashing** is the main alternative for dynamic scenes, and the two approaches have complementary strengths.

In spatial hashing the scene is overlaid with a regular grid of cells. Each cell is identified by its grid coordinates, which are hashed to an index in a fixed-size hash table. To find collision candidates for an object, you look up every cell that its AABB overlaps and collect all other objects stored there. Insertion and lookup both run in expected $O(1)$ time per object, giving an overall expected cost of $O(n)$ per frame — better than SAP's $O(n \log n)$ asymptotically.

The practical trade-off is less clear-cut:

- **Cell size.** Spatial hashing requires choosing a cell size. Too large, and each cell contains many objects; the number of candidate pairs explodes. Too small, and large objects span many cells; insertion and lookup become expensive. SAP requires only choosing an axis, which is trivially set to the longest dimension of the scene bounding box.

- **Distribution sensitivity.** SAP degrades when all objects cluster along the sweep axis. Spatial hashing degrades when all objects cluster in one cell. Both are sensitive to non-uniform distributions, but in different ways. For scenes with objects of varying size, SAP can be more robust because it does not require a cell-size decision.

- **Simplicity.** The SAP implementation shown in this chapter is ten lines. A correct spatial hash is longer and has more moving parts — hash function, table resizing, multi-cell object registration. The implementation cost matters, especially early in a project.

- **Cache behavior.** The sorted array in SAP has excellent cache locality: the inner loop scans forward through contiguous memory and terminates early. Spatial hashing involves pointer chasing through a hash table and can generate many cache misses in large scenes.

For most real-time simulations with objects of similar size and a reasonably uniform distribution, the two approaches perform comparably. SAP earns its place in the toolkit for being conceptually transparent, trivially implementable, and robust across a wide range of scene configurations without tuning.

---

## Choosing the Sweep Axis

One practical decision left unaddressed above is which axis to sweep along. Any axis works correctly; the choice only affects performance. The heuristic endorsed in practice is to choose the axis along which the overall scene bounding box is longest. If the scene spans 1000 units horizontally and 200 units vertically, sweeping along $x$ means that objects must travel much further before their projections can overlap, which means the early-break condition fires more often and fewer pairs enter the inner loop. When the scene is roughly isotropic, the choice matters little.

In 3D the same heuristic applies: compute the AABB of the entire scene, find the axis of maximum extent, and sort along that axis. Some implementations go further and reselect the axis each frame based on the current scene configuration, but for most simulations the axis is stable and a one-time or infrequent selection suffices.

---

## Key Takeaways

- **Broad phase before narrow phase.** Replace objects with AABBs for a fast, conservative first pass. Only forward candidate pairs to the expensive per-geometry test.

- **Brute force is $O(n^2)$.** For $n = 10{,}000$, that is fifty million tests per frame — impractical in real time.

- **SAP sorts boxes by their left edge along a chosen axis.** The inner loop breaks as soon as it finds a box whose left edge exceeds the current box's right edge. In practice this reduces the work to $O(n \log n)$ or better.

- **The algorithm is $O(n \log n + k)$** where $k$ is the number of axis-overlapping pairs. It is best when objects are well distributed; it degrades toward $O(n^2)$ when all objects cluster along the sweep axis.

- **For moving objects, incremental sorting makes updates near $O(n)$.** Insertion sort on a nearly-sorted array costs almost nothing when objects move smoothly between frames.

- **SAP vs spatial hashing.** SAP needs no cell-size tuning, is simpler to implement, and has good cache behavior. Spatial hashing has better asymptotic complexity but is sensitive to cell-size choice. For most real-time simulations the simpler algorithm is the right starting point.

- **Axis choice matters for performance.** Sweep along the axis of greatest scene extent to maximize early terminations.
