# Chapter 16 — Simulation on the GPU

**Video:** https://youtu.be/q4rNoupGr8U
**Slides:** https://matthias-research.github.io/pages/tenMinutePhysics/16-GPUSimulation.pdf
**Code:** https://raw.githubusercontent.com/matthias-research/pages/master/tenMinutePhysics/16-GPUCloth.py

## Video Transcript

hi not just from 10 minute physics here welcome to tutorial number 16. today i will show you how to run simulations on the gpu and as we will see writing codes for the gpu is easy and fun and you will get huge speed ups so let's start as usual for the slides and demos have a look at my web page at www.matiasmiller.info 10-minute physics here's a teaser simulation this piece of cloth contains 250 000 particles 500 000 triangles and 1.5 million distance constraints the simulation runs at about 30 frames per second with 30 sub steps this means that the gpu solves 1.35 billion distance constraints per second i will put the code for this demo on my page it's a python script at the end of the tutorial i will explain how to run it now let me give you some background on how to simulate on the gpu gpus are perfect for simulations they are designed to apply a single program to multiple objects in graphics a rendering program also called a shader is applied to calculate the color of each pixel on the screen for simulations we run a single program also called a kernel for many particles or for many constraints let us have a look at a very simple example the velocity update of position-based dynamics i discussed this in tutorial number nine at each simulation step we run through all the particles we update the velocities store the positions in the previous positions and update the positions by adding delta t times the velocity next we solve all the constraints individually finally we update the velocities as the positions after the solve minus the positions before the solve divided by delta t it is the for all statements that lends themselves to be parallelized now how can we put the velocity update on the gpu from a hardware point of view we have the motherboard with the cpu also called the host and the graphics card with the gpu also called the device the gpu contains a large number of individual compute units or cores the rtx 3090 for instance has over 10 thousand of them a threat is the execution of the kernel on one core each thread has a unique id there can be more threats than cores in that case each core executes more than one thread sequentially the graphics card has its own memory therefore we have to store the velocities the previous positions and the positions on the graphics card we use the thread id as the particle number such that each thread computes the velocity for exactly one particle we don't need all the buffers in the main memory as well for rendering for instance we only need the positions of the particles in this case we use a dma to copy the positions from the gpu to the cpu memory how can we implement this one way is to use the cuda library and write c plus plus programs now there is a much easier way you can write gpu simulations with python and our new python extension called warp you can create standalone projects or a plugin for nvidia omniverse omniverse offers all you need in terms of visualization and interaction i will talk about omniverse plugins in an upcoming tutorial have a look at nvidia's developer site for the warp documentation warp is also available on github now let's see how we can implement the pbd velocity update with warp first we include the warp library then we define the buffers we need the position previous position and velocity buffers on the gpu we also allocate the position buffer on the cpu next we write the kernel as a python function and declare it to be a warp kernel the kernel takes as input at the buffer's previous position position and velocity we interpret the thread id at the particle number next we simply implement the position based dynamics velocity update that's it there's a special warp function to launch the kernel first we specify the name of the kernel then the inputs the number of threads and finally whether it should be executed on the gpu or on the cpu after the execution we read back the particle positions there are two main challenges when writing gpu code the first one are threads that write to the same locations in per-particle loops each thread writes to a separate entry in the array however in the case where we execute one thread per constraint multiple threads typically write to the same location in an array in this example here we have four particles and five distance constraints here threads two three and five all update the position of particle 2. the problem that arises here is that if one thread starts adding its computed correction before the addition operation of other threads is finished the previous addition is lost the solution to this problem is simple we can use the work command atomic add which makes sure that threats have to wait with executing their add until other threats writing to the same location are done this can slow down execution slightly the second problem are simultaneous reads and adds we take the same setup as an example the xbbd position corrections computed by thread number 3 depend on the locations of particles 2 and 3. therefore we get a different result before or after threads 2 and 5 have added their corrections since threads are not executed in a predefined order the result is non-deterministic which can yield there are two popular solutions here the first is to use a jacobi solver and the second is to use graph coloring the cpu solver of xpbt runs through all the constraints and immediately adds corrections to the particles this algorithm is also called gauss-seidel for jacobi solve we use an additional buffer which stores corrections for each particle here called d at the beginning of the solve we set all entries to zero then in the constraint solve kernels we do not apply corrections to the particles but sum them up in the correction buffer we do this using atomic operations only after the solve we apply these corrections to the particles the advantage of this method is that particle positions are not changed during the solve therefore all threads work with the same particle positions the method is also quite easy to implement the disadvantages are jacobi converges more slowly than gauss-seidel due to the slower error propagation also we get possible overshootings this is why we scale the corrections by a scalar s smaller than one one idea is to simply average all corrections this does not work very well unfortunately because momentum conservation is violated also the strength of a constraint depends on the number of adjacent constraints which yields artifacts so what we typically do is to use a global magic value of s typically about one-fourth it has to be adjusted to the current simulation setup the second method is to use graph coloring here the idea is to use multiple constraint solved passes each pass process is a subset of independent constraints this method is stable and we don't have to choose a magic s let's take as an example a regular cloth mesh without shear resistance in this case we can split the constraints into four subsets blue yellow green and red in each pass a particle position is only touched by at most one constraint this case is easy but what about the general case now we are faced with a mathematical problem given a graph color all the edges with as few colors as possible such that no pair of edges with the same color touches the same note finding the optimal solution is np hard this means that it is very likely that there is no better way to do this than to test all the possible colorings of course this is not feasible because the number of colorings increases exponentially with number of constraints fortunately there is a quite simple algorithm the greedy algorithm it does not find the optimal solution but typically a good one it is also more general and can handle constraints with more than two adjacent particles it works as follows while there exists unmarked constraints create a new set clear all the particle marks then for all unmarked constraints c if no adjacent particle is marked add c to s mark c and mark all the adjacent particles even with the best solution many passes are typically required we need at least as many passes as the largest number of constraints touching one particle here is a typical set size distribution we have a few large sets in the beginning followed by a long tail of smaller ones a simple way to reduce the number of passes is to solve the entire tail with one jacobi iteration for cloth for instance it makes sense to only solve the stretching constraints with coloring handling the bending and the shear constraints with jacobi is fine because they don't need to be as stiff now let's have a look at the demo in order to be able to use warp you need to set up a python environment once there's a nice website that explains how to install python and connect it with visual studio code after this we are able to step through python code inside visual studio code warp has a strong connection with numpy installing numpy is super easy just type pip install numpy in the console the same is true for warp simply type pip install warp lang my demo uses pi opengl people on the internet suggest to visit this page it has links to a lot of python libraries stored as wheel files download pi opengl accelerate and pi open shell from there make sure you pick the right versions once downloaded you can install the files using the pip install command as mentioned before you can download my demo at my 10 minute physics web page i will put all these links in the description below i will also update them in case things change in the future let me finally give you a very short overview of the code at the start i have a documentation of how to interact with the demo then we have some general settings like the dimension of the cloth now follows the cloth object in the init method i set up the cloth and all the constraints here you see the integration kernel that integrates the particles and handles the simple collisions this is the kernel that solves distance constraints then we have to add corrections kernel that is only used in the jacobi case here then is the update velocity kernel that i showed in the slides in the simulation method i run n sub steps first i call the integration kernel then dependent on the type of the solver i only do jacobi solves or i go through multiple passes and check whether a path is independent or not if the path contains independent constraints i just solve them on the particle positions otherwise i solve them jacobi style finally i launch the update velocity kernel and copy the positions on the graphics card back to the host then i define a raycast kernel to support dragging of the cloth this is the method that renders the cloth using opengl from the middle of the code down you see the implementation of the viewer it has a camera controller finally it handles all the glute callbacks and sets up opengl at the very end it calls the glute main loop this concludes the tutorial thanks for watching i hope you enjoyed it and i see you in the next tutorial

