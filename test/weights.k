/ test/weights.k — safetensors weight loading validated by round-trip: build a
/ synthetic model dict (name→tensor) the way safetensors.read would, load it back
/ into the nn weight lists, and confirm (a) exact round-trip and (b) a real encoder
/ forward pass matches running with the weights directly.   INK_SNAP=0 ink test/weights.k

2: "lib/dye.k"
2: "lib/gpu.k"
2: "lib/nn.k"

D:8; H:2; Dff:16; ks:3; EPS:0.00001
CFG: (4; D; H; Dff; ks; EPS)                / T=4
rv:{[n;o] (`f$ ((o+!n) mod 13) - 6) % 6.}
gv:{[n;o] 0.8 + 0.02 * `f$ (o+!n) mod 11}
mkLayer:{[b]
  ( gv[D;b];rv[D;b+1]; rv[Dff*D;b+2];rv[Dff;b+3];rv[D*Dff;b+4];rv[D;b+5];
    gv[D;b+6];rv[D;b+7];
    rv[D*D;b+8];rv[D;b+9];rv[D*D;b+10];rv[D;b+11];rv[D*D;b+12];rv[D;b+13];rv[D*D;b+14];rv[D;b+15];
    rv[D*D;b+16];rv[D;b+17];rv[D;b+18];
    gv[D;b+19];rv[D;b+20]; rv[2*D*D;b+21];rv[2*D;b+22]; rv[D*ks;b+23];rv[D;b+24];
    gv[D;b+25];rv[D;b+26]; rv[D*D;b+27];rv[D;b+28];
    gv[D;b+29];rv[D;b+30]; rv[Dff*D;b+31];rv[Dff;b+32];rv[D*Dff;b+33];rv[D;b+34];
    gv[D;b+35];rv[D;b+36] ) }
X0: (`f$ (!(4*D)) mod 9) - 4.

/ synthetic tensor as safetensors.read returns them (symbol-keyed dict of dicts)
mkTensor:{[data] `dtype`shape`data ! (`f32; (,#data); data)}

/ subsample + decoder weight sets (shapes match ConvSubsample / TdtGreedy)
C:4; Ti:16; Fi:16; F3: nnSub2 nnSub2 nnSub2 Fi
subW: ( rv[C*9;1]; rv[C;2]; rv[C*9;3]; rv[C;4]; rv[C*C;5]; rv[C;6];
        rv[C*9;7]; rv[C;8]; rv[C*C;9]; rv[C;10]; rv[D*(C*F3);11]; rv[D;12] )
V:5; EncD:8; EmbD:4; LH:6; J:10; DUR:0 1 2 3 4
NOUT: (V+1) + #DUR
decW: ( rv[(V+1)*EmbD;1]; rv[4*LH*EmbD;2]; rv[4*LH*LH;3]; rv[4*LH;4];
        rv[J*EncD;5]; rv[J*LH;6]; rv[J;7]; rv[NOUT*J;8]; rv[NOUT;9] )

demo:{[]
  / encoder: build model, load, round-trip + forward
  Ws: (mkLayer[100]; mkLayer[400])
  names: ,/ {[i] nnEncNm[i;]' nnBlkSuf}' !2
  model: (`s$' names) ! mkTensor' ,/Ws
  loaded: nnLoadEncoder[model; 2]
  `0 0:"encoder  round-trip exact -> "; `0 0:$(,/,/loaded) ~ ,/,/Ws; `0 0:"\n"
  Rd: Encoder[X0; Ws; CFG]
  Rl: Encoder[X0; loaded; CFG]
  `0 0:"encoder  forward(loaded)==forward(direct) -> "; `0 0:$Rl~Rd; `0 0:"  maxerr="; `0 0:$|/abs Rl-Rd; `0 0:"\n"

  / subsample round-trip
  sm: (`s$' "sub." ,/: nnSubSuf) ! mkTensor' subW
  `0 0:"subsample round-trip exact -> "; `0 0:$(,/ nnLoadSubsample[sm]) ~ ,/subW; `0 0:"\n"

  / decoder round-trip
  dm: (`s$' nnDecSuf) ! mkTensor' decW
  `0 0:"decoder  round-trip exact -> "; `0 0:$(,/ nnLoadDecoder[dm]) ~ ,/decW; `0 0:"\n"
  0}
gDone::0
go::{[] gDone::1; demo[]}
loop:{[props] $[gDone=0; go[]; 0]}
gpu.computeRun[{[x] demo[]}]
