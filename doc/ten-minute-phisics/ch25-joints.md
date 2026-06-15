# Chapter 25 — Joint Simulation Made Simple

**Video:** https://youtu.be/YVaQxeWGlJA
**Slides:** https://matthias-research.github.io/pages/tenMinutePhysics/25-joints.pdf
**Code:** https://raw.githubusercontent.com/matthias-research/pages/master/tenMinutePhysics/25-joints.html

## Lecture Notes

### Overview

Joint simulation using **XPBD** (ch09, ch22). XPBD replaces large complementarity-problem solvers with simple forward formulas. Requires rigid-body simulation from ch22.

**Key advantage:** unconditionally stable, simple forward execution, physically derived.

---

### Two Primitive Operations

**ApplyLinearCorrection(p₁, p₂, Δp, α)**
- C ← |Δp|, **n** ← Δp/|Δp|
- wᵢ ← mᵢ⁻¹ + (**rᵢ** × **n**)ᵀ **I**ᵢ⁻¹ (**rᵢ** × **n**)
- λ ← −C · (w₁ + w₂ + α/Δt²)⁻¹
- **xᵢ** ← **xᵢ** ± λ**n** mᵢ⁻¹
- **qᵢ** ← **qᵢ** ± ½λ [**I**ᵢ⁻¹(**rᵢ** × **n**), 0] **qᵢ**

**ApplyAngularCorrection(Δφ, α)**
- C ← |Δφ|, **n** ← Δφ/|Δφ|
- wᵢ ← **n**ᵀ **I**ᵢ⁻¹ **n**
- λ ← −C · (w₁ + w₂ + α/Δt²)⁻¹
- **qᵢ** ← **qᵢ** ± ½λ [**I**ᵢ⁻¹**n**, 0] **qᵢ**

α = 0: infinitely stiff. Compliance α = 1/stiffness for soft constraints.

---

### Three Building Blocks

**Attach(p₁, p₂, d_rest, α):** pull two world-space points to distance d_rest.

**RestrictToAxis(a, p₁, p₂, p_min, p_max, α):** remove components of (p₂ − p₁) perpendicular to axis **a**; clamp the projection to [p_min, p_max].

**AlignAxes(a₁, a₂, α):** apply ApplyAngularCorrection(−**a₁** × **a₂**, α).

**LimitAngle(n, a₁, a₂, φ_min, φ_max, α):** compute signed angle φ between a₁ and a₂ around **n**; if outside limits, clamp and drive a₂ to the clamped target.

---

### Joint Types (all built from blocks above)

| Joint | Calls |
|-------|-------|
| **Hinge** (1 rot DOF) | Attach + AlignAxes + LimitAngle |
| **Servo** | Hinge with φ_min = φ_max = φ_target |
| **Velocity motor** | Servo with φ_target advancing by ω·Δt each step |
| **Ball & socket** (3 rot DOF) | Attach + LimitAngle(swing) + LimitAngle(twist) |
| **Prismatic** (1 trans DOF) | RestrictToAxis + AlignAxes + LimitAngle |
| **Cylinder** | RestrictToAxis(position) + AlignAxes + LimitAngle(rotation) |

---

### Velocity-Level Corrections (forces, torques, damping)

After the position step, apply velocity corrections:

**ApplyTorque(τ):** call ApplyAngularVelocityCorrection(τ/Δt · **a**)

**ApplyForce(f):** call ApplyLinearVelocityCorrection(p₁, p₂, f/Δt · **a**)

**DampLinear / DampAngular:** compute relative velocity at contact point, scale by min(Δt·c, 1), apply velocity correction to remove it.


## Video Transcript

Hi, Mus from 10-minute physics here. Today, I will talk about the core subject in VGO simulation, the simulation of joints. With this knowledge, you will be able to simulate almost any mechanical system you can think of, such as cars or robots. Many existing techniques are complex and hard to understand. I will show you a simple method that is also more robust than many existing techniques.

I will cover an entire subject in only 15 minutes. However, I will include the source code as well as the slides. so you can go at your own pace. This is my simulation demo. As usual, I wrote it in JavaScript so you can run it directly in your browser.

I will put a link to the demo and the source code in the description. This is a hinge joint with angle limits. Here we have the same hinge joint damped. This is a ball and socket joint with swing and twist limits. Here we have a prismatic joint with a target offset and a given stiffness.

And here the same joint damped. These three joints can be controlled. We have a motor, a servo and a cylinder joint. I can control them with this simple touch interface. With these basic joints, we can create any mechanical system we like.

Here you see the steering mechanism of a car. I created this setup in Blender with custom parameters. In the next tutorial, I will show you my Blender exporter and importer so you can create your own cool demos. This final scene shows the power of position based simulation with substepping. Here we have a double pendulum.

There's very little numerical damping. This is a triple pendulum. Position based dynamics allows the resolution of the fastmoving third segment. This demo shows how position based dynamics can handle very large mass ratios. The mass of the box at the bottom is 200 times the mass of the segments.

Now let me show you how joint simulation works. We will employ extended positionbased dynamics which I introduced in tutorial number nine. This method is very simple to implement and unconditionally stable meaning it never blows up even for infinite stiffnesses which makes it well suited for interactive applications. Unlike the original positionbased dynamics method, extended positionbased dynamics is physically based and it lets us handle true physical quantities like forces, torqus and stiffnesses with high fidelity. Traditional rigid body simulation methods require solving complicated large systems of complimentarity problems.

In contrast with XPBD, all we need to do is executing simple formulas that are easy to understand. To make the tutorial self-contained, I will give you a short recap of rigid body simulation with XPBD. Have a look at tutorial number 22 for a detailed explanation. The traditional positionbased dynamics method uses particles. Here you see the simulation loop in pseudo code.

In every time step, we first perform what is called an integration step. We run through all the particles. We add gravity times the time step size delta t to the velocity. Next, we store the position x in a variable p. Then we add the velocity times the time step size to the position.

This integration method is called semi-implicit oiler method. After integration, we solve all constraints. We repeat this for a given number of iterations. One of the most used constraints is a distance constraint. It is used in cloth and soft body simulations.

The distance constraint makes sure that the distance between pairs of particles equals the rest distance. After solving all constraints, the velocities of the particles are updated. The new velocity is set to the position after the solve minus the position before the solve divided by delta t. In position based dynamics, we solve a constraint by computing correction vectors delta x for all the particles participating in the constraint. These correction vectors are then immediately added to the particle positions after each constraint is solved.

Position-based dynamics manipulates particle positions directly, contrasting with traditional methods that work with velocities or forces. This direct manipulation of positions gives the method its name and contributes to its intuitive nature and stability. What I showed you is called a local solver. It solves each constraint one at a time. Local solvers are much easier to implement and understand than global solvers.

Global solvers solve all the constraints simultaneously. The only disadvantage of local solvers is that they converge more slowly which makes joints look stretchy. Fortunately, there's a super simple method to solve this problem. In the algorithm as described before, we iterate through all the constraints n times. Instead of performing an iteration over all the constraints, we use a single iteration, but subdivides the simulation step into multiple substeps.

The effect is truly amazing. This simple modification makes our local solver converge as fast as global solvers. Now, let us extend the method from particles to rigid bodies. In addition to position, linear velocity and mass, a rigid body possesses corresponding angular quantities. An orientation Q and angular velocity omega and the moment of inertia I.

The orientation Q is typically represented by a cernian. The angle velocity is a 3D vector and the moment of inertia is also a 3D vector in the rest pose of the rigid body. It can be premputed from the shape of the body. Now let's have a look at how we can extend positionbased dynamics to handle rigid bodies. In addition to handling the linear quantities x and v, we must now also handle the rotational quantities omega and q.

We need to integrate them in time and updates them after solving the constraints. A constraint can affect both position and orientation of the body. Therefore, we compute updates delta x and delta q for each constraint. Then we apply them to the position X and the orientation Q. I will now show you how to handle two basic constraints.

The first is a distance constraint. Let's first recap the distance constraint between two simple particles. The constraint forces the distance between the particles to be L0. Here the current distance L is larger than L0. Therefore, we move the particles toward each other.

We split the correction delta x into delta x1 and delta x2 proportional to the inverse masses of the particles. For rigid bodies, we must specify where on the bodies the distance constraint is attached. We call these positions in world space p1 and p2. In our example, the current distance between the attachment points is larger than l0. Therefore, we pull the attachment points toward each other.

Doing this pulls the centers of mass x1 and x2 closer to each other by delta x1 and delta x2. It also causes the rotations q1 and q2 of the bodies as shown in yellow. The rotations are distributed proportional to the inverse moments of inertia i1 and i2. Here you see the procedure to compute these corrections. It looks quite complicated.

