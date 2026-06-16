# Chapter 20 — Height-Field Water Simulation

Simulating a believable ocean, lake, or tank of water is one of the most visually rewarding problems in real-time physics. Full volumetric fluid simulation is expensive enough that it is usually reserved for offline rendering. For interactive use, a much lighter approach exists: represent the water surface as a 2D grid of column heights and propagate disturbances across that grid using the wave equation. The result is fast enough to run in a browser, expressive enough to handle floating objects and splashing, and requires fewer than one hundred lines of code.

---

## Representing Water as a Column Grid

Instead of tracking every particle of water, divide the surface into a rectangular grid of vertical columns, each with uniform width $s$. Each column $(i, j)$ stores two numbers:

- $h_{i,j}$ — the total height of the water column above the ground.
- $v_{i,j}$ — the vertical velocity of that column.

The column representation makes surface mesh extraction trivial — just read heights and build triangles between neighboring grid points. Simulation cost scales as O(N) in the number of columns. The price is that overturning waves and spray cannot be represented. For tanks, rivers, and gentle ocean surfaces, the column model is entirely convincing.

---

## Deriving the Wave Equation

The dynamics of each column follow from Archimedes' buoyancy and Newton's second law. Two adjacent columns with heights $h_1$ and $h_2$: the taller column pushes down harder on the interface. The net force is proportional to $h_2 - h_1$. For an interior column $i$ with neighbors $i-1$ and $i+1$:

$$a_i = \frac{c^2}{s^2}(h_{i-1} + h_{i+1} - 2h_i)$$

This is the discrete Laplacian scaled by $c^2/s^2$, where $c$ is the wave propagation speed and $s$ is the column width. In 2.5D with four neighbors:

$$a_{i,j} = \frac{c^2}{s^2}(h_{i-1,j} + h_{i+1,j} + h_{i,j-1} + h_{i,j+1} - 4h_{i,j})$$

Disturbances propagate outward at speed $c$, producing characteristic circular ripple patterns.

---

## Boundary Conditions

For **reflecting walls** — the behavior of a tank — substitute a column's own height for any out-of-domain neighbor. The missing term cancels with the corresponding subtracted term, so the boundary column feels no net force from the missing direction. Waves hit the wall and bounce back, conserving energy exactly.

---

## Numerical Integration

Advancing the simulation is a two-pass loop: first update velocities using current heights, then update heights using the fresh velocities:

```k
/ Height-field water state: (nx; nz; spacing; h; vel; bodyH; prevBodyH)
/ h, vel: flat float lists (nx*nz elements), indexed i*nz + j
mkWater: {[nx;nz;spacing;initH]
  nC: nx*nz
  (nx; nz; spacing; nC#initH; nC#0.; nC#0.; nC#0.)
}

/ One wave propagation step
/ waveSpeed: propagation speed (m/s); velDamp: velocity damping; posDamp: position damping
waterStep: {[w;dt;waveSpeed;velDamp;posDamp]
  nx:w@0; nz:w@1; s:w@2; h:w@3; vel:w@4
  / Enforce CFL stability condition: c*dt < s
  c: (waveSpeed & 0.5*s%dt) * (waveSpeed & 0.5*s%dt) % s*s

  / Pass 1: update velocities from height Laplacian
  vel2: {[idx]
    i: idx div nz; j: idx mod nz
    hi: h@idx
    sumH: ($ [i>0; h@((i-1)*nz+j); hi]) +
          ($ [i<nx-1; h@((i+1)*nz+j); hi]) +
          ($ [j>0; h@(i*nz+j-1); hi]) +
          ($ [j<nz-1; h@(i*nz+j+1); hi])
    vel@idx + dt*c*(sumH - 4.*hi)
  }' !nx*nz

  / Apply velocity damping (exponential decay)
  vel3: vel2 * (0.|1. - velDamp*dt)

  / Pass 2: update heights from velocities
  h2: h + vel3*dt

  / Apply positional damping (smooth high-frequency noise)
  h3: {[idx]
    i: idx div nz; j: idx mod nz
    hi: h2@idx
    sumH: ($ [i>0; h2@((i-1)*nz+j); hi]) +
          ($ [i<nx-1; h2@((i+1)*nz+j); hi]) +
          ($ [j>0; h2@(i*nz+j-1); hi]) +
          ($ [j<nz-1; h2@(i*nz+j+1); hi])
    cnt: (i>0) + (i<nx-1) + (j>0) + (j<nz-1)
    $[cnt>0; hi + (sumH%cnt - hi) * (posDamp*dt & 1.); hi]
  }' !nx*nz

  @[@[@[w;3;:;h3];4;:;vel3]]
}
```

