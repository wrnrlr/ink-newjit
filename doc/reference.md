# Ink Language Reference

## Grammar

### Lexical Grammar

```ebnf
digit    = "0" | "1" | ... | "9" ;
hex      = digit | "a" ... "f" | "A" ... "F" ;
letter   = "a" ... "z" | "A" ... "Z" ;
sign     = "-" ;
exponent = ( "e" | "E" ) , [ "+" | "-" ] , digit , { digit } ;
mantissa = ( digit , { digit } , [ "." , { digit } ]
            | "." , digit , { digit } ) , [ exponent ] ;
bit = ( "0" | "1" ) , "b" ;
nat = ( digit , { digit } | "0" , ( "N" | "W" ) ) , "u" ;
int   = [ sign ] , ( "0" , ( "x" | "X" ) , hex , { hex }
          | "0" , ( "N" | "W" )
          | digit , { digit } ) ;
float = [ sign ] , ( "0" , ( "n" | "w" )
          | ( digit , { digit } , "." , { digit }
          | "." , digit , { digit } ) , [ exponent ]
          | digit , { digit } , exponent ) ;
double = [ sign ] , ( "0" , ( "n" | "w" ) | mantissa ) , "d" ;
half   = [ sign ] , ( "0" , ( "n" | "w" ) | mantissa ) , "h" ;
bits   = ( "0" | "1" ) , ( "0" | "1" ) , { "0" | "1" } , "b" ;
string = '"' , { stringchar } , '"' ;
symbol = "`" , ( { letter | digit | "." }| '"' , { ? any char except '"' ? } , '"' ) ;
name   = letter , { letter | digit } ,
         { "." , letter , { letter | digit } } ;
