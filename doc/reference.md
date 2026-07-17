# Ink Language Reference

## Grammar

### Lexical Grammar

Source is tokenized into literals, names, operators, adverbs, delimiters and
comments. The literal grammar in EBNF:

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
int   §= [ sign ] , ( "0" , ( "x" | "X" ) , hex , { hex }
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
(* exception: a backtick directly followed by `<digit> ":"` is the blank symbol
   `` ` `` plus the io verb `<digit>:`, not a digit-named symbol — so `` `0:"hi" ``
   is (blank) 0: "hi", i.e. write to stdout. *)
name   = letter , { letter | digit } ,
         { "." , letter , { letter | digit } } ;
```

Four tokenizer behaviors the grammar above can't fully express:

- **`sign`** attaches as a negative literal only when the `-` isn't glued to a
  preceding noun: `abs -3` → negative `-3`, but `abs-3` → dyadic subtract
  (`abs` minus `3`). Matches ngn/k, where `cos -3` works but `cos-3` errors.
- **`stringchar`** follows the K doubling convention — an interior `"` is
  content unless the next character is whitespace, a bracket, an operator glyph
  or a digit, so `"""` is a 1-char string holding `"`. A `"` immediately
  followed by a newline opens a multi-line string that runs to its closing `"`.
- A **char** is a single-character like `"H"` is atom, not a string.
- **`symbol`** joins only `letter | digit | "."` in its unquoted body; an
  operator glyph ends it (`` `~ `` is the null symbol `` ` `` then Match `~`).
  Quote the body to include glyphs: `` `"+" ``, `` `"<=" ``.
- **`name`** extends across a `.` only when the dot is followed by a letter —
  `a.b` is one name, but `a.1` and `a. b` keep `.` as the Apply/index operator.
  `_` is never part of a name (it is always the Drop/Cut/Delete primitive).

Comments: a `/` preceded by whitespace (or starting a line) runs to end of line.
A line containing only `/` opens a block comment that runs until a line
containing only `\`. Newlines and `;` are statement separators (`sep`).

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

### Monadic Operators `:%+-*!#@&|<>=?,^~$.`
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
- `` 9: x `` **Place** — upload x to the GPU; returns a placed-array descriptor dict `[gpu:handle;t;n;s]` (`s` = `%x`, the shape; nested rectangular input flattens for upload). A TABLE places as a structured buffer — one resident buffer per column (`gpu.holdT`, kk2 §2.5) — and `8:` reassembles it. The device is an io channel: work recorded on placed arrays only submits at the `8:` sync point. Requires `lib/gpu.k` (else `!io`). NB `f 9: x` after a NAME parses the verb as dyadic — write `f[9: x]`. See `doc/design/kk.md` §1.
- `` d 9: x `` **PlaceInto** — overwrite placement `d`'s buffer in place (no realloc); returns `d`
- `` 8: d `` **Fetch** — sync + read a placed array back to the host, reshaped to its `s`; a `tbl` descriptor reads every column and rebuilds the table
- `` n 8: d `` **FetchN** — first n elements (trims the ×64 dispatch padding)

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
- Inverse trig `` `asin@x ``, `` `acos@x ``, `` `atan@x `` (element-wise over F vectors), `` `atan2@(y;x) `` (broadcasts scalar⊕vector) — no verb glyph, added for equirectangular UV mapping (see `demo/earth.k`)
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

### Crypto Library
Thin bindings over Zig's `std.crypto` (`lib/crypto.k`, build `zig build crypto`).
Everything is bytes (C vectors), so primitives compose.
- Hashes: `crypto.md5` `sha1` `sha224` `sha256` `sha384` `sha512` `sha3256`
  `sha3512` `blake2b` `blake2b512` `blake3` — `msg → raw digest`
- MAC: `crypto.hmac[key;msg]` (SHA-256), `crypto.hmac512[key;msg]`
- KDF: `crypto.hkdf[salt;ikm;info]` (SHA-256), `crypto.hkdf512[…]`,
  `crypto.pbkdf2[password;salt;rounds]`
- AEAD (encrypt → `ct||tag`, decrypt → plaintext or error `'`):
  `crypto.encrypt`/`decrypt` (XChaCha20-Poly1305, key 32 / nonce 24),
  `crypto.aesEncrypt`/`aesDecrypt` (AES-256-GCM, key 32 / nonce 12)
- Ed25519: `crypto.keypair seed(32) → pub(32)||secret(64)`,
  `crypto.sign[secret;msg]`, `crypto.verify[public;sig;msg]`
- X25519: `crypto.x25519pub secret(32)`, `crypto.x25519[secret;public] → shared`
- Random & encoding: `crypto.random n`, `crypto.hex`/`unhex`, `crypto.b64`/`unb64`,
  `crypto.equal[a;b]` (constant-time)

### Compression Library
DEFLATE over Zig's `std.compress.flate` (`lib/compress.k`, build `zig build compress`).
Bytes in, bytes out; decompressors return an error `'` on corrupt input.
- `compress.deflate`/`inflate` — raw DEFLATE
- `compress.gzip`/`gunzip` — gzip container (RFC 1952)
- `compress.zlib`/`unzlib` — zlib container (RFC 1950)
- `compress.crc32 bytes`, `compress.adler32 bytes` — i32 checksums

ZIP archives via `std.zip` + flate (`lib/zip.k`, build `zig build zip`).
Store + deflate, non-encrypted, non-zip64.
- `zip.list "a.zip"` → table `[name;size;csize;method;crc]`
- `zip.read "a.zip"` → dict name→decompressed bytes
- `zip.entry["a.zip"; name]` → one entry's bytes (error if absent)
- `zip.write["out.zip"; names; datas]` → create archive → `1b`

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

### Text Processing
- `regex`

### Graphics Library
Ink's GPU stack is three layers that load on demand:
`lib/gpu.k` (the native `libgpu.dylib` bindings — raw Vulkan via MoltenVK), `lib/dye.k`
(the **dye** shader compiler that turns ink lambdas into SPIR-V, backed by the
pure instruction stencils in `lib/spirv.k`), and a set of higher-level helpers
(`camera.k`, `pbr.k`, `font.k`, `color.k`).

#### Window & event loop (`lib/gpu.k`)
- `window.run[loop; cfg]` — open a window and call `loop[props]` every frame
  (blocking). `props` is a dict: `` `width`height`mx`my`time `` plus `` `events ``,
  a **table** of input events since the last frame. Event columns: `kind`
  (`` `text`key`mouse`scroll ``), `code`, `mods` (1=shift 2=ctrl 4=alt 8=super),
  `down` (1=press/0=release), `x`/`y`, `amt` (scroll delta). Track held keys
  yourself (see `camera.k`). Unused cells are nulls — filter them.
- `gpu.computeRun[fn]` — headless one-shot: create a device, call `fn` once, tear
  it down. Stash results in a global from inside `fn`.

#### 2D drawing
- `gpu.fill[verts; frag]` — draw triangles with the built-in shader. `verts` is a
  flat `F` of `[x,y,u,v]` per vertex; `frag` is a 44-float uniform block.
- `gpu.solid[r;g;b;a]` — build a solid-color `frag` block (channels in `[0,1]`).
- `gpu.tessellate[pts]` — triangulate a polygon `F` to a vertex buffer (NaN x/y
  pairs separate contours to cut holes).

#### Meshes & 3D
- `mesh.compile[vtx; frg]` — compile a vertex+fragment SPIR-V pair into a
  pipeline; the vertex stride is derived from the shader's declared inputs.
- `mesh.draw[verts; h]`, `mesh.drawU[verts; h; uni]` (per-draw uniform block, 8
  vec4 slots).
- `mesh.upload[verts; h]` → persistent geometry buffer; then `mesh.drawGeomT`
  draws it with uniform+textures without re-uploading.
- `mesh.compilePull[vtx; frg]` / `mesh.drawPull[pipe; bufs; count]` — vertex
  pulling: the vertex shader (`shader.vertexPull`) reads resident storage
  buffers by `gl_VertexIndex`; instancing is an index computation
  (`inst: floor[vid % NV]`, see `demo/scene.k`).
- `lib/pbr.k` — a physically-based `pbrVtx` / `PbrFragment` shader pair;
  `lib/camera.k` — orbit camera (`CamNew`, `CamUpdate[c;props]`) folding one
  frame of input into a camera-state dict (WASD pan, scroll zoom, right-drag
  rotate/tilt).

#### Textures
- `texture.upload[img]` — upload an image dict (`` `width`height`comp`data ``,
  e.g. from `image.read`) as a sampled GPU texture. In a fragment shader,
  `sample[k; uv]` reads texture `k` (see `shader.fragmentTexN`).

#### Compute
- `gpu.runShader[spirv; in]` / `gpu.runShader2[spirv; in1; in2]` — one-shot
  compute with host round-trip.
- Resident buffers keep data on the GPU across dispatches (iterative solvers):
  `gpu.buffer[F]` → handle, `gpu.write[buf; F]`, `gpu.read[buf]` / `gpu.readI`,
  `gpu.uniform[vec4]`.
- `gpu.compileCompute[spirv; nbind]` / `gpu.compileComputeU[spirv; nStorage]`
  cache a pipeline; `gpu.dispatch[pipe; bufs; nThreads]` runs it with no
  readback. `gpu.dispatchLoop[pipe; bufsA; bufsB; nThreads; reps]` batches N
  ping-pong passes into a single encoder (Jacobi / red-black SOR).

#### The dye shader compiler (`lib/dye.k`)
`dye` compiles ink lambdas to SPIR-V word lists (int lists) you feed to the
pipeline builders above. Types are symbols like `` `f32`v3`v4 ``.
- **Fragment:** `shader.fragment[ioTypes; fn]`, `shader.fragmentTex[ioTypes; fn]`
  / `shader.fragmentTexN[ioTypes; nTex; fn]` (sampled textures). All paths compile
  through the neutral IR and const-fold + DCE when `xOpt=1` (the default).
- **Vertex:** `shader.vertex[inTypes; varyTypes; fn]`,
  `shader.vertexU[…; uniNames; fn]` (with a uniform block),
  `shader.vertexPull[varyTypes; fn]` (pulled: buffers + `gl_VertexIndex`).
- **Compute:** `shader.kernel[fn]` — the general kernel with the binding table
  INFERRED from the lambda (params fed to `scatterAdd`/`iget`/`iset` are i32
  accumulators and must come first; the LAST param is the thread index; the
  rest are f32 buffers). `gpu.pipeline[fn]` compiles lambda → SPIR-V → cached
  pipeline in one call. Explicit forms remain: `gpu.kernel[fn;nAcc;nBuf]`,
  `shader.compute` / `shader.computeU` / `shader.compute2`.
- **Stencil/scatter kernels:** `shader.stencil` / `shader.stencilU` /
  `shader.stencilIP` and `shader.scatter` — buffer-gather + in-kernel bounded
  loops for GPU-resident numerics (the basis of `lib/nn.k`).

- **CPU backend (`lib/bits.k`):** `bits.run[fn; nAcc; nBuf; bufs; count]` runs the
  SAME kernel lambda on the CPU by interpreting dye's neutral IR node-for-node
  (returns the mutated buffer list). One source, two lowerings — the basis of the
  `test/kkbits.k` cross-backend oracle (bits CPU vs `gpu.kernel` GPU). v1 covers the
  scalar compute subset (elementwise/select/gather + `rsum`/`rmax`/`ndo`/`whileL`).

The shader dialect adds vector literals, monadic math names, and `<=`/`>=`
peephole support on top of ink; extra GPU builtins include `pow min max dot
cross step mod clamp mix smoothstep floor fract sign tanh length normalize`.
A name that is not a param or local resolves to the HOST global's current
numeric-scalar value, baked in as a constant at kernel-compile time
(recompile to pick up changes; unknown names warn and bake NaN).
Gotchas: `|` is logical-or (not max) in shaders — use `max[0.;x]` for ReLU;
there is no `>=`, use `~(a<b)`. See `doc/design/dye.md` and `doc/design/kk.md`.

#### Fonts & color
- `lib/font.k` — native sfnt reader. `font.read "path"` → list of face dicts
  (keyed by table name). `font.scale[f;sz]`, `font.metrics[f;sz]`,
  `font.glyph[f;cp]` (codepoint → gid), `font.shape[f;s]` (string → gids),
  `font.outline[f;gid;sz]` / `font.outlines` → flat `F` contours to tessellate,
  `font.family`/`subfamily`/`fullName`.
- `lib/color.k` — `hsl2rgb`, `pct2rgb`, and the full OKLCH Tailwind palette as
  named constants (`Red500`, `Amber300`, …), each an `[r,g,b,a]` vector.

### Network Library
HTTP client over Zig's `std.http.Client` (`lib/http.k`, build `zig build http`).
For web/JSON APIs: https (TLS), redirects and gzip/deflate/zstd response
decompression are automatic.  Every call returns a dict `[status; headers; body]`
(`status` i, `headers` dict of lowercased name→value, `body` C) or an error `'`
if the request could not be completed.
- `http.get url`, `http.del url`, `http.head url`
- `http.post[url; body]`, `http.put[url; body]`, `http.patch[url; body]`
  (default `content-type: application/json`)
- `http.request[method; url; headers; body]` — headers are flat C name/value
  pairs `("accept";"application/json";…)`; `http.raw (method;url;headers;body)`
  is the underlying primitive
- Decode a JSON response with `json.parse r`body`
- Streaming: `http.stream[method; url; headers; body; {[line]…}]` calls the
  callback with each response line (newline stripped) as it arrives and returns
  `[status; headers]`.  Used for Server-Sent Events / LLM token streams.

### LLM Library
Chat + streaming for Anthropic and xAI (Grok) over the http + json modules
(`lib/llm.k`, pure k — no build step).  Keys come from the environment
(`ANTHROPIC_API_KEY`, `XAI_API_KEY`).  Streaming is built in: `llm.ask` prints
tokens live as they arrive and returns the full assistant text.
- `llm.anthropic model` / `llm.grok model` → a provider config dict
- `llm.ask[cfg; prompt]` — one-shot; streams live, returns the text
- `llm.turn[cfg; history; text]` (alias `llm.say`) — multi-turn; returns the
  history extended with the user + assistant turns (start from `()`)
- `llm.stream[cfg; messages]` — lower level; `messages` is a list of
  `[role;content]` dicts (`llm.msg[role;text]`)
- Agent (buffered tool-use loop, both providers): `llm.agent[cfg; tools; task]`.
  A tool is `llm.tool[name; desc; params; fn]` where `params` is a JSON-schema
  object (`llm.obj[properties; required]`, `llm.prop[type; desc]`) and `fn` is a
  k lambda `inputDict → resultString`.  The loop runs the model, dispatches any
  tool calls to your `fn`s, feeds results back, and returns the final text.
  `json.list` (a non-columnarising `json.parse`) makes the response arrays
  navigate as lists.
