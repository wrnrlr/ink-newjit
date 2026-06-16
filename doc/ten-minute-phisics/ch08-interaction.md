# Chapter 8 — User Interaction: Picking and Dragging in 3D

A physics simulation that runs on its own is satisfying to watch. One that responds to your touch is compelling to use. This chapter adds that missing ingredient: the ability to reach into a 3D scene, grab a simulated object, drag it through space, and release it with velocity. Along the way we work through the mathematics of unprojecting a 2D screen point into a 3D ray, the mechanics of raycasting, and a clean design for separating camera control from object dragging.

---

## The Geometry of Seeing

Before we can pick anything, we need to understand what a 2D click actually means in 3D.

The scene displayed on screen is a *perspective projection* of a 3D world. Every pixel on screen corresponds not to a single world point but to an entire line — a ray that stretches from the camera's near plane outward through that pixel and into infinity. This is the **mouse ray**. Its origin is roughly the camera position, and its direction is the vector from the camera through the clicked screen pixel.

Concretely, if the camera has position $\mathbf{o}$ and we can compute the unit direction $\mathbf{d}$ toward the clicked pixel, then any point on the mouse ray is:

$$P(t) = \mathbf{o} + t\, \mathbf{d}, \quad t \geq 0$$

The parameter $t$ is a depth along the ray. Converting a screen-space pixel into this $(\mathbf{o}, \mathbf{d})$ pair is called **unprojection**.

---

## Raycasting: Finding What the Mouse Hits

Once we have the mouse ray, we cast it into the scene to find intersections with geometry. For each object we solve for the values of $t$ at which the ray touches the surface.

**Sphere intersection.** A sphere of radius $r$ centered at $\mathbf{c}$ yields a quadratic in $t$. Let $\mathbf{f} = \mathbf{o} - \mathbf{c}$:

$$|\mathbf{f} + t\, \mathbf{d}|^2 = r^2$$
$$t^2 + 2(\mathbf{f} \cdot \mathbf{d})\,t + |\mathbf{f}|^2 - r^2 = 0$$

In ink, the discriminant and smallest positive root:

```k
/ Ray-sphere intersection. Returns t, or infinity if no hit.
/ ray: (ox;oy;oz;dx;dy;dz) sphere: (cx;cy;cz;r)
raySphere: {[ray;sph]
  ox:ray@0; oy:ray@1; oz:ray@2
  dx:ray@3; dy:ray@4; dz:ray@5
  cx:sph@0; cy:sph@1; cz:sph@2; r:sph@3
  fx:ox-cx; fy:oy-cy; fz:oz-cz
  b: (fx*dx) + (fy*dy) + fz*dz
  c: (fx*fx) + (fy*fy) + (fz*fz) - r*r
  disc: (b*b) - c
  $[disc<0.; 0w; / no hit
    [sq: sqrt disc
     t1: -b-sq; t2: -b+sq
     $[t1>0.; t1; $[t2>0.; t2; 0w]]]]
}
```

`0w` is ink's positive infinity, used as a sentinel for "no hit". The nearest hit across all spheres is found with `&/`:

```k
/ Nearest sphere index for a ray. spheres: list of (cx;cy;cz;r) tuples
nearestSphere: {[ray;spheres]
  ts: raySphere[ray;] each spheres
  i: ts?&/ts                   / index of minimum t
  $[ts@i<0w; i; -1]            / -1 if no hit
}
```

---

## Dragging at a Fixed Depth

Once we know which object was clicked and at what depth $d_{\text{down}} = t_{\text{hit}}$ along the ray, we can drag smoothly.

The key insight is that during a drag we do not need to raycast on every mouse-move event. We already know the depth of the grab point in camera space. As the mouse moves, compute the new mouse ray and evaluate it at the same stored depth:

$$\mathbf{g} = \mathbf{o}_{\text{new}} + d_{\text{down}}\, \mathbf{d}_{\text{new}}$$

This keeps the object on a spherical shell around the camera at radius $d_{\text{down}}$, which closely approximates the flat plane perpendicular to the viewing direction through the original grab point. For typical viewing angles and moderate drags the difference is imperceptible, and the approach is far cheaper than solving a plane-ray intersection on every event.

---

## Grabber Design in Ink

In ink, a grabber is a small state tuple threaded through the simulation state. When the user clicks, we record the grabbed particle index and its grab position; when the user moves, we update that position and propagate constraints; when the user releases, we restore the particle to dynamic simulation.

For a soft body the grab works by pinning one particle: its inverse mass is set to zero for the duration of the drag.

