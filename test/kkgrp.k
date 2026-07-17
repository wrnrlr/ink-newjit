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

  `0 0: "kkgrp: ",($ok)," ok, ",($nok)," fail\n"}

gpu.computeRun[{[x] run[]}]
