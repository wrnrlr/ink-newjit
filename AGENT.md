# Agent Instructions
- Implementation of the Ink array programming language similar to ngn/k and k9.
- Ink is a polysemic language; operators have different meanings based on argument count and type.
- It has a runtime written in Zig for interpreting k code on the CPU.
- It has a compiler targetting SPIRV for written in k for the GPU.
- A transpiler 
- Commands can get stuck in a loop, run with a timeout: `timeout 1s ./zig-out/bin/ink; [ $? -eq 124 ] && echo 'Script timed out!'`.
- Use 2 spaces for code indentation.
- Use zig version 0.16.
- Don't use `zig fmt` on code.
- Cast ints and floats in Zig like this: `@as(f64, @floatFromInt(a))`.
- Add debug statements to verify your thinking.
- Report issues and bugs unrelated to the current task to `.plan/triage.md`.
- See `doc/spec.md` for the most up-to-date specification (WIP).

# Ink Language Overview
Ink (sometimes called terse) is an array programming language based on k.

## Tips
- **Two-tier numerics.** Tier 1 = canonical `bool→i32→f32` (un-suffixed literals, implicit promotion, as in classic k). Tier 2 = explicit-precision types, each *isolated* (combines only with itself; cross-tier arithmetic is `!type`): `u` = u32 natural (`3u`, `@`→`` `u ``/`` `U ``), `d` = f64 (`2.3d`, `` `d ``/`` `D ``), `h` = f16 (`2.3h`, `` `h ``/`` `H ``). Type symbols are one letter (lowercase atom / uppercase vector), same as the suffix and the cast target: `` `d$x ``, `` `f$2.5d ``, `` `u$5 ``. Suffix `e`/`E` stays exponent (so no bf16 `12.3e`; use dedicated letters). bf16/fp8 not yet implemented (needs a `VEC_BIT` re-layout — only slots 14/15 were free, taken by d/h).
- No `>=`/`<=` - use `~(a>b)` and `~(a<b)` respectively.
- `_` is always the Drop/WeedOut verb; underscores are never valid in variable names.
- Expressions evaluate right-to-left; no operator precedence rules.
- Newlines inside `(...)` inject null elements - keep list literals on one line.
- `,/()` returns a unit, not an empty list - use `$[#x;,/x;!0]` when folding possibly-empty lists.

# Ink Tutorial
Ink is an array programming language with k 

```k
ints: -2 1 0 0N
particle:`px`py`vx`vy / array of symbols for position and velocity
types: `i`f`s`c`m`I`F`S`C`M`L / symbols 
list: (0b;1;2.3;`c)
dict: [id:1;name:"Bob"]
f: {x+y} / lambda with inplicit arguments
g: {[a;b]#a,b} / lambda with explicit arguments
train: *|
sum: +/;
inc: 1+ / partial
p1:particle!1. 2. 0. 0.2
```

# About Ink
Ink is an array programming language for high-performance computing, based on ngn/k and k9.
The parser, compiler, and runtime are all written in Zig 0.16.

# Project Overview
- `bench` - benchmarks for ink and ngn/k
  - `alloc.k`
  - `simulate.k` - Monte Carlo simulation of random walks
- `doc`
  - `bivector`
  - `papers`
  - `ten-minute-physics`
  - `spec.md` - language specification (WIP)
  - `changelog.md` - change log
  - `future.md` - planned features
- `lib` - language extensions
  - `color`
  - `csv`
  - `font`
  - `json`
  - `gpu`
  - `md5`
- `src` - core language components
  - `noun/` - basic building blocks
    - `array.zig` - array struct `N`
    - `class.zig` - class enum `K` with fields: `b i f s c B I F S C L m M`
    - `value.zig` - value struct `V`
    - `symbol.zig` - symbols interned in `Pool`
  - `parser/`
    - `ast.zig`, `lexer.zig`, `parser.zig`
  - `primitive/`
    - `adverb/` - ~15 adverb implementations; `adverbs.zig` is the overview
    - `verb/` - ~60 verb implementations
      - `calc.zig` - arithmetic `+ - * %`, numeric functions
      - `logic.zig` - `< > = ~`
      - `helper.zig` - comptime kernel helpers
      - `verbs.zig` - monadic/dyadic jump table
    - `amend.zig` - amend and drill
    - `dispatch.zig` - type-based dispatch
    - `derived.zig` - adverb-derived values
    - `promote.zig` - scalar/vector/list promotion
  - `runtime/`
    - `call.zig`, `command.zig`, `compiler.zig`, `disarm.zig`
    - `fntable.zig`, `ir.zig`
    - `tape.zig` - OpCode enum, BasicBlock, Chunk
    - `vm.zig`
  - `ffi.zig` bridges ink K values to C shared-library functions
  - `runner.zig`
  - `test.zig` 
- `test/` - test scripts and data
  - `circle.k` Example of fragment shader with simple SDF for circle
  - `eyes.k` Eyes that follow the mouse, drawn with the analytic Canvas/Slug API (lib/canvas.k)
  - `planes.k` 

# Optimizations
- Static allocated array for `!N` with N<256.
- Ref counting, copy-on-write.
- Dead code ellimination
- Constant folding

## Common Idioms
- First n even numbers: `` {2*!x} ``
- Capitalize first letter of each word: `` {s:~" "=x;@[x;&s>0,-1_s;`c$-32+]}"hi an" ``
- Raze - flatten list `` ,/(1 0 0; 0 1 0) `` -> `1 0 0 0 1 0`.
- No `<=`/`>=` operators `x <= y` parses as `x < (= y)`, use `~(x > y)` and `~(x < y)`.
- Reshape array into 2 columns and infer size of rows `0N 2#x`
- Connect to server `` h:<"127.0.0.1:5001" ``
- Write text to stdout `` `0:"hello" ``
- Tokenize `` {?x@<x} ``

## Home Directory
The ink home directory is by default `~/.ink`. The `$INK_HOME` variable can overwrite the default.
This directory contains the ink executable for all platforms, shared libraries and k files:
- `ink` symlink to system executable
- `bin/ink-<target>`
- `lib/`
- `share/<target>/`


## Useful Commands
- Build debug: `time zig build`
- Build release: `time zig build -Doptimize=ReleaseFast`
- Unit tests: `time zig build test`
- REPL test: `` echo "1+2" | ./zig-out/bin/ink ``
- Walk example: `./zig-out/bin/ink test/walk.k`
- Eyes example: `./zig-out/bin/ink demo/eyes.k`
- Artifact sizes: `du -h zig-out/*/*`
- Download Huggingface Model `` hf download nvidia/parakeet-tdt-0.6b-v2 --local-dir ./data/parakeet-tdt-0.6b-v2 ``

## Ink Library


# Open Problems

## Auto-loading
Public identifiers defined in `lib/*.k` are auto-loaded on first use — no manual `2:` import needed.
The loader (`src/modules.zig`) scans `lib/*.k` at startup, indexes all public definitions, and calls `vm.load` for the relevant file the first time a matching identifier appears in source.

Available auto-loaded libraries:
- `lib/csv.k` — `csv.read`
- `lib/parquet.k` — `ReadParquet`
- `lib/safetensors.k` — `safetensors.read`
- `lib/gpu.k` — namespaced GPU API (Phase 4): `window.run`; `gpu.fill`, `gpu.tessellate`,
  `gpu.compileSpirv`, `gpu.drawShader`, `gpu.runShader`, `gpu.buffer`, `gpu.read`,
  `gpu.write`, `gpu.dispatch`, `gpu.compileCompute`, `gpu.solid`, `gpu.kernel`;
  `mesh.compilePull`/`drawPull`/`drawPullT` (the one mesh API — vertex pulling);
  `texture.upload`
- `lib/dye.k` — shader compiler (loads `lib/spirv.k` encoder): `shader.fragment`/`Tex`/
  `TexN`, `shader.vertexPull`, `shader.compute`/`compute2`, `shader.stencil`/`U`/`IP`,
  `shader.scatter`. Every path compiles through the neutral IR. See `doc/design/dye.md`.
- `lib/bits.k` — the CPU backend for the neutral IR: `bits.run[fn;nAcc;nBuf;bufs;count]`
  interprets a kernel lambda on the CPU (cross-backend oracle, `test/kkbits.k`).
- `lib/font.k` — font functions
- `lib/json.k` — JSON functions
- `lib/audio.k` — audio (native miniaudio ext, `zig build audio`). Playback is fire-and-forget on miniaudio's own thread; recording is polled. `audio.play`/`load`/`stream`/`music`, `start`/`stop`/`volume`/`pitch`/`loop`/`seek`, 3D `pos`/`vel`/`dir`/`spatial`/`range`/`listener`, `decode`/`save`; `audio.rec.start`/`read`/`stop` (drain the mic ring buffer from your loop).


## Language gotchas
- **No underscores in names:** `_` is always Drop/WeedOut. `foo_bar` parses as `foo _ bar`. Use camelCase.
- **Keyword-verb param names are rejected:** a lambda parameter named after one of the four keyword verbs (`in has mod div`) now raises `!parse_error: UnexpectedToken` (the lexer always reads them as verbs). The removed math/monadic names (`count first last sqrt parse …`) are prelude identifiers and are fine as params — only those 4 are rejected. Use `cnt`, `src`, `elem`, ….
- **`x,()` is identity; `(),x` still boxes:** appending the empty list on the *right* preserves the operand's type (`` `a`b,() `` → `` `S ``, `1,()` → `,1` int-vec), so dict keys / env merges built with `(k,())!(v,())` index correctly. The *left*-empty form `(),x` still boxes into a general list (`` `L ``) — an intentional idiom the GPU shader compiler relies on; use `!0` (empty `` `I ``) as an empty numeric seed, not `()`.
- **Newlines in list literals:** a newline inside `(a;b;\n c)` injects a null element. Keep list literals on one line.
- **Fold over empty list:** `,/()` returns a unit value, not an empty list. Use `$[#x;,/x;!0]`.
- **Operator-glyph symbols are quoted:** a backtick symbol joins only alphanumerics and dots, never operator glyphs. `` `~ `` is the null symbol `` ` `` then the Match verb (a projection); `` `~` `` is Match of two null symbols (`1b`); `` `<abc `` is null-symbol `` ` `` then `<` then `abc`. To name a symbol after an operator, quote it: `` `"+" ``, `` `"<=" ``, `` `"," ``.
- **`-` juxtaposition:** a `-` glued to a following number is a negative literal when it has a space before it (or starts a phrase), else it is dyadic subtract. So `abs -4` applies `abs` to `-4`, but `abs-4` subtracts; `1 -2 3` is a 3-vector, `1-2` is `-1`. Matches ngn/k (`cos -3` works, `cos-3` errors).
- **`list in symlist`:** returns a boolean list (element-wise), not a scalar - always truthy. Use `~` for scalar match or check a specific element.
- **`$[cond; a; [stmt;stmt;…]]` hangs the parser:** a bracketed multi-statement block used as a `$[…]` branch makes the whole-file parse loop forever (no output, times out — the file is fully parsed before any statement runs, so nothing prints). Keep `$[]` branches as single expressions; move multi-statement work into a helper function.
- **`each` over a bare name errors:** `f ' xs` (named function, space, `'`) can return an error (`` `! ``). Wrap it: `{f x}' xs`. Related: `'` binds to the term on its left, so `f g' x` is `(f g)' x`, never `f (g' x)` — inline lambdas/verbs absorb the adverb. Pre-compute the each into a variable, or parenthesize.
- **Micro-benchmarks get dead-code eliminated:** `z: {[i] f x}' !n` with `z` unused is removed by the compiler, so a timing loop around `gpu.dispatch`/`LinearR` reports sub-microsecond "per-call" times for work that never ran (and a following `gpu.read` returns the un-updated buffer — check that the result actually changed). Assigning to a variable is NOT enough; the variable must be *used*. For GPU timing, prefer measuring the real pipeline with pieces stubbed out over a synthetic repeat-loop.
- **A SPACED `\` is the scan adverb, never split:** `sep \ str` means "scan", so `"\n" \ 1: path` silently returns the whole file as a ONE-element list instead of its lines — a wrong answer, not an error. Glue it: `"\n"\s` (and `NL\s` for a named separator) split correctly. This is what made `nnLoadVocab` return a 1-entry vocab and every ASR transcript come out empty.
- **`verb ,/expr` misparses:** e.g. `Tessellate ,/{…}'cs` binds the `,/` to the verb on its left and yields the wrong result/length. Parenthesize the argument: `Tessellate (,/{…}'cs)`.
- **Mixed int/float join does NOT promote to `F`:** `0,1,200.` → general list `(0;1;200.0)`, not `0. 1. 200.`. FFI marshalling (e.g. `kfp`) then rejects it as not-a-float-vector. Coerce each item: `(0.+a),(0.+b),c`.
- **`` dict`key `` before an operator misparses:** `` f`h,g `` is read as `f` indexed by the symbol-list `` `h,g `` , not `` (f`h),g ``. Safe only as a standalone term; otherwise parenthesize `` (f`h) ``. (This plus the int/float-join item above were why `FontOutline` silently returned an error for every glyph until fixed in `lib/font.k`.)

## GPU drawing gotchas (`lib/gpu.k`)
- **Adverbs don't run draw side effects:** a `FillFrame[…]` issued from inside an each/over (`'` `/`) draws nothing — adverb results are treated as pure and the draw is eliminated. The same call works fine as an explicit statement. Use adverbs only to *compute* vertices (Tessellate/FontOutline via `'` return correct values), build all triangles into one `F` buffer with `,/{…}'idx`, then issue ONE explicit `FillFrame[buffer; col]` per color layer (also faster than per-shape draws).
- **`Tessellate` resolves glyph counters via NaN separators:** pack multiple contours into one flat array separated by a NaN x/y pair (`,/{x,0n,0n}'cs`) and `Tessellate` subtracts holes (the counters in `0 8 @ a b e …`). A single contour with no NaN behaves exactly as before. See `demo/typeset.k` for the full ASCII-glyph example.
