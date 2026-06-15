# Chapter 19 — Differential Equations and Calculus from Scratch

**Video:** https://youtu.be/asiFbvRKgRk
**Slides:** https://matthias-research.github.io/pages/tenMinutePhysics/19-ODE.pdf
**Code:** https://raw.githubusercontent.com/matthias-research/pages/master/tenMinutePhysics/19-julia.html

## Lecture Notes

### Core Idea

Physics is about *change*. Forces change velocities; velocities describe the change of positions. **Differential equations** — equations with functions and their derivatives as unknowns — are required to describe this mathematically. They are the foundation of all physics simulation.

---

### Notation

| Symbol | Meaning |
|--------|---------|
| s(t) | position at time t |
| ṡ(t) = s'(t) | first derivative — velocity |
| s̈(t) = s''(t) | second derivative — acceleration |
| Δx = x_after − x_before | difference |

Rate of change: Δs/Δt (slope of the s-t graph). For non-constant rates:

f'(x) = lim_{Δx→0} [f(x + Δx) − f(x)] / Δx   (the derivative)

---

### Four Canonical ODEs

**Rabbit equation** (exponential growth): Ṅ(t) = k · N(t)

Solution: N(t) = N₀ · e^{k(t−t₀)}

**Coffee equation** (exponential decay): Ṫ(t) = −k · T(t)

Solution: T(t) = T₀ · e^{−k(t−t₀)}

**Soccer ball** (constant acceleration): ḧ(t) = −g

Solution: h(t) = h₀ + v₀t − ½gt²

**Spring equation**: ẍ(t) = −(k/m) · x(t)

Solution: x(t) = a · sin(√(k/m)·t) + b · cos(√(k/m)·t)

---

### Calculus Rules (derived from the limit definition)

- Constant: f(x) = a → f'(x) = 0
- Identity: f(x) = x → f'(x) = 1
- **Power rule**: f(x) = xⁿ → f'(x) = n · xⁿ⁻¹
- **Constant multiple**: (a·g)' = a·g'
- **Sum rule**: (f₁ + f₂)' = f₁' + f₂'
- **Polynomial**: (a₀ + a₁x + a₂x² + …)' = a₁ + 2a₂x + 3a₃x² + …

---

### The Exponential e and Euler's Formula

e is defined so that (eˣ)' = eˣ:

e = lim_{n→∞} (1 + 1/n)ⁿ ≈ 2.71828…

Maclaurin series: eˣ = Σ_{n=0}^∞ xⁿ/n!

Generalization: (e^{ax})' = a · e^{ax}

For the spring equation, plugging x(t) = e^{it} reveals that we need the imaginary number **i = √(−1)**. Expanding e^{ix} via the Maclaurin series and using i² = −1, i³ = −i, i⁴ = 1, … gives:

**Euler's formula**: e^{ix} = cos(x) + i · sin(x)

This explains why the spring equation has sinusoidal solutions.

---

### Taylor / Maclaurin Series

Any analytic function can be recovered from its derivatives at zero:

a_n = f^{(n)}(0) / n!    →    f(x) = Σ_{n=0}^∞ [f^{(n)}(0)/n!] · xⁿ

**Bonus — Julia and Mandelbrot sets**: iterating z_{i+1} = z_i² + c in the complex plane produces fractal boundaries. The filled set (bounded orbits) is the Julia set for fixed c; varying c gives the Mandelbrot set.


## Video Transcript

Hi, Marcus from 10 Minute Physics here. Welcome to this new tutorial. I'm very excited about this tutorial because it gives me the opportunity to show you the beauty and elegance of math. I had the idea for this tutorial many years ago, but now finally created it. The idea is to start with basic algebra and then derive in one train of thought, not just calculus, but also differential equations and the mathematical constants e, i, and pi.

And in the end, the most beautiful and mind-blowing mathematical structure I know. The idea of the tutorial is to keep it self-contained in that I will derive all the concepts we need as we go. You might not be able to follow all the derivations in detail when watching the video for the first time, but don't worry, you will still understand the main ideas. For a detailed study, I will also provide the slides. So, sit back, relax, and enjoy the beauty and elegance of mathematics.

Just before we start, I want to apologize because this video is now 70 minutes long, much longer than what the name of my channel says. So, I apologize and I promise that future videos will be around 10 minutes again. So, now let's start. Let me start with a very simple concept, the concept of change. Physics is all about change.

Forces change velocities, and velocities describe the change of positions. Without change in a static world, there would be no physics at all. It is said that Newton found out how forces change velocities by looking at an apple falling from a tree. How do we measure change? Let's assume we have a quantity x.

We measure it before an event and after an event. The change delta x is then simply x after minus x before. We use the Greek letter delta for difference. Let me give you two very simple examples. Let's assume we want to compute how much time passes from 1:00 p.m.

to 5:00 p.m. We simply compute 5 minus 1, which is 4 hours. Here is Newton's example. I call the position of the apple on the tree p before and on the ground p after. These are two vectors.

We can now compute the change in position delta p as p after minus p before, which is also a vector. In physics, we are typically interested in processes, not in single events. Therefore, we're more interested in the rate of change. The rate of change is a change with respect to another quantity, most often time in physics. We can visualize the rate of change in two-dimensional diagrams.

Here is the example of speed. We have the distance on the y-axis and time passes from left to right on the x-axis. As you can see, as time passes, the distance increases. A faster car travels a longer distance within the same amount of time than a slower car. As you can see, the rate of change corresponds to the slope of this line.

Here is another example that does not involve time. Here, we look at the efficiency of an engine. On the y-axis, we have the distance traveled and on the x-axis, the amount of gas consumed. With a more efficient engine, we can travel a longer distance with the same amount of gas than with a less efficient engine. So, in general, the rate of change is proportional to the slope.

How do we measure the rate of change? Here's a simple example. We have a car that travels straight up the y-axis. Time passes from left to right on the x-axis. The trajectory of the car is only a diagonal in the space-time diagram.

In space alone, the car travels straight up the y-axis. To measure the rate of change, we first choose a time interval delta t. We then measure the distance the car traveled during this time interval and we call it delta s. The rate of change is then simply delta s divided by delta t. Since we have time on the x-axis, the rate of change corresponds to the velocity of the car.

This definition of the rate of change makes sense because it's constant for a uniform rate of change. For instance, a car that travels 50 km in half an hour has the same speed as a car that travels 200 km in 2 hours. Both have a velocity of 100 km/h. In this diagram, you can either choose delta t1 and delta s1 or delta t2 and delta s2 and always get the same rate of change. Now, what if the car drives backwards?

Well, then s decreases. This means delta s becomes negative. The rate of change also becomes negative. This means a negative rate of change corresponds to a decrease. But what if the rate of change is not constant?

What if the rate of change changes over time? Here's our car example again. As before, we have the distance traveled along the y-axis and time passes from left to right along the x-axis. But now, the trajectory of the car is not a straight line anymore in the space-time diagram. It's a curve.

Therefore, we need the function that tells us how far the car has traveled at time t. We call this function s of t. As you can see, the slope of this curve is not constant. At this point, the rate of change is smaller than at this point. Therefore, we can describe the rate of change with another function.

I call it s' of t. It describes the rate of change of the function s at time t. This function is called the derivative of s. Since we have time on the x-axis, it corresponds to the velocity of the car. If we have time on the x-axis, we also use the dot character for the derivative, but both are okay.

