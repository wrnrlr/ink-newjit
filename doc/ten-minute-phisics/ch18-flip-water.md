# Chapter 18 — FLIP Water: Hybrid Particle-Grid Simulation

The Eulerian fluid simulator built in the previous chapter is elegant and fast, but it has a subtle problem that becomes obvious the moment you try to simulate water with a free surface: the water loses energy. Turbulent jets smooth themselves into laminar flows, splashes die away before they form, and the overall motion looks more like thick syrup than water. The cause is numerical diffusion — an artifact of the grid-based velocity representation, not of the physics. This chapter introduces the FLIP method (Fluid Implicit Particle), a hybrid scheme that cures numerical diffusion by letting particles carry velocity while the grid handles the pressure solve. The result is the kind of splashy, detail-rich water simulation familiar from visual effects production, running in real time.

---

## From Two Phases to Three

The pure Eulerian method fills the entire domain with fluid. Extending it to water and air requires distinguishing three types of grid cell: **fluid** (water), **air**, and **solid**. At first glance this seems complicated, but a powerful simplification is available: the density of water is roughly one thousand times that of air. Air, in effect, weighs nothing compared to water. We therefore treat air as a vacuum — no momentum, no coupling — and simply skip air cells in the pressure solver.

This approximation does miss a few real phenomena, most notably wind-driven waves and long-lived bubbles. For the kind of dam-break, splashing, sloshing water that makes a compelling simulation, however, the approximation is excellent and the cost savings are substantial.

The remaining question is how to know which cells contain water and which contain air. The answer is what makes the FLIP method distinctive: we track **particles**.

---

## What PIC Gets Right — and What It Gets Wrong

The Particle-In-Cell (PIC) method, the direct predecessor of FLIP, establishes the basic structure. Each particle carries a position $\mathbf{x}$ and a velocity $\mathbf{v}$. The simulation advances in four steps per frame:

1. Integrate the particles forward under gravity (and any other body forces).
2. Transfer particle velocities onto the grid.
3. Make the grid velocity field incompressible (the pressure projection step, identical to the pure Eulerian method).
4. Transfer the corrected grid velocities back to the particles.

Because the particles act as both the fluid marker and the advection mechanism, the semi-Lagrangian advection step from the Eulerian method is no longer needed. The particles handle transport automatically.

The problem is step 4. When velocities are transferred from grid to particles via bilinear interpolation, each particle's new velocity is a weighted average over four neighboring grid corners. Averaging is irreversible: fine-scale particle motion that was not resolved on the grid disappears permanently. After a handful of steps, the particle velocities have been averaged into approximate agreement with the smooth grid field, and the characteristic squiggles and jets of real turbulent water are gone. This is numerical viscosity, and for water — a fluid whose viscosity is nearly zero — it is catastrophically wrong.

---

## The FLIP Idea

FLIP, which stands for Fluid Implicit Particle, fixes numerical viscosity with one conceptual shift: instead of replacing particle velocities with the post-projection grid velocities, add only the *change* in grid velocity to each particle.

The modified step 4 reads:

$$\mathbf{v}_p \leftarrow \mathbf{v}_p + \left(\mathbf{u}^{\text{new}} - \mathbf{u}^{\text{old}}\right)\bigg|_{\mathbf{x}_p}$$

where $\mathbf{u}^{\text{new}}$ is the grid velocity after projection and $\mathbf{u}^{\text{old}}$ is the grid velocity before projection (but after gathering from the particles). The interpolation $(\cdot)|_{\mathbf{x}_p}$ evaluates this difference at the particle's position using the same bilinear weights as before.

What changes? The absolute value is no longer averaged away — only the *correction* made by the pressure solver is interpolated and applied. All the fine-scale velocity variation that the grid cannot represent remains untouched on the particles. The particles act as a high-resolution memory that the grid cannot access but also cannot destroy.

The cost of this fidelity is noise. The particle velocities accumulate small inconsistencies over time because the particle field and the grid field can drift apart. In practice, the optimal strategy is to blend the two approaches:

$$\mathbf{v}_p^{\text{final}} = (1 - \alpha)\,\mathbf{v}_p^{\text{PIC}} + \alpha\,\mathbf{v}_p^{\text{FLIP}}$$

where $\alpha$ is the FLIP ratio. A value of $\alpha = 0.9$ — ninety percent FLIP, ten percent PIC — gives water that is lively without being noticeably noisy. The ten percent PIC contribution continuously damps the accumulated noise without washing out the large-scale splashing behavior.

