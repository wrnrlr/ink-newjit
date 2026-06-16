# Chapter 7 — 3D Vector Math for Simulation

Every physics simulation that runs in three dimensions rests on the same compact set of mathematical tools. Vectors describe where things are and how fast they move. The dot product measures alignment. The cross product builds perpendiculars and counts area. Matrices encode coordinate changes and deformations, and quaternions represent orientations without the pitfalls of Euler angles. This chapter develops each of these tools from first principles, with emphasis on the geometric pictures that make them useful in practice.

---

## Vectors in 3D Space

A **3D vector** $\mathbf{v}$ packs three real numbers into a column:

$$\mathbf{v} = \begin{bmatrix} v_x \\ v_y \\ v_z \end{bmatrix}$$

In ink, a 3D vector is a 3-element float list: `1.0 2.0 3.0`. A vector serves two distinct roles in simulation. It can represent a **position** — where a particle sits in space — or an **arrow** — a direction and magnitude, such as a velocity or a force. The same mathematical object handles both; only interpretation differs.

We work in a **right-handed coordinate system**: point the thumb of the right hand along $x$, the index finger along $y$, and the middle finger naturally extends along $z$. In ink's GPU rendering, $y$ points upward, matching the typical physics convention.

### Basic Operations

All standard vector operations are element-wise on ink's float lists:

```k
/ 3D vector operations
vadd: {x + y}              / addition
vsub: {x - y}              / subtraction
vscale: {x * y}            / scalar scaling (y is a scalar)
```

**Addition** advances a position by an offset — the core of every time-integration step.

**Length** follows from the Pythagorean theorem:

$$|\mathbf{v}| = \sqrt{v_x^2 + v_y^2 + v_z^2}$$

```k
vlen: {sqrt +/ x*x}      / sum of squares via fold, then sqrt
```

The `+/ x*x` idiom folds addition over the element-wise square, sidesteps the right-to-left operator precedence issue completely, and works for vectors of any length.

**Normalization** produces a unit vector:

```k
vnorm: {x % vlen x}
```

---

## The Dot Product

$$\mathbf{a} \cdot \mathbf{b} = a_x b_x + a_y b_y + a_z b_z$$

```k
dot3: {+/ x*y}             / sum of element-wise products
```

The dot product takes two vectors and returns a **scalar**. The key insight is that it measures **projection**: given a unit vector $\hat{\mathbf{n}}$ and any vector $\mathbf{v}$, the scalar $v_n = \hat{\mathbf{n}} \cdot \mathbf{v}$ is exactly the signed length of $\mathbf{v}$'s shadow cast along $\hat{\mathbf{n}}$.

Two immediate consequences:
- $\mathbf{a} \cdot \mathbf{b} = 0$ if and only if $\mathbf{a}$ and $\mathbf{b}$ are **perpendicular**.
- $\mathbf{v} \cdot \mathbf{v} = |\mathbf{v}|^2$, so squaring a length avoids a square root.

### Decomposing a Vector

Simulations frequently need to split a velocity into components parallel and perpendicular to a surface. Given the surface normal $\hat{\mathbf{n}}$:

$$\mathbf{v}_n = (\hat{\mathbf{n}} \cdot \mathbf{v})\, \hat{\mathbf{n}} \qquad \text{(normal component)}$$
$$\mathbf{v}_t = \mathbf{v} - \mathbf{v}_n \qquad \text{(tangential component)}$$

```k
/ Decompose velocity v into normal and tangential components
/ n must be a unit vector
vnormal: {[v;n] (dot3[v;n]) * n}
vtangent: {[v;n] v - vnormal[v;n]}
```

Restitution scales $\mathbf{v}_n$; friction attenuates $\mathbf{v}_t$. Every collision response in this book runs through this two-line decomposition.

---

## The Cross Product

$$\mathbf{a} \times \mathbf{b} = \begin{bmatrix} a_y b_z - b_y a_z \\ a_z b_x - b_z a_x \\ a_x b_y - b_x a_y \end{bmatrix}$$

```k
cross3: {[a;b]
  (((a@1)*(b@2))-(b@1)*(a@2)
   ((a@2)*(b@0))-(b@2)*(a@0)
   ((a@0)*(b@1))-(b@0)*(a@1))
}
```