Now, let's have a look at s'. At this point, it is zero, which means the rate of change of s is zero, so it's a flat curve. Then, the rate of change increases. Here, we have a maximum of the rate of change, so this is also the point where s is steepest. Then, the rate of change decreases, which means the slope of s decreases as well.

At this point, we have the maximum of the derivative s', which means at this point, we have the maximal rate of change or the maximal slope of s. In physics, we are also interested in the rate of change of the rate of change. Don't worry, this is as complicated as it will get. As before, we have the function s of t, which is the position of the car at time t. As before, we have s', which is the slope of s or the derivative of s.

In our case, it's also the velocity of the car. But now, we have s''. s'' describes the slope of s'. While s' is the first derivative of s, we call s'' the second derivative of s. When s'' is positive, then the slope of s' is positive, which means s' increases.

This also means that the slope or the rate of change of s increases, which means s is bent upwards or has a positive curvature. When s'' is zero, then the rate of change of s' is zero, which means s' is flat. This means the rate of change of s doesn't change. In other words, s is a straight line. Here, s'' is negative.

This means the slope of s' is negative, which means s' decreases. This also means that the rate of change of s decreases. Therefore, s is bent downwards and the curvature is negative. According to Newton's second law, the force is proportional to the acceleration. This means the force is proportional to s''.

Here, the driver hits the gas, so the velocity increases and the car accelerates. At this point, she releases the gas and the velocity stays constant. This means the car travels at a constant velocity. At this point, she hits the brake. This means the velocity decreases and the car decelerates.

At this point, she releases the brake, which means the car travels at a constant velocity. Here, she hits the gas again, the velocity increases, and the car accelerates. The cool thing is that we already know enough to understand differential equations. Differential equations are equations with functions and their derivatives as unknowns. They are so important because they are required to describe physics mathematically.

They are the basis for all physical simulations. Let me give you four examples. We start with a rabbit equation. Here, we use a function n of t, which is the number of rabbits at time t. And this is our differential equation.

What does it say? It says that the derivative of n or the rate of change of n is proportional to n itself. Here, k is a constant. This means the rate of increase of the number of rabbits is proportional to the number of rabbits. This makes sense.

The more rabbits, the more births. We can guess how the solution will look like. In this diagram, we have n, the number of rabbits, along the y-axis. Time passes from left to right in months along the x-axis. For this example, I chose k equals 1/2.

So, let's assume we start with 10 rabbits. According to our differential equation, n' is 5. This means the rate of change is five rabbits per month. This also means the number of rabbits increases. At a certain point, we reach 20 rabbits.

According to our differential equation, the rate of change is now 10 rabbits per month. This means the curve gets steeper. So, as n increases, the rate of change increases as well. What you see here is exponential growth. Here's our second example, the coffee equation.

Now we work with a function capital T of T, which is the temperature of the coffee at the time T. And this is our differential equation. It says that the rate of change of the temperature is proportional to the temperature itself. Again, K is a constant, but now we have a negative sign here. So the equation says that the rate of decrease of the temperature is proportional to the temperature.

In other words, the hotter the coffee, the faster it cools down. Again, we can guess how the solution will look like. Now we have the temperature in degrees above room temperature along the Y axis. As before, we have time from left to right on the X axis, now in minutes. Let's assume the temperature of the coffee is 80° above room temperature at time T equals 0.

For this example, I chose 1/8 for K. So according to our differential equation, the rate of change T dot in the beginning is minus 10° per minute. This means that the temperature decreases. When the coffee's temperature hits 40° above room temperature, then T dot is minus 5° per minute. So as you can see, the slope gets smaller and smaller.

In theory, the temperature never reaches zero. What you see here is exponential decrease. This is our third example, the soccer equation. Now we have a function H of T, which tells us the height of the ball at time T. And this is our differential equation.

It says that the second derivative of H is minus G, where G is a constant. In other words, the acceleration of the ball is minus G. G is the gravitational acceleration on the surface of the Earth. It's the same for all objects. Its value is about 9.81 m/s².

This unit tells us that this is an acceleration. The velocity increases by 9.81 m/s in each second. In other words, gravity pulls the velocity downwards. Again, we can guess how the solution will look like. Here we have the height of the ball along the Y axis and time again passes from left to right.

We know that H double dot is a flat line at the position minus G. Therefore, H dot needs to be a straight line with a constant negative rate of change. We can move this line up and down without changing its rate of change. I will talk about this degree of freedom later. Now let's guess how H itself will look like.

We have another degree of freedom. We can choose the height of the ball at time equals 0. Let's assume the height is zero at the beginning. H dot tells us that the rate of change is positive at this point. However, as time passes, the rate of change gets smaller and smaller.

Therefore, H is bent downwards. At this point in time, the rate of change of H is zero. This is the maximum height the ball reaches. After this point, the rate of change of H becomes negative, so H decreases. What you see here is a parabola.

It's the trajectory of a free flying object without air resistance. So here's our fourth and last example, the spring equation. Now we have a spring with an attached weight. We use X T as the elongation of the spring at time T. And this is our differential equation.

It says that the second derivative X double dot is proportional to X. The constant in this case is composed of two constants. K is the stiffness of the spring and M is the mass of the attached weight. The most important part of this equation is this minus sign here. This says that the weight is always accelerated against the elongation.

And this is how I derived this equation. I first took Newton's second law F equals M A. A is the acceleration, so in our case it's X double dot. Then I substituted the spring force. The spring force is proportional to the elongation, but points in the opposite direction.

In this example, I chose zero gravity and a zero rest length of the spring. One last time, we can guess the solution. Here I have the elongation X along the Y axis and again time passes from left to right. Let's assume the elongation of the spring is one at the beginning. For the constant of proportionality, I chose one in this case.

So we have this very simple equation X double dot equals minus X. In the beginning, X is one, so X double dot is minus one. This means X is bent downwards. At this point, X is zero, so X double dot is also zero. This means X is a straight line.

After this point, X becomes negative. This means X double dot becomes positive and X is bent upwards. Then X hits zero again, so X double dot is also zero and X is a straight line. After this, X becomes positive, so X double dot becomes negative and X is bent downwards. What you see here is the cosine function.

It's the shape we expect from the elongation of a bouncing spring. After we guessed all the solutions, I will now show you how to solve differential equations mathematically. For this, we need to be able to measure a changing rate of change. This is a very important slide. Let me first go back to the simple case where the rate of change is constant.

In this case, the trajectory of the car was a straight line. We chose time interval delta T and measured how far the car traveled during this time interval. Then the rate of change was simply delta S divided by delta T. We can choose any delta T and always get the same result. This is because the rate of change is constant.

But now we look at the general case. This time we have F of X along the Y axis and X along the X axis, but this of course doesn't matter. What we want is to compute the rate of change of F of X at position X. As before, we choose an interval delta X. Then we want to measure how much F changes during this interval delta X, which we call delta F.

An estimate of the rate of change is then delta F divided by delta X. Now how can we compute delta F? For this, we evaluate F at position X and at position X plus delta X. Delta F is then simply F at position X plus delta X minus F at position X. So as an estimate for the rate of change, we can use F at X plus delta X minus F of X divided by delta X.

This is a very important formula. However, it's only an approximation of the derivative of F at position X. As you can see, this estimate depends on delta X. For this delta X, we get as an estimate the rate of change of this straight line here. Of course, this is not the correct result.

What you can see is while we decrease delta X, our estimate gets better and better. So we get the true result when we set delta X to zero. However, when we do that, we get F of X minus F of X divided by zero, which is zero divided by zero, which of course is nonsense. Since derivatives are essential to describe physical phenomena, it was very important for mathematicians to find a solution to this problem. Finding a solution spawned an entirely new branch of mathematics.

