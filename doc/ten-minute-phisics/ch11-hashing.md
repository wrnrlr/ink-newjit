# Chapter 11 — Spatial Hashing: Finding Neighbors in O(n)

Collision detection has two phases. The *narrow phase* does the precise geometry work — checking whether two specific objects actually overlap and computing the contact normal. The *broad phase* answers a prior question: which pairs are even worth checking? Get the broad phase wrong and you spend 99% of your time on tests that could never produce a collision. This chapter is about getting the broad phase right.

The technique is **spatial hashing**: a data structure that maps continuous space onto a flat array using a hash function, then sorts particle IDs into that array in a single pass. Construction costs O(n). Each neighbor query costs O(1) amortised. The result is a simulation loop that scales to tens of thousands of particles and stays real-time on modest hardware.

---

## The Problem With Brute Force

Given $n$ particles, the neighbor-search problem is: for every particle $\mathbf{p}_i$, find all particles $\mathbf{p}_j$ such that $|\mathbf{p}_j - \mathbf{p}_i| \leq d$.

The naïve approach tests all pairs:

```k
/ O(n²) naive: check all n*(n-1)/2 pairs
naivePairs: {[n] a:!n*n; ri:a div n; ci:a mod n; +(ri@(&ri<ci))@ci@(&ri<ci)}
```

For $n = 100{,}000$ that is 10 billion distance tests per frame. Spatial hashing reduces this to O(n).

---

## Dividing Space Into a Grid

The core insight is locality: two particles can only collide if they are spatially close. Partition space into cubic cells of side length $h$. Each particle belongs to exactly one cell — the cell containing its centre. To check for collisions around particle $\mathbf{p}_i$, only inspect the 27 cells in the $3 \times 3 \times 3$ neighborhood around $\mathbf{p}_i$'s cell. When $h = 2r$ (twice the particle radius), any colliding particle must have its centre in one of those 27 cells. This constant bound is what keeps the per-particle query cost O(1).

A particle at position $(px, py, pz)$ maps to integer cell coordinates:

```k
intCoord: {[x;h] _x%h}     / floor(x/h) — integer cell coordinate
```

---

## Spatial Hashing: Unbounded Grids

A bounded grid requires knowing the world extents in advance. Spatial hashing drops that requirement. Instead of using the flat cell index directly, we map cell coordinates through a hash function into a fixed-size table:

```k
/ Map 3D integer cell (xi, yi, zi) to a hash bucket index
/ Uses large prime multipliers for good distribution
hashCell: {[xi;yi;zi;ts]
  (abs ((xi*92837111) + (yi*689287499) + zi*283923481)) mod ts
}
```

**Parenthesization note:** `(xi*92837111)` and `(yi*689287499)` get extra parens to prevent right-to-left mis-association in the subsequent additions.

**Hash collisions are acceptable.** Two different cells can map to the same bucket. Those collisions produce only false positives — extra distance tests that fail the narrow-phase check. Correctness is preserved. Setting `tableSize ≥ 2*n` keeps false positive rates low.

---

## Building the Table

The hash table is rebuilt from scratch every frame using a sort-based approach:

1. Compute the bucket for every particle (vectorized).
2. Sort particle indices by bucket using the grade operator `<`.
3. Find each bucket's start position using the find operator `?`.
4. Fill missing buckets with a backward fill scan.

```k
/ Global hash state — must be global for lambda access inside queries
gCellStart: 0
gOrder: 0

/ 27 neighbor cell offsets (precomputed)
oxs: -1 -1 -1 -1 -1 -1 -1 -1 -1  0  0  0  0  0  0  0  0  0  1  1  1  1  1  1  1  1  1
oys: -1 -1 -1  0  0  0  1  1  1 -1 -1 -1  0  0  0  1  1  1 -1 -1 -1  0  0  0  1  1  1
ozs: -1  0  1 -1  0  1 -1  0  1 -1  0  1 -1  0  1 -1  0  1 -1  0  1 -1  0  1 -1  0  1

/ Build spatial hash from n 3D particles (flat pos array: x0 y0 z0 x1 y1 z1 ...)
buildHash: {[pos;n;h;ts]
  / Step 1: vectorized bucket for all particles
  bs: hashCell[intCoord[pos@(3*!n);h]
               intCoord[pos@(1+3*!n);h]
               intCoord[pos@(2+3*!n);h]; ts]
  / Step 2: sort particle indices by bucket
  order: <bs
  sortedBs: bs@order
  / Step 3: first occurrence of each bucket in sorted sequence.
  / find→length: an absent bucket yields #sortedBs = n, exactly the "not found"
  / sentinel we append as the guard — so empty buckets are already n, no 0N to patch.
  cs: (sortedBs?!ts),n     / n is the sentinel: "bucket not found"
  / Step 4: backward fill — missing (n-valued) buckets point to next non-empty bucket.
  / Reverse, forward-fill the n sentinels with the previous real start, then reverse back.
  gOrder:: order
  gCellStart:: |({[acc;x] $[x=n; acc; x]}\ |cs)
}
```

