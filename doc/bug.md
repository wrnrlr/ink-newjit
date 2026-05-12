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
