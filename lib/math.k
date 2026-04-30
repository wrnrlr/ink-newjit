Pitagoras: {sqrt (x*x)+y*y}
Fib: {x{x,+/ -2#x}/0 1}          / Iterative: generates x Fibonacci numbers
FibN: {*(x-1){x,+/ -2#x}/0 1}    / Returns specifically the Nth Fib number
Factorial: {*/1+!x}                   / Factorial: product of 1 to x
Comb: {(Fact x)%(Fact[y]*Fact[x-y])} / Combination: nCr
Catalan: {(Comb[2*x;x])%1+x}     / Nth Catalan number
/ Generates triples using Euclid's formula for y > x
Pyth: {((sqr x)-(sqr y); 2*x*y; (sqr x)+(sqr y))}  

Greycode: { +! (#x) #2 }
Lexicograph: *| +@/ 1<:\ (|1#:\)'
Powerset: { Lexicograph x@ &'Greycode x }

RunLength: {
  start: & x> 0, -1_x
  end: & x> 1_ x,0
  start+ !' 1+ end-start
}

SimpleTokenizer: { x@ RunLength[~" "=x] }

MortonCode: { ,/r+/:2*r:4/2\!x }

PerilNoise1D: {x}
SimplexNoise: {x}
TurbulentNoise: {x}

R1: `+
Cl: `+-
R2: `++
R1: `+-0
R3: `+++
G2: `++0
G3: `+++0

/ Apter Tree's
ApterTree: [p: 0N 0 1 0 3; n: 15 12 9 18 2]

5 = Pitagoras[3; 4] / Returns 1 (true)
Catalan'!10         / Returns first 10 Catalan numbers: 1 1 2 5 14 42 132 429 1430 4862
