# Chapter 8 — User Interaction: Picking and Dragging in 3D

A physics simulation that runs on its own is satisfying to watch. One that responds to your touch is compelling to use. This chapter adds that missing ingredient: the ability to reach into a 3D scene with a mouse or finger, grab a simulated object, drag it through space, and release it with velocity. Along the way we will work through the mathematics of unprojecting a 2D screen point into a 3D ray, the mechanics of raycasting, and the design of a small, reusable `Grabber` class that keeps camera control and object dragging from stepping on each other.


## The Geometry of Seeing

Before we can pick anything, we need to understand what a 2D click actually means in 3D.

The scene displayed on screen is a *perspective projection* of a 3D world. Every pixel on screen corresponds not to a single world point but to an entire line — a ray that stretches from the camera's near plane outward through that pixel and into infinity. This is the **mouse ray**. Its origin is roughly the camera position, and its direction is the vector from the camera through the clicked screen pixel.

A useful analogy: close one eye and hold a pencil at arm's length. No matter how you orient the pencil, you can tilt it so that it appears as a single dot. The entire length of the pencil maps to that one point in your visual field. Clicking on a pixel in a 3D viewport is the inverse problem — given that dot, reconstruct all the possible 3D positions it could represent.

Concretely, if the camera has position **o** and we can compute the unit direction **d** toward the clicked pixel, then any point on the mouse ray is:

```
P(t) = o + t · d,   t ≥ 0
```

The parameter *t* is a depth along the ray. Converting a screen-space pixel into this (o, d) pair is called **unprojection**.


## Raycasting: Finding What the Mouse Hits

Once we have the mouse ray, we cast it into the scene to find intersections with geometry. For each object, we solve for the values of *t* at which the ray touches the surface. A sphere of radius *r* centered at **c** yields a quadratic in *t*; a triangle mesh is tested face by face.

In practice the renderer library handles all of this. Three.js provides a `Raycaster` that takes a camera and a normalized device coordinate (NDC) — a 2D value in [-1, 1] × [-1, 1] — computes the ray, and intersects it against any scene objects you hand it. The result is a list of hits sorted by ascending *t*, so `intersects[0]` is always the nearest surface.

To keep pickable objects separate from decorative geometry such as the ground plane or grid lines, Three.js supports **layers**. We assign layer 1 to every physics object mesh and configure the raycaster to only consider layer 1:

```js
this.raycaster = new THREE.Raycaster();
this.raycaster.layers.set(1);
```

On the physics object side, enabling the layer on the mesh is one line:

```js
this.visMesh.layers.enable(1);
```

Everything that should not be pickable simply stays on the default layer 0.


## Linking Visual Meshes to Physics Objects

Raycasting returns a Three.js mesh. But we need to know which physics object owns that mesh so we can call its interaction methods. Three.js provides a general-purpose `userData` property on every object for exactly this kind of back-reference:

```js
this.visMesh.userData = this;   // 'this' is the Ball instance
```

When a raycast hit comes back, we recover the physics object with a single property lookup:

```js
var obj = intersects[0].object.userData;
```

This pattern — attaching a physics object reference to its visual mesh — appears in every subsequent tutorial. It is the glue between the rendering world and the simulation world.


## Dragging at a Fixed Depth

Once we know which object was clicked and at what distance *t = d_down* along the ray, we have enough information to drag it smoothly.

The key insight is that during a drag we do not need to raycast on every mouse-move event. We already know the depth of the grab point in camera space. As the mouse moves, we compute the new mouse ray and evaluate it at the same stored depth:

```
grab_pos = ray.origin + d_down · ray.direction
```

This keeps the object on a spherical shell around the camera at radius *d_down*, which closely approximates the flat plane perpendicular to the viewing direction passing through the original grab point. For typical viewing angles and moderate drags the difference is imperceptible, and the approach is far cheaper than solving a plane-ray intersection on every event.


## The Grabber Class

All of the above logic lives in a single class. Here is the full implementation:

