# Chapter 21 — Simulating Fire

Few phenomena in real-time graphics are as immediately recognizable — and as difficult to fake convincingly — as fire. Flame flickers, rises, swirls, dims to glowing embers, and fades to smoke. This chapter builds a fire simulator directly on top of the Eulerian fluid simulator from Chapter 17. The key insight is that fire is simply a gas with a temperature field attached: that one extra scalar quantity, combined with buoyancy forces and injected turbulence, is sufficient to produce convincing flames.

---

## From Fluid to Fire

The Eulerian fluid method represents a gas as a velocity field on a regular grid. Each simulation step has three phases: modify the velocity field (external forces), enforce incompressibility (projection), and advect field quantities along with the flow.

For a fire simulator, the modification step changes: instead of downward gravity, hot gas rises. And instead of a passive smoke-density scalar, we track a temperature field $T$. Everything else — the staggered grid, the pressure-projection solver, the semi-Lagrangian advection — carries over unchanged from Chapter 17.

The full per-frame loop:

```
1. Modify velocities  (buoyancy lift + swirl turbulence)
2. Make fluid incompressible  (projection)
3. Advect velocity and temperature fields
4. Update temperatures  (ignite sources, cool, smooth)
```

---

## The Temperature Field

Rather than maintaining separate fields for fuel, combustion products, and smoke density, collapse everything into a single normalized scalar $T \in [0, 1]$ encoding the combustion lifecycle:

| Range | Meaning |
|---|---|
| $T \in [0.5, 1.0]$ | Active flame (yellow to red) |
| $T \in [0.3, 0.5]$ | Glowing embers, dark red |
| $T \in [0.0, 0.3]$ | Smoke (dark gray to black) |

At every time step, fire source cells have their temperature reset to $T = 1$. All other cells cool:

$$T \leftarrow \max(T - r \cdot \Delta t,\; 0)$$

Flames cool quickly (rate 1.2/s) because the bright combustion phase is short-lived. Smoke cools more slowly (rate 0.3/s) because dispersed particles retain heat longer.

```k
/ Temperature cooling and source ignition
/ f: fluid grid tuple (from ch17); srcCells: list of source cell indices
/ fireRate: cooling rate in flame zone (e.g. 1.2); smokeRate: cooling rate in smoke zone (e.g. 0.3)
gFireT: 0   / global temperature field (required for lambda access)

updateTemp: {[f;dt;srcCells;fireRate;smokeRate]
  nx:f@1; ny:f@2; s:f@8
  t: gFireT
  / Cool all cells
  t2: {[idx]
    tc: t@idx
    rate: $[tc>0.5; fireRate; smokeRate]
    tc - rate*dt | 0.
  }' !nx*(f@2)
  / Reset source cells to T=1
  t3: {[idx] @[t2;idx;:;1.]}/ t2, srcCells
  gFireT:: t3
  f
}
```

---

## Advecting Temperature

Temperature is advected just like velocity — semi-Lagrangian backward trace from Chapter 17:

```k
/ Advect temperature field (same pattern as advectSmoke in ch17)
advectTemp: {[f;dt]
  nx:f@1; ny:f@2; h:f@3; nC:f@4; u:f@5; v:f@6; s:f@8
  h2: 0.5*h
  newT: gFireT
  {[i]
    {[j]
      ii: i*ny+j
      $[(s@ii)=1.;
        [ux: ((u@(i*ny+j)) + u@((i+1)*ny+j)) * 0.5
         vx: ((v@(i*ny+j)) + v@(i*ny+j+1)) * 0.5
         x2: i*h+h2 - dt*ux; y2: j*h+h2 - dt*vx
         x2: x2&(nx-2)*h+h2 | h2; y2: y2&(ny-2)*h+h2 | h2
         newT:: @[newT; ii; :; bilinSample[gFireT;nx;ny;h;h2;h2;x2;y2]]];
        0]
    }' 1+!ny-2
  }' 1+!nx-2
  gFireT:: newT
  f
}
```

---

## Buoyancy: Hot Air Rises

Hot gas is less dense than cold gas; the surrounding cooler air pushes it upward. Rather than modeling density differences explicitly, convert temperature directly into an upward velocity target:

$$v_{\text{target}} = v_{\text{lift}} \cdot T$$

The current vertical velocity is driven toward $v_{\text{target}}$ with a first-order rate $a$:

$$v \leftarrow v + a \cdot (v_{\text{target}} - v) \cdot \Delta t$$

