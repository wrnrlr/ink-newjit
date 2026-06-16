# Chapter 18 — FLIP Water: Hybrid Particle-Grid Simulation

The Eulerian fluid simulator from Chapter 17 is elegant and fast, but it has a subtle problem when simulating water with a free surface: the water loses energy. Turbulent jets smooth themselves into laminar flows, splashes die away before they form, and the motion looks more like thick syrup than water. The cause is **numerical diffusion** — an artifact of the grid-based velocity representation, not of the physics. This chapter introduces the FLIP method (Fluid Implicit Particle), a hybrid scheme that cures numerical diffusion by letting particles carry velocity while the grid handles the pressure solve.

---

## From Two Phases to Three

The pure Eulerian method fills the entire domain with fluid. Extending it to water and air requires distinguishing three types of grid cell: **fluid** (water), **air**, and **solid**. Water density is roughly 1000× that of air, so we treat air as a vacuum — no momentum, no coupling — and simply skip air cells in the pressure solver.

The remaining question: how to know which cells contain water? The answer is what makes FLIP distinctive: we track **particles**. Any cell containing at least one particle is marked FLUID; all others are AIR. Water surface emerges implicitly from where the particles are.

---

## What PIC Gets Right — and What It Gets Wrong

The Particle-In-Cell (PIC) method establishes the basic structure. Each particle carries a position and a velocity. The simulation advances in four steps:

1. Integrate particles forward under gravity.
2. Transfer particle velocities onto the grid.
3. Make the grid velocity field incompressible (pressure projection).
4. Transfer corrected grid velocities back to the particles.

The problem is step 4. When velocities are transferred from grid to particles via bilinear interpolation, each particle's new velocity is a weighted average over four neighboring grid corners. Averaging is irreversible: fine-scale particle motion disappears permanently. After a handful of steps, the characteristic jets and turbulence of real water are gone.

---

## The FLIP Idea

FLIP fixes numerical viscosity with one conceptual shift: instead of replacing particle velocities with the post-projection grid velocities, **add only the change** in grid velocity to each particle:

$$\mathbf{v}_p \leftarrow \mathbf{v}_p + \left(\mathbf{u}^{\text{new}} - \mathbf{u}^{\text{old}}\right)\bigg|_{\mathbf{x}_p}$$

The absolute value is no longer averaged away — only the correction made by the pressure solver is interpolated and applied. All fine-scale velocity variation that the grid cannot represent remains untouched on the particles.

The cost of this fidelity is noise. In practice, blend the two approaches:

$$\mathbf{v}_p^{\text{final}} = (1 - \alpha)\,\mathbf{v}_p^{\text{PIC}} + \alpha\,\mathbf{v}_p^{\text{FLIP}}$$

A value of α = 0.9 (90% FLIP, 10% PIC) gives water that is lively without being noticeably noisy.

---

## The Simulation Loop

The full per-frame loop:

1. Integrate particles: apply gravity, advance positions.
2. Push particles apart to prevent clumping.
3. Handle particle collisions with walls and obstacles.
4. Transfer particle velocities to the grid (particles → grid).
5. Mark fluid cells (any cell containing a particle).
6. Solve for incompressibility (pressure projection).
7. Transfer corrected velocities back to particles (grid → particles), applying PIC/FLIP blend.

---

## Data Layout

```k
/ FLIP water state:
/ pPos: flat float list [x0 y0 x1 y1 ...] — 2D particle positions
/ pVel: flat float list [vx0 vy0 vx1 vy1 ...] — 2D particle velocities
/ Grid arrays (same as Chapter 17 MAC grid):
/ u, v: velocity components on staggered faces
/ prevU, prevV: saved velocity before projection
/ cellType: flat int list — 0=solid, 1=fluid, 2=air
/ s: flat float — same as cellType but 0/1 for solid boundaries
mkFlip: {[nx;ny;h;rho]
  nC: nx*ny
  (nx; ny; h; rho; nC;
   nC#0.; nC#0.; nC#0.; nC#0.;  / u, v, prevU, prevV
   nC#2; nC#1.)                  / cellType (all air), s (all fluid)
}
```

---

## Particle Integration

