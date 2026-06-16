# Chapter 11 — Spatial Hashing: Finding Neighbors in O(n)

Collision detection has two phases. The *narrow phase* does the precise geometry work — checking whether two specific objects actually overlap and computing the contact normal. The *broad phase* answers a prior question: which pairs are even worth checking? Get the broad phase wrong and you spend 99% of your time on tests that could never produce a collision. This chapter is about getting the broad phase right.

The technique is **spatial hashing**: a data structure that maps continuous space onto a flat array using a hash function, then sorts particle IDs into that array in a single counting-sort pass. Construction costs O(n). Each neighbor query costs O(1) amortised. The result is a simulation loop that scales to tens of thousands of particles and stays real-time on modest hardware.

---

## The Problem With Brute Force

Given *n* particles, the neighbor-search problem is: for every particle **p**ᵢ, find all particles **p**ⱼ such that

```
|pⱼ − pᵢ| ≤ d
```

For sphere collision, set d = 2r (the sum of the two radii). The naïve solution is a nested loop over all pairs:

```javascript
for (let i = 0; i < n; i++)
    for (let j = 0; j < n; j++)
        if (distance(p[i], p[j]) <= d)
            handleCollision(i, j);
```

This is O(n²). At n = 100,000 particles that is 10 billion distance tests per frame. No amount of SIMD or micro-optimisation rescues an O(n²) algorithm at that scale.

The target complexities for real-time physics are:

| Complexity | Tests at n = 100,000 | Verdict |
|------------|----------------------|---------|
| O(n)       | 100,000              | ideal   |
| O(n log n) | ~1,700,000           | fine    |
| O(n²)      | 10,000,000,000       | unusable |

Every particle must be touched every time step regardless, so O(n) is as good as it gets. Spatial hashing delivers exactly that.

---

## Dividing Space Into a Grid

The core insight is locality: two particles can only collide if they are spatially close. A regular grid makes "spatially close" precise.

Partition space into cubic cells of side length *h*. Each particle belongs to exactly one cell — the cell containing its centre. To check for collisions around particle **p**ᵢ, only inspect the cells adjacent to **p**ᵢ's cell. If h = 2r, then any colliding particle must have its centre inside one of the 3 × 3 × 3 = 27 surrounding cells (9 in 2D). This constant bound is what keeps the per-particle query cost O(1).

Given a particle at position (px, py, pz), its cell coordinates are:

```javascript
xi = Math.floor(px / h)
yi = Math.floor(py / h)
zi = Math.floor(pz / h)
```

For a bounded grid of dimensions numX × numY × numZ, the flat array index is:

```
i = (xi * numY + yi) * numZ + zi
```

This is just column-major (or row-major, by convention) flattening — the same trick used to store matrices in a 1D array.

---

## Spatial Hashing: Unbounded Grids

A bounded grid requires knowing the world extents in advance and allocates memory proportional to the number of *cells*, not the number of *particles*. For a large sparse world that wastes enormous amounts of memory, and for a dynamically growing simulation it breaks entirely.

Spatial hashing drops the bounded-grid requirement. Instead of directly using the flat cell index, we pass the cell coordinates through a hash function to map them into a fixed-size table:

```javascript
hashCoords(xi, yi, zi) {
    var h = (xi * 92837111) ^ (yi * 689287499) ^ (zi * 283923481);
    return Math.abs(h) % this.tableSize;
}
```

The large prime multipliers and XOR combination distribute cell coordinates across the table with low correlation between nearby cells. The table size is arbitrary — a good default is `tableSize = 2 * numParticles`.

**Hash collisions are acceptable.** Two different cells can map to the same table slot. When that happens, their particles end up in the same bucket and get tested against each other. Those tests will fail the distance check — they are false positives, not false negatives. Correctness is preserved; we just do a handful of extra distance computations. Choosing `tableSize ≥ numParticles` keeps the expected number of false positives low.

---

## Building the Table: Counting Sort

The hash table is rebuilt from scratch every frame. That sounds expensive, but the construction algorithm is a three-pass counting sort that runs in O(n) time with no heap allocation (all arrays are pre-allocated in the constructor).

The data structure holds two parallel arrays:

- **cellStart[h]** — the index in `cellEntries` where the particles for hash bucket *h* begin.
- **cellEntries[k]** — the particle ID at position *k*.

The guard entry `cellStart[tableSize]` holds the total particle count so the last bucket's range is well-defined as `[cellStart[h], cellStart[h+1])`.

### Pass 1: Count particles per bucket

```javascript
this.cellStart.fill(0);

for (var i = 0; i < numObjects; i++) {
    var h = this.hashPos(pos, i);
    this.cellStart[h]++;
}
```

After this pass, `cellStart[h]` holds the number of particles in bucket *h*.

### Pass 2: Prefix sums → start indices

```javascript
var start = 0;
for (var i = 0; i < this.tableSize; i++) {
    start += this.cellStart[i];
    this.cellStart[i] = start;
}
this.cellStart[this.tableSize] = start;  // guard
```

After prefix-summing, `cellStart[h]` points one past the *last* slot for bucket *h* (i.e., to the first slot of the next non-empty bucket). That off-by-one is intentional — it makes the fill pass elegant.

