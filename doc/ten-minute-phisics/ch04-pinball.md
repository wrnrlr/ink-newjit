# Chapter 4 — Pinball: Collision with Geometry

A ball bouncing between two other balls is interesting physics. A ball bouncing around a pinball machine — ricocheting off bumpers, skidding along curved walls, launched skyward by a flipper rotating at speed — is a small world. This chapter builds that world. Along the way we encounter two ideas that recur throughout rigid-body simulation: reducing complex geometry to simpler primitives, and computing the velocity of a moving surface at the exact point of contact.

The simulation introduced here is deliberately stripped of fancy graphics. The geometry is a closed polygon border, a handful of circular obstacles (bumpers), and two flippers represented as capsule shapes. Two steel balls enter play at once. The physics is 2D, the time step is fixed at 1/60 s, and the whole thing runs in roughly 200 lines of JavaScript.

---

## The Core Geometric Primitive: Closest Point on a Segment

Almost every collision in this chapter reduces to the same geometric question: given a point P and a line segment AB, what is the closest point on AB to P?

Define the vector **ab** = B − A. Any point on the infinite line through A and B can be written as A + t·**ab** for some scalar t. When t = 0 we are at A; when t = 1 we are at B. The value of t that places us closest to P is the projection of (P − A) onto **ab**, divided by the squared length of **ab**:

```
t = dot(P − A, ab) / dot(ab, ab)
```

Notice that the unit vector does not appear. Because **ab** shows up in both numerator and denominator, normalization cancels out. We only need to guard against the degenerate case where A and B coincide (making the denominator zero), in which case the closest point is simply A.

For a segment (not an infinite line) we clamp t to [0, 1], which forces the result to the nearest endpoint when the projection falls outside the segment:

```javascript
function closestPointOnSegment(p, a, b) {
    var ab = new Vector2();
    ab.subtractVectors(b, a);
    var t = ab.dot(ab);
    if (t == 0.0)
        return a.clone();
    t = Math.max(0.0, Math.min(1.0, (p.dot(ab) - a.dot(ab)) / t));
    var closest = a.clone();
    return closest.add(ab, t);
}
```

This function is used twice: once to find the contact point between the ball and a flipper, and once to find which segment of the boundary polygon is closest to the ball.

---

## The Perp Operator

A second small but essential piece of mathematics is the perpendicular operator. Given a 2D vector **v** = (x, y), its 90-degree counterclockwise rotation is:

```
perp(v) = (−y, x)
```

This operator converts a radial displacement into a tangential velocity direction, which is exactly what we need when computing how fast a rotating flipper's surface is moving.

```javascript
perp() {
    return new Vector2(-this.y, this.x);
}
```

---

## Capsule Shapes and the Flipper

A capsule is the Minkowski sum of a line segment and a disk: the set of all points within radius r of a segment AB. Visually it looks like a rectangle with semicircular caps. Flippers are represented as capsules because the shape naturally models their rounded ends and their solid body.

Collision between a ball (center P, radius r_b) and a capsule (axis AB, radius r_c) reduces directly to ball-ball collision. Find the closest point C on AB to the ball center P. Then treat the capsule as a ball of radius r_c centered at C, and apply the same overlap-correction and velocity-update logic used for ball-ball contact.

The `Flipper` class stores the pivot point (pos), the arm length, a rest angle, and the maximum rotation from rest. Two additional quantities govern motion: a fixed angular speed and the current rotation accumulated since simulation start. The sign field (±1) distinguishes the left flipper from the right.

```javascript
class Flipper {
    constructor(radius, pos, length, restAngle, maxRotation,
            angularVelocity, restitution) {
        this.radius = radius;
        this.pos = pos.clone();
        this.length = length;
        this.restAngle = restAngle;
        this.maxRotation = Math.abs(maxRotation);
        this.sign = Math.sign(maxRotation);
        this.angularVelocity = angularVelocity;
        this.rotation = 0.0;
        this.currentAngularVelocity = 0.0;
        this.touchIdentifier = -1;
    }
    ...
}
```

Each frame, the flipper's `simulate` method either increases or decreases the accumulated rotation angle depending on whether it is currently pressed, then records the resulting angular velocity by finite difference:

