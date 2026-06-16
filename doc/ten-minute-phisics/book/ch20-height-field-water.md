# Chapter 20 — Height-Field Water Simulation

Simulating a believable ocean, lake, or tank of water is one of the most visually rewarding problems in real-time physics. Full volumetric fluid simulation is expensive enough that it is usually reserved for offline rendering. For interactive use, a much lighter approach exists: represent the water surface as a 2D grid of column heights and propagate disturbances across that grid using the wave equation. The result is fast enough to run in a browser, expressive enough to handle floating objects and splashing, and requires fewer than one hundred lines of code.

---

## Representing Water as a Column Grid

Instead of tracking every particle of water, we divide the surface into a rectangular grid of vertical columns, each with a uniform width $s$. Each column $(i, j)$ stores two numbers:

- $h_{i,j}$ — the total height of the water column above the ground.
- $v_{i,j}$ — the vertical velocity of that column.

When the grid is laid out along a single line of columns this is called a **1.5D** simulation: the grid is one-dimensional but the columns reach up into a second dimension. Extending the grid to a full plane gives a **2.5D** simulation: a two-dimensional array of columns that poke up into three-dimensional space.

The column representation has important practical consequences. Extracting the visible surface mesh is trivial — just read off the heights and build triangles between neighboring grid points. Simulation cost scales as $O(N)$ in the number of columns rather than $O(N^2)$ or worse. The price paid for this efficiency is that the method cannot represent overturning waves or spray. Those effects require a separate particle layer added on top, but for tanks, rivers, and gentle ocean surfaces the column model is entirely convincing.

---

## Deriving the Wave Equation

The dynamics of each column follow directly from two principles: Archimedes' buoyancy and Newton's second law.

Imagine two adjacent columns of water with heights $h_1$ and $h_2$. Because $h_2 > h_1$, the taller column pushes down harder on the interface between them. By Archimedes' principle the resulting net force is proportional to the height difference $h_2 - h_1$. Newton's second law then says the acceleration of the shorter column is proportional to that force. By conservation of volume, if column 1 is accelerated upward then column 2 must be accelerated downward by the same amount.

Extending this reasoning to an interior column $i$ surrounded by neighbors $i-1$ and $i+1$, each neighbor pair contributes its own push. The total acceleration is the sum of both contributions:

$$a_i = \frac{c^2}{s^2}\left(h_{i-1} + h_{i+1} - 2h_i\right)$$

This is precisely the discrete Laplacian scaled by $c^2/s^2$, where $c$ is the wave propagation speed and $s$ is the column width. In the 2.5D case a column $(i,j)$ has four neighbors, and the formula extends naturally:

$$a_{i,j} = \frac{c^2}{s^2}\left(h_{i-1,j} + h_{i+1,j} + h_{i,j-1} + h_{i,j+1} - 4h_{i,j}\right)$$

This is the discrete wave equation in two spatial dimensions. Disturbances propagate outward at speed $c$, producing the characteristic circular ripple patterns seen on still water.

---

## Boundary Conditions

At the edges of the grid, one or more neighbors fall outside the domain. The choice of how to handle them determines the physical behavior at the boundary.

For **reflecting walls** — the behavior of a tank — we substitute the column's own height for any out-of-domain neighbor. Algebraically, the missing term cancels with the corresponding subtracted term, so the column at the boundary feels no net force from the missing direction. Waves hit the wall and bounce back, conserving energy exactly as a rigid wall would.

---

## Numerical Integration

With the acceleration formula established, advancing the simulation is a two-pass loop over the grid. The first pass updates velocities; the second updates heights:

```javascript
// Pass 1: update velocities
for (let i = 0; i < numX; i++) {
    for (let j = 0; j < numZ; j++) {
        let id = i * numZ + j;
        let h = heights[id];
        let sumH = 0.0;
        sumH += i > 0          ? heights[id - numZ] : h;
        sumH += i < numX - 1   ? heights[id + numZ] : h;
        sumH += j > 0          ? heights[id - 1]    : h;
        sumH += j < numZ - 1   ? heights[id + 1]    : h;
        velocities[id] += dt * c * (sumH - 4.0 * h);
    }
}

// Pass 2: update heights
for (let i = 0; i < numCells; i++) {
    heights[i] += velocities[i] * dt;
}
```

