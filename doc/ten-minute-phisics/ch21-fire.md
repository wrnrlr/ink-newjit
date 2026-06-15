# Chapter 21 — How to Write a Fire Simulator in a Web Page

**Video:** https://youtu.be/RsgmS3ZxDtc
**Slides:** https://matthias-research.github.io/pages/tenMinutePhysics/21-fire.pdf
**Code:** https://raw.githubusercontent.com/matthias-research/pages/master/tenMinutePhysics/21-fire.html

## Video Transcript

hi Matas from 10minute physics here Welcome To tutorial number 21 today I'm going to show you how to write a fire simulator I've never done this in my entire career so I thought let's give it a try this is my result it's not perfect but I'm quite happy with it as usually I wrote it in JavaScript so you can immediately play with it in your browser the direct link is in the description the fire simulator I will show you here is based on an oian fluid simulator it's the one that I discussed in tutorial number 17 so I highly recommend that you watch this tutorial first how to write an oian fluid simulator however I will give you a very brief recap of that method a fluid is a liquid or a gas in tutorial 17 we looked at passive fluids that are just pushed around today we look at active fluids gas that is burning in the orian fluid simulation method a fluid is represented by a velocity field stored on a grid in two Dimensions the velocity has two components u and v we're going to use a staggered Grid in this grid the two velocity components are not stored in the same location the horizontal component U is stored at the center of the vertical faces the vertical component V is stored at the center of the horizontal faces here is an overview of the oian fluid simulation method there are three steps the first step is to modify the velocity field for instance to add gravity or external forces the second step is called projection here we make sure that the fluid is incompressible the last step is the advection step here we move the velocity field as well as a smoke density field along the velocity field in the grid so the first step is a simple one for instance if we want to add the gravitational acceleration we simply go through all the cells then we add delta T * G to the vertical components V stored in the cells here delta T is the time step size and G is the gravitational acceleration which is about 9.81 m/s squared the second step is projection here we make the fluid incompressible for this we run through all the cells in the grid for each cell we compute the total outflow which is also called the Divergence this is a formula to compute this quantity in this example here the total outflow or Divergence is positive there is more fluid flowing out of the cell than into the cell so we have too much outflow in this example here the Divergence or the total outflow is negative there's too much fluid flowing into the cell only if the Divergence or the total out flow is zero then the fluid is incompressible now how can we force incompressibility in the grid here we have a grid cell with too much inflow what we could do is just modify one velocity component to make the inflow zero however a fluid cannot do that we need to push all the velocity at the same time by the same amount to get a global solution we have to iterate through all the cells multiple times we also have to consider boundary conditions for this have a look at tutorial number 17 the last step is the dection step here we want to move quantities such as the density of the Velocity components along the velocity field stored in the grid so let's assume we have a quantity Q This Could Be the density value or a velocity component if it's a density then it is stored at the center of the cells if it's a velocity component then it is stored at the center of the faing of the cells in order to compute the value of Q at the current time step T we need to know what the value was at the previous time step T minus one for this we Trace Q backwards in time we can compute the position of Q at the previous time step XT minus one by subtracting the velocity times the time step size from the current position here we assume that Q traveled in a straight line which is an approximation the location XT minus VT * delta T is not necessarily located at the center of the cell or at the center of a phase therefore to compute this value we need to compute a weighted average of the values around it here is an overview of the fire simulation method we modify the first step and add a fourth step in the first step we modify the velocity field as before but this time instead of gravity we add lift forces and turbulence in the second step we make the velocity field incompressible as before in the third step we adva the velocity and temperature Fields so instead of having a smoke density field we have a temperature field in the fourth step we modify the temperature field due to burning and cooling I simplified physics a bit in reality there are multiple Fields such as fuel temperature and a smoke field we use only one field which is a normalized temperature field it has values between one and zero for values between 1 and3 we consider the field to represent a burning gas between 3 and Zer it represents smoke the value decreases over time we use three color gradients to render it one between yellow and red one between red and gray and one between gray and black at every time step we initialize T to be one at fire sources we decrease T over time by subtracting a cooling rate times delta T and have to make sure that the temperature doesn't go below zero I use two different cooling rates for fire and smoke then we ADV T along the fluid velocity the temperature field has an influence on the velocities integrate we first compute an upwards Target velocity V Target this is V lift time t v lift is a parameter as you can see the target velocity increases with t once you have the target velocity V Target we drive the current velocity V towards this target velocity here we using acceleration a so we have two parameters to tune the lift and the acceleration a so let's assume we have a burning floor which means all the values at the bottom r one when we run the simulation we get this pattern of course this is not very interesting what we need are external influences and we need to enhance turbulence we do this by introducing swirls a swirl has a position x a radius R an angular velocity Omega and an H swirls are created with a given probability at fire Source cells then they are aded using the velocity field in the R when they reach their maximum age they are deleted let me now show you how swirls influence the velocity field integ grd let's assume that we have a swirl at position X swirl and it influences a GD velocity component at position X grid let bolt D be the vector between X swirl and X grid and D its length we can now use these two statements to update the grid velocity components at X grid the equations pull the current grid velocity components towards the swirl velocity at their locations the strength of this effect is defined by a kernel function k k depends on the distance D between the swirl Center and X grid the function yields a value between zero and one it is zero when D is larger than the SR radius I use a very simple current function it is one up to a dist of8 times the swirl radius then it decreases linearly to zero this concludes the tutorial I hope you had fun thanks for watching and I see you in the next one

