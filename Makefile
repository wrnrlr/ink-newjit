VERSION := 0.0.1

INK  := zig-out/bin/ink

.PHONY: test build release

test:
	time zig build test

build:
	time zig build -Doptimize=ReleaseFast

release:
	time zig build -Doptimize=ReleaseFast
	@echo "Total lines:" && find src -name '*.zig' | xargs wc -l | tail -n 1
	@echo "Binary size:" && du -h zig-out/*/*
	# find src \( -path 'src/graphics' -o -path 'src/encoding' \) -prune -o -name '*.zig' -print | xargs wc -l

info:
	@echo "Total lines:" && find src -name '*.zig' | xargs wc -l | tail -n 1
	@echo "Binary size:" && du -h zig-out/bin/*

clean:
	rm -rf zig-out
