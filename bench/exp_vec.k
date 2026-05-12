/ exp_vec — element-wise exp over negative range
/ O(N) time · O(N) space
/ Input: 0.0-!N = [0, -1, -2, ..., -(N-1)] — bounded, decays to ~0.
/ exp(-k) is in (0, 1] for k>=0, so no overflow at any N.
/ More compute-heavy than sqrt: exp is ~3-5x costlier than sqrt on CPU.
/ JIT: reduces element-loop dispatch overhead.
/ GPU: each element independent — ideal SIMD / GPU workload.
/ Throughput proxy: N*8 bytes read + N*8 bytes written per iteration.
/ reps: 10
N: `I$`argv[2]
\t:10 exp 0.0-!N