```k
/ Apply buoyancy: hot cells rise
/ vLift: max lift velocity (e.g. 3.0 m/s); a: acceleration rate (e.g. 6.0 /s)
applyBuoyancy: {[f;dt;vLift;a]
  nx:f@1; ny:f@2; nC:f@4; v:f@6; s:f@8
  v2: v
  {[ii]
    $[(s@ii)=1.;
      [targetV: vLift * gFireT@ii
       v2:: @[v2; ii; +; (targetV - v@ii) * a * dt]];
      0]
  }' !nC
  @[f; 6; :; v2]
}
```

A cell at $T = 1$ is pulled toward the full lift velocity. A cooling cell at $T = 0.3$ generates only a gentle upward nudge. Fully cooled smoke at $T = 0$ contributes no lift.

---

## Swirl Particles: Injecting Turbulence

A burning floor with uniform initial conditions produces a flat, horizontal band of yellow-to-red. The physics are correct but the result looks nothing like fire. Real flames are turbulent — small eddies break the symmetry and produce flickering columns and swirling tendrils.

Turbulence in a real gas emerges spontaneously from fluid instabilities. On a coarse simulation grid, those instabilities are suppressed. The solution: inject turbulence artificially using **swirl particles**.

A swirl particle has:
- **position** $(x, y)$ — advected with the fluid each step
- **radius** $r$ — region of influence
- **angular velocity** $\omega$ — positive for counter-clockwise rotation
- **remaining lifetime** — decremented each step; deleted when it expires

Swirls are spawned stochastically at fire-source cells each frame.

```k
/ Swirl state: list of (x; y; r; omega; ttl) tuples
/ Spawn new swirls at source cells with probability p
spawnSwirls: {[swirls;srcCells;nx;ny;h;spawnProb;maxOmega;ttl]
  newS: ,/ {[idx]
    $[(rand 1.)@0 < spawnProb;
      ,((idx div ny) * h + 0.5*h;    / x position
        (idx mod ny) * h + 0.5*h;    / y position
        h * (1. + (rand 1.)@0);      / radius: 1-2 cells
        maxOmega * (2.*(rand 1.)@0 - 1.);  / random sign
        ttl);
      ()]
  }' srcCells
  swirls, newS
}

/ Update swirl positions (advect with fluid) and decrement lifetime
updateSwirls: {[swirls;f;dt;swirlDamp]
  nx:f@1; ny:f@2; h:f@3; u:f@5; v:f@6
  {[sw]
    x:sw@0; y:sw@1; r:sw@2; omega:sw@3; ttl:sw@4
    / Sample fluid velocity at swirl position
    su: (1.-swirlDamp) * bilinSample[u;nx;ny;h;0.;0.5*h;x;y]
    sv: (1.-swirlDamp) * bilinSample[v;nx;ny;h;0.5*h;0.;x;y]
    (x+su*dt; y+sv*dt; r; omega; ttl-dt)
  }' {sw@4>0.}# swirls    / remove expired swirls
}
```

### Swirl Velocity Influence

Each active swirl modifies nearby grid velocities. For a swirl at $(sx, sy)$ with angular velocity $\omega$ and radius $r$, the influence on a grid node at displacement $(dx, dy)$ from the swirl center:

$$u_{\text{target}} = u_{\text{swirl}} + \omega \cdot dy, \quad v_{\text{target}} = v_{\text{swirl}} - \omega \cdot dx$$

The kernel falls off with distance: full strength within 80% of $r$, linear ramp to zero at $r$, zero beyond.

```k
/ Apply swirl influence to grid velocities
applySwirls: {[f;swirls;dt]
  nx:f@1; ny:f@2; h:f@3; u:f@5; v:f@6
  h2: 0.5*h
  u2: u; v2: v
  {[sw]
    sx:sw@0; sy:sw@1; r:sw@2; omega:sw@3
    / Compute swirl velocity at its own position
    su: bilinSample[u;nx;ny;h;0.;h2;sx;sy]
    sv: bilinSample[v;nx;ny;h;h2;0.;sx;sy]
    / Find affected grid nodes (bounding box of influence radius)
    i0: 0|_((sx-r)%h); i1: (nx-1)&_((sx+r)%h)
    j0: 0|_((sy-r)%h); j1: (ny-1)&_((sy+r)%h)
    {[i]
      {[j]
        / u-face at (i*h, j*h+0.5h)
        dx: i*h - sx; dy: j*h+h2 - sy
        d: sqrt (dx*dx)+dy*dy
        $[d<r;
          [k: $[d<0.8*r; 1.; (r-d)%(0.2*r)]
           tgt: su + omega*dy
           u2:: @[u2; i*ny+j; +; (tgt - u@(i*ny+j)) * k]];
          0]
        / v-face at (i*h+0.5h, j*h)
        dx2: i*h+h2 - sx; dy2: j*h - sy
        d2: sqrt (dx2*dx2)+dy2*dy2
        $[d2<r;
          [k2: $[d2<0.8*r; 1.; (r-d2)%(0.2*r)]
           tgt2: sv - omega*dx2
           v2:: @[v2; i*ny+j; +; (tgt2 - v@(i*ny+j)) * k2]];
          0]
      }' j0+!j1-j0+1
    }' i0+!i1-i0+1
  }' swirls
  @[@[f;5;:;u2];6;:;v2]
}
```

