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

---

## 7. Use-after-free: projection capturing a heap array, mapped with `'`

A projection (partial) that captures a **heap array value** (a vector, a list,
or a dict whose values include a list) and is then mapped with each (`'`)
corrupts memory. In Debug it surfaces as
`error(DebugAllocator): Allocation alignment 8 does not match free alignment 4`
(thousands of times for large captures). Results still print correctly, and
Release is clean (`c_allocator.free` ignores alignment/size), so it is a latent
use-after-free that the Debug allocator catches.

Minimal repro (1 line, Debug build) — exactly **one** alignment error:

```k
{[a;t] a+t}[(1.;1.)]'(0.1 0.2 0.3)
```

The captured `a` is a 2-element F vector. Variants that pin the trigger:
- capture a SCALAR → clean: `{[a;t] a+t}[5.]'((1.;1.);(2.;2.))`
- plain lambda each (no capture) → clean: `{[t] (1.;1.)*t}'(0.1 0.2 0.3)`
- capture a LIST → triggers: `{[lst;i] lst i}[((1.;1.);(2.;2.))]'(0 1 0)`
- capture a dict of I-vectors → clean; dict whose values are LISTS → triggers.
Error count scales with the captured array's size (e.g. capturing a face dict
that holds the 2030-element `glyf` list → ~10k errors), i.e. it fires while
freeing the captured value, but as a wrong-alignment free of a *recycled*
address — a stale pointer, not a plain double-free (std's `retain_metadata` +
`never_unmap` still reports alignment-mismatch, not double-free).

Stack traces: alloc = `promote.zig:49` (`promoteAs`, building the captured
literal) ← `doMakeList`; free = `partial.zig:20` (`p.args[i].deinit`) ←
`value.zig:64` union deinit ← `fntable.zig:32` (derived-function teardown).
The captured arg's buffer is freed at the wrong alignment because its address
was reused by an align-8 `N(V)` between a premature free and the partial's
teardown free. Refcounting in `doMakePartial`/`applyPartial`/`callLambdaAndRun`
*looks* balanced on inspection; refing the borrowed args in `applyPartial` did
NOT fix it. Needs an lldb watchpoint on the captured buffer to catch the
premature free. NOTE: `lib/font.k` is written to avoid this pattern entirely
(scalar/dict captures, `_`-cut splitting, vectorized arithmetic), so the font
outline path is clean — but the underlying VM bug remains.
