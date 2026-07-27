/ bench/nnshapes.k — the tropical cost model against REAL kernel shapes.
/ doc/research/tropical.md, Experiment 2. Replaces the synthetic bench/tropical.k
/ (since deleted), which only ever exercised one shape (elementwise map). These are lib/nn.k's production kernels,
/ the ones the Parakeet pipeline actually runs, spanning shapes the elementwise grid
/ says nothing about:
/
/   0 gemm      plain GEMM        reduction per output, 8K+4 B/out, 2K flop/out
/   1 gemmt     8x8-tiled GEMM    SAME flops, ~8x less traffic (shared-memory tiles)
/   2 silu      elementwise       x/(1+exp(-x))       — transcendental, 8 B/elem
/   3 gelu      elementwise       tanh approximation  — heavier transcendental
/   4 softmax   TWO dispatches    row reduce then apply
/   5 layernorm TWO dispatches    row mean/var then affine
/   6 attnsc    attention scores  reduction over dh per output
/   7 attnctx   attention context reduction over T  per output
/
/   8..11  the SAME four params-writing ops with the params write HOISTED out of the
/          repeat loop (written once at setup, then raw dispatches). lib/nn.k's
/          resident ops call gpu.write on their params buffer every invocation, and
/          gpuBufferWrite calls v.sync() — a full vkQueueSubmit + vkQueueWaitIdle.
/          So each call drains the queue and throws away the deferred batching the
/          rest of the design depends on. 8..11 measure the same GPU work without
/          that stall; the gap between 4..7 and 8..11 IS the per-call sync cost.
/
/ gemm vs gemmt is the point of the whole file: identical arithmetic, different memory
/ traffic, and lib/nn.k picks between them today with a hand-written 8-alignment test
/ and no cost reasoning at all. If a max-plus cost model is worth anything to a
/ compiler, predicting THAT crossover is the least it should do.
/
/   usage: ink bench/nnshapes.k <KI> <S> <R>
/     KI  kernel index 0..7
/     S   size knob (per-kernel meaning; see the driver)
/     R   repetitions recorded before the single readback
/
/ Buffers are allocated ONCE and reused, so R
/ adds only work, and the caller differences two R values to cancel start-up, device
/ creation, upload and readback.

2: "lib/nn.k"

KI: `I$`argv[2]
S:  `I$`argv[3]
R:  `I$`argv[4]

/ ── setup: allocate every buffer ONCE, park handles in globals ────────────────
/ (ink lambdas do not close over enclosing locals, so the per-step lambdas below
/ read globals rather than captured state.)
nnbSetup: {[]
  $[KI<2;  nnbGemm[]
    KI<4;  nnbEw[]
    (KI=4)|KI=8;  nnbSm[]
    (KI=5)|KI=9;  nnbLn[]
    (KI=6)|KI=10; nnbAsc[]
    nnbActx[]]
  / Hoisted variants: run the wrapper ONCE so its pipelines are compiled and its
  / params buffer is written, then the repeat loop dispatches those pipes directly.
  $[KI=8;  SoftmaxR[BO;BX;BM;BS;M;NCOL]
    KI=9;  LayerNormR[BO;BX;BG;BB2;BM;BS;(M;NCOL;0.00001)]
    KI=10; AttnScoresR[BSC;BQ;BK;TT;DMODEL;DHEAD;0.125]
    KI=11; AttnCtxR[BO;BAT;BV;TT;DMODEL;DHEAD]
    0]}

