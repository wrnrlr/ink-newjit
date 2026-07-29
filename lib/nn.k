/
# nn

Neural-net primitives that keep their weights and activations on the GPU.

Compute needs a live device, so these run inside a `window.run` loop — see
test/nn.k.  All matrices are ROW-MAJOR flat f32 vectors.

## Naming

Every operator comes in three forms (doc/design/nn.md §2):

```k
gemm        / public entry, RESIDENT: buffer handles in, handle out
gemm.host   / host arrays in, host array out (one-shot, and the bit-exact oracle)
gemm.kern   / the gpu.kernel value
```

`nn.*` is shared plumbing and `nn.fn.*` the host-side scalar/vector helpers.
Every mutable global lives under a dotted prefix — there are no bare globals.

## The padding rule

`gpu.dispatch` rounds the grid up to a multiple of 64, and Metal CLAMPS an
out-of-bounds store to the last valid index.  So every OUTPUT buffer is padded to
the launched thread count (`nn.pad`), and stray writes land in padding instead of
clobbering a live element.  Out-of-bounds input reads clamp harmlessly — their
outputs are discarded anyway.

Pure k — loads on the first reference to any `nn.*` name.
\

\e gemm linear softmax layernorm silu gelu relu addscaled glu dwconv chanaffine
\e conv2d dwconv2d pwconv2d flatten ffn lstm

