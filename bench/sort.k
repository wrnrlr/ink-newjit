/ sort — grade-up of reversed range <|!N (worst-case input)
/ O(N log N) time · O(N) space
/ <x returns the permutation that would sort x ascending.
/ |!N is the descending sequence — worst case for ascending sort.
/ JIT: reduces comparison-loop dispatch overhead.
/ GPU: radix sort or bitonic sort can achieve O(N log^2 N / P).
/ Throughput proxy: N*4 bytes read + N*4 bytes written per iteration.
/ reps: 5  (fewer reps: O(N log N) cost grows faster than O(N))
N: `I$`argv[2]
\t:5 <|!N