```

### Syntactical Grammar
Nouns can be combined into expressions using verbs and adverbs.
Expressions are evaluated **right-to-left**; there is no operator precedence, so
`2*3+4` is `2*(3+4)` = `14`. A verb with a noun on both sides is **dyadic**
(infix); with only a noun to its right it is **monadic** (prefix).

The grammar below is a readable distillation of the tree-sitter grammar
(`tools/tree-sitter-ink/grammar.js`), which resolves the monadic/dyadic valence
and the noun/verb ambiguity through dynamic precedence rather than the plain
productions shown here.

```ebnf
(* A program is statements separated by newlines or ';'. *)
program   = [ line ] , { sep , [ line ] } ;
sep       = ";" | newline ;
line      = statement | comment | namespace | command ;
(* A statement is one right-to-left expression. *)
statement = verb | noun | clause ;
clause    = binding | dyad | monad ;
binding   = noun , [ op ] , ( ":" | "::" ) , [ clause ] ;   (* x:e  x+:e  x::e *)
dyad      = noun , verb , statement ;                       (* a f b  — infix  *)
monad     = verb , statement ;                              (* f x    — prefix *)
phrase    = verb | noun ;
(* Verbs *)
verb      = op | verb_io | derived ;
derived   = phrase , adverb ;                               (* +/  f'  {x}\ *)
op        = "+" | "-" | "*" | "%" | "!" | "&" | "|" | "<" | ">" | "="
          | "~" | "," | "^" | "#" | "_" | "$" | "?" | "@" | "." | ":"
          | "in" | "has" | "mod" | "div" ;
verb_io   = digit , ":" ;                                   (* 0: 1: 2: *)
adverb    = [ ":" ] , ( "'" | "/" | "\" ) , [ ":" ] ;       (* ' / \ ': /: \: *)
(* Nouns *)
noun      = literal | name | group | list | lambda
          | dict | table | ktable | apply | amend | cond ;
group     = "(" , statement , ")" ;                         (* precedence grouping *)
list      = "(" , [ seq ] , ")" ;                           (* (1;2;3)  () *)
apply     = phrase , "[" , [ seq ] , "]" ;                  (* f[x;y]  m[k] *)
amend     = ( "@" | "." ) , "[" , seq , "]" ;               (* @[x;i;f]  .[x;i;f;y] *)
cond      = "$[" , statement , { div , statement } , "]" ;  (* $[c;t;…;e] *)
lambda    = "{" , [ params ] , [ seq ] , "}" ;              (* {x+y}  {[a;b] a+b} *)
params    = "[" , [ name , { div , name } ] , "]" ;
(* Dictionaries and tables *)
dict      = "[" , [ items ] , "]" ;                         (* [a:1;b:2]  [] *)
table     = "[[]" , [ items ] , "]" ;                       (* [[]a:1 2;b:3 4] *)
ktable    = "[[" , items , "]" , [ items ] , "]" ;          (* keyed table *)
items     = item , { div , item } ;
item      = name , ":" , [ statement ] ;

seq       = statement , { div , statement } ;
div       = ";" | newline ;
```

## Operational Semantics

#### Binding
- `n:e` **Single Binding** - When in global scope set a global constant and when in local scope set a local variable
- `n::e` **Double Binding** - When in global scope set a global variable and when in local scope set a global variable;
- `n f:e` **Compound Binding** - modify in place through verb `f`: `x+:1` is `x:x+1`, `x,:y` appends. The value is required (`x+:` alone is not a binding), so `1<:\y` still reads as a transit with the scanned grade-up verb `<:\`.

An empty right-hand side (`x:` continued on the next line) is allowed for plain
`:`/`::` binding but not for the compound form.

#### Juxtaposition
Juxtaposition is two ink values written next to each other; its meaning depends
on the type of the left value:

- **callable on the left** (lambda `` `o ``, operator, partial `` `p ``,
  composition `` `q ``) — the left value is *applied* to the right: `sqrt 4`,
  `(1+) 2`, `f x`.
- **array on the left** (vectors and list) — pick the rhs indexes from the rhs array.
- **mapping on the left** (dict and table) — select by key.
- **verb between two nouns** — the verb applies **dyadically**: `2+3`, `a,b`.
- **verb with a noun only to its right** — the verb applies **monadically**:
  `-x`, `#l`, `|v`.

Bracket application `f[a;b]` is the explicit form and disambiguates valence and
argument count; `f[;b]` fixes only the second argument (a projection). Because
evaluation is right-to-left, a chain of juxtaposed monads reads outermost-last:
`f g h x` is `f(g(h(x)))`.

### Branching


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

### Error Values
- `!type` **Type Error**
- `!rank` **Rank Error**
- `!domain` **Domain Error**

### Other types
- **Error**
- **List** - heterogeneous list; empty list is `` () ``, type symbol `` `L ``.

### Callable types
- **Lambda** - a user-defined function, eg `{ a+b*c }`, type `` `o ``
- **Partial** - partialy applied operator/lambda, type `` `p ``
- **Composition** - A composition is a sequence of variadics applied in succession, type `` `q ``

### Blank
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

### General Verbs
- `@x` **Type** - Type of x. `` @(1;2.3;`c;"Hi")  / `i`f`s`C ``
- `#x` **Tally** - Count number of elements in x. `` #(1 2;3 4)  / 2 ``

### Arithmetic Verbs
- `-x` **Minus** - Negative x. `` -(1;2.3)  / (-1;-2.3) ``
- `x+y` **Add** - Sum of x and y
- `x-y` **Sub** - Difference between x and y
- `x*y` **Mul** - Product of x and y
- `x%y` **Div** - Return x divided by y. `` (2%3;4.%2.)  / 0.6666667 2.0 ``  

### Logical Verbs
- `~x` **Not** - boolean negation `` ~0110b  / 1001b ``
- `x~y` **Match** - identity check (same type and value)
- `x=y` **Equal** - elementwise equality
- `x|y` **Max/Or** - maximum value of x or y
- `x&y` **Min/And** - minimum value of x and y

### Grading Verbs
- `<X` **GradeUp** - indices that sort array or table in ascending order
- `>X` **GradeDown** - indices that sort array or table in descending order

### Index Verbs
- `x mod y` **Modulo** - remainder of x÷y (integer)
- `x div y` **Integer division** - floor(x÷y)
- `!i` **Iota** - integers 0..i-1
- `!I` **Odometer** - Cartesian product indices for an integer list

### Random Verb
- `?X` **Distinct** - distinct elements in order
- `?i` **Uniform** - i random floats in [0,1)
- `i?x` **Roll/Deal** - i random selections from x

### String Verbs
- `$x` **String** - string representation
- `i$C` **Pad** - pad string to length |i|

### Array Verbs
- `*x` **First** - first item in x
- `|x` **Reverse** - elements in reverse order

### List Verbs
- `,x` **Enlist** - wrap x in a list
- `x,y` **Join** - join atoms/lists; merge dictionaries (right-side wins). `x,()` (empty list on the right) is identity and preserves x's type — a typed vector stays typed (`` `a`b,() `` → `` `S ``), an atom enlists to its typed 1-vector (`1,()` → `,1`). (The left form `(),x` still boxes into a general list `` `L ``.)

### Mappping Verbs
- `+d` **Pivot** - table to dict-of-lists and vice versa. `` +[[]n:`b`c;i:2 3] `` → `` [n:`b`c;i:2 3] ``
- `.d` **Value** - extract dictionary values
- `<m` **Ascend** - Sort dict by ascending values. `` <`a`b`c!3 1 2 `` → `` [b:1;c:2;a:3] ``
- `>m` **Decend** - Sort dict by decending values
- `<t` **Ascend** - Indices that sort table t's rows ascending, comparing the columns left to right, so `t@<t` sorts. `` <[[]a:3 1 2;b:`x`y`z] `` → `1 2 0`
- `>t` **Decend** - Indices that sort table t's rows decending. A keyed table is an `m`, so it follows the dict rule instead: reordered by its value rows, with the key rows following along.
- `=d` **Group** - group d by its values: each distinct value → the list of keys carrying it. `` =`a`b`c`d!1 0 1 0 `` → `` 0 1!(`b`d;`a`c) ``. Same verb as `=X`, with a dict's keys standing in where a vector's indices would be, so `==X` inverts a group.
- `|d` **Reverse** - reverse the entry order, keys and values together. `` |`a`b`c!1 2 3 `` → `` [c:3;b:2;a:1] ``. A keyed table reverses its rows.
- `x@d` **Apply** - index x through d's values, keys unchanged: `(x@d)[k]` is `x@d[k]`. `` 1 2 3 4@`x`y!(0 2;1) `` → `` [x:1 3;y:2] ``
- `x!y` **Key** - dictionary creation
- `X#d` **TakeKeys** - filter dictionary d to keys X
- `X_d` **DropKeys** - remove keys X from dictionary d

### Structural Verbs
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

### Bulk Verbs
- `@[x;y;f]` **Amend3** - `` @["ABC";1;_:] `` → `"AbC"`
- `@[x;y;F;z]` **Amend4** - `` @["abc";1;:;"x"] `` → `"axc"`
- `.[x;y;f]` **Drill3** - `` .[("AB";"CD");1 0;_:] `` → `("AB";"cD")`
- `.[x;y;F;z]` **Drill4** - `` .[("ab";"cd");1 0;:;"x"] `` → `("ab";"xd")`
- `?[C;I;C]` **Splice** - `` ?["abcd";1 3;"xyz"] -> "axyzd" `` TODO: does this work for non-char arrays as well

### Monadic Operators
- `:x` **Identity** - return right-hand side
- `%x` **Shape** - rectangular extent as an int vector (APL rho): `%5`→`!0` (atom, rank 0), `%1 2 3`→`,3`, `%(1 2;3 4;5 6)`→`3 2`. Ragged lists stop at the first non-uniform level (`%(1 2;3 4 5)`→`,2`). Inverse of reshape: `(%m)#,/m ~ m`. Placed arrays carry it as the descriptor's `s` field.
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
- `x.y` **ApplyN** - deep indexing (`(1 2 3;4 5) . 1 0` → `4`), or applying a function to
  a list of arguments: `` {x+y} . 1 2 `` → `3`, `` {x+y+z} . (1;2;3) `` → `6`. The items
  of y become the arguments, so the argument count may be computed at runtime; an atom is
  a single argument and `f . ()` applies nothing. A function takes at most 16 arguments,
  and passing more than its arity is a `!rank` error.

### IO Verbs
The IO system is organized around file descriptors (filename, port number, etc.).
- `` >s `` **OpenFile** - return file handle for file (a symbol path, relative or absolute)
- `` >C `` **OpenSocket** - connect to `"host:port"`, return a connection handle
- `` >i `` **Listen** - listen on port `i` and block until the first client connects;
  a **negative** port listens without blocking and serves through the event loop
  (same as the `\p` command). See [IPC](#ipc).
- `` <i `` **CloseHandle**
- `` 0:x `` **ReadLine** - read lines from stdin
- `` x 0:y `` **Write line** - write text. `` `0 0:"Hi" ``
- `` 1:x `` **ReadBytes** 
- `` 1:`stdin `` reads up to 64 KiB of available bytes from stdin (blocks for ≥1 byte); returns `""` at EOF. Partial by design — frame/buffer in k. For byte-stream protocols (LSP/Jupyter).
- `` x 1: y `` **Write bytes** — `y` is a `` `C `` char vector or a single `c` char atom (a 1-byte write; `` `stdout 1: "a" `` works without enlisting).
- `` `stdout 1: y `` / `` `stderr 1: y `` write raw bytes with **no** trailing newline and flush.
- Writing to a path that doesn't exist **creates** the file (`` "new.txt" 1: bytes ``); the same holds for `` x 0: y ``. (Reads still require the file to exist.)
- `` 2: y `` **LoadCode** - used for importing other files
- `` 2: h `` **Receive** - on a connection handle, block for one binary message
- `` h 2: y `` **Send** - on a connection handle, send `y` as one binary message
- `` 9: x `` **Place** — upload x to the GPU; returns a placed-array descriptor dict `[gpu:handle;t;n;s]`.
- `` d 9: x `` **PlaceInto** — overwrite placement `d`'s buffer in place (no realloc); returns `d`
- `` 8: d `` **Fetch** — sync + read a placed array back to the host, reshaped to its `s`; a `tbl` descriptor reads every column and rebuilds the table
- `` n 8: d `` **FetchN** — first n elements (trims the ×64 dispatch padding)

## Adverbs
An adverb is one of the glyphs: `` ' / \ ': /: \: `` when it is used as a modifier 
of how the verb on the right-hand side is applied to the verb on the left hand argument.
The verb can be a operator, partial or lambda.
- `f'` **Each** - apply f to each item. `` #'("abc";3 4 5 6) `` → `3 4`. A dict maps over its values and stays keyed (`` (+/)'`a`b!(1 2;3 4) `` → `` [a:3;b:7] ``, so `` (|/)'score@=player `` reports a max per player); a table maps over its rows.
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


## IPC

Processes talk over TCP. **Verbs move data; backtick-symbols configure the
runtime; bare globals are the hooks.** There is no `.z` namespace — `.` is a
verb, so a handler that needs to know who called takes an extra argument
instead.

### Connections

```k
h: > "127.0.0.1:5010"   / connect; a dead address returns an error VALUE
h: > 5010               / listen, blocking until the first client connects
h: > -5010              / listen without blocking, serve via the event loop
< h                     / close
```

`\p 5010` is the same as `> -5010` and is the usual way to open a service.
Handles are integers (≥ 32768, so they never collide with file handles). A
failed connect is an ordinary error value, which is what a reconnect loop
tests each tick:

```k
iserr:{`"!"~@x}
c: > "127.0.0.1:5010"
$[iserr c; retry[]; connected c]
```

### Messages

`h 2: v` sends `v` as one length-prefixed binary message; `2: h` blocks for
one. Every value class travels: atoms, vectors, general lists, dicts, tables
and keyed tables go structurally; **lambdas, projections, derived verbs and
trains travel as their source text and are re-compiled by the receiver**, so a
function arrives callable. Only foreign objects (`x`, e.g. GPU handles) are
rejected. A function's text is compiled — not run — on arrival, but any global
it names resolves in the *receiver's* scope, so treat an inbound function the
way you would treat inbound code.

For a byte- or line-oriented protocol (HTTP, LSP) use `0:` and `1:` on the same
handle instead; they do no framing and no serialization.

### Handlers

A handler is a plain global. Its **arity** picks the calling convention:

```k
pg:{[m] "echo: ", m}    / message only; a non-blank result is sent back
pg:{[h;m] …}            / also given the handle it arrived on
ps:{[m] …}              / same, but never replies (the async side)
po:{[h] …}              / a peer connected
pc:{[h] …}              / a peer went away
ts:{[] …}               / timer tick, see `timer below
```