/ ── Shared plumbing ──────────────────────────────────────────────────────────
/ round a length up to the launched thread count (grid = ceil(n/64)*64)
nn.pad:  {[n] 64 * 1 | `i$ (n+63) div 64}
nn.buf:  {[n] gpu.bufferN[nn.pad n]}            / padded scratch, contents undefined
nn.zbuf: {[n] gpu.buffer[(nn.pad n)#0.]}        / padded scratch, zeroed
nn.drop: {[bs] gpu.free' bs}

/ Compile-once pipeline cache, keyed by symbol. Replaces the ~20 `xPipe::0` globals
/ and their `$[p=0; p::compile; 0]` guards.
nn.pipes:: ()!()
nn.pipeAdd: {[nm;kern;nb] p: gpu.compileCompute[kern;nb]; nn.pipes:: nn.pipes,(,nm)!,p; p}
nn.pipe:    {[nm;kern;nb] $[nm in !nn.pipes; nn.pipes nm; nn.pipeAdd[nm;kern;nb]]}

/ Per-op params buffer (8 floats), keyed by symbol, written on every call.
/ ONE BUFFER PER OP, NOT ONE SHARED BUFFER. gpu.write drains the queue (v.sync) when
/ it changes bytes that recorded-but-unsubmitted work still references — see
/ lib/gpu/gpu_vk.zig gpuBufferWrite. Sharing a single params buffer across ops would
/ make every write collide with every other op's pending dispatch, forcing a full
/ pipeline stall per op: the 3-10x regression measured in doc/research/tropical.md
/ Exp 2. Distinct keys keep the ops independent, so the writes stay free.
nn.pars:: ()!()
nn.parAdd: {[nm] b: gpu.buffer[8#0.]; nn.pars:: nn.pars,(,nm)!,b; b}
nn.parB:   {[nm] $[nm in !nn.pars; nn.pars nm; nn.parAdd nm]}
nn.par:    {[nm;v] b: nn.parB nm; gpu.write[b; 8#(0.+v),8#0.]; b}

/ ── GEMM  C[M,N] = A[M,K] · B[K,N] ───────────────────────────────────────────
/ One pipeline serves every shape: dims travel in the params buffer g=(M;N;K).
/ thread d → C[d]; i=d div N, j=d mod N; C[d] = Σ_k A[i*K+k]·B[k*N+j].
/ (integer-index dialect: d is i32, dims cast once with `i$, all address math exact)
gemm.kern: gpu.kernel[{[c;a;b;g;d]
  n:`i$g[1]; kk:`i$g[2]
  i:d div n; j:d mod n
  set[c; d; +/{[k] (a[(i*kk)+k]) * b[(k*n)+j]}'!kk]}; 0; 4]

/ 8×8-tiled GEMM with workgroup shared memory (kk.md finding 3). A 1-D workgroup of 64
/ threads computes an 8×8 block of C, cooperatively loading an 8×8 tile of BOTH A and B
/ into shared memory per K-tile — each A/B element is fetched from global once per tile
/ (8× fewer global loads) instead of once per output. That load count is exact, but the
/ MEASURED speedup is 1.7-2.5x, not 8x (bench/nnshapes.py, M=N=K=64/128/512): the cache
/ already recovers most of the traffic the tiling avoids, so the analytic ratio is an
/ upper bound on the win, not a prediction of it. Block coords derive from the 1-D
/ index; the store index is computed (row*n+col). Requires M,N,K all multiples of 8 (then
/ M*N is a multiple of 64, so the launch is exact — no over-dispatch to guard). Same
/ params buffer (M;N;K) and thread count (M*N) as gemm.kern, so `gemm` just swaps pipeline.
gemm.tile.kern: gpu.kernelWG[{[c;a;b;g;d]
  n:`i$g[1]; kk:`i$g[2]
  wgId:d div wgsz
  lr:lid div 8; lc:lid mod 8
  bpr:n div 8
  brow:wgId div bpr; bcol:wgId mod bpr
  row:(brow*8)+lr; col:(bcol*8)+lc
  nt:kk div 8
  acc: +/{[t]
    lset[0; (lr*8)+lc; a[(row*kk)+(t*8)+lc]]
    lset[1; (lr*8)+lc; b[(((t*8)+lr)*n)+col]]
    barrier[]
    p: +/{[m] (lget[0; (lr*8)+m]) * lget[1; (m*8)+lc]}'!8
    barrier[]
    p}'!nt
  set[c; (row*n)+col; acc]}; 0; 4; (64;64); 64]

/ Resident GEMM: bc must already be a buffer of length ≥ nn.pad[M*N]; ba/bb hold A/B.
/ Dispatches the shared-memory-tiled kernel when the dims are 8-aligned (the common
/ nn case: D is a multiple of 8), else the plain per-element kernel.
gemm: {[bc;ba;bb;M;K;N]
  g: nn.par[`gemm; (M;N;K)]
  tiled: (0 = M mod 8) & (0 = N mod 8) & (0 = K mod 8)
  pipe: $[tiled; nn.pipe[`gemmTile; gemm.tile.kern; 4]; nn.pipe[`gemm; gemm.kern; 4]]
  gpu.dispatch[pipe; (bc;ba;bb;g); M*N]
  bc}

/ Host convenience: A,B host arrays → C host array (M*N).
gemm.host: {[A;B;M;K;N]
  ba:gpu.buffer[A]; bb:gpu.buffer[B]; bc:nn.zbuf[M*N]
  gemm[bc;ba;bb;M;K;N]
  r: (M*N) # gpu.read[bc]
  nn.drop(ba;bb;bc)
  r}

/ ── Linear  Y[M,N] = X[M,K] · Wᵀ + b   (W is [N,K] = PyTorch [out,in]) ─────────
/ Fuses GEMM-with-transposed-B and bias: no host weight transpose, and reading
/ row j of W (w[j*K+k]) is the j-th output's weights.
linear.kern: gpu.kernel[{[o;x;w;b;g;d]
  nn:`i$g[1]; kk:`i$g[2]
  i:d div nn; j:d mod nn
  set[o; d; (+/{[k] (x[(i*kk)+k]) * w[(j*kk)+k]}'!kk) + b[j]]}; 0; 5]

/ 16×16-tiled Linear — gemm.tile.kern's shared-memory scheme with B TRANSPOSED (W is
/ [N,K]) and the bias folded into the store.  linear.kern gives every output its own
/ private pass over a full row of X and a full row of W, so each weight is re-read M
/ times and neighbouring threads (adjacent j) read K floats apart — no reuse AND
/ uncoalesced.  This fetches each X/W element once per 16×16 tile instead of once per
/ output.  16×16 rather than gemm's 8×8: a taller tile cuts how many times each weight
/ is re-read, and weight traffic is what dominates here (X is only T×1024).
/ ROW COUNT IS NOT REQUIRED TO BE ALIGNED. M is the number of encoder frames T', which
/ is an arbitrary function of the utterance length — demanding M%16=0 would silently
/ drop most real utterances back onto linear.kern (a 10 s clip gives T'=126, and the
/ fallback is ~5× slower). Instead the launch rounds the ROWS up to a whole tile and
/ threads outside [0,M) neither load nor store. Only N and K must be multiples of 16,
/ and in this model they always are (D=1024, 2D=2048, Dff=4096).
linear.tile.kern: gpu.kernelWG[{[o;x;w;b;g;d]
  m:`i$g[0]; n:`i$g[1]; kk:`i$g[2]
  wgId:d div wgsz
  lr:lid div 16; lc:lid mod 16
  bpr:n div 16
  brow:wgId div bpr; bcol:wgId mod bpr
  row:(brow*16)+lr; col:(bcol*16)+lc
  ok: row < m
  nt:kk div 16
  acc: +/{[t]
    lset[0; (lr*16)+lc; $[ok; x[(row*kk)+(t*16)+lc]; 0.]]
    lset[1; (lr*16)+lc; w[(col*kk)+(t*16)+lr]]
    barrier[]
    p: +/{[q] (lget[0; (lr*16)+q]) * lget[1; (q*16)+lc]}'!16
    barrier[]
    p}'!nt
  $[ok; set[o; (row*n)+col; acc + b[col]]; 0]}; 0; 5; (256;256); 256]

/ Resident: bo (≥nn.pad[M*N]) = bx[M,K] · bw[N,K]ᵀ + bb[N].
linear: {[bo;bx;bw;bb;M;K;N]
  g: nn.par[`linear; (M;N;K)]
  tiled: (0 = N mod 16) & (0 = K mod 16)
  pipe: $[tiled; nn.pipe[`linearTile; linear.tile.kern; 5]; nn.pipe[`linear; linear.kern; 5]]
  Mp: 16 * ((M + 15) div 16)                / rows rounded up to a whole tile
  gpu.dispatch[pipe; (bo;bx;bw;bb;g); $[tiled; Mp*N; M*N]]
  bo}
linear.host: {[X;W;B;M;K;N]
  bx:gpu.buffer[X]; bw:gpu.buffer[W]; bb:gpu.buffer[B]; bo:nn.zbuf[M*N]
  linear[bo;bx;bw;bb;M;K;N]
  r: (M*N) # gpu.read[bo]
  nn.drop(bx;bw;bb;bo)
  r}

/ ── Row softmax  (numerically stable: subtract the row max) ───────────────────
/ Two passes: (1) per row i → m[i]=max, s[i]=Σexp(x-m);  (2) per element → exp/s.
softmax.stat.kern: gpu.kernel[{[mb;sb;x;g;i]
  n:`i$g[0]
  m: |/{[k] x[(i*n)+k]}'!n
  s: +/{[k] exp[(x[(i*n)+k]) - m]}'!n
  set[mb; i; m]; set[sb; i; s]}; 0; 4]
softmax.apply.kern: gpu.kernel[{[o;x;mb;sb;g;d]
  n:`i$g[0]; i:d div n
  set[o; d; (exp[(x[d]) - mb[i]]) % sb[i]]}; 0; 5]

/ Resident softmax: bo (≥nn.pad[M*N]) = row-softmax of bx; bmax/bsum per-row scratch.
softmax: {[bo;bx;bmax;bsum;M;N]
  g: nn.par[`softmax; (N;M)]
  gpu.dispatch[nn.pipe[`softmaxStat;  softmax.stat.kern;  4]; (bmax;bsum;bx;g); M]
  gpu.dispatch[nn.pipe[`softmaxApply; softmax.apply.kern; 5]; (bo;bx;bmax;bsum;g); M*N]
  bo}
/ Softmax of X (M rows × N cols) over each row → host array (M*N).
softmax.host: {[X;M;N]
  bx:gpu.buffer[X]
  bm:nn.zbuf M; bs:nn.zbuf M; bo:nn.zbuf[M*N]
  softmax[bo;bx;bm;bs;M;N]
  r: (M*N) # gpu.read[bo]
  nn.drop(bx;bm;bs;bo)
  r}

/ ── LayerNorm over the last dim  (mean/var per row, affine γ/β per feature) ───
/ Two passes: (1) per row i → mean[i], rstd[i]=1/√(var+eps);  (2) per element →
/ ((x-mean)*rstd)*γ[j] + β[j].
layernorm.stat.kern: gpu.kernel[{[mb;rb;x;g;i]
  nf:g[0]; eps:g[1]; n:`i$nf              / n indexes (i32); nf divides (f32)
  mean: (+/{[k] x[(i*n)+k]}'!n) % nf
  var:  (+/{[k] sqr[(x[(i*n)+k]) - mean]}'!n) % nf
  set[mb; i; mean]; set[rb; i; 1. % sqrt[var + eps]]}; 0; 4]

/ layernorm.stat.kern gives each ROW one thread, so a [32,1024] LayerNorm launches 32
/ threads that each walk 2048 dependent global loads — the GPU sits idle and the
/ dispatch costs ~0.38 ms of pure latency. Over 5 LayerNorms × 24 layers that was
/ ~46 ms, 15% of the encoder. This gives each row a whole WORKGROUP: 256 threads take a
/ strided (hence coalesced) slice each, then one thread folds the 256 partials in
/ shared memory. Still the same two-pass mean-then-variance formulation, so it stays
/ numerically close to the scalar kernel; only the summation ORDER changes.  Needs
/ N % 256 = 0 — `layernorm` falls back to the scalar kernel otherwise.
layernorm.wide.kern: gpu.kernelWG[{[mb;rb;x;g;d]
  nf:g[0]; eps:g[1]; n:`i$nf
  row: d div wgsz
  base: row*n
  per:  n div wgsz
  s: +/{[t] x[base+(t*wgsz)+lid]}'!per
  lset[0; lid; s]
  barrier[]
  $[lid=0; lset[1; 0; +/{[q] lget[0;q]}'!wgsz]; 0]
  barrier[]
  mean: (lget[1;0]) % nf
  s2: +/{[t] sqr[(x[base+(t*wgsz)+lid]) - mean]}'!per
  lset[0; lid; s2]
  barrier[]
  $[lid=0; lset[1; 1; +/{[q] lget[0;q]}'!wgsz]; 0]
  barrier[]
  $[lid=0; set[mb; row; mean]; 0]
  $[lid=0; set[rb; row; 1. % sqrt[((lget[1;1]) % nf) + eps]]; 0]}; 0; 4; (256;2); 256]

layernorm.apply.kern: gpu.kernel[{[o;x;mb;rb;gm;bt;g;d]
  n:`i$g[0]; i:d div n; j:d mod n
  nrm: ((x[d]) - mb[i]) * rb[i]
  set[o; d; (nrm * gm[j]) + bt[j]]}; 0; 7]

/ Resident LayerNorm: writes bo (≥nn.pad[M*N]); bm/br are per-row scratch (≥nn.pad M).
/ cfg=(M;N;eps) — dims are packed because ink lambdas cap at 8 params.
layernorm: {[bo;bx;bg;bb;bm;br;cfg]
  M:cfg 0; N:cfg 1; eps:cfg 2
  g: nn.par[`layernorm; (N;eps)]
  wide: 0 = N mod 256
  $[wide; gpu.dispatch[nn.pipe[`lnWide; layernorm.wide.kern; 4]; (bm;br;bx;g); M*256]
        ; gpu.dispatch[nn.pipe[`lnStat; layernorm.stat.kern; 4]; (bm;br;bx;g); M]]
  gpu.dispatch[nn.pipe[`lnApply; layernorm.apply.kern; 7]; (bo;bx;bm;br;bg;bb;g); M*N]
  bo}
/ LayerNorm of X (M×N) with per-feature gamma G (N) and beta B (N) → host (M*N).
layernorm.host: {[X;G;B;M;N;eps]
  bx:gpu.buffer[X]; bg:gpu.buffer[G]; bb:gpu.buffer[B]
  bm:nn.zbuf M; br:nn.zbuf M; bo:nn.zbuf[M*N]
  layernorm[bo;bx;bg;bb;bm;br;(M;N;eps)]
  r: (M*N) # gpu.read[bo]
  nn.drop(bx;bg;bb;bm;br;bo)
  r}

/ ── Elementwise activations + residual (one thread per element) ───────────────
/ SiLU / Swish:  x·σ(x) = x / (1 + e^-x)
silu.kern: gpu.kernel[{[o;x;d] t:x[d]; set[o; d; t % (1. + exp[0. - t])]}; 0; 2]
/ GELU (tanh approximation):  0.5x(1 + tanh(√(2/π)(x + 0.044715x³)))
gelu.kern: gpu.kernel[{[o;x;d] t:x[d]; c:0.7978845608 * (t + 0.044715*t*t*t); set[o; d; (0.5*t)*(1. + tanh[c])]}; 0; 2]
/ ReLU  (shader `|` is logical-or, not max — use the max builtin)
relu.kern: gpu.kernel[{[o;x;e] set[o; e; max[0.; x[e]]]}; 0; 2]
/ scaled residual:  o = a + s·b   (s in params g[0])
addscaled.kern: gpu.kernel[{[o;a;b;g;d] set[o; d; (a[d]) + (g[0])*b[d]]}; 0; 4]

silu: {[bo;bx;n] gpu.dispatch[nn.pipe[`silu; silu.kern; 2]; (bo;bx); n]; bo}
gelu: {[bo;bx;n] gpu.dispatch[nn.pipe[`gelu; gelu.kern; 2]; (bo;bx); n]; bo}
relu: {[bo;bx;n] gpu.dispatch[nn.pipe[`relu; relu.kern; 2]; (bo;bx); n]; bo}
addscaled: {[bo;ba;bb;s;n]
  g: nn.par[`addscaled; ,s]
  gpu.dispatch[nn.pipe[`addscaled; addscaled.kern; 4]; (bo;ba;bb;g); n]
  bo}

/ host forms: X host array → host array (n)
nn.ewHost: {[f;X;n] bx:gpu.buffer[X]; bo:nn.zbuf n; f[bo;bx;n]; r: n # gpu.read[bo]; nn.drop(bx;bo); r}
silu.host: {[X;n] nn.ewHost[silu;X;n]}
gelu.host: {[X;n] nn.ewHost[gelu;X;n]}
relu.host: {[X;n] nn.ewHost[relu;X;n]}

/ log with a floor:  o = log(x + eps)
logeps.kern: gpu.kernel[{[o;x;g;e] set[o; e; log[(x[e]) + g[0]]]}; 0; 3]
logeps: {[bo;bx;eps;n]
  g: nn.par[`logeps; ,eps]
  gpu.dispatch[nn.pipe[`logeps; logeps.kern; 3]; (bo;bx;g); n]
  bo}

/ ── Gated linear unit / depthwise 1-D conv / per-channel affine ──────────────
/ GLU gate: X is [T,2D]; out[t,c] = X[t,c]·σ(X[t,D+c])  (split channels a|b → a·σ(b))
glu.kern: gpu.kernel[{[o;x;g;e]
  D:`i$g[0]; w2:2*D
  i:e div D; c:e mod D
  a: x[(i*w2)+c]; b: x[(i*w2)+D+c]
  set[o; e; a * 1. % 1. + exp[0. - b]]}; 0; 3]
/ Depthwise 1-D conv (per-channel, zero-padded): out[t,c]=Σ_k x[t+k-pad,c]·W[c,k]+B[c]
dwconv.kern: gpu.kernel[{[o;x;w;b;g;e]
  T:`i$g[0]; D:`i$g[1]; ks:`i$g[2]; pad:`i$g[3]
  i:e div D; c:e mod D
  acc: +/{[k]
    tp: (i+k)-pad
    ok: (~(tp<0)) & (tp<T)
    ($[ok; x[(tp*D)+c]; 0.]) * w[(c*ks)+k]}'!ks
  set[o; e; acc + b[c]]}; 0; 5]
/ Per-channel affine (BatchNorm inference folded to scale/shift): out[t,c]=x·A[c]+B[c]
chanaffine.kern: gpu.kernel[{[o;x;a;b;g;e]
  D:`i$g[0]; c:e mod D
  set[o; e; (x[e]*a[c]) + b[c]]}; 0; 5]

/ GLU:  bx[T,2D] → bo[T,D].
glu: {[bo;bx;T;D]
  g: nn.par[`glu; ,D]
  gpu.dispatch[nn.pipe[`glu; glu.kern; 3]; (bo;bx;g); T*D]
  bo}
/ Depthwise conv:  bx[T,D], bw[D,ks], bb[D] → bo[T,D].  pad = (ks-1)÷2 for "same".
dwconv: {[bo;bx;bw;bb;T;D;ks;pad]
  g: nn.par[`dwconv; (T;D;ks;pad)]
  gpu.dispatch[nn.pipe[`dwconv; dwconv.kern; 5]; (bo;bx;bw;bb;g); T*D]
  bo}
/ Channel affine:  bo[T,D] = bx·A[c] + B[c].
chanaffine: {[bo;bx;ba;bb;T;D]
  g: nn.par[`chanaffine; ,D]
  gpu.dispatch[nn.pipe[`chanaffine; chanaffine.kern; 5]; (bo;bx;ba;bb;g); T*D]
  bo}

/ ── 2-D convolution family (kernel 3, stride 2, pad 1) ───────────────────────
/ Layout [C,T,F] channel-major flat.  conv output size s(n) = 1 + (n−1)÷2.
nn.sub2: {[n] 1 + (n-1) div 2}

/ regular conv2d 1→C:  out[oc,t',f'] = b[oc] + Σ_{kt,kf} in[2t'+kt−1, 2f'+kf−1]·W[oc,kt,kf]
conv2d.kern: gpu.kernel[{[o;x;w;b;g;e]
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
dwconv2d.kern: gpu.kernel[{[o;x;w;b;g;e]
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
pwconv2d.kern: gpu.kernel[{[o;x;w;b;g;e]
  C:`i$g[0]; T:`i$g[1]; F:`i$g[2]
  tf: T*F
  oc: e div tf; pos: e mod tf
  set[o; e; (b[oc]) + +/{[ic] (x[(ic*tf)+pos]) * w[(oc*C)+ic]}'!C]}; 0; 5]
/ flatten [C,Tp,Fp] → [Tp, C·Fp]  (out[t',c·Fp+f'] = in[c,t',f'])
flatten.kern: gpu.kernel[{[o;x;g;e]
  C:`i$g[0]; Tp:`i$g[1]; Fp:`i$g[2]
  cf: C*Fp
  tpp: e div cf; rem: e mod cf
  c: rem div Fp; fp: rem mod Fp
  set[o; e; x[(c*Tp*Fp)+(tpp*Fp)+fp]]}; 0; 3]

/ cfg = (C;Tout;Fout;Tin;Fin)
conv2d: {[bo;bin;bw;bb;cfg]
  g: nn.par[`conv2d; cfg]
  gpu.dispatch[nn.pipe[`conv2d; conv2d.kern; 5]; (bo;bin;bw;bb;g); (cfg 0)*(cfg 1)*(cfg 2)]
  bo}
dwconv2d: {[bo;bin;bw;bb;cfg]
  g: nn.par[`dwconv2d; cfg]
  gpu.dispatch[nn.pipe[`dwconv2d; dwconv2d.kern; 5]; (bo;bin;bw;bb;g); (cfg 0)*(cfg 1)*(cfg 2)]
  bo}
pwconv2d: {[bo;bin;bw;bb;C;T;F]
  g: nn.par[`pwconv2d; (C;T;F)]
  gpu.dispatch[nn.pipe[`pwconv2d; pwconv2d.kern; 5]; (bo;bin;bw;bb;g); C*T*F]
  bo}
flatten: {[bo;bin;C;Tp;Fp]
  g: nn.par[`flatten; (C;Tp;Fp)]
  gpu.dispatch[nn.pipe[`flatten; flatten.kern; 3]; (bo;bin;g); Tp*C*Fp]
  bo}

/ ── Multi-head self-attention ────────────────────────────────────────────────
/ Two head-structured batched-matmul kernels (Q/K/V projections and the output
/ projection are plain Linear); softmax over the [H*T,T] score rows reuses `softmax`.
/ Indices are i32 (integer-index dialect) — exact for any H*T*T, no 2^24 cliff.
/
/ scores S[h,i,j] = scale · Σ_k Q[i,h·dh+k]·K[j,h·dh+k]   (one thread per H*T*T elem)
attn.scores.kern: gpu.kernel[{[s;q;kb;g;e]
  T:`i$g[0]; D:`i$g[1]; dh:`i$g[2]; sc:g[3]
  tt: T*T
  h: e div tt; rem: e mod tt
  i: rem div T; j: rem mod T
  base: h*dh
  set[s; e; sc * +/{[k] (q[(i*D)+base+k]) * kb[(j*D)+base+k]}'!dh]}; 0; 4]
/ context C[i,c] = Σ_j A[h,i,j]·V[j,c]  where h = c÷dh   (one thread per T*D elem)
/ writes straight into the concatenated [T,D] layout — no per-head regather.
attn.ctx.kern: gpu.kernel[{[o;a;v;g;e]
  T:`i$g[0]; D:`i$g[1]; dh:`i$g[2]
  i: e div D; c: e mod D
  h: c div dh
  hb: h*T*T
  set[o; e; +/{[j] (a[hb+(i*T)+j]) * v[(j*D)+c]}'!T]}; 0; 4]

/ Resident attention scores: bs[H*T*T] = scaled QKᵀ per head.  H = D÷dh.
attn.scores: {[bs;bq;bk;T;D;dh;scale]
  g: nn.par[`attnScores; (T;D;dh;scale)]
  gpu.dispatch[nn.pipe[`attnScores; attn.scores.kern; 4]; (bs;bq;bk;g); (D div dh)*T*T]
  bs}
/ Resident attention context: bc[T,D] = A·V, gathered into concatenated-head layout.
attn.ctx: {[bc;ba;bv;T;D;dh]
  g: nn.par[`attnCtx; (T;D;dh)]
  gpu.dispatch[nn.pipe[`attnCtx; attn.ctx.kern; 4]; (bc;ba;bv;g); T*D]
  bc}

/ ── Relative-position attention (Transformer-XL / Conformer) ─────────────────
/ score[h,i,j] = scale·Σ_k (q[i,c]+u[c])·k[j,c] + (q[i,c]+v[c])·P[i−j, c]   (c=h·dh+k)
/ P[rel] is the projected sinusoidal positional encoding, rel = i−j indexed at row
/ (i−j)+(T−1) of a [2T−1, D] table (P = posEmb · Wposᵀ).  u,v are learned [D] biases.
attn.rT::0; attn.rD::0
/ sinusoidal positional encoding row for table index idx (relative pos idx−(T−1)):
/ interleaved sin(r·ωk)/cos(r·ωk), ωk = 10000^(−2k/D).
attn.posRow: {[idx]
  r:  (0.+idx) - 0. + attn.rT - 1
  kk: `f$ !attn.rD div 2
  freq: exp (0. - (2. * kk) % 0. + attn.rD) * log 10000.
  ang: r * freq
  ,/ +(sin ang; cos ang)}
attn.pos: {[T;D] attn.rT::T; attn.rD::D; ,/ attn.posRow' !(2*T)-1}

/ The rel-pos table depends only on (T,D), so it is IDENTICAL for all 24 layers — but
/ rebuilding it host-side and re-uploading it every layer cost ~45 ms per encoder run
/ (11% of the total). Cache the device buffer and rebuild only when the shape changes.
/ Same for the constant zero bias the pos projection uses.
attn.peT::0; attn.peD::0; attn.peB::0; attn.peZ::0
attn.peMk: {[T;D]
  $[attn.peB=0; 0; gpu.free attn.peB]
  $[attn.peZ=0; 0; gpu.free attn.peZ]
  attn.peB:: gpu.buffer[attn.pos[T;D]]
  attn.peZ:: gpu.buffer[D#0.]
  attn.peT::T; attn.peD::D}
attn.peFresh: {[T;D] $[(attn.peT=T)&(attn.peD=D); 0; attn.peMk[T;D]]}
attn.posBuf:  {[T;D] attn.peFresh[T;D]; attn.peB}
attn.zeroBuf: {[T;D] attn.peFresh[T;D]; attn.peZ}

/ rel-pos scores: buffers s,q,k,u,v,P + params (T;D;dh;scale).  One thread per H·T·T.
attn.relScores.kern: gpu.kernel[{[s;q;kb;u;v;pe;g;e]
  T:`i$g[0]; D:`i$g[1]; dh:`i$g[2]; sc:g[3]
  tt: T*T
  h: e div tt; rem: e mod tt
  i: rem div T; j: rem mod T
  base: h*dh
  prow: (((i-j)+(T-1)) * D)
  set[s; e; sc * +/{[k]
    c: base+k; qc: q[(i*D)+c]
    ((qc + u[c]) * kb[(j*D)+c]) + (qc + v[c]) * pe[prow+c]}'!dh]}; 0; 7]
/ cfg = (T;D;dh;scale)
attn.relScores: {[bs;bq;bk;bu;bv;bpe;cfg]
  g: nn.par[`attnRel; cfg]
  gpu.dispatch[nn.pipe[`attnRel; attn.relScores.kern; 7]; (bs;bq;bk;bu;bv;bpe;g)
             ; ((cfg 1) div (cfg 2))*(cfg 0)*(cfg 0)]
  bs}

/ attn.rel[bx; WB; cfg] — resident rel-pos self-attention.
/   WB = 11 handles (Wq;Bq;Wk;Bk;Wv;Bv;Wo;Bo; Wpos[D,D]; u[D]; v[D]);  cfg=(T;D;H).
/ Chained fully resident: 3 Linear (Q/K/V) → rel scores → row-softmax → context → Linear.
attn.rel: {[bx; WB; cfg]
  T:cfg 0; D:cfg 1; H:cfg 2
  dh: D div H; scale: 1. % sqrt 0.+dh
  bwq:WB 0; bbq:WB 1; bwk:WB 2; bbk:WB 3; bwv:WB 4; bbv:WB 5; bwo:WB 6; bbo:WB 7
  bwp:WB 8; bu:WB 9; bv:WB 10
  bq:nn.buf[T*D];  linear[bq;bx;bwq;bbq;T;D;D]
  bk:nn.buf[T*D];  linear[bk;bx;bwk;bbk;T;D;D]
  bvv:nn.buf[T*D]; linear[bvv;bx;bwv;bbv;T;D;D]
  np: (2*T)-1
  bpe0: attn.posBuf[T;D]                     / cached: identical for every layer
  bz:   attn.zeroBuf[T;D]                    / cached constant zero bias
  bpe:nn.buf[np*D]; linear[bpe;bpe0;bwp;bz;np;D;D]     / P = posEmb·Wposᵀ
  bs:nn.buf[H*T*T]; attn.relScores[bs;bq;bk;bu;bv;bpe;(T;D;dh;scale)]
  bsm:nn.buf[H*T*T]; bmx:nn.buf[H*T]; bsu:nn.buf[H*T]
  softmax[bsm;bs;bmx;bsu;H*T;T]
  bc:nn.buf[T*D]; attn.ctx[bc;bsm;bvv;T;D;dh]
  bo:nn.buf[T*D]; linear[bo;bc;bwo;bbo;T;D;D]
  nn.drop(bq;bk;bvv;bpe;bs;bsm;bmx;bsu;bc)   / bpe0/bz are cached, not owned here
  bo}
/ Host form: X[T,D] + host weight list → [T,D].
attn.rel.host: {[X;W;cfg]
  bx:gpu.buffer[X]
  WB: gpu.buffer' W
  bo: attn.rel[bx; WB; cfg]
  r: ((cfg 0)*(cfg 1)) # gpu.read[bo]
  nn.drop(bx;bo); nn.drop WB
  r}

/ attn.abs[bx; WB; cfg] — resident absolute-position (plain scaled dot-product) MHSA.
/   WB = 8 handles (Wq;Bq;Wk;Bk;Wv;Bv;Wo;Bo);  cfg=(T;D;H).
attn.abs: {[bx; WB; cfg]
  T:cfg 0; D:cfg 1; H:cfg 2
  dh: D div H; scale: 1. % sqrt 0.+dh
  bwq:WB 0; bbq:WB 1; bwk:WB 2; bbk:WB 3; bwv:WB 4; bbv:WB 5; bwo:WB 6; bbo:WB 7
  bq:nn.buf[T*D];  linear[bq;bx;bwq;bbq;T;D;D]
  bk:nn.buf[T*D];  linear[bk;bx;bwk;bbk;T;D;D]
  bvv:nn.buf[T*D]; linear[bvv;bx;bwv;bbv;T;D;D]
  bs:nn.buf[H*T*T]; attn.scores[bs;bq;bk;T;D;dh;scale]
  bsm:nn.buf[H*T*T]; bmx:nn.buf[H*T]; bsu:nn.buf[H*T]
  softmax[bsm;bs;bmx;bsu;H*T;T]
  bc:nn.buf[T*D]; attn.ctx[bc;bsm;bvv;T;D;dh]
  bo:nn.buf[T*D]; linear[bo;bc;bwo;bbo;T;D;D]
  nn.drop(bq;bk;bvv;bs;bsm;bmx;bsu;bc)
  bo}
attn.abs.host: {[X;W;cfg]
  bx:gpu.buffer[X]
  WB: gpu.buffer' W
  bo: attn.abs[bx; WB; cfg]
  r: ((cfg 0)*(cfg 1)) # gpu.read[bo]
  nn.drop(bx;bo); nn.drop WB
  r}

/ ── Feed-forward block (pre-norm, residual) ──────────────────────────────────
/   out = x + s · Linear2( SiLU( Linear1( LayerNorm(x) ) ) )
/ WB = (W1[Dff,D];B1[Dff];W2[D,Dff];B2[D];GAM[D];BET[D]) handles.
/ cfg = (M;D;Dff;eps;s) — `s` is 0.5 for a conformer macaron half-step, 1. for a
/ plain transformer FFN.  Packed because ink lambdas cap at 8 params.
ffn: {[bx; WB; cfg]
  M:cfg 0; D:cfg 1; Dff:cfg 2; eps:cfg 3; s:cfg 4
  bw1:WB 0; bb1:WB 1; bw2:WB 2; bb2:WB 3; bgm:WB 4; bbt:WB 5
  h0:nn.buf[M*D]; bm:nn.zbuf M; br:nn.zbuf M
  h1:nn.buf[M*Dff]; h2:nn.buf[M*Dff]; h3:nn.buf[M*D]
  bo:nn.buf[M*D]
  layernorm[h0; bx; bgm; bbt; bm; br; (M;D;eps)]
  linear[h1; h0; bw1; bb1; M; D; Dff]
  silu[h2; h1; M*Dff]
  linear[h3; h2; bw2; bb2; M; Dff; D]
  addscaled[bo; bx; h3; s; M*D]
  nn.drop(h0;bm;br;h1;h2;h3)
  bo}
ffn.host: {[X; W; cfg]
  bx:gpu.buffer[X]
  WB: gpu.buffer' W
  bo: ffn[bx; WB; cfg]
  r: ((cfg 0)*(cfg 1)) # gpu.read[bo]
  nn.drop(bx;bo); nn.drop WB
  r}

/ ── Resident weight helpers ──────────────────────────────────────────────────
nn.hold:   {[arrs] gpu.buffer' arrs}     / list of host arrays → resident handles
nn.holdWs: {[Ws] nn.hold' Ws}            / per-layer weight lists → handle lists

/ ── Host-side scalar/vector helpers (CPU, no GPU) ────────────────────────────
/ Small sequential work where a dispatch would cost more than it saves — the
/ transducer decode loop lives on these.
nn.fn.sig:  {[v] 1. % 1. + exp 0. - v}
nn.fn.tanh: {[v] e: exp 2.*v; (e-1.) % e+1.}
nn.fn.relu: {[v] 0. | v}
nn.fn.amax: {[v] v ? |/v}                         / argmax = index of first max

/ Matrix-vector W[n,k]·x.  Three forms, fastest last:
/   nn.fn.mv   flat W, rebuilds a k-long index vector per output row — slowest.
/   nn.fn.mvr  W pre-split into ROWS; 3.1x faster than mv at 2560×640.
/   nn.fn.mvc  W pre-split into COLUMNS, read as Σ_k x[k]·W[:,k] — same k order, so
/              BIT-IDENTICAL to mvr, but n·(alloc+multiply+reduce) collapses into
/              k·(scalar×vector) plus one fold: far fewer interpreter round-trips and
/              temporaries.  ~3.4x faster than mvr at the decoder's 2560×640 shape.
nn.fn.mvd: {[W;k;x;o] +/ x * W@(o*k)+!k}
nn.fn.mv:  {[W;n;k;x] nn.fn.mvd[W;k;x;]' !n}
nn.fn.mvX:: ()
nn.fn.dot: {[r] +/ nn.fn.mvX * r}
nn.fn.mvr: {[rows;x] nn.fn.mvX:: x; nn.fn.dot' rows}
nn.fn.mvc: {[cols;x] +/ x * cols}

/ nn.fn.cols[Wf;n;k] — flat row-major W[n,k] → list of k columns, each n long.
nn.fn.colW:: (); nn.fn.colN::0; nn.fn.colK::0
nn.fn.colOne: {[j] nn.fn.colW@(j + nn.fn.colK*!nn.fn.colN)}
nn.fn.cols: {[Wf;n;k] nn.fn.colW::Wf; nn.fn.colN::n; nn.fn.colK::k; nn.fn.colOne' !k}

/ LSTM cell step: (x[E],h[H],c[H]) → (h'[H]; c'[H]).  Cih/Chh are COLUMN LISTS of
/ Wih[4H,E] / Whh[4H,H] (see nn.fn.cols/nn.fn.mvc); b is flat [4H].
lstm: {[x;h;c;Cih;Chh;b;H]
  pre: b + (nn.fn.mvc[Cih;x]) + nn.fn.mvc[Chh;h]
  ig: nn.fn.sig pre@!H
  fg: nn.fn.sig pre@H+!H
  gg: nn.fn.tanh pre@(2*H)+!H
  og: nn.fn.sig pre@(3*H)+!H
  nc: (fg*c) + ig*gg
  (og * nn.fn.tanh nc; nc)}
