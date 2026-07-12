# Ink Language Reference

## Grammar

### Lexical Grammar


### Syntactical Grammar
Nouns can be combined into expressions using verbs and adverbs.
Expressions are evaluated right-to-left. There are no special precedence rules for operators.

#### Binding
- `n:e` **Single Binding** - When in global scope set a global constant and when in local scope set a local variable
- `n::e` **Double Binding** - When in global scope set a global variable and when in local scope set a global variable;

#### Juxtaposition

## Datetypes

| s|null|inf|
|--|---|---|
| b|0b |
| u|0Nu|0Wu|
| i|0N |0W|
| h|0nh|0wh|
| f|0n |0w|
| d|0nd|0wd|
|q3|0q3|0Wu|
| s|0nh|
| c|   |
--------

### Numeric tiers

Ink's numeric types are split into two tiers so that precision is **explicit**,
never transparent — the type system will not silently widen one precision to
another.

- **Tier 1 — the canonical tower** `bool → int(i32) → float(f32)`. These three
  implicitly promote among themselves (`1b+1` → `2`, an int in a float vector →
  float). All un-suffixed literals land here. Unchanged from classic k.
- **Tier 2 — explicit-precision types**, each an *isolated, closed* type that
  combines **only with itself** — `f32+f64`, `f16+f32`, `nat+int` are all
  `!type`. You enter a Tier-2 type with a suffixed literal or a cast, and leave
  it only with an explicit cast. Arithmetic (`+ - * % & |`), comparison
  (`= < >`), match (`~`), and the monadic math (`- abs sqrt sqr exp log sin
  cos`) are closed within each Tier-2 type.

Each Tier-2 type has a one-letter type symbol (lowercase = atom, uppercase =
vector), matching the literal suffix. `@` returns it; the same letter is the
cast target.

| suffix | type | `@` atom / vec | example | null | backing |
|--------|------|----------------|---------|------|---------|
| `u`    | u32 natural | `` `u `` / `` `U `` | `1u 2u 3u` | `0Nu` | u32 |
| `d`    | f64 double  | `` `d `` / `` `D `` | `2.3d` `2d` | `0nd` | f64 |
| `h`    | f16 half    | `` `h `` / `` `H `` | `2.3h` `2h` | `0nh` | f16 |

Cross-tier conversion is via cast: `` `u$5 ``, `` `d$x ``, `` `h$x ``,
`` `f$2.5d `` (back to f32), `` `i$2.9d ``. Casts route through the canonical
f32/i32 hubs. `q3`/`q2` (fp8 e4m3/e5m2) and `bf16` are planned, not yet
implemented (see the note at the end of this file / doc/design).

### Scalar types
- `b` **Boolean** - boolean number `0b 1b`, null `0b`, type `` `b ``
- `u` **Natural** - unsigned `u32`, e.g. `1u 2u 3u`, null `0Nu`, type `` `u `` (Tier 2)
- `i` **Integer** - numbers like `-2 0 1`, null `0N`, infinities `-0W 0W`, 32bit signed int.
- `f` **Float** - floating point numbers `0.1 2. -3.`, null `0n`, infinities `0w -0w`, 32bit float
- `d` **Double** - `f64`, e.g. `2.3d`, null `0nd`, type `` `d `` (Tier 2)
- `h` **Half** - `f16`, e.g. `2.3h`, null `0nh`, type `` `h `` (Tier 2)
- **Symbol** - interned string, e.g. `` `px ``, null/empty `` ` ``, type `` `s ``
- **Char** - a single character, eg `"H"`, null `" "`, type `` `c ``, u8 char

### Vector types
- **Boolean** - boolean number `0b 1b`, null `0b`, type `` `b ``
- **Integers** - array of integers, null `` &0 ``, type `` `I ``
- **Floats** - array of floats, null `` 0#0.0 ``, type `` `F ``
- **Naturals** - array of `u32`, e.g. `` 1u 2u 3u ``, type `` `U `` (Tier 2)
- **Doubles** - array of `f64`, e.g. `` 1.0d 2.0d ``, type `` `D `` (Tier 2)
- **Halves** - array of `f16`, e.g. `` 1.0h 2.0h ``, type `` `H `` (Tier 2)
- **Symbols** - array of symbols, empty value `` 0#` ``, type `` `S ``
- **Chars** - array of characters, null `""`, type `` `C ``
  - type symbol `` `C ``
  - empty value `` "" ``
  - backed by an array of u8.

> Structural/array verbs cover Tier-2 vectors for: construction, arithmetic,
> comparison, `~` match, `,` join, `#` tally, `|` reverse, `* *|` first/last,
> `@` index, `#` take, `+/ */ &/ |/` fused folds, `< >` grade/sort, `^` null
> mask, and cast. Naturals additionally support `?` distinct and `?` find.
> Deferred (low-value for precision floats): `?` distinct/find on f64/f16 and `=`
> group on any Tier-2 type — these need per-bit-width NaN-safe dedup helpers and
> a kind-tagged key vector. `&` where is int/bool-only by definition.

