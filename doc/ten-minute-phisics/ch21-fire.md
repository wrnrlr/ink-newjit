# Chapter 21 — Simulating Fire

Few phenomena in real-time graphics are as immediately recognizable — and as difficult to fake convincingly — as fire. Flame flickers, rises, swirls, dims to glowing embers, and fades to smoke. Each of those behaviors arises from different physics, yet they must all coexist in a single coherent simulation running at interactive frame rates. This chapter builds a fire simulator directly on top of the Eulerian fluid simulator introduced in Chapter 17. The key insight is that fire is simply a gas with a temperature field attached to it: that one extra scalar quantity, combined with buoyancy forces and injected turbulence, is sufficient to produce convincing flames in a browser.

## From Fluid to Fire

The Eulerian fluid method represents a gas as a velocity field sampled on a regular grid. Each simulation step has three phases: modify the velocity field (for external forces), enforce incompressibility (the projection step), and advect the field quantities — velocity and any scalars — along with the flow.

For a fire simulator, the modification step changes: instead of downward gravity, hot gas rises. And instead of a passive smoke-density scalar, we track a temperature field $T$. Everything else — the staggered grid, the pressure-projection solver, the semi-Lagrangian advection — carries over unchanged.

The full per-frame loop becomes:

```
1. Modify velocities  (buoyancy lift + swirl turbulence)
2. Make fluid incompressible  (projection)
3. Advect velocity and temperature fields
4. Update temperatures  (ignite sources, cool, smooth)
```

## The Temperature Field

Rather than maintaining separate fields for fuel concentration, combustion products, and smoke density, this simulation collapses everything into a single normalized scalar $T \in [0, 1]$. The interpretation is a simple color-coded encoding of the combustion lifecycle:

| Range | Meaning |
|---|---|
| $T \in [0.5, 1.0]$ | Active flame (yellow to red) |
| $T \in [0.3, 0.5]$ | Glowing embers, dark red |
| $T \in [0.0, 0.3]$ | Smoke (dark gray to black) |

At every time step, fire source cells — cells inside or just outside a burning obstacle, or cells near a burning floor — have their temperature reset to $T = 1$. All other cells cool:

$$T \leftarrow \max(T - r \cdot \Delta t,\; 0)$$

where the cooling rate $r$ differs between the fire and smoke regimes. Flames cool quickly (rate 1.2 per second in the reference implementation) because the bright combustion phase is short-lived. Smoke cools more slowly (rate 0.3 per second) because dispersed particles retain heat longer. Once $T$ reaches zero the cell is simply dark background.

After cooling, the temperature is advected along the velocity field just like the velocity components themselves, using the same semi-Lagrangian back-tracing:

```javascript
advectTemperature(dt) {
    this.newT.set(this.t);
    var n = this.numY, h = this.h, h2 = 0.5 * h;

    for (var i = 1; i < this.numX - 1; i++) {
        for (var j = 1; j < this.numY - 1; j++) {
            if (this.s[i*n + j] != 0.0) {
                var u = (this.u[i*n + j] + this.u[(i+1)*n + j]) * 0.5;
                var v = (this.v[i*n + j] + this.v[i*n + j+1]) * 0.5;
                var x = i*h + h2 - dt*u;
                var y = j*h + h2 - dt*v;
                this.newT[i*n + j] = this.sampleField(x, y, T_FIELD);
            }
        }
    }
    this.t.set(this.newT);
}
```

Each cell traces its position backward by one time step and samples the temperature at that upstream location. This is the same semi-Lagrangian scheme used for velocity advection: unconditionally stable, first-order accurate, and slightly diffusive — which actually helps, because numerical diffusion softens the temperature field in a visually plausible way.

## Buoyancy: Hot Air Rises

The physical reason fire rises is buoyancy. Hot gas is less dense than cold gas; the surrounding cooler air pushes it upward. Rather than modeling density differences explicitly, the simulator converts temperature directly into an upward velocity target:

$$v_{\text{target}} = v_{\text{lift}} \cdot T$$

The current vertical velocity $v$ is then driven toward $v_{\text{target}}$ with a simple first-order rate:

$$v \leftarrow v + a \cdot (v_{\text{target}} - v) \cdot \Delta t$$

