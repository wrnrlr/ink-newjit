# Chapter 2 — From 2D to 3D: Building Your First 3D Physics Scene

The cannonball simulation from Chapter 1 captured the essential mechanics of physics programming — an integration loop, Newtonian kinematics, and boundary collisions — but it lived on a flat canvas. This chapter lifts that simulation into three dimensions. Along the way we introduce Three.js as a rendering layer, build out a pair of UI controls for run/pause and restart, organize the code into a reusable class structure, and end with something genuinely surprising: turning the whole demo into a VR experience with only three extra lines.

---

## Why Three.js?

Writing a 3D renderer from scratch is a months-long project. Fortunately, the web platform ships with WebGL — a low-level GPU API — and Three.js is a mature JavaScript library that wraps WebGL in a sensible, high-level scene graph. It runs in any modern browser, requires no installation, and has a large library of examples to borrow from. For physics simulations, this is the right tradeoff: we want to spend our time on the physics, not on matrix math and shader programs.

Adding Three.js to a standalone HTML file takes two `<script>` tags: one for the core library and one for `OrbitControls`, a helper that lets the user drag and zoom the camera with the mouse.

```html
<script src="https://unpkg.com/three@0.139.2/build/three.min.js"></script>
<script src="https://unpkg.com/three@0.139.2/examples/js/controls/OrbitControls.js"></script>
```

That is literally everything needed to have access to a full 3D renderer. The rest is our own code.

---

## Setting Up the 3D Scene

Before the physics runs, we need a scene to render into. The `initThreeScene` function creates the visual world: lights, a ground plane, a renderer, and a camera. This is mostly boilerplate assembled from Three.js examples, but a few decisions are worth understanding.

### The Scene Graph

Three.js organizes everything in a scene graph — a hierarchy of objects. You create a root `THREE.Scene`, then `.add()` things to it: lights, meshes, the camera itself. The renderer walks this graph each frame and draws everything it finds.

```js
threeScene = new THREE.Scene();
```

### Lighting

Without lights, Phong-shaded meshes appear completely black. The scene uses two light sources: an ambient light that brightens everything uniformly (so nothing is ever pure black), and a spot light plus a directional light to cast shadows and give the scene depth.

```js
threeScene.add(new THREE.AmbientLight(0x505050));

var spotLight = new THREE.SpotLight(0xffffff);
spotLight.position.set(2, 3, 3);
spotLight.castShadow = true;
threeScene.add(spotLight);
```

The hex values are RGB colors — `0x505050` is a dim gray, `0xffffff` is white. Shadow maps are configured on the light objects, and `renderer.shadowMap.enabled = true` turns on shadow rendering globally.

### The Ground Plane

A `PlaneBufferGeometry` is a flat rectangle. By default it lies in the X/Y plane (facing up the Z axis), which is not where we want a floor. Rotating it by -90 degrees around X tips it flat into the X/Z plane, making Y the vertical axis — the standard convention in Three.js.

```js
var ground = new THREE.Mesh(
    new THREE.PlaneBufferGeometry(20, 20, 1, 1),
    new THREE.MeshPhongMaterial({ color: 0xa0adaf, shininess: 150 })
);
ground.rotation.x = -Math.PI / 2;  // rotate X/Y plane into X/Z
ground.receiveShadow = true;
threeScene.add(ground);
```

This rotation is easy to forget the first time. Remember it: Y is up, and a default plane needs a 90-degree X rotation to become a floor.

### The Renderer and Camera

The `WebGLRenderer` owns the `<canvas>` element. It is appended to the DOM container div, and its size is set to 80% of the window so there is room for the buttons above it.

```js
renderer = new THREE.WebGLRenderer();
renderer.setSize(0.8 * window.innerWidth, 0.8 * window.innerHeight);
container.appendChild(renderer.domElement);
```

The camera is a `PerspectiveCamera`. Its first argument is the vertical field of view in degrees, then the aspect ratio, then the near and far clipping planes. Anything closer than the near plane or farther than the far plane is invisible — set these reasonably to avoid floating-point precision artifacts.

```js
camera = new THREE.PerspectiveCamera(70, window.innerWidth / window.innerHeight, 0.01, 100);
camera.position.set(0, 1, 4);
threeScene.add(camera);
```

Note that the camera is added to the scene graph just like any other object. The `OrbitControls` object is then wired to the camera so the user can navigate:

