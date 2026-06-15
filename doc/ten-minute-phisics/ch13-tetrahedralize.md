# Chapter 13 — Writing a Tetrahedralizer for Blender

**Video:** https://youtu.be/sNxz_Ht6Y1Y
**Slides:** https://matthias-research.github.io/pages/tenMinutePhysics/13-Tetrahedralize.pdf
**Code:** https://raw.githubusercontent.com/matthias-research/pages/master/tenMinutePhysics/BlenderTetPlugin.py

## Video Transcript

hi not just from 10 minute physics here welcome to tutorial number 13. many of you have asked how i create my tetrahedral meshes so today i'm going to show you how to write a tetrahedralizer we will do it as a blender plugin and as far as i know there are no tetrahedralizers for blend react so i hope it will be useful let's start as usual for the slides and demos have a look at my web page at www dot multismoother.infoslash 10 minute physics since the attention span on youtube is only about two minutes let me first show the result so here we are in blender i first delete the default cube and then add the blender monkey here it is let me move it a little bit to the side first now in order to use the plugin go to edit preferences add-ons click install and select the python implementation of the tetrahedralizer the plugin adds a new entry to add mesh add tetrahydrolyzation when you click it you immediately get the tetrahedral mesh for the surface mesh it looks a little bit strange the reason is that i create one non-planar quad phase for each tetrahedron this doesn't look very natural but it's perfect for exporting you can simply interpret every quad phase as a tetrahedron there are a bunch of parameters here that you can choose from one is to use more than one phase per tetrahedron this is not well suited for exporting but it gives you a very good impression of how the tetrahedral mesh looks like there are a few other parameters that you can tweak for instance you can create interior vertices on a regular grid here you can choose the resolution of this grid you can also specify a mint ted quality all tetrahedra below this quality are simply deleted now i will show you how the algorithm that i used in the plugin works we will use the incremental delivery method it works for triangulation as well as for tetrisation since it is easier to visualize triangles i will show triangles in the slides but i will talk about tetrahedra first i have to show you what the dilunade mesh is in the dillon mesh the circumsphere of any tetrahedron only contains the four adjacent points this mesh is the lunae this mesh is not because the circumsphere of this tetrahedron contains these two additional points let's now have a look at incremental tetrahedralization algorithm the input are the vertices of the surface mesh first we start with four temporary points forming one big tetrahedron containing all input points then we add the first point next we delete all the tetrahedra that violates the dna condition in our case we only have one tetrahedron and it contains the new point therefore we delete it next we fill the voids that we just created with a tetrahedral fan centered at the new point later in the process our mesh might look like this we delete all the tetrahedra that violates the delaney condition then we fill the void with a tetrahedral fan centered at the new point this is the mesh we get when we start with the surface of a dock there are two main problems here the first one is that we have too many tetrahedra this is easy to solve we simply remove the tetrahedra whose centralized outside of the input mesh the second problem is a little bit trickier there might be tetrahedra that do not match the input surface we also say that the tetrahedral mesh is non-conforming this is a very difficult problem and there's a large body of work about it for our purposes we use a very simple solution along with the tetrahedral indices we also keep the indices of the input mesh then we can use the input mesh for collision handling as we saw in the last tutorial visual mesh embedding still works even if some vertices of the high resolution visual mesh are not contained in any tetrahedron now i'll show you a fast implementation of this method an important part of the algorithm is to find all violating tetrahedra after inserting a new point of course we could just check all the tetrahedra but this will deal an algorithm with complexity of n squared fortunately there is a much faster way to do this we start at the blue tetrahedron in the first step we choose it randomly later we use the tetrahedron we found for the previous point then we create array from the tetrahedral center to the new point we find the intersecting phase and we move across this phase to the adjacent tetrahedron if we repeat this process we end up at the containing tetrahedron often consecutive points are close to each other so we typically only have to check one or two tetrahedra now we have to find all the tetrahedra that violates the stellar condition it can be shown that they are all connected directly or indirectly to the tetrahedron that contains the new point therefore we can use a flot fill to find them at the end of the algorithm we want to delete all the tetrahedra whose center is outside of the surface mesh for this we need a fast inside outside test for points to check whether a point p is inside the surface we create a ray originating at p with a random direction r we then find the closest intersection point and normal of the ray with the surface mesh and to speed this up we use a bounding volume hierarchy of the input triangles if the ray intersects the surface and the surface normal at the intersection point points into the direction of r we know that the point p is inside the surface we can make this algorithm more robust by checking more rays and use a majority vote now let's have a look at the python implementation here you see the implementation of the plugin in python it's about 600 lines of code so i won't go into the details i will just scroll quickly through it this is the procedure to check whether a point is inside a mesh as input we have the bounding volume hierarchy of the triangles of the surface mesh we then shoot six rays in all canonical directions the raycast method of blender tells us whether our a intersects any of the surface triangles if the ray hits any triangle we check the surface normal at the intersection point and see whether it points in the same direction as the ray if so we increment the number of votes if more than three of the six rays say the point is inside then we return true here is a function to compute at the center of the circumsphere of a tetrahedron this function measures the quality of a tetrahedron the quality is a value between 0 and 1 where 1 is the value for a perfect tetrahedron here we created actual tetrahedral indices we start with the first big tetrahedron and then we run through all the input points we first search for the containing tetrahedron then we run a flood fill from that tetrahedron outwards to find all the biology tetrahedra then we remove them and finally we add a tetrahedral fan centered at the new point finally we remove all the tetrahedra that we don't want in the result here we check for the quality of the tetrahedron and here we compute the center and check whether the center is inside of the surface mesh if not we don't copy the tetrahedron i hope you enjoyed the tutorial thanks for watching and i will see you in the next one

