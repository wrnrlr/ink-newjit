/ test/tdt.k — TDT greedy decoder (host, pure k) validated on controlled models.
/ Runs without a GPU device (decode is host-side).   Run:  ink test/tdt.k

2: "lib/spirv.k"
2: "lib/dye.k"
2: "lib/gpu.k"
2: "lib/nn.k"

V:5; EncD:8; EmbD:4; H:6; J:10; T:7
DUR: 0 1 2 3 4
MAXS: 8
NOUT: (V+1) + #DUR                       / token slots (incl blank @ V) + durations
CFG: (T; EncD; EmbD; H; J; V; DUR; MAXS)

ENC: (`f$ (!(T*EncD)) mod 5) - 2.

/ zero-weight model with a rigged output bias `bo` → logits == bo (constant), so the
/ token/duration argmax is exactly what we choose.
zeroW: {[bo] ( (((V+1)*EmbD)#0.); ((4*H*EmbD)#0.); ((4*H*H)#0.); ((4*H)#0.);
               ((J*EncD)#0.); ((J*H)#0.); (J#0.); ((NOUT*J)#0.); bo )}
/ nonzero (tiny) weights but a huge bias peak → argmax still bias-determined.
tiny: {[n;o] 0.01 * `f$ ((o+!n) mod 7) - 3}
nzW:  {[bo] ( tiny[(V+1)*EmbD;1]; tiny[4*H*EmbD;2]; tiny[4*H*H;3]; tiny[4*H;4];
              tiny[J*EncD;5]; tiny[J*H;6]; tiny[J;7]; tiny[NOUT*J;8]; bo )}

demo:{[]
  `0 0:"tanh(1)="; `0 0:$nnTanh 1.; `0 0:"  sig(0)="; `0 0:$nnSig 0.; `0 0:"  (want ~0.7616, 0.5)\n"

  / token 3 (non-blank), duration index 2 → dur value 2:  emit 3 every 2 frames
  bo1: @[NOUT#0.; 3, (V+1)+2; :; 1.]
  `0 0:"emit(tok3,dur2)  -> "; `0 0:$TdtGreedy[ENC; zeroW bo1; CFG]; `0 0:"  (want 3 3 3 3)\n"

  / blank (token V), duration index 1 → dur 1:  emit nothing, advance 1/frame
  bo2: @[NOUT#0.; V, (V+1)+1; :; 1.]
  e2: TdtGreedy[ENC; zeroW bo2; CFG]
  `0 0:"emit(blank)       -> "; `0 0:$e2; `0 0:"  #="; `0 0:$#e2; `0 0:"  (want empty)\n"

  / duration index 0 → dur 0 (stall): token 2 emitted MAXS times/frame then forced on
  bo3: @[NOUT#0.; 2, (V+1)+0; :; 1.]
  e3: TdtGreedy[ENC; zeroW bo3; CFG]
  `0 0:"emit(tok2,dur0)   -> #="; `0 0:$#e3; `0 0:"  all==2? "; `0 0:$&/e3=2; `0 0:"  (want T*MAXS=56, 1b)\n"

  / nonzero weights, huge bias peak → still token 3 / dur 2
  bo4: @[NOUT#0.; 3, (V+1)+2; :; 100.]
  `0 0:"nonzero-weights   -> "; `0 0:$TdtGreedy[ENC; nzW bo4; CFG]; `0 0:"  (want 3 3 3 3)\n"
  0}
demo[]
