# Chapter 03 — Ball Collision Handling in 2D

**Video:** https://youtu.be/ThhdlMbGT5g
**Code:** https://raw.githubusercontent.com/matthias-research/pages/master/tenMinutePhysics/03-billiard.html

## Video Transcript

hi malthus from 10 minute physics here welcome to tutorial number three this time i'm going to show you how to handle collisions for this we are going to write a little 2d billiard simulation let's jump right into it before we can start coding we have to look at the math first let us assume we have two balls with masses m1 and m2 and velocities v1 and v2 after a collision they will have new velocities v1 prime and v2 prime we can compute these new velocities with these two equations you might ask where the forces and newton's second law are in these two equations during a collision deformations occur which cause repulsive forces that separate objects for stiff objects this happens during a very short amount of time therefore we only look at the resulting velocities after this process i won't derive these equations here you find derivations in various textbooks the number e that appears in both formulas is the coefficient of restitution if set to 0 the collision will be completely inelastic if set to 1 the collision will be perfectly elastic this was the one-dimensional case however we are interested in the two-dimensional case here the velocities are vectors not simple numbers they are not necessarily aligned with the axis through the centers of the ball therefore we need to look a little bit into vector math you will see that this is very simple at vector v is an entity that has components that are simple numbers we write a vector in bold phase while simple numbers are written in regular font we can also write vectors as square brackets containing the components in column form a 2d vector can represent a point in 2d as in this example or an arrow as for velocities and forces in order to be able to work with vectors we need a few vector operations the first one is scaling here we multiply the vector with a simple number this is done by multiplying each component by this number the result is a vector that points in the same direction but has its length changed we already use this idea to scale forces and velocities by the time step size dt another important operation is the addition of two vectors here i show an important use case for our simulations i add the vector v scaled by the time step size dt to the position x to do this we simply perform this operation on both components it couldn't be simpler another important operation is vector subtraction again we simply perform the subtraction on both components an important use case is to compute a vector that points from a point a to a point b to compute this vector we simply subtract a from b computing their length of a vector is quite easy too here we use the pythagorean theorem the length is the square root of the sum of the squared components this holds for any dimension the length of a vector is written as the vector embraced by two vertical bars a further important concept are normalized vectors these are vectors of length one we can normalize a vector by scaling it by one over its length now comes the most important and most beautiful operation the dot product i view it as a gift of seychard the goddess of mathematics it's super simple to compute and very useful the dot product is written as a dot not a surprise its value is a simple number it is the sum of the products of the components of the two vectors now if we have a vector v and a normalized vector n then the dot product of the two is the length of the projection of v in the direction of n we can call this vn since it is a simple number we write it in regular font the dot product allows us to reduce our 2d problem to 1d and apply the formulas on the first slide with dot product we can also split the vector into two components one that points in the direction of n and one that is perpendicular to n in our particular case we can compute n by normalizing the vector from the center of the ball one to the center of the ball too now we are ready to write some code we start with the html skeleton that we developed in the first tutorial we have a head section where we define a title that will show up in the tab of the browser and then we have the body section that contains the content of the page we have a canvas element and a script section that contains all our javascript code i described the drawing setup part in the first tutorial as well here we define the canvas size and we also define two functions that map physical coordinates into screen coordinates in the drawing function we now simply clear the canvas the update function called simulate and then draw and make sure that it is called again and again the only statement is the first call of the update function now we add some new code after the drawing setup we first define a class vector2 that contains everything that i described in the slides the vector2 class has two members x and y we define them in the constructor then we have a set of methods the first method is set which copies the content of the vector v to this vector then we have the method clone that creates a new vector2 with the content of this vector the add method adds the vector v to this vector and we can also specify a scaling parameter s add vectors adds the vectors a and b and stores the result in this vector the subtract method subtracts the vector v from this vector and again we can define a scaling s subtract vectors subtracts a from b and stores the result in this vector we also define a method length that computes the length of this vector and a method scale that scales this vector by s finally we define the method dot which computes a dot product between this vector and the vector v now we are ready to define our billiard scene we first define a class ball it has four attributes a radius a mass a position and a velocity and we specify all of them in the constructor we only have one method which is the simulate method as before we add gravity times dt to the velocity and velocity times dt to the position in the struct physics scene we define all the information that we need for our simulation we define gravity the time step size a world size a boolean variable post which tells us whether our simulation is paused or not a set of balls and the restitution in the setup scene function we define all these values we define the number of balls on the screen then for each ball we define a random radius mass position and velocity and then we create a new ball object with these four properties and add it to the balls array in the physics scene the draw function is simple first we clear the canvas and then we iterate through all the balls for each ball we render a circle with the ball's position and the ball's radius now comes the interesting part we define a function handle ball collision which takes a ball 1 and the ball 2 and the restitution first we compute a direction vector that points from the position of ball one to the position of ball two we compute its length and then if the length is larger than the radius of ball one plus the radius of ball two then the two balls are not colliding and we can simply return if they are colliding we normalize the direction vector deer by scaling it by one over d next we compute a correction vectors to push the balls apart the distance is the sum of the radii minus the current distance of the balls divided by 2. we move the balls along the direction deer for the ball 1 by minus core and for the ball 2 by plus core next we update the velocities as i showed you on the first slide we first use the dot product to compute the part of the velocities along the direction dear then with the masses m1 and m2 we can compute the new velocities exactly as on the first slide finally we change the velocity components along the direction here we subtract the current velocity and add the new velocity for both balls ball 1 and ball 2. handling the wall collisions is simpler we simply clamp the ball's position against the world bounce and if necessary reflect the velocities here's the simulate function we iterate through all the balls in the physics scene for each ball we call simulate then we use a nested loop to check all possible ball collisions this can get very slow if we have a thousand balls we have to check 1 million collisions in a later tutorial i will show you how to speed this up using spatial hashing finally we call handle wall collision for each ball now let's check how this looks in a browser so now we have it our billiard scene with 20 volts of varying radii and masses i could look at this forever but before we stop we're gonna add one more thing we want to add a button to restart the scene and the slider to specify the restitution for this i add two elements before defining the canvas the first one is a button that when clicked calls setup scene the next is a slider for which we define a minimum of 0 and a maximum of 10. we also specify an id to access it below there's one additional thing we have to add at the very bottom of the document with this statement we specify what happens when the restitution slider is changed in this case a function is called in the function we update the restitution of the physics scene based on the value of the slider so now let's look how this looks in the browser so here's our final result we now have a restart button that lets us recreate the scene and the restitution slider let's set it to zero now as you can see there's no bouncing at all what you can also see is that energy is lost and this is expected as usual i provide a link to the description to a page where i provide the html documents of all the tutorials in the next tutorial i'm going to show you how to write a pinball machine

