# Chapter 07 — Intuitive 3D Vector Math for Simulation

**Video:** https://youtu.be/hRz3sh7QQ6w
**Slides:** https://matthias-research.github.io/pages/tenMinutePhysics/07-3dmath.pdf

## Lecture Notes

### 3D Vector

A 3D vector is written in **bold** (e.g. **v**) and has three components:

**v** = [vx, vy, vz]^T

Used as a **location** (particle position) or an **arrow** (velocity). Right-hand coordinate system.

---

### Vector Operations

**Addition** — move forward in time:

**p** + **a** = [px+ax, py+ay, pz+az]^T

**Scaling** — direction preserved:

Δt **v** = [Δt vx, Δt vy, Δt vz]^T

**Subtraction** — vector *from* **a** *to* **b** is **b** − **a** (not **a** − **b**!):

**b** − **a** = [bx−ax, by−ay, bz−az]^T

**Length and normalization:**

|**v**| = √(vx² + vy² + vz²)

**n** = (1/|**v**|) **v**      (unit vector, same direction)

---

### The Dot Product

**a** · **b** = ax·bx + ay·by + az·bz      (yields a scalar)

- **a** · **b** = 0  ↔  **a** ⊥ **b**
- Component of **v** along direction **n**: vₙ = **n** · **v**

**Decomposing a vector** (restitution / friction):

**v**ₙ = (**n** · **v**) **n**      (normal component)
**v**t = **v** − **v**ₙ           (tangential component)

---

### The Cross Product

**a** × **b** = [ay·bz − by·az,  az·bx − bz·ax,  ax·by − bx·ay]^T

Yields a **vector** perpendicular to both **a** and **b** (right-hand rule).

**Normal of a triangle** (p1, p2, p3):

**n** = (**p**2 − **p**1) × (**p**3 − **p**1) / |(**p**2 − **p**1) × (**p**3 − **p**1)|

**Area of a parallelogram / triangle:**

A_parallelogram = |**a** × **b**|

A_triangle = (1/2) |(**p**2 − **p**1) × (**p**3 − **p**1)|

**Tetrahedral volume** (edges **a**, **b**, **c** from one vertex):

V_tet = (1/6) (**a** × **b**) · **c**

---

### 3D Matrices and Transformations

A 3×3 matrix A transforms a vector **x** → A**x**. Column representation:

A**x** = x1·**a**1 + x2·**a**2 + x3·**a**3      (columns are axes)

Affine transform: **v**' = A**v** + **b**

**Determinant:**

det(A) = (**a**1 × **a**2) · **a**3

- det = 1: volume conserving
- det = 0: singular, no inverse

