/ dot — dot product of two distinct float vectors  +/x*y
/ O(N) time · O(N) space (temporary for x*y before fold)
/ 2N FLOPs: N multiplications + N-1 additions.
/ x and y are pre-allocated once outside the timing loop so we measure
/ only the multiply-then-fold compute, not allocation.
/ Compare inner_sq.k which includes allocation inside the loop.
/ JIT: eliminates dispatch in both the element-wise multiply and the fold.
/ GPU: parallel multiply-accumulate — classic BLAS-1 dot-product kernel.
/ Throughput proxy: N*16 bytes read (x + y) per iteration.
/ reps: 10
N: `I$`argv[2]
x: 0.0+!N
y: |x
\t:10 +/x*y
