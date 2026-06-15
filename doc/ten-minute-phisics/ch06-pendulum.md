# Chapter 06 — Writing a Triple Pendulum Simulation is Simple

**Video:** https://youtu.be/XPZEeS70zzU
**Code:** https://raw.githubusercontent.com/matthias-research/pages/master/tenMinutePhysics/06-pendulumShort.html
**Code:** https://raw.githubusercontent.com/matthias-research/pages/master/tenMinutePhysics/06-pendulum.html

## Video Transcript

hi maltese from 10 minute physics here welcome to tutorial number six today i'm going to show you how to handle hard distance constraints with position based dynamics they can be used for the simulation of a variety of objects like cloth ropes hair fur and even sand to show you the simplicity and accuracy of position based dynamics we will write a simulation of an n pendulum this one is a double pendulum let's start okay so let's have a look at harsh distance constraints hard means they are conceptually springs with infinite stiffness the distance constraint makes sure that the distance between two particles is constant if l0 is the initial distance then we want the current distance l to remain l0 hard distance constraints are very useful they can be used to simulate non-stretchable cloth ropes hair fur robot arms or sand if they are one-sided exactly as in the case of a bead on a wire there are three main methods to handle harsh distance constraints we could use a spring to force the distance to be l0 however as last time we need to tune the stiffness parameter and large differences cause numerical problems the second approach is to use constraint forces here we solve for constraint forces that make the velocities of the particles perpendicular to the common line between the particles however solving for constrained forces especially when multiple distance constraints are present is non-trivial and the drift problem has to be solved as well a third approach is to use generalized coordinates for distance constraints instead of using independent sets of coordinates for the two particles we could describe the configuration by specifying the center of the particles and the angle of the distance constraint this way the constraint is satisfied by construction again as we saw in the last tutorial this formulation gets complicated even for moderate systems so let's have a look at position based dynamics as in the beat on wire example we simply move the particles so that the constraint is satisfied here are the equations we first compute the constraint error as the difference between the current distance and the rest distance we then scale the normal vector from particle 1 to particle 2 with this value the correction vector is then evenly split between the two particles what if the masses are different here particle 1 has mass m1 and particle 2 has mass m2 in this case we distribute the correction vector proportional to the inverse masses of the particles here are the equations we simply replace the one-half with normalized inverse masses scaling by the inverse masses makes sense imagine we want to attach the particle 2 to a wall in this case we simply set the mass of particle one to infinity which means w1 is zero now particle one is not moved at all and the full correction vector is applied to particle two we have to extend the position-based dynamics algorithm a bit since we have multiple particles now and multiple constraints so for the integration we iterate through all the particles and add gravity times dt to the velocity then we store the current position of particle i to the variable pi and only then we add the velocity times dt to the position of particle i there might be more than one distance constraint so we have to iterate through them as well for each constraint we apply the corrections to the adjacent particles as described before finally we update the velocities by iterating through all the particles and set their velocity to the current position minus the position at the beginning of the time step divided by dt okay so let's use these equations to write an n pendulum simulation here's my solution i tried to make it as short as possible but still easy to read i even omitted the vector 2 class and wrote everything in a straightforward way the whole document is only 116 lines long at the top we specified the lengths masses and initial angles of the pendulum right now these arrays have only three entries so we will simulate a triple pendulum however the implementation works for pendulum of any size you can just make these arrays longer than follows the usual code for the canvas setup and transformation of coordinates next i define the pendulum class the constructor just initializes all the quantities we need for the simulation the core is of course the simulation method as you can see it fits on the screen and only contains 23 lines of code it is a one-to-one and easy to read implementation of the algorithm i just described in the first loop i update the velocities store the position and update them using the velocities in the second loop i iterate through all the links and for each link i compute the direction and magnitude of the distance error then i apply the correction to both particles weighted by the inverse masses the third loop updates the velocities the draw is not very exciting it just draws masses as disks and links as lines the simulate function calls the simulate method of the pendulum using sub stepping finally we have the update function that repeatedly calls simulate and draw so let's see how this looks in the browser okay cool we get the interesting and chaotic behavior of a triple pendulum as in a previous tutorial we might ask how accurate is this at this point i want to make an important remark some of you might have heard about xpbt and how it fixes the inaccuracy of pbd this actually is only true for soft constraints for hard constraints pbd is as accurate as xpbd pendula with more than one link show chaotic behavior this means small errors have huge effects on the future behavior of the system so the question is for how long can position-based dynamics generate the true trajectory of the pendulum as last time we will compare against the analytic solution there are many videos and resources of the double pendulum so reproducing these results is not really exciting finding information about the triple pendulum however is much harder after a longer web search i finally found a paper with the derivation of the equations of the triple pendulum here is the impressive result there are three equations for three unknown angular accelerations all quantities except the angular accelerations are known at the given time step so we can solve a linear 3x3 system of equations to get the angular accelerations here is the implementation it's substantially longer now because it contains the analytics solver as well as a bunch of cool features i define three buttons one for choosing different examples one to start the simulation and one for single stepping the setup of the canvas and the pendulum are exactly the same however now we can choose between two solvers the pbd solver and the analytic solver the analytic solver is just an implementation of the crazy equations you just saw on the slides there's one thing i have to clarify though once we have the angular accelerations a1 a2 and a3 we do need a numerical integration scheme to compute the new angular velocities and angles so this part is not truly analytic in fact there is no closed form equation for the triple pendulum not even for a double pendulum actually however we use symplectic euler with very tiny time steps so we get very close to an analytic solution in this loop we compute the positions of the masses based on angles and links because that's all we have in the analytic solver i also added a feature to draw the trail of the lowest mass which helps to see its motion so let's put this into action here we have a standard triple pendulum i draw the analytic solution in green and position based dynamics in red as you can see they are in agreement for quite a long time this is remarkable since tiny differences in the state let the triple pendulum's path diverge very quickly here is another example in this example we have a mass ratio of 1 to 100 and position based dynamics handles this scenario without problems and then as i said our code can handle pendula of any length here is a queen tuple pendulum this would actually be a pretty cool screen saver i think in these comparisons we have used a crazy number of sub steps 10 000 to be precise this was just to match the chaotic trajectories of a triple pendulum however only a few sub steps are typically enough to simulate common objects like cloth or hair here are all examples with just one sub step as you can see there's a lot of damping however for cloth and rope simulation this is perfectly fine constraints with high mass ratios get very stretchy though fortunately we can solve this with as few as five sub steps as usual in the description i provide a link to a page that contains all the html files of all the tutorials i hope you had fun and i see you in the next tutorial you