It's called calculus. Calculus was invented by Isaac Newton and Gottfried Leibniz. Their idea was to introduce an infinitely small but non-zero difference. They called it differential. So far you used the Greek letter delta for difference.

For differential, we use the Latin lower case letter D. Differentials give differential equations their name. However, they're strange quantity. For instance, what's the value of DX plus DX? What's the sum of two infinitely small quantities?

Differentials are still used today mathematics, but in a non-rigorous way, just as notation. The correct way to solve the problem is to use a limit. So this is how we compute the derivative of F at position X. What you can see is the formula we used to approximate this value, F at the position X plus delta X minus F at the position X divided by delta X. The only difference is this limit here.

It tells us that the instantaneous rate of change is the estimated rate of change as delta X approaches but never reaches zero. The cool thing is that this equation is all you need to know to understand and derive all of calculus. It is quite tedious to use this limit to compute derivatives of functions. This is why people use so-called rules. Let me start with a very simple rule.

We have the function F of X equals A, where A is a constant. If you find the derivative of this function, we simply plug it into our limit. F of X plus delta X is A. F of X is A as well, so we have A minus A divided by delta X. Now for any delta X except zero, this is a clean zero.

If we set delta X to zero, then we get zero over zero, which is the original problem. But now we never go all the way to zero, so this is a clean zero and we get a clean zero for the derivative of F of X equals A. This makes sense. A constant function has a zero rate of change. Here's another very simple example, F of X equals X.

Let's plug this function into our limit. F of X plus delta X is simply X plus delta X. F of X is simply X. So in the numerator, we get X plus delta X minus X, which is delta X. This expression is a clean one for all delta X except zero.

Since we never go all the way to zero, we get a clean one for this derivative. Now we look at a very important rule, the power rule. It's called the power rule because we look at the powers of n. Here n is a constant. It's also a very powerful rule.

So, what is the derivative of X to the power of n? We simply plug it into our limit. F at X plus delta X is now X plus delta X to the power of n. F at X is X to the power of n. Now let's write out this expression here.

It's X plus delta X times X plus delta X and so on n times. And at the end we get minus X to the power of n. Now let's expand this expression here. For this we get the terms X to the power of n, X to the power of n minus one delta X, X to the power of n minus two squared and so on. Now what we need to know is how many times these terms appear.

It's the number of times we can create them from these multipliers here. To create X to the power of n we pick X in all the multipliers. For this term we pick delta X in one of these multipliers and X in all the others. There's n ways we can do this. We don't care about how many times these terms appear.

We just call the coefficients A2, A3, and so on. What we immediately see is that X to the power of n cancels. Now we have to divide all these terms by delta X. And this is what we get. For this term delta X cancels.

All the other terms still contain delta X. This means when we go with delta X to zero, we end up with this term alone, which is n times X to the power of n minus one. Now we have a very simple result. The derivative of X to the power of n is n times X to the power of n minus one. We need two more rules for the derivations in this tutorial.

I will prove both because I want this tutorial to be completely self-contained. So, here's the next one, multiplication by a constant. The question is, what is the derivative of a times a function g of X? As before, we plug this function into the limit. Now f at X plus delta X is a times g at X plus delta X, and f of X is a times g of X.

We can factor out a, and since a is not dependent on delta X, we can factor it out of the limit. Now what you see here is the definition of the derivative of the function g. So, our result is a times the derivative of g. Another very nice result. So, the derivative of a times a function is simply a times the derivative of this function.

The last rule is the summation rule. The question is, what is the derivative of the sum of two functions f1 and f2? Let's plug it into the limit. F at X plus delta X is f1 at X plus delta X plus f2 at X plus delta X. F X is f1 of X plus f2 of X.

Now we can rearrange these terms a bit. Now we can split the limit into two limits. And what you see here is the derivative of f1 and the derivative of f2. We have the simple result that the derivative of a sum of two functions is the sum of the derivatives of these two functions. Before we go back to the examples, I introduce you to polynomials.

Polynomials are functions of the form A0 plus A1 times X plus A2 times X squared plus A3 times X cubed plus A4 times X to the four and so on. The Ai are constants and are called the coefficients of the polynomial. Polynomials are very useful because we can approximate other more complicated functions, and polynomials have very simple derivatives. So, what's the derivative of a polynomial? We can simply apply the rules we just derived before.

A0 for instance just disappears because it's a constant. A1 times X turns into A1 because the derivative of X is one. The derivative of X squared is two times X, so this term turns into two times A2 times X. The derivative of X cubed is three times X squared, so A3 times X cubed turns into three times A3 times X squared. As you can see, we have very simple rules to differentiate all these terms individually.

Now let's go back to the examples. Let's first look at the soccer equation. The equation says that the second derivative h double dot of the height of the ball is equal to minus g. Now our task is to find a function h of t whose second derivative is minus g. Using the power rule, we can easily construct such a function.

Minus one half g t squared is such a function. Let's see why. Let's differentiate once. T squared turns into two t and the two cancels. So, the first derivative is minus g times t.

Let's differentiate this function again. The derivative of t is just one, so the second derivative of h is minus g, exactly what we want. However, this h of t is not the only solution. We can actually add two more terms without changing the second derivative. Here I have a constant term h0 and a linear term v0 times t.

When we differentiate this function, h0 disappears because it's a constant. V0 is a constant and the derivative of t is one, so v0 times t turns into v0. Now when you differentiate a second time, v0 disappears as well because it's a constant. So again, as before, the second derivative of our new function ht is also minus g. In general, differential equations can have many solutions.

In this case, we can freely choose an initial height h0 and an initial velocity v0. Here I plotted a concrete example. I chose one for the initial height and 10 for the velocity of the ball. I approximated g with 10. So, as you can see, we get the parabola that we predicted earlier.

What we learned so far is interesting, but not that exciting. Now comes the really cool stuff. What about the rabbit equation? In the rabbit equation we have the function n, which is perhaps the number of rabbits at time t. The differential equation says that the derivative of n, or the rate of change of n, is proportional to n itself, where k is a constant.

Let's set k to one for the moment to make things a little bit easier. What would that mean? In that case, we need a function whose derivative is itself. Is that possible? This would mean that the motion, the velocity, the acceleration, the acceleration of the acceleration, and so on, they're all the same.

Is this possible? Let's construct such a function. What about f of X equals X to the power of n? Well, the problem here is that this function is not strong enough. As we saw, the derivative of X to the power of n is n times X to the power of n minus one.

So, when we differentiate, the power reduces by one. What about an exponential? What about the function e to the power of X, where e is a constant? Before we plug this function into the limit, I need to do a short recap of exponents. A to the power of b times a to the power of c is basically just a times a times a and so on b times times a times a times a and so on c times.

This is simply a to the power of b plus c. So, the general rule is a to the power of b times a to the power of c is a to the power of b plus c. Now we can derive what a to the power of zero is. Let's multiply a to the power of zero with a. According to the rule above, a to the power of zero times a is a to the power of zero plus one, which is a to the power of one, which is a.

Now we divide both sides by a. And what we get is a to the power of zero is simply one. What about a to the power of minus one? A to the power of minus one times a is a to the power of minus one plus one, which is a to the power of zero, which is one. Now we divide both sides by a and get the result a to the power of minus one equals one over a.

