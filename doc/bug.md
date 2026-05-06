# Issues

## 1. `$0W` displays as integer max value

`$0W` prints `2147483647` instead of `0W`. Compare: `$0N` → `0N`, `$0w` → `0w` (correct).

---

## 2. `Op` enum insertion breaks JIT stencil scanner

Adding a new member to the `Op` enum anywhere except the end causes an illegal instruction crash in JIT-compiled lambdas.

**Root cause:** The JIT stencil scanner (`stencils.zig`) identifies NEXT and OPERAND holes by scanning the machine code of stencil functions for specific byte patterns (e.g. `MOVZ X8, #0` = `0xD2800008`). The stencil functions (`stencilApply2`, etc.) call handler functions via BL or BLR. When `Op.COUNT` increases, the compile-time `monad_table` and `dyad_table` arrays grow, shifting global symbol addresses in the binary. If handler addresses shift relative to JIT memory, the stencil scanner finds pattern matches at wrong offsets and patches incorrect bytes — producing illegal instructions at runtime.

**Observed failure:** Inserting `exec` between `parse` and `@"0:"` in the `Op` enum caused all demos that use `each` with a JIT-compiled lambda to crash with `SIGABRT` / illegal instruction on the first call from `each.zig:53`.

**Current workaround:** New ops must be appended at the end of the `Op` enum, after `@":"`, so existing integer values stay stable.

**Needed fix:** The stencil scanner should be made robust against symbol layout changes. Options:
- Use explicit `comptime` offsets or marker values (e.g. a sentinel instruction only used as a hole) instead of scanning for patterns that could occur elsewhere in the binary.
- Add a comptime assertion that verifies the scanned hole offsets match expected positions in each stencil function.
- Consider a non-scanning approach: encode hole locations as explicit offsets in a parallel comptime table, computed from the `asm volatile` instruction positions.

---

## 3. Bug in test/trend.k

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

## 4. JIT + UI combined build crashes with illegal instruction

Building with `-Djit=true -Dui=true` causes `SIGABRT` / illegal instruction crashes when running UI scripts (e.g. `test/deck/slides.k`, demos using `each` with lambdas).

**Observed failure:** The crash occurs in JIT-compiled lambdas called from the UI render loop (`runner_ui.zig:frame`). Example stack trace:

```
Illegal instruction at address 0x...
src/runtime/call.zig:67: if (try self.vm.tryJit()) continue;
src/runtime/vm.zig:227: executeCall
src/runner_ui.zig:139: frame
```

**Likely cause:** Related to issue #2 — the stencil scanner produces incorrect `StencilInfo` (wrong `next_offset` or `operand_offset`) when the binary is compiled with both UI and JIT enabled. This corrupts the emitted JIT code, producing invalid ARM64 instructions. The additional code pulled in by `-Dui=true` (zgpu, zglfw, Metal bindings) shifts symbol addresses in the binary, which triggers the same fragility described in issue #2 even when `exec` is placed at the end of the `Op` enum.

**Workaround:** Use `-Dui=true` without `-Djit=true` for UI scripts, or vice versa. The non-JIT UI build and the non-UI JIT build both work correctly.

**Needed fix:** Same as issue #2 — make the stencil scanner position-independent so it is not affected by binary layout changes.

---
