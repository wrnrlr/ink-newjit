# Chapter 11 — Finding Overlaps Among Thousands of Objects Blazing Fast

**Video:** https://youtu.be/D2M8jTtKi44
**Slides:** https://matthias-research.github.io/pages/tenMinutePhysics/11-hashing.pdf
**Code:** https://raw.githubusercontent.com/matthias-research/pages/master/tenMinutePhysics/11-hashing.html

## Lecture Notes

### Problem

Given n points, for each **p**ᵢ find all neighbors **p**ⱼ with |**p**ⱼ − **p**ᵢ| ≤ d.
Special case d = 2r: find all overlapping particles of radius r.

Naïve O(n²) nested loop is not viable — for 100,000 points: 10 billion tests.

Algorithm complexity targets:
- O(n): good
- O(n log n): OK (log 100,000 ≈ 17)
- O(n²): not an option

---

### Grid-Based Acceleration

Store particles in a regular grid of cell size h. Choose h = 2r → only check the 9 surrounding cells (2D) or 27 (3D).

**Cell index:**
```
xi = Math.floor(px / spacing)
yi = Math.floor(py / spacing)
i  = xi * numY + yi          // 2D
i  = (xi * numY + yi) * numZ + zi   // 3D
```

**Dense grid storage** (3 steps):
1. Count particles per cell
2. Compute partial sums → array of start indices
3. Fill particle ID array

---

### Spatial Hashing (unbounded grid)

For infinite/large worlds, hash the cell coords to a fixed-size table:

```javascript
hashCoords(xi, yi, zi) {
    var h = (xi * 92837111) ^ (yi * 689287499) ^ (zi * 283923481);
    return Math.abs(h) % this.numCells;
}
```

Table index: `i = hash(xi, yi, zi) % tableSize`

Hash collisions are OK — they just cause a few extra distance tests.
Best practice: `tableSize = numParticles`.


## Video Transcript