This is semi-implicit Euler integration. The velocity is updated using the current height configuration, and the height is then updated using the freshly computed velocity. Splitting the two passes is important: if we updated height and velocity together in a single pass we would be using partially updated heights when computing accelerations, introducing asymmetric errors.

The stability condition for this scheme is the **CFL condition** — named after Courant, Friedrichs, and Lewy — which requires that a wave must not travel more than one grid cell in one time step:

$$\Delta t \cdot c < s$$

In practice, we enforce this by clamping the wave speed before each step:

```javascript
waveSpeed = Math.min(waveSpeed, 0.5 * spacing / dt);
let c = waveSpeed * waveSpeed / (spacing * spacing);
```

---

## Damping

Undamped waves reflect endlessly between the walls. Real water dissipates energy through viscosity and turbulence. Two separate damping mechanisms are useful here.

**Velocity damping** multiplies every velocity by a factor slightly less than one each step, exponentially draining energy from the system:

```javascript
velocities[i] *= Math.max(0.0, 1.0 - velDamping * dt);
```

**Positional damping** nudges each column height a small fraction of the way toward the average of its neighbors, which suppresses high-frequency noise without strongly affecting long-wavelength waves:

```javascript
heights[id] += (0.25 * sumH - h) * Math.min(posDamping * dt, 1.0);
```

Together these two mechanisms give good control over how quickly the water settles after a disturbance.

---

## Coupling Objects to the Water

A simulation with no objects floating in the water is not very interesting. Making the coupling work in both directions — objects disturbing the water, and water exerting forces on objects — requires a small amount of bookkeeping.

### Objects Pushing Down on the Water

The naive approach is to push water columns downward wherever a submerged object occupies space. This is easy to implement but has two serious flaws: it does not conserve water volume, and it fails entirely for fully submerged bodies because it leaves an empty void inside them.

A better solution introduces an auxiliary field $b_{i,j}$ that stores the **height covered by objects** in each column. At each time step we compute how $b$ has changed since the last step and add that change to the water column heights:

$$h_{i,j} \leftarrow h_{i,j} + \alpha\,(b_{i,j} - b^{\text{prev}}_{i,j})$$

The scalar $\alpha \in [0, 1]$ controls the coupling strength. When an object moves downward into the water ($b$ increases), the water surface rises around it. When the object rises ($b$ decreases), the surface lowers. Because we add the *change* in $b$ rather than setting $h$ directly, volume is automatically conserved — water pushed up in one place does not disappear. The same mechanism handles fully submerged objects correctly, since $b$ simply tracks the body's cross-section at every depth.

To prevent sharp spikes at object boundaries, the $b$ field is smoothed with a few iterations of neighbor averaging before it is applied:

```javascript
simulateCoupling() {
    this.prevBodyHeights.set(this.bodyHeights);
    this.bodyHeights.fill(0.0);

    // Accumulate body cross-sections into bodyHeights
    for (let ball of objects) {
        // ... (compute overlap of ball with each grid column)
        if (bodyHeight > 0.0) {
            ball.applyForce(-bodyHeight * cellArea * gravity.y);  // buoyancy
            this.bodyHeights[xi * numZ + zi] += bodyHeight;
        }
    }

    // Smooth bodyHeights to suppress spikes
    for (let iter = 0; iter < 2; iter++) {
        for (let xi = 0; xi < numX; xi++) {
            for (let zi = 0; zi < numZ; zi++) {
                let id = xi * numZ + zi;
                let avg = /* neighbor average */ 0.0;
                // ... accumulate and divide by neighbor count
                this.bodyHeights[id] = avg;
            }
        }
    }

    // Apply change to water heights
    for (let i = 0; i < numCells; i++) {
        let bodyChange = this.bodyHeights[i] - this.prevBodyHeights[i];
        this.heights[i] += this.alpha * bodyChange;
    }
}
```

### Water Pushing Up on Objects