The dyadic form is what `.z.w` is for in q. Because the handler is *given* the
handle, it can park it and answer later — from a different dispatch entirely —
which is how a gateway forwards a query and routes the answer back to the
client that asked. Returning blank sends nothing.

`` `on[h;f] `` attaches `f` to one handle and takes priority over `pg`/`ps`, so
one process can speak different protocols to different peers. A handler
attached to a listening handle is inherited by the clients it accepts.

### Event loop

The loop polls every connection, fires the timer, accepts new clients, and
dispatches one message per ready handle per pass. A script enters it
automatically when it finishes with work outstanding: a listening port, a
timer, or a handler attached to an outbound connection — that last case is what
lets a *client* process sit waiting for replies without listening on a port it
does not need. `` `serve[] `` enters it explicitly; `` `poll[] `` runs a single
non-blocking pass, which is what a render loop wants.

It is single-threaded: a handler that blocks (on `2: h`, say, to forward a
query synchronously) stalls every other connection until it returns. Prefer
`` `on `` plus a dyadic handler when that matters.

### Worked shape

```k
/ gateway: park the caller, forward, answer out of band
sqs: !0                       / outstanding sequence numbers
uhs: !0                       / the client handle each belongs to
seq: 0
bh: > "127.0.0.1:5211"        / long-lived connection to the backend

back:{[m]                     / backend answered (sq;payload)
  i: *&sqs=m 0
  uh: uhs i
  sqs:: sqs _ i
  uhs:: uhs _ i
  uh 2: (`res; m 1) }
