/ Call-path microbenchmark: per-call overhead of the Call/Apply opcodes, the
/ argument marshalling buffer and partial allocation. ms per 1M calls.
/ Run in ReleaseFast: ./zig-out/bin/ink bench/call.k     (`\t:` needs a literal
/ count, so the reps are baked in rather than taken from argv).

f1:{x+1}
f2:{x+y}
f3:{[a;b;c]a+b+c}
f8:{[a;b;c;d;e;g;h]a+b+c+d+e+g+h}
r:{x{x+y}[y]}          / a fresh partial per iteration

`0:"monad   "; \t:1000000 f1 1
`0:"monad   "; \t:1000000 f1 1
`0:"dyad    "; \t:1000000 f2[1;2]
`0:"dyad    "; \t:1000000 f2[1;2]
`0:"triad   "; \t:1000000 f3[1;2;3]
`0:"triad   "; \t:1000000 f3[1;2;3]
`0:"heptad  "; \t:1000000 f8[1;2;3;4;5;6;7]
`0:"heptad  "; \t:1000000 f8[1;2;3;4;5;6;7]
`0:"partial "; \t:1000000 f3[1;2]
`0:"partial "; \t:1000000 f3[1;2]
`0:"nested  "; \t:1000000 r[1;2]
`0:"nested  "; \t:1000000 r[1;2]
