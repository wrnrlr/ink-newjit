/ each_sq — lambda applied element-wise {x*x}'
/ O(N) time · O(N) space
/ Key JIT benchmark: without JIT the interpreter is invoked once per element.
/ At N=1000000 without JIT: ~1 interpreter dispatch per element = potentially
/ 10-100x slower than the equivalent primitive x*x.
/ JIT compiles the lambda body to native ARM64 → closes the gap with primitives.
/ GPU: each element independent → embarrassingly parallel.
/ Throughput proxy: N*8 bytes read + N*8 bytes written per iteration.
/ reps: 1  (1 rep: without JIT this can be very slow at large N)
N: `I$`argv[2]
\t:1 {x*x}'0.0+!N