`on[bh; back]

pg:{[h;m]                     / client asked: remember h, forward, reply LATER
  seq:: seq+1
  sqs:: sqs,seq
  uhs:: uhs,h
  bh 2: (seq; m) }
\p 5210
```

Runnable versions of all three tiers are in `test/ipcback.k`,
`test/ipcgate.k` and `test/ipccli.k`.

## Special Symbols
- `` `argv[] `` **Arguments** - list of cmd-line args (also in global `x`)
- `` `env[] `` **Environment variables** - dict of env variables
- `` `dir p `` **Directory walk** - recursively list file paths under directory `p` (a char vector), skipping hidden/build dirs; returns a list of path strings. Apply by **juxtaposition** (`` `dir p ``), not `@`.
- `` `prng[] `` **Random number**
- `` `t[] `` **Clock** - microseconds on a monotonic clock; for elapsed time, not wall time
- `` `sleep[ms] `` **Sleep** - block for `ms` milliseconds (fractional is fine; ≤0 is a no-op)
- `` `timer[ms] `` **Timer** - call the global `ts` every `ms` ms while the event
  loop runs. `` `timer[0] `` stops it, `` `timer[] `` reads it back.
- `` `on[h;f] `` **Attach handler** - `` `on[h;] `` detaches, `` `on[h] `` reads it back
- `` `conns[] `` **Open handles** - ascending int vector
- `` `peer[h] `` **Peer address** - `"ip:port"` of the far end, `""` while only listening
- `` `poll[] `` **Pump** - one non-blocking pass of the event loop
- `` `serve[] `` **Serve** - run the event loop forever
- Inverse trig `` `asin@x ``, `` `acos@x ``, `` `atan@x `` (element-wise over F vectors), `` `atan2@(y;x) `` (broadcasts scalar⊕vector) — no verb glyph, added for equirectangular UV mapping (see `demo/earth.k`)
- Exit `` `exit@i ``

## Commands
A command always starts at the beginning of a line with `\`.
- `\d name` - Declare namespace
- `\e a b c` - Export the **bare** (undotted) names `a b c` for autoload. Dotted names
  (`ns.member`) are indexed automatically, along with their `ns` prefix; bare globals are
  not, because most of them are private helpers and indexing them all would pull in half
  the library on any common identifier. `\e` lets a module publish an unqualified API
  (`gemm`, `linear`, …) without that. Runtime no-op — it is read by the module indexer.
- `\l name` - Load `name` module from `$INK_HOME/lib/<name>.k`
- `\l name.k` - Loads `name` module from `$PWD/<name>.k`
- `\p port` - Listen on `port` and serve through the event loop when the script
  finishes. Same as `> -port` but discards the handle. See [IPC](#ipc).
- `\t:n expr` - Time elapsed in milliseconds after n runs (n is optional). This
  is a benchmark, **not** a repeating timer — for that use `` `timer[ms] ``.

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
