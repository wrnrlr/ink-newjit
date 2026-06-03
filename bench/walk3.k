/ Energy-based numeric solver - Gauss-Seidel (row-by-row sweep)
/ E(x,y) = 0 at boundary
/ E(x,y) = 1 + 0.25*(E(n)+E(s)+E(e)+E(w)) at interior
/
/ Difference from Jacobi (solve_ink.k): each row immediately uses the
/ freshly-updated row above, so values propagate north->south within one
/ sweep -> fewer iterations to converge.
/
/ Note: named f/list is converge in ink, not fold.
/ Seeded fold requires inline lambda: seed {lambda}/list

N: 10
irows: 1+!(N-2)   / interior row indices: 1..N-2

E: (N*N)#0.0

/ One Gauss-Seidel sweep: seeded fold an inline lambda over interior rows.
/ x (outer) = seed E; inside lambda: x = accumulator E, y = row index.
step: {
  x {
    flat: (y*N)+1+!(N-2)
    new: 1.0+0.25*((x@flat-N)+(x@flat+N)+(x@flat+1)+(x@flat-1))
    @[x;flat;:;new]
  }/irows
}

\t result: step/E
half: N div 2
result@half+half*N
