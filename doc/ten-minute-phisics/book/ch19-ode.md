# Chapter 19 — Differential Equations and the Mathematics of Change

Physics is, at its core, a theory of change. Forces change velocities; velocities change positions; temperatures change with heat flow; populations change with birth and death rates. The language in which all of this is written is the language of **differential equations** — equations whose unknowns are not just numbers, but functions, and whose constraints involve those functions and their rates of change. This chapter builds that language from first principles, derives the key mathematical constants $e$, $i$, and $\pi$ along the way, and ends with one of the most striking results in all of mathematics: that a six-line iteration on complex numbers produces geometry of infinite, self-similar complexity.

---

## Change and the Derivative

Start with a quantity $s$ that depends on time $t$. If you measure $s$ before and after some event, the **change** is:

$$\Delta s = s_{\text{after}} - s_{\text{before}}$$

The **rate of change** — how fast $s$ is moving — is that difference divided by the elapsed time:

$$\frac{\Delta s}{\Delta t}$$

When the rate of change is constant, this ratio is the same no matter which interval $\Delta t$ you choose. But when the rate of change is itself varying, the ratio depends on the size of the interval. The true instantaneous rate of change at a particular moment is obtained by letting the interval shrink toward zero:

$$s'(t) = \lim_{\Delta t \to 0} \frac{s(t + \Delta t) - s(t)}{\Delta t}$$

This is the **derivative** of $s$ with respect to $t$. The notation $s'(t)$, $\dot{s}(t)$ (a dot, used when the independent variable is time), and $\frac{ds}{dt}$ all mean the same thing. The derivative is itself a function — it tells you the slope of $s$ at every moment.

Nothing stops you from differentiating the derivative. The **second derivative** $s''(t) = \ddot{s}(t)$ describes the rate of change of the rate of change. In physics, if $s(t)$ is position, then $s'(t)$ is velocity and $s''(t)$ is acceleration. Newton's second law, $F = ma$, says that a force does not move an object directly: it changes the object's velocity, and the velocity changes the position. Everything flows through two layers of differentiation.

---

## Four Canonical Differential Equations

A **differential equation** is an equation that constrains a function and one or more of its derivatives. The unknowns are the functions themselves, not individual numbers. Four examples cover almost everything you will encounter in classical mechanics.

**Exponential growth — the rabbit equation.**

$$\dot{N}(t) = k \, N(t)$$

The rate of change of the rabbit population is proportional to the population itself. The more rabbits, the faster they breed. Because the slope is always proportional to the current value, the curve is always getting steeper (for $k > 0$), producing exponential growth. The solution is:

$$N(t) = N_0 \, e^{k(t - t_0)}$$

**Exponential decay — the coffee equation.**

$$\dot{T}(t) = -k \, T(t)$$

Here $T(t)$ is the temperature of the coffee above room temperature. The hotter the coffee, the faster it loses heat. The negative sign means the function decreases toward zero, never quite reaching it. The solution is:

$$T(t) = T_0 \, e^{-k(t - t_0)}$$

**Constant acceleration — the soccer ball.**

$$\ddot{h}(t) = -g$$

The height $h(t)$ of a ball has a second derivative equal to the constant $-g \approx -9.81\ \text{m/s}^2$. Integrating twice yields the familiar parabola:

$$h(t) = h_0 + v_0 t - \tfrac{1}{2} g t^2$$

The constants $h_0$ and $v_0$ are free parameters that encode the initial height and initial velocity. Differential equations typically have families of solutions parameterized by initial conditions, not single solutions.

**Oscillatory motion — the spring equation.**

$$\ddot{x}(t) = -\frac{k}{m} \, x(t)$$

The spring pulls back with a force proportional to the elongation $x$. Because the acceleration always opposes the displacement, the system oscillates. The solution turns out to involve cosine and sine — but explaining why requires the exponential function and imaginary numbers.

---

## The Calculus Rules

The limit definition of the derivative is exact but tedious. Working mathematicians use a small set of rules derived from it once and applied everywhere.

**Power rule.** Plugging $f(x) = x^n$ into the limit and expanding $(x + \Delta x)^n$ using the binomial theorem, all terms containing $\Delta x$ vanish in the limit, leaving only the leading term:

$$\frac{d}{dx} x^n = n \, x^{n-1}$$

**Constant multiple.** Because a constant factor can be pulled through the limit:

$$(a \, g)' = a \, g'$$

**Sum rule.** Because the limit of a sum is the sum of the limits:

$$(f_1 + f_2)' = f_1' + f_2'$$

**Polynomials.** Combining these three rules, every polynomial differentiates term by term:

$$(a_0 + a_1 x + a_2 x^2 + a_3 x^3 + \cdots)' = a_1 + 2a_2 x + 3a_3 x^2 + \cdots$$

