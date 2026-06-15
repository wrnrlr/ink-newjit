# Chapter 24 — Bounding Volume Hierarchies with a Blazing Fast Implementation

**Video:** https://youtu.be/LAxHQZ8RjQ4
**Slides:** https://matthias-research.github.io/pages/tenMinutePhysics/24-morton.pdf
**Code:** https://raw.githubusercontent.com/matthias-research/pages/master/tenMinutePhysics/24-morton.html

## Lecture Notes

### Problem

Find all objects overlapping a query region. Brute force costs O(n²) tests. Sweep and Prune (ch23) gives O(n log n) but only uses one axis — bad for dense 3D scenes.

**Complexity comparison** (n = 10⁶ objects):
| Method | Tests / query |
|--------|--------------|
| Brute force | n |
| SAP (1 axis) | √n (3D: n^{2/3}) |
| BVH | log₂ n |

---

### BVH Data Structure

A binary tree where each node stores an axis-aligned bounding box (AABB) covering all objects in its subtree. Leaf nodes hold individual objects.

**Query:** traverse tree. If query region misses a node's bounds, skip the entire subtree. Expected depth h = log₂ n.

---

### Fast Construction with Morton Codes

To rebuild the BVH every frame (dynamic scenes) we need a single-sort construction:

1. Map each object's center to integer coordinates (i, j) in a 2^b × 2^b grid:
   `xi = floor((cx − minX)/(maxX − minX) * 2^b)`

2. **Interleave bits** of xi and yi to form a Morton code (Z-order curve):
   Bits alternate: y₅ x₅ y₄ x₄ y₃ x₃ …

3. Sort objects by Morton code (one integer sort).

4. Build BVH top-down by recursively splitting at the **highest bit where adjacent Morton codes differ**. The sorted order guarantees each split creates spatially coherent groups.

**Splitting rule:**
- Find the position in the sorted list where the leading bits of Morton codes change → this is the median split.
- If all codes in the range are equal, split at the midpoint.

**Algorithm:**

```
createTree():
    sort objects by mortonCode
    return createSubTree(0, n-1)

createSubTree(begin, end):
    if begin == end: return leaf(objects[begin])
    m = getSplitPos(begin, end)   # highest differing bit
    left  = createSubTree(begin, m-1)
    right = createSubTree(m, end)
    return node(union(left.bounds, right.bounds), left, right)
```

The Morton code encodes the full path from root to leaf, enabling O(n log n) construction with a single sort.


## Video Transcript

