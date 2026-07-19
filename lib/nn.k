/ lib/nn.k — GPU neural-net primitives on the resident-compute stack. In-kernel
/ reductions use the canonical full syntax  +/{[k] e}'!K  (|/ → max), which dye
/ lowers to the rsum/rmax region node (doc/design/kk2.md §2.4-1/§8-3).
/
/ Build first:  zig build gpu
/ Load deps FIRST, then this (nested `2:` loads overflow), e.g.:
/                 2: "lib/dye.k"; 2: "lib/gpu.k"; 2: "lib/nn.k"
/ Run:          inside a window.run loop (compute needs a live device — see test/nn.k)
/
/ All matrices are ROW-MAJOR flat f32 vectors.  Each primitive comes in two forms:
/   Gemm/Softmax/LayerNorm   — host arrays in, host result out (allocates fresh
/                              buffers each call; convenient for one-shot / testing).
/   GemmR                    — resident: operates on GPU buffer handles, no readback
/                              (the form the encoder/decoder chain wants — data stays
/                              on the GPU between layers).
/ Pipelines are compiled ONCE and cached in globals; a 4-float scratch params buffer
/ is reused via gpu.write so a call allocates no per-invocation param buffer.
/
/ gpu.dispatch rounds the grid up to a multiple of 64, and Metal CLAMPS an out-of-bounds
/ store to the last valid index — so every OUTPUT buffer is padded to the launched
/ thread count (`nnPad`) so stray writes land in padding, never clobbering a live
/ element.  OOB input reads clamp harmlessly (their outputs are discarded).

