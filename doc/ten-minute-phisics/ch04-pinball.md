# Chapter 4 — Pinball: Collision with Geometry

A ball bouncing between two other balls is interesting physics. A ball bouncing around a pinball machine — ricocheting off bumpers, skidding along curved walls, launched skyward by a flipper rotating at speed — is a small world. This chapter builds that world. Along the way we encounter two ideas that recur throughout rigid-body simulation: reducing complex geometry to simpler primitives, and computing the velocity of a moving surface at the exact point of contact.

---

## The Core Geometric Primitive: Closest Point on a Segment

Almost every collision in this chapter reduces to the same geometric question: given a point P and a line segment AB, what is the closest point on AB to P?

Define the vector **ab** = B − A. Any point on the segment can be written as A + t·**ab** for some scalar $t \in [0, 1]$. The value of $t$ that places us closest to P is:

$$t = \text{clamp}\!\left(\frac{(P - A) \cdot \mathbf{ab}}{|\mathbf{ab}|^2}, 0, 1\right)$$

In ink, 2D points are pairs of scalars. The function returns the closest point as `(cx; cy)`:

```k
/ Closest point on segment (ax,ay)-(bx,by) to point (px,py)
closestPtSeg: {[px;py;ax;ay;bx;by]
  abx: bx-ax; aby: by-ay
  t2: (abx*abx) + aby*aby
  t: $[t2=0.; 0.; 0.|1.&((px-ax)*abx+(py-ay)*aby)%t2]
  (ax+t*abx; ay+t*aby)
}
```

`0.|1.&expr` is `max(0, min(1, expr))` — the clamp to $[0,1]$. This handles the degenerate case where A = B (zero-length segment) and automatically snaps to endpoints for projections outside the segment.

---

## The Perp Operator

A second small but essential piece of mathematics is the perpendicular operator. Given a 2D vector $(x, y)$, its 90-degree counterclockwise rotation is $(-y, x)$:

```k
/ Perp of 2D vector (vx; vy) → (-vy; vx)
perp2: {[vx;vy] (-vy; vx)}
```

This operator converts a radial displacement into a tangential velocity direction, which is exactly what we need when computing how fast a rotating flipper's surface is moving.

---

## Capsule Shapes and the Flipper

A capsule is the Minkowski sum of a line segment and a disk: the set of all points within radius $r$ of a segment AB. Visually it looks like a rectangle with semicircular caps. Flippers are represented as capsules because the shape naturally models their rounded ends and solid body.

Collision between a ball (center P, radius $r_b$) and a capsule (axis AB, radius $r_c$) reduces directly to ball-ball collision. Find the closest point C on AB to the ball center P. Then treat the capsule as a ball of radius $r_c$ centered at C.

A flipper's state is: pivot position, arm length, rest angle, current rotation, angular velocity, and sign (±1 for left/right). Each frame the rotation angle advances or retreats depending on whether the flipper is pressed:

```k
/ Update flipper rotation. State: (rot; omega; pressed; sign; maxRot; angVel)
flipperStep: {[s;dt]
  rot:s@0; sign:s@3; maxRot:s@4; angVel:s@5
  pressed: s@2
  prevRot: rot
  rot: $[pressed; 0.|maxRot&rot+dt*angVel; 0.|rot-dt*angVel]
  omega: sign*(rot-prevRot)%dt
  (@[s;0;:;rot]; @[s;1;:;omega])
}
```

The tip position (point B of the capsule axis) is computed on demand from the current angle:

```k
/ Get flipper tip from (pivx; pivy; restAngle; sign; rot; length)
flipperTip: {[f]
  angle: (f@2) + (f@3)*(f@4)
  (f@0 + (f@5)*cos angle; f@1 + (f@5)*sin angle)
}
```

---

## Ball–Flipper Collision

The contact velocity of a rotating body at a point is the key calculation that makes flippers feel like flippers rather than walls. For a rigid body rotating about a fixed pivot with angular velocity $\omega$, every point at displacement $\mathbf{r}$ from the pivot moves with velocity:

$$\mathbf{v}_{\text{contact}} = \omega \cdot \text{perp}(\mathbf{r})$$

In the collision handler, after pushing the ball out of penetration, we compute this surface velocity and use it to replace the ball's velocity component along the contact normal:

```k
/ Ball-flipper collision. Returns updated (bpx;bpy;bvx;bvy).
ballFlipperCol: {[bpx;bpy;bvx;bvy;br;f]
  / f: (pivx;pivy;restAngle;sign;rot;length;radius;omega)
  pivx:f@0; pivy:f@1; fr:f@6; omega:f@7
  tip: flipperTip[f]
  cp: closestPtSeg[bpx;bpy;pivx;pivy;tip@0;tip@1]
  cx:cp@0; cy:cp@1
  dx: bpx-cx; dy: bpy-cy
  d: sqrt (dx*dx)+dy*dy
  minD: br+fr
  $[d<0.0001|d>minD;
    (bpx;bpy;bvx;bvy);
    [nx:dx%d; ny:dy%d
     / Push ball out of penetration
     bpx2: bpx + nx*(minD-d)
     bpy2: bpy + ny*(minD-d)
     / Contact point radius from pivot
     rx: (cx+nx*fr)-pivx; ry: (cy+ny*fr)-pivy
     / Surface velocity: omega * perp(r)
     svx: -ry*omega; svy: rx*omega
     / Replace normal velocity component
     vn: (nx*bvx)+ny*bvy
     svn: (nx*svx)+ny*svy
     (bpx2; bpy2; bvx+nx*(svn-vn); bvy+ny*(svn-vn))]]
}
```

