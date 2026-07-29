/
# asr

Speech recognition on top of lib/nn.k: conv subsampling, encoder, TDT greedy decode.

Full pipeline:  audio → logmel → subsample → conformer → tdt → asr.detok → text

Pure k — loads on the first reference to any `asr.*` name.
\

\e subsample tdt

/ ── Conv subsampling  (mel spectrogram → 8×-downsampled encoder input) ───────
/ 2-D conv, kernel 3, stride 2, pad 1, applied three times.  Layout [C,T,F].
/ subsample[bmel; WB; cfg] — resident.  cfg=(Tin;Fin;C;D);
/   WB = (Wc[C,9];Bc; Wdw1[C,9];Bdw1; Wpw1[C,C];Bpw1; Wdw2[C,9];Bdw2; Wpw2[C,C];Bpw2;
/         Wproj[D, C·F3];Bproj)   (12 handles)
/ Output is [T3, D] where T3 = nn.sub2 applied three times to Tin.
subsample: {[bmel; WB; cfg]
  Ti:cfg 0; Fi:cfg 1; C:cfg 2; D:cfg 3
  T1:nn.sub2 Ti; F1:nn.sub2 Fi; T2:nn.sub2 T1; F2:nn.sub2 F1; T3:nn.sub2 T2; F3:nn.sub2 F2
  bw0:WB 0; bb0:WB 1
  bwd1:WB 2; bbd1:WB 3; bwp1:WB 4; bbp1:WB 5
  bwd2:WB 6; bbd2:WB 7; bwp2:WB 8; bbp2:WB 9
  bwpr:WB 10; bbpr:WB 11
  h1:nn.buf[C*T1*F1]; conv2d[h1;bmel;bw0;bb0;(C;T1;F1;Ti;Fi)]
  r1:nn.buf[C*T1*F1]; relu[r1;h1;C*T1*F1]
  h2:nn.buf[C*T2*F2]; dwconv2d[h2;r1;bwd1;bbd1;(C;T2;F2;T1;F1)]
  p2:nn.buf[C*T2*F2]; pwconv2d[p2;h2;bwp1;bbp1;C;T2;F2]
  r2:nn.buf[C*T2*F2]; relu[r2;p2;C*T2*F2]
  h3:nn.buf[C*T3*F3]; dwconv2d[h3;r2;bwd2;bbd2;(C;T3;F3;T2;F2)]
  p3:nn.buf[C*T3*F3]; pwconv2d[p3;h3;bwp2;bbp2;C;T3;F3]
  r3:nn.buf[C*T3*F3]; relu[r3;p3;C*T3*F3]
  Kf: C*F3
  hf:nn.buf[T3*Kf]; flatten[hf;r3;C;T3;F3]
  bo:nn.buf[T3*D]; linear[bo;hf;bwpr;bbpr;T3;Kf;D]
  nn.drop(h1;r1;h2;p2;r2;h3;p3;r3;hf)
  bo}
/ subsample.outT[Tin] — frames the three stride-2 stages leave.
subsample.outT: {[Ti] nn.sub2 nn.sub2 nn.sub2 Ti}
subsample.host: {[MEL;W;cfg]
  bmel:gpu.buffer[MEL]
  WB: gpu.buffer' W
  bo: subsample[bmel; WB; cfg]
  T3: subsample.outT cfg 0
  r: (T3*(cfg 3)) # gpu.read[bo]
  nn.drop(bmel;bo); nn.drop WB
  r}

/ ── TDT decoder (host greedy loop) ──────────────────────────────────────────
/ The transducer decode is SEQUENTIAL with tiny per-step work + data-dependent
/ control flow (emit/blank, variable frame advance) → GPU buys nothing; this runs
/ host-side (pure k), using the host `while` adverb.  The encoder is the parallel part.
/
/ TDT joint: (enc_t[Fe], g[H]) → logits[nout].
/   JW=(Wf[J,Fe]; Wg[J,H]; bj[J]; Wo[nout,J]; bo[nout]).
/ NeMo's joint_net is Sequential(ReLU, Dropout, Linear) — the activation is RELU,
/ not tanh (jointnet.activation: relu in model_config.yaml).
/ JW 0/1/3 are COLUMN LISTS (Wf, Wg, Wo); JW 2/4 stay flat bias vectors.
asr.joint: {[enc;g;JW]
  jj: nn.fn.relu (JW 2) + (nn.fn.mvc[JW 0;enc]) + nn.fn.mvc[JW 1;g]
  (JW 4) + nn.fn.mvc[JW 3;jj]}