## Source Code

### 16-GPUCloth.py

```python
# The MIT License (MIT)
# Copyright (c) 2022 NVIDIA
# www.youtube.com/c/TenMinutePhysics
# www.matthiasMueller.info/tenMinutePhysics

# Permission is hereby granted, free of charge, to any person obtaining a copy of
# this software and associated documentation files (the "Software"), to deal in
# the Software without restriction, including without limitation the rights to
# use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
# the Software, and to permit persons to whom the Software is furnished to do so,
# subject to the following conditions:
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
# FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
# COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
# IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
# CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

# control:

# 'p': toggle paused
# 'h': toggle hidden
# 'c': solve type coloring hybrid
# 'j': solve type Jacobi
# 'r': reset state
# 'w' 's' 'a' 'd' 'e' 'q' : camera control
# left mouse view
# middle mouse pan
# right mouse orbit
# shift mouse interact

from OpenGL.GL import *
from OpenGL.GLU import *
from OpenGL.GLUT import *
import numpy as np
import warp as wp
import math
import time

wp.init()

# ---------------------------------------------

targetFps = 60
numSubsteps = 30
timeStep = 1.0 / 60.0
gravity = wp.vec3(0.0, -10.0, 0.0)
paused = False
hidden = False
frameNr = 0

# 0 Coloring
# 1 Jacobi
solveType = 0
jacobiScale = 0.2

clothNumX = 500
clothNumY = 500
clothY = 2.2
clothSpacing = 0.01
sphereCenter = wp.vec3(0.0, 1.5, 0.0)
sphereRadius = 0.5

# ---------------------------------------------

class Cloth:

    @wp.kernel
    def computeRestLengths(
            pos: wp.array(dtype = wp.vec3),
            constIds: wp.array(dtype = wp.int32),
            restLengths: wp.array(dtype = float)):
        cNr = wp.tid()
        p0 = pos[constIds[2 * cNr]]
        p1 = pos[constIds[2 * cNr + 1]]
        restLengths[cNr] = wp.length(p1 - p0)

    # -----------------------------------------------------
    def __init__(self, yOffset, numX, numY, spacing, sphereCenter, sphereRadius):
        device = "cpu"

        self.dragParticleNr = -1
        self.dragDepth = 0.0
        self.dragInvMass = 0.0
        self.renderParticles = []
        
        self.sphereCenter = sphereCenter
        self.sphereRadius = sphereRadius

        if numX % 2 == 1:
            numX = numX + 1
        if numY % 2 == 1:
            numY = numY + 1

        self.spacing = spacing
        self.numParticles = (numX + 1) * (numY + 1)
        pos = np.zeros(3 * self.numParticles)
        normals = np.zeros(3 * self.numParticles)
        invMass = np.zeros(self.numParticles)

        for xi in range(numX + 1):
            for yi in range(numY + 1):
                id = xi * (numY + 1) + yi
                pos[3 * id] = (-numX * 0.5 + xi) * spacing
                pos[3 * id + 1] = yOffset
                pos[3 * id + 2] = (-numY * 0.5 + yi) * spacing
                invMass[id] = 1.0
                # if yi == numY and (xi == 0 or xi == numX):
                #     invMass[id] = 0.0
                #     self.renderParticles.append(id)

        self.pos = wp.array(pos, dtype = wp.vec3, device = "cuda")
        self.prevPos = wp.array(pos, dtype = wp.vec3, device = "cuda")
        self.restPos = wp.array(pos, dtype = wp.vec3, device = "cuda")
        self.invMass = wp.array(invMass, dtype = float, device = "cuda")
        self.corr = wp.array(np.zeros(3 * self.numParticles), dtype = wp.vec3, device = "cuda")
        self.vel = wp.array(np.zeros(3 * self.numParticles), dtype = wp.vec3, device = "cuda")
        self.normals = wp.array(normals, dtype = wp.vec3, device = "cuda")

        self.hostInvMass = wp.array(invMass, dtype = float, device = "cpu")
        self.hostPos = wp.array(pos, dtype = wp.vec3, device = "cpu")
        self.hostNormals = wp.array(normals, dtype = wp.vec3, device = "cpu")

        # constraints

        self.passSizes = [
            (numX + 1) * math.floor(numY / 2),
            (numX + 1) * math.floor(numY / 2),
            math.floor(numX / 2) * (numY + 1),
            math.floor(numX / 2) * (numY + 1),
            2 * numX * numY + (numX + 1) * (numY - 1) + (numY + 1) * (numX - 1)
            ]
        self.passIndependent = [
            True, True, True, True, False
        ]

        self.numDistConstraints = 0
        for passSize in self.passSizes:            
            self.numDistConstraints = self.numDistConstraints + passSize

        distConstIds = np.zeros(2 * self.numDistConstraints, dtype = wp.int32)

        # stretch constraints

        i = 0
        for passNr in range(2):
            for xi in range(numX + 1):
                for yi in range(math.floor(numY / 2)):
                    distConstIds[2 * i] = xi * (numY + 1) + 2 * yi + passNr
                    distConstIds[2 * i + 1] = xi * (numY + 1) + 2 * yi + passNr + 1
                    i = i + 1

        for passNr in range(2):
            for xi in range(math.floor(numX / 2)):
                for yi in range(numY + 1):
                    distConstIds[2 * i] = (2 * xi + passNr) * (numY + 1) + yi
                    distConstIds[2 * i + 1] = (2 * xi + passNr + 1) * (numY + 1) + yi
                    i = i + 1

        # shear constraints

        for xi in range(numX):
            for yi in range(numY):
                distConstIds[2 * i] = xi * (numY + 1) + yi
                distConstIds[2 * i + 1] = (xi + 1) * (numY + 1) + yi + 1
                i = i + 1
                distConstIds[2 * i] = (xi + 1) * (numY + 1) + yi
                distConstIds[2 * i + 1] = xi * (numY + 1) + yi + 1
                i = i + 1

        # bending constraints

        for xi in range(numX + 1):
            for yi in range(numY - 1):
                distConstIds[2 * i] = xi * (numY + 1) + yi
                distConstIds[2 * i + 1] = xi * (numY + 1) + yi + 2
                i = i + 1

        for xi in range(numX - 1):
            for yi in range(numY + 1):
                distConstIds[2 * i] = xi * (numY + 1) + yi
                distConstIds[2 * i + 1] = (xi + 2) * (numY + 1) + yi                
                i = i + 1

        self.distConstIds = wp.array(distConstIds, dtype = wp.int32, device = "cuda")
        self.constRestLengths = wp.zeros(self.numDistConstraints, dtype = float, device = "cuda")

        wp.launch(kernel = self.computeRestLengths,
                inputs = [self.pos, self.distConstIds, self.constRestLengths], 
                dim = self.numDistConstraints,  device = "cuda")

        # tri ids

        self.numTris = 2 * numX * numY
        self.hostTriIds = np.zeros(3 * self.numTris, dtype = np.int32)

        i = 0
        for xi in range(numX):
            for yi in range(numY):
                id0 = xi * (numY + 1) + yi
                id1 = (xi + 1) * (numY + 1) + yi
                id2 = (xi + 1) * (numY + 1) + yi + 1
                id3 = xi * (numY + 1) + yi + 1

                self.hostTriIds[i] = id0
                self.hostTriIds[i + 1] = id1
                self.hostTriIds[i + 2] = id2

                self.hostTriIds[i + 3] = id0
                self.hostTriIds[i + 4] = id2
                self.hostTriIds[i + 5] = id3

                i = i + 6

        self.triIds = wp.array(self.hostTriIds, dtype = wp.int32, device = "cuda")

        self.triDist = wp.zeros(self.numTris, dtype = float, device = "cuda")
        self.hostTriDist = wp.zeros(self.numTris, dtype = float, device = "cpu")

        print(str(self.numTris) + " triangles created")
        print(str(self.numDistConstraints) + " distance constraints created")
        print(str(self.numParticles) + " particles created")


    # ----------------------------------
    @wp.kernel
    def addNormals(
            pos: wp.array(dtype = wp.vec3),
            triIds: wp.array(dtype = wp.int32),
            normals: wp.array(dtype = wp.vec3)):
        triNr = wp.tid()

        id0 = triIds[3 * triNr]
        id1 = triIds[3 * triNr + 1]
        id2 = triIds[3 * triNr + 2]
        normal = wp.cross(pos[id1] - pos[id0], pos[id2] - pos[id0])
        wp.atomic_add(normals, id0, normal)
        wp.atomic_add(normals, id1, normal)
        wp.atomic_add(normals, id2, normal)

    @wp.kernel
    def normalizeNormals(
            normals: wp.array(dtype = wp.vec3)):

        pNr = wp.tid()
        normals[pNr] = wp.normalize(normals[pNr])

    def updateMesh(self):
        self.normals.zero_()
        wp.launch(kernel = self.addNormals, inputs = [self.pos, self.triIds, self.normals], dim = self.numTris, device = "cuda")
        wp.launch(kernel = self.normalizeNormals, inputs = [self.normals], dim = self.numParticles, device = "cuda")
        wp.copy(self.hostNormals, self.normals)

    # ----------------------------------

    @wp.kernel
    def integrate(
            dt: float,
            gravity: wp.vec3,
            invMass: wp.array(dtype = float),
            prevPos: wp.array(dtype = wp.vec3),
            pos: wp.array(dtype = wp.vec3),
            vel: wp.array(dtype = wp.vec3),
            sphereCenter: wp.vec3,
            sphereRadius: float):

        pNr = wp.tid()

        prevPos[pNr] = pos[pNr]
        if invMass[pNr] == 0.0:
            return
        vel[pNr] = vel[pNr] + gravity * dt
        pos[pNr] = pos[pNr] + vel[pNr] * dt
        
        # collisions
        
        thickness = 0.001
        friction = 0.01

        d = wp.length(pos[pNr] - sphereCenter)
        if d < (sphereRadius + thickness):
            p = pos[pNr] * (1.0 - friction) + prevPos[pNr] * friction
            r = p - sphereCenter
            d = wp.length(r)            
            pos[pNr] = sphereCenter + r * ((sphereRadius + thickness) / d)
            
        p = pos[pNr]
        if p[1] < thickness:
            p = pos[pNr] * (1.0 - friction) + prevPos[pNr] * friction
            pos[pNr] = wp.vec3(p[0], thickness, p[2])

    # ----------------------------------
    @wp.kernel
    def solveDistanceConstraints(
            solveType: wp.int32,
            firstConstraint: wp.int32,
            invMass: wp.array(dtype = float),
            pos: wp.array(dtype = wp.vec3),
            corr: wp.array(dtype = wp.vec3),
            constIds: wp.array(dtype = wp.int32),
            restLengths: wp.array(dtype = float)):

        cNr = firstConstraint + wp.tid()
        id0 = constIds[2 * cNr]
        id1 = constIds[2 * cNr + 1]
        w0 = invMass[id0]
        w1 = invMass[id1]
        w = w0 + w1
        if w == 0.0:
            return
        p0 = pos[id0]
        p1 = pos[id1]
        d = p1 - p0
        n = wp.normalize(d)
        l = wp.length(d)
        l0 = restLengths[cNr]
        dP = n * (l - l0) / w
        if solveType == 1:
            wp.atomic_add(corr, id0, w0 * dP)
            wp.atomic_sub(corr, id1, w1 * dP)
        else:
            wp.atomic_add(pos, id0, w0 * dP)
            wp.atomic_sub(pos, id1, w1 * dP)

    # ----------------------------------
    @wp.kernel
    def addCorrections(
            pos: wp.array(dtype = wp.vec3),
            corr: wp.array(dtype = wp.vec3),
            scale: float):
        pNr = wp.tid()
        pos[pNr] = pos[pNr] + corr[pNr] * scale

    # ----------------------------------
    @wp.kernel
    def updateVel(
            dt: float,
            prevPos: wp.array(dtype = wp.vec3),
            pos: wp.array(dtype = wp.vec3),
            vel: wp.array(dtype = wp.vec3)):
        pNr = wp.tid()
        vel[pNr] = (pos[pNr] - prevPos[pNr]) / dt

    # ----------------------------------
    def simulate(self):

        # ----------------------------------
        dt = timeStep / numSubsteps
        numPasses = len(self.passSizes)

        for step in range(numSubsteps):  
            wp.launch(kernel = self.integrate, 
                inputs = [dt, gravity, self.invMass, self.prevPos, self.pos, self.vel, self.sphereCenter, self.sphereRadius], 
                dim = self.numParticles, device = "cuda")

            if solveType == 0:
                firstConstraint = 0
                for passNr in range(numPasses):
                    numConstraints = self.passSizes[passNr]

                    if self.passIndependent[passNr]:
                        wp.launch(kernel = self.solveDistanceConstraints,
                            inputs = [0, firstConstraint, self.invMass, self.pos, self.corr, self.distConstIds, self.constRestLengths], 
                            dim = numConstraints,  device = "cuda")
                    else:
                        self.corr.zero_()
                        wp.launch(kernel = self.solveDistanceConstraints,
                            inputs = [1, firstConstraint, self.invMass, self.pos, self.corr, self.distConstIds, self.constRestLengths], 
                            dim = numConstraints,  device = "cuda")
                        wp.launch(kernel = self.addCorrections,
                            inputs = [self.pos, self.corr, jacobiScale], 
                            dim = self.numParticles,  device = "cuda")
                    
                    firstConstraint = firstConstraint + numConstraints

            elif solveType == 1:
                self.corr.zero_()
                wp.launch(kernel = self.solveDistanceConstraints, 
                    inputs = [1, 0, self.invMass, self.pos, self.corr, self.distConstIds, self.constRestLengths], 
                    dim = self.numDistConstraints,  device = "cuda")
                wp.launch(kernel = self.addCorrections,
                    inputs = [self.pos, self.corr, jacobiScale], 
                    dim = self.numParticles,  device = "cuda")

            wp.launch(kernel = self.updateVel, 
                inputs = [dt, self.prevPos, self.pos, self.vel], dim = self.numParticles, device = "cuda")
            
        wp.copy(self.hostPos, self.pos)

    # -------------------------------------------------
    def reset(self):
        self.vel.zero_()
        wp.copy(self.pos, self.restPos)

    # -------------------------------------------------
    @wp.kernel
    def raycastTriangle(
            orig: wp.vec3,
            dir: wp.vec3,
            pos: wp.array(dtype = wp.vec3),
            triIds: wp.array(dtype = wp.int32),
            dist: wp.array(dtype = float)):
        triNr = wp.tid()
        noHit = 1.0e6

        id0 = triIds[3 * triNr]
        id1 = triIds[3 * triNr + 1]
        id2 = triIds[3 * triNr + 2]              
        pNr = wp.tid()

        edge1 = pos[id1] - pos[id0]
        edge2 = pos[id2] - pos[id0]
        pvec = wp.cross(dir, edge2)
        det = wp.dot(edge1, pvec)

        if (det == 0.0):
            dist[triNr] = noHit
            return

        inv_det = 1.0 / det
        tvec = orig - pos[id0]
        u = wp.dot(tvec, pvec) * inv_det
        if u < 0.0 or u > 1.0:
            dist[triNr] = noHit
            return 

        qvec = wp.cross(tvec, edge1)
        v = wp.dot(dir, qvec) * inv_det
        if v < 0.0 or u + v > 1.0:
            dist[triNr] = noHit
            return

        dist[triNr] = wp.dot(edge2, qvec) * inv_det

    # ------------------------------------------------
    def startDrag(self, orig, dir):
        
        wp.launch(kernel = self.raycastTriangle, inputs = [
            wp.vec3(orig[0], orig[1], orig[2]), wp.vec3(dir[0], dir[1], dir[2]), 
            self.pos, self.triIds, self.triDist], dim = self.numTris, device = "cuda")
        wp.copy(self.hostTriDist, self.triDist)

        pos = self.hostPos.numpy()
        self.dragDepth = 0.0

        dists = self.hostTriDist.numpy()
        minTriNr = np.argmin(dists)
        if dists[minTriNr] < 1.0e6:
            self.dragParticleNr = self.hostTriIds[3 * minTriNr]
            self.dragDepth = dists[minTriNr]
            invMass = self.hostInvMass.numpy()
            self.dragInvMass = invMass[self.dragParticleNr]
            invMass[self.dragParticleNr] = 0.0
            wp.copy(self.invMass, self.hostInvMass)

            pos = self.hostPos.numpy()
            dragPos = wp.vec3(
                orig[0] + self.dragDepth * dir[0], 
                orig[1] + self.dragDepth * dir[1], 
                orig[2] + self.dragDepth * dir[2])
            pos[self.dragParticleNr] = dragPos

            wp.copy(self.pos, self.hostPos)
        
    def drag(self, orig, dir):
        if self.dragParticleNr >= 0:
            pos = self.hostPos.numpy()
            dragPos = wp.vec3(
                orig[0] + self.dragDepth * dir[0], 
                orig[1] + self.dragDepth * dir[1], 
                orig[2] + self.dragDepth * dir[2])
            pos[self.dragParticleNr] = dragPos
            wp.copy(self.pos, self.hostPos)

    def endDrag(self):
        if self.dragParticleNr >= 0:
            invMass = self.hostInvMass.numpy()
            invMass[self.dragParticleNr] = self.dragInvMass
            wp.copy(self.invMass, self.hostInvMass)
            self.dragParticleNr = -1

    def render(self):

        # cloth

        twoColors = False

        glColor3f(1.0, 0.0, 0.0)
        glNormal3f(0.0, 0.0, -1.0)

        glEnableClientState(GL_VERTEX_ARRAY)
        glEnableClientState(GL_NORMAL_ARRAY)

        glVertexPointer(3, GL_FLOAT, 0, self.hostPos.numpy())
        glNormalPointer(GL_FLOAT, 0, self.hostNormals.numpy())

        glPolygonMode(GL_FRONT_AND_BACK, GL_LINE)
  
        if twoColors:
            glCullFace(GL_FRONT)
            glColor3f(1.0, 1.0, 0.0)
            glDrawElementsui(GL_TRIANGLES, self.hostTriIds)
            glCullFace(GL_BACK)
            glColor3f(1.0, 0.0, 0.0)
            glDrawElementsui(GL_TRIANGLES, self.hostTriIds)
        else:
            glDisable(GL_CULL_FACE)
            glColor3f(1.0, 0.0, 0.0)
            glDrawElementsui(GL_TRIANGLES, self.hostTriIds)
            glEnable(GL_CULL_FACE)

        glPolygonMode(GL_FRONT_AND_BACK, GL_FILL)

        glDisableClientState(GL_VERTEX_ARRAY)
        glDisableClientState(GL_NORMAL_ARRAY)

        # kinematic particles

        glColor3f(1.0, 1.0, 1.0)
        pos = self.hostPos.numpy()

        q = gluNewQuadric()

        if self.dragParticleNr >= 0:
            self.renderParticles.append(self.dragParticleNr)

        for id in self.renderParticles:
            glPushMatrix()
            p = pos[id]
            glTranslatef(p[0], p[1], p[2])
            gluSphere(q, 0.02, 40, 40)
            glPopMatrix()

        if self.dragParticleNr >= 0:
            self.renderParticles.pop()
            
        # sphere
        glColor3f(0.8, 0.8, 0.8)

        glPushMatrix()
        glTranslatef(self.sphereCenter[0], self.sphereCenter[1], self.sphereCenter[2])
        gluSphere(q, self.sphereRadius, 40, 40)
        glPopMatrix()

        gluDeleteQuadric(q)



# --------------------------------------------------------------------
# Demo Viewer
# --------------------------------------------------------------------

groundVerts = []
groundIds = []
groundColors = []
cloth = []

# -------------------------------------------------------
def initScene():
    global cloth
  
    cloth = Cloth(clothY, clothNumX, clothNumY, clothSpacing, sphereCenter, sphereRadius)

# --------------------------------
def showScreen():
    glClearColor(0.0, 0.0, 0.0, 1.0)
    glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT)

    # ground plane

    glColor3f(1.0, 1.0, 1.0)
    glNormal3f(0.0, 1.0, 0.0)

    numVerts = math.floor(len(groundVerts) / 3)

    glVertexPointer(3, GL_FLOAT, 0, groundVerts)
    glColorPointer(3, GL_FLOAT, 0, groundColors)

    glEnableClientState(GL_VERTEX_ARRAY)
    glEnableClientState(GL_COLOR_ARRAY)
    glDrawArrays(GL_QUADS, 0, numVerts)
    glDisableClientState(GL_VERTEX_ARRAY)
    glDisableClientState(GL_COLOR_ARRAY)

    # objects

    if not hidden:
        cloth.render()

    glutSwapBuffers()

# -----------------------------------
class Camera:
    def __init__(self):
        self.pos = wp.vec3(0.0, 1.0, 5.0)
        self.forward = wp.vec3(0.0, 0.0, -1.0)
        self.up = wp.vec3(0.0, 1.0, 0.0)
        self.right = wp.cross(self.forward, self.up)
        self.speed = 0.1
        self.keyDown = [False] * 256

    def rot(self, unitAxis, angle, v):
       q = wp.quat_from_axis_angle(unitAxis, angle)
       return wp.quat_rotate(q, v)

    def setView(self):
        viewport = glGetIntegerv(GL_VIEWPORT)
        width = viewport[2] - viewport[0]
        height = viewport[3] - viewport[1]

        glMatrixMode(GL_PROJECTION)
        glLoadIdentity()
        gluPerspective(40.0, float(width) / float(height), 0.01, 1000.0)

        glMatrixMode(GL_MODELVIEW)
        glLoadIdentity()

        gluLookAt( 
            self.pos[0], self.pos[1], self.pos[2], 
            self.pos[0] + self.forward[0], self.pos[1] + self.forward[1], self.pos[2] + self.forward[2], 
            self.up[0], self.up[1], self.up[2])

    def lookAt(self, pos, at):
        self.pos = pos
        self.forward = wp.sub(at, pos)
        self.forward = wp.normalize(self.forward)
        self.up = wp.vec3(0.0, 1.0, 0.0)
        self.right = wp.cross(self.forward, self.up)
        self.right = wp.normalize(self.right)
        self.up = wp.cross(self.right, self.forward)

    def handleMouseTranslate(self, dx, dy):
        
        scale = wp.length(self.pos) * 0.001
        self.pos = wp.sub(self.pos, wp.mul(self.right, scale * float(dx)))
        self.pos = wp.add(self.pos, wp.mul(self.up, scale * float(dy)))

    def handleWheel(self, direction):
        self.pos = wp.add(self.pos, wp.mul(self.forward, direction * self.speed))

    def handleMouseView(self, dx, dy):
        scale = 0.005
        self.forward = self.rot(self.up, -dx * scale, self.forward)
        self.forward = self.rot(self.right, -dy * scale, self.forward)
        self.forward = wp.normalize(self.forward)
        self.right = wp.cross(self.forward, self.up)
        self.right = wp.vec3(self.right[0], 0.0, self.right[2])
        self.right = wp.normalize(self.right)
        self.up = wp.cross(self.right, self.forward)
        self.up = wp.normalize(self.up)
        self.forward = wp.cross(self.up, self.right)
    
    def handleKeyDown(self, key):
        self.keyDown[ord(key)] = True

    def handleKeyUp(self, key):
        self.keyDown[ord(key)] = False

    def handleKeys(self):
        if self.keyDown[ord('+')]:
            self.speed = self.speed * 1.2
        if self.keyDown[ord('-')]:
            self.speed = self.speed * 0.8
        if self.keyDown[ord('w')]:
            self.pos = wp.add(self.pos, wp.mul(self.forward, self.speed))
        if self.keyDown[ord('s')]:
            self.pos = wp.sub(self.pos, wp.mul(self.forward, self.speed))
        if self.keyDown[ord('a')]:
            self.pos = wp.sub(self.pos, wp.mul(self.right, self.speed))
        if self.keyDown[ord('d')]:
            self.pos = wp.add(self.pos, wp.mul(self.right, self.speed))
        if self.keyDown[ord('e')]:
            self.pos = wp.sub(self.pos, wp.mul(self.up, self.speed))
        if self.keyDown[ord('q')]:
            self.pos = wp.add(self.pos, wp.mul(self.up, self.speed))

    def handleMouseOrbit(self, dx, dy, center):

        offset = wp.sub(self.pos, center)
        offset = [
            wp.dot(self.right, offset),
            wp.dot(self.forward, offset),
            wp.dot(self.up, offset)]

        scale = 0.01
        self.forward = self.rot(self.up, -dx * scale, self.forward)
        self.forward = self.rot(self.right, -dy * scale, self.forward)
        self.up = self.rot(self.up, -dx * scale, self.up)
        self.up = self.rot(self.right, -dy * scale, self.up)

        self.right = wp.cross(self.forward, self.up)
        self.right = wp.vec3(self.right[0], 0.0, self.right[2])
        self.right = wp.normalize(self.right)
        self.up = wp.cross(self.right, self.forward)
        self.up = wp.normalize(self.up)
        self.forward = wp.cross(self.up, self.right)
        self.pos = wp.add(center, wp.mul(self.right, offset[0]))
        self.pos = wp.add(self.pos, wp.mul(self.forward, offset[1]))
        self.pos = wp.add(self.pos, wp.mul(self.up, offset[2]))

camera = Camera()

# ---- callbacks ----------------------------------------------------

mouseButton = 0
mouseX = 0
mouseY = 0
shiftDown = False

def getMouseRay(x, y):
    viewport = glGetIntegerv(GL_VIEWPORT)
    modelMatrix = glGetDoublev(GL_MODELVIEW_MATRIX)
    projMatrix = glGetDoublev(GL_PROJECTION_MATRIX)

    y = viewport[3] - y - 1
    p0 = gluUnProject(x, y, 0.0, modelMatrix, projMatrix, viewport)
    p1 = gluUnProject(x, y, 1.0, modelMatrix, projMatrix, viewport)
    orig = wp.vec3(p0[0], p0[1], p0[2])
    dir = wp.sub(wp.vec3(p1[0], p1[1], p1[2]), orig)
    dir = wp.normalize(dir)
    return [orig, dir]

def mouseButtonCallback(button, state, x, y):
    global mouseX
    global mouseY
    global mouseButton
    global shiftDown
    global paused
    mouseX = x
    mouseY = y
    if state == GLUT_DOWN:
        mouseButton = button
    else:
        mouseButton = 0
    shiftDown = glutGetModifiers() & GLUT_ACTIVE_SHIFT
    if shiftDown:
        ray = getMouseRay(x, y)
        if state == GLUT_DOWN:
            cloth.startDrag(ray[0], ray[1])
            paused = False
    if state == GLUT_UP:
        cloth.endDrag()

def mouseMotionCallback(x, y):
    global mouseX
    global mouseY
    global mouseButton
    
    dx = x - mouseX
    dy = y - mouseY
    if shiftDown:
        ray = getMouseRay(x, y)
        cloth.drag(ray[0], ray[1])
    else:
        if mouseButton == GLUT_MIDDLE_BUTTON:
            camera.handleMouseTranslate(dx, dy)
        elif mouseButton == GLUT_LEFT_BUTTON:
            camera.handleMouseView(dx, dy)
        elif mouseButton == GLUT_RIGHT_BUTTON:
            camera.handleMouseOrbit(dx, dy, wp.vec3(0.0, 1.0, 0.0))

    mouseX = x
    mouseY = y        

def mouseWheelCallback(wheel, direction, x, y):
    camera.handleWheel(direction)

def handleKeyDown(key, x, y):
    camera.handleKeyDown(key)
    global paused
    global solveType
    global hidden
    if key == b'p':
        paused = not paused
    elif key == b'h':
        hidden = not hidden
    elif key == b'c':
        solveType = 0
    elif key == b'j':
        solveType = 1
    elif key == b'r':
        cloth.reset()

def handleKeyUp(key, x, y):
    camera.handleKeyUp(key)
    
def displayCallback():
    i = 0

prevTime = time.time()

def timerCallback(val):
    global prevTime
    global frameNr
    frameNr = frameNr + 1
    numFpsFrames = 30
    currentTime = time.perf_counter()

    if frameNr % numFpsFrames == 0:
        passedTime = currentTime - prevTime
        prevTime = currentTime
        fps = math.floor(numFpsFrames / passedTime)
        glutSetWindowTitle("Parallel cloth simulation " + str(fps) + " fps")

    if not paused:
        cloth.simulate()

    cloth.updateMesh()
    showScreen()
    camera.setView()
    camera.handleKeys()

    elapsed_ms = (time.perf_counter() - currentTime) * 1000
    glutTimerFunc(max(0, math.floor((1000.0 / targetFps) - elapsed_ms)), timerCallback, 0)

# -----------------------------------------------------------

def setupOpenGL():
    glEnable(GL_DEPTH_TEST)
    glEnable(GL_COLOR_MATERIAL)
    glEnable(GL_CULL_FACE)
    glShadeModel(GL_SMOOTH)
    glLightModelf(GL_LIGHT_MODEL_TWO_SIDE, GL_TRUE)
    glLightModelf(GL_LIGHT_MODEL_LOCAL_VIEWER, GL_TRUE)

    glEnable(GL_LIGHTING)
    glEnable(GL_LIGHT0)

    ambientColor = [0.2, 0.2, 0.2, 1.0]
    diffuseColor = [0.8, 0.8 ,0.8, 1.0]
    specularColor = [1.0, 1.0, 1.0, 1.0]

    glLightfv(GL_LIGHT0, GL_AMBIENT, ambientColor)
    glLightfv(GL_LIGHT0, GL_DIFFUSE, diffuseColor)
    glLightfv(GL_LIGHT0, GL_SPECULAR, specularColor)

    glMaterialfv(GL_FRONT_AND_BACK, GL_SPECULAR, specularColor)
    glMaterialf( GL_FRONT_AND_BACK, GL_SHININESS, 50.0)

    lightPosition = [10.0, 10.0 , 10.0, 0.0]
    glLightfv(GL_LIGHT0, GL_POSITION, lightPosition)

    glEnable(GL_NORMALIZE)
    glEnable(GL_POLYGON_OFFSET_FILL)
    glPolygonOffset(1.0, 1.0)

    groundNumTiles = 30
    groundTileSize = 0.5

    global groundVerts
    global groundIds
    global groundColors

    groundVerts = np.zeros(3 * 4 * groundNumTiles * groundNumTiles, dtype = float)
    groundColors = np.zeros(3 * 4 * groundNumTiles * groundNumTiles, dtype = float)

    squareVerts = [[0,0], [0,1], [1,1], [1,0]]
    r = groundNumTiles / 2.0 * groundTileSize

    for xi in range(groundNumTiles):
        for zi in range(groundNumTiles):
            x = (-groundNumTiles / 2.0 + xi) * groundTileSize
            z = (-groundNumTiles / 2.0 + zi) * groundTileSize
            p = xi * groundNumTiles + zi
            for i in range(4):
                q = 4 * p + i
                px = x + squareVerts[i][0] * groundTileSize
                pz = z + squareVerts[i][1] * groundTileSize
                groundVerts[3 * q] = px
                groundVerts[3 * q + 2] = pz
                col = 0.4
                if (xi + zi) % 2 == 1:
                    col = 0.8
                pr = math.sqrt(px * px + pz * pz)
                d = max(0.0, 1.0 - pr / r)
                col = col * d
                for j in range(3):
                    groundColors[3 * q + j] = col

# ------------------------------

glutInit()
initScene()

x = wp.vec3(0.0, 1.0, 2.0)
y = wp.vec3(1.0, -3.0, 0.0)
z = wp.sub(x, y)
print(str(z[0]) + "," + str(z[1]) + "," + str(z[2]))

glutInitDisplayMode(GLUT_RGBA)
glutInitWindowSize(800, 500)
glutInitWindowPosition(10, 10)
wind = glutCreateWindow("Parallel cloth simulation")

setupOpenGL()

glutDisplayFunc(displayCallback)
glutMouseFunc(mouseButtonCallback)
glutMotionFunc(mouseMotionCallback)
glutMouseWheelFunc(mouseWheelCallback)
glutKeyboardFunc(handleKeyDown)
glutKeyboardUpFunc(handleKeyUp)
glutTimerFunc(math.floor(1000.0 / targetFps), timerCallback, 0)


glutMainLoop()

```
