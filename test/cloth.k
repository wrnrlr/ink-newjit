/ test/cloth.k — XPBD cloth simulation with PBR rendering
/
/ 20×20 grid cloth pinned at two top corners, falling under gravity.
/
/ Constraint solver: 4 sequential vectorized passes (h/v/d/b constraint types).
/ Each pass is a vectorized Jacobi step within one constraint type, and passes
/ are applied sequentially (Gauss-Seidel across types). This is stable because:
/ - Within each type, each particle appears at most twice → tridiagonal structure
/ - Tridiagonal Jacobi always converges for any correction magnitude
/ - Gauss-Seidel across types propagates corrections through the mesh
/
/ Run: zig build gpu && ink test/cloth.k

2: "lib/gpu/spirv.k"
2: "lib/gpu/gpu.k"

/ ── Math helpers ──────────────────────────────────────────────────────────────
vlen3: {[x;y;z] sqrt[(x*x)+(y*y)+(z*z)]}
cross3: {[a;b]
  (((a@1)*(b@2))-((b@1)*(a@2))
   ((a@2)*(b@0))-((b@2)*(a@0))
   ((a@0)*(b@1))-((b@0)*(a@1)))
}
vnorm: {[v] v%((vlen3[v@0;v@1;v@2])|0.0001)}

/ ── Grid parameters ───────────────────────────────────────────────────────────
nCols:: 20; nRows:: 20; n:: nCols*nRows
gFrameDt:: 1.%60.
gNumSubsteps:: 15
gBendAlpha:: 1.0
gSdt:: 0.0

/ ── Initial positions as flat float lists ─────────────────────────────────────
gPx:: {[i] ((1.*(i mod nCols))%(1.*(nCols-1)))-0.5}' !n
gPy:: n#1.
gPz:: {[i] ((1.*(i div nCols))%(1.*(nRows-1)))-0.5}' !n
gVx:: n#0.; gVy:: n#0.; gVz:: n#0.

/ ── Triangle indices — CCW winding gives upward normals on flat cloth ──────────
triIds:: ,/ {[k]
  r:k div (nCols-1); c:k mod (nCols-1)
  i00:(r*nCols)+c; i01:(r*nCols)+c+1
  i10:((r+1)*nCols)+c; i11:((r+1)*nCols)+c+1
  ((i00;i11;i01); (i00;i10;i11))
}' !((nRows-1)*(nCols-1))

/ ── Inverse masses from triangle areas ────────────────────────────────────────
gInvM:: n#0.
{[t]
  i0:t@0; i1:t@1; i2:t@2
  e0x:(gPx@i1)-(gPx@i0); e0y:(gPy@i1)-(gPy@i0); e0z:(gPz@i1)-(gPz@i0)
  e1x:(gPx@i2)-(gPx@i0); e1y:(gPy@i2)-(gPy@i0); e1z:(gPz@i2)-(gPz@i0)
  cx:(e0y*e1z)-(e1y*e0z); cy:(e0z*e1x)-(e1z*e0x); cz:(e0x*e1y)-(e1x*e0y)
  A:0.5*sqrt[(cx*cx)+(cy*cy)+(cz*cz)]
  contrib:$[A>0.;3.%A;0.]
  gInvM::@[@[@[gInvM;i0;+;contrib];i1;+;contrib];i2;+;contrib]
}' triIds;
/ Pin top-left (0) and top-right (nCols-1) corners
gInvM::@[@[gInvM;0;:;0.];nCols-1;:;0.]

/ ── Constraint edges — 4 separate types for stable 4-pass Jacobi ──────────────
eLen: {[i;j]
  dx:(gPx@j)-(gPx@i); dy:(gPy@j)-(gPy@i); dz:(gPz@j)-(gPz@i)
  sqrt[(dx*dx)+(dy*dy)+(dz*dz)]
}

buildCons: {[cons]
  ci: {[c] c@0}' cons; cj: {[c] c@1}' cons
  cl0: {[c] c@2}' cons; cal: {[c] c@3}' cons
  cw0: gInvM@ci; cw1: gInvM@cj; cwt: cw0+cw1
  (ci;cj;cl0;cal;cw0;cw1;cwt)
}

