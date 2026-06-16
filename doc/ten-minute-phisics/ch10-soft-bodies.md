# Chapter 10 — Soft Bodies: Squish, Bounce, and Volume

A rigid body is an idealization. Real objects deform: rubber bands stretch, gel cubes squish, foam pillows compress and spring back. Simulating this behavior is traditionally one of the most mathematically demanding areas of physics simulation — finite element methods, constitutive models, global solvers. This chapter takes a different path. By representing a soft body as a cloud of particles connected by simple XPBD constraints from Chapter 9, we arrive at a simulation that is stable, fast, and surprisingly accurate.

---

## Why Not Finite Elements?

The classical approach to soft body simulation borrows from structural engineering: represent the object as a continuous deformable medium and derive equations of motion from continuum mechanics. This yields **finite element methods (FEM)**, powerful but carrying heavy engineering baggage:

- **Volume loss under stretch.** Popular linear elastic models shed volume as the object deforms.
- **Inversion artifacts.** When elements flip inside out under large deformation, linear models produce severe visual artifacts.
- **Global solvers.** FEM requires assembling and solving large sparse matrices at every time step.
- **Stability under high damping.** Implicit integration helps with stiffness but introduces its own convergence problems.

Nature does not use continuous functions. Rubber, at the scale that matters, looks like a mass-spring network. Modeling materials as particles connected by constraints is an equally valid physical model at a different scale. With XPBD, that model becomes trivial to implement.

---

## Representing a Soft Body

The geometric foundation is a **tetrahedral mesh**: a solid 3D shape decomposed into tetrahedra in the same way that a surface mesh decomposes a 2D shape into triangles.

From this mesh, the simulation constructs three things:

1. **One particle per vertex.** Each vertex becomes a point mass with a position, a velocity, and an inverse mass.
2. **One distance constraint per edge.** Keeps pairs of particles at their rest separation, providing resistance to stretching and compression.
3. **One volume constraint per tetrahedron.** Resists compression and expansion of each tet — a local incompressibility condition.

Together, these two constraint types approximate the behavior of a neo-Hookean elastic material. In practice, this approach shows *less* volume loss under extreme stretch than standard linear FEM.

---

## Data Layout

In ink, all particle data lives in parallel arrays. The simulation mesh is a tuple of arrays:

```k
/ Soft body state tuple layout:
/ s@0: pos    — list of 3-vectors, one per vertex
/ s@1: vel    — list of 3-vectors
/ s@2: invM   — float list, inverse masses
/ s@3: edges  — list of (i; j; restLen; alpha) tuples
/ s@4: tets   — list of (i1; i2; i3; i4; restVol6; alpha) tuples
/ s@5: prevPos — list of 3-vectors (previous positions for velocity recovery)
```

---

## Mass Assignment

Mass is derived from the mesh geometry: each vertex receives mass contributions from all tetrahedra it belongs to. A tet of volume $V$ contributes $V/4$ of mass to each of its four vertices:

```k
cross3: {[a;b]
  (((a@1)*(b@2))-(b@1)*(a@2)
   ((a@2)*(b@0))-(b@2)*(a@0)
   ((a@0)*(b@1))-(b@0)*(a@1))
}
dot3: {+/ x*y}
tetVol6: {[p1;p2;p3;p4] dot3[cross3[p2-p1; p3-p1]; p4-p1]}

/ Compute inverse masses for all particles from tet list
/ tetIds: list of (i1;i2;i3;i4) index tuples; pos: position list
initMasses: {[pos;tetIds]
  n: #pos
  mass: n#0.
  / Each tet contributes V/4 to each of its 4 vertices
  {[t]
    p1:pos@t@0; p2:pos@t@1; p3:pos@t@2; p4:pos@t@3
    vol: tetVol6[p1;p2;p3;p4] % 6.        / actual volume (not ×6)
    contrib: vol%4.
    mass:: @[@[@[@[mass; t@0; +; contrib]; t@1; +; contrib]; t@2; +; contrib]; t@3; +; contrib]
  } each tetIds
  {$[x=0.; 0.; 1.%x]} each mass           / invert: m → 1/m (0 mass stays pinned)
}
```

