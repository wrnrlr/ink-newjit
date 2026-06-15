/ lib/pga.k — Projective Geometric Algebra G(3,0,1)
/
/ Metric: e0²=0, e1²=e2²=e3²=1  (signature +++0, aka PGA or R3,0,1)
/ 16 basis blades ordered by grade then lexicographic:
/   i=0 : 1          (scalar)
/   i=1..4 : e0 e1 e2 e3   (vectors)
/   i=5..10: e01 e02 e03 e12 e13 e23  (bivectors)
/   i=11..14: e012 e013 e023 e123     (trivectors)
/   i=15: e0123      (pseudoscalar)
/
/ Load with: 2: "lib/pga.k"

/ ── Precomputed Cayley table (sign and blade index for all 16×16 products) ───────
/ Row i, column j at flat index i*16+j.
/ Signs are integers: 1, -1, or 0 (zero for products involving e0²=0 terms).
pgaGpS: 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 0 1 1 1 0 0 0 1 1 1 0 0 0 1 0 1 -1 1 1 1 -1 -1 -1 1 1 1 -1 -1 -1 1 -1 1 -1 -1 1 1 1 -1 -1 -1 -1 1 1 1 -1 -1 1 1 -1 -1 -1 1 1 1 -1 1 -1 -1 -1 1 1 1 -1 1 0 1 1 1 0 0 0 1 1 1 0 0 0 1 0 1 0 -1 1 1 0 0 0 -1 -1 1 0 0 0 -1 0 1 0 -1 -1 1 0 0 0 1 -1 -1 0 0 0 1 0 1 1 -1 1 1 -1 1 1 -1 -1 1 -1 -1 1 -1 -1 1 1 -1 -1 1 -1 -1 1 1 -1 -1 1 -1 -1 1 1 1 1 1 -1 1 1 -1 1 -1 1 -1 -1 1 -1 -1 -1 1 0 -1 1 1 0 0 0 -1 -1 1 0 0 0 -1 0 1 0 -1 -1 1 0 0 0 1 -1 -1 0 0 0 1 0 1 0 1 -1 1 0 0 0 -1 1 -1 0 0 0 -1 0 1 -1 1 -1 1 -1 1 -1 -1 1 -1 1 -1 1 -1 1 1 0 1 -1 1 0 0 0 -1 1 -1 0 0 0 -1 0

pgaGpB: 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 1 0 5 6 7 0 0 0 11 12 13 0 0 0 15 0 2 5 0 8 9 1 11 12 3 4 14 6 7 15 10 13 3 6 8 0 10 11 1 13 2 14 4 5 15 7 9 12 4 7 9 10 0 12 13 1 14 2 3 15 5 6 8 11 5 0 1 11 12 0 0 0 6 7 15 0 0 0 13 0 6 0 11 1 13 0 0 0 5 15 7 0 0 0 12 0 7 0 12 13 1 0 0 0 15 5 6 0 0 0 11 0 8 11 3 2 14 6 5 15 0 10 9 1 13 12 4 7 9 12 4 14 2 7 15 5 10 0 8 13 1 11 3 6 10 13 14 4 3 15 7 6 9 8 0 12 11 1 2 5 11 0 6 5 15 0 0 0 1 13 12 0 0 0 7 0 12 0 7 15 5 0 0 0 13 1 11 0 0 0 6 0 13 0 15 7 6 0 0 0 12 11 1 0 0 0 5 0 14 15 10 9 8 13 12 11 4 3 2 7 6 5 0 1 15 0 13 12 11 0 0 0 7 6 5 0 0 0 1 0

/ Grade of each basis blade (index → grade)
pgaGrd: 0 1 1 1 1 2 2 2 2 2 2 3 3 3 3 4

/ Dual (complement) map: drm[i] is the complement blade index of blade i,
/ drms[i] is its sign.  The dual swaps grade-k blades with grade-(4-k) blades.
pgaDrm:  15 14 13 12 11 10 9 8 7 6 5 4 3 2 1 0
pgaDrms: 1 1 -1 1 -1 1 -1 1 1 -1 1 1 -1 1 -1 1

