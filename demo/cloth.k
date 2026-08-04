/ test/cloth.k — XPBD cloth simulation with PBR rendering
/
/ 20×20 grid cloth pinned at two top corners, falling under gravity.
/
/ Particle state lives in one table `g` (px py pz vx vy vz), one row per particle.
/ Each constraint type (h/v/d/b) is its own edge table (i j l0 al w0 w1 wt).
/
/ Constraint solver: 4 sequential vectorized passes (h/v/d/b constraint types).
/ Each pass is a vectorized Jacobi step within one constraint type, and passes
/ are applied sequentially (Gauss-Seidel across types). This is stable because:
/ - Within each type, each particle appears at most twice → tridiagonal structure
/ - Tridiagonal Jacobi always converges for any correction magnitude
/ - Gauss-Seidel across types propagates corrections through the mesh
/
/ XPBD
/ while simulating
/   for all particle i
/     vi <- vi + Δt g
/     pi <- xi
/     xi <- xi + Δt vi
/   for all constraints C
/     solve(C,Δt)
/   for all particles i
/     vi <- (xi-pi)/Δt
/ 
/ Run: zig build gpu && ink test/cloth.k

2: "lib/dye.k"
2: "lib/gpu.k"
2: "lib/pbr.k"   / shared PBR renderer: PbrFragment (Cook-Torrance)

clothMat::0.18 0.28 0.62 0.75 1.                 / blue cloth: rgb + roughness + sun (lit)

vlen3:{sqrt[(sqr x)+(sqr y)+(sqr z)]}            / length from x;y;z component arrays
cross3:{((x@1 2 0)*y@2 0 1)-(x@2 0 1)*y@1 2 0}   / cross product of two 3-vectors
vnorm:{x%vlen3[x@0;x@1;x@2]|0.0001}              / normalise a packed 3-vector

nCols::20;nRows::20;n::nCols*nRows
nTris::2*(nRows-1)*nCols-1                       / two triangles per grid cell
gFrameDt::1.%60.;gNumSubsteps::15
gBendAlpha::1.0;gSdt::0.0

/ ── Grid: particle state as a table, one row per particle ─────────────────────
/ Flat 1×1 sheet in the xz-plane centred on the origin, held at y=1, at rest.
Grid:{[w;h]c:w*h;i:!c;
  px:((i mod w)%w-1)-.5;py:((i div w)%h-1)-.5
  ([]px:px;py:c#1.;pz:py;vx:c#0.;vy:c#0.;vz:c#0.)
}
g::Grid[nCols;nRows]

P:{[i] ((g`px)@i;(g`py)@i;(g`pz)@i)}     / particle i as a packed 3-vector

/ ── Triangles — flat index buffer (3*nTris ints), CCW winding → upward normals ─
/ Cell corners as vectors (rc@0;rc@1 = cell row;col from the odometer), then the
/ two triangles (i00,i11,i01) and (i00,i10,i11) interleaved and razed into one buffer.
rc:!(nRows-1;nCols-1)
i00:(nCols*rc@0)+rc@1                           / top-left particle of each cell
i01:i00+1; i10:i00+nCols; i11:i00+nCols+1       / top-right, bottom-left, bottom-right
triIds::,/+(i00;i11;i01;i00;i10;i11)

/ ── Inverse masses from triangle areas; pin the two top corners ───────────────
triArea:{[t]
  cr:cross3[(P t@1)-P t@0;(P t@2)-P t@0];
  0.5*vlen3[cr@0;cr@1;cr@2]}
tcol:+(nTris;3)#triIds                   / transpose buffer → (i0s;i1s;i2s) vertex streams
av:triArea tcol                          / area of every triangle at once (triArea is elementwise)
cpt:(av>0.)*3.%av|0.0001                 / inverse-mass contribution per triangle = 1/(A/3)
gIm::@[n#0.;triIds;+;,/+(cpt;cpt;cpt)]   / scatter each triangle's contrib to its 3 vertices
gIm[0,nCols-1]:0.                        / pin top-left and top-right

/ ── Constraints: each edge type is a table of edges ───────────────────────────
eLen:{[i;j] vlen3[((g`px)@j)-(g`px)@i; ((g`py)@j)-(g`py)@i; ((g`pz)@j)-(g`pz)@i]}
buildCons:{[rows]                                / rows: list of (i;j;restLen;alpha)
  i:{x@0}'rows; j:{x@1}'rows; l0:{x@2}'rows; al:{x@3}'rows
  w0:gIm@i; w1:gIm@j
  ([]i:i; j:j; l0:l0; al:al; w0:w0; w1:w1; wt:w0+w1)}

/ Edge rows are pre-computed, then handed to buildCons: writing
/ `buildCons {..}'!n` misparses as `(buildCons {..})'!n`, so keep two steps.
hRows:{[k] r:k div nCols-1; c:k mod nCols-1; i:(r*nCols)+c; (i;i+1;eLen[i;i+1];0.)}' !nRows*nCols-1
vRows:{[k] r:k div nCols; c:k mod nCols; i:(r*nCols)+c; (i;i+nCols;eLen[i;i+nCols];0.)}' !(nRows-1)*nCols
dRows:{[k] r:k div nCols-1; c:k mod nCols-1; i:(r*nCols)+c; (i;i+nCols+1;eLen[i;i+nCols+1];0.)}' !(nRows-1)*nCols-1
bRows:{[k] r:k div nCols-1; c:k mod nCols-1; i:(r*nCols)+c+1; j:((r+1)*nCols)+c; (i;j;eLen[i;j];gBendAlpha)}' !(nRows-1)*nCols-1
hCons::buildCons hRows; vCons::buildCons vRows; dCons::buildCons dRows; bCons::buildCons bRows

/ ── One constraint-type pass: vectorized Jacobi over its edge table ───────────
/ Reads+writes the position columns of g. c is one of the constraint tables.
applyPass:{[c]
  i:c`i; j:c`j; l0:c`l0; al:c`al; w0:c`w0; w1:c`w1; wt:c`wt
  px:g`px; py:g`py; pz:g`pz
  dxs:(px@j)-px@i; dys:(py@j)-py@i; dzs:(pz@j)-pz@i
  ds:vlen3[dxs;dys;dzs]
  safe:ds>0.0001
  dsc:ds|0.0001
  ndx:dxs%dsc; ndy:dys%dsc; ndz:dzs%dsc
  Cs:ds-l0
  lams:0.5*(Cs*safe)%wt+al%gSdt*gSdt
  dlx:ndx*lams; dly:ndy*lams; dlz:ndz*lams
  / Scatter-add via amend-with-+: duplicate indices accumulate, so the +at ci and
  / -at cj corrections collapse into one amend per axis. k=i,j indexes both ends.
  k:i,j
  g[`px]::@[px;k;+;(dlx*w0),0.-dlx*w1]
  g[`py]::@[py;k;+;(dly*w0),0.-dly*w1]
  g[`pz]::@[pz;k;+;(dlz*w0),0.-dlz*w1]}

