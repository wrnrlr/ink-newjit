/ scan — prefix sum +\ (running fold)
/ O(N) time · O(N) space
/ Measures: sequential prefix accumulation over float array.
/ Each output element depends on all previous — sequential dependency chain.
/ JIT: eliminates dispatch overhead in the sequential scan loop.
/ GPU: parallel prefix-scan algorithm O(N/P + log P) with P processors.
/ Throughput proxy: N*8 bytes read + N*8 bytes written per iteration.
/ reps: 10
N: `I$`argv[2]
\t:10 +\0.0+!N