hi notas from 10minute physics here today I will show you how to perform broad phase Collision detection using bounding volume hierarchies I will also present a very fast and clever way to create them the problem we're looking into is to find all objects that overlap a given region here the red rectangle we can use this operation to perform broad face Collision detection for instance for this we iterate through all the objects for each object we set the region to the bounding box of the object this way we detect all pair collisions in the last tutorial we looked at the sweeten prun method there we projected the bounding boxes of all objects onto the xaxis then we tested for overlaps of the projections while iterating from left to right for 10,000 2D objects evenly distributed in the plane we need about 100 overlap tests for each object this is faster than a 10,000 tests for the brute force method of testing all objects against all other objects but we want to do better for 100 million objects arranged evenly in a cube we need to perform about 100 times 100 tests per object the problem with sweeping prun is that we only use one axis the method I present today is much more efficient it uses a bounding volume hierarchy for n objects it only has to perform about log two of nend tests per object I will explain in a minute what the log function is here I just give some numbers here is an example in 2D with 100 times 100 objects the brute force method needs to do 10,000 tests per object and a million tests in total as we just saw sweeping prune needs 100 tests per object resulting in a million tests in total with the use of a bounding volume hierarchy we only need to perform about 13 tests per object this yields 130,000 tests in total in 3D the situation is even more dramatic the brute force method performs 1 million tests per object this yields 1 trillion tests in total sweep and prun performs about 10,000 tests per object and 10 billion in total the BBH requires about 20 tests per object and 20 million tests in total let me now show you what the bounding volume hierarchy is and how it is constructed it looks like a tree we start with a set of objects first we compute the bounding boxes of all objects these are the leaves of the tree now we join pair of object objects to build the first layer of internal nodes or branches each note stores the union of the bounding boxes of the object it contains we want those bounding boxes to be as small as possible therefore we want to group objects that are closed together now we repeat this process we create the next layer of notes by pairing the notes on the current layer each note stores the union of the bounding boxes of its children again we want those bounding boxes to be small therefore we group notes on the first level that are close we repeat this process until we only have one big node this node contains the entire scene and it is called the root Noe here I have drawn the bounding volume hierarchy as a tree this way it is easier to see the parent child relations marked as arrows in computer science we draw trees upside down the bounding volume hierarchy allows us to find overlapping objects efficiently let's assume we want to find all objects overlapping this gray area a key observation is that if a region does not overlap the bounds of a node we can ignore the entire subtree below this node this is because the bounds of a node are the union of all the bounds below it we start at the root node the region overlaps the bounding box of the root node in this case we have to test both children the region overlaps the left node so we need to test both Children of the left node now only the right child overlaps the region the left child does not which means we can ignore the entire sub tree we repeat this process and find all the overlapping objects without having to test all objects in the scene let's assume we have H layers of nodes since each note has two children the number of nodes doubles in each layer this means if the height of the tree is H the number of leaves is two to the power of H this is only true for perfectly balanced trees but similar for average trees in a perfect case in which the bounds are small and we have to follow only one path down the number of tests is AG in a scenario in which the size of the query bounds is close to the object sizes and the objects do not overlap much the number of tests is not much bigger in this case we can solve the equation for H which gives us H equal log 2 of n the log 2 of n is the exponent of two which gives us n the nice thing is that the log 2 function grows very slowly for n equal 1,000 it is approximately 10 for a million about 20 and for a trillion about 30 the question is how can we create bounding box hierarchies there are two main algorithms the top down and the bottom up approach we already saw the bottom up approach we started by grouping pairs of objects to form the lowest level nodes then we grouped the lowest level nodes to form larger nodes we did this until we ended up with one single note the root node the problem with this approach is how to find pairs such that the bounding boxes of the nodes are small this is easier to achieve with a top down approach here we alternate the axis we start with the x-axis and sort all object centers with respect to this axis then we split the objects into two equal sets a left and a right set we then repeat this process for both subsets recursively in the next step we take the Y AIS for static scenes it doesn't matter much how fast the creation is since we only have to do it once in Dynamic scenes however it is different there are two main approaches to handle Dynamic scenes we can reorder parts of the tree dynamically the problem is that such algorithms are complicated and heterogeneous this means that they're not very well suited for a parallel implementation the other option we have is to reconstruct the entire tree from scratch every time the scene changes to speed things up we can only recreate the tree every nth frame to make sure we don't miss any collisions we have to expand the bounds a bit to make this method practical we need a very fast tree construction algorithm what would help is if we only needed to perform a single sword for the entire construction is this possible yes we split the bounding box of the entire scene into regular grid of cells we don't store a data structure for this grid we just use it conceptually the number of cells in each Dimension need to be equal and the Power of Two we replace each object by its Center then we compute the integer coordinates of the center these are the coordinates of the cells in the grid here is the code to do this we first clamp the coordinates of the centers within the grid to values between 0 and one then we multiply by the number of cells along each axis and clamp to integer values for a single sword we need a single key from the two coordinates now comes the really clever idea we want to alternate the axis again from top down this can be achieved by interleaving the bits of the two coordinates here's an example example the first bit of the key is the first bit of the first coordinate the second bit is the first bit of the second coordinate the third bit is the second bit of the first coordinate and the fourth bit is the second bit of the second coordinate I guess you get the idea what we get is the so-called Morton code here I wrote down the Morton codes for all cells in the grid the first bit splits the grid into two halves along the x-axis all cells with a zero belong to the lower half the cells with a one to the upper half now let's look at the lower part only here we see that the second bit splits the cells into two vertical halves the same is true for the upper half here is the second half of the first half now it is the third bit which splits it into two halves I'm following only one path here is the fourth split the fifth and number six finally we arrive at the leaf node which only contains one cell here is the part of the tree we just looked at the leaf note we arrived at was 01101 to get there we first picked the lower half meaning we went to the left then we went to the right to the right to the left to the left and to the right as you can see the Morton code tells us exactly where in the tree we are the main part of the top- down construction algorithm was to split a sorted list of objects of a node into two parts to create the child nodes here you see an example of the sort of at list of more than codes of a node the first two bits of all codes are the same this means we are in the sub tree 01 the third bit is the most significant bit that changes since the codes are sorted this bit splits the codes into two separate lists one for each subnode if all keys are equal we simply split in the middle we are now ready to write down the entire algorithm we first Define a node class it stores the bounce of all objects in the sub tree it also stores an ID of an object this variable is only used for leaf nodes the left and right pointers reference the children of the node they're only used in internal nodes the create tree function is the main function we first create a list of pairs of object IDs and Morton codes we sort this list by the Morton codes then we create the tree by calling the create subtree function with the entire list the create sub tree function takes a list of ID and Morton code pairs it also takes a and an end index these indices Define which part of the list should be taken to create the sub tree if begin and end are the same we only have one ID in this case we create a leaf node it contains the bounce of the object and the ID of the object as a leaf node it doesn't have children we then return this Leaf node if the list is longer we compute the middle index as we just saw the previous slide now we create two children for the left child we use the list from the beginning to to the middle index minus one for the right child we use the list from the middle index to the end once we have created the children we can create the new node its bounds or the union of the bounds of the children the index minus one indicates that this is an internal node then we add the pointers to the children we just created and return the node I gave this pseudo code to Claud and told him to use an HTML page and the library 3js to create a demo with moving boxes and mor code based Collision detection he wrote the complete demo you see here in one shot I will link it in the description we have 10,000 boxes moving through each other as you can see the construction of the bvh only takes between two and three milliseconds and this is with unoptimized JavaScript code this is far from being the bottleneck Collision detection itself takes about 10 milliseconds so together we would have over 60 frames per second we have about 20 frames per second here I guess the rest is taken by rendering and the creation of the Shadow map

