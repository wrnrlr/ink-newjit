
echo "ngn/k fused (a+b ; a+b*c ; (a+b)*(a-b)+c)"
~/.k/k bench/fused.k 100000
~/.k/k bench/fused.k 1000000

echo "ink fused (a+b ; a+b*c ; (a+b)*(a-b)+c)  -- FusedMap target"
./zig-out/bin/ink bench/fused.k 100000
./zig-out/bin/ink bench/fused.k 1000000

echo "ngn/k temp"
~/.k/k bench/temp.k

echo "ink temp"
./zig-out/bin/ink bench/temp.k

echo "ngn/k dot"
~/.k/k bench/dot.k 10000
~/.k/k bench/dot.k 100000
~/.k/k bench/dot.k 1000000

echo "ink dot"
./zig-out/bin/ink bench/dot.k 10000
./zig-out/bin/ink bench/dot.k 100000
./zig-out/bin/ink bench/dot.k 1000000

echo "ngn/k iota"
~/.k/k bench/iota.k 10000
~/.k/k bench/iota.k 100000
~/.k/k bench/iota.k 1000000

echo "ink iota"
./zig-out/bin/ink bench/iota.k 100000
./zig-out/bin/ink bench/iota.k 1000000

echo "ngn/k last"
~/.k/k bench/last.k 100000
~/.k/k bench/last.k 1000000

echo "ink last"
./zig-out/bin/ink bench/last.k 100000
./zig-out/bin/ink bench/last.k 1000000

echo "ngn/k avg"
~/.k/k bench/avg.k 10000
~/.k/k bench/avg.k 100000
~/.k/k bench/avg.k 1000000

echo "ink avg"
./zig-out/bin/ink bench/avg.k 10000
./zig-out/bin/ink bench/avg.k 100000
./zig-out/bin/ink bench/avg.k 1000000

echo "ngn/k fibonacci"
~/.k/k bench/fibonacci.k 100
~/.k/k bench/fibonacci.k 1000
~/.k/k bench/fibonacci.k 10000
~/.k/k bench/fibonacci.k 20000

echo "ink fibonacci"
./zig-out/bin/ink bench/fibonacci.k 100
./zig-out/bin/ink bench/fibonacci.k 1000
./zig-out/bin/ink bench/fibonacci.k 10000
./zig-out/bin/ink bench/fibonacci.k 20000

echo "ngn/k simulate"
~/.k/k bench/simulate_ngn.k

echo "ink simulate"
./zig-out/bin/ink bench/simulate_ink.k

echo "ngn/k powerset"
~/.k/k bench/powerset.k 10
~/.k/k bench/powerset.k 15

echo "ink powerset"
./zig-out/bin/ink bench/powerset.k 10
./zig-out/bin/ink bench/powerset.k 15

echo "ink group family (ms/20 reps of 1M: +/d  =d  #'=d  <d  ?d  =L)"
echo "  100 distinct (dense-bucket path)"
./zig-out/bin/ink bench/group.k 1000000 100
echo "  100k distinct (dense-bucket path)"
./zig-out/bin/ink bench/group.k 1000000 100000
echo "  10M distinct (hash path)"
./zig-out/bin/ink bench/group.k 1000000 10000000
