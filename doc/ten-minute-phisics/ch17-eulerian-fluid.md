# Chapter 17 — Eulerian Fluid Simulation

Fluid simulation sits at the heart of visual effects, weather modeling, and aerodynamic engineering. Yet the core algorithm for an incompressible fluid — the kind that produces the mesmerizing vortex street behind a cylinder in a wind tunnel — fits in roughly 200 lines of code. This chapter builds that simulator from the ground up, covering the mathematical foundations, the data structures that make the numerics tractable, and the implementation decisions that keep the code both simple and stable.

---

## Two Ways to Think About Fluid

There are two classical frameworks for simulating a fluid. The choice between them shapes everything that follows.

The **Lagrangian** approach, associated with the mathematician Joseph-Louis Lagrange, tracks individual fluid particles as they move through space. You follow the atoms (or a representative sample of them), updating each particle's position and velocity at every step. The method is intuitive and naturally handles free surfaces such as splashing water, but the data structure becomes irregular and expensive to query as particles wander far from their initial positions.

The **Eulerian** approach, associated with Leonhard Euler, takes the opposite view: instead of following particles, you fix a grid in space and record what is happening at each grid point — how fast is the fluid moving here, at this location, right now? The fluid flows through the grid rather than being represented by it. The data stays organized in regular arrays, cache-friendly and straightforward to index, which is why Eulerian methods dominate scientific and engineering simulation.

This chapter implements an Eulerian simulator. The fluid is 2D, incompressible, and inviscid. The 3D extension follows the same logic with an additional grid dimension. Adding viscosity is a modest further step; compressible flow is a separate topic.

---

## The Governing Equations

The physics of an incompressible, inviscid fluid are described by the **incompressible Euler equations** (a simplified form of the Navier-Stokes equations with zero viscosity):

