# Chapter 7 — 3D Vector Math for Simulation

Every physics simulation that runs in three dimensions rests on the same compact set of mathematical tools. Vectors describe where things are and how fast they move. The dot product measures alignment. The cross product builds perpendiculars and counts area. Matrices encode coordinate changes and deformations, and quaternions represent orientations without the pitfalls of Euler angles. This chapter develops each of these tools from first principles, with emphasis on the geometric pictures that make them useful in practice.

---

## Vectors in 3D Space

A **3D vector** $\mathbf{v}$ packs three real numbers into a column:

$$\mathbf{v} = \begin{bmatrix} v_x \\ v_y \\ v_z \end{bmatrix}$$

A vector serves two distinct roles in simulation. It can represent a **position** — where a particle sits in space — or an **arrow** — a direction and magnitude, such as a velocity or a force. The same mathematical object handles both; only interpretation differs.

We work in a **right-handed coordinate system**: point the thumb of the right hand along $x$, the index finger along $y$, and the middle finger naturally extends along $z$. In graphics, $y$ often points upward to match the camera's screen coordinates, but the handedness stays the same.

### Basic Operations

**Addition** moves a point by an offset — the core of every time-integration step:

$$\mathbf{p} + \mathbf{a} = \begin{bmatrix} p_x + a_x \\ p_y + a_y \\ p_z + a_z \end{bmatrix}$$

**Scaling** stretches or shrinks a vector without changing its direction. Multiplying a velocity $\mathbf{v}$ by a timestep $\Delta t$ converts it to a displacement:

$$\Delta t\, \mathbf{v} = \begin{bmatrix} \Delta t\, v_x \\ \Delta t\, v_y \\ \Delta t\, v_z \end{bmatrix}$$

**Subtraction** produces the arrow from one point to another. The vector *from* $\mathbf{a}$ *to* $\mathbf{b}$ is $\mathbf{b} - \mathbf{a}$, not $\mathbf{a} - \mathbf{b}$. Getting this sign wrong is a common source of sign errors in collision handling.

**Length** is the familiar Euclidean norm:

$$|\mathbf{v}| = \sqrt{v_x^2 + v_y^2 + v_z^2}$$

A **unit vector** (or normalized vector) preserves direction while forcing length to one:

$$\hat{\mathbf{n}} = \frac{\mathbf{v}}{|\mathbf{v}|}$$

Unit vectors appear constantly — as surface normals, as rotation axes, as reference directions for projections.

---

## The Dot Product

$$\mathbf{a} \cdot \mathbf{b} = a_x b_x + a_y b_y + a_z b_z$$

The dot product takes two vectors and returns a **scalar**. Computationally it is as cheap as it looks: three multiplications and two additions.

### Geometric meaning

The key insight is that the dot product measures **projection**. Given a unit vector $\hat{\mathbf{n}}$ and any vector $\mathbf{v}$, the scalar

$$v_n = \hat{\mathbf{n}} \cdot \mathbf{v}$$

is exactly the signed length of $\mathbf{v}$'s shadow cast along $\hat{\mathbf{n}}$. This is positive when $\mathbf{v}$ points broadly in the same direction as $\hat{\mathbf{n}}$, zero when they are perpendicular, and negative when they point apart.

Two immediate consequences:

- $\mathbf{a} \cdot \mathbf{b} = 0$ if and only if $\mathbf{a}$ and $\mathbf{b}$ are **perpendicular**.
- $\mathbf{v} \cdot \mathbf{v} = |\mathbf{v}|^2$, so squaring a length avoids a square root.

### Decomposing a vector

Simulations frequently need to split a velocity into components parallel and perpendicular to a surface. Given the surface normal $\hat{\mathbf{n}}$:

$$\mathbf{v}_n = (\hat{\mathbf{n}} \cdot \mathbf{v})\, \hat{\mathbf{n}} \qquad \text{(normal component)}$$
$$\mathbf{v}_t = \mathbf{v} - \mathbf{v}_n \qquad \text{(tangential component)}$$

Restitution (bounciness) scales $\mathbf{v}_n$; friction attenuates $\mathbf{v}_t$. Every collision response in this book runs through this two-line decomposition.

---

## The Cross Product

$$\mathbf{a} \times \mathbf{b} = \begin{bmatrix} a_y b_z - b_y a_z \\ a_z b_x - b_z a_x \\ a_x b_y - b_x a_y \end{bmatrix}$$