## Source Code

### 06-pendulumShort.html

```html
<!DOCTYPE html>
<html>
<body>
	<canvas id = "myCanvas"></canvas>
<script>
    var lengths = [0.2, 0.2, 0.2];
    var masses = [1.0, 0.5, 0.3];
    var angles = [0.5 * Math.PI, Math.PI, Math.PI];

    var canvas = document.getElementById("myCanvas");
	var c = canvas.getContext("2d");
	canvas.width = window.innerWidth - 20;
	canvas.height = window.innerHeight - 20;
	var simMinWidth = 1.0;
	var cScale = Math.min(canvas.width, canvas.height) / simMinWidth;

	function cX(pos) { return canvas.width / 2 + pos.x * cScale; }
	function cY(pos) { return 0.4 * canvas.height - pos.y * cScale; }

    class Pendulum {
        constructor(masses, lengths, angles) {
            this.masses = [0.0];
            this.lengths = [0.0];
            this.pos = [{x:0.0, y:0.0}];
            this.prevPos = [{x:0.0, y:0.0}];
            this.vel = [{x:0.0, y:0.0}];
            var x = 0.0, y = 0.0;
            for (var i = 0; i < masses.length; i++) {
                this.masses.push(masses[i]);
                this.lengths.push(lengths[i]);
                x += lengths[i] * Math.sin(angles[i]);
                y += lengths[i] * -Math.cos(angles[i]); 
                this.pos.push({ x:x, y:y});
                this.prevPos.push({ x:x, y:y});
                this.vel.push({x:0, y:0});
            }
        }
        simulate(dt, gravity) 
        {
            var p = this;
            for (var i = 1; i < p.masses.length; i++) {
                p.vel[i].y += dt * scene.gravity;
                p.prevPos[i].x = p.pos[i].x;
                p.prevPos[i].y = p.pos[i].y;
                p.pos[i].x += p.vel[i].x * dt;
                p.pos[i].y += p.vel[i].y * dt;
            }
            for (var i = 1; i < p.masses.length; i++) {
                var dx = p.pos[i].x - p.pos[i-1].x;
                var dy = p.pos[i].y - p.pos[i-1].y;
                var d = Math.sqrt(dx * dx + dy * dy);
                var w0 = p.masses[i - 1] > 0.0 ? 1.0 / p.masses[i - 1] : 0.0;
                var w1 = p.masses[i] > 0.0 ? 1.0 / p.masses[i] : 0.0;
                var corr = (p.lengths[i] - d) / d / (w0 + w1);
                p.pos[i - 1].x -= w0 * corr * dx; 
                p.pos[i - 1].y -= w0 * corr * dy; 
                p.pos[i].x += w1 * corr * dx; 
                p.pos[i].y += w1 * corr * dy; 
            }
            for (var i = 1; i < p.masses.length; i++) {
                p.vel[i].x = (p.pos[i].x - p.prevPos[i].x) / dt;
                p.vel[i].y = (p.pos[i].y - p.prevPos[i].y) / dt;
            }
        }
        draw() {
            var p = this;
            c.strokeStyle = "#303030";
            c.lineWidth = 10;
            c.beginPath();
            c.moveTo(cX(p.pos[0]), cY(p.pos[0]));
            for (var i = 1; i < p.masses.length; i++) 
                c.lineTo(cX(p.pos[i]), cY(p.pos[i]));
            c.stroke();
            c.lineWidth = 1;            

            c.fillStyle = "#FF0000";
            for (var i = 1; i < p.masses.length; i++) {
                var r = 0.05 * Math.sqrt(p.masses[i]);
                c.beginPath();			
                c.arc(
                    cX(p.pos[i]), cY(p.pos[i]), cScale * r, 0.0, 2.0 * Math.PI); 
                c.closePath();
                c.fill();
            }
        }
    }

    var scene = {
        gravity : -10.0,
        dt : 0.01,
        numSubSteps : 100,
        pendulum : new Pendulum(masses, lengths, angles)
    };

    function draw() {
        c.fillStyle = "#000000";
        c.fillRect(0, 0, canvas.width, canvas.height);
        scene.pendulum.draw();
    }

    function simulate() {
        var sdt = scene.dt / scene.numSubSteps;
        for (var step = 0; step < scene.numSubSteps; step++) 
            scene.pendulum.simulate(sdt, scene.gravity);
    }

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

### 06-pendulum.html

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
<title>Pendulum</title>
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

<body>
	<button class="button" onclick="setupScene()">Restart</button>
	<button class="button" onclick="run()">Run</button>
	<button class="button" onclick="step()">Step</button>
    <p>Number of sub-steps: <input type = "range" min = "0" max = "5" value = "5" id = "stepsSlider" class = "slider"> <span id = "steps">10000</span></p>

	<canvas id = "myCanvas"></canvas>
<script>
   	var canvas = document.getElementById("myCanvas");
	var c = canvas.getContext("2d");
	canvas.width = window.innerWidth - 20;
	canvas.height = window.innerHeight - 20;

	var simMinWidth = 1.0;
	var cScale = Math.min(canvas.width, canvas.height) / simMinWidth;

	function cX(pos) { return canvas.width / 2 + pos.x * cScale; }
	function cY(pos) { return 0.4 * canvas.height - pos.y * cScale; }

    class Pendulum {
        constructor(usePBD, color, masses, lengths, angles) {
            this.usePBD = usePBD;
            this.color = color;
            this.masses = [0.0];
            this.lengths = [0.0];
            this.pos = [{x:0.0, y:0.0}];
            this.prevPos = [{x:0.0, y:0.0}];
            this.vel = [{x:0.0, y:0.0}];
            this.theta = [0.0];
            this.omega = [0.0];

            this.trail = new Int32Array(1000);
            this.trailFirst = 0;
            this.trailLast = 0;

            var x = 0.0, y = 0.0;
            for (var i = 0; i < masses.length; i++) {
                this.masses.push(masses[i]);
                this.lengths.push(lengths[i]);
                this.theta.push(angles[i]);
                this.omega.push(0.0);
                x += lengths[i] * Math.sin(angles[i]);
                y += lengths[i] * -Math.cos(angles[i]); 
                this.pos.push({ x:x, y:y});
                this.prevPos.push({ x:x, y:y});
                this.vel.push({x:0, y:0});
            }
        }
        simulate(dt, gravity) {
            if (this.usePBD)
                this.simulatePBD(dt, gravity);
            else
                this.simulateAnalytic(dt, gravity);
        }
        simulatePBD(dt, gravity) 
        {
            var p = this;
            for (var i = 1; i < p.masses.length; i++) {
                p.vel[i].y += dt * scene.gravity;
                p.prevPos[i].x = p.pos[i].x;
                p.prevPos[i].y = p.pos[i].y;
                p.pos[i].x += p.vel[i].x * dt;
                p.pos[i].y += p.vel[i].y * dt;
            }
            for (var i = 1; i < p.masses.length; i++) {
                var dx = p.pos[i].x - p.pos[i-1].x;
                var dy = p.pos[i].y - p.pos[i-1].y;
                var d = Math.sqrt(dx * dx + dy * dy);
                var w0 = p.masses[i - 1] > 0.0 ? 1.0 / p.masses[i - 1] : 0.0;
                var w1 = p.masses[i] > 0.0 ? 1.0 / p.masses[i] : 0.0;
                var corr = (p.lengths[i] - d) / d / (w0 + w1);
                p.pos[i - 1].x -= w0 * corr * dx; 
                p.pos[i - 1].y -= w0 * corr * dy; 
                p.pos[i].x += w1 * corr * dx; 
                p.pos[i].y += w1 * corr * dy; 
            }
            for (var i = 1; i < p.masses.length; i++) {
                p.vel[i].x = (p.pos[i].x - p.prevPos[i].x) / dt;
                p.vel[i].y = (p.pos[i].y - p.prevPos[i].y) / dt;
            }
        }
        simulateAnalytic(dt, gravity) 
        {
			var g = -gravity;
			var m1 = this.masses[1];
			var m2 = this.masses[2];
			var m3 = this.masses[3];
			var l1 = this.lengths[1];
			var l2 = this.lengths[2];
			var l3 = this.lengths[3];
			var t1 = this.theta[1];
			var t2 = this.theta[2];
			var t3 = this.theta[3];
			var w1 = this.omega[1];
			var w2 = this.omega[2];
			var w3 = this.omega[3];

			var b1 = 
				g*l1*m1*Math.sin(t1) + g*l1*m2*Math.sin(t1)+g*l1*m3*Math.sin(t1) + m2*l1*l2*Math.sin(t1-t2)*w1*w2 + 
				m3*l1*l3*Math.sin(t1-t3)*w1*w3       +   m3*l1*l2*Math.sin(t1-t2)*w1*w2  +  
				m2*l1*l2*Math.sin(t2-t1)*(w1-w2)*w2  +   
				m3*l1*l2*Math.sin(t2-t1)*(w1-w2)*w2  +  
				m3*l1*l3*Math.sin(t3-t1)*(w1-w3)*w3;

			var a11 = l1*l1*(m1+m2+m3);
			var a12 = m2*l1*l2*Math.cos(t1-t2) + m3*l1*l2*Math.cos(t1-t2);
			var a13 = m3*l1*l3*Math.cos(t1-t3);

			var b2 = 
				g*l2*m2*Math.sin(t2) + g*l2*m3*Math.sin(t2) + w1*w2*l1*l2*Math.sin(t2-t1)*(m2 + m3) +
				m3*l2*l3*Math.sin(t2-t3)*w2*w3               +    
				(m2 + m3)*l1*l2*Math.sin(t2-t1)*(w1-w2)*w1   +  
				m3*l2*l3*Math.sin(t3-t2)*(w2-w3)*w3; 

			var a21 = (m2 + m3)*l1*l2*Math.cos(t2-t1);
			var a22 = l2*l2*(m2+m3);
			var a23 = m3*l2*l3*Math.cos(t2-t3);

			var b3 = 
				m3*g*l3*Math.sin(t3) - m3*l2*l3*Math.sin(t2-t3)*w2*w3 - m3*l1*l3*Math.sin(t1-t3)*w1*w3 + 
				m3*l1*l3*Math.sin(t3-t1)*(w1-w3)*w1    + 
				m3*l2*l3*Math.sin(t3-t2)*(w2-w3)*w2;

			var a31 = m3*l1*l3*Math.cos(t1-t3);
			var a32 = m3*l2*l3*Math.cos(t2-t3);
			var a33 = m3*l3*l3;

			b1 = -b1;
			b2 = -b2;
			b3 = -b3;

			var det = a11 * (a22 * a33 - a23 * a32) + a21 * (a32 * a13 - a33 * a12) + a31 * (a12 * a23 - a13 * a22);
			if (det == 0.0)
				return;

			var a1 = b1 * (a22 * a33 - a23 * a32) + b2 * (a32 * a13 - a33 * a12) + b3 * (a12 * a23 - a13 * a22);
			var a2 = b1 * (a23 * a31 - a21 * a33) + b2 * (a33 * a11 - a31 * a13) + b3 * (a13 * a21 - a11 * a23);
			var a3 = b1 * (a21 * a32 - a22 * a31) + b2 * (a31 * a12 - a32 * a11) + b3 * (a11 * a22 - a12 * a21);

			a1 /= det;
			a2 /= det;
			a3 /= det;

			this.omega[1] += a1 * dt;
			this.omega[2] += a2 * dt;
			this.omega[3] += a3 * dt;
			this.theta[1] += this.omega[1] * dt;
			this.theta[2] += this.omega[2] * dt;	
			this.theta[3] += this.omega[3] * dt;	

            var x = 0.0, y = 0.0;
            for (var i = 1; i < this.masses.length; i++) {
                x += this.lengths[i] * Math.sin(this.theta[i]);
                y += this.lengths[i] * -Math.cos(this.theta[i]); 
                this.pos[i].x = x;
                this.pos[i].y = y;
            }
        }
        updateTrail() {
            this.trail[this.trailLast] = cX(this.pos[this.pos.length-1]);
            this.trail[this.trailLast + 1] = cY(this.pos[this.pos.length-1]);
            this.trailLast = (this.trailLast + 2) % this.trail.length;
            if (this.trailLast == this.trailFirst)
                this.trailFirst = (this.trailFirst + 2) % this.trail.length;
        }
        draw() {
            c.strokeStyle = this.color;
            c.lineWidth = 2.0;
            if (this.trailLast != this.trailFirst) {
                var i = this.trailFirst;
                c.beginPath();
                c.moveTo(this.trail[i], this.trail[i + 1]);
                i = (i + 2) % this.trail.length;
                while (i != this.trailLast) {
                    c.lineTo(this.trail[i], this.trail[i + 1]);
                    i = (i + 2) % this.trail.length;
                }
                c.stroke();
            }

            var p = this;
            c.strokeStyle = "#303030";
            c.lineWidth = 10;
            c.beginPath();
            c.moveTo(cX(p.pos[0]), cY(p.pos[0]));
            for (var i = 1; i < p.masses.length; i++) 
                c.lineTo(cX(p.pos[i]), cY(p.pos[i]));
            c.stroke();
            c.lineWidth = 1;            

            c.fillStyle = this.color;
            for (var i = 1; i < p.masses.length; i++) {
                var r = 0.03 * Math.sqrt(p.masses[i]);
                c.beginPath();			
                c.arc(
                    cX(p.pos[i]), cY(p.pos[i]), cScale * r, 0.0, 2.0 * Math.PI); 
                c.closePath();
                c.fill();
            }
        }
    }

    var scene = {
        gravity : -10.0,
        dt : 0.01,
        numSubSteps : 10000,
        paused : true,
        pendulumPBD : null,
        pendulumAnalytic : null
    };

    var sceneNr = 0;

    function setupScene() {
        var angles = [0.5 * Math.PI, Math.PI, Math.PI, Math.PI, Math.PI];
        var lengths = [];
        var masses = [];

        switch(sceneNr % 6) {
            case 0 : {
                lengths = [0.15, 0.15, 0.15];
                masses = [1.0, 1.0, 1.0];
                break;
            }
            case 1 : {
                lengths = [0.06, 0.15, 0.2];
                masses = [1.0, 0.5, 0.1];
                break;
            }
            case 2 : {
                lengths = [0.15, 0.15, 0.15];
                masses = [1.0, 0.01, 1.0];
                break;
            }
            case 3 : {
                lengths = [0.15, 0.15, 0.15];
                masses = [0.01, 1.0, 0.01];
                break;
            }
            case 4 : {
                lengths = [0.2, 0.133, 0.04];
                masses = [0.3, 0.3, 0.3];
                break;
            }
            case 5 : {
                lengths = [0.1, 0.12, 0.1, 0.15, 0.05];
                masses = [0.2, 0.6, 0.4, 0.3, 0.2];
                break;
            }
        }

        scene.pendulumAnalytic = null;

        scene.pendulumPBD = new Pendulum(true, "#FF3030", masses, lengths, angles);
        if (masses.length <= 3)
            scene.pendulumAnalytic = new Pendulum(false, "#00FF00", masses, lengths, angles);
        scene.paused = true;

        sceneNr++;
    }

    function draw() {
        c.fillStyle = "#000000";
        c.fillRect(0, 0, canvas.width, canvas.height);
        if (scene.pendulumPBD)
            scene.pendulumPBD.draw();
        if (scene.numSubSteps >= 100) {
            if (scene.pendulumAnalytic)
                scene.pendulumAnalytic.draw();
        }
    }

    function simulate() {
        if (scene.paused)
            return;
        var sdt = scene.dt / scene.numSubSteps;
        var trailGap = scene.numSubSteps / 10;

        for (var step = 0; step < scene.numSubSteps; step++) {
            if (scene.pendulumPBD) {
                scene.pendulumPBD.simulate(sdt, scene.gravity);
                if (step % trailGap == 0)
                    scene.pendulumPBD.updateTrail();
            }
            if (scene.pendulumAnalytic) {
                scene.pendulumAnalytic.simulate(sdt, scene.gravity);
                if (step % trailGap == 0)
                    scene.pendulumAnalytic.updateTrail();
            }
        }
    }
    
	document.getElementById("stepsSlider").oninput = function() {
		var steps = [1, 5, 10, 100, 1000, 10000];
		scene.numSubSteps = steps[Number(this.value)];
		document.getElementById("steps").innerHTML = scene.numSubSteps.toString();
	}

    document.addEventListener("keydown", event => {
        if (event.isComposing || event.keyCode === 229) 
            return;
        if (event.key == 's')
            step();
        });    

	function run() {
		scene.paused = false;
	}

	function step() {
		scene.paused = false;
		simulate();
		scene.paused = true;
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