```k
/ Integrate particles: gravity + advance positions
/ pPos, pVel: flat float lists (2 floats per particle)
integrateParticles: {[pPos;pVel;n;dt;grav]
  pVel2: {[i]
    (pVel@(2*i); (pVel@(2*i+1)) + grav*dt)  / x-vel unchanged, y-vel += gravity
  }' !n
  pPos2: {[i]
    ((pPos@(2*i)) + (pVel2@i)@0 * dt;
     (pPos@(2*i+1)) + (pVel2@i)@1 * dt)
  }' !n
  (,/ pPos2; ,/ pVel2)
}
```

---

## Particle-to-Grid Transfer

Scatter particle velocities onto the MAC grid using bilinear weights. Each particle at position $(x_p, y_p)$ contributes to the four surrounding face nodes proportional to its bilinear weight:

```k
/ Transfer particle velocities to MAC grid (scatter step)
/ Returns updated u, v, and cellType arrays
p2Grid: {[pPos;pVel;n;nx;ny;h;s]
  fu: (nx*ny)#0.; du: (nx*ny)#0.   / velocity accumulator + weight accumulator
  fv: (nx*ny)#0.; dv: (nx*ny)#0.
  cellType: (nx*ny)#2               / start all AIR

  {[pi]
    xp: pPos@(2*pi); yp: pPos@(2*pi+1)
    vxp: pVel@(2*pi); vyp: pVel@(2*pi+1)

    / Scatter u-component (left faces: stagger x by 0, y by 0.5h)
    x1: xp%h; y1: (yp - 0.5*h)%h
    i0: _x1; j0: _y1
    tx: x1-i0; ty: y1-j0
    i1: i0+1&nx-1; j1: j0+1&ny-1
    w0:(1.-tx)*(1.-ty); w1:tx*(1.-ty); w2:tx*ty; w3:(1.-tx)*ty
    fu:: @[@[@[@[fu;i0*ny+j0;+;w0*vxp];i1*ny+j0;+;w1*vxp];i1*ny+j1;+;w2*vxp];i0*ny+j1;+;w3*vxp]
    du:: @[@[@[@[du;i0*ny+j0;+;w0];i1*ny+j0;+;w1];i1*ny+j1;+;w2];i0*ny+j1;+;w3]

    / Scatter v-component (bottom faces: stagger x by 0.5h, y by 0)
    x2: (xp - 0.5*h)%h; y2: yp%h
    i2: _x2; j2: _y2
    tx2: x2-i2; ty2: y2-j2
    i3: i2+1&nx-1; j3: j2+1&ny-1
    w4:(1.-tx2)*(1.-ty2); w5:tx2*(1.-ty2); w6:tx2*ty2; w7:(1.-tx2)*ty2
    fv:: @[@[@[@[fv;i2*ny+j2;+;w4*vyp];i3*ny+j2;+;w5*vyp];i3*ny+j3;+;w6*vyp];i2*ny+j3;+;w7*vyp]
    dv:: @[@[@[@[dv;i2*ny+j2;+;w4];i3*ny+j2;+;w5];i3*ny+j3;+;w6];i2*ny+j3;+;w7]

    / Mark cell as fluid
    ci: (_xp%h)*ny + _yp%h
    cellType:: @[cellType; ci; :; 1]
  }' !n

  / Normalize by weight (avoid divide by zero for empty nodes)
  u2: {[i] $[du@i>0.; fu@i % du@i; 0.]}' !nx*ny
  v2: {[i] $[dv@i>0.; fv@i % dv@i; 0.]}' !nx*ny
  (u2; v2; cellType)
}
```

---

## Grid-to-Particle Transfer with PIC/FLIP Blending

Save the grid velocity before projection, then after projection blend the absolute value (PIC) with the delta (FLIP):