And finally, what is a to the power of one half? A to the power of one half times a to the power of one half is a to the power of one half plus one half, which is a to the power of one, which is a. This means a to the power of one half is a number that when multiplied with itself equals a. And this is the square root of a. Now we're ready to see whether e to the power of X is the function we're looking for, and if so, what the value of e is.

So, let's plug e to the power of X into the limit. What's the derivative of e to the power of X? In the numerator we always had f at the position X plus delta X minus f at the position X. In our case, this is e to the power of X plus delta X minus e to the power of X. Now we know that e to the power of X plus delta X is e to the power of X times e to the power of delta X.

This means we can factor out e to the power of X. Now e to the power of X doesn't depend on delta X, so we can factor it out of the limit. Now we're almost there. The derivative of e to the power of X is actually the e to the power of X. This, however, is only true if this expression here is one.

This means we have to find a value for e that makes this term one. First, we substitute delta x by 1/n. This means if we want delta x to go to zero, we need n to go to infinity. Now, e to the power of delta x turns into e to the power of 1/n. Division by delta x turns into multiplication with n.

Now, we have the equation n * e to the power of 1/n - 1 must be equal to 1. Now, let's have a look at a finite n. For any finite n, we can solve this equation. For a finite n, we get en = 1 + 1/n to the power of n. The value we are interested in, e, is the limit as n goes to infinity of en.

So, we get for e the limit as n goes to infinity 1 + 1/n to the power of n. So, what's the value of this limit? Let's see. This equation is actually completely crazy formula. Let me show you why.

For any constant a greater than one, the limit as n goes to infinity of a to the power of n is infinity. So, for instance, 2 * 2 * 2 * 2 and so on to infinity, of course, is infinity. However, if we set a to one, then the limit as n goes to infinity of a to the power of one is 1 * 1 * 1 and so on is one. The question is now which of these two rules apply to our limit? It seems that this expression here is always greater than one for any n.

So, that would mean that e is infinity. However, as n goes to infinity, this expression here approaches one. So, maybe the value of e is one. There are two forces here. One pulls e to infinity, and the other one pulls e to one.

Which of these two forces wins? Well, we can try with a calculator. So, take your calculator and enter 1.000001 to the power of 1 million. Or 1.0000000001 to the power of 1 billion. To this very day, I cannot believe what I see on the calculator.

As we make n bigger and bigger, the result approaches a seemingly random number. Its value is 2.71828 with an infinitely long non-repeating sequence of digits. So, why is this value some value between two and three? Is this the compromise between one and infinity? Isn't math crazy?

Let me show you an alternative approach to find the constant e. We're still looking for a function whose derivative is itself, but now let's try a polynomial, a polynomial of infinite length. We already saw how to compute the derivative of a polynomial. The polynomial a0 + a1 * x + a2 * x squared + a3 * x cubed and so on turns into a1 + 2 * a2 * x + 3 * a3 * x squared + 4 * a4 * x cubed and so on. We need now that all these coefficients are equal.

This gives us equations for all the coefficients. For instance, a1 needs to be equal to a0. 2a2 needs to be equal to a1, which means a2 must be equal to 1/2 a1, or 3 * a3 must be equal to a2, which means a3 needs to be 1/3 * a2. So, we can derive this general rule, an must be 1/n * a n - 1. With this, we have equations for all the coefficients, but the coefficient a0.

Let me set a0 to one for reasons we will see later. If we set a0 to one, we get this polynomial. a0 is one. a1 is a0, which is also one. So, we have 1 + 1x.

a2 is 1/2 a1. a1 is one, so a2 is 1/2. a3 is 1/3 * a2. Therefore, we get 1/2 * 3. For a4, we get 1/2 * 3 * 4.

You can already see the rule here. The polynomial is actually the sum n from zero to infinity of 1/n! * x to the power of n. n! is simply 1 * 2 * 3 and so on * n.

So, we have actually found a polynomial whose derivative is itself. However, this only works for an infinitely long polynomial. Now, the problem we have is that f(x) is an infinite sum. And it seems that these terms get bigger and bigger if x is greater than one. Does this polynomial explode?

Do these terms actually really get bigger and bigger and bigger? Let's see. Well, after n gets bigger than 2x, the terms actually shrink by more than a factor of two. Let's see why. This is the coefficient an - 1.

Here, we have x * x * x and so on n - 1 times in the numerator. In the denominator, we have n - 1! Now, what happens if we go from n - 1 to n? Now, we have one more x in the numerator. We also have to go from n - 1!

to n! which means we multiply with an additional n. As you can see, the coefficient is multiplied by x/n. Now, for n greater than 2x, this factor is smaller than 1/2. Here, I drew a little image of the sum of a + a/2 + a/4 and so on.

And as you can see, the sum is actually finite. This means the sum of all the terms for which n is greater than 2x is actually limited. This also means the complete sum is limited as well. So, we don't have an explosion. Now, we want to know whether these two solutions are equal.

Is e to the power of x equal to our polynomial for all x? Well, let's check. At the position x = 0, they are the same. Our polynomial at x = 0 is one because we choose a0 to be one. e to the power of zero is also one.

So, they match at the position x = 0. The question is do they ever split at some point? So, let's assume they do split at the position x = xs. A split means that the values of these two functions are the same at the position x = xs. However, their derivatives, or their rate of change, are different.

Is that possible? Is it possible that the values of the functions are the same, but derivatives are different at the same location? Well, both functions have the property that they're equal to their derivatives. This means if the functions have the same value, their derivatives must also have the same value. So, it's not possible that we ever have a split.

And this means the two functions we just derived are indeed equal. So, we get this very interesting and nice formula. So, we have as a result e to the power of x is the sum n = 0 to infinity of 1/n! * x to the power of n. Now, we can compute e in a different way.

We can plug one into our polynomial. e to the power of one is e. So, what we get is the sum n = 0 to infinity of 1/n! This is 1 + 1 + 1/2 + 1/6 + 1/24 + 1/120 + 1/720. If we stop here, we get about 2.718.

If we do this to infinity, we indeed get the same e as we found before. This time, I think the value 2.718 and so on makes a little bit more sense. Now, look what crazy equation we just derived with a little bit of algebra. We found that the limit as n goes to infinity of 1 + 1/n to the power of n is the same as the sum n = 0 to infinity of 1/n! This is very far from being a trivial equation.

However, we need to generalize our findings a little bit. Remember that I set k to one in the rabbit equation. However, if k is not one, then what you need is a function whose derivative is a times itself. How can we solve this problem? If we plug a * x into our polynomial, we get 1 + ax + 1/2 a squared x squared + 1/6 a cubed x cubed and so on.

Let's compute the derivative of this polynomial. One disappears. a * x turns into a. 1/2 * a squared * x squared turns into a squared x. 1/6 a cubed x cubed turns into 1/2 a cubed x squared.

This polynomial corresponds to a times f at the position ax. This means that the derivative e to the power of ax is a times e to the power of ax. The function that solves this equation is e to the power of ax. Let's go back to the rabbit equation. We worked with the function n(t), the number of rabbits at time t.

The differential equation said that the derivative of n equals k times n itself. Now, we can write down the solution. The solution is n(t) = e to the power of kt. Let's plug it into our differential equation. The derivative of e to the power of kt is k times e to the power of kt, and this is n.

So, the derivative of n is k times n, which is exactly a solution to this problem here. As in the soccer equation, we have multiple solutions. We can choose the value of n of t at time t0, we call it n0. So, this is a generalized solution. If we plug in t = t0, then we get a zero here, and e to the power of zero is one.

