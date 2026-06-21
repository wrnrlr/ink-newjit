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
- Report issues and bugs unrelated to the current task to `doc/triage.md`.
- See `doc/spec.md` for the most up-to-date specification (WIP).

# Ink Language Overview
Ink (sometimes called terse) is an array programming language based on k.

## Tips
- No `>=`/`<=` - use `~(a>b)` and `~(a<b)` respectively.
- `_` is always the Drop/WeedOut verb; underscores are never valid in variable names.
- Expressions evaluate right-to-left; no operator precedence rules.
- Newlines inside `(...)` inject null elements - keep list literals on one line.
- `,/()` returns a unit, not an empty list - use `$[#x;,/x;!0]` when folding possibly-empty lists.

# Language Reference
## Grammar
Nouns can be combined into expressions using verbs and adverbs.
Expressions are evaluated right-to-left. There are no special precedence rules for operators.

```k
Integers: -2 1 0 0N
Types: `i`f`s`c`m`I`F`S`C`M`L
List: (1;2.3;`c)
Lambda: {[a;b]@a+b}
Dict: [id:1;name:"Bob"]
Train: *|
Sum: +/
```


## Types `` ` `i`f`s`c`m`I`F`S`C`M`L ``
- Integer - numbers like `-2 0 1 0N`
  - null value `0N`
  - type symbol `` `i ``.
- Float - floating point numbers `0.1 2. -3.`
  - null value `0n`, positive/negative infinity `` 0w -0w ``
  - type symbol `` `f ``.
- Symbol - interned names, e.g. `` `id`Red100 ``, type symbol `` `s ``.
- Char - single u8 character; whitespace is interpreted as empty `" "`. E.g. `"H"`, type symbol `` `c ``.
- Integers - vector of integers
  - type symbol `` `I ``
- Floats - vector of floats
  - type symbol `` `F ``
- Symbols - array of symbols, type symbol `` `S ``.
- Chars - string of characters (`[]u8`), type symbol `` `C ``.
- List - heterogeneous list; empty list is `` ,() ``, type symbol `` `L ``.
- Table - e.g. `` [[]a:1 2] ``, type symbol `` `M ``.

Types are organized into classes:
- Atoms: Integer, Float, Symbol, Char
- Vectors: Integers, Floats, Symbols, Chars
- Mappings: Dict & Table

### Dict
Dict can be written with bracket syntax `[a:1;b:2]`.
The dict operator `!` pairs two equal-length arrays: `` `a`b!1 2 ``.
A dict has type symbol `` `m ``.

### Table `` `M ``
Table can be written with bracket syntax `[[]a:1 2;b:"ab"]`.
A table can be created from a dict: `` +`a`b!(1 2;"ab") ``.
Constructing a table from mismatching lengths results in a length error.

### Lambda
A lambda is a user-defined function with its own local scope.
Written between curly braces: `{ a+b*c }`.
Arguments are either implicit (`x`, `y`, `z`) or declared in a square-bracket header `[arg1;arg2]`.
A lambda can have up to 8 arguments. Type symbol `` `o ``.

### Partial `` `p ``
A partial is a variadic (operator or lambda) with some arguments already applied.

### Composition/Train `` `q ``
A composition is a sequence of variadics applied in succession.

### Error `` `! ``
### Blank `` ` ``
Blanks are used for empty assignment and defining partials.

## Variables
A variable is a name associated with a value, a name is an alphanumeric identifier starting with an alphabetic character. A name may contain dots to separate segments (e.g. `a.b`, `ab1.ed4`), but a dot is only part of the name when immediately followed by a letter — `a.1` and `a. b` keep the dot as the index/apply operator. Underscores are not permitted in a variable name (`_` is always the Drop verb).
A variable declared at the top level of a fileis a global variable and a variable declared inside a lambda is a local variable. 
Assignmet of globals and locals at the top level happens with the singe colon `:`,
while assigment of globals in a lambda happen with a double colon `::`

### Monadic Operators `:+-*!#@&|<>=?,^~$.`
- Identity `:x` - return right-hand side
- Flip `+x` - transpose. `` +(1 2 3;4 5 6) `` → `` (1 4;2 5;3 6) ``
- Pivot `+d` - table to dict-of-lists and vice versa. `` +[[]n:`b`c;i:2 3] `` → `` [n:`b`c;i:2 3] ``
- Negate `-x` - numeric negation
- First `*x` - first item
- Iota `!i` - integers 0..i-1
- Odometer `!I` - Cartesian product indices for an integer list
- Tally `#x` - number of elements
- Type `@x` - type symbol (e.g. `` `i ``, `` `F ``)
- Where `&I` - convert counts to repeated indices
- Reverse `|x` - elements in reverse order
- Ascend `<X` - indices that sort X ascending
- Descend `>X` - indices that sort X descending
- Group `=X` - for each distinct value, the indices where it occurs
- Unit `=i` - identity matrix
- Distinct `?X` - distinct elements in order
- Uniform `?i` - i random floats in [0,1)
- Enlist `,x` - wrap x in a list
- Null `^x` - boolean mask of null/missing elements
- Not `~x` - logical negation
- String `$x` - string representation
- Value/Get `.x` - extract dictionary values; retrieve global by symbol name
- `sqrt n`, `sqr n`, `log n`, `exp n`, `sin n`, `cos n`, `abs n`

### Dyadic Operators
- Right `x:y` - return right-hand side
- Add `x+y`
- Sub `x-y`
- Mul `x*y`
- Div `x%y` - divFloor for integers, float division for floats
- Modulo `x mod y` - remainder of x÷y (integer)
- Integer division `x div y` - floor(x÷y)
- Key `x!y` - dictionary creation
- Equal `x=y` - elementwise equality
- Match `x~y` - identity check (same type and value)
- Drop `i_Y` - drop i items from start (positive) or end (negative)
- Drop keys `X_d` - remove keys X from dictionary d
- Cut `I_Y` - slice Y at indices I
- WeedOut `f_Y` - remove elements where boolean mask f is 1
- Delete `X_i` - remove element at index i from list X
- Join `x,y` - join atoms/lists; merge dictionaries (right-side wins)
- Take `x#y` - resize/cycle y to length |x|
- TakeKeys `X#d` - filter dictionary d to keys X
- Reshape `I#y` - reshape y to shape I
  - A `0N` value 
- Fill `x^y` - replace nulls in y with x
- Without `X^y` - remove occurrences of X from y
- Pad `i$C` - pad string to length |i|
- Cast `s$y` - cast y to type s. `` `I$"-12" `` → `-12`; `` `F$"-12.3" `` → `-12.3`
- Find `x?y` - first index of y in x (null if not found)
- Roll/Deal `i?x` - i random selections from x
- `x@y` (At/Apply) - index into x at y; apply function x to y
- `x.y` (Dot/ApplyN) - deep indexing or multi-argument application

### IO Verbs
The IO system is organized around file descriptors (filename, port number, etc.).
- Open File `` <"file.txt" `` or `` <"/path/to/file.txt" ``
- Open Connection `` <":port" `` or `` <"host:port" ``
- Close handle `` >s ``
- Read line `` 0: x `` - read lines from stdin
- Write line `` x 0: y `` - write text. `` `0 0:"Hi" ``
- Read bytes `` 1: x ``
- Write bytes `` x 1: y ``
- Load code `` 2: y `` used for importing other files

### Special Forms
- Amend3 `` @[x;y;f] `` - `` @["ABC";1;_:] `` → `"AbC"`
- Amend4 `` @[x;y;F;z] `` - `` @["abc";1;:;"x"] `` → `"axc"`
- Drill3 `` .[x;y;f] `` - `` .[("AB";"CD");1 0;_:] `` → `("AB";"cD")`
- Drill4 `` .[x;y;F;z] `` - `` .[("ab";"cd");1 0;:;"x"] `` → `("ab";"xd")`
- Splice `` ?[C;I;C] `` - `` ?["abcd";1 3;"xyz"] -> "axyzd" ``

## Adverbs
An adverb is one of the glyphs: `` ' / \ ': /: \: `` when it is used as a modifier 
of how the verb on the right-hand side is applied to the verb on the left hand argument.
The verb can be a operator, partial or lambda.
- Each `f'` - apply f to each item. `` #'("abc";3 4 5 6) `` → `3 4`
- Zip `x F'` - elementwise dyad. `` 2 3#'"ab" `` → `("aa";"bbb")`
- Fold `F/` - left fold. `+/1 2 3` → `6`
- Scan `F\` - running fold. `+\1 2 3` → `1 3 6`
- Seeded fold `x F/` - fold with seed. `10+/1 2 3` → `16`
- Seeded scan `x F\` - running fold with seed. `10+\1 2 3` → `11 13 16`
- N-do `i f/` - apply f i times. `` 5(2*)/1 `` → `32`
- N-dos `i f\` - all intermediate results. `` 5(2*)\1 `` → `1 2 4 8 16 32`
- While `f f/` - apply until condition fails. `(1<){:[2!x;1+3*x;-2!x]}/3` → `1`
- Whiles `f f\` - all states while condition holds
- Converge `f/` - iterate until stable. `` {1+1.0%x}/1 `` → `1.618...`
- Converges `f\` - successive results until convergence
- Join `C/` - join list with separator. `"ra"/("ab";"cadab";"")` → `"abracadabra"`
- Split `C\` - split by separator. `"ra"\"abracadabra"` → `("ab";"cadab";"")`
- Decode `I/` - mixed-base to number. `24 60 60/1 2 3` → `3723`
- Encode `I\` - number to mixed-base. `24 60 60\3723` → `1 2 3`
- Window `i'` - sliding windows. `3':"abcdef"` → `("abc";"bcd";"cde";"def")`
- Stencil `i f'` - apply f to each window. `` 3{x,"."}'"abcde" ``
- Eachprior `F':` - apply F between each item and its predecessor. `-':12 13 11 17 14` → `12 1 -2 6 -3`
- Eachprior seeded `x F':` - like eachprior with seed. `10-':12 13 11 17 14` → `2 1 -2 6 -3`
- Eachright `x F/:` - fixed right arg to each left item. `1 2*/:3 4` → `(3 6;4 8)`
- Eachleft `x F\:` - fixed left arg to each right item. `1 2*\:3 4` → `(3 4;6 8)`

Adverbs are polysemic and have a different behaviour based on operand types.
Monadic and dyadic verbs influence how a adverb is interpreted.
For example the `\` can be either a fold with a dyadic verb `F` or a converge with a monadic verb `f`.
- `'`: Each, Zip
- `/`: Fold, Decode, Join, N-do, While, Converge
- `\`: Scan, Encode, Split, N-dos, Whiles, Converges
- `':`: Eachprior, Window, Stencil
- `/:`: Eachright
- `\:`: Eachleft

## Special Symbols
- Arguments `` `argv[] `` - list of cmd-line args (also in global `x`)
- Environment variables `` `env[] `` - dict of env variables
- Random number `` `prng[] ``
- Exit `` `exit@i ``

## Native Extension
Ink supports writing native extensions based on a FFI.

## Commands
A command always starts at the beginning of a line with `\`.

### Time Command `\t:n expr`
Time elapsed in milliseconds after n runs (n is optional).

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
  - `triage.md` - open correctness issues
  - `spec.md` - language specification (WIP)
  - `changelog.md` - change log
  - `future.md` - planned features
- `lib` - language extensions
  - `csv`
  - `font`
  - `json`
  - `gpu`
    - `fill.wgsl`
    - `gpu.k` Load RunWindow, FillFrame from `libgpu.dylib`
    - `gpu.zig`
    - `main.zig` 
    - `render.zig`
    - `spirv.k` - FragmentShader, VertexShader
    - `triangulate.zig`
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
  - `eyes.k` Eyes that follow the mouse drawn using 2D raster API FillFrame & Tessellate
  - `planes.k` 

# Optimizations
- Static allocated array for `!N` with N<256.
- Ref counting, copy-on-write.
- Dead code ellimination
- Constant folding

## Common Idioms
- First n even numbers: `` {2*!x} ``
- Capitalize first letter of each word: `` {s:~" "=x;@[x;&s>0,-1_s;`c$-32+]}"hi an" ``
- Flatten list `` ,/(1 0 0; 0 1 0) `` -> `1 0 0 0 1 0`.
- No `<=`/`>=` operators `x <= y` parses as `x < (= y)`, use `~(x > y)` and `~(x < y)`.
- Reshape array into 2 columns and infer size of rows `0N 2#x`
- Connect to server `` h: > "127.0.0.1:5001" ``
- Write text to stdout `` `0 0: "hello" ``

## Useful Commands
- Build debug: `time zig build`
- Build release: `time zig build -Doptimize=ReleaseFast`
- Unit tests: `time zig build test`
- REPL test: `` echo "1+2" | ./zig-out/bin/ink ``
- Walk example: `./zig-out/bin/ink test/walk.k`
- Eyes example: `./zig-out/bin/ink test/eyes.k`
- Artifact sizes: `du -h zig-out/*/*`

# Open Problems

## Auto-loading
Public identifiers defined in `lib/*.k` are auto-loaded on first use — no manual `2:` import needed. A definition is public when it either starts with an uppercase letter (e.g. `ReadCsv`) or is a dotted name namespaced under the file's stem (e.g. `regex.match` in `regex.k`). For example, just write `ReadCsv "data.csv"` and the CSV library loads automatically.

The loader (`src/modules.zig`) scans `lib/*.k` at startup, indexes all public definitions (uppercase `[A-Z][A-Za-z0-9]*:` and dotted `<stem>.…:`), and calls `vm.load` for the relevant file the first time a matching identifier appears in source.

Available auto-loaded libraries:
- `lib/csv.k` — `ReadCsv`
- `lib/gpu.k` — `RunWindow`, `FillFrame`, `Tessellate`, `CompileSpirV`, `DrawShader`, `RunShader`, `CompileWgsl`, `CompileMesh`, `DrawMesh`
- `lib/spirv.k` — `FragmentShader`, `VertexShader`
- `lib/font.k` — font functions
- `lib/json.k` — JSON functions

## Module system is incomplete
`\l file.k` loads a file but namespace access from ngn/k doesn't work: `\d mod`, `mod.A`, `.mod`, etc. Current code uses `2:"code.k"` for file loading. A proper module system requires names to support dots.

## Language gotchas
- **Underscores in names:** `_` is always Drop/WeedOut. `foo_bar` parses as `foo _ bar`. Use camelCase.
- **Newlines in list literals:** a newline inside `(a;b;\n c)` injects a null element. Keep list literals on one line.
- **Fold over empty list:** `,/()` returns a unit value, not an empty list. Use `$[#x;,/x;!0]`.
- **Multi-char operator symbols:** `` `<= `` is the symbol `<=` (lexer greedily consumes op chars). Operator-char and alnum modes don't mix: `` `<abc `` is symbol `` `< `` then identifier `abc`.
- **`list in symlist`:** returns a boolean list (element-wise), not a scalar - always truthy. Use `~` for scalar match or check a specific element.
- **`$[cond; a; [stmt;stmt;…]]` hangs the parser:** a bracketed multi-statement block used as a `$[…]` branch makes the whole-file parse loop forever (no output, times out — the file is fully parsed before any statement runs, so nothing prints). Keep `$[]` branches as single expressions; move multi-statement work into a helper function.
- **`each` over a bare name errors:** `f ' xs` (named function, space, `'`) can return an error (`` `! ``). Wrap it: `{f x}' xs`. Related: `'` binds to the term on its left, so `f g' x` is `(f g)' x`, never `f (g' x)` — inline lambdas/verbs absorb the adverb. Pre-compute the each into a variable, or parenthesize.
- **`verb ,/expr` misparses:** e.g. `Tessellate ,/{…}'cs` binds the `,/` to the verb on its left and yields the wrong result/length. Parenthesize the argument: `Tessellate (,/{…}'cs)`.
- **Mixed int/float join does NOT promote to `F`:** `0,1,200.` → general list `(0;1;200.0)`, not `0. 1. 200.`. FFI marshalling (e.g. `kfp`) then rejects it as not-a-float-vector. Coerce each item: `(0.+a),(0.+b),c`.
- **`` dict`key `` before an operator misparses:** `` f`h,g `` is read as `f` indexed by the symbol-list `` `h,g `` , not `` (f`h),g ``. Safe only as a standalone term; otherwise parenthesize `` (f`h) ``. (This plus the int/float-join item above were why `FontOutline` silently returned an error for every glyph until fixed in `lib/font.k`.)

## GPU drawing gotchas (`lib/gpu.k`)
- **Adverbs don't run draw side effects:** a `FillFrame[…]` issued from inside an each/over (`'` `/`) draws nothing — adverb results are treated as pure and the draw is eliminated. The same call works fine as an explicit statement. Use adverbs only to *compute* vertices (Tessellate/FontOutline via `'` return correct values), build all triangles into one `F` buffer with `,/{…}'idx`, then issue ONE explicit `FillFrame[buffer; col]` per color layer (also faster than per-shape draws).
- **`Tessellate` resolves glyph counters via NaN separators:** pack multiple contours into one flat array separated by a NaN x/y pair (`,/{x,0n,0n}'cs`) and `Tessellate` subtracts holes (the counters in `0 8 @ a b e …`). A single contour with no NaN behaves exactly as before. See `test/typeset.k` for the full ASCII-glyph example.
