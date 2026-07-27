/ bench/tropical.k — size x arithmetic-intensity sweep for the tropical cost model.
/ doc/research/tropical.md, Experiment 1. GENERATED — the generator is in that doc.
/
/   usage: ink bench/tropical.k <N> <KI> <R>
/     N   elements (f32)
/     KI  kernel index 0..9:  0-4 = FMA chains  K = 1 2 4 8 16
/                             5-9 = sin chains  K = 1 2 4 8 16
/     R   dispatches recorded before the single readback
/
/ ONE elementwise kernel, ONE output buffer reused across all R dispatches: memory
/ stays fixed and R adds only work. Timing is the caller's job (bench/tropical.py),
/ differencing two R values so process start-up, device creation, the upload and the
/ readback all cancel.
/
/ Two families because the FMA chain cannot reach the roofline ridge on its own:
/ 8 bytes/element and <=27 ops (see the chain-length cliff in .plan/triage.md) caps
/ intensity at ~4 flop/byte, while machine balance is ~25. The sin chain buys ~an
/ order of magnitude more arithmetic per op, so the compute-bound regime is
/ reachable within the same op budget.
/
/ No parentheses in the FMA chains on purpose: `$lambda` does not round-trip a
/ parenthesised body out of a list, and kk.plan re-parses `$fn` (.plan/triage.md).
/ Right-to-left nesting gives the same expression without them.
2: "lib/kk.k"
N: `I$`argv[2]
KI: `I$`argv[3]
R: `I$`argv[4]
KS: 1 2 4 8 16 1 2 4 8 16
FAM: "fffffsssss"
TK0: {0.0001+1.0001*x}
TK1: {0.0001+1.0001*0.0001+1.0001*x}
TK2: {0.0001+1.0001*0.0001+1.0001*0.0001+1.0001*0.0001+1.0001*x}
TK3: {0.0001+1.0001*0.0001+1.0001*0.0001+1.0001*0.0001+1.0001*0.0001+1.0001*0.0001+1.0001*0.0001+1.0001*0.0001+1.0001*x}
TK4: {0.0001+1.0001*0.0001+1.0001*0.0001+1.0001*0.0001+1.0001*0.0001+1.0001*0.0001+1.0001*0.0001+1.0001*0.0001+1.0001*0.0001+1.0001*0.0001+1.0001*0.0001+1.0001*0.0001+1.0001*0.0001+1.0001*0.0001+1.0001*0.0001+1.0001*0.0001+1.0001*x}
TK5: {sin x}
TK6: {sin sin x}
TK7: {sin sin sin sin x}
TK8: {sin sin sin sin sin sin sin sin x}
TK9: {sin sin sin sin sin sin sin sin sin sin sin sin sin sin sin sin x}
F: $[KI=0; TK0; KI=1; TK1; KI=2; TK2; KI=3; TK3; KI=4; TK4; KI=5; TK5; KI=6; TK6; KI=7; TK7; KI=8; TK8; TK9]
SEED: $[(FAM KI)="s"; 1.; 1000.]      / sin chains want a bounded seed
gpu.computeRun[{[_]
  a: 9: `f$ N # SEED
  P::  (kk.plan[F; ,a])`pipe
  AG:: a`gpu
  OB:: gpu.buffer[(kkPad N)#0.]
  NN:: N
  {[i] gpu.dispatch[P; (AG;OB); NN]}' !R
  v: gpu.read OB
  `0 0: "n=",($N)," fam=",(,FAM KI)," k=",($KS KI)," r=",($R)," chk=",($*|v),"\n"
  0 }]
