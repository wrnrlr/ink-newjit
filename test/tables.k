/ test/tables.k — row selection on a native M table.
/
/ `t@&mask` / `t@indices` gather rows by building each result column from the
/ source column. This had no test, which is how it went ~9x slower per element
/ than the same gather on a bare column without anyone noticing (pickTableRowVec
/ used the generic box-into-N(V)-then-promote path instead of the typed gather —
/ see bench/ecs.k, which is what surfaced it). These checks pin the SEMANTICS the
/ fast path has to preserve: values, per-column types, empties, and the general
/ list column that still legitimately needs the boxed path.
/
/ Run: ink test/tables.k

ok:: 0; nok:: 0
chk: {[nm;b] $[b; ok::ok+1; nok::nok+1]; $[b; 0; `0: "FAIL ",nm,"\n"]}

T: [[]i:1 2 3 4 5; f:1.5 2.5 3.5 4.5 5.5; s:`a`b`c`d`e; b:10011b; c:"vwxyz"]

run: {[]
  / ── select by mask ────────────────────────────────────────────────────────
  r: T@&01011b                    / rows 1, 3, 4
  chk["mask: I column"; (r`i)~2 4 5]
  chk["mask: F column"; (r`f)~2.5 4.5 5.5]
  chk["mask: S column"; (r`s)~`b`d`e]
  chk["mask: B column"; (r`b)~011b]
  chk["mask: C column"; (r`c)~"wyz"]
  / the typed gather must not silently widen or box a column
  chk["mask: column types preserved"; (@'.r)~`I`F`S`B`C]
  chk["mask: result is still a table"; (@r)~`M]
  chk["mask: agrees with per-column gather"; (r`b)~(T`b)@1 3 4]

  / ── select by index vector, including reordering and repeats ──────────────
  g: T@4 0 2
  chk["idx: I column reordered"; (g`i)~5 1 3]
  chk["idx: S column reordered"; (g`s)~`e`a`c]
  chk["idx: C column reordered"; (g`c)~"zvx"]
  d: T@1 1 1
  chk["idx: repeats are allowed"; (d`i)~2 2 2]

  / ── empty selection keeps the column types (promote can't infer from 0) ───
  e: T@&00000b
  chk["empty: column types preserved"; (@'.e)~`I`F`S`B`C]
  chk["empty: no rows"; 0=#e`i]

  / ── a single row is a dict, not a 1-row table ─────────────────────────────
  chk["single row is a dict"; (T@1)~`i`f`s`b`c!(2;2.5;`b;0b;"w")]

  / ── grade routes through the same permute path ────────────────────────────
  chk["grade by a column"; ((T@<T`f)`i)~1 2 3 4 5]
  chk["grade descending";  ((T@>T`f)`i)~5 4 3 2 1]

  / ── a general-list column CANNOT take the typed path: its elements are
  / boxed values that have to be ref-counted, so it keeps the generic gather.
  L: [[]k:1 2 3; v:((1;`a);(2;`b);(3;`c))]
  lr: L@&101b
  chk["L column: values gathered"; (lr`v)~((1;`a);(3;`c))]
  chk["L column: stays a list";    (@lr`v)~`L]
  chk["L column: siblings intact"; (lr`k)~1 3]

  / ── out-of-range index is an error, not a silent wrong row ────────────────
  / The error type symbol has to be DERIVED: `` `! `` written literally lexes as a
  / bare backtick (the empty symbol) followed by the `!` verb, not as a symbol.
  ERR: @(1 2 3)@9
  chk["index past the end errors"; (@T@9)~ERR]
  chk["negative index errors";     (@T@-1)~ERR]

  `0: "tables: ",($ok)," ok, ",($nok)," fail\n"}
z: run[]
