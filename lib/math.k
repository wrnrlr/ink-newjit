Pitagoras: sqrt +/sqr
Fib: {x{x,+/ -2#x}/0 1}          / Iterative: generates x Fibonacci numbers
FibN: {*(x-1){x,+/ -2#x}/0 1}    / Returns specifically the Nth Fib number
Fact: {*/1+!x}                   / Factorial: product of 1 to x
Comb: {(Fact x)%(Fact[y]*Fact[x-y])} / Combination: nCr
Catalan: {(Comb[2*x;x])%1+x}     / Nth Catalan number


Greycode: { +! (#x) #2 }
Lexicograph: *| +@/ 1<:\ (|1#:\)'
Powerset: { Lexicograph x@ &'Greycode x }

RunLength: {
  start: & x>  0b,-1_x
  end:   & x> 1_x,0b
  start+ !' 1+ end-start
}

SimpleTokenizer: { x@ RunLength[~" "=x] }


MortonCode: { ,/r+/:2*r:4/2\!x }

PerilNoise1D: {x}
SimplexNoise: {x}
TurbulentNoise: {x}

/ Apter Tree's
ApterTree: [p: 0N 0 1 0 3; n: 15 12 9 18 2]
