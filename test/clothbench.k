/ test/clothbench.k — CPU vs GPU XPBD cloth performance across grid sizes.
/ Times PHYSICS only (15 substeps/frame, no rendering). Run:  ink test/clothbench.k
/ (needs a GPU device, so it runs inside window.run; headless: INK_SNAP=0 ink …).
/
/ CPU = the vectorized-Jacobi solver from test/cloth.k. GPU = the resident-buffer
/ solver from test/clothgpu.k. For the GPU we report both pure compute (queue N
/ substeps, one final sync) and the realistic render-loop cost (+ a per-frame
/ position readback). `t is a microsecond clock; ms/frame = elapsed / frames.

2: "lib/spirv.k"
2: "lib/dye.k"
2: "lib/gpu.k"

vlen3:{sqrt[(sqr x)+(sqr y)+(sqr z)]}
cross3:{((x@1 2 0)*y@2 0 1)-(x@2 0 1)*y@1 2 0}
SDT::(1.%60.)%15.
FR::20                                    / frames to time per size

/ ── CPU solver (cloth.k physics, size set by cpuSetup) ────────────────────────
Grid:{[w;h]c:w*h;i:!c; px:((i mod w)%w-1)-.5;py:((i div w)%h-1)-.5; [[]px:px;py:c#1.;pz:py;vx:c#0.;vy:c#0.;vz:c#0.]}
Pp:{[i] ((g`px)@i;(g`py)@i;(g`pz)@i)}
eLen:{[i;j] vlen3[((g`px)@j)-(g`px)@i; ((g`py)@j)-(g`py)@i; ((g`pz)@j)-(g`pz)@i]}
buildCons:{[rows] i:{x@0}'rows; j:{x@1}'rows; l0:{x@2}'rows; al:{x@3}'rows; w0:gIm@i; w1:gIm@j; [[]i:i;j:j;l0:l0;al:al;w0:w0;w1:w1;wt:w0+w1]}
applyPass:{[c] i:c`i;j:c`j;l0:c`l0;al:c`al;w0:c`w0;w1:c`w1;wt:c`wt; px:g`px;py:g`py;pz:g`pz; dxs:(px@j)-px@i;dys:(py@j)-py@i;dzs:(pz@j)-pz@i; ds:vlen3[dxs;dys;dzs]; safe:ds>0.0001;dsc:ds|0.0001; ndx:dxs%dsc;ndy:dys%dsc;ndz:dzs%dsc; Cs:ds-l0; lams:0.5*(Cs*safe)%wt+al%gSdt*gSdt; dlx:ndx*lams;dly:ndy*lams;dlz:ndz*lams; k:i,j; g[`px]::@[px;k;+;(dlx*w0),0.-dlx*w1]; g[`py]::@[py;k;+;(dly*w0),0.-dly*w1]; g[`pz]::@[pz;k;+;(dlz*w0),0.-dlz*w1]}
clothSubstep:{[x] free:gIm>0.; g[`vy]::(g`vy)+free*(-9.81*gSdt); prev:g; g[`px`py`pz]::(g`px`py`pz)+gSdt*g`vx`vy`vz; g[`py]|::-2.; applyPass'(hCons;vCons;dCons;bCons); g[`vx`vy`vz]::free*/:((g`px`py`pz)-prev`px`py`pz)%gSdt; x}
clothFrame:{[] gSdt::SDT; 15 clothSubstep/ 0}
cpuSetup:{[side]
  nCols::side; nRows::side; n::nCols*nRows; nTris::2*(nRows-1)*nCols-1; gBendAlpha::1.0
  g::Grid[nCols;nRows]
  rc:!(nRows-1;nCols-1); i00:(nCols*rc@0)+rc@1
  triIds::,/+(i00;i00+nCols+1;i00+1;i00;i00+nCols;i00+nCols+1)
  triArea:{[t] cr:cross3[(Pp t@1)-Pp t@0;(Pp t@2)-Pp t@0]; 0.5*vlen3[cr@0;cr@1;cr@2]}
  tcol:+(nTris;3)#triIds; av:triArea tcol; cpt:(av>0.)*3.%av|0.0001   / intermediate tcol: `triArea +x` mis-parses + as dyadic
  gIm::@[n#0.;triIds;+;,/+(cpt;cpt;cpt)]; gIm::@[gIm;0,nCols-1;:;0.]   / pin corners (@-amend, not x[i]:v — breaks in a fn)
  hR:{[k] r:k div nCols-1;c:k mod nCols-1;i:(r*nCols)+c;(i;i+1;eLen[i;i+1];0.)}' !nRows*nCols-1
  vR:{[k] r:k div nCols;c:k mod nCols;i:(r*nCols)+c;(i;i+nCols;eLen[i;i+nCols];0.)}' !(nRows-1)*nCols
  dR:{[k] r:k div nCols-1;c:k mod nCols-1;i:(r*nCols)+c;(i;i+nCols+1;eLen[i;i+nCols+1];0.)}' !(nRows-1)*nCols-1
  bR:{[k] r:k div nCols-1;c:k mod nCols-1;i:(r*nCols)+c+1;j:((r+1)*nCols)+c;(i;j;eLen[i;j];gBendAlpha)}' !(nRows-1)*nCols-1
  hCons::buildCons hR; vCons::buildCons vR; dCons::buildCons dR; bCons::buildCons bR; 0}

/ ── GPU solver (clothgpu.k kernels — compiled once, size lives in the buffers) ─
kInt::GpKernel[{[p;v;prev;im;g;d] sdt:g[0];ax:mod[d;3.];part:floor[d%3.];isY:$[ax=1.;1.;0.];free:$[(im[part])>0.;1.;0.];nv:(v[d])+isY*free*(-9.81*sdt);set[v;d;nv];set[prev;d;p[d]];np:(p[d])+sdt*nv;set[p;d;$[ax=1.;$[np<(-2.);-2.;np];np]]};0;5]
kCon::GpKernel[{[dp;p;e;g;ee] sc:1048576.;ne:g[0];sdt:g[1];ok:$[ee<ne;1.;0.];base:7.*ee;pi:e[base];pj:e[base+1.];l0:e[base+2.];al:e[base+3.];w0:e[base+4.];w1:e[base+5.];wt:e[base+6.];bi:3.*pi;bj:3.*pj;dx:(p[bj])-p[bi];dy:(p[bj+1.])-p[bi+1.];dz:(p[bj+2.])-p[bi+2.];ds:sqrt[(dx*dx)+(dy*dy)+dz*dz];safe:$[ds>0.0001;1.;0.];dsc:$[ds>0.0001;ds;0.0001];cc:ds-l0;lam:0.5*((cc*safe)%(wt+al%(sdt*sdt)));cx:ok*sc*(dx%dsc)*lam;cy:ok*sc*(dy%dsc)*lam;cz:ok*sc*(dz%dsc)*lam;a0:scatterAdd[dp;bi;cx*w0];a1:scatterAdd[dp;bi+1.;cy*w0];a2:scatterAdd[dp;bi+2.;cz*w0];b0:scatterAdd[dp;bj;(0.-cx)*w1];b1:scatterAdd[dp;bj+1.;(0.-cy)*w1];scatterAdd[dp;bj+2.;(0.-cz)*w1]};1;3]
kApp::GpKernel[{[dp;p;g;d] set[p;d;(p[d])+(iget[dp;d])%1048576.];iset[dp;d;0.]};1;2]
kVel::GpKernel[{[v;p;prev;im;g;d] sdt:g[0];damp:g[1];part:floor[d%3.];free:$[(im[part])>0.;1.;0.];set[v;d;damp*free*((p[d])-prev[d])%sdt]};0;5]
distp::{[a;b] sqrt[+/(a-b)*a-b]}
gpuSetup:{[side]
  W::side; H::side; nP::W*H; nDof::3*nP
  ii::!nP; col::ii mod W; row::ii div W
  px0::(col%W-1)-0.5; py0::nP#1.; pz0::(row%H-1)-0.5
  im0::nP#1.; im0::@[im0;0,W-1;:;0.]; posf::{[k] (px0@k;py0@k;pz0@k)}   / pin corners (@-amend, not x[i]:v — breaks in a fn)
  hi::&col<W-1; vi::&row<H-1; di::&(col<W-1)&row<H-1
  mkE::{[is;js;al] l0:{[a;b]distp[posf a;posf b]}'[is;js]; ,/+((0.+is);(0.+js);l0;al;im0@is;im0@js;(im0@is)+im0@js)}
  P::NewBuffer[,/+(px0;py0;pz0)]; V::NewBuffer[nDof#0.]; PREV::NewBuffer[nDof#0.]; IM::NewBuffer[im0]; DP::NewBuffer[nDof#0.]
  bH::NewBuffer[mkE[hi;hi+1;(#hi)#0.]]; bV::NewBuffer[mkE[vi;vi+W;(#vi)#0.]]; bD::NewBuffer[mkE[di;di+W+1;(#di)#0.]]; bB::NewBuffer[mkE[di+1;di+W;(#di)#1.]]
  G::NewBuffer[SDT,0.995,0.,0.]; GH::NewBuffer[(0.+(#hi)),SDT,0.,0.]; GV::NewBuffer[(0.+(#vi)),SDT,0.,0.]; GD::NewBuffer[(0.+(#di)),SDT,0.,0.]; GB::NewBuffer[(0.+(#di)),SDT,0.,0.]
  cons::((bH;GH);(bV;GV);(bD;GD);(bB;GB)); 0}
pInt::CompileCompute[kInt;5]; pCon::CompileCompute[kCon;4]; pApp::CompileCompute[kApp;3]; pVel::CompileCompute[kVel;5]
onePass::{[cg] Dispatch[pCon;(DP;P;cg 0;cg 1);nP]; Dispatch[pApp;(DP;P;G);nDof]}
gsub::{[s] Dispatch[pInt;(P;V;PREV;IM;G);nDof]; onePass'cons; Dispatch[pVel;(V;P;PREV;IM;G);nDof]; s+1}

msPer::{[a;b;fr] ((0.+b-a)%1000.)%fr}      / µs delta → ms/frame
bench:{[side]
  cpuSetup side; clothFrame[]              / warm
  a::`t@[]; FR {[x] clothFrame[]; x}/0; b::`t@[]
  gpuSetup side; 15 gsub/0; z::ReadBuffer[P]
  c::`t@[]; (FR*15) gsub/0; z::ReadBuffer[P]; d::`t@[]          / GPU compute (one sync)
  e::`t@[]; FR {[x] 15 gsub/0; ReadBuffer[P]; x+1}/0; f::`t@[]  / GPU + per-frame readback
  `0 0:$side;`0 0:"x";`0 0:$side;`0 0:"  n=";`0 0:$nP
  `0 0:"  cpu=";`0 0:$msPer[a;b;FR];`0 0:"  gpu=";`0 0:$msPer[c;d;FR];`0 0:"  gpu+rb=";`0 0:$msPer[e;f;FR];`0 0:" ms/frame\n"; 0}

gDone::0
run::{[] gDone::1; `0 0:"grid       particles   CPU     GPU      GPU+readback  (ms/frame, 15 substeps)\n"
  bench 10; bench 20; bench 30; bench 50; bench 70; bench 100; 0}
window.run[{[props] $[gDone=0; run[]; 0]}; 0]
