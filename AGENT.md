# Agent Instructions
- Implementation of the Ink array programming language similar to ngn/k and k9.
- Ink is a polysemic language, its operators have a different meaning based on the number of arguments and the type of those arguments.
- Commands can get stuck in a loop, run with a timeout: `timeout 1s ./zig-out/bin/ink; [ $? -eq 124 ] && echo 'Script timed out!'`.
- Use 2 spaces for code indentation.
- Use zig version 0.16
- Don't use `zig fmt` on code.
- Cast ints and floats in Zig like this: `@as(f64, @floatFromInt(a))`.
- Run a single test `zig test myfile.zig --test-filter "parses header"`
- Add debug statements to verify your thinking.

# Ink language Overview
Ink (sometimes called terse) is an array programming language based on k.


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

### Vectors
```k
ints: 1 2 0N
floats: 1.2 -3 0n 0w -0w
chars: "Hello"
symbols: `a`b`c
```

### List `` (1;2.3;`c) ``
```k
list: (1;2.3;`c)
```

### Types & Archtypes
- scalars: int `` `i ``, float `` `f ``, char `` `c ``
- vectors: in `` `i ``, float `` `f ``, char `` `c ``

## Verbs

### Logical & Arithmetic `` +-*% ``
```k
1 2 3 + 4 5 6
```

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

### Monadic Operators `+-*!#@&|<>=?,^~$.`
- `+x` Flip: Matrix transpose on nested lists; Table to Dict-of-Lists (and vice versa).
- `-x` Negate: Numeric negation.
- `*x` First: Returns the first item of its argument.
- `!i` Iota: Generates a list of consecutive integers starting at 0 up to i-1.
- `!I` Odometer: For an integer list I, produces Cartesian product indices.
- `#x` Tally: Returns the number of elements.
- `@x` Type: Returns the symbol representing the type of x (e.g. \`i, \`F, \`v).
- `&I` Where: Converts a list of counts into repeated indices.
- `|x` Reverse: Returns x with its elements in reverse order.
- `<s` Open file and return handle
- `<X` Ascend: Returns the indices that would sort X in ascending order.
- `<s` Close file handle
- `>X` Descend: Returns the indices that would sort X in descending order.
- `=X` Group: Returns index lists for unique values in X.
- `=i` Unit: Identity matrix.
- `?X` Distinct: Returns the distinct elements of X in order.
- `?i` Uniform: Returns i random floats in [0,1).
- `,x` Enlist: Wraps x in a list (increases rank).
- `^x` Null: Returns a boolean mask indicating null/missing elements.
- `~x` Not: Logical negation (returns 1 for 0/nulls, 0 otherwise).
- `$x` String: Returns the string representation of x.
- `.x` Values/Get: Extracts dictionary values; Retrieves global symbol value.
- `sqrt n`
- `sqr n`
- `log n`
- `exp n`
- `sin n`
- `cos n`
- `abs n`

### Dyadic Operators
- `x+y` Add: Addition.
- `x-y` Sub: Subtraction.
- `x*y` Mul: Multiplication.
- `x%y` Div: Division (integer divFloor for integers, float division for floats).
- `x!y` Key: Dictionary creation.
- `x=y` Equal: Elementwise equality comparison.
- `x~y` Match: Identity check (same type and value).
- `i_Y` Drop: Drops i items from the start (positive i) or end (negative i).
- `X_d` Drop keys: Removes keys X from dictionary d.
- `I_Y` Cut: Slices Y at indices I.
- `f_Y` WeedOut: Removes elements where boolean vector f is 1.
- `X_i` Delete: Removes element at index i from list X.
- `x,y` Join: Joins atoms/lists into a list; Merges dictionaries (right-side precedence).
- `x#y` Take: Resizes/cycles list y to length |x|.
- `X#d` TakeKeys: Filters dictionary d for keys in X.
- `I#y` Reshape: Filters dictionary d for keys in X.
- `x^y` Fill: Replaces nulls in y with x.
- `X^y` Without: Removes occurrences of elements in X from list y.
- `x$y` Pad: Pads string y to length |x|.
- `x$y` Cast: Casts y to type represented by symbol x.
- `x?y` Find: Returns first index of y in x (null if not found).
- `i?x` Roll/Deal): i random selections from x (positive: replacement, negative: unique).
- `s@x` (Unmarchal/Deserialize): supports csv, bin
- `s?x` (Marchal/Serialize): 
- `x@y` (At/Apply): Indices into x at y; Applies function x to y.
- `x.y` (Dot/ApplyN): Deep indexing or multi-argument function application.

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

