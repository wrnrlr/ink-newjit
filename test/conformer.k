/ test/conformer.k — full FastConformer block + stacked encoder on the GPU,
/ validated against a from-scratch CPU reference.  Run headless:
/   INK_SNAP=0 ink test/conformer.k

2: "lib/dye.k"
2: "lib/gpu.k"
2: "lib/nn.k"

T:4; D:8; H:2; Dff:16; ks:3; EPS:0.00001
CFG: (T;D;H;Dff;ks;EPS)

/ ── deterministic weight generation ─────────────────────────────────────────
rv: {[n;o] (`f$ ((o+!n) mod 13) - 6) % 6.}     / centred ~[-1,1] (int-mod then cast)
gv: {[n;o] 0.8 + 0.02 * `f$ (o+!n) mod 11}     / positive ~[0.8,1.0] (LN γ / BN scale)
/ one layer's 37-array weight list (rel-pos attn), offset by b so layers differ.
mkLayer: {[b]
  ( gv[D;b];         rv[D;b+1]
    rv[Dff*D;b+2];   rv[Dff;b+3];  rv[D*Dff;b+4];  rv[D;b+5]
    gv[D;b+6];       rv[D;b+7]
    rv[D*D;b+8];     rv[D;b+9];    rv[D*D;b+10];   rv[D;b+11]
    rv[D*D;b+12];    rv[D;b+13];   rv[D*D;b+14];   rv[D;b+15]
    rv[D*D;b+16];    rv[D;b+17];   rv[D;b+18]                / Wpos, u, v (rel-pos)
    gv[D;b+19];      rv[D;b+20]
    rv[2*D*D;b+21];  rv[2*D;b+22]
    rv[D*ks;b+23];   rv[D;b+24]
    gv[D;b+25];      rv[D;b+26]
    rv[D*D;b+27];    rv[D;b+28]
    gv[D;b+29];      rv[D;b+30]
    rv[Dff*D;b+31];  rv[Dff;b+32];  rv[D*Dff;b+33]; rv[D;b+34]
    gv[D;b+35];      rv[D;b+36] ) }

X0: (`f$ (!(T*D)) mod 9) - 4.

/ ── generalized CPU helpers (top-level, explicit args, projections dodge closures)
gLNr:  {[G;Bs;d;eps;r] m:(+/r)%d; v:(+/(r-m)*r-m)%d; (((r-m)%sqrt v+eps)*G)+Bs}
gDot:  {[Wm;kk;r;o] +/ r * Wm@(o*kk)+!kk}
gLinR: {[Wm;Bs;kk;nn;r] Bs + gDot[Wm;kk;r;]' !nn}
gSiluV:{[v] v % 1. + exp 0. - v}
cpuLN: {[X;G;Bs;t;d;eps] ,/ gLNr[G;Bs;d;eps;]' (t;d)#X}

cpuFfn:{[X;Wl;t;d;dff;eps]
  Xm:(t;d)#X
  H0: gLNr[Wl 0; Wl 1; d; eps;]' Xm
  H1: gLinR[Wl 2; Wl 3; d; dff;]' H0
  H2: gSiluV' H1
  H3: gLinR[Wl 4; Wl 5; dff; d;]' H2
  X + 0.5 * ,/H3}

/ rel-pos MHSA — globals hold projected Q/K/V, P, u/v, dims (intermediates)
grTerm:{[h;i;j;c] qc: GQF@(i*GD)+c
  ((qc + Gu c) * GKF@(j*GD)+c) + (qc + Gv c) * GPF@(((i-j)+(GT-1))*GD)+c}
grScEl:{[h;i;j] Gscale * +/ grTerm[h;i;j;]' (h*Gdh)+!Gdh}
grawRow:{[h;i] v: grScEl[h;i;]' !GT; e: exp v-|/v; e % +/e}
grctxEl:{[h;i;kk] +/ (grawRow[h;i]) * GVF@((!GT)*GD)+((h*Gdh)+kk)}
grcEl: {[i;c] grctxEl[c div Gdh; i; c mod Gdh]}
grcRow:{[i] grcEl[i;]' !GD}
cpuMhsa:{[X;Wl;t;d;h]
  GT::t; GD::d; Gdh:: d div h; Gscale:: 1. % sqrt 0.+Gdh
  Gu:: Wl 9; Gv:: Wl 10
  Xm:(t;d)#X
  GQF:: ,/ gLinR[Wl 0; Wl 1; d; d;]' Xm
  GKF:: ,/ gLinR[Wl 2; Wl 3; d; d;]' Xm
  GVF:: ,/ gLinR[Wl 4; Wl 5; d; d;]' Xm
  GPF:: ,/ gLinR[Wl 8; d#0.; d; d;]' ((2*t)-1; d)#nnPosEmb[t;d]
  ,/ gLinR[Wl 6; Wl 7; d; d;]' grcRow' !t}

/ Conv module — globals hold flat GLU output + depthwise weights/dims
gcdwTerm:{[t;c;k] tp:(t+k)-GCpad; ($[(~(tp<0))&(tp<GCT); GCH2F@(tp*GCD)+c; 0.]) * GCWdw@(c*GCKS)+k}
gcdwEl:  {[t;c] (+/ gcdwTerm[t;c;]' !GCKS) + GCBdw@c}
gcdwRow: {[t] gcdwEl[t;]' !GCD}
cpuConv:{[X;Wl;t;d;kk;eps]
  GCT::t; GCD::d; GCKS::kk; GCpad:: (kk-1) div 2
  GCWdw:: Wl 4; GCBdw:: Wl 5; GCcaA:: Wl 6; GCcaB:: Wl 7   / hoist: inline lambdas can't see Wl
  Xm:(t;d)#X
  H0: gLNr[Wl 0; Wl 1; d; eps;]' Xm
  H1: gLinR[Wl 2; Wl 3; d; 2*d;]' H0
  H2: {[r] a:r@!GCD; b:r@GCD+!GCD; a * 1. % 1. + exp 0. - b}' H1
  GCH2F:: ,/H2
  H3: gcdwRow' !t
  H4: {[r] (r * GCcaA) + GCcaB}' H3
  H5: gSiluV' H4
  H6: gLinR[Wl 8; Wl 9; d; d;]' H5
  X + ,/H6}

cpuBlock:{[X;W;cfg]
  t:cfg 0; d:cfg 1; h:cfg 2; dff:cfg 3; kk:cfg 4; eps:cfg 5
  x1: cpuFfn[X; W@0+!6; t; d; dff; eps]
  x2: x1 + cpuMhsa[cpuLN[x1; W 6; W 7; t; d; eps]; W@8+!11; t; d; h]
  x3: cpuConv[x2; W@19+!10; t; d; kk; eps]
  x4: cpuFfn[x3; W@29+!6; t; d; dff; eps]
  cpuLN[x4; W 35; W 36; t; d; eps]}
cpuStep:{[x;w] cpuBlock[x;w;CFG]}
cpuEnc: {[X;Ws] X cpuStep/ Ws}

WL: mkLayer[100]
Ws: (mkLayer[100]; mkLayer[400]; mkLayer[900])

demo:{[]
  Rg: ConformerBlock[X0; WL; CFG]
  Rc: cpuBlock[X0; WL; CFG]
  `0 0:"1 block  #out="; `0 0:$#Rg; `0 0:"  maxerr -> "; `0 0:$(|/abs Rg-Rc); `0 0:"\n"

  Eg: Encoder[X0; Ws; CFG]
  Ec: cpuEnc[X0; Ws]
  `0 0:"3 layers #out="; `0 0:$#Eg; `0 0:"  maxerr -> "; `0 0:$(|/abs Eg-Ec); `0 0:"\n"
  `0 0:"encoder out[0..7] -> "; `0 0:$8#Eg; `0 0:"\n"
  `0 0:"all finite (|/|.|<1e9) -> "; `0 0:$(1e9 > |/abs Eg); `0 0:"\n"
  0}
gDone::0
go::{[] gDone::1; demo[]}
loop:{[props] $[gDone=0; go[]; 0]}
gpu.computeRun[{[x] demo[]}]