---

## Temperature Smoothing

Resetting source cells to $T = 1$ every frame creates a sharp edge in the temperature field. A single smoothing pass over those cells (replace with diagonal neighbor average) softens the base of the flame:

```k
/ Smooth temperature at source cells using diagonal neighbor average
smoothTempAtSrc: {[srcCells;nx;ny]
  {[idx]
    i: idx div ny; j: idx mod ny
    $[(gFireT@idx)=1. & i>0 & i<nx-1 & j>0 & j<ny-1;
      [avg: ((gFireT@((i-1)*ny+j-1)) + (gFireT@((i+1)*ny+j-1))) + ((gFireT@((i+1)*ny+j+1)) + gFireT@((i-1)*ny+j+1))
       gFireT:: @[gFireT; idx; :; avg*0.25]];
      0]
  }' srcCells
}
```

---

## Temperature-to-Color Mapping

Color mapping uses three piecewise-linear gradients:

```k
/ Map temperature T in [0,1] to (r;g;b) in [0,1]
fireColor: {[T]
  t: 0.|T&1.
  $[t<0.3;
    [s: t%0.3; (0.2*s; 0.2*s; 0.2*s)];       / black → dark gray (smoke)
    $[t<0.5;
      [s: (t-0.3)%0.2; (0.2+0.8*s; 0.1; 0.1)]; / dark gray → red (embers)
      [s: (t-0.5)%0.48; (1.; s; 0.)]]]         / red → yellow (flame)
}

/ Map grid to pixel colors
gridColors: {[nx;ny] {[ii] fireColor[gFireT@ii]}' !nx*ny}
```

---

## The Full Fire Simulation Step

```k
/ Complete fire step: buoyancy + swirls → project → advect → update temps
/ swirls: current swirl list; srcCells: source cell indices; gFireT must be initialized
fireStep: {[f;swirls;dt;srcCells;vLift;a;numIters;omega;maxOmega;ttl;spawnProb;fireRate;smokeRate;swirlDamp]
  nx:f@1; ny:f@2

  / 1. Apply buoyancy
  f2: applyBuoyancy[f;dt;vLift;a]

  / 2. Spawn and update swirls
  swirls2: spawnSwirls[swirls;srcCells;nx;ny;f@3;spawnProb;maxOmega;ttl]
  f3: applySwirls[f2;swirls2;dt]
  swirls3: updateSwirls[swirls2;f3;dt;swirlDamp]

  / 3. Project (enforce incompressibility)
  f4: @[f3;7;:;(f3@4)#0.]
  f5: fluidProject[f4;numIters;dt;1.9]    / from ch17

  / 4. Extrapolate, advect velocity
  f6: fluidExtrapolate[f5]
  f7: fluidAdvectVel[f6;dt]

  / 5. Advect temperature
  advectTemp[f7;dt]

  / 6. Cool, ignite sources, smooth
  updateTemp[f7;dt;srcCells;fireRate;smokeRate]
  smoothTempAtSrc[srcCells;nx;ny]

  (f7; swirls3)
}
```

---

## Key Takeaways

- Fire in a fluid simulator is achieved with a single additional scalar field — a normalized **temperature** $T \in [0, 1]$ — that encodes the full combustion lifecycle from burning gas to cooling smoke.
- **Buoyancy** is modeled as a direct upward force proportional to $T$: hot cells are pulled toward a target lift velocity; cold cells feel nothing.
- Without perturbation, a uniform heat source produces visually flat output. **Swirl particles** — lightweight vortex descriptors advected through the fluid — inject turbulence and produce the irregular flickering of real flame.
- Swirls influence nearby grid velocities through a **flat-topped kernel**: full influence within 80% of the swirl radius, linear falloff to the edge, zero outside.
- **Two cooling rates** (one for fire, one for smoke) reproduce the observed behavior that a flame extinguishes quickly while the smoke it leaves behind persists.
- The rendering is a direct **temperature-to-color mapping** through three piecewise-linear gradients: black smoke, red embers, and yellow-white flame.
- The approach is deliberately approximate — fuel, oxygen, and combustion chemistry collapse into one field — but the result is visually convincing at interactive frame rates.
