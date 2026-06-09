# Language Reference

## Grammar

Nouns can be combined into an expression using verbs and adverbs.

Expressions are evaluated from right-to-left. There are no special priority rules for operators.


## Types `` ` `i`f`s`c`m`I`F`S`C`M`L ``
- Integer - numbers like `` -2 0 1 0N ``, type symbol `` `i ``.
- Float - floating point numbers `` 0.1 2. -3. 0n 0w -0w ``, type symbol `` `f ``.
- Symbol `` `s `` - Common nouns for names for tables or colors Ex. `` `id`Red100 ``
- Char `` `c `` - Single u8 character, Whitespace is interpreted as empty `" "`. Ex. `` "H" ``
- Integers `` `I `` - Vector of integers.
- Floats `` `F `` - Vector of floats.
- Symbols `` `S `` - Array of symbols.
- Chars `` `C `` - String of characters encoding text in `[]u8`.
- List `` `L `` - Empty list is written as `` ,() ``.
- List `` `L `` - Empty list is written as `` ,() ``.
- Table `` `M `` Ex. `` [[]a:1 2] ``
The types are organized in different classes.
- Atoms: Integer, Float, Symbol, Char;
- Vectors: Integers, Floats, Symbols, Chars;
- Mappings: Dict & Table

### Dict
Dict can be written with bracke t syntax `` [a:1:b:2] ``.
The dict operator `!` can pair 2 equal length array `` `a`b!1 2 ``.
A dict has the type symbol `` `m ``.

### Table `` `M ``
Dict can be written with bracket syntax `` [[]a:1 2;b:"ab"] ``.
A table can be created from a dict with thee following phrase `` +`a`b!(1 2;"ab") ``.
Constructing a table from mismatching length results in a length error.
A dict has the type symbol `` `M ``.

### Lambda
A lambdas is user defined function. They have their own local scope.
A lambda is written between curly backeds: `` { a+b*c } ``.
A lambda can have up to 8 arguments, arguments are either implicit in the lambda body or specified in the square bracked header `[]`.
A lambda can have up to 8 arguments.
A lambda's type symbol is `` `o ``.

### Partial `` `p ``
A partial is a variadic (operator or lambda) with only a certain arguments applied.

### Composition/Train `` `q ``
A compition is a sequence of variadics..

### Error `` `! ``

### Blank `` ` ``

Blanks can be used to  empty assignment and defining partials:
```k
a: / Blank assignment
p: +[;3]
```

## Nouns

## Verbs

### Assigment

#### Local Assign `` : ``

#### Global Assign `` :: ``

### Monadic Operators `:+-*!#@&|<>=?,^~$.`

#### Identity `:x`
Return right hand side

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

#### Ascend `<X`
Returns the indices that would sort X in ascending order.

#### Descend `>X`
Returns the indices that would sort X in descending order.

#### Group `=X`
For each distinct value, give me the indices where it occurs.

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

#### Right `x:y`
Return right hand side

#### Add `x+y`
Addition.

#### Sub `x-y`
Subtraction.

#### Mul `x*y`
Multiplication.

#### Div `x%y`
Division (integer divFloor for integers, float division for floats).

#### Modulo `x mod y`
Modulo operator, return remainder of x divided by y as integer

#### Integer division `x div y`
Return floor of x divided by y as integer

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

#### Pad `i$C`
Pads string y to length |x|.

#### Cast `x$y`
Casts y to type represented by symbol x.
String to int `` `I$"-12" `` --> `` -12 ``
String to float `` `F$"-12.3" `` --> `` -12.3 `` 

#### Parse `` `p@C ``
Parse ink, return AST ast list.

#### Find `x?y`
Returns first index of y in x (null if not found).

- `i?x` Roll/Deal): i random selections from x (positive: replacement, negative: unique).
- `s@x` (Unmarchal/Deserialize): supports csv, bin
- `s?x` (Marchal/Serialize): 
- `x@y` (At/Apply): Indices into x at y; Applies function x to y.
- `x.y` (Dot/ApplyN): Deep indexing or multi-argument function application.

#### Apply1 `x@y`

### IO Verbs

#### Read Line `` 0:x ``

#### Write Line `` x 0:y``

#### Read Byte `` 1:x ``

#### Write Byte `` x 1:y``

#### Open `<s`
Open file and return handle

#### Close `>s`
file handle

### Special Forms 
Some special symbols can be called with apply `s@` or call `s "Abc"` .
- Amend3 `` @[x;y;f]   amend  @["ABC";1;_:] -> "AbC"   @[2 3;1;{-x}] -> 2 -3 ``
- Amend4 `` @[x;y;F;z] amend  @["abc";1;:;"x"] -> "axc"   @[2 3;0;+;4] -> 6 3 ``
- Drill3
- Drill4


