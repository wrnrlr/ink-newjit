# Chapter 12 — 100x Speedup for Soft Body Simulations

**Video:** https://youtu.be/Noo5sfGGWe0
**Slides:** https://matthias-research.github.io/pages/tenMinutePhysics/12-softBodySkinning.pdf
**Code:** https://raw.githubusercontent.com/matthias-research/pages/master/tenMinutePhysics/12-softBodySkinning.html

## Lecture Notes

### Key Idea: Surface Embedding

A high-resolution visual mesh (60,000 triangles → 300,000 tetrahedra) can be driven by a coarse simulation mesh (3,000 tetrahedra) — the essential motions are the same.

**Two approaches:**
- *Model reduction*: eigenmode decomposition of system matrix — mathematically complex, non-trivial
- **Surface embedding** (this tutorial): tetrahedralize a decimated surface, embed the visual mesh — very simple

---

### Tetrahedral Skinning

Express visual vertex **v** as a weighted sum of the four tet vertices **p**1…**p**4:

**v** = b1·**p**1 + b2·**p**2 + b3·**p**3 + b4·**p**4

The scalars b1…b4 are the **barycentric coordinates** of **v**. They are unique for a non-degenerate tetrahedron.

---

### Computing Barycentric Coordinates

Using the 4th vertex as origin:

**v** − **p**4 = b1(**p**1−**p**4) + b2(**p**2−**p**4) + b3(**p**3−**p**4)

Form the matrix P = [**p**1−**p**4,  **p**2−**p**4,  **p**3−**p**4]:

**b** = P⁻¹ (**v** − **p**4)      where **b** = [b1, b2, b3]^T

Then b4 = 1 − b1 − b2 − b3.

---

### Properties of Barycentric Coordinates

- b1 + b2 + b3 + b4 = 1 always
- All bᵢ ≥ 0 iff **v** is inside the tetrahedron
- **Barycentric distance** (how far outside): d = max(−b1, −b2, −b3, −b4)
- Attach **v** to the tetrahedron with the smallest d (closest)

---

### Attachment Computation

```
for each visual vertex v:
    d_min = ∞
    for each tetrahedron (via spatial hash, inflated bbox):
        if d_min ≤ 0: skip (already inside a tet)
        compute b = P⁻¹(v − p4), d = max(−b1,−b2,−b3,−b4)
        if d < d_min: store attachment (tet, b1,b2,b3,b4), d_min = d
```

Fast enough to run at startup. During simulation: **v** = b1**p**1 + b2**p**2 + b3**p**3 + b4**p**4.


## Video Transcript