**Matrix inverse:** A⁻¹A = I;  **v** = A⁻¹(**v**' − **b**)

**Transpose:** A^T flips rows and columns. Key identity:

**a**^T **b** = **a** · **b**      (dot product without the dot)
**a**^T **a** = |**a**|²

---

### Rigid Transforms (Rotations)

Columns of a rotation matrix R are orthonormal unit vectors:
**r**1 · **r**2 = 0  and  |**r**1|² = 1  →  R^T R = I  →  R⁻¹ = R^T

Deformation energy: E_deformation = f(F^T F − I)  (zero if not deformed)

**Axis-angle** rotation by angle α around unit axis **n** (4 values, use library):

**q** = [sin(α)·nx,  sin(α)·ny,  sin(α)·nz,  cos(α)]^T      ← quaternion

Use a math library (e.g. THREE.js) for quaternion multiply, apply, compose.

---

### Tetrahedral Skinning

Map a point **x** in rest-pose tet Q to deformed tet P:

**x**' = PQ⁻¹**x** + (**p** − PQ⁻¹**q**)

Where Q = [**q**1−**q**4, **q**2−**q**4, **q**3−**q**4] and P similarly.


## Video Transcript

hi malthus from 10 minute physics here this time we won't write any code instead i will introduce you to 3d vector math the math that we need to do 3d simulations of course there are many textbooks on the subject here however i give you a very compact presentation which focuses precisely on the part that we need to do 3d simulations in addition to the definitions of the concepts i will also give you my personal intuitions behind them which i developed over time in the description you will find a link to my 10 minutes physics page as well as to the slides of the presentation in order to be able to work in three-dimensional space we need a coordinate system here we have the x and the y-axis on the ground and the z-axis pointing upwards we typically use a right-handed coordinate system which means if the x-axis points along the thumb and the y-axis points along the index finger then the z-axis points along the middle finger then a vector is just a combination of three components or coordinates we can write them in column form surrounded by square brackets or as a single symbol but then we use bold phase we can use vectors for two different things first we describe a position in 3d space like the particle position using x y and z we can also use it to describe an arrow like the velocity of a particle here you can see that the x component is negative pointing against the direction of the x-axis as i just mentioned in mathematics the coordinate system is oriented such that the x and y axis are on the ground and the z-axis points upwards in graphics the coordinate system is oriented such that the y-axis points upwards as you can see this is still a right-handed coordinate system the reason for having the y-axis pointing upwards is that if we place a camera the camera sees a two-dimensional coordinate system with the x-axis pointing to the right and the y-axis pointing upwards the z-axis then points against us which is also the reason why a depth buffer typically is called an z buffer to do simulations we need vector operations the first one is addition we can use this to move forward in time let's say we have p the position of a particle and we want to add a to do this we can simply add all the components individually a second operation is scaling we can use this to go from a velocity to a position update scaling means that we multiply a vector by a simple number here delta t to do this we simply multiply all the components individually what's important to note this is that the scaled vector has the same direction as the original vector a third operation is subtraction we can use this to compute the vector from position a to position b in order to do this we subtract a from b we can compute this vector by simply do the subtraction on all components individually note that in order to compute the vector from a to b we have to subtract a from b and not b from a computing the length of a vector is pretty simple we can just add the squares of all the components and take the square root an important concept in simulation is a normalized vector or unit vector this is a vector that points in the same direction as v but has length 1. we can compute this vector by scaling the vector v by the inverse of its length finally we have two very important operations the dot product and the cross product they are essential to do 3d simulations and 3d math in general the dot product is an operation between two vectors it's written as a little dot to compute it we compute a x times b x plus a y times b y plus a z times b z as you can see the result is a scalar or a simple number this is also the reason why the dot product is sometimes called the scalar product it is super simple to compute and very useful a first very important use case is to compute the length of a vector v along a direction defined by a unit vector n to compute this scalar value v n we simply take the dot product between n and v a second important use case is to decide whether two vectors are perpendicular to each other in this case their dot product is zero a third important use case is to compute general vector components let's say we have a vector v and we want to compute its component along a direction defined by a unit vector n to compute this we measure the length of v in the direction of n and multiply n by this length to get the vector v n we can compute the perpendicular component by simply subtracting v n from the original vector v such a decomposition is important to hand the restitution and friction effects the cross product is also an operation between two vectors and is written as a little cross as you can see the result is a vector in contrast to the dot product where the result is a simple number here are the equations to compute the individual components of this resulting vector the result a cross b is a vector that is perpendicular to both a and b in the right-handed coordinate system if a points along the thumb and b points along the index finger then the result a cross b points along the middle finger we can also use the cross product to compute the normal of a triangle the normal of a triangle is a unit vector that is perpendicular to the plane of the triangle to do this we compute the vector from p1 to p2 and from p1 to p3 if we then take the cross product of these two vectors we get a vector that is perpendicular to the plane of the triangle here i want to introduce a very important concept the concept of an orientation of a triangle if you curl the fingers of your right hand along p1 p2 and p3 then your thumb points into the direction of the normal of the triangle since the normal of the triangle is a unit vector we have to normalize it an oriented mesh is a mesh for which all triangle faces point outwards to guarantee this we have to define the faces in a certain way for this tetrahedron we have to define the bottom face as 3 2 1. if we define it as 1 2 3 the normal will point inwards as it can verify with your right hand so this is a valid definition of all the faces of the tetrahedron this is another valid definition because it doesn't matter at which vertex we start here we define the bottom face as 132 which also generates a normal that points out of the surface we know that the cross product of the vectors a and b is perpendicular to the two vectors however does the length of this vector also have a meaning the length of the cross product is the area of the parallelogram defined by the vector a and b with this we can compute the area of a triangle in a very easy way we first define the vector from p1 to p2 again and from p1 to p3 we then take the cross product and measure its length the length is then two times the area of the triangle so we can compute the area of the triangle with this simple formula the cool thing is that we can use the cross product to compute the volume of a tetrahedron as well so let's assume we have a tetrahedron defined by three vectors a b and c the length of a cross b is the area of the parallelogram defined by a and b as we just saw we see we can define a parallel pipe in order to compute its volume we need its height which is the projection of the vector c in the direction of a cross b to compute h we use the dot product it's the dot product of the normalized vector a cross b and c the length of a cross b is the area of the base phase if we multiply this equation by a we have a times h on the left hand side this however is the volume of the parallel piped this means that we can compute the volume of the parallel piped as a cross b dot c since the volume of the tetrahedron is 1 6 of the volume of the parallel pipe we have this nice formula to compute the volume of a tetrahedron for simulations we need vector transformations as well a transformation can describe the motion of a rigid body or a soft body transformations are typically described by matrices here we have a 3x3 matrix we can write the matrix as the two-dimensional array of components surrounded by square brackets or a single symbol if we use a single symbol we use a capital letter we can multiply a matrix with a vector to get a new vector for the first entry we perform a dot product of the first row of the matrix with the vector for the second entry we perform a dot product with the second row and the vector and the same for the third entry we can construct a matrix that doesn't change the vector this matrix is called the identity matrix and represented by a capital i the formula for multiplying a matrix with a vector looked kind of arbitrary things get much more intuitive if we represent the matrix a by three column vectors as you can see the resulting vector is the first column times x1 plus the second column times x2 plus the third column times x3 i can write this in a more compact way by writing the matrix a as three column vectors a1 a2 and a3 for a general linear transformation we multiply a vector v by a matrix a and add an offset vector b using column vectors for a we get this form here now this form can be visualized in a very intuitive way we can describe the vector v with three components v x v y and v z applying a transformation with b a 1 a 2 and a 3 means that we transform the vector v into a new coordinate system with its origin at b and the three new axis a1 a2 and a3 now the resulting vector v is just the origin plus the scaled axis which means we land at this point here as you can see we transformed the vector v into this new coordinate system what you can also see is that if the length of a1 is larger than 1 then things get stretched along the x-axis if the length of an axis is smaller than 1 then objects get compressed in that direction also if the axes are not perpendicular to each other a shear is applied each matrix has a property called the determinant there is a specific formula to compute it this formula looks kind of arbitrary however there's a very nice interpretation of it using the columns of the matrix it is basically just the volume of the parallel pipe spawned by the three axes we can use this quantity to characterize our transformation if the determinant is one the transformation is volume conserving this is because the parallel pipe shows us how a unit cube is transformed by a if the determinant is 0 however all axes lie in a common plane this means our transformation doesn't reach all the points in space this also means that the inverse of the transformation does not exist we can combine transformations let's say we have vector x and transform it using matrix a we can take the result and transform it using matrix b we can combine these two transformations by multiplying b and a to get a new matrix c as an example to compute the entry in c on the second row and first column we take the dot product between the second row of a and the first column of b here is the explicit formula for this entry the inverse of a matrix is a matrix that reverses a certain transformation if we have a vector x and transform it using matrix a and take the result and transform it with the inverse then we end up at the same location this means that the inverse matrix multiplied by the matrix is the identity matrix the inverse of a matrix can be easily computed from the entries of a for a general transformation using an offset b the inverse has this form this means that before applying the inverse matrix a we have to subtract the new origin we can use the idea of inverse matrices for tetrahedral skinning this means we can deform a visual mesh along with the surrounding volumetric tetrahedral mesh let's assume we have a tetrahedron defined by the origin q and the vectors q1 q2 and q3 we also have a deformed version of the same tetrahedron defined by the origin p and the vectors p1 p2 and p3 now we are looking for a transformation that transforms a vector x along with the tetrahedron to arrive at the position x prime we can interpret the vectors q1 q2 and q3 as the column vectors of a matrix q if we transform the tetrahedron using the transformation defined by the vector q and the inverse of the matrix q we get the unit tetrahedron in the regular coordinate system applying the transformation defined by p p1 p2 and p3 brings us into the deformed tetrahedron the combined transformation looks like this we saw earlier that we can interpret the column vectors of matrix a as the axis of a deformed coordinate system in the special case where all axes are perpendicular to each other and each axis has length 1 we have a rigid transformation this is because no shear and no stretch is introduced a rigid transformation is basically just a translation and a rotation to characterize a rigid transformation i have to introduce you to transposition let's say we have a matrix a the transpose of a has the same dimension as a however we turn columns into rows this means the element of the first column of a are now stored in the first row of a transposed the same for the second column and for the third column which appear now in the second row and the third row we can do the same thing with a vector if we transpose a vector it turns from a column vector into a row vector using the idea of a transposed vector we can now compute the dot product without a dot for this we multiply a transposed with b to compute a certain entry of the resulting matrix c we have to take the dot product of the corresponding rows and columns here we have only one row and one column so our result is just one value if we now multiply a transpose with a we get as a result a x squared plus a y squared plus a z squared which is the length of the vector a squared what happens if we multiply a transposed matrix with itself in the transposed matrix all the column vectors of r are now row vectors if we multiply these two matrices out we get the following structure we have the squares of the lengths of the column vectors on the diagonal in the off-diagonal elements we have the mutual dot products of the column vectors now for rigid transformation which is also a rotation we know that all axes are perpendicular to each other which means all the dot products are zero we also know that the lengths of the axes are one this means the diagonal entries are all one and we have zeros on the off diagonal elements this means for rigid transformation or rotation we have r transposed times r is the identity matrix we can also conclude that the inverse of a rotation matrix is just its transpose as a side note the deformation energy of a transformation is often measured as a function of the transformation matrix transposed times the transformation matrix minus the identity matrix what we know from above is that for rigid transformation this expression is zero so we get a zero deformation energy for a rigid transformation which is exactly what we expect in 3d we can express every rotation by a rotation axis and a rotation angle if we define the rotation axis with a unit vector n and the rotation angle with alpha then we can write down the rotation matrix like this a unit vector has two degrees of freedom and the scalar has one degree of freedom so we have three degrees of freedom for any rotation however if we use a matrix we have nine values to store to save space we could represent any rotation by a simple vector r r would then be n times alpha to store r we only need three entries the problem of this idea is that to perform the actual rotation we need to design at the cosine of alpha not alpha itself these quantities are expensive to compute a better way is to use a vector with four entries in this case we scale n not by alpha but by the sine of alpha and store the cosine in a separate element this quantity is called a quaternion quaternions allow us to rotate vectors we can also combine rotations by multiplying quaternions finding the inverse of a rotation is particularly simple we just have to change the sign of the first three entries now we are ready to write 3d simulations i hope you enjoyed this tutorial and i will see you in the next one