The constant term disappears, each remaining term drops one power, and the exponent multiplies in as a coefficient.

---

## The Exponential Function and the Constant $e$

The rabbit and coffee equations require a function whose derivative is proportional to itself. Can such a function exist? For the special case $k = 1$, we need:

$$f'(x) = f(x)$$

No power $x^n$ works — differentiation reduces the exponent by one, so no single power can reproduce itself. What if we try an infinite polynomial? If $f(x) = a_0 + a_1 x + a_2 x^2 + \cdots$, the requirement $f' = f$ forces the coefficients to satisfy $a_1 = a_0$, $2a_2 = a_1$, $3a_3 = a_2$, and in general:

$$a_n = \frac{a_{n-1}}{n}$$

Choosing $a_0 = 1$ (so that $f(0) = 1$) gives:

$$f(x) = \sum_{n=0}^{\infty} \frac{x^n}{n!} = 1 + x + \frac{x^2}{2!} + \frac{x^3}{3!} + \cdots$$

This series converges for all $x$ — after $n > 2x$, each successive term is smaller than half the previous one, so the tail is bounded by a geometric series.

It turns out this polynomial is the same function as $e^x$, where $e$ is the unique constant for which the derivative of $e^x$ is itself. Plugging $x = 1$:

$$e = 1 + 1 + \frac{1}{2!} + \frac{1}{3!} + \cdots \approx 2.71828\ldots$$

Equivalently, $e = \lim_{n \to \infty}\left(1 + \frac{1}{n}\right)^n$. This formula captures the same tension that makes $e$ feel strange: the base approaches $1$ (which would give $1^\infty = 1$) while the exponent grows without bound (which would give $1^{\infty} = \infty$ for any base greater than $1$). These two forces exactly balance at $e \approx 2.718$.

The generalization follows immediately from the series: replacing $x$ with $ax$ gives:

$$\frac{d}{dx} e^{ax} = a \, e^{ax}$$

This is exactly what the rabbit and coffee equations need.

---

## The Maclaurin Series

The polynomial construction generalizes far beyond $e^x$. Any sufficiently smooth function $f$ can be recovered from its derivatives at a single point, say $x = 0$:

$$f(x) = \sum_{n=0}^{\infty} \frac{f^{(n)}(0)}{n!} \, x^n$$

This is the **Maclaurin series** (a special case of the Taylor series centered at zero). It says something remarkable: knowing the value of a function and all of its derivatives at a single point is enough to reconstruct the entire function everywhere. The local information at one point encodes the global shape.

---

## Imaginary Numbers and the Spring

To solve the spring equation $\ddot{x} = -(k/m)\, x$, try $x(t) = e^{at}$. Differentiating twice gives $\ddot{x} = a^2 e^{at}$, so the equation requires:

$$a^2 = -\frac{k}{m}$$

For $k/m > 0$, there is no real number $a$ satisfying this. The square root of a negative number does not exist on the real line. Rather than declare the spring equation unsolvable — which conflicts with the obvious physical reality that springs oscillate — we extend our number system by defining:

$$i = \sqrt{-1}, \qquad i^2 = -1$$

The number $i$ is called the **imaginary unit**. A **complex number** is any expression $a + bi$ where $a$ and $b$ are real. Complex numbers add component-wise and multiply using $i^2 = -1$:

$$(a_1 + b_1 i)(a_2 + b_2 i) = (a_1 a_2 - b_1 b_2) + (a_1 b_2 + b_1 a_2)i$$

Geometrically, complex numbers live in a plane: the horizontal axis is the real part, the vertical axis is the imaginary part. Multiplying by $i$ rotates a number by $90°$ counterclockwise. Multiplying by $i$ twice — that is, multiplying by $i^2 = -1$ — rotates by $180°$. The powers of $i$ cycle: $1,\ i,\ -1,\ -i,\ 1,\ i,\ \ldots$

Now plug $a = i\sqrt{k/m}$ back into $e^{at}$. The solution to the spring equation is $e^{i\sqrt{k/m}\,t}$. But what does this mean geometrically?

---

## Euler's Formula

Substituting $ix$ into the Maclaurin series for $e^x$ and grouping real and imaginary terms by the cycling powers of $i$:

$$e^{ix} = \left(1 - \frac{x^2}{2!} + \frac{x^4}{4!} - \cdots\right) + i\left(x - \frac{x^3}{3!} + \frac{x^5}{5!} - \cdots\right)$$

The two series in parentheses are exactly the Maclaurin series for $\cos x$ and $\sin x$, which can be derived independently from the geometry of a point moving at unit speed around the unit circle. (The derivative of $\cos$ is $-\sin$, and the derivative of $\sin$ is $\cos$, from which their series follow immediately.) The identification gives:

