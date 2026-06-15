# Chapter 14 — The Secret of Cloth Simulation

**Video:** https://youtu.be/z5oWopN39OU
**Slides:** https://matthias-research.github.io/pages/tenMinutePhysics/14-cloth.pdf
**Code:** https://raw.githubusercontent.com/matthias-research/pages/master/tenMinutePhysics/14-cloth.html

## Lecture Notes

### The Secret: Cloth Only Bends

Real cloth barely stretches (0–5% elongation under gravity). The force-vs-elongation curve is nearly flat. Too much stretch is a visible artifact; too little is never noticeable.

**Conclusion:** model cloth as an **infinitely stiff** material in the stretch direction.

- Force-based infinite stiffness → numerical explosion
- **Solution:** zero-compliance distance constraints with XPBD

No spring stiffness parameter needed. Sub-steps converge fast.

---

### Cloth Simulation Setup

1. Triangulate the cloth surface
2. One particle per vertex
3. Zero-compliance distance constraint per edge (stretch resistance)
4. Optional: bending constraint per pair of adjacent triangles

---

### Bending Resistance

Two adjacent triangles share edge **p**1–**p**2; opposing vertices are **p**3 and **p**4.

**Option A — Diagonal distance constraint** (simple):
- Add a compliant distance constraint between **p**3 and **p**4
- Weak when the cloth is flat (diagonal is short)

**Option B — Dihedral angle constraint** (strong in flat state, more expensive):
- Constrains the angle between the two triangle normals

One tunable parameter: bending compliance α.

---

### Finding Triangle Neighbors

To build the bending constraint list:

1. Define `globalEdgeNr = 3 * triNr + localEdgeNr`
2. Build edge list of `{min(id0, id1), max(id0, id1), globalEdgeNr}` tuples
3. Sort by vertex IDs
4. Find adjacent pairs (matching vertex IDs) → they are the bending constraint particles

Result: an `edgeNeighborList` array parallel to the edge list.


## Video Transcript

hi maltese from telugu physics here welcome to tutorial number 14. today i'm gonna reveal the secret of class simulation we will use it to write a very fast demo that simulates 6 000 triangles at 30 frames per second on my three-year-old cell phone let's start this is my galaxy s10 as you can see simulating this piece of cloth with over 6 000 triangles takes about 20 milliseconds per frame this is the same demo on my desktop as you can see it only takes about 13 milliseconds per frame it's also unconditionally stable the reason is that i use xpbd or extended position based dynamics this is the method i advocate on this channel have a look at tutorial number nine where i explain it in detail as usual for the slides and demos have a look at my web page at www.martiasmiller.info 10 minute physics so let me reveal the secret of class simulation it's very simple cloth only bends of course as rigid bodies are not perfectly rigid cloth is stretchable however typically only between zero and five percent and has a very strong stretch limit when you apply a force it stretches a little bit but then keeps its length as you increase the force try it at home try it with shirts jeans skirts leather jackets rain jackets towels curtains tents tarpaulin flags and carpets gravity is rarely strong enough to cause noticeable stretching i have never noticed too little stretching in a cloth simulation however too much stretching is a bad visual artifact what about latex or other stretchable material well there you don't have dynamics it's just quasi-static motion so you can use skeletal skinning to animate this so what's the conclusion forget about all sophisticated cloth models they simulate this very small part of the force elongation curve what we want is to simulate an infinitely stiff material but how force-based methods explode the solution is the xpbd or extended position based dynamics method we simply use zero compliance distance constraints on the cloth mesh edges the cool thing is there are no parameters to tune the only remaining effect is bending resistance and we only have one parameter for this we can handle this as a constraint between two neighboring triangles there are two popular approaches here in the first one we add an additional distance constraint between the opposing particles it's simple but weak in the flat state the other solution is to use the angle between the two triangles such a constraint is strongly the flat state but more expensive to simulate i will talk about it in a future tutorial since we need triangle neighbors to create bending constraints i'll show you how to find these neighbors fast first we define a global etch number which is three times the triangle number plus the local etch number in this example we have edges 0 1 2 of triangle 0 and 3 4 5 of triangle 1. first we create a list for each edge the first entry is the minimum of the indices the second one the maximum of the indices and the third one the global edge number it's important that the indices are sorted now we sort the entire list as you can see adjacent edges appear next to each other from this information we can compute an edge neighbor list a -1 means the edge is open now if you want to know what the neighbor of triangle 0 across local h2 is we first compute the global edge number in this case it's two we check the neighbor list and read a four four means it's triangle one with local edge number one as you can see this is the correct result now let's have a look at the code i took the code mostly from the softbody example these are the fast vector functions that operates directly on float32 arrays the function finds triangle neighbors is the implementation of the method that i just explained first i run through all the triangles and all their edges and creates the edge list next the edge list is sorted then i run through all the entries of the sorted list if the indices of two consecutive entries in the list are equal then i fill in the neighbor list accordingly the cloth class is very similar to the soft body class an important difference is how to create the constraints here i first compute the neighbors then i run through all the triangles and all their edges for each edge i create a distance constraint for each triangle pair i create a bending constraint i store all the four indices of the triangle neighbors for a simple bending constraint we only need id2 and id3 however for a future implementation in which i will use the angles between the triangles i will use all four indices here i create the visual meshes the edge mesh and the triangle mesh this is the implementation of xpbd the first loop updates all the velocities and all the positions of the particles here we solve the constraints we have two types the stretching and the bending constraints after this we update the velocities this is the code to solve a distance constraint that i showed many times before since we use distance constraint for bending resistance the code is identical the difference is that we now use the bending ids this concludes the tutorial i hope you enjoyed it thanks for watching and i'll see you in the next one