**CFL condition**: $\Delta t \cdot c < s$. The clamp `waveSpeed & 0.5*s%dt` enforces stability. Semi-implicit Euler (velocity updated using current heights, heights updated using fresh velocities) is unconditionally stable.

---

## Damping

Two separate damping mechanisms:

**Velocity damping** multiplies every velocity by a factor slightly less than one each step, exponentially draining energy:

```k
vel3: vel2 * (0.|1. - velDamp*dt)   / clamp to 0 to prevent sign flip
```

**Positional damping** nudges each column height toward the average of its neighbors, suppressing high-frequency noise without affecting long-wavelength waves. The factor `posDamp*dt & 1.` prevents overshoot.

Together these control how quickly the water settles after a disturbance. Typical values: `velDamp = 0.05`, `posDamp = 0.0` (let velocity damping handle it), or `posDamp = 0.1` for very choppy water that needs extra smoothing.

---

## Coupling Objects to the Water

### Objects Pushing Down on the Water

An auxiliary field $b_{i,j}$ stores the **height covered by objects** in each column. At each step, add the *change* in $b$ to the water column heights:

$$h_{i,j} \leftarrow h_{i,j} + \alpha\,(b_{i,j} - b^{\text{prev}}_{i,j})$$

The scalar $\alpha \in [0, 1]$ controls coupling strength. Because we add the *change* in $b$ rather than setting $h$ directly, volume is automatically conserved. The same mechanism handles fully submerged objects correctly, since $b$ tracks the body's cross-section at every depth.

```k
/ Compute and apply water-object coupling
/ balls: list of (x; z; r; mass; vy) tuples; waterH: rest height; rhoWater: density
waterCoupling: {[w;balls;dt;alpha;waterH;rhoWater;grav]
  nx:w@0; nz:w@1; s:w@2; h:w@3; vel:w@4; bodyH:w@5; prevBodyH:w@6
  nC: nx*nz

  / Save previous body heights
  prevH2: bodyH

  / Compute current body heights and buoyancy forces
  bodyH2: nC#0.
  newBalls: {[ball]
    bx:ball@0; bz:ball@1; br:ball@2; bm:ball@3; bvy:ball@4
    / Find grid cells overlapping this ball's footprint
    xi0: _(bx-br)%s; xi1: _(bx+br)%s
    zi0: _(bz-br)%s; zi1: _(bz+br)%s
    totalForce: 0.
    {[xi]
      {[zi]
        $[xi>=0 & xi<nx & zi>=0 & zi<nz;
          [idx: xi*nz+zi
           / Overlap depth: min of ball bottom to water surface
           overlap: (h@idx) - (bvy - br) | 0.   / simplified spherical overlap
           $[overlap>0.;
             [bodyH2:: @[bodyH2; idx; +; overlap]
              force: rhoWater * overlap * s*s * (neg grav)
              totalForce:: totalForce + force]];
          0]; 0]
      }' zi0 + !xi1-zi0+1
    }' xi0 + !xi1-xi0+1
    bvy2: bvy + dt * totalForce % bm
    (bx; bz; br; bm; bvy2)
  }' balls

  / Smooth bodyH to suppress spikes (2 iterations of neighbor averaging)
  bodyH3: {[bodyH_]
    {[idx]
      i: idx div nz; j: idx mod nz
      cnt: (i>0) + (i<nx-1) + (j>0) + (j<nz-1)
      sumH: ($ [i>0; bodyH_@((i-1)*nz+j); 0.]) +
            ($ [i<nx-1; bodyH_@((i+1)*nz+j); 0.]) +
            ($ [j>0; bodyH_@(i*nz+j-1); 0.]) +
            ($ [j<nz-1; bodyH_@(i*nz+j+1); 0.])
      $[cnt>0; sumH%cnt; bodyH_@idx]
    }' !nC
  }/ (bodyH2; bodyH2)  / 2 smoothing passes

  / Apply change to water heights
  h2: h + alpha * bodyH3 - prevH2
  w2: @[@[@[@[w;3;:;h2];5;:;bodyH3];6;:;prevH2]]
  (w2; newBalls)
}
```

