# Chapter 01 — Introduction to 2D Web Browser Physics

**Video:** https://youtu.be/oPuSvdBGrpE
**Code:** https://raw.githubusercontent.com/matthias-research/pages/master/tenMinutePhysics/01-cannonball2d.html

## Video Transcript

hi i'm maltese miller a physics researcher at nvidia i've been working as a researcher in the field of physics-based simulations in computer graphics for over 20 years now over the years my colleagues and i have come up with a variety of methods to simulate rigid bodies soft bodies cloth water and their interaction these methods have become popular both in the gaming and in the movie industry i have always had three main goals in mind simplicity robustness and speed simplicity means that the methods are easy to understand and to implement robustness means that the methods produce realistic simulations either under unphysical or crazy setups and speed means that the methods can be used in real-time applications such as computer games if you look for simulation methods in research articles or books you most likely find quite complicated formulations that only a small percentage of people interested in physical simulations understand fortunately physics is quite simple at its heart i'm talking about the physics of everyday objects everything around us is made of simple particles the atoms and the forces that hold them together the difference between a rigid body cloth and water is just how these particles are arranged and the strength of the forces that hold them together therefore it should be possible to simulate everyday objects with very simple methods and this is indeed the case in this channel i will show you how easy it is to write simulations of rigid bodies soft bodies cloth sand and their mutual interactions setting up development environments libraries and creating applications that work on multiple platforms used to be difficult fortunately this has become super simple too this is the fact for me to create this channel i will use javascript embedded in web pages to write and test simulations all we need is a text editor and a browser i will write the programs into one single html document drop it into a browser and we have fun and you can try out what we implemented on all platforms pcs tablets cell phones android windows mac os and linux devices i will use the free visual studio code editor for microsoft this great tool makes writing javascript very easy with code completion syntax highlighting and error checking as a browser i will use google chrome because i like its built-in debugger before we start i would actually like to thank nvidia i've been with nvidia for 13 years and i can't think of a better place to work they gave me a lot of freedom for my research and the opportunity to work with very smart and talented and creative people without that most of the research you're going to see wouldn't exist also if you want to do physics in games you don't have to port our javascript code into c plus have a look at our physics engine physx it's also included in our new environment omniverse which also provides real-time ray tracing now let's start with our project as i mentioned before we're going to put all our code into one single html document so that we can run our demos in any browser since an html document is a text document we need a text editor i use the free visual studio code editor for microsoft because it has code completion and syntax highlighting but you can use any other text editor i'm not going to type online because this way we would be restricted by my typing speed instead i'm going to use copy paste so we can concentrate on the content so here's a very basic html document html stands for hypertext markup language and what makes a text a hypertext are these tags here which are names surrounded by angle brackets as you can see there are start and end tags and certain tags have attributes as well as start and the end tag mark a certain block in the text file in a html file we can have commands and there is this tag that tells us that this is actually an html document and then we have the html section inside this section we have a head section and a body section in the head we can define a title which will show up in the tab of the browser and here is the actual content of the page we need a canvas element here we can draw our scene and then there's the script section and this is basically where the code javascript code will go into here you can see what happens when you load this html document into a browser we have the canvas with some random size and we have the title in the tab of the browser but nothing more the next step is to fill the script section with some code here i define three functions a draw function in which we're going to draw our scene a simulation function and an update function the update function called simulate then draw and then make sure that the update function is called again and again these are just three function definitions the only actual command is this one which makes sure that the update function is called the first time okay so let's write some actual content by the way javascript is quite similar to c plus plus the language that i mostly use and there are also a lot of tutorials and great web pages to learn it so first we want to resize the canvas that it fills the inner width and height of the document for this we need a variable that refers to the canvas and we do this by defining an id for the canvas element and then getting this canvas element by get element by id and store it in the variable canvas we also need a reference to the 2d context to draw to do the drawing later so to resize the canvas we simply set its width and height to the inner width and inner height of the window with some margin now we need to briefly talk about coordinate systems the coordinate system within the canvas has its origin at the top left and the width and the height are given by these two variables in physics we want the origin to be at the bottom left and we want to specify the same width and the same height therefore we need to be able to map from one coordinate system to the other so here is how i do this in code i first define a variable sim min width which defines a minimal distance that i want to see on the screen no matter how the screen is oriented then i compute a scaling factor to go from the simulation coordinates to the canvas coordinates with this variable i compute the actual sim width and sim height by simply scaling the sizes of the canvas now i define two functions for both coordinates to go from simulation to canvas coordinates for the x component i simply need to scale but for the y component i also need to flip vertically what we wrote so far is pretty boring but we can reuse it for any 2d simulation in the future now it gets a little bit more interesting our original goal was to simulate the canon ball so we first define a ball with a radius and a position the radius is 20 centimeters and the position is at the bottom left the next thing is that we want to draw our scene first we clear the canvas and then we define the fill style of the cannonball which is red in this case this is how you draw a filled circle in javascript it's a little bit clumsy but the essential part is that you have to define a center and a radius we use our transformation functions to map the ball's position from physical to canvas coordinates and to compute the radius we simply multiply the physical radius by the scaling factor now let's see how this looks in a web browser so now here we have it we have our canvas 20 meters across and our little cannonball with a radius of 20 centimeters at the bottom left corner now comes the essential part basically the simulation of the cannonball in order to be able to write this i need to give you a brief introduction to physics the most important equation that describes everyday physics is f equals m times a or force equals mass times acceleration also known as newton's second law it basically says that a force doesn't change the position of objects but their velocities the same force has a stronger effect on lighter objects and a weaker effect on heavier objects it also means that without a force objects keep a constant velocity and this means for simulation we have to store not just the position of objects but also their velocities for simulation there's a very important force its gravity is the force that pulls objects towards the surface of the earth gravity is equal to mass times g where g is a constant if we plug this force into newton's second law we find that all objects independent of their mass are accelerated by the same amount 10 meters per second per second this means for an object in free fall if it starts with zero velocity it has a velocity of 10 meters per second after one second 20 meters per second after two seconds and so on let's assume we have a one-dimensional simulation of one object so we can store its position in x its velocity in v gravitational acceleration in g and the time step size in dt and here is our simulation loop since an acceleration tells us how much the velocity changes over time we update the velocity as v equals v plus g times dt the velocity tells us how much the position changes over time so position equals position plus v times dt then we draw the scene and we loop a method to compute the velocity and position at the next time step given the quantities at the current time step is called the time integration method the simple way we do it here is called symplectic euler a pretty fancy name for a very simple idea it's important that we update the velocity before the position in order to get a stable simulation the problem with this idea is that we assume that both the force as well as the velocity or constant during the entire time step while this is true for the gravitational force it's not true for the velocity which means we introduce a small error every time step the question is how can we make this error small one way is to use calculus to compute an explicit formula that describes the trajectory of our objects unfortunately this only works for toy problems even for a double pendulum it doesn't work anymore as you will see in another episode another idea would be to use more sophisticated time integration methods however they're slower and no improvement when collisions occur the easiest way to reduce the error is to make dt small it's very simple and it works great one way to reduce the time step size is to use sub stepping first we define n to be the number of sub steps and then we compute the size of a substep to be dt divided by n in the simulation loop we now have a for loop over n sub steps as before we update the velocity and deposition but now using sdt then after the n sub steps we draw the scene and loop now i'll show you how easy it is to bring this cannonball to life with just a little knowledge about physics we first define gravity and the time step size as discussed before we also add a velocity component to the ball we initialize it such that it flies off in the beginning now in a simulation loop we add gravity times the time step size to the velocity and the velocity times the time step size to the position as discussed before to make sure that the ball doesn't leave the window we reflect it at the boundaries of the window for this we check the x component of the position every time step if it's smaller than 0 we set it to 0 and reflect the x component of the velocity the same on the other side of the window and also for the y component of the ball now let's see how this looks like in action nice exactly as we expected in the next tutorial i will show you how to write 3d simulations and how to simulate our canon ball in 3d in the description below i provide a link to the complete html code ok see you in the next tutorial