where $v_{\text{lift}}$ controls how fast the hottest gas rises (set to 3.0 m/s in the reference) and $a$ is an acceleration constant (6.0 per second) that governs how quickly the velocity catches up. This formulation elegantly ties the lift strength to temperature: a cell at $T = 1$ is pulled toward the full lift velocity, while a cooling cell at $T = 0.3$ generates only a gentle upward nudge, and fully cooled smoke at $T = 0$ contributes no lift at all.

In code, these two lines sit inside the per-cell temperature update:

```javascript
let targetV = t * lift;
this.v[i*n + j] += (targetV - v) * acceleration;
```

## The Swirl Problem

A burning floor with uniform initial conditions and no external perturbation produces a flat, horizontal band of yellow-to-red. The physics are correct — the gas rises uniformly — but the result looks nothing like fire. Real flames are turbulent. Small eddies break the symmetry and produce the characteristic flickering columns and swirling tendrils.

Turbulence in a real gas emerges spontaneously from fluid instabilities. In a coarse simulation grid, those instabilities are suppressed because the grid cannot represent the small velocity variations that seed them. The solution is to inject turbulence artificially using **swirl particles**.

A swirl particle is a lightweight vortex descriptor:

- **position** $(x, y)$ — advected with the fluid each step
- **radius** $r$ — the region of influence
- **angular velocity** $\omega$ — positive for counter-clockwise rotation
- **remaining lifetime** — decremented each step; the swirl is deleted when it expires

Swirls are spawned stochastically at fire-source cells each frame. The probability scales with the cell area $h^2$, so the number of new swirls per frame stays roughly constant as the grid resolution changes. Each new swirl is assigned a random angular velocity $\omega$ drawn uniformly from $[-\omega_{\max}, +\omega_{\max}]$, which gives the fire a mix of left-spinning and right-spinning vortices.

## Swirl Velocity Influence

Each active swirl modifies the velocity field of nearby grid nodes. Let $\mathbf{d} = \mathbf{x}_{\text{grid}} - \mathbf{x}_{\text{swirl}}$ be the displacement from the swirl center to a grid node, and $d = |\mathbf{d}|$. The swirl imposes a tangential velocity at that node — perpendicular to $\mathbf{d}$ — with magnitude $\omega \cdot d$. Written component-wise, the target velocity at the grid node is the swirl's own advected velocity plus the rotational component:

$$u_{\text{target}} = u_{\text{swirl}} + \omega \cdot d_y$$
$$v_{\text{target}} = v_{\text{swirl}} - \omega \cdot d_x$$

The current grid velocity is pulled toward this target, scaled by a kernel $k(d)$ that falls off with distance:

$$k(d) = \begin{cases} 1 & d < 0.8\,r \\ \frac{r - d}{0.2\,r} & 0.8\,r \le d < r \\ 0 & d \ge r \end{cases}$$

The flat top of the kernel (full strength out to 80% of the radius, then a linear ramp to zero) means the swirl applies uniform rotation near its center and a smooth rolloff at the edge, avoiding velocity discontinuities in the grid.

```javascript
if (dim == 0) {
    let target = ry * omega + swirlU;
    let u = this.u[n*i + j];
    this.u[n*i + j] += (target - u) * s;
}
else {
    let target = -rx * omega + swirlV;
    let v = this.v[n*i + j];
    this.v[n*i + j] += (target - v) * s;
}
```

Here `s` is the kernel value, `swirlU` and `swirlV` are the swirl's own velocity (sampled from the fluid field), and `rx`, `ry` are the components of $\mathbf{d}$.

Swirls are advected each step by sampling the velocity field at their current position. A small damping factor is applied to keep them from accelerating indefinitely:

```javascript
let swirlU = (1.0 - swirlDamping) * this.sampleField(x, y, U_FIELD);
let swirlV = (1.0 - swirlDamping) * this.sampleField(x, y, V_FIELD);
x += swirlU * dt;
y += swirlV * dt;
```

This way each swirl drifts upward through the flame, injecting its rotational pattern as it goes, then eventually expires. A probability slider in the interactive demo controls how frequently new swirls are born; at high probability the fire is visibly more turbulent and chaotic.

