# Ink Language Reference

## Grammar

### Lexical Grammar

### Syntactical Grammar
Nouns can be combined into expressions using verbs and adverbs.
Expressions are evaluated right-to-left. There are no special precedence rules for operators.

## Datetypes

### Scalar types
- **Natural numbers** (no syntax support yet)
- **Integer** - numbers like `-2 0 1`, null `0N`, infinities `-0W 0W`, type `` `i ``, 32bit signed int.
- **Float** - floating point numbers `0.1 2. -3.`, null `0n`, infinities `0w -0w`, type `` `f ``, 32bit float
- **Symbol** - interned string, e.g. `` `px ``, null/empty `` ` ``, type `` `s ``
- **Char** - a single character, eg `"H"`, null `" "`, type `` `c ``, u8 char

### Vector types
- **Integers** - array of integers, null `` &0 ``, type `` `I ``
- **Floats** - array of floats, null `` 0#0.0 ``, type `` `F ``
- **Symbols** - array of symbols, empty value `` 0#` ``, type `` `S ``
- **Chars** - array of characters, null `""`, type `` `C ``
  - type symbol `` `C ``
  - empty value `` "" ``
  - backed by an array of u8.

### Other types
- **List** - heterogeneous list; empty list is `` ,() ``, type symbol `` `L ``.
- **Dict**
  - The syntax `` [a:1; b:2; c: 3] `` is equivalent to `` `a`b`c!1 2 3 ``
  - Empty dict `` [] ``
  - Type symbol `` `m ``
- **Table**
  - The syntax `` [[]a:1 2; b:3 4] `` is equivalent to `` `a`b`c!1 2 3 ``
  - Type symbol `` `M ``.
- **Lambda** - a user-defined function, eg `{ a+b*c }`, type `` `o ``
- **Partial** - partialy applied operator/lambda, type `` `p ``

### Composition/Train `` `q ``
A composition is a sequence of variadics applied in succession.

### Error `` `! ``
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

### Arithmetic Verbs `-+*% mod div`
- `-x` **Negate** - numeric negation
- `x+y` **Add** - sum of x and y
- `x-y` **Sub** - difference between x from y
- `x*y` **Mul** - product of x and y
- `x%y` **Div** - divFloor for integers, float division for floats
- `x mod y` **Modulo** - remainder of x÷y (integer)
- `x div y` **Integer division** - floor(x÷y)

### Logic Verbs `~=|&`
- `~x` **Not** - logical negation
- `x=y` **Equal** - elementwise equality
- `x|y` **Max/Or** - maximum value of x or y
- `x&y` **Min/And** - minimum value of x and y

### Monadic Operators `:+-*!#@&|<>=?,^~$.`
- `:x` **Identity** - return right-hand side
- `+x` **Flip** - transpose. `` +(1 2 3;4 5 6) `` → `` (1 4;2 5;3 6) ``
- `+d` **Pivot** - table to dict-of-lists and vice versa. `` +[[]n:`b`c;i:2 3] `` → `` [n:`b`c;i:2 3] ``
- `*x` **First** - first item
- `!i` **Iota** - integers 0..i-1
- `!I` **Odometer** - Cartesian product indices for an integer list
- `#x` **Tally** - number of elements
- `@x` **Type** - type symbol (e.g. `` `i ``, `` `F ``)
- `&I` **Where** - convert counts to repeated indices
- `|x` **Reverse** - elements in reverse order
- `<X` **Ascend** - indices that sort X ascending
- `>X` **Descend** - indices that sort X descending
- `=X` **Group** - for each distinct value, the indices where it occurs
- `=i` **Unit** - identity matrix
- `?X` **Distinct** - distinct elements in order
- `?i` **Uniform** - i random floats in [0,1)
- `,x` **Enlist** - wrap x in a list
- `^x` **Null** - boolean mask of null/missing elements
- `$x` **String** - string representation
- **Value/Get** `.x` - extract dictionary values; retrieve global by symbol name
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
- Find `x?y` - first index of y in x (`#x` / length if not found, for index-with-fallback)
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
  - `` 1: `stdin `` reads up to 64 KiB of available bytes from stdin (blocks for ≥1 byte); returns `""` at EOF. Partial by design — frame/buffer in k. For byte-stream protocols (LSP/Jupyter).
- Write bytes `` x 1: y ``
  - `` `stdout 1: y `` / `` `stderr 1: y `` write raw bytes with **no** trailing newline and flush (unlike `` `0 0:y `` which appends `\n`).
- Load code `` 2: y `` used for importing other files

### Special Forms
- `` @[x;y;f] `` **Amend3** - `` @["ABC";1;_:] `` → `"AbC"`
- `` @[x;y;F;z] `` **Amend4** - `` @["abc";1;:;"x"] `` → `"axc"`
- `` .[x;y;f] `` **Drill3** - `` .[("AB";"CD");1 0;_:] `` → `("AB";"cD")`
- `` .[x;y;F;z] `` **Drill4** - `` .[("ab";"cd");1 0;:;"x"] `` → `("ab";"xd")`
- `` ?[C;I;C] `` **Splice** - `` ?["abcd";1 3;"xyz"] -> "axyzd" ``

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
Some adverbs are digrams, like While `f f/` and Stencil `i f'`, they have 2 left-hand arguments.

## Tables, Queries & Joins
- Create table `` [[]id:1 2 3; age:20 43 7] ``
- Created keyes table `` [[]id:1 2 3; age:20 43 7] ``

## Special Symbols
- Arguments `` `argv[] `` - list of cmd-line args (also in global `x`)
- Environment variables `` `env[] `` - dict of env variables
- Random number `` `prng[] ``
- Inverse trig `` `asin@x ``, `` `acos@x ``, `` `atan@x `` (element-wise over F vectors), `` `atan2@(y;x) `` (broadcasts scalar⊕vector) — no verb glyph, added for equirectangular UV mapping (see `test/earth.k`)
- Exit `` `exit@i ``

## Native Extension
Ink supports writing native extensions based on a FFI.

## Commands
A command always starts at the beginning of a line with `\`.

### Time Command `\t:n expr`
Time elapsed in milliseconds after n runs (n is optional).
