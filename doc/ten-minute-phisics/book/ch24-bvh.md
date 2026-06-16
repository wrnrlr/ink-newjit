# Chapter 24 — Bounding Volume Hierarchies with Morton Code Construction

Broad-phase collision detection — finding which pairs of objects are even candidates for collision before doing any precise geometry test — is the quiet workhorse of real-time physics. Get it wrong and your simulation either misses collisions or buries itself in unnecessary work. This chapter covers the data structure that has become the industry standard for this problem: the **Bounding Volume Hierarchy**, or BVH. More specifically, it covers a construction algorithm that is fast enough to rebuild the entire tree from scratch every frame, even for large dynamic scenes. The key ingredient is the **Morton code**, a space-filling curve that collapses 3D position into a single integer in a way that preserves spatial locality — and that makes the entire tree constructible from a single integer sort.


## Why Not Brute Force?

The naive approach to collision detection is to test every object against every other object. For *n* objects that is O(n²) tests per frame. With a thousand objects, a million tests. With ten thousand, a hundred million. Clearly this does not scale.

Chapter 23 introduced Sweep and Prune (SAP), which projects all bounding boxes onto one axis, sorts the projections, and finds overlaps in O(n log n) time. SAP is effective, but it only exploits one axis. In 3D with objects spread through a volume, the projection onto a single axis carries little spatial information. The number of overlap tests SAP must actually perform scales roughly as n^{2/3} in 3D — about 10,000 tests per object for a million-object scene, and 10 billion tests in total.

A BVH brings this down to O(log n) tests per object query. The table below makes the difference concrete for n = 10⁶ objects:

| Method         | Tests per query |
|----------------|----------------|
| Brute force    | n              |
| SAP (one axis) | n^{2/3}        |
| BVH            | log₂ n ≈ 20    |

That jump from 10,000 to 20 is the reason BVHs appear in nearly every physics engine, ray tracer, and game engine written in the last twenty years.


## The BVH Data Structure

A BVH is a binary tree. Each node stores an **axis-aligned bounding box** (AABB) that encloses all the objects in its subtree. Leaf nodes wrap individual objects. Internal nodes wrap the union of their two children's boxes.

Construction proceeds bottom-up conceptually: group nearby objects into pairs, wrap each pair in a bounding box, group those boxes into pairs, and so on until you have a single root box that contains the entire scene. The tree is balanced by design, so its height is approximately log₂ n.

**Querying** the tree for all objects that overlap a given region is a recursive traversal:

1. If the query region does not overlap the current node's AABB, stop — the entire subtree is clear.
2. If it does overlap and the node is a leaf, the object is a candidate; record it.
3. If it does overlap and the node is internal, recurse into both children.

The power of this algorithm is step 1: a single AABB miss prunes an entire subtree of potentially thousands of objects in one test. In the best case, where the query region is small and the tree is well-balanced, you follow roughly one path from root to leaf, touching only O(log n) nodes. Even in practice, with query regions comparable in size to individual objects and moderate overlap between objects, the tests-per-query stays close to this theoretical minimum.

A height-h tree contains 2^h leaves, so h = log₂ n. For a million objects, that is 20 levels. For a trillion, 40. The logarithm grows so slowly that even planetary-scale simulations remain tractable.


## The Problem with Dynamic Scenes

For static scenes, tree construction cost is amortized over many frames and almost any construction algorithm will do. Dynamic scenes are different. Objects move every frame, so bounding boxes change every frame, and the tree must reflect those changes.

There are two standard approaches. The first is **incremental update**: detect which nodes have been violated by moving objects and repair them locally. This produces tighter trees but the algorithms are complex and irregular — each node may need a different repair strategy, which makes parallelization difficult.

The second approach is to **rebuild the tree from scratch every frame**. This sounds wasteful, but if construction is fast enough — say, a few milliseconds for tens of thousands of objects — it is actually preferable. The resulting code is simple, uniform, and parallelizable. The catch is that "fast enough" demands a clever algorithm.

The key insight is that a standard top-down construction algorithm sorts objects along alternating axes at each level of recursion. This requires O(n log n) work at every level, or O(n log² n) total. We can do better: if we can reduce construction to a **single sort** of all objects, everything else is linear.


## Morton Codes: Space-Filling Curves

The single-sort trick relies on **Morton codes**, also known as Z-order curve values.

Start by dividing the scene's bounding box into a uniform grid of 2^b × 2^b × 2^b cells. Replace each object by its center. Map the center to integer grid coordinates (i, j, k) in the range [0, 2^b − 1]:

```
i = floor((cx − minX) / (maxX − minX) × 2^b)
j = floor((cy − minY) / (maxY − minY) × 2^b)
k = floor((cz − minZ) / (maxZ − minZ) × 2^b)
```

Now form the Morton code by **interleaving the bits** of the three integer coordinates. If i, j, and k each have b bits, the Morton code has 3b bits. The bits alternate: the most significant bit of k, the most significant bit of j, the most significant bit of i, then the next bit of k, and so on:

```
Morton(i, j, k) = ... k₂ j₂ i₂ k₁ j₁ i₁ k₀ j₀ i₀
```

The resulting integer is a single key that encodes all three coordinates. When objects are sorted by this key, spatially nearby objects end up near each other in the sorted list — this is the defining property of a space-filling curve.

Why does interleaving work? Consider just two dimensions (i, j) for clarity. The highest bit of the Morton code is the highest bit of j, which splits the grid into a top half and a bottom half. The second-highest bit is the highest bit of i, which splits each half into a left and right quarter. The pattern continues, recursively subdividing the plane in alternating axis order. The sorted list of Morton codes is therefore already organized as a tree: the first half of the list occupies the lower-y half of the space, the second half occupies the upper-y half, and within each half the first quarter occupies lower-x, and so on.

This is exactly the subdivision order a top-down BVH builder would produce if it alternated axes at each level — but we get it from a single integer sort, with no recursive sorting required.

In three dimensions, the bit-interleaving expands each coordinate independently before ORing the results together. A standard trick using bit-manipulation masks achieves this efficiently:

```js
function expandBits(v) {
    v = (v * 0x00010001) & 0xFF0000FF;
    v = (v * 0x00000101) & 0x0F00F00F;
    v = (v * 0x00000011) & 0xC30C30C3;
    v = (v * 0x00000005) & 0x49249249;
    return v;
}

function mortonCode(x, y, z) {
    // x, y, z are integer grid coordinates in [0, 1023] (10 bits each)
    return expandBits(x) | (expandBits(y) << 1) | (expandBits(z) << 2);
}
```

`expandBits` inserts two zero bits after every bit of `v`, spreading a 10-bit value across 30 bits. Shifting y left by 1 and z left by 2 before ORing interleaves the three expanded values. The result is a 30-bit Morton code, sufficient for a 1024³ grid.


## LBVH Construction

With Morton codes in hand, the **Linear BVH** (LBVH) construction algorithm is straightforward:

1. Normalize each object center to [0, 1]³ and map it to integer grid coordinates.
2. Compute the Morton code for each object.
3. Sort the objects by Morton code.
4. Build the tree top-down by recursively splitting the sorted list.

The only non-obvious step is step 4: given a subrange of the sorted list, how do we find the split point?

The answer falls directly out of the Morton code's bit structure. Within any subrange, all objects share the same leading bits — that is why they are grouped together in the sorted list. The split point is the position where the **next most significant bit changes** from 0 to 1. Objects before that position go to the left child; objects from that position onward go to the right child. Since the list is sorted, this transition happens exactly once within the subrange, and a binary search finds it efficiently.

If all Morton codes in a subrange are identical (all objects fall in the same grid cell), there is no bit that changes. In that case we split at the midpoint, accepting a geometrically imperfect but structurally valid split.

The complete algorithm in pseudocode:

```
createTree():
    for each object i:
        codes[i] = mortonCode(center(i))
    sort objects by codes
    return createSubTree(0, n − 1)

createSubTree(begin, end):
    if begin == end:
        return LeafNode(objects[begin])
    m = findSplitPosition(begin, end)
    left  = createSubTree(begin, m)
    right = createSubTree(m + 1, end)
    bounds = union(left.bounds, right.bounds)
    return InternalNode(bounds, left, right)

findSplitPosition(begin, end):
    if codes[begin] == codes[end]:
        return (begin + end) / 2          // all equal: split at midpoint
    commonPrefix = highestBit(codes[begin] XOR codes[end])
    // binary search for where bit 'commonPrefix' changes
    lo = begin; hi = end
    while lo + 1 < hi:
        mid = (lo + hi) / 2
        if highestBit(codes[begin] XOR codes[mid]) == commonPrefix:
            lo = mid
        else:
            hi = mid
    return lo
```

The `findSplitPosition` function finds the last position in [begin, end] where the leading common prefix is shared with `codes[begin]`. Everything up to and including that position shares the same leading bit pattern; everything after it diverges. This is the correct split point for a Morton-code-ordered BVH.

Each level of the recursion does O(n) work in total across all nodes at that level, and the tree has O(log n) levels, so the total construction time (excluding the sort) is O(n log n). In practice the recursion is so cache-friendly — the sorted list is accessed sequentially at each level — that constant factors are small.


## Putting It Together in Code

Here is the JavaScript implementation from the demo, lightly annotated.

**Computing the Morton code** from a world-space center position:

```js
function calculateMortonCode(x, y, z) {
    // Map world coordinates to [0, 1]
    x = (x + WORLD_SIZE / 2) / WORLD_SIZE;
    y = (y + WORLD_SIZE / 2) / WORLD_SIZE;
    z = (z + WORLD_SIZE / 2) / WORLD_SIZE;

    // Clamp and scale to [0, 1023]
    x = Math.min(Math.floor(Math.max(x, 0) * 1023), 1023);
    y = Math.min(Math.floor(Math.max(y, 0) * 1023), 1023);
    z = Math.min(Math.floor(Math.max(z, 0) * 1023), 1023);

    return expandBits(x) | (expandBits(y) << 1) | (expandBits(z) << 2);
}
```

