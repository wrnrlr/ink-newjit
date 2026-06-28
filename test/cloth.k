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
/ Run: zig build gpu && ink test/cloth.k

2: "lib/spirv.k"
2: "lib/gpu.k"

/ ── Vector helpers ────────────────────────────────────────────────────────────
vlen3:{sqrt[(sqr x)+(sqr y)+(sqr z)]}            / length from x;y;z component arrays
cross3:{((x@1 2 0)*y@2 0 1)-(x@2 0 1)*y@1 2 0}   / cross product of two 3-vectors
vnorm:{x%vlen3[x@0;x@1;x@2]|0.0001}              / normalise a packed 3-vector

nCols::20;nRows::20;n::nCols*nRows
gFrameDt::1.%60.;gNumSubsteps::15
gBendAlpha::1.0;gSdt::0.0

/ ── Grid: particle state as a table, one row per particle ─────────────────────
/ Flat 1×1 sheet in the xz-plane centred on the origin, held at y=1, at rest.
Grid:{[w;h]c:w*h;i:!c;
  px:((i mod w)%w-1)-.5;py:((i div w)%h-1)-.5
  [[]px:px;py:c#1.;pz:py;vx:c#0.;vy:c#0.;vz:c#0.]
}
g::Grid[nCols;nRows]

P:{[i] ((g`px)@i;(g`py)@i;(g`pz)@i)}     / particle i as a packed 3-vector

/ ── Triangles — CCW winding gives upward normals on flat cloth ────────────────
triIds:: ,/ {[k]
  r:k div nCols-1; c:k mod nCols-1
  i00:(r*nCols)+c; i01:(r*nCols)+c+1
  i10:((r+1)*nCols)+c; i11:((r+1)*nCols)+c+1
  ((i00;i11;i01);(i00;i10;i11))
}' !(nRows-1)*nCols-1

/ ── Inverse masses from triangle areas; pin the two top corners ───────────────
triArea:{[t] cr:cross3[(P t@1)-P t@0;(P t@2)-P t@0]; 0.5*vlen3[cr@0;cr@1;cr@2]}
gIm::n#0.
{[t] a:triArea t; gIm::@[gIm;t;+;$[a>0.;3.%a;0.]]}' triIds;
gIm::@[gIm;0,nCols-1;:;0.]                        / pin top-left and top-right

/ ── Constraints: each edge type is a table of edges ───────────────────────────
eLen:{[i;j] vlen3[((g`px)@j)-(g`px)@i; ((g`py)@j)-(g`py)@i; ((g`pz)@j)-(g`pz)@i]}
buildCons:{[rows]                                / rows: list of (i;j;restLen;alpha)
  i:{x@0}'rows; j:{x@1}'rows; l0:{x@2}'rows; al:{x@3}'rows
  w0:gIm@i; w1:gIm@j
  [[]i:i; j:j; l0:l0; al:al; w0:w0; w1:w1; wt:w0+w1]}

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
  free:gIm>0.                              / 1 for movable particles, 0 for pinned
  g[`vy]::(g`vy)+free*(-9.81*gSdt)         / gravity on free particles
  prev::g                                  / snapshot positions for velocity recovery
  g[`px]::(g`px)+(g`vx)*gSdt               / integrate positions
  g[`py]::(g`py)+(g`vy)*gSdt
  g[`pz]::(g`pz)+(g`vz)*gSdt
  g[`py]::(g`py)|-2.                        / floor, below the hanging cloth
  applyPass hCons                          / 4-pass solve: h → v → d → b
  applyPass vCons
  applyPass dCons
  applyPass bCons
  g[`vx]::free*((g`px)-prev`px)%gSdt        / recover velocity from displacement
  g[`vy]::free*((g`py)-prev`py)%gSdt
  g[`vz]::free*((g`pz)-prev`pz)%gSdt
  x}

clothFrame:{[] gSdt::gFrameDt%gNumSubsteps; gNumSubsteps clothSubstep/ 0}

/ ── Mesh building ─────────────────────────────────────────────────────────────
buildClothMesh:{[]
  ,/ {[t]
    p0:P t@0; p1:P t@1; p2:P t@2
    nor:vnorm cross3[p1-p0;p2-p0]; nf:0.-nor
    ((p0,nor),(p1,nor),(p2,nor)),(p0,nf),(p2,nf),(p1,nf)   / double-sided, per-face normals
  }' triIds}

/ ── Shaders ───────────────────────────────────────────────────────────────────
clothVtx: VertexShader[[pos:`v3;nor:`v3]; [wPos:`v3;wNor:`v3]; {[pos;nor]
  c45:0.7071; s45:0.7071; c30:0.8165; s30:0.5774; sc:0.6
  py0:(c45*pos[0])+(s45*pos[2])
  py2:(c45*pos[2])-(s45*pos[0])
  cy:pos[1]-1.0
  px1:(c30*cy)-(s30*py2)
  px2:(s30*cy)+(c30*py2)
  ((sc*py0;sc*px1;0.5-(px2*sc*0.5);1.0);pos;nor)
}]
/ gpu.px gpu.fn gpu.vx
/ normalize3:{x%+/x}
clothFrag: FragmentShader[[wPos:`v3;wNor:`v3; out:`v4]; {[wPos;wNor]
  ar:0.18; ag:0.28; ab:0.62; rough:0.75
  V:normalize 0.5774 0.5774 0.5774
  L:normalize 0.5 1.5 0.3
  H:normalize V+L
  NdotL:max[0.0;dot[wNor;L]]
  NdotV:max[0.0001;dot[wNor;V]]
  NdotH:max[0.0;dot[wNor;H]]
  VdotH:max[0.0;dot[V;H]]
  a:sqr rough; a2:sqr a
  dn:(sqr[NdotH]*(a2-1.0))+1.0
  D:a2%(3.14159*dn*dn)
  k:sqr[rough+1.0]%8.0
  Gl:NdotL%((NdotL*(1.0-k))+k)
  Gv:NdotV%((NdotV*(1.0-k))+k)
  G:Gl*Gv
  F:0.04+(0.96*pow[1.0-VdotH;5.0])
  dnom:(4.0*NdotL*NdotV)+0.001
  spec:(D*G*F)%dnom
  kd:1.0-F
  dr:kd*ar%3.14159; dg:kd*ag%3.14159; db:kd*ab%3.14159
  nl2:NdotL*2.0
  lr:clamp[(0.04*ar)+((spec+dr)*nl2);0.0;1.0]
  lg:clamp[(0.04*ag)+((spec+dg)*nl2);0.0;1.0]
  lb:clamp[(0.04*ab)+((spec+db)*nl2);0.0;1.0]
  (lr;lg;lb;1.0)
}]

/ ── Window loop ───────────────────────────────────────────────────────────────
gHandle:: 0

loop: {[props]
  $[gHandle=0; gHandle::CompileMesh[clothVtx;clothFrag]; 0]
  clothFrame[]
  DrawMesh[buildClothMesh[]; gHandle]
}

RunWindow[loop; 0]