```k
/ Transfer grid velocities back to particles (PIC/FLIP blend)
/ flipRatio: 0.9 = mostly FLIP (low diffusion); 0.0 = pure PIC (high diffusion)
grid2Particles: {[pPos;pVel;n;u;v;prevU;prevV;nx;ny;h;flipRatio]
  {[pi]
    xp: pPos@(2*pi); yp: pPos@(2*pi+1)
    / PIC: sample new grid velocity at particle position
    picVx: bilinSample[u;nx;ny;h;0.;0.5*h;xp;yp]
    picVy: bilinSample[v;nx;ny;h;0.5*h;0.;xp;yp]
    / FLIP: add grid delta to particle velocity
    dVx: picVx - bilinSample[prevU;nx;ny;h;0.;0.5*h;xp;yp]
    dVy: picVy - bilinSample[prevV;nx;ny;h;0.5*h;0.;xp;yp]
    flipVx: (pVel@(2*pi)) + dVx
    flipVy: (pVel@(2*pi+1)) + dVy
    / Blend
    vx: ((1.-flipRatio)*picVx) + flipRatio*flipVx
    vy: ((1.-flipRatio)*picVy) + flipRatio*flipVy
    (vx; vy)
  }' !n
}
```

---

## Pressure Projection for Water

The projection step is identical to Chapter 17, with one modification: skip AIR cells. Only cells typed as FLUID participate:

```k
/ Project: enforce incompressibility for fluid cells only
/ cellType: 0=solid, 1=fluid, 2=air — only fluid cells get pressure correction
flipProject: {[u;v;p;s;cellType;nx;ny;h;rho;dt;numIters;omega]
  cp: rho*h%dt
  gFluidU:: u; gFluidV:: v; gFluidP:: p
  {[iter]
    {[i]
      {[j]
        ii: i*ny+j
        $[(cellType@ii)=1;    / only fluid cells
          [sx0:s@((i-1)*ny+j); sx1:s@((i+1)*ny+j)
           sy0:s@(i*ny+j-1); sy1:s@(i*ny+j+1)
           / For air neighbors: treat as free surface (s=1 for projection)
           ax0: $[(cellType@((i-1)*ny+j))=2; 1.; sx0]
           ax1: $[(cellType@((i+1)*ny+j))=2; 1.; sx1]
           ay0: $[(cellType@(i*ny+j-1))=2; 1.; sy0]
           ay1: $[(cellType@(i*ny+j+1))=2; 1.; sy1]
           st: ax0+ax1+ay0+ay1
           $[st=0.; 0;
             [div: ((gFluidU@((i+1)*ny+j)) - (gFluidU@(i*ny+j))) + ((gFluidV@(i*ny+j+1)) - (gFluidV@(i*ny+j)))
              pp: omega * neg div % st
              gFluidP:: @[gFluidP; ii; +; cp*pp]
              gFluidU:: @[@[gFluidU; i*ny+j; -; ax0*pp]; (i+1)*ny+j; +; ax1*pp]
              gFluidV:: @[@[gFluidV; i*ny+j; -; ay0*pp]; i*ny+j+1; +; ay1*pp]]]]
        ; 0]
      }' 1+!ny-2
    }' 1+!nx-2
  }' !numIters
  (gFluidU; gFluidV; gFluidP)
}
```

Air cells are treated as free-surface boundaries (pressure = 0), which is the key difference from the fully-filled Eulerian solver.

---

## Particle Separation

Particles drift and clump over time. Push them apart geometrically: use a spatial hash, find pairs closer than $2r$, and displace each by half the overlap:

```k
/ Separate overlapping particles
separateParticles: {[pPos;pVel;n;r;h;ts]
  buildHash[pPos;n;h;ts]
  pPos2: pPos
  {[pi]
    nbs: queryNeighbors[pPos;pi;2.*r;h;ts]
    {[pj]
      $[pj<=pi; 0;
        [dx: (pPos2@(2*pj)) - pPos2@(2*pi)
         dy: (pPos2@(2*pj+1)) - pPos2@(2*pi+1)
         d2: (dx*dx)+dy*dy
         $[d2<(2.*r*2.*r)&d2>0.;
           [d: sqrt d2; corr: 0.5*(2.*r-d)%d
            pPos2:: @[@[@[@[pPos2;2*pi;-;dx*corr];2*pi+1;-;dy*corr];2*pj;+;dx*corr];2*pj+1;+;dy*corr]];
           0]]]
    }' nbs
  }' !n
  pPos2
}
```

