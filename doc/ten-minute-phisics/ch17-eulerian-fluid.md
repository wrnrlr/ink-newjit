# Chapter 17 — Eulerian Fluid Simulation

Fluid simulation sits at the heart of visual effects, weather modeling, and aerodynamic engineering. Yet the core algorithm for an incompressible fluid — the kind that produces the mesmerizing vortex street behind a cylinder in a wind tunnel — fits in roughly 200 lines of code. This chapter builds that simulator from the ground up, covering the mathematical foundations, the data structures that make the numerics tractable, and the implementation decisions that keep the code both simple and stable.

---

## Two Ways to Think About Fluid

There are two classical frameworks for simulating a fluid.

The **Lagrangian** approach tracks individual fluid particles as they move through space. You follow particles, updating each one's position and velocity at every step. The method handles free surfaces naturally but becomes irregular and expensive as particles wander.

The **Eulerian** approach fixes a grid in space and records what is happening at each grid point — how fast is the fluid moving here, right now? The fluid flows through the grid rather than being represented by it. Data stays organized in regular arrays, cache-friendly and straightforward to index.

This chapter implements an Eulerian simulator: 2D, incompressible, and inviscid. The 3D extension follows the same logic with an additional grid dimension.

---

## The Governing Equations

The physics of an incompressible, inviscid fluid:

