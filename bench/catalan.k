N: `I$`argv[2]
Fact: {*/1+!x} / Factorial: product of 1 to x
Comb: {(Fact x)%(Fact[y]*Fact[x-y])}
Catalan: {(Comb[2*x;x])%1+x}

\t:100 Catalan N
