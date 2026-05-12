/ reverse — double reverse ||!N (round-trip)
/ O(N) time · O(N) space
/ Measures: two sequential memory copies (reversed).
/ Double reverse is a no-op logically but forces two full-array passes.
/ JIT: minimal gain — dominated by memcpy-like bandwidth.
/ GPU: parallel in-place reverse; two passes but fully parallel.
/ Throughput proxy: N*8 bytes read + N*8 bytes written per iteration.
/ reps: 10
N: `I$`argv[2]
\t:10 ||!N