**Building the tree** from a sorted list of (id, mortonCode) pairs:

```js
function createTree(boxes) {
    const list = boxes.map((box, i) => ({
        id: i,
        mortonCode: calculateMortonCode(
            box.position.x, box.position.y, box.position.z)
    }));

    list.sort((a, b) => a.mortonCode - b.mortonCode);

    return createSubTree(list, 0, list.length - 1, boxes);
}

function createSubTree(list, begin, end, boxes) {
    if (begin === end) {
        // Leaf: one object
        const node = new BVHNode();
        node.boxId = list[begin].id;
        node.aabb = boxes[node.boxId].getAABB();
        return node;
    }

    const m = Math.floor((begin + end) / 2);   // simplified split
    const node = new BVHNode();
    node.left  = createSubTree(list, begin, m,     boxes);
    node.right = createSubTree(list, m + 1, end,   boxes);

    // Parent AABB is the union of children's AABBs
    node.aabb.min = componentMin(node.left.aabb.min, node.right.aabb.min);
    node.aabb.max = componentMax(node.left.aabb.max, node.right.aabb.max);

    return node;
}
```

The split in this demo uses a simple midpoint rather than the full highest-differing-bit search. For a demo this is fine: the Morton sort already ensures that objects near the midpoint of the sorted range are spatially adjacent. A production implementation would use the binary search described above for tighter bounds.

**Querying** for collisions against the built tree:

```js
function findCollisions(queryId, queryAABB, node, boxes, results) {
    if (!aabbIntersect(queryAABB, node.aabb)) return;  // prune entire subtree

    if (node.isLeaf()) {
        if (node.boxId !== queryId)
            results.push({ a: queryId, b: node.boxId });
        return;
    }

    findCollisions(queryId, queryAABB, node.left,  boxes, results);
    findCollisions(queryId, queryAABB, node.right, boxes, results);
}
```

The single early-return on an AABB miss is where all the performance comes from.

**The animation loop** rebuilds the BVH every frame:

```js
function animate() {
    for (const box of boxes) box.update();

    const bvhRoot = createTree(boxes);       // rebuild: ~2–3 ms for 10,000 boxes
    const collisions = checkCollisionsBVH(boxes, bvhRoot);  // query: ~10 ms

    // mark colliding boxes red, render, repeat
}
```

In testing with 10,000 boxes in unoptimized JavaScript, BVH construction takes 2–3 milliseconds per frame and collision detection takes around 10 milliseconds — well inside the 16 ms budget for 60 Hz. The bottleneck is rendering, not the physics.


## Why This Works on GPUs

The LBVH construction algorithm is not just fast on a single CPU thread — it is the standard approach for GPU-accelerated BVH construction in ray tracers and physics engines. The reasons are worth understanding.

First, **sorting is a primitive that GPUs do extremely well**. Radix sort over 30-bit Morton codes runs in microseconds on modern hardware.

Second, **the recursion is data-parallel**. At each level of the tree, all nodes at that level can be processed simultaneously. Each node just needs to find its split position in its subrange of the sorted list, which is an independent operation. There is no dependency between sibling subtrees.

Third, **memory access is sequential**. Because the sorted list is accessed in-order at each level, cache lines are consumed front to back. Random-access tree traversal, by contrast, causes cache misses at every internal node. The sorted Morton-code layout is one of the few tree representations that is friendly to hardware prefetchers.

Fourth, **the resulting tree layout is compact**. A scheme called the **compact LBVH** stores the tree in an array where node i's children are at predictable indices, eliminating pointer storage entirely. This reduces memory bandwidth — the other GPU bottleneck — significantly.


## Key Takeaways

- **Brute-force collision detection is O(n²)**; BVH traversal reduces the per-query cost to O(log n), making it practical for millions of objects.
- A BVH is a binary tree where each node stores an **AABB** enclosing all objects below it. An AABB miss during traversal prunes the entire subtree.
- **Morton codes** interleave the bits of integer grid coordinates to produce a single integer per object. Sorting objects by Morton code places spatially nearby objects contiguously in memory.
- The sorted Morton-code order is equivalent to the visit order of a top-down BVH builder that alternates axes at each level. This means the **entire BVH can be built from a single sort** plus a linear-time recursive split.
- The split position at each node is the point where the **highest differing bit** of the Morton codes changes within that node's sorted subrange.
- **Dynamic scenes** can be handled by rebuilding the BVH every frame. With LBVH construction, rebuilding 10,000 objects takes a few milliseconds in unoptimized JavaScript — fast enough to be irrelevant to the frame budget.
- LBVH construction maps naturally to GPUs: the sort is a GPU primitive, the per-level node processing is data-parallel, and the sequential memory access pattern is cache-friendly.