### Mapping Types
- **Dict**
  - The syntax `` [a:1; b:2; c: 3] `` is equivalent to `` `a`b`c!1 2 3 ``
  - Empty dict `` [] ``
  - Type symbol `` `m ``
- **Table**
  - The syntax `` [[]a:1 2; b:3 4] `` is equivalent to `` `a`b`c!1 2 3 ``
  - Type symbol `` `M ``.

### Other types
- **Error**
- **List** - heterogeneous list; empty list is `` () ``, type symbol `` `L ``.

### Callable types
- **Lambda** - a user-defined function, eg `{ a+b*c }`, type `` `o ``
- **Partial** - partialy applied operator/lambda, type `` `p ``
- **Composition** - A composition is a sequence of variadics applied in succession, type `` `q ``

### Blank `` ` ``
Blanks are used for empty assignment and defining partials.

## Variables
A variable is a name associated with a value, a name is an alphanumeric identifier starting with an alphabetic character.
A name may contain dots to separate segments (e.g. `a.b`, `ab1.ed4`), but a dot is only part of the name when immediately followed by a letter — `a.1` and `a. b` keep the dot as the index/apply operator. Underscores are not permitted in a variable name (`_` is always the Drop/Cut/Delete primitive).
The scope of a variable is either global or local.
A variable declared at the top level of a file are global.
A global is (assumed) constant when assigned with the single colon `:`
but a global is 
and a variable declared inside a lambda is a local variable.
Assignmet of globals and locals at the top level happens with the singe colon `:`,
while assigment of globals in a lambda happen with a double colon `::`

