# Language Reference

## Grammar

## Types

The types are organized in different classes:
- Atoms: 
- Scalars: singular numeric types
- Vectors: 
- Mappings: the associative types Dict & Table

### Integer `` `i ``
Signed hole numbers, writen as arabic numerals, `-2 0 1`, null value `0N`.

### Float `` `f ``
Floating point number, null value `0n`, plus/minus infinity `-0w 0w`

### Symbol `` `s ``
Common nouns. Blank symbols are written with single backquote `` ` ``.

### Char `` `c ``
Character encoded in `u8`. Whitespace is interpreted as empty `" "`.

### Integers `` `I ``
Vector of integers.

### Floats `` `F ``
Vector of floats.

### Symbols `` `S ``
Array of symbols.
Array of 3 Symbols `` `a`b`c ``.
Array of 3 empty symbols `` ``` ``.

### Chars `` `C ``
String of characters encoding text in `[]u8`. Empty quoted string is interpreted as empty char `""`.

### List `` `L ``
Empty list is written as `` ,() ``.

### Dict `` `m ``
Dict can be written with bracket syntax `` [a:1:b:2] `` or
using the dict operator to pair 2 equal length array `` `a`b!1 2 ``.

### Table `` `M ``

### Lambda `` `o ``
User defined function. 

### Partial `` `p ``

### 

### Error `` `! ``

### Blank `` ` ``

Blanks can be used to  empty assignment and defining partials:
```k
a: / Blank assignment
p: +[;3]
```

## Nouns

## Verbs

### Monadic Operators `+-*!#@&|<>=?,^~$.`

#### Flip `+x`
Transpose (flip rows/columns).
Row vector becomes column `` +(1 2 3;4 5 6) `` --> `` (1 4;2 5;3 6) ``
Table to Dict-of-Lists (and vice versa) `` +[[]n:`b`c;i:2 3] `` --> `` [n:`b`c;i:2 3] ``
`` +("abc";1;1 2 3 4) `` --> `` !length ``

#### Negate `-x`
Numeric negation.

#### First `*x`
Returns the first item of its argument.

#### Iota `!i`
Generates a list of consecutive integers starting at 0 up to i-1.

#### Odometer `!I`
For an integer list I, produces Cartesian product indices.

#### Tally `#x`
Returns the number of elements.

#### Type `@x`
Returns the symbol representing the type of x (e.g. \`i, \`F, \`v).

#### Where `&I`
Converts a list of counts into repeated indices.

#### Reverse `|x`
Returns x with its elements in reverse order.

#### Open `<s`
ile and return handle

#### Ascend `<X`
Returns the indices that would sort X in ascending order.

#### Close `<s`
ile handle

#### Descend `>X`
Returns the indices that would sort X in descending order.

#### Group `=X`
Returns index lists for unique values in X.

#### Unit `=i`
Identity matrix.

#### Distinct `?X`
Returns the distinct elements of X in order.

#### Uniform `?i`
Returns i random floats in [0,1).

#### Enlist `,x`
Wraps x in a list (increases rank).

#### Null `^x`
Returns a boolean mask indicating null/missing elements.

#### Not `~x`
Logical negation (returns 1 for 0/nulls, 0 otherwise).

#### String `$x`
Returns the string representation of x.

- `.x` Values/Get: Extracts dictionary values; Retrieves global symbol value.
- `sqrt n`
- `sqr n`
- `log n`
- `exp n`
- `sin n`
- `cos n`
- `abs n`

### Dyadic Operators

#### Add `x+y`
Addition.

#### Sub `x-y`
Subtraction.

#### Mul `x*y`
Multiplication.

#### Div `x%y`
Division (integer divFloor for integers, float division for floats).

#### Key `x!y`
Dictionary creation.

#### Equal `x=y`
Elementwise equality comparison.

#### Match `x~y`
Identity check (same type and value).

#### Drop `i_Y`
Drops i items from the start (positive i) or end (negative i).

#### Drop `X_d`
eys: Removes keys X from dictionary d.

#### Cut `I_Y`
Slices Y at indices I.

#### WeedOut `f_Y`
Removes elements where boolean vector f is 1.

#### Delete `X_i`
Removes element at index i from list X.

#### Join `x,y`
Joins atoms/lists into a list; Merges dictionaries (right-side precedence).

#### Take `x#y`
Resizes/cycles list y to length |x|.

#### TakeKeys `X#d`
Filters dictionary d for keys in X.

#### Reshape `I#y`
Filters dictionary d for keys in X.

#### Fill `x^y`
Replaces nulls in y with x.

#### Without `X^y`
Removes occurrences of elements in X from list y.

#### Pad `x$y`
Pads string y to length |x|.

#### Cast `x$y`
Casts y to type represented by symbol x.
String to int `` `I$"-12" `` --> `` -12 ``
String to float `` `F$"-12.3" `` --> `` -12.3 `` 

#### Find `x?y`
Returns first index of y in x (null if not found).

- `i?x` Roll/Deal): i random selections from x (positive: replacement, negative: unique).
- `s@x` (Unmarchal/Deserialize): supports csv, bin
- `s?x` (Marchal/Serialize): 
- `x@y` (At/Apply): Indices into x at y; Applies function x to y.
- `x.y` (Dot/ApplyN): Deep indexing or multi-argument function application.