/ ── Simulation substep ────────────────────────────────────────────────────────
clothSubstep:{[x]
  free:gIm>0.                                           / 1 for movable particles, 0 for pinned
  g[`vy]::(g`vy)+free*(-9.81*gSdt)                       / gravity on free particles
  prev:g                                                 / snapshot positions for velocity recovery (function-local)
  g[`px`py`pz]::(g`px`py`pz)+gSdt*g`vx`vy`vz             / integrate all three axes at once
  g[`py]|::-2.                                     / floor, below the hanging cloth
  applyPass'(hCons;vCons;dCons;bCons)
  g[`vx`vy`vz]::free*/:((g`px`py`pz)-prev`px`py`pz)%gSdt / recover velocity from displacement
  x}
 
clothFrame:{[] gSdt::gFrameDt%gNumSubsteps; gNumSubsteps clothSubstep/ 0}

/ ── Mesh building ─────────────────────────────────────────────────────────────
/ Vertex layout matches lib/pbr.k (stride 11): pos(3) nor(3) mat(4) lit(1).
buildClothMesh:{[]
  ,/ {[t]
    p0:P t@0; p1:P t@1; p2:P t@2
    nor:vnorm cross3[p1-p0;p2-p0]; nf:0.-nor
    m:clothMat
    ((p0,nor,m),(p1,nor,m),(p2,nor,m)),(p0,nf,m),(p2,nf,m),(p1,nf,m)   / double-sided, per-face normals
  }'(nTris;3)#triIds}

/ ── Vertex shader ─────────────────────────────────────────────────────────────
/ Cloth keeps its own projection (bigger scale, y-recentre, and a real depth term
/ so the draped sheet self-occludes correctly), but emits the standard
/ wNor;wMat;wLit varyings so lib/pbr.k's PbrFragment can shade it.
/ Vertex pulling: the (per-frame rebuilt) stride-11 cloth mesh lives in a resident
/ buffer overwritten each frame with gpu.write and pulled at 11*vid.
clothVtx: shader.vertexPull[(wNor:`v3;wMat:`v4;wLit:`f32); {[vb;vid]
  b:11.*vid
  px:vb[b]; py:vb[b+1.]; pz:vb[b+2.]
  c45:0.7071; s45:0.7071; c30:0.8165; s30:0.5774; sc:0.6
  py0:(c45*px)+(s45*pz)
  py2:(c45*pz)-(s45*px)
  cy:py-1.0
  px1:(c30*cy)-(s30*py2)
  px2:(s30*cy)+(c30*py2)
  ((sc*py0;sc*px1;0.5-(px2*sc*0.5);1.0);(vb[b+3.];vb[b+4.];vb[b+5.]);(vb[b+6.];vb[b+7.];vb[b+8.];vb[b+9.]);vb[b+10.])
}]

/ ── Window loop ───────────────────────────────────────────────────────────────
gPipe:: 0
gVB::   0

loop: {[props]
  $[gPipe=0; gPipe:: mesh.compilePull[clothVtx;PbrFragment]; 0]
  clothFrame[]
  cm: buildClothMesh[]
  $[gVB=0; gVB:: gpu.buffer[cm]; gpu.write[gVB; cm]]
  mesh.drawPull[gPipe; ,gVB; (#cm) div 11]
}

window.run[loop; 0]
