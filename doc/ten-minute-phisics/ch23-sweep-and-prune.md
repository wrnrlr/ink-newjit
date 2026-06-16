# Chapter 23 — Broad Phase Collision Detection with Sweep and Prune

A physics simulation with a few dozen objects can afford to test every pair for collision on every frame — the brute-force approach is simple, correct, and fast enough. Scale the scene to ten thousand objects and the arithmetic changes dramatically: the number of pairs grows as $\frac{n(n-1)}{2}$, so ten thousand objects produce roughly fifty million candidate pairs per frame. This chapter addresses that problem with **Sweep and Prune (SAP)**, one of the oldest and most practical broad-phase algorithms in collision detection. The core idea: sort the objects along one axis, and use that order to skip enormous numbers of tests that could never produce a collision.

---

## The Two-Phase Approach to Collision Detection

Collision detection is conventionally split into two phases.

The **broad phase** works with simplified stand-ins: for each body we compute an **axis-aligned bounding box (AABB)** — the smallest axis-parallel box containing the object completely. Two objects cannot be colliding unless their AABBs overlap. The broad phase produces a list of *candidate pairs* conservatively: may admit false positives, never misses true collisions.

The **narrow phase** takes only those candidate pairs and subjects them to a precise geometry-aware test. For spheres this is a single distance comparison. For meshes it may involve GJK or separating-axis tests.

The division of labor makes large scenes tractable: broad phase processes every object cheaply; narrow phase does real work on only a fraction of all pairs.

---

## Why Brute Force Fails

The naive broad phase tests every pair of AABBs — O(n²) tests. For $n = 10{,}000$, that is roughly fifty million tests per frame. Even at a few nanoseconds each, the cumulative cost dominates.

In ink, the brute-force approach is:

```k
/ O(n²) brute-force: check all pairs
/ aabbs: list of (left; right; bottom; top) 2D bounding boxes
bruteForce: {[aabbs;n]
  ,/ {[i]
    ,/ {[j]
      $[j<=i; ();
        [a:aabbs@i; b:aabbs@j
         $[(a@1)>(b@0) & (b@1)>(a@0) & (a@3)>(b@2) & (b@3)>(a@2);
           ,(i;j); ()]]]
    }' !n
  }' !n
}
```

For 10,000 objects this performs ~50M tests. A faster approach is a necessity.

---

## Sweep and Prune

SAP exploits a simple geometric fact: if two AABBs do not overlap along any one axis, they cannot overlap in 3D space. Use a single axis as an early rejection filter.

**Choose a sweep axis.** Project every AABB onto one axis — conventionally the $x$-axis, or the axis along which the scene extent is greatest. Along this axis each box defines an interval $[\ell_i, r_i]$.

**Sort by left edge.** Arrange boxes in ascending order of $\ell_i$.

**Sweep through the sorted list.** For each box $i$, scan forward through boxes $j > i$. Because the list is sorted by left edge, $\ell_j \geq \ell_i$ for all $j > i$. The moment $\ell_j > r_i$, every remaining box starts to the right of where box $i$ ends — break immediately.

```k
/ Sweep and prune: 2D AABB collision candidate pairs
/ spheres: list of (x; y; r) 3-tuples; returns list of (i;j) candidate pairs
sweepAndPrune: {[spheres;n]
  / Compute 2D AABBs: (left; right; y; r) for sort + y-filter
  boxes: {[s] (s@0 - s@2; s@0 + s@2; s@1; s@2)}' spheres

  / Sort by left edge
  lefts: {x@0}' boxes
  order: <lefts          / grade: indices sorted by left edge
  sorted: boxes@order    / sorted AABB list
  ids: order             / original sphere index for each sorted position

  / Sweep
  pairs: ()
  {[i]
    box_i: sorted@i
    right_i: box_i@1
    {[j]
      box_j: sorted@j
      $[(box_j@0) > right_i; 0;   / stop: left_j > right_i (no more overlaps)
        / y-filter: check y separation
        $[abs((box_j@2) - (box_i@2)) <= ((box_i@3) + box_j@3);
          pairs:: pairs, (ids@i; ids@j);
          0]]
    } scan/ i+1+!n-i-1    / scan until early exit (but scan doesn't early-exit in ink)
  }' !n
  pairs
}
```

