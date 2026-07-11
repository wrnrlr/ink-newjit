/ lib/nn.k — GPU neural-net primitives on the resident-compute + rsum loop stack.
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
/ is reused via WriteBuffer so a call allocates no per-invocation param buffer.
/
/ Dispatch rounds the grid up to a multiple of 64, and Metal CLAMPS an out-of-bounds
/ store to the last valid index — so every OUTPUT buffer is padded to the launched
/ thread count (`nnPad`) so stray writes land in padding, never clobbering a live
/ element.  OOB input reads clamp harmlessly (their outputs are discarded).

/ round a length up to the launched thread count (grid = ceil(n/64)*64)
nnPad: {[n] 64 * 1 | `i$ (n+63) div 64}

/ ── GEMM  C[M,N] = A[M,K] · B[K,N] ───────────────────────────────────────────
/ One pipeline serves every shape: dims travel in the params buffer g=(M;N;K).
/ thread d → C[d]; i=d/N, j=d%N; C[d] = Σ_k A[i*K+k]·B[k*N+j].
gemmK: GpKernel[{[c;a;b;g;d]
  n:g[1]; kk:g[2]
  i:floor[d%n]; j:mod[d;n]
  set[c; d; rsum[kk; {[k] (a[(i*kk)+k]) * b[(k*n)+j]}]]}; 0; 4]

gPipe::  0    / cached gemm pipeline
gParam:: 0    / cached 4-float params scratch buffer

/ Resident GEMM: bc must already be a buffer of length ≥ nnPad[M*N]; ba/bb hold A/B.
GemmR: {[bc;ba;bb;M;K;N]
  $[gPipe=0;  gPipe::  CompileCompute[gemmK;4]; 0]
  $[gParam=0; gParam:: NewBuffer[4#0.]; 0]
  WriteBuffer[gParam; (0.+M),(0.+N),(0.+K),0.]
  Dispatch[gPipe; (bc;ba;bb;gParam); M*N]
  bc}

/ Host convenience: A,B host arrays → C host array (M*N).
Gemm: {[A;B;M;K;N]
  ba:NewBuffer[A]; bb:NewBuffer[B]; bc:NewBuffer[(nnPad[M*N])#0.]
  GemmR[bc;ba;bb;M;K;N]
  (M*N) # ReadBuffer[bc]}

/ ── Row softmax  (numerically stable: subtract the row max) ───────────────────
/ Two passes: (1) per row i → m[i]=max, s[i]=Σexp(x-m);  (2) per element → exp/s.
smStatK: GpKernel[{[mb;sb;x;g;i]
  n:g[0]
  m: rmax[n; {[k] x[(i*n)+k]}]
  s: rsum[n; {[k] exp[(x[(i*n)+k]) - m]}]
  set[mb; i; m]; set[sb; i; s]}; 0; 4]
smApplyK: GpKernel[{[o;x;mb;sb;g;d]
  n:g[0]; i:floor[d%n]
  set[o; d; (exp[(x[d]) - mb[i]]) % sb[i]]}; 0; 5]

smSP::0; smAP::0; smParam::0
/ Resident softmax: bo (≥nnPad[M*N]) = row-softmax of bx; bmax/bsum per-row scratch.
SoftmaxR: {[bo;bx;bmax;bsum;M;N]
  $[smSP=0;    smSP::    CompileCompute[smStatK;4];  0]
  $[smAP=0;    smAP::    CompileCompute[smApplyK;5]; 0]
  $[smParam=0; smParam:: NewBuffer[4#0.]; 0]
  WriteBuffer[smParam; (0.+N),(0.+M),0.,0.]
  Dispatch[smSP; (bmax;bsum;bx;smParam); M]
  Dispatch[smAP; (bo;bx;bmax;bsum;smParam); M*N]
  bo}
/ Softmax of X (M rows × N cols) over each row → host array (M*N).
Softmax: {[X;M;N]
  bx:NewBuffer[X]
  bm:NewBuffer[(nnPad M)#0.]; bs:NewBuffer[(nnPad M)#0.]; bo:NewBuffer[(nnPad[M*N])#0.]
  SoftmaxR[bo;bx;bm;bs;M;N]
  (M*N) # ReadBuffer[bo]}

/ ── LayerNorm over the last dim  (mean/var per row, affine γ/β per feature) ───
/ Two passes: (1) per row i → mean[i], rstd[i]=1/√(var+eps);  (2) per element →
/ ((x-mean)*rstd)*γ[j] + β[j].
lnStatK: GpKernel[{[mb;rb;x;g;i]
  n:g[0]; eps:g[1]
  mean: (rsum[n; {[k] x[(i*n)+k]}]) % n
  var:  (rsum[n; {[k] sqr[(x[(i*n)+k]) - mean]}]) % n
  set[mb; i; mean]; set[rb; i; 1. % sqrt[var + eps]]}; 0; 4]
lnApplyK: GpKernel[{[o;x;mb;rb;gm;bt;g;d]
  n:g[0]; i:floor[d%n]; j:mod[d;n]
  nrm: ((x[d]) - mb[i]) * rb[i]
  set[o; d; (nrm * gm[j]) + bt[j]]}; 0; 7]

lnSP::0; lnAP::0; lnParam::0
/ Resident LayerNorm: writes bo (≥nnPad[M*N]); bm/br are per-row scratch (≥nnPad M).
/ cfg=(M;N;eps) — dims are packed because ink lambdas cap at 8 params.
LayerNormR: {[bo;bx;bg;bb;bm;br;cfg]
  M:cfg 0; N:cfg 1; eps:cfg 2
  $[lnSP=0;    lnSP::    CompileCompute[lnStatK;4];  0]
  $[lnAP=0;    lnAP::    CompileCompute[lnApplyK;7]; 0]
  $[lnParam=0; lnParam:: NewBuffer[4#0.]; 0]
  WriteBuffer[lnParam; (0.+N),eps,0.,0.]
  Dispatch[lnSP; (bm;br;bx;lnParam); M]
  Dispatch[lnAP; (bo;bx;bm;br;bg;bb;lnParam); M*N]
  bo}
/ LayerNorm of X (M×N) with per-feature gamma G (N) and beta B (N) → host (M*N).
LayerNorm: {[X;G;B;M;N;eps]
  bx:NewBuffer[X]; bg:NewBuffer[G]; bb:NewBuffer[B]
  bm:NewBuffer[(nnPad M)#0.]; br:NewBuffer[(nnPad M)#0.]
  bo:NewBuffer[(nnPad[M*N])#0.]
  LayerNormR[bo;bx;bg;bb;bm;br;(M;N;eps)]
  (M*N) # ReadBuffer[bo]}

/ ── Linear  Y[M,N] = X[M,K] · Wᵀ + b   (W is [N,K] = PyTorch [out,in]) ─────────
/ Fuses GEMM-with-transposed-B and bias: no host weight transpose, and reading
/ row j of W (w[j*K+k]) is the j-th output's weights.
linK: GpKernel[{[o;x;w;b;g;d]
  nn:g[1]; kk:g[2]
  i:floor[d%nn]; j:mod[d;nn]
  set[o; d; (rsum[kk; {[k] (x[(i*kk)+k]) * w[(j*kk)+k]}]) + b[j]]}; 0; 5]
linPipe::0; linParam::0
/ Resident: bo (≥nnPad[M*N]) = bx[M,K] · bw[N,K]ᵀ + bb[N].
LinearR: {[bo;bx;bw;bb;M;K;N]
  $[linPipe=0;  linPipe::  CompileCompute[linK;5]; 0]
  $[linParam=0; linParam:: NewBuffer[4#0.]; 0]
  WriteBuffer[linParam; (0.+M),(0.+N),(0.+K),0.]
  Dispatch[linPipe; (bo;bx;bw;bb;linParam); M*N]
  bo}
Linear: {[X;W;B;M;K;N]
  bx:NewBuffer[X]; bw:NewBuffer[W]; bb:NewBuffer[B]; bo:NewBuffer[(nnPad[M*N])#0.]
  LinearR[bo;bx;bw;bb;M;K;N]
  (M*N) # ReadBuffer[bo]}

/ ── Elementwise activations + residual (one thread per element) ───────────────
/ SiLU / Swish:  x·σ(x) = x / (1 + e^-x)
siluK: GpKernel[{[o;x;d] t:x[d]; set[o; d; t % (1. + exp[0. - t])]}; 0; 2]
/ GELU (tanh approximation):  0.5x(1 + tanh(√(2/π)(x + 0.044715x³)))
geluK: GpKernel[{[o;x;d] t:x[d]; c:0.7978845608 * (t + 0.044715*t*t*t); set[o; d; (0.5*t)*(1. + tanh[c])]}; 0; 2]
/ scaled residual:  o = a + s·b   (s in params g[0])
addsK: GpKernel[{[o;a;b;g;d] set[o; d; (a[d]) + (g[0])*b[d]]}; 0; 4]

siluPipe::0; geluPipe::0; addsPipe::0; addsParam::0
SiluR: {[bo;bx;n] $[siluPipe=0; siluPipe:: CompileCompute[siluK;2]; 0]; Dispatch[siluPipe;(bo;bx);n]; bo}
GeluR: {[bo;bx;n] $[geluPipe=0; geluPipe:: CompileCompute[geluK;2]; 0]; Dispatch[geluPipe;(bo;bx);n]; bo}
AddScaledR: {[bo;ba;bb;s;n]
  $[addsPipe=0;  addsPipe::  CompileCompute[addsK;4]; 0]
  $[addsParam=0; addsParam:: NewBuffer[4#0.]; 0]
  WriteBuffer[addsParam; (0.+s),0.,0.,0.]
  Dispatch[addsPipe; (bo;ba;bb;addsParam); n]
  bo}
Silu: {[X;n] bx:NewBuffer[X]; bo:NewBuffer[(nnPad n)#0.]; SiluR[bo;bx;n]; n # ReadBuffer[bo]}
Gelu: {[X;n] bx:NewBuffer[X]; bo:NewBuffer[(nnPad n)#0.]; GeluR[bo;bx;n]; n # ReadBuffer[bo]}

/ ── Conformer feed-forward sub-block (macaron half-step) ──────────────────────
/   out = x + 0.5 · Linear2( SiLU( Linear1( LayerNorm(x) ) ) )
/ Shapes: X[M,D];  W1[Dff,D],B1[Dff];  W2[D,Dff],B2[D];  gamma GAM[D], beta BET[D].
/ cfg=(M;D;Dff;eps) — packed (ink lambdas cap at 8 params).
FfnBlock: {[X;W1;B1;W2;B2;GAM;BET;cfg]
  M:cfg 0; D:cfg 1; Dff:cfg 2; eps:cfg 3
  bx:NewBuffer[X]
  bw1:NewBuffer[W1]; bb1:NewBuffer[B1]; bw2:NewBuffer[W2]; bb2:NewBuffer[B2]
  bgm:NewBuffer[GAM]; bbt:NewBuffer[BET]
  h0:NewBuffer[(nnPad[M*D])#0.]                 / LayerNorm(x)   [M,D]
  bm:NewBuffer[(nnPad M)#0.]; br:NewBuffer[(nnPad M)#0.]
  h1:NewBuffer[(nnPad[M*Dff])#0.]               / Linear1        [M,Dff]
  h2:NewBuffer[(nnPad[M*Dff])#0.]               / SiLU(h1)       [M,Dff]
  h3:NewBuffer[(nnPad[M*D])#0.]                 / Linear2        [M,D]
  bo:NewBuffer[(nnPad[M*D])#0.]
  LayerNormR[h0; bx; bgm; bbt; bm; br; (M;D;eps)]
  LinearR[h1; h0; bw1; bb1; M; D; Dff]
  SiluR[h2; h1; M*Dff]
  LinearR[h3; h2; bw2; bb2; M; Dff; D]
  AddScaledR[bo; bx; h3; 0.5; M*D]
  (M*D) # ReadBuffer[bo]}

/ ── Multi-head self-attention ────────────────────────────────────────────────
/ Two head-structured batched-matmul kernels (Q/K/V projections and the output
/ projection are plain Linear); softmax over the [H*T,T] score rows reuses SoftmaxR.
/ NB indices are computed in f32 (exact ≤ 2^24) — fine for the T we validate; a
/ large-T model needs i32 indices / tiling here (H*T*T can exceed 16M).
/
/ scores S[h,i,j] = scale · Σ_k Q[i,h·dh+k]·K[j,h·dh+k]   (one thread per H*T*T elem)
attnScoresK: GpKernel[{[s;q;kb;g;e]
  T:g[0]; D:g[1]; dh:g[2]; sc:g[3]
  tt: T*T
  h: floor[e%tt]; rem: mod[e;tt]
  i: floor[rem%T]; j: mod[rem;T]
  base: h*dh
  set[s; e; sc * rsum[dh; {[k] (q[(i*D)+base+k]) * kb[(j*D)+base+k]}]]}; 0; 4]
/ context C[i,c] = Σ_j A[h,i,j]·V[j,c]  where h = c÷dh   (one thread per T*D elem)
/ writes straight into the concatenated [T,D] layout — no per-head regather.
attnCtxK: GpKernel[{[o;a;v;g;e]
  T:g[0]; D:g[1]; dh:g[2]
  i: floor[e%D]; c: mod[e;D]
  h: floor[c%dh]
  hb: h*T*T
  set[o; e; rsum[T; {[j] (a[hb+(i*T)+j]) * v[(j*D)+c]}]]}; 0; 4]

asPipe::0; asParam::0; acPipe::0; acParam::0
/ Resident attention scores: bs[H*T*T] = scaled QKᵀ per head.  H = D÷dh.
AttnScoresR: {[bs;bq;bk;T;D;dh;scale]
  $[asPipe=0;  asPipe::  CompileCompute[attnScoresK;4]; 0]
  $[asParam=0; asParam:: NewBuffer[4#0.]; 0]
  WriteBuffer[asParam; (0.+T),(0.+D),(0.+dh),scale]
  Dispatch[asPipe; (bs;bq;bk;asParam); (D div dh)*T*T]
  bs}
/ Resident attention context: bc[T,D] = A·V, gathered into concatenated-head layout.
AttnCtxR: {[bc;ba;bv;T;D;dh]
  $[acPipe=0;  acPipe::  CompileCompute[attnCtxK;4]; 0]
  $[acParam=0; acParam:: NewBuffer[4#0.]; 0]
  WriteBuffer[acParam; (0.+T),(0.+D),(0.+dh),0.]
  Dispatch[acPipe; (bc;ba;bv;acParam); T*D]
  bc}

/ Mhsa[X; W; cfg] — standard scaled-dot-product self-attention (no rel-pos yet).
/   X[T,D];  W = (Wq;Bq; Wk;Bk; Wv;Bv; Wo;Bo)  (each proj weight is [D,D], bias [D]);
/   cfg = (T; D; H).   Returns [T,D].
/ Chained fully resident: 3 Linear (Q/K/V) → scores → row-softmax → context → Linear.
Mhsa: {[X;W;cfg]
  T:cfg 0; D:cfg 1; H:cfg 2
  dh: D div H
  scale: 1. % sqrt 0.+dh
  bx:NewBuffer[X]
  bwq:NewBuffer[W 0]; bbq:NewBuffer[W 1]; bwk:NewBuffer[W 2]; bbk:NewBuffer[W 3]
  bwv:NewBuffer[W 4]; bbv:NewBuffer[W 5]; bwo:NewBuffer[W 6]; bbo:NewBuffer[W 7]
  bq:NewBuffer[(nnPad[T*D])#0.]; LinearR[bq;bx;bwq;bbq;T;D;D]
  bk:NewBuffer[(nnPad[T*D])#0.]; LinearR[bk;bx;bwk;bbk;T;D;D]
  bv:NewBuffer[(nnPad[T*D])#0.]; LinearR[bv;bx;bwv;bbv;T;D;D]
  bs:NewBuffer[(nnPad[H*T*T])#0.]; AttnScoresR[bs;bq;bk;T;D;dh;scale]
  bsm:NewBuffer[(nnPad[H*T*T])#0.]
  bmx:NewBuffer[(nnPad[H*T])#0.]; bsu:NewBuffer[(nnPad[H*T])#0.]
  SoftmaxR[bsm;bs;bmx;bsu;H*T;T]
  bc:NewBuffer[(nnPad[T*D])#0.]; AttnCtxR[bc;bsm;bv;T;D;dh]
  bo:NewBuffer[(nnPad[T*D])#0.]; LinearR[bo;bc;bwo;bbo;T;D;D]
  (T*D) # ReadBuffer[bo]}

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
attnScoresRelK: GpKernel[{[s;q;kb;u;v;pe;g;e]
  T:g[0]; D:g[1]; dh:g[2]; sc:g[3]
  tt: T*T
  h: floor[e%tt]; rem: mod[e;tt]
  i: floor[rem%T]; j: mod[rem;T]
  base: h*dh
  prow: (((i-j)+(T-1)) * D)
  set[s; e; sc * rsum[dh; {[k]
    c: base+k; qc: q[(i*D)+c]
    ((qc + u[c]) * kb[(j*D)+c]) + (qc + v[c]) * pe[prow+c]}]]}; 0; 7]
asrPipe::0; asrParam::0
AttnScoresRelR: {[bs;bq;bk;bu;bv;bpe;cfg]
  $[asrPipe=0;  asrPipe::  CompileCompute[attnScoresRelK;7]; 0]
  $[asrParam=0; asrParam:: NewBuffer[4#0.]; 0]
  WriteBuffer[asrParam; (0.+cfg 0),(0.+cfg 1),(0.+cfg 2),cfg 3]
  Dispatch[asrPipe; (bs;bq;bk;bu;bv;bpe;asrParam); ((cfg 1) div (cfg 2))*(cfg 0)*(cfg 0)]
  bs}

/ MhsaRel[X; W; cfg] — rel-pos self-attention.  W = (Wq;Bq;Wk;Bk;Wv;Bv;Wo;Bo; Wpos;
/ u; v)  (Wpos[D,D] projects the sinusoid; u,v are [D]);  cfg=(T;D;H).
MhsaRel: {[X;W;cfg]
  T:cfg 0; D:cfg 1; H:cfg 2
  dh: D div H; scale: 1. % sqrt 0.+dh
  bx:NewBuffer[X]
  bwq:NewBuffer[W 0]; bbq:NewBuffer[W 1]; bwk:NewBuffer[W 2]; bbk:NewBuffer[W 3]
  bwv:NewBuffer[W 4]; bbv:NewBuffer[W 5]; bwo:NewBuffer[W 6]; bbo:NewBuffer[W 7]
  bwp:NewBuffer[W 8]; bu:NewBuffer[W 9]; bv:NewBuffer[W 10]
  bq:NewBuffer[(nnPad[T*D])#0.];  LinearR[bq;bx;bwq;bbq;T;D;D]
  bk:NewBuffer[(nnPad[T*D])#0.];  LinearR[bk;bx;bwk;bbk;T;D;D]
  bvv:NewBuffer[(nnPad[T*D])#0.]; LinearR[bvv;bx;bwv;bbv;T;D;D]
  np: (2*T)-1
  bz:NewBuffer[D#0.]
  bpe0:NewBuffer[nnPosEmb[T;D]]
  bpe:NewBuffer[(nnPad[np*D])#0.]; LinearR[bpe;bpe0;bwp;bz;np;D;D]     / P = posEmb·Wposᵀ
  bs:NewBuffer[(nnPad[H*T*T])#0.]; AttnScoresRelR[bs;bq;bk;bu;bv;bpe;(T;D;dh;scale)]
  bsm:NewBuffer[(nnPad[H*T*T])#0.]; bmx:NewBuffer[(nnPad[H*T])#0.]; bsu:NewBuffer[(nnPad[H*T])#0.]
  SoftmaxR[bsm;bs;bmx;bsu;H*T;T]
  bc:NewBuffer[(nnPad[T*D])#0.]; AttnCtxR[bc;bsm;bvv;T;D;dh]
  bo:NewBuffer[(nnPad[T*D])#0.]; LinearR[bo;bc;bwo;bbo;T;D;D]
  (T*D) # ReadBuffer[bo]}

/ ── Conformer convolution module ─────────────────────────────────────────────
/ GLU gate: X is [T,2D]; out[t,c] = X[t,c]·σ(X[t,D+c])  (split channels a|b → a·σ(b))
gluK: GpKernel[{[o;x;g;e]
  D:g[0]; w2:2.*D
  i:floor[e%D]; c:mod[e;D]
  a: x[(i*w2)+c]; b: x[(i*w2)+D+c]
  set[o; e; a * 1. % 1. + exp[0. - b]]}; 0; 3]
/ Depthwise 1-D conv (per-channel, zero-padded): out[t,c]=Σ_k x[t+k-pad,c]·W[c,k]+B[c]
dwK: GpKernel[{[o;x;w;b;g;e]
  T:g[0]; D:g[1]; ks:g[2]; pad:g[3]
  i:floor[e%D]; c:mod[e;D]
  acc: rsum[ks; {[k]
    tp: (i+k)-pad
    ok: (~(tp<0.)) & (tp<T)
    ($[ok; x[(tp*D)+c]; 0.]) * w[(c*ks)+k]}]
  set[o; e; acc + b[c]]}; 0; 5]
/ Per-channel affine (BatchNorm inference folded to scale/shift): out[t,c]=x·A[c]+B[c]
caK: GpKernel[{[o;x;a;b;g;e]
  D:g[0]; c:mod[e;D]
  set[o; e; (x[e]*a[c]) + b[c]]}; 0; 5]

gluPipe::0; gluParam::0; dwPipe::0; dwParam::0; caPipe::0; caParam::0
/ GLU:  bx[T,2D] → bo[T,D].
GluR: {[bo;bx;T;D]
  $[gluPipe=0;  gluPipe::  CompileCompute[gluK;3]; 0]
  $[gluParam=0; gluParam:: NewBuffer[4#0.]; 0]
  WriteBuffer[gluParam; (0.+D),0.,0.,0.]
  Dispatch[gluPipe; (bo;bx;gluParam); T*D]
  bo}
/ Depthwise conv:  bx[T,D], bw[D,ks], bb[D] → bo[T,D].  pad = (ks-1)÷2 for "same".
DwConvR: {[bo;bx;bw;bb;T;D;ks;pad]
  $[dwPipe=0;  dwPipe::  CompileCompute[dwK;5]; 0]
  $[dwParam=0; dwParam:: NewBuffer[4#0.]; 0]
  WriteBuffer[dwParam; (0.+T),(0.+D),(0.+ks),(0.+pad)]
  Dispatch[dwPipe; (bo;bx;bw;bb;dwParam); T*D]
  bo}
/ Channel affine:  bo[T,D] = bx·A[c] + B[c].
ChanAffineR: {[bo;bx;ba;bb;T;D]
  $[caPipe=0;  caPipe::  CompileCompute[caK;5]; 0]
  $[caParam=0; caParam:: NewBuffer[4#0.]; 0]
  WriteBuffer[caParam; (0.+D),0.,0.,0.]
  Dispatch[caPipe; (bo;bx;ba;bb;caParam); T*D]
  bo}

/ ConvModule[X; W; cfg] — conformer conv module (residual included).
/   out = x + PW2( Swish( BN( DWConv( GLU( PW1( LayerNorm(x) ) ) ) ) ) )
/   X[T,D];  cfg=(T;D;ks;eps);
/   W = (lnG;lnB;  Wpw1[2D,D];Bpw1[2D];  Wdw[D,ks];Bdw[D];  caA[D];caB[D];  Wpw2[D,D];Bpw2[D])
/ BatchNorm is folded into (caA;caB) = (rstd·γ ; β − μ·rstd·γ) at load time.
ConvModule: {[X;W;cfg]
  T:cfg 0; D:cfg 1; ks:cfg 2; eps:cfg 3
  pad: (ks-1) div 2
  bx:NewBuffer[X]
  blnG:NewBuffer[W 0]; blnB:NewBuffer[W 1]
  bwp1:NewBuffer[W 2]; bbp1:NewBuffer[W 3]
  bwdw:NewBuffer[W 4]; bbdw:NewBuffer[W 5]
  bcaA:NewBuffer[W 6]; bcaB:NewBuffer[W 7]
  bwp2:NewBuffer[W 8]; bbp2:NewBuffer[W 9]
  h0:NewBuffer[(nnPad[T*D])#0.]; bm:NewBuffer[(nnPad T)#0.]; br:NewBuffer[(nnPad T)#0.]
  h1:NewBuffer[(nnPad[T*2*D])#0.]
  h2:NewBuffer[(nnPad[T*D])#0.]; h3:NewBuffer[(nnPad[T*D])#0.]
  h4:NewBuffer[(nnPad[T*D])#0.]; h5:NewBuffer[(nnPad[T*D])#0.]; h6:NewBuffer[(nnPad[T*D])#0.]
  bo:NewBuffer[(nnPad[T*D])#0.]
  LayerNormR[h0; bx; blnG; blnB; bm; br; (T;D;eps)]
  LinearR[h1; h0; bwp1; bbp1; T; D; 2*D]
  GluR[h2; h1; T; D]
  DwConvR[h3; h2; bwdw; bbdw; T; D; ks; pad]
  ChanAffineR[h4; h3; bcaA; bcaB; T; D]
  SiluR[h5; h4; T*D]
  LinearR[h6; h5; bwp2; bbp2; T; D; D]
  AddScaledR[bo; bx; h6; 1.; T*D]
  (T*D) # ReadBuffer[bo]}

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
stftPowerK: GpKernel[{[pw;sig;cr;ci;g;e]
  hop:g[0]; win:g[1]; nf:g[2]
  f:floor[e%nf]; k:mod[e;nf]
  base: f*hop; kb: k*win
  re: rsum[win; {[t] (sig[base+t]) * cr[kb+t]}]
  im: rsum[win; {[t] (sig[base+t]) * ci[kb+t]}]
  set[pw; e; (re*re) + im*im]}; 0; 5]
/ log with a floor:  o = log(x + eps)
logK: GpKernel[{[o;x;g;e] set[o; e; log[(x[e]) + g[0]]]}; 0; 3]

spPipe::0; spParam::0; logPipe::0; logParam::0
StftPowerR: {[bpw;bsig;bcr;bci;hop;win;nf;nfr]
  $[spPipe=0;  spPipe::  CompileCompute[stftPowerK;5]; 0]
  $[spParam=0; spParam:: NewBuffer[4#0.]; 0]
  WriteBuffer[spParam; (0.+hop),(0.+win),(0.+nf),0.]
  Dispatch[spPipe; (bpw;bsig;bcr;bci;spParam); nfr*nf]
  bpw}
LogEpsR: {[bo;bx;eps;n]
  $[logPipe=0;  logPipe::  CompileCompute[logK;3]; 0]
  $[logParam=0; logParam:: NewBuffer[4#0.]; 0]
  WriteBuffer[logParam; (0.+eps),0.,0.,0.]
  Dispatch[logPipe; (bo;bx;logParam); n]
  bo}

/ LogMel[sig; Cr; Ci; MelFb; cfg] cfg=(hop;win;nfreq;nmels;nframes;eps) → [nframes*nmels].
/ Chain: STFT power → mel projection (Linear, zero bias) → log(·+eps).
LogMel: {[sig; Cr; Ci; MelFb; cfg]
  hop:cfg 0; win:cfg 1; nf:cfg 2; nm:cfg 3; nfr:cfg 4; eps:cfg 5
  bsig:NewBuffer[sig]; bcr:NewBuffer[Cr]; bci:NewBuffer[Ci]; bmf:NewBuffer[MelFb]
  bz:NewBuffer[nm#0.]
  bpw:NewBuffer[(nnPad[nfr*nf])#0.]
  StftPowerR[bpw;bsig;bcr;bci;hop;win;nf;nfr]
  bmel:NewBuffer[(nnPad[nfr*nm])#0.]
  LinearR[bmel;bpw;bmf;bz;nfr;nf;nm]
  bout:NewBuffer[(nnPad[nfr*nm])#0.]
  LogEpsR[bout;bmel;eps;nfr*nm]
  (nfr*nm) # ReadBuffer[bout]}

/ ── Conv subsampling  (mel spectrogram → 8×-downsampled encoder input) ───────
/ 2-D conv, kernel 3, stride 2, pad 1.  Layout [C,T,F] channel-major flat.
/ conv output size s(n) = (n+2·1−3)÷2 + 1 = 1 + (n−1)÷2.
nnSub2: {[n] 1 + (n-1) div 2}

/ regular conv2d 1→C:  out[oc,t',f'] = b[oc] + Σ_{kt,kf} in[2t'+kt−1, 2f'+kf−1]·W[oc,kt,kf]
conv2dK: GpKernel[{[o;x;w;b;g;e]
  C:g[0]; Tout:g[1]; Fout:g[2]; Tin:g[3]; Fin:g[4]
  tf: Tout*Fout
  oc: floor[e%tf]; rem: mod[e;tf]
  tp: floor[rem%Fout]; fp: mod[rem;Fout]
  set[o; e; (b[oc]) + rsum[9; {[kk]
    kt: floor[kk%3.]; kf: mod[kk;3.]
    ti: ((2.*tp)+kt)-1.; fi: ((2.*fp)+kf)-1.
    ok: (~(ti<0.)) & (ti<Tin) & (~(fi<0.)) & (fi<Fin)
    ($[ok; x[(ti*Fin)+fi]; 0.]) * w[(oc*9.)+kk]}]]}; 0; 5]
/ depthwise conv2d C→C (per channel):  reads input channel c only.
dwConv2dK: GpKernel[{[o;x;w;b;g;e]
  C:g[0]; Tout:g[1]; Fout:g[2]; Tin:g[3]; Fin:g[4]
  tf: Tout*Fout
  c: floor[e%tf]; rem: mod[e;tf]
  tp: floor[rem%Fout]; fp: mod[rem;Fout]
  cin: c*Tin*Fin
  set[o; e; (b[c]) + rsum[9; {[kk]
    kt: floor[kk%3.]; kf: mod[kk;3.]
    ti: ((2.*tp)+kt)-1.; fi: ((2.*fp)+kf)-1.
    ok: (~(ti<0.)) & (ti<Tin) & (~(fi<0.)) & (fi<Fin)
    ($[ok; x[cin+(ti*Fin)+fi]; 0.]) * w[(c*9.)+kk]}]]}; 0; 5]
/ pointwise conv2d C→C (1×1) = per-position channel linear.
pwConv2dK: GpKernel[{[o;x;w;b;g;e]
  C:g[0]; T:g[1]; F:g[2]
  tf: T*F
  oc: floor[e%tf]; pos: mod[e;tf]
  set[o; e; (b[oc]) + rsum[C; {[ic] (x[(ic*tf)+pos]) * w[(oc*C)+ic]}]]}; 0; 5]
/ ReLU  (shader `|` is logical-or, not max — use the max builtin)
reluK: GpKernel[{[o;x;e] set[o; e; max[0.; x[e]]]}; 0; 2]
/ flatten [C,Tp,Fp] → [Tp, C·Fp]  (out[t',c·Fp+f'] = in[c,t',f'])
flattenK: GpKernel[{[o;x;g;e]
  C:g[0]; Tp:g[1]; Fp:g[2]
  cf: C*Fp
  tpp: floor[e%cf]; rem: mod[e;cf]
  c: floor[rem%Fp]; fp: mod[rem;Fp]
  set[o; e; x[(c*Tp*Fp)+(tpp*Fp)+fp]]}; 0; 3]

c2Pipe::0; c2Param::0; dw2Pipe::0; dw2Param::0; pw2Pipe::0; pw2Param::0
reluPipe::0; flPipe::0; flParam::0
Conv2dR: {[bo;bin;bw;bb;cfg]
  $[c2Pipe=0;  c2Pipe::  CompileCompute[conv2dK;5]; 0]
  $[c2Param=0; c2Param:: NewBuffer[8#0.]; 0]
  WriteBuffer[c2Param; (0.+cfg 0),(0.+cfg 1),(0.+cfg 2),(0.+cfg 3),(0.+cfg 4),0.,0.,0.]
  Dispatch[c2Pipe; (bo;bin;bw;bb;c2Param); (cfg 0)*(cfg 1)*(cfg 2)]
  bo}
DwConv2dR: {[bo;bin;bw;bb;cfg]
  $[dw2Pipe=0;  dw2Pipe::  CompileCompute[dwConv2dK;5]; 0]
  $[dw2Param=0; dw2Param:: NewBuffer[8#0.]; 0]
  WriteBuffer[dw2Param; (0.+cfg 0),(0.+cfg 1),(0.+cfg 2),(0.+cfg 3),(0.+cfg 4),0.,0.,0.]
  Dispatch[dw2Pipe; (bo;bin;bw;bb;dw2Param); (cfg 0)*(cfg 1)*(cfg 2)]
  bo}
PwConv2dR: {[bo;bin;bw;bb;C;T;F]
  $[pw2Pipe=0;  pw2Pipe::  CompileCompute[pwConv2dK;5]; 0]
  $[pw2Param=0; pw2Param:: NewBuffer[4#0.]; 0]
  WriteBuffer[pw2Param; (0.+C),(0.+T),(0.+F),0.]
  Dispatch[pw2Pipe; (bo;bin;bw;bb;pw2Param); C*T*F]
  bo}
ReluR: {[bo;bx;n] $[reluPipe=0; reluPipe:: CompileCompute[reluK;2]; 0]; Dispatch[reluPipe;(bo;bx);n]; bo}
FlattenR: {[bo;bin;C;Tp;Fp]
  $[flPipe=0;  flPipe::  CompileCompute[flattenK;3]; 0]
  $[flParam=0; flParam:: NewBuffer[4#0.]; 0]
  WriteBuffer[flParam; (0.+C),(0.+Tp),(0.+Fp),0.]
  Dispatch[flPipe; (bo;bin;flParam); Tp*C*Fp]
  bo}

/ ConvSubsample[MEL; W; cfg] — dw_striding 8× subsampling → [T/8, D].
/   MEL[Tin,Fin] (1-channel log-mel); cfg=(Tin;Fin;C;D);
/   W = (Wc[C,9];Bc; Wdw1[C,9];Bdw1; Wpw1[C,C];Bpw1; Wdw2[C,9];Bdw2; Wpw2[C,C];Bpw2;
/        Wproj[D, C·F3];Bproj)   (12 arrays)
ConvSubsample: {[MEL;W;cfg]
  Ti:cfg 0; Fi:cfg 1; C:cfg 2; D:cfg 3
  T1:nnSub2 Ti; F1:nnSub2 Fi; T2:nnSub2 T1; F2:nnSub2 F1; T3:nnSub2 T2; F3:nnSub2 F2
  bmel:NewBuffer[MEL]
  bw0:NewBuffer[W 0]; bb0:NewBuffer[W 1]
  bwd1:NewBuffer[W 2]; bbd1:NewBuffer[W 3]; bwp1:NewBuffer[W 4]; bbp1:NewBuffer[W 5]
  bwd2:NewBuffer[W 6]; bbd2:NewBuffer[W 7]; bwp2:NewBuffer[W 8]; bbp2:NewBuffer[W 9]
  bwpr:NewBuffer[W 10]; bbpr:NewBuffer[W 11]
  h1:NewBuffer[(nnPad[C*T1*F1])#0.]; Conv2dR[h1;bmel;bw0;bb0;(C;T1;F1;Ti;Fi)]
  r1:NewBuffer[(nnPad[C*T1*F1])#0.]; ReluR[r1;h1;C*T1*F1]
  h2:NewBuffer[(nnPad[C*T2*F2])#0.]; DwConv2dR[h2;r1;bwd1;bbd1;(C;T2;F2;T1;F1)]
  p2:NewBuffer[(nnPad[C*T2*F2])#0.]; PwConv2dR[p2;h2;bwp1;bbp1;C;T2;F2]
  r2:NewBuffer[(nnPad[C*T2*F2])#0.]; ReluR[r2;p2;C*T2*F2]
  h3:NewBuffer[(nnPad[C*T3*F3])#0.]; DwConv2dR[h3;r2;bwd2;bbd2;(C;T3;F3;T2;F2)]
  p3:NewBuffer[(nnPad[C*T3*F3])#0.]; PwConv2dR[p3;h3;bwp2;bbp2;C;T3;F3]
  r3:NewBuffer[(nnPad[C*T3*F3])#0.]; ReluR[r3;p3;C*T3*F3]
  Kf: C*F3
  hf:NewBuffer[(nnPad[T3*Kf])#0.]; FlattenR[hf;r3;C;T3;F3]
  bo:NewBuffer[(nnPad[T3*D])#0.]; LinearR[bo;hf;bwpr;bbpr;T3;Kf;D]
  (T3*D) # ReadBuffer[bo]}

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
