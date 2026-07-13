/ test/subsample.k — GPU conv-subsampling (dw_striding 8×) validated vs CPU.
/ Each conv kernel is checked individually, then the full ConvSubsample pipeline.
/ Run headless:  INK_SNAP=0 ink test/subsample.k

2: "lib/dye.k"
2: "lib/gpu.k"
2: "lib/nn.k"

Ti:16; Fi:16; C:4; D:8
T1:nnSub2 Ti; F1:nnSub2 Fi; T2:nnSub2 T1; F2:nnSub2 F1; T3:nnSub2 T2; F3:nnSub2 F2
rv:{[n;o] (`f$ ((o+!n) mod 13) - 6) % 6.}
MEL: (`f$ (!(Ti*Fi)) mod 9) - 4.

/ ── generalized CPU 2-D conv helpers (globals for the current conv) ──────────
GI::(); GW::(); GB::(); GTo::0; GFo::0; GTi::0; GFi::0; GCc::0
c2Term:{[oc;tp;fp;kk] kt:kk div 3; kf:kk mod 3; ti:((2*tp)+kt)-1; fi:((2*fp)+kf)-1
  ($[(~(ti<0))&(ti<GTi)&(~(fi<0))&(fi<GFi); GI@(ti*GFi)+fi; 0.]) * GW@(oc*9)+kk}
c2El:  {[oc;tp;fp] (+/ c2Term[oc;tp;fp;]' !9) + GB oc}
c2Flat:{[oc;pos] c2El[oc; pos div GFo; pos mod GFo]}
c2ocRow:{[oc] c2Flat[oc;]' !GTo*GFo}
cpuConv2d:{[IN;Wm;Bs;cfg] GI::IN;GW::Wm;GB::Bs;GCc::cfg 0;GTo::cfg 1;GFo::cfg 2;GTi::cfg 3;GFi::cfg 4; ,/ c2ocRow' !GCc}

dwTerm:{[c;tp;fp;kk] kt:kk div 3; kf:kk mod 3; ti:((2*tp)+kt)-1; fi:((2*fp)+kf)-1
  ($[(~(ti<0))&(ti<GTi)&(~(fi<0))&(fi<GFi); GI@(c*GTi*GFi)+(ti*GFi)+fi; 0.]) * GW@(c*9)+kk}
dwEl:  {[c;tp;fp] (+/ dwTerm[c;tp;fp;]' !9) + GB c}
dwFlat:{[c;pos] dwEl[c; pos div GFo; pos mod GFo]}
dwcRow:{[c] dwFlat[c;]' !GTo*GFo}
cpuDwConv2d:{[IN;Wm;Bs;cfg] GI::IN;GW::Wm;GB::Bs;GCc::cfg 0;GTo::cfg 1;GFo::cfg 2;GTi::cfg 3;GFi::cfg 4; ,/ dwcRow' !GCc}

GPI::();GPW::();GPB::();GPC::0;GPTF::0
pwEl:{[oc;pos] (+/ (GPI@((!GPC)*GPTF)+pos) * GPW@(oc*GPC)+!GPC) + GPB oc}
pwocRow:{[oc] pwEl[oc;]' !GPTF}
cpuPwConv2d:{[IN;Wm;Bs;c;tf] GPI::IN;GPW::Wm;GPB::Bs;GPC::c;GPTF::tf; ,/ pwocRow' !c}

GFI::();GFC::0;GFTp::0;GFFp::0
flEl:{[tp;j] c:j div GFFp; fp:j mod GFFp; GFI@(c*GFTp*GFFp)+(tp*GFFp)+fp}
flRow:{[tp] flEl[tp;]' !GFC*GFFp}
cpuFlatten:{[IN;c;tp;fp] GFI::IN;GFC::c;GFTp::tp;GFFp::fp; ,/ flRow' !tp}

gDot:{[Wm;kk;r;o] +/ r * Wm@(o*kk)+!kk}
gLinR:{[Wm;Bs;kk;nn;r] Bs + gDot[Wm;kk;r;]' !nn}
cpuLin:{[X;Wm;Bs;t;kk;nn] ,/ gLinR[Wm;Bs;kk;nn;]' (t;kk)#X}
cpuRelu:{[X] 0. | X}

cpuSubsample:{[M;W;cfg]
  ti:cfg 0; fi:cfg 1; c:cfg 2; d:cfg 3
  t1:nnSub2 ti;f1:nnSub2 fi;t2:nnSub2 t1;f2:nnSub2 f1;t3:nnSub2 t2;f3:nnSub2 f2
  h1: cpuRelu cpuConv2d[M; W 0; W 1; (c;t1;f1;ti;fi)]
  h2: cpuDwConv2d[h1; W 2; W 3; (c;t2;f2;t1;f1)]
  p2: cpuRelu cpuPwConv2d[h2; W 4; W 5; c; t2*f2]
  h3: cpuDwConv2d[p2; W 6; W 7; (c;t3;f3;t2;f2)]
  p3: cpuRelu cpuPwConv2d[h3; W 8; W 9; c; t3*f3]
  hf: cpuFlatten[p3; c; t3; f3]
  cpuLin[hf; W 10; W 11; t3; c*f3; d]}

/ ── GPU wrappers for the individual convs ───────────────────────────────────
gConv2d:  {[IN;Wm;Bs;cfg] n:(cfg 0)*(cfg 1)*(cfg 2); bo:gpu.buffer[(nnPad n)#0.]
  Conv2dR[bo; gpu.buffer[IN]; gpu.buffer[Wm]; gpu.buffer[Bs]; cfg]; n#gpu.read[bo]}
gDwConv2d:{[IN;Wm;Bs;cfg] n:(cfg 0)*(cfg 1)*(cfg 2); bo:gpu.buffer[(nnPad n)#0.]
  DwConv2dR[bo; gpu.buffer[IN]; gpu.buffer[Wm]; gpu.buffer[Bs]; cfg]; n#gpu.read[bo]}
gPwConv2d:{[IN;Wm;Bs;c;t;f] n:c*t*f; bo:gpu.buffer[(nnPad n)#0.]
  PwConv2dR[bo; gpu.buffer[IN]; gpu.buffer[Wm]; gpu.buffer[Bs]; c; t; f]; n#gpu.read[bo]}
gFlatten: {[IN;c;tp;fp] n:tp*c*fp; bo:gpu.buffer[(nnPad n)#0.]
  FlattenR[bo; gpu.buffer[IN]; c; tp; fp]; n#gpu.read[bo]}

/ full subsample weight list (12 arrays)
WSUB: ( rv[C*9;1];  rv[C;2]
        rv[C*9;3];  rv[C;4];  rv[C*C;5];  rv[C;6]
        rv[C*9;7];  rv[C;8];  rv[C*C;9];  rv[C;10]
        rv[D*(C*F3);11]; rv[D;12] )

demo:{[]
  / conv2d 1->C
  Wc:rv[C*9;1]; Bc:rv[C;2]; cc:(C;T1;F1;Ti;Fi)
  `0 0:"conv2d  maxerr -> "; `0 0:$(|/abs gConv2d[MEL;Wc;Bc;cc] - cpuConv2d[MEL;Wc;Bc;cc]); `0 0:"\n"
  / depthwise C->C : make a C-channel input of the right size
  IN1:(`f$ (!(C*T1*F1)) mod 9) - 4.; Wd:rv[C*9;3]; Bd:rv[C;4]; dc:(C;T2;F2;T1;F1)
  `0 0:"dwconv  maxerr -> "; `0 0:$(|/abs gDwConv2d[IN1;Wd;Bd;dc] - cpuDwConv2d[IN1;Wd;Bd;dc]); `0 0:"\n"
  / pointwise C->C
  IN2:(`f$ (!(C*T2*F2)) mod 7) - 3.; Wp:rv[C*C;5]; Bp:rv[C;6]
  `0 0:"pwconv  maxerr -> "; `0 0:$(|/abs gPwConv2d[IN2;Wp;Bp;C;T2;F2] - cpuPwConv2d[IN2;Wp;Bp;C;T2*F2]); `0 0:"\n"
  / flatten (exact permutation)
  `0 0:"flatten maxerr -> "; `0 0:$(|/abs gFlatten[IN2;C;T2;F2] - cpuFlatten[IN2;C;T2;F2]); `0 0:"\n"
  / full pipeline
  scfg:(Ti;Fi;C;D)
  Rg: ConvSubsample[MEL; WSUB; scfg]
  Rc: cpuSubsample[MEL; WSUB; scfg]
  `0 0:"subsample out=[T3="; `0 0:$T3; `0 0:",D="; `0 0:$D; `0 0:"]  #gpu="; `0 0:$#Rg; `0 0:"  #cpu="; `0 0:$#Rc; `0 0:"\n"
  `0 0:"subsample maxerr -> "; `0 0:$(|/abs Rg-Rc); `0 0:"\n"
  0}
gDone::0
go::{[] gDone::1; demo[]}
loop:{[props] $[gDone=0; go[]; 0]}
gpu.computeRun[{[x] demo[]}]
