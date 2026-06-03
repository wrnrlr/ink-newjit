/ Energy-based solver - Full D4 symmetry (8-fold reduction)
/ E=0 on boundary; E=1+0.25*(N+S+E+W) at interior
/
/ All 8 symmetries of the square (D4): two mirror axes (quadrant) plus
/ diagonal E(r,c)=E(c,r) reduce the domain to a right-isoceles triangle.
/ ~N^2/8 interior cells. Axes are between cells for even N, through cells
/ for odd N — both handled by the same sym=N-2*half formula.

N: 100
half: N div 2
qN:  N - half        / ceil(N/2)
sym: N - 2*half      / 0 for even N, 1 for odd N

all: !qN*qN
r:   all div qN
c:   all mod qN

/ Diagonal canonicalization: map (r,c) with r>c to (c,r).
/ swap=1 where r>c (c is not the max of c and r)
swap:  ~c=c|r
canon: all + swap*(((c-r)*qN)+(r-c))

/ Fundamental domain interior: r<=c (below diagonal), not at boundary
tri: &(c=c|r)*(~r=r|qN-1)*(~c=c|qN-1)

/ Rows and cols of fundamental domain interior cells
rti: r@tri
cti: c@tri

/ Pre-compute canonical neighbor flat indices for fundamental domain cells.
/ North/west: quadrant-reflect at axis, then diagonal-canonicalize.
/ South:      may cross diagonal for diagonal cells (r=c) -> canonicalize.
/ East:       always stays in fundamental domain (rti<=cti<cti+1).
nrti: ((rti=0)*sym)|rti-1
wcti: ((cti=0)*sym)|cti-1

ni: canon @ (cti + nrti*qN)
si: canon @ (cti + (rti+1)*qN)
ei: cti+1+rti*qN
wi: canon @ (wcti + rti*qN)

E:    (qN*qN)#0.0
step: {@[x;tri;:;1.0+0.25*((x@ni)+(x@si)+(x@ei)+(x@wi))]}
\t result: step/E
result@0