```js
cameraControl = new THREE.OrbitControls(camera, renderer.domElement);
```

When the window is resized, the camera aspect ratio and renderer dimensions both need to be updated — a detail that is easy to overlook and causes a stretched image if missed.

---

## Run/Pause and Restart Controls

Before looking at the physics, it is worth covering two buttons that make interactive development much easier: Run and Restart.

The HTML buttons are wired to JavaScript functions via the `onclick` attribute. The Run button is given an `id` so the JavaScript can update its label.

```html
<button id="buttonRun" onclick="run()">Run</button>
<button onclick="restart()">Restart</button>
```

The Restart function is intentionally trivial:

```js
function restart() {
    location.reload();
}
```

Reloading the page is the simplest possible reset — it re-runs all initialization code and brings everything back to its initial state. For more complex simulations you might want a true reset that avoids the page flicker, but for quick iteration this is perfectly fine.

The Run function is slightly more interesting because it needs to toggle between two states and update the button label to reflect the current state:

```js
function run() {
    var button = document.getElementById('buttonRun');
    if (physicsScene.paused) {
        button.innerHTML = "Stop";
    } else {
        button.innerHTML = "Run";
    }
    physicsScene.paused = !physicsScene.paused;
}
```

The simulation starts paused (`paused: true` in the physics scene), so the user must explicitly press Run to begin. This gives time to inspect the initial configuration before anything moves.

---

## Organizing Physics: The Scene Object and Ball Class

The code makes a clean separation between physics state and rendering. A plain JavaScript object called `physicsScene` holds the parameters that govern the simulation:

```js
var physicsScene = {
    gravity: new THREE.Vector3(0.0, -10.0, 0.0),
    dt: 1.0 / 60.0,
    worldSize: { x: 1.5, z: 2.5 },
    paused: true,
    objects: [],
};
```

`THREE.Vector3` is used here not because it is a rendering concept, but because it is a convenient 3D vector type that ships with Three.js and supports the arithmetic methods we need. Gravity points in the negative Y direction — down — at 10 m/s², a good approximation of Earth's surface gravity. The time step is a fixed 1/60th of a second, matching a typical 60 Hz display.

### The Ball Class

Each simulated object is an instance of the `Ball` class. The constructor takes a starting position, radius, initial velocity, and the Three.js scene. It stores the physics quantities as member variables and immediately creates the visual representation:

```js
constructor(pos, radius, vel, scene) {
    this.pos = pos;
    this.radius = radius;
    this.vel = vel;

    var geometry = new THREE.SphereGeometry(radius, 32, 32);
    var material = new THREE.MeshPhongMaterial({ color: 0xff0000 });
    this.visMesh = new THREE.Mesh(geometry, material);
    this.visMesh.position.copy(pos);
    threeScene.add(this.visMesh);
}
```

The `32, 32` arguments to `SphereGeometry` are the horizontal and vertical segment counts for the sphere mesh. More segments means a rounder-looking ball at the cost of more geometry to render. 32 is a reasonable default — smooth enough to read as a sphere, cheap enough to run in real time.

The key insight here is the pairing: every physics object carries its own visual mesh. When the physics position updates, the mesh position follows. This keeps the connection between simulation and rendering local to the object rather than scattered across the code.

### The Simulation Step

The `simulate` method on `Ball` does the physics update for one time step. It is structurally identical to the 2D version from Chapter 1, now extended to three dimensions:

```js
simulate() {
    this.vel.addScaledVector(physicsScene.gravity, physicsScene.dt);
    this.pos.addScaledVector(this.vel, physicsScene.dt);

    // Boundary collisions on X and Z
    if (this.pos.x < -physicsScene.worldSize.x) {
        this.pos.x = -physicsScene.worldSize.x; this.vel.x = -this.vel.x;
    }
    if (this.pos.x >  physicsScene.worldSize.x) {
        this.pos.x =  physicsScene.worldSize.x; this.vel.x = -this.vel.x;
    }
    // ... same for Z axis ...
    if (this.pos.y < this.radius) {
        this.pos.y = this.radius; this.vel.y = -this.vel.y;
    }

    this.visMesh.position.copy(this.pos);
}
```

`addScaledVector(v, s)` is equivalent to `this += v * s` — it adds a vector multiplied by a scalar in one call. The two lines that use it implement explicit Euler integration: first accumulate velocity from gravity, then move the position by velocity. Both of those steps are multiplied by `dt` to convert rates (m/s, m/s²) into per-frame increments.