In the other direction, Archimedes' principle gives us the upward force directly. For each grid column that overlaps with an object, the overlap volume is $o \cdot s^2$, where $o$ is the height of the intersection between the object and the water column and $s^2$ is the column's cross-sectional area. The buoyancy force is the weight of the displaced water:

$$f = \rho_{\text{water}} \cdot o \cdot s^2 \cdot g$$

This force is applied upward at the center of the column. For a ball of mass $m$ this translates to a velocity impulse:

```javascript
applyForce(f) {
    this.vel.y += dt * f / this.mass;
}
```

The force is applied per column, so an object spanning many columns receives contributions from each one. A ball floating with half its volume submerged experiences a net upward force equal to its own weight — the equilibrium condition Archimedes described. Objects with density greater than water will experience a buoyancy force smaller than their weight and sink; objects less dense than water will float with just enough of their volume submerged to balance.

---

## Refraction Rendering

The wave simulation produces a height field and a normal at every vertex. Converting those normals into a convincing water appearance uses a simple screen-space trick.

The scene behind the water plane is rendered first to an offscreen texture. Then, when rendering each fragment of the water mesh, instead of sampling the texture at the fragment's own screen coordinates, we add a small offset proportional to the surface normal:

```glsl
// Fragment shader
float r = 0.02;
vec2 uv = varScreenPos + r * vec2(varNormal.x, varNormal.z);
vec4 color = texture2D(background, uv);
color.z = min(color.z + 0.2, 1.0);  // tint slightly blue
```

The offset shifts the apparent position of the background in a direction that depends on the local surface slope. Where the water surface tilts toward the viewer, the background appears to shift in one direction; where it tilts away, it shifts in the other. The result mimics the way refraction bends light at the water–air interface, bending the image of objects below the surface as waves pass overhead. A more accurate implementation would make the offset magnitude proportional to the camera distance to the water surface — closer water refracts more noticeably in screen space — but the constant approximation is plausible at typical camera distances.

The two-pass rendering is arranged so that the offscreen render captures everything *except* the water mesh, giving a clean background. The water mesh is then rendered on top, sampling the background texture with the normal-derived offset.

---

## Putting It Together

The top-level simulation step runs three stages in order:

1. **Coupling pass** — compute object-to-water displacements, apply buoyancy forces back to objects.
2. **Surface pass** — propagate the wave equation across the height field, apply damping.
3. **Mesh update** — write the new heights into the vertex buffer and recompute normals.

```javascript
simulate() {
    this.simulateCoupling();   // two-way object ↔ water
    this.simulateSurface();    // wave equation + damping
    this.updateVisMesh();      // push heights to GPU
}
```

The entire physics core, including coupling, wave propagation, and damping, fits in roughly one hundred lines of JavaScript. Rendering and scene setup add more, but the simulation heart is genuinely compact. That compactness is not accidental: by restricting the water representation to a height field and the dynamics to the discrete wave equation, we avoided all of the algorithmic complexity of pressure solvers, advection schemes, and particle resamplers that appear in more general fluid simulations.

---

## Key Takeaways

- A **height-field** (2.5D column grid) represents water as heights $h_{i,j}$ and velocities $v_{i,j}$, enabling fast simulation with trivial surface extraction at the cost of no overturning waves.
- The **discrete wave equation** $a_{i,j} = (c^2/s^2)(h_{i-1,j} + h_{i+1,j} + h_{i,j-1} + h_{i,j+1} - 4h_{i,j})$ governs column acceleration, derived directly from Archimedes' principle and Newton's second law.
- **Reflecting boundary conditions** are implemented by substituting a column's own height for any out-of-domain neighbor, making missing terms cancel.
- **Semi-implicit Euler** integration — update velocities first, then heights — is stable and simple. The **CFL condition** $\Delta t \cdot c < s$ bounds the time step.
- **Two-way coupling** is achieved via an auxiliary body-height field $b_{i,j}$: the *change* in $b$ is added to water heights (conserving volume), while Archimedes' principle applied per column yields buoyancy forces on objects.
- Smoothing the body-height field before applying it suppresses sharp spikes at object boundaries and improves stability.
- **Screen-space refraction** requires only two render passes: render the background to a texture, then sample that texture at normal-offset coordinates when drawing the water surface.
