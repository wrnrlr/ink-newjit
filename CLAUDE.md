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
- No underscores in k variable names.
- Cast numerics with: `@as(f64, @floatFromInt(a))`
- Report bugs unrelated to the current task in `.plan/triage.md`

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
│   ├── vm.zig        # Stack VM: [2048]V stack, [64] call frames, [4096] globals
│   ├── compiler.zig  # AST → IR → OpCode bytecode (DCE, constant folding)
│   ├── tape.zig      # OpCode enum and Chunk (bytecode storage)
│   └── ir.zig        # Intermediate representation
├── ffi.zig        # FFI bridge to C shared libraries
├── cmd/
│   ├── runner.zig # Main entry point (argv, tools, script/stdin evaluation)
│   ├── repl.zig   # Statement streaming for scripts + the Jupyter kernel's cell eval
│   └── …          # bundle, jupyter, modules, parse, disasm, help
└── test.zig       # Unit test harness (Tester struct, vm.eval())
lib/               # Native extensions (gpu, font, json, csv, md5)
tools/             # k tools run by `ink <tool>` — repl.k (the interactive loop), lsp.k, doc.k, klint.k
test/              # Integration test scripts (.k files)
doc/               # changelog.md
```

**Execution pipeline:** source → Lexer → Parser → AST → Compiler (IR) → bytecode → VM

**Memory model:** reference counting with copy-on-write.

## Documenting a k module

`lib/*.k` is self-documenting: `lib/doc.k` extracts an API reference from the parse
CST, `ink tools/doc.k` writes it to `doc/api/`, and `tools/lsp.k` serves the same text
as editor hover.

**Module header** — a **block comment holding markdown**: a line that is exactly `/`
opens it, a line that is exactly `\` closes it (both alone in column 0). The first
heading names the module, the line under it is a one-sentence summary that has to read
on its own (it becomes the index row), and the last line says how to load it.

```k
/
# audio

Play, stream, record and decode audio, with 3D positioning.

```k
audio.play "boop.wav"
```

Build the extension first with `zig build audio`; …
\
```

**Per-binding docs** stay `/` line comments. A top-level binding is **public** when it
starts its own line (indentation is fine) *and* a comment block sits directly above it
with no blank line between; an aligned trailing comment counts too. Anything else — no
comment, a blank line in between, a binding after other code on the same line, or a
name a `\d ns a b` export list hides — is private and never listed. A `/ ── section ──`
banner separates code rather than documenting the next binding.

```bash
make docs-api      # regenerate doc/api.md + doc/api/*.md
make docs-check    # which modules still have no documented API
```

## Language Gotchas

- No `>=`/`<=` operators — `x<=y` parses as `x<(=y)`. Use `~(x>y)` and `~(x<y)`.
- `_` is always the Drop/WeedOut/Delete verb; never a name character.
- Evaluation is strictly right-to-left; no operator precedence.
- Newlines separate items inside `(...)` `[...]` `$[...]` just like `;`, but never inject a null — items can be written one-per-line, with or without a trailing `;`, and blank lines are ignored. Only `;;` and a trailing `;` inject a null element (the intended way to elide). (This was fixed in "Fix bracket and newline syntax"; a multi-line `$[...]` no longer hangs either.)
- **Round brackets build values, square brackets sequence statements.** `(a:1;b:2)` is a dict, `([]a:1 2;b:3 4)` a table, `([k:1 2]v:3 4)` a keyed table, `()!()` the empty dict (there is no empty-dict literal). A `(` commits to a dict as soon as its first item reads `key:` and not `key::`; every remaining item must then be `key:value`, so `(a:1;2)` and `(1;a:2)` are both parse errors and an assignment may not be a top-level item of `(…)`. `[a;b;c]` is a **progn**: every statement runs, the last one's value is the block's — that is where assignments and multi-statement `$[]` branches go. `[` directly after a noun is still apply/index.
- **Null is the identity verb `::`; there is no blank type.** As in ngn/k, `::` is an ordinary `.o` value — `@::` is `` `o ``, `` $:: `` is `"::"`, `#::` is `1`, and the null test is `` x~:: ``. It is falsy, it is what bindings / side-effecting verbs / unset globals / dict misses evaluate to, and **the REPL prints nothing for it**. An elided list item or call argument *is* `::` (`(1;;2)` prints `(1;::;2)`), and in bracket position it marks a projection gap (`f[::;2]` ≡ `f[;2]`) — so you cannot pass null through brackets, though juxtaposition (`@a`) still applies. `noun ::` stays the global-bind digram: `a::1` and `a,::x` are assignments, but with nothing after it (`a~::`, `1,::`) the `::` is the null literal.
- **`:x` in statement position returns from the enclosing lambda** (`{$[x<0;:0;x*2]}`, `{[a] [t:a*2; :t+1]}`, `{:}` returns null). In value position — a call argument or list element — `:` keeps its verb reading, so `@[v;`px;:;99.]` is unchanged. At top level, with no frame to unwind, `:x` is plain identity.
- `,/()` returns a unit, not an empty list — use `$[#x;,/x;!0]` when folding possibly-empty lists.
- Lambdas do **not** close over parent scope. Use `/:` patterns instead of nested closures.
- Namespaces: `\d ns` opens namespace `ns` (all members public); `\d ns a b` makes only `a`,`b` public (rest private, reachable only within `ns`); bare `\d` resets to global. Resolution is compile-time — names mangle to `ns.member` global keys (zero runtime cost). A bare name inside `ns` resolves to `ns.name` if that member exists, else the global.
- Only **four keyword verbs remain**: `in has mod div` (all genuinely dyadic). Everything else that used to be a keyword — the math functions (`sqrt sqr exp log sin cos abs`) and the monadic verbs (`first last count parse exec depth epoch`) — was removed from the grammar and rebound as **names in `lib/prelude.k`** (loaded at VM init). Consequences: (1) a bare op-glyph directly after one is **dyadic** unless it is a `-` glued to a numeric literal with a space before it: `abs -4` now applies `abs` to `-4` (a negative literal, like ngn/k), but `abs-4` is subtract and `parse $x` is still dyadic — write `parse[$x]` (and `abs[-x]` when the operand isn't a literal); (2) these names no longer need qualified LHS in a namespace (`parse: …` is fine now); (3) any monadic primitive is callable as a symbol (`` `first x ``, `` `parse x `` → its Op1 kernel via syms.zig). `first`/`last`/`count` are bound to the glyph verbs (`*`/`*|`/`#`); `parse`/`exec`/`depth`/`epoch` to their Op1 kernels. See `doc/design/dye.md`.
- Module loading: `2:"lib/foo.k"` loads by path; `2:"foo"` / `\l foo` (extension-less) resolve to `lib/foo.k`. A public `ns.member` / dotted name auto-loads its file on first reference (both the full name and its `ns` prefix are indexed). Bare global names are file-private by default — a module publishes an unqualified API with the `\e a b c` export directive (runtime no-op, read by the module indexer). Unset globals read as `0` rather than erroring, so a mistyped or un-renamed name fails silently.
- Build ink in release build `make release` when benchmarking code otherwise the debug symbols will slow things down.

## Native Extensions (FFI)

Extensions are shared libraries loaded at runtime via `src/ffi.zig`. Available: `libgpu.dylib` (raw Vulkan via MoltenVK; dye.k SPIR-V 1.4 straight to `vkCreateShaderModule`), `libfont.dylib`, `libjson.dylib`, `libcsv.dylib`, `libmd5.dylib`.

## Useful References

- `AGENT.md` — language tips, known gotchas, full operator reference
- `doc/reference.md` — language specification (WIP, most up-to-date)
- `doc/api.md` + `doc/api/*.md` — **generated** library API reference (`make docs-api`); edit the k source, not these
- `doc/api-legacy.md` — the old hand-written library notes, being migrated into module headers
- `doc/design/nn.md` — neural-net stack (lib/nn.k, conformer.k, feat.k, asr.k): naming rules, the params-buffer perf trap, negative results, roadmap
- `doc/design/ui.md` — UI library design docs
- `doc/design/kk2.md` — UI library design docs
- `doc/design/canvas-slug.md` — canvas and slug library design docs
- `.plan/triage.md` — open correctness issues
- `.plan/tasks.md` — future work 
- `.plan/ideas.md` — Open questions and research ideas

- `tools/zed-ink/` — Zed IDE extension (submodule); pins the grammars by commit in `extension.toml`. After bumping a pin run `sh tools/zed-ink/build-grammars.sh` — Zed refetches the grammar clone on reload but does **not** recompile it, and a missing `grammars/<name>.wasm` kills ink highlighting outright. Never delete `grammars/` without rerunning it. See that repo's README.
- `tools/tree-sitter-ink/` — tree-sitter grammar + reference queries (submodule); `tools/zed-ink/languages/ink/highlights.scm` mirrors `queries/highlights.scm`
- `tools/tree-sitter-ink-repl/` — grammar for REPL transcripts (submodule)
