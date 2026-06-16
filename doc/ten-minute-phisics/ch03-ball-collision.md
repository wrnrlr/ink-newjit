# Chapter 3 — Ball Collision Handling in 2D

Two balls rolling toward each other must bounce. That sentence hides a surprising amount of physics and linear algebra. This chapter builds a complete 2D billiard simulation from scratch: we derive the collision response equations, introduce just enough vector mathematics to handle the 2D case cleanly, and then implement a working multi-ball simulator in a handful of functions. By the end you will have a reusable pattern for circle–circle collision that applies equally well to particles, projectiles, and rigid discs.

---

## The Physics of a Collision

When two balls collide, deformations propagate through the material and generate repulsive forces that drive the objects apart. For stiff bodies this happens over an extremely short time interval, so short that it is impractical to integrate the forces directly. Instead we jump straight to the result: we compute the post-collision velocities using a pair of equations derived from the conservation of momentum and the coefficient of restitution.

For a 1D collision between balls with masses $m_1$, $m_2$ and pre-collision speeds $v_1$, $v_2$, the post-collision speeds are:

$$v_1' = \frac{m_1 v_1 + m_2 v_2 - m_2 (v_1 - v_2)\,e}{m_1 + m_2}$$

$$v_2' = \frac{m_1 v_1 + m_2 v_2 - m_1 (v_2 - v_1)\,e}{m_1 + m_2}$$

The scalar $e$ is the **coefficient of restitution**. When $e = 1$ the collision is perfectly elastic: kinetic energy is conserved and the balls bounce away at full speed. When $e = 0$ the collision is completely inelastic: the balls stick together and move as one. Any value in between models the energy loss that occurs in real materials.

These formulas handle 1D, but billiard balls move in 2D. The key insight is that only the velocity component along the line connecting the two centres is affected by the collision — the perpendicular component passes through unchanged. Vector mathematics gives us a clean way to isolate that component.

---

## Vector Mathematics

A 2D vector $\mathbf{v} = [v_x,\, v_y]$ is an arrow in the plane. We need four operations.

**Scaling** multiplies every component by a scalar $s$:

$$s\,\mathbf{v} = [s\,v_x,\; s\,v_y]$$

This is how we scale a velocity by the time step $\Delta t$ to obtain a displacement.

**Addition** combines two vectors component-wise. Advancing a position $\mathbf{x}$ by velocity $\mathbf{v}$ over time $\Delta t$ is simply:

$$\mathbf{x} \leftarrow \mathbf{x} + \Delta t\,\mathbf{v}$$

**Length** follows from the Pythagorean theorem:

$$|\mathbf{v}| = \sqrt{v_x^2 + v_y^2}$$

**Normalization** produces a unit vector pointing in the same direction:

$$\hat{\mathbf{v}} = \frac{\mathbf{v}}{|\mathbf{v}|}$$

The most important operation for collision handling is the **dot product**:

$$\mathbf{a} \cdot \mathbf{b} = a_x b_x + a_y b_y$$

If $\hat{\mathbf{n}}$ is a unit vector, then $\mathbf{v} \cdot \hat{\mathbf{n}}$ is the **scalar projection** of $\mathbf{v}$ onto $\hat{\mathbf{n}}$ — the signed length of $\mathbf{v}$'s shadow along the direction $\hat{\mathbf{n}}$. This single number is exactly the $v$ that appears in the 1D formulas above. Everything else in the velocity is perpendicular to the collision axis and remains untouched.

---

## Detecting a Collision

Two circles of radii $r_1$ and $r_2$ overlap whenever the distance between their centres is less than $r_1 + r_2$. Computing that distance is straightforward:

```javascript
var dir = new Vector2();
dir.subtractVectors(ball2.pos, ball1.pos);   // vector from centre 1 to centre 2
var d = dir.length();
if (d == 0.0 || d > ball1.radius + ball2.radius)
    return;   // no collision
```

The `dir` vector points from ball 1 toward ball 2. Its length $d$ is the centre-to-centre distance. If $d > r_1 + r_2$ the balls are not touching. If $d = 0$ the centres coincide — a degenerate case we skip to avoid a divide-by-zero later.

---

## Resolving the Overlap

When a collision is detected, the balls are already interpenetrating by an amount:

$$\delta = (r_1 + r_2) - d$$

If we simply update the velocities and move on, the balls drift further into each other over successive frames. The standard fix is **positional correction**: push each ball half the overlap distance along the collision normal before updating velocities.

```javascript
dir.scale(1.0 / d);   // normalize: dir is now the unit collision normal n̂

var corr = (ball1.radius + ball2.radius - d) / 2.0;
ball1.pos.add(dir, -corr);   // push ball 1 away
ball2.pos.add(dir,  corr);   // push ball 2 away
```

After this step the balls are exactly touching but no longer overlapping, and we are ready to compute new velocities.

---

## Computing the Collision Response

With the unit normal $\hat{\mathbf{n}}$ in hand, we project both velocities onto it:

```javascript
var v1 = ball1.vel.dot(dir);   // scalar projection of vel1 onto n̂
var v2 = ball2.vel.dot(dir);   // scalar projection of vel2 onto n̂
```

These two scalars are exactly the $v_1$ and $v_2$ that appear in the 1D formulas. Plugging in the masses and the restitution:

```javascript
var m1 = ball1.mass;
var m2 = ball2.mass;

var newV1 = (m1 * v1 + m2 * v2 - m2 * (v1 - v2) * restitution) / (m1 + m2);
var newV2 = (m1 * v1 + m2 * v2 - m1 * (v2 - v1) * restitution) / (m1 + m2);
```

