/ Energy-based numeric solver (value iteration / relaxation)
/ E(x,y) = 0 at boundary
/ E(x,y) = 1 + 0.25*(E(n)+E(s)+E(e)+E(w)) at interior

N: 10
M: N-1
E: (N*N)#0.0

row: {x div N}
col: {x mod N}

cell: {
  r: x div N; c: x mod N;
  a: 1.0+0.25*(E c*r+1)+(E c*r-1)+(E r*c+1)+(E r*c-1)
  E:: @[E; r*c; :; a]
}

iter: {
  E:: @[E;]
}

cell 15

/ step: {[e] cell[e;]'!N*N}
/ result: step/E
/ 10 10 # result
/ result@55
