VERSION := 0.0.1

INK  := zig-out/bin/ink
NGNK := $(HOME)/.k/k

.PHONY: test bench bench-sort bench-view bench-langs bench-report release

test:
	time zig build test

build:
	time zig build -Dui=true

release:
	time zig build -Doptimize=ReleaseFast -Djit=true -Dui=true

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
	@echo "Total lines:" && \
	find src -name '*.zig' | xargs wc -l | tail -n 1
	@echo "Binary size:" && \
	du -h zig-out/bin/*

clean:
	rm -rf zig-out
