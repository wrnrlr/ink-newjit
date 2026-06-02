/ Energy-based numeric solver (value iteration / relaxation)
/ E(x,y) = 0 at boundary
/ E(x,y) = 1 + 0.25*(E(n)+E(s)+E(e)+E(w)) at interior

N: 10

/ Pre-compute neighbor index tables for all interior cells.
/ This is the "pre-baked index" idea: like a morton code, we collapse
/ 2D neighbor arithmetic into 4 flat index arrays computed once upfront.
all: !N*N
r: all div N
c: all mod N
interior: &~((r=0)|(r=N-1)|(c=0)|(c=N-1))
ni: interior-N   / north: row-1
si: interior+N   / south: row+1
ei: interior+1   / east:  col+1
wi: interior-1   / west:  col-1

/ Initialize E; boundary stays 0 throughout
E: (N*N)#0.0

/ One Jacobi relaxation: all interior cells updated simultaneously from
/ the 4 pre-baked neighbor index arrays. No 2D indexing at step time.
step: {@[x;interior;:;1.0+0.25*((x@ni)+(x@si)+(x@ei)+(x@wi))]}

/ Converge adverb: iterate step until the array stops changing
\t result: step/E

/ Center of N×N grid: row=col=N div 2, flat index = half + half*N
/ (half*N evaluated first right-to-left, then +half)
half: N div 2
result@half+half*N