## Source Code

### 03-billiard.html

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
		<title>Billiard</title>
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
	
<body>

	<button class="button" onclick="setupScene()">Restart</button>
	Restitution <input type = "range" min = "0" max = "10" value = "10" id = "restitutionSlider" class = "slider">
	<br>
	<canvas id="myCanvas" style="border:2px solid"></canvas>
	
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
		}

		dot(v) {
			return this.x * v.x + this.y * v.y;
		}
	}

	// physics scene -------------------------------------------------------

	class Ball {
		constructor(radius, mass, pos, vel) {
			this.radius = radius;
			this.mass = mass;
			this.pos = pos.clone();
			this.vel = vel.clone();
		}
		simulate(dt, gravity) {
			this.vel.add(gravity, dt);
			this.pos.add(this.vel, dt);
		}
	}

	var physicsScene = 
	{
		gravity : new Vector2(0.0, 0.0),
		dt : 1.0 / 60.0,
		worldSize : new Vector2(simWidth, simHeight),
		paused: true,
		balls: [],				
		restitution : 1.0
	};

	function setupScene() 
	{
		physicsScene.balls = [];
		var numBalls = 20;

		for (i = 0; i < numBalls; i++) {

			var radius = 0.05 + Math.random() * 0.1;
			var mass = Math.PI * radius * radius;
			var pos = new Vector2(Math.random() * simWidth, Math.random() * simHeight);
			var vel = new Vector2(-1.0 + 2.0 * Math.random(), -1.0 + 2.0 * Math.random());

			physicsScene.balls.push(new Ball(radius, mass, pos, vel));
		}
	}

	// draw -------------------------------------------------------

	function draw() 
	{
		c.clearRect(0, 0, canvas.width, canvas.height);

		c.fillStyle = "#FF0000";

		for (i = 0; i < physicsScene.balls.length; i++) {
			var ball = physicsScene.balls[i];
			c.beginPath();			
			c.arc(
				cX(ball.pos), cY(ball.pos), cScale * ball.radius, 0.0, 2.0 * Math.PI); 
			c.closePath();
			c.fill();
		}
	}

	// collision handling -------------------------------------------------------

	function handleBallCollision(ball1, ball2, restitution) 
	{
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

	// ------------------------------------------------------

	function handleWallCollision(ball, worldSize) 
	{
		if (ball.pos.x < ball.radius) {
			ball.pos.x = ball.radius;
			ball.vel.x = -ball.vel.x;
		}
		if (ball.pos.x > worldSize.x - ball.radius) {
			ball.pos.x = worldSize.x - ball.radius;
			ball.vel.x = -ball.vel.x;
		}
		if (ball.pos.y < ball.radius) {
			ball.pos.y = ball.radius;
			ball.vel.y = -ball.vel.y;
		}

		if (ball.pos.y > worldSize.y - ball.radius) {
			ball.pos.y = worldSize.y - ball.radius;
			ball.vel.y = -ball.vel.y;
		}
	}

	// simulation -------------------------------------------------------

	function simulate() 
	{
		for (i = 0; i < physicsScene.balls.length; i++) {
			var ball1 = physicsScene.balls[i];
			ball1.simulate(physicsScene.dt, physicsScene.gravity);

			for (j = i + 1; j < physicsScene.balls.length; j++) {
				var ball2 = physicsScene.balls[j];
				handleBallCollision(ball1, ball2, physicsScene.restitution);
			}

			handleWallCollision(ball1, physicsScene.worldSize);
		}
	}

	function update() {
		simulate();
		draw();
		requestAnimationFrame(update);
	}
	
	setupScene();
	update();

	document.getElementById("restitutionSlider").oninput = function() {
		physicsScene.restitution = this.value / 10.0;
	}
	
</script> 
</body>
</html>
```
