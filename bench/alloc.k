arr: !100
f0: {x*x}                  / 0 temps (return value only, scratch can't help)
f1: {a: x+1; x*a}        / 1 temp per call
f2: {a: x+1; b: x*2; a+b} / 2 temps per call
f3: {x+x}

n: 1000000
\t n f0\ arr
\t n f1\ arr
\t n f2\ arr
\t n f3\ arr