So, n at the position t0 is n0. Here's the proof that the generalized solution also solves the differential equation. Here I plotted a concrete example. I chose k to be 1/2 and n0 to be 10. So, as you can see, the number of rabbits at time t = 0 is 10.

We get the curve that we guessed earlier. Now, let's have a look at the coffee equation. We had capital T of t, which was the temperature of the coffee above room temperature. And the equation said that the derivative of T is equal - k * T. We can again write down the solution.

This time, the solution is e to the power of - kt. Why is that? Let's plug it into the equation. The derivative of T is - k * e to the power of - kt, which is - k * T. Again, we can choose the value of n of t at time t0.

This is the generalized function. Here I plotted a concrete example. I chose T at time t0 to be 80 as before. Now, k is 1/8. This is the plot of this function.

It looks as we guessed before. Now, finally, let's solve the spring equation. Here we worked with a function x of t, the elongation of the spring at time t. The equation says that the second derivative, x double dot, equals - x. Here I chose k to be one.

Let's again try x of t equals a to the power of at, where a is a constant. Now, to check whether this function solves the differential equation, we again just plug it in. The first derivative of e to the power of at is a * e to the power of at. The second derivative is a squared * e to the power of at. Now, the equation says that a squared * e to the power of at equals - e to the power of at.

Now, let's divide this equation by e to the power of at. Now, we have a squared equals - 1. So, a itself is the square root of - 1. Oops, the square root of a negative number does not exist. It seems that the differential equation has no solution.

However, we know that the bouncing spring exists. What's going on here? Well, since there's no number on the real axis that solves our equation, we simply invent a new number. We call this number i. It's the square root of - 1.

It's an imaginary number. Now, we have a solution to our equation. x at position t is equal e to the power of it. We also have a solution if k is not one. In this case, the solution is e to the power of i square root of k t.

We can easily see that. When you differentiate once, we get an additional factor square root of k. When you differentiate again, we get another additional factor square root of k. So, we get square root of k * square root of k, which is k. Now, is this solution useful?

What does this mean? Let's check what properties i has. Let's juggle with i a little bit. For instance, what's i to the power of some number? Well, i to the power of zero is one.

We saw earlier that any number to the power of zero is one. i to the power of one is simply i. i squared is the square root of - 1 * the square root of - 1, which is - 1. i cubed is i squared * i. And since i squared is - 1, we get - i.

i to the power of four is i to the power of two squared. i to the power of two is - 1, so you get - 1 * - 1, which is one. i to the power of five is i to the power of four * i, which is 1 * i, which is i. i to the power of six is i to the power of four * i squared, which is - 1 * 1, which is - 1. As you can see, we get a repeating sequence: 1, i, - 1, - i, 1, i, - 1, - i, and so on.

Now, the expression a + b * i, where a and b are real numbers, cannot be further reduced. Therefore, we define a complex number to be a + b * i. We call a the real part and b the imaginary part. Now, the cool thing is, we don't have to invent any operations on complex numbers. We can simply derive them with a little bit of algebra.

For instance, the addition a1 + b1 * i + a2 + b2 * i is simply a1 + a2 + b1 + b2 * i. Simple algebra. Here I derived what the multiplication of two complex numbers is. Here we use the property that i squared is - 1. This is why we get the minus sign here.

Now, there is a nice way to visualize complex numbers. For this, we use a two-dimensional diagram. We have the real axis along the x-axis and the imaginary axis along the y-axis. So, the x-axis corresponds to the number line as we know it. We have -2, -1, 0, 1, 2, 3, 4, and so on.

But now, we expand this number line up and down to get an entire plane. In this plane, each dot is a complex number. For instance, this yellow dot here corresponds to 1.5 + 2i. Its real part is 1.5 and its imaginary part is 2i. Here's another example.

This yellow dot corresponds to -1.5 - i. Now, the cool thing is that the expansion of the real number line to an entire plane opens an entirely new playground. As you will see in the bonus slides. Now, the complex plane enables us to see what the meaning of the square root of - 1 or i is. Here I repeatedly multiply one by -1, which gives 1, -1, 1, -1, and so on.

So, a continuous multiplication with -1 can be interpreted as a rotation on the real axis. Now, let's see what happens when we continuously multiply one by i. Multiplying by i and then multiplying by i again means multiplying by i squared. And since i squared is -1, this has the same effect as multiplying by -1. So, therefore, we get from 1 to -1.

However, multiplying by i does just half the job. So, while multiplying with -1 is a 180° turn, multiplying by i is a 90° turn. So, now we have a nice interpretation of what we already computed, the exponents of i. So, i to the power of zero is one. i to the power of one is i.

i to the power of two is -1. i to the power of three is - i. And i to the power of four is one. So, as you can see, continuous multiplication with i rotates one on the unit circle in the complex plane. There's actually a nice way to figure out what e to the power of ix is.

Earlier, I showed you how to approximate e to the power of x with a polynomial. The polynomial was the sum n equals zero to infinity 1 over n factorial * x to the power of n. Now, we plug i * x into this polynomial. We get one + x, which is now ix, + 1 over 2 factorial * x squared, which is now i squared * x squared. Plus 1 over 3 factorial * x cubed, which is now i cubed * x cubed, and so on.

We already figured out what i, i squared, i to the power of three, four, five are. This is what we get. Now, what we can see is all the odd terms are real numbers and all the even terms contain i. So, they're pure imaginary numbers. To get the complex number, we then just have to group the real and the imaginary parts.

If we do that, we get this complex number. This means we have two polynomials now, a real and an imaginary polynomial. Let's now check whether the two polynomials solve our original differential equation f double dot equals - f. To do this, we need to differentiate twice. This is the real polynomial.

Differentiating once yields this polynomial here. This is what we get when you differentiate another time. When you look closely, you can see that this polynomial equals this polynomial * -1. So, we have exactly what we want, f double dot equals - f. Let's check the imaginary polynomial.

This is what we get when we differentiate once. Differentiating another time gives this polynomial here. And again, you can see that this polynomial is the same as this one multiplied by -1. So, both these polynomials solve our original differential equation. Now, the question is, do these two polynomials also have a nice closed form as the polynomial that approximates e to the power of x?

Do they have a deeper meaning, and interpretation? To answer this question, we play a little game, the polynomial quiz. Let's say we are given a polynomial in a black box with unknown coefficients ai. We are allowed to evaluate this polynomial and all its derivatives. Can we recover the coefficients?

Now, this is the solution. Here we have our general polynomial a0 + a1 * x + a2 * x squared and so on. We know how to differentiate polynomials. So, here's the first derivative, the second, the third, and so on. What's important to notice here is that each time we differentiate, one of the coefficients disappears.

If we now evaluate the polynomial and all its derivatives at the position x = 0, all these terms that contain x also disappear. a0 is f evaluated at position x = 0. To recover a1, we evaluate f prime at the position x = 0. To recover a2, we evaluate the second derivative at position x = 0, but have to divide by 2. To recover a3, we evaluate the third derivative at position x = 0, but have to divide by 6.

So, here we have the general formula to compute an. an is the nth derivative of f evaluated at x = 0 divided by n factorial. Now, this is the compact way to write polynomials as we saw before. f of x is the sum n = 0 to infinity of an * x to the power of n. Now, here I just plugged in the formula we found for an.

