/ test/kkopt.k — oracle for xOpt (compute/vertex fold + multi-root DCE, kk2 §3).
/ Compiles kernels with xOpt off (0) and on (1) and asserts the optimizer is BOTH
/ effective (folds consts, culls dead loads) AND safe (never drops a store / atomic
/ scatter / loop phi, and leaves a fully-live kernel byte-identical). Numeric parity
/ of the optimized modules is covered on real GPUs by test/nn.k; this runs headless.
/   ink test/kkopt.k

2: "lib/dye.k"

ok:: 0; nok:: 0
chk: {[nm;b] $[b; ok::ok+1; nok::nok+1]; $[b; 0; `0 0: "FAIL ",nm,"\n"]}
cnt: {[w;op] +/ w=op}                 / how many words equal opword op
ATOMIC:: 458986; STORE:: 196670; PHI:: 458997

/ Compile fn twice: (words with xOpt=0; words with xOpt=1).
both: {[fn;na;nb] xOpt::0; a: gpu.kernel[fn;na;nb]; xOpt::1; b: gpu.kernel[fn;na;nb]; xOpt::0; (a;b)}

/ 1. Dead-load DCE: sdt:g[1] is bound but never used → xOpt=1 drops that one
/    buffer load (f2s + access-chain + load), so the module is strictly shorter,
/    while BOTH atomic scatters survive (effects are DCE roots).
deadK: {[dp;p;e;g;ee]
  sc:1048576.
  ne:`i$g[0]; sdt:g[1]; ok:$[ee<ne;1.;0.]     / sdt is dead
  base:7*ee
  pi:e[base]; pj:e[base+1]; l0:e[base+2]
  bi:3.*pi; bj:3.*pj
  dx:(p[bj])-p[bi]
  cx:ok*sc*dx*l0
  a0:scatterAdd[dp;bi;cx]; scatterAdd[dp;bj;0.-cx]}
/ 2. Const-fold: 0.5*0.5 → 0.25 (both operands const) shrinks the body and the
/    store is preserved.
foldK: {[o;x;g;d] set[o; d; (x[d]) * 0.5 * 0.5]}

/ 3. Loop survives DCE: a reduction kernel's phi nodes (loop counter + accumulator)
/    must be preserved, and its store kept.
redK: {[o;x;g;d] n:`i$g[0]; set[o; d; +/{[k] x[(d*n)+k]}'!n]}

/ 4. Fully-live kernel: nothing to fold or cull → xOpt=1 is byte-identical to
/    xOpt=0 (the optimizer is conservative, never gratuitously reorders ids).
liveK: {[o;x;y;g;d] set[o; d; (x[d]) + (g[0])*y[d]]}

/ All checks inside one lambda so intermediate chk results aren't echoed (only the
/ final `0 0: write is the top-level value — the kkgold/ck convention).
run: {[]
  dr: both[deadK;1;3]
  chk["dead-load DCE shrinks module"; (#dr 1) < (#dr 0)]
  chk["both atomic scatters survive DCE"; (cnt[dr 1;ATOMIC]) = cnt[dr 0;ATOMIC]]
  chk["dead kernel keeps 2 atomics"; 2 = cnt[dr 1;ATOMIC]]
  fr: both[foldK;0;3]
  chk["const-fold shrinks module"; (#fr 1) < (#fr 0)]
  chk["folded kernel keeps its store"; (cnt[fr 1;STORE]) = cnt[fr 0;STORE]]
  rr: both[redK;0;3]
  chk["reduction phi count preserved"; (cnt[rr 1;PHI]) = cnt[rr 0;PHI]]
  chk["reduction has 2 phis (counter+acc)"; 2 = cnt[rr 1;PHI]]
  chk["reduction keeps its store"; (cnt[rr 1;STORE]) = cnt[rr 0;STORE]]
  lr: both[liveK;0;4]
  chk["fully-live kernel byte-identical under xOpt"; (lr 0)~lr 1]
  `0 0: "kkopt: ",($ok)," ok, ",($nok)," fail\n"}
run[]