hi malchus from 10 minute physics here welcome to tutorial number 11. today i will show you how to find neighbors among thousands of particles in a blazing fast way for this we will use spatial hashing and i will show you how to implement this very efficiently neighbor search is an essential part in the simulation of liquid gas sand or snow particles we will also use it for embedding visual meshes into volumetric meshes let's start as usual for the slides and demos have a look at my webpage at www.matiasmiller.info 10-minute physics here is the problem we're looking at given n points or particles or objects for all points p i find neighbors p j such that the distance between p i and p j is smaller or equal than d for the special case you already set d equals two r we find overlaps of particles with radius r as i mentioned before there are several use cases for instance simulating fluid sand or snow with particles of course there's a very simple solution to this we simply iterate through all the points and then for each point we again iterate through all the points in a nested loop and then we check whether the distance between the two points is smaller or equal to d if so we handle the overlap between the two particles the problem with this idea is that the complexity of this algorithm is o of n squared n being the number of points this means if we have a hundred thousand points which is common we have to perform a hundred billion tests this is of course very expensive in general for simulation an algorithm is good if it has complexity o of n this is because we have to touch every particle at every time step anyway a complexity of n log n is also okay this is the complexity of sorting for instance instead of 100 billion we only have to do 1.7 million tests however an algorithm with complexity n squared is not an option various data structures and algorithms have been proposed to reduce a complexity of n squared for instance bounding volume hierarchies or regular grids we are going to look at the solution with regular grids the idea is pretty simple we store all the particles in a regular grid and then for each particle we only have to look at closed cells to check whether some particles are overlapping particles may overlap multiple cells we store particles only where the center is located if we choose the spacing of the grid h to be 2r then we only have to check the cell of the particle itself and all direct neighbor cells in 2d we have to check 9 cells in 3d we have to check 27 cells now we have to think about how to store the greeting memory let's assume we have a grid of num x times num y cells with a given spacing the spacing is a floating point number if we have the coordinates of a point p x and p y which are floaty point numbers we can compute the integer numbers x i and y i of the cell that contains it these are the equations to do this first we flatten the grid and store one column after the other in a one-dimensional array the array has numx times non-y entries we can compute the position of a cell in the flattened array with this formula here in 3d we have three coordinates for each cell x i y i and zi to store the particles themselves we store a pointer to a linked list in each entry of the array however the memory layout of this data structure is not guaranteed to be dense we can create a dense representation which is much more efficient in terms of creation and traversal this time we store the particle indices in a separate dense array the size of this array is equal to the number of particles the particles are sorted such that the particles contained in one cell are next to each other an entry in the grid array now tells us where the first particle of this cell is located in the particle array we can compute the number of particles in the cell by looking where the next cell starts to make this work for the last cell we need an additional entry called a guard therefore the size of the grid array is num x times num y plus one what if our simulation is not contained in a bounded grid in this case we don't have the numbers num x num y and num z spatial hashing helps in this case the idea is very simple we use an array of any size to compute the position of a cell in the array we use a random function that takes as input x i and y i the coordinates of the cell and output the position in the array i using the modular operator we make sure that i lies between 0 and table size -1 however this way it can happen that different cells map to the same entry in the array like the green and the yellow cell here this is called a hash collision however in our case this is not a problem we simply get false positives meaning we will see particles that are further away they will be filtered when checking the distances however hash collisions slow down the computation due to additional checks therefore the hash function should return a value that distributes the cells evenly here is a function that i usually use obviously large hash tables produce fewer collisions and therefore fewer tests and faster running times choosing the hash table size to be equal to the number of particles works well the final question is how do we create the data structure efficiently first we initialize the table array with all zeros then we iterate through all the particles compute the hash value of the cell and increase the corresponding value in the array in this case we have two particles in the blue cell two in the yellow cell and one in the green cell next we run through this array and compute partial sums now the hash table almost has the correct values the difference is that each number points to the last cell entry plus one instead of to the first entry which is what we need for the next steps finally we run through all the particles again and fill them into the particle array the pointer to the cell of particle 1 is stored in the blue entry we first decrease it then we use the entry to put the particle index in the right position in the particle array the cell of particle 2 is stored in the yellow entry again we decrease it by 1 and use it to fill in particle 2 in the right location particle 3 lies in the green cell we first decrease the corresponding pointer and use it to fill in particle 3. particle 4 lies in the yellow cell so we first decrease the corresponding number and put particle 4 in the right location in the particles array finally particle 5 lies in the blue cell so we decrease the pointer here and put 5 in location 0. here is the final result as you can see we have over 13 000 particles in this scene when i hit run they start to move and collide against an invisible cube but they also collide against each other i can visualize these collisions here i turn the color of every particle that collides to yellow and as you can see this demo runs at about 80 milliseconds per frame on my laptop i took most of the code from previous tutorials the core of the implementation is of course the class hash in the constructor we provide the spacing of the grid and the maximal number of objects we store these values in member variables i set the table size to 2 times the maximal number of objects you can play with this number here and see the effect on the performance i call the hash array cell start and the object array cell entries this is because cell start tells us where in the cell entries array the objects of the cell are stored the method hash quartz is the hash function i showed in the slides int chord computes the coordinate of a cell that contains the object with a given coordinate chord these methods are used in the method hash pass it takes as inputs the position of an object and returns the index of the containing cell in the hash table the create method creates the hash given the positions of all the objects first we set the entries of cell start and cell entries to zero then we run through all the objects compute the index of the surrounding cell using the hash function and increase the corresponding entry by one next we compute the partial sums finally we fill in the objects as i explained in the slides the query function shows how to retrieve objects from the hash we provide the position of an object and the maximal distance the query function is general because we can choose a max distance that is larger than degree spacing this is why we have to query a block of cells we iterate through all the cells in the block here the cell start array tells us where in the cell entries array the objects are that are contained in the current cell we then store all the objects in the current cell in the query ids array the balls class stores and simulates a set of balls it's pretty easy to understand if you have watched my previous tutorials here is the simulation method note that we can recreate the hash at every time step because the creation method is so fast therefore we don't need any complicated update operations in the interval collision section we query the hash for every particle as you can see my query distance is 2 times the ball's radius when running through the query array returned by the hash function i have to check whether the balls are actually overlapping this concludes this tutorial thanks for watching and i'll see you in the next one

