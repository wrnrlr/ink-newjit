/ regression bench: *|x must compile to last via the optimizer peephole.
/ Without the peephole this is O(n); with it, O(1).
N: `I$`argv[2]
n: !N
\t:1000 *|n