## Source Code

### 14-cloth.html

```html
<!--
Copyright 2022 Matthias Müller - Ten Minute Physics, 
https://www.youtube.com/channel/UCTG_vrRdKYfrpqCv_WV4eyA
www.matthiasMueller.info/tenMinutePhysics

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
-->

<!DOCTYPE html>
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<html lang="en">
	<head>
		<title>Cloth Simulation</title>
		<style>
			body {
				font-family: verdana; 
				font-size: 15px;
			}			
			.button {
			background-color: #606060;
			border: none;
			color: white;
			padding: 15px 32px;
			font-size: 16px;
			margin: 4px 2px;
			cursor: pointer;
		}
		</style>	
	</head>
	
	<body>

        <h1>Cloth Simulation</h1> 
		<button id = "buttonRun" onclick="run()" class="button">Run</button>
		<button onclick="restart()" class="button">Restart</button>
		<input type = "checkbox" onclick = "onShowEdges()"> Show edges</p>
	
		<span id = "numTris">0</span> tris&nbsp;&nbsp;
		<span id = "numVerts">0</span> verts&nbsp;&nbsp;
		<span id = "ms">0.000</span> ms per frame
		<br>
		Bending compliance:
		<input type = "range" min = "0" max = "10" value = "1" id = "bendingComplianceSlider" class = "slider"> 


		<br><br>		
        <div id="container"></div>
        
        <script src="https://unpkg.com/three@0.139.2/build/three.min.js"></script>
        <script src="https://unpkg.com/three@0.139.2/examples/js/controls/OrbitControls.js"></script>
		<script>

			// ----- math on vector arrays -------------------------------------------------------------

			function vecSetZero(a,anr) {
				anr *= 3;
				a[anr++] = 0.0;
				a[anr++] = 0.0;
				a[anr]   = 0.0;
			}

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

			function vecSetCross(a,anr, b,bnr, c,cnr) {
				anr *= 3; bnr *= 3; cnr *= 3;
				a[anr++] = b[bnr + 1] * c[cnr + 2] - b[bnr + 2] * c[cnr + 1];
				a[anr++] = b[bnr + 2] * c[cnr + 0] - b[bnr + 0] * c[cnr + 2];
				a[anr]   = b[bnr + 0] * c[cnr + 1] - b[bnr + 1] * c[cnr + 0];
			}			
			
			var gThreeScene;
			var gRenderer;
			var gCamera;
			var gCameraControl;
			var gGrabber;
			var gMouseDown = false;

			// ------------------------------------------------------------------

			var gPhysicsScene = 
			{
				gravity : [0.0, -10.0, 0.0],
				dt : 1.0 / 60.0,
				numSubsteps : 15,
				paused: true,
				showEdges: false,
				objects: [],				
			};

			// ------------------------------------------------------------------
			function onShowEdges() 
			{
				gPhysicsScene.showEdges = !gPhysicsScene.showEdges;
				for (var i = 0; i < gPhysicsScene.objects.length; i++) {
					gPhysicsScene.objects[i].edgeMesh.visible = gPhysicsScene.showEdges;
					gPhysicsScene.objects[i].triMesh.visible = !gPhysicsScene.showEdges;
				}
			}			

			// ------------------------------------------------------------------
			function findTriNeighbors(triIds) 
			{
				// create common edges

				var edges = [];
				var numTris = triIds.length / 3;

				for (var i = 0; i < numTris; i++) {
					for (var j = 0; j < 3; j++) {
						var id0 = triIds[3 * i + j];
						var id1 = triIds[3 * i + (j + 1) % 3];
						edges.push({
							id0 : Math.min(id0, id1), 
							id1 : Math.max(id0, id1), 
							edgeNr : 3 * i + j
						});
					}
				}

				// sort so common edges are next to each other

				edges.sort((a, b) => ((a.id0 < b.id0) || (a.id0 == b.id0 && a.id1 < b.id1)) ? -1 : 1);

				// find matchign edges

				neighbors = new Float32Array(3 * numTris);
				neighbors.fill(-1);		// open edge

				var nr = 0;
				while (nr < edges.length) {
					var e0 = edges[nr];
					nr++;
					if (nr < edges.length) {
						var e1 = edges[nr];
						if (e0.id0 == e1.id0 && e0.id1 == e1.id1) {
							neighbors[e0.edgeNr] = e1.edgeNr;
							neighbors[e1.edgeNr] = e0.edgeNr;
						}
						nr++;
					}
				}

				return neighbors;
			}

			// ------------------------------------------------------------------
			class Cloth {
				constructor(mesh, scene, bendingCompliance = 1.0)
				{
					// particles

					this.numParticles = mesh.vertices.length / 3;
					this.pos = new Float32Array(mesh.vertices);
					this.prevPos = new Float32Array(mesh.vertices);
					this.restPos = new Float32Array(mesh.vertices);
					this.vel = new Float32Array(3 * this.numParticles);
					this.invMass = new Float32Array(this.numParticles);

					// stretching and bending constraints

					neighbors = findTriNeighbors(mesh.faceTriIds);
					var numTris = mesh.faceTriIds.length / 3;
					var edgeIds = [];
					var triPairIds = [];

					for (var i = 0; i < numTris; i++) {
						for (var j = 0; j < 3; j++) {
							var id0 = mesh.faceTriIds[3 * i + j];
							var id1 = mesh.faceTriIds[3 * i + (j + 1) % 3];

							// each edge only once
							var n = neighbors[3 * i + j];
							if (n < 0 || id0 < id1) {
								edgeIds.push(id0);
								edgeIds.push(id1);
							}
							// tri pair
							if (n >= 0) {
								// opposite ids
								var ni = Math.floor(n / 3);
								var nj = n % 3;
								var id2 = mesh.faceTriIds[3 * i + (j + 2) % 3];
								var id3 = mesh.faceTriIds[3 * ni + (nj + 2) % 3];
								triPairIds.push(id0);
								triPairIds.push(id1);
								triPairIds.push(id2);
								triPairIds.push(id3);
							}
						}
					}

					this.stretchingIds = new Int32Array(edgeIds);
					this.bendingIds = new Int32Array(triPairIds);
					this.stretchingLengths = new Float32Array(this.stretchingIds.length / 2);
					this.bendingLengths = new Float32Array(this.bendingIds.length / 4);

					this.stretchingCompliance = 0.0;		
					this.bendingCompliance = bendingCompliance;

					this.temp = new Float32Array(4 * 3);
					this.grads = new Float32Array(4 * 3);

					this.grabId = -1;
					this.grabInvMass = 0.0;

					this.initPhysics(mesh.faceTriIds);

					// visual edge mesh

					var geometry = new THREE.BufferGeometry();
					geometry.setAttribute('position', new THREE.BufferAttribute(this.pos, 3));
					geometry.setIndex(edgeIds);
					var lineMaterial = new THREE.LineBasicMaterial({color: 0xff0000, linewidth: 2});
					this.edgeMesh = new THREE.LineSegments(geometry, lineMaterial);
					this.edgeMesh.visible = false;
					scene.add(this.edgeMesh);

					// visual tri mesh

					geometry = new THREE.BufferGeometry();
					geometry.setAttribute('position', new THREE.BufferAttribute(this.pos, 3));
					geometry.setIndex(mesh.faceTriIds);
					var visMaterial = new THREE.MeshPhongMaterial({color: 0xff0000, side: THREE.DoubleSide});
					this.triMesh = new THREE.Mesh(geometry, visMaterial);
					this.triMesh.castShadow = true;
					this.triMesh.userData = this;	// for raycasting
					
					this.triMesh.layers.enable(1);
					scene.add(this.triMesh);
					geometry.computeVertexNormals();
					
					this.updateMeshes();

					this.volIdOrder = [[1,3,2], [0,2,3], [0,3,1], [0,1,2]];
				}

				initPhysics(triIds) 
				{
					this.invMass.fill(0.0);

					var numTris = triIds.length / 3;
					var e0 = [0.0, 0.0, 0.0];
					var e1 = [0.0, 0.0, 0.0];
					var c = [0.0, 0.0, 0.0];

					for (var i = 0; i < numTris; i++) {
						var id0 = triIds[3 * i];
						var id1 = triIds[3 * i + 1];
						var id2 = triIds[3 * i + 2];
						vecSetDiff(e0,0, this.pos,id1, this.pos,id0);
						vecSetDiff(e1,0, this.pos,id2, this.pos,id0);
						vecSetCross(c,0, e0,0, e1,0);
						var A = 0.5 * Math.sqrt(vecLengthSquared(c,0));
						var pInvMass = A > 0.0 ? 1.0 / A / 3.0 : 0.0;
						this.invMass[id0] += pInvMass;
						this.invMass[id1] += pInvMass;
						this.invMass[id2] += pInvMass;
					}

					for (var i = 0; i < this.stretchingLengths.length; i++) {
						var id0 = this.stretchingIds[2 * i];
						var id1 = this.stretchingIds[2 * i + 1];
						this.stretchingLengths[i] = Math.sqrt(vecDistSquared(this.pos,id0, this.pos,id1));
					}

					for (var i = 0; i < this.bendingLengths.length; i++) {
						var id0 = this.bendingIds[4 * i + 2];
						var id1 = this.bendingIds[4 * i + 3];
						this.bendingLengths[i] = Math.sqrt(vecDistSquared(this.pos,id0, this.pos,id1));
					}

					// attach

					var minX = Number.MAX_VALUE;
					var maxX = -Number.MAX_VALUE;
					var maxY = -Number.MAX_VALUE;

					for (var i = 0; i < this.numParticles; i++) {
						minX = Math.min(minX, this.pos[3 * i]);
						maxX = Math.max(maxX, this.pos[3 * i]);
						maxY = Math.max(maxY, this.pos[3 * i + 1]);
					}
					var eps = 0.0001;

					for (var i = 0; i < this.numParticles; i++) {
						var x = this.pos[3 * i];
						var y = this.pos[3 * i + 1];
						if ((y > maxY - eps) && (x < minX + eps || x > maxX - eps))
							this.invMass[i] = 0.0;
					}
				}

				preSolve(dt, gravity)
				{
					for (var i = 0; i < this.numParticles; i++) {
						if (this.invMass[i] == 0.0)
							continue;
						vecAdd(this.vel,i, gravity,0, dt);
						vecCopy(this.prevPos,i, this.pos,i);
						vecAdd(this.pos,i, this.vel,i, dt);
						var y = this.pos[3 * i + 1];
						if (y < 0.0) {
							vecCopy(this.pos,i, this.prevPos,i);
							this.pos[3 * i + 1] = 0.0;
						}
					}
				}

				solve(dt)
				{
					this.solveStretching(this.stretchingCompliance, dt);
					this.solveBending(this.bendingCompliance, dt);
				}

				postSolve(dt)
				{
					for (var i = 0; i < this.numParticles; i++) {
						if (this.invMass[i] == 0.0)
							continue;
						vecSetDiff(this.vel,i, this.pos,i, this.prevPos,i, 1.0 / dt);
					}
				}

				solveStretching(compliance, dt) {
					var alpha = compliance / dt /dt;

					for (var i = 0; i < this.stretchingLengths.length; i++) {
						var id0 = this.stretchingIds[2 * i];
						var id1 = this.stretchingIds[2 * i + 1];
						var w0 = this.invMass[id0];
						var w1 = this.invMass[id1];
						var w = w0 + w1;
						if (w == 0.0)
							continue;

						vecSetDiff(this.grads,0, this.pos,id0, this.pos,id1);
						var len = Math.sqrt(vecLengthSquared(this.grads,0));
						if (len == 0.0)
							continue;
						vecScale(this.grads,0, 1.0 / len);
						var restLen = this.stretchingLengths[i];
						var C = len - restLen;
						var s = -C / (w + alpha);
						vecAdd(this.pos,id0, this.grads,0, s * w0);
						vecAdd(this.pos,id1, this.grads,0, -s * w1);
					}
				}

				solveBending(compliance, dt) {
					var alpha = compliance / dt /dt;

					for (var i = 0; i < this.bendingLengths.length; i++) {
						var id0 = this.bendingIds[4 * i + 2];
						var id1 = this.bendingIds[4 * i + 3];
						var w0 = this.invMass[id0];
						var w1 = this.invMass[id1];
						var w = w0 + w1;
						if (w == 0.0)
							continue;

						vecSetDiff(this.grads,0, this.pos,id0, this.pos,id1);
						var len = Math.sqrt(vecLengthSquared(this.grads,0));
						if (len == 0.0)
							continue;
						vecScale(this.grads,0, 1.0 / len);
						var restLen = this.bendingLengths[i];
						var C = len - restLen;
						var s = -C / (w + alpha);
						vecAdd(this.pos,id0, this.grads,0, s * w0);
						vecAdd(this.pos,id1, this.grads,0, -s * w1);
					}
				}

				updateMeshes() {
					this.triMesh.geometry.computeVertexNormals();
					this.triMesh.geometry.attributes.position.needsUpdate = true;
					this.triMesh.geometry.computeBoundingSphere();

					this.edgeMesh.geometry.attributes.position.needsUpdate = true;
				}

				endFrame() 
				{
					this.updateMeshes();
				}

				startGrab(pos) 
				{
					var p = [pos.x, pos.y, pos.z];
					var minD2 = Number.MAX_VALUE;
					this.grabId = -1;
					for (let i = 0; i < this.numParticles; i++) {
						var d2 = vecDistSquared(p,0, this.pos,i);
						if (d2 < minD2) {
							minD2 = d2;
							this.grabId = i;
						}
					}

					if (this.grabId >= 0) {
						this.grabInvMass = this.invMass[this.grabId];
						this.invMass[this.grabId] = 0.0;
						vecCopy(this.pos,this.grabId, p,0);	
					}
				}

				moveGrabbed(pos, vel) 
				{
					if (this.grabId >= 0) {
						var p = [pos.x, pos.y, pos.z];
						vecCopy(this.pos,this.grabId, p,0);
					}
				}

				endGrab(pos, vel) 
				{
					if (this.grabId >= 0) {
						this.invMass[this.grabId] = this.grabInvMass;
						var v = [vel.x, vel.y, vel.z];
						vecCopy(this.vel,this.grabId, v,0);
					}
					this.grabId = -1;
				}								
			}

			// ------------------------------------------------------------------
			function initPhysics() 
			{
				var mesh = meshes[0];

				var body = new Cloth(mesh, gThreeScene);
				gPhysicsScene.objects.push(body); 
				document.getElementById("numTris").innerHTML = mesh.faceTriIds.length / 3;
				document.getElementById("numVerts").innerHTML = mesh.vertices.length / 3;
			}

			var timeFrames = 0;
			var timeSum = 0;	

			// ------------------------------------------------------------------
			function simulate() 
			{
				if (gPhysicsScene.paused)
					return;

				var startTime = performance.now();					

				var sdt = gPhysicsScene.dt / gPhysicsScene.numSubsteps;

				for (var step = 0; step < gPhysicsScene.numSubsteps; step++) {

					for (var i = 0; i < gPhysicsScene.objects.length; i++) 
						gPhysicsScene.objects[i].preSolve(sdt, gPhysicsScene.gravity);
					
					for (var i = 0; i < gPhysicsScene.objects.length; i++) 
						gPhysicsScene.objects[i].solve(sdt);

					for (var i = 0; i < gPhysicsScene.objects.length; i++) 
						gPhysicsScene.objects[i].postSolve(sdt);

				}
				for (var i = 0; i < gPhysicsScene.objects.length; i++) 
						gPhysicsScene.objects[i].endFrame();

				gGrabber.increaseTime(gPhysicsScene.dt);

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
				gThreeScene = new THREE.Scene();
				
				// Lights
				
				gThreeScene.add( new THREE.AmbientLight( 0x505050 ) );	
				gThreeScene.fog = new THREE.Fog( 0x000000, 0, 15 );				

				var spotLight = new THREE.SpotLight( 0xffffff );
				spotLight.angle = Math.PI / 5;
				spotLight.penumbra = 0.2;
				spotLight.position.set( 2, 3, 3 );
				spotLight.castShadow = true;
				spotLight.shadow.camera.near = 3;
				spotLight.shadow.camera.far = 10;
				spotLight.shadow.mapSize.width = 1024;
				spotLight.shadow.mapSize.height = 1024;
				gThreeScene.add( spotLight );

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
				gThreeScene.add( dirLight );
				
				// Geometry

				var ground = new THREE.Mesh(
					new THREE.PlaneBufferGeometry( 20, 20, 1, 1 ),
					new THREE.MeshPhongMaterial( { color: 0xa0adaf, shininess: 150 } )
				);				

				ground.rotation.x = - Math.PI / 2; // rotates X/Y to X/Z
				ground.receiveShadow = true;
				gThreeScene.add( ground );
				
				var helper = new THREE.GridHelper( 20, 20 );
				helper.material.opacity = 1.0;
				helper.material.transparent = true;
				helper.position.set(0, 0.002, 0);
				gThreeScene.add( helper );				
				
				// Renderer

				gRenderer = new THREE.WebGLRenderer();
				gRenderer.shadowMap.enabled = true;
				gRenderer.setPixelRatio( window.devicePixelRatio );
				gRenderer.setSize( 0.8 * window.innerWidth, 0.8 * window.innerHeight );
				window.addEventListener( 'resize', onWindowResize, false );
				container.appendChild( gRenderer.domElement );
				
				// Camera
						
				gCamera = new THREE.PerspectiveCamera( 70, window.innerWidth / window.innerHeight, 0.01, 100);
			    gCamera.position.set(0, 1, 1);
				gCamera.updateMatrixWorld();	

				gThreeScene.add(gCamera);

				gCameraControl = new THREE.OrbitControls(gCamera, gRenderer.domElement);
				gCameraControl.zoomSpeed = 2.0;
    			gCameraControl.panSpeed = 0.4;
				gCameraControl.target = new THREE.Vector3(0.0, 0.6, 0.0);
				gCameraControl.update();

				// grabber

				gGrabber = new Grabber();
				container.addEventListener( 'pointerdown', onPointer, false );
				container.addEventListener( 'pointermove', onPointer, false );
				container.addEventListener( 'pointerup', onPointer, false );
			}

			// ------- grabber -----------------------------------------------------------

			class Grabber {
				constructor() {
					this.raycaster = new THREE.Raycaster();
					this.raycaster.layers.set(1);
					this.raycaster.params.Line.threshold = 0.1;
					this.physicsObject = null;
					this.distance = 0.0;
					this.prevPos = new THREE.Vector3();
					this.vel = new THREE.Vector3();
					this.time = 0.0;
				}
				increaseTime(dt) {
					this.time += dt;
				}
				updateRaycaster(x, y) {
					var rect = gRenderer.domElement.getBoundingClientRect();
					this.mousePos = new THREE.Vector2();
					this.mousePos.x = ((x - rect.left) / rect.width ) * 2 - 1;
					this.mousePos.y = -((y - rect.top) / rect.height ) * 2 + 1;
					this.raycaster.setFromCamera( this.mousePos, gCamera );
				}
				start(x, y) {
					this.physicsObject = null;
					this.updateRaycaster(x, y);
					var intersects = this.raycaster.intersectObjects( gThreeScene.children );
					if (intersects.length > 0) {
						var obj = intersects[0].object.userData;
						if (obj) {
							this.physicsObject = obj;
							this.distance = intersects[0].distance;
							var pos = this.raycaster.ray.origin.clone();
							pos.addScaledVector(this.raycaster.ray.direction, this.distance);
							this.physicsObject.startGrab(pos);
							this.prevPos.copy(pos);
							this.vel.set(0.0, 0.0, 0.0);
							this.time = 0.0;
							if (gPhysicsScene.paused)
								run();
						}
					}
				}
				move(x, y) {
					if (this.physicsObject) {
						this.updateRaycaster(x, y);
						var pos = this.raycaster.ray.origin.clone();
						pos.addScaledVector(this.raycaster.ray.direction, this.distance);

						this.vel.copy(pos);
						this.vel.sub(this.prevPos);
						if (this.time > 0.0)
							this.vel.divideScalar(this.time);
						else
							this.vel.set(0.0, 0.0, 0.0);
						this.prevPos.copy(pos);
						this.time = 0.0;

						this.physicsObject.moveGrabbed(pos, this.vel);
					}
				}
				end(x, y) {
					if (this.physicsObject) { 
						this.physicsObject.endGrab(this.prevPos, this.vel);
						this.physicsObject = null;
					}
				}
			}			

			function onPointer( evt ) 
			{
				event.preventDefault();
				if (evt.type == "pointerdown") {
					gGrabber.start(evt.clientX, evt.clientY);
					gMouseDown = true;
					if (gGrabber.physicsObject) {
						gCameraControl.saveState();
						gCameraControl.enabled = false;
					}
				}
				else if (evt.type == "pointermove" && gMouseDown) {
					gGrabber.move(evt.clientX, evt.clientY);
				}
				else if (evt.type == "pointerup") {
					if (gGrabber.physicsObject) {
						gGrabber.end();
						gCameraControl.reset();
					}
					gMouseDown = false;
					gCameraControl.enabled = true;
				}
			}	

			document.getElementById("bendingComplianceSlider").oninput = function() {
				for (var i = 0; i < gPhysicsScene.objects.length; i++) 
					gPhysicsScene.objects[i].bendingCompliance = this.value;
			}
			
			// ------------------------------------------------------

			function onWindowResize() {

				gCamera.aspect = window.innerWidth / window.innerHeight;
				gCamera.updateProjectionMatrix();
				gRenderer.setSize( window.innerWidth, window.innerHeight );
			}

			function run() {
				var button = document.getElementById('buttonRun');
				if (gPhysicsScene.paused)
					button.innerHTML = "Stop";
				else
					button.innerHTML = "Run";
				gPhysicsScene.paused = !gPhysicsScene.paused;
			}

			function restart() {
				location.reload();
			}
			
			// make browser to call us repeatedly -----------------------------------

			function update() {
				simulate();
				gRenderer.render(gThreeScene, gCamera);
				requestAnimationFrame(update);
			}
			
			var meshes = [
				{
					name : "cloth",
					vertices : [ /* 112,582 chars of embedded mesh/geometry data (~19,488 values) truncated for readability */ ],
					faceTriIds : [ /* 124,466 chars of embedded mesh/geometry data (~19,220 values) truncated for readability */ ]
				}
			];
		
			initThreeScene();
			onWindowResize();
			initPhysics();
			update();
			
		</script>
	</body>
</html>

```
