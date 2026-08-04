/
# geometry

Generates the uniform polyhedra from Coxeter groups by Wythoff construction.

```k
1 0 0 regular {p,q}   0 0 1 dual {q,p}   0 1 0 rectified
1 1 0 truncated       1 0 1 cantellated  1 1 1 omnitruncated
```

So (p,q; t₀ t₁ t₂) is a 5-integer address for a uniform polyhedron —
every Platonic AND Archimedean solid in these families.  See the fuller
walk-through and a V/E/F census in demo/geometry.k.

API:  wythoff[p;q;t] → vertices ;  group[mirrors[p;q]] → symmetry group
      adj V → boolean adjacency ;  faces adj V → triangular faces (index
      triples, for the deltahedra: tetra/octa/icosa).

Pure k — loads on the first reference to any `geometry.*` name.
\

PI: 3.14159265

/ ── vector / matrix helpers ───────────────────────────────────────────
/ NB: prelude math names (sqrt nrm …) are NOUNS — an op-glyph right after
/ one is dyadic, so `sqrt +/x*x` is a seeded fold.  Bracket: sqrt[…].
sqr:   {x*x}                            / (prelude `sqr is scalar/vector only — this broadcasts through matrices)
rnd:   {(_ 0.5+x*1e3)%1e3}              / snap to a 1e-3 grid → float-safe ~ match
nrm:   {x%sqrt[+/x*x]}                  / unit vector
cross: {((x[1]*y 2)-x[2]*y 1;(x[2]*y 0)-x[0]*y 2;(x[0]*y 1)-x[1]*y 0)}
cross3:{((x@1 2 0)*y@2 0 1)-(x@2 0 1)*y@1 2 0}
mm:    {x {+/x*y}/:\: +y}               / 3x3 · 3x3
id3:   (1. 0. 0.;0. 1. 0.;0. 0. 1.)
refl:  {y-(2*+/x*y)*x}                  / reflect point y in the mirror with unit normal x
rmat:  {id3-2*x*\:x}                    / the same reflection, as a matrix I - 2nnᵀ
det:   {+/x[0]*cross[x 1;x 2]}          / +1 for a rotation, -1 for a reflection

/ ── §1  the Coxeter diagram → three mirror normals ────────────────────
/ Unit normals with n₁·n₂ = -cos(π/p), n₂·n₃ = -cos(π/q), n₁·n₃ = 0.
mirrors: {[p;q]
  a:cos PI%p;s:sin PI%p;b:(-cos PI%q)%s
  ((1. 0. 0.); ((-a);s;0.); (0.;b;sqrt[1.-b*b]))}

/ Corner directions of the fundamental triangle (the reciprocal basis):
/ corner i is fixed by the *other* two mirrors — where the seed sits when
/ only ring i is lit.  A weighted sum lands the seed anywhere inside.
corners: {[N] (cross[N 1;N 2]; cross[N 2;N 0]; cross[N 0;N 1])}

/ ── §2  one breadth-first closure, used twice ────────────────────────
/ The symmetry group and the Wythoff orbit are the SAME algorithm: from a
/ seed, keep applying a fixed set of maps to the frontier until nothing
/ new appears.  Only two things vary — how the frontier is EXPANDED, and
/ how deep values are rounded for the dedup key — so both ride through the
/ loop state (lambdas don't capture parent scope, so they travel as data).
/ Values stay EXACT throughout; rounding is only the key — rounding the
/ elements feeds error back through the maps and the closure never settles.
/ The state is a `search`: a dict bundling the expansion rule, the dedup
/ key, the `seen` (explored) set and the `frontier` still to grow — the
/ textbook quadruple, the way a `particle` bundles position+velocity.
bfc.step: {[search]
  expand:   search`expand   / frontier → candidate elements
  key:      search`key      / dedup normaliser (how deep to round)
  seen:     search`seen     / everything found so far (explored set)
  frontier: search`frontier / the newest elements, still to grow
  cand: expand frontier
  ra:   key seen
  rc:   key cand
  k1:   ?rc
  k2:   k1@&(#ra)=ra?k1                  / keys not seen before
  nw:   cand@rc?k2                       / one exact representative each
  (expand:expand; key:key; seen:seen,nw; frontier:nw)}
bfc: {[expand;key;seed]                  / breadth-first closure
  search: (expand:expand; key:key; seen:,seed; frontier:,seed)
  ({0<#x`frontier}step/search)`seen}

/ §2a  the reflection group: expand = frontier · the 3 generator matrices.
/ group.expand[gens] is a PARTIAL carrying its generators, so `bfc` needs
/ no special-casing — just a different expander and a deeper round (rnd'').
group:        {[N] bfc[expand[rmat' N]; rnd''; id3]}
group.expand: {[G;fr] ,/ fr {mm[x;y]}/:\: G}

orbit:        {[N;seed] rnd' bfc[expand[N]; rnd'; seed]}
orbit.expand: {[N;fr] ,/ N {refl[x;y]}/:\: fr}

/ ── §3  Wythoff's construction: reflect the seed in every mirror ──────
/ Same closure, one-level round; orbit.expand[N] carries the mirror set.
wythoff:      {[p;q;t] N:mirrors[p;q]; orbit[N; nrm[+/ t*corners N]]}

/ ── §4  the 1-skeleton, from nothing but distance ────────────────────
/ Vertices come from the orbit; an edge is any vertex pair at the MINIMUM
/ nonzero distance; a triangular face is three mutually-adjacent vertices
/ (i<j<k).  This is Steinitz's viewpoint — the graph fixes the polyhedron.
adj:   {d: x {+/sqr x-y}/:\: x; m: &/,/{x@&x>1e-6}'d; 1e-3>sqr d-m}   / vertices → boolean adjacency
edges: {&,/ x&(!#x)<\:!#x}               / adjacency → flat upper-triangle positions
pairs: {[A] i:edges A; (i div #A),'i mod #A}                          / adjacency → (i;j) index pairs, i<j
faces: {[A] ,/ {[A;e] i:e 0; j:e 1; k:&(A i)&(A j)&(!#A)>j; e,/:k}[A]' pairs A}   / → triangular faces
