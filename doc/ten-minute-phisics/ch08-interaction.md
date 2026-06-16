# Chapter 08 — Providing User Interaction with a 3D Scene

**Video:** https://youtu.be/iH_UgUb-LYM
**Code:** https://raw.githubusercontent.com/matthias-research/pages/master/tenMinutePhysics/08-interaction.html

## Video Transcript

hi matthias from 10 minute physics here welcome to tutorial number eight today i will show you how to let the user interact with a 3d scene it took me quite a while to figure out how to map between the different coordinate systems of the browser how to properly switch between camera control and dragon and how to use the raycast feature of 3.js properly i put all this knowledge into one clean and simple class called grabber we will use it in future tutorials and you can use it for your demos as well let's start we have a 3d scene what we see on the screen however is a projection of this world the projection depends on the position and the orientation of the camera let's assume we click at the two-dimensional position p in screen coordinates where is this point in our 3d world the answer is not unique the point can be anywhere on array that is defined by an origin and the direction this ray is called the mouse ray the camera sees this entire ray as a single point you can reproduce this scenario take a pencil and open only one eye now you can orient the pencil in such a way that it appears as a small single disc the next concept we need is raycasting let's assume we have two spheres in our scene and the user clicks at the red location from this we can compute the mouse ray with its origin and its direction casting array means computing the intersections of the array with all the objects in the scene a single object can potentially be intersected multiple times a raycast operation typically returns only one hit per object the one that is closest to the ray's origin since the ray can intersect multiple objects the raycast function returns a list of pairs of distances and object references in 3js this list is sorted by distances it is also possible to associate a layer number with each object if a layer number is passed to the raycast function it only returns objects with that layer from the distances we can easily compute the 3d positions of the intersections as the origin of the array plus its direction times the distance to the intersection we can now use raycasts for enabling the user to drag objects when a mouse event occurs we compute the mouse ray next we use raycasting to find the closest intersection of the mouse ray and the scene we then compute the intersection point p down and notify the object returned by the raycast function with a drag start event passing p down we also store the distance d down when a mouse move event occurs we first compute the new mouse ray to compute the new drag position we don't need to call raycast this time we use distort initial distance from the mouse down event we now notify the object with a drag move event passing the new drag position when a mouse up event occurs we simply notify the object with a track and event each object will handle the events drag start drag move and drag end differently here is a simple version for rigid bodies this is also the one we will implement in this tutorial we simply ignore the start event when a move event occurs we simply move the body to the new drag position here is a more advanced version at the start event we compute a local attachment position on the body by transforming the drag position into the body's local frame we then create a zero length spring between the attachment point and the global attachment point at the move event we set the global attachment position of the spring to the new drag position this way the user gets a feel of the weight of the body as well here's a way to implement dragging for soft bodies at the start drag event we find the particle closest to the drag position and make this particle kinematic at the move event we set the particle's position to the drag position at the end event we make the particle dynamic again so now let's code this okay so this is the goal of the tutorial i took the scene from tutorial number two with the red sphere in the 3d scene but now the user can pick it move it around and throw it as i just mentioned we use the 3d demo with the red sphere from tutorial number 2 to demonstrate user interaction therefore i will only focus on the codes that we have to add to this example to enable user interaction the core of the implementation is an object i call grabber it handles mouse down movement opulence and calls the grab start movement and method of the graphed physics object with the graph position and velocity first we add four lines at the bottom of the function in e3 scene the first one creates a new grabber object the next three lines make sure that our on pointer function is called when pointer down move or up events occur a pointer event represents both a mouse or touch event the onpointer function is quite simple it basically feeds the grabber object with the necessary information when a point-to-down event occurs we call the start method of the grabber with the x and y-coordinates of the mouse also if the grabber picks up a physics object we turn camera control off if a pointer move event occurs we call the move method of the grabber again providing the x and y coordinates of the mouse if we get the pointer up event we call the grabber's end method and turn camera control back on here is the definition of the grabber object in the constructor we create a raycaster object provided by the three library we also saw the grabbed physics object the distance the previous position the velocity and the simulation time the time is used to compute a grab velocity the increased time method is called by the simulation function and enables the grabber to keep track of the time the method update raycaster takes as input the mouse or touch coordinates it first transforms them from document to canvas coordinates then we call the set from camera method of the raycaster which computes the mouse ray in 3d the start method first updates the raycaster then we let 3js perform arraycast into the scene this function returns a list of intersections if it is not empty then the first entry is the intersected visual mesh closest to the camera to get the physics object that owns this visual mesh we use the user data variable of the mesh if this is set then we store the physics object we also store the distance to this mesh then we compute the graph position as the origin of the ray plus the direction times the distance then we call the start grab method of the physics object with the grab position we then set the previous position and reset the velocity finally if the scene was paused we start the simulation in the move method if a physics object is present we update the raycaster this time we do not perform a raycast but only compute the new mouse ray with its origin direction and the graph distance from the down event we can compute the new graph position we also compute the velocity as the current position minus the previous position divided by the time that has passed since the last event now we can call the move grabbed method of the physics object with the new position and velocity in the and method we simply call the and grab method of the physics object with the previous graph position and the velocity what is left now is to make the ball grabbable first we add a boolean variable to know whether the ball needs to be simulated in the constructor we also set the user data variable of the visual mesh to the ball as discussed before all we need to add to the simulation function is to return if the object is grabbed now we have the three methods that a grabbable object needs to implement start grab move craft and ant grab they're super simple here we simply move the ball and the visual mesh to the grab position in the end grab method we set the velocity to make sure that the ball keeps moving when we let it go in the next tutorial we use the grabber to drag soft bodies in that case these methods are a little bit more interesting this concludes this tutorial in the description i have a link to a page that contains all the html files of all the tutorials i hope you had fun and i'll see you in the next tutorial

