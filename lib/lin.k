/ PLU decomposition and linear system solver.
/
/ factor[A]     — factor square matrix A into (LU;P)
/ solve[LUP;b]  — solve Ax=b given factor output and right-hand side b
/
/ WHAT IS PLU FACTORIZATION?
/ Every square matrix A = P·L·U where:
/   P — permutation matrix (partial pivoting for numerical stability)
/   L — lower triangular, 1s on diagonal (implicit; multipliers stored below)
/   U — upper triangular (Gaussian elimination result; on and above diagonal)
/ P is a permutation vector: P[i] = original row index now at row i.
/
/ FORMAT: A is a list of row vectors (row-major), b is a flat float vector.
/ CONTRAST: svd.k (column-major, iterative Jacobi) suits rank-deficient or
/           overdetermined systems; LU is direct O(n³), best for square A.
/
/ kyte→ink translation notes:
/   kyte `while[cond;body]`    → N-do `n f/init` carrying step index in state
/   kyte `A[k;i]` (column i)  → `(+(A@k))@i`  (transpose, then index)
/   kyte in-place `%:` `-:`   → global helpers with full state (no closures in ink)
/   kyte heterogeneous folds   → N-do avoids mixed-type fold list issues

/ ── helpers (all global — ink lambdas don't close over parent locals) ─────────

/ Divide element at column `col` of row `k1[j]` by `piv`. State: (A;col;piv;k1;j).
luDivRow:{[st]
  A:st@0;col:st@1;piv:st@2;k1:st@3;j:st@4
  r:k1@j
  (@[A;r;:;@[A@r;col;%;piv]];col;piv;k1;1+j)
}

/ Rank-1 update row cols[j]: A[r;cols] -= A[r;col]*pivrow. State: (A;col;cols;pivrow;j).
luUpdateRow:{[st]
  A:st@0;col:st@1;cols:st@2;pivrow:st@3;j:st@4
  r:cols@j
  mult:(A@r)@col
  (@[A;r;:;@[A@r;cols;-;mult*pivrow]];col;cols;pivrow;1+j)
}

/ One Gaussian elimination step at pivot column i. State: (A;P;i).
luStep:{[st]
  A:st@0;P:st@1;i:st@2
  n:#A
  k:i+!n-i                         / rows i..n-1 (pivot search range)
  k1:(1+i)+!n-(1+i)                / rows i+1..n-1 (sub-diagonal rows to update)
  / partial pivot: find row with max |A[r;i]| among rows k
  ci:(+(A@k))@i                    / column i of remaining submatrix via transpose
  a:abs ci
  m:|/a
  j:i+*&a=m                        / actual row index of max-|element|
  / swap rows i and j in A and P (no-op when j=i)
  ri:A@i;rj:A@j;A:@[@[A;i;:;rj];j;:;ri]
  pi:P@i;pj:P@j;P:@[@[P;i;:;pj];j;:;pi]
  / store L multipliers: A[k1;i] /= A[i;i]
  piv:(A@i)@i
  st2:(#k1) luDivRow/(A;i;piv;k1;0)
  A:st2@0
  / Gaussian elimination: A[k1;k1] -= A[k1;i] ×outer A[i;k1]
  pivrow:(A@i)@k1
  st3:(#k1) luUpdateRow/(A;i;k1;pivrow;0)
  A:st3@0
  (A;P;1+i)
}

/ ── public API ────────────────────────────────────────────────────────────────

/ factor[A] — PLU decomposition of square matrix A (list of float row vectors).
/ Returns (LU;P). Pass directly to solve[] or inspect LU for the L/U factors.
/ Ex: (LU;P):factor((2.;1.;-1.);(-3.;-1.;2.);(-2.;1.;2.))
factor:{[A]
  n:#A
  st:(n-1) luStep/(A;!n;0)
  (st@0;st@1)
}

/ Forward substitution: solve L x = b (L has implicit 1s on diagonal). State: (x;A;i).
solveL:{[st]
  x:st@0;A:st@1;i:st@2
  k:!i
  dot:$[0=#k;0.;+/((A@i)@k)*x@k]
  xi:(x@i)-dot
  (@[x;i;:;xi];A;1+i)
}

/ Backward substitution: solve U x = b. State: (x;A;j) where i = (n-1)-j.
solveU:{[st]
  x:st@0;A:st@1;j:st@2
  n:#x
  i:(n-1)-j
  k:(1+i)+!n-(1+i)
  dot:$[0=#k;0.;+/((A@i)@k)*x@k]
  xi:((x@i)-dot)%(A@i)@i
  (@[x;i;:;xi];A;1+j)
}

/ solve[LUP;b] — solve Ax=b given factor[] output (LU;P) and right-hand side b.
/ Ex: solve[factor((2.;1.;-1.);(-3.;-1.;2.);(-2.;1.;2.));(8.;-11.;-3.)]
/     → 2. 3. -1.
solve:{[LUP;b]
  A:LUP@0;P:LUP@1
  n:#A
  st1:n solveL/(b@P;A;0)
  st2:n solveU/(st1@0;A;0)
  st2@0
}