### each1 `f'`
#'("abc";3 4 5 6) -> 3 4
### each2 `x F'`
2 3#'"ab" -> ("aa";"bbb")
### binsearch `X'`
1 3 5 7 9'8 9 0 -> 3 4 -1
### fold `F/`
+/1 2 3 -> 6
### scan `F\`
+\1 2 3 -> 1 3 6
### seeded `x F/ /`
10+/1 2 3 -> 16
### seeded `x F\ \`
10+\1 2 3 -> 11 13 16
### n-do i f/
5(2*)/1 -> 32
### n-dos i f\
5(2*)\1 -> 1 2 4 8 16 32
### while `f f/`
(1<){:[2!x;1+3*x;-2!x]}/3 -> 1
### whiles `f f\`
(1<){:[2!x;1+3*x;-2!x]}\3 -> 3 10 5 16 8 4 2 1
### converge `f/`
{1+1.0%x}/1 -> 1.618033988749895
### converges `f\`
(-2!)\100 -> 100 50 25 12 6 3 1 0
### join `C/`
"ra"/("ab";"cadab";"") -> "abracadabra"
### split `C\`
"ra"\"abracadabra" -> ("ab";"cadab";"")
### decode `I/`
24 60 60/1 2 3 -> 3723   2/1 1 0 1 -> 13
### encode `I\`
24 60 60\3723 -> 1 2 3   2\13 -> 1 1 0 1
### window `i'`
3':"abcdef" -> ("abc";"bcd";"cde";"def")
### stencil `i f'`
3{x,"."}':"abcde" -> ("abc.";"bcd.";"cde.")
### eachprior `F'`
-':12 13 11 17 14 -> 12 1 -2 6 -3
### seeded `x F'`
': 10-':12 13 11 17 14 -> 2 1 -2 6 -3
### eachright `x F/`
1 2*/:3 4 -> (3 6;4 8)
### eachleft `x F\`
1 2*\:3 4 -> (3 4;6 8)



# About the Ink array programming language
Ink is a array programming language for high performance computing.
It is based on the k array programming languages ngn/k and k9.
The language parser, compiler and runtime are all written in Zig 0.16.


# Project Overview
- `src`
  - `graphics`
    - `color.zig` Oklch color 
    - `data.zig` Unicode data (very big, 14K lines of data tables)
    - `shape.zig` Text shaping for glyphs
    - `ink.zig` Vector graphics API and named colors
    - `triangulate.zig` Triangulate bezier curve using earcutting
    - `window.zig` Window screen
  - `noun` Basic buildings blocks of the language
    - `class.zig` Class enum `K`
    - `value.zig` Value struct `V`
    - `symbol.zig` Symbols interned in `Pool`
  - `parser`
    - `ast.zig`
    - `lexer.zig`
    - `parser.zig`
  - `primitive`
    - `adverb` Implementation of adverbs
    - `verb` Implementation of 60 verbs
      - `calc.zig` Arithmetic `+ - * %`, numeric: `sin abs ...`
      - `logic.zig` Logic verbs `< > = ~`
      - `helper.zig` Kernel comptime helpers for arithmetic and logical verbs
      - `verbs.zig` Overview of all monadic and dyadic verbs used in jump table.
    - `amend.zig` Implement amend and drill
    - `broadcast.zig`
    - `dispatch.zig`
    - `promote.zig` Promote between scalars, vectors and lists.
  - `runtime`
    - `jit`
    - `vm.zig`
  - `runner.zig`
  - `runner_ui.zig`
  - `test.zig`
- `test`
  - `corpus` Parser tests in TxtTest format
  - `data`
  - `demo` Example of k code with cool visuals
- `build.zig`
- `build.zig.zon`
- `Makefile`
