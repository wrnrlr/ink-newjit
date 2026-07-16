/ test/kkred.k — whole-buffer reduce (kk2 §6, tier-2 gateway) vs CPU.
/ Places arrays with gpu.hold, runs kk.sum/max/min/prod (two-stage shader.reduce),
/ and checks against the CPU fold. Float sum reorders (grid-stride), so sum is
/ checked to a relative tolerance; max/min/prod-of-ints match exactly.
/ Run headless:  INK_SNAP=0 ink test/kkred.k

2: "lib/dye.k"
2: "lib/gpu.k"

ok:: 0; nok:: 0
chkb: {[nm;b] $[b; ok::ok+1; nok::nok+1]; $[b; 0; `0 0: "FAIL ",nm,"\n"]}
/ relative tolerance for reordered float sums
rel:  {[a;b] $[b=0.; abs a; (abs a-b) % abs b]}
chkr: {[nm;g;c] chkb[nm; 1e-5 > rel[g;c]]}
chke: {[nm;g;c] chkb[nm; g ~ c]}      / exact

demo: {[]
  / exact integer sums (representable in f32) match bit-for-bit
  A: `f$ 1 + !1000
  dA: gpu.hold A
  chke["sum 1..1000 exact";  kk.sum dA; +/A]
  chke["max 1..1000";        kk.max dA; |/A]
  chke["min 1..1000";        kk.min dA; &/A]

  / n exactly P (256) and just over — grid-stride boundary
  E: `f$ 1 + !256
  chke["sum n=256";  kk.sum gpu.hold E; +/E]
  F: `f$ 1 + !257
  chke["sum n=257";  kk.sum gpu.hold F; +/F]

  / n=1 (bracket form: `gpu.hold ,7.` would parse `,` as dyadic join)
  chke["sum n=1"; kk.sum gpu.hold[,7.]; 7.]

  / large float array — reordered sum within relative tolerance
  B: 0.001 * `f$ !100000
  chkr["sum n=1e5 float";  kk.sum gpu.hold B; +/B]

  / max/min over signed floats
  C: (`f$ !64) - 20.
  dC: gpu.hold C
  chke["max signed"; kk.max dC; |/C]
  chke["min signed"; kk.min dC; &/C]

  / product of near-one factors (relative tolerance)
  P: 20 # 1.1
  chkr["prod 1.1^20"; kk.prod gpu.hold P; */P]

  / 2-D placement reduces over all elements (shape ignored for the fold)
  M: (8;8) # `f$ 1 + !64
  chke["sum of 8x8 grid"; kk.sum gpu.hold M; +/ ,/ M]

  / pipeline cache: second sum reuses the cached `sum` pipeline (no recompile)
  nkeys: # !kkCache
  junk: kk.sum dA
  chkb["reduce pipeline cached"; nkeys = # !kkCache]

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

  `0 0: "kkred: ",($ok)," ok, ",($nok)," fail\n"
  0}

gpu.computeRun[{[x] demo[]}]