The change in the normal component of each ball's velocity is $\Delta v_1 = v_1' - v_1$ and $\Delta v_2 = v_2' - v_2$. We apply these changes as vector impulses along $\hat{\mathbf{n}}$:

```javascript
ball1.vel.add(dir, newV1 - v1);
ball2.vel.add(dir, newV2 - v2);
```

The `add(v, s)` method computes `this += s * v`, so this adds $\Delta v_1 \hat{\mathbf{n}}$ to ball 1's velocity and $\Delta v_2 \hat{\mathbf{n}}$ to ball 2's velocity. The perpendicular components are untouched — they were never projected out and they never needed to be.

Collecting everything into the complete function:

```javascript
function handleBallCollision(ball1, ball2, restitution) {
    var dir = new Vector2();
    dir.subtractVectors(ball2.pos, ball1.pos);
    var d = dir.length();
    if (d == 0.0 || d > ball1.radius + ball2.radius)
        return;

    dir.scale(1.0 / d);

    var corr = (ball1.radius + ball2.radius - d) / 2.0;
    ball1.pos.add(dir, -corr);
    ball2.pos.add(dir,  corr);

    var v1 = ball1.vel.dot(dir);
    var v2 = ball2.vel.dot(dir);

    var m1 = ball1.mass;
    var m2 = ball2.mass;

    var newV1 = (m1 * v1 + m2 * v2 - m2 * (v1 - v2) * restitution) / (m1 + m2);
    var newV2 = (m1 * v1 + m2 * v2 - m1 * (v2 - v1) * restitution) / (m1 + m2);

    ball1.vel.add(dir, newV1 - v1);
    ball2.vel.add(dir, newV2 - v2);
}
```

---

## Wall Collisions

Boundary collisions are simpler. The world is an axis-aligned rectangle, so each wall has a normal aligned with one coordinate axis. We clamp the position to the boundary and flip the corresponding velocity component:

```javascript
function handleWallCollision(ball, worldSize) {
    if (ball.pos.x < ball.radius) {
        ball.pos.x = ball.radius;
        ball.vel.x = -ball.vel.x;
    }
    if (ball.pos.x > worldSize.x - ball.radius) {
        ball.pos.x = worldSize.x - ball.radius;
        ball.vel.x = -ball.vel.x;
    }
    if (ball.pos.y < ball.radius) {
        ball.pos.y = ball.radius;
        ball.vel.y = -ball.vel.y;
    }
    if (ball.pos.y > worldSize.y - ball.radius) {
        ball.pos.y = worldSize.y - ball.radius;
        ball.vel.y = -ball.vel.y;
    }
}
```

This is a special case of the general impulse formula with $e = 1$ and an infinitely massive wall ($m_2 \to \infty$), which reduces to reflecting the normal velocity component and leaving the tangential component unchanged.

---

## The Simulation Loop

Each frame, we advance every ball under gravity, check it against every other ball, and then clamp it to the walls:

```javascript
function simulate() {
    for (var i = 0; i < physicsScene.balls.length; i++) {
        var ball1 = physicsScene.balls[i];
        ball1.simulate(physicsScene.dt, physicsScene.gravity);

        for (var j = i + 1; j < physicsScene.balls.length; j++) {
            var ball2 = physicsScene.balls[j];
            handleBallCollision(ball1, ball2, physicsScene.restitution);
        }

        handleWallCollision(ball1, physicsScene.worldSize);
    }
}
```

The inner loop starts at `j = i + 1` so each pair is checked exactly once. With $N$ balls this is $O(N^2)$ work per frame — manageable for tens of balls, but it becomes the bottleneck as the count grows into the hundreds. Spatial hashing (covered in a later chapter) reduces the average cost dramatically by only testing balls that are nearby.

Ball mass is set proportional to area, $m = \pi r^2$, which matches the uniform-density assumption. A heavier ball will deflect a lighter one more strongly, and the momentum formulas handle the asymmetry correctly.

---

## Controlling Elasticity

Exposing the restitution as a runtime parameter is instructive. Setting $e = 0$ makes every collision completely inelastic: balls clump and slow down until kinetic energy is visibly drained from the system. Setting $e = 1$ conserves energy and the scene remains lively indefinitely. Values between 0 and 1 model real rubber, wood, or steel.

```javascript
document.getElementById("restitutionSlider").oninput = function() {
    physicsScene.restitution = this.value / 10.0;
}
```

Watching the simulation drain at $e = 0$ also demonstrates an important correctness check: positions are corrected but no energy is injected, so the only source of energy loss is the restitution factor itself.

---

## Key Takeaways

- **Overlap detection** for two circles requires only a distance comparison: $d < r_1 + r_2$.
- **Positional correction** pushes balls apart by the overlap amount before updating velocities, preventing penetration from accumulating over time.
- **The dot product** reduces the 2D collision to a 1D problem by projecting velocities onto the collision normal $\hat{\mathbf{n}}$.
- **The 1D impulse formulas** give the new normal-direction speeds directly from masses, pre-collision speeds, and the coefficient of restitution $e$.
- **Only the normal component** of each velocity changes; the tangential component is unaffected by a frictionless collision.
- **Wall collisions** are the degenerate case of an infinitely massive second body: clamp the position and flip the relevant velocity component.
- **Naive pair-testing** is $O(N^2)$ and sufficient for small scenes; spatial hashing is the standard upgrade for larger ones.
