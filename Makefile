VERSION := 0.0.1

INK  := zig-out/bin/ink

.PHONY: test bench bench-sort bench-view bench-langs bench-report bench-micro bench-micro-gpu bench-micro-view bench-jit bench-jit-gpu bench-jit-view release

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

# JIT/GPU compiler comparison (Python, produces HTML chart).
bench-jit:
	python3 tool/bench_jit.py --no-gpu --open

bench-jit-gpu:
	python3 tool/bench_jit.py --open

# Reopen report without rebuilding or re-running
bench-jit-view:
	python3 tool/bench_jit.py --no-build --open

bench-sort:
	zig test src/verb/sort/bench.zig

bench: build
	python3 tool/bench.py --open

bench-view:
	python3 tool/bench.py --open --ink $(INK)

# Cross-language benchmarks: ink vs ngnk
# Runs test/bench/ink/*.k and test/bench/ngnk/*.k, writes bench/measure.csv
bench-langs: build
	python3 tool/bench_langs.py --ink $(INK) --ngnk $(NGNK)

# Open the benchmark chart (requires bench-langs to have been run first)
bench-report:
	$(INK) test/bench/report.k

info: build
	@echo "Total lines:" && find src -name '*.zig' | xargs wc -l | tail -n 1
	@echo "Binary size:" && du -h zig-out/bin/*

clean:
	rm -rf zig-out