/ GEMM: square M=N=K=S. Threads = S*S, each reducing over K=S.
nnbGemm: {[]
  M:: S; NN:: S; KK:: S
  BA:: gpu.buffer[(M*KK) # 0.01]
  BB:: gpu.buffer[(KK*NN) # 0.02]
  BC:: gpu.buffer[(nnPad[M*NN]) # 0.]
  GP:: gpu.buffer[4#0.]
  gpu.write[GP; (0.+M),(0.+NN),(0.+KK),0.]
  PIPE:: $[KI=0; gemmPlainPipe[]; gemmTilePipe[]]
  0}

/ Elementwise silu/gelu over S elements.
nnbEw: {[]
  NEL:: S
  BX:: gpu.buffer[(nnPad S) # 0.5]
  BO:: gpu.buffer[(nnPad S) # 0.]
  0}

/ Softmax / LayerNorm: M=S rows of NCOL columns.
NCOL:: 256
nnbSm: {[]
  M:: S
  BX:: gpu.buffer[(nnPad[S*NCOL]) # 0.5]
  BO:: gpu.buffer[(nnPad[S*NCOL]) # 0.]
  BM:: gpu.buffer[(nnPad S) # 0.]
  BS:: gpu.buffer[(nnPad S) # 0.]
  0}
nnbLn: {[]
  nnbSm[]
  BG:: gpu.buffer[(nnPad NCOL) # 1.]
  BB2:: gpu.buffer[(nnPad NCOL) # 0.]
  0}

/ Attention: T=S tokens, D=256 model dim, dh=64 head dim (H=4 heads).
DMODEL:: 256
DHEAD::  64
nnbAsc: {[]
  TT:: S
  BQ:: gpu.buffer[(nnPad[S*DMODEL]) # 0.01]
  BK:: gpu.buffer[(nnPad[S*DMODEL]) # 0.02]
  BSC:: gpu.buffer[(nnPad[(DMODEL div DHEAD)*S*S]) # 0.]
  0}
nnbActx: {[]
  TT:: S
  BAT:: gpu.buffer[(nnPad[(DMODEL div DHEAD)*S*S]) # 0.01]
  BV::  gpu.buffer[(nnPad[S*DMODEL]) # 0.02]
  BO::  gpu.buffer[(nnPad[S*DMODEL]) # 0.]
  0}

/ ── one repetition of the op under test ──────────────────────────────────────
nnbStep: {[i]
  $[KI<2;  gpu.dispatch[PIPE; (BC;BA;BB;GP); M*NN]
    KI=2;  SiluR[BO;BX;NEL]
    KI=3;  GeluR[BO;BX;NEL]
    KI=4;  SoftmaxR[BO;BX;BM;BS;M;NCOL]
    KI=5;  LayerNormR[BO;BX;BG;BB2;BM;BS;(M;NCOL;0.00001)]
    KI=6;  AttnScoresR[BSC;BQ;BK;TT;DMODEL;DHEAD;0.125]
    KI=7;  AttnCtxR[BO;BAT;BV;TT;DMODEL;DHEAD]
    KI=8;  nnbSmH[]
    KI=9;  nnbLnH[]
    KI=10; gpu.dispatch[asPipe; (BSC;BQ;BK;asParam); (DMODEL div DHEAD)*TT*TT]
    gpu.dispatch[acPipe; (BO;BAT;BV;acParam); TT*DMODEL]]}
/ Same two dispatches SoftmaxR/LayerNormR issue, minus the params write + sync.
nnbSmH: {[]
  gpu.dispatch[smSP; (BM;BS;BX;smParam); M]
  gpu.dispatch[smAP; (BO;BX;BM;BS;smParam); M*NCOL]}
nnbLnH: {[]
  gpu.dispatch[lnSP; (BM;BS;BX;lnParam); M]
  gpu.dispatch[lnAP; (BO;BX;BM;BS;BG;BB2;lnParam); M*NCOL]}

/ Which buffer to read back to force the queue to drain.
nnbOut: {[] $[KI<2; BC; (KI=6)|KI=10; BSC; BO]}

/ ── in-process timing (doc/research/tropical.md, Experiment 2) ────────────────
/ `t[] is a microsecond CLOCK_MONOTONIC counter (src/runtime/syms.zig) that works
/ inside a lambda, so the timed region can sit INSIDE gpu.computeRun, around the
/ dispatch loop only. The previous harness differenced whole-subprocess wall times
/ from python, which charged every point with process start-up, device creation,
/ buffer allocation, the upload and the readback — and produced negative per-rep
/ times, non-monotone data, and a non-reproducible 1.8x error. Porting to in-process
/ timing took reproducibility from ~80% to ~1% and removed a 65% inflation.
/ The R-vs-4R slope now cancels only the readback and the loop setup.
REPS: $[4 < #`argv; `I$`argv[5]; 3]
RA:: 0; RB:: 0
nnbLoop: {[R] nnbStep' !R; gpu.read nnbOut[]; 0}
nnbTime: {[R] s: `t[]; nnbLoop R; e: `t[]; e-s}
nnbA: {[j] nnbTime RA}
nnbB: {[j] nnbTime RB}

gpu.computeRun[{[_]
  nnbSetup[]
  RA:: R; RB:: 4*R
  nnbTime 4                                 / warm-up: compile, ramp clocks, page in
  ta: &/ nnbA' !REPS                        / best-of: min rejects one-sided noise
  tb: &/ nnbB' !REPS
  per: (`f$ tb-ta) % `f$ RB-RA
  v: gpu.read nnbOut[]
  `0 0: "ki=",($KI)," s=",($S)," r=",($R)," us=",($per)," chk=",($*v)
  0 }]