/ Each raw list must be pre-computed before passing to buildCons.
/ Passing an inline lambda-each to buildCons (e.g. buildCons {[k]...}' !n)
/ is parsed as (buildCons {[k]...})' !n — wrong. Split into two steps.
hRaw:: {[k] r:k div (nCols-1); c:k mod (nCols-1); i:(r*nCols)+c; (i;i+1;eLen[i;i+1];0.)}' !(nRows*(nCols-1))
vRaw:: {[k] r:k div nCols; c:k mod nCols; i:(r*nCols)+c; (i;i+nCols;eLen[i;i+nCols];0.)}' !((nRows-1)*nCols)
dRaw:: {[k] r:k div (nCols-1); c:k mod (nCols-1); i:(r*nCols)+c; (i;i+nCols+1;eLen[i;i+nCols+1];0.)}' !((nRows-1)*(nCols-1))
bRaw:: {[k] r:k div (nCols-1); c:k mod (nCols-1); i:(r*nCols)+c+1; j:((r+1)*nCols)+c; (i;j;eLen[i;j];gBendAlpha)}' !((nRows-1)*(nCols-1))

hBuf:: buildCons hRaw
vBuf:: buildCons vRaw
dBuf:: buildCons dRaw
bBuf:: buildCons bRaw

/ Extract per-type constraint arrays as globals
ghCi::hBuf@0; ghCj::hBuf@1; ghCl0::hBuf@2; ghCal::hBuf@3; ghCw0::hBuf@4; ghCw1::hBuf@5; ghCwt::hBuf@6
gvCi::vBuf@0; gvCj::vBuf@1; gvCl0::vBuf@2; gvCal::vBuf@3; gvCw0::vBuf@4; gvCw1::vBuf@5; gvCwt::vBuf@6
gdCi::dBuf@0; gdCj::dBuf@1; gdCl0::dBuf@2; gdCal::dBuf@3; gdCw0::dBuf@4; gdCw1::dBuf@5; gdCwt::dBuf@6
gbCi::bBuf@0; gbCj::bBuf@1; gbCl0::bBuf@2; gbCal::bBuf@3; gbCw0::bBuf@4; gbCw1::bBuf@5; gbCwt::bBuf@6

/ ── One constraint-type pass: vectorized Jacobi within the type ───────────────
/ Reads+writes globals gPx/gPy/gPz. ci/cj/cl0/cal/cw0/cw1/cwt are parameters.
applyPass: {[ci;cj;cl0;cal;cw0;cw1;cwt]
  dxs:(gPx@cj)-(gPx@ci); dys:(gPy@cj)-(gPy@ci); dzs:(gPz@cj)-(gPz@ci)
  ds: sqrt[(dxs*dxs)+(dys*dys)+(dzs*dzs)]
  safe: ds>0.0001
  dsc: ds|0.0001
  ndx:dxs%dsc; ndy:dys%dsc; ndz:dzs%dsc
  Cs: ds-cl0
  lams: 0.5*(Cs*safe)%(cwt+cal%gSdt*gSdt)
  dlx:ndx*lams; dly:ndy*lams; dlz:ndz*lams
  gPx:: @[@[gPx;ci;+;dlx*cw0];cj;-;dlx*cw1]
  gPy:: @[@[gPy;ci;+;dly*cw0];cj;-;dly*cw1]
  gPz:: @[@[gPz;ci;+;dlz*cw0];cj;-;dlz*cw1]
}

/ ── Simulation substep ────────────────────────────────────────────────────────
gPrevPx:: n#0.; gPrevPy:: n#0.; gPrevPz:: n#0.

clothSubstep: {[x]
  freeMask: gInvM>0.
  / Gravity: add g*dt to velocity for free (non-pinned) particles
  gVy:: gVy+freeMask*(-9.81*gSdt)
  / Save positions for velocity recovery
  gPrevPx:: gPx; gPrevPy:: gPy; gPrevPz:: gPz
  / Integrate positions
  gPx:: gPx+gVx*gSdt
  gPy:: gPy+gVy*gSdt
  gPz:: gPz+gVz*gSdt
  / Floor: low enough not to interfere with freely hanging cloth
  gPy:: gPy|(-2.)
  / 4-pass constraint solve: h → v → d → b (Gauss-Seidel across types)
  applyPass[ghCi;ghCj;ghCl0;ghCal;ghCw0;ghCw1;ghCwt]
  applyPass[gvCi;gvCj;gvCl0;gvCal;gvCw0;gvCw1;gvCwt]
  applyPass[gdCi;gdCj;gdCl0;gdCal;gdCw0;gdCw1;gdCwt]
  applyPass[gbCi;gbCj;gbCl0;gbCal;gbCw0;gbCw1;gbCwt]
  / Velocity recovery from position delta (zero for pinned particles)
  gVx:: freeMask*(gPx-gPrevPx)%gSdt
  gVy:: freeMask*(gPy-gPrevPy)%gSdt
  gVz:: freeMask*(gPz-gPrevPz)%gSdt
  x
}

clothFrame: {[]
  gSdt:: gFrameDt%gNumSubsteps
  gNumSubsteps clothSubstep/ 0
}

/ ── Mesh building ─────────────────────────────────────────────────────────────
buildClothMesh: {[]
  ,/ {[t]
    i0:t@0; i1:t@1; i2:t@2
    p0:(gPx@i0;gPy@i0;gPz@i0)
    p1:(gPx@i1;gPy@i1;gPz@i1)
    p2:(gPx@i2;gPy@i2;gPz@i2)
    e0:p1-p0; e1:p2-p0
    nor:vnorm cross3[e0;e1]
    nf:0.-nor
    fr:(p0,nor),(p1,nor),(p2,nor)
    bk:(p0,nf),(p2,nf),(p1,nf)
    fr,bk
  }' triIds
}

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

clothFrag: FragmentShader[[wPos:`v3;wNor:`v3; out:`v4]; {[wPos;wNor]
  ar:0.18; ag:0.28; ab:0.62; rough:0.75
  V:normalize[(0.5774;0.5774;0.5774)]
  L:normalize[(0.5;1.5;0.3)]
  H:normalize[V+L]
  NdotL:max[0.0;dot[wNor;L]]
  NdotV:max[0.0001;dot[wNor;V]]
  NdotH:max[0.0;dot[wNor;H]]
  VdotH:max[0.0;dot[V;H]]
  a:rough*rough; a2:a*a
  dn:(NdotH*NdotH*(a2-1.0))+1.0
  D:a2%(3.14159*dn*dn)
  k:(rough+1.0)*(rough+1.0)%8.0
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
