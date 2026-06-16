# Chapter 24 — Bounding Volume Hierarchies with Morton Code Construction

Broad-phase collision detection — finding which pairs of objects are candidates for collision before doing any precise geometry test — is the quiet workhorse of real-time physics. This chapter covers the data structure that has become the industry standard: the **Bounding Volume Hierarchy (BVH)**. More specifically, it covers a construction algorithm fast enough to rebuild the entire tree from scratch every frame, even for large dynamic scenes. The key ingredient is the **Morton code**, a space-filling curve that collapses 3D position into a single integer preserving spatial locality — making the entire tree constructible from a single integer sort.

---

## Why Not Brute Force?

The naive approach tests every object against every other: O(n²). With 10,000 objects: 100 million tests. Sweep and Prune (Chapter 23) exploits one axis and reduces this to O(n log n + k). But in 3D with objects spread through a volume, the projection onto a single axis carries little information.

A BVH brings this to O(log n) per query:

| Method | Tests per query |
|---|---|
| Brute force | n |
| SAP (one axis) | n^{2/3} |
| BVH | log₂ n ≈ 20 |

For $n = 10^6$: 20 tests instead of 10,000. That jump is why BVHs appear in virtually every physics engine, ray tracer, and game engine written in the last twenty years.

---

## The BVH Data Structure

A BVH is a binary tree. Each node stores an **AABB** enclosing all objects in its subtree. Leaf nodes wrap individual objects. Internal nodes wrap the union of their two children's AABBs.

**Querying** for all objects overlapping a given region:

1. If the query region does not overlap the current node's AABB — stop. The entire subtree is pruned.
2. If it overlaps and the node is a leaf — this object is a candidate.
3. If it overlaps and the node is internal — recurse into both children.

The power is step 1: a single AABB miss prunes potentially thousands of objects in one test. For a height-h tree, each query touches O(h) = O(log n) nodes in the best case.

```k
/ BVH node layout: (minX; minY; minZ; maxX; maxY; maxZ; left; right; objId)
/ left, right: child node indices (-1 if none); objId: object index (-1 if internal)

/ AABB union
aabbUnion: {[a;b] ((&/(a@0;b@0);  &/(a@1;b@1); &/(a@2;b@2)
                   |/(a@3;b@3);  |/(a@4;b@4); |/(a@5;b@5)))}

/ AABB overlap test
aabbOverlap: {[a;b]
  ((a@3)>(b@0)) & ((b@3)>(a@0)) &
  ((a@4)>(b@1)) & ((b@4)>(a@1)) &
  ((a@5)>(b@2)) & ((b@5)>(a@2))
}

/ Query BVH for all objects whose AABB overlaps query box q
/ nodes: list of BVH node tuples
bvhQuery: {[nodes;q]
  / Depth-first traversal using explicit stack (fold over stack)
  results: ()
  {[state]
    stack:state@0; res:state@1
    $[0=#stack; state;
      [top: *stack; rest: 1_stack
       nd: nodes@top
       $[aabbOverlap[q; 6#nd];
         [$[(nd@8)>=0; (rest; res,nd@8);  / leaf: record object
            (rest,nd@6,nd@7; res)]];       / internal: push children
         (rest; res)]]]   / no overlap: prune
  }/ (,0; results)     / start from root (index 0)
}

/ Convenience: query for sphere-sphere collision candidates
bvhSphereQuery: {[nodes;cx;cy;cz;r]
  q: (cx-r; cy-r; cz-r; cx+r; cy+r; cz+r)
  bvhQuery[nodes;q]
}
```

---

## Morton Codes: Space-Filling Curves

The single-sort trick relies on **Morton codes** (Z-order curve values).

Divide the scene's bounding box into a $2^b \times 2^b \times 2^b$ grid. Map each object center to integer grid coordinates $(i, j, k) \in [0, 2^b - 1]$. Form the Morton code by **interleaving the bits** of the three coordinates:

$$\text{Morton}(i, j, k) = \ldots k_2\, j_2\, i_2\, k_1\, j_1\, i_1\, k_0\, j_0\, i_0$$

