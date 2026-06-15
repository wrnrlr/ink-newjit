# Chapter 20 — How to Write a Height-Field Water Simulation

**Video:** https://youtu.be/hswBi5wcqAA
**Slides:** https://matthias-research.github.io/pages/tenMinutePhysics/20-heightFieldWater.pdf
**Code:** https://raw.githubusercontent.com/matthias-research/pages/master/tenMinutePhysics/20-heightFieldWater.html

## Video Transcript

hi not just from 10 minute physics here Welcome To tutorial number 20. today I'm going to show you how to write a 3d water simulator and the interaction of water with objects in under 100 lines of code here is my water simulation as you can see we have a tank and three balls interacting with the water the density of the yellow ball is larger than the density of water so it sinks to the ground the densities of the orange ball and the red ball are lower than the density of water so they float on the surface since the density of the orange ball is larger than the density of the red ball it is more immersed in the water I also implemented a refraction effect of the water surface as usual I wrote this demo in JavaScript so it runs in any browser I put the direct link to the demo into the description so you can immediately play with it for the demos and the slides of all my tutorials have a look at my web page let me now explain the method that I used to implement the simulation I represent water as an array of columns we can do this on a line or in the plane if we use a line we call this a one and a half dimensional simulation this is because we have a one-dimensional line but the columns poke out of this line if we use a plane then we call this a two and a half dimensional simulation this is because we work on a two-dimensional plane but the columns poke out of this plane there is a variety of advantages when representing water as columns first it's very simple to simulate second we get a fast simulation and third it's easy to extract the water surface there are also a few disadvantages we cannot simulate overturning waves and we don't get splashes we can however add this effect by using an additional particle simulator the grid setup is very simple each column stores a height and a velocity both the height and the velocity are needed to get the dynamic simulation we use the same width as for all the columns to derive the simulation method when using water columns we need Archimedes principle the principle says that any object totally or partially immersed in fluid or liquid is buoyed up by a force equal to the weight of the fluid displaced by the object if we have two water columns next to each other with the same height and velocity zero then we expect nothing to happen so let's assume we have two adjacent water columns with different heights H1 and H2 in this situation we can think of having a balloon here now the question is what's the force acting on the balloon from Archimedes principle we know that the force is proportional to the volume of the balloon the volume of the balloon is proportional to H2 minus H1 this means the force acting on the balloon is proportional to H2 minus H1 from Newton's Second Law we know that the acceleration is proportional to the force from the conservation of volume we know that if the column 1 is accelerated upwards then the column 2 must be accelerated downwards by the same amount to the acceleration of the second column H2 is minus H1 now let's have a look at what happens when you have a column I surrounded by two columns I minus 1 and I Plus 1. now to compute a I we need to consider both Neighbors in the pair I and I plus 1 the column I place the role of the left column as in the slide before therefore AI is proportional to h i plus 1 minus h i in the pair I minus 1i the column I plays the role of the right neighbor therefore we have a minus sign here removing the brackets gives AI is proportional to h i minus 1 plus h i plus 1 minus 2 h i saying a quantity is proportional to another quantity means that the quantity is equal to K the constant of proportionality times the other quantity in our case AI is equal to K times h i minus 1 plus h i plus 1 minus 2 h i where K is a constant from the discretization of the wave equation we can actually derive what the meaning of this constant K is K depends on two other constants C and S the constant C is the wave speed and S is the column width here is the situation of a two and a half dimensional simulation now a column i j is surrounded by four neighbors the equation to compute the acceleration of the column i j is very similar to the formula we got for the one and a half dimensional simulation the acceleration of column i j is proportional to the sum of the height of all the surrounding columns minus four times the height of the column itself the constant of proportionality turns out to be exactly the same as in the one and a half dimensional simulation c squared over s squared where C is the wave speed and S is the column width there's one last problem we have to solve before writing our simulator the problem is that when column i j is on the boundary of the domain then we access a column outside of the boundary there's a very simple solution to this if you want the simulate reflecting boundary conditions then when accessing a column outside of the domain we just use the height of the column i j itself now we are ready to write down the algorithm to simulate the 3D water surface it's extremely simple it consists of two Loops over all the columns in the domain in the first Loop we first compute the acceleration of each column we use the formula we just derived before then given the timestep delta T we can update the velocity of each column by adding delta T times the acceleration then we loop again over all the columns and update the heights we update them by adding delta T times the velocity in this case we use the semi-implicit Euler integration with timestamp delta T to get a stable simulation we have to make sure that waves do not travel further than one grid cell in one time step now let's see how we can simulate the interaction of objects with the water surface we want to have two-way coupling this means we want to know how objects influence the water surface and how the water influences the objects let's first have a look at how the objects influence the water surface here's a very simple way to do this we simply push down all the water columns such that they don't intersect with objects the first problem is volume loss the second problem with this approach is that it doesn't work for fully submerged bodies because we get this void here is my own solution I use an additional field B as before H stores the height of each column the value B stores the height covered by objects now I add a third Loop over all the columns in the simulation algorithm first I compute the change of the values of B between the current timestamp and the previous time step I then add the change of B to the heights of the water columns this change can be positive or negative without bias so volume is conserved the constant Alpha is a number between 0 and 1 and defines the intensity of this effect it's important to smooth the B field to prevent spikes and instabilities now we need the opposite direction as well how the water surface influences objects for this we use Archimedes principle again the force acting on the object is the same as the weight of the water replaced by the object we can compute the weight that's M times G where G is the gravitational acceleration the mass is the density of water times the volume the volume is O times s squared where s is the width of the column this means that for each overlap of an object with a water column we add this Force to the object at the position of the water column I use a very simple method to render the refraction effect on the water surface let me first show you how to render fully transparent plane of course the simplest way to do this would be to just not render anything but there's another method to do this we first render the scene behind the plane to a texture using the current camera then to render fragment of the plane we use the screen coordinates of this fragment to look up the color in the texture now there's a very simple way to get the refraction effect now we use the screen coordinates of the fragment plus an offset to look up the texture color we make this direction dependent on the surface normal the length of this offset is dependent on the distance of the camera to the water surface now let's have a quick look at the code I implemented a class called water surface here is the Constructor the actual simulation starts at line 170 with the simulation of the coupling between bodies and the water surface here you see the method to simulate the surface itself and this is the simulation Loop it ends at Line 270 so we have exactly 100 lines of code as promised as you can see the method to simulate the surface itself is really very simple I run through all the water columns compute the sum of the heights of all the neighbors and subtract the height of the central column itself I multiply this quantity by the time step DT and add this to the velocity in the second loop I add the velocity times DT to the height this is a fragment Shader for the water surface and this is the most important line here UV are the texture coordinates to look up the color in the background texture I use this green position of the fragment but now add R times the normal of the water surface for R I should actually use the distance to the camera however in my very simple implementation I just used a constant for Simplicity I also rendered the entire scene and not just the scene behind the plane so the challenge for you is to fix these two problems if somebody finds a very nice Solution please send me a pull request on GitHub this concludes the tutorial I hope you enjoyed it thanks for watching and I see you in the next one

