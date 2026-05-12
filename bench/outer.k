/ outer — outer product x *\: x  (NxN matrix from vector of size M=isqrt(N))
/ O(N) time · O(N) space  (M*M = N output floats)
/ M = floor(sqrt(N)) so the output is always ~N elements regardless of N,
/ making this directly comparable to other O(N) benchmarks.
/ Unlike flat-array ops, the result is a list of M float vectors — each row
/ is a separate heap allocation.  Tests both compute AND allocator throughput
/ for M allocations of size M.
/ x *\: x  =  for each xi in x: xi * x  →  list of M length-M vectors.
/ JIT: each row multiply benefits from reduced dispatch overhead.
/ GPU: all rows are independent — embarrassingly parallel.
/ Throughput proxy: M*M*8 bytes written = N*8 bytes per iteration.
/ reps: 5  (fewer reps: M separate allocations per iter have higher overhead)
N: `I$`argv[2]
M: `I$sqrt 0.0+N
x: 0.0+!M
\t:5 x *\: x