Unlike the dot product, the cross product returns a **vector**. That vector is perpendicular to both $\mathbf{a}$ and $\mathbf{b}$, and its direction follows the right-hand rule: wrap the right hand from $\mathbf{a}$ toward $\mathbf{b}$ and the thumb points along $\mathbf{a} \times \mathbf{b}$.

### Triangle normals and mesh orientation

The cross product is the standard way to find a triangle's surface normal. Given vertices $\mathbf{p}_1, \mathbf{p}_2, \mathbf{p}_3$:

$$\hat{\mathbf{n}} = \frac{(\mathbf{p}_2 - \mathbf{p}_1) \times (\mathbf{p}_3 - \mathbf{p}_1)}{|(\mathbf{p}_2 - \mathbf{p}_1) \times (\mathbf{p}_3 - \mathbf{p}_1)|}$$

The direction of this normal depends on the order of the vertices. Curling the right hand along $p_1 \to p_2 \to p_3$, the thumb points toward the normal. For a closed mesh to have all normals pointing outward, every face must be wound consistently — checking this with the right-hand rule is quicker than staring at index arrays.

### Area from the cross product

The length of $\mathbf{a} \times \mathbf{b}$ equals the area of the parallelogram spanned by $\mathbf{a}$ and $\mathbf{b}$:

$$A_{\text{parallelogram}} = |\mathbf{a} \times \mathbf{b}|$$

A triangle is half a parallelogram, so:

$$A_{\text{triangle}} = \tfrac{1}{2}\, |(\mathbf{p}_2 - \mathbf{p}_1) \times (\mathbf{p}_3 - \mathbf{p}_1)|$$

### Tetrahedral volume

Combining the cross product with the dot product gives the volume of a tetrahedron with edge vectors $\mathbf{a}$, $\mathbf{b}$, $\mathbf{c}$ emanating from one vertex:

$$V_{\text{tet}} = \tfrac{1}{6}\, (\mathbf{a} \times \mathbf{b}) \cdot \mathbf{c}$$

Why? The cross product $\mathbf{a} \times \mathbf{b}$ has magnitude equal to the base parallelogram's area. The dot product with $\mathbf{c}$ projects $\mathbf{c}$ onto the normal of that base, yielding the parallelepiped's height. Together they give the parallelepiped volume; the tetrahedron is one-sixth of that. This formula comes up repeatedly in soft-body simulation, where preserving tetrahedral volumes is equivalent to preserving material incompressibility.

---

## Matrices and Transformations

A $3 \times 3$ matrix $A$ transforms a vector $\mathbf{x}$ into a new vector $A\mathbf{x}$. The most illuminating way to read this product is column-wise:

$$A\mathbf{x} = x_1\, \mathbf{a}_1 + x_2\, \mathbf{a}_2 + x_3\, \mathbf{a}_3$$

where $\mathbf{a}_1, \mathbf{a}_2, \mathbf{a}_3$ are the columns of $A$. The result is a linear combination of the columns, weighted by the components of $\mathbf{x}$. Read this way, the matrix is simply **a new coordinate frame**: $\mathbf{a}_1$ is where the $x$-axis lands after the transformation, $\mathbf{a}_2$ is where the $y$-axis lands, and so on.

An **affine transformation** adds a translation offset $\mathbf{b}$:

$$\mathbf{v}' = A\mathbf{v} + \mathbf{b}$$

Geometrically, this maps the origin to $\mathbf{b}$ and stretches, shears, or rotates along the axes defined by the columns of $A$.

### The determinant as volume

$$\det(A) = (\mathbf{a}_1 \times \mathbf{a}_2) \cdot \mathbf{a}_3$$

This is exactly the volume of the parallelepiped formed by the three column vectors — in other words, how the transformation scales volume. When $\det(A) = 1$ the transformation is volume-preserving; when $\det(A) = 0$ the three axes are coplanar, the transformation collapses 3D space into a plane or line, and no inverse exists.

### Transpose and the dot product

The **transpose** $A^T$ exchanges rows and columns. For vectors, transposing turns a column into a row, and the product $\mathbf{a}^T \mathbf{b}$ is identical to the dot product $\mathbf{a} \cdot \mathbf{b}$. In particular:

$$\mathbf{a}^T \mathbf{a} = |\mathbf{a}|^2$$

### Inverses

The inverse $A^{-1}$ undoes the transformation: $A^{-1} A = I$. For an affine transform with offset $\mathbf{b}$, inverting requires removing the offset first:

