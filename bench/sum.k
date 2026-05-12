/ sum — fold sum +/ over float range
/ O(N) time · O(N) space (intermediate float array)
/ Measures: allocation + float cast + sequential fold reduction.
/ JIT: eliminates interpreter dispatch per fold step → noticeable speedup.
/ GPU: parallel reduction tree O(log N) depth → large speedup at N>=100k.
/ Throughput proxy: N*8 bytes read (float) per iteration.
/ reps: 10
N: `I$`argv[2]
\t:10 +/0.0+!N
