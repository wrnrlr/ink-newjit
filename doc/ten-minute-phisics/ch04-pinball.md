# Chapter 04 — How to Write a Pinball Simulation

**Video:** https://youtu.be/NhVUCsXp-Uo
**Code:** https://raw.githubusercontent.com/matthias-research/pages/master/tenMinutePhysics/04-pinball.html

## Video Transcript

hi maltese integrity physics here welcome to tutorial number four this time i'm going to show you how to write a pinball simulator for this i will show you how to handle the collision between a ball and a capsule shape a ball and an arbitrary boundary and how to handle user input this tutorial builds on tutorial number three so i highly recommend to watch tutorial number three first before we can start to code we have to look at the math first there is an important vector operation we need for our project it's finding the point on the line a b which is closest to a point p the closest point c is the projection of p onto the line a b now the question is how can we compute it since it lies on the line a b we can express it with a regular number t in this way if t is 0 we are at point a if it is 1 we are at a plus b minus a which is b for values in between we are somewhere on the line therefore all we need is to find t in the previous tutorial we saw how to compute projections onto a line for this we need the normal vector n it is the vector that points along a b and has unit length now using the dot product we can compute the distance from a to c by measuring the distance from a to p along n we can also compute the distance from a to b in this way we get t by dividing these two numbers if p is above a with respect to n then the numerator is zero and t is zero as well in this case we get a as the result if p is above b with respect to n then the two distances are the same and we get one for t landing at point b we do not even have to make n unit length because it appears both in the numerator and in the denominator so we can simply use b minus a it can happen that the projection of p does not lie between a and b then t is smaller than 0 or larger than 1. in this case we want the end point to be the closest point it is easy to achieve this by clamping t to the interval zero to one we can now use this operation to handle the collision between a ball and a capsule shape a capsule shape is defined by a segment a b and the radius r we are going to model the flipper with this shape in order to handle the collision we first compute the closest point c on the axis of the capsule then we replace the capsule by a ball centered at c with radius r and handle the collision between the two balls as in the last tutorial this works nicely even at the rounded ends we will rotate the flipper about a in our simulation for this we need the concept of angular velocity this is a simple number called omega it tells us how fast something rotates with a unit angle per second in the simulation we will give the flipper a fixed angular velocity at every time step we can then multiply omega with a time step size to compute an angle by which we need to rotate the capsule about a a last concept we need is the perp operator to compute a vector that is perpendicular to a given vector v with coordinates x and y the result is a vector that is turned by 90 degrees in the mathematically positive direction which is counterclockwise as you can see from the diagram it can easily be computed it is the vector with coordinates minus y and x to handle the collision between the ball and the capsule we also need the velocity at the contact point for the ball this is simply a velocity of the ball itself for the capsule this is not the case in this case we can compute the velocity vector using the angle velocity omega and the vector r pointing from the rotation center to the contact point the velocity is then simply r scaled by omega and turn 90 degrees finally we need to be able to handle the collision of the ball with the boundary we will represent the boundary as a closed loop of straight segments to handle the collision we first search for the segment that is closest to the ball then we replace the ball by a point and the segment by a capsule with the radius of the ball and handle the collision between the two this yields the correct behavior at sharp corners there is one last problem we have to fix if the center of the ball gets on the wrong side of the boundary segment it gets pushed in the wrong direction the situation is rare and only happens with large time steps or high velocities in this case we compute what is called an inward normal we turn the segment a b by 90 degrees for this we need to make sure that we define the boundary counterclockwise we then check whether our direction vector points in the opposite direction this can be done using the dot product in such a case we flip the correction now we are ready to look into the code we use the html skeleton from the 2d simulations that i described in the first tutorial by the way it took me quite a long time to figure out how to make pages look good on mobile devices by default they look like on the desktop scales down and are hardly readable this is simply done by this magical meta statement inside the html document we have the head section here we define the title that shows in the tab of the browser next in the style section we define styles for the body and buttons inside the body section we define the content of the page we define a button to restart the scene next we have the text score and the text element with the content 0 we assign an id to it so that we can access it and modify it later below them we have the canvas to draw the pinball machine the script section contains all the java code i already described the drawing setup in the first tutorial here we set the size of the canvas we also defined functions to map physical coordinates to canvas coordinates we reused the vector2 class we wrote in the last tutorial with its function set clone add add vectors subtract subtract vectors length and dot however we add a function perp to create a new vector that is 90 degrees rotated as described in the math section we then write the function closest point on segment that returns the point on segment a b that is closest to p first we compute the vector a b pointing from a to b next we compute t with a formula i described before the equation has a b a b in the denominator if it is 0 we will divide by 0 which produces an error however ab.ab is only 0 if the vector has zero length this means a and b are in the same location in this case the closest point is a or b and we return a in the other case computing t is safe we return the vector a plus a b times t next we define the physics scene we reused the ball class from the last tutorial it contains a radius a mass a restitution position and velocity in the simulate function we simply add gravity times dt to the velocity and velocity times dt to the position as before we then declare an additional class obstacle for our simple pinball machine we only use disks they have a position a radius and a push velocity this is used to push balls away when they collide we don't need a simulation method because obstacles are static and do not move the flipper class is a bit more involved as mentioned before we represent it by a capsule shape therefore we store a radius a position and a length the position defines the location of the point a and is fixed the length is the distance from the point a to the point b we also specify a rest angle which defines the orientation of the flipper when it is not activated the sine property defines direction in which the flipper rotates we also specify the angular velocity the changing properties are the current rotation the current angular velocity and the touch identifier which specifies whether the flipper is activated in the simulation method we rotate the flipper if necessary first we store the current rotation then we check whether the flipper is activated if so we add dt times angular velocity to the current rotation but make sure that the rotation does not exceed the maximum rotation if it is not activated we subtract dt times the angle velocity from the current rotation and this time make sure that the rotation stays above zero the current angle velocity can then be computed as the current rotation minus the previous rotation divided by dt here we also need to consider the sign the select method is used to specify whether the flipper is activated depending on the location of a touch given by pause we return true if the position lies within the circle defined by the rotation center and the length of the flipper the get tip function returns the location of the point b which in contrast to a is not fixed but depends on the current rotation with these classes we can now specify the physics scene it contains the gravity the time step size and the score it also contains arrays four boundary segments balls obstacles and flippers the function setup scene creates the scene we define an offset of the machine to the canvas boundary we also set the score to zero the border is specified as a set of points each segment is then defined as the vector from one point to the next wrapping around to form a closed shape we create two balls to make the game a little bit more interesting and simply because we can we create four obstacles specifying their position radius and push velocities finally we create the flippers with opposite signs the draw procedure is a bit longer this time we first define a function to draw a disk because we need it multiple times below first we clear the canvas then we draw the border in black using a path for the balls we set the color to dark gray and call draw disc for all of them since our obstacles are discs as well we do the same thing for them this time using the color orange drawing the flippers is a little bit more tricky here we use the ability of the canvas to specify a transformation we translate to the rotation center and rotate such that the capsule is aligned with the x-axis then we draw a rectangle of size length times radius next we draw a disk at the origin and one shifted by length along the x-axis then we reset the transformation now let's check how this looks in the browser looks pretty good as you can see i designed the machine to match cell phones rather than a desktop screen there is no fancy graphics since we only care about physics i'll let you do that the next step is to write the collision handling functions i copied the function for ball ball collisions from the previous tutorial handling ball obstacle collisions is simpler because obstacles don't move first we compute a vector deer from the ball center to the obstacle center the length d of this vector tells us how far they are apart if the distance is bigger than the sum of the radii we can simply return if not we normalize the vector dear we then compute the penetration depth core as the sum of the radii minus the current distance to push the ball out of the obstacle we add deer times core to its position to make sure that the obstacle pushes the ball away we replace the component of the ball's velocity along the penetration direction by the push velocity of the obstacle we also increase the score by 1. handling ball flipper collisions is a bit more involved to make things a little bit easier we assume that the ball has no effect on the flipper and that the restitution of the ball is zero this means that the ball gets the velocity of the flipper at the contact point first however we have to resolve the collision by pushing them apart first we compute the point on the flipper's axis that is closest to the ball center now we can conceptually replace the flipper by a ball around the closest point therefore we first compute the vector deer pointing from the ball center to the closest point we compute its length d and return if it's longer than the sum of the radius of the ball plus the radius of the flipper next we normalize the vector deer and push the ball along by the penetration distance which is the sum of the radii minus the current distance to update the velocity of the ball we first have to compute the velocity of the flipper at the contact point the radius is a vector that points from the rotation center to the contact point to get the contact velocity we turn it by 90 degrees and scale it with the current angular velocity of the flipper the flipper can only modify the component of the ball's velocity along the penetration direction therefore we compute the projection of both the ball's velocity as well as the contact velocity onto the collision direction deer we then replace the ball's velocity by the contact velocity along the direction deer finally we need to handle collisions of the balls against the border first we need to find the segment that is closest to the ball center we do this by iterating through all border points we then compute the closest point c and the distance from the ball center to c we keep track of the current minimal distance in mintest if the distance is smaller than mindist we update mintest we also store the current closest point and the inward normal now we can push the ball out of the boundary if necessary we check where the penetration direction points in the same direction as the inward normal if so we push the ball away as usual otherwise we push it in the opposite direction finally we update the velocity of the ball again collisions can only change the velocity components along the penetration direction for the boundary we take the restitution of the ball into consideration as well we are now finally ready to write the simulation function first we iterate through all the flippers and call their simulation function then we try through all the balls and call their simulation functions as well with a nested loop we handle ball ball collisions next we hand all ball obstacle collisions ball flipper collisions and ball border collisions in the update function we add one line it replaces the content of the score text element with the current score value what is new in this tutorial is that we have to handle user interaction for this we add four listeners to the canvas one for touch start one for touch end one for mouse down and one for mouse up the untouched start function is called when the user touches the screen or when the number of touches increases because multiple touches can occur the event variable passed to the callback contains a list of touches for each touch we transform its screen coordinates to the physical coordinates then we iterate through all the flippers and check whether they accept it since each touch has a unique identifier we can use this to uniquely assign a touch to a flipper touch end is called when one of the touches is lost here we'd run through all the flippers and check whether the assigned touch is still in the event list if not we set the touch identifier of the flipper to -1 to play laptops or desktops we also support mouse interaction however as you will see playing the game with a mouse is really tricky because we do not have multiple touches in the on mouse down function we first transform the click position into physical coordinates for all flippers that accept the position we set the touch identifier to 0 because mouse events don't have identifiers in the mouse up function we simply set the touch identifiers of all flippers to -1 so here is our pinball game in action as you can see it's really hard to play with the mouse in the description you find a link to a page that contains the html files of all tutorials okay i hope you had fun watching this tutorial and i see you in the next one you