**Momentum equation** (Newton's second law for a fluid parcel):

$$\frac{\partial \mathbf{v}}{\partial t} + (\mathbf{v} \cdot \nabla)\mathbf{v} = -\frac{1}{\rho}\nabla p + \mathbf{g}$$

**Incompressibility constraint** (fluid neither created nor destroyed):

$$\nabla \cdot \mathbf{v} = 0$$

Here **v** = (u, v) is the velocity field, p is pressure, ρ is fluid density, and **g** is gravitational acceleration. The left-hand side of the momentum equation is the material derivative — the rate of change of velocity following a fluid parcel. The right-hand side contains the pressure gradient force and gravity.

The incompressibility constraint says that the **divergence** of the velocity field must be zero everywhere. Divergence measures net outflow: if more fluid is leaving a small volume than entering it, the constraint is violated.

In practice the simulator enforces these two equations through three sequential steps each frame: apply external forces, project the velocity field to make it divergence-free, and advect the field forward in time.

---

## The Staggered MAC Grid

Before looking at the simulation steps, the choice of grid layout deserves attention because it determines how every formula is written and indexed.

A naive approach stores all velocity components at cell centers (a **collocated** grid). This leads to a well-known numerical instability: the pressure and velocity equations decouple in a checkerboard pattern, producing unphysical oscillations.

The fix, proposed by Harlow and Welch in 1965, is the **MAC grid** (Marker-And-Cell), also called a staggered grid. On this grid:

- The horizontal velocity component **u** is stored at the center of vertical cell faces (left and right edges).
- The vertical velocity component **v** is stored at the center of horizontal cell faces (top and bottom edges).
- Scalar quantities such as pressure **p** and smoke density **m** are stored at cell centers.

```
    v[i,j+1]
       |
u[i,j]--[p,m]--u[i+1,j]
       |
    v[i,j]
```

This arrangement has a direct physical reading: `u[i+1,j] - u[i,j]` is the net horizontal outflow from cell (i, j), and `v[i,j+1] - v[i,j]` is the net vertical outflow. The divergence is simply their sum, computed with no averaging required. Face-centered storage also means that the no-slip boundary condition at walls — zero normal velocity — is enforced exactly by zeroing the single face value that crosses the wall.

In code the grid is stored as flat arrays indexed by `i*numY + j`:

```javascript
class Fluid {
    constructor(density, numX, numY, h) {
        this.density = density;
        this.numX = numX + 2;   // two extra columns for border cells
        this.numY = numY + 2;
        this.numCells = this.numX * this.numY;
        this.h = h;             // cell size in metres
        this.u  = new Float32Array(this.numCells);  // horizontal velocity
        this.v  = new Float32Array(this.numCells);  // vertical velocity
        this.newU = new Float32Array(this.numCells);
        this.newV = new Float32Array(this.numCells);
        this.p  = new Float32Array(this.numCells);  // pressure
        this.s  = new Float32Array(this.numCells);  // 0 = solid, 1 = fluid
        this.m  = new Float32Array(this.numCells);  // smoke density
        this.newM = new Float32Array(this.numCells);
        this.m.fill(1.0);
    }
    // ...
}
```

The `s` array encodes obstacles and walls: a cell with `s[i,j] = 0` is solid and its faces are treated as no-flow boundaries. This single flag handles walls, obstacles, and moving objects uniformly.

---

## The Simulation Loop

Each frame runs three steps in order:

```
1. integrate   — apply gravity to v components
2. project     — enforce incompressibility (pressure solve)
3. advect      — move the velocity and smoke fields
```

### Step 1: External Forces (Gravity)

The simplest step. For every interior fluid cell, add gravity times the time step to the vertical velocity component:

```javascript
integrate(dt, gravity) {
    var n = this.numY;
    for (var i = 1; i < this.numX; i++) {
        for (var j = 1; j < this.numY - 1; j++) {
            // only update faces between two fluid cells
            if (this.s[i*n + j] != 0.0 && this.s[i*n + j-1] != 0.0)
                this.v[i*n + j] += gravity * dt;
        }
    }
}
```

The check on `s` prevents applying gravity at solid-cell faces.

### Step 2: Projection (Enforcing Incompressibility)

This is the mathematical core of the simulation. After gravity is applied, the velocity field generally has nonzero divergence — fluid is accumulating or depleting in some cells. The projection step corrects each cell's adjacent face velocities to drive the divergence to zero.

For cell (i, j) the divergence is:

$$d = u_{i+1,j} - u_{i,j} + v_{i,j+1} - v_{i,j}$$

If d > 0 there is net outflow; if d < 0 there is net inflow. To zero out the divergence we push the four surrounding face velocities outward by equal amounts, subject to the obstacle flags s of the neighboring cells:

$$u_{i,j} \mathrel{-}= \frac{d \cdot s_{i-1,j}}{s_\text{total}}, \quad
u_{i+1,j} \mathrel{+}= \frac{d \cdot s_{i+1,j}}{s_\text{total}}, \quad
v_{i,j} \mathrel{-}= \frac{d \cdot s_{i,j-1}}{s_\text{total}}, \quad
v_{i,j+1} \mathrel{+}= \frac{d \cdot s_{i,j+1}}{s_\text{total}}$$

where s_total = s_{i-1,j} + s_{i+1,j} + s_{i,j-1} + s_{i,j+1}. A solid neighbor (s = 0) contributes nothing; the correction is distributed only among the free faces. This naturally handles corners, edges, and arbitrary obstacle shapes.

Applying this update to every cell one pass does not fully enforce incompressibility, because correcting one cell disturbs its neighbors. The fix is to iterate. The method is **Gauss-Seidel iteration**: run through all cells in order, updating immediately so each correction benefits subsequent cells in the same pass. Repeating 40–100 times gives a satisfactory result.

**Overrelaxation** makes the iteration converge dramatically faster. Instead of correcting exactly to zero divergence, multiply the correction by a constant ω ∈ (1, 2). The implementation uses ω = 1.9:

$$d \leftarrow \omega \cdot (u_{i+1,j} - u_{i,j} + v_{i,j+1} - v_{i,j})$$

This is not merely a heuristic — it is the successive overrelaxation (SOR) method, and the final converged solution is identical to plain Gauss-Seidel. The difference is that without overrelaxation the pressure field can take hundreds of iterations to propagate across the domain; with ω = 1.9 the same quality is reached in a fraction of the iterations.

The pressure itself is accumulated as a by-product of the projection, using the relation between velocity corrections and pressure gradients:

$$p_{i,j} \mathrel{+}= \frac{\rho h}{\Delta t} \cdot \frac{d}{s_\text{total}}$$

```javascript
solveIncompressibility(numIters, dt) {
    var n  = this.numY;
    var cp = this.density * this.h / dt;

    for (var iter = 0; iter < numIters; iter++) {
        for (var i = 1; i < this.numX - 1; i++) {
            for (var j = 1; j < this.numY - 1; j++) {

                if (this.s[i*n + j] == 0.0) continue;

                var sx0 = this.s[(i-1)*n + j];
                var sx1 = this.s[(i+1)*n + j];
                var sy0 = this.s[i*n + j-1];
                var sy1 = this.s[i*n + j+1];
                var s   = sx0 + sx1 + sy0 + sy1;
                if (s == 0.0) continue;

                var div = this.u[(i+1)*n + j] - this.u[i*n + j]
                        + this.v[i*n + j+1]   - this.v[i*n + j];

                var p = -div / s;
                p *= scene.overRelaxation;      // ω = 1.9
                this.p[i*n + j] += cp * p;

                this.u[i*n + j]     -= sx0 * p;
                this.u[(i+1)*n + j] += sx1 * p;
                this.v[i*n + j]     -= sy0 * p;
                this.v[i*n + j+1]   += sy1 * p;
            }
        }
    }
}
```

The pressure accumulation is not needed for the velocity computation — it is just useful for visualization and debugging.

### Step 3: Advection (Semi-Lagrangian)

The velocity field must now be moved forward in time. In a real fluid, momentum is carried by the fluid particles themselves; on a grid, this transport must be computed explicitly. The challenge is doing so stably.

**Forward advection** — moving values in the direction of flow — is numerically unstable. Tiny errors grow exponentially. The standard solution is **semi-Lagrangian advection**, which traces characteristics backward in time.

The idea: to find the new velocity at a grid face, ask which fluid parcel arrived at that face during this time step. Trace that parcel backward from the face position **x** along the velocity field for time Δt to find where it came from:

$$\mathbf{x}_\text{prev} = \mathbf{x} - \Delta t \cdot \mathbf{v}(\mathbf{x})$$

Then sample the velocity field at **x**_prev — that is the value the face inherits. Crucially, this backward trace always lands inside the existing grid, so the method is unconditionally stable regardless of time-step size.

Sampling the field at **x**_prev requires **bilinear interpolation** between the four surrounding face values. For a point at fractional coordinates (tx, ty) within a cell:

$$f = (1-t_x)(1-t_y)\,f_{00} + t_x(1-t_y)\,f_{10} + t_x t_y\,f_{11} + (1-t_x)t_y\,f_{01}$$

One subtlety on the staggered grid: the u and v components live at different positions. To advect the u component at face (i, j), the full 2D velocity **v** = (u, v) must be assembled at that face's physical location. The u value is available directly; the v value must be averaged from the four surrounding v-faces in the neighborhood:

```javascript
avgV(i, j) {
    var n = this.numY;
    return (this.v[(i-1)*n + j] + this.v[i*n + j] +
            this.v[(i-1)*n + j+1] + this.v[i*n + j+1]) * 0.25;
}
```

The full advection pass writes results into temporary arrays `newU` and `newV` to avoid using partially-updated values within the same time step:

```javascript
advectVel(dt) {
    this.newU.set(this.u);
    this.newV.set(this.v);
    var n = this.numY;
    var h = this.h, h2 = 0.5 * h;

    for (var i = 1; i < this.numX; i++) {
        for (var j = 1; j < this.numY; j++) {

            // advect u component
            if (this.s[i*n+j] != 0.0 && this.s[(i-1)*n+j] != 0.0 && j < this.numY-1) {
                var x = i*h,      y = j*h + h2;
                var u = this.u[i*n + j];
                var v = this.avgV(i, j);
                x -= dt * u;  y -= dt * v;
                this.newU[i*n + j] = this.sampleField(x, y, U_FIELD);
            }

            // advect v component
            if (this.s[i*n+j] != 0.0 && this.s[i*n+j-1] != 0.0 && i < this.numX-1) {
                var x = i*h + h2, y = j*h;
                var u = this.avgU(i, j);
                var v = this.v[i*n + j];
                x -= dt * u;  y -= dt * v;
                this.newV[i*n + j] = this.sampleField(x, y, V_FIELD);
            }
        }
    }
    this.u.set(this.newU);
    this.v.set(this.newV);
}
```

The straight-line backward trace is an approximation — the true characteristic follows a curved path. This approximation introduces a small amount of **numerical diffusion** (artificial viscosity), slightly smoothing the flow over many steps. Techniques such as vorticity confinement can compensate for this effect when sharper features are needed.

---

## Smoke and Visualization

The velocity field is invisible on its own. A common and cheap visualization strategy is to advect a passive **smoke density** scalar alongside the velocity. The smoke field `m` stores a value in [0, 1] at each cell center; it contributes no forces and only follows the flow. Advecting it is identical in structure to advecting velocity, but simpler because scalar values live at cell centers rather than at faces:

```javascript
advectSmoke(dt) {
    this.newM.set(this.m);
    var n = this.numY, h = this.h, h2 = 0.5 * h;

    for (var i = 1; i < this.numX - 1; i++) {
        for (var j = 1; j < this.numY - 1; j++) {
            if (this.s[i*n + j] != 0.0) {
                var u = (this.u[i*n+j] + this.u[(i+1)*n+j]) * 0.5;
                var v = (this.v[i*n+j] + this.v[i*n+j+1]) * 0.5;
                var x = i*h + h2 - dt*u;
                var y = j*h + h2 - dt*v;
                this.newM[i*n + j] = this.sampleField(x, y, S_FIELD);
            }
        }
    }
    this.m.set(this.newM);
}
```

The wind-tunnel demo seeds a thin stripe of smoke at the inlet and lets the flow carry it around the obstacle. The resulting vortex-shedding pattern — smoke curling into alternating eddies downstream — emerges purely from the simulation with no special-case logic.

Pressure visualization uses a scientific colormap (blue-cyan-green-yellow-red) mapped to the pressure range found in that frame. Displaying pressure minus smoke simultaneously produces an artistic, physically interpretable rendering.

---

## Boundary Conditions

Two types of boundary conditions arise.

**Wall cells** are handled by the obstacle flag `s`. Setting `s[i,j] = 0` marks a solid cell; the projection step automatically excludes its faces from updates because the neighboring-s terms evaluate to zero. No special code is needed — the obstacle handling falls out of the general formula.

**Moving obstacles** require the velocity of the obstacle surface to be imposed on the adjacent face values. When the user drags the circular obstacle, its velocity is computed from the displacement between frames and stamped into the surrounding grid faces:

```javascript
f.u[i*n + j]     = vx;   // obstacle horizontal velocity
f.u[(i+1)*n + j] = vx;
f.v[i*n + j]     = vy;
f.v[i*n + j+1]   = vy;
```

**Border cells** are handled by copying the values of the adjacent interior cells (`extrapolate`), which approximates a free-slip or zero-gradient condition at the domain boundary.

---

## Putting It Together

The top-level simulate method calls the three steps in the correct order:

```javascript
simulate(dt, gravity, numIters) {
    this.integrate(dt, gravity);
    this.p.fill(0.0);
    this.solveIncompressibility(numIters, dt);
    this.extrapolate();
    this.advectVel(dt);
    this.advectSmoke(dt);
}
```

Pressure is zeroed before each projection pass — the incremental accumulation within `solveIncompressibility` is reset so pressure reflects only the current frame's corrections rather than accumulating indefinitely. The order matters: forces first, then projection to clean up divergence, then advection to carry the corrected field forward.

Typical parameters for an interactive wind-tunnel simulation at 100×50 cells: time step Δt = 1/60 s, 40 projection iterations, overrelaxation ω = 1.9. A higher-resolution run at 200×100 cells uses 100 iterations and Δt = 1/120 s for visual quality. The tank scene uses gravity = −9.81 m/s²; the wind tunnel sets gravity to zero and applies a horizontal inlet velocity of 2 m/s at the left boundary.

---

## Key Takeaways

- **Eulerian simulation** stores fluid state on a fixed grid. Data stays in regular arrays, making it cache-friendly and easy to implement.
- The **staggered MAC grid** places velocity components on cell faces rather than centers. This eliminates the pressure–velocity decoupling instability and makes the divergence formula exact and cheap to compute.
- **Projection** drives the velocity field to be divergence-free by iteratively correcting face velocities using the local divergence. Gauss-Seidel iteration is the simplest solver; **overrelaxation** (ω ≈ 1.9) dramatically accelerates convergence at no cost to accuracy.
- **Semi-Lagrangian advection** traces characteristics backward in time, sampling the existing field at the departure point. It is unconditionally stable and straightforward to implement with bilinear interpolation.
- **Obstacle handling** requires only a single `s` flag per cell. Moving obstacles impose their velocity on adjacent face values; the projection step handles the no-penetration constraint automatically.
- A passive **smoke density** can be advected alongside the velocity field to produce rich visualizations with no additional simulation cost.
- The complete simulator — forces, projection, advection — fits in roughly 200 lines of code and runs in real time in a browser at moderate grid resolutions.