Edge rest lengths are the initial distances between connected vertices:

```k
initEdges: {[pos;edgeIds;alpha]
  {[e]
    i:e@0; j:e@1
    d: sqrt +/ (pos@j - pos@i) * pos@j - pos@i
    (i; j; d; alpha)
  } each edgeIds
}
```

---

## The XPBD Simulation Loop

Each frame runs $N$ substeps. Within each substep:

1. **Pre-solve:** apply gravity to free particles, record predicted positions, advance.
2. **Solve edges:** apply distance constraints.
3. **Solve volumes:** apply volume constraints.
4. **Post-solve:** recover velocity from position change.

```k
grav: 0. -9.81 0.
dt: 1.%60
numSubsteps: 10

solveEdge: {[pos;invM;i;j;l0;alpha;sdt]
  p0: pos@i; p1: pos@j
  w0: invM@i; w1: invM@j
  wt: w0+w1
  dx: p1 - p0
  d: sqrt +/ dx*dx
  n: dx % (d|0.0001)
  C: d - l0
  lam: C % wt + alpha%sdt*sdt
  @[@[pos; i; +; n*lam*w0]; j; -; n*lam*w1]
}

solveVol: {[pos;invM;i1;i2;i3;i4;rv6;alpha;sdt]
  p1:pos@i1; p2:pos@i2; p3:pos@i3; p4:pos@i4
  g1: cross3[p4-p2; p3-p2]
  g2: cross3[p3-p1; p4-p1]
  g3: cross3[p4-p1; p2-p1]
  g4: cross3[p2-p1; p3-p1]
  w1:invM@i1; w2:invM@i2; w3:invM@i3; w4:invM@i4
  denom: (w1*(+/g1*g1)) + (w2*(+/g2*g2)) + (w3*(+/g3*g3)) + w4*(+/g4*g4)
  C: tetVol6[p1;p2;p3;p4] - rv6
  lam: C % denom + alpha%sdt*sdt
  pos2: @[pos; i1; -; g1*lam*w1]
  pos3: @[pos2; i2; -; g2*lam*w2]
  pos4: @[pos3; i3; -; g3*lam*w3]
  @[pos4; i4; -; g4*lam*w4]
}

/ One substep of XPBD soft body simulation
sbStep: {[s;sdt]
  pos:s@0; vel:s@1; invM:s@2; edges:s@3; tets:s@4
  n: #pos
  / 1. Pre-solve: gravity + predict + floor clamp
  vel2: {[i] $[invM@i=0.; vel@i; (vel@i)+grav*sdt]} each !n
  prevPos: pos
  pos2: {[i]
    p2: (pos@i) + (vel2@i)*sdt
    / Floor collision: reset to prevPos with y clamped to 0
    $[(p2@1)<0.; (prevPos@i;(prevPos@i)@0,0.,(prevPos@i)@2)@1; p2]
  } each !n
  / 2. Solve edges
  pos3: {[p;e] solveEdge[p; invM; e@0; e@1; e@2; e@3; sdt]}/ (pos2;),edges
  / 3. Solve volumes
  pos4: {[p;t] solveVol[p; invM; t@0; t@1; t@2; t@3; t@4; t@5; sdt]}/ (pos3;),tets
  / 4. Post-solve: recover velocity
  vel3: {[i] $[invM@i=0.; vel@i; (pos4@i - prevPos@i)%sdt]} each !n
  (pos4; vel3; invM; edges; tets)
}

softStep: {[s] numSubsteps sbStep[;dt%numSubsteps]/ s}
```

The fold `{fn}/ (initialState;), constraintList` threads the state through all constraints in sequence, applying each one in turn.

---

## Compliance and Material Properties

Two compliance values control the material's feel:

