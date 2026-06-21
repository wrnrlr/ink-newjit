# Issues

## 1. `$0W` displays as integer max value

`$0W` prints `2147483647` instead of `0W`. Compare: `$0N` → `0N`, `$0w` → `0w` (correct).

---

## 2. Bug in test/trend.k

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

## 3. Long for-each breaks ink+rlwrap

```
  \t {x*3}'!100000000
```

---

## 4. Integer parsing bug

```k-repl
 `I$"10000000000"
0N
```

---

## 5. DebugAllocator alignment mismatch when building list values

Compiling a SPIR-V shader (`FragmentShader[...]` in `lib/spirv.k`) prints
several `DebugAllocator: Allocation alignment 8 does not match free alignment 4`
warnings on teardown. Reproduces with shader source using *only* plain list
syntax (no vector literals), so it is unrelated to the parser/compiler.

Traces point at `promote`/`promoteAs` (`src/primitive/promote.zig`) and
`V.Values`/`N(V).n1` via `doMakeList` (`src/runtime/vm.zig:573-577`): a value
array is allocated at alignment 8 (the `Rc`/pointer alignment for `N(V)`) but
freed through a path that computes alignment 4. Debug-build only; output is
still correct. Likely a mismatch between `alignedAlloc` alignment and the
`alignment` used in `N(T).deinit`'s `free`.

---

## 6. Index-assign into a dict crashes (stack underflow)

```k-repl
 d:[a:1]
 d[`b]:2
thread panic: integer overflow  (vm.zig pop on empty stack)
```

Amend-assigning a dict element via `d[`k]:v` leaves no value on the stack, so
the final `interpret` pop underflows. Reproduces on any dict (empty or not), so
it is unrelated to the empty-dict literal fix. Likely the bracket-index
assignment path does not push its result.
