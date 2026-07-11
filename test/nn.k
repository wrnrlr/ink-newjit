/ test/nn.k — validate the GPU nn primitives (Gemm/Softmax/LayerNorm) against
/ CPU references.  Run headless:  INK_SNAP=0 ink test/nn.k

2: "lib/dye.k"
2: "lib/gpu.k"
2: "lib/nn.k"

/ ── GEMM  3×4×2 ──────────────────────────────────────────────────────────────
GM:3; GK:4; GN:2
GA: 1.+`f$!GM*GK
GB: 1.+`f$!GK*GN
gdot: {[i;j] +/ (GA@(i*GK)+!GK) * (GB@((!GK)*GN)+j)}
gref: {[] ds:!GM*GN; gdot'[ds div GN; ds mod GN]}

/ ── Softmax  5×7 (with negatives, to exercise the stable max-subtraction) ─────
/ NB ink `mod` is integer-only (float mod → !type) so build test data as int-mod
/ then cast; the GPU side uses float FMod, which is fine.
SM:5; SN:7
SX: (`f$ (!(SM*SN)) mod 11) - 5.
SXm: (SM;SN)#SX                                        / precompute reshape (avoids each-parse trap)
smrow: {[r] e: exp r - |/r; e % +/e}                 / stable row softmax (CPU)
sref:  {[] ,/ smrow' SXm}

/ ── LayerNorm  4×6 with affine γ/β ───────────────────────────────────────────
LM:4; LN:6; LEPS:0.00001
LX: (`f$ (!(LM*LN)) mod 7) - 3.
LXm: (LM;LN)#LX
LG: 0.5 + 0.1 * `f$!LN                                 / per-feature gamma
LB: (`f$!LN) - 2.                                      / per-feature beta
lnrow: {[r] m:(+/r)%LN; v:(+/(r-m)*r-m)%LN; (((r-m)%sqrt v+LEPS)*LG)+LB}
lref:  {[] ,/ lnrow' LXm}

/ ── Linear  4×5 · Wᵀ(3×5) + b(3) ─────────────────────────────────────────────
PM:4; PK:5; PN:3
PX: (`f$ (!(PM*PK)) mod 9) - 4.
PW: ((`f$ (!(PN*PK)) mod 7) - 3.) % 4.                 / W is [N,K]
PB: (`f$!PN) - 1.
PXm: (PM;PK)#PX
pdot:  {[r;o] +/ r * PW@(o*PK)+!PK}                    / o-th output for row r
prow:  {[r] PB + pdot[r;]' (!PN)}
pref:  {[] ,/ prow' PXm}

/ ── Activations (elementwise) ────────────────────────────────────────────────
AN:16
AX: 0.5 * (`f$ (!AN) mod 13) - 6.                      / -3 .. 3
siluC: {[t] t % 1. + exp 0. - t}
tanhC: {[t] e: exp 2.*t; (e-1.) % e+1.}               / ink has no tanh verb
geluC: {[t] c:0.7978845608 * t + 0.044715*t*t*t; (0.5*t) * 1. + tanhC c}

