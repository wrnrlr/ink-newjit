/ test/kkgrp.k — oracle for kk.freq (tier-2 histogram, kk2 §5 / kk.md §2).
/ kk.freq[d; nb] counts integer indices into nb buckets on the GPU (one scatter-add
/ dispatch) and must match the CPU freq peephole @[nb#0; d; +; 1] (== #'=d grouped).
/ Checks both input forms: a host index vector and a placement produced on-device.
/ Run headless:  INK_SNAP=0 ink test/kkgrp.k     (needs the gpu ext)

2: "lib/kk.k"

ok:: 0; nok:: 0
chk: {[nm; b] $[b; ok:: ok + 1; nok:: nok + 1]; $[b; 0; `0 0: "FAIL ",nm,"\n"]}

/ CPU histogram reference: counts[b] = number of indices equal to b.
cpuFreq: {[idx; nb] `f$ @[nb#0; idx; +; (#idx)#1]}

/ CPU group reference + the order-independent checks (helpers are top-level: the
/ inner set-builders and chk/cpuFreq are globals — no closure over run's locals).
grpChk: {[nb; idx]
  n: #idx
  gr: kk.group[idx; nb]
  perm: `i$ 8: gr
  goff: `i$ nb # 8: gr`off
  gcnt: `i$ nb # 8: gr`cnt
  cnt:  `i$ cpuFreq[idx; nb]
  coff: 0 , +\ -1 _ cnt                        / exclusive offsets = 0, running Σ of all-but-last
  dp:   idx @ perm
  gsets: {[b] p: perm @ (goff b) + ! gcnt b; p @ < p}' ! nb
  csets: {[b] & idx = b}' ! nb
  chk["group nb=",($nb)," counts match";        gcnt ~ cnt]
  chk["group nb=",($nb)," offsets match";        goff ~ coff]
  chk["group nb=",($nb)," perm is permutation";  (perm @ < perm) ~ ! n]
  chk["group nb=",($nb)," d@perm bucketed";      dp ~ dp @ < dp]
  chk["group nb=",($nb)," per-bucket sets";      gsets ~ csets]}

run: {[]
  / 1. skewed indices, 8 buckets (duplicates accumulate) — host-vector input
  nb1: 8; I1: (13 * !40) mod nb1
  g1: nb1 # 8: kk.freq[I1; nb1]
  chk["freq host-vector matches CPU @[;;+;1]"; g1 ~ cpuFreq[I1; nb1]]
  chk["freq total = #indices"; (`i$ +/ g1) = #I1]

  / 2. dense small range, every bucket hit
  nb2: 4; I2: (!12) mod nb2
  chk["freq dense range"; (nb2 # 8: kk.freq[I2; nb2]) ~ cpuFreq[I2; nb2]]

  / 3. placement input (indices already on-device) gives the same counts
  nb3: 5; I3: (7 * !30) mod nb3
  dP: gpu.hold `f$ I3
  chk["freq from a placement == from a host vector"; (nb3 # 8: kk.freq[dP; nb3]) ~ cpuFreq[I3; nb3]]

  / 4. an empty bucket (index range < nb) stays zero
  nb4: 6; I4: (!20) mod 4
  chk["freq leaves unhit buckets 0"; (nb4 # 8: kk.freq[I4; nb4]) ~ cpuFreq[I4; nb4]]

  / 5. kk.group — CSR bucketing via per-bucket atomic cursors. Intra-bucket order
  / is nondeterministic (atomics race), so the oracle is order-INDEPENDENT: counts
  / and offsets match CPU, perm is a valid permutation of !n, d@perm is bucketed
  / (non-decreasing), and each bucket's index SET equals the CPU grouping.
  grpChk[5;   (13 * !20) mod 5]              / skewed, every bucket hit
  grpChk[4;   (!12) mod 4]                   / dense, equal buckets
  grpChk[6;   (!20) mod 4]                   / empty tail buckets (4,5 stay empty)
  grpChk[8;   (7 * !50) mod 8]               / larger, uneven

  `0 0: "kkgrp: ",($ok)," ok, ",($nok)," fail\n"}

gpu.computeRun[{[x] run[]}]
