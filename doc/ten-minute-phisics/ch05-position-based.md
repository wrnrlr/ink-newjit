# Chapter 05 — The Simplest Possible Physics Simulation Method

**Video:** https://youtu.be/qISgdDhdCro
**Code:** https://raw.githubusercontent.com/matthias-research/pages/master/tenMinutePhysics/05-bead.html
**Code:** https://raw.githubusercontent.com/matthias-research/pages/master/tenMinutePhysics/05-manyBeads.html

## Video Transcript

hi maltjust from 10 minute physics here welcome to tutorial number five today i'm going to show you how to simulate constraint dynamics in the simplest possible way this is an important tutorial because many ideas that follow will be based on it let's start okay so let's have a look at constraint dynamics our balls could so far move freely except in the case of collisions in the real world however motions of objects or parts of them are typically restricted one of the simplest examples which is often used as the first example in textbooks is the beat on a circular wire here the beat only has one degree of freedom instead of two a more practical example is a robot arm there are six rigid parts each of which has multiple degrees of freedom however with the joint constraints only four are left there are three main methods to handle constraints in physical simulations i will take the beat on wire example to explain them the simplest approach is to have a spring that pulls the beat back on the wire the problem with this approach is that we have to tune the stiffness of the spring we want it to be as big as possible however big stiffnesses cause problems in numerical simulators a popular approach is to use generalized coordinates instead of describing the location of a beat with x and y coordinates we describe it with a single angle alpha now the beat stays on the wire by construction however this approach gets involved very quickly even for this simple example here are screenshots of the derivation taken from the great page myphysicslab.com as you can see you need to be good at both calculus and trigonometry to understand it a third and popular approach is to solve for constraint forces these forces make the velocity tangential to the constraint manifold in this case the circle however with this approach the constraints remain satisfied only if they are satisfied to begin with therefore an additional feedback mechanism is necessary to counteract drift here are screenshots of sick graph course notes by andrew witkin which explained the approach the derivation is a bit simpler for the beat on circle example but still non-trivial so how can we make this simpler here's our bead unfortunately it is not on the wire what is the simplest way to fix this problem right simply put it on the wire in order to get the physics right we need to move it to the closest point on the wire however we cannot just change the position we have to modify the velocity as well in this example the beat is in the equilibrium position gravity pulls on it constantly we put the beat back to the circle every time step however because we don't modify the velocity it gets bigger and bigger and bigger this has the effect that we will have to apply a bigger and bigger force to be able to move the beat here is the simplest way to fix the velocity in the time step we add the velocity times dt to the position as in previous examples what is new is that we move the position to satisfy the constraint at the end of the time step we simply set the velocity to the current position minus the position at the beginning of the time step divided by dt so here's our final algorithm first we add gravity times dt to the velocity then we store the current position in the variable p next we have the velocity times dt to the position now we move x to satisfy the constraint then we compute the new velocity as x minus p divided by dt so let's code this and try we start with the html document that we used in the previous tutorials we have a head section with a title that appears in the tab of the browser and some style information the body of the page only contains one element which is the canvas that we use to draw our scene the script section contains all javascript code first we set up drawing as we did in previous examples we define the canvas width and height we also define functions to map physical coordinates to screen coordinates we use the vector2 class that we wrote in the third tutorial here is the physics scene it contains gravity dt and then the center on the radius of the wire and the bead the bead class looks very much like the ball class we used in previous examples in the constructor we define a set of member variables the radius the mass the position this time we also have a member variable previous position and the velocity the start step method takes as input dt and gravity we first add gravity times dt to the velocity this time we store the current position in the variable previous position and then add velocity times dt to the position the next method keeps the beat on the wire it takes as input the center and the radius of the wire first we compute the vector from the center of the wire to the position of the bead we normalize this vector and compute its length the constraint error is the radius of the circular wire minus the distance from the center of the wire to the position of the bead we then add the constraint direction times the constraint error to the position of the bead at the end of the time step we compute the velocity as the current position minus the previous position divided by dt in the setup function we set up our physics scene we first define the center and the radius of the wire then we define a position for the bead create a new bead and store it in the physics scene for drawing we use the function draw circle that we used in previous tutorials in the draw function itself we first clear the canvas then we draw the wire circle and the beat the simulate function is very simple in each step we first call start step for the beat then keep on wire and then end step the update function looks as usual we first call simulate then draw and make sure that the update function is called again and again now let's check how this looks in the browser so here it is our circular wire with the bead swinging on it as you can see it loses energy over time this is because our method is related to implicit integration people in the gaming and movie industry mostly use implicit integration and typically do not care too much about this effect because objects in everyday life are highly damped and do not oscillate noticeably we can reduce this effect quite easily though in the first tutorial i mentioned substepping as a way to increase fidelity let us implement this right now to do this we add variable num steps to the physics scene and then in the simulation function we have a loop over num steps inside the loop we do exactly as we did before we call start step keep on wire and step with one important difference we have first to compute the sub step size which is the time step divided by the number of sub steps then we use sdt in all function calls here now let's see what happens as you can see with 10 sub steps energy conservation is significantly improved now the question we have to ask is is this a hack is this physical let us compare our result to the analytic solution we have the following equation of motion when the position of the ball is defined by the angle alpha alone given the radius r of the circle the magnitude g of gravity and the current angle alpha we can compute the change of the angle of velocity omega omega then tells us how fast the angle changes we will use symplectic euler integration with very small time steps to solve these two equations let us implement this in addition to the regular beat we now define a class analytic beat it stores the radius of the wire its own radius and the position as an angle in the simulate function we first compute the angular acceleration as on the slide by minus gravity divided by the radius of the wire times the sinus of the angle with the angular acceleration we update the angle velocity by adding the angular acceleration times dt and the angle by adding the angular velocity times dt this is a simulation with 10 sub steps in the beginning the two beats match quite well but over time the red beat loses energy this is the same simulation with the hundreds up steps and with a thousand sub steps the cool thing is that this simple method converges to the analytic solution with decreasing time step size we don't need calculus trigonometry linearizations accelerations forces tuning drift fixing and it works for general constraints too however what if we need the constraint force for other purposes the nice thing is that we can actually recover the constraint force for the beat on circle example we can compute the constraint force analytically it is the sum of the centrifugal force plus the gravitational force in pbd we get the constraint force by simply dividing the correction distance by dt squared let's check this for this test i added a step button so we can single step through the simulation here you can see the constraint force computed by a pbd and here computed analytically here we use a thousand sub steps as you can see the two forces match perfectly to show you that our method also works in more general setups i added multiple beats for this i copied the function handleball ball collisions from tutorial number three then in the simulation procedure i call start step for all the beats keep on wire for all the beats and end step for all the beats then i have a nested loop to check all beat beat collisions here you see the result as usual in the description i provide a link to a page that contains all the html documents of all the tutorials in the next tutorial i will show you how to extend our approach to handle more general and soft constraints i hope you had fun and i'll see you in the next tutorial