## Source Code

### 21-fire.html

```html
<!--
Copyright 2022 Matthias Müller - Ten Minute Physics, 
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
		<title>Fire Simulation</title>
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
	
<body onresize="onResize()">

	<input type = "checkbox" id = "burningFloor" onclick = "scene.burningFloor = !scene.burningFloor"> Floor
	<input type = "checkbox" id = "burningObstacle" onclick = "scene.burningObstacle = !scene.burningObstacle" checked> Ring
	<input type = "checkbox" id = "swirlButton" onclick = "scene.showSwirls = !scene.showSwirls"> Swirls
	<input type = "range" min = "0" max = "100" value = "50" id = "probabilitySlider" class = "slider"> Probability

	<br>
	<canvas id="myCanvas" style="border:2px solid"></canvas>
	
<script>

var scene = 
	{
		gravity : 0.00,
		dt : 1.0 / 60.0,
		numIters : 10,
		frameNr : 0,
		obstacleX : 0.0,
		obstacleY : 0.0,
		obstacleRadius: 0.2,
		burningObstacle: true,
		burningFloor: false,
		paused: false,
		showObstacle: false,
		showSwirls: false,
		swirlProbability: 50.0,
		swirlMaxRadius: 0.05,
		fluid: null
	};


	var canvas = document.getElementById("myCanvas");
	var c = canvas.getContext("2d");	
	canvas.width = window.innerWidth;
	canvas.height = window.innerHeight - 100;

	canvas.focus();

	var cScale = 1.0;

	var U_FIELD = 0;
	var V_FIELD = 1;
	var T_FIELD = 2;

	var cnt = 0;

	function cX(x) {
		return x * cScale;
	}

	function cY(y) {
		return canvas.height - y * cScale;
	}

	function kernel(r, rmax, leftBorder, rightBorder) {
		if (r >= rmax || r <= 0.0)
			return 0.0;
		else if (r < leftBorder)
			return r / leftBorder;
		else if (r <= rmax - rightBorder)
			return 1.0;
		else 
			return (rmax - r) / rightBorder;
	}


	// ----------------- start of simulator ------------------------------

	class Fluid {
		constructor(numX, numY, h) {
			this.numX = numX + 2; 
			this.numY = numY + 2;
			this.numCells = this.numX * this.numY;
			this.h = h;
			this.u = new Float32Array(this.numCells);
			this.v = new Float32Array(this.numCells);
			this.newU = new Float32Array(this.numCells);
			this.newV = new Float32Array(this.numCells);
			this.s = new Float32Array(this.numCells);
			this.t = new Float32Array(this.numCells);
			this.newT = new Float32Array(this.numCells);
			var num = numX * numY;
			this.t.fill(0.0);
			this.s.fill(1.0);
			
			this.numSwirls = 0;

			let maxSwirls = 100;
			this.swirlGlobalTime = 0.0;
			this.swirlX = new Float32Array(maxSwirls);
			this.swirlY = new Float32Array(maxSwirls);
			this.swirlOmega = new Float32Array(maxSwirls);
			this.swirlRadius = new Float32Array(maxSwirls);
			this.swirlTime = new Float32Array(maxSwirls);
			this.swirlTime.fill(0.0);
		}

		integrate(dt, gravity) {
			var n = this.numY;
			for (var i = 1; i < this.numX; i++) {
				for (var j = 1; j < this.numY-1; j++) {
					if (this.s[i*n + j] != 0.0 && this.s[i*n + j-1] != 0.0)
						this.v[i*n + j] += gravity * dt;
				}	 
			}
		}

		solveIncompressibility(numIters, dt) {

			var n = this.numY;
			let overRelaxation = 1.9;

			for (var iter = 0; iter < numIters; iter++) {

				for (var i = 1; i < this.numX-1; i++) {
					for (var j = 1; j < this.numY-1; j++) {

						if (this.s[i*n + j] == 0.0)
							continue;

						var s = this.s[i*n + j];
						var sx0 = this.s[(i-1)*n + j];
						var sx1 = this.s[(i+1)*n + j];
						var sy0 = this.s[i*n + j-1];
						var sy1 = this.s[i*n + j+1];
						var s = sx0 + sx1 + sy0 + sy1;
						if (s == 0.0)
							continue;

						var div = this.u[(i+1)*n + j] - this.u[i*n + j] + 
							this.v[i*n + j+1] - this.v[i*n + j];

						var p = -div / s;
						p *= overRelaxation;
						this.u[i*n + j] -= sx0 * p;
						this.u[(i+1)*n + j] += sx1 * p;
						this.v[i*n + j] -= sy0 * p;
						this.v[i*n + j+1] += sy1 * p;
					}
				}
			}
		}

		extrapolate() {
			var n = this.numY;
			for (var i = 0; i < this.numX; i++) {
				this.u[i*n + 0] = this.u[i*n + 1];
				this.u[i*n + this.numY-1] = this.u[i*n + this.numY-2]; 
			}
			for (var j = 0; j < this.numY; j++) {
				this.v[0*n + j] = this.v[1*n + j];
				this.v[(this.numX-1)*n + j] = this.v[(this.numX-2)*n + j] 
			}
		}

		sampleField(x, y, field) {
			var n = this.numY;
			var h = this.h;
			var h1 = 1.0 / h;
			var h2 = 0.5 * h;

			x = Math.max(Math.min(x, this.numX * h), h);
			y = Math.max(Math.min(y, this.numY * h), h);

			var dx = 0.0;
			var dy = 0.0;

			var f;

			switch (field) {
				case U_FIELD: f = this.u; dy = h2; break;
				case V_FIELD: f = this.v; dx = h2; break;
				case T_FIELD: f = this.t; dx = h2; dy = h2; break

			}

			var x0 = Math.min(Math.floor((x-dx)*h1), this.numX-1);
			var tx = ((x-dx) - x0*h) * h1;
			var x1 = Math.min(x0 + 1, this.numX-1);
			
			var y0 = Math.min(Math.floor((y-dy)*h1), this.numY-1);
			var ty = ((y-dy) - y0*h) * h1;
			var y1 = Math.min(y0 + 1, this.numY-1);

			var sx = 1.0 - tx;
			var sy = 1.0 - ty;

			var val = sx*sy * f[x0*n + y0] +
				tx*sy * f[x1*n + y0] +
				tx*ty * f[x1*n + y1] +
				sx*ty * f[x0*n + y1];
			
			return val;
		}

		avgU(i, j) {
			var n = this.numY;
			var u = (this.u[i*n + j-1] + this.u[i*n + j] +
				this.u[(i+1)*n + j-1] + this.u[(i+1)*n + j]) * 0.25;
			return u;
				
		}

		avgV(i, j) {
			var n = this.numY;
			var v = (this.v[(i-1)*n + j] + this.v[i*n + j] +
				this.v[(i-1)*n + j+1] + this.v[i*n + j+1]) * 0.25;
			return v;
		}

		advectVel(dt) {

			this.newU.set(this.u);
			this.newV.set(this.v);

			var n = this.numY;
			var h = this.h;
			var h2 = 0.5 * h;

			for (var i = 1; i < this.numX; i++) {
				for (var j = 1; j < this.numY; j++) {

					cnt++;

					// u component
					if (this.s[i*n + j] != 0.0 && this.s[(i-1)*n + j] != 0.0 && j < this.numY - 1) {
						var x = i*h;
						var y = j*h + h2;
						var u = this.u[i*n + j];
						var v = this.avgV(i, j);
						x = x - dt*u;
						y = y - dt*v;
						u = this.sampleField(x,y, U_FIELD);
						this.newU[i*n + j] = u;
					}
					// v component
					if (this.s[i*n + j] != 0.0 && this.s[i*n + j-1] != 0.0 && i < this.numX - 1) {
						var x = i*h + h2;
						var y = j*h;
						var u = this.avgU(i, j);
						var v = this.v[i*n + j];
						x = x - dt*u;
						y = y - dt*v;
						v = this.sampleField(x,y, V_FIELD);
						this.newV[i*n + j] = v;
					}
				}	 
			}

			this.u.set(this.newU);
			this.v.set(this.newV);
		}

		advectTemperature(dt) {

			this.newT.set(this.t);

			var n = this.numY;
			var h = this.h;
			var h2 = 0.5 * h;

			for (var i = 1; i < this.numX-1; i++) {
				for (var j = 1; j < this.numY-1; j++) {

					if (this.s[i*n + j] != 0.0) {
						var u = (this.u[i*n + j] + this.u[(i+1)*n + j]) * 0.5;
						var v = (this.v[i*n + j] + this.v[i*n + j+1]) * 0.5;
						var x = i*h + h2 - dt*u;
						var y = j*h + h2 - dt*v;

						this.newT[i*n + j] = this.sampleField(x,y, T_FIELD);
 					}
				}	 
			}
			this.t.set(this.newT);
		}

		updateFire(dt) {

			let h = this.h;

			let swirlTimeSpan = 1.0;
			let swirlOmega = 20.0;
			let swirlDamping = 10.0 * dt;
			let swirlProbability = scene.swirlProbability * h * h;

			var fireCooling = 1.2 * dt;
			var smokeCooling = 0.3 * dt;
			var lift = 3.0;
			var acceleration = 6.0 * dt;
			let kernelRadius = scene.swirlMaxRadius;

			// update swirls

			var n = this.numY;
			let maxX = (this.numX - 1) * this.h;
			let maxY = (this.numY - 1) * this.h;

			// kill swirls

			let num = 0
			for (let nr = 0; nr < this.numSwirls; nr++) {
				this.swirlTime[nr] -= dt;
				if (this.swirlTime[nr] > 0.0) {
					this.swirlTime[num] = this.swirlTime[nr];
					this.swirlX[num] = this.swirlX[nr];
					this.swirlY[num] = this.swirlY[nr];
					this.swirlOmega[num] = this.swirlOmega[nr];
					num++;
				}
			}
			this.numSwirls = num;

			// advect and modify velocity field

			for (let nr = 0; nr < this.numSwirls; nr++) {

				let ageScale = this.swirlTime[nr] / swirlTimeSpan;
				let x = this.swirlX[nr];
				let y = this.swirlY[nr];
				let swirlU = (1.0 - swirlDamping) * this.sampleField(x, y, U_FIELD);
				let swirlV = (1.0 - swirlDamping) * this.sampleField(x, y, V_FIELD);
				x += swirlU * dt;
				y += swirlV * dt;
				x = Math.min(Math.max(x, h), maxX);
				y = Math.min(Math.max(y, h), maxY);

				this.swirlX[nr] = x;
				this.swirlY[nr] = y;
				let omega = this.swirlOmega[nr];

				// update surrounding velocity field

				let x0 = Math.max(Math.floor((x - kernelRadius) / h), 0);
				let y0 = Math.max(Math.floor((y - kernelRadius) / h), 0);
				let x1 = Math.min(Math.floor((x + kernelRadius) / h) + 1, this.numX - 1);
				let y1 = Math.min(Math.floor((y + kernelRadius) / h) + 1, this.numY - 1);

				for (let i = x0; i <= x1; i++) {
					for (let j = y0; j <= y1; j++) {
						for (let dim = 0; dim < 2; dim++) {

							let vx = dim == 0 ? i * h : (i + 0.5) * h;
							let vy = dim == 0 ? (j + 0.5) * h : j * h;

							let rx = vx - x;
							let ry = vy - y;
							let r = Math.sqrt(rx * rx + ry * ry);

							if (r < kernelRadius) {
								let s = 1.0;
								if (r > 0.8 * kernelRadius) {
									s = 5.0 - 5.0 / kernelRadius * r;
									// s = (kernelRadius - r) / kernelRadius * ageScale;
								}
							
								if (dim == 0) {
									let target = ry * omega + swirlU;
									let u = this.u[n*i + j];
									this.u[n*i + j] = (target - u) * s;
								}
								else {
									let target = -rx * omega + swirlV;
									let v = this.v[n*i + j];
									this.v[n*i + j] += (target - v) * s;
								}
							}
						}
					}
				}
			}

			// update temperatures 

			let minR = 0.85 * scene.obstacleRadius;
			let maxR = scene.obstacleRadius + h;

			for (var i = 0; i < this.numX; i++) {
				for (var j = 0; j < this.numY; j++) {
					let t = this.t[i*n + j];

					let cooling = t < 0.3 ? smokeCooling : fireCooling;
					this.t[i*n + j] = Math.max(t - cooling, 0.0);
					let u = this.u[i*n + j];
					let v = this.v[i*n + j];
					let targetV = t * lift;
					this.v[i*n + j] += (targetV - v) * acceleration;

					let numNewSwirls = 0;

					// obstacle burning
					if (scene.burningObstacle) {
						let dx = (i + 0.5) * this.h - scene.obstacleX;
						let dy = (j + 0.5) * this.h - scene.obstacleY - 3.0 * this.h;
						let d = dx * dx + dy * dy;
						if (minR * minR <= d && d < maxR * maxR) {
							this.t[i*n + j] = 1.0;
							if (Math.random() < 0.5 * swirlProbability)
								numNewSwirls++;
						}
					}

					// floor burning
					if (j < 4 && scene.burningFloor) {
						this.t[i*n + j] = 1.0;
						this.u[i*n + j] = 0.0;
						this.v[i*n + j] = 0.0;
						if (Math.random() < swirlProbability)
							numNewSwirls++;
					}

					for (let k = 0; k < numNewSwirls; k++) {
						if (this.numSwirls >= this.maxSwirls)
							break;
						let nr = this.numSwirls;
						this.swirlX[nr] = i * h;
						this.swirlY[nr] = j * h;
						this.swirlOmega[nr] = (-1.0 + 2.0 * Math.random()) * swirlOmega;
						this.swirlTime[nr] = swirlTimeSpan;
						this.numSwirls++;
					}
				}
			}

			// foo: maybe for obstacle
			
			// smooth temperatures

			for (let i = 1; i < this.numX - 1; i++) {
				for (let j = 1; j < this.numY - 1; j++) {
					let t = this.t[i * n + j];
					if (t == 1.0) {
						let avg = (
							this.t[(i - 1) * n + (j - 1)] + 
							this.t[(i + 1) * n + (j - 1)] + 
							this.t[(i + 1) * n + (j + 1)] + 
							this.t[(i - 1) * n + (j + 1)]) * 0.25;
						this.t[i * n + j] = avg;
					}
				}
			}
		}

		// ----------------- end of simulator ------------------------------

		simulate(dt, gravity, numIters) {

			this.integrate(dt, gravity);

			this.solveIncompressibility(numIters, dt);
			this.extrapolate();
			this.advectVel(dt);
			this.advectTemperature(dt);
			this.updateFire(dt);
		}
	}

	function setupScene() 
	{
		var canvas = document.getElementById("myCanvas");
		canvas.width = window.innerWidth;
		canvas.height = window.innerHeight - 20;

		let simHeight = 1.0;	
		cScale = canvas.height / simHeight;
		let simWidth = canvas.width / cScale;

		var numCells = 100000;
		var h = Math.sqrt(simWidth * simHeight / numCells);

		var numX = Math.floor(simWidth / h);
		var numY = Math.floor(simHeight / h);

		if (numX < numY) {
			scene.swirlProbability = 80.0;
			scene.swirlMaxRadius = 0.04;
		}

		scene.obstacleX = 0.5 * numX * h;
		scene.obstacleY = 0.3 * numY * h;
		scene.showObstacle = scene.burningObstacle;

		scene.fluid = new Fluid(numX, numY, h);
	}


	// draw -------------------------------------------------------

	function setColor(r,g,b) {
		c.fillStyle = `rgb(
			${Math.floor(255*r)},
			${Math.floor(255*g)},
			${Math.floor(255*b)})`
		c.strokeStyle = `rgb(
			${Math.floor(255*r)},
			${Math.floor(255*g)},
			${Math.floor(255*b)})`
	}

	function getFireColor(val) {
		val = Math.min(Math.max(val, 0.0), 1.0);
		var r, g, b;

		if (val < 0.3) {
			let s = val / 0.3;
			r = 0.2 * s; g = 0.2 * s; b = 0.2 * s; 
		}
		else if (val < 0.5) {
			let s = (val-0.3) / 0.2;
			r = 0.2 + 0.8 * s; g = 0.1; b = 0.1;
		}
		else  {
			let s = (val - 0.5) / 0.48;
			r = 1.0; g = s; b = 0.0;
		}
		return[255*r,255*g,255*b, 255]
	}

	function draw() 
	{
		c.clearRect(0, 0, canvas.width, canvas.height);

		c.fillStyle = "#FF0000";
		f = scene.fluid;
		n = f.numY;

		var cellScale = 1.1;

		var h = f.h;

		id = c.getImageData(0,0, canvas.width, canvas.height)

		var color = [255, 255, 255, 255]

		for (var i = 0; i < f.numX; i++) {
			for (var j = 0; j < f.numY; j++) {

				var t = f.t[i*n + j];
				color = getFireColor(t, 0.0, 1.0);

				var x = Math.floor(cX(i * h));
				var y = Math.floor(cY((j+1) * h));
				var cx = Math.floor(cScale * cellScale * h) + 1;
				var cy = Math.floor(cScale * cellScale * h) + 1;

				r = color[0];
				g = color[1];
				b = color[2];

				for (var yi = y; yi < y + cy; yi++) {
					var p = 4 * (yi * canvas.width + x)

					for (var xi = 0; xi < cx; xi++) {
						id.data[p++] = r;
						id.data[p++] = g;
						id.data[p++] = b;
						id.data[p++] = 255;
					}
				}
			}
		}

		c.putImageData(id, 0, 0);

		if (scene.showObstacle) {

			r = scene.obstacleRadius + f.h;
			if (scene.showPressure)
				c.fillStyle = "#000000";
			else
				c.fillStyle = "#DDDDDD";
			// c.beginPath();	
			// c.arc(
			// 	cX(scene.obstacleX), cY(scene.obstacleY), cScale * r, 0.0, 2.0 * Math.PI); 
			// c.closePath();
			// c.fill();

			c.lineWidth = 20.0;
			c.strokeStyle = "#404040";
			c.beginPath();	
			c.arc(
				cX(scene.obstacleX), cY(scene.obstacleY), cScale * r, 0.0, 2.0 * Math.PI); 
			c.closePath();
			c.stroke();
			c.lineWidth = 1.0;
		}

		if (scene.showSwirls) {

			for (let i = 0; i < f.numSwirls; i++) {
				let x = f.swirlX[i];
				let y = f.swirlY[i];
				let r = scene.swirlMaxRadius;

				c.lineWidth = 1.0;
				c.strokeStyle = "#303030";
				c.beginPath();	
				c.arc(
					cX(x), cY(y), cScale * r, 0.0, 2.0 * Math.PI); 
				c.closePath();
				c.stroke();
				c.lineWidth = 1.0;
			}
		}
	}

	function setObstacle(x, y, reset) {

		var vx = 0.0;
		var vy = 0.0;

		if (!reset) {
			vx = (x - scene.obstacleX) / scene.dt;
			vy = (y - scene.obstacleY) / scene.dt;
		}

		scene.obstacleX = x;
		scene.obstacleY = y;
		scene.showObstacle = true;

		var r = scene.obstacleRadius;
		var f = scene.fluid;
		var n = f.numY;
		var cd = Math.sqrt(2) * f.h;

		for (var i = 1; i < f.numX-2; i++) {
			for (var j = 1; j < f.numY-2; j++) {

				f.s[i*n + j] = 1.0;

				dx = (i + 0.5) * f.h - x;
				dy = (j + 0.5) * f.h - y;

				let d2 = dx * dx + dy * dy;
				if (d2 < r * r) {
					// f.s[i*n + j] = 0.0;
					f.u[i*n + j] += 0.2 * vx;
					f.u[(i+1)*n + j] += 0.2 * vx;
					f.v[i*n + j] += 0.2 * vy;
					f.v[i*n + j+1] += 0.2 * vy;
				}
			}
		}
	}

	// interaction -------------------------------------------------------

	var mouseDown = false;

	function startDrag(x, y) {
		let bounds = canvas.getBoundingClientRect();

		let mx = x - bounds.left - canvas.clientLeft;
		let my = y - bounds.top - canvas.clientTop;
		mouseDown = true;

		x = mx / cScale;
		y = (canvas.height - my) / cScale;

		setObstacle(x,y, true);
	}

	function drag(x, y) {
		if (mouseDown) {
			let bounds = canvas.getBoundingClientRect();
			let mx = x - bounds.left - canvas.clientLeft;
			let my = y - bounds.top - canvas.clientTop;
			x = mx / cScale;
			y = (canvas.height - my) / cScale;
			setObstacle(x,y, false);
		}
	}

	function endDrag() {
		mouseDown = false;
	}

	canvas.addEventListener('mousedown', event => {
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


	document.addEventListener('keydown', event => {
		switch(event.key) {
			case 'p': scene.paused = !scene.paused; break;
			case 'm': scene.paused = false; simulate(); scene.paused = true; break;
		}
	});

	function toggleStart()
	{
		var button = document.getElementById('startButton');
		if (scene.paused)
			button.innerHTML = "Stop";
		else
			button.innerHTML = "Start";
		scene.paused = !scene.paused;
	}

	document.getElementById("probabilitySlider").oninput = function() {
		scene.swirlProbability = this.value;
	}

	var resizeTimer = 0;
	
	onResize = function() {
    	clearTimeout(resizeTimer);
		resizeTimer = setTimeout(setupScene, 300);
	};

	// main -------------------------------------------------------

	function simulate() 
	{
		if (!scene.paused)
			scene.fluid.simulate(scene.dt, scene.gravity, scene.numIters)
			scene.frameNr++;
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