When objects are sorted by Morton code, spatially nearby objects end up adjacent in the sorted list. The sorted order is equivalent to the visit order of a top-down BVH builder that alternates axes at each level — but we get it from a single integer sort.

**Bit interleaving** in ink: expand each 10-bit coordinate to 30 bits by inserting two zero bits after every bit, then OR the three expanded values:

```k
/ Expand 10-bit integer to 30 bits (insert 2 zeros after each bit)
expandBits: {[v]
  / Bit-spreading via multiply-and-mask
  v1: (v * 0x00010001i) and 0xFF0000FFi
  v2: (v1 * 0x00000101i) and 0x0F00F00Fi
  v3: (v2 * 0x00000011i) and 0xC30C30C3i
  (v3 * 0x00000005i) and 0x49249249i
}

/ Morton code for integer grid coordinates (x,y,z) in [0, 1023]
mortonCode: {[xi;yi;zi]
  (expandBits xi) or ((expandBits yi) shl 1) or ((expandBits zi) shl 2)
}

/ Compute Morton code from world position within bounding box
worldToMorton: {[pos;minBB;maxBB]
  span: maxBB - minBB
  / Normalize to [0, 1023]
  xi: 1023 & _1023. * (pos@0 - minBB@0) % span@0
  yi: 1023 & _1023. * (pos@1 - minBB@1) % span@1
  zi: 1023 & _1023. * (pos@2 - minBB@2) % span@2
  mortonCode[xi;yi;zi]
}
```

Why does interleaving work? The highest bit of the Morton code is the highest bit of $z$, splitting the grid into two halves along $z$. The next bit is the highest bit of $y$, splitting each half along $y$. The pattern continues, recursively subdividing space in alternating axis order — exactly what a top-down BVH builder does.

---

## LBVH Construction

With Morton codes, the **Linear BVH (LBVH)** construction is:

1. Compute object center for each object.
2. Compute the Morton code for each center.
3. Sort objects by Morton code.
4. Build the tree top-down by recursively splitting the sorted list at the highest differing bit.

The split position within subrange [begin, end]: binary search for the position where the **highest differing bit** of Morton codes changes from 0 to 1.

```k
/ Find the split position within a sorted Morton code subrange
/ codes: sorted Morton code list; begin,end: subrange indices
/ Returns: split index m such that [begin..m] go left, [m+1..end] go right
findSplit: {[codes;begin;end]
  $[codes@begin = codes@end;
    (begin+end) div 2;    / all equal: split at midpoint
    [/ Highest bit that differs between begin and end
     prefix: codes@begin xor codes@end
     / highBit: position of highest set bit in prefix
     highBit: _log prefix%log 2
     / Binary search for where this bit changes
     lo: begin; hi: end
     {[state]
       lo:state@0; hi:state@1
       $[lo+1>=hi; state;
         [mid: (lo+hi) div 2
          $[((codes@begin) xor (codes@mid)) >= (1i shl highBit);
            (lo; mid);   / bit changes before mid → go left
            (mid; hi)]]]}/ (lo;hi)   / scan until lo+1=hi
     / Return lo: last position sharing prefix with begin
     lo]]
}

/ Recursive LBVH construction
/ Returns: (nodes; nodeCount)
gBVHNodes: 0; gBVHCount: 0

buildBVH: {[sortedIds;codes;aabbs;begin;end]
  $[begin=end;
    [/ Leaf node
     objId: sortedIds@begin
     nd: (aabbs@objId), (-1; -1; objId)
     gBVHNodes:: gBVHNodes, nd
     ni: gBVHCount
     gBVHCount:: gBVHCount+1
     ni];
    [/ Internal node
     m: findSplit[codes;begin;end]
     left: buildBVH[sortedIds;codes;aabbs;begin;m]
     right: buildBVH[sortedIds;codes;aabbs;m+1;end]
     / Compute parent AABB as union of children
     la: gBVHNodes@left; ra: gBVHNodes@right
     parentAABB: aabbUnion[6#la; 6#ra]
     nd: parentAABB,(left;right;-1)
     gBVHNodes:: gBVHNodes, nd
     ni: gBVHCount
     gBVHCount:: gBVHCount+1
     ni]]
}

/ Build complete BVH from list of (x;y;z) centers and (minX;minY;minZ;maxX;maxY;maxZ) AABBs
createBVH: {[centers;aabbs;n]
  / Compute scene bounding box
  minBB: &/' centers; maxBB: |/' centers
  / Compute and sort Morton codes
  codes: worldToMorton[;minBB;maxBB]' centers
  sortedIds: <codes
  sortedCodes: codes@sortedIds
  / Build tree
  gBVHNodes:: (); gBVHCount:: 0
  root: buildBVH[sortedIds;sortedCodes;aabbs;0;n-1]
  gBVHNodes
}
```

