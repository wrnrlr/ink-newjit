# Chapter 22 — How to Write a Basic Rigid Body Simulator Using Position Based Dynamics

**Video:** https://youtu.be/euypZDssYxE
**Slides:** https://matthias-research.github.io/pages/tenMinutePhysics/22-rigidBodies.pdf
**Code:** https://raw.githubusercontent.com/matthias-research/pages/master/tenMinutePhysics/22-rigidBodies.html

## Lecture Notes

### Rigid Body State

| Linear | Rotational |
|--------|-----------|
| position **x**, mass m | orientation quaternion **q** |
| velocity **v** | angular velocity **ω** |
| inverse mass w = 1/m | moment of inertia **I** (tensor) |

Rigid transform: **a'** = **x** + **q** ⊛ **a** (world ← local)
Inverse: **a** = **q**⁻¹ ⊛ (**a'** − **x**)

---

### Moment of Inertia

Torque **τ** = **I** · **α** (angular analogue of F = ma).
**I** is a 3×3 symmetric tensor; diagonal when aligned with principal axes.
Standard shapes (sphere I = ⅔mr²; box diagonal I = m/12(b²+c²), …).

---

### XPBD for Rigid Bodies

**Integration step:**

```
p_i ← x_i;  v_i ← v_i + Δt·g;  x_i ← x_i + Δt·v_i
q_prev ← q;  ω ← ω + h·I⁻¹·τ_ext
q ← q + ½h·[ω_x, ω_y, ω_z, 0]·q;  q ← normalize(q)
```

**Velocity update:**

```
v_i ← (x_i − p_i)/Δt
Δq ← q · q_prev⁻¹;  ω ← 2·[Δq_x, Δq_y, Δq_z]/Δt
if Δq_w < 0: negate ω
```

---

### Constraint Solver (XPBD)

Given attachment points **p**₁, **p**₂ (world space), constraint direction **n**, scalar C:

1. Generalized inverse mass:
   wᵢ = mᵢ⁻¹ + (**r**ᵢ × **n**)ᵀ **I**ᵢ⁻¹ (**r**ᵢ × **n**)   where **r**ᵢ = **p**ᵢ − **x**ᵢ

2. Lagrange multiplier (α = compliance = 1/stiffness):
   λ = −C · (w₁ + w₂ + α/Δt²)⁻¹

3. Update:
   **x**ᵢ ← **x**ᵢ ± λ wᵢ **n**
   **q**ᵢ ← **q**ᵢ ± ½λ [**I**ᵢ⁻¹(**r**ᵢ × **n**), 0] **q**ᵢ

λ**n**/Δt² is the constraint force.

---

### Distance Constraint (example)

**n** = (**a**₂ − **a**₁)/|**a**₂ − **a**₁|,   C = l − l₀

Apply the formulas above with **p**₁ = **a**₁, **p**₂ = **a**₂.

---

### Mouse Interaction

On click: intersect mouse ray with scene → **p**, store ray distance d and local point **r**.
On drag: update **p_m** along ray at depth d; update **p_b** = **x** + **q**⊛**r**; solve distance constraint between **p_m** and **p_b** (constraint = 0, so l₀ = 0).


## Video Transcript

hi M from 10minute physics here welcome to this video which marks the beginning of a new series on Rigid body simulation in this tutorial we're starting from square one I will guide you through writing your own rid body simulation from scratch using JavaScript that you can run right in your browser this lesson sets the stage for the various aspects of R body simulation we will cover in future videos whether you're curious beginner or season developer this Journey will be both educational and fun stay tuned for upcoming videos in this series we will dwell deeper into the various facets of rigid body simulation for now let's focus on mastering the basics here you see the JavaScript rigid body engine in action this simulation of a mobile shows two basic features we will discuss today the simulation of unconstraint rid body motion and handling distance constraints these constraints restrict the motion of pairs of bodies by maintaining the distance between two arbitrary points on the surface of the bodies we use the constraints to link the bars and the Spheres and for grabbing bodies with the mouse I will put a direct link to this demo and a link to all the demos and slides of the channel in the description now while our implementation is perfect for Learning and experimentation I want to give a quick shout out to two professional grade Solutions if you're working on a serious Project Check out Nvidia simulation engines which also Al support rigid bodies and are fully GPU accelerated there is physx for C++ projects and warp for python users these are powerful tools that can take your simulations to the next level warp supports Collision handling between complex shapes inverse kinematics the simulation of gyroscopic effects differential simulation for optimization rigid and soft body interaction height field fluids or fluids and SP simulations physx allows the simulation of complex structures it is used in real-time applications and games but also for robotic simulations and digital twins so now let's start with the first tutorial on Rigid body simulation if you search online for rigid body simulation techniques you might encounter intimidating equations like these does this mean rigid body simulation is only for math Wizards absolutely not in the following slides I'll introduce a much simpler and more intuitive method for simulating rigid bodies my Approach makes rigid body simulation accessible to a wider range of developers designers and enthusiasts not just mathematicians we will employ position based Dynamics an Innovative method I introduced in tutorial number nine this approach simplifies rid body simulation making it more accessible and intuitive in addition it is unconditionally stable meaning it never blows up even for infinite stiffnesses which makes it well suited for interactive applications in this tutorial I will briefly recap the method however for a thorough understanding I recommend watching tutorial number nine for those less familiar with Factor math tutorial number seven will equip you with the necessary background information the traditional position based Dynamics method uses particles here you see the simulation Loop in Zo your code in every time step we first perform an integration step we run through all the particles we add gravity times the time step size delta T to the velocity V Next we store the position X in the variable P then we add the velocity times the time step size to the position this integration method is called semi-implicit Oiler method after integrating we solve all the constraints a good example is the distance constraint it is used in cloths or soft body simulations the distance constraint makes sure that the distance between Pairs of particles equals the rest distance after solving all the constraints the velocities of the particles are updated the new velocity is set to the position after the solve minus the position before the solve divided by delta T in position based Dynamics we solve a constraint by Computing correction vectors Delta X for all the particles participating in a constraint these correction vectors are then immediately added to the particle positions after each constraint is solved position-based Dynamics manipulates particle positions directly contrasting with traditional methods that work with velocities or forces this direct manipulation of positions gives the method its name and contributes to its intuitive nature and stability let us have a look at the special case of a distance constraint here we have two particles with position X1 and X2 and masses M1 and M2 we use the letter W for the inverse Mass 1 / m l0 is the rest or Target length of the constraint and L its current length our goal is to move the particle such that the distance constraint is satisfied in this case we have to move them closer together to get the physics right we need to split the correction according to the inverse masses of the particles using inverse masses also provides a simple way to handle attachments to fixed objects by simply setting their inverse Mass to zero in this case the fixed attachment point won't move at all here you see the the formulas for the two correction vectors they're quite simple the vector X2 - X1 divided by its length is a normalized vector pointing from particle one to particle two multiplying it with the difference L minus l0 creates a correction Vector which enforces the distance between the particles to be l0 this Vector is then distributed between the particles proportional to their inverse masses transitioning from particle simulation to rigid body simulation is relatively straightforward a key advantage is that the rigid Body Center of mass behaves exactly like a particle with position x velocity V and mass m this similarity allows us to reuse the same code we developed for particles in addition to position and linear velocity a rigid body possesses three Key Properties an orientation Q an angle velocity Omega and the moment of inertia I let's examine each of these quantities individually we Define a local frame for each body the local frame has its origin at the center of mass of the body and the axis are aligned with the principal axis of the body the global pose of a rigid body is described by a position X and an orientation Q it defines how a point a in the local frame is transformed to a point a prime in the global coordinate frame these are the equations to go from the local to the global frame and vice versa in these equations Q is a querian and the star is the operation that rotates a vector using the querian fortunately you don't have to know the math of querian because virtually all simulation Frameworks provide a querian class we use three.js as in many previous tutorials here is my implementation in the constructure of the rigid body class I Define a member variable rot of the type ceran and its inverse the rigid body provides two methods one to go from local to global coordinates and one to go from Global back to local coordinates as you can see their implementations are quite simple and straightforward in addition to the veloc of the center of mass a rigid body has an angular velocity Omega which is a 3D Vector passing through the center of mass its length defines the speed of the rotation in angles per second its direction describes the axis of rotation the velocity of a point on the body can now be computed as Omega cross R if the body is in motion we have to add the velocity V of the center of mass as well the third additional quantity is the moment of inertia we have used Newton's second law fals ma many times before we use this equation to simulate the center of mass of the body solving for a shows that the mass disc crabs the resistance of the body to force for larger masses it takes a stronger Force to cause the same acceleration there's a rotational version of Newton Second Law as well T equals I * Alpha T is a torque which is an angle of force R cross F where R is the offset to the center of mass of the point where the force is applied applying a torque causes an angular acceleration Alpha solving for the angular acceleration shows that the moment of inertia describes the resistance of a body to torque for a larger moment of inertia it takes a larger torque to cause the same angular acceleration in three dimensions the resistance to a torque can vary in different directions here we have a cylinder whose height is larger than its diameter here the resistance to a torque that is applied perpendicular to the axis of the cylinder is larger than the resistance to a torque applied along the axis of the cylinder therefore we represent the moment of inertia by a 3X3 Matrix in a general pose of a rigid body all the elements of this Matrix are nonzero in general if we align the body with its principal Dimensions the tensor becomes diagonal and we can store it in a three-dimensional Vector this is what I do in my code then whenever the inertia tensor is present in an equation I transform all the quantities involved into the local frame of the body and perform the calculations there you can find the inertia tensor for various basic shapes on Wikipedia I will create another tutorial on how to compute the inertia tensor and other physical quantities for arbitrary triangle meeses now let's have a look at how we can extend the position based Dynamics algorithm to handle rigid Bodies In addition to handling the linear quantities X and V we must now also handle the rotational quantities Omega and Q we need to integrate them in time and update them after solving the constraints a constraint can now affect both the position and the orientation of the bodies therefore we compute updates Delta X and Delta Q for all bodies participating in the constraint then we apply them to the position X and the orientation Q here you see the extended integration step we integrate the position and velocity of the center of mass exactly as we integrated the position and velocity of particles in Orange you see how the orientation and angle of velocities are updated as for the position we store the orientation before for the solve next we apply an external torque to the angle velocity if necessary finally we update the orientation using the angle velocity the JavaScript code on the right shows that the integration step is quite easy to implement I won't derive any of those equations in this tutorial maybe I will create a future tutorial just about the mathematical derivations the update of the angle of velocity after the solve is quite easy to implement as well we first compute the transformation Delta Q that transforms the body from the frame before the solve into the frame after the solve then we turn this transformation into an angle of velocity I will now show you how to generalize a distance constraint to constraint the distance between two arbitrary points on two bodies let us first recap the distance constraint between two particles the constraint forces the distance between the particles to be l0 here the current distance L is larger than l0 therefore we move the particles towards each other we split theur Direction proportional to their inverse masses for two rigid bodies we specify the two attachment points relative to the center of mass by two vectors R1 and R2 to solve the constraint we need R1 and R2 to be in the global frame because we typically want the points to stay in the same location of the body we store R1 and R2 in the local frame of the bodies then to solve the constraint we rotate them back into the global frame using the body's current transformations in our example the current distance between the attachment point points is again larger than l0 therefore we pull attachment points toward each other doing this not only pulls the centers of mass closer together it also causes rotations of the bodies as shown in Orange the rotations are distributed proportional to the inverse moments of inertia I will now show you how to compute the position and orientation updates we are given the two vectors R1 and R2 in global space in addition we have a constraint Direction n and a constrainted distance C the following equations are enal and can be used for other constraints as a collision constraint for instance in the case of a distance constraint n is the normalized vector from A1 to A2 and C lus l0 first we compute a generalized inverse Mass wi for each body now we compute the scalar value Lambda which is called the L multiplier of the constraint here Alpha is compliance which is the inverse of physical stiffness having Lambda we can now update the positions and orientations of the two bodies in position-based Dynamics we do not work with forces however in certain situations we might be interested in the force acting on the constraint fortunately it is straightforward to compute this Force as Lambda * n / delta T ^ 2 this is a good point to explain the difference between position based Dynamics pbd and the extended version X pbd both are unconditionally stable which means they never blow up the difference is subtle it is a simple modification of the formula to compute Lambda the two methods differ in how to handle soft constraints pbd uses a scaler s between zero and one and simply scales the constraint updates to make a constraint soft this parameter is quite easy to tune one means infinite stiffness and zero disables the constraint however this way the effect depends on the time step size objects become stiffer for smaller time steps therefore s is not really a physical quantity fortunately this problem can be fixed in a surprisingly simple way by modif in the formula to compute Lambda the new formula is derived from explicit Oiler integration instead of scaling the constraint a new term Alpha ided Delta T squ is added to the denominator as mentioned on the previous slide Alpha is the compliance or the inverse of physical stiffness since it is the inverse of physical stiffness xpd can also handle infinite stiffness by simplying setting Alpha to zero for infinite stiffness pbd and X pbd are identical you can try this yourself itself in My Demo started the scene called chain wait until the simulation comes to rest I added quite a bit of damping in the scene as you can see the log multipliers yields the correct forces the force equals 10 times the weight below the constraint I chose gravity to be 10 m/s squared to get nicer values I set the compliance of the constraints to be 01 in this example as you can see in each link the elongation of the constraint is 01 times the force acting on it change time step size and the values remain the same the following implementation to handle distance constraints together with the code for integration and velocity update I showed before make up 90% of the implementation of the entire rigid body engine we first compute CN n then the inverse mass of the two bodies are computed next we compute Lambda using the X pbd formula finally the corrections are applied to the bodies the method to compute the generalized inverse mass of a body is a direct implementation of the equation I gave in the slides here you see how a correction is applied to a body this is the position update and here you see the orientation update on my last slide I show you how to use a distance constraint to drag objects with the mouse the 2D location of a mouse can be interpreted as a ray along the camera direction if if it intersects a body I comput the intersection point of the ray with the body I sort a distance D to the intersection point I also store a position p in the body's local frame as R then I create a distance constraint with zero rest length between the body and the fixed point in space located at p on the mouse move event I update the fixed Point using the new mouse aray and the stored distance D I also update the attachment point on the body using the current pose on Mouse up I simply dis disabl the constraint this concludes the tutorial I hope you enjoyed it and I'll see you in the next one

## Source Code

### 22-rigidBodies.html

```html
<!--
Copyright 2024 Matthias Müller - Ten Minute Physics, 
www.youtube.com/c/TenMinutePhysics
www.matthiasMueller.info/tenMinutePhysics

MIT License

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
-->


<!DOCTYPE html>
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<html lang="en">
	<head>
		<title>Rigid Body Simulation</title>
		<style>
			body {
				font-family: verdana; 
				font-size: 15px;
			}			
			.button {
                background-color: #606060;
                border: none;
                color: white;
                padding: 15px 32px;
                font-size: 16px;
                margin: 4px 2px;
                cursor: pointer;
		    }
            .styled-select {
                appearance: none;
                background-color: #606060;
                border: none;
                color: white;
                padding: 15px 32px;
                font-size: 16px;
                margin: 4px 2px;
                cursor: pointer;
            }
		</style>	
	</head>
	
	<body>

        <h1>Rigid Body Simulation</h1> 
		<button id = "startButton" onclick="onStart()" class="button">Start</button>
		<button id = "startRestart" onclick="onRestart()" class="button">Restart</button>

        Scene:

        <select id="sceneNumber" class="styled-select" onchange="onRestart()">
            <option value="0">Crib mobile</option>
            <option value="1">Chain</option>
        </select>

        Time step size:

        <select id="timeStep" class="styled-select" onchange="onRestart()">
            <option value="0.01">0.01</option>
            <option value="0.02" selected>0.02</option>
            <option value="0.05">0.05</option>
        </select>
        s
	
		<br><br>		
        <div id="container"></div>
        
        <script src="https://unpkg.com/three@0.139.2/build/three.min.js"></script>
        <script src="https://unpkg.com/three@0.139.2/examples/js/controls/OrbitControls.js"></script>
        <script src="https://unpkg.com/three@0.139.2/examples/js/geometries/TextGeometry.js"></script>
        <script src="https://unpkg.com/three@0.139.2/examples/js/loaders/FontLoader.js"></script>
        
        <script>

            var TextRenderer;

			// ------------------------------------------------------------------

			class RigidBody 
            {
                constructor(scene, type, size, density, pos, angles, fontSize = 0.0) 
                {
                    this.type = type;
                    this.size = new THREE.Vector3(size.x, size.y, size.z);
                    this.dt = 0.0;
                    this.damping = 0.0;

                    this.pos = new THREE.Vector3(pos.x, pos.y, pos.z);
                    this.rot = new THREE.Quaternion();
                    this.rot.setFromEuler(new THREE.Euler(angles.x, angles.y, angles.z));
                    this.vel = new THREE.Vector3(0.0, 0.0, 0.0);
                    this.omega = new THREE.Vector3(0.0, 0.0, 0.0);

                    this.prevPos = this.pos.clone();
                    this.prevRot = this.rot.clone();
                    this.dRot = new THREE.Quaternion();
                    this.invRot = this.rot.clone();
                    this.invRot.invert();

                    this.invMass = 0.0;
                    this.invInertia = new THREE.Vector3();

                    this.meshes = [];
                    this.vertices = null;
                    this.triIds = null;
                    let mass = 0.0;

                    if (type == "box") 
                    {
                        let mesh = new THREE.Mesh(
                            new THREE.BoxBufferGeometry(size.x, size.y, size.z),
                            new THREE.MeshPhongMaterial({ color: 0xffffff })
                        );
                        this.meshes.push(mesh);
                        if (density > 0.0)
                        {
                            mass = density * size.x * size.y * size.z;
                            this.invMass = 1.0 / mass;
                            let Ix = 1.0 / 12.0 * mass * (size.y * size.y + size.z * size.z);
                            let Iy = 1.0 / 12.0 * mass * (size.x * size.x + size.z * size.z);
                            let Iz = 1.0 / 12.0 * mass * (size.x * size.x + size.y * size.y);
                            this.invInertia.set(1.0 / Ix, 1.0 / Iy, 1.0 / Iz);
                        }
                        let ex = 0.5 * size.x;
                        let ey = 0.5 * size.y;
                        let ez = 0.5 * size.z;

                        this.vertices = new Float32Array([
                            -ex, -ey, -ez,
                            ex, -ey, -ez,
                            ex, ey, -ez,
                            -ex, ey, -ez,
                            -ex, -ey, ez,
                            ex, -ey, ez,
                            ex, ey, ez,
                            -ex, ey, ez
                        ]);
                    }
                    else if (type == "sphere") 
                    {
                        let hemiSphere0 = new THREE.Mesh(
                            new THREE.SphereBufferGeometry(size.x, 32, 32, 0.0, Math.PI),
                            new THREE.MeshPhongMaterial({ color: 0xffffff })
                        );
                        let hemiSphere1 = new THREE.Mesh(
                            new THREE.SphereBufferGeometry(size.x, 32, 32, Math.PI, Math.PI),
                            new THREE.MeshPhongMaterial({ color: 0xff0000 })
                        );
                        this.meshes.push(hemiSphere0);
                        this.meshes.push(hemiSphere1);
                        if (density > 0.0)
                        {
                            mass = 4.0 / 3.0 * Math.PI * size.x * size.x * size.x * density;
                            this.invMass = 1.0 / mass;
                            let I = 2.0 / 5.0 * mass * size.x * size.x;
                            this.invInertia.set(1.0 / I, 1.0 / I, 1.0 / I);
                        }
                    }

                    for (let i = 0; i < this.meshes.length; i++) {
                        let mesh = this.meshes[i];
                        mesh.body = this;		// for raycasting
                        mesh.layers.enable(1);
                        mesh.castShadow = true;
				        mesh.receiveShadow = true;
                        scene.add(mesh);
                    }

                    // Create text renderer for mass display
                    this.textRenderer = null;
                    if (fontSize > 0.0) {
                        this.textRenderer = new TextRenderer(scene, fontSize);
                        this.textRenderer.loadFont().then(() => {
                            this.textRenderer.createText(`                      ${mass.toFixed(1)} kg`, this.meshes[0].position);
                        });
                    }
                    
                    this.updateMeshes();
                }

                updateMeshes()
                {
                    for (let i = 0; i < this.meshes.length; i++)
                    {
                        this.meshes[i].position.copy(this.pos);
                        this.meshes[i].quaternion.copy(this.rot);
    					this.meshes[i].geometry.computeBoundingSphere();
                    }
                    
                    if (this.textRenderer) {
                        this.textRenderer.updatePosition(this.meshes[0].position);
                        this.textRenderer.updateRotation(gCamera.quaternion);
                    }           
                }                

                // begin simulation functions

                localToWorld(localPos, worldPos)
                {
                    worldPos.copy(localPos);
                    worldPos.applyQuaternion(this.rot);
                    worldPos.add(this.pos);
                }

                worldToLocal(worldPos, localPos)
                {
                    localPos.copy(worldPos);
                    localPos.sub(this.pos);
                    localPos.applyQuaternion(this.invRot);
                }

                integrate(dt, gravity)
                {
                    this.dt = dt;

                    if (this.invMass == 0.0)
                        return;

                    // linear motion
                    this.prevPos.copy(this.pos);
                    this.vel.addScaledVector(gravity, dt);
                    this.pos.addScaledVector(this.vel, dt);

                    // angular motion
                    this.prevRot.copy(this.rot);
                    this.dRot.set(
                        this.omega.x,
                        this.omega.y,
                        this.omega.z,
                        0.0
                    );
                    this.dRot.multiply(this.rot);
                    this.rot.x += 0.5 * dt * this.dRot.x;
                    this.rot.y += 0.5 * dt * this.dRot.y;
                    this.rot.z += 0.5 * dt * this.dRot.z;
                    this.rot.w += 0.5 * dt * this.dRot.w;
                    this.rot.normalize();
                    this.invRot.copy(this.rot);
                    this.invRot.invert();
                }

                updateVelocities()
                {   
                    if (this.invMass == 0.0)
                        return;

                    // linear motion
                    this.vel.subVectors(this.pos, this.prevPos);
                    this.vel.multiplyScalar(1.0 / this.dt);

                    // angular motion
                    this.prevRot.invert();
                    this.dRot.multiplyQuaternions(this.rot, this.prevRot);
                    this.omega.set(
                        this.dRot.x * 2.0 / this.dt,
                        this.dRot.y * 2.0 / this.dt,
                        this.dRot.z * 2.0 / this.dt
                    );
                    if (this.dRot.w < 0.0)
                        this.omega.negate();
                    
                    this.vel.multiplyScalar(Math.max(1.0 - this.damping * this.dt, 0.0));
                }

                getInverseMass(normal, pos)
                {
                    if (this.invMass == 0.0)
                        return 0.0;

                    let rn = normal.clone();

                    if (pos == undefined)  // angular case
                    {
                        rn.applyQuaternion(this.invRot);
                    }
                    else            // linear case
                    {
                        rn.subVectors(pos, this.pos);
                        rn.cross(normal);
                        rn.applyQuaternion(this.invRot);
                    }

                    let w = 
                        rn.x * rn.x * this.invInertia.x + 
                        rn.y * rn.y * this.invInertia.y + 
                        rn.z * rn.z * this.invInertia.z;

                    if (pos != undefined)
                        w += this.invMass;
                 
                    return w;
                }

                _applyCorrection(corr, pos)
                {
                    if (this.invMass == 0.0)
                        return;

                    // linear correction

                    this.pos.addScaledVector(corr, this.invMass);

                    // angular correction

                    let dOmega = corr.clone();

                    dOmega.subVectors(pos, this.pos);
                    dOmega.cross(corr);
                    dOmega.applyQuaternion(this.invRot);
                    dOmega.multiply(this.invInertia);
                    dOmega.applyQuaternion(this.rot);

                    this.dRot.set(
                        dOmega.x,
                        dOmega.y,
                        dOmega.z,
                        0.0
                    );

                    this.dRot.multiply(this.rot);
                    this.rot.x += 0.5 * this.dRot.x;
                    this.rot.y += 0.5 * this.dRot.y;
                    this.rot.z += 0.5 * this.dRot.z;
                    this.rot.w += 0.5 * this.dRot.w;
                    this.rot.normalize();
                    this.invRot.copy(this.rot);
                    this.invRot.invert();
                }

                applyCorrection(compliance, corr, pos, otherBody, otherPos)
                {
                    if (corr.lengthSq() == 0.0)
                        return;

                    let C = corr.length();
                    let normal = corr.clone();
                    normal.normalize();

                    let w = this.getInverseMass(normal, pos);
                    if (otherBody != undefined)
                        w += otherBody.getInverseMass(normal, otherPos);

                    if (w == 0.0)
                        return;

                    // XPBD
                    let alpha = compliance / this.dt / this.dt;
                    let lambda = -C / (w + alpha);
                    normal.multiplyScalar(-lambda);

                    this._applyCorrection(normal, pos);
                    if (otherBody != undefined) {
                        normal.multiplyScalar(-1.0);
                        otherBody._applyCorrection(normal, otherPos);
                    }
                    return lambda / this.dt / this.dt;
                }

                // end simulation functions

                dispose() {
                    for (let i = 0; i < this.meshes.length; i++) {
                        if (this.meshes[i].geometry) this.meshes[i].geometry.dispose();
                        if (this.meshes[i].material) this.meshes[i].material.dispose();
                        gThreeScene.remove(this.meshes[i]);
                    }
                    if (this.textRenderer) {
                        this.textRenderer.dispose();
                    }
                }
            }


            class DistanceConstraint {
                constructor(scene, body0, body1, pos0, pos1, distance, compliance, unilateral, width = 0.01, fontSize = 0.0, color = 0xff0000) {
                    this.scene = scene;
                    this.body0 = body0;
                    this.body1 = body1;
                    this.unilateral = unilateral;
            
                    this.worldPos0 = pos0.clone();
                    this.worldPos1 = pos1.clone();
                    this.localPos0 = pos0.clone();
                    this.localPos1 = pos1.clone();
            
                    this.body0.worldToLocal(pos0, this.localPos0);
                    if (body1 != undefined)
                        this.body1.worldToLocal(pos1, this.localPos1);
            
                    this.distance = distance;
                    this.compliance = compliance;
            
                    this.corr = new THREE.Vector3();
            
                    // Create a cylinder for visualization
                    const geometry = new THREE.CylinderGeometry(width, width, 1, 32);
                    const material = new THREE.MeshBasicMaterial({ color: color });
                    this.cylinder = new THREE.Mesh(geometry, material);
                    this.cylinder.castShadow = true;
                    this.cylinder.receiveShadow = true;
                    scene.add(this.cylinder);
            
                    // Create text renderer for force display
                    this.textRenderer = null;
                    if (fontSize > 0.0) {
                        this.textRenderer = new TextRenderer(scene, fontSize);
                        this.textRenderer.loadFont().then(() => {
                            this.updateText(0, 1);
                            this.updateMesh();
                        });
                    }
            
                    this.updateMesh();
                }
            
                solve() {
                    this.body0.localToWorld(this.localPos0, this.worldPos0);
                    if (this.body1 != undefined)
                        this.body1.localToWorld(this.localPos1, this.worldPos1);
                    this.corr.subVectors(this.worldPos1, this.worldPos0);
                    let distance = this.corr.length();
                    this.corr.normalize();
                    if (this.unilateral && distance < this.distance)
                        return;
                    this.corr.multiplyScalar(distance - this.distance);
                    let force = this.body0.applyCorrection(this.compliance, this.corr, this.worldPos0, this.body1, this.worldPos1);
                    
                    let elongation = distance - this.distance;
                    elongation = Math.round(elongation * 100) / 100;
                    this.updateText(Math.abs(force), elongation);
                }                
            
                updateMesh() {
                    const start = this.worldPos0;
                    const end = this.worldPos1;
            
                    // Calculate the center point
                    const center = new THREE.Vector3().addVectors(start, end).multiplyScalar(0.5);
            
                    // Calculate the direction vector
                    const direction = new THREE.Vector3().subVectors(end, start);
                    const length = direction.length();
            
                    // Create a rotation quaternion
                    const quaternion = new THREE.Quaternion();
                    quaternion.setFromUnitVectors(new THREE.Vector3(0, 1, 0), direction.normalize());
            
                    // Update cylinder's transformation
                    this.cylinder.position.copy(center);
                    this.cylinder.setRotationFromQuaternion(quaternion);
                    this.cylinder.scale.set(1, length, 1);
            
                    // Update text position and rotation
                    if (this.textRenderer) {
                        this.textRenderer.updatePosition(center);
                        this.textRenderer.updateRotation(gCamera.quaternion);
                    }
                }
            
                updateText(force, elongation) {
                    if (this.textRenderer) {
                        this.textRenderer.createText(`   ${Math.round(force)} N,  ${elongation} m`, this.cylinder.position);
                    }
                }
            
                dispose() {
                    if (this.cylinder) {
                        if (this.cylinder.geometry) this.cylinder.geometry.dispose();
                        if (this.cylinder.material) this.cylinder.material.dispose();
                        this.scene.remove(this.cylinder);
                    }
                    if (this.textRenderer) {
                        this.textRenderer.dispose();
                    }
                }
            }            
			
			// ------------------------------------------------------------------

            class RigidBodySimulator 
            {
				constructor(scene, timeStepSize, gravity)
				{
                    this.scene = scene;
                    this.gravity = gravity.clone();
                    this.dt = timeStepSize;
                    this.numSubSteps = 10;
                    this.numIterations = 1;
                    this.rigidBodies = [];
                    this.distanceConstraints = [];

                    this.dragConstraint = null;
                    this.dragCompliance = 0.001;
                }

                addRigidBody(rigidBody)
                {
                    this.rigidBodies.push(rigidBody);
                }

                addDistanceConstraint(distanceConstraint)
                {
                    this.distanceConstraints.push(distanceConstraint);
                }

				simulate()
				{
                    let sdt = this.dt / this.numSubSteps;

                    for (let subStep = 0; subStep < this.numSubSteps; subStep++)
                    {
                        for (let i = 0; i < this.rigidBodies.length; i++)
                            this.rigidBodies[i].integrate(sdt, this.gravity);

                        for (let i = 0; i < this.distanceConstraints.length; i++)
                            this.distanceConstraints[i].solve();

                        if (this.dragConstraint)
                            this.dragConstraint.solve();

                        for (let i = 0; i < this.rigidBodies.length; i++)
                        {
                            this.rigidBodies[i].updateVelocities(sdt);
                        }
                    }
                    for (let i = 0; i < this.rigidBodies.length; i++)
                        this.rigidBodies[i].updateMeshes();

                    for (let i = 0; i < this.distanceConstraints.length; i++)
                        this.distanceConstraints[i].updateMesh();

                    if (this.dragConstraint)
                        this.dragConstraint.updateMesh();
				}

                startDrag(body, pos)
                {
                    this.dragConstraint = new DistanceConstraint(this.scene, body, null, pos, pos, 0.0, this.dragCompliance);
                }

                drag(pos)
                {
                    if (this.dragConstraint)
                        this.dragConstraint.worldPos1.copy(pos);
                }

                endDrag(pos)
                {
                    if (this.dragConstraint)
                    {
                        this.dragConstraint.dispose();
                        this.dragConstraint = null;
                    }
                }

                dispose()
                {
                    for (let i = 0; i < this.rigidBodies.length; i++)
                        this.rigidBodies[i].dispose();

                    for (let i = 0; i < this.distanceConstraints.length; i++)
                        this.distanceConstraints[i].dispose();

                    if (this.dragConstraint)
                        this.dragConstraint.dispose();
                }
            }

            // ------------------------------------------------------------------

            var gThreeScene;
			var gCamera;
			var gCameraControl;
            var gRaycaster;
            var gSimulator;
            var gPaused = true;

            function random(min, max)
            {
                return min + Math.random() * (max - min)
            }

            function initScene(nr) 
            {
                let gravity = new THREE.Vector3(0, -10.0, 0);
                let timeStepSize = parseFloat(document.getElementById("timeStep").value);
                gSimulator = new RigidBodySimulator(gThreeScene, timeStepSize, gravity);

                let density = 1000.0;

                if (nr == 0)
                {
                    let unilateral = true;
                    let compliance = 0.0;
                    let length = 0.9;
                    let thickness = 0.04;
                    let height = 0.3;
                    let baseRadius = 0.08;
                    let distance = 0.5 * length - thickness
                    let barSize = new THREE.Vector3(length, thickness, thickness);
                    let angles = new THREE.Vector3(0.0, 0.0, 0.0);
                    let barPos = new THREE.Vector3(0.0, 2.5, 0.0);
                    let prevBar = null;

                    let numLevels = 5;

                    let volBar = length * thickness * thickness;
                    let volTree = 2.0 * 4.0 / 3.0 * Math.PI * baseRadius * baseRadius * baseRadius + volBar;

                    let radii = [baseRadius];

                    for (let i = 1; i < numLevels; i++)
                    {
                        // sphere of volume volTree
                        radius = Math.pow(3.0 / 4.0 / Math.PI * volTree, 1.0 / 3.0);
                        radii.push(radius);
                        volTree = 2.0 * volTree + volBar;
                    }

                    for (let i = 0; i < numLevels; i++)
                    {
                        let radius = radii[numLevels - i - 1];
                        let bar = new RigidBody(gThreeScene, "box", barSize, density, barPos, angles);
                        gSimulator.addRigidBody(bar);

                        let p0 = new THREE.Vector3(barPos.x, barPos.y + 0.5 * thickness, barPos.z);
                        let p1 = new THREE.Vector3(barPos.x, barPos.y + height - 0.5 * thickness, barPos.z);
                        let barConstraint = new DistanceConstraint(gThreeScene, bar, prevBar, p0, p1, height - thickness, compliance, unilateral);
                        gSimulator.addDistanceConstraint(barConstraint);

                        let spherePos = new THREE.Vector3(barPos.x + distance, barPos.y - height, barPos.z);
                        let sphereSize = new THREE.Vector3(radius, radius, radius); 
                        let sphere = new RigidBody(gThreeScene, "sphere", sphereSize, density, spherePos, angles);
                        gSimulator.addRigidBody(sphere);

                        p0 = new THREE.Vector3(spherePos.x, spherePos.y + 0.5 * radius, spherePos.z);
                        p1 = new THREE.Vector3(spherePos.x, spherePos.y + height - 0.5 * thickness, spherePos.z);
                        let sphereConstraint = new DistanceConstraint(gThreeScene, sphere, bar, p0, p1, height - thickness, compliance, unilateral);
                        gSimulator.addDistanceConstraint(sphereConstraint);

                        if (i == numLevels - 1)
                        {
                            spherePos.x -= 2.0 * distance;
                            sphere = new RigidBody(gThreeScene, "sphere", sphereSize, density, spherePos, angles);
                            gSimulator.addRigidBody(sphere);
                            p0.x -= 2.0 * distance;
                            p1.x -= 2.0 * distance;
                            sphereConstraint = new DistanceConstraint(gThreeScene, sphere, bar, p0, p1, height - thickness, compliance, unilateral);
                            gSimulator.addDistanceConstraint(sphereConstraint);
                        }

                        prevBar = bar;
                        barPos.y -= height;
                        barPos.x -= distance;
                    }
                }
                else {
                    let unilateral = false;
                    let compliance = 0.001;
                    let boxSize = new THREE.Vector3(0.1, 0.1, 0.1);
                    let boxPos = new THREE.Vector3(0.0, 2.5, 0.0);
                    let boxAngles = new THREE.Vector3(0.0, 0.0, 0.0);
                    let width = 0.01;
                    let fontSize = 0.03;
                    let dist = 0.2;
                    let prevY = 2.5;
                    let prevSize = 0.0;
                    let prevBox = null;

                    for (let level = 0; level < 4; level++)
                    {
                        prevY = boxPos.y;
                        boxPos.y -= dist + boxSize.y;
                        let box = new RigidBody(gThreeScene, "box", boxSize, density, boxPos, boxAngles, fontSize);
                        box.damping = 5.0;
                        gSimulator.addRigidBody(box);
    
                        let p0 = new THREE.Vector3(0.4 * prevSize, boxPos.y + 0.5 * boxSize.y, 0.0);
                        let p1 = new THREE.Vector3(0.4 * prevSize, prevY - 0.5 * prevSize, 0.0);
                        let barConstraint = new DistanceConstraint(gThreeScene, box, prevBox, p0, p1, p1.y - p0.y, compliance, unilateral, width, fontSize);
                        gSimulator.addDistanceConstraint(barConstraint);

                        prevBox = box;
                        prevSize = boxSize.y;
                        boxSize.multiplyScalar(Math.cbrt(2.0));
                    }



                }
            }

			// ------------------------------------------
					
			function initThreeScene() {
                gThreeScene = new THREE.Scene();
                
                // Lights
                gThreeScene.add(new THREE.AmbientLight(0x505050));
                gThreeScene.fog = new THREE.Fog(0x000000, 0.0, 15.0);

                var spotLight = new THREE.SpotLight(0xffffff);
                spotLight.angle = Math.PI / 5;
                spotLight.penumbra = 0.2;
                spotLight.position.set(2, 3, 2);
                gThreeScene.add(spotLight);

                var dirLight = new THREE.DirectionalLight(0x55505a, 1);
                dirLight.position.set(0, 10, 0); 
                dirLight.castShadow = true;
                dirLight.shadow.camera.near = 1;
                dirLight.shadow.camera.far = 20; 

                dirLight.shadow.camera.right = 10;
                dirLight.shadow.camera.left = -10;
                dirLight.shadow.camera.top = 10;
                dirLight.shadow.camera.bottom = -10;

                dirLight.shadow.mapSize.width = 2048; 
                dirLight.shadow.mapSize.height = 2048;
                dirLight.shadow.blurSamples = 10;
                dirLight.shadow.radius = 2.0;  
                gThreeScene.add(dirLight);
                
                // Geometry
                var ground = new THREE.Mesh(
                    new THREE.PlaneBufferGeometry(50.0, 50.0),
                    new THREE.MeshPhongMaterial({ color: 0xa0adaf, shininess: 150 })
                );

                ground.rotation.x = -Math.PI / 2; // rotates X/Y to X/Z
                ground.receiveShadow = true;
                gThreeScene.add(ground);
                            
                // Renderer
                gRenderer = new THREE.WebGLRenderer({ antialias: true });
                gRenderer.shadowMap.enabled = true;
                gRenderer.shadowMap.type = THREE.PCFSoftShadowMap;  // Softer shadows
                gRenderer.setPixelRatio(window.devicePixelRatio);
                gRenderer.setSize(0.8 * window.innerWidth, 0.8 * window.innerHeight);
                window.addEventListener('resize', onWindowResize, false);
                container.appendChild(gRenderer.domElement);
                
                // Camera
                gCamera = new THREE.PerspectiveCamera(70, window.innerWidth / window.innerHeight, 0.01, 100);
                gCamera.position.set(0, 2.5, 2.5);
                gCamera.updateMatrixWorld();
                gThreeScene.add(gCamera);

                gCameraControl = new THREE.OrbitControls(gCamera, gRenderer.domElement);
                gCameraControl.zoomSpeed = 2.0;
                gCameraControl.panSpeed = 0.4;
                gCameraControl.target = new THREE.Vector3(0.0, 1.2, 0.0);
                gCameraControl.update();

                gRaycaster = new THREE.Raycaster();
                gRaycaster.layers.set(1);
                gRaycaster.params.Line.threshold = 0.1;
            }

            TextRenderer = class {
                constructor(scene, fontSize = 0.05) {
                    this.scene = scene;
                    this.font = null;
                    this.textMesh = null;
                    this.fontSize = fontSize;
                    this.fontHeight = 0.0001;
                    this.loadFont();
                }
            
                loadFont() {
                    return new Promise((resolve, reject) => {
                        const loader = new THREE.FontLoader();
                        loader.load(
                            'https://threejs.org/examples/fonts/helvetiker_regular.typeface.json',
                            font => {
                                this.font = font;
                                resolve();
                            },
                            undefined,
                            reject
                        );
                    });
                }
            
                createText(text, position, color = 0xffffff) {
                    if (this.textMesh) {
                        this.scene.remove(this.textMesh);
                        if (this.textMesh.geometry) this.textMesh.geometry.dispose();
                        if (this.textMesh.material) this.textMesh.material.dispose();
                    }
            
                    if (!this.font) return;  // If font hasn't loaded yet, skip creating text
            
                    const textGeometry = new THREE.TextGeometry(text, {
                        font: this.font,
                        size: this.fontSize,
                        height: this.fontHeight,
                    });
                    const textMaterial = new THREE.MeshBasicMaterial({ color: color });
                    this.textMesh = new THREE.Mesh(textGeometry, textMaterial);
                    this.textMesh.position.copy(position);
                    this.scene.add(this.textMesh);
                }
            
                updatePosition(position) {
                    if (this.textMesh) {
                        this.textMesh.position.copy(position);
                    }
                }
            
                updateRotation(quaternion) {
                    if (this.textMesh) {
                        this.textMesh.quaternion.copy(quaternion);
                    }
                }
            
                dispose() {
                    if (this.textMesh) {
                        if (this.textMesh.geometry) this.textMesh.geometry.dispose();
                        if (this.textMesh.material) this.textMesh.material.dispose();
                        this.scene.remove(this.textMesh);
                    }
                }
            }            

			// ------------------------------------------------------

			function onWindowResize() {

				gCamera.aspect = window.innerWidth / window.innerHeight;
				gCamera.updateProjectionMatrix();
				gRenderer.setSize( window.innerWidth, window.innerHeight );
			}

			function onStart() {
				var button = document.getElementById("startButton");
				if (gPaused)
					button.innerHTML = "Stop";
				else
					button.innerHTML = "Start";
				gPaused = !gPaused;
			}

			function onRestart() {
                if (!gPaused)
                    onStart();

                gSimulator.dispose();
                let sceneNr = parseInt(document.getElementById("sceneNumber").value);
                initScene(sceneNr);
			}

            var gPointerInfo = 
            { 
                mousePos : new THREE.Vector2(),
                worldPos : new THREE.Vector3(),
                distance : 0.0,
            };
            
            function onPointer( evt ) 
			{
				event.preventDefault();

                var rect = gRenderer.domElement.getBoundingClientRect();
				gPointerInfo.mousePos.x = ((evt.clientX - rect.left) / rect.width ) * 2 - 1;
				gPointerInfo.mousePos.y = -((evt.clientY - rect.top) / rect.height ) * 2 + 1;
                gRaycaster.setFromCamera(gPointerInfo.mousePos, gCamera);

				if (evt.type == "pointerdown") {
                    var intersects = gRaycaster.intersectObjects(gThreeScene.children);
					if (intersects.length > 0) {
                        gPointerInfo.distance = intersects[0].distance;
                        gPointerInfo.worldPos.copy(gRaycaster.ray.origin);
                        gPointerInfo.worldPos.addScaledVector(gRaycaster.ray.direction, gPointerInfo.distance);
                        gPointerInfo.body = intersects[0].object.body;
                        if (gPointerInfo.body)
                        {
                            gCameraControl.saveState();
						    gCameraControl.enabled = false;
                            gSimulator.startDrag(gPointerInfo.body, gPointerInfo.worldPos);
                            if (gPaused)
                                onStart(); 
                        }
                        else
                            gPointerInfo.body = null;
                    }
				}
				else if (evt.type == "pointermove" && gPointerInfo.body != null) {
                    gPointerInfo.worldPos.copy(gRaycaster.ray.origin);
                    gPointerInfo.worldPos.addScaledVector(gRaycaster.ray.direction, gPointerInfo.distance);
                    gSimulator.drag(gPointerInfo.worldPos);
				}
				else if (evt.type == "pointerup") {
                    if (gPointerInfo.body != null)
                    {
                        gSimulator.endDrag();
                        gPointerInfo.body = null;
                        gCameraControl.reset();
                    }
                    gCameraControl.enabled = true;
                }
			}	

            container.addEventListener( 'pointerdown', onPointer, false );
			container.addEventListener( 'pointermove', onPointer, false );
			container.addEventListener( 'pointerup', onPointer, false );

			// make browser to call us repeatedly -----------------------------------

			function update() {
				if (!gPaused) {
                    gSimulator.simulate();
                }
				gRenderer.render(gThreeScene, gCamera);
				requestAnimationFrame(update);
			}
					
			initThreeScene();
			onWindowResize();
            let sceneNr = parseInt(document.getElementById("sceneNumber").value);
			initScene(sceneNr);
			update();
			
		</script>
	</body>
</html>

```