## Source Code

### BlenderTetPlugin.py

```python

# Copyright 2022 Matthias Mueller - Ten Minute Physics, 
# https://www.youtube.com/channel/UCTG_vrRdKYfrpqCv_WV4eyA 
# www.matthiasMueller.info/tenMinutePhysics

# Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation 
# files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, 
# copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom 
# the Software is furnished to do so, subject to the following conditions:
# The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES 
# OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS 
# BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, 
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

bl_info = {
    "name": "Create Tetrahedralization",
    "description": "Create Tetrahedralization",
    "author": "Matthias Mueller",
    "version": (1, 0, 0),
    "blender": (2, 90, 0),
    "wiki_url": "",
    "tracker_url": "",
    "category": "Add Mesh"}

import bpy
import bmesh
import math
import mathutils
from random import random
from bpy_extras.object_utils import AddObjectHelper
from mathutils.bvhtree import BVHTree
from functools import cmp_to_key

from bpy.props import (
    FloatProperty,
    IntProperty,
    BoolProperty,
)

# ------------------------------------------------
dirs = [
    mathutils.Vector((1.0, 0.0, 0.0)), \
    mathutils.Vector((0.0,-1.0, 0.0)), \
    mathutils.Vector((0.0, 1.0, 0.0)), \
    mathutils.Vector((0.0,-1.0, 0.0)), \
    mathutils.Vector((0.0, 0.0, 1.0)), \
    mathutils.Vector((0.0, 0.0,-1.0))]

tetFaces = [[2,1,0], [0,1,3], [1,2,3], [2,0,3]]

# ------------------------------------------------
def isInside(tree, p, minDist = 0.0):

    numIn = 0

    for i in range(6):
        location, normal, index, distance = tree.ray_cast(p, dirs[i])
        if normal:
            if normal.dot(dirs[i]) > 0.0:
                numIn = numIn + 1
            if minDist > 0.0 and distance < minDist:
                return False
        
    return numIn > 3

# ------------------------------------------------
def getCircumCenter(p0, p1, p2, p3):

    b = p1 - p0
    c = p2 - p0
    d = p3 - p0

    det = 2.0 * (b.x*(c.y*d.z - c.z*d.y) - b.y*(c.x*d.z - c.z*d.x) + b.z*(c.x*d.y - c.y*d.x))
    if det == 0.0:
        return p0
    else: 
        v = c.cross(d)*b.dot(b) + d.cross(b)*c.dot(c) + b.cross(c)*d.dot(d)
        v /= det
        return p0 + v

# ------------------------------------------------
def tetQuality(p0, p1, p2, p3):

    d0 = p1 - p0
    d1 = p2 - p0
    d2 = p3 - p0
    d3 = p2 - p1
    d4 = p3 - p2
    d5 = p1 - p3

    s0 = d0.magnitude
    s1 = d1.magnitude
    s2 = d2.magnitude
    s3 = d3.magnitude
    s4 = d4.magnitude
    s5 = d5.magnitude

    ms = (s0*s0 + s1*s1 + s2*s2 + s3*s3 + s4*s4 + s5*s5) / 6.0
    rms = math.sqrt(ms)

    s = 12.0 / math.sqrt(2.0)

    vol = d0.dot(d1.cross(d2)) / 6.0
    return s * vol / (rms * rms * rms)
    # 1.0 for regular tetrahedron


# ------------------------------------------------
def compareEdges(e0, e1):
    if e0[0] < e1[0] or (e0[0] == e1[0] and e0[1] < e1[1]):
        return -1
    else:
        return 1

def equalEdges(e0, e1):
    return e0[0] == e1[0] and e0[1] == e1[1]

# ------------------------------------------------
def createTetIds(verts, tree, minQuality):

    tetIds = []
    neighbors = []
    tetMarks = []
    tetMark = 0
    firstFreeTet = -1

    planesN = []
    planesD = []

    firstBig = len(verts) - 4

    # first big tet
    tetIds.append(firstBig)
    tetIds.append(firstBig + 1)
    tetIds.append(firstBig + 2)
    tetIds.append(firstBig + 3)
    tetMarks.append(0)

    for i in range(4):
        neighbors.append(-1)
        p0 = verts[firstBig + tetFaces[i][0]]
        p1 = verts[firstBig + tetFaces[i][1]]
        p2 = verts[firstBig + tetFaces[i][2]]
        n = (p1 - p0).cross(p2 - p0)
        n.normalize()
        planesN.append(n)
        planesD.append(p0.dot(n))

    center = mathutils.Vector((0.0, 0.0, 0.0))

    print(" ------------- tetrahedralization ------------------- ")
    
    for i in range(0, firstBig):
        p = verts[i]

        if i % 100 == 0:
            print("inserting vert", i + 1, "of", firstBig)

        # find non-deleted tet

        tetNr = 0
        while tetIds[4 * tetNr] < 0:
            tetNr = tetNr + 1
            
        # find containing tet

        tetMark = tetMark + 1
        found = False

        while not found:
            if tetNr < 0 or tetMarks[tetNr] == tetMark:
                break
            tetMarks[tetNr] = tetMark

            id0 = tetIds[4 * tetNr]
            id1 = tetIds[4 * tetNr + 1]
            id2 = tetIds[4 * tetNr + 2]
            id3 = tetIds[4 * tetNr + 3]

            center = (verts[id0] + verts[id1] + verts[id2] + verts[id3]) * 0.25

            minT = float('inf')
            minFaceNr = -1

            for j in range(0, 4):
                n = planesN[4 * tetNr + j]
                d = planesD[4 * tetNr + j]

                hp = n.dot(p) - d
                hc = n.dot(center) - d

                t = hp - hc
                if t == 0:
                    continue

                # time when c -> p hits the face
                t = -hc / t

                if t >= 0.0 and t < minT:
                    minT = t
                    minFaceNr = j
            
            if minT >= 1.0:
                found = True
            else:
                tetNr = neighbors[4 * tetNr + minFaceNr]
        
        if not found:
            print("*********** failed to insert vertex")
            continue
        
        # find violating tets

        tetMark = tetMark + 1

        violatingTets = []
        stack = [tetNr]

        while len(stack) != 0:
            tetNr = stack.pop()
            if tetMarks[tetNr] == tetMark:
                continue
            tetMarks[tetNr] = tetMark
            violatingTets.append(tetNr)

            for j in range(4):
                n = neighbors[4 * tetNr + j]
                if n < 0 or tetMarks[n] == tetMark:
                    continue
                
                # Delaunay condition test

                id0 = tetIds[4 * n]
                id1 = tetIds[4 * n + 1]
                id2 = tetIds[4 * n + 2]
                id3 = tetIds[4 * n + 3]

                c = getCircumCenter(verts[id0], verts[id1], verts[id2], verts[id3])

                r = (verts[id0] - c).magnitude
                if (p - c).magnitude < r:
                    stack.append(n)

        # remove old tets, create new ondes

        edges = []

        for j in range(len(violatingTets)):
            tetNr = violatingTets[j]

            # copy info before we delete it
            ids = [0] * 4
            ns = [0] * 4
            for k in range(4):
                ids[k] = tetIds[4 * tetNr + k]
                ns[k] = neighbors[4 * tetNr + k]

            # delete the tet
            tetIds[4 * tetNr] = -1
            tetIds[4 * tetNr + 1] = firstFreeTet
            firstFreeTet = tetNr

            # visit neighbors

            for k in range(4):
                n = ns[k]
                if n >= 0 and tetMarks[n] == tetMark:
                    continue

                # no neighbor or neighbor is not-violating -> we are facing the border

                # create new tet

                newTetNr = firstFreeTet
                
                if newTetNr >= 0:
                    firstFreeTet = tetIds[4 * firstFreeTet + 1]
                else:
                    newTetNr = int(len(tetIds) / 4)
                    tetMarks.append(0)
                    for l in range(4):
                        tetIds.append(-1)
                        neighbors.append(-1)
                        planesN.append(mathutils.Vector((0.0, 0.0, 0.0)))
                        planesD.append(0.0)

                id0 = ids[tetFaces[k][2]]
                id1 = ids[tetFaces[k][1]]
                id2 = ids[tetFaces[k][0]]

                tetIds[4 * newTetNr] = id0
                tetIds[4 * newTetNr + 1] = id1
                tetIds[4 * newTetNr + 2] = id2
                tetIds[4 * newTetNr + 3] = i

                neighbors[4 * newTetNr] = n

                if n >= 0:
                    for l in range(4):
                        if neighbors[4 * n + l] == tetNr:
                            neighbors[4 * n + l] = newTetNr
                        
                # will set the neighbors among the new tets later

                neighbors[4 * newTetNr + 1] = -1
                neighbors[4 * newTetNr + 2] = -1
                neighbors[4 * newTetNr + 3] = -1

                for l in range(4):
                    p0 = verts[tetIds[4 * newTetNr + tetFaces[l][0]]]
                    p1 = verts[tetIds[4 * newTetNr + tetFaces[l][1]]]
                    p2 = verts[tetIds[4 * newTetNr + tetFaces[l][2]]]
                    newN = (p1 - p0).cross(p2 - p0)
                    newN.normalize()
                    planesN[4 * newTetNr + l] = newN
                    planesD[4 * newTetNr + l] = newN.dot(p0)

                if id0 < id1:
                    edges.append((id0, id1, newTetNr, 1))
                else:
                    edges.append((id1, id0, newTetNr, 1))

                if id1 < id2:
                    edges.append((id1, id2, newTetNr, 2))
                else:
                    edges.append((id2, id1, newTetNr, 2))

                if id2 < id0:
                    edges.append((id2, id0, newTetNr, 3))
                else:
                    edges.append((id0, id2, newTetNr, 3))

            # next neighbor
        # next violating tet

        # fix neighbors

        sortedEdges = sorted(edges, key = cmp_to_key(compareEdges))

        nr = 0
        numEdges = len(sortedEdges)

        while nr < numEdges:
            e0 = sortedEdges[nr]
            nr = nr + 1

            if nr < numEdges and equalEdges(sortedEdges[nr], e0):
                e1 = sortedEdges[nr]

                id0 = tetIds[4 * e0[2]]
                id1 = tetIds[4 * e0[2] + 1]
                id2 = tetIds[4 * e0[2] + 2]
                id3 = tetIds[4 * e0[2] + 3]

                jd0 = tetIds[4 * e1[2]]
                jd1 = tetIds[4 * e1[2] + 1]
                jd2 = tetIds[4 * e1[2] + 2]
                jd3 = tetIds[4 * e1[2] + 3]

                neighbors[4 * e0[2] + e0[3]] = e1[2]
                neighbors[4 * e1[2] + e1[3]] = e0[2]
                nr = nr + 1

    # next point

    # remove outer, deleted and outside tets

    numTets = int(len(tetIds) / 4)
    num = 0
    numBad = 0

    for i in range(numTets):
        id0 = tetIds[4 * i]
        id1 = tetIds[4 * i + 1]
        id2 = tetIds[4 * i + 2]
        id3 = tetIds[4 * i + 3]

        if id0 < 0 or id0 >= firstBig or id1 >= firstBig or id2 >= firstBig or id3 >= firstBig:
            continue

        p0 = verts[id0]
        p1 = verts[id1]
        p2 = verts[id2]
        p3 = verts[id3]
        
        quality = tetQuality(p0, p1, p2, p3)
        if quality < minQuality:
            numBad = numBad + 1
            continue

        center = (p0 + p1 + p2 + p3) * 0.25
        if not isInside(tree, center):
            continue

        tetIds[num] = id0
        num = num + 1
        tetIds[num] = id1
        num = num + 1
        tetIds[num] = id2
        num = num + 1
        tetIds[num] = id3
        num = num + 1

    del tetIds[num:]

    print(numBad, "bad tets deleted")
    print(int(len(tetIds) / 4),"tets created")

    return tetIds

# ------------------------------------------------
def randEps():
    eps = 0.0001
    return - eps + 2.0 * random() * eps

# ------------------------------------------------
def createTets(resolution, minQuality, oneFacePerTet, scale = 1.0):

    objs = bpy.context.selected_objects
    if len(objs) != 1:
        return

    obj = objs[0]
    tree = BVHTree.FromObject(obj, bpy.context.evaluated_depsgraph_get())

    tetMesh = bpy.data.meshes.new("Tets")
    bm = bmesh.new()

    # create vertices

    # from input mesh

    tetVerts = []

    for v in obj.data.vertices:
        tetVerts.append(mathutils.Vector((v.co[0] + randEps(), v.co[1] + randEps(), v.co[2] + randEps())))

    # measure vertices

    inf = float('inf')

    center = mathutils.Vector((0.0, 0.0, 0.0))
    bmin  = mathutils.Vector((inf, inf, inf))
    bmax  = mathutils.Vector((-inf, -inf, -inf))
    for p in tetVerts:
        center += p
        for i in range(3):
            bmin[i] = min(bmin[i], p[i])
            bmax[i] = max(bmax[i], p[i])
    center /= len(tetVerts)

    radius = 0.0
    for p in tetVerts:
        d = (p - center).magnitude
        radius = max(radius, d)

    # interior sampling

    if resolution > 0:
        dims = bmax - bmin
        dim = max(dims[0], max(dims[1], dims[2]))
        h = dim / resolution

        for xi in range(int(dims[0] / h) + 1):
            x = bmin[0] + xi * h + randEps()
            for yi in range(int(dims[1] / h) + 1):
               y = bmin[1] + yi * h + randEps()
               for zi in range(int(dims[2] / h) + 1):
                   z = bmin[2] + zi * h + randEps()
                   p = mathutils.Vector((x, y, z))
                   if isInside(tree, p, 0.5 * h):
                       tetVerts.append(p)

    # big tet to start with

    s = 5.0 * radius
    tetVerts.append(mathutils.Vector((-s, 0.0, -s)))
    tetVerts.append(mathutils.Vector((s, 0.0, -s)))
    tetVerts.append(mathutils.Vector((0.0, s, s)))
    tetVerts.append(mathutils.Vector((0.0, -s, s)))

    faces = createTetIds(tetVerts, tree, minQuality)

    numTets = int(len(faces) / 4)

    if oneFacePerTet:
        numSrcPoints = len(obj.data.vertices)
        numPoints = len(tetVerts) - 4
        # copy src points without distortion
        for i in range(0, numSrcPoints):
            co = obj.data.vertices[i].co
            bm.verts.new(co)
        for i in range(numSrcPoints, numPoints):
            p = tetVerts[i]
            bm.verts.new((p.x, p.y, p.z))
    else:
        for i in range(numTets):
            center = (tetVerts[faces[4 * i]] + tetVerts[faces[4 * i + 1]] + tetVerts[faces[4 * i + 2]] + tetVerts[faces[4 * i + 3]]) * 0.25
            for j in range(4):
                for k in range(3):
                    p = tetVerts[faces[4 * i + tetFaces[j][k]]]
                    p = center + (p - center) * scale
                    bm.verts.new((p.x, p.y, p.z))

    bm.verts.ensure_lookup_table()

    nr = 0

    for i in range(numTets):
        if oneFacePerTet:
            id0 = faces[4 * i]
            id1 = faces[4 * i + 1]
            id2 = faces[4 * i + 2]
            id3 = faces[4 * i + 3]
            bm.faces.new([bm.verts[id0], bm.verts[id1], bm.verts[id2], bm.verts[id3]])
        else:
            for j in range(4):
                bm.faces.new([bm.verts[nr], bm.verts[nr + 1], bm.verts[nr + 2]])
                nr = nr + 3

    bm.to_mesh(tetMesh)
    tetMesh.update()

    return tetMesh

# ------------------------------------------------

class Tetrahedralizer(bpy.types.Operator, AddObjectHelper):
    """create a tetrahedralization"""
    bl_idname = "mesh.primitive_add_tets"
    bl_label = "Add Tetrahedralization"
    bl_options = {'REGISTER', 'UNDO'}

    resolution: IntProperty(
        name = "Interior resolution",
        description = "Interior resolution",
        min = 0, max = 100,
        default = 10,
    )

    minQualityExp: IntProperty(
        name = "Min Tet Quality Exp",
        description = "Min Tet Quality Exp",
        min = -4, max = 0,
        default = -3,
    )

    oneFacePerTet: BoolProperty(
        name = "One Face Per Tet",
        description = "One Face Per Tet",
        default = True,
    )

    tetScale: FloatProperty(
        name = "Tet Scale",
        description = "Tet Scale",
        min = 0.1, max = 1.0,
        default = 0.8,
    )

    def execute(self, context):

        tetMesh = createTets(self.resolution, math.pow(10.0, self.minQualityExp), self.oneFacePerTet, self.tetScale)

        # add the mesh as an object into the scene with this utility module
        from bpy_extras import object_utils
        object_utils.object_data_add(context, tetMesh, operator = self)

        return {'FINISHED'}


def menu_func(self, context):
    self.layout.operator(Tetrahedralizer.bl_idname, icon='PMARKER_SEL')


def register():
    bpy.utils.register_class(Tetrahedralizer)
    bpy.types.VIEW3D_MT_mesh_add.append(menu_func)


def unregister():
    bpy.utils.unregister_class(Tetrahedralizer)
    bpy.types.VIEW3D_MT_mesh_add.remove(menu_func)


if __name__ == "__main__":
    register()



```
