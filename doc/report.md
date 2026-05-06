
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
