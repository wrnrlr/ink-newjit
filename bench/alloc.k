/ alloc — allocate integer range !N
/ O(N) time · O(N) space
/ Baseline: measures raw allocation throughput.
/ JIT: minimal gain (allocator is a runtime builtin, not JIT-compiled).
/ GPU: N/A — integer allocation stays on CPU.
/ Throughput proxy: N*4 bytes written per iteration.
/ reps: 10
N: `I$`argv[2]
\t:10 !N
