# Chapter 19 — Differential Equations and the Mathematics of Change

Physics is, at its core, a theory of change. Forces change velocities; velocities change positions; temperatures change with heat flow. The language in which all of this is written is the language of **differential equations** — equations whose unknowns are functions, and whose constraints involve those functions and their rates of change. This chapter builds that language from first principles, derives the key mathematical constants $e$, $i$, and $\pi$ along the way, and ends with one of the most striking results in mathematics: that a six-line iteration on complex numbers produces geometry of infinite, self-similar complexity.

---

## Change and the Derivative

Start with a quantity $s$ that depends on time $t$. The **rate of change** — how fast $s$ is moving — is the difference divided by the elapsed time:

$$\frac{\Delta s}{\Delta t}$$

The true instantaneous rate of change at a particular moment is the limit as the interval shrinks toward zero:

$$s'(t) = \lim_{\Delta t \to 0} \frac{s(t + \Delta t) - s(t)}{\Delta t}$$

This is the **derivative** of $s$ with respect to $t$. If $s(t)$ is position, then $s'(t)$ is velocity and $s''(t)$ is acceleration. Newton's second law, $F = ma$, says a force changes velocity, and velocity changes position — everything flows through two layers of differentiation.

---

## Four Canonical Differential Equations

**Exponential growth** (rabbit equation): $\dot{N} = k N$. The more rabbits, the faster they breed. Solution: $N(t) = N_0 e^{k(t-t_0)}$.

**Exponential decay** (coffee equation): $\dot{T} = -k T$. The hotter the coffee, the faster it loses heat. Solution: $T(t) = T_0 e^{-k(t-t_0)}$.

**Constant acceleration** (soccer ball): $\ddot{h} = -g$. Solution: $h(t) = h_0 + v_0 t - \tfrac{1}{2}g t^2$.

**Oscillatory motion** (spring equation): $\ddot{x} = -(k/m) x$. The spring pulls back proportional to elongation. Solution involves cosine and sine — explained below.

---

## The Calculus Rules

Three rules derived from the limit definition cover almost everything:

- **Power rule**: $(x^n)' = n x^{n-1}$
- **Constant multiple**: $(a g)' = a g'$
- **Sum rule**: $(f_1 + f_2)' = f_1' + f_2'$

Polynomials differentiate term-by-term from these three.

---

## The Exponential Function and $e$

The rabbit equation needs a function whose derivative is proportional to itself. For $k = 1$, we need $f'(x) = f(x)$. No power $x^n$ works — differentiation reduces the exponent. Try an infinite polynomial $f(x) = \sum a_n x^n$. The requirement $f' = f$ forces $a_n = a_{n-1}/n$. Choosing $a_0 = 1$:

$$f(x) = \sum_{n=0}^{\infty} \frac{x^n}{n!} = 1 + x + \frac{x^2}{2!} + \frac{x^3}{3!} + \cdots = e^x$$

This series converges for all $x$. In ink, we can evaluate the partial sum directly:

```k
/ Taylor series for e^x (N terms)
expSeries: {[x;N]
  +/ {[n] (x xexp n) % (prd 1+!n)}' !N
}

/ More idiomatically: unfold with term accumulation
exp_: {[x]
  / Compute until next term < epsilon
  terms: {[t;n] t*x%(n+1)}\ 1., !30
  +/ terms
}

expSeries[1.; 20]    / → ~2.71828...
expSeries[0.; 5]     / → 1.0
expSeries[-1.; 30]   / → ~0.36788... = 1/e
```

The constant $e = \sum 1/n! \approx 2.71828\ldots$

---

## The Maclaurin Series

Any sufficiently smooth function can be recovered from its derivatives at a single point:

$$f(x) = \sum_{n=0}^{\infty} \frac{f^{(n)}(0)}{n!} x^n$$

This says that knowing all derivatives at one point encodes the entire global shape. The series for $e^x$, $\cos x$, and $\sin x$:

$$e^x = \sum \frac{x^n}{n!}, \qquad \cos x = \sum \frac{(-1)^n x^{2n}}{(2n)!}, \qquad \sin x = \sum \frac{(-1)^n x^{2n+1}}{(2n+1)!}$$