## Amend 

## Drill

## Adverbs `` ' / \ ': /: \: ``

### Each `f'`
Apply f to each item (unary map)
Ex, Length of each element in a list:  `` #'("abc";3 4 5 6) `` -> `` 3 4 ``

### Zip (each2) `x F'`
Apply rhs array elementwise on rhs dyad.
Ex. Reshape each element in a list:  `` 2 3#'"ab" `` -> `` ("aa";"bbb") ``

### binsearch `X'` (NYI)
for each x, return its index in sorted X (or -1)
1 3 5 7 9'8 9 0 -> 3 4 -1

### Fold `F/`
Reduce list with F (left fold)
Ex. `+/1 2 3` -> `6`

### Scan `F\`
Running fold (prefix results)
`+\1 2 3 -> 1 3 6`

### Seeded Fold `x F/ /`
Fold with initial seed x
`10+/1 2 3 -> 16`

### Seeded Scan `x F\ \`
Scan with initial seed x
`10+\1 2 3 -> 11 13 16`

### N-Do i f/
apply f repeatedly i times (iterate)
`5(2*)/1 -> 32`

### N-Dos i f\
list all intermediate results of i iterations
5(2*)\1 -> 1 2 4 8 16 32

### While `f f/`
apply f until condition fails (loop)
`(1<){:[2!x;1+3*x;-2!x]}/3 -> 1`

### Whiles `f f\`
list all states while condition holds
`(1<){:[2!x;1+3*x;-2!x]}\3 -> 3 10 5 16 8 4 2 1`

### Converge `f/`
Iterate f until result stops changing
`` ~{1+1.0%x}/1 `` -> `` 1.618033988749895 ``

### Converges `f\`
list successive results until convergence
`(-2!)\100 -> 100 50 25 12 6 3 1 0`

### Join `C/`
join list with separator C
"ra"/("ab";"cadab";"") -> "abracadabra"

### split `C\`
split data by separator C
"ra"\"abracadabra" -> ("ab";"cadab";"")

### decode `I/`
interpret digits in mixed base I → number
24 60 60/1 2 3 -> 3723   2/1 1 0 1 -> 13

### encode `I\`
express number in mixed base I
24 60 60\3723 -> 1 2 3   2\13 -> 1 1 0 1

### Window `i'`
sliding windows of size i
`3':"abcdef" -> ("abc";"bcd";"cde";"def")`

### Stencil `i f'`
Apply f to each sliding window
`3{x,"."}':"abcde" -> ("abc.";"bcd.";"cde.")`

### Eachprior `F'`
apply F between each item and its predecessor
-':12 13 11 17 14 -> 12 1 -2 6 -3

### EachpriorSeeded `x F'`
like eachprior but starting with seed x
` ': 10-':12 13 11 17 14 -> 2 1 -2 6 -3 `

### Eachright `x F/`
apply F with fixed right arg to each left item
` 1 2*/:3 4 -> (3 6;4 8) `

### Eachleft `x F\`
apply F with fixed left arg to each right item
` 1 2*\:3 4 -> (3 4;6 8) `

## Special Symbols

 ### Arguments `` `argv[] ``
 list of cmd line args (also in global variable x)

 ### Enviroment Variables `` `env[] ``
 dict of env variables

 ### Random Number `` `prng[] ``
 The `` `prng@I `` get/set pseudo-random number generator internal state
 
                      s:`prng[];r:9?0;`prng s;r~9?0 -> 1
         `prng@0 use current time to set state
 `exit@i exit
 