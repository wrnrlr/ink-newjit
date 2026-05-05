
### 6. Closures do not capture outer scope

**Severity:** High — higher-order functions broken

Nested lambdas return a function value of the correct type (`` `func ``) but applying it produces no result. The outer scope variable is not captured:

```k

adder: {[n]{x+n}}
add5: adder[5]
@add5   / → `func  (correct type)
add5 10 / → (no output, should be 15)
```

**Fix:** Lambda construction must snapshot captured variables from the enclosing scope into the closure value.

---

## Medium Severity Bugs

### 7. Window on strings returns list of single chars instead of strings

`src/primitive/adverb/window.zig` always creates `N(V)` (generic list) windows regardless of input type. For char vectors (`C`), each window should be a `C` (string):

```k
3':"abcde"   / → ("a" "b" "c";"b" "c" "d";"c" "d" "e")
             /   (expected ("abc";"bcd";"cde"))
```

Integer windows work correctly (`3':(1 2 3 4 5)` → `(1 2 3;2 3 4;3 4 5)`).

**Fix:** Mirror the type dispatch in `stencil.zig`'s `makeWindow` — use `N(u8)` and return `.C` for char input.

---

### 8. Function composition/train cannot be stored in a variable

Assigning a verb train to a variable results in type `` `! `` (error):

```k
h: *|
@h      / → `!  (expected `q or similar)
h 1 2 3 / → (no output, expected 3)
```

Inline trains work: `*|1 2 3` → `3`.

**Fix:** Ensure the compiler/VM correctly captures composed function values during assignment.

---

## Memory Issues

### 9. Split adverb leaks memory

`src/primitive/adverb/split.zig` leaks `charsFromSlice` allocations per the DebugAllocator:

```
error(DebugAllocator): memory address 0x... leaked:
    split.zig:23 and split.zig:30
```

Each `C\` call leaks the string parts. The list container is returned but the parts' backing buffers are not tracked by the ref-count system.

---

## Minor Issues

### 10. `$0W` displays as integer max value

`$0W` prints `2147483647` instead of `0W`. Compare: `$0N` → `0N`, `$0w` → `0w` (correct).

### 11. Stencil syntax in reference documentation

The reference shows `3{f}':"abcde"` but the `':` adverb dispatches to eachprior, not stencil. The working stencil syntax is `3{f}'("abcde")` or `{f}'[3;"abcde"]`. Update the reference to use `3{x,"."}'("abcde")`.

---

## Bug in test/trend.k

The `ma` function in `test/trend.k` has a double-indexing bug — `begin` and `end` hold prefix-sum values, not indices, so `s[begin]` and `s[end]` try to index with float vectors and return `` `!type ``:

```k
/ BUG — begin/end are values, not indices; s[begin] fails
begin: s[w+!nn];
end: s[!nn]
((w-1)#0.0),-1_(s[begin]-s[end])%w
```

The correct form (used in `momentum.k` and `arbitrage.k`) is:

```k
((w-1)#0.0),-1_(s[w+!nn]-s[!nn])%w
```

---

## What Works Correctly

| Feature | Status |
|---------|--------|
| Integer/float/char/symbol/bool literals | ✓ |
| Null values (`0N`, `0n`, `0w`, `-0w`) | ✓ |
| All monadic verbs (`+ - * ! # @ & \| < > = ? , ^ ~ $`) | ✓ |
| Arithmetic `+ - *` (with spaces or variable operands) | ✓ |
| Comparison `< > =`, Match `~`, Not `~` | ✓ |
| Dict creation `x!y`, access, values, keys, tally | ✓ |
| Dict take-keys, drop-key, merge | ✓ |
| Table creation (`+dict`), tally | ✓ |
| Drop `i_Y`, Cut `I_Y`, WeedOut (boolean), Delete `X_i` | ✓ |
| Join `,`, Take `#`, Reshape `I#y`, Fill `^`, Without `X^y` | ✓ |
| Pad `i$C`, Cast `s$y`, Find `?` | ✓ |
| Amend `@[x;y;f]` and `@[x;y;F;z]` | ✓ |
| Conditional `$[b;t;f]` | ✓ |
| Fold `F/`, Scan `F\`, Seeded fold/scan | ✓ |
| N-Do `n f/`, N-Dos `n f\` | ✓ |
| Each1 `f'`, Each2 `x f'` | ✓ |
| EachPrior `F':`, seeded eachprior | ✓ |
| EachRight `x F/:`, EachLeft `x F\:` | ✓ |
| Window `n':X` (integers/floats) | ✓ |
| Stencil `n{f}'X` | ✓ |
| Join `C/`, Split `C\` (functional, memory leak) | ✓/⚠ |
| Decode `I/`, Encode `I\` | ✓ |
| Lambdas with explicit args, partial application | ✓ |
| Math functions (`sqrt`, `abs`, `log`, `exp`, `sin`, `cos`) | ✓ |
| String formatting `$x`, type `@x` | ✓ |
| IO (`0:`, `1:`) | ✓ |
| Null propagation at runtime (non-constant-folded expressions) | ✓ |