This polynomial is called the Taylor expansion at zero or Maclaurin series. Now, the cool thing is that this f doesn't need to be a polynomial. For a general function, this polynomial here is an approximation of f. And the interesting thing is, to get the polynomial that approximates f at any position x, all we need is f and all its derivatives evaluated at position x = 0. This means it is enough to inspect the function at zero and all its derivatives to recover the entire shape of the function.

This is a little bit like the Big Bang. If there was no quantum randomness, we could indeed predict the entire history of the universe by just looking at the state of the universe at the Big Bang. Now, let's go back to our question. Do the real and imaginary polynomials have a deeper meaning? For this, we look at the point that moves on the unit circle with unit velocity.

p of t is the position of the point at time t. Since we are in two dimensions, the position of the point can be expressed by two coordinates, x and y. Since p is dependent on time, these two coordinates are also dependent on time. Now, mathematicians gave these two functions names. x of t is called cosine and y of t is called sine.

So, cosine of t and sine of t are the coordinates of a point moving on a unit circle with unit velocity. So, this is the definition of the function sine and cosine. Can we compute the derivative of these two functions, sine and cosine? What we saw earlier is that the derivative of a function that depends on t is actually the velocity. So, the question is, what is the velocity of the point p at time t?

The velocity is tangential to the circle here. This also means that it is perpendicular to the radius. Since the velocity of p is 1, the length of the velocity vector is also 1. What we can see from the diagram is that the coordinates of the velocity vector are minus sine of t and cosine of t. So, we have p dot equals minus sine t, cosine t.

So, from this simple diagram, we can see that the derivative of cosine is minus sine. Also, the derivative of sine is cosine. This is a quite simple result. Our goal is now to approximate cosine and sine with a Maclaurin series. For this, we need the value and all its derivatives at t = 0 for the two functions.

First, what are the values of sine and cosine at t = 0? Let's go back to the diagram. The point p is at position x = 1 and y = 0 at t = 0. This means cosine of 0 is 1 and sine of 0 is 0. Now, we simply take derivatives.

The derivative of cosine is minus sine. The derivative of minus sine is minus cosine. The derivative of minus cosine is sine and the derivative of sine is cosine. Now, we simply plug these values in and get 1 0 -1 0 1. The same for the sine function.

This is our previous result. When we plugged ix into the polynomial that approximates e to the power of x, we got this result. We got two polynomials, a real one and an imaginary one. Now, if you look closely, this is the Maclaurin series for cosine and this is the Maclaurin series for sine. For cosine, the constant is 1.

The first term is missing. The second term is 1 over 2 factorial * x squared and we have a minus sign here. So, we get minus 1 over 2 factorial * x squared. The third term is missing. The fourth term is just as it is, 1 over 4 factorial * x to the power of 4 and so on.

The same for the sine function. For the sine function, we do not have a constant. The first term x is just as it is. The second term is missing. The third term is minus 1 over 3 factorial * x cubed and so on.

So, we get this really nice result. e to the power of ix is cosine of x + i sine of x. In other words, e to the power of ix describes a circle in the complex plane. Now, let's go back to the spring equation one last time. This was the simple differential equation where k equals 1.

Here we have x double dot equals minus x. We found the solution e to the power of it, but didn't really know what this means. For the general case, we got a solution x at t is equal e to the power of i square root of k over m * t. Now, we know that the real part of this function is cosine of square root k over m * t. The general solution has this form here.

Here I plotted the cosine function. So, we do get the shape of x of t that we guessed in the beginning. Now, we solved all our four examples, but there's more cool stuff. We just found Euler's equation. e to the power of i phi is cosine of phi + i sine of phi.

Here I used phi instead of x or t. This is a complex number. So, let's check where this number is in the complex plane. As before, we have the real axis here and the imaginary axis here. This equation gives us the coordinates of this point e to the power of i phi.

The real part is cosine of phi. The imaginary part is sine of phi. This means e to the power of i phi must lie on the unit circle. This is because cosine and sine are the coordinates of a point on the unit circle. Also, phi describes the distance from the real point 1 to e to the power of i phi.

Phi is also the definition of an angle in radians. So, we have the final result that e to the power of i phi is the point on the unit circle for which the angle between the line 0 to e to the power of i phi and the real axis is phi. Let me now introduce you to the constant pi. The constant pi is defined as half of the circumference of the unit circle. So, pi is the length of this arc here.

Now, let's check what we get for e to the power of i phi for various values of phi. If we set phi = 0, then we get e to the power of 0, which is 1. So, we start at the real number 1. If we set phi to pi over 2, we end up at i, the complex number i. If we set phi = pi, then we end up at minus 1.

So, we get the famous formula e to the power of i pi = minus 1. We can go one step further and set phi = 3 * pi over 2. With this, we end up at minus i. e to the power of i 2 pi is 1. As e, pi is a number with a non-repeating infinite sequence of digits.

Now, we get the crazy result. We can actually plug in the values of these three constants into this equation. So, we have 2.71828 and so on to the power of square root of minus 1 * 3.14159 and so on. So, this crazy thing here equals minus 1. Isn't this fascinating?

Let me show you another fascinating fact about pi. We want to know the area of an n-gon. An n-gon is a shape that has n sides of equal length. We assume that the corners of the n-gon are on the unit circle. Now, we want to know the area.

Let's call the length of the sides an. The n-gon is composed of n triangles. Let's call the height of the triangles hn. The area of each triangle is 1/2 an * hn. Since we have n triangles, we multiply this by n.

Now, let me call the circumference of the n-gon sn. sn is n * an. We can now express the area of the n-gon an as 1/2 sn * hn. Now, what about the area of the unit disk? As n gets bigger and bigger, the n-gon approximates the disk.

So, the area of the disk is the limit as n goes to infinity 1/2 sn * hn. When n gets bigger and bigger, sn gets closer and closer to the circumference of the unit circle. We just learned that this is 2π. h gets closer and closer to 1. So, in the limit, we get 1/2 2π * 1, which is π.

So, the area of the unit disk is also π. Here is a fascinating fact about i. What is the value of i to the power of i? We just use some basic algebra. We already saw that a to the power of b * a to the power of c is a to the power of b + c.

Now, what is a to the power of b to the power of c? Well, that is a to the power of b * a to the power of b and so on c times, which is, according to this law, a to the power of c * b. On the slide with the unit disk in the complex plane, we saw that we can express i as e to the power of π / 2 i. According to our rule, e to the power of π / 2 i to the power of i is e to the power of π / 2 i * i. Now, i * i is -1 according to the definition of i.

So, we get e to the power of - π / 2. There is no i here, so we can type this into our calculator. And this is what we get. Some random real number. i to the power of i is real.

How crazy is math? In the last part of this tutorial, I want to show you something that I think is the most fascinating fact of all of mathematics. Let's start with the square game. It's a very simple game. We start with any number, and then we keep squaring.

So, we start with x1, and then x2 is x1 squared. x3 is x2 squared and so on. So, in general, xi + 1 is xi squared. So, if we set x1 to 2, we get 4, 8, 16, 32, and so on. You can play this game very easily.

Just enter a number into your calculator, then keep pressing the key x squared. You can think of this game as a ball on a terrain. Here, I drew the number line. 0 is here, -1 is here, and 1 is here. If you start with a number larger than -1 and smaller than 1, the ball rolls into a sink at 0.

x gets smaller and smaller. If x is larger than 1 or smaller than -1, the number gets bigger and bigger, and the ball rolls into the abyss. Only if x is exactly -1 or 1, then the ball stays on the edge. Here, we have an unstable equilibrium. Now, what about the complex plane?