### Drill

```
.[x;y;f]   drill  .[("AB";"CD");1 0;_:] -> ("AB";"cD")
.[x;y;F;z] drill  .[("ab";"cd");1 0;:;"x"] -> ("ab";"xd")
```

## Adverbs
- Each `f'` - Apply f to each item (unary map). Ex, Length of each element in a list:  `` #'("abc";3 4 5 6) `` -> `` 3 4 ``
- Zip `x F'` - Apply rhs array elementwise on rhs dyad. Ex. Reshape each element in a character string:  `` 2 3#'"ab" `` -> `` ("aa";"bbb") ``
- Binsearch `X'` (NYI) - for each x, return its index in sorted X (or -1). `` 1 3 5 7 9'8 9 0 `` -> `` 3 4 -1 ``
- `F/` - Reduce list with F (left fold). Ex. `+/1 2 3` -> `6`
- Scan `F\` - Running fold (prefix results). Ex. `+\1 2 3 -> 1 3 6`
- Seeded Fold `x F/ /` - Reduce list with F starting with x. Ex. `` f:{x+y}; 10 f/1 2 3 ``, `` 10+/1 2 3 `` -> `` 16 ``
- Seeded Scan `x F\ \` - Running fold over F starting with x. `10+\1 2 3 -> 11 13 16`
- N-Do `i f/` - apply f repeatedly i times (iterate). Multiply 5 times the double function starting with 1 `` 5(2*)/1 `` -> `` 32 ``
- N-Dos `i f\` - list all intermediate results of i iterations. `` 5(2*)\1 -> 1 2 4 8 16 32 ``
- While `f f/` - apply f until condition fails (loop). `(1<){:[2!x;1+3*x;-2!x]}/3 -> 1`
- Whiles `f f\` - list all states while condition holds. `(1<){:[2!x;1+3*x;-2!x]}\3 -> 3 10 5 16 8 4 2 1`
- Converge `f/` - Iterate f until result stops changing. `` {1+1.0%x}/1 `` -> `` 1.618033988749895 ``
- Converges `f\` - list successive results until convergence. `(-2!)\100 -> 100 50 25 12 6 3 1 0`
- Join `C/` - join list with separator C. "ra"/("ab";"cadab";"") -> "abracadabra"
- Split `C\` - split data by separator C "ra"\"abracadabra" -> ("ab";"cadab";"")
- Decode `I/` - interpret digits in mixed base I → number 24 60 60/1 2 3 -> 3723   2/1 1 0 1 -> 13
- Encode `I\` - express number in mixed base I 24 60 60\3723 -> 1 2 3   2\13 -> 1 1 0 1
- Window `i'` - sliding windows of size i. `3':"abcdef" -> ("abc";"bcd";"cde";"def")`
- Stencil `i f'` - Apply f to each sliding window. `` 3{x,"."}'"abcde" `` -> `` ("abc.";"bcd.";"cde.") ``
- Eachprior `F'` - apply F between each item and its predecessor. `` -':12 13 11 17 14 -> 12 1 -2 6 -3 ``
- EachpriorSeeded `x F'` - like eachprior but starting with seed x. ` ': 10-':12 13 11 17 14 -> 2 1 -2 6 -3 `
- Eachright `x F/` - apply F with fixed right arg to each left item. ` 1 2*/:3 4 -> (3 6;4 8) `
- Eachleft `x F\` - apply F with fixed left arg to each right item. ` 1 2*\:3 4 -> (3 4;6 8) `
An adverb is written using any of these glyph(s) `` ' / \ ': /: \: ``.
Adverbs have a different meaning based on the type of the operands (Polysemic):
- `'` adverb can be Each, Zip
- `/`: Fold, Decode, Join
- `\`: Scan, Encode, Split
- `':`
- `/:`
- `\:` EachLeft
An adverb with only character or integer operands, the string utilities `C/` Join & `C\` Split, or the `I/` Decode & `I\` Encode, behave like verbs.
A digram is an adverb is written with 2 values on the left hand side: Zip `x F'`, N-Do `i f/`, N-Dos `i f\`.
## Special Symbols
- Arguments `` `argv[] `` - list of cmd line args (also in global variable x)
- Enviroment Variables `` `env[] `` - dict of env variables
- Random Number `` `prng[] ``
- Exit `` `exit@i ``
## Commands
A command always start at the beginning of a line with `\`.
### Time Command `\t:n expr`
The time elapsed milliseconds after n runs. The n is optional.
