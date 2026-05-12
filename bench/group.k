/ group — group-by = over N random draws from 100 keys
/ O(N) time · O(N + K) space  (K=100 keys)
/ Builds a dict mapping each key to its occurrence indices.
/ Random memory access pattern — cache-unfriendly for large N.
/ JIT: reduces per-element dispatch overhead.
/ GPU: hash-map grouping is hard to parallelize well; limited GPU gain.
/ Throughput proxy: N*4 bytes read per iteration.
/ reps: 5  (fewer reps: hash-map overhead grows with N)
N: `I$`argv[2]
\t:5 =N?!100