Where is the edge in the complex plane? To answer this question, I need to briefly introduce you to polar coordinates. It is quite easy to see that for any complex number a + b * i, we can find r and φ such that a + b * i is r * e to the power of iφ. e to the power of iφ is a number on the unit circle, as we saw before. Multiplying a complex number by a constant r moves it along the line to the origin.

If r is smaller than 1, it moves it towards the origin. If r is larger than 1, it pushes it away from the origin. Now, to represent a + b * i, we simply measure the angle φ. So, to represent the number a + b * i, we draw a line from this number to the origin. The intersection is our number e to the power of iφ, where φ is the length of this arc here.

Now, we just have to multiply this number by the correct r to reach a + b * i. So, let's find the edge. Now, the polar representation gives us a nice intuition about what happens when we square complex numbers. So, here's our complex number. z = r * e to the power of iφ.

Now, z squared is r * e to the power of iφ * r * e to the power of iφ, which is r squared * e to the power of i2φ, because we can add these two terms. Now, we see that squaring a number squares the radius and doubles the angle. So, here is an image to visualize this. If r is equal to 1, then we move on the unit circle, and the angle doubles. If r is smaller than 1, then we are pulled towards the origin.

If r is larger than 1, then we are pushed away from the origin. Of course, we can also compute the square with the regular representation. So, here we have z = a + b * i. This gives z squared = a + b * i * a + b * i. Now, we expand this expression.

This gives a squared + 2 * a * b * i + b squared i squared. Now, we know that i squared is -1, so we get a squared + 2 * a * b * i b squared. Now, these two terms don't contain i. So, this is the real part of the number, a squared - b squared, and this is the imaginary part of the number, 2 * a * b. So, in this representation, it's not at all clear that we stay on the unit circle if r is 1.

Now, we can answer our original question. Where is the edge in the complex plane? If we start with a number whose r is smaller than 1, then the points whirls about the origin and eventually ends up there. If r is exactly 1, then we rotate on the unit circle forever. If r is larger than 1, then the points whirls towards infinity.

In this case, we say that our game diverges. So, the edge in the complex plane is the unit circle. Nice, but not so fascinating. Now, we introduce some wind. What if the ball is pushed by a constantly blowing wind?

For this, we modify our game a little bit. After each iteration, we add a constant complex number c. So, this is our new game. We start with a complex number, then we square it, and each time we square it, we also add a constant c, which is also a complex number. Now, is the question, where is the edge now?

Is it still a disk that is just translated by c? Is the shape still a circle? Answering this question theoretically is quite tricky. Let us write a program instead. So, here I define a function.

It returns whether our game diverges. x1 and x2 define the starting number. x1 is the real part, and x2 is the imaginary part. c1 and c2 define our constant. Again, c1 is the real part, and c2 is the imaginary part.

Max iters define how many steps we perform in our game. Here, we have the loop performing max iters step. It is a mathematical fact that if r reaches 2, then the game diverges. In this case, we return true. Otherwise, we square our number x just the way we saw in the previous slide.

After this, we add our constant c. If after max iterations, our game has not diverged, then we assume that it does not diverge. This is an approximate answer, though. This little program here is the most mind-boggling and magic program I have ever seen in my entire life. What we are now going to do is we map each pixel on the screen to a complex number in the complex plane.

For each complex number, we run our game. If our function tells us that the game diverges, we leave the pixel black. Otherwise, we paint it yellow. For c = 0, we get exactly what we expected. For points outside the unit circle, our game diverges.

For points inside the unit circle, it converges to 0. This is for c = 0. Now, the question is, what happens to the unit circle when we introduce wind? Maybe it just shifts the circle. Well, let's see.

This is not the case. Increasing c distorts the circle in a magic way. Let's make c even bigger. Look at this. Look at this beautiful shape here.

And even bigger. Isn't this magic? Our simple algorithm I showed you on the last slide produces this beautiful shape. Here are more examples. I will always show you the value of c.

Here, we have the unit disk. These beautiful patterns are called the Julia set. To create this even more beautiful result, I changed the way I visualized the result a little bit. This time, I don't just return true or false. I return the number of iterations it took for the game to diverge.

Then, I mapped every number to a color, and this is what we get. Now, this picture is infinitely complex. Let's zoom into this region here. Look at how beautiful this is. Let's zoom even further.

Let's have a look how this region here looks. This is what we get. You can continue zooming, and you get more and more interesting patterns. Here is the program I used to create the images in the slides. As usual, I wrote it in JavaScript, so it runs in a browser.

You can download it from our webpage and play with it. Here I use the mouse to specify the constant C. So, as I move the mouse, the image changes. The Mandelbrot set is closely related to the Julia set. All we need to do is modify our game a little bit.

Instead of using a constant C for the entire image, we use the starting number C1 as the offset. So, now we don't have a global parameter C. This is what we get. In German, this is called the Apfelmännchen, which means the little apple man. Let's enjoy this beautiful Mandelbrot zoom of Mathigon.

This is the end of the tutorial, but just the beginning of the magic of mathematics. I hope you enjoyed this tutorial. Thanks for watching, and I see you in the next one.

## Source Code

### 19-julia.html

