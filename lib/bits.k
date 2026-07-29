/
# bits

Runs a dye compute kernel on the CPU by interpreting its neutral IR.

dye lowers a kernel lambda to a target-neutral typed SSA IR (xOp/xTy/xArg/xVal
in lib/dye.k) and then to SPIR-V. `bits` is a SECOND back-end for that SAME IR:
a pure-k interpreter that runs the kernel on the CPU, node-for-node, over ink
vectors. So ONE kernel lambda yields both the GPU program (gpu.kernel) and a
CPU reference (bits.run) — a permanent cross-backend oracle (test/kkbits.k;
test/nn.k's hand-written references are generated from this).

v1 scope: the elementwise/select/gather/reduce subset the nn kernels use —
const cons extract arith math neg lnot select f2s i2f, buffer gather (bufidx)
and store (setb), and the in-kernel reductions rsum/rmax plus the bounded
loops ndo/whileL. Scatter (sadd/igetb/isetb, the XPBD path) is not needed by
the nn references and errors loudly if hit — correctness first.

Pure k — loads on the first reference to any `bits.*` name.
\

2: "lib/dye.k"

/ ── truncation toward zero (OpConvertFToS / integer divide semantics) ─────────
bTrunc: {[x] $[x<0.; 0. - _ (0. - x); _ x]}
bIdiv:  {[a;b] bTrunc[a % b]}
bImod:  {[a;b] a - b * bIdiv[a;b]}
bFmod:  {[a;b] a - b * bTrunc[a % b]}
bTanh:  {[x] e: exp 2. * x; (e - 1.) % e + 1.}

/ ── interpreter state (globals; k lambdas don't close over parent scope) ──────
bBuf:: ()          / the buffer bindings (accumulators then buffers), mutated by setb
bV::   ()          / per-thread value slot per IR node
bD::   0           / current thread index

/ ── build the neutral IR for a kernel lambda, WITHOUT SPIR-V lowering ─────────
/ Mirrors compGpN's env (accumulators 0..nAcc-1, then nBuf buffers, then the
/ thread index), but binds each param to its SLOT INDEX rather than a SPIR-V id,
/ and stops after xSeq — so xOp/xTy/xArg/xVal hold the body IR to interpret.
/ kIrEnvOne emits the bufp (buffer pointer, xVal=slot) / param (thread index)
/ prologue nodes; returns the value-root node index. Xidx=1 = integer dialect,
/ matching gpu.kernel's default.
bits.build: {[fn; nAcc; nBuf]
  Xidx:: 1
  lam: lamOf fn; an: lamArgs lam
  np: #an
  / roles: nAcc scatter accumulators, then nBuf buffers, then the thread index.
  / Build the list directly — an inner {[j] …nAcc…} lambda can't see nAcc (no closures).
  roles: (nAcc # `scat), (nBuf # `buf), `i32
  pairs: {[s;r] (s;r)}'[!np; roles]
  env: an!pairs
  xReset[]
  e2: (!env)!kIrEnvOne' env[!env]
  rp: xSeq[lamBody lam; e2; `f32]
  rp 0}

/ ── the node evaluator ───────────────────────────────────────────────────────
/ bEv[k] returns node k's value for the current thread (bD) / loop state (bV of
/ the counter nodes). Args always have lower indices and are already in bV.
bArith: {[g; ty; a; b]
  isi: ty~`i32
  $[g~`"+"; a + b
    g~`"-"; a - b
    g~`"*"; a * b
    g~`"%"; $[isi; bIdiv[a;b]; a % b]
    g~`div; bIdiv[a;b]
    g~`mod; bImod[a;b]
    g~`"<"; $[a < b; 1.; 0.]
    g~`">"; $[a > b; 1.; 0.]
    g~`"="; $[a = b; 1.; 0.]
    g~`"~"; $[a = b; 0.; 1.]          / dyadic ~ = not-equal (OpFOrdNotEqual / OpINotEqual)
    g~`"&"; $[(a > 0.5) & b > 0.5; 1.; 0.]
    g~`"|"; $[(a > 0.5) | b > 0.5; 1.; 0.]
    g~`","; a , b
    !"bits: unknown arith glyph ",$g]}
bMath: {[nm; ty; a]
  x: bV a 0
  y: $[1 < #a; bV a 1; 0n]
  z: $[2 < #a; bV a 2; 0n]
  $[nm~`sqrt; sqrt x
    nm~`exp;  exp x
    nm~`log;  log x
    nm~`abs;  abs x
    nm~`floor; _ x
    nm~`fract; x - _ x
    nm~`sign;  $[x < 0.; -1.; $[x > 0.; 1.; 0.]]
    nm~`sqr;  x * x
    nm~`sin;  sin x
    nm~`cos;  cos x
    nm~`tanh; bTanh x
    nm~`min;  $[x < y; x; y]
    nm~`max;  $[x > y; x; y]
    nm~`pow;  exp y * log x
    nm~`mod;  $[ty~`i32; bImod[x;y]; bFmod[x;y]]
    nm~`step; $[y < x; 0.; 1.]                       / step(edge=x, v=y)
    nm~`clamp; $[x < y; y; $[x > z; z; x]]           / clamp(x, lo=y, hi=z)
    nm~`mix;  (x * 1. - z) + y * z                   / mix(x, y, t=z)
    nm~`smoothstep; bSmooth[x; y; z]                 / smoothstep(e0=x, e1=y, v=z)
    nm~`length; sqrt +/ x * x
    nm~`dot;  +/ x * y
    !"bits: unimplemented math ",$nm]}
bSmooth: {[e0; e1; v] t: (v - e0) % e1 - e0; t: $[t < 0.; 0.; $[t > 1.; 1.; t]]; (t * t) * 3. - 2. * t}

bEv: {[k]
  op: xOp k; a: xArg k
  $[op~`const;   xVal k
    op~`param;   bD                       / the sole plain param = the thread index
    op~`bufp;    xVal k                    / a buffer pointer carries its slot index
    op~`consc;   bV @ a                    / vector constant = component node values
    op~`cons;    bV @ a                    / OpCompositeConstruct
    op~`extract; (bV a 0) @ xVal k
    op~`arith;   bArith[xVal k; xTy k; bV a 0; bV a 1]
    op~`math;    bMath[xVal k; xTy k; a]
    op~`neg;     0. - bV a 0
    op~`lnot;    $[(bV a 0) > 0.5; 0.; 1.]
    op~`select;  $[(bV a 0) > 0.5; bV a 1; bV a 2]
    op~`f2s;     bTrunc bV a 0
    op~`i2f;     0. + bV a 0
    op~`bufidx;  (bBuf @ xVal a 0) @ `i$ bTrunc bV a 1
    op~`setb;    bSet[a]
    op in `kparam`kparami`lparam; bV k     / loop var: value set by the loop runner
    op in `rsum`rmax`ndo`whileL; bLoop k
    !"bits: unimplemented op ",$op]}

/ bV is an F-vector (every compute-kernel value is a scalar); storing an INTEGER
/ node value (a buffer slot or thread index) coerces to float — the amend coercion
/ this once tripped over is fixed in src/primitive/amend.zig, so these are plain
/ in-place indexed assigns in an each (no amend-reassign / recursion workaround).
bPut:   {[k; v] bV[k]:: v}
bSweep: {[idxs] {[j] bV[j]:: bEv j}' idxs; 0}

/ store: bBuf[slot][idx] := val. Returns the stored value (set's IR value is vp).
bSet: {[a]
  slot: xVal a 0
  idx:  `i$ bTrunc bV a 1
  val:  bV a 2
  bBuf:: @[bBuf; slot; :; @[bBuf slot; idx; :; val]]
  val}

/ evaluate every DIRECT child node of loop L (xRgn=L) in [L+1, oe), in order.
/ Nested-loop bodies (xRgn=nested) are skipped here and run by bLoop recursively.
bRegion: {[k; oe] j: (1 + k) + ! oe - 1 + k; j @ & (xRgn j) = k}
bRun1:   {[k; oe] bSweep bRegion[k; oe]}

bLoop: {[k]
  op: xOp k
  $[op~`rsum;   bRsum[k]
    op~`rmax;   bRmax[k]
    op~`ndo;    bNdo[k]
    op~`whileL; bWhile[k]
    !"bits: unimplemented loop ",$op]}

/ rsum/rmax: xArg[k] 0 = trip-count node; xVal[k] = (counterNode; resultRoot; ownedEnd).
/ Explicit accumulator recursion (not an each) so the result-root is threaded as an
/ argument — a nested reduction in the body reuses these functions without clobbering
/ any shared state (bV node slots are disjoint across nested loops). mode 0=sum, 1=max.
bRsum: {[k] m: xVal k; bFold[k; m 0; m 1; m 2; 0; `i$ bV xArg[k] 0; 0.; 0]}
bRmax: {[k] m: xVal k; bFold[k; m 0; m 1; m 2; 0; `i$ bV xArg[k] 0; -0w; 1]}
bFold: {[k; cn; rr; oe; c; kt; acc; mode]
  $[c = kt; acc; bFold[k; cn; rr; oe; c + 1; kt; bAccum[k; cn; rr; oe; c; acc; mode]; mode]]}
bAccum: {[k; cn; rr; oe; c; acc; mode]
  bPut[cn; c]; bRun1[k; oe]; v: bV rr; $[mode; $[v > acc; v; acc]; acc + v]}

/ ndo: `n f/ x` — xArg[k] = (countNode; initStateNode); xVal[k] = (stateParam; resultRoot; ownedEnd).
bNdo: {[k] m: xVal k; a: xArg k; bNdoLoop[k; m 0; m 1; m 2; 0; `i$ bV a 0; bV a 1]}
bNdoLoop: {[k; sp; rr; oe; c; n; st]
  $[c = n; st; bNdoLoop[k; sp; rr; oe; c + 1; n; bNdoStep[k; sp; rr; oe; st]]]}
bNdoStep: {[k; sp; rr; oe; st] bPut[sp; st]; bRun1[k; oe]; bV rr}

/ whileL: xArg[k] = ,initState; xVal[k] = (stateParam; condRoot; condEnd; bodyRoot; ownedEnd).
bWhile: {[k] m: xVal k; bWhileLoop[k; m 0; m 1; m 2; m 3; m 4; bV *xArg k]}
bWhileLoop: {[k; sp; cr; ce; br; oe; st]
  bPut[sp; st]
  bRun1[k; ce]                                             / evaluate the cond region [k+1, ce)
  $[(bV cr) > 0.5; bWhileLoop[k; sp; cr; ce; br; oe; bWhileBody[k; ce; oe; br]]; st]}
bWhileBody: {[k; ce; oe; br] bSweep bBodyIdx[k; ce; oe]; bV br}
bBodyIdx: {[k; ce; oe] j: ce + ! oe - ce; j @ & (xRgn j) = k}

/ ── driver: run one kernel dispatch over `count` threads ──────────────────────
/ bufs = the buffer bindings in param order (accumulators then buffers, incl. the
/ grid buffer). Returns the mutated buffer list; index the output slot(s) yourself.
bits.run: {[fn; nAcc; nBuf; bufs; count]
  root: bits.build[fn; nAcc; nBuf]
  bBuf:: bufs
  bDrive[0; count]
  bBuf}
bDrive:  {[d; n] $[d < n; bDriveOne[d; n]; 0]}
bDriveOne: {[d; n] bThread d; bDrive[d + 1; n]}
bThread: {[d] bD:: d; bV:: (# xOp) # 0.; bSweep[&0 > xRgn]}
