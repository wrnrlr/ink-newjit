
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