## Source Code

### 08-interaction.html

```html
<!DOCTYPE html>
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<html lang="en">
	<head>
		<title>Interaction</title>
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

        <h1>User Interaction Demo</h1> 
		<button id = "buttonRun" onclick="run()" class="button">Run</button>
		<button onclick="restart()" class="button">Restart</button>

		<br><br>		
        <div id="container"></div>
        
        <script src="https://unpkg.com/three@0.139.2/build/three.min.js"></script>
        <script src="https://unpkg.com/three@0.139.2/examples/js/controls/OrbitControls.js"></script>
		<script>
			
			var gThreeScene;
			var gRenderer;
			var gCamera;
			var gCameraControl;
			var gGrabber;
			var gMouseDown = false;

			var gPhysicsScene = 
			{
				gravity : new THREE.Vector3(0.0, -10.0, 0.0),
				dt : 1.0 / 60.0,
				worldSize : { x: 1.5, z : 2.5 },
				paused: true,
				objects: [],				
			};

			// ------------------------------------------------------------------
			class Ball {
				constructor(pos, radius, vel)
				{
					// physics data 

                    this.pos = pos;
                    this.radius = radius;
                    this.vel = vel;
					this.grabbed = false;

					// visual mesh

                    var geometry = new THREE.SphereGeometry( radius, 32, 32 );
                    var material = new THREE.MeshPhongMaterial({color: 0xff0000});
                    this.visMesh = new THREE.Mesh( geometry, material );
					this.visMesh.position.copy(pos);
					this.visMesh.userData = this;		// for raycasting
					this.visMesh.layers.enable(1);
					gThreeScene.add(this.visMesh);
				}
			
				simulate()
				{
					if (this.grabbed)
						return;

					this.vel.addScaledVector(gPhysicsScene.gravity, gPhysicsScene.dt);
					this.pos.addScaledVector(this.vel, gPhysicsScene.dt);

					var size = gPhysicsScene.worldSize;

					if (this.pos.x < -size.x) {
						this.pos.x = -size.x; this.vel.x = -this.vel.x;
					}
					if (this.pos.x >  size.x) {
						this.pos.x =  size.x; this.vel.x = -this.vel.x;
					}
					if (this.pos.z < -size.z) {
						this.pos.z = -size.z; this.vel.z = -this.vel.z;
					}
					if (this.pos.z >  size.z) {
						this.pos.z =  size.z; this.vel.z = -this.vel.z;
					}
					if (this.pos.y < this.radius) {
						this.pos.y = this.radius; this.vel.y = -this.vel.y;
					}

					this.visMesh.position.copy(this.pos);
					this.visMesh.geometry.computeBoundingSphere();
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
			function initPhysics() 
			{
				var radius = 0.2;
				var pos = new THREE.Vector3(radius, 1.0, radius);
//				var vel = new THREE.Vector3(2.0, 5.0, 3.0);
				var vel = new THREE.Vector3();
				
				gPhysicsScene.objects.push(new Ball(pos, radius, vel)); 
			}

			// ------------------------------------------------------------------
			function simulate() 
			{
				if (gPhysicsScene.paused)
					return;
				for (var i = 0; i < gPhysicsScene.objects.length; i++)
					gPhysicsScene.objects[i].simulate();

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
							vel.set(0.0, 0.0, 0.0);
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
			
			initThreeScene();
			onWindowResize();
			initPhysics();
			update();
			
		</script>
	</body>
</html>

```