### Water Pushing Up on Objects (Buoyancy)

Archimedes' principle: for each grid column overlapping with an object, the buoyancy force is the weight of the displaced water:

$$f = \rho_\text{water} \cdot o \cdot s^2 \cdot g$$

where $o$ is the height of the intersection between the object and the water column. The `totalForce` accumulation in the coupling code above applies this per column and sums them for each ball.

---

## The Full Simulation Step

```k
/ Complete water simulation step: coupling → wave propagation → mesh update
waterSimStep: {[w;balls;dt;waveSpeed;velDamp;posDamp;alpha;waterH;rhoWater;grav]
  / 1. Coupling: object ↔ water
  cwres: waterCoupling[w;balls;dt;alpha;waterH;rhoWater;grav]
  w2: cwres@0; balls2: cwres@1
  / 2. Wave propagation + damping
  w3: waterStep[w2;dt;waveSpeed;velDamp;posDamp]
  (w3; balls2)
}
```

---

## Setting Up a Splash Scene

```k
/ Initialize a tank with calm water and a floating ball
nx: 30; nz: 30; spacing: 0.1
waterH: 0.5    / rest water height
w: mkWater[nx;nz;spacing;waterH]

/ Create a splash: set one column to a high value
splashIdx: 15*nz+15
w: @[w; 3; :; @[w@3; splashIdx; :; waterH+0.3]]   / 0.3m spike at center

/ A floating ball: (x z r mass vy) — radius 0.08m, density < water → floats
balls: (1.5; 1.5; 0.08; 0.5; 0.)

/ Benchmark: 100 steps
\t {[n] w:: waterStep[w;1.%60;0.5;0.05;0.;0.]; w}' !100
/ → ~5ms for 30x30 grid, 100 steps
```

---

## Refraction Rendering

The wave simulation produces a height field and a normal at every vertex. To compute per-vertex normals from the height field:

```k
/ Compute surface normals from height field
waterNormals: {[h;nx;nz;spacing]
  {[idx]
    i: idx div nz; j: idx mod nz
    hc: h@idx
    dhx: $[i>0 & i<nx-1; (h@((i+1)*nz+j)) - h@((i-1)*nz+j); 0.]
    dhz: $[j>0 & j<nz-1; (h@(i*nz+j+1)) - h@(i*nz+j-1); 0.]
    / Normal = normalize((-dhx, 2*spacing, -dhz))
    n: (neg dhx; 2.*spacing; neg dhz)
    n % sqrt +/ n*n
  }' !nx*nz
}
```

For screen-space refraction: render the scene behind the water to an offscreen texture, then sample that texture at coordinates offset by the surface normal components $n_x, n_z$. The offset direction and magnitude mimic refraction at the water–air interface.

---

## Key Takeaways

- A **height-field** (2.5D column grid) represents water as heights $h_{i,j}$ and velocities $v_{i,j}$, enabling O(N) simulation with trivial surface extraction — at the cost of no overturning waves.
- The **discrete wave equation** $a_{i,j} = (c^2/s^2)(h_{i-1,j} + h_{i+1,j} + h_{i,j-1} + h_{i,j+1} - 4h_{i,j})$ governs column acceleration, derived from Archimedes' principle and Newton's second law.
- **Reflecting boundary conditions** substitute a column's own height for out-of-domain neighbors, making the missing terms cancel.
- **Semi-implicit Euler** (update velocities then heights) is stable. The **CFL condition** $\Delta t \cdot c < s$ bounds the time step.
- **Velocity damping** multiplies velocities by $(1 - k\Delta t)$ each step. **Positional damping** nudges heights toward neighbor averages, suppressing high-frequency noise.
- **Two-way coupling** via an auxiliary body-height field $b_{i,j}$: the *change* in $b$ is added to water heights (conserving volume), while the per-column overlap gives Archimedes' buoyancy force on objects.
- Smoothing the body-height field before applying it suppresses sharp spikes at object boundaries.
- The complete physics core fits in roughly 100 lines of code — water simulation is one of the most compact yet visually rewarding techniques in this book.