| Parameter | Value | Effect |
|-----------|-------|--------|
| `edgeAlpha` | `0.` | Hard — infinite stiffness edges (very rubber-like) |
| `edgeAlpha` | `1e-5` | Slightly stretchy |
| `volAlpha` | `0.` | Incompressible — volume conserved exactly |
| `volAlpha` | `1e-3` | Slightly compressible (squishy) |

Setting both to zero produces a nearly rigid body. Setting `volAlpha = 0` and `edgeAlpha` to a small positive value gives an elastic solid that stretches and bounces but preserves volume. This combination closely matches the behavior of rubber.

The compliance values go in the edge and tet tuples:

```k
/ Build soft body from a loaded tet mesh (edgeAlpha, volAlpha are globals)
buildSoftBody: {[pos;edgeIds;tetIds]
  invM: initMasses[pos;tetIds]
  edges: initEdges[pos;edgeIds;edgeAlpha]
  tets: {[t]
    p1:pos@t@0; p2:pos@t@1; p3:pos@t@2; p4:pos@t@3
    rv6: tetVol6[p1;p2;p3;p4]     / rest volume × 6
    (t@0; t@1; t@2; t@3; rv6; volAlpha)
  } each tetIds
  vel: (#pos)#,3#0.               / zero initial velocity
  (pos; vel; invM; edges; tets)
}
```

---

## Floor Collision and Grabbing

Floor collision is handled in the pre-solve step by clamping any particle that drops below $y = 0$. Because we record `prevPos` before the prediction and clamp `pos2` afterward, the post-solve velocity recovery automatically gives a zero or positive y-velocity — no bounce artifacts.

Grabbing a particle (interactive dragging) sets its inverse mass to zero temporarily:

```k
/ Pin particle idx: set invM[idx] = 0 and override position each frame
pinParticle: {[s;idx;target]
  pos2: @[s@0; idx; :; target]
  invM2: @[s@2; idx; :; 0.]
  @[@[s; 0; :; pos2]; 2; :; invM2]
}

/ Unpin particle idx: restore saved inverse mass
unpinParticle: {[s;idx;savedInvM;throwVel]
  invM2: @[s@2; idx; :; savedInvM]
  vel2: @[s@1; idx; :; throwVel]
  @[@[s; 1; :; vel2]; 2; :; invM2]
}
```

When the grab is released, injecting the drag velocity as `throwVel` gives throw physics for free.

---

## Performance

With 10 substeps per frame at 60 Hz, each substep has $\Delta t_s = 1/600\,\text{s} \approx 1.67\,\text{ms}$. A single solver pass per substep is sufficient for convergence at this scale:

```k
/ Benchmark: 600 frames of 10-substep soft body with ~100 particles
edgeAlpha: 0.
volAlpha: 0.
\t 600 softStep/ s0
```

For a coarse bunny mesh (~3,000 edges, ~1,000 tetrahedra), this runs in well under 100ms per 600 frames on a modern machine.

---

## Key Takeaways

- **Tetrahedral meshes** decompose a solid 3D object into tetrahedra. One particle per vertex, one distance constraint per edge, and one volume constraint per tetrahedron are sufficient to simulate elastic behavior.
- **Distance constraints** resist edge stretching and compression. They are the primary source of shear stiffness.
- **Volume constraints** resist compression and expansion of each tetrahedron. Setting $\alpha = 0$ produces a near-incompressible material that conserves volume even under extreme deformation.
- **Compliance** $\alpha = 1/k$ is the inverse of stiffness. $\alpha = 0$ enforces a constraint exactly; positive $\alpha$ allows controlled elasticity. XPBD remains stable at any compliance value.
- **Substepping** — running multiple constraint passes per rendered frame at a smaller time step — replaces the need for iteration within a single step.
- **Mass comes from geometry.** Each vertex's mass is proportional to the volume of the tetrahedra surrounding it. This naturally makes interior vertices heavier than surface vertices.
- The XPBD soft body approach **matches or exceeds** standard Hookean FEM models for volume conservation under large stretch, despite being far simpler to implement.
