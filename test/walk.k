/ https://www.youtube.com/shorts/c8lDKs2vb6A

/ Start at the center of a 10 by 10 grid, every second you flip a coin twice,
/ for HH move north, TT move south, HT move east, TH move west.
/ How long on avarage does it take to get to the boundry of the grid?

direction:(0 1;0 -1;1 0;-1 0)
bounds:{&/(0<x)&x<9}
wander:{x+*1?direction}
steps:{# bounds wander\5 5}
avg:{(+/x)%#x}
walk1:{avg[steps@'!10000]}
\t walk1[]

/ Energy-based numeric solver (value iteration / relaxation)
/ E(x,y) = 0 at boundary 
/ E(x,y) = 1 + 0.25*(eN+eS+eE+eW) at interior

N:100;h: N div 2
(r;c):1+!2#N-2;I:c+N*r
W:((-N),N,1,-1)+/:I
f:{@[x;I;:;1.+.25*+/x@W]}
\t m:(f/(N*N)#0.0)@h+N*h
m

/ Up-down & left-right symmetry (4-fold): Q×Q quadrant, ~N^2/4 cells
/ Full N=7 grid — each cell labelled with its quadrant flat index:
/      0   1   2   3   4   5   6
/  0   B   B   B   B   B   B   B
/  1   B  10   9   8   9  10   B
/  2   B   6   5   4   5   6   B
/  3   B   2   1   0   1   2   B  ← center = flat index 0
/  4   B   6   5   4   5   6   B
/  5   B  10   9   8   9  10   B
/  6   B   B   B   B   B   B   B
/
/       c'=0  c'=1  c'=2  c'=3(B)
/  r'=0  [0]   [1]   [2]   B       ← center row (axis)
/  r'=1  [4]   [5]   [6]   B
/  r'=2  [8]   [9]  [10]   B
/  r'=3  [B]   [B]   [B]   B       ← actual grid boundary

Q:N-h;sm:N-2*h
(r;c):!Q,Q;all:c+Q*r
P:&(~r=r|Q-1)*(~c=c|Q-1)
(ri;ci):(r@P;c@P)
nr:((ri=0)*sm)|ri-1
wc:((ci=0)*sm)|ci-1
WQ:(ci+nr*Q;ci+(ri+1)*Q;ci+1+ri*Q;wc+ri*Q)
g:{@[x;P;:;1.+.25*+/x@WQ]}
\t E:g/(Q*Q)#0.
E 0

/ Full D4 symmetry (8-fold): right-isoceles fundamental triangle ~N^2/8 cells
/ Quadrant (above) + diagonal E(r,c)=E(c,r)

/ Full N=7 grid — each interior cell labelled with which fundamental-domain cell holds its value:
/     0  1  2  3  4  5  6
/ 0   B  B  B  B  B  B  B
/ 1   B  5  4  2  4  5  B
/ 2   B  4  3  1  3  4  B
/ 3   B  2  1  0  1  2  B  ← center row h=3
/ 4   B  4  3  1  3  4  B
/ 5   B  5  4  2  4  5  B
/ 6   B  B  B  B  B  B  B
/              ↑
/       center col h=3
/ 
/       c'=0  c'=1  c'=2  c'=3
/ r'=0  [T0]  [T1]  [T2]  [B]
/ r'=1  [ × ] [T3]  [T4]  [B]
/ r'=2  [ × ] [ × ] [T5]  [B]
/ r'=3  [ B ] [ B ] [ B ] [B]

Q:N-h;sm:N-2*h
(r;c):!Q,Q;all:c+Q*r
sw:~c=c|r;
K:all+sw*(((c-r)*Q)+r-c) / canonicalisation table: for every flat index in the Q×Q array, K[i] gives the flat index of its canonical representative (the one with r′≤c′).
T:&(c=c|r)*(~r=r|Q-1)*(~c=c|Q-1) /  indices of the fundamental domain interior cells
(ri;ci):(r@T;c@T)
(nr;wc):(((ri=0)*sm)|ri-1;((ci=0)*sm)|ci-1)
NN:(K@ci+nr*Q;K@ci+(ri+1)*Q;ci+1+ri*Q;K@wc+ri*Q)
KT:{@[x;T;:;1.+.25*+/x@NN]}
\t E: KT/(Q*Q)#0.
E 0
