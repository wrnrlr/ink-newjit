/ sqrt_vec — element-wise square root
/ O(N) time · O(N) space
/ Applies sqrt to each element of a float range.
/ Each sqrt call is an independent transcendental operation.
/ JIT: eliminates element-loop dispatch overhead.
/ GPU: each element computed in parallel — near-ideal GPU workload.
/ Throughput proxy: N*8 bytes read + N*8 bytes written per iteration.
/ reps: 10
N: `I$`argv[2]
\t:10 sqrt 0.0+!N