In ink:

```k
/ Cosine via Maclaurin series (N terms)
cosSeries: {[x;N]
  +/ {[n] (neg 1. xexp n) * (x xexp 2*n) % prd 1+!2*n}' !N
}

/ Sine via Maclaurin series
sinSeries: {[x;N]
  +/ {[n] (neg 1. xexp n) * (x xexp 1+2*n) % prd 1+!1+2*n}' !N
}

cosSeries[3.14159; 10]   / → ~-1.0
sinSeries[1.5708; 10]    / → ~1.0
```

---

## Imaginary Numbers and Euler's Formula

To solve the spring equation $\ddot{x} = -(k/m) x$, try $x(t) = e^{at}$. Differentiating twice gives $a^2 e^{at}$, requiring $a^2 = -k/m$. There is no real number satisfying this. We extend the reals by defining $i = \sqrt{-1}$, $i^2 = -1$.

A complex number $a + bi$ lives in a plane: real part on the horizontal axis, imaginary part on the vertical axis. Multiplying by $i$ rotates 90° counterclockwise.

In ink, represent complex numbers as 2-element float lists `(re; im)`:

```k
/ Complex number arithmetic
cmul: {[a;b] ((a@0)*(b@0) - (a@1)*(b@1); ((a@0)*(b@1)) + (a@1)*(b@0))}
cadd: {x+y}          / element-wise
cabs2: {+/ x*x}      / |z|² = re²+im²
cabs: {sqrt +/ x*x}
```

Substituting $ix$ into the Maclaurin series for $e^x$ and grouping real/imaginary terms:

$$e^{ix} = \left(1 - \frac{x^2}{2!} + \cdots\right) + i\left(x - \frac{x^3}{3!} + \cdots\right) = \cos x + i\sin x$$

**Euler's formula**: $e^{ix} = \cos x + i\sin x$. It says that $e^{ix}$ traces the unit circle as $x$ increases. Setting $x = \pi$:

$$e^{i\pi} = -1$$

Three of the most fundamental constants — $e$, $i$, and $\pi$ — are connected by this single equation.

```k
/ Euler's formula: e^{i*x} = (cos x, sin x)
euler: {[x] (cos x; sin x)}

euler[0.]        / → (1.0; 0.0)
euler[3.14159]   / → (-1.0; ~0.0)
euler[1.5708]    / → (~0.0; 1.0)
```

The spring equation's solution $x(t) = e^{i\omega t}$ has real part $\cos(\omega t)$ — the physically observed oscillation at angular frequency $\omega = \sqrt{k/m}$.

---

## Julia Sets

The complex plane is not just a tool for differential equations — it is a playground with unexpected structure. Consider the iteration:

$$z_{n+1} = z_n^2 + c$$

where both $z$ and $c$ are complex numbers. For some starting points $z_0$, the orbit $z_0, z_1, z_2, \ldots$ remains bounded; for others, it escapes to infinity. The boundary between these behaviors is the **Julia set** for a fixed constant $c$.

The escape criterion: once $|z|^2 > 4$, the orbit is guaranteed to diverge.

```k
/ Iterate z → z² + c, return escape iteration count (or maxIters if bounded)
juliaIter: {[z;c;maxIters]
  {[state]
    z:state@0; n:state@1
    $[n>=maxIters | (+/z*z)>4.; state;
      [(z2: cmul[z;z]; (z2+c; n+1))]]
  }/ (z; 0)
}

/ Escape count for one pixel at complex position z with parameter c
juliaEscape: {[z;c;maxIters] (juliaIter[z;c;maxIters])@1}

/ Map a grid of pixels to Julia escape counts
/ w,h: pixel dimensions; re0,re1,im0,im1: complex plane bounds; c: Julia parameter
juliaGrid: {[w;h;re0;re1;im0;im1;c;maxIters]
  {[py]
    im: im0 + (im1-im0)*py%h
    {[px]
      re: re0 + (re1-re0)*px%w
      juliaEscape[(re;im); c; maxIters]
    }' !w
  }' !h
}

/ Render Julia set for c = (-0.4, 0.6)
c: -0.4 0.6
grid: juliaGrid[80; 40; -1.5; 1.5; -1.; 1.; c; 50]
/ grid@y@x = iteration count (0=fast escape, 50=bounded)
```