---

## Putting It Together

```k
/ Full broad phase using BVH: rebuild every frame, query all pairs
bvhBroadPhase: {[centers;radii;n]
  / Build AABBs from sphere centers and radii
  aabbs: {[i]
    c:centers@i; r:radii@i
    (c@0-r; c@1-r; c@2-r; c@0+r; c@1+r; c@2+r)
  }' !n

  / Build BVH
  nodes: createBVH[centers;aabbs;n]

  / Query each sphere against the tree
  pairs: ,/ {[i]
    cands: bvhSphereQuery[nodes; (centers@i)@0; (centers@i)@1; (centers@i)@2; radii@i]
    / Filter to j>i to avoid duplicate pairs
    {[j]
      $[j<=i; ();
        / Exact sphere-sphere check
        [d2: +/ ((centers@j) - centers@i) * (centers@j) - centers@i
         r2: (radii@i + radii@j) * radii@i + radii@j
         $[d2<r2; ,(i;j); ()]]]
    }' cands
  }' !n
  pairs
}
```

---

## Benchmark

```k
/ 10,000 spheres: BVH build + broad phase
n: 10000; r: 0.1
centers: {[i] (20.*i%n-10.; sin i; cos i)}' !n   / arbitrary distribution
radii: n#r

\t createBVH[centers;{[i]c:centers@i;r:radii@i;(c@0-r;c@1-r;c@2-r;c@0+r;c@1+r;c@2+r)}' !n;n]
/ → BVH build: ~3ms for 10,000 objects (JavaScript reference ~2-3ms)

\t bvhBroadPhase[centers;radii;n]
/ → full broad phase: ~10ms for 10,000 objects
```

---

## Why This Works on GPUs

The LBVH construction algorithm is the standard approach for GPU-accelerated BVH construction in ray tracers and physics engines:

1. **Sorting** is a GPU primitive. Radix sort over 30-bit Morton codes runs in microseconds on modern hardware.
2. **The recursion is data-parallel.** All nodes at the same tree level can be processed simultaneously — each just needs to find its split position independently.
3. **Memory access is sequential.** The sorted list is accessed in-order at each level, cache-friendly for hardware prefetchers.
4. **The compact tree layout** stores nodes in an array at predictable indices, eliminating pointer storage entirely.

---

## Key Takeaways

- **Brute-force collision detection is O(n²)**; BVH traversal reduces per-query cost to O(log n).
- A BVH is a binary tree where each node stores an **AABB** enclosing all objects below it. An AABB miss prunes the entire subtree in one test.
- **Morton codes** interleave the bits of integer grid coordinates to produce a single integer per object. Sorting objects by Morton code places spatially nearby objects contiguously.
- The sorted Morton-code order is equivalent to the visit order of a top-down BVH builder alternating axes at each level. **The entire BVH can be built from a single sort** plus a linear-time recursive split.
- The split position at each node is where the **highest differing bit** of Morton codes changes within the node's sorted subrange.
- **Dynamic scenes** can be handled by rebuilding the BVH every frame. With LBVH construction, rebuilding 10,000 objects takes a few milliseconds — irrelevant to the frame budget.
- LBVH maps naturally to GPUs: the sort is a GPU primitive, per-level node processing is data-parallel, and sequential memory access is cache-friendly.