**Parenthesization note:** In ink, all operators share equal precedence and evaluate right-to-left. In `A*B - C*D`, the right-to-left rule gives `A*(B - C*D)`, which is wrong. The fix is to parenthesize the LEFT product: `(A*B) - C*D` evaluates the right side `C*D` first, then subtracts from the pre-computed `(A*B)`. Each element of `cross3` follows this `((left product)) - right product` pattern.

Unlike the dot product, the cross product returns a **vector** perpendicular to both $\mathbf{a}$ and $\mathbf{b}$, following the right-hand rule.

### Triangle Normals and Mesh Orientation

The cross product is the standard way to find a triangle's surface normal. Given vertices $\mathbf{p}_1, \mathbf{p}_2, \mathbf{p}_3$:

```k
triNormal: {[p1;p2;p3]
  vnorm cross3[p2-p1; p3-p1]
}
```

### Area from the Cross Product

The length of $\mathbf{a} \times \mathbf{b}$ equals the area of the parallelogram spanned by $\mathbf{a}$ and $\mathbf{b}$. A triangle is half a parallelogram:

$$A_{\text{triangle}} = \tfrac{1}{2}\, |(\mathbf{p}_2 - \mathbf{p}_1) \times (\mathbf{p}_3 - \mathbf{p}_1)|$$

```k
triArea: {[p1;p2;p3] 0.5 * vlen cross3[p2-p1; p3-p1]}
```

### Tetrahedral Volume

Combining the cross product with the dot product gives the volume of a tetrahedron with edge vectors $\mathbf{a}$, $\mathbf{b}$, $\mathbf{c}$ emanating from one vertex:

$$V_{\text{tet}} = \tfrac{1}{6}\, (\mathbf{a} \times \mathbf{b}) \cdot \mathbf{c}$$

```k
tetVol: {[p1;p2;p3;p4]
  (dot3[cross3[p2-p1; p3-p1]; p4-p1]) % 6.
}
```

This formula comes up repeatedly in soft-body simulation, where preserving tetrahedral volumes is equivalent to preserving material incompressibility.

---

## Matrices and Transformations

A $3 \times 3$ matrix $A$ transforms a vector $\mathbf{x}$ into a new vector $A\mathbf{x}$. In ink, a matrix is a list of column vectors or a flat array of 9 floats. The most illuminating way to read the matrix-vector product is column-wise:

$$A\mathbf{x} = x_1\, \mathbf{a}_1 + x_2\, \mathbf{a}_2 + x_3\, \mathbf{a}_3$$

The matrix is simply a new coordinate frame: $\mathbf{a}_1$ is where the $x$-axis lands after the transformation.

```k
/ 3×3 matrix-vector multiply: M is a 3-element list of column 3-vectors
mat3x3vec: {[M;v]
  ((M@0)*(v@0)) + ((M@1)*(v@1)) + (M@2)*(v@2)
}

/ 3×3 matrix-matrix multiply: apply mat3x3vec to each column of B
mat3x3: {[A;B]
  {mat3x3vec[A;x]} each B
}
```

The extra parentheses around `((M@0)*(v@0))` and `((M@1)*(v@1))` are required. Without them, the right-to-left rule evaluates `(M@0) * ((v@0) + (M@1)*(...))`, which scales the first column by an incorrect combined scalar rather than by `v@0` alone.

### The Determinant as Volume

$$\det(A) = (\mathbf{a}_1 \times \mathbf{a}_2) \cdot \mathbf{a}_3$$

This is the volume of the parallelepiped formed by the three column vectors — how the transformation scales volume. When $\det(A) = 1$ the transformation is volume-preserving.

```k
det3x3: {[M] dot3[cross3[M@0;M@1];M@2]}
```

### Transpose and the Dot Product

The **transpose** $A^T$ exchanges rows and columns. For a rotation matrix, **the inverse is the transpose**: $R^{-1} = R^T$.

```k
/ Transpose of 3×3 matrix (list of column vectors)
trans3: {[M]
  ((M@0)@0,(M@1)@0,(M@2)@0
   (M@0)@1,(M@1)@1,(M@2)@1
   (M@0)@2,(M@1)@2,(M@2)@2)
}
```

### Tetrahedral Skinning

A practical application is mapping a point in a rest-pose tetrahedron $Q$ to its position in the deformed tetrahedron $P$:

$$\mathbf{x}' = PQ^{-1}\mathbf{x} + (\mathbf{p}_0 - PQ^{-1}\mathbf{q}_0)$$

where $Q$ is the $3 \times 3$ matrix whose columns are the edge vectors of the rest tetrahedron, and $P$ likewise for the deformed tetrahedron. In ink, $Q^{-1}$ can be computed using the SVD from `lib/svd.k` or the PLU solver from `lib/lin.k`.

---

## Rotation Matrices and Quaternions

### Rotation Matrices

A rotation is a special linear transformation that preserves lengths and orientations. Its columns are mutually orthogonal unit vectors:

$$R^T R = I \implies R^{-1} = R^T$$

The quantity $F^T F - I$ measures how far a deformation $F$ deviates from a rigid transformation. For any rotation $R$, this expression is exactly zero.

### Axis-Angle Representation

Every rotation in 3D can be described by a unit axis $\hat{\mathbf{n}}$ and an angle $\alpha$. A unit vector has two independent degrees of freedom; the angle contributes one more — three in total.

### Quaternions

A **quaternion** avoids expensive trigonometric evaluation at application time by precomputing the values at storage time:

$$\mathbf{q} = \begin{bmatrix} \sin(\alpha)\, \hat{n}_x \\ \sin(\alpha)\, \hat{n}_y \\ \sin(\alpha)\, \hat{n}_z \\ \cos(\alpha) \end{bmatrix}$$

In ink, a quaternion is a 4-element float list `(qx; qy; qz; qw)`:

```k
/ Quaternion multiply: p ⊗ q  (index order: x y z w)
/ Each component: put all positives first, one negation last.
/ Extra parens on each product (except last) prevent right-to-left mis-association.
qmul: {[p;q]
  (((p@3)*(q@0)) + ((p@0)*(q@3)) + ((p@1)*(q@2)) - (p@2)*(q@1)
   ((p@3)*(q@1)) + ((p@1)*(q@3)) + ((p@2)*(q@0)) - (p@0)*(q@2)
   ((p@3)*(q@2)) + ((p@0)*(q@1)) + ((p@2)*(q@3)) - (p@1)*(q@0)
   ((p@3)*(q@3)) - (((p@0)*(q@0)) + ((p@1)*(q@1)) + (p@2)*(q@2)))
}

/ Conjugate of unit quaternion: negate vector part, keep scalar
qconj: {(-(x@0); -(x@1); -(x@2); x@3)}

/ Rotate vector v by quaternion q (sandwich product q v q*)
qrotate: {[q;v]
  p: v,0.
  r: qmul[q; qmul[p; qconj q]]
  3#r
}

/ Quaternion from axis-angle (axis must be unit vector)
qAxisAngle: {[axis;angle]
  s: sin 0.5*angle
  (s*axis@0; s*axis@1; s*axis@2; cos 0.5*angle)
}
```

The w-component of `qmul` uses `E1 - (E2 + E3 + E4)` rather than `E1 - E2 - E3 - E4`. In right-to-left k, `A - B - C - D` evaluates as `A - (B - (C - D)) = A - B + C - D`, which is wrong. Grouping all subtracted terms in a positive sum and subtracting the whole group gives the correct result.

Quaternions form an algebra in which:
- **Applying** a rotation to a vector is the sandwich product $q \mathbf{v} q^*$.
- **Composing** two rotations is quaternion multiplication, faster than multiplying two $3 \times 3$ matrices.
- **Inverting** a rotation requires only negating the first three components.

---

## Key Takeaways

- **Vectors** serve as both positions and directions. In ink, they are float lists; element-wise operations are built in.
- **The dot product** measures projection: `+/ x*y`. A zero dot product means perpendicularity.
- **The cross product** builds a perpendicular vector. Triangle normals, surface areas, and tetrahedral volumes all follow from `cross3`.
- **Matrix columns are coordinate axes.** `mat3x3vec` reads the transform as a weighted sum of columns.
- **Rotation matrices satisfy $R^T = R^{-1}$.** This makes undoing a rotation trivially cheap.
- **Quaternions** store $(\sin\alpha\, \hat{\mathbf{n}},\, \cos\alpha)$. Four numbers represent any 3D rotation, compose efficiently, and invert by a sign flip.