The boundary conditions are the same elastic reflection used in 2D: when the ball would leave a wall, clamp the position to the boundary and flip the velocity component perpendicular to that wall. The floor check uses `this.radius` rather than zero so the ball rests on its surface, not with its center at ground level.

The last line syncs the Three.js mesh position with the physics position. Without this call, the ball would move in the physics simulation but the rendered sphere would never move.

### Initialization and the Main Loop

Two functions wire everything together:

```js
function initPhysics() {
    var radius = 0.2;
    var pos = new THREE.Vector3(radius, radius, radius);
    var vel = new THREE.Vector3(2.0, 5.0, 3.0);
    physicsScene.objects.push(new Ball(pos, radius, vel));
}

function simulate() {
    if (physicsScene.paused) return;
    for (var i = 0; i < physicsScene.objects.length; i++)
        physicsScene.objects[i].simulate();
}
```

The `simulate` function checks the paused flag and, if the simulation is running, calls `simulate()` on every object. This loop over `physicsScene.objects` is the pattern that will scale to dozens or hundreds of objects in later chapters.

The render loop calls both simulate and the Three.js renderer each frame:

```js
function update() {
    simulate();
    renderer.render(threeScene, camera);
    cameraControl.update();
    requestAnimationFrame(update);
}
```

`requestAnimationFrame` asks the browser to call `update` before the next display refresh — typically at 60 Hz. This is the standard animation loop pattern on the web. `cameraControl.update()` must be called each frame for the orbit controls to apply any inertia or smooth motion they accumulate.

The startup sequence calls the three initialization functions in order, then kicks off the loop:

```js
initThreeScene();
initPhysics();
update();
```

---

## Adding VR Support

This is where the chapter earns its "cool part" label. Three.js has built-in support for WebXR, the browser API for VR and AR headsets. Converting the 3D demo to a VR demo requires exactly three changes inside `initThreeScene`:

```js
// 1. Add the VR button to the page
document.body.appendChild(VRButton.createButton(renderer));

// 2. Enable XR on the renderer
renderer.xr.enabled = true;

// 3. Hand animation control to the renderer
renderer.setAnimationLoop(update);
```

The third change replaces `requestAnimationFrame` — because in VR mode, the browser (or headset runtime) controls the timing, not the page's animation frame scheduler. Calling `renderer.setAnimationLoop(update)` registers `update` as the callback, and Three.js will call it at the appropriate rate for both desktop and VR sessions.

The `VRButton` class itself is a small utility that probes the browser for WebXR support and creates an "ENTER VR" button if a headset is available, or a "VR NOT SUPPORTED" message if not. When the user clicks the button, it initiates a WebXR immersive-vr session:

```js
navigator.xr.requestSession('immersive-vr', {
    optionalFeatures: ['local-floor', 'bounded-floor', 'hand-tracking']
}).then(onSessionStarted);
```

The optional features request floor tracking and hand tracking if the headset supports them, without requiring them. In VR mode, the camera is driven entirely by the headset's head tracking rather than `OrbitControls`, so the camera control is simply removed. The physics and rendering code is otherwise unchanged — the same simulation that works on desktop drops directly into a headset.

---

## Key Takeaways

- **Three.js as an accelerator.** Adding a full 3D renderer takes two script tags and roughly 50 lines of setup code. The investment is small and the payoff is large: shadows, camera controls, and an interactive viewport come for free.

- **Y is up.** Three.js uses a Y-up coordinate system. Gravity points in the negative Y direction, the floor is the X/Z plane, and planes need a -90 degree X rotation to lie flat.

- **Keep physics and rendering coupled at the object level.** Storing both `pos` (physics) and `visMesh` (rendering) on the same `Ball` instance — and syncing them at the end of each `simulate()` — keeps the code localized and easy to reason about.

- **Explicit Euler integration extends naturally to 3D.** The integration step from Chapter 1 is identical in 3D; only the types change from scalar to `Vector3`.

- **VR is three lines away.** If the physics runs in 3D with Three.js, WebXR support is almost free. The only real change is handing animation control to the renderer with `setAnimationLoop`.

- **Start paused.** Initializing `paused: true` and requiring the user to press Run is a small UX choice that makes a big difference during development — you can inspect the initial state before anything moves.