```js
class Grabber {
    constructor() {
        this.raycaster = new THREE.Raycaster();
        this.raycaster.layers.set(1);
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
        this.mousePos.x = ((x - rect.left) / rect.width)  *  2 - 1;
        this.mousePos.y = -((y - rect.top)  / rect.height) * 2 + 1;
        this.raycaster.setFromCamera(this.mousePos, gCamera);
    }

    start(x, y) {
        this.physicsObject = null;
        this.updateRaycaster(x, y);
        var intersects = this.raycaster.intersectObjects(gThreeScene.children);
        if (intersects.length > 0) {
            var obj = intersects[0].object.userData;
            if (obj) {
                this.physicsObject = obj;
                this.distance = intersects[0].distance;
                var pos = this.raycaster.ray.origin.clone();
                pos.addScaledVector(this.raycaster.ray.direction, this.distance);
                this.physicsObject.startGrab(pos);
                this.prevPos.copy(pos);
                this.vel.set(0, 0, 0);
                this.time = 0.0;
                if (gPhysicsScene.paused) run();
            }
        }
    }

    move(x, y) {
        if (this.physicsObject) {
            this.updateRaycaster(x, y);
            var pos = this.raycaster.ray.origin.clone();
            pos.addScaledVector(this.raycaster.ray.direction, this.distance);

            this.vel.copy(pos).sub(this.prevPos);
            if (this.time > 0.0)
                this.vel.divideScalar(this.time);
            else
                this.vel.set(0, 0, 0);

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
```

A few details worth noting:

**Coordinate conversion.** The `updateRaycaster` method converts from document pixel coordinates to NDC. The `getBoundingClientRect()` call accounts for the canvas being offset within the page, and the Y axis is flipped because browser Y increases downward while NDC Y increases upward.

**Velocity tracking.** The grabber maintains a running estimate of drag velocity. Each `move` call records the displacement since the last call and divides by the elapsed simulation time (tracked via `increaseTime`). This velocity is passed to `endGrab` so the object can be released with momentum — throw physics emerges naturally.

**Auto-start.** If the simulation is paused when the user clicks, `start` automatically unpauses it. There is no point picking a frozen object.


## Coordinating with the Camera

A 3D scene typically has an orbit camera controlled by mouse drag. But when the user is dragging a physics object, those same mouse events should move the object, not rotate the camera. The two behaviors must be mutually exclusive.

The `onPointer` function handles this by enabling and disabling camera control around the grab:

```js
function onPointer(evt) {
    evt.preventDefault();
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
```

Using `pointerdown / pointermove / pointerup` rather than their mouse equivalents gives touch support for free — pointer events unify mouse, stylus, and finger input under one API.


## Making the Ball Grabbable

The physics object needs to implement three methods that the grabber calls: `startGrab`, `moveGrabbed`, and `endGrab`. For a simple rigid body the implementations are minimal:

```js
startGrab(pos) {
    this.grabbed = true;
    this.pos.copy(pos);
    this.visMesh.position.copy(pos);
}

moveGrabbed(pos, vel) {
    this.pos.copy(pos);
    this.visMesh.position.copy(pos);
}

endGrab(pos, vel) {
    this.grabbed = false;
    this.vel.copy(vel);
}
```

The `grabbed` flag tells `simulate` to skip integration for this object while it is being held:

```js
simulate() {
    if (this.grabbed) return;
    // ... gravity integration, collision response ...
}
```

This interface — three methods with a position and velocity — is intentionally general. For a rigid body we teleport the body to the mouse position. For a soft body we would instead find the nearest particle and pin it kinematically, moving it each frame. For a rigid body with weight feedback we would attach a zero-rest-length spring between the grab point and a local attachment position on the body. The grabber itself does not change; only the three methods change.


## Variations on Dragging

The simple "teleport to cursor" approach works well for demonstrations, but two more physically interesting variations are worth knowing.

**Spring dragging.** At `startGrab`, compute a local attachment point on the body in its own frame. Create a zero-rest-length spring connecting that point to a global anchor. At `moveGrabbed`, move the anchor to the cursor position. The object follows with a lag proportional to its mass and the spring stiffness, giving the user a tactile sense of the object's weight.

**Soft body pinning.** At `startGrab`, find the particle nearest to the grab position and mark it kinematic. At `moveGrabbed`, set that particle's position directly to the cursor. At `endGrab`, restore the particle to dynamic simulation. This is how the next chapter extends the grabber for cloth and soft bodies.


## Key Takeaways

- A mouse click in a 3D viewport defines a **ray**, not a point. The ray's origin is near the camera and its direction passes through the clicked pixel.
- **Raycasting** intersects this ray with scene geometry to find what was clicked and at what depth.
- During a drag, reusing the **stored depth** from the initial click to reproject mouse movement is simple and visually correct for typical viewing conditions.
- A `userData` back-reference on each visual mesh bridges the gap between the renderer's scene graph and the physics simulation's object list.
- Three methods — `startGrab`, `moveGrabbed`, `endGrab` — form a clean interface that the grabber calls without knowing anything about the underlying simulation. Rigid bodies, soft bodies, and constraints all implement the same interface differently.
- Camera orbit control and object dragging must be **mutually exclusive**; disabling the camera control while a grab is active and restoring it on release keeps both behaviors working correctly.