## Source Code

### 24-morton.html

```html
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Morton BVH Collision Detection Demo</title>
    <style>
        body { margin: 0; overflow: hidden; background-color: #000; }
        .info {
            position: absolute;
            top: 10px;
            left: 10px;
            background: rgba(0, 0, 0, 0.7);
            color: white;
            font-family: monospace;
            padding: 10px;
            font-size: 12px;
            pointer-events: none;
            z-index: 100;
            border-radius: 5px;
        }
    </style>
</head>
<body>
    <div id="container"></div>
    <div class="info">
        <h3>3D Morton BVH Collision Detection</h3>
        <p>Boxes: <span id="boxCount">0</span></p>
        <p>Collisions: <span id="collisionCount">0</span></p>
        <p>BVH Build Time: <span id="buildTime">0</span> ms</p>
        <p>Collision Check Time: <span id="checkTime">0</span> ms</p>
        <p>BVH Checks: <span id="bvhChecks">0</span></p>
        <p>FPS: <span id="fps">0</span></p>
    </div>

    <script src="https://cdnjs.cloudflare.com/ajax/libs/three.js/r128/three.min.js"></script>
    <script>
        // All function declarations first, then usage
        
        // ================ Constants ================
        const BOX_COUNT = 10000; // Reduced for better performance with shadows
        const WORLD_SIZE = 100;
        const MIN_BOX_SIZE = 0.5;
        const MAX_BOX_SIZE = 3;
        const MAX_SPEED = 0.5;
        
        // ================ Utility Functions ================
        
        // Morton code bit manipulation
        function expandBits(v) {
            v = (v * 0x00010001) & 0xFF0000FF;
            v = (v * 0x00000101) & 0x0F00F00F;
            v = (v * 0x00000011) & 0xC30C30C3;
            v = (v * 0x00000005) & 0x49249249;
            return v;
        }
        
        // Calculate 3D Morton code
        function calculateMortonCode(x, y, z) {
            // Normalize coordinates to [0,1] range based on world size
            const normalizeCoord = (val) => {
                return (val + WORLD_SIZE / 2) / WORLD_SIZE;
            };
            
            x = normalizeCoord(x);
            y = normalizeCoord(y);
            z = normalizeCoord(z);
            
            // Clamp to ensure they're in [0,1]
            x = Math.min(Math.max(x, 0.0), 1.0);
            y = Math.min(Math.max(y, 0.0), 1.0);
            z = Math.min(Math.max(z, 0.0), 1.0);
            
            // Scale to range [0, 1023] for 10-bit encoding
            x = Math.min(Math.floor(x * 1023), 1023);
            y = Math.min(Math.floor(y * 1023), 1023);
            z = Math.min(Math.floor(z * 1023), 1023);
            
            // Insert zeros between bits (3D Morton code)
            const xx = expandBits(x);
            const yy = expandBits(y);
            const zz = expandBits(z);
            
            // Interleave the bits
            return xx | (yy << 1) | (zz << 2);
        }
        
        // Check if two AABBs intersect
        function aabbIntersect(aabb1, aabb2) {
            return (
                aabb1.min.x <= aabb2.max.x && aabb1.max.x >= aabb2.min.x &&
                aabb1.min.y <= aabb2.max.y && aabb1.max.y >= aabb2.min.y &&
                aabb1.min.z <= aabb2.max.z && aabb1.max.z >= aabb2.min.z
            );
        }
        
        // ================ Box Class ================
        class Box {
            constructor(id) {
                this.id = id;
                
                // Random size
                this.width = MIN_BOX_SIZE + Math.random() * (MAX_BOX_SIZE - MIN_BOX_SIZE);
                this.height = MIN_BOX_SIZE + Math.random() * (MAX_BOX_SIZE - MIN_BOX_SIZE);
                this.depth = MIN_BOX_SIZE + Math.random() * (MAX_BOX_SIZE - MIN_BOX_SIZE);
                
                // Random position within 3D cube bounds
                this.position = new THREE.Vector3(
                    (Math.random() - 0.5) * WORLD_SIZE,
                    (Math.random() - 0.5) * WORLD_SIZE + WORLD_SIZE/4, // Offset upward a bit
                    (Math.random() - 0.5) * WORLD_SIZE
                );
                
                // Random velocity in all three dimensions
                this.velocity = new THREE.Vector3(
                    (Math.random() - 0.5) * MAX_SPEED,
                    (Math.random() - 0.5) * MAX_SPEED,
                    (Math.random() - 0.5) * MAX_SPEED
                );
                
                // Create Three.js mesh with improved materials
                const geometry = new THREE.BoxGeometry(this.width, this.height, this.depth);
                const material = new THREE.MeshStandardMaterial({ 
                    color: 0x00ff00,
                    roughness: 0.5,
                    metalness: 0.2,
                    emissive: 0x002200,
                    emissiveIntensity: 0.1
                });
                this.mesh = new THREE.Mesh(geometry, material);
                this.mesh.position.copy(this.position);
                
                // Enable shadows
                this.mesh.castShadow = true;
                this.mesh.receiveShadow = true;
                
                // Default state
                this.isColliding = false;
            }
            
            update() {
                // Update position based on velocity
                this.position.add(this.velocity);
                
                // Bounce off world boundaries in all three dimensions
                if (Math.abs(this.position.x) > WORLD_SIZE / 2 - this.width / 2) {
                    this.velocity.x *= -1;
                    this.position.x = Math.sign(this.position.x) * (WORLD_SIZE / 2 - this.width / 2);
                }
                
                if (Math.abs(this.position.y) > WORLD_SIZE / 2 - this.height / 2) {
                    this.velocity.y *= -1;
                    this.position.y = Math.sign(this.position.y) * (WORLD_SIZE / 2 - this.height / 2);
                }
                
                if (Math.abs(this.position.z) > WORLD_SIZE / 2 - this.depth / 2) {
                    this.velocity.z *= -1;
                    this.position.z = Math.sign(this.position.z) * (WORLD_SIZE / 2 - this.depth / 2);
                }
                
                // Update mesh position
                this.mesh.position.copy(this.position);
                
                // Reset collision state
                if (this.isColliding) {
                    this.mesh.material.color.set(0x00ff00);
                    this.mesh.material.emissive.set(0x002200);
                    this.isColliding = false;
                }
            }
            
            markCollision() {
                this.mesh.material.color.set(0xff3300);
                this.mesh.material.emissive.set(0x330000);
                this.isColliding = true;
            }
            
            // Get axis-aligned bounding box
            getAABB() {
                return {
                    min: new THREE.Vector3(
                        this.position.x - this.width / 2,
                        this.position.y - this.height / 2,
                        this.position.z - this.depth / 2
                    ),
                    max: new THREE.Vector3(
                        this.position.x + this.width / 2,
                        this.position.y + this.height / 2,
                        this.position.z + this.depth / 2
                    )
                };
            }
            
            // Check collision with another box
            checkCollision(other) {
                const aabb1 = this.getAABB();
                const aabb2 = other.getAABB();
                
                return (
                    aabb1.min.x <= aabb2.max.x && aabb1.max.x >= aabb2.min.x &&
                    aabb1.min.y <= aabb2.max.y && aabb1.max.y >= aabb2.min.y &&
                    aabb1.min.z <= aabb2.max.z && aabb1.max.z >= aabb2.min.z
                );
            }
        }
        
        // ================ BVH Node Class ================
        class BVHNode {
            constructor() {
                this.left = null;
                this.right = null;
                this.boxId = -1;  // Only leaf nodes have valid boxIds
                this.aabb = {
                    min: new THREE.Vector3(Infinity, Infinity, Infinity),
                    max: new THREE.Vector3(-Infinity, -Infinity, -Infinity)
                };
            }
            
            isLeaf() {
                return this.boxId !== -1;
            }
        }
        
        // ================ BVH Construction Functions ================
        function getSplitPos(list, begin, end) {
            // Simple middle split strategy
            return Math.floor((begin + end) / 2);
        }
        
        function createLeaf(boxId, box) {
            const node = new BVHNode();
            node.boxId = boxId;
            
            // Set AABB from box
            const aabb = box.getAABB();
            node.aabb.min.copy(aabb.min);
            node.aabb.max.copy(aabb.max);
            
            return node;
        }
        
        function createNode() {
            return new BVHNode();
        }
        
        function createSubTree(list, begin, end, boxes) {
            if (begin === end) {
                return createLeaf(list[begin].id, boxes[list[begin].id]);
            } else {
                const m = getSplitPos(list, begin, end);
                const node = createNode();
                
                node.left = createSubTree(list, begin, m, boxes);
                node.right = createSubTree(list, m + 1, end, boxes);
                
                // Update node's AABB to encompass children's AABBs
                node.aabb.min.x = Math.min(node.left.aabb.min.x, node.right.aabb.min.x);
                node.aabb.min.y = Math.min(node.left.aabb.min.y, node.right.aabb.min.y);
                node.aabb.min.z = Math.min(node.left.aabb.min.z, node.right.aabb.min.z);
                
                node.aabb.max.x = Math.max(node.left.aabb.max.x, node.right.aabb.max.x);
                node.aabb.max.y = Math.max(node.left.aabb.max.y, node.right.aabb.max.y);
                node.aabb.max.z = Math.max(node.left.aabb.max.z, node.right.aabb.max.z);
                
                return node;
            }
        }
        
        function createTree(boxes) {
            // Create list of box IDs with their Morton codes
            const list = [];
            for (let i = 0; i < boxes.length; i++) {
                const box = boxes[i];
                const center = box.position;
                const mortonCode = calculateMortonCode(center.x, center.y, center.z);
                list.push({ id: i, mortonCode: mortonCode });
            }
            
            // Sort by Morton code for spatial locality
            list.sort((a, b) => a.mortonCode - b.mortonCode);
            
            // Create the BVH tree recursively
            return createSubTree(list, 0, list.length - 1, boxes);
        }
        
        // ================ Collision Detection Functions ================
        // Find collisions between a box and the BVH tree
        function findCollisions(boxId, box, node, boxes, collisions, checkCount) {
            checkCount.value++;
            
            // If this box's AABB doesn't intersect with the node's AABB, return
            if (!aabbIntersect(box.getAABB(), node.aabb)) {
                return;
            }
            
            // If this is a leaf node
            if (node.isLeaf()) {
                // Don't check collisions with self
                if (node.boxId !== boxId) {
                    // Check for actual collision between boxes
                    if (box.checkCollision(boxes[node.boxId])) {
                        collisions.push({ a: boxId, b: node.boxId });
                    }
                }
                return;
            }
            
            // Recurse through children
            findCollisions(boxId, box, node.left, boxes, collisions, checkCount);
            findCollisions(boxId, box, node.right, boxes, collisions, checkCount);
        }
        
        // Check all collisions using BVH
        function checkCollisionsBVH(boxes, bvhRoot) {
            const collisions = [];
            const checkCount = { value: 0 };
            
            for (let i = 0; i < boxes.length; i++) {
                findCollisions(i, boxes[i], bvhRoot, boxes, collisions, checkCount);
            }
            
            return { collisions, checkCount: checkCount.value };
        }
        
        // Naive collision detection (for comparison)
        function checkCollisionsNaive(boxes) {
            const collisions = [];
            let checkCount = 0;
            
            for (let i = 0; i < boxes.length; i++) {
                for (let j = i + 1; j < boxes.length; j++) {
                    checkCount++;
                    if (boxes[i].checkCollision(boxes[j])) {
                        collisions.push({ a: i, b: j });
                    }
                }
            }
            
            return { collisions, checkCount };
        }
        
        // Camera rotation variables
        let cameraAngle = 0;
        const cameraRadius = 85;
        const cameraHeight = 40;
        
        // Function to update camera position
        function updateCamera() {
            cameraAngle += 0.001;
            camera.position.x = Math.sin(cameraAngle) * cameraRadius;
            camera.position.z = Math.cos(cameraAngle) * cameraRadius;
            camera.position.y = cameraHeight;
            camera.lookAt(0, 0, 0);
        }
        
        // FPS calculation
        let frameCount = 0;
        let lastTime = performance.now();
        
        function updateFPS() {
            const now = performance.now();
            frameCount++;
            
            if (now - lastTime >= 1000) {
                const fps = Math.round((frameCount * 1000) / (now - lastTime));
                document.getElementById('fps').textContent = fps;
                frameCount = 0;
                lastTime = now;
            }
        }
        
        // ================ Animation Loop ================
        function animate() {
            requestAnimationFrame(animate);
            
            // Update box positions
            for (const box of boxes) {
                box.update();
            }
            
            // Rebuild BVH (since boxes are moving)
            const buildStartTime = performance.now();
            const bvhRoot = createTree(boxes);
            const buildEndTime = performance.now();
            
            // Check collisions using BVH
            const checkStartTime = performance.now();
            const bvhResult = checkCollisionsBVH(boxes, bvhRoot);
            const checkEndTime = performance.now();
            
            // For comparison: naive collision checking
            // const naiveResult = checkCollisionsNaive(boxes);
            const naiveResult = { checkCount: 0 };
            
            // Mark colliding boxes
            const collisions = bvhResult.collisions;
            for (const collision of collisions) {
                boxes[collision.a].markCollision();
                boxes[collision.b].markCollision();
            }
            
            // Update stats
            document.getElementById('boxCount').textContent = boxes.length;
            document.getElementById('collisionCount').textContent = collisions.length;
            document.getElementById('buildTime').textContent = (buildEndTime - buildStartTime).toFixed(2);
            document.getElementById('checkTime').textContent = (checkEndTime - checkStartTime).toFixed(2);
            // document.getElementById('naiveChecks').textContent = naiveResult.checkCount;
            document.getElementById('bvhChecks').textContent = bvhResult.checkCount;
            
            // Update camera position
            updateCamera();
            
            // Update FPS counter
            updateFPS();
            
            // Render the scene
            renderer.render(scene, camera);
        }
        
        // ================ Scene Setup ================
        const scene = new THREE.Scene();
        scene.background = new THREE.Color(0x111111);
        
        // Add fog for depth perception
        scene.fog = new THREE.FogExp2(0x111111, 0.0025);
        
        const camera = new THREE.PerspectiveCamera(45, window.innerWidth / window.innerHeight, 0.1, 1000);
        camera.position.set(70, 40, 70);
        camera.lookAt(0, 0, 0);
        
        // Improved renderer with shadow maps
        const renderer = new THREE.WebGLRenderer({ 
            antialias: true,
            powerPreference: "high-performance"
        });
        renderer.setSize(window.innerWidth, window.innerHeight);
        renderer.setPixelRatio(window.devicePixelRatio);
        
        // Enable shadows in the renderer
        renderer.shadowMap.enabled = true;
        renderer.shadowMap.type = THREE.PCFSoftShadowMap; // Softer shadows
        
        document.getElementById('container').appendChild(renderer.domElement);
        
        // Enhanced Lighting Setup
        
        // Ambient light for base illumination
        const ambientLight = new THREE.AmbientLight(0x333333);
        scene.add(ambientLight);
        
        // Main directional light (sun-like) with shadows
        const mainLight = new THREE.DirectionalLight(0xffffff, 0.8);
        mainLight.position.set(50, 100, 50);
        mainLight.castShadow = true;
        
        // Optimize shadow map settings
        mainLight.shadow.mapSize.width = 2048;
        mainLight.shadow.mapSize.height = 2048;
        mainLight.shadow.camera.near = 0.5;
        mainLight.shadow.camera.far = 500;
        
        // Adjust shadow camera frustum to fit the scene
        const d = 100;
        mainLight.shadow.camera.left = -d;
        mainLight.shadow.camera.right = d;
        mainLight.shadow.camera.top = d;
        mainLight.shadow.camera.bottom = -d;
        
        // Add bias to reduce shadow acne
        mainLight.shadow.bias = -0.001;
        
        scene.add(mainLight);
        
        // Additional accent lights for better dimension
        const fillLight = new THREE.DirectionalLight(0x9090ff, 0.4);
        fillLight.position.set(-50, 20, -50);
        scene.add(fillLight);
        
        const rimLight = new THREE.DirectionalLight(0xff9090, 0.3);
        rimLight.position.set(0, -30, 100);
        scene.add(rimLight);
        
        // Create a floor plane to catch shadows
        const floorGeometry = new THREE.PlaneGeometry(WORLD_SIZE * 2, WORLD_SIZE * 2);
        const floorMaterial = new THREE.MeshStandardMaterial({ 
            color: 0x222222,
            roughness: 0.8,
            metalness: 0.2,
            side: THREE.DoubleSide
        });
        const floor = new THREE.Mesh(floorGeometry, floorMaterial);
        floor.rotation.x = Math.PI / 2;
        floor.position.y = -WORLD_SIZE / 2;
        floor.receiveShadow = true;
        scene.add(floor);
        
        // Create a transparent cube to visualize the 3D bounds
        const cubeGeometry = new THREE.BoxGeometry(WORLD_SIZE, WORLD_SIZE, WORLD_SIZE);
        const cubeMaterial = new THREE.MeshBasicMaterial({ 
            color: 0x444444, 
            wireframe: true,
            transparent: true,
            opacity: 0.2
        });
        const boundingCube = new THREE.Mesh(cubeGeometry, cubeMaterial);
        scene.add(boundingCube);
        
        // Grid helper with better visibility
        const gridHelper = new THREE.GridHelper(WORLD_SIZE * 2, 20, 0x444444, 0x222222);
        gridHelper.position.y = -WORLD_SIZE / 2 + 0.01; // Slightly above the floor
        scene.add(gridHelper);
        
        // Axes helper
        const axesHelper = new THREE.AxesHelper(10);
        scene.add(axesHelper);
        
        // ================ Main ================
        // Create boxes
        const boxes = [];
        for (let i = 0; i < BOX_COUNT; i++) {
            const box = new Box(i);
            boxes.push(box);
            scene.add(box.mesh);
        }
        
        // Handle window resize
        window.addEventListener('resize', () => {
            camera.aspect = window.innerWidth / window.innerHeight;
            camera.updateProjectionMatrix();
            renderer.setSize(window.innerWidth, window.innerHeight);
        });
        
        // Start animation
        animate();
    </script>
</body>
</html>

```