## Source Code

### 11-hashing.html

```html
<!--
Copyright 2022 Matthias Müller - Ten Minute Physics

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
-->

<!DOCTYPE html>
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<html lang="en">
	<head>
		<title>Spatial Hashing</title>
		<style>
			body {
				font-family: verdana; 
				font-size: 15px;
			}			
			.button {
				background-color: #606060;
				border: none;
				color: white;
				padding: 10px 32px;
				font-size: 16px;
				margin: 4px 2px;
				cursor: pointer;
			}
		</style>
	</head>
	
	<body>

        <h1>Spatial Hashing</h1> 
		<button id = "buttonRun" onclick="run()" class="button">Run</button>
		<button onclick="restart()" class="button">Restart</button>
		<input type = "checkbox" onclick = "onShowColl()"> Show collisions</p>
		<span id = "particleCount">0</span> particles, 
		<span id = "ms">0.000</span> ms per frame

		<br><br>		
        <div id="container"></div>
        
        <script src="https://unpkg.com/three@0.139.2/build/three.min.js"></script>
        <script src="https://unpkg.com/three@0.139.2/examples/js/controls/OrbitControls.js"></script>
		<script>
			
			var threeScene;
			var renderer;
			var camera;
			var cameraControl;	

			// ------------------------------------------------------------------
			class Hash {
				constructor(spacing, maxNumObjects) 
				{
					this.spacing = spacing;
					this.tableSize = 2 * maxNumObjects;
					this.cellStart = new Int32Array(this.tableSize + 1);
					this.cellEntries = new Int32Array(maxNumObjects);
					this.queryIds = new Int32Array(maxNumObjects);
					this.querySize = 0;
				}

				hashCoords(xi, yi, zi) {
					var h = (xi * 92837111) ^ (yi * 689287499) ^ (zi * 283923481);	// fantasy function
					return Math.abs(h) % this.tableSize; 
				}

				intCoord(coord) {
					return Math.floor(coord / this.spacing);
				}

				hashPos(pos, nr) {
					return this.hashCoords(
						this.intCoord(pos[3 * nr]), 
						this.intCoord(pos[3 * nr + 1]),
						this.intCoord(pos[3 * nr + 2]));
				}

				create(pos) {
					var numObjects = Math.min(pos.length / 3, this.cellEntries.length);

					// determine cell sizes

					this.cellStart.fill(0);
					this.cellEntries.fill(0);

					for (var i = 0; i < numObjects; i++) {
						var h = this.hashPos(pos, i);
						this.cellStart[h]++;
					}

					// determine cells starts

					var start = 0;
					for (var i = 0; i < this.tableSize; i++) {
						start += this.cellStart[i];
						this.cellStart[i] = start;
					}
					this.cellStart[this.tableSize] = start;	// guard

					// fill in objects ids

					for (var i = 0; i < numObjects; i++) {
						var h = this.hashPos(pos, i);
						this.cellStart[h]--;
						this.cellEntries[this.cellStart[h]] = i;
					}
				}

				query(pos, nr, maxDist) {
					var x0 = this.intCoord(pos[3 * nr] - maxDist);
					var y0 = this.intCoord(pos[3 * nr + 1] - maxDist);
					var z0 = this.intCoord(pos[3 * nr + 2] - maxDist);

					var x1 = this.intCoord(pos[3 * nr] + maxDist);
					var y1 = this.intCoord(pos[3 * nr + 1] + maxDist);
					var z1 = this.intCoord(pos[3 * nr + 2] + maxDist);

					this.querySize = 0;

					for (var xi = x0; xi <= x1; xi++) {
						for (var yi = y0; yi <= y1; yi++) {
							for (var zi = z0; zi <= z1; zi++) {
								var h = this.hashCoords(xi, yi, zi);
								var start = this.cellStart[h];
								var end = this.cellStart[h + 1];

								for (var i = start; i < end; i++) {
									this.queryIds[this.querySize] = this.cellEntries[i];
									this.querySize++;
								}
							}
						}
					}
				}
			};

			// ----- math on vector arrays -------------------------------------------------------------

			function vecScale(a,anr, scale) {
				anr *= 3;
				a[anr++] *= scale;
				a[anr++] *= scale;
				a[anr]   *= scale;
			}

			function vecCopy(a,anr, b,bnr) {
				anr *= 3; bnr *= 3;
				a[anr++] = b[bnr++]; 
				a[anr++] = b[bnr++]; 
				a[anr]   = b[bnr];
			}
			
			function vecAdd(a,anr, b,bnr, scale = 1.0) {
				anr *= 3; bnr *= 3;
				a[anr++] += b[bnr++] * scale; 
				a[anr++] += b[bnr++] * scale; 
				a[anr]   += b[bnr] * scale;
			}

			function vecSetDiff(dst,dnr, a,anr, b,bnr, scale = 1.0) {
				dnr *= 3; anr *= 3; bnr *= 3;
				dst[dnr++] = (a[anr++] - b[bnr++]) * scale;
				dst[dnr++] = (a[anr++] - b[bnr++]) * scale;
				dst[dnr]   = (a[anr] - b[bnr]) * scale;
			}

			function vecLengthSquared(a,anr) {
				anr *= 3;
				let a0 = a[anr], a1 = a[anr + 1], a2 = a[anr + 2];
				return a0 * a0 + a1 * a1 + a2 * a2;
			}

			function vecDistSquared(a,anr, b,bnr) {
				anr *= 3; bnr *= 3;
				let a0 = a[anr] - b[bnr], a1 = a[anr + 1] - b[bnr + 1], a2 = a[anr + 2] - b[bnr + 2];
				return a0 * a0 + a1 * a1 + a2 * a2;
			}	

			function vecDot(a,anr, b,bnr) {
				anr *= 3; bnr *= 3;
				return a[anr] * b[bnr] + a[anr + 1] * b[bnr + 1] + a[anr + 2] * b[bnr + 2];
			}	

			// ------------------------------------------------------------------

			var physicsScene = 
			{
				gravity : [0.0, 0.0, 0.0],
				dt : 1.0 / 60.0,
				worldBounds :  [-1.0, 0.0, -1.0, 1.0, 2.0, 1.0],
				paused: true,
				balls: null,
			};

			function onShowColl() {
				if (physicsScene.balls)
					physicsScene.balls.showCollisions = !physicsScene.balls.showCollisions;
			}			
						
			// ------------------------------------------------------------------
			class Balls {
				constructor(radius, pos, vel, scene)
				{
					// physics data 

                    this.radius = radius;
                    this.pos = pos;
					this.prevPos = pos;
                    this.vel = vel;
					this.matrix = new THREE.Matrix4();
					this.numBalls = Math.floor(pos.length / 3);
					this.hash = new Hash(2.0 * radius, this.numBalls);
					this.showCollisions = false;

					this.normal = new Float32Array(3);

					// visual mesh

                    var geometry = new THREE.SphereGeometry( radius, 8, 8 );
                    var material = new THREE.MeshPhongMaterial();

					this.visMesh = new THREE.InstancedMesh( geometry, material, this.numBalls );
					this.visMesh.instanceMatrix.setUsage(THREE.DynamicDrawUsage); 

					this.ballColor = new THREE.Color(0xFF0000);
					this.ballCollisionColor = new THREE.Color(0xFF8000);

					var colors = new Float32Array(3 * this.numBalls);
					this.visMesh.instanceColor = new THREE.InstancedBufferAttribute(colors, 3, false, 1);
					for (var i = 0; i < this.numBalls; i++) 
						this.visMesh.setColorAt(i, this.ballColor);

                    threeScene.add(this.visMesh);

					this.updateMesh();
				}

				updateMesh()
				{
					for (var i = 0; i < this.numBalls; i++) {
						this.matrix.makeTranslation(this.pos[3 * i], this.pos[3 * i + 1], this.pos[3 * i + 2]);
						this.visMesh.setMatrixAt(i, this.matrix);
					}
					this.visMesh.instanceMatrix.needsUpdate = true;
					this.visMesh.instanceColor.needsUpdate = true;
				}
			
				simulate(dt, gravity, worldBounds)
				{
					var minDist = 2.0 * this.radius;

					// integrate

					for (var i = 0; i < this.numBalls; i++) {
						vecAdd(this.vel, i, gravity, 0, dt);
						vecCopy(this.prevPos, i, this.pos, i);
						vecAdd(this.pos, i, this.vel, i, dt);
					}

					this.hash.create(this.pos);

					// handle collisions

					for (var i = 0; i < this.numBalls; i++) {

						this.visMesh.setColorAt(i, this.ballColor);

						// world collision

						for (var dim = 0; dim < 3; dim++) {

							var nr = 3 * i + dim;
							if (this.pos[nr] < worldBounds[dim] + this.radius) {
								this.pos[nr] = worldBounds[dim] + this.radius;
								this.vel[nr] = - this.vel[nr];
								if (this.showCollisions)
									this.visMesh.setColorAt(i, this.ballCollisionColor);
							}
							else if (this.pos[nr] > worldBounds[dim + 3] - this.radius) {
								this.pos[nr] = worldBounds[dim + 3] - this.radius;
								this.vel[nr] = - this.vel[nr];
								if (this.showCollisions)
									this.visMesh.setColorAt(i, this.ballCollisionColor);
							}
						}

						//  interball collision

						this.hash.query(this.pos, i, 2.0 * this.radius);

						for (var nr = 0; nr < this.hash.querySize; nr++) {
							var j = this.hash.queryIds[nr];

							vecSetDiff(this.normal, 0, this.pos, i, this.pos, j);
							var d2 = vecLengthSquared(this.normal, 0);

							 // are the balls overlapping?

							if (d2 > 0.0 && d2 < minDist * minDist) {
								var d = Math.sqrt(d2);
								vecScale(this.normal, 0, 1.0 / d);	

								// separate the balls

								var corr = (minDist - d) * 0.5;

								vecAdd(this.pos, i, this.normal, 0, corr);
								vecAdd(this.pos, j, this.normal, 0, -corr);

								// reflect velocities along normal

								var vi = vecDot(this.vel, i, this.normal, 0);
								var vj = vecDot(this.vel, j, this.normal, 0);

								vecAdd(this.vel, i, this.normal, 0, vj - vi);
								vecAdd(this.vel, j, this.normal, 0, vi - vj);

								if (this.showCollisions)
									this.visMesh.setColorAt(i, this.ballCollisionColor);
							}
						}
					}
					this.updateMesh();
				}
			}

			// ------------------------------------------------------------------
			function initPhysics(scene) 
			{
				var radius = 0.025;

				var spacing = 3.0 * radius;
				var velRand = 0.2;

				var s = physicsScene.worldBounds;

				var numX = Math.floor((s[3] - s[0] - 2.0 * spacing) / spacing);
				var numY = Math.floor((s[4] - s[1] - 2.0 * spacing) / spacing);
				var numZ = Math.floor((s[5] - s[2] - 2.0 * spacing) / spacing);

				var pos = new Float32Array(3 * numX * numY * numZ);
				var vel = new Float32Array(3 * numX * numY * numZ);
				vel.fill(0.0);

				for (var xi = 0; xi < numX; xi++) {
					for (var yi = 0; yi < numY; yi++) {
						for (var zi = 0; zi < numZ; zi++) {
							var x = 3 * ((xi * numY + yi) * numZ + zi);
							var y = x + 1;
							var z = x + 2;
							pos[x] = s[0] + spacing + xi * spacing;
							pos[y] = s[1] + spacing + yi * spacing;
							pos[z] = s[2] + spacing + zi * spacing;

							vel[x] = -velRand + 2.0 * velRand * Math.random();
							vel[y] = -velRand + 2.0 * velRand * Math.random();
							vel[z] = -velRand + 2.0 * velRand * Math.random();
						}
					}
				}

				physicsScene.balls = new Balls(radius, pos, vel, threeScene);

				document.getElementById("particleCount").innerHTML = pos.length / 3;		

			}

			var timeFrames = 0;
			var timeSum = 0;	
						
			// ------------------------------------------------------------------
			function simulate() 
			{
				if (physicsScene.paused)
					return;

				var startTime = performance.now();					

				physicsScene.balls.simulate(physicsScene.dt, 
					physicsScene.gravity, physicsScene.worldBounds);

				var endTime = performance.now();
				timeSum += endTime - startTime; 
				timeFrames++;

				if (timeFrames > 10) {
					timeSum /= timeFrames;
					document.getElementById("ms").innerHTML = timeSum.toFixed(3);		
					timeFrames = 0;
					timeSum = 0;
				}
			}
						
			// ------------------------------------------
					
			function initThreeScene() 
			{
				threeScene = new THREE.Scene();
				
				// Lights
				
				threeScene.add( new THREE.AmbientLight( 0x505050 ) );	
				threeScene.fog = new THREE.Fog( 0x000000, 0, 15 );				

				var spotLight = new THREE.SpotLight( 0xffffff );
				spotLight.angle = Math.PI / 5;
				spotLight.penumbra = 0.2;
				spotLight.position.set( 2, 3, 3 );
				spotLight.castShadow = true;
				spotLight.shadow.camera.near = 3;
				spotLight.shadow.camera.far = 10;
				spotLight.shadow.mapSize.width = 1024;
				spotLight.shadow.mapSize.height = 1024;
				threeScene.add( spotLight );

				var dirLight = new THREE.DirectionalLight( 0x55505a, 1 );
				dirLight.position.set( 0, 3, 0 );
				dirLight.castShadow = true;
				dirLight.shadow.camera.near = 1;
				dirLight.shadow.camera.far = 10;

				dirLight.shadow.camera.right = 1;
				dirLight.shadow.camera.left = - 1;
				dirLight.shadow.camera.top	= 1;
				dirLight.shadow.camera.bottom = - 1;

				dirLight.shadow.mapSize.width = 1024;
				dirLight.shadow.mapSize.height = 1024;
				threeScene.add( dirLight );
				
				// Geometry

				var ground = new THREE.Mesh(
					new THREE.PlaneBufferGeometry( 20, 20, 1, 1 ),
					new THREE.MeshPhongMaterial( { color: 0xa0adaf, shininess: 150 } )
				);				

				ground.rotation.x = - Math.PI / 2; // rotates X/Y to X/Z
				ground.receiveShadow = true;
				threeScene.add( ground );
				
				var helper = new THREE.GridHelper( 20, 20 );
				helper.material.opacity = 1.0;
				helper.material.transparent = true;
				helper.position.set(0, 0.002, 0);
				threeScene.add( helper );				
				
				// Renderer

				renderer = new THREE.WebGLRenderer();
				renderer.shadowMap.enabled = true;
				renderer.setPixelRatio( window.devicePixelRatio );
				renderer.setSize( 0.8 * window.innerWidth, 0.8 * window.innerHeight );
				window.addEventListener( 'resize', onWindowResize, false );
				container.appendChild( renderer.domElement );
				
				// Camera
						
				camera = new THREE.PerspectiveCamera( 70, window.innerWidth / window.innerHeight, 0.01, 100);
			    camera.position.set(0, 2, 4);
				camera.updateMatrixWorld();	

				threeScene.add( camera );

				cameraControl = new THREE.OrbitControls(camera, renderer.domElement);
    			cameraControl.zoomSpeed = 2.0;
    			cameraControl.panSpeed = 0.4;
			}

			function onWindowResize() {

				camera.aspect = window.innerWidth / window.innerHeight;
				camera.updateProjectionMatrix();
				renderer.setSize( window.innerWidth, window.innerHeight );
			}

			function run() {
				var button = document.getElementById('buttonRun');
				if (physicsScene.paused)
					button.innerHTML = "Stop";
				else
					button.innerHTML = "Run";
				physicsScene.paused = !physicsScene.paused;
			}

			function restart() {
				location.reload();
			}
			
			// make browser to call us repeatedly -----------------------------------

			function update() {
				simulate();
				renderer.render(threeScene, camera);
				cameraControl.update();				
				
				requestAnimationFrame(update);
			}
			
			initThreeScene();
			onWindowResize();
			initPhysics();
			update();
			
		</script>
	</body>
</html>

```
