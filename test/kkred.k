/ test/kkred.k — whole-buffer reduce (kk2 §6, tier-2 gateway) vs CPU.
/ Places arrays with the 9: io verb, runs kk.sum/max/min/prod (two-stage reduce),
/ and checks against the CPU fold. Float sum reorders (grid-stride), so sum is
/ checked to a relative tolerance; max/min/prod-of-ints match exactly.
/ Run headless:  INK_SNAP=0 ink test/kkred.k

2: "lib/kk.k"

ok:: 0; nok:: 0
chkb: {[nm;b] $[b; ok::ok+1; nok::nok+1]; $[b; 0; `0 0: "FAIL ",nm,"\n"]}
/ relative tolerance for reordered float sums
rel:  {[a;b] $[b=0.; abs a; (abs a-b) % abs b]}
chkr: {[nm;g;c] chkb[nm; 1e-5 > rel[g;c]]}
chke: {[nm;g;c] chkb[nm; g ~ c]}      / exact

demo: {[]
  / exact integer sums (representable in f32) match bit-for-bit
  A: `f$ 1 + !1000
  dA: 9: A
  chke["sum 1..1000 exact";  kk.sum dA; +/A]
  chke["max 1..1000";        kk.max dA; |/A]
  chke["min 1..1000";        kk.min dA; &/A]

  / n exactly P (256) and just over — grid-stride boundary
  E: `f$ 1 + !256
  chke["sum n=256";  kk.sum[9: E]; +/E]
  F: `f$ 1 + !257
  chke["sum n=257";  kk.sum[9: F]; +/F]

  / n=1 (bracket form: `gpu.hold ,7.` would parse `,` as dyadic join)
  chke["sum n=1"; kk.sum gpu.hold[,7.]; 7.]

  / large float array — reordered sum within relative tolerance
  B: 0.001 * `f$ !100000
  chkr["sum n=1e5 float";  kk.sum[9: B]; +/B]

  / max/min over signed floats
  C: (`f$ !64) - 20.
  dC: 9: C
  chke["max signed"; kk.max dC; |/C]
  chke["min signed"; kk.min dC; &/C]

  / product of near-one factors (relative tolerance)
  P: 20 # 1.1
  chkr["prod 1.1^20"; kk.prod[9: P]; */P]

  / 2-D placement reduces over all elements (shape ignored for the fold)
  M: (8;8) # `f$ 1 + !64
  chke["sum of 8x8 grid"; kk.sum[9: M]; +/ ,/ M]

  / pipeline cache: second sum reuses the cached `sum` pipeline (no recompile)
  nkeys: # !kkCache
  junk: kk.sum dA
  chkb["reduce pipeline cached"; nkeys = # !kkCache]

  / subgroup fast path (§6) vs the two-dispatch fallback: identical exact results
  / (integer sums), and the default picks subgroup when gpu.caps sgArith is set.
  sgv: kk.sum dA
  kkRedForceFb:: 1
  fbv: kk.sum dA
  kkRedForceFb:: 0
  chke["subgroup reduce == fallback"; sgv; fbv]
  chke["subgroup reduce == CPU";      sgv; +/A]
  chkb["subgroup path used by default"; (kkGetCaps[])`sgArith]

  / prefix scan +\d (kk2 tier-2): inclusive running combine, chunked across P=256.
  chke["sum-scan 1..10 exact";   8: kk.sums[9: `f$ 1+!10];  +\ `f$ 1+!10]
  chke["sum-scan n=256";         8: kk.sums[9: E];          +\E]
  chke["sum-scan n=257 (2 blk)"; 8: kk.sums[9: F];          +\F]
  chke["sum-scan n=1000 exact";  8: kk.sums dA;                  +\A]
  chke["max-scan signed";        8: kk.maxs dC;                  |\C]
  chke["min-scan signed";        8: kk.mins dC;                  &\C]
  chke["sum-scan n=1";           8: kk.sums gpu.hold[,7.];       ,7.]
  chkr["sum-scan n=1e5 float";   *| 8: kk.sums[9: B];       *| +\B]

  / compaction &mask (kk2 tier-2): indices where a 0/1 mask is true.
  MK: `f$ 1 0 1 1 0 0 1 0 1
  chke["where small";        8: kk.where[9: MK];   `f$ & `i$ MK]
  M300: `f$ (!300) mod 2
  chke["where n=300 (2 blk)"; 8: kk.where[9: M300]; `f$ & `i$ M300]
  chke["where all-true";      gpu.fetch kk.where gpu.hold 40#1.; `f$ !40]
  chkb["where all-false → 0"; 0 = # gpu.fetch kk.where gpu.hold 40#0.]
  / value compaction x@&mask composes via the gather path
  VX: `f$ 10 20 30 40 50 60 70 80 90
  chke["x@&mask (gather∘where)"; gpu.fetch kk.compile[{x@y}; (gpu.hold VX; kk.where gpu.hold MK)]; VX @ & `i$ MK]

  / device-side converge (kk2 §6): the max-abs-diff reduce drives termination.
  / walk.k Jacobi on a 20×20 grid — kk.converge (tolerance) must reach the SAME
  / fixpoint as kk.loop (fixed count), and stop early (well under maxIter).
  N: 20; ch: N div 2
  (rr;cc): 1 + !2 # N-2
  I:: cc + N*rr
  WW:: ((-N),N,1,-1) +\: I
  fJ: {@[x;I;:;1.+.25*+/x@WW]}
  x0: gpu.hold[(N*N)#0.]
  ref: (gpu.fetch kk.loop[fJ; x0; 6000]) @ ch + N*ch
  cvd: kk.converge[fJ; x0; 1e-5; 12000]
  cv:  (gpu.fetch cvd) @ ch + N*ch
  chke["converge == fixed-count fixpoint"; cv; ref]
  chkb["converge stopped early (< maxIter)"; (CVlast 0) < 12000]

  / count-exactness past the f32 2^24 cliff: the reduce/scan uniform
  / ships counts as raw i32 bits (gpu.uniformI + shader bitcast), so a length that f32
  / cannot represent still folds every element. N=2^24+51 rounds under f32 (`i$`f$N≠N),
  / and a spike at the LAST index is only found if the count is exact. Both paths.
  BN: (2*8388608) + 51
  chkb["2^24+51 rounds under f32 (test is live)"; ~ BN = `i$ `f$ BN]
  bv: BN # 1.; bv[BN-1]: 9.
  bd: 9: bv
  chke["kk.max past 2^24 (subgroup)"; kk.max bd; 9.]
  kkRedForceFb:: 1
  chke["kk.max past 2^24 (fallback)"; kk.max bd; 9.]
  kkRedForceFb:: 0
  gpu.drop bd

  `0 0: "kkred: ",($ok)," ok, ",($nok)," fail\n"
  0}

gpu.computeRun[{[x] demo[]}]
