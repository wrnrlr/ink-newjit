# Chapter 1 — A Bouncing Ball: The Foundations of Real-Time Physics

Physics simulation sounds intimidating until you realize that the physics of everyday objects — balls, cloth, water, rigid bodies — reduces to a surprisingly small set of ideas. This chapter introduces those ideas through the simplest possible program: a cannonball bouncing around a 2D box. Along the way, we will cover Newton's second law, the symplectic Euler integration method, and the technique of substepping. Every concept introduced here reappears throughout this book, so it is worth understanding them deeply before moving on.

---

## The Setup: One Loop, One State

The entire simulation lives in a single function that updates state and draws each frame. In ink, the `RunWindow` function from `lib/gpu/gpu.k` provides the event loop — it calls a user function each frame with window properties (width, height, mouse position), and the function draws the scene and updates physics.

The simulation's heartbeat is:

```k
step: {[s] ... }         / advance physics one frame
draw: {[props;s] ... }   / draw current state, return next state
RunWindow[draw; 0]
```

`RunWindow` calls `draw` approximately 60 times per second. This is the equivalent of `requestAnimationFrame` in a web browser.

---

## Two Coordinate Systems

The screen coordinate system has its origin at the top-left corner, with $y$ increasing downward. Physics is most naturally expressed with a bottom-left origin and $y$ increasing upward. In ink, the GPU shader handles this mapping. Physical coordinates in meters are converted to clip space $[-1, 1]$ in the vertex shader, so the physics code can work entirely in physical units.

---

## Newton's Second Law

Before writing any physics code, we need one equation:

$$\mathbf{F} = m\mathbf{a}$$

Force equals mass times acceleration. Rearranged:

$$\mathbf{a} = \frac{\mathbf{F}}{m}$$

For our cannonball, the only force is gravity. The gravitational acceleration $\mathbf{g}$ points straight down with magnitude roughly $9.8\ \text{m/s}^2$, which we round to $10\ \text{m/s}^2$ for convenience.

---

## Symplectic Euler Integration

We know the acceleration. To get the velocity and position at the next moment in time, we need a *time integration method* — a recipe for stepping the simulation forward by a small interval $\Delta t$.

The simplest recipe says: assume the acceleration is constant over $\Delta t$, update the velocity, then use that updated velocity to move the position.

$$\mathbf{v}_{n+1} = \mathbf{v}_n + \mathbf{a}\,\Delta t$$
$$\mathbf{x}_{n+1} = \mathbf{x}_n + \mathbf{v}_{n+1}\,\Delta t$$

Notice that $\mathbf{x}_{n+1}$ uses the *new* velocity $\mathbf{v}_{n+1}$, not the old one $\mathbf{v}_n$. This is **symplectic Euler** integration. The difference looks small — just one line — but it determines whether energy in the simulation grows without bound or stays bounded.

In ink, 2D vectors are represented as two-element float lists. Velocity is updated first, then position:

```k
g: 0. -10.          / gravity vector (x; y)
dt: 1.%60           / time step 1/60 s
r: 0.2              / ball radius (m)

/ Simulation bounds
w: 20.              / world width (m)
h: 15.              / world height (m)
```

---

## The Cannonball

The ball is represented as a 2-element list for position and a 2-element list for velocity. The initial velocity launches it upward and to the right:

```k
pos: 0.2 0.2        / starting position (m)
vel: 10. 15.        / initial velocity (m/s)
```

All coordinates are in meters. The radius is 20 centimeters.

---

## Boundary Collisions

Keeping the ball inside the window requires boundary checks after each integration step. When the ball crosses a wall, clamp its position back to the boundary and flip the corresponding velocity component. In array-programming style, we compute which components need to flip and apply the flip in a single vectorized step:

```k
/ Clamp position and reflect velocity at walls
lo: r, r
hi: (w-r), h-r
flip: (pos<lo) | pos>hi
vel: vel * 1. - 2.*flip
pos: lo | pos & hi
```

`lo | pos & hi` is `max(lo, min(pos, hi))` — the standard clamp. `flip` is a boolean list (1 where the ball hit a wall), and `vel * 1. - 2.*flip` flips the sign of each component that hit a boundary.

---

## Substepping

Symplectic Euler introduces an error at every step because it assumes constant force and velocity over $\Delta t$. The solution is **substepping**: divide each frame into $n$ substeps, each of size $\Delta t / n$, and run the integration loop $n$ times per frame.

```k
step: {[s]
  pos: s@0; vel: s@1
  sdt: dt%10.                          / substep size (10 substeps/frame)
  vel: vel + g*sdt
  pos: pos + vel*sdt
  lo: r, r; hi: (w-r), h-r
  flip: (pos<lo) | pos>hi
  vel: vel * 1. - 2.*flip
  pos: lo | pos & hi
  (pos; vel)
}

simulate: {[s] 10 step/ s}             / 10 substeps per frame
```

`10 step/ s` applies `step` ten times starting from state `s`, threading the result of each call as input to the next. The drawing still happens once per frame; only the physics runs faster.

---

## Complete Simulation

The full simulation integrates and bounces the ball across 600 frames (10 seconds at 60 Hz) with 10 substeps each:

```k
g: 0. -10.
dt: 1.%60
r: 0.2; w: 20.; h: 15.

step: {[s]
  pos: s@0; vel: s@1
  sdt: dt%10.
  vel: vel + g*sdt
  pos: pos + vel*sdt
  lo: r, r; hi: (w-r), h-r
  flip: (pos<lo) | pos>hi
  vel: vel * 1. - 2.*flip
  pos: lo | pos & hi
  (pos; vel)
}

/ Benchmark: 10 seconds of simulation
\t 600 {10 step/ x}/ (0.2 0.2; 10. 15.)
```

On a typical machine this runs in under 10 ms — fast enough to run physics many times per rendered frame if needed.

---

## Why These Choices Last

Throughout this book, more complex phenomena will be added: multiple bodies, constraints, joints, soft bodies, fluid. Yet the core loop — apply forces, integrate velocity, integrate position, resolve collisions — will remain the same. Symplectic Euler with substepping is not a toy. It is the method underlying many production physics engines. Its virtues are exactly what a physics engine needs: it is simple to implement, hard to break, and fast enough that many substeps can be afforded even in real-time applications.

The cannonball is the simplest system in which all of these ideas appear together. Everything more complicated is built on this foundation.

---

## Key Takeaways

- **Newton's second law**, $\mathbf{F} = m\mathbf{a}$, is the starting point for all classical simulation. Forces change velocities; velocities change positions.
- **Gravity** accelerates all objects equally at $g \approx 10\ \text{m/s}^2$ downward, because the mass in $F = mg$ cancels with the mass in $F = ma$.
- **Symplectic Euler** updates velocity first, then uses the updated velocity to advance position. This subtle ordering makes the integrator energy-stable.
- **Substepping** runs the integration loop $n$ times per rendered frame with a time step of $\Delta t / n$. It reduces integration error proportionally to $n$ with no algorithmic complexity, and it remains effective in the presence of collisions where higher-order integrators offer no benefit.
- **Array arithmetic** in ink lets boundary clamping and velocity reflection be expressed as a single vectorized operation: compute a boolean flip mask, negate the flagged components, clamp the position in one step.
