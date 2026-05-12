/ max — fold max |/ over integer range
/ O(N) time · O(1) space output (scalar result, O(N) input)
/ Measures: sequential fold reduction with integer comparisons.
/ JIT: eliminates fold dispatch overhead → measurable speedup.
/ GPU: parallel max-reduction tree, same asymptotic as sum.
/ Throughput proxy: N*4 bytes read (int) per iteration.
/ reps: 10
N: `I$`argv[2]
\t:10 |/!N