/ round a length up to the launched thread count (grid = ceil(n/64)*64)
nnPad: {[n] 64 * 1 | `i$ (n+63) div 64}

/ ── GEMM  C[M,N] = A[M,K] · B[K,N] ───────────────────────────────────────────
/ One pipeline serves every shape: dims travel in the params buffer g=(M;N;K).
/ thread d → C[d]; i=d div N, j=d mod N; C[d] = Σ_k A[i*K+k]·B[k*N+j].
/ (integer-index dialect: d is i32, dims cast once with `i$, all address math exact)
gemmK: gpu.kernel[{[c;a;b;g;d]
  n:`i$g[1]; kk:`i$g[2]
  i:d div n; j:d mod n
  set[c; d; +/{[k] (a[(i*kk)+k]) * b[(k*n)+j]}'!kk]}; 0; 4]

gPipe::  0    / cached gemm pipeline
gParam:: 0    / cached 4-float params scratch buffer

/ Resident GEMM: bc must already be a buffer of length ≥ nnPad[M*N]; ba/bb hold A/B.
GemmR: {[bc;ba;bb;M;K;N]
  $[gPipe=0;  gPipe::  gpu.compileCompute[gemmK;4]; 0]
  $[gParam=0; gParam:: gpu.buffer[4#0.]; 0]
  gpu.write[gParam; (0.+M),(0.+N),(0.+K),0.]
  gpu.dispatch[gPipe; (bc;ba;bb;gParam); M*N]
  bc}

/ Host convenience: A,B host arrays → C host array (M*N).
Gemm: {[A;B;M;K;N]
  ba:gpu.buffer[A]; bb:gpu.buffer[B]; bc:gpu.buffer[(nnPad[M*N])#0.]
  GemmR[bc;ba;bb;M;K;N]
  (M*N) # gpu.read[bc]}

/ ── Row softmax  (numerically stable: subtract the row max) ───────────────────
/ Two passes: (1) per row i → m[i]=max, s[i]=Σexp(x-m);  (2) per element → exp/s.
smStatK: gpu.kernel[{[mb;sb;x;g;i]
  n:`i$g[0]
  m: |/{[k] x[(i*n)+k]}'!n
  s: +/{[k] exp[(x[(i*n)+k]) - m]}'!n
  set[mb; i; m]; set[sb; i; s]}; 0; 4]
smApplyK: gpu.kernel[{[o;x;mb;sb;g;d]
  n:`i$g[0]; i:d div n
  set[o; d; (exp[(x[d]) - mb[i]]) % sb[i]]}; 0; 5]

smSP::0; smAP::0; smParam::0
/ Resident softmax: bo (≥nnPad[M*N]) = row-softmax of bx; bmax/bsum per-row scratch.
SoftmaxR: {[bo;bx;bmax;bsum;M;N]
  $[smSP=0;    smSP::    gpu.compileCompute[smStatK;4];  0]
  $[smAP=0;    smAP::    gpu.compileCompute[smApplyK;5]; 0]
  $[smParam=0; smParam:: gpu.buffer[4#0.]; 0]
  gpu.write[smParam; (0.+N),(0.+M),0.,0.]
  gpu.dispatch[smSP; (bmax;bsum;bx;smParam); M]
  gpu.dispatch[smAP; (bo;bx;bmax;bsum;smParam); M*N]
  bo}
/ Softmax of X (M rows × N cols) over each row → host array (M*N).
Softmax: {[X;M;N]
  bx:gpu.buffer[X]
  bm:gpu.buffer[(nnPad M)#0.]; bs:gpu.buffer[(nnPad M)#0.]; bo:gpu.buffer[(nnPad[M*N])#0.]
  SoftmaxR[bo;bx;bm;bs;M;N]
  (M*N) # gpu.read[bo]}

/ ── LayerNorm over the last dim  (mean/var per row, affine γ/β per feature) ───
/ Two passes: (1) per row i → mean[i], rstd[i]=1/√(var+eps);  (2) per element →
/ ((x-mean)*rstd)*γ[j] + β[j].
lnStatK: gpu.kernel[{[mb;rb;x;g;i]
  nf:g[0]; eps:g[1]; n:`i$nf              / n indexes (i32); nf divides (f32)
  mean: (+/{[k] x[(i*n)+k]}'!n) % nf
  var:  (+/{[k] sqr[(x[(i*n)+k]) - mean]}'!n) % nf
  set[mb; i; mean]; set[rb; i; 1. % sqrt[var + eps]]}; 0; 4]
lnApplyK: gpu.kernel[{[o;x;mb;rb;gm;bt;g;d]
  n:`i$g[0]; i:d div n; j:d mod n
  nrm: ((x[d]) - mb[i]) * rb[i]
  set[o; d; (nrm * gm[j]) + bt[j]]}; 0; 7]

lnSP::0; lnAP::0; lnParam::0
/ Resident LayerNorm: writes bo (≥nnPad[M*N]); bm/br are per-row scratch (≥nnPad M).
/ cfg=(M;N;eps) — dims are packed because ink lambdas cap at 8 params.
LayerNormR: {[bo;bx;bg;bb;bm;br;cfg]
  M:cfg 0; N:cfg 1; eps:cfg 2
  $[lnSP=0;    lnSP::    gpu.compileCompute[lnStatK;4];  0]
  $[lnAP=0;    lnAP::    gpu.compileCompute[lnApplyK;7]; 0]
  $[lnParam=0; lnParam:: gpu.buffer[4#0.]; 0]
  gpu.write[lnParam; (0.+N),eps,0.,0.]
  gpu.dispatch[lnSP; (bm;br;bx;lnParam); M]
  gpu.dispatch[lnAP; (bo;bx;bm;br;bg;bb;lnParam); M*N]
  bo}
/ LayerNorm of X (M×N) with per-feature gamma G (N) and beta B (N) → host (M*N).
LayerNorm: {[X;G;B;M;N;eps]
  bx:gpu.buffer[X]; bg:gpu.buffer[G]; bb:gpu.buffer[B]
  bm:gpu.buffer[(nnPad M)#0.]; br:gpu.buffer[(nnPad M)#0.]
  bo:gpu.buffer[(nnPad[M*N])#0.]
  LayerNormR[bo;bx;bg;bb;bm;br;(M;N;eps)]
  (M*N) # gpu.read[bo]}

/ ── Linear  Y[M,N] = X[M,K] · Wᵀ + b   (W is [N,K] = PyTorch [out,in]) ─────────
/ Fuses GEMM-with-transposed-B and bias: no host weight transpose, and reading
/ row j of W (w[j*K+k]) is the j-th output's weights.
linK: gpu.kernel[{[o;x;w;b;g;d]
  nn:`i$g[1]; kk:`i$g[2]
  i:d div nn; j:d mod nn
  set[o; d; (+/{[k] (x[(i*kk)+k]) * w[(j*kk)+k]}'!kk) + b[j]]}; 0; 5]
linPipe::0; linParam::0
/ Resident: bo (≥nnPad[M*N]) = bx[M,K] · bw[N,K]ᵀ + bb[N].
LinearR: {[bo;bx;bw;bb;M;K;N]
  $[linPipe=0;  linPipe::  gpu.compileCompute[linK;5]; 0]
  $[linParam=0; linParam:: gpu.buffer[4#0.]; 0]
  gpu.write[linParam; (0.+M),(0.+N),(0.+K),0.]
  gpu.dispatch[linPipe; (bo;bx;bw;bb;linParam); M*N]
  bo}
Linear: {[X;W;B;M;K;N]
  bx:gpu.buffer[X]; bw:gpu.buffer[W]; bb:gpu.buffer[B]; bo:gpu.buffer[(nnPad[M*N])#0.]
  LinearR[bo;bx;bw;bb;M;K;N]
  (M*N) # gpu.read[bo]}

/ ── Elementwise activations + residual (one thread per element) ───────────────
/ SiLU / Swish:  x·σ(x) = x / (1 + e^-x)
siluK: gpu.kernel[{[o;x;d] t:x[d]; set[o; d; t % (1. + exp[0. - t])]}; 0; 2]
/ GELU (tanh approximation):  0.5x(1 + tanh(√(2/π)(x + 0.044715x³)))
geluK: gpu.kernel[{[o;x;d] t:x[d]; c:0.7978845608 * (t + 0.044715*t*t*t); set[o; d; (0.5*t)*(1. + tanh[c])]}; 0; 2]
/ scaled residual:  o = a + s·b   (s in params g[0])
addsK: gpu.kernel[{[o;a;b;g;d] set[o; d; (a[d]) + (g[0])*b[d]]}; 0; 4]

siluPipe::0; geluPipe::0; addsPipe::0; addsParam::0
SiluR: {[bo;bx;n] $[siluPipe=0; siluPipe:: gpu.compileCompute[siluK;2]; 0]; gpu.dispatch[siluPipe;(bo;bx);n]; bo}
GeluR: {[bo;bx;n] $[geluPipe=0; geluPipe:: gpu.compileCompute[geluK;2]; 0]; gpu.dispatch[geluPipe;(bo;bx);n]; bo}
AddScaledR: {[bo;ba;bb;s;n]
  $[addsPipe=0;  addsPipe::  gpu.compileCompute[addsK;4]; 0]
  $[addsParam=0; addsParam:: gpu.buffer[4#0.]; 0]
  gpu.write[addsParam; (0.+s),0.,0.,0.]
  gpu.dispatch[addsPipe; (bo;ba;bb;addsParam); n]
  bo}
Silu: {[X;n] bx:gpu.buffer[X]; bo:gpu.buffer[(nnPad n)#0.]; SiluR[bo;bx;n]; n # gpu.read[bo]}
Gelu: {[X;n] bx:gpu.buffer[X]; bo:gpu.buffer[(nnPad n)#0.]; GeluR[bo;bx;n]; n # gpu.read[bo]}

/ ── Conformer feed-forward sub-block (macaron half-step) ──────────────────────
/   out = x + 0.5 · Linear2( SiLU( Linear1( LayerNorm(x) ) ) )
/ Shapes: X[M,D];  W1[Dff,D],B1[Dff];  W2[D,Dff],B2[D];  gamma GAM[D], beta BET[D].
/ cfg=(M;D;Dff;eps) — packed (ink lambdas cap at 8 params).
FfnBlock: {[X;W1;B1;W2;B2;GAM;BET;cfg]
  M:cfg 0; D:cfg 1; Dff:cfg 2; eps:cfg 3
  bx:gpu.buffer[X]
  bw1:gpu.buffer[W1]; bb1:gpu.buffer[B1]; bw2:gpu.buffer[W2]; bb2:gpu.buffer[B2]
  bgm:gpu.buffer[GAM]; bbt:gpu.buffer[BET]
  h0:gpu.buffer[(nnPad[M*D])#0.]                 / LayerNorm(x)   [M,D]
  bm:gpu.buffer[(nnPad M)#0.]; br:gpu.buffer[(nnPad M)#0.]
  h1:gpu.buffer[(nnPad[M*Dff])#0.]               / Linear1        [M,Dff]
  h2:gpu.buffer[(nnPad[M*Dff])#0.]               / SiLU(h1)       [M,Dff]
  h3:gpu.buffer[(nnPad[M*D])#0.]                 / Linear2        [M,D]
  bo:gpu.buffer[(nnPad[M*D])#0.]
  LayerNormR[h0; bx; bgm; bbt; bm; br; (M;D;eps)]
  LinearR[h1; h0; bw1; bb1; M; D; Dff]
  SiluR[h2; h1; M*Dff]
  LinearR[h3; h2; bw2; bb2; M; Dff; D]
  AddScaledR[bo; bx; h3; 0.5; M*D]
  (M*D) # gpu.read[bo]}

/ ── Multi-head self-attention ────────────────────────────────────────────────
/ Two head-structured batched-matmul kernels (Q/K/V projections and the output
/ projection are plain Linear); softmax over the [H*T,T] score rows reuses SoftmaxR.
/ Indices are i32 (integer-index dialect) — exact for any H*T*T, no 2^24 cliff.
/
/ scores S[h,i,j] = scale · Σ_k Q[i,h·dh+k]·K[j,h·dh+k]   (one thread per H*T*T elem)
attnScoresK: gpu.kernel[{[s;q;kb;g;e]
  T:`i$g[0]; D:`i$g[1]; dh:`i$g[2]; sc:g[3]
  tt: T*T
  h: e div tt; rem: e mod tt
  i: rem div T; j: rem mod T
  base: h*dh
  set[s; e; sc * +/{[k] (q[(i*D)+base+k]) * kb[(j*D)+base+k]}'!dh]}; 0; 4]
/ context C[i,c] = Σ_j A[h,i,j]·V[j,c]  where h = c÷dh   (one thread per T*D elem)
/ writes straight into the concatenated [T,D] layout — no per-head regather.
attnCtxK: gpu.kernel[{[o;a;v;g;e]
  T:`i$g[0]; D:`i$g[1]; dh:`i$g[2]
  i: e div D; c: e mod D
  h: c div dh
  hb: h*T*T
  set[o; e; +/{[j] (a[hb+(i*T)+j]) * v[(j*D)+c]}'!T]}; 0; 4]

asPipe::0; asParam::0; acPipe::0; acParam::0
/ Resident attention scores: bs[H*T*T] = scaled QKᵀ per head.  H = D÷dh.
AttnScoresR: {[bs;bq;bk;T;D;dh;scale]
  $[asPipe=0;  asPipe::  gpu.compileCompute[attnScoresK;4]; 0]
  $[asParam=0; asParam:: gpu.buffer[4#0.]; 0]
  gpu.write[asParam; (0.+T),(0.+D),(0.+dh),scale]
  gpu.dispatch[asPipe; (bs;bq;bk;asParam); (D div dh)*T*T]
  bs}
/ Resident attention context: bc[T,D] = A·V, gathered into concatenated-head layout.
AttnCtxR: {[bc;ba;bv;T;D;dh]
  $[acPipe=0;  acPipe::  gpu.compileCompute[attnCtxK;4]; 0]
  $[acParam=0; acParam:: gpu.buffer[4#0.]; 0]
  gpu.write[acParam; (0.+T),(0.+D),(0.+dh),0.]
  gpu.dispatch[acPipe; (bc;ba;bv;acParam); T*D]
  bc}

/ Mhsa[X; W; cfg] — standard scaled-dot-product self-attention (no rel-pos yet).
/   X[T,D];  W = (Wq;Bq; Wk;Bk; Wv;Bv; Wo;Bo)  (each proj weight is [D,D], bias [D]);
/   cfg = (T; D; H).   Returns [T,D].
/ Chained fully resident: 3 Linear (Q/K/V) → scores → row-softmax → context → Linear.
Mhsa: {[X;W;cfg]
  T:cfg 0; D:cfg 1; H:cfg 2
  dh: D div H
  scale: 1. % sqrt 0.+dh
  bx:gpu.buffer[X]
  bwq:gpu.buffer[W 0]; bbq:gpu.buffer[W 1]; bwk:gpu.buffer[W 2]; bbk:gpu.buffer[W 3]
  bwv:gpu.buffer[W 4]; bbv:gpu.buffer[W 5]; bwo:gpu.buffer[W 6]; bbo:gpu.buffer[W 7]
  bq:gpu.buffer[(nnPad[T*D])#0.]; LinearR[bq;bx;bwq;bbq;T;D;D]
  bk:gpu.buffer[(nnPad[T*D])#0.]; LinearR[bk;bx;bwk;bbk;T;D;D]
  bv:gpu.buffer[(nnPad[T*D])#0.]; LinearR[bv;bx;bwv;bbv;T;D;D]
  bs:gpu.buffer[(nnPad[H*T*T])#0.]; AttnScoresR[bs;bq;bk;T;D;dh;scale]
  bsm:gpu.buffer[(nnPad[H*T*T])#0.]
  bmx:gpu.buffer[(nnPad[H*T])#0.]; bsu:gpu.buffer[(nnPad[H*T])#0.]
  SoftmaxR[bsm;bs;bmx;bsu;H*T;T]
  bc:gpu.buffer[(nnPad[T*D])#0.]; AttnCtxR[bc;bsm;bv;T;D;dh]
  bo:gpu.buffer[(nnPad[T*D])#0.]; LinearR[bo;bc;bwo;bbo;T;D;D]
  (T*D) # gpu.read[bo]}

/ ── Relative-position attention (Transformer-XL / Conformer) ─────────────────
/ score[h,i,j] = scale·Σ_k (q[i,c]+u[c])·k[j,c] + (q[i,c]+v[c])·P[i−j, c]   (c=h·dh+k)
/ P[rel] is the projected sinusoidal positional encoding, rel = i−j indexed at row
/ (i−j)+(T−1) of a [2T−1, D] table (P = posEmb · Wposᵀ).  u,v are learned [D] biases.
nnPosT::0; nnPosD::0
/ sinusoidal positional encoding row for table index idx (relative pos idx−(T−1)):
/ interleaved sin(r·ωk)/cos(r·ωk), ωk = 10000^(−2k/D).
nnPosRow: {[idx]
  r:  (0.+idx) - 0. + nnPosT - 1
  kk: `f$ !nnPosD div 2
  freq: exp (0. - (2. * kk) % 0. + nnPosD) * log 10000.
  ang: r * freq
  ,/ +(sin ang; cos ang)}
nnPosEmb: {[T;D] nnPosT::T; nnPosD::D; ,/ nnPosRow' !(2*T)-1}

/ rel-pos scores: buffers s,q,k,u,v,P + params (T;D;dh;scale).  One thread per H·T·T.
attnScoresRelK: gpu.kernel[{[s;q;kb;u;v;pe;g;e]
  T:`i$g[0]; D:`i$g[1]; dh:`i$g[2]; sc:g[3]
  tt: T*T
  h: e div tt; rem: e mod tt
  i: rem div T; j: rem mod T
  base: h*dh
  prow: (((i-j)+(T-1)) * D)
  set[s; e; sc * +/{[k]
    c: base+k; qc: q[(i*D)+c]
    ((qc + u[c]) * kb[(j*D)+c]) + (qc + v[c]) * pe[prow+c]}'!dh]}; 0; 7]
asrPipe::0; asrParam::0
AttnScoresRelR: {[bs;bq;bk;bu;bv;bpe;cfg]
  $[asrPipe=0;  asrPipe::  gpu.compileCompute[attnScoresRelK;7]; 0]
  $[asrParam=0; asrParam:: gpu.buffer[4#0.]; 0]
  gpu.write[asrParam; (0.+cfg 0),(0.+cfg 1),(0.+cfg 2),cfg 3]
  gpu.dispatch[asrPipe; (bs;bq;bk;bu;bv;bpe;asrParam); ((cfg 1) div (cfg 2))*(cfg 0)*(cfg 0)]
  bs}

/ MhsaRel[X; W; cfg] — rel-pos self-attention.  W = (Wq;Bq;Wk;Bk;Wv;Bv;Wo;Bo; Wpos;
/ u; v)  (Wpos[D,D] projects the sinusoid; u,v are [D]);  cfg=(T;D;H).
MhsaRel: {[X;W;cfg]
  T:cfg 0; D:cfg 1; H:cfg 2
  dh: D div H; scale: 1. % sqrt 0.+dh
  bx:gpu.buffer[X]
  bwq:gpu.buffer[W 0]; bbq:gpu.buffer[W 1]; bwk:gpu.buffer[W 2]; bbk:gpu.buffer[W 3]
  bwv:gpu.buffer[W 4]; bbv:gpu.buffer[W 5]; bwo:gpu.buffer[W 6]; bbo:gpu.buffer[W 7]
  bwp:gpu.buffer[W 8]; bu:gpu.buffer[W 9]; bv:gpu.buffer[W 10]
  bq:gpu.buffer[(nnPad[T*D])#0.];  LinearR[bq;bx;bwq;bbq;T;D;D]
  bk:gpu.buffer[(nnPad[T*D])#0.];  LinearR[bk;bx;bwk;bbk;T;D;D]
  bvv:gpu.buffer[(nnPad[T*D])#0.]; LinearR[bvv;bx;bwv;bbv;T;D;D]
  np: (2*T)-1
  bz:gpu.buffer[D#0.]
  bpe0:gpu.buffer[nnPosEmb[T;D]]
  bpe:gpu.buffer[(nnPad[np*D])#0.]; LinearR[bpe;bpe0;bwp;bz;np;D;D]     / P = posEmb·Wposᵀ
  bs:gpu.buffer[(nnPad[H*T*T])#0.]; AttnScoresRelR[bs;bq;bk;bu;bv;bpe;(T;D;dh;scale)]
  bsm:gpu.buffer[(nnPad[H*T*T])#0.]; bmx:gpu.buffer[(nnPad[H*T])#0.]; bsu:gpu.buffer[(nnPad[H*T])#0.]
  SoftmaxR[bsm;bs;bmx;bsu;H*T;T]
  bc:gpu.buffer[(nnPad[T*D])#0.]; AttnCtxR[bc;bsm;bvv;T;D;dh]
  bo:gpu.buffer[(nnPad[T*D])#0.]; LinearR[bo;bc;bwo;bbo;T;D;D]
  (T*D) # gpu.read[bo]}

/ ── Conformer convolution module ─────────────────────────────────────────────
/ GLU gate: X is [T,2D]; out[t,c] = X[t,c]·σ(X[t,D+c])  (split channels a|b → a·σ(b))
gluK: gpu.kernel[{[o;x;g;e]
  D:`i$g[0]; w2:2*D
  i:e div D; c:e mod D
  a: x[(i*w2)+c]; b: x[(i*w2)+D+c]
  set[o; e; a * 1. % 1. + exp[0. - b]]}; 0; 3]
/ Depthwise 1-D conv (per-channel, zero-padded): out[t,c]=Σ_k x[t+k-pad,c]·W[c,k]+B[c]
dwK: gpu.kernel[{[o;x;w;b;g;e]
  T:`i$g[0]; D:`i$g[1]; ks:`i$g[2]; pad:`i$g[3]
  i:e div D; c:e mod D
  acc: +/{[k]
    tp: (i+k)-pad
    ok: (~(tp<0)) & (tp<T)
    ($[ok; x[(tp*D)+c]; 0.]) * w[(c*ks)+k]}'!ks
  set[o; e; acc + b[c]]}; 0; 5]
/ Per-channel affine (BatchNorm inference folded to scale/shift): out[t,c]=x·A[c]+B[c]
caK: gpu.kernel[{[o;x;a;b;g;e]
  D:`i$g[0]; c:e mod D
  set[o; e; (x[e]*a[c]) + b[c]]}; 0; 5]

gluPipe::0; gluParam::0; dwPipe::0; dwParam::0; caPipe::0; caParam::0
/ GLU:  bx[T,2D] → bo[T,D].
GluR: {[bo;bx;T;D]
  $[gluPipe=0;  gluPipe::  gpu.compileCompute[gluK;3]; 0]
  $[gluParam=0; gluParam:: gpu.buffer[4#0.]; 0]
  gpu.write[gluParam; (0.+D),0.,0.,0.]
  gpu.dispatch[gluPipe; (bo;bx;gluParam); T*D]
  bo}
/ Depthwise conv:  bx[T,D], bw[D,ks], bb[D] → bo[T,D].  pad = (ks-1)÷2 for "same".
DwConvR: {[bo;bx;bw;bb;T;D;ks;pad]
  $[dwPipe=0;  dwPipe::  gpu.compileCompute[dwK;5]; 0]
  $[dwParam=0; dwParam:: gpu.buffer[4#0.]; 0]
  gpu.write[dwParam; (0.+T),(0.+D),(0.+ks),(0.+pad)]
  gpu.dispatch[dwPipe; (bo;bx;bw;bb;dwParam); T*D]
  bo}
/ Channel affine:  bo[T,D] = bx·A[c] + B[c].
ChanAffineR: {[bo;bx;ba;bb;T;D]
  $[caPipe=0;  caPipe::  gpu.compileCompute[caK;5]; 0]
  $[caParam=0; caParam:: gpu.buffer[4#0.]; 0]
  gpu.write[caParam; (0.+D),0.,0.,0.]
  gpu.dispatch[caPipe; (bo;bx;ba;bb;caParam); T*D]
  bo}

/ ConvModule[X; W; cfg] — conformer conv module (residual included).
/   out = x + PW2( Swish( BN( DWConv( GLU( PW1( LayerNorm(x) ) ) ) ) ) )
/   X[T,D];  cfg=(T;D;ks;eps);
/   W = (lnG;lnB;  Wpw1[2D,D];Bpw1[2D];  Wdw[D,ks];Bdw[D];  caA[D];caB[D];  Wpw2[D,D];Bpw2[D])
/ BatchNorm is folded into (caA;caB) = (rstd·γ ; β − μ·rstd·γ) at load time.
ConvModule: {[X;W;cfg]
  T:cfg 0; D:cfg 1; ks:cfg 2; eps:cfg 3
  pad: (ks-1) div 2
  bx:gpu.buffer[X]
  blnG:gpu.buffer[W 0]; blnB:gpu.buffer[W 1]
  bwp1:gpu.buffer[W 2]; bbp1:gpu.buffer[W 3]
  bwdw:gpu.buffer[W 4]; bbdw:gpu.buffer[W 5]
  bcaA:gpu.buffer[W 6]; bcaB:gpu.buffer[W 7]
  bwp2:gpu.buffer[W 8]; bbp2:gpu.buffer[W 9]
  h0:gpu.buffer[(nnPad[T*D])#0.]; bm:gpu.buffer[(nnPad T)#0.]; br:gpu.buffer[(nnPad T)#0.]
  h1:gpu.buffer[(nnPad[T*2*D])#0.]
  h2:gpu.buffer[(nnPad[T*D])#0.]; h3:gpu.buffer[(nnPad[T*D])#0.]
  h4:gpu.buffer[(nnPad[T*D])#0.]; h5:gpu.buffer[(nnPad[T*D])#0.]; h6:gpu.buffer[(nnPad[T*D])#0.]
  bo:gpu.buffer[(nnPad[T*D])#0.]
  LayerNormR[h0; bx; blnG; blnB; bm; br; (T;D;eps)]
  LinearR[h1; h0; bwp1; bbp1; T; D; 2*D]
  GluR[h2; h1; T; D]
  DwConvR[h3; h2; bwdw; bbdw; T; D; ks; pad]
  ChanAffineR[h4; h3; bcaA; bcaB; T; D]
  SiluR[h5; h4; T*D]
  LinearR[h6; h5; bwp2; bbp2; T; D; D]
  AddScaledR[bo; bx; h6; 1.; T*D]
  (T*D) # gpu.read[bo]}

/ ── Full conformer block + encoder stack ─────────────────────────────────────
/ block(x) = ½FFN → (x + MHSA(LayerNorm x)) → ConvModule → ½FFN → LayerNorm
/ (FfnBlock and ConvModule already self-contain their LayerNorm + residual; MHSA
/  is bare, so the block wraps it with a LayerNorm and a residual add.)
/ W = 37-array list, cfg = (T; D; H; Dff; ks; eps):
/   [0..5]   FFN1  : lnG lnB W1[Dff,D] B1 W2[D,Dff] B2
/   [6..7]   attn LayerNorm : lnG lnB
/   [8..18]  MHSA (rel-pos) : Wq Bq Wk Bk Wv Bv Wo Bo  Wpos[D,D]  u[D]  v[D]
/   [19..28] Conv : lnG lnB Wpw1[2D,D] Bpw1 Wdw[D,ks] Bdw caA caB Wpw2[D,D] Bpw2
/   [29..34] FFN2 : lnG lnB W1 B1 W2 B2
/   [35..36] final LayerNorm : lnG lnB
ConformerBlock: {[X;W;cfg]
  T:cfg 0; D:cfg 1; H:cfg 2; Dff:cfg 3; ks:cfg 4; eps:cfg 5
  fc: (T;D;Dff;eps)
  x1: FfnBlock[X; W 2; W 3; W 4; W 5; W 0; W 1; fc]
  att: MhsaRel[LayerNorm[x1; W 6; W 7; T; D; eps]; W@8+!11; (T;D;H)]
  x2: x1 + att
  x3: ConvModule[x2; W@19+!10; (T;D;ks;eps)]
  x4: FfnBlock[x3; W 31; W 32; W 33; W 34; W 29; W 30; fc]
  LayerNorm[x4; W 35; W 36; T; D; eps]}

/ Encoder: fold ConformerBlock over a list of per-layer weight lists (X + Ws → out).
cbCfg:: 0
cbStep: {[x;w] ConformerBlock[x; w; cbCfg]}   / top-level dyad (lambdas can't close over cfg)
Encoder: {[X; Ws; cfg] cbCfg:: cfg; X cbStep/ Ws}

/ ── Resident encoder (resident weights + activations): keep weights AND activations on-device ──
/ The host composites above upload every weight and read back the activation between
/ each of the ~17 conformer blocks — so a stacked encoder re-uploads all weights and
/ round-trips the [T,D] activation once PER layer. The resident forms below take the
/ INPUT as a buffer handle, resident WEIGHT handles (uploaded ONCE via nnHold), and
/ return an OUTPUT handle — no host round-trip between blocks. Each frees its own
/ scratch with gpu.free (kk2 §1), so memory stays bounded across a deep stack. The
/ kernels and dispatch sizes are IDENTICAL to the host path, so EncoderR is bit-for-
/ bit equal to Encoder (host round-trips are lossless f32 copies — the oracle).
nnHold:   {[arrs] gpu.buffer' arrs}                / list of host arrays → resident handles
nnHoldWs: {[Ws] nnHold' Ws}                        / per-layer weight lists → handle lists

/ Resident FFN block (macaron half-step). WB = (W1;B1;W2;B2;GAM;BET) handles; returns bo.
FfnBlockRB: {[bx; WB; cfg]
  M:cfg 0; D:cfg 1; Dff:cfg 2; eps:cfg 3
  bw1:WB 0; bb1:WB 1; bw2:WB 2; bb2:WB 3; bgm:WB 4; bbt:WB 5
  h0:gpu.buffer[(nnPad[M*D])#0.]; bm:gpu.buffer[(nnPad M)#0.]; br:gpu.buffer[(nnPad M)#0.]
  h1:gpu.buffer[(nnPad[M*Dff])#0.]; h2:gpu.buffer[(nnPad[M*Dff])#0.]; h3:gpu.buffer[(nnPad[M*D])#0.]
  bo:gpu.buffer[(nnPad[M*D])#0.]
  LayerNormR[h0; bx; bgm; bbt; bm; br; (M;D;eps)]
  LinearR[h1; h0; bw1; bb1; M; D; Dff]
  SiluR[h2; h1; M*Dff]
  LinearR[h3; h2; bw2; bb2; M; Dff; D]
  AddScaledR[bo; bx; h3; 0.5; M*D]
  gpu.free'(h0;bm;br;h1;h2;h3)
  bo}

/ Resident rel-pos MHSA. WB = 11 handles (Wq;Bq;Wk;Bk;Wv;Bv;Wo;Bo; Wpos; u; v); returns bo.
MhsaRelRB: {[bx; WB; cfg]
  T:cfg 0; D:cfg 1; H:cfg 2
  dh: D div H; scale: 1. % sqrt 0.+dh
  bwq:WB 0; bbq:WB 1; bwk:WB 2; bbk:WB 3; bwv:WB 4; bbv:WB 5; bwo:WB 6; bbo:WB 7
  bwp:WB 8; bu:WB 9; bv:WB 10
  bq:gpu.buffer[(nnPad[T*D])#0.];  LinearR[bq;bx;bwq;bbq;T;D;D]
  bk:gpu.buffer[(nnPad[T*D])#0.];  LinearR[bk;bx;bwk;bbk;T;D;D]
  bvv:gpu.buffer[(nnPad[T*D])#0.]; LinearR[bvv;bx;bwv;bbv;T;D;D]
  np: (2*T)-1
  bz:gpu.buffer[D#0.]
  bpe0:gpu.buffer[nnPosEmb[T;D]]
  bpe:gpu.buffer[(nnPad[np*D])#0.]; LinearR[bpe;bpe0;bwp;bz;np;D;D]
  bs:gpu.buffer[(nnPad[H*T*T])#0.]; AttnScoresRelR[bs;bq;bk;bu;bv;bpe;(T;D;dh;scale)]
  bsm:gpu.buffer[(nnPad[H*T*T])#0.]; bmx:gpu.buffer[(nnPad[H*T])#0.]; bsu:gpu.buffer[(nnPad[H*T])#0.]
  SoftmaxR[bsm;bs;bmx;bsu;H*T;T]
  bc:gpu.buffer[(nnPad[T*D])#0.]; AttnCtxR[bc;bsm;bvv;T;D;dh]
  bo:gpu.buffer[(nnPad[T*D])#0.]; LinearR[bo;bc;bwo;bbo;T;D;D]
  gpu.free'(bq;bk;bvv;bz;bpe0;bpe;bs;bsm;bmx;bsu;bc)
  bo}

/ Resident conv module (residual included). WB = 10 handles (lnG;lnB;Wpw1;Bpw1;Wdw;Bdw;caA;caB;Wpw2;Bpw2).
ConvModuleRB: {[bx; WB; cfg]
  T:cfg 0; D:cfg 1; ks:cfg 2; eps:cfg 3
  pad: (ks-1) div 2
  blnG:WB 0; blnB:WB 1; bwp1:WB 2; bbp1:WB 3; bwdw:WB 4; bbdw:WB 5; bcaA:WB 6; bcaB:WB 7; bwp2:WB 8; bbp2:WB 9
  h0:gpu.buffer[(nnPad[T*D])#0.]; bm:gpu.buffer[(nnPad T)#0.]; br:gpu.buffer[(nnPad T)#0.]
  h1:gpu.buffer[(nnPad[T*2*D])#0.]
  h2:gpu.buffer[(nnPad[T*D])#0.]; h3:gpu.buffer[(nnPad[T*D])#0.]
  h4:gpu.buffer[(nnPad[T*D])#0.]; h5:gpu.buffer[(nnPad[T*D])#0.]; h6:gpu.buffer[(nnPad[T*D])#0.]
  bo:gpu.buffer[(nnPad[T*D])#0.]
  LayerNormR[h0; bx; blnG; blnB; bm; br; (T;D;eps)]
  LinearR[h1; h0; bwp1; bbp1; T; D; 2*D]
  GluR[h2; h1; T; D]
  DwConvR[h3; h2; bwdw; bbdw; T; D; ks; pad]
  ChanAffineR[h4; h3; bcaA; bcaB; T; D]
  SiluR[h5; h4; T*D]
  LinearR[h6; h5; bwp2; bbp2; T; D; D]
  AddScaledR[bo; bx; h6; 1.; T*D]
  gpu.free'(h0;bm;br;h1;h2;h3;h4;h5;h6)
  bo}

/ Resident conformer block: bx handle + WB (37 resident weight handles) → bo handle.
ConformerBlockRB: {[bx; WB; cfg]
  T:cfg 0; D:cfg 1; H:cfg 2; Dff:cfg 3; ks:cfg 4; eps:cfg 5
  fc: (T;D;Dff;eps)
  b1: FfnBlockRB[bx; (WB 2;WB 3;WB 4;WB 5;WB 0;WB 1); fc]
  / attn LayerNorm(x1) resident
  bln:gpu.buffer[(nnPad[T*D])#0.]; am:gpu.buffer[(nnPad T)#0.]; ar:gpu.buffer[(nnPad T)#0.]
  LayerNormR[bln; b1; WB 6; WB 7; am; ar; (T;D;eps)]
  batt: MhsaRelRB[bln; WB@8+!11; (T;D;H)]
  bx2:gpu.buffer[(nnPad[T*D])#0.]; AddScaledR[bx2; b1; batt; 1.; T*D]
  bx3: ConvModuleRB[bx2; WB@19+!10; (T;D;ks;eps)]
  bx4: FfnBlockRB[bx3; (WB 31;WB 32;WB 33;WB 34;WB 29;WB 30); fc]
  bo:gpu.buffer[(nnPad[T*D])#0.]; bfm:gpu.buffer[(nnPad T)#0.]; bfr:gpu.buffer[(nnPad T)#0.]
  LayerNormR[bo; bx4; WB 35; WB 36; bfm; bfr; (T;D;eps)]
  gpu.free'(b1;bln;am;ar;batt;bx2;bx3;bx4;bfm;bfr)
  bo}

/ Resident block step: produce bo, free the (owned) input handle. cbwB set by EncoderR.
cbStepRB: {[bx;wb] bo: ConformerBlockRB[bx; wb; cbCfg]; gpu.free bx; bo}
/ EncoderR[X; Ws; cfg] — resident conformer stack. Uploads all weights ONCE, keeps the
/ activation resident across layers, reads back the final [T,D] and frees everything.
/ Bit-identical to Encoder (same kernels; only the host round-trips are removed).
EncoderR: {[X; Ws; cfg]
  cbCfg:: cfg
  WB: nnHoldWs Ws
  bx: gpu.buffer[X]
  bo: bx cbStepRB/ WB
  r: ((cfg 0)*(cfg 1)) # gpu.read bo
  gpu.free bo
  gpu.free' ,/ WB
  r}

/ ── Log-mel featurizer  (audio samples → log-mel spectrogram) ────────────────
/ STFT power via one kernel (framing folded in), mel projection = a GEMM, then log.
/ The Hann window / DFT basis / mel filterbank are precomputed host-side below; in a
/ real pipeline you'd ship the mel matrix from the offline export (librosa/NeMo).
nnPI:: 3.14159265358979

/ frames produced from n samples given window/hop ("valid" framing).
nnFrames: {[n;win;hop] 1 + (n - win) div hop}

/ Hann window of length win.
nnHann: {[win] 0.5 - 0.5 * cos (2. * nnPI * `f$!win) % (0. + win - 1)}

/ DFT basis folded with the window → (Cr;Ci), each [nfreq,win] flat, nfreq=nfft÷2+1.
/ Cr[k,t]=cos(2πkt/nfft)·w[t];  Ci[k,t]=−sin(2πkt/nfft)·w[t].
nnWin::0; nnNfft::0; nnWnd::()
nnCrRow: {[k] (cos (2. * nnPI * k * `f$!nnWin) % (0. + nnNfft)) * nnWnd}
nnCiRow: {[k] (0. - sin (2. * nnPI * k * `f$!nnWin) % (0. + nnNfft)) * nnWnd}
nnDft: {[nfft; win; wnd]
  nnNfft:: nfft; nnWin:: win; nnWnd:: wnd
  nfreq: (nfft div 2) + 1
  (,/ nnCrRow' !nfreq; ,/ nnCiRow' !nfreq)}

/ Triangular mel filterbank → [nmels,nfreq] flat.
nnHz2Mel: {[f] 2595. * (log 1. + f % 700.) % log 10.}
nnMel2Hz: {[m] 700. * (exp (m * log 10.) % 2595.) - 1.}
nnNfreq::0; nnBpts::()
nnMelRow: {[m] b: `f$!nnNfreq; lo:nnBpts m; mi:nnBpts m+1; hi:nnBpts m+2
  0. | ((b-lo)%mi-lo) & (hi-b)%hi-mi}
nnMelFb: {[sr; nfft; nmels; fmin; fmax]
  nnNfreq:: (nfft div 2) + 1
  mmin: nnHz2Mel fmin; mmax: nnHz2Mel fmax
  mpts: mmin + (mmax - mmin) * (`f$!nmels+2) % (0. + nmels + 1)
  fpts: nnMel2Hz' mpts
  nnBpts:: (0. + nfft) * fpts % (0. + sr)
  ,/ nnMelRow' !nmels}

/ STFT power: pw[f,k] = re²+im², re=Σ_t sig[f·hop+t]·Cr[k,t]  (one thread per frame×freq)
stftPowerK: gpu.kernel[{[pw;sig;cr;ci;g;e]
  hop:`i$g[0]; win:`i$g[1]; nf:`i$g[2]
  f:e div nf; k:e mod nf
  base: f*hop; kb: k*win
  re: +/{[t] (sig[base+t]) * cr[kb+t]}'!win
  im: +/{[t] (sig[base+t]) * ci[kb+t]}'!win
  set[pw; e; (re*re) + im*im]}; 0; 5]
/ log with a floor:  o = log(x + eps)
logK: gpu.kernel[{[o;x;g;e] set[o; e; log[(x[e]) + g[0]]]}; 0; 3]

spPipe::0; spParam::0; logPipe::0; logParam::0
StftPowerR: {[bpw;bsig;bcr;bci;hop;win;nf;nfr]
  $[spPipe=0;  spPipe::  gpu.compileCompute[stftPowerK;5]; 0]
  $[spParam=0; spParam:: gpu.buffer[4#0.]; 0]
  gpu.write[spParam; (0.+hop),(0.+win),(0.+nf),0.]
  gpu.dispatch[spPipe; (bpw;bsig;bcr;bci;spParam); nfr*nf]
  bpw}
LogEpsR: {[bo;bx;eps;n]
  $[logPipe=0;  logPipe::  gpu.compileCompute[logK;3]; 0]
  $[logParam=0; logParam:: gpu.buffer[4#0.]; 0]
  gpu.write[logParam; (0.+eps),0.,0.,0.]
  gpu.dispatch[logPipe; (bo;bx;logParam); n]
  bo}

/ LogMel[sig; Cr; Ci; MelFb; cfg] cfg=(hop;win;nfreq;nmels;nframes;eps) → [nframes*nmels].
/ Chain: STFT power → mel projection (Linear, zero bias) → log(·+eps).
LogMel: {[sig; Cr; Ci; MelFb; cfg]
  hop:cfg 0; win:cfg 1; nf:cfg 2; nm:cfg 3; nfr:cfg 4; eps:cfg 5
  bsig:gpu.buffer[sig]; bcr:gpu.buffer[Cr]; bci:gpu.buffer[Ci]; bmf:gpu.buffer[MelFb]
  bz:gpu.buffer[nm#0.]
  bpw:gpu.buffer[(nnPad[nfr*nf])#0.]
  StftPowerR[bpw;bsig;bcr;bci;hop;win;nf;nfr]
  bmel:gpu.buffer[(nnPad[nfr*nm])#0.]
  LinearR[bmel;bpw;bmf;bz;nfr;nf;nm]
  bout:gpu.buffer[(nnPad[nfr*nm])#0.]
  LogEpsR[bout;bmel;eps;nfr*nm]
  (nfr*nm) # gpu.read[bout]}

/ ── Conv subsampling  (mel spectrogram → 8×-downsampled encoder input) ───────
/ 2-D conv, kernel 3, stride 2, pad 1.  Layout [C,T,F] channel-major flat.
/ conv output size s(n) = (n+2·1−3)÷2 + 1 = 1 + (n−1)÷2.
nnSub2: {[n] 1 + (n-1) div 2}

/ regular conv2d 1→C:  out[oc,t',f'] = b[oc] + Σ_{kt,kf} in[2t'+kt−1, 2f'+kf−1]·W[oc,kt,kf]
conv2dK: gpu.kernel[{[o;x;w;b;g;e]
  C:`i$g[0]; Tout:`i$g[1]; Fout:`i$g[2]; Tin:`i$g[3]; Fin:`i$g[4]
  tf: Tout*Fout
  oc: e div tf; rem: e mod tf
  tp: rem div Fout; fp: rem mod Fout
  set[o; e; (b[oc]) + +/{[kk]
    kt: kk div 3; kf: kk mod 3
    ti: ((2*tp)+kt)-1; fi: ((2*fp)+kf)-1
    ok: (~(ti<0)) & (ti<Tin) & (~(fi<0)) & (fi<Fin)
    ($[ok; x[(ti*Fin)+fi]; 0.]) * w[(oc*9)+kk]}'!9]}; 0; 5]
/ depthwise conv2d C→C (per channel):  reads input channel c only.
dwConv2dK: gpu.kernel[{[o;x;w;b;g;e]
  C:`i$g[0]; Tout:`i$g[1]; Fout:`i$g[2]; Tin:`i$g[3]; Fin:`i$g[4]
  tf: Tout*Fout
  c: e div tf; rem: e mod tf
  tp: rem div Fout; fp: rem mod Fout
  cin: c*Tin*Fin
  set[o; e; (b[c]) + +/{[kk]
    kt: kk div 3; kf: kk mod 3
    ti: ((2*tp)+kt)-1; fi: ((2*fp)+kf)-1
    ok: (~(ti<0)) & (ti<Tin) & (~(fi<0)) & (fi<Fin)
    ($[ok; x[cin+(ti*Fin)+fi]; 0.]) * w[(c*9)+kk]}'!9]}; 0; 5]
/ pointwise conv2d C→C (1×1) = per-position channel linear.
pwConv2dK: gpu.kernel[{[o;x;w;b;g;e]
  C:`i$g[0]; T:`i$g[1]; F:`i$g[2]
  tf: T*F
  oc: e div tf; pos: e mod tf
  set[o; e; (b[oc]) + +/{[ic] (x[(ic*tf)+pos]) * w[(oc*C)+ic]}'!C]}; 0; 5]
/ ReLU  (shader `|` is logical-or, not max — use the max builtin)
reluK: gpu.kernel[{[o;x;e] set[o; e; max[0.; x[e]]]}; 0; 2]
/ flatten [C,Tp,Fp] → [Tp, C·Fp]  (out[t',c·Fp+f'] = in[c,t',f'])
flattenK: gpu.kernel[{[o;x;g;e]
  C:`i$g[0]; Tp:`i$g[1]; Fp:`i$g[2]
  cf: C*Fp
  tpp: e div cf; rem: e mod cf
  c: rem div Fp; fp: rem mod Fp
  set[o; e; x[(c*Tp*Fp)+(tpp*Fp)+fp]]}; 0; 3]

c2Pipe::0; c2Param::0; dw2Pipe::0; dw2Param::0; pw2Pipe::0; pw2Param::0
reluPipe::0; flPipe::0; flParam::0
Conv2dR: {[bo;bin;bw;bb;cfg]
  $[c2Pipe=0;  c2Pipe::  gpu.compileCompute[conv2dK;5]; 0]
  $[c2Param=0; c2Param:: gpu.buffer[8#0.]; 0]
  gpu.write[c2Param; (0.+cfg 0),(0.+cfg 1),(0.+cfg 2),(0.+cfg 3),(0.+cfg 4),0.,0.,0.]
  gpu.dispatch[c2Pipe; (bo;bin;bw;bb;c2Param); (cfg 0)*(cfg 1)*(cfg 2)]
  bo}
DwConv2dR: {[bo;bin;bw;bb;cfg]
  $[dw2Pipe=0;  dw2Pipe::  gpu.compileCompute[dwConv2dK;5]; 0]
  $[dw2Param=0; dw2Param:: gpu.buffer[8#0.]; 0]
  gpu.write[dw2Param; (0.+cfg 0),(0.+cfg 1),(0.+cfg 2),(0.+cfg 3),(0.+cfg 4),0.,0.,0.]
  gpu.dispatch[dw2Pipe; (bo;bin;bw;bb;dw2Param); (cfg 0)*(cfg 1)*(cfg 2)]
  bo}
PwConv2dR: {[bo;bin;bw;bb;C;T;F]
  $[pw2Pipe=0;  pw2Pipe::  gpu.compileCompute[pwConv2dK;5]; 0]
  $[pw2Param=0; pw2Param:: gpu.buffer[4#0.]; 0]
  gpu.write[pw2Param; (0.+C),(0.+T),(0.+F),0.]
  gpu.dispatch[pw2Pipe; (bo;bin;bw;bb;pw2Param); C*T*F]
  bo}
ReluR: {[bo;bx;n] $[reluPipe=0; reluPipe:: gpu.compileCompute[reluK;2]; 0]; gpu.dispatch[reluPipe;(bo;bx);n]; bo}
FlattenR: {[bo;bin;C;Tp;Fp]
  $[flPipe=0;  flPipe::  gpu.compileCompute[flattenK;3]; 0]
  $[flParam=0; flParam:: gpu.buffer[4#0.]; 0]
  gpu.write[flParam; (0.+C),(0.+Tp),(0.+Fp),0.]
  gpu.dispatch[flPipe; (bo;bin;flParam); Tp*C*Fp]
  bo}

/ ConvSubsample[MEL; W; cfg] — dw_striding 8× subsampling → [T/8, D].
/   MEL[Tin,Fin] (1-channel log-mel); cfg=(Tin;Fin;C;D);
/   W = (Wc[C,9];Bc; Wdw1[C,9];Bdw1; Wpw1[C,C];Bpw1; Wdw2[C,9];Bdw2; Wpw2[C,C];Bpw2;
/        Wproj[D, C·F3];Bproj)   (12 arrays)
ConvSubsample: {[MEL;W;cfg]
  Ti:cfg 0; Fi:cfg 1; C:cfg 2; D:cfg 3
  T1:nnSub2 Ti; F1:nnSub2 Fi; T2:nnSub2 T1; F2:nnSub2 F1; T3:nnSub2 T2; F3:nnSub2 F2
  bmel:gpu.buffer[MEL]
  bw0:gpu.buffer[W 0]; bb0:gpu.buffer[W 1]
  bwd1:gpu.buffer[W 2]; bbd1:gpu.buffer[W 3]; bwp1:gpu.buffer[W 4]; bbp1:gpu.buffer[W 5]
  bwd2:gpu.buffer[W 6]; bbd2:gpu.buffer[W 7]; bwp2:gpu.buffer[W 8]; bbp2:gpu.buffer[W 9]
  bwpr:gpu.buffer[W 10]; bbpr:gpu.buffer[W 11]
  h1:gpu.buffer[(nnPad[C*T1*F1])#0.]; Conv2dR[h1;bmel;bw0;bb0;(C;T1;F1;Ti;Fi)]
  r1:gpu.buffer[(nnPad[C*T1*F1])#0.]; ReluR[r1;h1;C*T1*F1]
  h2:gpu.buffer[(nnPad[C*T2*F2])#0.]; DwConv2dR[h2;r1;bwd1;bbd1;(C;T2;F2;T1;F1)]
  p2:gpu.buffer[(nnPad[C*T2*F2])#0.]; PwConv2dR[p2;h2;bwp1;bbp1;C;T2;F2]
  r2:gpu.buffer[(nnPad[C*T2*F2])#0.]; ReluR[r2;p2;C*T2*F2]
  h3:gpu.buffer[(nnPad[C*T3*F3])#0.]; DwConv2dR[h3;r2;bwd2;bbd2;(C;T3;F3;T2;F2)]
  p3:gpu.buffer[(nnPad[C*T3*F3])#0.]; PwConv2dR[p3;h3;bwp2;bbp2;C;T3;F3]
  r3:gpu.buffer[(nnPad[C*T3*F3])#0.]; ReluR[r3;p3;C*T3*F3]
  Kf: C*F3
  hf:gpu.buffer[(nnPad[T3*Kf])#0.]; FlattenR[hf;r3;C;T3;F3]
  bo:gpu.buffer[(nnPad[T3*D])#0.]; LinearR[bo;hf;bwpr;bbpr;T3;Kf;D]
  (T3*D) # gpu.read[bo]}

/ ── TDT decoder (host greedy loop) ──────────────────────────────────────────
/ The transducer decode is SEQUENTIAL with tiny per-step work + data-dependent
/ control flow (emit/blank, variable frame advance) → GPU buys nothing; this runs
/ host-side (pure k), using the host `while` adverb.  Encoder = the parallel part.
nnSig:  {[v] 1. % 1. + exp 0. - v}
nnTanh: {[v] e: exp 2.*v; (e-1.) % e+1.}
nnMvd:  {[W;k;x;o] +/ x * W@(o*k)+!k}
nnMv:   {[W;n;k;x] nnMvd[W;k;x;]' !n}        / matrix-vector  W[n,k]·x
nnAmax: {[v] v ? |/v}                         / argmax = index of first max

/ LSTM cell step: (x[E],h[H],c[H]) → (h'[H]; c'[H]).  Wih[4H,E], Whh[4H,H], b[4H].
nnLstm: {[x;h;c;Wih;Whh;b;H]
  pre: b + (nnMv[Wih;4*H;#x;x]) + nnMv[Whh;4*H;H;h]
  ig: nnSig pre@!H
  fg: nnSig pre@H+!H
  gg: nnTanh pre@(2*H)+!H
  og: nnSig pre@(3*H)+!H
  nc: (fg*c) + ig*gg
  (og * nnTanh nc; nc)}

/ TDT joint: (enc_t[Fe], g[H]) → logits[nout].  JW=(Wf[J,Fe];Wg[J,H];bj[J];Wo[nout,J];bo[nout]).
nnJoint: {[enc;g;JW;dims]
  J:dims 0; nout:dims 1
  jj: nnTanh (JW 2) + (nnMv[JW 0;J;#enc;enc]) + nnMv[JW 1;J;#g;g]
  (JW 4) + nnMv[JW 3;nout;J;jj]}

/ decode state = (t; u; h; c; prev; emitted).  Weights/config in globals (the while
/ body is single-arg; blank token id = tdVocab, last of the vocab+1 token slots).
tdEnc::(); tdEmb::(); tdWih::(); tdWhh::(); tdLb::(); tdJW::(); tdJd::()
tdDur::(); tdVocab::0; tdT::0; tdH::0; tdEncD::0; tdEmbD::0; tdMax::0
tdStep: {[st]
  t:st 0; u:st 1; h:st 2; c:st 3; prev:st 4; em:st 5
  x: tdEmb@(prev*tdEmbD)+!tdEmbD
  hc: nnLstm[x;h;c;tdWih;tdWhh;tdLb;tdH]; nh:hc 0; nc:hc 1
  enc: tdEnc@(t*tdEncD)+!tdEncD
  lg: nnJoint[enc; nh; tdJW; tdJd]
  tok: nnAmax lg@!tdVocab+1
  dur: tdDur nnAmax lg@(tdVocab+1)+!#tdDur
  blank: tok = tdVocab
  em2:   $[blank; em;   em,tok]           / host $ is lazy — no join on blank
  prev2: $[blank; prev; tok]
  h2:    $[blank; h;    nh]               / predictor state advances only on emit
  c2:    $[blank; c;    nc]
  adv:   $[dur>0; dur; $[~((u+1)<tdMax); 1; 0]]   / dur=0 stall → force advance at tdMax (no >= in ink)
  u2:    $[adv>0; 0; u+1]
  (t+adv; u2; h2; c2; prev2; em2)}
tdCond: {[st] (st 0) < tdT}

/ TdtGreedy[enc; W; cfg] → emitted token ids.
/   enc[T,EncD] encoder output;  W = (Emb[V,EmbD]; Wih; Whh; Lb; Wf; Wg; bj; Wo; bo);
/   cfg = (T; EncD; EmbD; H; J; V; durList; maxSym).
TdtGreedy: {[enc;W;cfg]
  tdEnc::enc; tdEmb::W 0; tdWih::W 1; tdWhh::W 2; tdLb::W 3
  tdJW:: (W 4; W 5; W 6; W 7; W 8)
  tdT::cfg 0; tdEncD::cfg 1; tdEmbD::cfg 2; tdH::cfg 3
  tdVocab::cfg 5; tdDur::cfg 6; tdMax::cfg 7
  tdJd:: (cfg 4; (tdVocab+1) + #tdDur)
  st: (0; 0; tdH#0.; tdH#0.; tdVocab; !0)      / prev = blank, empty emission
  (tdCond tdStep/ st) 5}

/ ── Weight loading  (safetensors dict → the weight lists the nn fns expect) ───
/ `model` is the dict from safetensors.read: symbol name → (`dtype`shape`data).
/ Layout: PyTorch weights are [out,in] row-major — exactly how LinearR/GemmR/conv
/ kernels index them — so a tensor's flat `data` drops straight in (no transpose).
/ The offline export (see doc/parakeet-export.py) renames NeMo params to the names
/ below, sums the LSTM bias_ih+bias_hh, and flattens conv [C,1,3,3]/[C,C,1,1].
nnTen: {[model; nm] (model[`s$nm])[`data]}

/ conformer block: 37 tensors in ConformerBlock's W order (rel-pos attention).
nnBlkSuf: ("ff1.ln.g";"ff1.ln.b";"ff1.w1";"ff1.b1";"ff1.w2";"ff1.b2";
  "attn.ln.g";"attn.ln.b";
  "attn.wq";"attn.bq";"attn.wk";"attn.bk";"attn.wv";"attn.bv";"attn.wo";"attn.bo";
  "attn.wpos";"attn.u";"attn.v";
  "conv.ln.g";"conv.ln.b";"conv.pw1.w";"conv.pw1.b";"conv.dw.w";"conv.dw.b";
  "conv.bn.a";"conv.bn.b";"conv.pw2.w";"conv.pw2.b";
  "ff2.ln.g";"ff2.ln.b";"ff2.w1";"ff2.b1";"ff2.w2";"ff2.b2";
  "norm.g";"norm.b")
nnEncNm: {[i;s] "enc.",($i),".",s}
nnLoadBlock:   {[model;i] nnTen[model;]' nnEncNm[i;]' nnBlkSuf}
nnLoadEncoder: {[model;nlayers] nnLoadBlock[model;]' !nlayers}

/ subsampling: 12 tensors in ConvSubsample's W order.
nnSubSuf: ("c0.w";"c0.b";"dw1.w";"dw1.b";"pw1.w";"pw1.b";"dw2.w";"dw2.b";"pw2.w";"pw2.b";"proj.w";"proj.b")
nnLoadSubsample: {[model] nnTen[model;]' "sub." ,/: nnSubSuf}

/ decoder: 9 tensors in TdtGreedy's W order (LSTM predictor + joint).
nnDecSuf: ("dec.emb";"dec.wih";"dec.whh";"dec.b";"joint.wf";"joint.wg";"joint.bj";"joint.wo";"joint.bo")
nnLoadDecoder: {[model] nnTen[model;]' nnDecSuf}

/ ── SentencePiece detokenize  (token ids → text) ─────────────────────────────
/ `vocab` = list of subword pieces (piece id = index), from the model tokenizer.
/ Pieces beginning with ▁ (U+2581 = UTF-8 bytes 226 150 129) start a new word → the
/ marker becomes a leading space; other pieces continue the current word.
nnSpc:: `c$226 150 129                              / the ▁ word-boundary marker
nnPiece:  {[p] $[((#p)>2) & nnSpc~3#p; " ", 3_p; p]}
nnStripL: {[r] $[0=#r; r; $[" "=*r; 1_r; r]]}       / drop the leading word-space
nnCat:    {[vocab; ids] ,/ (nnPiece' vocab@ids)}    / precompute the each (`,/ f'x` mis-parses)
nnDetok:  {[vocab; ids] $[0=#ids; ""; nnStripL nnCat[vocab;ids]]}
/ load a vocab file: one piece per line, in id order (from the offline export).
nnLoadVocab: {[path] "\n" \ 1: path}
