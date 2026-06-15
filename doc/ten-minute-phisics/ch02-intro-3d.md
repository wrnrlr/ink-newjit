# Chapter 02 — Introduction to 3D and VR Web Browser Physics

**Video:** https://youtu.be/j84zJ06wnVA
**Code:** https://raw.githubusercontent.com/matthias-research/pages/master/tenMinutePhysics/02-cannonball3d.html
**Code:** https://raw.githubusercontent.com/matthias-research/pages/master/tenMinutePhysics/02-cannonballVR.html

## Video Transcript

hi not just from 10 minute physics here welcome to tutorial number two this time i'm going to show you how to write 3d simulations in a web browser and for this we're going to turn our 2d bulb simulation into a 3d simulation let's start here we are in visual studio code again we use the html skeleton that we wrote in the first tutorial so we have the html section and then we have the head section inside we defined a title that will appear in the tab of the browser and this time we also define a nicer font and the font size in the body section we have the title that will appear in the body of the page and then instead of a canvas we use a general div element and give it also an id to access it later in the script part we also have a simulation function as before and an update function that calls simulate and make sure that the update function is called again and again and the only command that we actually have is to call update for a first time writing a 3d simulation is almost as simple as writing a 2d simulation the reason is that there's a very cool 3d library called 3.js have a look at their webpage at 3js.org it runs in any browser because it's based on javascript have a look at their examples for instance this little city as you can see it can draw any 3d model we can change the camera view and can also animate models like this little tram exactly what we need to create our 3d simulations adding 3.js into our project is super simple we simply add these two lines here the first includes the 3.js library itself and the second adds a control to move the camera then we need four additional variables the three scene a renderer a camera and a camera control now we need a function that initializes the three library we first create the three scene object then we add various elements to this scene i copied the code below from various examples first i add a few lights and then i create a ground plane then i create the renderer this code is also taken from their examples a camera again part of their examples and finally an object and this is the only tutorial specific code first i create a sphere geometry with a radius of 20 centimeters and a certain resolution for the visual mesh then i create a material with color red and with the sphere geometry and the material i can create the sphere object i place it at a certain location in 3d space and add it to the 3 scene in the callback function on window resize we have to update the camera as well as the renderer with the new window width and height in the update function we still call the simulate function but we also call the render function of the renderer and we update the camera control finally before we call update we call init 3 scene here you can see how this looks like in the browser we have our canon ball the red sphere here in the center and we can move the camera using the mouse before we look into the simulation code we're going to add two buttons to our page a run button and a restart button we can specify which function is called when we click the button by the on click property for the run button we call the function run and for the restart button the function restart we also specify an id for the run button to be able to access it below here you see the two function for the restart function we simply call location reload which just reloads the page in the browser for the run function we want a specific behavior we want to be able to stop and start the simulation so for this we define a boolean variable pause to specify whether our simulation is passed or not in the run function we first get the object of the button via the id then we check whether a simulation is passed if the simulation is passed and the user clicks the button we switch the text to stop otherwise we switch it to run and then we change the state of our simulation so now let's look how this looks in the browser here you can see our two buttons the run button and the restart button when we click the restart button the page is reloaded when you click the run button the text switches to stop and back to run again we are finally ready to do some physics for this i define a variable called physics scene which is a structure that contains information about our simulation the first one is gravity as you can see i use the class vector3 provided by three it has three components x y and z and is very useful to store 3d information like a position a velocity or force then i defined dt which is our time step size a world size the variable pause that tells us whether our simulation is paused or not and then a variable that will contain our simulation objects next we define a class for the ball in the constructor we provide the position the radius the velocity and the scene first we store the position the radius and the velocity in member variables now we create a visual mesh for three as we did before we create a geometry a material and then create the visual mesh we set its position to pause and then we add it to the three scene the core method of the ball class is the simulation method in the constructor we created two member variables for the position and for the velocity in the simulation method we want to update these two variables based on newton's second law and you can see this in these two statements what we do is we add to the velocity gravity times dt and to the position the velocity times tt exactly as in the 2d case then we make sure that the ball doesn't leave a certain area and finally we update the position of the visual mesh that's all next we add two additional functions the init physics function and the simulate function in the init physics function we set up our scene first we choose a radius a position and a velocity for a ball then we create a new ball object and add it to the objects of the physics scene in the simulate function we first check whether our simulation is paused if so we return otherwise we iterate through all the objects in the physics scene and call simulate now we have to call these two functions in the right places we call init physics right after any three scene and in the update function we call simulate that's it now let's have a look at how this looks in the web browser so here's our final result as before we can change the camera view we can zoom in and out but now we can also run the simulation so as in the 2d case we have a cannonball that jumps up and down and is kept within a certain boundary now comes the really cool part we can turn our demo into a vr demo with 3.js all we need is this class vr button i wasn't able to link it as i linked the camera control so i copied pasted their code into our html file in order to be standalone now we have to change three simple things in the init3 scene at the bottom we add these three lines the first one adds a vr button then we have to enable vr and then we change our update logic we tell the renderer what our update function is and so we can remove the request animation frame update and also the camera is now controlled by the vr of course it's not possible to show you the result in this video here is just a recording of my cell phone in vr mode now that you know everything about 3d simulations we will turn back to 2d for the next few tutorials because it is easier to explain simulation concepts in 2d