When $c = 0$ the boundary is exactly the unit circle. As $c$ moves away from zero, the boundary fractures into intricate, self-similar filaments that repeat at every level of magnification — **Julia sets**.

A closely related object, the **Mandelbrot set**, fixes $z_0 = 0$ and varies $c$: a point $c$ belongs to the set if the orbit from zero does not diverge.

```k
/ Mandelbrot escape count for parameter c
mandelbrot: {[c;maxIters]
  z: 0. 0.
  {[state]
    z:state@0; n:state@1
    $[n>=maxIters | (+/z*z)>4.; state;
      [(cmul[z;z]+c; n+1)]]
  }/ (z; 0)
  (juliaIter[0. 0.; c; maxIters])@1
}

/ Both structures emerge from six lines of code and one equation: z → z² + c
```

The iteration body is eight arithmetic operations on two real numbers (squaring and adding a complex number):

```k
/ Complex squaring: (x+yi)² = (x²-y²) + 2xy·i
csq: {[z] ((z@0)*(z@0) - (z@1)*(z@1); 2. * (z@0) * z@1)}
```

Both structures are infinitely complex. Zoom into any region of the boundary and new patterns emerge, forever. All of this emerges from one equation.

---

## Numerical Integration Review

The chapters ahead use these ODE integration schemes repeatedly:

```k
/ Explicit (forward) Euler: x(t+dt) ≈ x(t) + dt * f(x,t)
/ Unstable for stiff equations — good for conceptual examples
eulerStep: {[x;f;dt] x + dt*f[x]}

/ Symplectic Euler: update velocity first, then position (used throughout this book)
/ Stable for conservative systems (mass-spring, rigid body, XPBD)
symplecticStep: {[x;v;f;dt]
  v2: v + dt*f[x]
  x2: x + dt*v2
  (x2; v2)
}

/ Second-order Runge-Kutta (midpoint method): more accurate than Euler
rk2Step: {[x;f;dt]
  k1: f[x]
  k2: f[x + 0.5*dt*k1]
  x + dt*k2
}

/ Fourth-order Runge-Kutta: standard choice when accuracy matters
rk4Step: {[x;f;dt]
  k1: f[x]
  k2: f[x + 0.5*dt*k1]
  k3: f[x + 0.5*dt*k2]
  k4: f[x + dt*k3]
  x + (dt%6.) * (k1 + (2.*k2) + (2.*k3) + k4)
}
```

For physics simulation with position-based dynamics (XPBD), symplectic Euler gives the best trade-off: it conserves energy (unlike pure forward Euler) and is trivial to implement. RK4 is appropriate when high temporal accuracy is needed, such as ODE integration for orbital mechanics or rigid body dynamics over long time intervals.

---

## Key Takeaways

- **Differential equations** constrain functions through their derivatives. They are the unavoidable mathematical language of physics.
- **The derivative** $f'(x) = \lim_{\Delta x \to 0}[f(x+\Delta x) - f(x)]/\Delta x$ is the instantaneous rate of change. Power, constant-multiple, and sum rules derive from this definition.
- **The exponential function** $e^x = \sum x^n/n!$ is the unique function equal to its own derivative with $e^0 = 1$. It solves exponential growth and decay.
- **Imaginary numbers** arise naturally from the spring equation. Extending the reals to the complex plane — adding $i = \sqrt{-1}$ — is a necessity, not a trick.
- **Euler's formula** $e^{ix} = \cos x + i\sin x$ unifies the exponential and trigonometric functions. It explains why oscillators have sinusoidal solutions.
- **Julia sets** demonstrate that simple complex-plane iterations produce geometry of unbounded complexity. The boundary under $z \mapsto z^2 + c$ is a fractal whose structure repeats at every scale.
- In ink, **complex numbers** are 2-element float lists `(re; im)`. All operations — multiplication, addition, magnitude — are simple expressions using element indexing and `+/ x*x` for squared magnitude.