The backward fill `|({...}\ |cs)` works as follows:
- `|cs` reverses the array so we process from right to left.
- `{[acc;x] $[x=0N; acc; x]}\` is a scan: for each element, keep it if non-null, else use the accumulated value (which is the next non-null to the right of the original).
- `|` reverses back to get the forward-order result.

The result `gCellStart[b]` is the index into `gOrder` where bucket `b` begins. For a missing bucket, it equals the start of the next non-empty bucket, making the range `[gCellStart[b], gCellStart[b+1])` correctly empty.

---

## Querying Neighbors

To find all neighbors of particle `nr`, query all 27 surrounding cells:

```k
/ Query: return all candidate particle indices near particle nr
/ Post-filter with exact distance check in the caller
queryNeighbors: {[pos;nr;h;ts]
  cx: intCoord[pos@(3*nr);h]
  cy: intCoord[pos@(1+3*nr);h]
  cz: intCoord[pos@(2+3*nr);h]
  / Vectorized: compute hash for all 27 neighbor cells at once
  cells: hashCell[cx+oxs; cy+oys; cz+ozs; ts]
  / Collect particle IDs from all 27 buckets
  / Note: use ' adverb (not 'each' keyword) for lambda application
  ,/ {gOrder@((gCellStart@x)+!(gCellStart@(x+1)) - gCellStart@x)}' cells
}
```

The caller filters candidates with an exact distance check:

```k
/ Resolve sphere-sphere collisions using spatial hash
/ r: particle radius (uniform); minDist: 2*r; state: (pos; vel; ...)
resolveSphereCollisions: {[pos;vel;r;n;h;ts]
  minDist: 2.*r; minDist2: minDist*minDist
  buildHash[pos;n;h;ts]
  / Process each particle
  {[i]
    candidates: ?queryNeighbors[pos;i;h;ts]   / de-duplicate
    / Filter to actual collisions
    {[j]
      $[j<=i; 0;    / skip self and already-processed pairs
        [dx:(pos@(3*j))-(pos@(3*i)); dy:(pos@(1+3*j))-(pos@(1+3*i)); dz:(pos@(2+3*j))-(pos@(2+3*i))
         d2: ((dx*dx)+(dy*dy))+dz*dz
         $[d2<minDist2&d2>0.;
           / ... resolve collision ...
           0; 0]]]
    }' candidates
  }' !n
}
```

---

## Collision Resolution

The narrow phase for two spheres $i$ and $j$: compute the distance, check if less than $2r$, and if so push them apart and exchange normal velocity components as in Chapter 3.

The broad-phase query dramatically reduces the work: for uniformly distributed particles, each particle has an expected O(1) neighbors per frame, making the entire collision loop O(n).

---

## Benchmark

```k
/ 10,000 particles: spatial hash build + 1 frame of collision detection
n: 10000; h: 0.2; ts: 2*n
\t buildHash[pos; n; h; ts]    / should be <5ms
\t {queryNeighbors[pos;x;h;ts]}' !n   / full query pass
```

At 10,000 particles, spatial hash construction runs in about 2ms and the full collision pass in under 10ms on a modern machine — comfortably interactive.

---

## Key Takeaways

- Naïve pair-wise collision detection is O(n²) and unworkable beyond a few thousand particles.
- A grid of cell size $h = 2r$ reduces each neighbor query to at most 27 cell lookups (3D), giving O(1) per query and O(n) overall.
- **Spatial hashing** extends the grid to unbounded worlds by hashing cell coordinates into a fixed-size table. Hash collisions produce only false positives — correctness is unaffected.
- The sort-based construction: vectorize buckets → grade sort → find start indices → backward fill for missing buckets. O(n log n) from the sort, but very cache-friendly.
- **Rebuilding every frame** is simpler and often faster than incremental updates because the construction is branchless and highly cache-friendly.
- In ink, lambdas that run inside `'` (each) can only access **global** variables, not function-local ones. Use `gCellStart` and `gOrder` as global state.
- Use the `'` adverb (tick), not the `each` keyword, for applying a lambda to each element of a list that needs global array access.