hi marcus from 10 minute physics here welcome to tutorial number 12. today i'm going to show you how to speed up soft body simulations by 100x given high resolution visual mesh the idea is to create a lower resolution tetrahedral simulation mesh that still captures all the desired motions and then embeds the visual mesh in the simulation mesh let's start as usual for the slides and demos have a look at my webpage at www.matesmiller.info slash 10 minute physics so here we have a surface mesh of 60 000 triangles and let's say we want to simulate this as a soft body what we can do is tetrahedralize the volume surrounded by this surface mesh however with sixty thousand triangles we probably get something like three hundred thousand tetrahedra which of course yields a very slow simulation now there's a key observation to speed up the simulation the essential motion of this dragon can be captured with a very low resolution simulation mesh so here i use only 3 000 tetrahedra you could probably go even lower there are two main solutions to reduce the complexity of a simulation the first one is model reduction here we start with the high resolution tetrahedral mesh then we decompose the system matrix into eigenmodes which are basically deformation patterns then we select the k most important deformation patterns only the model is mathematically involved especially for non-linear deformations and for collision handling it is also highly non-trivial to implement i will explain to you the method of surface embedding we first create a feature aware decimated surface of the input mesh for instance with blender then we tetrahedralize the simplified surface i will show how to do this in a later tutorial this yields a lower solution tetrahedral mesh then we embed the visual mesh in the volumetric mesh and i will show you how to do this in this tutorial this method is very simple to implement as you will see the idea is as follows let's say we have a vertex of the visual mesh and a tetrahedron that encloses it we want the vertex v to move with the surrounding tetrahedron we can do this by expressing v as a weighted sum of p1 p2 p3 and p4 the particles adjacent to the tetrahedron these scalar values are called the varicentic coordinates of v they're unique for four points not contained in a plane now the question is given the tetrahedron with adjacent particles p1 p2 p3 and p4 and the vertex coordinate v how do we compute the paracentric coordinates first we observe that we can move all the points v p1 p2 p3 and p4 by the same amount without changing the result so here i subtract p4 from all these points the result is that the last term drops out because we have p4 minus p4 which is zero this means that we are left with only three unknowns we can put these three scalar values into one three-dimensional vector b we can also define a matrix p with the columns p1 minus p4 p2 minus p4 and p3 minus p4 now we can write this equation here in a more compact way it's now also possible to solve for the vector b what we have to do is invert the matrix p and multiply it by v minus p4 now we only have the first three bar centric coordinates to derive b4 we use the translated equation here if we move p4 to the other side and multiply out these terms we get this form here as you can see the scalar in front of p4 is 1 minus p1 minus b2 minus b3 which is b4 barycentric coordinates have some interesting properties for instance they sum to 1. we can easily see this from this equation here by moving b4 to the other side also for all the points in the tetrahedron and only for them all the four barycentric coordinates are greater or equal to zero for points outside the tetrahedron the interpolation still works but it might introduce potential artifacts i will show how to solve this problem in an upcoming tutorial we can also define a barycentric distance of a point to a tetrahedron i define it as the maximum value of the negative barycentric coordinates as you can see the distance is negative if the point is inside the tetrahedron and positive if it's outside if a vertex is not contained in any tetrahedron we attach it to the tetrahedron with the smallest distance before the simulation starts we have to compute all the barycentric coordinates of all the vertices of the visual mesh to do this we store a value d min with each vertex and initialize it with infinity then we store all the vertices in a hash grid for each tetrahedron we compute an inflated bounding box we use this to query the vertex hash for each vertex returned by the query we check whether the corresponding value d min is smaller than zero if so we already found the containing tetrahedron if not we compute the barycentric coordinates of the returned vertex with respect to the current tetrahedron d if d is smaller than the d min value of the vertex we overwrite the min and replace the attachment this process is fast enough so we can do it on the fly before each simulation so let's implement this this demo is an extension of the demo we wrote in tutorial number 10 about soft body simulation i also added the hash class we wrote in tutorial number 11. at the very bottom of the file we have the meshes first the tetrahedral mesh with its vertices here you see the indices of the tetrahedra four consecutive numbers define one tetrahedron we also have the edge indices of the tetrahedra for visualization here is the definition of the visual mesh first we have the vertices and finally the indices of the triangles i compute the barycentric coordinates of all vertices in a method of the class softbody here i first create a hash for all the visual vertices then i define the mint list array and fill it with number.maximum value next i run through all the tetrahedra instead of computing a bounding box as mentioned in the slides i actually compute a bounding sphere i use it to query the hash before iterating through all the vertices returned by the hash i compute the inverse of the matrix p if mean distance of the current vertex is smaller or equal to 0 we know that we already found the surrounding tetrahedron otherwise we computed the barycentric coordinates and the new distance if the new distance is smaller than the min distance we update the min distance and overrides the scanning information after each time step we call update visual mesh which does the skinning we iterate through all the visual vertices first we get the tetrahedral number the vertex is attached to then we reach the barycentric coordinates next we get the indices of all the particles adjacent to the tetrahedron and compute the weighted sum using the positions of the particles adjacent to the tetrahedron so here is our final demo as you can see the mesh with almost 60 000 triangles simulates very fast we also have all the necessary deformation modes i can show the tetrahedral mesh here since we're using the method i presented in tutorial number 10 the simulation is also unbreakable this concludes this tutorial i hope you enjoyed it thanks for watching and i'll see you in the next one

## Source Code

### 12-softBodySkinning.html

