# Issues

## Minor Issues

### 1. `$0W` displays as integer max value

`$0W` prints `2147483647` instead of `0W`. Compare: `$0N` → `0N`, `$0w` → `0w` (correct).

### 2. Stencil syntax in reference documentation

The reference shows `3{f}':"abcde"` but the `':` adverb dispatches to eachprior, not stencil. The working stencil syntax is `3{f}'("abcde")` or `{f}'[3;"abcde"]`. Update the reference to use `3{x,"."}'("abcde")`.

### 3. `Op` enum insertion breaks JIT stencil scanner

Adding a new member to the `Op` enum anywhere except the end causes an illegal instruction crash in JIT-compiled lambdas.

**Root cause:** The JIT stencil scanner (`stencils.zig`) identifies NEXT and OPERAND holes by scanning the machine code of stencil functions for specific byte patterns (e.g. `MOVZ X8, #0` = `0xD2800008`). The stencil functions (`stencilApply2`, etc.) call handler functions via BL or BLR. When `Op.COUNT` increases, the compile-time `monad_table` and `dyad_table` arrays grow, shifting global symbol addresses in the binary. If handler addresses shift relative to JIT memory, the stencil scanner finds pattern matches at wrong offsets and patches incorrect bytes — producing illegal instructions at runtime.

**Observed failure:** Inserting `exec` between `parse` and `@"0:"` in the `Op` enum caused all demos that use `each` with a JIT-compiled lambda to crash with `SIGABRT` / illegal instruction on the first call from `each.zig:53`.

**Current workaround:** New ops must be appended at the end of the `Op` enum, after `@":"`, so existing integer values stay stable.

**Needed fix:** The stencil scanner should be made robust against symbol layout changes. Options:
- Use explicit `comptime` offsets or marker values (e.g. a sentinel instruction only used as a hole) instead of scanning for patterns that could occur elsewhere in the binary.
- Add a comptime assertion that verifies the scanned hole offsets match expected positions in each stencil function.
- Consider a non-scanning approach: encode hole locations as explicit offsets in a parallel comptime table, computed from the `asm volatile` instruction positions.

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
