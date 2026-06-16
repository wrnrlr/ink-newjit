# Chapter 14 — The Secret of Cloth Simulation

Cloth is one of the most visually compelling things a physics engine can simulate and, for a long time, one of the most computationally treacherous. Waving flags, falling capes, and draped fabric all demand that a mesh of thousands of triangles move convincingly in real time. This chapter reveals a surprisingly simple principle at the heart of cloth simulation and shows how XPBD turns that principle into a fast, stable, and parameter-light implementation.

---

## The Secret: Cloth Only Bends

The key insight is this: real cloth barely stretches. Pick up a shirt, a pair of jeans, or a curtain and pull it lengthwise. It resists immediately and strongly. Under ordinary gravity, a typical fabric elongates by somewhere between zero and five percent, and only under quite large loads. Cloth reaches its stretch limit fast and stays there.

This has a practical consequence for simulation. Too much stretching is a glaring visual artifact — cloth that sags like taffy looks wrong to every viewer. Too little stretching is essentially unnoticeable. The tolerance for under-stretching is effectively infinite; the tolerance for over-stretching is nearly zero.

The logical conclusion is bold: **model cloth as an infinitely stiff material in the stretch direction.** Do not try to tune a spring stiffness to match fabric; simply forbid elongation entirely.

In a force-based simulation, infinite stiffness means infinite forces and numerical explosion. In XPBD, infinite stiffness corresponds directly to **zero compliance**. A zero-compliance distance constraint enforces its target length exactly within the substep, with no spring constant to tune and no risk of explosion.

---

## Mesh Setup

A cloth mesh is a triangulated surface. Every vertex becomes a particle with a position, a previous position, a velocity, and an inverse mass. Every edge of the triangulation becomes a distance constraint at its rest length.

Particle masses are set proportional to the area of the surrounding triangles. For each triangle with area $A$, each of its three vertices receives an inverse mass contribution of $1/(A/3)$:

```k
/ Compute inverse masses for cloth from triangle mesh
/ triIds: list of (i0;i1;i2) triangles; pos: list of 3-vectors
initClothMasses: {[pos;triIds]
  n: #pos
  invM: n#0.
  {[t]
    i0:t@0; i1:t@1; i2:t@2
    e0: (pos@i1) - pos@i0
    e1: (pos@i2) - pos@i0
    A: 0.5 * vlen cross3[e0;e1]
    contrib: $[A>0.; 1.%(A%3.); 0.]
    invM:: @[@[@[invM;i0;+;contrib];i1;+;contrib];i2;+;contrib]
  } each triIds
  invM
}
```

Two corner particles are fixed in place by setting their inverse mass to zero — they act as attachment points, and the cloth hangs from them under gravity.

---

## Two Kinds of Constraints

### Stretch Constraints

Every edge in the triangulation gets a **zero-compliance distance constraint**. These enforce the rest length of each edge exactly, preventing the fabric from stretching or compressing along any triangle edge. This includes both the grid-direction edges and the diagonal edges, covering all in-plane directions simultaneously.

The rest length for each edge is the Euclidean distance between endpoint particles in the initial configuration.

### Bending Constraints

Stretch constraints alone produce cloth that can fold completely flat with zero resistance. Real fabric resists bending: it takes effort to fold crisply, and cloth naturally relaxes to a curved low-energy shape.

Bending resistance comes from pairs of adjacent triangles. When two triangles share an edge, they form a hinge. The two **non-shared** vertices (one from each triangle) move closer together or apart when the hinge bends. A distance constraint between these two opposite vertices therefore resists bending.

This is the **diagonal distance constraint** for bending. It is simple and cheap to evaluate. Its known weakness: when the cloth is already flat, the diagonal distance is at its maximum and the constraint gradient is nearly zero. For cloth that starts and remains roughly flat, this weakness is minor. A dihedral angle constraint directly measuring the angle between the two triangle normals does not share this weakness, but costs more.

The bending constraint uses a compliance parameter $\alpha$. Unlike stretch (zero compliance), bending is intentionally soft. High compliance produces floppy drapey fabric; low compliance produces stiff canvas.

---

## Finding Triangle Neighbors

To build bending constraints, we need adjacent triangle pairs. The approach is sorting an edge list:

