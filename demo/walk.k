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
W:((-N),N,1,-1)+\:I
f:{@[x;I;:;1.+.25*+/x@W]}
\t m:(f/(N*N)#0.0)@h+N*h
m

/ Red-black SOR: same Poisson solve, ~40x fewer sweeps than Jacobi.
/ Jacobi's convergence factor is ~0.9995, so f/ grinds ~21000 iterations to a
/ bit-fixpoint — and in f32 that fixpoint is biased ~0.14 low (2887.34 vs the
/ true 2887.48). Over-relaxing with w=2/(1+sin(pi/N)) on a checkerboard split
/ (reds read only blacks, blacks read only reds) converges in a few hundred
/ sweeps and lands on the correct value.
par:(r+c)mod 2                     / checkerboard colour of each interior cell
Ir:I@&par=0; Ib:I@&par=1           / red / black flat indices
off:(-N),N,1,-1                    / N,S,E,W offsets in the flat buffer
Wr:off+\:Ir; Wb:off+\:Ib          / 4 x #colour neighbour tables
w:1.939                            / optimal SOR factor 2/(1+sin(pi/N))
sweep:{
  vr:1.+.25*+/x@Wr;
  x:@[x;Ir;:;(x@Ir)+w*vr-x@Ir]   / relax reds off blacks
  vb:1.+.25*+/x@Wb;
  @[x;Ib;:;(x@Ib)+w*vb-x@Ib]}     / relax blacks off reds
\t S:(400 sweep/(N*N)#0.)@h+N*h
S

/ Full D4 symmetry (8-fold): right-isoceles fundamental triangle ~N^2/8 cells
/       c'=0  c'=1  c'=2  c'=3
/ r'=0  [T0]  [T1]  [T2]  [B]
/ r'=1  [ × ] [T3]  [T4]  [B]
/ r'=2  [ × ] [ × ] [T5]  [B]
/ r'=3  [ B ] [ B ] [ B ] [B]

Q:N-h;sm:N-2*h
(r;c):!Q,Q;all:c+Q*r;sw:~c=c|r;
K:all+sw*(((c-r)*Q)+r-c) / canonicalisation table: for every flat index in the Q×Q array, K[i] gives the flat index of its canonical representative (the one with r′≤c′).
T:&(c=c|r)*(~r=r|Q-1)*(~c=c|Q-1) /  indices of the fundamental domain interior cells
(ri;ci):(r@T;c@T)
(nr;wc):(((ri=0)*sm)|ri-1;((ci=0)*sm)|ci-1)
NN:(K@ci+nr*Q;K@ci+(ri+1)*Q;ci+1+ri*Q;K@wc+ri*Q)
KT:{@[x;T;:;1.+.25*+/x@NN]}
\t E: KT/(Q*Q)#0.
E 0

/ Red-black SOR on the folded domain — the fastest of the lot (fold x SOR).
/ The diagonal fold (r,c)->(c,r) preserves r+c parity, so a checkerboard split
/ survives it. The center-axis mirror does NOT: on an even-N grid it folds a
/ cell's north neighbour onto itself (E(50,c)=E(49,c) by symmetry), a self-loop
/ that can't be 2-coloured. Fold that self-term into the diagonal instead:
/ E_i*(1-.25*selfcount) = 1 + .25*(sum of non-self neighbours). Then reds read
/ only blacks again and it converges to the true value in ~400 sweeps on 2500
/ cells, ~35x faster than the Jacobi fixpoint above.
pard:(ri+ci)mod 2
rd:&pard=0; bk:&pard=1
Tr:T@rd; Tb:T@bk                       / red / black canonical flat indices
NNr:{x@rd}'NN; NNb:{x@bk}'NN          / 4 x #colour folded neighbour tables
scr:+/{x=Tr}'NNr; scb:+/{x=Tb}'NNb    / self-loop count per cell (0/1/2)
denr:1.-.25*scr; denb:1.-.25*scb       / diagonal after folding the self-term
w:1.939
sweepD:{[x]
  sr:+/x@NNr; tr:(1.+.25*sr-scr*x@Tr)%denr; x:@[x;Tr;:;(x@Tr)+w*tr-x@Tr]
  sb:+/x@NNb; tb:(1.+.25*sb-scb*x@Tb)%denb; @[x;Tb;:;(x@Tb)+w*tb-x@Tb]}
\t ES:400 sweepD/(Q*Q)#0.
ES 0