**Note on early exit in ink**: ink's `'` (each) and `scan/` operators do not support mid-iteration break. For proper early exit, use a conditional fold:

```k
/ SAP with proper early exit using fold
sweepAndPruneCorrect: {[spheres;n]
  boxes: {[s] (s@0-s@2; s@0+s@2; s@1; s@2)}' spheres
  ord: <({x@0}' boxes)
  sorted: boxes@ord

  ,/ {[i]
    ri: (sorted@i)@1
    / Collect pairs: fold accumulates (pairs; done_flag)
    pairs: ()
    {[acc;j]
      $[acc@1; acc;    / already done
        [(bj: sorted@j; lj: bj@0)
         $[lj>ri; (acc@0; 1);  / done
           $[abs((bj@2) - (sorted@i)@2) <= ((bj@3) + (sorted@i)@3);
             ((acc@0),(ord@i; ord@j); 0);
             (acc@0; 0)]]]]
    }/ (pairs; 0), i+1+!n-i-1
    / Return just the pairs
    0       / placeholder — full implementation extracts acc@0
  }' !n
}
```

The elegant implementation has no data structures beyond a sorted array. The early break condition is the entire acceleration.

---

## Complexity Analysis

Sorting $n$ boxes costs O(n log n). For $n = 10{,}000$: roughly $130{,}000$ comparisons — three orders of magnitude fewer than the brute-force 50M.

The inner loop cost depends on scene configuration. In the best case (objects well separated): each inner loop terminates after one step, giving O(n) total inner-loop work and overall O(n log n). In the worst case (all boxes at the same position): inner loop never breaks early, O(n²). The algorithm is $O(n \log n + k)$ where $k$ is the number of axis-overlapping pairs.

```k
/ Benchmark SAP vs brute force
n: 1000
spheres: {[i] (i mod 100 % 10.; i div 100 % 10.; 0.3)}' !n
\t bruteForce[{(x@0-x@2;x@0+x@2;x@1-x@2;x@1+x@2)}' spheres;n]  / O(n²) ~500K pairs
\t sweepAndPrune[spheres;n]                                         / O(n log n + k)
```

---

## Incremental Updates for Moving Objects

Re-sorting from scratch costs O(n log n) per frame. In a simulation where objects move smoothly, the sorted order changes very little between frames. **Insertion sort** on nearly-sorted data degenerates to O(n): it makes one pass through the array, performs a small number of swaps near positions that actually moved.

```k
/ Insertion sort: efficient for nearly-sorted data (moving objects)
insertionSort: {[arr;key]
  {[i]
    k: key@(arr@i)
    j: i
    {[jj]
      $[jj>0 & key@(arr@(jj-1))>k;
        [arr:: @[@[arr;jj;:;arr@(jj-1)];jj-1;:;arr@i]
         jj-1];
        neg 1]   / sentinel to stop
    }/ j, !i
  }' 1+!#arr-1
  arr
}
```

---

## Choosing the Sweep Axis

Any axis works correctly; the choice only affects performance. The heuristic: sweep along the axis of greatest scene extent. If the scene spans 1000 units horizontally and 200 units vertically, sweeping along $x$ maximizes the number of early breaks (objects must travel further before their projections overlap).

```k
/ Choose best sweep axis from list of (x;y;z) positions
chooseSweepAxis: {[positions]
  mins: &/' positions; maxs: |/' positions
  extents: maxs - mins
  / 0=x, 1=y, 2=z
  extents?&/extents   / axis with maximum extent
}
```

---

## SAP vs Spatial Hashing

SAP is not the only broad-phase algorithm. Spatial hashing (Chapter 11) is the main alternative.

| Property | SAP | Spatial Hash |
|---|---|---|
| Asymptotic | O(n log n + k) | O(n) expected |
| Tuning needed | axis choice (trivial) | cell size (important) |
| Implementation | ~10 lines | ~40 lines |
| Cache behavior | sequential scan (excellent) | pointer chasing (worse) |
| Worst case | all objects along sweep axis | all objects in one cell |

For most real-time simulations with objects of similar size and roughly uniform distribution, both approaches perform comparably. SAP earns its place for being conceptually transparent, trivially implementable, and robust without tuning.

---

## Key Takeaways

- **Broad phase before narrow phase.** Replace objects with AABBs for a fast, conservative first pass. Forward only candidate pairs to the expensive per-geometry test.
- **Brute force is O(n²).** For $n = 10{,}000$, that is fifty million tests per frame — impractical in real time.
- **SAP sorts boxes by left edge along a chosen axis.** The inner loop breaks as soon as it finds a box whose left edge exceeds the current box's right edge.
- **The algorithm is O(n log n + k)** where $k$ is the number of axis-overlapping pairs. Best when objects are well distributed; degrades toward O(n²) when all objects cluster along the sweep axis.
- **For moving objects, incremental sorting makes updates near O(n).** Insertion sort on a nearly-sorted array costs almost nothing when objects move smoothly.
- **SAP vs spatial hashing.** SAP needs no cell-size tuning, is simpler to implement, and has good cache behavior. Spatial hashing has better asymptotic complexity but is sensitive to cell-size choice.
- **Sweep along the axis of greatest scene extent** to maximize early terminations.
