# Agent Instructions
- Implementation of the Ink array programming language similar to ngn/k and k9.
- Ink is a polysemic language, its operators have a different meaning based on the number of arguments and the type of those arguments.
- Commands can get stuck in a loop, run with a timeout: `timeout 1s ./zig-out/bin/ink; [ $? -eq 124 ] && echo 'Script timed out!'`.
- Use 2 spaces for code indentation.
- Use zig version 0.16
- Don't use `zig fmt` on code.
- Cast ints and floats in Zig like this: `@as(f64, @floatFromInt(a))`.
- Add debug statements to verify your thinking.
- Report issues and bugs with the ink language or runtime, and that are not stricktly related to the current task to `report.md`
- See `doc/spec.md` for most up to date specification (WIP)

# Ink language Overview
Ink (sometimes called terse) is an array programming language based on k.

## Tips
- No `>=`/`<=` — use `~(a<b)`

## Nouns

### Symbol `` `Abc ``
### Integer `` 1 2 -3 0N ``
### Float `` 1.2 -3 0n 0w -0w ``
### Character `` "H" ``
### String `` "Hello" ``
### List `` (1;2.3;`c) ``
### Dict `` [id:1;name:,"Bob"] ``
### Table `` [[]id:] ``
### Lambda `` {[a;b;c]a+b*c} ``
### Scalars: [`` `i ``](), [`` `f ``](), [`` `s ``](), [`` `c ``]()
### Vectors: [`` `I ``](), [`` `F ``](), [`` `S ``](), [`` `C ``]()

### IO verbs `` < > 0: 1: ``
- Open
- Close
- ReadLines
- WriteLines
- ReadBytes
- WriteBytes

### Graphics Operations `` 9: ``


## Operators

Symbol operators like + * are ambivalent, meaning they have different meaning in the dyadic and monadic form, keyword operator are always either monadic or dyadic.

Operators can be polysemic, based on the types of the LHS and RHS is will behave differently.

The type canbe a real value class/type, or a pseudo/generic type;
- `x`, `y`: any type, scalar or vector
- `X`, `Y`: any list/vector type
- `i` integer, `I` integers
- `s` symbol, `S` Symbol 
- `m` dict, `M` table
- `N` numeric, ints or floats, chars
- `y` is monadic and `Y` is dyadic.

### Amend `@[x;y;f]` & `@[x;y;F;z]`
### Drill `.[x;y;f]` & `.[x;y;F;z]`
### Splice `?[x;y;f]`
### Conditional `$[b;t;f]`

### Adverbs `' / \ ': /: \:`
An adverb is any of these 3 symbols `' / \`, with an optional `:`.
Some adverbs like encode and decode behave like normals verbs.
Adverbs are polysemic just like verbs. 
- `'`: [Each1](), [Each2]()
- `/` : [Fold](), [NDo](), [While](), [Converge](), [Dencode]()
- `\` : [Scan](), [NDos](), [Whiles](), [Converges](), [Ecode]()
- `':`: [EachPrior](), [Window](), [Stencil]()
- `/:`: [EachRight](),
- `\:` [EachLeft]()

# About the Ink array programming language
Ink is a array programming language for high performance computing.
It is based on the k array programming languages ngn/k and k9.
The language parser, compiler and runtime are all written in Zig 0.16.
The underscore glyph `_` is a verb in k — `north_r` parses as `north` `_` `r` (drop), not an identifier. Avoid underscores in names.


# Project Overview
- `bench` benchmarks for ink and ngn/k
  - `alloc.k`
  - `simulate.k` monte carlo simulation of random walks
- `doc`
  - `bug.md` Known bugs, add new issues unrelated to the current task here
  - `spec.md` Ink language specification (WIP)
  - `changelog.md` Changelog, document changes here
  - `future.md` Planning of future features
- `lib` language extensions
  - `csv`
  - `font`
  - `json`
  - `gpu`
  - `md5`
- `src` core language components
  - `graphics` old graphics code
  - `noun` Basic buildings blocks of the language
    - `class.zig` Class enum `K`
    - `value.zig` Value struct `V`, array struct `N`
    - `symbol.zig` Symbols interned in `Pool`
  - `parser` Parser ink code to `IR`
    - `ast.zig` 
    - `lexer.zig`
    - `parser.zig`
  - `primitive`
    - `adverb` Implementation of around 15 adverbs 
      - `adverbs.zig` Overview of all adverbs.
    - `verb` Implementation of 60 verbs
      - `calc.zig` Arithmetic `+ - * %`, numeric: `sin abs ...`
      - `logic.zig` Logic verbs `< > = ~`
      - `helper.zig` Kernel comptime helpers for arithmetic and logical verbs
      - `verbs.zig` Overview of all monadic and dyadic verbs used in jump table.
    - `amend.zig` Implement amend and drill
    - `broadcast.zig`
    - `dispatch.zig` Dispatch to kernel based on operator and type of the operand(s)
    - `derived.zig` Derive value from an adverb phrase
    - `promote.zig` Promote between scalars, vectors and lists.
  - `runtime`
    - `call.zig`
    - `command.zig`
    - `compiler.zig`
    - `disarm.zig`
    - `fntable.zig`
    - `ir.zig`
    - `tape.zig` OpCode enum, BasicBlock struct and Chunk struct
    - `vm.zig`
  - `ffi.zig`
  - `runner.zig`
  - `runner_ui.zig`
  - `test.zig` All 178 unit tests passed
- `test`
  - `corpus` Parser tests in TxtTest format
  - `data`
  - `demo` Example of k code with cool visuals
- `build.zig`
- `build.zig.zon`
- `Makefile`

# Optimalizations
- JIT: as built is useful for user-defined reduce (`f:{x+y}; f/!N`),
- Optional GPU accelorator with`--gpu` flag.  `zig build -Dgpu=true && ink --gpu yourscript.ink
- Static allocated array for `!N` with N<256.
- Ref counting, copy on write.

# Building
The JIT build needs to be tested in debug and release mode because the compiler can generate different instructions and this can throw off the JIT.

- Runtime artifect: `zig-out/bin/ink`

Make sure the runtime compiles and builds with the following options for macos arm, linux x86_64 or arm, and windows x86_64

```
zig build
zig build -Djit=true
zig build -Dui=true
zig build -Djit=true -Dui=true

zig build -Doptimize=ReleaseFast
zig build -Djit=true -Doptimize=ReleaseFast
zig build -Dui=true -Doptimize=ReleaseFast
zig build -Djit=true -Dui=true -Doptimize=ReleaseFast
```

Test runtime with:
echo "1+2" | ink
