/ Energy-based numeric solver (value iteration / relaxation)
/ E(x,y) = 0 at boundary
/ E(x,y) = 1 + 0.25*(E(n)+E(s)+E(e)+E(w)) at interior

N: 10
M: N-1
E: (N*N)#0.0

row: {-N!x}
col: {N!x}

cell: {[e;i]
  r: row i
  c: col i
  a: r*c
  b: (M-r)*(M-c)
  nb: (e@i-N)+(e@i+N)
  sc: (e@i-1)+(e@i+1)
  :[a*b; 1.0+0.25*(nb+sc); 0.0]
}

step: {[e] cell[e;]'!N*N}
result: step/E
10 10 # result
result@55
