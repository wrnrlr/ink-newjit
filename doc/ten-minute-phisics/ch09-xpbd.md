# Chapter 09 — Getting Ready to Simulate the World with XPBD

**Video:** https://youtu.be/jrociOAYqxA
**Slides:** https://matthias-research.github.io/pages/tenMinutePhysics/09-xpbd.pdf

## Lecture Notes

### Simulation Approaches Compared

| Method | Mechanism | Issues |
|--------|-----------|--------|
| Force-based | f = kd → velocity → position | overlap needed, reaction lag, stiffness k is hard to tune |
| Impulse-based | detect → impulse → velocity | drift (consistent v ≠ consistent x) |
| **Position-based (PBD)** | detect → fix position → update v | **unconditionally stable, no drift** |

PBD is closely related to **implicit Euler integration** — specifically the first Newton iteration of a backward Euler step using non-linear Gauss-Seidel. Original PBD is only unphysical in how it handles softness; XPBD fixes this.

---

### Bead on a Wire (PBD as integrator + solver)

1. **State**: position **x**, velocity **v**
2. **Integration**: **p** ← **x**;  **x** ← **x** + Δt **v**
3. **Solve**: project **x** onto the wire
4. **Velocity update**: **v** = (**x** − **p**) / Δt

---

### PBD Algorithm

```
Δtₛ ← Δt / n
while simulating:
    for n substeps:
        for all particles i:
            vᵢ ← vᵢ + Δtₛ g
            pᵢ ← xᵢ
            xᵢ ← xᵢ + Δtₛ vᵢ
        for all constraints C:
            solve(C, Δtₛ)
        for all particles i:
            vᵢ ← (xᵢ − pᵢ) / Δtₛ

solve(C, Δt):
    for all particles i of C:
        compute Δxᵢ
        xᵢ ← xᵢ + Δxᵢ
```

**Key insight**: sub-steps converge much faster than iterations for the same compute budget. XPBD with sub-steps also requires no λ tracking.

---

### Distance Constraint

Two particles **x**1, **x**2; masses m1, m2; inverse masses wᵢ = 1/mᵢ; rest distance l₀; current distance l.

Δ**x**1 = (w1 / (w1+w2)) · (l − l₀) · (**x**2 − **x**1) / |**x**2 − **x**1|

Δ**x**2 = −(w2 / (w1+w2)) · (l − l₀) · (**x**2 − **x**1) / |**x**2 − **x**1|

---

### General Constraint

Constraint function C(**x**1, …, **x**n) → scalar (zero when satisfied).

Distance constraint: C_dist(**x**1, **x**2) = |**x**2 − **x**1| − l₀

**Constraint gradient ∇C**(**x**) — a vector:
- *Direction*: where C increases most
- *Length*: how much C changes per unit move of **x**

For C_dist: ∇C(**x**) = **x** / |**x**|

---

### Solving a General Constraint (PBD)

Compute scalar λ:

λ = −C / (w1|∇C1|² + w2|∇C2|² + ⋯ + wn|∇Cn|²)

Correction for particle **x**ᵢ:

Δ**x**ᵢ = λ wᵢ ∇Cᵢ

---

### XPBD: Making Constraints Soft

Add compliance α (= 1/stiffness) to the denominator:

λ = −C / (w1|∇C1|² + ⋯ + wn|∇Cn|² + α/Δt²)

- Hard constraint: α = 0
- PBD stiffness k ∈ [0,1] is time-step dependent; XPBD compliance α is physically correct

---

### Volume Conservation Constraint (Soft Bodies)

Tetrahedron **x**1…**x**4, rest volume V₀:

C = 6(V − V₀) = [(**x**2−**x**1) × (**x**3−**x**1)] · (**x**4−**x**1) − 6V₀

Gradients (right-hand rule):

∇1C = (**x**4−**x**2) × (**x**3−**x**2)
∇2C = (**x**3−**x**1) × (**x**4−**x**1)
∇3C = (**x**4−**x**1) × (**x**2−**x**1)
∇4C = (**x**2−**x**1) × (**x**3−**x**1)

Then apply the general λ formula and Δ**x**ᵢ = λ wᵢ ∇Cᵢ.


## Video Transcript