```javascript
simulate(dt) {
    var prevRotation = this.rotation;
    var pressed = this.touchIdentifier >= 0;
    if (pressed)
        this.rotation = Math.min(this.rotation + dt * this.angularVelocity,
            this.maxRotation);
    else
        this.rotation = Math.max(this.rotation - dt * this.angularVelocity, 0.0);
    this.currentAngularVelocity = this.sign * (this.rotation - prevRotation) / dt;
}
```

The tip position (point B of the capsule axis) is computed on demand from the current angle:

```javascript
getTip() {
    var angle = this.restAngle + this.sign * this.rotation;
    var dir = new Vector2(Math.cos(angle), Math.sin(angle));
    var tip = this.pos.clone();
    return tip.add(dir, this.length);
}
```

---

## Ball–Flipper Collision

The contact velocity of a rotating body at a point is the key calculation that makes flippers feel like flippers rather than walls. For a rigid body rotating about a fixed pivot with angular velocity ω, every point at displacement **r** from the pivot moves with velocity:

```
v_contact = ω · perp(r)
```

This comes directly from differentiating the rotation: if a point traces a circle of radius |**r**|, its instantaneous velocity is tangent to that circle (i.e., perpendicular to **r**) with magnitude ω·|**r**|.

In the collision handler, after pushing the ball out of penetration, we compute this surface velocity and use it to replace the ball's velocity component along the contact normal:

```javascript
function handleBallFlipperCollision(ball, flipper) {
    var closest = closestPointOnSegment(ball.pos, flipper.pos, flipper.getTip());
    var dir = new Vector2();
    dir.subtractVectors(ball.pos, closest);
    var d = dir.length();
    if (d == 0.0 || d > ball.radius + flipper.radius)
        return;

    dir.scale(1.0 / d);

    // push ball out of penetration
    var corr = (ball.radius + flipper.radius - d);
    ball.pos.add(dir, corr);

    // compute contact velocity of flipper surface
    var radius = closest.clone();
    radius.add(dir, flipper.radius);
    radius.subtract(flipper.pos);
    var surfaceVel = radius.perp();
    surfaceVel.scale(flipper.currentAngularVelocity);

    // replace ball's normal velocity component with flipper's
    var v = ball.vel.dot(dir);
    var vnew = surfaceVel.dot(dir);
    ball.vel.add(dir, vnew - v);
}
```

The restitution of the ball is set to zero in this simulation, meaning the ball takes on exactly the flipper's surface velocity along the normal. This is a deliberate simplification: it makes flippers feel predictably powerful without introducing numerical instability from large velocity impulses.

---

## Ball–Bumper Collision

Circular obstacles (bumpers) do not move, so their collision response is simpler. The ball is pushed out along the line connecting the two centers, and its normal velocity is replaced by a fixed `pushVel` regardless of incoming speed. This gives bumpers their characteristic active-repulsion feeling — they always kick the ball away at the same speed, which is how real pinball bumpers work:

```javascript
function handleBallObstacleCollision(ball, obstacle) {
    var dir = new Vector2();
    dir.subtractVectors(ball.pos, obstacle.pos);
    var d = dir.length();
    if (d == 0.0 || d > ball.radius + obstacle.radius)
        return;

    dir.scale(1.0 / d);

    var corr = ball.radius + obstacle.radius - d;
    ball.pos.add(dir, corr);

    var v = ball.vel.dot(dir);
    ball.vel.add(dir, obstacle.pushVel - v);

    physicsScene.score++;
}
```

Each contact increments the score, which is the game mechanic.

---

## Ball–Border Collision

The playfield boundary is a closed polygon defined by a list of vertices in counterclockwise order. Handling a ball against a polygon wall involves two steps.

**Step 1: Find the nearest segment.** Iterate over all edges, compute the closest point on each segment to the ball center, and keep track of the minimum distance. Also record the inward normal of the winning segment — this is the segment direction rotated 90 degrees counterclockwise (since the boundary winds counterclockwise, this points into the playfield).

**Step 2: Push out and reflect.** Normally the ball sits just inside the boundary and the contact normal points inward. But at high speeds or large time steps, the ball's center can cross to the outside of a segment. Without a check, the code would push it further outward. The inward normal catches this: if the displacement from the closest point to the ball center points *opposite* to the inward normal, we negate the correction:

