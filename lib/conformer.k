/ lib/conformer.k — Conformer convolution module, block and encoder stack.
/ Built on the generic layers in lib/nn.k.  Design notes: doc/design/nn.md
/
/ block(x) = ½FFN → (x + MHSA(LayerNorm x)) → ConvModule → ½FFN → LayerNorm
/ (ffn and conformer.conv already self-contain their LayerNorm + residual; MHSA is
/  bare, so the block wraps it with a LayerNorm and a residual add.)
/
/ Resident forms are primary: buffer handle in, buffer handle out, weights held on
/ device.  `.host` forms upload/read back and exist for one-shot use and as the
/ bit-exactness oracle — host round-trips are lossless f32 copies, so
/ `conformer` and `conformer.fold` must agree to the bit.

\e conformer

/ ── Conformer convolution module ─────────────────────────────────────────────
/   out = x + PW2( Swish( BN( DWConv( GLU( PW1( LayerNorm(x) ) ) ) ) ) )
/   cfg = (T;D;ks;eps)
/   WB  = 10 handles (lnG;lnB; Wpw1[2D,D];Bpw1; Wdw[D,ks];Bdw; caA;caB; Wpw2[D,D];Bpw2)
/ BatchNorm is folded into (caA;caB) = (rstd·γ ; β − μ·rstd·γ) at load time.
conformer.conv: {[bx; WB; cfg]
  T:cfg 0; D:cfg 1; ks:cfg 2; eps:cfg 3
  pad: (ks-1) div 2
  blnG:WB 0; blnB:WB 1; bwp1:WB 2; bbp1:WB 3; bwdw:WB 4; bbdw:WB 5
  bcaA:WB 6; bcaB:WB 7; bwp2:WB 8; bbp2:WB 9
  h0:nn.buf[T*D]; bm:nn.zbuf T; br:nn.zbuf T
  h1:nn.buf[T*2*D]
  h2:nn.buf[T*D]; h3:nn.buf[T*D]
  h4:nn.buf[T*D]; h5:nn.buf[T*D]; h6:nn.buf[T*D]
  bo:nn.buf[T*D]
  layernorm[h0; bx; blnG; blnB; bm; br; (T;D;eps)]
  linear[h1; h0; bwp1; bbp1; T; D; 2*D]
  glu[h2; h1; T; D]
  dwconv[h3; h2; bwdw; bbdw; T; D; ks; pad]
  chanaffine[h4; h3; bcaA; bcaB; T; D]
  silu[h5; h4; T*D]
  linear[h6; h5; bwp2; bbp2; T; D; D]
  addscaled[bo; bx; h6; 1.; T*D]
  nn.drop(h0;bm;br;h1;h2;h3;h4;h5;h6)
  bo}
conformer.conv.host: {[X;W;cfg]
  bx:gpu.buffer[X]
  WB: gpu.buffer' W
  bo: conformer.conv[bx; WB; cfg]
  r: ((cfg 0)*(cfg 1)) # gpu.read[bo]
  nn.drop(bx;bo); nn.drop WB
  r}

/ ── Full conformer block ─────────────────────────────────────────────────────
/ WB = 37 handles, cfg = (T; D; H; Dff; ks; eps):
/   [0..5]   FFN1  : lnG lnB W1[Dff,D] B1 W2[D,Dff] B2
/   [6..7]   attn LayerNorm : lnG lnB
/   [8..18]  MHSA (rel-pos) : Wq Bq Wk Bk Wv Bv Wo Bo  Wpos[D,D]  u[D]  v[D]
/   [19..28] Conv : lnG lnB Wpw1[2D,D] Bpw1 Wdw[D,ks] Bdw caA caB Wpw2[D,D] Bpw2
/   [29..34] FFN2 : lnG lnB W1 B1 W2 B2
/   [35..36] final LayerNorm : lnG lnB
conformer.block: {[bx; WB; cfg]
  T:cfg 0; D:cfg 1; H:cfg 2; Dff:cfg 3; ks:cfg 4; eps:cfg 5
  fc: (T;D;Dff;eps;0.5)                      / macaron half-step: residual scale ½
  b1: ffn[bx; (WB 2;WB 3;WB 4;WB 5;WB 0;WB 1); fc]
  bln:nn.buf[T*D]; am:nn.zbuf T; ar:nn.zbuf T
  layernorm[bln; b1; WB 6; WB 7; am; ar; (T;D;eps)]
  batt: attn.rel[bln; WB@8+!11; (T;D;H)]
  bx2:nn.buf[T*D]; addscaled[bx2; b1; batt; 1.; T*D]
  bx3: conformer.conv[bx2; WB@19+!10; (T;D;ks;eps)]
  bx4: ffn[bx3; (WB 31;WB 32;WB 33;WB 34;WB 29;WB 30); fc]
  bo:nn.buf[T*D]; bfm:nn.zbuf T; bfr:nn.zbuf T
  layernorm[bo; bx4; WB 35; WB 36; bfm; bfr; (T;D;eps)]
  nn.drop(b1;bln;am;ar;batt;bx2;bx3;bx4;bfm;bfr)
  bo}
conformer.block.host: {[X;W;cfg]
  bx:gpu.buffer[X]
  WB: gpu.buffer' W
  bo: conformer.block[bx; WB; cfg]
  r: ((cfg 0)*(cfg 1)) # gpu.read[bo]
  nn.drop(bx;bo); nn.drop WB
  r}

/ ── Encoder stack ────────────────────────────────────────────────────────────
/ The activation stays resident across blocks: a stacked encoder that round-tripped
/ [T,D] to the host between each of ~24 blocks would re-upload every weight and pay a
/ readback per layer.  Each block frees its own scratch (kk2 §1), so memory stays
/ bounded across a deep stack.
/ Lambdas cannot close over the config, so the fold step reads it from a global.
conformer.cfg:: 0
conformer.step: {[bx;wb] bo: conformer.block[bx; wb; conformer.cfg]; gpu.free bx; bo}

/ conformer.hold[Ws] — upload per-layer host weight lists to the device ONCE.
/ Uploading 24 layers costs ~300 ms, a large slice of a short utterance's encode time,
/ so a caller that transcribes repeatedly should hoist this out of the per-utterance path.
conformer.hold: nn.holdWs

/ conformer.run[X; WBs; cfg] — encode over weights ALREADY on the device.
conformer.run: {[X; WBs; cfg]
  conformer.cfg:: cfg
  bx: gpu.buffer[X]
  bo: bx conformer.step/ WBs
  r: ((cfg 0)*(cfg 1)) # gpu.read bo
  gpu.free bo
  r}

/ conformer[X; Ws; cfg] — one-shot: upload weights, encode, free.
conformer: {[X; Ws; cfg]
  WBs: conformer.hold Ws
  r: conformer.run[X; WBs; cfg]
  nn.drop[,/ WBs]                / MUST bracket: `nn.drop ,/ WBs` trains instead of applying
  r}

/ conformer.fold[X; Ws; cfg] — the pure-host oracle: every block uploads its own
/ weights and reads its activation back.  Same kernels and dispatch sizes as
/ `conformer`, so the two are bit-for-bit equal; this one is just far slower.
conformer.foldStep: {[x;w] conformer.block.host[x; w; conformer.cfg]}
conformer.fold: {[X; Ws; cfg] conformer.cfg:: cfg; X conformer.foldStep/ Ws}