**Momentum equation** (Newton's second law for a fluid parcel):

$$\frac{\partial \mathbf{v}}{\partial t} + (\mathbf{v} \cdot \nabla)\mathbf{v} = -\frac{1}{\rho}\nabla p + \mathbf{g}$$

**Incompressibility constraint** (fluid neither created nor destroyed):

$$\nabla \cdot \mathbf{v} = 0$$

The incompressibility constraint says the **divergence** of the velocity field must be zero everywhere. Divergence measures net outflow: if more fluid is leaving a small volume than entering it, the constraint is violated.

The simulator enforces these equations through three sequential steps each frame: apply external forces, project the velocity field to make it divergence-free, and advect the field forward in time.

---

## The Staggered MAC Grid

A naive approach storing all velocity components at cell centers leads to a well-known numerical instability: pressure and velocity equations decouple in a checkerboard pattern, producing unphysical oscillations.

The fix is the **MAC grid** (Marker-And-Cell), also called a staggered grid:

- Horizontal velocity **u** is stored at the center of **vertical** cell faces (left and right edges).
- Vertical velocity **v** is stored at the center of **horizontal** cell faces (top and bottom edges).
- Scalar quantities (pressure **p**, smoke density **m**) are stored at cell centers.

```
    v[i,j+1]
       |
u[i,j]--[p,m]--u[i+1,j]
       |
    v[i,j]
```

This gives a direct physical reading: `u[i+1,j] - u[i,j]` is the net horizontal outflow from cell (i,j), and `v[i,j+1] - v[i,j]` is the net vertical outflow. The divergence is simply their sum, computed with no averaging required.

In ink, the grid is stored as flat arrays indexed by `i*numY + j`:

```k
/ Eulerian fluid grid state
/ Grid is numX × numY cells; flat index: i*numY + j
/ u[idx]: horizontal velocity at left face of cell idx
/ v[idx]: vertical velocity at bottom face of cell idx
/ p[idx]: pressure at cell center
/ s[idx]: 0=solid, 1=fluid (obstacle flag)
/ m[idx]: smoke density at cell center
mkFluid: {[rho;nx;ny;h]
  nCells: nx*ny
  u: nCells#0.
  v: nCells#0.
  p: nCells#0.
  s: nCells#1.      / start all as fluid
  m: nCells#1.      / start with smoke everywhere
  (rho; nx; ny; h; nCells; u; v; p; s; m)
}

/ Accessor for flat 2D index
idx: {[nx;ny;i;j] i*ny + j}
```

---

## The Simulation Loop

Each frame runs three steps in order:

```
1. integrate   — apply gravity to v components
2. project     — enforce incompressibility (pressure solve)
3. advect      — move the velocity and smoke fields
```

### Step 1: External Forces (Gravity)

For every interior fluid cell, add gravity × dt to the vertical velocity component. Skip faces adjacent to solid cells:

```k
/ Apply gravity to vertical velocity components
/ f: fluid grid tuple; grav: gravity scalar (negative for downward)
fluidGravity: {[f;dt;grav]
  rho:f@0; nx:f@1; ny:f@2; h:f@3; nC:f@4; u:f@5; v:f@6; p:f@7; s:f@8; m:f@9
  v2: v
  {[i]
    {[j]
      $[(s@(i*ny+j))=1. & (s@(i*ny+j-1))=1.;
        v2:: @[v2; i*ny+j; +; grav*dt];
        0]
    }' 1+!ny-2
  }' 1+!nx-1
  @[f; 6; :; v2]
}
```

### Step 2: Projection (Enforcing Incompressibility)

This is the mathematical core. After gravity, the velocity field has nonzero divergence. The projection step corrects each cell's adjacent face velocities to drive divergence to zero.

For cell (i, j) the divergence is:

$$d = u_{i+1,j} - u_{i,j} + v_{i,j+1} - v_{i,j}$$

To zero it out, push the four surrounding face velocities outward, weighted by the solid flags of neighboring cells:

$$u_{i,j} \mathrel{-}= \frac{d \cdot s_{i-1,j}}{s_\text{total}}, \quad u_{i+1,j} \mathrel{+}= \frac{d \cdot s_{i+1,j}}{s_\text{total}}, \quad \text{etc.}$$

Applying this to every cell in one pass does not fully enforce incompressibility — correcting one cell disturbs its neighbors. The fix is to iterate: **Gauss-Seidel iteration** runs through all cells in order, updating immediately so each correction benefits subsequent cells. Repeating 40–100 times gives a satisfactory result.

**Overrelaxation** (SOR with ω ≈ 1.9) makes the iteration converge dramatically faster — the same quality in a fraction of the iterations.

```k
/ Pressure projection (Gauss-Seidel with overrelaxation)
/ f: fluid grid; numIters: projection iterations (40-100); omega: overrelaxation (1.9)
gFluidU: 0; gFluidV: 0; gFluidP: 0
fluidProject: {[f;numIters;dt;omega]
  rho:f@0; nx:f@1; ny:f@2; h:f@3; nC:f@4
  u:f@5; v:f@6; p:f@7; s:f@8; m:f@9
  cp: rho*h%dt
  gFluidU:: u; gFluidV:: v; gFluidP:: p
  {[iter]
    {[i]
      {[j]
        ii: i*ny+j
        $[(s@ii)=0.; 0;
          [sx0: s@((i-1)*ny+j)
           sx1: s@((i+1)*ny+j)
           sy0: s@(i*ny+j-1)
           sy1: s@(i*ny+j+1)
           st: sx0+sx1+sy0+sy1
           $[st=0.; 0;
             [div: ((gFluidU@((i+1)*ny+j)) - (gFluidU@(i*ny+j))) + ((gFluidV@(i*ny+j+1)) - (gFluidV@(i*ny+j)))
              pp: omega * neg div % st
              gFluidP:: @[gFluidP; ii; +; cp*pp]
              gFluidU:: @[@[gFluidU; i*ny+j; -; sx0*pp]; (i+1)*ny+j; +; sx1*pp]
              gFluidV:: @[@[gFluidV; i*ny+j; -; sy0*pp]; i*ny+j+1; +; sy1*pp]]]]]
      }' 1+!ny-2
    }' 1+!nx-2
  }' !numIters
  @[@[@[@[f;5;:;gFluidU];6;:;gFluidV];7;:;gFluidP]]
}
```

### Step 3: Semi-Lagrangian Advection

The velocity field must now be moved forward in time. **Forward advection** — moving values in the direction of flow — is numerically unstable. The standard solution is **semi-Lagrangian advection**, which traces characteristics backward in time.

The idea: to find the new velocity at a grid face, trace the fluid parcel backward from that face's position **x** along the velocity field for time Δt:

$$\mathbf{x}_\text{prev} = \mathbf{x} - \Delta t \cdot \mathbf{v}(\mathbf{x})$$

Then sample the velocity field at **x**_prev using bilinear interpolation. Because the backward trace always lands inside the existing grid, the method is unconditionally stable regardless of time-step size.

```k
/ Bilinear sample of field f at world position (x,y) on grid with spacing h
/ field: flat float list; nx,ny: grid dims; dx,dy: stagger offsets (0. or 0.5*h)
bilinSample: {[field;nx;ny;h;dx;dy;x;y]
  x1: (x-dx)%h; y1: (y-dy)%h
  x0: _x1 & nx-1; y0: _y1 & ny-1
  tx: x1-x0; ty: y1-y0
  x1c: x0+1 & nx-1; y1c: y0+1 & ny-1
  w0: (1.-tx)*(1.-ty); w1: tx*(1.-ty); w2: tx*ty; w3: (1.-tx)*ty
  ((w0*field@(x0*ny+y0)) + (w1*field@(x1c*ny+y0))) + ((w2*field@(x1c*ny+y1c)) + w3*field@(x0*ny+y1c))
}

/ Advect velocity field (semi-Lagrangian, writes to new arrays)
fluidAdvectVel: {[f;dt]
  rho:f@0; nx:f@1; ny:f@2; h:f@3; nC:f@4; u:f@5; v:f@6; p:f@7; s:f@8; m:f@9
  h2: 0.5*h
  newU: u
  newV: v
  / Advect u component (lives at left face: x=i*h, y=j*h+0.5h)
  {[i]
    {[j]
      ii: i*ny+j
      $[(s@ii)=1. & (s@((i-1)*ny+j))=1. & j<ny-1;
        [ux: u@ii
         / Interpolate v at u-face location (average of 4 surrounding v values)
         vx: 0.25 * (((v@((i-1)*ny+j)) + (v@ii)) + ((v@((i-1)*ny+j+1)) + v@(i*ny+j+1)))
         x2: i*h - dt*ux; y2: j*h+h2 - dt*vx
         x2: x2&(nx-1)*h | h; y2: y2&(ny-2)*h+h2 | h2
         newU:: @[newU; ii; :; bilinSample[u;nx;ny;h;0.;h2;x2;y2]]];
        0]
    }' 1+!ny-2
  }' 1+!nx-1
  / Advect v component (lives at bottom face: x=i*h+0.5h, y=j*h)
  {[i]
    {[j]
      ii: i*ny+j
      $[(s@ii)=1. & (s@(i*ny+j-1))=1. & i<nx-1;
        [ux: 0.25 * (((u@(i*ny+j)) + (u@((i+1)*ny+j))) + ((u@(i*ny+j-1)) + u@((i+1)*ny+j-1)))
         vx: v@ii
         x2: i*h+h2 - dt*ux; y2: j*h - dt*vx
         x2: x2&(nx-2)*h+h2 | h2; y2: y2&(ny-1)*h | h
         newV:: @[newV; ii; :; bilinSample[v;nx;ny;h;h2;0.;x2;y2]]];
        0]
    }' 1+!ny-1
  }' 1+!nx-2
  @[@[f;5;:;newU];6;:;newV]
}

/ Advect smoke scalar field (lives at cell centers)
fluidAdvectSmoke: {[f;dt]
  rho:f@0; nx:f@1; ny:f@2; h:f@3; nC:f@4; u:f@5; v:f@6; p:f@7; s:f@8; m:f@9
  h2: 0.5*h
  newM: m
  {[i]
    {[j]
      ii: i*ny+j
      $[(s@ii)=1.;
        [ux: ((u@(i*ny+j)) + u@((i+1)*ny+j)) * 0.5
         vx: ((v@(i*ny+j)) + v@(i*ny+j+1)) * 0.5
         x2: i*h+h2 - dt*ux; y2: j*h+h2 - dt*vx
         x2: x2&(nx-2)*h+h2 | h2; y2: y2&(ny-2)*h+h2 | h2
         newM:: @[newM; ii; :; bilinSample[m;nx;ny;h;h2;h2;x2;y2]]];
        0]
    }' 1+!ny-2
  }' 1+!nx-2
  @[f;9;:;newM]
}
```

---

## Boundary Conditions and Obstacles

**Wall cells** are handled by the obstacle flag `s`. Setting `s@(i*ny+j) = 0` marks a solid cell; the projection step automatically excludes its faces because the neighboring-s terms evaluate to zero. No special code is needed — the obstacle handling falls out of the general formula.

**Border extrapolation**: copy values of adjacent interior cells to the border to approximate a free-slip condition at the domain boundary.

```k
/ Extrapolate velocities to border cells (free-slip condition)
fluidExtrapolate: {[f]
  rho:f@0; nx:f@1; ny:f@2; h:f@3; nC:f@4; u:f@5; v:f@6
  / Copy first interior column to left border, last to right
  u2: {[j] @[@[u; j; :; u@ny+j]; (nx-1)*ny+j; :; u@(nx-2)*ny+j]}/ u, !ny
  / Copy first interior row to bottom border, last to top
  v2: {[i] @[@[v; i*ny; :; v@(i*ny+1)]; i*ny+ny-1; :; v@(i*ny+ny-2)]}/ v, !nx
  @[@[f;5;:;u2];6;:;v2]
}
```

---

## The Full Simulation Step

```k
/ One simulation step: gravity → project → extrapolate → advect
fluidStep: {[f;dt;grav;numIters;omega]
  f2: fluidGravity[f;dt;grav]
  f3: @[f2;7;:;(f2@4)#0.]   / reset pressure
  f4: fluidProject[f3;numIters;dt;omega]
  f5: fluidExtrapolate[f4]
  f6: fluidAdvectVel[f5;dt]
  fluidAdvectSmoke[f6;dt]
}
```

Typical parameters for an interactive wind-tunnel simulation at 100×50 cells: Δt = 1/60 s, 40 projection iterations, ω = 1.9.

---

## Benchmark

```k
/ Setup 100x50 grid
nx: 102; ny: 52    / +2 for border cells
h: 1.%50           / cell size
f: mkFluid[1000.;nx;ny;h]

/ Set left column velocity (wind tunnel inlet)
f: @[f;5; :; {[j] $[j=26; 2.; f@5@j]}' !nx*ny]

/ Benchmark one step
\t fluidStep[f; 1.%60; 0.; 40; 1.9]   / → ~5ms for 100x50 grid
```

---

## Key Takeaways

- **Eulerian simulation** stores fluid state on a fixed grid. Data stays in regular arrays, making it cache-friendly and easy to implement.
- The **staggered MAC grid** places velocity components on cell faces rather than centers. This eliminates the pressure–velocity decoupling instability and makes the divergence formula exact and cheap to compute.
- **Projection** drives the velocity field to be divergence-free by iteratively correcting face velocities using the local divergence. **Gauss-Seidel with overrelaxation** (ω ≈ 1.9) dramatically accelerates convergence.
- **Semi-Lagrangian advection** traces characteristics backward in time, sampling the existing field at the departure point. It is unconditionally stable with bilinear interpolation.
- **Obstacle handling** requires only a single `s` flag per cell. The projection step handles no-penetration automatically.
- A passive **smoke density** can be advected alongside the velocity field to produce rich visualizations at no additional simulation cost.
- The complete simulator — forces, projection, advection — fits in roughly 200 lines of code and runs in real time at moderate grid resolutions.