/ decode state = (t; u; h0; c0; h1; c1; prev; emitted).  Weights/config in globals
/ (the while body is single-arg; blank token id = asr.td.vocab, last of the vocab+1
/ token slots).  The predictor is a 2-LAYER LSTM (prednet.pred_rnn_layers: 2) — layer 0
/ consumes the embedding, layer 1 consumes layer 0's hidden state, and the JOINT sees
/ layer 1's output.
/ prev=blank feeds embedding row `asr.td.vocab`, which is the padding_idx row and is
/ all zeros — exactly NeMo's _SOS "zero input" start state.
asr.td.enc::(); asr.td.emb::(); asr.td.jw::()
asr.td.wih0::(); asr.td.whh0::(); asr.td.lb0::()
asr.td.wih1::(); asr.td.whh1::(); asr.td.lb1::()
asr.td.dur::(); asr.td.vocab::0; asr.td.t::0; asr.td.h::0
asr.td.encD::0; asr.td.embD::0; asr.td.max::0
/ NB memoising the predictor across BLANK steps (state unchanged ⇒ identical LSTM
/ output) looks attractive but measured a 0% hit rate: TDT advances time with its
/ duration head instead of emitting blanks, so essentially every step emits. Not worth
/ the extra state — the win came from the column-major matvec (nn.fn.mvc) instead.
asr.td.step: {[st]
  t:st 0; u:st 1; h0:st 2; c0:st 3; h1:st 4; c1:st 5; prev:st 6; em:st 7
  x:  asr.td.emb@(prev*asr.td.embD)+!asr.td.embD
  l0: lstm[x;    h0; c0; asr.td.wih0; asr.td.whh0; asr.td.lb0; asr.td.h]
  l1: lstm[l0 0; h1; c1; asr.td.wih1; asr.td.whh1; asr.td.lb1; asr.td.h]
  enc: asr.td.enc@(t*asr.td.encD)+!asr.td.encD
  lg: asr.joint[enc; l1 0; asr.td.jw]
  tok:  nn.fn.amax lg@!asr.td.vocab+1
  skip: asr.td.dur nn.fn.amax lg@(asr.td.vocab+1)+!#asr.td.dur
  blank: tok = asr.td.vocab
  em2:   $[blank; em;   em,tok]           / host $ is lazy — no join on blank
  prev2: $[blank; prev; tok]
  n0: $[blank; h0; l0 0]; k0: $[blank; c0; l0 1]   / predictor state advances only on emit
  n1: $[blank; h1; l1 0]; k1: $[blank; c1; l1 1]
  / NeMo GreedyTDTInfer: time += skip every step; the inner loop repeats only while
  / skip==0, and when it bails out at max_symbols time gets ONE extra frame.
  un:   u+1
  last: un = asr.td.max
  t2:   $[last; (t+skip)+1; t+skip]
  u2:   $[last | ~skip=0; 0; un]
  (t2; u2; n0; k0; n1; k1; prev2; em2)}
asr.td.cond: {[st] (st 0) < asr.td.t}

/ asr.prep[W;cfg] — transpose the decoder weights into column lists ONCE. This is
/ per-utterance work otherwise, and it is not cheap (the four 2560×640 LSTM matrices),
/ so a caller that transcribes repeatedly should hoist it and call `tdt` directly.
/   W = (Emb[V+1,EmbD]; Wih0;Whh0;b0; Wih1;Whh1;b1; Wf; Wg; bj; Wo; bo);
/   cfg = (T; EncD; EmbD; H; J; V; durList; maxSym).
asr.prep: {[W;cfg]
  EmbD:cfg 2; H:cfg 3; J:cfg 4; V:cfg 5
  nout: (V+1) + #cfg 6
  H4: 4*H
  (W 0;
   nn.fn.cols[W 1;H4;EmbD]; nn.fn.cols[W 2;H4;H]; W 3;
   nn.fn.cols[W 4;H4;H];    nn.fn.cols[W 5;H4;H]; W 6;
   nn.fn.cols[W 7;J;cfg 1]; nn.fn.cols[W 8;J;H];  W 9; nn.fn.cols[W 10;nout;J]; W 11)}