## Source Code

### 20-heightFieldWater.html

```html
<!DOCTYPE html>
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<html lang="en">
	<head>
		<title>Water 3d</title>
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
		</style>
	</head>
	
	<body>
		<button id = "buttonRun" onclick="run()" class="button">Run</button>
		<button onclick="restart()" class="button">Restart</button>

		<br><br>		
        <div id="container"></div>
        
		<script src="https://unpkg.com/three@0.139.2/build/three.min.js"></script>
		<script src="https://unpkg.com/three@0.139.2/examples/js/controls/OrbitControls.js"></script>
			 
		<script id="waterVertexShader" type="x-shader/x-vertex">
			varying vec3 varNormal;
			varying vec2 varScreenPos;
			varying vec3 varPos;

			void main() {
				vec4 pos = projectionMatrix * modelViewMatrix * vec4(position, 1.0);
				varScreenPos = vec2(0.5, 0.5) + 0.5 * vec2(pos) / pos.z;
				varPos = vec3(position);       
				varNormal = normal;	
				gl_Position = pos;
			}
		</script>

		<script id="waterFragmentShader" type="x-shader/x-fragment">
			uniform sampler2D background;
			varying vec3 varNormal;
			varying vec2 varScreenPos;
			varying vec3 varPos;			

			void main() {
				float r = 0.02;	// todo: should be distance dependent!
				vec2 uv = varScreenPos + r * vec2(varNormal.x, varNormal.z);
				vec4 color = texture2D(background, uv);
				color.z = min(color.z + 0.2, 1.0);

				vec3 L = normalize(vec3(10.0, 10.0, 10.0) - varPos);   
				float s = max(dot(varNormal,L), 0.0); 
				color *= (0.5 + 0.5 * s);
			 
				gl_FragColor = color;
			}
		</script>

		<script>

            // ------------------------------------------------------------------

			// physics scene

			var gPhysicsScene = 
			{
				gravity : new THREE.Vector3(0.0, -10.0, 0.0),
				dt : 1.0 / 30.0,
				tankSize : { x: 2.5, y : 1.0, z : 3.0 },
				tankBorder : 0.03,
				waterHeight : 0.8,
				waterSpacing : 0.02,
				paused: true,
				waterSurface: null,
				objects: []
			};

			// globals
			
			var gThreeScene;
			var gRenderer;
			var gRenderTarget;
			var gCamera;
			var gCameraControl;
			var gWaterMaterial; 
			var gGrabber;
			var gMouseDown;
			var gPrevTime = 0.0;

			// ------------------------------------------------------------------
			class WaterSurface {
				constructor(sizeX, sizeZ, depth, spacing, visMaterial)
				{
					// physics data

					this.waveSpeed = 2.0;
					this.posDamping = 1.0;
					this.velDamping = 0.3;
					this.alpha = 0.5;
					this.time = 0.0;

					this.numX = Math.floor(sizeX / spacing) + 1
					this.numZ = Math.floor(sizeZ / spacing) + 1
					this.spacing = spacing;
					this.numCells = this.numX * this.numZ;
					this.heights = new Float32Array(this.numCells);
					this.bodyHeights = new Float32Array(this.numCells);
					this.prevHeights = new Float32Array(this.numCells);
					this.velocities = new Float32Array(this.numCells);		
					this.heights.fill(depth)
					this.velocities.fill(0.0)

					// visual mesh

					let positions = new Float32Array(this.numCells * 3);
					let uvs = new Float32Array(this.numCells * 2);
					let cx = Math.floor(this.numX / 2.0);
					let cz = Math.floor(this.numZ / 2.0);

					for (let i = 0; i < this.numX; i++) {
						for (let j = 0; j < this.numZ; j++) {
							positions[3 * (i * this.numZ + j)] = (i - cx) * spacing; 
							positions[3 * (i * this.numZ + j) + 2] = (j - cz) * spacing; 

							uvs[2 * (i * this.numZ + j)] = i / this.numX;
							uvs[2 * (i * this.numZ + j) + 1] = j / this.numZ;
						}
					}

					var index = new Uint32Array((this.numX - 1) * (this.numZ - 1) * 2 * 3);
					let pos = 0;
					for (let i = 0; i < this.numX - 1; i++) {
						for (let j = 0; j < this.numZ - 1; j++) {
							let id0 = i * this.numZ + j;
							let id1 = i * this.numZ + j + 1;
							let id2 = (i + 1) * this.numZ + j + 1;
							let id3 = (i + 1) * this.numZ + j;

							index[pos++] = id0;
							index[pos++] = id1;
							index[pos++] = id2;

							index[pos++] = id0;
							index[pos++] = id2;
							index[pos++] = id3;
						}
					}
					var geometry = new THREE.BufferGeometry();

//					var positions = new Float32Array([0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 1.0, 1.0, 0.0]);
					geometry.setAttribute('position', new THREE.BufferAttribute(positions, 3));
					geometry.setAttribute('uv', new THREE.BufferAttribute(uvs, 2));
					
//					geometry.setIndex(index);
					geometry.setIndex(new THREE.BufferAttribute(index,1));

					this.visMesh = new THREE.Mesh(geometry, visMaterial);

					this.updateVisMesh();
                    gThreeScene.add(this.visMesh);
				}

				simulateCoupling() 
				{
					let cx = Math.floor(this.numX / 2.0);
					let cz = Math.floor(this.numZ / 2.0);
					let h1 = 1.0 / this.spacing;

					this.prevHeights.set(this.bodyHeights);
					this.bodyHeights.fill(0.0);

					for (let i = 0; i < gPhysicsScene.objects.length; i++) {
						let ball = gPhysicsScene.objects[i];
						let pos = ball.pos;
						let br = ball.radius;
						let h2 = this.spacing * this.spacing;

						let x0 = Math.max(0, cx + Math.floor((pos.x - br) * h1));
						let x1 = Math.min(this.numX - 1, cx + Math.floor((pos.x + br) * h1));
						let z0 = Math.max(0, cz + Math.floor((pos.z - br) * h1));
						let z1 = Math.min(this.numZ - 1, cz + Math.floor((pos.z + br) * h1));

						for (let xi = x0; xi <= x1; xi++) {
							for (let zi = z0; zi <= z1; zi++) {
								let x = (xi - cx) * this.spacing; 
								let z = (zi - cz) * this.spacing;
								let r2 = (pos.x - x) * (pos.x - x) + (pos.z - z) * (pos.z - z);
								if (r2 < br * br) {
									let bodyHalfHeight = Math.sqrt(br * br - r2);
									let waterHeight = this.heights[xi * this.numZ + zi];

									let bodyMin = Math.max(pos.y - bodyHalfHeight, 0.0);
									let bodyMax = Math.min(pos.y + bodyHalfHeight, waterHeight);
									var bodyHeight = Math.max(bodyMax - bodyMin, 0.0);
									if (bodyHeight > 0.0) {
										ball.applyForce(-bodyHeight * h2 * gPhysicsScene.gravity.y);
										this.bodyHeights[xi * this.numZ + zi] += bodyHeight;
									}
								}
							}
						}
					}

					for (let iter = 0; iter < 2; iter++) {
						for (let xi = 0; xi < this.numX; xi++) {
							for (let zi = 0; zi < this.numZ; zi++) {
								let id = xi * this.numZ + zi;

								let num = xi > 0 && xi < this.numX - 1 ? 2 : 1;
								num += zi > 0 && zi < this.numZ - 1 ? 2 : 1; 
								let avg = 0.0;
								if (xi > 0) avg += this.bodyHeights[id - this.numZ];
								if (xi < this.numX - 1) avg += this.bodyHeights[id + this.numZ];
								if (zi > 0) avg += this.bodyHeights[id - 1];
								if (zi < this.numZ - 1) avg += this.bodyHeights[id + 1];
								avg /= num;
								this.bodyHeights[id] = avg;
							}
						}
					}

					for (let i = 0; i < this.numCells; i++) {
						let bodyChange = this.bodyHeights[i] - this.prevHeights[i];
						this.heights[i] += this.alpha * bodyChange;
					}
				}

				simulateSurface()
				{
					this.waveSpeed = Math.min(this.waveSpeed, 0.5 * this.spacing / gPhysicsScene.dt);
					let c = this.waveSpeed * this.waveSpeed / this.spacing / this.spacing
					let pd = Math.min(this.posDamping * gPhysicsScene.dt, 1.0);
					let vd = Math.max(0.0, 1.0 - this.velDamping * gPhysicsScene.dt);

					for (let i = 0; i < this.numX; i++) {
						for (let j = 0; j < this.numZ; j++) {
							let id = i * this.numZ + j
							let h = this.heights[id];
							let sumH = 0.0;
							sumH += i > 0 ? this.heights[id - this.numZ] : h;
							sumH += i < this.numX - 1 ? this.heights[id + this.numZ] : h;
							sumH += j > 0 ? this.heights[id - 1] : h;
							sumH += j < this.numZ - 1 ? this.heights[id + 1] : h;
							this.velocities[id] += gPhysicsScene.dt * c * (sumH - 4.0 * h)
							this.heights[id] += (0.25 * sumH - h) * pd;  // positional damping
						}
					}

					for (var i = 0; i < this.numCells; i++) {
						this.velocities[i] *= vd;		// velocity damping
						this.heights[i] += this.velocities[i] * gPhysicsScene.dt;
					}
				}

				simulate() 
				{
					this.time += gPhysicsScene.dt;
					this.simulateCoupling()
					this.simulateSurface()
					this.updateVisMesh();
				}

				updateVisMesh()
				{
					const positions = this.visMesh.geometry.attributes.position.array;
					for (let i = 0; i < this.numCells; i++)
						positions[3 * i + 1] = this.heights[i];
					this.visMesh.geometry.attributes.position.needsUpdate = true;
					this.visMesh.geometry.computeVertexNormals();
					this.visMesh.geometry.computeBoundingSphere();
				}

				setVisible(visible)
				{
					this.visMesh.visible = visible;
				}
			}

			// ------------------------------------------------------------------
			class Ball {
				constructor(pos, radius, density, color = 0xff0000)
				{
					// physics data 

                    this.pos = new THREE.Vector3(pos.x, pos.y, pos.z);
                    this.radius = radius;
					this.mass = 4.0 * Math.PI / 3.0 * radius * radius * radius * density;
                    this.vel = new THREE.Vector3(0.0, 0.0, 0.0);
					this.grabbed = false;
					this.restitution = 0.1;

					// visual mesh

                    let geometry = new THREE.SphereGeometry( radius, 32, 32 );
                    let material = new THREE.MeshPhongMaterial({color: color});
                    this.visMesh = new THREE.Mesh( geometry, material );
					this.visMesh.position.copy(pos);
					this.visMesh.userData = this;		// for raycasting
					this.visMesh.layers.enable(1);
					gThreeScene.add(this.visMesh);
				}

				handleCollision(other) 
				{
					let dir = new THREE.Vector3();
					dir.subVectors(other.pos, this.pos);
					let d = dir.length();

					let minDist = this.radius + other.radius;
					if (d >= minDist)
						return;

					dir.multiplyScalar(1.0 / d);
					let corr = (minDist - d) / 2.0;
					this.pos.addScaledVector(dir, -corr);
					other.pos.addScaledVector(dir, corr);

					let v1 = this.vel.dot(dir);
					let v2 = other.vel.dot(dir);

					let m1 = this.mass;
					let m2 = other.mass;

					let newV1 = (m1 * v1 + m2 * v2 - m2 * (v1 - v2) * this.restitution) / (m1 + m2);
					let newV2 = (m1 * v1 + m2 * v2 - m1 * (v2 - v1) * this.restitution) / (m1 + m2);

					this.vel.addScaledVector(dir, newV1 - v1);
					other.vel.addScaledVector(dir, newV2 - v2);					

				}
			
				simulate()
				{
					if (this.grabbed)
						return;

					this.vel.addScaledVector(gPhysicsScene.gravity, gPhysicsScene.dt);
					this.pos.addScaledVector(this.vel, gPhysicsScene.dt);

					let wx = 0.5 * gPhysicsScene.tankSize.x - this.radius - 0.5 * gPhysicsScene.tankBorder;
					let wz = 0.5 * gPhysicsScene.tankSize.z - this.radius - 0.5 * gPhysicsScene.tankBorder;

					if (this.pos.x < -wx) {
						this.pos.x = -wx; this.vel.x = -this.restitution * this.vel.x;
					}
					if (this.pos.x >  wx) {
						this.pos.x =  wx; this.vel.x = -this.restitution * this.vel.x;
					}
					if (this.pos.z < -wz) {
						this.pos.z = -wz; this.vel.z = -this.restitution * this.vel.z;
					}
					if (this.pos.z >  wz) {
						this.pos.z =  wz; this.vel.z = -this.restitution * this.vel.z;
					}
					if (this.pos.y < this.radius) {
						this.pos.y = this.radius; this.vel.y = -this.restitution * this.vel.y;
					}

					this.visMesh.position.copy(this.pos);
					this.visMesh.geometry.computeBoundingSphere();
				}

				applyForce(force)
				{
					this.vel.y += gPhysicsScene.dt * force / this.mass;
					this.vel.multiplyScalar(0.999);
				}

				startGrab(pos) 
				{
					this.grabbed = true;
					this.pos.copy(pos);
					this.visMesh.position.copy(pos);
				}

				moveGrabbed(pos, vel) 
				{
					this.pos.copy(pos);
					this.visMesh.position.copy(pos);
				}

				endGrab(pos, vel) 
				{
					this.grabbed = false;
					this.vel.copy(vel);
				}		
			}	

			// ------------------------------------------------------------------
			function initScene(scene) 
			{				
				// water surface

				let wx = gPhysicsScene.tankSize.x;
				let wy = gPhysicsScene.tankSize.y;
				let wz = gPhysicsScene.tankSize.z;
				let b = gPhysicsScene.tankBorder;

				var waterSurface = new WaterSurface(wx, wz, gPhysicsScene.waterHeight, 
										gPhysicsScene.waterSpacing, gWaterMaterial)
				gPhysicsScene.waterSurface = waterSurface;

				// tank

				var tankMaterial = new THREE.MeshPhongMaterial({color: 0x909090});
				var boxGeometry = new THREE.BoxGeometry(b, wy, wz);
				var box = new THREE.Mesh(boxGeometry, tankMaterial);
				box.position.set(-0.5 * wx, wy * 0.5, 0.0)
                gThreeScene.add(box);
				var box = new THREE.Mesh(boxGeometry, tankMaterial);
				box.position.set(0.5 * wx, 0.5 * wy, 0.0)
                gThreeScene.add(box);
				var boxGeometry = new THREE.BoxGeometry(wx, wy, b);
				var box = new THREE.Mesh(boxGeometry, tankMaterial);
				box.position.set(0.0, 0.5 * wy, - wz * 0.5)
                gThreeScene.add(box);
				var box = new THREE.Mesh(boxGeometry, tankMaterial);
				box.position.set(0.0, 0.5 * wy, wz * 0.5)
                gThreeScene.add(box);

				// ball

				gPhysicsScene.objects.push(new Ball({x:-0.5, y:1.0, z:-0.5}, 0.2, 2.0, 0xffff00));
				gPhysicsScene.objects.push(new Ball({x:0.5, y:1.0, z:-0.5}, 0.3, 0.7, 0xff8000));				
				gPhysicsScene.objects.push(new Ball({x:0.5, y:1.0, z:0.5}, 0.25, 0.2, 0xff0000));

			}

			// ------------------------------------------------------------------
			function simulate() 
			{
				if (gPhysicsScene.paused)
					return;

				gPhysicsScene.waterSurface.simulate();
				
				for (let i = 0; i < gPhysicsScene.objects.length; i++) {
					obj = gPhysicsScene.objects[i]
					obj.simulate();
					for (let j = 0; j < i; j++) 
						obj.handleCollision(gPhysicsScene.objects[j]);
				}
			}

			// ------------------------------------------
			function render() {

				gPhysicsScene.waterSurface.setVisible(false);
				gRenderer.setRenderTarget(gRenderTarget);
				gRenderer.clear();
				gRenderer.render(gThreeScene, gCamera);

				gPhysicsScene.waterSurface.setVisible(true);
				gRenderer.setRenderTarget(null);
				gRenderer.render(gThreeScene, gCamera);
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
				spotLight.shadow.camera.near = 1;
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
				
				// gRenderer

				gRenderer = new THREE.WebGLRenderer();
				gRenderer.shadowMap.enabled = true;
				gRenderer.setPixelRatio( window.devicePixelRatio );
				gRenderer.setSize( window.innerWidth, window.innerHeight );
				window.addEventListener( 'resize', onWindowResize, false );
				container.appendChild( gRenderer.domElement );

				gRenderTarget = new THREE.WebGLRenderTarget( window.innerWidth, window.innerHeight, 
					{ minFilter: THREE.LinearFilter, magFilter: THREE.NearestFilter, format: THREE.RGBAFormat } );

				gWaterMaterial = new THREE.ShaderMaterial( {
					uniforms: { background: { value: gRenderTarget.texture } },
					vertexShader: document.getElementById( 'waterVertexShader' ).textContent,
					fragmentShader: document.getElementById( 'waterFragmentShader' ).textContent} );
					
				// gCamera
						
				gCamera = new THREE.PerspectiveCamera( 60, window.innerWidth / window.innerHeight, 0.01, 100);
			    gCamera.position.set(0.0, 2.1, 1.5);
				gCamera.updateMatrixWorld();	

				gThreeScene.add( gCamera );

				gCameraControl = new THREE.OrbitControls(gCamera, gRenderer.domElement);
    			gCameraControl.zoomSpeed = 2.0;
    			gCameraControl.panSpeed = 0.4;
				gCameraControl.target.set(0.0, 0.8, 0.0)

				// Grabber

				gGrabber = new Grabber();
				container.addEventListener( 'pointerdown', onPointer, false );
				container.addEventListener( 'pointermove', onPointer, false );
				container.addEventListener( 'pointerup', onPointer, false );
			}

			// ------- Grabber -----------------------------------------------------------

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

			function onWindowResize() {

				gCamera.aspect = window.innerWidth / window.innerHeight;
				gCamera.updateProjectionMatrix();
				gRenderer.setSize( window.innerWidth, window.innerHeight );
				gRenderTarget.setSize(window.innerWidth, window.innerHeight);
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

			function update() 
			{
				let time = performance.now();
				let dt = (time - gPrevTime) / 1000.0;
				gPrevTime = time;

				gPhysicsScene.dt = Math.min(1.0 / 30.0, 2.0 * dt);

				simulate();
				render();
				gCameraControl.update();	
				gGrabber.increaseTime(gPhysicsScene.dt);			
				
				requestAnimationFrame(update);
			}
			
			initThreeScene();
			initScene();
			update();
			
		</script>
	</body>
</html>

```
