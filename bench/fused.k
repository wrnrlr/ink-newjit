/ Elementwise verb chains — the FusedMap target.
/ Today each binary verb allocates a full-length temporary (helper.zig kernelVec2),
/ so these chains stream N f32s to DRAM once per operator. A chunked/fused executor
/ should keep intermediates in registers and cut memory traffic by ~chain length.
/ See doc/research/columnar-execution.md.
/ usage: ink bench/fused.k <N>
N: `I$`argv[2]
a: `f$!N
b: 1+`f$!N
c: 2+`f$!N

/ 1 op (baseline: one temp)
\t:1000 a+b
/ 2 ops (one intermediate temp today)
\t:1000 a+b*c
/ 4 ops (three intermediate temps today) — biggest fusion win
\t:1000 (a+b)*(a-b)+c