## Temperature Smoothing

One subtle artifact of resetting source cells to $T = 1$ every frame is that the boundary of the source region creates a sharp edge in the temperature field. When those cells are advected they produce a hard seam. The simulation addresses this by running a single smoothing pass over cells that are at the source temperature: each such cell is replaced by the average of its four diagonal neighbors. This is applied once per step and costs very little, but visibly softens the base of the flame.

```javascript
for (let i = 1; i < this.numX - 1; i++) {
    for (let j = 1; j < this.numY - 1; j++) {
        if (this.t[i * n + j] == 1.0) {
            let avg = (
                this.t[(i-1)*n + (j-1)] + this.t[(i+1)*n + (j-1)] +
                this.t[(i+1)*n + (j+1)] + this.t[(i-1)*n + (j+1)]) * 0.25;
            this.t[i * n + j] = avg;
        }
    }
}
```

## Rendering

Color mapping is straightforward once the temperature field exists. Three piecewise-linear gradients cover the full range:

```javascript
function getFireColor(val) {
    val = Math.min(Math.max(val, 0.0), 1.0);
    var r, g, b;
    if (val < 0.3) {
        let s = val / 0.3;
        r = 0.2*s; g = 0.2*s; b = 0.2*s;           // black → dark gray
    } else if (val < 0.5) {
        let s = (val - 0.3) / 0.2;
        r = 0.2 + 0.8*s; g = 0.1; b = 0.1;          // dark gray → red
    } else {
        let s = (val - 0.5) / 0.48;
        r = 1.0; g = s; b = 0.0;                     // red → yellow
    }
    return [255*r, 255*g, 255*b, 255];
}
```

Each grid cell is mapped to a rectangular region of pixels using direct pixel-buffer writes — the `ImageData` API. This avoids the overhead of canvas `fillRect` calls for each cell and is fast enough to run at 60 fps even on grids with 100,000 cells.

## Putting the Loop Together

The full simulation step is:

```javascript
simulate(dt, gravity, numIters) {
    this.integrate(dt, gravity);          // apply lift forces
    this.solveIncompressibility(numIters, dt);
    this.extrapolate();
    this.advectVel(dt);
    this.advectTemperature(dt);
    this.updateFire(dt);                  // cool, ignite, spawn swirls
}
```

The `integrate` call here applies buoyancy rather than gravity — the gravity parameter is set to zero in the fire scene. Buoyancy is applied per-cell inside `updateFire` alongside cooling and swirl spawning. The projection step (`solveIncompressibility`) and advection are unchanged from the base fluid simulator.

One design detail worth noting: swirl velocity updates happen before projection. This means the incompressibility solver immediately removes any divergence introduced by the swirls. The rotational component of a swirl is inherently divergence-free (it is a pure vortex), but the interaction between the swirl target velocity and the existing grid velocity can produce small divergence errors. Projecting afterward cleans those up.

## Key Takeaways

- Fire in a fluid simulator is achieved with a single additional scalar field — a normalized **temperature** $T \in [0, 1]$ — that encodes the full combustion lifecycle from burning gas to cooling smoke.
- **Buoyancy** is modeled as a direct upward force proportional to $T$: hot cells are pulled toward a target lift velocity, cold cells feel nothing.
- Without additional perturbation, a uniform heat source produces visually flat, banded output. **Swirl particles** — lightweight vortex descriptors advected through the fluid — inject turbulence and break the symmetry, producing the irregular flickering of real flame.
- Swirls influence nearby grid velocities through a **flat-topped kernel**: full influence within 80% of the swirl radius, linear falloff to the edge, zero outside. This avoids velocity discontinuities.
- Two different **cooling rates** (one for fire, one for smoke) reproduce the observed behavior that a flame extinguishes quickly while the smoke it leaves behind persists.
- The rendering is a direct **temperature-to-color mapping** through three piecewise-linear gradients: black smoke, red embers, and yellow-white flame.
- The approach is deliberately approximate — fuel concentration, oxygen depletion, and combustion chemistry are all collapsed into a single field — but the result is visually convincing at interactive frame rates with no additional data structures beyond those already present in the base fluid solver.
