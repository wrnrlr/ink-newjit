/ Energy-based solver - Quadrant symmetry (4-fold reduction)
/ E=0 on boundary; E=1+0.25*(N+S+E+W) at interior
/
/ Left-right and up-down symmetry reduce N×N to ceil(N/2)×ceil(N/2).
/ Works for both even and odd N:
/   sym=0 (even N): axis cell's reflected neighbor = itself
/   sym=1 (odd N):  axis cell's reflected neighbor = row/col 1

N: 100
half: N div 2
qN:  N - half        / ceil(N/2): quadrant edge length
sym: N - 2*half      / 0 for even N, 1 for odd N

all: !qN*qN
r:   all div qN
c:   all mod qN

/ Interior cells (not at actual grid boundary row/col = qN-1)
interior: &(~r=r|qN-1)*(~c=c|qN-1)

/ Rows and cols of interior cells only (avoids out-of-bounds on E@si etc.)
ri: r@interior
ci: c@interior

/ North/west reflected neighbor rows/cols for interior cells.
/ Note: _ is an operator in k so variable names avoid it.
/ max formula: ((ri=0)*sym)|ri-1 = sym for ri=0, ri-1 for ri>0
nri: ((ri=0)*sym)|ri-1
wci: ((ci=0)*sym)|ci-1

/ Pre-compute flat neighbor indices for interior cells only
ni: ci + nri*qN
si: ci + (ri+1)*qN
ei: ci+1+ri*qN
wi: wci + ri*qN

E:    (qN*qN)#0.0
step: {@[x;interior;:;1.0+0.25*((x@ni)+(x@si)+(x@ei)+(x@wi))]}
\t result: step/E
result@0
