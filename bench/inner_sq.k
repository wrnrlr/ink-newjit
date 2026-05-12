/ inner_sq — sum of squares +/x*x  (inner product with self)
/ O(N) time · O(N) space (temporary for x*x)
/ 2N FLOPs: N multiplications + N additions in the fold.
/ Classic BLAS-1 dot-product pattern: multiply then reduce.
/ JIT: eliminates dispatch in both the multiply loop and the fold.
/ GPU: parallel multiply-accumulate → one of the best GPU workloads.
/ Throughput proxy: N*16 bytes (read x twice) + N*8 bytes written per iter.
/ reps: 10
N: `I$`argv[2]
\t:10 x:0.0+!N;+/x*x