/ ── Index arrays for all 256 (i,j) blade pairs ──────────────────────────────────
/ pgaAi[k] = row index, pgaBj[k] = column index, for k in 0..255
pgaAi: ,/ 16#' !16
pgaBj: 256#!16

/ ── Outer product filter (wedge ∧): keep only grade-increasing contributions ─────
/ A∧B blade (i,j) contributes iff grade(result) = grade(A_blade) + grade(B_blade)
pgaWedgeF: pgaGrd[pgaGpB] = pgaGrd[pgaAi]+pgaGrd[pgaBj]
pgaWedgeS: pgaGpS * pgaWedgeF

/ ── Left contraction filter (⌋): A⌋B — grade(result) = grade(B) - grade(A) ──────
pgaLDotF: (pgaGrd[pgaGpB] = pgaGrd[pgaBj]-pgaGrd[pgaAi]) & pgaGrd[pgaBj]>=pgaGrd[pgaAi]
pgaLDotS: pgaGpS * pgaLDotF

/ ── Reverse signs (flip sign of grade-2 and grade-3 blades) ─────────────────────
pgaRevS: 1 1 1 1 1 -1 -1 -1 -1 -1 -1 -1 -1 -1 -1 1

/ ── Products ────────────────────────────────────────────────────────────────────

/ Geometric product: a*b
pgaGP: {[a;b] @[16#0.0; pgaGpB; +; pgaGpS*a[pgaAi]*b[pgaBj]]}

/ Outer product (wedge ∧): a∧b — zero for grade-decreasing pairs
pgaWedge: {[a;b] @[16#0.0; pgaGpB; +; pgaWedgeS*a[pgaAi]*b[pgaBj]]}

/ Left contraction (⌋): a⌋b
pgaLDot: {[a;b] @[16#0.0; pgaGpB; +; pgaLDotS*a[pgaAi]*b[pgaBj]]}

/ Dual (complement): swap via drm/drms
pgaDual: {[a] pgaDrms*a[pgaDrm]}

/ Reverse: negate grade-2 and grade-3 components
pgaRev: {[a] pgaRevS*a}

/ Regressive product (vee ∨): a∨b = dual(dual(a)∧dual(b))
pgaVee: {[a;b] pgaDual[pgaWedge[pgaDual[a];pgaDual[b]]]}

/ Sandwich product B>>>A = B*A*rev(B) (applies motor/rotor B to element A)
pgaSandwich: {[b;a] pgaGP[pgaGP[b;a];pgaRev[b]]}

/ ── Element constructors ────────────────────────────────────────────────────────

/ Plane π: n·x + d = 0  where n=(a,b,c) is normal, d is signed distance
/ Representation: a·e1 + b·e2 + c·e3 + d·e0
/ Blade indices: e0=1, e1=2, e2=3, e3=4
pgaPlane: {[a;b;c;d] @[16#0.0; 2 3 4 1; :; (a;b;c;d)]}

/ Ideal point (direction): x·e23 - y·e13 + z·e12  (grade-2, no e0 factor)
/ Blade indices: e12=8, e13=9, e23=10
pgaIdealPt: {[x;y;z] @[16#0.0; 10 9 8; :; (x;0.0-y;z)]}

/ Euclidean point P=(x,y,z): x·e032 + y·e013 + z·e021 + w·e123
/ e032=-e023, e021=-e012  so: -x·e023 + y·e013 - z·e012 + w·e123
/ Blade indices: e012=11, e013=12, e023=13, e123=14
pgaPoint: {[x;y;z] @[16#0.0; 13 12 11 14; :; ((0.0-x);y;(0.0-z);1.0)]}

/ Line through two points A and B: pgaVee[pgaPoint[...]; pgaPoint[...]]
/ (or wedge of a point and a direction)