## Source Code

### 02-cannonball3d.html

```html
<!--
Copyright 2021 Matthias Müller - Ten Minute Physics

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
-->

<!DOCTYPE html>
<html lang="en">
	<head>
		<title>Cannonball 3d</title>
		<style>
		body {
			font-family: verdana; 
			font-size: 15px;
		}
		</style>
	</head>
	
	<body>

        <h1>Cannonball 3d</h1> 
		<button id = "buttonRun" onclick="run()" class="button">Run</button>
		<button onclick="restart()" class="button">Restart</button>

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

			// physics scene

			var physicsScene = 
			{
				gravity : new THREE.Vector3(0.0, -10.0, 0.0),
				dt : 1.0 / 60.0,
				worldSize : { x: 1.5, z : 2.5 },
				paused: true,
				objects: [],				
			};
						
			// ------------------------------------------------------------------
			class Ball {
				constructor(pos, radius, vel, scene)
				{
					// physics data 

                    this.pos = pos;
                    this.radius = radius;
                    this.vel = vel;

					// visual mesh

                    var geometry = new THREE.SphereGeometry( radius, 32, 32 );
                    var material = new THREE.MeshPhongMaterial({color: 0xff0000});
                    this.visMesh = new THREE.Mesh( geometry, material );
					this.visMesh.position.copy(pos);
                    threeScene.add(this.visMesh);
				}
			
				simulate()
				{
					this.vel.addScaledVector(physicsScene.gravity, physicsScene.dt);
					this.pos.addScaledVector(this.vel, physicsScene.dt);

					if (this.pos.x < -physicsScene.worldSize.x) {
						this.pos.x = -physicsScene.worldSize.x; this.vel.x = -this.vel.x;
					}
					if (this.pos.x >  physicsScene.worldSize.x) {
						this.pos.x =  physicsScene.worldSize.x; this.vel.x = -this.vel.x;
					}
					if (this.pos.z < -physicsScene.worldSize.z) {
						this.pos.z = -physicsScene.worldSize.z; this.vel.z = -this.vel.z;
					}
					if (this.pos.z >  physicsScene.worldSize.z) {
						this.pos.z =  physicsScene.worldSize.z; this.vel.z = -this.vel.z;
					}
					if (this.pos.y < this.radius) {
						this.pos.y = this.radius; this.vel.y = -this.vel.y;
					}

					this.visMesh.position.copy(this.pos);
				}
			}

			// ------------------------------------------------------------------
			function initPhysics(scene) 
			{
				var radius = 0.2;
				var pos = new THREE.Vector3(radius, radius, radius);
				var vel = new THREE.Vector3(2.0, 5.0, 3.0);
				
				physicsScene.objects.push(new Ball(pos, radius, vel, scene)); 
			}

			// ------------------------------------------------------------------
			function simulate() 
			{
				if (physicsScene.paused)
					return;
				for (var i = 0; i < physicsScene.objects.length; i++)
					physicsScene.objects[i].simulate();
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
			    camera.position.set(0, 1, 4);
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
			initPhysics();
			update();
			
		</script>
	</body>
</html>

```