The restitution of the ball is set to zero in this simulation, meaning the ball takes on exactly the flipper's surface velocity along the normal. This makes flippers feel predictably powerful without introducing numerical instability.

---

## Ball–Bumper Collision

Circular obstacles (bumpers) do not move, so their collision response is simpler. The ball is pushed out along the line connecting the two centers, and its normal velocity is replaced by a fixed `pushVel` regardless of incoming speed. This gives bumpers their characteristic active-repulsion feeling:

```k
/ Ball-bumper collision. Returns updated (bpx;bpy;bvx;bvy; score).
ballBumperCol: {[bpx;bpy;bvx;bvy;br;score;ob]
  / ob: (ox;oy;or;pushVel)
  ox:ob@0; oy:ob@1; obr:ob@2; pushVel:ob@3
  dx:bpx-ox; dy:bpy-oy
  d: sqrt (dx*dx)+dy*dy
  minD: br+obr
  $[d<0.0001|d>minD;
    (bpx;bpy;bvx;bvy;score);
    [nx:dx%d; ny:dy%d
     bpx2: bpx + nx*(minD-d)
     bpy2: bpy + ny*(minD-d)
     vn: (nx*bvx)+ny*bvy
     (bpx2; bpy2; bvx+nx*(pushVel-vn); bvy+ny*(pushVel-vn); score+1)]]
}
```

Each contact increments the score, which is the game mechanic.

---

## Ball–Border Collision

The playfield boundary is a closed polygon defined by a list of vertices in counterclockwise order. Handling a ball against a polygon wall involves two steps:

1. **Find the nearest segment.** For each edge, find the closest point on the segment to the ball center and keep the one with minimum distance.
2. **Push out and reflect.** Use the inward normal to distinguish the "inside" case (push out slightly) from the "tunneled through" case (push from the other side).

```k
/ Ball vs polygon border. Border stored as flat list: x0 y0 x1 y1 ...
ballBorderCol: {[bpx;bpy;bvx;bvy;br;border;e]
  n: #border
  / Find closest segment
  i: e*2
  ax: border@i; ay: border@(i+1)
  bi: ((i+2) mod n); bx: border@bi; by: border@(bi+1)
  cp: closestPtSeg[bpx;bpy;ax;ay;bx;by]
  dx: bpx-(cp@0); dy: bpy-(cp@1)
  d: sqrt (dx*dx)+dy*dy
  / Inward normal: rotate edge direction 90° CCW
  ex: bx-ax; ey: by-ay
  nx: -ey; ny: ex              / perp of edge = inward normal
  nl: sqrt (nx*nx)+ny*ny
  nx: nx%nl; ny: ny%nl
  / Dot to check side
  side: (nx*dx)+ny*dy
  $[side>=0.;
    $[d>br; (bpx;bpy;bvx;bvy);
      [c: br-d
       (bpx+nx*c; bpy+ny*c; bvx-2.*(nx*bvx+ny*bvy)*nx; bvy-2.*(nx*bvx+ny*bvy)*ny)]];
    [c: d+br
     (bpx-nx*c; bpy-ny*c; bvx-2.*(nx*bvx+ny*bvy)*nx; bvy-2.*(nx*bvx+ny*bvy)*ny)]]
}
```

---

## Simulation Loop

Each frame: advance the flippers, then for each ball apply gravity, detect and resolve all pairwise collisions, obstacles, flipper, and border:

```k
/ All collision pairs for n balls
pairs: {[n] a:!n*n; ri:a div n; ci:a mod n; k:&ri<ci; +(ri@k;ci@k)}

simulate: {[scene;dt]
  / 1. Update flippers
  / 2. Integrate each ball under gravity
  / 3. Ball-ball collisions (via collidePair fold)
  / 4. Ball-bumper collisions
  / 5. Ball-flipper collisions
  / 6. Ball-border collision
  scene
}
```

The order matters: the flippers' angular velocity must be current before any ball-flipper collision is processed.

---

## Key Takeaways

- **Closest-point queries unify collision geometry.** Ball vs. capsule, ball vs. polygon wall, ball vs. circular bumper — all resolve to: find the nearest surface point, measure penetration depth, push apart, update velocity.
- **The perp operator** converts rotation into velocity: $\mathbf{v}_{\text{contact}} = \omega \cdot \text{perp}(\mathbf{r})$.
- **Clamping $t$ to $[0, 1]$** handles endpoints for free. `0.|1.&expr` is the idiomatic ink clamp.
- **Inward normals guard against tunneling at walls.** Checking whether the push direction agrees with the boundary's inward normal catches the rare but important case where a fast-moving ball crosses through a wall in a single time step.