### General Verbs `@#`
- `@x` **Type** - Type of x. `` @(1;2.3;`c;"Hi")  / `i`f`s`C ``
- `#x` **Tally** - Count number of elements in x. `` #(1 2;3 4)  / 2 ``

### Arithmetic Verbs `-+*%`
- `-x` **Minus** - Negative x. `` -(1;2.3)  / (-1;-2.3) ``
- `x+y` **Add** - Sum of x and y
- `x-y` **Sub** - Difference between x and y
- `x*y` **Mul** - Product of x and y
- `x%y` **Div** - Return x divided by y. `` (2%3;4.%2.)  / 0.6666667 2.0 ``  

### Logical Verbs `~=|&`
- `~x` **Not** - boolean negation `` ~0110b  / 1001b ``
- `x~y` **Match** - identity check (same type and value)
- `x=y` **Equal** - elementwise equality
- `x|y` **Max/Or** - maximum value of x or y
- `x&y` **Min/And** - minimum value of x and y

### Grading Verbs `<>`
- `<X` **Ascend** - indices that sort X ascending
- `>X` **Descend** - indices that sort X descending

### Index Verbs `div mod`
- `x mod y` **Modulo** - remainder of x÷y (integer)
- `x div y` **Integer division** - floor(x÷y)
- `!i` **Iota** - integers 0..i-1
- `!I` **Odometer** - Cartesian product indices for an integer list

### Random Verb `?`
- `?X` **Distinct** - distinct elements in order
- `?i` **Uniform** - i random floats in [0,1)
- `i?x` **Roll/Deal** - i random selections from x

### String Verbs `$`
- `$x` **String** - string representation
- `i$C` **Pad** - pad string to length |i|

### Array Verbs `*|`
- `*x` **First** - first item in x
- `|x` **Reverse** - elements in reverse order

### List Verbs `,`
- `,x` **Enlist** - wrap x in a list
- `x,y` **Join** - join atoms/lists; merge dictionaries (right-side wins)

### Mappping Verbs `+!#_`
- `+d` **Pivot** - table to dict-of-lists and vice versa. `` +[[]n:`b`c;i:2 3] `` → `` [n:`b`c;i:2 3] ``
- `.d` **Value** - extract dictionary values
- `x!y` **Key** - dictionary creation
- `X#d` **TakeKeys** - filter dictionary d to keys X
- `X_d` **DropKeys** - remove keys X from dictionary d

### Structural Verbs `+#`
- `+x` **Flip** - transpose. `` +(1 2 3;4 5 6) `` → `` (1 4;2 5;3 6) ``
- `I#y` **Reshape** - reshape y to shape I, a `0N` means shape whats fits

### Erasure Verbs
- `i_Y` **Drop** - drop i items from start (positive) or end (negative)
- `I_Y` **Cut** - slice Y at indices I
- `f_Y` **WeedOut** - remove elements where boolean mask f is 1
- `X_i` **Delete** - remove element at index i from list X

### Other Verbs
- `.s` **GetSymbol** - retrieve global by symbol name
- `s$y` **Cast** - cast y to type s. `` `I$"-12" `` → `-12`; `` `F$"-12.3" `` → `-12.3`

### Bulk Verbs `` @[] .[] ?[] ``
- `@[x;y;f]` **Amend3** - `` @["ABC";1;_:] `` → `"AbC"`
- `@[x;y;F;z]` **Amend4** - `` @["abc";1;:;"x"] `` → `"axc"`
- `.[x;y;f]` **Drill3** - `` .[("AB";"CD");1 0;_:] `` → `("AB";"cD")`
- `.[x;y;F;z]` **Drill4** - `` .[("ab";"cd");1 0;:;"x"] `` → `("ab";"xd")`
- `?[C;I;C]` **Splice** - `` ?["abcd";1 3;"xyz"] -> "axyzd" `` TODO: does this work for non-char arrays as well

### Monadic Operators `:+-*!#@&|<>=?,^~$.`
- `:x` **Identity** - return right-hand side
- `&I` **Where** - convert counts to repeated indices
- `=X` **Group** - for each distinct value, the indices where it occurs
- `=i` **Unit** - identity matrix
- `^x` **Null** - boolean mask of null/missing elements

### Dyadic Operators
- Right `x:y` - return right-hand side
- `x#y` **Take** - resize/cycle y to length |x|
- `x^y` **Fill** - replace nulls in y with x
- `X^y` **Without** - remove occurrences of X from y
- `x?y` **Find** - first index of y in x (`#x` / length if not found, for index-with-fallback)
- `x@y` **Apply** - index into x at y; apply function x to y
- `x.y` **ApplyN** - deep indexing or multi-argument application

### IO Verbs
The IO system is organized around file descriptors (filename, port number, etc.).
- `` <c `` **OpenFile** - return file handle for file (relative or absolute path)
- `` <s `` **OpenSocket** - return file handle for connection to `"host:port"` or `":port"`
- `` >n `` **CloseHandle**
- `` 0:x `` **ReadLine** - read lines from stdin
- `` x 0:y `` **Write line** - write text. `` `0 0:"Hi" ``
- `` 1:x `` **ReadBytes** 
- `` 1:`stdin `` reads up to 64 KiB of available bytes from stdin (blocks for ≥1 byte); returns `""` at EOF. Partial by design — frame/buffer in k. For byte-stream protocols (LSP/Jupyter).
- `` x 1: y `` **Write bytes**
- `` `stdout 1: y `` / `` `stderr 1: y `` write raw bytes with **no** trailing newline and flush (unlike `` `0 0:y `` which appends `\n`).
- Writing to a path that doesn't exist **creates** the file (`` "new.txt" 1: bytes ``); the same holds for `` x 0: y ``. (Reads still require the file to exist.)
- `` 2: y `` **LoadCode** - used for importing other files

## Adverbs `` ' / \ ': /: \: ``
An adverb is one of the glyphs: `` ' / \ ': /: \: `` when it is used as a modifier 
of how the verb on the right-hand side is applied to the verb on the left hand argument.
The verb can be a operator, partial or lambda.
- `f'` **Each** - apply f to each item. `` #'("abc";3 4 5 6) `` → `3 4`
- `x F'` **Zip** - elementwise dyad. `` 2 3#'"ab" `` → `("aa";"bbb")`
- `F/` **Fold** - left fold. `+/1 2 3` → `6`
- `F\` **Scan** - running fold. `+\1 2 3` → `1 3 6`
- `x F/` **Seeded Fold** - fold with seed. `10+/1 2 3` → `16`
- `x F\` **Seeded Scan** - running fold with seed. `10+\1 2 3` → `11 13 16`
- `i f/` **N-do** - apply f i times. `` 5(2*)/1 `` → `32`
- `i f\` **N-dos** - all intermediate results. `` 5(2*)\1 `` → `1 2 4 8 16 32`
- `f f/` **While** - apply until condition fails. `(1<){:[2!x;1+3*x;-2!x]}/3` → `1`
- `f f\` **Whiles** - all states while condition holds
- `f/` **Converge** - iterate until stable. `` {1+1.0%x}/1 `` → `1.618...`
- `f\` **Converges** - successive results until convergence
- `C/` **Join** - join list with separator. `"ra"/("ab";"cadab";"")` → `"abracadabra"`
- `C\` **Split** - split by separator. `"ra"\"abracadabra"` → `("ab";"cadab";"")`
- `I/` **Decode** - mixed-base to number. `24 60 60/1 2 3` → `3723`
- `I\` **Encode** - number to mixed-base. `24 60 60\3723` → `1 2 3`
- `i'` **Window** - sliding windows. `3':"abcdef"` → `("abc";"bcd";"cde";"def")`
- `i f'` **Stencil** - apply f to each window. `` 3{x,"."}'"abcde" ``
- `F':` **Eachprior** - apply F between each item and its predecessor. `-':12 13 11 17 14` → `12 1 -2 6 -3`
- `x F':` **Seeded Eachprior** - like eachprior with seed. `10-':12 13 11 17 14` → `2 1 -2 6 -3`
- `x F/:` **Eachright** - fixed right arg to each left item. `1 2*/:3 4` → `(3 6;4 8)`
- `x F\:` **Eachleft** - fixed left arg to each right item. `1 2*\:3 4` → `(3 4;6 8)`
Adverbs are polysemic, there behaviour depends on the unique combination of the operator glyph, type of the operands and the arity (monadic/dyadic) of the operator verb. For example the `\` can be either a Fold with a dyadic verb `F` or a Converge with a monadic verb `f`.
- `'`: Each, Zip
- `/`: Fold, Decode, Join, N-do, While, Converge
- `\`: Scan, Encode, Split, N-dos, Whiles, Converges
- `':`: Eachprior, Window, Stencil
- `/:`: Eachright
- `\:`: Eachleft
Some adverbs are digrams, like While `f f/` and Stencil `i f'`, they have 2 left-hand arguments.

## Tables, Queries & Joins
- Create table `` [[]id:1 2 3; age:20 43 7] ``
- Created keyes table `` [[]id:1 2 3; age:20 43 7] ``

### Math Functions (prelude names, not grammar keywords)
`sqrt sqr log exp sin cos abs` and the inverse trig `asin acos atan atan2` are **not**
built-in verbs — they are ordinary names bound in `lib/prelude.k` (loaded into every VM
at init) to callable symbols: `` sin:`sin@ `` etc. `` `sin@x `` routes through `syms.zig`
to the same opcode kernel the old verb used, so `sin x` / `sqrt 4 9` behave as before and
`sqr`/`abs` stay integer-closed on integers. Because they are names (nouns) rather than
verbs, a bare op-glyph directly after one is **dyadic** — but a `-` glued to a numeric
literal with a leading space is a negative literal, so `abs -4` applies `abs` to `-4`
(while `abs-4` subtracts and `abs -x` still needs `abs[-x]`). See
`src/primitive/intrinsic.zig` (the canonical registry) and
`doc/design/dye.md`. GPU shaders (lib/dye.k) additionally support `pow min max dot cross
step mod clamp mix smoothstep floor fract sign tanh length normalize`.


## Special Symbols
- `` `argv[] `` **Arguments** - list of cmd-line args (also in global `x`)
- `` `env[] `` **Environment variables** - dict of env variables
- `` `dir p `` **Directory walk** - recursively list file paths under directory `p` (a char vector), skipping hidden/build dirs; returns a list of path strings. Apply by **juxtaposition** (`` `dir p ``), not `@`.
- `` `prng[] `` **Random number**
- Inverse trig `` `asin@x ``, `` `acos@x ``, `` `atan@x `` (element-wise over F vectors), `` `atan2@(y;x) `` (broadcasts scalar⊕vector) — no verb glyph, added for equirectangular UV mapping (see `test/earth.k`)
- Exit `` `exit@i ``

## Commands
A command always starts at the beginning of a line with `\`.
- `\d name` - Declare namespace
- `\l name` - Load `name` module from `$INK_HOME/lib/<name>.k`
- `\l name.k` - Loads `name` module from `$PWD/<name>.k`
- `\t:n expr` - Time elapsed in milliseconds after n runs (n is optional).

## Native Extension
Ink supports writing native extensions based on a FFI.
The names of exported symbols from a shared library should be prefixed by the name of the module.

## Fuzed Operators
- `+/` **Sum**
- `*/` **Product**
- `|/` **Maximum**
- `&/` **Minimum**
- `=/` 
- `</` 
- `>/` 
- `,/` **Raze**

## Libraries

### Audio Library
- `audio.play "boop.wav"` - one-shot UI/SFX
- `audio.load "gun.wav"`a controllable voice
- `audio.start h`          (re)trigger it
- `audio.music "song.mp3"` streamed, looping background music
- `audio.pos[h; 3 0 -2]`   place it in 3D; move the listener
- `audio.listener 0 0 0` - with audio.listener each frame
- `audio.rec.start[]` - start the mic
- `s: audio.rec.read[]` - drain samples (call in your loop)
- `audio.save["take.wav"; audio.rec.channels[]; audio.rec.rate[]; s]`
- `clip: audio.decode "take.wav"` - load a file to a PCM dict

### Crypto Library TODO

### Data Library
- `csv.read`
- `csv.write`
- `json.read`
- `json.write`
- `parquet.read`
- `parquet.write`

### Image Library
- `image.read[path]`
- `image.write[path;img]`
- `image.scale[img;w;h]`

### Graphics Library
- `window.run`

### Network Library