### Pass 3: Fill particle IDs

```javascript
for (var i = 0; i < numObjects; i++) {
    var h = this.hashPos(pos, i);
    this.cellStart[h]--;
    this.cellEntries[this.cellStart[h]] = i;
}
```

Decrementing before writing turns the "one past the end" pointer into a valid slot index. Particles are inserted in reverse order within each bucket, but the order within a bucket does not matter for correctness.

After all three passes, `cellStart` contains valid start indices and `cellEntries` is a dense array of particle IDs grouped by bucket.

---

## Querying Neighbors

To find all neighbors of particle *nr* within distance `maxDist`:

```javascript
query(pos, nr, maxDist) {
    var x0 = this.intCoord(pos[3 * nr]     - maxDist);
    var y0 = this.intCoord(pos[3 * nr + 1] - maxDist);
    var z0 = this.intCoord(pos[3 * nr + 2] - maxDist);

    var x1 = this.intCoord(pos[3 * nr]     + maxDist);
    var y1 = this.intCoord(pos[3 * nr + 1] + maxDist);
    var z1 = this.intCoord(pos[3 * nr + 2] + maxDist);

    this.querySize = 0;

    for (var xi = x0; xi <= x1; xi++) {
        for (var yi = y0; yi <= y1; yi++) {
            for (var zi = z0; zi <= z1; zi++) {
                var h = this.hashCoords(xi, yi, zi);
                var start = this.cellStart[h];
                var end   = this.cellStart[h + 1];
                for (var i = start; i < end; i++) {
                    this.queryIds[this.querySize++] = this.cellEntries[i];
                }
            }
        }
    }
}
```

The query computes the bounding box of cells that could possibly contain a particle within `maxDist`, iterates over those cells (always a small constant number when `maxDist ≈ h`), and collects candidate particle IDs into `queryIds`. Crucially, `maxDist` can be larger than the grid spacing — the query just expands the cell range accordingly.

The caller then filters candidates with an explicit distance check:

```javascript
this.hash.query(this.pos, i, 2.0 * this.radius);

for (var nr = 0; nr < this.hash.querySize; nr++) {
    var j = this.hash.queryIds[nr];
    var d2 = vecDistSquared(this.pos, i, this.pos, j);
    if (d2 > 0.0 && d2 < minDist * minDist) {
        // resolve collision between i and j
    }
}
```

The `d2 > 0.0` guard is important: a particle always finds itself in its own bucket, and the zero-distance self-hit must be skipped.

---

## Integrating Into the Simulation Loop

Because the hash is rebuilt in O(n), there is no need for an incremental update. The simulation step simply recreates the table after integrating positions:

```javascript
simulate(dt, gravity, worldBounds) {
    // 1. Integrate positions
    for (var i = 0; i < this.numBalls; i++) {
        vecAdd(this.vel, i, gravity, 0, dt);
        vecAdd(this.pos, i, this.vel, i, dt);
    }

    // 2. Rebuild spatial hash — O(n)
    this.hash.create(this.pos);

    // 3. Resolve collisions
    for (var i = 0; i < this.numBalls; i++) {
        this.hash.query(this.pos, i, 2.0 * this.radius);
        for (var nr = 0; nr < this.hash.querySize; nr++) {
            // narrow-phase distance test and response
        }
    }
}
```

The full pipeline — integrate, rebuild hash, query all particles — runs in O(n). With 13,000 particles the simulation completes in roughly 80 ms per frame on a mid-range laptop, comfortably fast enough for interactive use.

---

## Implementation Notes

**Pre-allocate everything.** The `Hash` constructor takes the maximum number of objects and pre-allocates `cellStart`, `cellEntries`, and `queryIds` as typed arrays (`Int32Array`). No allocation happens during `create` or `query`.

**Table size trades memory for collisions.** A larger table has fewer hash collisions and therefore fewer spurious neighbor candidates, but uses more memory. `tableSize = 2 * numParticles` is a practical default.

**The hash function is a "fantasy function."** The specific constants (92837111, 689287499, 283923481) are just large primes chosen to spread cell coordinates around without obvious patterns. There is no mathematical proof of optimality — they work well in practice and are cheap to compute.

**Reconstruction beats incremental updates.** Maintaining a spatial hash incrementally (inserting and deleting particles as they move between cells) is error-prone and often slower in practice than a clean O(n) rebuild, because the rebuild is branchless and cache-friendly while incremental updates are pointer-chasing.

---

## Key Takeaways

- Naïve pair-wise collision detection is O(n²) and unworkable beyond a few thousand particles.
- A grid of cell size h = 2r reduces each neighbor query to at most 27 cell lookups (3D), giving O(1) per query and O(n) overall.
- Spatial hashing extends the grid idea to unbounded worlds by hashing cell coordinates into a fixed-size table. Hash collisions produce only false positives, not false negatives — correctness is unaffected.
- The table is built with a three-pass counting sort: count, prefix-sum, fill. All three passes are O(n) and work on pre-allocated arrays with no dynamic memory.
- Rebuilding the entire table every frame is simpler and often faster than incremental updates because the construction is branchless and highly cache-friendly.
- With this structure, 10,000+ particle simulations run comfortably in real time on consumer hardware.