```javascript
if (d.dot(normal) >= 0.0) {
    if (dist > ball.radius)
        return;
    ball.pos.add(d, ball.radius - dist);
}
else
    ball.pos.add(d, -(dist + ball.radius));
```

The velocity update applies restitution — unlike bumpers, the walls are passive surfaces, so the ball bounces with energy loss proportional to `ball.restitution`.

This segment-search strategy handles sharp corners gracefully. At a corner, the closest point on one of the two adjacent segments is the shared vertex, so the ball is pushed away from the vertex point itself rather than along either wall direction. This is the same reason capsule shapes work so well: routing collision through a closest-point query automatically handles endpoint geometry.

---

## User Input: Touch and Mouse

The game maps physical touches (on mobile) and mouse clicks (on desktop) to flipper activation. Each touch carries a unique numeric identifier. When a touch lands within a flipper's radius from its pivot, that identifier is stored on the flipper. The flipper remains active until the identifier disappears from the touch list:

```javascript
function onTouchStart(event) {
    for (var i = 0; i < event.touches.length; i++) {
        var touch = event.touches[i];
        var rect = canvas.getBoundingClientRect();
        var touchPos = new Vector2(
            (touch.clientX - rect.left) / cScale,
            simHeight - (touch.clientY - rect.top) / cScale);

        for (var j = 0; j < physicsScene.flippers.length; j++) {
            var flipper = physicsScene.flippers[j];
            if (flipper.select(touchPos))
                flipper.touchIdentifier = touch.identifier;
        }
    }
}
```

Mouse events do not carry multi-touch identifiers, so mouse clicks simply use the constant 0. The two flippers can be operated simultaneously on a touchscreen (one finger per side), but only one at a time with a mouse.

---

## Simulation Loop

Each frame the main `simulate` function runs in a fixed order: first advance the flippers, then for each ball apply gravity, detect and resolve all pairwise collisions, then check against obstacles, flippers, and the border. The order matters because the flippers' angular velocity — used in the contact velocity calculation — must be current before any ball-flipper collision is processed.

```javascript
function simulate() {
    for (var i = 0; i < physicsScene.flippers.length; i++)
        physicsScene.flippers[i].simulate(physicsScene.dt);

    for (var i = 0; i < physicsScene.balls.length; i++) {
        var ball = physicsScene.balls[i];
        ball.simulate(physicsScene.dt, physicsScene.gravity);

        for (var j = i + 1; j < physicsScene.balls.length; j++)
            handleBallBallCollision(ball, physicsScene.balls[j]);

        for (var j = 0; j < physicsScene.obstacles.length; j++)
            handleBallObstacleCollision(ball, physicsScene.obstacles[j]);

        for (var j = 0; j < physicsScene.flippers.length; j++)
            handleBallFlipperCollision(ball, physicsScene.flippers[j]);

        handleBallBorderCollision(ball, physicsScene.border);
    }
}
```

The outer ball loop uses `i + 1` for the inner loop to ensure each pair is tested exactly once.

---

## Key Takeaways

- **Closest-point queries unify collision geometry.** Ball vs. capsule, ball vs. polygon wall, ball vs. circular bumper — all resolve to: find the nearest surface point, measure penetration depth, push apart, update velocity. Once you have `closestPointOnSegment`, most cases follow the same template.

- **The perp operator converts rotation into velocity.** For any point on a rotating body at displacement **r** from the pivot, the instantaneous surface velocity is ω·perp(**r**). This is the bridge between the angular world (angles, angular velocity) and the linear world (positions, linear velocity).

- **Clamping t to [0, 1] handles endpoints for free.** When the closest point on an infinite line falls outside the segment, clamping snaps it to the nearest endpoint. This is why the same function handles both the flat body of the flipper and its rounded tip — no special cases required.

- **Inward normals guard against tunneling at walls.** Checking whether the push direction agrees with the boundary's inward normal catches the rare but important case where a fast-moving ball crosses through a wall in a single time step.

- **Touch identifiers allow independent multi-finger control.** Assigning a touch's unique ID to a specific flipper and tracking it through `touchend` events lets two fingers operate two flippers independently — the correct interaction model for mobile pinball.