Fortunately, you don't really need to understand these formulas. I won't derive them here. Maybe in a future tutorial you will find the implementation in my code. As you can see, the procedure takes as input the locations of the attachment points P1 and P2. It also takes a correction vector delta P and the compliance alpha.

In the last two statements in yellow, you see how the positions and orientations of the bodies are updated. This procedure and its angular version that I will show in a minute are the only procedures that are not straightforward to understand. Everything else we will build on top of these is intuitive. The compliance alpha here is the inverse of physical stiffness. W is the inverse of mass.

The fact that we work with inverses lets us handle infinite stiffness and infinite mass simply and stably. We can compute the force that acts on the constraint as lambda * n / delta t ^ 2. The second basic constraint we need to be able to handle is the orientation constraint. In this case, we want to fix the relative orientations of the bodies. In this particular example, we want the two bodies to be aligned.

We can compute an orientation correction delta f to achieve this. As before, the correction is split between the two bodies relative to their inverse inertas. Here you see the procedure to apply an angular correction delta fi. It is simpler than the linear version. In this case, we don't need the positions of the attachment points.

Also only the orientations Q of the two bodies are modified. We can compute the torque acting on the constraint as lambda * N / delta T ^ 2. We will now build our joint simulation on top of these two basic procedures. First, we write a small set of procedures that serve as building blocks to simulate all joints that are used in the real world. The first procedure attaches two bodies at the attachment points P1 and P2.

We can also provide a rest distance and a compliance. We first compute the current distance T between the attachment points. The vector N is the unit vector pointing from P1 to P2. The length of the correction vector is the difference between the current and the rest distance. The next procedure restricts the second attachment point P2 to be on an axis A through the first attachment point P1.

We can also provide a lower and upper limit for the offset. Here we first compute the distance vector P from P1 to P2. Applying this vector as a correction vector would attach P1 to P2. However, we want the bodies to be able to slide along the axis A. For this, we compute the component of P along the axis A.

Without limits, we simply subtract this component from P. This step eliminates a correction along A. To respect limits, we simply clamp the correction if limits are provided. The third procedure aligns two axis A1 and A2. The correction vector in this case is simply minus A1 cross A2.

This is a fast approximation for small angles. The last building block is the procedure to limit the angle between two axis A1 and A2. The rotation axis is given by unit vector N. First we compute the current angle phi between the axis A1 and A2 with respect to the axis N. If the angle is within the bounds, we don't have to do anything.

Otherwise, we clamp phi based on the limit. Next, we compute a2 prime by rotating a1 by the angle phi. This is the direction a2 should have to form the desired angle. Now, we apply an angular correction to rotate a2 into a2 prime. We are now ready to handle all joints with these four building blocks.

For this, we need attachment frames. An attachment frame is composed of a location P REST and a set of perpendicular axis A rest and B rest. We define these in the rest state of the bodies and store them with each body. Before solving a constraint, we transform these into world space using the current position X and the current rotation Q of a body. The current attachment point is X plus the rest position P rest rotated by Q.

The current axis are the rest axis rotated by Q. We are now ready to simulate individual joint types. The first is the hinge joint. We first force the two attachment points to be in the same location by calling the attach method with a rest length of zero and infinite stiffness. Then we align the rotation axis A1 and A2 of the bodies again with infinite stiffness.

Finally, we apply joint limits if requested. We can easily simulate a servo too. For this, we perform the same operations as for the hinge joint. However, instead of having two angle limits, we force the angle to be the desired angle fi servo. For a velocity motor, we use the limit angle procedure to force the angle to be fi motor.

In addition, at every time step, we update this angle using the user specified angular velocity of the motor. To simulate a ball joint, we first align the attachment points as for the previous joints. To handle a swing limit, we limit the angle between the main axis A1 and A2 of the attachment frames. To handle a twist limit, we limit the angle between the secondary axis B1 and B2. As the rotation axis, we take the average of the two main axis A1 and A2.

For a prismatic joint, instead of forcing the attachment positions to be at the same location, we restrict the attachment point of the second body to be on the main axis of the first body. Again, we consider limits. Then we align the main axis. Finally, we restrict the torsion around axis A1. Often for prismatic joints, this torsion is forced to be zero.

We can achieve this by setting the limits of fi and alpha to zero. A cylinder joint is a prismatic joint. However, for a cylinder joint, we force the distance between the attachment points to a given value P target. We can achieve this by calling the restrict to axis procedure with a value P target. So far, I have only talked about positions and orientations.

To handle damping and application of forces and torqus, we need to be able to correct linear and angle velocities as well. In this loop, we apply corrections to the velocities after they are updated by XPBD. The procedure to add a linear velocity correction delta V looks very similar to the positional counterpart. We provide two points P1 and P2 and the velocity correction delta V. The method computes updates for the linear and angular velocities of the bodies.

Here is the procedure to apply a correction to the angle velocities. As in the positional case, we don't need the positions of the attachment points. We only need the correction vector delta omega. Also, only the angle velocities are updated in this case. With these procedures, we are now able to implement the last two missing features of joint simulation, damping and the application of forces and torqus.

Here you see the method that applies linear damping along a direction N. This method is typically used to damp a prismatic joint. For a prismatic joint, n is the main axis a1. We also provide the attachment points and the scalar damping coefficient c linear. We first compute the difference of the velocities delta v at the attachment points p1 and p2.

This is the relative velocity of the attachment point p2 with respect to the point p1. We then extract the component along the axis n. This is a scalar value. The part of delta V that is removed by damping is delta V * the damping coefficient C linear time the time step size delta T. The cool thing with XPBD is that we can make this step unconditionally stable by just clamping this value to not overshoot the value of one.

A value of one removes the relative velocity completely. This is very difficult to guarantee with global solvers. Angular damping is used to damp the rotation of hinge joints. Here n is the rotation axis of the hinge. We compute the relative angular velocity and extract the component along n.

Then we subtract delta t * c angular. Again, we make sure that we don't overshoot. Then we apply the corresponding angular velocity correction. We saw how to force the position of a cylinder to be at a certain offset. We can also control the cylinder by applying a force.

The force is a scalar value and a is the main axis of the cylinder. According to Newton's second law, dividing the force by the time step size yields the necessary velocity correction. I showed you how to control a servo by specifying a target angle or a motor by specifying a velocity. Similarly, we can control these joints by applying a torque. Dividing the scalar torque by the time step size delta t yields the necessary angular correction.

This concludes the tutorial. I hope you enjoyed it and I see you in the next one.

## Source Code

### 25-joints.html

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

<!--
To run:
start a server: python -m http.server 8000
install Install "Live Server" extension in VSCode
Right-click your HTML file → "Open with Live Server"
-->