/ ── Conformer FFN sub-block  M×D, hidden Dff ─────────────────────────────────
FM:3; D:8; Dff:16; FEPS:0.00001
FX:  (`f$ (!(FM*D))   mod 11) - 5.
W1:  ((`f$ (!(Dff*D)) mod 7)  - 3.) % 6.               / [Dff,D]
FB1: (`f$ (!Dff) mod 5) - 2.
W2:  ((`f$ (!(D*Dff)) mod 5)  - 2.) % 7.               / [D,Dff]
FB2: (`f$ (!D) mod 3) - 1.
FGA: 0.8 + 0.05 * `f$!D                                / gamma[D]
FBE: (`f$!D) % 4.                                      / beta[D]
FXm: (FM;D)#FX
DI: !Dff
DD: !D
lnvC:  {[r] m:(+/r)%D; v:(+/(r-m)*r-m)%D; (((r-m)%sqrt v+FEPS)*FGA)+FBE}
l1dot: {[v;o] +/ v * W1@(o*D)+!D}                      / Linear1 output o (in=D)
l2dot: {[v;o] +/ v * W2@(o*Dff)+!Dff}                  / Linear2 output o (in=Dff)
ffnRow:{[r]
  ln: lnvC r
  p1: l1dot[ln;];  h1: FB1 + p1' DI
  h2: siluC h1
  p2: l2dot[h2;];  h3: FB2 + p2' DD
  r + 0.5*h3}
fref:  {[] ,/ ffnRow' FXm}

/ ── Multi-head self-attention  T=4, D=8, H=2 (dh=4) ──────────────────────────
MT:4; MD:8; MH:2; Mdh: MD div MH
MX:  (`f$ (!(MT*MD)) mod 9) - 4.
MWq: ((`f$ (!(MD*MD)) mod 7) - 3.) % 3.                / all weights [D,D]
MBq: ((`f$ (!MD) mod 5) - 2.) % 2.
MWk: ((`f$ (!(MD*MD)) mod 5) - 2.) % 3.
MBk: ((`f$ (!MD) mod 3) - 1.) % 2.
MWv: ((`f$ (!(MD*MD)) mod 6) - 2.) % 3.
MBv: ((`f$ (!MD) mod 4) - 1.) % 2.
MWo: ((`f$ (!(MD*MD)) mod 4) - 1.) % 3.
MBo: ((`f$ (!MD) mod 5) - 2.) % 2.
MXm: (MT;MD)#MX
mscale: 1. % sqrt 0.+Mdh
mprd:  {[Wf;x;o] +/ x * Wf@(o*MD)+!MD}                 / o-th projection output
mproj: {[Wf;Bf;x] Bf + mprd[Wf;x;]' !MD}              / project a [D] row → [D]
QF: ,/ mproj[MWq;MBq;]' MXm                            / flat [T*D] Q/K/V
KF: ,/ mproj[MWk;MBk;]' MXm
VF: ,/ mproj[MWv;MBv;]' MXm
mscEl: {[h;i;j] mscale * +/ (QF@((i*MD)+(h*Mdh))+!Mdh) * (KF@((j*MD)+(h*Mdh))+!Mdh)}
mawRow:{[h;i] v: mscEl[h;i;]' !MT; e: exp v-|/v; e % +/e}   / softmax attn row
mctxEl:{[h;i;kk] +/ (mawRow[h;i]) * VF@((!MT)*MD)+((h*Mdh)+kk)}
mcEl:  {[i;c] mctxEl[c div Mdh; i; c mod Mdh]}
mcRow: {[i] mcEl[i;]' !MD}                             / context [D] for query i
mref:  {[] Cm: mcRow' !MT; ,/ mproj[MWo;MBo;]' Cm}

/ ── Conformer conv module  T=6, D=8, kernel=3 ───────────────────────────────
CT:6; CD:8; CKS:3; CEPS:0.00001
Cpad: (CKS-1) div 2
CX:    (`f$ (!(CT*CD)) mod 9) - 4.
ClnG:  0.8 + 0.05 * `f$!CD
ClnB:  (`f$ (!CD) mod 5) - 2.
CWpw1: ((`f$ (!(2*CD*CD)) mod 7) - 3.) % 4.            / [2D,D]
CBpw1: ((`f$ (!(2*CD)) mod 5) - 2.) % 2.
CWdw:  ((`f$ (!(CD*CKS)) mod 5) - 2.) % 2.             / [D,ks]
CBdw:  ((`f$ (!CD) mod 3) - 1.) % 2.
CcaA:  0.5 + 0.1 * `f$!CD                              / folded BN scale
CcaB:  ((`f$ (!CD) mod 4) - 1.) % 2.                   / folded BN shift
CWpw2: ((`f$ (!(CD*CD)) mod 6) - 2.) % 4.              / [D,D]
CBpw2: ((`f$ (!CD) mod 5) - 2.) % 2.
CXm:  (CT;CD)#CX
CH2F: 0#0.                                             / flat GLU output (set in cref)
clnRow: {[r] m:(+/r)%CD; v:(+/(r-m)*r-m)%CD; (((r-m)%sqrt v+CEPS)*ClnG)+ClnB}
cpw1dot:{[r;o] +/ r * CWpw1@(o*CD)+!CD}
cpw1Row:{[r] CBpw1 + cpw1dot[r;]' !(2*CD)}
cgluRow:{[r] a:r@!CD; b:r@CD+!CD; a * 1. % 1. + exp 0. - b}
cdwTerm:{[t;c;k] tp:(t+k)-Cpad; ($[(~(tp<0))&(tp<CT); CH2F@(tp*CD)+c; 0.]) * CWdw@(c*CKS)+k}
cdwEl:  {[t;c] (+/ cdwTerm[t;c;]' !CKS) + CBdw@c}
cdwRow: {[t] cdwEl[t;]' !CD}
csiluRow:{[r] r % 1. + exp 0. - r}
cpw2dot:{[r;o] +/ r * CWpw2@(o*CD)+!CD}
cpw2Row:{[r] CBpw2 + cpw2dot[r;]' !CD}
cref:{[]
  H0: clnRow' CXm
  H1: cpw1Row' H0
  H2: cgluRow' H1
  CH2F:: ,/H2
  H3: cdwRow' !CT
  H4: {[r] (r*CcaA)+CcaB}' H3
  H5: csiluRow' H4
  H6: cpw2Row' H5
  CX + ,/H6}

demo:{[]
  Rg: Gemm[GA;GB;GM;GK;GN]
  `0 0:"GEMM      maxerr -> "; `0 0:$(|/abs Rg-gref[]); `0 0:"\n"

  Rs: Softmax[SX;SM;SN]
  `0 0:"Softmax   maxerr -> "; `0 0:$(|/abs Rs-sref[]);  `0 0:"\n"
  `0 0:"  row0 sums (want 1) gpu/cpu -> "; `0 0:$((+/SN#Rs); +/SN#sref[]); `0 0:"\n"

  Rl: LayerNorm[LX;LG;LB;LM;LN;LEPS]
  `0 0:"LayerNorm maxerr -> "; `0 0:$(|/abs Rl-lref[]);  `0 0:"\n"

  Rp: Linear[PX;PW;PB;PM;PK;PN]
  `0 0:"Linear    maxerr -> "; `0 0:$(|/abs Rp-pref[]);  `0 0:"\n"

  Rsi: Silu[AX;AN]
  `0 0:"SiLU      maxerr -> "; `0 0:$(|/abs Rsi-siluC AX); `0 0:"\n"
  Rge: Gelu[AX;AN]
  `0 0:"GELU      maxerr -> "; `0 0:$(|/abs Rge-geluC AX); `0 0:"\n"

  Rf: FfnBlock[FX;W1;FB1;W2;FB2;FGA;FBE;(FM;D;Dff;FEPS)]
  `0 0:"FFN block maxerr -> "; `0 0:$(|/abs Rf-fref[]);  `0 0:"\n"

  Rm: Mhsa[MX; (MWq;MBq;MWk;MBk;MWv;MBv;MWo;MBo); (MT;MD;MH)]
  `0 0:"MHSA      maxerr -> "; `0 0:$(|/abs Rm-mref[]);  `0 0:"\n"

  Rc: ConvModule[CX; (ClnG;ClnB;CWpw1;CBpw1;CWdw;CBdw;CcaA;CcaB;CWpw2;CBpw2); (CT;CD;CKS;CEPS)]
  `0 0:"ConvMod   maxerr -> "; `0 0:$(|/abs Rc-cref[]);  `0 0:"\n"
  0}
gDone::0
go::{[] gDone::1; demo[]}
loop:{[props] $[gDone=0; go[]; 0]}
window.run[loop; 0]