```html
<!--
Copyright 2022 Matthias Müller - Ten Minute Physics, https://www.youtube.com/channel/UCTG_vrRdKYfrpqCv_WV4eyA

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
-->

<!DOCTYPE html>
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<html lang="en">
	<head>
		<title>Soft Body Simulation</title>
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

        <h1>Soft Body Simulation</h1> 
		<button id = "buttonRun" onclick="run()" class="button">Run</button>
		<button onclick="restart()" class="button">Restart</button>
		<button onclick="squash()" class="button">Squash</button>
		<input type = "checkbox" onclick = "onShowTets()"> Show tets</p>
	
		<span id = "numTets">0</span> tets&nbsp;&nbsp;
		<span id = "numTris">0</span> tris&nbsp;&nbsp;
		<span id = "numVerts">0</span> verts&nbsp;&nbsp;
		Compliance:
		<input type = "range" min = "0" max = "10" value = "0" id = "complianceSlider" class = "slider"> 


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

			function matGetDeterminant(A) {
				let a11 = A[0], a12 = A[3], a13 = A[6];
				let a21 = A[1], a22 = A[4], a23 = A[7];
				let a31 = A[2], a32 = A[5], a33 = A[8];
				return a11*a22*a33 + a12*a23*a31 + a13*a21*a32 - a13*a22*a31 - a12*a21*a33 - a11*a23*a32;
			}

			function matSetMult(A, a,anr, b,bnr) {
				bnr *= 3;
				var bx = b[bnr++];
				var by = b[bnr++];
				var bz = b[bnr];
				vecSetZero(a,anr);
				vecAdd(a,anr, A,0, bx);
				vecAdd(a,anr, A,1, by);
				vecAdd(a,anr, A,2, bz);
			}

			function matSetInverse(A) {
				let det = matGetDeterminant(A);
				if (det == 0.0) {
					for (let i = 0; i < 9; i++)
						A[anr + i] = 0.0;
						return;
				}
				let invDet = 1.0 / det;
				let a11 = A[0], a12 = A[3], a13 = A[6];
				let a21 = A[1], a22 = A[4], a23 = A[7];
				let a31 = A[2], a32 = A[5], a33 = A[8]
				A[0] =  (a22 * a33 - a23 * a32) * invDet; 
				A[3] = -(a12 * a33 - a13 * a32) * invDet;
				A[6] =  (a12 * a23 - a13 * a22) * invDet;
				A[1] = -(a21 * a33 - a23 * a31) * invDet;
				A[4] =  (a11 * a33 - a13 * a31) * invDet;
				A[7] = -(a11 * a23 - a13 * a21) * invDet;
				A[2] =  (a21 * a32 - a22 * a31) * invDet;
				A[5] = -(a11 * a32 - a12 * a31) * invDet;
				A[8] =  (a11 * a22 - a12 * a21) * invDet;
			}

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
				numSubsteps : 10,
				paused: true,
				showTets : false,
				objects: [],				
			};

			// ------------------------------------------------------------------
			function onShowTets() 
			{
				gPhysicsScene.showTetMesh = !gPhysicsScene.showTetMesh;
				for (var i = 0; i < gPhysicsScene.objects.length; i++)
					gPhysicsScene.objects[i].tetMesh.visible = gPhysicsScene.showTetMesh;
			}			

			// ------------------------------------------------------------------
			class SoftBody {
				constructor(tetMesh, visMesh, scene, edgeCompliance = 0.0, volCompliance = 0.0)
				{
					// physics

					this.numParticles = tetMesh.verts.length / 3;
					this.numTets = tetMesh.tetIds.length / 4;
					this.pos = new Float32Array(tetMesh.verts);
					this.prevPos = tetMesh.verts.slice();
					this.vel = new Float32Array(3 * this.numParticles);

					this.tetIds = tetMesh.tetIds;
					this.edgeIds = tetMesh.edgeIds;
					this.restVol = new Float32Array(this.numTets);
					this.edgeLengths = new Float32Array(this.edgeIds.length / 2);	
					this.invMass = new Float32Array(this.numParticles);

					this.edgeCompliance = edgeCompliance;
					this.volCompliance = volCompliance;

					this.temp = new Float32Array(4 * 3);
					this.grads = new Float32Array(4 * 3);

					this.grabId = -1;
					this.grabInvMass = 0.0;

					this.initPhysics();

					// visual tet mesh

					var geometry = new THREE.BufferGeometry();
					geometry.setAttribute('position', new THREE.BufferAttribute(this.pos, 3));
					geometry.setIndex(tetMesh.edgeIds);
					var lineMaterial = new THREE.LineBasicMaterial({color: 0xffffff, linewidth: 2});
					this.tetMesh = new THREE.LineSegments(geometry, lineMaterial);
					this.tetMesh.visible = true;
					scene.add(this.tetMesh);
					this.tetMesh.visible = false;

					// visual embedded mesh

					this.numVisVerts = visMesh.verts.length / 3;
					this.skinningInfo = new Float32Array(4 * this.numVisVerts);
					this.computeSkinningInfo(visMesh.verts);

					geometry = new THREE.BufferGeometry();
					geometry.setAttribute('position', new THREE.BufferAttribute(
						new Float32Array(3 * this.numVisVerts), 3));
					geometry.setIndex(visMesh.triIds);
					var visMaterial = new THREE.MeshPhongMaterial({color: 0xf78a1d});
					this.visMesh = new THREE.Mesh(geometry, visMaterial);
					this.visMesh.castShadow = true;
					this.visMesh.userData = this;	// for raycasting
					this.visMesh.layers.enable(1);
					scene.add(this.visMesh);
					geometry.computeVertexNormals();
					this.updateVisMesh();

					this.volIdOrder = [[1,3,2], [0,2,3], [0,3,1], [0,1,2]];
				}

				computeSkinningInfo(visVerts)
				{
					// create a hash for all vertices of the visual mesh

					var hash = new Hash(0.05, this.numVisVerts);
					hash.create(visVerts);

					this.skinningInfo.fill(-1.0);		// undefined

					var minDist = new Float32Array(this.numVisVerts);
					minDist.fill(Number.MAX_VALUE);
					var border = 0.05;

					// each tet searches for containing vertices

					var tetCenter = new Float32Array(3);
					var mat = new Float32Array(9);
					var bary = new Float32Array(4);

					for (var i = 0; i < this.numTets; i++) {

						// compute bounding sphere of tet

						tetCenter.fill(0.0);
						for (var j = 0; j < 4; j++)
							vecAdd(tetCenter, 0, this.pos, this.tetIds[4 * i + j], 0.25);

						var rMax = 0.0;
						for (var j = 0; j < 4; j++) {
							var r2 = vecDistSquared(tetCenter, 0, this.pos, this.tetIds[4 * i + j]);
							rMax = Math.max(rMax, Math.sqrt(r2));
						}

						rMax += border;

						hash.query(tetCenter, 0, rMax);
						if (hash.queryIds.length == 0)
							continue;

						var id0 = this.tetIds[4 * i];
						var id1 = this.tetIds[4 * i + 1];
						var id2 = this.tetIds[4 * i + 2];
						var id3 = this.tetIds[4 * i + 3];

						vecSetDiff(mat, 0, this.pos, id0, this.pos, id3);
						vecSetDiff(mat, 1, this.pos, id1, this.pos, id3);
						vecSetDiff(mat, 2, this.pos, id2, this.pos, id3);

						matSetInverse(mat);

						for (var j = 0; j < hash.queryIds.length; j++) {
							var id = hash.queryIds[j];

							// we already have skinning info

							if (minDist[id] <= 0.0)
								continue;

							if (vecDistSquared(visVerts, id, tetCenter, 0) > rMax * rMax)
								continue;

							// compute barycentric coords for candidate

							vecSetDiff(bary,0, visVerts,id, this.pos, id3);
							matSetMult(mat, bary,0, bary,0);
							bary[3] = 1.0 - bary[0] - bary[1] - bary[2];

							var dist = 0.0;
							for (var k = 0; k < 4; k++)
								dist = Math.max(dist, -bary[k]);
								
							if (dist < minDist[id]) {
								minDist[id] = dist;
								this.skinningInfo[4 * id] = i;
								this.skinningInfo[4 * id + 1] = bary[0];
								this.skinningInfo[4 * id + 2] = bary[1];
								this.skinningInfo[4 * id + 3] = bary[2];
							}
						}
					}
				}

				getTetVolume(nr) 
				{
					var id0 = this.tetIds[4 * nr];
					var id1 = this.tetIds[4 * nr + 1];
					var id2 = this.tetIds[4 * nr + 2];
					var id3 = this.tetIds[4 * nr + 3];
					vecSetDiff(this.temp,0, this.pos,id1, this.pos,id0);
					vecSetDiff(this.temp,1, this.pos,id2, this.pos,id0);
					vecSetDiff(this.temp,2, this.pos,id3, this.pos,id0);
					vecSetCross(this.temp,3, this.temp,0, this.temp,1);
					return vecDot(this.temp,3, this.temp,2) / 6.0;
				}

				initPhysics() 
				{
					this.invMass.fill(0.0);
					this.restVol.fill(0.0);

					for (var i = 0; i < this.numTets; i++) {
						var vol =this.getTetVolume(i);
						this.restVol[i] = vol;
						var pInvMass = vol > 0.0 ? 1.0 / (vol / 4.0) : 0.0;
						this.invMass[this.tetIds[4 * i]] += pInvMass;
						this.invMass[this.tetIds[4 * i + 1]] += pInvMass;
						this.invMass[this.tetIds[4 * i + 2]] += pInvMass;
						this.invMass[this.tetIds[4 * i + 3]] += pInvMass;
					}
					for (var i = 0; i < this.edgeLengths.length; i++) {
						var id0 = this.edgeIds[2 * i];
						var id1 = this.edgeIds[2 * i + 1];
						this.edgeLengths[i] = Math.sqrt(vecDistSquared(this.pos,id0, this.pos,id1));
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
					this.solveEdges(this.edgeCompliance, dt);
					this.solveVolumes(this.volCompliance, dt);
				}

				postSolve(dt)
				{
					for (var i = 0; i < this.numParticles; i++) {
						if (this.invMass[i] == 0.0)
							continue;
						vecSetDiff(this.vel,i, this.pos,i, this.prevPos,i, 1.0 / dt);
					}
				}

				solveEdges(compliance, dt) {
					var alpha = compliance / dt /dt;

					for (var i = 0; i < this.edgeLengths.length; i++) {
						var id0 = this.edgeIds[2 * i];
						var id1 = this.edgeIds[2 * i + 1];
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
						var restLen = this.edgeLengths[i];
						var C = len - restLen;
						var s = -C / (w + alpha);
						vecAdd(this.pos,id0, this.grads,0, s * w0);
						vecAdd(this.pos,id1, this.grads,0, -s * w1);
					}
				}

				solveVolumes(compliance, dt) {
					var alpha = compliance / dt /dt;

					for (var i = 0; i < this.numTets; i++) {
						var w = 0.0;
						
						for (var j = 0; j < 4; j++) {
							var id0 = this.tetIds[4 * i + this.volIdOrder[j][0]];
							var id1 = this.tetIds[4 * i + this.volIdOrder[j][1]];
							var id2 = this.tetIds[4 * i + this.volIdOrder[j][2]];

							vecSetDiff(this.temp,0, this.pos,id1, this.pos,id0);
							vecSetDiff(this.temp,1, this.pos,id2, this.pos,id0);
							vecSetCross(this.grads,j, this.temp,0, this.temp,1);
							vecScale(this.grads,j, 1.0/6.0);

							w += this.invMass[this.tetIds[4 * i + j]] * vecLengthSquared(this.grads,j);
						}
						if (w == 0.0)
							continue;

						var vol = this.getTetVolume(i);
						var restVol = this.restVol[i];
						var C = vol - restVol;
						var s = -C / (w + alpha);

						for (var j = 0; j < 4; j++) {
							var id = this.tetIds[4 * i + j];
							vecAdd(this.pos,id, this.grads,j, s * this.invMass[id])
						}
					}
				}

				endFrame() 
				{
					this.updateTetMesh();
					this.updateVisMesh();
				}

				updateTetMesh()
				{
					const positions = this.tetMesh.geometry.attributes.position.array;
					for (let i = 0; i < this.pos.length; i++) 
						positions[i] = this.pos[i];
					this.tetMesh.geometry.attributes.position.needsUpdate = true;
					this.tetMesh.geometry.computeBoundingSphere();
				}	

				updateVisMesh()
				{
					const positions = this.visMesh.geometry.attributes.position.array;
					var nr = 0;
					for (let i = 0; i < this.numVisVerts; i++) {
						var tetNr = this.skinningInfo[nr++] * 4;
						if (tetNr < 0) {
							nr += 3;
							continue;
						}
						var b0 = this.skinningInfo[nr++];
						var b1 = this.skinningInfo[nr++];
						var b2 = this.skinningInfo[nr++];
						var b3 = 1.0 - b0 - b1 - b2;
						var id0 = this.tetIds[tetNr++];
						var id1 = this.tetIds[tetNr++];
						var id2 = this.tetIds[tetNr++];
						var id3 = this.tetIds[tetNr++];
						vecSetZero(positions,i);
						vecAdd(positions,i, this.pos,id0, b0);
						vecAdd(positions,i, this.pos,id1, b1);
						vecAdd(positions,i, this.pos,id2, b2);
						vecAdd(positions,i, this.pos,id3, b3);
					}
					this.visMesh.geometry.computeVertexNormals();
					this.visMesh.geometry.attributes.position.needsUpdate = true;
					this.visMesh.geometry.computeBoundingSphere();
				}			

				squash() {
					for (var i = 0; i < this.numParticles; i++) {
						this.pos[3 * i + 1] = 0.5;
					}
					this.endFrame();
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
				var body = new SoftBody(dragonTetMesh, dragonVisMesh, gThreeScene);
				gPhysicsScene.objects.push(body); 
				document.getElementById("numTets").innerHTML = body.numTets;
				document.getElementById("numTris").innerHTML = dragonVisMesh.triIds.length / 3;
				document.getElementById("numVerts").innerHTML = dragonVisMesh.verts.length / 3;
			}

			// ------------------------------------------------------------------
			function simulate() 
			{
				if (gPhysicsScene.paused)
					return;

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
			    gCamera.position.set(0, 1, 4);
				gCamera.updateMatrixWorld();	

				gThreeScene.add(gCamera);

				gCameraControl = new THREE.OrbitControls(gCamera, gRenderer.domElement);
				gCameraControl.zoomSpeed = 2.0;
    			gCameraControl.panSpeed = 0.4;

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

			document.getElementById("complianceSlider").oninput = function() {
				for (var i = 0; i < gPhysicsScene.objects.length; i++) 
					gPhysicsScene.objects[i].edgeCompliance = this.value * 10.0;
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

			function squash() {
				for (var i = 0; i < gPhysicsScene.objects.length; i++)
					gPhysicsScene.objects[i].squash();
				if (!gPhysicsScene.paused)
					run();
			}
			
			// make browser to call us repeatedly -----------------------------------

			function update() {
				simulate();
				gRenderer.render(gThreeScene, gCamera);
				requestAnimationFrame(update);
			}
			
			var dragonTetMesh = 
			{
				verts : [ /* 41,340 chars of embedded mesh/geometry data (~7,380 values) truncated for readability */ ],
				tetIds : [ /* 63,065 chars of embedded mesh/geometry data (~20,916 values) truncated for readability */ ],
				edgeIds : [ /* 63,985 chars of embedded mesh/geometry data (~16,569 values) truncated for readability */ ] };


	var dragonVisMesh = 
	{
	verts : [ /* 938,462 chars of embedded mesh/geometry data (~180,096 values) truncated for readability */ ],
triIds : [ /* 1,284,925 chars of embedded mesh/geometry data (~177,192 values) truncated for readability */ ]
			};
	
	
			initThreeScene();
			onWindowResize();
			initPhysics();
			update();
			
		</script>
	</body>
</html>

```