1. Assign each edge a **global edge number**: $3i + j$ for local edge $j$ of triangle $i$.
2. Build one record per edge with sorted vertex indices and the global edge number.
3. Sort by `(id0, id1)`. Interior edges appear as consecutive duplicate pairs.
4. Scan the sorted list: when two consecutive records have the same vertex pair, they are neighbors.

```k
/ Build neighbor table for triangle mesh
/ triIds: list of (i0;i1;i2) triangles
/ Returns (stretchIds; bendIds; restLens; bendRestLens)
buildClothConstraints: {[pos;triIds;bendAlpha]
  nTris: #triIds

  / Step 1: build edge records (id0; id1; globalEdgeNr)
  edgeRecs: ,/ {[ti]
    t: triIds@ti
    {[j] [a:t@j; b:t@((j+1)mod 3)
          (a&b; a|b; 3*ti+j)]}' !3    / min,max,edgeNr
  }' !nTris

  / Step 2: sort by (id0,id1) — use grade on packed key
  nEdges: #edgeRecs
  sortKey: {[e] (e@0)*100000 + e@1}' edgeRecs
  ord: <sortKey
  sorted: edgeRecs@ord

  / Step 3: build neighbor array (globalEdgeNr → neighbor globalEdgeNr or -1)
  neighbors: nEdges*3#-1
  i: 0
  {[ii]
    e0: sorted@ii; e1: sorted@(ii+1)
    $[(e0@0)=(e1@0) & (e0@1)=(e1@1);
      [g0:e0@2; g1:e1@2
       neighbors:: @[@[neighbors;g0;:;g1];g1;:;g0]];
      0]
  }' !nEdges-1

  / Step 4: collect stretch edges (unique) and bending pairs
  stretchPairs: ?{[e] e@0,e@1}' edgeRecs    / de-duplicate
  stretchIds: {[p] (p@0; p@1)}' stretchPairs
  stretchLens: {[p] sqrt +/ ((pos@(p@0)) - pos@(p@1)) * (pos@(p@0)) - pos@(p@1)}' stretchPairs

  / Bending: collect (id2,id3) pairs from adjacent triangles
  bendPairs: ,/ {[ti]
    t: triIds@ti
    ,/ {[j]
      g: 3*ti+j; nb: neighbors@g
      $[nb<0; ();
        [ni: nb div 3; nj: nb mod 3
         nt: triIds@ni
         id2: t@((j+2)mod 3)
         id3: nt@((nj+2)mod 3)
         $[g<nb; ,(id2;id3); ()]]]   / each pair stored once
    }' !3
  }' !nTris
  bendIds: bendPairs
  bendLens: {[p] sqrt +/ ((pos@(p@0)) - pos@(p@1)) * (pos@(p@0)) - pos@(p@1)}' bendPairs

  (stretchIds; stretchLens; bendIds; bendLens)
}
```

---

## The XPBD Simulation Loop

The per-frame loop runs 15 substeps. Within each substep:

1. **Pre-solve**: apply gravity to free particles, save previous positions, integrate positions, resolve floor collisions.
2. **Solve**: all stretch constraints (zero compliance), then all bending constraints (soft compliance).
3. **Post-solve**: recover velocity from position differences.

