# Chapter 1 — A Bouncing Ball: The Foundations of Real-Time Physics

Physics simulation sounds intimidating until you realize that the physics of everyday objects — balls, cloth, water, rigid bodies — reduces to a surprisingly small set of ideas. This chapter introduces those ideas through the simplest possible program: a cannonball bouncing around a 2D box. Along the way, we will cover Newton's second law, the symplectic Euler integration method, and the technique of substepping. Every concept introduced here reappears throughout this book, so it is worth understanding them deeply before moving on.

---

## The Setup: One File, One Browser

The goal is to have something running with as little ceremony as possible. The entire simulation lives in a single HTML file — no build system, no dependencies, no installation. Drop it in a browser and it runs on any platform: desktop, tablet, or phone.

The skeleton of that file is straightforward. An HTML document has a `<canvas>` element where the scene is drawn, and a `<script>` block where the JavaScript lives. Three functions carry the simulation forward:

- `draw()` — clears the canvas and repaints the current state.
- `simulate()` — advances the physics by one time step.
- `update()` — calls `simulate()`, then `draw()`, then schedules itself to be called again via `requestAnimationFrame`.

The loop is started with a single call to `update()`. After that, the browser drives everything.

```javascript
function update() {
    simulate();
    draw();
    requestAnimationFrame(update);
}

update();
```

`requestAnimationFrame` tells the browser to call `update` before the next repaint, typically sixty times per second. This is the heartbeat of every real-time simulation in this book.

---

## Two Coordinate Systems

The canvas coordinate system has its origin at the top-left corner, with $y$ increasing downward. Physics, on the other hand, is most naturally expressed with the origin at the bottom-left and $y$ increasing upward. Mixing these up produces upside-down behavior, so we establish a clean mapping early.

The key variable is `cScale`, a pixels-per-meter factor computed so that a minimum physical width of 20 meters always fits on screen regardless of the window size:

```javascript
var simMinWidth = 20.0;
var cScale = Math.min(canvas.width, canvas.height) / simMinWidth;
var simWidth  = canvas.width  / cScale;
var simHeight = canvas.height / cScale;
```

Converting a position from simulation space to canvas space then requires only scaling for $x$ and scaling-plus-flipping for $y$:

```javascript
function cX(pos) { return pos.x * cScale; }
function cY(pos) { return canvas.height - pos.y * cScale; }
```

Everything in the physics simulation uses meters. Everything passed to the canvas API uses pixels. These two functions are the only bridge between the two worlds.

---

## Newton's Second Law

Before writing any physics code, we need one equation:

$$\mathbf{F} = m\mathbf{a}$$

Force equals mass times acceleration. This is Newton's second law, and it is the engine of classical mechanics. Rearranged, it says:

$$\mathbf{a} = \frac{\mathbf{F}}{m}$$

Acceleration is the rate of change of velocity. Velocity is the rate of change of position. A force does not move an object directly — it changes the object's velocity, and the velocity changes the position. This is why every simulated object must carry both a position and a velocity.

For our cannonball, the only force is gravity. Near the Earth's surface, gravity accelerates every object downward at the same rate regardless of mass. If you substitute the gravitational force $\mathbf{F} = m\mathbf{g}$ into Newton's second law, the mass $m$ cancels:

$$\mathbf{a} = \frac{m\mathbf{g}}{m} = \mathbf{g}$$

The gravitational acceleration $\mathbf{g}$ points straight down with a magnitude of roughly $9.8\ \text{m/s}^2$, which we round to $10\ \text{m/s}^2$ for convenience. An object in free fall that starts from rest reaches $10\ \text{m/s}$ after one second, $20\ \text{m/s}$ after two seconds, and so on.

---

## Symplectic Euler Integration

We know the acceleration. To get the velocity and position at the next moment in time, we need a *time integration method* — a recipe for stepping the simulation forward by a small interval $\Delta t$.

The simplest possible recipe says: assume the acceleration is constant over $\Delta t$, update the velocity, then use that updated velocity to move the position.

$$\mathbf{v}_{n+1} = \mathbf{v}_n + \mathbf{a}\,\Delta t$$
$$\mathbf{x}_{n+1} = \mathbf{x}_n + \mathbf{v}_{n+1}\,\Delta t$$

Notice that $\mathbf{x}_{n+1}$ uses the *new* velocity $\mathbf{v}_{n+1}$, not the old one $\mathbf{v}_n$. This is the defining feature of **symplectic Euler** integration, and it is what makes it more stable than naive (explicit) Euler, where you would use the old velocity to update the position. The difference looks small — just one line — but it determines whether energy in the simulation grows without bound or stays bounded. Symplectic Euler conserves a modified version of the total energy, which is why simulations using it do not explode.

In code:

