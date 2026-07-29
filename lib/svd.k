/
# svd

Singular value decomposition by the Jacobi-Hestenes algorithm.

`A` is a list of COLUMN vectors, e.g. `A:(col0;col1;col2)`, and the result is
`(U; s; V)` sorted by decreasing singular value.  Real matrices only.

## What SVD is

Every matrix factors as `A = U · diag(s) · V'`, where `U` and `V` are orthogonal
(pure rotation/reflection; their columns are the left and right singular vectors)
and `s` is the non-negative vector of singular values.  Read it as "rotate to the
V-frame, scale by s, rotate to the U-frame" — the singular values measure how much
the matrix stretches space along each principal axis.

## How Jacobi here relates to walk.k

walk.k does Jacobi RELAXATION: set each cell to the average of its neighbours,
repeatedly, until the energy stabilises.  This does Jacobi ROTATIONS: apply 2×2
Givens rotations to pairs of columns, repeatedly, until every cross-product
vanishes.  Both are the same shape — a local two-element update iterated to
convergence — and a Givens rotation is exactly the 2×2 Jacobian step from
Newton's method, finding the angle that zeros one off-diagonal entry of `A'A`.

## Translating from kyte

```k
kyte `%x` (monadic sqrt)            / → ink `sqrt x`
kyte `f.list` (multi-arg apply)     / → ink `f[a;b;c]`, brackets required
kyte `[stmt;stmt;val]` inside $[;;] / → a helper (svdRot); ink has no blocks there
kyte complex conj/imag              / → dropped; real matrices only
kyte lambdas closing over scope     / → ink lambdas DO NOT; every helper is global
```

Pure k — loads on the first reference to any `svd.*` name.
\

/ ── global helpers (ink lambdas don't close over parent scope) ───────────────

/ inner product of two real column vectors: Σ xᵢyᵢ
svdD:{+/x*y}

/ Jacobi rotation parameters for column pair (x,y) with cross-product z = svdD[x;y].
/ q = cot(2θ): ratio of norm-difference to twice the overlap magnitude.
/ t = tan(θ): numerically stable form sign(q)/(|q|+√(1+q²)) — avoids cancellation.
/ Special case q=0 (equal column norms): sign(0)=0 gives t=0 (identity), but we need
/ t=1 (45° rotation) to actually zero the cross-product.
/ s gets a sign factor z/|z| so the rotation always makes svdD[new_x;new_y] → 0.
svdJ:{[x;y;z]
  a:abs z
  q:(svdD[y;y]-svdD[x;x])%2.*a
  t:$[0.=q;1.;((q>0)-(q<0))%(abs q)+sqrt 1+q*q]
  c:1%sqrt 1+t*t
  (c;(z%a)*t*c)
}

/ Apply Givens rotation (c,s) to column pair (x,y):
/   new_x = c*x - s*y    new_y = s*x + c*y
svdR:{[c;s;x;y]((x*c)-y*s;(x*s)+y*c)}

/ Update A and V at column indices ik by one Jacobi rotation.
/ Factored out of svdP because ink's $[;;] branches must be single expressions.
svdRot:{[A;V;ik;z]
  r:svdJ[A@ik@0;A@ik@1;z]
  nc:svdR[r@0;r@1;A@ik@0;A@ik@1]
  nA:@[@[A;ik@0;:;nc@0];ik@1;:;nc@1]
  nv:svdR[r@0;r@1;V@ik@0;V@ik@1]
  nV:@[@[V;ik@0;:;nv@0];ik@1;:;nv@1]
  (nA;nV)
}

/ One Jacobi step on state (A;V) for column pair ik.
/ Threshold 1e-6: f32 machine epsilon is ~1.19e-7; using 1e-14 (f64-era) would
/ never converge in f32 arithmetic, causing infinite iteration.
svdP:{[st;ik]
  A:st@0; V:st@1
  z:svdD[A@ik@0;A@ik@1]
  $[1e-6<abs z;svdRot[A;V;ik;z];st]
}

/ All unordered column pairs (i,k) with i<k — no nested lambdas needed.
/ For n=3: ((0;1);(0;2);(1;2)); for n=4: adds (0;3);(1;3);(2;3)
svdPairs:{[n]a:!n*n;r:a div n;c:a mod n;k:&r<c;+(r[k];c[k])}

/ One full sweep: fold svdP over (A;V) and every column pair.
/ Takes I as explicit first arg (ink lambdas can't close over parent locals).
svdSweep:{[I;st]svdP/(,st),I}

/ ── main function ────────────────────────────────────────────────────────────

svd:{[A]
  n:#A
  V:1.*(!n)=/:!n             / float identity: right-singular-vector accumulator
  I:svdPairs n               / all (i,k) pairs with i<k
  / n*n sweeps: converge adverb loops forever in f32 (cross-products oscillate
  / near 1e-6 threshold); n*n sweeps is the standard Jacobi convergence budget.
  st:(n*n)(svdSweep I)/(A;V)
  A2:st@0; V2:st@1
  s:{sqrt+/x*x}'A2           / singular values = column norms after orthogonalisation
  U:A2 {x%y}' s              / normalise columns → left singular vectors
  g:>s                       / sort indices descending
  (U@g;s@g;V2@g)
}

/ ── derived functions ────────────────────────────────────────────────────────

/ Condition number: ratio of largest to smallest singular value.
/ > 1 always; > 1e6 signals numerical ill-conditioning.
/ Ex: cond (1. 0.;0. 1.)   / identity → 1.0
cond:{s:(svd x)@1;(*s)%*|s}

/ svq: thin SVD via QR (faster for tall matrices: more rows than columns).
/ NOT TRANSLATED: requires qr function (not defined here).
/ svq:{q:qr x; ...}

/ ── verification helpers ─────────────────────────────────────────────────────

/ n×n identity matrix (list of column vectors).
/ Ex: eye 3  →  (1.0 0.0 0.0; 0.0 1.0 0.0; 0.0 0.0 1.0)
eye:{1.*(!x)=/:!x}

/ Diagonal matrix from vector v; col j = v[j]*eⱼ
/ Ex: dia 3. 1. 4.  →  diagonal columns
dia:{x*(!#x)=/:!#x}

/ Matrix multiply (A, B as lists of column vectors).
/ Uses /: (each-right) to fix A as left arg — avoids nested-closure issue.
/ In x {+/x{x*y}'y}/: B: outer x=A (fixed matrix), y=each column of B.
/ Ex: mmul[eye 3;eye 3]  →  identity
mmul:{[A;B]A {+/x{x*y}'y}/: B}

/ Max absolute value across all entries of a matrix (list of columns).
maxabs:{|/{|/abs x}'x}

/ ── examples ─────────────────────────────────────────────────────────────────
/ (paste into ink REPL or a .k file after loading this one)

/ Diagonal matrix — singular values should be the diagonal entries:
/ A:(3. 0.;0. 2.)
/ (svd A)@1   / → 3.0 2.0

/ Symmetric equal-norm matrix — exercises the q=0 special case:
/ A:(2. 1.;1. 2.)
/ (svd A)@1   / → ~3.0 ~1.0

/ Random 4×4 (use ?n for ink random floats, not n?1.):
/ n:4; A:{?n}'!n
/ (U;s;V):svd A
/ s         / singular values sorted descending
/ cond A    / condition number

/ Verify reconstruction A ≈ U*diag(s)*V' (should be ~1e-7 for f32):
/ maxabs mmul[U;mmul[dia s;+V]]-A

/ Verify U is orthogonal (U'U ≈ I) (should be ~1e-7 for f32):
/ maxabs mmul[+U;U]-eye@#U