```html
<!--
Copyright 2023 Matthias Müller - Ten Minute Physics, 
www.youtube.com/c/TenMinutePhysics
www.matthiasMueller.info/tenMinutePhysics

MIT License

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
-->

<!DOCTYPE html>
<html>
	<meta name="viewport" content="width=device-width, initial-scale=1.0">

	<head>
		<title>Fractals</title>
		<style>
			body {
				font-family: verdana; 
				font-size: 15px;
			}			
			.button {
				background-color: #606060;
				border: none;
				color: white;
				padding: 10px 10px;
				font-size: 16px;
				margin: 4px 2px;
				cursor: pointer;
			}
			.slider {
				-webkit-appearance: none;
				width: 80px;
				height: 6px;
				border-radius: 5px;
				background: #d3d3d3;
				outline: none;
				opacity: 0.7;
				-webkit-transition: .2s;
				transition: opacity .2s;
			}
		</style>
	</head>

	<button class="button" id="toggleModeButton" onclick="toggleMode()">Julia</button>
	<button class="button" id="toggleViewButton" onclick="toggleView()">Mono</button>
 	Iterations <input type = "range" min = "1" max = "500" value = "50" id = "numItersSlider" class = "slider">
     <span id = "numIters">50</span>    
	 &nbsp;&nbsp; [shift] - drag to change c

    <canvas id="myCanvas" style="border:2px solid"></canvas>
	
<body>
	
<script>

	var canvas = document.getElementById("myCanvas");
	var c = canvas.getContext("2d");	
	canvas.width = window.innerWidth - 20;
	canvas.height = window.innerHeight - 100;

	canvas.focus();

	var examples = [
		{ 
			centerX: 0.0,
			centerY: 0.0,
			scale: 0.0035,
			juliaX: 0.0,
			juliaY: 0.0,
			maxIters: 100,
			mandelbrot: false
		}
	];



	// var juliaX = 0.0;
    // var juliaY = 0.0;

	// var juliaX = -0.553000000000000;
	// var juliaY = 0.504000000000000;

	var juliaX = -0.62580000000000;
	var juliaY = 0.40250000000000;

	// juliaX *= 0.99;
	// juliaY *= 0.99;

	// mandelbrot
	// centerX = -0.9033519195433093
	// centerY> = -0.25002747496554767
	// scale = 0.0000022849254986921118
	// maxIters = 147

	centerX = -0.8115766681578079
	centerY = -0.20141225898974988
	scale = 0.0000014034116967598337
	maxIters = 500

	centerX = -0.8115734686602871
	centerY = -0.20143013094290876
	scale = 2.8456343445241582e-8
	maxIters = 500


	var maxIters = 100;
    var drawMandelbrot = false;
    var centerX = 0.0;
    var centerY = 0.0;
    var scale = 0.0035;


	// function setExample(nr) {
	// 	if (nr < examples.length) {
	// 		maxIters = examples[nr].maxIters;
	// 		drawMandelbrot
	// 		centerX: 0.0,
	// 		centerY: 0.0,
	// 		scale: 0.0035,
	// 		juliaX: 0.0,
	// 		juliaY: 0.0,
	// 		maxIters: 100,
	// 		julia: true
	// 	}

	// }

	






	var modifyJulia = false;

    // var juliaX = -0.785 * 0.95;
    // var juliaY = 0.13083333969116212 * 0.95;

	var drawMono = true;

    var redraw = true;
    var id = 0;

	function getNumIters(x1, x2, c1, c2, maxIters) 
	{
		for (iters = 0; iters < maxIters; iters++)
		{
			if (x1 * x1 + x2 * x2 > 4.0)
				return iters;

			var x = x1;
			x1 = x1 * x1 - x2 * x2;
			x2 = 2.0 * x * x2;

			x1 += c1;
			x2 += c2;
		}
		return maxIters;
	}	

// var gradientColors = 
// 	[[1, 1, 65],
// 	[0, 40, 129],
// 	[147, 205, 242],
// 	[243, 228, 189],
// 	[111, 59, 37],
// 	[0, 40, 129]];

var gradientColors = 
	[[15, 2, 66],
	[191, 41, 12],
	[222, 99, 11],
	[229, 208, 14],
	[255, 255, 255],
	[102, 173, 183],
	[14, 29, 104]];

	function getGradientColor(nr, steps) 
	{
		var numCols = gradientColors.length;
		var col0 = Math.floor(nr / steps) % numCols;
		var col1 = (col0 + 1) % numCols;
		var step = nr % steps;

		var color = [0,0,0];

		for (var i = 0; i < 3; i++) {
			var c0 = gradientColors[col0][i];
			var c1 = gradientColors[col1][i];
			color[i] = Math.floor(c0 + (c1 - c0) / steps * step);
		}
		return color;
	}


	function draw() {
		c.clearRect(0, 0, canvas.width, canvas.height);

		c.fillStyle = "#FF0000";

        if (redraw) {
            redraw = false;

    		id = c.getImageData(0,0, canvas.width, canvas.height);

            var p = 0;
            var y = centerY - canvas.height / 2.0 * scale;

    		for (var j = canvas.height - 1; j >= 0; j--) {

                var x = centerX - canvas.width / 2.0 * scale;

                for (var i = 0; i < canvas.width; i++) {

                    // compute Julia color

					var numIters = getNumIters(x, y, drawMandelbrot ? x : juliaX, drawMandelbrot ? y : juliaY, maxIters);

					if (numIters < maxIters) {
						if (drawMono) {
							id.data[p++] = 0;
	                        id.data[p++] = 0;
    	                    id.data[p++] = 0;
						}
						else {
							colNr = numIters;
							color = getGradientColor(colNr, 20);
							id.data[p++] = color[0];
							id.data[p++] = color[1];
							id.data[p++] = color[2];

							// id.data[p++] = 255;
							// id.data[p++] = (10 * numIters) % 256;
							// // id.data[p++] = Math.floor(numIters / maxIters * 255);
							// id.data[p++] = 0;
						}
					}
					else {
						if (drawMono) {
							id.data[p++] = 255;
	                        id.data[p++] = 192;
    	                    id.data[p++] = 0;
						}
						else {
							id.data[p++] = 0;
							id.data[p++] = 0;
							id.data[p++] = 0;
						}
                    }
                    id.data[p++] = 255;
                    x = x + scale;
				}
                y = y + scale;
			}
		}

		c.putImageData(id, 0, 0);

        var drawCircle = false;

		if (drawCircle && mouseDown && modifyJulia) {

            var cx = juliaX / scale + 0.5 * canvas.width;
            var cy = canvas.height * 0.5 - juliaY / scale;

			c.fillStyle = "#FFFFFF";
			c.beginPath();	
			c.arc(cx, cy, 5, 0.0, 2.0 * Math.PI); 
			c.closePath();
			c.fill();
        }

	}

	// interaction -------------------------------------------------------

    function toggleMode() {
        drawMandelbrot = !drawMandelbrot;
        redraw = true;
		var button = document.getElementById('toggleModeButton');
		if (drawMandelbrot)
			button.innerHTML = "Mandelbrot";
		else
			button.innerHTML = "Julia";
    }

	function toggleView() {
        drawMono = !drawMono;
        redraw = true;
		var button = document.getElementById('toggleViewButton');
		if (drawMono)
			button.innerHTML = "Mono";
		else
			button.innerHTML = "Gradient";
    }

	document.getElementById("numItersSlider").oninput = function() {
		maxIters = this.value;
        document.getElementById("numIters").innerHTML = maxIters.toString();
	        
        redraw = true;
	}

	var mouseDown = false;
	var mouseX = 0;
	var mouseY = 0;

    function setJuliaOffset(x, y) {
        let bounds = canvas.getBoundingClientRect();
        let mx = x - bounds.left - canvas.clientLeft;
        let my = y - bounds.top - canvas.clientTop;
        juliaX = (mx - 0.5 * canvas.width) * scale;
        juliaY = (canvas.height * 0.5 - my) * scale;
        redraw = true;
    }

	function startDrag(x, y) {
		// if (modifyJulia)
        // 	setJuliaOffset(x, y);
		mouseX = x;
		mouseY = y;
		mouseDown = true;
	}

	function drag(x, y) {
        if (mouseDown) {
			dx = x - mouseX;
			dy = y - mouseY;

			if (modifyJulia) {
				juliaX += 0.1 * dx * scale;
				juliaY += 0.1 * dy * scale; 
            	// setJuliaOffset(x, y);	
				redraw = true;
			}
			else {
				centerX -= dx * scale;
				centerY -= dy * scale; 
				redraw = true;
			}
		}
		mouseX = x;
		mouseY = y;
	}

	function endDrag() {
		mouseDown = false;
	}

	canvas.addEventListener('mousedown', event => {
		modifyJulia = event.shiftKey;
		startDrag(event.x, event.y);
	});

	canvas.addEventListener('mouseup', event => {
		endDrag();
	});

	canvas.addEventListener('mousemove', event => {
		drag(event.x, event.y);
	});

	canvas.addEventListener('touchstart', event => {
		startDrag(event.touches[0].clientX, event.touches[0].clientY)
	});

	canvas.addEventListener('touchend', event => {
		endDrag()
	});

	canvas.addEventListener('touchmove', event => {
		event.preventDefault();
		event.stopImmediatePropagation();
		drag(event.touches[0].clientX, event.touches[0].clientY)
	}, { passive: false});

	document.addEventListener('wheel', event => {
		console.log(event.deltaX)
		console.log(event.deltaY)
		if (event.deltaY > 0)
			scale *= 1.05;
		else if (event.deltaY < 0)
			scale *= 0.95;
		redraw = true;
	});

	// main -------------------------------------------------------

	function update() {
		draw();
		requestAnimationFrame(update);
	}
	
	update();
	
</script> 
</body>
</html>
```
