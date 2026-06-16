# Chapter 2 — From 2D to 3D: Building Your First 3D Physics Scene

The cannonball simulation from Chapter 1 captured the essential mechanics of physics programming — an integration loop, Newtonian kinematics, and boundary collisions — but it lived on a flat canvas. This chapter lifts that simulation into three dimensions. Along the way we introduce the ink GPU library for 3D rendering, organize the physics into a clean array-programming style, and end with something genuinely interesting: a fully interactive 3D scene where multiple bouncing balls can be watched from any camera angle.

---

## Rendering in 3D with ink

Writing a 3D renderer from scratch is a months-long project. ink's GPU library (`lib/gpu/gpu.k`) provides the foundation: it wraps the system GPU API in a handful of functions that compile shader programs, upload mesh data, and run the render loop. A 3D scene requires:

```k
2: "lib/gpu/gpu.k"
2: "lib/gpu/spirv.k"
```

The main rendering primitives are:

- `RunWindow[loop_fn; config]` — starts the event loop, calls `loop_fn` each frame with window props
- `CompileMesh[vtx_shader; frag_shader]` — compiles a vertex+fragment pipeline
- `DrawMesh[verts; handle]` — draws a triangle mesh with stride-6 `[x y z nx ny nz]` layout

A vertex shader receives per-vertex position and normal, applies the camera transform, and outputs clip-space coordinates. A fragment shader computes the final pixel colour from the interpolated normal and lighting.

---

## The 3D Scene

Setting up a 3D scene requires a camera transform. The vertex shader applies a view-projection matrix. For simplicity, we can hard-code a perspective projection with a fixed camera position:

```k
/ Vertex shader: isometric camera at 45° Y + 35° X tilt, scale 0.5
vert: VertexShader[[pos:`v3; nor:`v3]; [vNor:`v3]; {[pos;nor]
  c45: 0.7071; s45: 0.7071; c30: 0.8165; s30: 0.5774; sc: 0.5
  py0: (c45*pos[0]) + s45*pos[2]
  py2: (c45*pos[2]) - s45*pos[0]
  px1: (c30*pos[1]) - s30*py2
  px2: (s30*pos[1]) + c30*py2
  ((sc*py0; sc*px1; 0.5-px2*sc*0.5; 1.0); nor)
}]

/ Fragment shader: Phong lighting with fixed light direction
frag: FragmentShader[[nor:`v3; out:`v4]; {[nor]
  ld: normalize[(0.5; 1.0; 0.3)]
  diff: max[0.0; dot[nor; ld]]
  (0.8*diff + 0.05; 0.5*diff + 0.05; 0.3*diff + 0.05; 1.0)
}]
```

This is the same shader pattern used in `test/sphere.k` and `test/planes.k` in the ink test suite.

---

## Coordinate System

We use a right-handed coordinate system with Y up. Gravity points in the negative Y direction at $10\ \text{m/s}^2$. The floor is the X/Z plane.

---

## Organizing Physics: Parallel Arrays

In 3D, each ball has a 3D position and 3D velocity. Rather than using objects, we store all balls as parallel flat arrays — one array per coordinate component. For $n$ balls:

```k
/ n balls in 3D, parallel arrays
n: 5
px: n # 0.; py: n # 0.5; pz: n # 0.     / positions
vx: n # 0.; vy: n # 0.; vz: n # 0.      / velocities
r: n # 0.2                               / radii
```

This layout is cache-friendly and allows vectorized operations over all balls simultaneously.

---

## The Simulation Step

Gravity, integration, and boundary reflection are all applied to all $n$ balls at once with array operations:

```k
g: -10.             / gravity (y-direction)
dt: 1.%60
wx: 1.5; wz: 2.5   / world half-extents

step3D: {[s]
  px:s@0; py:s@1; pz:s@2
  vx:s@3; vy:s@4; vz:s@5; r:s@6
  sdt: dt%10.
  / Gravity
  vy: vy + g*sdt
  / Integrate
  px: px + vx*sdt; py: py + vy*sdt; pz: pz + vz*sdt
  / Boundary reflection
  fx: (px<r) | px>wx-r; fy: py<r; fz: (pz<r) | pz>wz-r
  vx: vx*1.-2.*fx; vy: vy*1.-2.*fy; vz: vz*1.-2.*fz
  px: r|px&(wx-r); py: r|py; pz: r|pz&(wz-r)
  (px;py;pz;vx;vy;vz;r)
}
```

All $n$ balls are updated in one pass through array broadcasting.

---

## Building the Mesh for Rendering

Each ball is a sphere mesh. For rendering, we represent each sphere as a small icosphere (subdivided icosahedron) scaled by the ball's radius and translated to its position. The `test/sphere.k` example shows how to build a sphere mesh. For multiple balls, the mesh is simply the concatenation of per-ball sphere meshes, rebuilt each frame.

A simpler alternative for many balls is to render each as a single billboard (two triangles facing the camera), using a fragment shader with a circle SDF to draw the circular silhouette. This avoids rebuilding mesh data each frame.

---

## Run/Pause Control

An ink simulation can be paused by simply skipping the `step` call:

```k
paused:: 0

run: {[props]
  $[~paused; state:: 10 step3D/ state; 0]
  / draw state ...
}
```

The `::` operator assigns to the global `state` variable. `~paused` is "not paused."

---

## Key Takeaways

- **ink's GPU library** provides `RunWindow`, `CompileMesh`, and `DrawMesh` for 3D rendering. Vertex and fragment shaders are written as ink lambdas compiled to SPIR-V.
- **Y is up.** Gravity points in the negative Y direction. The floor is the X/Z plane.
- **Parallel arrays** for physics state — one array per coordinate component — allow vectorized updates over all particles simultaneously with no loops.
- **Symplectic Euler extends naturally to 3D.** The integration step from Chapter 1 is identical in 3D; only the array shapes change.
- **Array operations** eliminate the need for per-ball loops: one line updates all ball positions, one line checks all boundaries.