## Source Code

### 05-bead.html

```html
<!DOCTYPE html>
<html>
<meta name="viewport" content="width=device-width, initial-scale=1.0">

<head>
	<title>Constrained Dynamics</title>
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
	</style>
</head>

<body>

	<button class="button" onclick="setupScene()">Restart</button>
	<button class="button" onclick="run()">Run</button>
	<button class="button" onclick="step()">Step</button>
	<br>
	PBD <span id = "force">0</span>  &emsp; Analytic <span id ="aforce">0</span>
	<br>

	<canvas id="myCanvas"></canvas>
		

<script>

	// drawing -------------------------------------------------------

	var canvas = document.getElementById("myCanvas");
	var c = canvas.getContext("2d");

	canvas.width = window.innerWidth - 20;
	canvas.height = window.innerHeight - 100;

	var simMinWidth = 2.0;
	var cScale = Math.min(canvas.width, canvas.height) / simMinWidth;
	var simWidth = canvas.width / cScale;
	var simHeight = canvas.height / cScale;

	function cX(pos) {
		return pos.x * cScale;
	}

	function cY(pos) {
		return canvas.height - pos.y * cScale;
	}

	// vector math -------------------------------------------------------

	class Vector2 {
		constructor(x = 0.0, y = 0.0) {
			this.x = x; 
			this.y = y;
		}

		set(v) {
			this.x = v.x; this.y = v.y;
		}

		clone() {
			return new Vector2(this.x, this.y);
		}

		add(v, s = 1.0) {
			this.x += v.x * s;
			this.y += v.y * s;
			return this;
		}

		addVectors(a, b) {
			this.x = a.x + b.x;
			this.y = a.y + b.y;
			return this;
		}

		subtract(v, s = 1.0) {
			this.x -= v.x * s;
			this.y -= v.y * s;
			return this;
		}

		subtractVectors(a, b) {
			this.x = a.x - b.x;
			this.y = a.y - b.y;
			return this;			
		}

		length() {
			return Math.sqrt(this.x * this.x + this.y * this.y);
		}

		scale(s) {
			this.x *= s;
			this.y *= s;
			return this;
		}

		dot(v) {
			return this.x * v.x + this.y * v.y;
		}

		perp() {
			return new Vector2(-this.y, this.x);
		}
	}

	// scene -------------------------------------------------------

    var physicsScene = 
	{
		gravity : new Vector2(0.0, -10.0),
		dt : 1.0 / 60.0,
		numSteps : 1000,
		paused : false,        
		wireCenter : new Vector2(),
		wireRadius : 0.0,
		bead : null,
        analyticBead : null
	};

   // -------------------------------------------------------
 
	class Bead {
		constructor(radius, mass, pos) {
			this.radius = radius;
			this.mass = mass;
			this.pos = pos.clone();
			this.prevPos = pos.clone();
			this.vel = new Vector2();
		}
		startStep(dt, gravity) {
			this.vel.add(gravity, dt);
			this.prevPos.set(this.pos);
			this.pos.add(this.vel, dt);
		}
		keepOnWire(center, radius) {
			var dir = new Vector2();
			dir.subtractVectors(this.pos, center);
			var len = dir.length();
			if (len == 0.0)
				return;
			dir.scale(1.0 / len);
			var lambda = physicsScene.wireRadius - len;
			this.pos.add(dir, lambda);
			return lambda;
		}
		endStep(dt) {
			this.vel.subtractVectors(this.pos, this.prevPos);
			this.vel.scale(1.0 / dt);
		}
	}

// -------------------------------------------------------

class AnalyticBead {
		constructor(radius, beadRadius, mass, angle) {
			this.radius = radius;
			this.beadRadius = beadRadius;
			this.mass = mass;
			this.angle = angle;
			this.omega = 0.0;
		}
		simulate(dt, gravity) {
			var acc = -gravity / this.radius * Math.sin(this.angle);
			this.omega += acc * dt;
			this.angle += this.omega * dt;

			var centrifugalForce = this.omega * this.omega * this.radius;
			var force = centrifugalForce + Math.cos(this.angle) * Math.abs(gravity);
			return force;
		}
		getPos() {
			return new Vector2(
				Math.sin(this.angle) * this.radius,
				-Math.cos(this.angle) * this.radius); 
		}
	}    

	// -----------------------------------------------------

	function setupScene() 
	{
		physicsScene.paused = true;

		physicsScene.wireCenter.x = simWidth / 2.0;
		physicsScene.wireCenter.y = simHeight / 2.0;
		physicsScene.wireRadius = simMinWidth * 0.4;

		var pos = new Vector2(
			physicsScene.wireCenter.x + physicsScene.wireRadius, 
			physicsScene.wireCenter.y);

        physicsScene.bead = new Bead(0.1, 1.0, pos);

		physicsScene.analyticBead = new AnalyticBead(
			physicsScene.wireRadius, 0.1, 1.0, 0.5 * Math.PI);

        document.getElementById("force").innerHTML = 0.0.toFixed(3);		
        document.getElementById("aforce").innerHTML = 0.0.toFixed(3);		

	}

	// draw -------------------------------------------------------

	function drawCircle(pos, radius, filled)
	{
		c.beginPath();			
		c.arc(
			cX(pos), cY(pos), cScale * radius, 0.0, 2.0 * Math.PI); 
		c.closePath();
		if (filled)
			c.fill();
		else 
			c.stroke();
	}

	function draw() 
	{
		c.clearRect(0, 0, canvas.width, canvas.height);

		c.fillStyle = "#FF0000";
		c.lineWidth = 2.0;
		drawCircle(physicsScene.wireCenter, physicsScene.wireRadius, false);

		c.fillStyle = "#FF0000";

		var bead = physicsScene.bead;
		drawCircle(bead.pos, bead.radius, true);

        c.fillStyle = "#00FF00";

        var analyticBead = physicsScene.analyticBead;
        var pos = analyticBead.getPos();
        pos.add(physicsScene.wireCenter);
        drawCircle(pos, analyticBead.beadRadius, true)        
	}

	// ------------------------------------------------

	function simulate() 
	{
		if (physicsScene.paused)
			return;

		var sdt = physicsScene.dt / physicsScene.numSteps;
        var force, analyticForce;

		for (var step = 0; step < physicsScene.numSteps; step++) {

            physicsScene.bead.startStep(sdt, physicsScene.gravity);

			var lambda = physicsScene.bead.keepOnWire(
					physicsScene.wireCenter, physicsScene.wireRadius);
            
            force = Math.abs(lambda / sdt / sdt);                    

			physicsScene.bead.endStep(sdt);

            analyticForce = physicsScene.analyticBead.simulate(sdt, -physicsScene.gravity.y);
		}

		document.getElementById("force").innerHTML = force.toFixed(3);		
		document.getElementById("aforce").innerHTML = analyticForce.toFixed(3);	        
	}

	// --------------------------------------------------------

	function run() {
		physicsScene.paused = false;
	}

	function step() {
		physicsScene.paused = false;
		simulate();
		physicsScene.paused = true;
	}

	function update() {
		simulate();
		draw();
		requestAnimationFrame(update);
	}
	
	setupScene();
	update();
	
</script> 
</body>
</html>
```

