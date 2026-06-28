# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Ink is an array programming language interpreter/compiler similar to ngn/k and k9. It is polysemic — operators have different meanings based on argument count and type. The runtime is written in Zig 0.16; there is also a GPU compiler targeting SPIR-V written in k.

## Build & Test Commands

```bash
# Debug build
time zig build

# Release build (ReleaseFast)
make build        # or: time zig build -Doptimize=ReleaseFast

# Unit tests
make test         # or: time zig build test

# REPL / stdin evaluation
echo "1+2" | ./zig-out/bin/ink

# Run a script (add timeout to avoid infinite loops)
timeout 1s ./zig-out/bin/ink test/walk.k; [ $? -eq 124 ] && echo 'Script timed out!'

# Watch mode (dev)
watchexec -r -e k -- ./zig-out/bin/ink test/planes.k

# QA (tests + demos)
make qa

# Show line counts and binary sizes
make info
```

## Code Style

- 2-space indentation
- Zig 0.16 — do **not** run `zig fmt`
- No underscores in variable names
- Cast numerics with: `@as(f64, @floatFromInt(a))`
- Report bugs unrelated to the current task in `doc/bug.md`

## Architecture

```
src/
├── noun/          # Core value model
│   ├── value.zig  # V — the top-level value union (all Ink values)
│   ├── class.zig  # K — type enum (b i f s c B I F S C L m M …)
│   ├── array.zig  # N<T> — homogeneous array struct
│   ├── symbol.zig # Interned symbol pool
│   └── format.zig # Printing / TerseFormatter
├── parser/        # Lexer → Parser → AST
├── primitive/
│   ├── verb/      # ~60 verb implementations (calc.zig, logic.zig, …)
│   │              # verbs.zig = monadic/dyadic jump-table dispatcher
│   ├── adverb/    # ~15 adverb implementations; adverbs.zig = overview
│   ├── dispatch.zig  # Type-based dispatch
│   └── promote.zig   # Scalar/vector/list promotion
├── runtime/
│   ├── vm.zig        # Stack VM: [2048]V stack, [64] call frames, [256] globals
│   ├── compiler.zig  # AST → IR → OpCode bytecode (DCE, constant folding)
│   ├── tape.zig      # OpCode enum and Chunk (bytecode storage)
│   └── ir.zig        # Intermediate representation
├── ffi.zig        # FFI bridge to C shared libraries
├── repl.zig       # REPL
├── runner.zig     # Main entry point
└── test.zig       # Unit test harness (Tester struct, vm.eval())
lib/               # Native extensions (gpu, font, json, csv, md5)
test/              # Integration test scripts (.k files)
doc/               # spec.md, triage.md, changelog.md, future.md
```

**Execution pipeline:** source → Lexer → Parser → AST → Compiler (IR) → bytecode → VM

**Memory model:** reference counting with copy-on-write.

## Language Gotchas

- No `>=`/`<=` operators — `x<=y` parses as `x<(=y)`. Use `~(x>y)` and `~(x<y)`.
- `_` is always the Drop/WeedOut/Delete verb; never a name character.
- Evaluation is strictly right-to-left; no operator precedence.
- Newlines inside `(...)` inject null elements — keep list literals on one line.
- `,/()` returns a unit, not an empty list — use `$[#x;,/x;!0]` when folding possibly-empty lists.
- Lambdas do **not** close over parent scope. Use `/:` patterns instead of nested closures.
- Module system is incomplete: use `2:"file.k"` for file loading (not `\l`).

## Native Extensions (FFI)

Extensions are shared libraries loaded at runtime via `src/ffi.zig`. Available: `libgpu.dylib` (Metal/WebGPU rendering), `libfont.dylib`, `libjson.dylib`, `libcsv.dylib`, `libmd5.dylib`.

## Useful References

- `AGENT.md` — language tips, known gotchas, full operator reference
- `doc/spec.md` — language specification (WIP, most up-to-date)
- `doc/triage.md` — open correctness issues