```k
/ Helpers from ch07
vlen: {sqrt +/ x*x}
cross3: {[a;b]
  (((a@1)*(b@2))-(b@1)*(a@2)
   ((a@2)*(b@0))-(b@2)*(a@0)
   ((a@0)*(b@1))-(b@0)*(a@1))
}
dot3: {+/ x*y}

/ Cloth step: pos and vel are lists of 3-vectors; invM is float list
grav: 0. -9.81 0.
clothStep: {[sdt;invM;stretchIds;stretchLens;bendIds;bendLens;bendAlpha;pos;vel]
  n: #pos
  / Pre-solve
  vel2: {[i] $[invM@i=0.; vel@i; (vel@i)+grav*sdt]}' !n
  prevPos: pos
  pos2: {[i]
    p2: (pos@i) + (vel2@i)*sdt
    $[(p2@1)<0.; (p2@0; 0.; p2@2); p2]
  }' !n
  / Solve stretch (zero compliance)
  pos3: {[p;c]
    i:c@0; j:c@1; l0:c@2
    p0:p@i; p1:p@j
    w0:invM@i; w1:invM@j; wt:w0+w1
    $[wt=0.; p;
      [dx:p1-p0; d:vlen dx
       $[d=0.; p;
         [n:dx%d; C:d-l0; lam:C%wt
          @[@[p;i;+;n*lam*w0];j;-;n*lam*w1]]]]]
  }/ (pos2;),{[s;i] s,stretchLens@i}[stretchIds]' !#stretchIds
  / Solve bending (soft compliance)
  pos4: {[p;c]
    i:c@0; j:c@1; l0:c@2
    p0:p@i; p1:p@j
    w0:invM@i; w1:invM@j; wt:w0+w1
    alpha: bendAlpha%sdt*sdt
    $[wt=0.; p;
      [dx:p1-p0; d:vlen dx
       $[d=0.; p;
         [n:dx%d; C:d-l0; lam:C%(wt+alpha)
          @[@[p;i;+;n*lam*w0];j;-;n*lam*w1]]]]]
  }/ (pos3;),{[s;i] s,bendLens@i}[bendIds]' !#bendIds
  / Post-solve
  vel3: {[i] $[invM@i=0.; vel@i; (pos4@i - prevPos@i)%sdt]}' !n
  (pos4; vel3)
}

/ Run numSubsteps cloth substeps per frame
clothFrame: {[dt;numSubsteps;invM;stretchIds;stretchLens;bendIds;bendLens;bendAlpha;state]
  sdt: dt%numSubsteps
  {clothStep[sdt;invM;stretchIds;stretchLens;bendIds;bendLens;bendAlpha;x@0;x@1]}/ state
}
```

Both stretch and bending reduce to the same code path: the XPBD distance constraint. The only difference is the compliance value.

---

## Why Zero Compliance Works

Setting `stretchAlpha = 0` makes the denominator in the position correction simply $w_0 + w_1$. The constraint violation $C = \text{len} - L_0$ is corrected fully in a single pass. This is the position-based dynamics limit: constraints satisfied by projection, not by force.

With 15 substeps per frame, even a complex mesh of 6,000 triangles converges quickly. Each substep propagates corrections through the mesh, and by the end of the frame the cloth is effectively inextensible. The simulation remains unconditionally stable regardless of substep size because there are no spring forces — only bounded positional corrections.

---

## What the Parameters Actually Control

Once the mesh and constraints are in place, the physical character of the cloth is determined by only two things:

**Bending compliance $\alpha$**: the single free parameter. A value of zero gives stiff canvas. A value of 10 or higher gives soft drapey silk. Intermediate values cover denim and cotton. Crucially, no amount of compliance in the bending constraints can cause instability — unlike spring stiffness in explicit integrators.

**Substep count**: more substeps produce a stiffer-looking cloth. Fifteen substeps at 60 fps handles meshes of a few thousand triangles.

Everything else — stretch resistance, shear resistance, mass distribution — is determined automatically from the mesh geometry.

---

## Benchmark

```k
/ Setup: 20x20 grid cloth mesh, 400 particles, ~760 triangles
nCols: 20; nRows: 20
pos: ,/ {[row] {[col] (col%nCols; 1. - row%nRows; 0.)}' !nCols}' !nRows
/ ... build triIds, invM, constraints ...
\t clothFrame[1.%60; 15; invM; stretchIds; stretchLens; bendIds; bendLens; 1.; state]
/ → ~2ms per frame for 400 particles, 15 substeps
```

---

## Key Takeaways

- **Cloth barely stretches in reality.** Modeling it as infinitely stiff in the stretch direction is physically accurate — viewers never notice under-stretching but always notice over-stretching.
- **Zero-compliance distance constraints** implement infinite stretch stiffness within XPBD without numerical explosion.
- **Bending resistance** is a distance constraint between the two vertices not shared by a pair of adjacent triangles. One compliance scalar $\alpha$ controls the fabric's drape.
- **Triangle neighbor finding** sorts an edge list by vertex indices and scans for consecutive duplicate pairs. O(E log E), where E is the edge count.
- **Stretch and bending use the same solver** — a standard XPBD distance constraint. Bending is not a fundamentally different computation; it just applies to a different pair of particles with non-zero compliance.
- **Substepping provides convergence.** With 15 substeps per frame, corrections propagate far enough each frame for convincing inextensibility with no tuning.
- The entire cloth system has **one tunable parameter**: bending compliance.