### 05-manyBeads.html

```html
<!--
Copyright 2021 Matthias Müller - Ten Minute Physics

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
-->

<!DOCTYPE html>
<html>
<meta name="viewport" content="width=device-width, initial-scale=1.0">

<head>
	<title>Constrained Dynamics</title>
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
	</style>
</head>

<body>


	<button class="button" onclick="setupScene()">Restart</button>
	<br>
	<canvas id="myCanvas"></canvas>
		

<script>

	// drawing -------------------------------------------------------

	var canvas = document.getElementById("myCanvas");
	var c = canvas.getContext("2d");

	canvas.width = window.innerWidth - 20;
	canvas.height = window.innerHeight - 100;

	var simMinWidth = 2.0;
	var cScale = Math.min(canvas.width, canvas.height) / simMinWidth;
	var simWidth = canvas.width / cScale;
	var simHeight = canvas.height / cScale;

	function cX(pos) {
		return pos.x * cScale;
	}

	function cY(pos) {
		return canvas.height - pos.y * cScale;
	}

	// vector math -------------------------------------------------------

	class Vector2 {
		constructor(x = 0.0, y = 0.0) {
			this.x = x; 
			this.y = y;
		}

		set(v) {
			this.x = v.x; this.y = v.y;
		}

		clone() {
			return new Vector2(this.x, this.y);
		}

		add(v, s = 1.0) {
			this.x += v.x * s;
			this.y += v.y * s;
			return this;
		}

		addVectors(a, b) {
			this.x = a.x + b.x;
			this.y = a.y + b.y;
			return this;
		}

		subtract(v, s = 1.0) {
			this.x -= v.x * s;
			this.y -= v.y * s;
			return this;
		}

		subtractVectors(a, b) {
			this.x = a.x - b.x;
			this.y = a.y - b.y;
			return this;			
		}

		length() {
			return Math.sqrt(this.x * this.x + this.y * this.y);
		}

		scale(s) {
			this.x *= s;
			this.y *= s;
			return this;
		}

		dot(v) {
			return this.x * v.x + this.y * v.y;
		}

		perp() {
			return new Vector2(-this.y, this.x);
		}
	}

	// scene -------------------------------------------------------

	class Bead {
		constructor(radius, mass, pos) {
			this.radius = radius;
			this.mass = mass;
			this.pos = pos.clone();
			this.prevPos = pos.clone();
			this.vel = new Vector2();
		}
		startStep(dt, gravity) {
			this.vel.add(gravity, dt);
			this.prevPos.set(this.pos);
			this.pos.add(this.vel, dt);
		}
		keepOnWire(center, radius) {
			var dir = new Vector2();
			dir.subtractVectors(this.pos, center);
			var len = dir.length();
			if (len == 0.0)
				return;
			dir.scale(1.0 / len);
			var lambda = physicsScene.wireRadius - len;
			this.pos.add(dir, lambda);
			return lambda;
		}
		endStep(dt) {
			this.vel.subtractVectors(this.pos, this.prevPos);
			this.vel.scale(1.0 / dt);
		}

	}

	var physicsScene = 
	{
		gravity : new Vector2(0.0, -10.0),
		dt : 1.0 / 60.0,
		numSteps : 100,
		wireCenter : new Vector2(),
		wireRadius : 0.0,
		beads : [],
	};

	// -----------------------------------------------------

	function setupScene() 
	{
		physicsScene.beads = [];

		physicsScene.wireCenter.x = simWidth / 2.0;
		physicsScene.wireCenter.y = simHeight / 2.0;
		physicsScene.wireRadius = simMinWidth * 0.4;

		var numBeads = 5;
		var mass = 1.0;

		var r = 0.1;
		var angle = 0.0;
		for (i = 0; i < numBeads; i++) {
			var mass = Math.PI * r * r;			
			var pos = new Vector2(
				physicsScene.wireCenter.x + physicsScene.wireRadius * Math.cos(angle), 
				physicsScene.wireCenter.y + physicsScene.wireRadius * Math.sin(angle));

			physicsScene.beads.push(new Bead(r, mass, pos));
			angle += Math.PI / numBeads;
			r = 0.05 + Math.random() * 0.1;
		}
	}

	// draw -------------------------------------------------------

	function drawCircle(pos, radius, filled)
	{
		c.beginPath();			
		c.arc(
			cX(pos), cY(pos), cScale * radius, 0.0, 2.0 * Math.PI); 
		c.closePath();
		if (filled)
			c.fill();
		else 
			c.stroke();
	}

	function draw() 
	{
		c.clearRect(0, 0, canvas.width, canvas.height);

		c.fillStyle = "#FF0000";
		c.lineWidth = 2.0;
		drawCircle(physicsScene.wireCenter, physicsScene.wireRadius, false);

		c.fillStyle = "#FF0000";

		for (var i = 0; i < physicsScene.beads.length; i++) {
			var bead = physicsScene.beads[i];
			drawCircle(bead.pos, bead.radius, true);
		}
	}

	// --- collision handling -------------------------------------------------------

	function handleBeadBeadCollision(bead1, bead2) 
	{
		var restitution = 1.0;
		var dir = new Vector2();
		dir.subtractVectors(bead2.pos, bead1.pos);
		var d = dir.length();
		if (d == 0.0 || d > bead1.radius + bead2.radius)
			return;

		dir.scale(1.0 / d);

		var corr = (bead1.radius + bead2.radius - d) / 2.0;
		bead1.pos.add(dir, -corr);
		bead2.pos.add(dir, corr);

		var v1 = bead1.vel.dot(dir);
		var v2 = bead2.vel.dot(dir);

		var m1 = bead1.mass;
		var m2 = bead2.mass;

		var newV1 = (m1 * v1 + m2 * v2 - m2 * (v1 - v2) * restitution) / (m1 + m2);
		var newV2 = (m1 * v1 + m2 * v2 - m1 * (v2 - v1) * restitution) / (m1 + m2);

		bead1.vel.add(dir, newV1 - v1);
		bead2.vel.add(dir, newV2 - v2);
	}

	// ------------------------------------------------

	function simulate() 
	{
		var sdt = physicsScene.dt / physicsScene.numSteps;

		for (var step = 0; step < physicsScene.numSteps; step++) {
			for (var i = 0; i < physicsScene.beads.length; i++)
				physicsScene.beads[i].startStep(sdt, physicsScene.gravity);

			for (var i = 0; i < physicsScene.beads.length; i++) {
				physicsScene.beads[i].keepOnWire(
					physicsScene.wireCenter, physicsScene.wireRadius);
			}

			for (var i = 0; i < physicsScene.beads.length; i++)
				physicsScene.beads[i].endStep(sdt);

			for (var i = 0; i < physicsScene.beads.length; i++) {
				for (var j = 0; j < i; j++) {
					handleBeadBeadCollision(
						physicsScene.beads[i], physicsScene.beads[j]);
				}
			}
		}
	}

	// --------------------------------------------------------

	function update() {
		simulate();
		draw();
		requestAnimationFrame(update);
	}
	
	setupScene();
	update();
	
</script> 
</body>
</html>
```