### 02-cannonballVR.html

```html
<!--
Copyright 2021 Matthias Müller - Ten Minute Physics

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
-->

<!DOCTYPE html>
<html lang="en">
	<head>
		<title>Cannonball VR</title>
		<style>
		body {
			font-family: verdana; 
			font-size: 15px;
		}
		</style>
	</head>
	
	<body>

        <h1>Cannonball VR</h1> 

		<br><br>		
        <div id="container"></div>
        
		<script src="https://threejs.org/build/three.js"></script>
		<script>
			
            // ------------------------------------------------------------------

			// physics scene

			var physicsScene = 
			{
				gravity : new THREE.Vector3(0.0, -10.0, 0.0),
				dt : 1.0 / 60.0,
				worldSize : { x: 1.5, z : 2.5 },
				objects: [],				
			};
			
			var threeScene;
			var renderer;
			var camera;

			// ------------------------------------------------------------------
			class Ball {
				constructor(pos, radius, vel, scene)
				{
					// physics data 

                    this.pos = pos;
                    this.radius = radius;
                    this.vel = vel;

					// visual mesh

                    var geometry = new THREE.SphereGeometry( radius, 32, 32 );
                    var material = new THREE.MeshPhongMaterial({color: 0xff0000});
                    this.visMesh = new THREE.Mesh( geometry, material );
					this.visMesh.position.copy(pos);
                    threeScene.add(this.visMesh);
				}
			
				simulate()
				{
					this.vel.addScaledVector(physicsScene.gravity, physicsScene.dt);
					this.pos.addScaledVector(this.vel, physicsScene.dt);

					if (this.pos.x < -physicsScene.worldSize.x) {
						this.pos.x = -physicsScene.worldSize.x; this.vel.x = -this.vel.x;
					}
					if (this.pos.x >  physicsScene.worldSize.x) {
						this.pos.x =  physicsScene.worldSize.x; this.vel.x = -this.vel.x;
					}
					if (this.pos.z < -physicsScene.worldSize.z) {
						this.pos.z = -physicsScene.worldSize.z; this.vel.z = -this.vel.z;
					}
					if (this.pos.z >  physicsScene.worldSize.z) {
						this.pos.z =  physicsScene.worldSize.z; this.vel.z = -this.vel.z;
					}
					if (this.pos.y < this.radius) {
						this.pos.y = this.radius; this.vel.y = -this.vel.y;
					}

					this.visMesh.position.copy(this.pos);
				}
			}

			// ------------------------------------------------------------------
			function initPhysics(scene) 
			{
				var radius = 0.2;
				var pos = new THREE.Vector3(radius, radius, radius);
				var vel = new THREE.Vector3(2.0, 5.0, 3.0);
				
				physicsScene.objects.push(new Ball(pos, radius, vel, scene)); 
			}

			// ------------------------------------------------------------------
			function simulate() 
			{
				for (var i = 0; i < physicsScene.objects.length; i++)
					physicsScene.objects[i].simulate();
			}

			// ------------------------------------------------------------------
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
			    camera.position.set(0, 1, 4);
				camera.updateMatrixWorld();	

				threeScene.add( camera );

				// VR 
				document.body.appendChild(VRButton.createButton(renderer));
				renderer.xr.enabled = true;
				renderer.setAnimationLoop(update);
			}

			function onWindowResize() {

				camera.aspect = window.innerWidth / window.innerHeight;
				camera.updateProjectionMatrix();
				renderer.setSize( window.innerWidth, window.innerHeight );
			}

			function update() {
				simulate();
				renderer.render(threeScene, camera);
			}

			// ------------------------------------------
			// start copied code from THREE.js
					
			class VRButton {

				static createButton( renderer, options ) {

					if ( options ) {

						console.error( 'THREE.VRButton: The "options" parameter has been removed. Please set the reference space type via renderer.xr.setReferenceSpaceType() instead.' );

					}

					const button = document.createElement( 'button' );

					function showEnterVR( /*device*/ ) {

						let currentSession = null;

						async function onSessionStarted( session ) {

							session.addEventListener( 'end', onSessionEnded );

							await renderer.xr.setSession( session );
							button.textContent = 'EXIT VR';

							currentSession = session;

						}

						function onSessionEnded( /*event*/ ) {

							currentSession.removeEventListener( 'end', onSessionEnded );

							button.textContent = 'ENTER VR';

							currentSession = null;

						}

						//

						button.style.display = '';

						button.style.cursor = 'pointer';
						button.style.left = 'calc(50% - 50px)';
						button.style.width = '100px';

						button.textContent = 'ENTER VR';

						button.onmouseenter = function () {

							button.style.opacity = '1.0';

						};

						button.onmouseleave = function () {

							button.style.opacity = '0.5';

						};

						button.onclick = function () {

							if ( currentSession === null ) {

								// WebXR's requestReferenceSpace only works if the corresponding feature
								// was requested at session creation time. For simplicity, just ask for
								// the interesting ones as optional features, but be aware that the
								// requestReferenceSpace call will fail if it turns out to be unavailable.
								// ('local' is always available for immersive sessions and doesn't need to
								// be requested separately.)

								const sessionInit = { optionalFeatures: [ 'local-floor', 'bounded-floor', 'hand-tracking' ] };
								navigator.xr.requestSession( 'immersive-vr', sessionInit ).then( onSessionStarted );

							} else {

								currentSession.end();

							}

						};

					}

					function disableButton() {

						button.style.display = '';

						button.style.cursor = 'auto';
						button.style.left = 'calc(50% - 75px)';
						button.style.width = '150px';

						button.onmouseenter = null;
						button.onmouseleave = null;

						button.onclick = null;

					}

					function showWebXRNotFound() {

						disableButton();

						button.textContent = 'VR NOT SUPPORTED';

					}

					function stylizeElement( element ) {

						element.style.position = 'absolute';
						element.style.bottom = '20px';
						element.style.padding = '12px 6px';
						element.style.border = '1px solid #fff';
						element.style.borderRadius = '4px';
						element.style.background = 'rgba(0,0,0,0.1)';
						element.style.color = '#fff';
						element.style.font = 'normal 13px sans-serif';
						element.style.textAlign = 'center';
						element.style.opacity = '0.5';
						element.style.outline = 'none';
						element.style.zIndex = '999';

					}

					if ( 'xr' in navigator ) {

						button.id = 'VRButton';
						button.style.display = 'none';

						stylizeElement( button );

						navigator.xr.isSessionSupported( 'immersive-vr' ).then( function ( supported ) {

							supported ? showEnterVR() : showWebXRNotFound();

						} );

						return button;

					} else {

						const message = document.createElement( 'a' );

						if ( window.isSecureContext === false ) {

							message.href = document.location.href.replace( /^http:/, 'https:' );
							message.innerHTML = 'WEBXR NEEDS HTTPS'; // TODO Improve message

						} else {

							message.href = 'https://immersiveweb.dev/';
							message.innerHTML = 'WEBXR NOT AVAILABLE';

						}

						message.style.left = 'calc(50% - 90px)';
						message.style.width = '180px';
						message.style.textDecoration = 'none';

						stylizeElement( message );

						return message;

					}
				}
			};

			// end copied code from THREE.js
			// ------------------------------------------

			initThreeScene();
			initPhysics();
			
		</script>
	</body>
</html>

```