## Source Code

### 04-pinball.html

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
		<title>Pinball</title>
		<style>
			body {
				font-family: verdana; 
				font-size: 15px;
			}			
			.button {
				background-color: #606060;
				border: none;
				color: white;
				padding: 10px 32px;
				font-size: 16px;
				margin: 4px 2px;
				cursor: pointer;
			}
		</style>
	</head>
	
<body>

	<button class="button" onclick="setupScene()">Restart</button>
	Score <span id = "score">0</span>
	<br>
	<canvas id="myCanvas"></canvas>
	
<script>

	// drawing setup -------------------------------------------------------

	var canvas = document.getElementById("myCanvas");
	var c = canvas.getContext("2d");

	canvas.width = window.innerWidth - 20;
	canvas.height = window.innerHeight - 100;

	var flipperHeight = 1.7;

	var cScale = canvas.height / flipperHeight;
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

	// ----------------------------------------------------------------------
	function closestPointOnSegment(p, a, b) 
	{
		var ab = new Vector2();
		ab.subtractVectors(b, a);
		var t = ab.dot(ab);
		if (t == 0.0)
			return a.clone();
		t = Math.max(0.0, Math.min(1.0, (p.dot(ab) - a.dot(ab)) / t));
		var closest = a.clone();
		return closest.add(ab, t);
	}

	// physics scene -------------------------------------------------------

	class Ball {
		constructor(radius, mass, pos, vel, restitution) {
			this.radius = radius;
			this.mass = mass;
			this.restitution = restitution;
			this.pos = pos.clone();
			this.vel = vel.clone();
		}
		simulate(dt, gravity) {
			this.vel.add(gravity, dt);
			this.pos.add(this.vel, dt);
		}
	}

	class Obstacle {
		constructor(radius, pos, pushVel) {
			this.radius = radius;
			this.pos = pos.clone();
			this.pushVel = pushVel;
		}
	}

	class Flipper {
		constructor(radius, pos, length, restAngle, maxRotation, 
			angularVelocity, restitution) 
		{
			// fixed
			this.radius = radius;
			this.pos = pos.clone();
			this.length = length;
			this.restAngle = restAngle;
			this.maxRotation = Math.abs(maxRotation);
			this.sign = Math.sign(maxRotation);
			this.angularVelocity = angularVelocity;
			// changing
			this.rotation = 0.0;
			this.currentAngularVelocity = 0.0;
			this.touchIdentifier = -1;
		}
		simulate(dt) 
		{
			var prevRotation = this.rotation;
			var pressed = this.touchIdentifier >= 0;
			if (pressed) 
				this.rotation = Math.min(this.rotation + dt * this.angularVelocity, 
					this.maxRotation);
			else 
				this.rotation = Math.max(this.rotation - dt * this.angularVelocity, 
					0.0);
			this.currentAngularVelocity = this.sign * (this.rotation - prevRotation) / dt;
		}
		select(pos) {
			var d = new Vector2();
			d.subtractVectors(this.pos, pos);
			return d.length() < this.length;
		}
		getTip() 
		{
			var angle = this.restAngle + this.sign * this.rotation;
			var dir = new Vector2(Math.cos(angle), Math.sin(angle));
			var tip = this.pos.clone();
			return tip.add(dir, this.length);
		}
	}

	var physicsScene = 
	{
		gravity : new Vector2(0.0, -3.0),
		dt : 1.0 / 60.0,
		score: 0,
		paused: true,
		border: [],
		balls: [],
		obstacles: [],
		flippers: []
	};

	function setupScene() 
	{
		var offset = 0.02;
		physicsScene.score = 0;
	
		// border

		physicsScene.border.push(new Vector2(0.74, 0.25));
		physicsScene.border.push(new Vector2(1.0 - offset, 0.4));
		physicsScene.border.push(new Vector2(1.0 - offset, flipperHeight - offset));
		physicsScene.border.push(new Vector2(offset, flipperHeight - offset));
		physicsScene.border.push(new Vector2(offset, 0.4));
		physicsScene.border.push(new Vector2(0.26, 0.25));
		physicsScene.border.push(new Vector2(0.26, 0.0));
		physicsScene.border.push(new Vector2(0.74, 0.0));

		// ball

		{
			physicsScene.balls = [];

			var radius = 0.03;
			var mass = Math.PI * radius * radius;
			var pos = new Vector2(0.92,  0.5);
			var vel = new Vector2(-0.2, 3.5);
			physicsScene.balls.push(new Ball(radius, mass, pos, vel, 0.2));

			pos = new Vector2(0.08,  0.5);
			vel = new Vector2(0.2, 3.5);
			physicsScene.balls.push(new Ball(radius, mass, pos, vel, 0.2));
		}

		// obstacles 

		{
			physicsScene.obstacles = [];
			var numObstacles = 4;

			physicsScene.obstacles.push(new Obstacle(0.1, new Vector2(0.25, 0.6), 2.0));
			physicsScene.obstacles.push(new Obstacle(0.1, new Vector2(0.75, 0.5), 2.0));
			physicsScene.obstacles.push(new Obstacle(0.12, new Vector2(0.7, 1.0), 2.0));
			physicsScene.obstacles.push(new Obstacle(0.1, new Vector2(0.2, 1.2), 2.0));
		}

		// flippers

		{
			var radius = 0.03;
			var length = 0.2;
			var maxRotation = 1.0;
			var restAngle = 0.5;
			var angularVelocity = 10.0;
			var restitution = 0.0;

			var pos1 = new Vector2(0.26, 0.22);
			var pos2 = new Vector2(0.74, 0.22);

			physicsScene.flippers.push(
				new Flipper(radius, pos1, length, 
					-restAngle, maxRotation, angularVelocity, restitution));
			physicsScene.flippers.push(
				new Flipper(radius, pos2, length, 
					Math.PI + restAngle, -maxRotation, angularVelocity, restitution));
		}
	}

	// draw -------------------------------------------------------

	function drawDisc(x, y, radius)
	{
		c.beginPath();			
		c.arc(
			x, y, radius, 0.0, 2.0 * Math.PI); 
		c.closePath();
		c.fill();
	}

	function draw() 
	{
		c.clearRect(0, 0, canvas.width, canvas.height);

		// border

		if (physicsScene.border.length >= 2) {

			c.strokeStyle = "#000000";
			c.lineWidth = 5;

			c.beginPath();
			var v = physicsScene.border[0];
			c.moveTo(cX(v), cY(v));
			for (var i = 1; i < physicsScene.border.length + 1; i++) {
				v = physicsScene.border[i % physicsScene.border.length];
				c.lineTo(cX(v), cY(v));
			}
			c.stroke();	
			c.lineWidth = 1;
		}

		// balls

		c.fillStyle = "#202020";

		for (var i = 0; i < physicsScene.balls.length; i++) {
			var ball = physicsScene.balls[i];
			drawDisc(cX(ball.pos), cY(ball.pos), ball.radius * cScale);
		}

		// obstacles

		c.fillStyle = "#FF8000";

		for (var i = 0; i < physicsScene.obstacles.length; i++) {
			var obstacle = physicsScene.obstacles[i];
			drawDisc(cX(obstacle.pos), cY(obstacle.pos), obstacle.radius * cScale);
		}

		// flippers

		c.fillStyle = "#FF0000";

		for (var i = 0; i < physicsScene.flippers.length; i++) {
			var flipper = physicsScene.flippers[i];
			c.translate(cX(flipper.pos), cY(flipper.pos));
			c.rotate(-flipper.restAngle - flipper.sign * flipper.rotation);

			c.fillRect(0.0, -flipper.radius * cScale, 
				flipper.length * cScale, 2.0 * flipper.radius * cScale);
			drawDisc(0, 0, flipper.radius * cScale);
			drawDisc(flipper.length * cScale, 0, flipper.radius * cScale);
			c.resetTransform();				
		} 
	}

	// --- collision handling -------------------------------------------------------

	function handleBallBallCollision(ball1, ball2) 
	{
		var restitution = Math.min(ball1.restitution, ball2.restitution);
		var dir = new Vector2();
		dir.subtractVectors(ball2.pos, ball1.pos);
		var d = dir.length();
		if (d == 0.0 || d > ball1.radius + ball2.radius)
			return;

		dir.scale(1.0 / d);

		var corr = (ball1.radius + ball2.radius - d) / 2.0;
		ball1.pos.add(dir, -corr);
		ball2.pos.add(dir, corr);

		var v1 = ball1.vel.dot(dir);
		var v2 = ball2.vel.dot(dir);

		var m1 = ball1.mass;
		var m2 = ball2.mass;

		var newV1 = (m1 * v1 + m2 * v2 - m2 * (v1 - v2) * restitution) / (m1 + m2);
		var newV2 = (m1 * v1 + m2 * v2 - m1 * (v2 - v1) * restitution) / (m1 + m2);

		ball1.vel.add(dir, newV1 - v1);
		ball2.vel.add(dir, newV2 - v2);
	}

	// -----------------------------------------------------------------
	function handleBallObstacleCollision(ball, obstacle) 
	{
		var dir = new Vector2();
		dir.subtractVectors(ball.pos, obstacle.pos);
		var d = dir.length();
		if (d == 0.0 || d > ball.radius + obstacle.radius)
			return;

		dir.scale(1.0 / d);

		var corr = ball.radius + obstacle.radius - d;
		ball.pos.add(dir, corr);

		var v = ball.vel.dot(dir);
		ball.vel.add(dir, obstacle.pushVel - v);

		physicsScene.score++;
	}

	// ----------------------------------------------------------------
	function handleBallFlipperCollision(ball, flipper) 
	{
		var closest = closestPointOnSegment(ball.pos, flipper.pos, flipper.getTip());
		var dir = new Vector2();
		dir.subtractVectors(ball.pos, closest);
		var d = dir.length();
		if (d == 0.0 || d > ball.radius + flipper.radius)
			return;

		dir.scale(1.0 / d);

		var corr = (ball.radius + flipper.radius - d);
		ball.pos.add(dir, corr);

		// update velocitiy

		var radius = closest.clone();
		radius.add(dir, flipper.radius);
		radius.subtract(flipper.pos);
		var surfaceVel = radius.perp();
		surfaceVel.scale(flipper.currentAngularVelocity);

		var v = ball.vel.dot(dir);
		var vnew = surfaceVel.dot(dir);

		ball.vel.add(dir, vnew - v);
	}

	// ---------------------------------------------------------------------
	function handleBallBorderCollision(ball, border) 
	{
		if (border.length < 3)
			return;

		// find closest segment;

		var d = new Vector2();
		var closest = new Vector2();
		var ab = new Vector2();
		var normal;

		var minDist = 0.0;

		for (var i = 0; i < border.length; i++) {
			var a = border[i];
			var b = border[(i + 1) % border.length];
			var c = closestPointOnSegment(ball.pos, a, b);
			d.subtractVectors(ball.pos, c);
			var dist = d.length();
			if (i == 0 || dist < minDist) {
				minDist = dist;
				closest.set(c);
				ab.subtractVectors(b, a);
				normal = ab.perp();
			}
		}

		// push out
		d.subtractVectors(ball.pos, closest);
		var dist = d.length();
		if (dist == 0.0) {
			d.set(normal);
			dist = normal.length();
		}
		d.scale(1.0 / dist);

		if (d.dot(normal) >= 0.0) {
			if (dist > ball.radius) 
				return;
			ball.pos.add(d, ball.radius - dist);
		}
		else
			ball.pos.add(d, -(dist + ball.radius));

		// update velocity
		var v = ball.vel.dot(d);
		var vnew = Math.abs(v) * ball.restitution;

		ball.vel.add(d, vnew - v);
	}

	// simulation -------------------------------------------------------

	function simulate() 
	{
		for (var i = 0; i < physicsScene.flippers.length; i++)
			physicsScene.flippers[i].simulate(physicsScene.dt);

		for (var i = 0; i < physicsScene.balls.length; i++) {
			var ball = physicsScene.balls[i];
			ball.simulate(physicsScene.dt, physicsScene.gravity);

			for (var j = i + 1; j < physicsScene.balls.length; j++) {
				var ball2 = physicsScene.balls[j];
				handleBallBallCollision(ball, ball2, physicsScene.restitution);
			}

			for (var j = 0; j < physicsScene.obstacles.length; j++)
				handleBallObstacleCollision(ball, physicsScene.obstacles[j]);

			for (var j = 0; j < physicsScene.flippers.length; j++)
				handleBallFlipperCollision(ball, physicsScene.flippers[j]);
	
			handleBallBorderCollision(ball, physicsScene.border);
	
		}
	}

	// ---------------------------------------------------------------

	function update() {
		simulate();
		draw();
		document.getElementById("score").innerHTML = physicsScene.score.toString();		
		requestAnimationFrame(update);
	}
	
	setupScene();
	update();

	// ------------------------ user interaction ---------------------------

	canvas.addEventListener("touchstart", onTouchStart, false);
	canvas.addEventListener("touchend", onTouchEnd, false);

	canvas.addEventListener("mousedown", onMouseDown, false);
	canvas.addEventListener("mouseup", onMouseUp, false);
	
	function onTouchStart(event)
	{
		for (var i = 0; i < event.touches.length; i++) {
			var touch = event.touches[i];

			var rect = canvas.getBoundingClientRect();	
			var touchPos = new Vector2(
				(touch.clientX - rect.left) / cScale, 
				simHeight - (touch.clientY - rect.top) / cScale);

			for (var j = 0; j < physicsScene.flippers.length; j++) {
				var flipper = physicsScene.flippers[j];
				if (flipper.select(touchPos)) 
					flipper.touchIdentifier = touch.identifier;
			}
		}
	}

	function onTouchEnd(event)
	{
		for (var i = 0; i < physicsScene.flippers.length; i++) {
			var flipper = physicsScene.flippers[i];
			if (flipper.touchIdentifier < 0)
				continue;
			var found = false;
			for (var j = 0; j < event.touches.length; j++) {
				if (event.touches[j].touchIdentifier == flipper.touchIdentifier)
					found = true;
			}
			if (!found)
				flipper.touchIdentifier = -1;
		}
	}

	function onMouseDown(event)
	{
		var rect = canvas.getBoundingClientRect();	
		var mousePos = new Vector2(
			(event.clientX - rect.left) / cScale, 
			simHeight - (event.clientY - rect.top) / cScale);

		for (var j = 0; j < physicsScene.flippers.length; j++) {
			var flipper = physicsScene.flippers[j];
			if (flipper.select(mousePos)) 
				flipper.touchIdentifier = 0;
		}
	}

	function onMouseUp(event)
	{
		for (var i = 0; i < physicsScene.flippers.length; i++) 
			physicsScene.flippers[i].touchIdentifier = -1;
	}	

</script> 
</body>
</html>
```