/ tdt[enc; P; cfg] → emitted token ids.  enc[T,EncD] is the encoder output;
/ P is asr.prep's column-major weight bundle.
tdt: {[enc;P;cfg]
  asr.td.t::cfg 0; asr.td.encD::cfg 1; asr.td.embD::cfg 2; asr.td.h::cfg 3
  asr.td.vocab::cfg 5; asr.td.dur::cfg 6; asr.td.max::cfg 7
  asr.td.enc::enc; asr.td.emb::P 0
  asr.td.wih0::P 1; asr.td.whh0::P 2; asr.td.lb0::P 3
  asr.td.wih1::P 4; asr.td.whh1::P 5; asr.td.lb1::P 6
  asr.td.jw:: (P 7; P 8; P 9; P 10; P 11)
  h: asr.td.h
  st: (0; 0; h#0.; h#0.; h#0.; h#0.; asr.td.vocab; !0)  / prev = blank, empty emission
  (asr.td.cond asr.td.step/ st) 7}

/ One-shot: prepare the weights, then decode.
tdt.once: {[enc;W;cfg] tdt[enc; asr.prep[W;cfg]; cfg]}

/ ── Weight loading  (safetensors dict → the weight lists the fns expect) ─────
/ `model` is the dict from safetensors.read: symbol name → (`dtype`shape`data).
/ Layout: PyTorch weights are [out,in] row-major — exactly how linear/gemm/conv
/ kernels index them — so a tensor's flat `data` drops straight in (no transpose).
/ The offline export (see doc/parakeet-export.py) renames NeMo params to the names
/ below, sums the LSTM bias_ih+bias_hh, and flattens conv [C,1,3,3]/[C,C,1,1].
asr.ten: {[model; nm] (model[`s$nm])[`data]}

/ conformer block: 37 tensors in conformer.block's WB order (rel-pos attention).
asr.blkSuf: ("ff1.ln.g";"ff1.ln.b";"ff1.w1";"ff1.b1";"ff1.w2";"ff1.b2";
  "attn.ln.g";"attn.ln.b";
  "attn.wq";"attn.bq";"attn.wk";"attn.bk";"attn.wv";"attn.bv";"attn.wo";"attn.bo";
  "attn.wpos";"attn.u";"attn.v";
  "conv.ln.g";"conv.ln.b";"conv.pw1.w";"conv.pw1.b";"conv.dw.w";"conv.dw.b";
  "conv.bn.a";"conv.bn.b";"conv.pw2.w";"conv.pw2.b";
  "ff2.ln.g";"ff2.ln.b";"ff2.w1";"ff2.b1";"ff2.w2";"ff2.b2";
  "norm.g";"norm.b")
asr.encNm: {[i;s] "enc.",($i),".",s}
asr.load.block:   {[model;i] asr.ten[model;]' asr.encNm[i;]' asr.blkSuf}
asr.load.encoder: {[model;nlayers] asr.load.block[model;]' !nlayers}

/ subsampling: 12 tensors in `subsample`'s WB order.
asr.subSuf: ("c0.w";"c0.b";"dw1.w";"dw1.b";"pw1.w";"pw1.b";"dw2.w";"dw2.b";"pw2.w";"pw2.b";"proj.w";"proj.b")
asr.load.subsample: {[model] asr.ten[model;]' "sub." ,/: asr.subSuf}

/ decoder: 12 tensors in `tdt`'s W order (2-layer LSTM predictor + joint).
asr.decSuf: ("dec.emb";
  "dec.wih0";"dec.whh0";"dec.b0"; "dec.wih1";"dec.whh1";"dec.b1";
  "joint.wf";"joint.wg";"joint.bj";"joint.wo";"joint.bo")
asr.load.decoder: {[model] asr.ten[model;]' asr.decSuf}

/ load a vocab file: one piece per line, in id order (from the offline export).
/ NB the split verb must be GLUED (`"\n"\s`): a SPACED `\` parses as the scan adverb
/ instead, which silently returns the whole file as a single line.
asr.load.vocab: {[path] s: 1: path; "\n"\s}

/ ── SentencePiece detokenize  (token ids → text) ─────────────────────────────
/ `vocab` = list of subword pieces (piece id = index), from the model tokenizer.
/ Pieces beginning with ▁ (U+2581 = UTF-8 bytes 226 150 129) start a new word → the
/ marker becomes a leading space; other pieces continue the current word.
asr.spc:: `c$226 150 129                             / the ▁ word-boundary marker
asr.piece:  {[p] $[((#p)>2) & asr.spc~3#p; " ", 3_p; p]}
asr.stripL: {[r] $[0=#r; r; $[" "=*r; 1_r; r]]}      / drop the leading word-space
asr.cat:    {[vocab; ids] ,/ (asr.piece' vocab@ids)} / precompute the each (`,/ f'x` mis-parses)
asr.detok:  {[vocab; ids] $[0=#ids; ""; asr.stripL asr.cat[vocab;ids]]}