$$\boxed{e^{ix} = \cos x + i \sin x}$$

This is **Euler's formula**. It says that $e^{ix}$ traces the unit circle in the complex plane as $x$ increases. The angle swept is $x$ radians.

The spring equation's solution now reads:

$$x(t) = e^{i\omega t} = \cos(\omega t) + i\sin(\omega t), \qquad \omega = \sqrt{k/m}$$

The real part, $\cos(\omega t)$, is the physically observed oscillation. The system oscillates at angular frequency $\omega = \sqrt{k/m}$, exactly the behavior anyone who has played with a spring has seen.

Setting $x = \pi$ in Euler's formula yields:

$$e^{i\pi} = -1$$

Three of the most fundamental constants in mathematics — $e$, $i$, and $\pi$ — are connected by this single equation.

---

## Julia Sets: A Bonus in the Complex Plane

The complex plane is not just a tool for differential equations. It is a playground with unexpected structure. Consider the following iteration, where both $z$ and $c$ are complex numbers:

$$z_{n+1} = z_n^2 + c$$

Start with some initial $z_0$ and apply this rule repeatedly. For some starting points, the orbit $z_0, z_1, z_2, \ldots$ remains bounded; for others, it escapes to infinity. The boundary between these two behaviors — the set of starting points whose orbits are neither converging to zero nor flying off to infinity — is the **Julia set** for a fixed constant $c$.

Using the polar form $z = r e^{i\phi}$, squaring gives $z^2 = r^2 e^{2i\phi}$: the radius is squared and the angle is doubled. When $r > 1$, repeated squaring makes $r$ grow without bound. When $r < 1$, it shrinks to zero. The unit circle $r = 1$ is therefore the natural boundary. A useful escape criterion: once $|z|^2 = z_1^2 + z_2^2 > 4$, the orbit is guaranteed to diverge.

In code, the inner loop is eight arithmetic operations on real numbers, exploiting the fact that for $z = (x_1, x_2)$:

$$(x_1 + x_2 i)^2 = (x_1^2 - x_2^2) + (2 x_1 x_2) i$$

```javascript
function getNumIters(x1, x2, c1, c2, maxIters) {
    for (var iters = 0; iters < maxIters; iters++) {
        if (x1 * x1 + x2 * x2 > 4.0)
            return iters;
        var x = x1;
        x1 = x1 * x1 - x2 * x2 + c1;
        x2 = 2.0 * x * x2 + c2;
    }
    return maxIters;
}
```

Map each pixel to a point in the complex plane, call this function, and color the pixel by how many iterations elapsed before escape. When $c = 0$, the boundary is exactly the unit circle. As $c$ moves away from zero, the boundary deforms — and the deformation is not a simple translation or scaling. It fractures into intricate, self-similar filaments that repeat at every level of magnification. The resulting images are **Julia sets**.

A closely related object, the **Mandelbrot set**, is obtained by fixing $z_0 = 0$ and varying $c$ instead: a point $c$ belongs to the Mandelbrot set if and only if the orbit starting at zero does not diverge. Every point on the boundary of the Mandelbrot set is the parameter for which the corresponding Julia set transitions from connected to dust.

Both structures are infinitely complex. Zoom into any region of the boundary and new patterns emerge, forever. All of this emerges from six lines of code and one equation: $z_{n+1} = z_n^2 + c$.

---

## Key Takeaways

- **Differential equations** constrain functions through their derivatives. They are the unavoidable mathematical language of physics, because forces act on accelerations, not positions.
- **The derivative** at a point is the limit of the average rate of change over an interval as the interval shrinks to zero: $f'(x) = \lim_{\Delta x \to 0}[f(x + \Delta x) - f(x)]/\Delta x$. The power, constant-multiple, and sum rules derive from this single definition.
- **The exponential function** $e^x$ is the unique function equal to its own derivative with $e^0 = 1$. It solves exponential growth and decay equations. Its Maclaurin series $\sum x^n/n!$ converges for all $x$.
- **Imaginary numbers** arise naturally when solving the spring equation. Extending the reals to the complex plane — adding $i = \sqrt{-1}$ — is not a trick but a necessity: the real line is simply too small.
- **Euler's formula** $e^{ix} = \cos x + i\sin x$ unifies the exponential and trigonometric functions. It explains why oscillators have sinusoidal solutions and connects $e$, $i$, and $\pi$ in a single equation.
- **Julia sets** demonstrate that simple iterations on the complex plane produce geometry of unbounded complexity. The boundary between convergent and divergent orbits under $z \mapsto z^2 + c$ is a fractal whose structure repeats at every scale.
