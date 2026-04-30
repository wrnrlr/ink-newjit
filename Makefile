VERSION := 0.0.1

.PHONY: parser play terse foliant build clean test ast vm ide ink runner bench bench-sort bench-view

TS := -I src -I src/tree_sitter --library c --library tree-sitter src/parser.c src/scanner.c

parser:
	timeout 5s tree-sitter generate src/grammar/ink/grammar.js
	timeout 5s tree-sitter test
	time tree-sitter build

play:
	tree-sitter generate src/grammar/ink/grammar.js
	# tree-sitter test --overview-only
	tree-sitter build --wasm
	tree-sitter playground

value:
	time zig test src/value.zig

ast:
	time zig test src/ast.zig $(TS)

fmt:
	time zig test src/format.zig $(TS)

test:
	time zig build test

vm:
	timeout 10s time zig test src/vm.zig $(TS)

demo:
	timeout 10s time zig test src/demo.zig $(TS)

build:
	time zig build

bench-sort:
	zig test src/verb/sort/bench.zig --library c

bench: build
	python3 tool/bench.py --open

bench-view:
	python3 tool/bench.py --open --ink zig-out/bin/ink

ide:
	time zig build ide

clean:
	rm -rf zig-out
	rm -f parser.dylib
	rm -f src/parser.c src/parser.h
	rm -f tree-sitter-terse.wasm
	rm -f grammar.js