$$\mathbf{v} = A^{-1}(\mathbf{v}' - \mathbf{b})$$

A practical application is **tetrahedral skinning**: mapping a point in a rest-pose tetrahedron $Q$ to its position in the deformed tetrahedron $P$:

$$\mathbf{x}' = PQ^{-1}\mathbf{x} + (\mathbf{p} - PQ^{-1}\mathbf{q})$$

where $Q$ is the $3 \times 3$ matrix whose columns are the edge vectors of the rest tetrahedron, and $P$ likewise for the deformed tetrahedron. This affine map lets a visual surface mesh follow a coarser tetrahedral simulation mesh — the foundation of soft-body rendering.

---

## Rotation Matrices and Quaternions

### Rotation matrices

A rotation is a special case of a linear transformation that preserves lengths and orientations. Its columns are mutually orthogonal unit vectors:

$$\mathbf{r}_i \cdot \mathbf{r}_j = 0 \text{ for } i \neq j, \qquad |\mathbf{r}_i| = 1$$

These two conditions together mean $R^T R = I$, which gives an extraordinarily useful identity: for a rotation matrix, **the inverse is the transpose**:

$$R^{-1} = R^T$$

This identity is essentially free to compute — transposing a matrix costs nothing — and it sidesteps the general matrix inversion formula entirely.

A related observation: the quantity $F^T F - I$ measures how far a deformation $F$ deviates from a rigid transformation. For any rotation $R$, this expression is exactly zero. Soft-body and cloth simulations often define an elastic energy as a function of $F^T F - I$, so that a purely rigid motion contributes no energy.

### Axis-angle representation

Every rotation in 3D can be described by a unit axis $\hat{\mathbf{n}}$ and an angle $\alpha$. A unit vector has two independent degrees of freedom and the angle contributes one more, giving three in total — the correct count for 3D rotations. If we stored a rotation as a matrix, we would need nine numbers for just three degrees of freedom, with six redundant constraints to maintain orthonormality.

One natural compact form is a vector $\mathbf{r} = \alpha\, \hat{\mathbf{n}}$, storing only three numbers. The problem is that applying such a rotation requires computing $\cos\alpha$ and $\sin\alpha$, which are expensive. We know $\alpha = |\mathbf{r}|$, so we need $\cos(|\mathbf{r}|)$ — not cheap.

### Quaternions

A **quaternion** avoids this cost by precomputing the trigonometric values at storage time:

$$\mathbf{q} = \begin{bmatrix} \sin(\alpha)\, \hat{n}_x \\ \sin(\alpha)\, \hat{n}_y \\ \sin(\alpha)\, \hat{n}_z \\ \cos(\alpha) \end{bmatrix}$$

Four numbers: three for the scaled axis, one for the cosine of the angle. This is not merely a storage trick — quaternions form an algebra in which:

- **Applying** a rotation to a vector is a direct formula involving $\mathbf{q}$.
- **Composing** two rotations is quaternion multiplication, faster than multiplying two $3 \times 3$ matrices.
- **Inverting** a rotation requires only negating the first three components (since $\sin(-\alpha) = -\sin(\alpha)$ while $\cos(-\alpha) = \cos(\alpha)$).

Quaternions also interpolate smoothly between orientations, which makes them the standard representation for rigid-body orientation in real-time simulation. In practice, use a well-tested library for quaternion arithmetic; the formulas are straightforward but sign errors are easy to introduce.

---

## Key Takeaways

- **Vectors** serve as both positions and directions. Subtraction gives the arrow from $\mathbf{a}$ to $\mathbf{b}$ as $\mathbf{b} - \mathbf{a}$.

- **The dot product** measures projection. A zero dot product means perpendicularity. Decomposing a vector into normal and tangential components — the basis of all collision response — takes two lines.

- **The cross product** builds a perpendicular vector and encodes area. Triangle normals, surface areas, and tetrahedral volumes all follow from it.

- **Matrix columns are coordinate axes.** Reading matrix-vector multiplication as a weighted sum of columns reveals the geometric meaning instantly. The determinant measures volume scaling.

- **Rotation matrices satisfy $R^T = R^{-1}$.** This makes undoing a rotation trivially cheap.

- **Quaternions store $(\sin\alpha\, \hat{\mathbf{n}},\, \cos\alpha)$.** Four numbers represent any 3D rotation, compose efficiently, and invert by a sign flip. They are the standard rotation representation for physics simulation.