---

## The Simulation Loop

With the conceptual structure in place, the full per-frame loop is:

1. Integrate particles: apply gravity, advance positions.
2. Push particles apart to prevent clumping.
3. Handle particle collisions with walls and obstacles.
4. Transfer particle velocities to the grid (particles → grid).
5. Compute and store particle density at grid cell centers.
6. Solve for incompressibility (pressure projection).
7. Transfer corrected velocities back to particles (grid → particles), applying PIC/FLIP blend.

Steps 4 through 7 are the heart of the method. The others are straightforward bookkeeping.

---

## Particle Integration

Integrating the particles is exactly the symplectic Euler step seen in Chapter 1:

```javascript
integrateParticles(dt, gravity) {
    for (var i = 0; i < this.numParticles; i++) {
        this.particleVel[2*i + 1] += dt * gravity;
        this.particlePos[2*i]     += this.particleVel[2*i]     * dt;
        this.particlePos[2*i + 1] += this.particleVel[2*i + 1] * dt;
    }
}
```

Velocity is updated first, position second. Each particle is an independent point mass; only the pressure projection (mediated through the grid) couples them.

After integration, `handleParticleCollisions` clamps positions to stay inside the tank walls and, when a particle lands inside a circular obstacle, overwrites its velocity with the obstacle's current velocity. This is a velocity constraint, not a position correction, which keeps the contact smooth.

---

## Particle-to-Grid Transfer

The staggered grid from the Eulerian solver is carried over unchanged. The $u$ velocity component lives at the left face of each cell (shifted half a cell spacing in $y$), and the $v$ component lives at the bottom face (shifted half a cell spacing in $x$). Both components are transferred using the same weighted-scatter algorithm, but with different lookup offsets.

For a particle at position $(x_p, y_p)$, the transfer for one velocity component proceeds as follows. First, identify the four surrounding grid nodes and compute the bilinear weights:

$$t_x = \frac{(x_p - dx) - x_0 h}{h}, \quad t_y = \frac{(y_p - dy) - y_0 h}{h}$$

where $(dx, dy)$ is the stagger offset for the component being transferred, $(x_0, y_0)$ is the lower-left node index, and $h$ is the cell spacing. The four weights are:

$$w_0 = (1-t_x)(1-t_y), \quad w_1 = t_x(1-t_y), \quad w_2 = t_x t_y, \quad w_3 = (1-t_x)t_y$$

Each particle scatters its velocity onto the surrounding nodes:

```
for each particle p:
    f[nr0] += v_p * w0;   d[nr0] += w0
    f[nr1] += v_p * w1;   d[nr1] += w1
    f[nr2] += v_p * w2;   d[nr2] += w2
    f[nr3] += v_p * w3;   d[nr3] += w3

for each node:
    if d[node] > 0: f[node] /= d[node]
```

The division normalizes the weighted sum. A node with no nearby particles receives no velocity; those nodes are typed as AIR and are skipped by the pressure solver.

Cell typing happens during the same pass. All cells start as AIR (or SOLID for boundary cells). Any cell that contains at least one particle is marked FLUID. This determines the water surface implicitly: fluid is wherever the particles are, everything else is air.

---

## Grid-to-Particle Transfer and PIC/FLIP Blending

Before the pressure projection runs, the code saves the current grid velocity:

```javascript
this.prevU.set(this.u);
this.prevV.set(this.v);
```

After projection, each particle gathers from both the new grid field and the saved old field. The PIC velocity is simply the interpolated new field; the FLIP velocity is the particle's existing velocity plus the interpolated change:

```javascript
var picV  = /* bilinear interpolation of u_new at particle position */;
var corr  = /* bilinear interpolation of (u_new - u_old) at particle position */;
var flipV = v_particle + corr;

this.particleVel[2*i + component] = (1.0 - flipRatio) * picV + flipRatio * flipV;
```

One important subtlety: when interpolating back to a particle, any grid node that is AIR on both sides of the face boundary is excluded from the weighted average. Nodes adjacent to at least one fluid cell carry valid, physically meaningful velocities; pure-air nodes have undefined values that would corrupt the result if included. The `valid0`...`valid3` flags in the code implement this check.

---

## Pressure Projection

