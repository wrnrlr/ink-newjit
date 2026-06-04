/ https://www.youtube.com/shorts/c8lDKs2vb6A

/ Start at the center of a 10 by 10 grid, every second you flip a coin twice,
/ for HH move north, TT move south, HT move east, TH move west.
/ How long on avarage does it take to get to the boundry of the grid?

direction: (0 1;0 -1;1 0;-1 0)
bounds: {&/(0<x)&x<9}
wander: {x+*1?direction}
steps: {# bounds wander\5 5}
avg: {(+/x)%#x}
avg[steps@'!100000]

/ Energy-based numeric solver (value iteration / relaxation)
/ E(x,y) = 0 at boundary 
/ E(x,y) = 1 + 0.25*(eN+eS+eE+eW) at interior

N: 10; h: N div 2
(r;c): 1+!2#N-2; I: c+N*r
W: ((-N),N,1,-1)+/:I
f: {@[x;I;:;1.+.25*+/x@W]}
m: (f/(N*N)#0.0)@h+N*h
m
 
/ Full D4 symmetry (8-fold): right-isoceles fundamental triangle ~N^2/8 cells
/ Quadrant (up-down & left-right reflection) + diagonal E(r,c)=E(c,r)
Q: N-h; sm: N-2*h
(r;c): !Q,Q; all: c+Q*r
sw: ~c=c|r;
K: all+sw*(((c-r)*Q)+r-c)
T: & (c=c|r) * (~r=r|Q-1) * (~c=c|Q-1)
(ri;ci): (r@T; c@T)
(nr;wc): (((ri=0)*sm)|ri-1; ((ci=0)*sm)|ci-1)
NN: (K@ci+nr*Q;K@ci+(ri+1)*Q;ci+1+ri*Q;K@wc+ri*Q)
E: {@[x;T;:;1.+.25*+/x@NN]}/(Q*Q)#0.0
E 0
#E
