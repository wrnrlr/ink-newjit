N: 100; E: (N*N)#0.0 / Energy-based numeric solver (value iteration / relaxation)
(r;c): 1+!2#N-2; I: c+N*r / E(x,y) = 0 at boundary 
W: ((-N),N,1,-1)+/:I      / E(x,y) = 1 + 0.25*(eN+eS+eE+eW) at interior
f: {@[x;I;:;1.+.25*+/x@W]}
h: N div 2
\t m:(f/E)@h+N*h
m