## Source Code

### 01-cannonball2d.html

```html
<!--
Copyright 2021 Matthias Müller - Ten Minute Physics

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
-->

<!DOCTYPE html>
<html>

<head>
<title>Cannonball</title>
</head>

<body>

<canvas id="myCanvas" style="border:2px solid"></canvas>

<script>

	// canvas setup -------------------------------------------------------

	var canvas = document.getElementById("myCanvas");
	var c = canvas.getContext("2d");

	canvas.width = window.innerWidth - 20;
	canvas.height = window.innerHeight - 100;

	var simMinWidth = 20.0;
	var cScale = Math.min(canvas.width, canvas.height) / simMinWidth;
	var simWidth = canvas.width / cScale;
	var simHeight = canvas.height / cScale;

	function cX(pos) {
		return pos.x * cScale;
	}

	function cY(pos) {
		return canvas.height - pos.y * cScale;
	}

	// scene -------------------------------------------------------

	var gravity = { x: 0.0, y: -10.0};
	var timeStep = 1.0 / 60.0;

	var ball = {
		radius : 0.2,
		pos : {x : 0.2, y : 0.2},
		vel : {x : 10.0, y : 15.0}
	};

	// drawing -------------------------------------------------------

	function draw() {
		c.clearRect(0, 0, canvas.width, canvas.height);

		c.fillStyle = "#FF0000";

		c.beginPath();			
		c.arc(
			cX(ball.pos), cY(ball.pos), cScale * ball.radius, 0.0, 2.0 * Math.PI); 
		c.closePath();
		c.fill();			
	}

	// simulation ----------------------------------------------------

	function simulate() {

		ball.vel.x += gravity.x * timeStep;
		ball.vel.y += gravity.y * timeStep;
		ball.pos.x += ball.vel.x * timeStep;
		ball.pos.y += ball.vel.y * timeStep;

		if (ball.pos.x < 0.0) {
			ball.pos.x = 0.0;
			ball.vel.x = -ball.vel.x;
		}
		if (ball.pos.x > simWidth) {
			ball.pos.x = simWidth;
			ball.vel.x = -ball.vel.x;
		}
		if (ball.pos.y < 0.0) {
			ball.pos.y = 0.0;
			ball.vel.y = -ball.vel.y;
		}
	}

	// make browser to call us repeatedly -----------------------------------

	function update() {
		simulate();
		draw();
		requestAnimationFrame(update);
	}
	
	update();
	
</script> 
</body>
</html>
```