<!DOCTYPE html>
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<html lang="en">
	<head>
		<title>Joint Simulation</title>
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
            /* Custom checkbox styling */
            .visual-toggle {
                display: none;
            }
            .visual-toggle-label {
                background-color: #606060;
                color: white;
                padding: 15px 32px;
                font-size: 16px;
                margin: 4px 2px;
                cursor: pointer;
                display: inline-block;
                user-select: none;
                transition: background-color 0.3s;
            }
            .visual-toggle-label:hover {
                background-color: #707070;
            }
            .visual-toggle:checked + .visual-toggle-label {
                background-color: #606060;
            }
            /* Touch control styling */
            #touchControl {
                position: fixed;
                bottom: 20px;
                right: 20px;
                width: 150px;
                height: 150px;
                pointer-events: none;
            }
            #outerCircle {
                position: absolute;
                width: 100%;
                height: 100%;
                border-radius: 0%;
                background-color: rgba(96, 96, 96, 0.5);
                pointer-events: auto;
            }
            #innerCircle {
                position: absolute;
                width: 40%;
                height: 40%;
                border-radius: 50%;
                background-color: rgba(255, 255, 255, 0.8);
                pointer-events: none;
                transform: translate(-50%, -50%);
            }
		</style>	
	</head>
	
	<body>

        <h1>Joint Simulation</h1> 
		<button id = "startButton" onclick="onStart()" class="button">Start</button>
		<button id = "startRestart" onclick="onRestart()" class="button">Restart</button>
		<button id = "toggleView" onclick="onToggleView()" class="button">Toggle View</button>
		<select id="sceneSelect" class="styled-select" onchange="onSceneChange()">
			<option value="0">Basic Joints</option>
			<option value="1">Steering</option>
			<option value="2">Pendulums</option>
		</select>

		<br><br>		
        <div id="container"></div>
        <div id="touchControl">
            <div id="outerCircle"></div>
            <div id="innerCircle"></div>
        </div>
        
        <script src="https://unpkg.com/three@0.139.2/build/three.min.js"></script>
        <script src="https://unpkg.com/three@0.139.2/examples/js/controls/OrbitControls.js"></script>
        
        <script>

			// ------------------------------------------------------------------

			class RigidBody 
            {
                constructor(scene, type, size, density, pos, angles, fontSize = 0.0) 
                {
                    this.type = type;
                    this.size = new THREE.Vector3(size.x, size.y, size.z);
                    this.dt = 0.0;

                    this.pos = new THREE.Vector3(pos.x, pos.y, pos.z);
                    this.rot = new THREE.Quaternion();
                    this.rot.setFromEuler(new THREE.Euler(angles.x, angles.y, angles.z));
                    this.vel = new THREE.Vector3(0.0, 0.0, 0.0);
                    this.omega = new THREE.Vector3(0.0, 0.0, 0.0);

                    this.prevPos = this.pos.clone();
                    this.prevRot = this.rot.clone();
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

                    this.firstVisualMesh = this.meshes.length;
                    this.showVisuals = true;
                    
                    this.updateMeshes();
                }

                updateMeshes()
                {
                    for (let i = 0; i < this.meshes.length; i++)
                    {
                        this.meshes[i].position.copy(this.pos);
                        this.meshes[i].quaternion.copy(this.rot);
    					this.meshes[i].geometry.computeBoundingSphere();
                        this.meshes[i].visible = (i < this.firstVisualMesh) !== this.showVisuals;
                    }
                }
                
                showSimulationView(show)
                {
                    this.showVisuals = show;
                    this.updateMeshes();
                }

                // begin simulation functions

                getVelocityAt(pos)
                {
                    let vel = new THREE.Vector3(0.0, 0.0, 0.0);
                    if (this.invMass > 0.0)
                    {
                        vel.subVectors(pos, this.pos);
                        vel.cross(this.omega);
                        vel.multiplyScalar(-1.0);
                        vel.add(this.vel);
                    }
                    return vel;
                }

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
                    let dRot = new THREE.Quaternion(
                        this.omega.x,
                        this.omega.y,
                        this.omega.z,
                        0.0
                    );
                    dRot.multiply(this.rot);
                    this.rot.x += 0.5 * dt * dRot.x;
                    this.rot.y += 0.5 * dt * dRot.y;
                    this.rot.z += 0.5 * dt * dRot.z;
                    this.rot.w += 0.5 * dt * dRot.w;
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
                    let dRot = new THREE.Quaternion();
                    dRot.multiplyQuaternions(this.rot, this.prevRot);
                    this.omega.set(
                        dRot.x * 2.0 / this.dt,
                        dRot.y * 2.0 / this.dt,
                        dRot.z * 2.0 / this.dt
                    );
                    if (dRot.w < 0.0)
                        this.omega.negate();
                }

                getInverseMass(normal, pos)
                {
                    if (this.invMass == 0.0)
                        return 0.0;

                    let rn = normal.clone();

                    if (pos)  
                    {
                        rn.subVectors(pos, this.pos);
                        rn.cross(normal);
                        rn.applyQuaternion(this.invRot);
                    }
                    else           
                    {
                        rn.applyQuaternion(this.invRot);
                    }

                    let w = 
                        rn.x * rn.x * this.invInertia.x + 
                        rn.y * rn.y * this.invInertia.y + 
                        rn.z * rn.z * this.invInertia.z;

                    if (pos)
                        w += this.invMass;
                 
                    return w;
                }

                _applyCorrection(corr, pos, velocityLevel)
                {
                    if (this.invMass == 0.0)
                        return;

                    // linear correction

                    if (pos) 
                    {
                        if (velocityLevel)
                            this.vel.addScaledVector(corr, this.invMass);
                        else
                            this.pos.addScaledVector(corr, this.invMass);
                    }

                    // angular correction

                    let dOmega = corr.clone();

                    if (pos)
                    {
                        dOmega.subVectors(pos, this.pos);
                        dOmega.cross(corr);
                    }
                    
                    dOmega.applyQuaternion(this.invRot);
                    dOmega.multiply(this.invInertia);
                    dOmega.applyQuaternion(this.rot);

                    if (velocityLevel)
                    {
                        this.omega.add(dOmega);
                    }
                    else
                    {
                        // stabilize rotation
                        dOmega.multiplyScalar(0.5);
                        
                        let dRot = new THREE.Quaternion(
                            dOmega.x,
                            dOmega.y,
                            dOmega.z,
                            0.0
                        );

                        dRot.multiply(this.rot);
                        this.rot.x += 0.5 * dRot.x;
                        this.rot.y += 0.5 * dRot.y;
                        this.rot.z += 0.5 * dRot.z;
                        this.rot.w += 0.5 * dRot.w;
                        this.rot.normalize();
                        this.invRot.copy(this.rot);
                        this.invRot.invert();
                    }
                }

                applyCorrection(compliance, corr, pos, otherBody, otherPos, velocityLevel = false)
                {
                    if (corr.lengthSq() == 0.0)
                        return;

                    let C = corr.length();
                    let normal = corr.clone();
                    normal.normalize();

                    let w = this.getInverseMass(normal, pos);
                    if (otherBody)
                        w += otherBody.getInverseMass(normal, otherPos);

                    if (w == 0.0)
                        return;

                    let lambda = -C / w;

                    if (!velocityLevel)
                    {
                        // XPBD
                        let alpha = compliance / this.dt / this.dt;
                        lambda = -C / (w + alpha);
                    }
                    normal.multiplyScalar(-lambda);

                    this._applyCorrection(normal, pos, velocityLevel);
                    if (otherBody) {
                        normal.multiplyScalar(-1.0);
                        otherBody._applyCorrection(normal, otherPos, velocityLevel);
                    }
                    return lambda / this.dt / this.dt;
                }
              
                // end simulation functions
            }

            class VisualDistance {
                constructor(scene, width = 0.01, color = 0xff0000) {
                    this.scene = scene;
                    
                    // Create a cylinder for visualization
                    const geometry = new THREE.CylinderGeometry(width, width, 1, 32);
                    const material = new THREE.MeshBasicMaterial({ color: color });
                    this.cylinder = new THREE.Mesh(geometry, material);
                    this.cylinder.castShadow = true;
                    this.cylinder.receiveShadow = true;
                    scene.add(this.cylinder);
                }
                
                updateMesh(startPos, endPos) {
                    // Calculate the center point
                    const center = new THREE.Vector3().addVectors(startPos, endPos).multiplyScalar(0.5);
                    
                    // Calculate the direction vector
                    const direction = new THREE.Vector3().subVectors(endPos, startPos);
                    const length = direction.length();
                    
                    // Create a rotation quaternion
                    const quaternion = new THREE.Quaternion();
                    quaternion.setFromUnitVectors(new THREE.Vector3(0, 1, 0), direction.normalize());
                    
                    // Update cylinder's transformation
                    this.cylinder.position.copy(center);
                    this.cylinder.setRotationFromQuaternion(quaternion);
                    this.cylinder.scale.set(1, length, 1);
                    
                    return length;
                }

                setVisible(visible) {
                    this.cylinder.visible = visible;
                }
            }

            class VisualFrame {
                constructor(scene, width, size = 0.1) {
                    // Create axis line objects
                    this.axes = {
                        x: this.createAxis(width, size, 0xff0000), // Red for X-axis
                        y: this.createAxis(width, size, 0x00ff00), // Green for Y-axis
                        z: this.createAxis(width, size, 0x0000ff)  // Blue for Z-axis
                    };
                    
                    // Add axes to scene
                    scene.add(this.axes.x);
                    scene.add(this.axes.y);
                    scene.add(this.axes.z);
                }
                
                createAxis(width, size, color) {
                    // Create a line representing an axis
                    const material = new THREE.MeshBasicMaterial({ color });
                    const geometry = new THREE.CylinderGeometry(width, width, size, 8);
                    
                    // Position the cylinder so it starts at the origin and extends in positive direction
                    geometry.translate(0, size/2, 0);
                    
                    const line = new THREE.Mesh(geometry, material);
                    return line;
                }
                
                updateMesh(pos, rot) {
                    // Extract basis vectors from quaternion
                    const xAxis = new THREE.Vector3(1, 0, 0).applyQuaternion(rot);
                    const yAxis = new THREE.Vector3(0, 1, 0).applyQuaternion(rot);
                    const zAxis = new THREE.Vector3(0, 0, 1).applyQuaternion(rot);
                    
                    // Update X axis (red)
                    this.axes.x.position.copy(pos);
                    this.axes.x.quaternion.setFromUnitVectors(
                        new THREE.Vector3(0, 1, 0), 
                        xAxis.clone().normalize()
                    );
                    
                    // Update Y axis (green)
                    this.axes.y.position.copy(pos);
                    this.axes.y.quaternion.setFromUnitVectors(
                        new THREE.Vector3(0, 1, 0), 
                        yAxis.clone().normalize()
                    );
                    
                    // Update Z axis (blue)
                    this.axes.z.position.copy(pos);
                    this.axes.z.quaternion.setFromUnitVectors(
                        new THREE.Vector3(0, 1, 0), 
                        zAxis.clone().normalize()
                    );
                }
                setVisible(visible) {
                    this.axes.x.visible = visible;
                    this.axes.y.visible = visible;
                    this.axes.z.visible = visible;
                }
            }


            class Joint {
                static TYPES = {
                    NONE: 'none',
                    DISTANCE: 'distance',
                    HINGE: 'hinge',
                    SERVO: 'servo',
                    MOTOR: 'motor',
                    BALL: 'ball',
                    PRISMATIC: 'prismatic',
                    CYLINDER: 'cylinder',
                    FIXED: 'fixed',
                };
                constructor(body0, body1, globalFramePos, globalFrameRot = null)
                {
                    this.type = Joint.TYPES.NONE;
                    this.body0 = body0;
                    this.body1 = body1;
                    this.diabled = false;

                    if (!globalFrameRot) {
                        globalFrameRot = new THREE.Quaternion(0.0, 0.0, 0.0, 1.0);
                    }

                    // distance

                    this.hasTargetDistance = false;
                    this.targetDistance = 0.0;
                    this.distanceCompliance = 0.0;
                    this.distanceMin = -Number.MAX_VALUE;
                    this.distanceMax = Number.MAX_VALUE;
                    this.linearDampingCoeff = 0.0;

                    // orientation

                    this.swingMin = -Number.MAX_VALUE;
                    this.swingMax = Number.MAX_VALUE;
                    this.twistMin = -Number.MAX_VALUE;
                    this.twistMax = Number.MAX_VALUE;
                    this.targetAngle = 0.0;
                    this.hasTargetAngle = false;
                    this.targetAngleCompliance = 0.0;
                    this.angularDampingCoeff = 0.0;

                    // motor
                    this.velocity = 0.0;

                    this.globalPos0 = globalFramePos.clone();
                    this.globalRot0 = globalFrameRot.clone();
                    this.globalPos1 = globalFramePos.clone();
                    this.globalRot1 = globalFrameRot.clone();

                    this.localPos0 = globalFramePos.clone();
                    this.localRot0 = globalFrameRot.clone();
                    this.localPos1 = globalFramePos.clone();
                    this.localRot1 = globalFrameRot.clone();

                    this.setFrames(globalFramePos, globalFrameRot);

                    this.visFrame0 = null;
                    this.visFrame1 = null;
                    this.visDistance = null;
                }

                setFrames(globalFramePos, globalFrameRot = null)
                {
                    if (!globalFrameRot) {
                        globalFrameRot = new THREE.Quaternion(0.0, 0.0, 0.0, 1.0);
                    }
                    
                    if (this.body0) {
                        // Store the local position relative to body0
                        this.localPos0.subVectors(globalFramePos, this.body0.pos);
                        this.localPos0.applyQuaternion(this.body0.invRot);
                        
                        // Store the local rotation relative to body0
                        this.localRot0.copy(globalFrameRot);
                        // Factor out the body's rotation
                        if (globalFrameRot) {
                            this.localRot0.premultiply(this.body0.invRot);
                        }
                    } else {
                        this.localPos0.copy(globalFramePos);
                        this.localRot0.copy(globalFrameRot);
                    }
                    
                    if (this.body1) {
                        // Store the local position relative to body1
                        this.localPos1.subVectors(globalFramePos, this.body1.pos);
                        this.localPos1.applyQuaternion(this.body1.invRot);
                        
                        // Store the local rotation relative to body1
                        this.localRot1.copy(globalFrameRot);
                        // Factor out the body's rotation
                        if (globalFrameRot) {
                            this.localRot1.premultiply(this.body1.invRot);
                        }
                    } else {
                        this.localPos1.copy(globalFramePos);
                        this.localRot1.copy(globalFrameRot);
                    }
                }

                setVisible(visible)
                {
                    if (this.visFrame0 != null)
                        this.visFrame0.setVisible(visible);
                    if (this.visFrame1 != null)
                        this.visFrame1.setVisible(visible);
                    if (this.visDistance != null)
                        this.visDistance.setVisible(visible);
                }

                setDisabled(disabled)
                {
                    this.disabled = disabled;
                    this.setVisible(!disabled);
                }

                initHingeJoint(swingMin, swingMax, hasTargetAngle, targetAngle, compliance, damping)
                {
                    this.type = Joint.TYPES.HINGE;
                    this.hasTargetDistance = true;
                    this.targetDistance = 0.0;
                    this.swingMin = swingMin;
                    this.swingMax = swingMax;
                    this.hasTargetAngle = hasTargetAngle;
                    this.targetAngle = targetAngle;
                    this.targetAngleCompliance = compliance;
                    this.angularDampingCoeff = damping;
                }

                initServo(swingMin, swingMax)
                {
                    this.type = Joint.TYPES.SERVO;
                    this.hasTargetDistance = true;
                    this.targetDistance = 0.0;
                    this.swingMin = swingMin;
                    this.swingMax = swingMax;
                    this.hasTargetAngle = true;
                    this.targetAngle = 0.0;
                    this.targetAngleCompliance = 0.0;
                }     
                initMotor(velocity)
                {
                    this.type = Joint.TYPES.MOTOR;
                    this.hasTargetDistance = true;
                    this.targetDistance = 0.0;
                    this.velocity = velocity;
                    this.hasTargetAngle = true;
                    this.targetAngle = 0.0;
                    this.targetAngleCompliance = 0.0
                }  
                initBallJoint(swingMax, twistMin, twistMax, damping)
                {
                    this.type = Joint.TYPES.BALL;
                    this.hasTargetDistance = true;
                    this.targetDistance = 0.0;
                    this.swingMin = 0.0;
                    this.swingMax = swingMax;
                    this.twistMin = twistMin;
                    this.twistMax = twistMax;
                    this.angularDampingCoeff = damping;
                }

                initPrismaticJoint(distanceMin, distanceMax, twistMin, twistMax, hasTarget, targetDistance, targetCompliance, damping)
                {
                    this.type = Joint.TYPES.PRISMATIC;
                    this.distanceMin = distanceMin;
                    this.distanceMax = distanceMax;
                    this.swingMin = 0.0;
                    this.swingMax = 0.0;
                    this.twistMin = twistMin;
                    this.twistMax = twistMax;
                    this.hasTargetDistance = hasTarget;
                    this.targetDistance = targetDistance;
                    this.distanceCompliance = targetCompliance;
                    this.linearDampingCoeff = damping;
                }
                
                initCylinderJoint(distanceMin, distanceMax, twistMin, twistMax, hasTargetDistance, restDistance, compliance, damping)
                {
                    this.type = Joint.TYPES.CYLINDER;
                    this.distaceMin = distanceMin;
                    this.distanceMax = distanceMax;
                    this.swingMin = 0.0;
                    this.swingMax = 0.0;
                    this.twistMin = twistMin;
                    this.twistMax = twistMax;
                    this.hasTargetDistance = true;
                    this.distanceCompliance = 0.0;
                }

                initDistanceJoint(restDistance, compliance, damping)
                {
                    this.type = Joint.TYPES.DISTANCE;
                    this.hasTargetDistance = true;
                    this.targetDistance = restDistance;
                    this.distanceCompliance = compliance;
                    this.linearDampingCoeff = damping;
                }

                applyTorque(dt, torque)
                {
                    updateGlobalFrames();

                    // assumng x-axis is the hinge axis

                    let corr = new THREE.Vector3(1.0, 0.0, 0.0);
                    corr.applyQuaternion(this.globalRot0);
                    corr.multiplyScalar(torque* dt);

                    this.body0.applyCorrection(0.0, corr, null, this.body1, null, true);
                }

                solvePosition(dt) 
                {
                    let hardCompliance = 0.0;

                    if (this.disabled || this.type == Joint.TYPES.NONE)
                        return;

                    let corr = new THREE.Vector3();

                    // align
                    
                    if (this.type == Joint.TYPES.PRISMATIC || this.type == Joint.TYPES.CYLINDER)
                    {   
                        this.targetDistance = Math.max(this.distanceMin, Math.min(this.targetDistance, this.distanceMax));
                        let hardCompliance = 0.0;
                        this.updateGlobalFrames();
                        corr.subVectors(this.globalPos1, this.globalPos0);

                        corr.applyQuaternion(this.globalRot0.clone().conjugate());
                        if (this.type == Joint.TYPES.CYLINDER)
                            corr.x -= this.targetDistance;
                        else if (corr.x > this.distanceMax)
                            corr.x -= this.distanceMax;
                        else if (corr.x < this.distanceMin)
                            corr.x -= this.distanceMin;
                        else
                            corr.x = 0.0; 

                        corr.applyQuaternion(this.globalRot0);
                        this.body0.applyCorrection(hardCompliance, corr, this.globalPos0, this.body1, this.globalPos1);                    
                    }

                    // solve distance

                    if (this.type != Joint.TYPES.CYLINDER && this.hasTargetDistance)
                    {
                        this.updateGlobalFrames();
                        corr.subVectors(this.globalPos1, this.globalPos0);
                        let distance = corr.length();
                        if (distance == 0.0)
                        {
                            corr.set(0.0, 0.0, 1.0);
                            corr.applyQuaternion(this.globalRot0);
                        }
                        else
                            corr.normalize();

                        corr.multiplyScalar(this.targetDistance - distance);
                        corr.multiplyScalar(-1.0);
                        this.body0.applyCorrection(this.distanceCompliance, corr, this.globalPos0, this.body1, this.globalPos1);
                    }
                }    

                updateGlobalFrames() 
                {
                    if (this.body0) {
                        this.globalPos0.copy(this.localPos0);
                        this.globalPos0.applyQuaternion(this.body0.rot);
                        this.globalPos0.add(this.body0.pos);
                        this.globalRot0.multiplyQuaternions(this.body0.rot, this.localRot0);
                    }
                    
                    if (this.body1) {
                        this.globalPos1.copy(this.localPos1);
                        this.globalPos1.applyQuaternion(this.body1.rot);
                        this.globalPos1.add(this.body1.pos);
                        this.globalRot1.multiplyQuaternions(this.body1.rot, this.localRot1);
                    }
                    else {
                        this.globalPos1.copy(this.localPos1);
                        this.globalRot1.copy(this.localRot1);
                    }
                }

                getAngle(n, a, b) 
                {
                    const c = new THREE.Vector3().crossVectors(a, b);
                    let phi = Math.asin(c.dot(n));
                    if (a.dot(b) < 0.0) 
                        phi = Math.PI - phi;
                    if (phi > Math.PI) 
                        phi -= 2.0 * Math.PI;
                    if (phi < -Math.PI) 
                        phi += 2.0 * Math.PI;
                    return phi;
                }

                limitAngle(n, a, b, minAngle, maxAngle, compliance)
                {
                    let phi = this.getAngle(n, a, b);

                    if (minAngle <= phi && phi <= maxAngle)
                        return;
                    phi = Math.max(minAngle, Math.min(phi, maxAngle));

                    let ra = a.clone();
                    ra.applyAxisAngle(n, phi);

                    let corr = new THREE.Vector3().crossVectors(ra, b);
                    this.body0.applyCorrection(compliance, corr, null, this.body1, null);
                }
            
                solveOrientation(dt)
                {
                    if (this.disabled || this.type == Joint.TYPES.NONE || this.type == Joint.TYPES.DISTANCE)
                    {
                        return;
                    }    

                    if (this.type == Joint.TYPES.MOTOR)
                    {
                        let aAngle = Math.min(Math.max(this.velocity * dt, -1.0), 1.0);
                        this.targetAngle += aAngle;
                    }
                    
                    let hardCompliance = 0.0;
                    let axis0 = new THREE.Vector3(1.0, 0.0, 0.0);
                    let axis1 = new THREE.Vector3(0.0, 1.0, 0.0);
                    let a0 = new THREE.Vector3();
                    let a1 = new THREE.Vector3();
                    let n = new THREE.Vector3();
                    let corr = new THREE.Vector3();

                    if (this.type == Joint.TYPES.HINGE || this.type == Joint.TYPES.SERVO || this.type == Joint.TYPES.MOTOR)
                    {
                        // align axes

                        this.updateGlobalFrames();

                        a0.copy(axis0);
                        a0.applyQuaternion(this.globalRot0);
                        a1.copy(axis0);
                        a1.applyQuaternion(this.globalRot1);
                        corr.crossVectors(a0, a1);
                        this.body0.applyCorrection(hardCompliance, corr, null, this.body1, null);

                        if (this.hasTargetAngle)
                        {
                            this.updateGlobalFrames();
                            n.copy(axis0);
                            n.applyQuaternion(this.globalRot0);
                            a0.copy(axis1);
                            a0.applyQuaternion(this.globalRot0);
                            a1.copy(axis1);
                            a1.applyQuaternion(this.globalRot1);
                            this.limitAngle(n, a0, a1, this.targetAngle, this.targetAngle, this.targetAngleCompliance);
                        }

                        // joint limits

                        if (this.swingMin > -Number.MAX_VALUE || this.swingMax < Number.MAX_VALUE)
                        {
                            this.updateGlobalFrames();
                            
                            n.copy(axis0);
                            n.applyQuaternion(this.globalRot0);
                            a0.copy(axis1);
                            a0.applyQuaternion(this.globalRot0);
                            a1.copy(axis1);
                            a1.applyQuaternion(this.globalRot1);
                            this.limitAngle(n, a0, a1, this.swingMin, this.swingMax, hardCompliance);
                        }
                    }
                    else if (this.type == Joint.TYPES.BALL || this.type == Joint.TYPES.PRISMATIC || this.type == Joint.TYPES.CYLINDER)
                    {
                        // swing limit

                        this.updateGlobalFrames();

                        a0.copy(axis0);
                        a0.applyQuaternion(this.globalRot0);
                        a1.copy(axis0);
                        a1.applyQuaternion(this.globalRot1);   
                        n.crossVectors(a0, a1);
                        n.normalize();
                        this.limitAngle(n, a0, a1, this.swingMin, this.swingMax, hardCompliance);

                        // twist limit

                        this.updateGlobalFrames();

                        a0.copy(axis0);
                        a0.applyQuaternion(this.globalRot0);
                        a1.copy(axis0);
                        a1.applyQuaternion(this.globalRot1);   
                        n.addVectors(a0, a1);
                        n.normalize();

                        a0.copy(axis1);
                        a0.applyQuaternion(this.globalRot0);
                        a1.copy(axis1);
                        a1.applyQuaternion(this.globalRot1);

                        a0.addScaledVector(n, -n.dot(a0));
                        a0.normalize();
                        a1.addScaledVector(n, -n.dot(a1));
                        a1.normalize();
                        this.limitAngle(n, a0, a1, this.twistMin, this.twistMax, hardCompliance);
                    }
                    else if (this.type == Joint.TYPES.FIXED)
                    {
                        // align orientations

                        this.updateGlobalFrames();

                        let dq = new THREE.Quaternion();
                        dq.multiplyQuaternions(this.globalRot0, this.globalRot1.conjugate());
                        corr.set(2.0 * dq.x, 2.0 * dq.y, 2.0 * dq.z);
                        if (dq.w > 0.0)
                            corr.multiplyScalar(-1.0);

                        this.body0.applyCorrection(hardCompliance, corr, null, this.body1, null);
                    }
                }

                solve(dt)
                {
                    this.solvePosition(dt);
                    this.solveOrientation(dt);
                }

                applyLinearDamping(dt)
                {
                    this.updateGlobalFrames();

                    let dVel = this.body0.getVelocityAt(this.globalPos0);
                    if (this.body1 != null)
                        dVel.sub(this.body1.getVelocityAt(this.globalPos1));

                    // only damp along the distance vector

                    let n = new THREE.Vector3();
                    n.subVectors(this.globalPos1, this.globalPos0);
                    n.normalize();
                    n.multiplyScalar(-dVel.dot(n));
                    n.multiplyScalar(Math.min(this.linearDampingCoeff * dt, 1.0));                    
                    this.body0.applyCorrection(0.0, n, this.globalPos0, this.body1, this.globalPos1, true);
                }
       
                applyAngularDamping(dt, coeff = this.angularDampingCoeff)
                {
                    this.updateGlobalFrames();

                    let dOmega = this.body0.omega.clone();
                    if (this.body1 != null)
                        dOmega.sub(this.body1.omega);

                    if (this.type == Joint.TYPES.HINGE)
                    {
                        // damp along the hinge axis
                        let n = new THREE.Vector3(1.0, 0.0, 0.0);
                        n.applyQuaternion(this.globalRot0);
                        n.multiplyScalar(dOmega.dot(n));
                        dOmega.copy(n);
                    }
                    if (this.type == Joint.TYPES.CYLINDER || this.type == Joint.TYPES.PRISMATIC || this.type == Joint.TYPES.FIXED)
                        dOmega.multiplyScalar(-1.0); // maximum damping
                    else
                        dOmega.multiplyScalar(-Math.min(this.angularDampingCoeff * dt, 1.0));
                    this.body0.applyCorrection(0.0, dOmega, null, this.body1, null, true);
                }

                addVisuals(scene, width = 0.004, size = 0.08)
                {
                    if (this.visFrame0 == null)
                    {
                        this.visFrame0 = new VisualFrame(scene, width, size);
                        this.visFrame1 = new VisualFrame(scene, width, size);
                    }

                    if (this.visDistance == null) {
                        this.visDistance = new VisualDistance(scene, width);
                    }
                    this.updateVisuals();
                }

                updateVisuals() 
                {
                    if (this.disabled)
                        return;

                    this.updateGlobalFrames();                    // Calculate the actual world positions for joint attachment points
                    
                    if (this.visFrame0)
                        this.visFrame0.updateMesh(this.globalPos0, this.globalRot0);
                    if (this.visFrame1)
                        this.visFrame1.updateMesh(this.globalPos1, this.globalRot1);
                    if (this.visDistance != null) 
                        this.visDistance.updateMesh(this.globalPos0, this.globalPos1);
                } 
            }            
			
			// ------------------------------------------------------------------

            class RigidBodySimulator 
            {
				constructor(scene, gravity)
				{
                    this.scene = scene;
                    this.gravity = gravity.clone();
                    this.dt = 0.03333; // 30 FPS
                    this.numSubSteps = 20;
                    this.numIterations = 1;
                    this.rigidBodies = [];
                    this.joints = [];

                    this.addDragJoint(scene);
                    this.simulationView = true;

                    // Touch control state
                    this.controlVector = new THREE.Vector2(0, 0);
                    this.controlVelocity = new THREE.Vector2(0, 0);
                    this.isDragging = false;
                    this.setupTouchControl();
                }

                setupTouchControl() {
                    const outerCircle = document.getElementById('outerCircle');
                    const innerCircle = document.getElementById('innerCircle');
                    const touchControl = document.getElementById('touchControl');

                    // Initialize inner circle to center
                    innerCircle.style.left = '50%';
                    innerCircle.style.top = '50%';

                    const updateControl = (clientX, clientY) => {
                        const rect = touchControl.getBoundingClientRect();
                        const centerX = rect.left + rect.width / 2;
                        const centerY = rect.top + rect.height / 2;
                        
                        // Calculate vector from center to touch point
                        let dx = clientX - centerX;
                        let dy = clientY - centerY;
                        
                        // Normalize and clamp to square
                        const maxRadius = rect.width / 2;
                        if (Math.abs(dx) > maxRadius) {
                            dx = Math.sign(dx) * maxRadius;
                        }
                        if (Math.abs(dy) > maxRadius) {
                            dy = Math.sign(dy) * maxRadius;
                        }
                        
                        // Update inner circle position
                        innerCircle.style.left = (rect.width / 2 + dx) + 'px';
                        innerCircle.style.top = (rect.height / 2 + dy) + 'px';
                        
                        // Store normalized control vector (-1 to 1)
                        this.controlVector.set(dx / maxRadius, -dy / maxRadius);
                        this.controlVelocity.set(0, 0); // Reset velocity when actively controlling
                    };

                    const onPointerDown = (e) => {
                        this.isDragging = true;
                        updateControl(e.clientX, e.clientY);
                        if (gPaused)
                            onStart();
                    };

                    const onPointerMove = (e) => {
                        if (this.isDragging) {
                            updateControl(e.clientX, e.clientY);
                        }
                    };

                    const onPointerUp = () => {
                        this.isDragging = false;
                    };

                    outerCircle.addEventListener('pointerdown', onPointerDown);
                    document.addEventListener('pointermove', onPointerMove);
                    document.addEventListener('pointerup', onPointerUp);
                }

                addDragJoint() 
                {
                    let dragCompliance = 0.01;
                    let dragDamping = 0.1;
                    this.dragJoint = new Joint(null, null, new THREE.Vector3(0.0, 0.0, 0.0));
                    this.dragJoint.initDistanceJoint(0.0, dragCompliance, dragDamping);                    
                    this.dragJoint.addVisuals(this.scene);
                    this.dragJoint.setDisabled(true);
                }

                clear()
                {
                    this.rigidBodies = [];
                    this.joints = [];
                    this.addDragJoint();
                }

                toggleView()
                {
                    this.simulationView = !this.simulationView;
                    for (let i = 0; i < this.rigidBodies.length; i++)
                        this.rigidBodies[i].showSimulationView(this.simulationView);
                    for (let i = 0; i < this.joints.length; i++)
                        this.joints[i].setVisible(!this.simulationView);
                }

                addRigidBody(rigidBody)
                {
                    this.rigidBodies.push(rigidBody);
                }

                addJoint(joint)
                {
                    this.joints.push(joint);
                }

                updateControl() {
                    // Update control vector with velocity
                    if (!this.isDragging) {
                        const returnSpeed = 5.0; // Adjust this value to control return speed
                        this.controlVelocity.x = -this.controlVector.x * returnSpeed;
                        this.controlVelocity.y = -this.controlVector.y * returnSpeed;
                        this.controlVector.add(this.controlVelocity.multiplyScalar(this.dt));
                        
                        // Update inner circle position
                        const innerCircle = document.getElementById('innerCircle');
                        const touchControl = document.getElementById('touchControl');
                        const rect = touchControl.getBoundingClientRect();
                        const maxRadius = rect.width / 2;
                        innerCircle.style.left = (rect.width / 2 + this.controlVector.x * maxRadius) + 'px';
                        innerCircle.style.top = (rect.height / 2 - this.controlVector.y * maxRadius) + 'px';
                    }

                    // Apply control to motors and servos
                    for (let i = 0; i < this.joints.length; i++) {
                        const joint = this.joints[i];
                        if (joint.type === Joint.TYPES.MOTOR) {
                            joint.velocity = this.controlVector.y * 5.0; // Scale factor for motor speed
                        }
                        else if (joint.type === Joint.TYPES.SERVO) {
                            joint.targetAngle = this.controlVector.x * Math.PI / 4; // Scale factor for steering angle
                        }
                        else if (joint.type === Joint.TYPES.CYLINDER) {
                            joint.targetDistance = -this.controlVector.y * 0.1; // Scale factor for offset
                        }
                    }
                }

                simulate()
				{
                    this.updateControl();

                    let sdt = this.dt / this.numSubSteps;

                    for (let subStep = 0; subStep < this.numSubSteps; subStep++)
                    {
                        for (let i = 0; i < this.rigidBodies.length; i++)
                            this.rigidBodies[i].integrate(sdt, this.gravity);

                        for (let i = 0; i < this.joints.length; i++)
                            this.joints[i].solve(sdt);

                        if (this.dragJoint)
                            this.dragJoint.solve(sdt);

                        for (let i = 0; i < this.rigidBodies.length; i++)
                        {
                            this.rigidBodies[i].updateVelocities(sdt);
                        }

                        for (let i = 0; i < this.joints.length; i++)
                        {
                            this.joints[i].applyLinearDamping(sdt);
                            this.joints[i].applyAngularDamping(sdt);
                        }
                    }

                    for (let i = 0; i < this.rigidBodies.length; i++)
                        this.rigidBodies[i].updateMeshes();

                    for (let i = 0; i < this.joints.length; i++)
                        this.joints[i].updateVisuals();

                    if (this.dragJoint)
                        this.dragJoint.updateVisuals();
				}

                startDrag(body, pos)
                {
                    this.dragJoint.body0 = body;
                    this.dragJoint.setFrames(pos);
                    this.dragJoint.setDisabled(false);
                }

                drag(pos)
                {
                    this.dragJoint.localPos1.copy(pos);
                }

                endDrag(pos)
                {
                    this.dragJoint.setDisabled(true);
                }
            }

   			// ------------------------------------------------------------------

            class SceneImporter {
                constructor(simulator, scene) {
                    this.simulator = simulator;
                    this.scene = scene;
                    this.rigidBodies = new Map(); // name -> RigidBody lookup
                }

                loadScene(jsonData) {
                    // Parse JSON if it's a string
                    const data = typeof jsonData === 'string' ? JSON.parse(jsonData) : jsonData;
                    
                    // Check if scene data is empty
                    if (!data || Object.keys(data).length === 0 || !data.meshes || data.meshes.length === 0) {
                        console.warn('Empty scene data provided. No objects to load.');
                        return;
                    }
                    
                    // Clear existing simulation
                    this.simulator.clear();
                    this.rigidBodies.clear();
                    
                    // Pass 1: Create all rigid bodies
                    for (const mesh of data.meshes) {
                        if (this.isRigidBody(mesh)) {
                            this.createRigidBody(mesh);
                        }
                    }
                    
                    // Pass 2: Create joints and visual meshes
                    for (const mesh of data.meshes) {
                        if (this.isJoint(mesh)) {
                            this.createJoint(mesh);
                        } else if (this.isVisual(mesh)) {
                            this.createVisualMesh(mesh);
                        }
                    }

                    this.simulator.simulationView = false;
                    this.simulator.toggleView();

                    console.log(`Loaded scene with ${this.rigidBodies.size} rigid bodies`);
                }

                isRigidBody(mesh) {
                    const simType = mesh.properties?.simType;
                    return simType && simType.startsWith('Rigid');
                }

                isJoint(mesh) {
                    const simType = mesh.properties?.simType;
                    return simType && simType.endsWith('Joint');
                }

                isVisual(mesh) {
                    return mesh.properties?.simType === 'Visual';
                }

                createRigidBody(mesh) {
                    const props = mesh.properties;
                    const simType = props.simType;
                    const density = props.density ?? 0.0;
                    
                    // Extract position and rotation from transform
                    const pos = new THREE.Vector3(
                        mesh.transform.position[0],
                        mesh.transform.position[1],
                        mesh.transform.position[2]
                    );
                    
                    const quat = new THREE.Quaternion(
                        mesh.transform.rotation[0],
                        mesh.transform.rotation[1],
                        mesh.transform.rotation[2],
                        mesh.transform.rotation[3]
                    );
                    const euler = new THREE.Euler().setFromQuaternion(quat);
                    const angles = new THREE.Vector3(euler.x, euler.y, euler.z);

                    let rigidBody;

                    if (simType === 'RigidBox') {
                        // Calculate bounding box from vertices
                        const size = this.calculateBoundingBox(mesh.vertices);
                        rigidBody = new RigidBody(this.scene, "box", size, density, pos, angles);
                    }
                    else if (simType === 'RigidSphere') {
                        // Calculate bounding sphere radius
                        const radius = this.calculateBoundingSphere(mesh.vertices);
                        const size = new THREE.Vector3(radius, radius, radius);
                        rigidBody = new RigidBody(this.scene, "sphere", size, density, pos, angles);
                    }
                    else {
                        console.warn(`Unknown rigid body type: ${simType}`);
                        return;
                    }

                    // Store in lookup table
                    this.rigidBodies.set(mesh.name, rigidBody);
                    this.simulator.addRigidBody(rigidBody);
                    
                    console.log(`Created ${simType}: ${mesh.name}`);
                }

                calculateBoundingBox(vertices) {
                    let minX = Infinity, minY = Infinity, minZ = Infinity;
                    let maxX = -Infinity, maxY = -Infinity, maxZ = -Infinity;

                    // Vertices are stored as [x, y, z, x, y, z, ...]
                    for (let i = 0; i < vertices.length; i += 3) {
                        const x = vertices[i];
                        const y = vertices[i + 1];
                        const z = vertices[i + 2];

                        minX = Math.min(minX, x);
                        maxX = Math.max(maxX, x);
                        minY = Math.min(minY, y);
                        maxY = Math.max(maxY, y);
                        minZ = Math.min(minZ, z);
                        maxZ = Math.max(maxZ, z);
                    }

                    return new THREE.Vector3(
                        (maxX - minX),
                        (maxY - minY),
                        (maxZ - minZ)
                    );
                }

                calculateBoundingSphere(vertices) {
                    // Find center
                    let centerX = 0, centerY = 0, centerZ = 0;
                    const numVerts = vertices.length / 3;

                    for (let i = 0; i < vertices.length; i += 3) {
                        centerX += vertices[i];
                        centerY += vertices[i + 1];
                        centerZ += vertices[i + 2];
                    }

                    centerX /= numVerts;
                    centerY /= numVerts;
                    centerZ /= numVerts;

                    // Find maximum distance from center
                    let maxRadius = 0;
                    for (let i = 0; i < vertices.length; i += 3) {
                        const dx = vertices[i] - centerX;
                        const dy = vertices[i + 1] - centerY;
                        const dz = vertices[i + 2] - centerZ;
                        const radius = Math.sqrt(dx * dx + dy * dy + dz * dz);
                        maxRadius = Math.max(maxRadius, radius);
                    }

                    return maxRadius;
                }

                createJoint(mesh) {
                    const props = mesh.properties;
                    const simType = props.simType;
                    
                    // Look up parent bodies
                    const body0 = this.rigidBodies.get(props.parent1);
                    const body1 = this.rigidBodies.get(props.parent2);
                    
                    if (!body0) {
                        console.error(`Parent body not found: ${props.parent1}`);
                        return;
                    }
                    if (!body1) {
                        console.error(`Parent body not found: ${props.parent2}`);
                        return;
                    }

                    // Joint position (use mesh position as anchor point)
                    const jointPos = new THREE.Vector3(
                        mesh.transform.position[0],
                        mesh.transform.position[1],
                        mesh.transform.position[2]
                    );

                    // Joint rotation
                    const jointRot = new THREE.Quaternion(
                        mesh.transform.rotation[0],
                        mesh.transform.rotation[1],
                        mesh.transform.rotation[2],
                        mesh.transform.rotation[3]
                    );

                    // Create joint
                    const joint = new Joint(body0, body1, jointPos, jointRot);

                    // Configure joint based on type
                    if (simType === 'BallJoint') {
                        let swingMax = props.swingMax ?? Number.MAX_VALUE
                        let twistMin = props.twistMin ?? -Number.MAX_VALUE
                        let twistMax = props.twistMax ?? Number.MAX_VALUE
                        let damping = props.damping ?? 0.0;
                        
                        joint.initBallJoint(swingMax, twistMin, twistMax, damping);
                    }
                    else if (simType === 'HingeJoint') {
                        let swingMin = props.swingMin ?? -Number.MAX_VALUE
                        let swingMax = props.swingMax ?? Number.MAX_VALUE;
                        let hasTargetAngle = props.targetAngle !== undefined;
                        let targetAngle = props.targetAngle ?? 0.0;
                        let compliance = props.targetAngleCompliance ?? 0.0;
                        let damping = props.damping ?? 0.0;

                        joint.initHingeJoint(swingMin, swingMax, hasTargetAngle, targetAngle, compliance, damping);
                    }
                    else if (simType === 'ServoJoint') {
                        let swingMin = props.swingMin ?? -Number.MAX_VALUE
                        let swingMax = props.swingMax ?? Number.MAX_VALUE;
                        
                        joint.initServo(swingMin, swingMax);
                    }
                    else if (simType === 'MotorJoint') {
                        let velocity = props.velocity ?? 0.0;
                        velocity = 3.0;
                        joint.initMotor(velocity);
                    }
                    else if (simType === 'DistanceJoint') {
                        let restDistance = props.restDistance ?? 0.0;
                        let compliance = props.compliance ?? 0.0;
                        let damping = props.damping ?? 0.0;

                        joint.initDistanceJoint(restDistance, compliance, damping);
                    }
                    else if (simType === 'PrismaticJoint') {
                        let distanceMin = props.distanceMin ?? -Number.MAX_VALUE
                        let distanceMax = props.distanceMax ?? Number.MAX_VALUE;
                        let compliance = props.compliance ?? 0.0;
                        let damping = props.damping ?? 0.0;
                        let hasTarget = props.distanceTarget !== undefined;
                        let targetDistance = props.posTarget ?? 0.0;
                        let twistMin = props.twistMin ?? -Number.MAX_VALUE;
                        let twistMax = props.twistMax ?? Number.MAX_VALUE;
                        joint.initPrismaticJoint(distanceMin, distanceMax, twistMin, twistMax, hasTarget, targetDistance, compliance, damping);
                    }
                    else if (simType === 'CylinderJoint') {
                        let hasDistanceLimits = props.distanceMin !== undefined && props.distanceMax !== undefined;
                        let distanceMin = props.distanceMin ?? -Number.MAX_VALUE
                        let distanceMax = props.distanceMax ?? Number.MAX_VALUE;
                        let twistMin = props.twistMin ?? -Number.MAX_VALUE;
                        let twistMax = props.twistMax ?? Number.MAX_VALUE;
                        joint.initCylinderJoint(distanceMin, distanceMax, twistMin, twistMax);
                    }
                    else {
                        console.warn(`Unknown joint type: ${simType}`);
                        return;
                    }

                    // Add visuals and register with simulator
                    joint.addVisuals(this.scene);
                    this.simulator.addJoint(joint);
                    
                    console.log(`Created ${simType}: ${mesh.name} connecting ${props.parent1} to ${props.parent2}`);
                }

                createVisualMesh(mesh) {
                    const props = mesh.properties;
                    const parentName = props.parent;
                    
                    // Look up parent body
                    const parentBody = this.rigidBodies.get(parentName);
                    if (!parentBody) {
                        console.error(`Parent body not found for visual mesh: ${parentName}`);
                        return;
                    }

                    // Get visual mesh transform
                    const visualPos = new THREE.Vector3(
                        mesh.transform.position[0],
                        mesh.transform.position[1], 
                        mesh.transform.position[2]
                    );
                    
                    const visualRot = new THREE.Quaternion(
                        mesh.transform.rotation[0],
                        mesh.transform.rotation[1],
                        mesh.transform.rotation[2],
                        mesh.transform.rotation[3]
                    );

                    // Transform visual mesh to parent body local space

                    const q_rel = parentBody.rot.clone().conjugate().multiply(visualRot);
                    const p_rel = visualPos.clone().sub(parentBody.pos).applyQuaternion(parentBody.rot.clone().conjugate());

                    const transformedVertices = [];
                    for (let i = 0; i < mesh.vertices.length; i += 3) {
                        const vertex = new THREE.Vector3(mesh.vertices[i], mesh.vertices[i + 1], mesh.vertices[i + 2]);
                        vertex.applyQuaternion(q_rel);
                        vertex.add(p_rel);
                        
                        transformedVertices.push(vertex.x, vertex.y, vertex.z);
                    }

                    const transformedNormals = [];
                    if (mesh.normals) {
                        for (let i = 0; i < mesh.normals.length; i += 3) {
                            const normal = new THREE.Vector3(mesh.normals[i], mesh.normals[i + 1], mesh.normals[i + 2]);
                            normal.applyQuaternion(q_rel);
                            transformedNormals.push(normal.x, normal.y, normal.z);
                        }
                    }

                    // Create Three.js geometry from transformed data
                    const geometry = new THREE.BufferGeometry();
                    geometry.setAttribute('position', new THREE.Float32BufferAttribute(transformedVertices, 3));
                    
                    if (transformedNormals.length > 0) {
                        geometry.setAttribute('normal', new THREE.Float32BufferAttribute(transformedNormals, 3));
                    }
                    
                    if (mesh.triangles) {
                        geometry.setIndex(mesh.triangles);
                    }

                    const color = props.color ? new THREE.Color(props.color[0], props.color[1], props.color[2]) : new THREE.Color(1, 1, 1);
                    const material = new THREE.MeshPhongMaterial({ color: color });

                    // Create mesh
                    const visualMesh = new THREE.Mesh(geometry, material);
                    visualMesh.castShadow = true;
                    visualMesh.receiveShadow = true;
                    visualMesh.body = parentBody; // For raycasting

                    parentBody.meshes.push(visualMesh);
                    parentBody.updateMeshes();
                    
                    this.scene.add(visualMesh);
                    
                    console.log(`Created visual mesh: ${mesh.name} attached to ${parentName} (transformed to body space)`);
                }
            }

            // ------------------------------------------------------------------

            class RenderScene
            {
                constructor()
                {
                    this.threeScene = new THREE.Scene();

                    // Lights
                    this.threeScene.add(new THREE.AmbientLight(0x505050));
                    this.threeScene.fog = new THREE.Fog(0x000000, 0.0, 15.0);

                    var spotLight = new THREE.SpotLight(0xffffff);
                    spotLight.angle = Math.PI / 5;
                    spotLight.penumbra = 0.2;
                    spotLight.position.set(2, 3, 2);
                    this.threeScene.add(spotLight);

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
                    this.threeScene.add(dirLight);

                    // Geometry
                    let ground = new THREE.Mesh(
                        new THREE.PlaneBufferGeometry(50.0, 50.0),
                        new THREE.MeshPhongMaterial({ color: 0xa0adaf, shininess: 150 })
                    );

                    ground.rotation.x = -Math.PI / 2; // rotates X/Y to X/Z
                    ground.receiveShadow = true;
                    this.threeScene.add(ground);

                    // Renderer
                    this.renderer = new THREE.WebGLRenderer({ antialias: true });
                    this.renderer.shadowMap.enabled = true;
                    this.renderer.shadowMap.type = THREE.PCFSoftShadowMap;  // Softer shadows
                    this.renderer.setPixelRatio(window.devicePixelRatio);
                    this.renderer.setSize(0.8 * window.innerWidth, 0.8 * window.innerHeight);
                    window.addEventListener('resize', onWindowResize, false);
                    container.appendChild(this.renderer.domElement);

                    // Camera
                    this.camera = new THREE.PerspectiveCamera(70, window.innerWidth / window.innerHeight, 0.01, 100);
                    this.camera.position.set(0, 0.4, 1.6);
                    this.camera.updateMatrixWorld();
                    this.threeScene.add(this.camera);

                    this.cameraControl = new THREE.OrbitControls(this.camera, this.renderer.domElement);
                    this.cameraControl.zoomSpeed = 2.0;
                    this.cameraControl.panSpeed = 0.4;
                    this.cameraControl.target = new THREE.Vector3(0.0, 0.4, 0.0);
                    this.cameraControl.update();

                    this.raycaster = new THREE.Raycaster();
                    this.raycaster.layers.set(1);
                    this.raycaster.params.Line.threshold = 0.1;

                    this.meshes = [];
                }

                render()
                {
                    this.renderer.render(this.threeScene, this.camera);
                }

                add(mesh)
                {
                    this.threeScene.add(mesh);
                    this.meshes.push(mesh);
                }

                clear()
                {
                    for (let i = 0; i < this.meshes.length; i++)
                    {
                        this.threeScene.remove(this.meshes[i]);
                    }
                    this.meshes = [];
                }
            }

            var gRenderScene = null;
            var gSimulator = null;
            var gPaused = true;

			// ------------------------------------------------------

			function onWindowResize() {
                if (gRenderScene == null)
                    return;
				gRenderScene.camera.aspect = window.innerWidth / window.innerHeight;
				gRenderScene.camera.updateProjectionMatrix();
				gRenderScene.renderer.setSize( window.innerWidth, window.innerHeight );
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
                window.location.reload();
			}

            function onToggleView()
            {
                gSimulator.toggleView();
            }

            function onSceneChange() {
                const select = document.getElementById('sceneSelect');
                loadScene(parseInt(select.value));
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

                var rect = gRenderScene.renderer.domElement.getBoundingClientRect();
				gPointerInfo.mousePos.x = ((evt.clientX - rect.left) / rect.width ) * 2 - 1;
				gPointerInfo.mousePos.y = -((evt.clientY - rect.top) / rect.height ) * 2 + 1;
                gRenderScene.raycaster.setFromCamera(gPointerInfo.mousePos, gRenderScene.camera);

				if (evt.type == "pointerdown") {
                    var intersects = gRenderScene.raycaster.intersectObjects(gRenderScene.threeScene.children);
					if (intersects.length > 0) {
                        gPointerInfo.distance = intersects[0].distance;
                        gPointerInfo.worldPos.copy(gRenderScene.raycaster.ray.origin);
                        gPointerInfo.worldPos.addScaledVector(gRenderScene.raycaster.ray.direction, gPointerInfo.distance);
                        gPointerInfo.body = intersects[0].object.body;
                        if (gPointerInfo.body)
                        {
                            gRenderScene.cameraControl.saveState();
						    gRenderScene.cameraControl.enabled = false;
                            gSimulator.startDrag(gPointerInfo.body, gPointerInfo.worldPos);
                            if (gPaused)
                                onStart(); 
                        }
                        else
                            gPointerInfo.body = null;
                    }
				}
				else if (evt.type == "pointermove" && gPointerInfo.body != null) {
                    gPointerInfo.worldPos.copy(gRenderScene.raycaster.ray.origin);
                    gPointerInfo.worldPos.addScaledVector(gRenderScene.raycaster.ray.direction, gPointerInfo.distance);
                    gSimulator.drag(gPointerInfo.worldPos);
				}
				else if (evt.type == "pointerup") {
                    if (gPointerInfo.body != null)
                    {
                        gSimulator.endDrag();
                        gPointerInfo.body = null;
                        gRenderScene.cameraControl.reset();
                    }
                    gRenderScene.cameraControl.enabled = true;
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
                gRenderScene.render();
				requestAnimationFrame(update);
			}
					            
            // Scene definitions
            const jointScenes = [
                { path: './basicJoints.json', name: 'Basic Joints' },
                { path: './steering.json', name: 'Steering' },
                { path: './pendulum.json', name: 'Pendulum' }
            ];

            function loadScene(sceneIndex) {
                gRenderScene.clear();
                gSimulator.clear();

                fetch(jointScenes[sceneIndex].path)
                .then(response => response.json())
                .then(scene => {
                    console.log('Scene loaded:', scene);
                    let importer = new SceneImporter(gSimulator, gRenderScene);
                    importer.loadScene(scene);
                });
            }

  			gRenderScene = new RenderScene();
            let gravity = new THREE.Vector3(0.0, -9.81, 0.0);
            gSimulator = new RigidBodySimulator(gRenderScene, gravity);

            loadScene(0); // Load the first scene by default

            onWindowResize();
			update();
		</script>
	</body>
</html>

```
