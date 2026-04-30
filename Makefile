VERSION := 0.0.1

.PHONY: test vm ink bench bench-sort bench-view

test:
	time zig build test

vm:
	timeout 10s time zig test src/vm.zig

build:
	time zig build

bench-sort:
	zig test src/verb/sort/bench.zig

bench: build
	python3 tool/bench.py --open

bench-view:
	python3 tool/bench.py --open --ink zig-out/bin/ink

ide:
	time zig build ide

clean:
	rm -rf zig-out
