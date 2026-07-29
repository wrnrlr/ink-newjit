/ test/relpos.k — relative-position self-attention (attn.rel.host) validated vs CPU.
/ Run headless:  INK_SNAP=0 ink test/relpos.k

2: "lib/dye.k"
2: "lib/gpu.k"
2: "lib/nn.k"

T:5; D:8; H:2; dh: D div H
rv:{[n;o] (`f$ ((o+!n) mod 13) - 6) % 3.}
X: (`f$ (!(T*D)) mod 9) - 4.
Wq:rv[D*D;1]; Bq:rv[D;2]; Wk:rv[D*D;3]; Bk:rv[D;4]; Wv:rv[D*D;5]; Bv:rv[D;6]
Wo:rv[D*D;7]; Bo:rv[D;8]; Wpos:rv[D*D;9]; U:rv[D;10]; Vv:rv[D;11]
WLIST: (Wq;Bq;Wk;Bk;Wv;Bv;Wo;Bo;Wpos;U;Vv)

/ ── CPU reference ────────────────────────────────────────────────────────────
gDot:  {[Wm;kk;r;o] +/ r * Wm@(o*kk)+!kk}
gLinR: {[Wm;Bs;kk;nn;r] Bs + gDot[Wm;kk;r;]' !nn}
scale: 1. % sqrt 0.+dh
Xm: (T;D)#X
QF: ,/ gLinR[Wq;Bq;D;D;]' Xm
KF: ,/ gLinR[Wk;Bk;D;D;]' Xm
VF: ,/ gLinR[Wv;Bv;D;D;]' Xm
PE: attn.pos[T;D]                                 / [2T-1, D]
PF: ,/ gLinR[Wpos; D#0.; D; D;]' ((2*T)-1; D)#PE  / P = PE·Wposᵀ  [2T-1, D]

/ score term for (h,i,j) channel c
rTerm:{[h;i;j;c] qc: QF@(i*D)+c
  ((qc + U c) * KF@(j*D)+c) + (qc + Vv c) * PF@(((i-j)+(T-1))*D)+c}
rScEl: {[h;i;j] scale * +/ rTerm[h;i;j;]' (h*dh)+!dh}
rawRow:{[h;i] v: rScEl[h;i;]' !T; e: exp v-|/v; e % +/e}
rCtx:  {[h;i;kk] +/ (rawRow[h;i]) * VF@((!T)*D)+((h*dh)+kk)}
rCel:  {[i;c] rCtx[c div dh; i; c mod dh]}
rCrow: {[i] rCel[i;]' !D}
cref:  {[] ,/ gLinR[Wo;Bo;D;D;]' rCrow' !T}

demo:{[]
  Rg: attn.rel.host[X; WLIST; (T;D;H)]
  Rc: cref[]
  `0 0:"#gpu="; `0 0:$#Rg; `0 0:"  #cpu="; `0 0:$#Rc; `0 0:"\n"
  `0 0:"RelAttn maxerr -> "; `0 0:$(|/abs Rg-Rc); `0 0:"\n"
  `0 0:"gpu[0..7] -> "; `0 0:$8#Rg; `0 0:"\n"
  `0 0:"cpu[0..7] -> "; `0 0:$8#Rc; `0 0:"\n"
  0}
gDone::0
go::{[] gDone::1; demo[]}
loop:{[props] $[gDone=0; go[]; 0]}
window.run[loop; 0]