The projection step is the Gauss-Seidel iteration from Chapter 17, with one modification. For each fluid cell $(i, j)$, the divergence is:

$$d_{ij} = u_{i+1,j} - u_{i,j} + v_{i,j+1} - v_{i,j}$$

When drift compensation is enabled, a density term is subtracted:

$$d_{ij} \leftarrow d_{ij} - k\,(\rho_{ij} - \rho_0)$$

Here $\rho_{ij}$ is the local particle density at the cell center, $\rho_0$ is the average rest density measured at the start of the simulation, and $k \approx 1$ is a stiffness coefficient. Cells that are denser than rest have their divergence artificially increased, which causes the pressure solver to push fluid outward from those regions. This corrective pressure counteracts the tendency of particles to clump even when the grid velocity field is technically divergence-free.

Over-relaxation with a factor near 1.9 accelerates convergence substantially without causing instability, allowing the simulation to run with only 50 pressure iterations per frame while maintaining visual quality.

---

## Handling Particle Drift

Even with an incompressible velocity field, particles drift and clump over time. Pure velocity-based methods cannot prevent this: the solver works in terms of flows, not positions, so it cannot see that particles are already touching.

Two mechanisms address the problem. The first is direct geometric separation: after integration, particles that overlap are pushed apart. A spatial hash (partitioning the domain into cells of diameter roughly $2r$, where $r$ is the particle radius) allows this to be done in near-linear time. For each particle, only the nine neighboring hash cells need to be checked. When two particles are closer than $2r$, each is displaced by half the overlap along the line connecting their centers.

The second mechanism is the density-modified divergence described above. Even after geometric separation, the pressure solver may not notice local overdensity. The density term gives the solver the information it needs to apply corrective outward pressure.

Together, these two fixes keep the particle distribution close to uniform, which is what the rest density $\rho_0$ assumes.

---

## Scene Setup: the Dam Break

The classic test for any free-surface water simulator is the dam break. A column of water fills the left portion of a tank; at $t = 0$, the constraint holding it in place is removed and the water rushes across the floor, climbs the far wall, and splashes back. The setup in code:

```javascript
var res = 100;                         // grid resolution
var h   = tankHeight / res;            // cell size
var r   = 0.3 * h;                     // particle radius

// particles arranged in a hexagonal close-packed grid
var dx = 2.0 * r;
var dy = Math.sqrt(3.0) / 2.0 * dx;

for (var i = 0; i < numX; i++) {
    for (var j = 0; j < numY; j++) {
        f.particlePos[p++] = h + r + dx * i + (j % 2 == 0 ? 0.0 : r);
        f.particlePos[p++] = h + r + dy * j;
    }
}
```

Hexagonal packing places approximately 15% more particles per unit area than a square grid. That extra density helps the rest-density estimate $\rho_0$ remain stable early in the simulation before the water spreads and thins.

The boundary cells (left wall, right wall, floor) are marked solid by setting their $s$ value to zero. The ceiling is left open — particles that fly upward simply leave the domain.

---

## Key Takeaways

- **Numerical diffusion** in grid-based (Eulerian) fluids arises because transferring velocities from grid to particles is a weighted average, which irreversibly smooths fine-scale motion. For low-viscosity fluids like water, this diffusion is physically wrong and visually obvious.
- **PIC** (Particle-In-Cell) defines the hybrid foundation: particles carry position and velocity; the grid provides the incompressibility constraint via pressure projection; particles replace the advection step.
- **FLIP** eliminates most of the smoothing by transferring only the *change* in grid velocity to the particles, rather than the grid velocity itself. The particle velocities accumulate the high-frequency detail that the grid cannot represent.
- **PIC/FLIP blending** at roughly 10% PIC / 90% FLIP gives the best of both worlds: the noise-damping of PIC and the detail-preservation of FLIP. The blend ratio $\alpha$ is a tunable parameter.
- **Three-phase typing** (fluid, air, solid) is the key to free-surface simulation. Cells containing particles are fluid; all others are air and are skipped by the pressure solver. Air velocities are undefined, not zero, and must be excluded from particle interpolations.
- **Drift correction** requires two separate fixes: geometric particle separation via a spatial hash, and a density-modified divergence term that gives the pressure solver awareness of local overcrowding.
- **Rest density** $\rho_0$ is measured from the initial particle distribution and used throughout the simulation as the target density. Deviations from it drive the corrective pressure that keeps particles spread evenly.