```javascript
var gravity  = { x: 0.0, y: -10.0 };
var timeStep = 1.0 / 60.0;

function simulate() {
    ball.vel.x += gravity.x * timeStep;
    ball.vel.y += gravity.y * timeStep;
    ball.pos.x += ball.vel.x * timeStep;
    ball.pos.y += ball.vel.y * timeStep;
    // ...
}
```

Velocity is updated first, then position. The order matters.

---

## The Cannonball

The ball is a simple object with a radius, a position, and a velocity:

```javascript
var ball = {
    radius: 0.2,
    pos: { x: 0.2, y: 0.2 },
    vel: { x: 10.0, y: 15.0 }
};
```

The radius is 20 centimeters. The initial velocity launches it upward and to the right — hence the name "cannonball." Drawing it requires converting from simulation coordinates to canvas coordinates and scaling the radius by `cScale` to get the pixel radius:

```javascript
function draw() {
    c.clearRect(0, 0, canvas.width, canvas.height);
    c.fillStyle = "#FF0000";
    c.beginPath();
    c.arc(cX(ball.pos), cY(ball.pos), cScale * ball.radius, 0.0, 2.0 * Math.PI);
    c.closePath();
    c.fill();
}
```

Keeping the ball inside the window requires boundary checks after each integration step. When the ball crosses a wall, we clamp its position back to the boundary and flip the corresponding velocity component:

```javascript
if (ball.pos.x < 0.0) {
    ball.pos.x = 0.0;
    ball.vel.x = -ball.vel.x;
}
if (ball.pos.x > simWidth) {
    ball.pos.x = simWidth;
    ball.vel.x = -ball.vel.x;
}
if (ball.pos.y < 0.0) {
    ball.pos.y = 0.0;
    ball.vel.y = -ball.vel.y;
}
```

This is an elastic collision with an immovable wall: the velocity component perpendicular to the wall reverses sign, the parallel component is unchanged. There is no upper boundary check — the ball is free to fly as high as the physics allow and gravity will bring it back down.

---

## Substepping

Symplectic Euler introduces an error at every step because it assumes that both the force and the velocity are constant over $\Delta t$. For a constant force like gravity this assumption is fine, but the velocity is never actually constant — gravity is continuously changing it. The error per step is proportional to $\Delta t$, so the total accumulated error over a fixed simulation time is also proportional to $\Delta t$.

The straightforward remedy is to use a smaller time step. But the frame rate is fixed: the browser calls `update` 60 times per second, giving $\Delta t = 1/60 \approx 0.0167\ \text{s}$. We cannot slow down the clock.

The solution is **substepping**: divide each frame into $n$ substeps, each of size $\Delta t / n$, and run the integration loop $n$ times per frame.

```javascript
var numSubSteps = 10;

function simulate() {
    var sdt = timeStep / numSubSteps;
    for (var i = 0; i < numSubSteps; i++) {
        ball.vel.x += gravity.x * sdt;
        ball.vel.y += gravity.y * sdt;
        ball.pos.x += ball.vel.x * sdt;
        ball.pos.y += ball.vel.y * sdt;
        // boundary checks ...
    }
}
```

The drawing still happens once per frame. Only the physics runs faster. This technique costs proportionally more CPU time, but it is simple, predictable, and — crucially — the only reliable strategy when collisions are involved. More sophisticated integrators gain nothing over symplectic Euler the moment you add discrete collision response, because collision events break any smoothness assumptions the fancier methods depend on.

---

## Why These Choices Last

Throughout this book, more complex phenomena will be added: multiple bodies, constraints, joints, soft bodies, fluid. Yet the core loop — apply forces, integrate velocity, integrate position, resolve collisions, draw — will remain the same. Symplectic Euler with substepping is not a toy. It is the method underlying many production physics engines. Its virtues are exactly what a physics engine needs: it is simple to implement, hard to break, and fast enough that many substeps can be afforded even in real-time applications.

The cannonball is the simplest system in which all of these ideas appear together. Everything more complicated is built on this foundation.

---

## Key Takeaways

- **Newton's second law**, $\mathbf{F} = m\mathbf{a}$, is the starting point for all classical simulation. Forces change velocities; velocities change positions.
- **Gravity** accelerates all objects equally at $g \approx 10\ \text{m/s}^2$ downward, because the mass in $F = mg$ cancels with the mass in $F = ma$.
- **Symplectic Euler** updates velocity first, then uses the updated velocity to advance position. This subtle ordering makes the integrator energy-stable.
- **Substepping** runs the integration loop $n$ times per rendered frame with a time step of $\Delta t / n$. It reduces integration error proportionally to $n$ with no algorithmic complexity, and it remains effective in the presence of collisions where higher-order integrators offer no benefit.
- **Coordinate mapping** is a practical necessity: keep physics in meters with a bottom-left origin, and convert to canvas pixels only at draw time.
