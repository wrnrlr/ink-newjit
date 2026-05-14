VERSION := 0.0.1

INK  := zig-out/bin/ink

.PHONY: test bench-micro bench-micro-gpu bench-micro-view bench-sort release

test:
	time zig build test

build:
	time zig build -Dui=true

release:
	time zig build -Doptimize=ReleaseFast -Djit=true -Dui=true
	@echo "Total lines:" && find src -name '*.zig' | xargs wc -l | tail -n 1
	@echo "Binary size:" && du -h zig-out/bin/*

# Micro-benchmarks comparing baseline vs JIT vs GPU.
# Builds three ink binaries, runs bench/*.k at 4 sizes, writes bench/report.csv.
bench-micro:
	bash bench/run.sh --no-gpu

bench-micro-gpu:
	bash bench/run.sh

bench-micro-view:
	bash bench/run.sh --no-build --no-gpu

bench-sort:
	zig test src/verb/sort/bench.zig

info:
	@echo "Total lines:" && find src -name '*.zig' | xargs wc -l | tail -n 1
	@echo "Binary size:" && du -h zig-out/bin/*

clean:
	rm -rf zig-out