---

## The Full FLIP Step

```k
/ One FLIP frame
flipStep: {[state;dt;grav;numIters;omega;flipRatio;r]
  pPos:state@0; pVel:state@1; nx:state@2; ny:state@3; h:state@4; rho:state@5; s:state@6

  / 1. Integrate particles
  pv2: integrateParticles[pPos;pVel;#pPos div 2;dt;grav]
  pPos2: pv2@0; pVel2: pv2@1

  / 2. Separate particles
  pPos3: separateParticles[pPos2;pVel2;#pPos2 div 2;r;2.*r;2*#pPos2 div 2]

  / 3. Particles → grid
  g: p2Grid[pPos3;pVel2;#pPos3 div 2;nx;ny;h;s]
  u:g@0; v:g@1; cellType:g@2

  / 4. Save pre-projection velocities
  prevU: u; prevV: v

  / 5. Project
  p: (nx*ny)#0.
  pv3: flipProject[u;v;p;s;cellType;nx;ny;h;rho;dt;numIters;omega]
  u2:pv3@0; v2:pv3@1

  / 6. Grid → particles (PIC/FLIP blend)
  newPVel: grid2Particles[pPos3;pVel2;#pPos3 div 2;u2;v2;prevU;prevV;nx;ny;h;flipRatio]
  pVel3: ,/ newPVel

  (pPos3; pVel3; nx; ny; h; rho; s)
}
```

---

## Scene Setup: Dam Break

The classic test — a column of water filling the left portion of a tank:

```k
/ Initialize dam break scene
/ Particles arranged in hexagonal close-packing for ~15% higher density
initDamBreak: {[nx;ny;h;rho]
  r: 0.3*h
  dx: 2.*r; dy: (sqrt 3.)%2. * dx
  / Fill left half of tank, bottom 2/3
  pPos: ,/ ,/ {[row]
    ,/ {[col]
      x: h + r + dx*col + $[row mod 2=0; 0.; r]
      y: h + r + dy*row
      $[x<(nx%2)*h & y<(ny%0.67)*h; ,(x;y); ()]
    }' !_((nx%2)*h%dx)
  }' !_(ny%0.67*h%dy)

  pVelFlat: (#pPos * 2) # 0.
  pPosFlat: ,/ pPos
  s: (nx*ny)#1.
  / Set boundary solid
  s2: {[j] @[s; j; :; 0.]}/ s, !ny                     / left col
  s3: {[j] @[s2; (nx-1)*ny+j; :; 0.]}/ s2, !ny          / right col
  s4: {[i] @[s3; i*ny; :; 0.]}/ s3, 1+!nx-2            / bottom row

  (pPosFlat; pVelFlat; nx; ny; h; rho; s4)
}

/ Setup and run
state: initDamBreak[100; 50; 0.02; 1000.]
state2: flipStep[state; 1.%60; -9.81; 50; 1.9; 0.9; 0.3*0.02]
```

Hexagonal packing places approximately 15% more particles per unit area than a square grid, helping the rest density estimate remain stable early in the simulation.

---

## Key Takeaways

- **Numerical diffusion** in grid-based fluids arises because transferring velocities from grid to particles is a weighted average, which irreversibly smooths fine-scale motion.
- **PIC** defines the hybrid foundation: particles carry position and velocity; the grid provides the incompressibility constraint via pressure projection.
- **FLIP** eliminates most smoothing by transferring only the *change* in grid velocity to particles. The particle velocities accumulate high-frequency detail that the grid cannot represent.
- **PIC/FLIP blending** at α ≈ 0.9 (90% FLIP, 10% PIC) gives the best of both worlds: noise-damping from PIC, detail-preservation from FLIP.
- **Three-phase cell typing** (fluid, air, solid) is the key to free-surface simulation. Cells containing particles are fluid; all others are air and are skipped by the pressure solver. Air boundaries impose zero pressure (free surface), not zero velocity.
- **Particle separation** via spatial hash prevents clumping. Geometric separation and density-modified divergence together keep particles spread evenly.
- **Rest density** is measured from the initial particle distribution and used as the target density. Deviations drive corrective pressure.