hi maltese from 10 minute physics here welcome to tutorial number nine today i will introduce you to extended position based dynamics or xpbd with that i will show you how to handle general not just distance constraints this will allow us to simulate a large variety of objects and phenomena in a very simple way if you don't use 3d math very often i highly recommend to watch tutorial number 7 first other than that this tutorial is self-contained let's start this tutorial will be quite technical you might want to watch it multiple times i also provide the slides so you can go through them in your own speed after this tutorial we are equipped with all the knowledge we need to write some really cool demos for the slides and all the information about my channel check out not just miller dot info 10 minute physics let me first motivate the method let's assume we have two bodies that are overlapping with a penetration depth of d in a force-based simulation we compute the separating force f which is proportional to the penetration depth d they are related via a scalar k which is also called the stiffness when the forces are applied they change the velocities eventually the velocities change to positions as you can see we need an overlap for the bodies to separate also there is a reaction lag to make objects look stiff we need a large difference coefficient k this however introduces stability problems and overshooting small values of k make the system squishy a big problem is how to set k to simulate a hard constraint as we will see in pbd we work with compliance which is the inverse of stiffness for hard constraints we can simply set it to 0 which corresponds to an infinitely big stiffness many rigid body engines use an impulse based simulation here the penetrations are only detected then an impulse is applied to make the velocities separating when the new velocities are applied the bodies separate this approach is more stable the velocity update is controlled and does not yield any overshooting problems the disadvantage of this approach is drift because we only work with velocities consistent velocities do not guarantee consistent positions additional tricks are needed to fix this problem now let's have a look at the position-based dynamics approach here we also just detect the penetrations then we directly change the positions of the objects to remove the overlap finally to get a dynamic system we need to update the velocities accordingly we have a controlled position change which yields an unconditionally stable simulation and we don't have the drift problem of impulse based approaches what people often ask is whether pbd is physical and accurate pbd has had the reputation of being unphysical and inaccurate however we found that it is closely related to implicit euler integration this is a very popular method because it is unconditionally stable to be precise position-based dynamics corresponds to the first iteration of the newton minimization of a backward euler integration step in variational position-based form using the non-linear gauss-seidel method where the newton solution is initialized with the unconstrained predicted inertial position using external forces don't get confused this is a very complicated description of a very simple method the original position-based dynamics approach is only unphysical in the way it handles softness fortunately we could fix this problem with xpbt extended position based dynamics as we will see let us now start with a simple example a beat on a wire we looked into this problem already in tutorial number five let's assume we have a beat with position x and velocity v and we want it to stay on the wire the first step is integration for this we use an explicit euler integration step we multiply the velocity times the time step size and add it to the position x is now the position where the bead would be without the constraint of staying on the wire it's also called the unconstrained position next we solve the constraint by moving the beat to the closest position on the wire finally we update the velocity as the current position minus the previous position divided by delta t as you can see position based dynamics is an integrator and a solver at the same time here is the algorithm for a set of particles the original pbd works these particles only they can be used to simulate cloths of bodies ropes hair fluids and more rigid objects can theoretically be simulated with particles as well but not in an elegant way we extended position-based dynamics to handle rigid bodies as single entities i will show you how in a later tutorial now let's assume we have a set of particles with positions x i and velocities vi we first perform the integration by iterating through all the particles for each particle we add gravity times the time step size delta t to the velocity then we store the current position in the previous position next we add delta t times the velocity to the current position next we iterate through all the constraints and solve each one finally we iterate through all the particles again and update the velocities as the current position minus the previous position divided by delta t solving a constraint means computing a correction vector delta x for all particles participating in the constraint after computing the correction vectors delta x we apply them to the current positions if multiple interwind constraints are present then solving them only once per time step yields stretchy objects implicit solvers typically run through all the constraints multiple times we can do that too by putting an iteration loop around the constraint solving loop in this case we run through all the constraints and times at each time step this indeed makes constraints less stretchy however we made a fascinating and very useful observation instead of spending the time on multiple iterations it is much better to run multiple sub steps in each sub step we solve all the constraints only once in this case we need to adjust the time step to be delta t over the number of sub steps the difference in convergence rate is really astonishing it made all our work on increasing conversions like hierarchical position-based dynamics or long-range attachment constraints obsolete there is an additional benefit of taking only one iteration in xpbd we need to keep track of a logarithmic multiplier per constraint this is not necessary if you use a single iteration let's start with a very simple constraint at distance constraint let's assume we have two particles at position x1 and x2 a rest distance l0 and the current distance l the particles have masses m1 and m2 we use the letter w to represent one over the mass in the position-based dynamics we simply move the particles such that the distance constraint of l being l0 is satisfied here are the two equations for the correction vectors delta x1 and delta x2 they look complicated but they're very simple this vector here is the vector from x1 to x2 normalized we multiply this vector by the error l minus l0 and then we distribute the error according to the inverse masses of the particles this makes sense let's assume one particle is attached to a wall then we assign a mass of infinity to this particle which corresponds to a w of 0. this means this particle is not moved at all and all the work is done by the other particle now let's have a look at how we can solve general constraints in this case we have a number of n particles that participate in the constraint first we define a constraint function which takes as input the positions of all the particles participating in the constraint this function produces a scalar value c which is the constraint error c is 0 exactly when the constraint is satisfied for a distance constraint we can define the constraint function as follows here we compute the actual distance between the particles and subtract the rest distance which is exactly zero when the constraint is satisfied now we need a very important concept the gradient of a constraint function let's assume we have a very simple constraint function which tells us that the distance between a particle and origin of the coordinate system needs to be l0 this simple diagram shows the situation here we have the origin of the coordinate system and here we have the particle for all positions on this circle the constraint is satisfied because the distance between this point and the origin of the coordinate system is l0 the locations where the constraint function is 1 is also a circle the same for the location where the constraint function is -1 the gradient of the constraint function is a vector it points into the direction in which c increases the most in our case this is the direction that points away from the origin the length of the gradient is how much c changes when we move x by one unit in our case if we move x by one unit the distance to the origin also increases by one unit now we can easily compute the gradient of our distance constraint function it's the vector x normalized now let's see how we can solve a general constraint using position based dynamics first we have to compute a scalar value lambda which is the same for all participating particles lambda can be computed as minus the constraint function evaluated at the current position divided by the sum of the inverse masses times the lengths of the gradients squared the gradient c i tells us how to move x i for a maximal increase of c this expression here is the squared length of the gradient c i once we have lambda we can easily compute the correction vector for each particle we take the gradient ci and multiplied by the inverse mass of the particle times lambda since these two are just scalars this means the correction vector points in the direction of the gradient since we want the constraint function to be zero we have to decrease it and that's the reason why we have a minus sign here so far we have only looked at hard constraints what if we want to make a constraint soft for instance to simulate a soft body in original position based dynamics we simply scaled the correction vectors by a scalar k k is a number between 0 and 1. if we set it to 0 we omit the constraint if we set it to 1 we have a hard constraint but we can select values between 0 and 1. this is very easy to tune however the effect of this scaling is dependent on the time step size constraints become stiffer for smaller time step sizes we fixed this problem with xpbt or extended position based dynamics fortunately it is very simple to apply correct physical stiffness all we need to do is add this little term to the computation of lambda here alpha is the compliance which is the inverse of physical stiffness if we set alpha to zero we have an infinitely stiff constraint and recover the original equation from position based dynamics now let me give you an example to show you that these equations are not as complicated as they seem what we're going to do is we're going to recover the equations for the distance constraint using the general formulas again we have two particles at position x1 and x2 and we want the mutual distance between the two particles to be l0 now the question is what are the gradients of this constraint function we have to ask how we have to move particle one to maximally increase the distance between the two particles obviously the direction of the gradient points along the line between the two particles the length of the gradient is one because if we move particle one by one unit the distance between the two particles also grows by one unit here are the equations how to compute the gradients what we do is we compute the vector between the two particles and normalize it now we can plug these two gradients into the computation of lambda we only have two terms because we only have two particles and the length of the gradients are one therefore we end up with w1 plus w2 in the denominator in the numerator we have to evaluate the constraint function at the current position this is the current distance between the two particles minus the rest distance once we have lambda we can compute the correction for particle one it's lambda times w1 times the gradient of particle one this is the equation for lambda here i put w1 and here is the gradient for particle one this is exactly the equation we had for the distance constraint the nice thing is that with the general equations we can now also formulate a volume conservation constraint such a constraint is important to simulate soft bodies for instance so let's assume we have a tetrahedron with adjacent particles 1 2 three and four the constraint function is six times the current volume of the tetrahedron minus its rest volume i put the six here to make the equations a little bit simpler however the constraint function is still zero exactly when the current volume is equal to the rest volume in tutorial 7 i showed you how to compute the volume of a tetrahedron using this equation we can now expand the constraint function to be a function of the positions of the four particles the question is what are the gradients of this function let's have a look at particle four the question is in which direction do we have to move the particle to maximally increase the volume obviously this direction is perpendicular to the base triangle we can compute the vector that is perpendicular to this triangle using a cross product here we compute the cross product of the vectors from particle 1 to 2 and particle 1 to 3. this cross product not only gives us the correct direction of the gradient but fortunately also the correct length with the right hand rule we can now compute the gradients of the constraint function with respect to all four particles these turn out to be very simple expressions now we can plug the constraint function as well as the gradients into our general equation for lambda once we have lambda we can now compute the correction vectors for all four particles adjacent to the tetrahedron to see these equations in action have a look at the upcoming tutorial about soft body simulation thanks for watching and i'll see you in the next tutorial