```k
/ Grabber state: (grabIdx; grabPos3D; savedInvMass)
/ -1 for grabIdx means nothing is grabbed

startGrab: {[simState; particleIdx; grabPos]
  invM: simState@`invM
  savedM: invM@particleIdx
  invM2: @[invM; particleIdx; :; 0.]   / pin particle (infinite mass)
  (`grabIdx; particleIdx; `grabPos; grabPos; `savedInvMass; savedM;
   `invM; invM2)
}

moveGrab: {[simState; grabPos]
  idx: simState@`grabIdx
  $[idx<0; simState;
    [pos: simState@`pos
     pos2: @[pos; idx; :; grabPos]     / teleport pinned particle
     simState,(`pos; pos2; `grabPos; grabPos)]]
}

endGrab: {[simState; throwVel]
  idx: simState@`grabIdx
  $[idx<0; simState;
    [invM: simState@`invM
     invM2: @[invM; idx; :; simState@`savedInvMass]
     vel: simState@`vel
     vel2: @[vel; idx; :; throwVel]
     simState,(`grabIdx; -1; `invM; invM2; `vel; vel2)]]
}
```

---

## Nearest Particle Search

For soft bodies, `startGrab` must first find which particle is closest to the grab point. This is a straightforward loop, vectorized in ink:

```k
/ Index of particle nearest to point p3
/ pos: flat (3×n) array; p3: 3-element vector
nearestParticle: {[pos;p3;n]
  dx: (pos@(3*!n)) - p3@0
  dy: (pos@(1+3*!n)) - p3@1
  dz: (pos@(2+3*!n)) - p3@2
  d2: (dx*dx) + (dy*dy) + dz*dz
  d2?&/d2
}
```

This computes the squared distance from every particle to the grab point in a single vectorized pass, then returns the index of the minimum.

---

## Unprojecting the Mouse Position

Mapping from a 2D mouse position to a 3D ray requires the inverse of the projection-view transformation. The projection matrix $P$ and view matrix $V$ together map world space to clip space:

$$\mathbf{x}_{\text{clip}} = P V \mathbf{x}_{\text{world}}$$

Unprojection inverts this. Starting from NDC coordinates $(u, v) \in [-1, 1]^2$:

1. Transform $(u, v, -1, 1)$ by $(PV)^{-1}$ to get the ray origin in world space.
2. Transform $(u, v, +1, 1)$ similarly to get the ray end.
3. Subtract and normalize to get the ray direction $\mathbf{d}$.

In ink's GPU framework, the camera matrices are available as uniforms. The unprojection matrix $(PV)^{-1}$ can be precomputed each frame and passed as a uniform. The ray construction then becomes 8 multiplications and a normalization per click.

---

## Coordinating with Camera Orbit

A 3D scene typically has an orbit camera controlled by mouse drag. When the user drags a physics object, those same mouse events should move the object — not rotate the camera. The two behaviors must be mutually exclusive.

The rule is simple: if `startGrab` found a physics object (`grabIdx ≥ 0`), suppress camera orbit events until `endGrab` is called. If `startGrab` found nothing, route all subsequent drag events to the camera.

---

## Variations on Dragging

**Spring dragging.** Rather than teleporting the grabbed particle to the cursor, attach a zero-rest-length spring between the cursor position and the particle. The object follows the cursor with a lag proportional to its mass. For stiff springs this is visually identical to teleporting but gives the user tactile feedback of the object's weight.

```k
/ Spring grab: add an external force pulling particle idx toward target
springGrabForce: {[pos;idx;target;stiffness]
  dx: (target@0) - pos@(3*idx)
  dy: (target@1) - pos@(1+3*idx)
  dz: (target@2) - pos@(2+3*idx)
  stiffness * (dx;dy;dz)
}
```

**Velocity throw.** Track the drag velocity by recording position differences between frames. On release, inject this velocity into the grabbed particle so the object flies along the throw direction.

---

## Key Takeaways

- A mouse click in a 3D viewport defines a **ray**, not a point. The ray's origin is near the camera; its direction passes through the clicked pixel.
- **Ray-sphere intersection** is a quadratic in $t$. The minimum positive root is the nearest hit; `0w` (infinity) encodes a miss.
- During a drag, reusing the **stored depth** $d_{\text{down}}$ from the initial click to reproject mouse movement is simple and visually correct for typical viewing conditions.
- **Pinning a particle** by setting its inverse mass to zero is the cleanest way to grab a soft body. Constraints propagate the pin's effect through the entire mesh automatically.
- **Nearest-particle search** is a vectorized distance computation: `d2?&/d2` finds the index in one pass.
- Camera orbit control and object dragging must be **mutually exclusive**; suppress orbit events while a grab is active.
