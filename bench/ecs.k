/ bench/ecs.k — an ECS-shaped workload across three storage layouts.
/
/ Two measurements, each run over IDENTICAL arithmetic in three layouts (and
/ checked to produce identical results, so the only thing measured is the cost of
/ naming the columns):
/
/   raw    four plain global vectors      the floor: no names, no lookup
/   dict   dict of columns                what lib/ecs.k recommends today
/   table  native M table                 what a fixed schema would optimize
/
/   frame  five whole-column systems (gravity, integrate x/y, damp x/y)
/          — 7 column reads and 5 column writes per frame, no row indexing
/   query  select the rows matching a mask, then reduce all four columns
/          — the other half of an ECS frame, and the one that indexes rows
/
/ The number that matters is table/raw: it is the headroom a compile-time schema
/ could recover, measured before any compiler work. Watch how it moves with N — a
/ per-CALL overhead amortizes away as N grows, a per-ELEMENT one does not.
/
/ Needs a ReleaseFast build (make build).
/ usage: ink bench/ecs.k

DT: 0.016
GR: -9.8
DK: 0.99
WORK: 4000000        / entity-frames per measurement → frames = WORK div N
QWORK: 400000        / entity-queries per measurement

/ ── raw: four plain global vectors ──────────────────────────────────────────
rawInit: {[n] Rpx:: `f$!n; Rpy:: `f$!n; Rvx:: n#1.0; Rvy:: n#2.0; 0}
rawStep: {[i]
  Rvy:: Rvy + GR*DT
  Rpx:: Rpx + Rvx*DT
  Rpy:: Rpy + Rvy*DT
  Rvx:: Rvx*DK
  Rvy:: Rvy*DK
  0}

/ ── dict of columns ─────────────────────────────────────────────────────────
dctInit: {[n] D:: `px`py`vx`vy!(`f$!n; `f$!n; n#1.0; n#2.0); 0}
dctStep: {[i]
  D[`vy]:: (D`vy) + GR*DT
  D[`px]:: (D`px) + (D`vx)*DT
  D[`py]:: (D`py) + (D`vy)*DT
  D[`vx]:: (D`vx)*DK
  D[`vy]:: (D`vy)*DK
  0}

/ ── native M table (recs.k's system idiom: a whole-column amend) ────────────
tabInit: {[n] T:: ([]px:`f$!n; py:`f$!n; vx:n#1.0; vy:n#2.0); 0}
tabStep: {[i]
  T:: @[T;`vy;:;(T`vy) + GR*DT]
  T:: @[T;`px;:;(T`px) + (T`vx)*DT]
  T:: @[T;`py;:;(T`py) + (T`vy)*DT]
  T:: @[T;`vx;:;(T`vx)*DK]
  T:: @[T;`vy;:;(T`vy)*DK]
  0}

/ ── query: select matching rows, reduce ALL FOUR columns ────────────────────
/ Every variant gathers four columns and runs four reductions, so the work is
/ identical and only the row-selection mechanism differs: raw/dict gather each
/ column by the index vector, the table selects rows once (recs.k's `Where`).
/ The result lands in a global so the gather is observable — an unused pure
/ expression is dead code the compiler may delete, which would measure nothing.
QQ:: 0.0
qryInit: {[n] MK:: (`f$!n) < `f$ n div 2; 0}
rawQry: {[i] w:&MK; QQ:: (+/Rpx@w)+(+/Rpy@w)+(+/Rvx@w)+(+/Rvy@w); 0}
dctQry: {[i] w:&MK; QQ:: (+/(D`px)@w)+(+/(D`py)@w)+(+/(D`vx)@w)+(+/(D`vy)@w); 0}
tabQry: {[i] s:T@&MK; QQ:: (+/s`px)+(+/s`py)+(+/s`vx)+(+/s`vy); 0}

/ ── harness ─────────────────────────────────────────────────────────────────
rnd2: {[x] (_ 0.5 + 100.*x) % 100.}
pad:  {[s;w] $[w>#s; s,(w-#s)#" "; s]}
col:  {[x;w] pad[($rnd2 x); w]}

/ All three layouts must compute the SAME thing, or the comparison is meaningless.
verify: {[n]
  rawInit[n]; dctInit[n]; tabInit[n]; qryInit[n]
  z0: 8 rawStep/0; z1: 8 dctStep/0; z2: 8 tabStep/0
  stepOk: (Rpx ~ D`px) & (Rpx ~ T`px) & (Rvy ~ D`vy) & (Rvy ~ T`vy)
  z3: rawQry[0]; qr: QQ
  z4: dctQry[0]; qd: QQ
  z5: tabQry[0]; qt: QQ
  qryOk: (qr=qd) & (qr=qt)
  `0: $[stepOk & qryOk; "layouts agree (n=",($n),")\n"; "MISMATCH — benchmark invalid\n"]
  0}

runN: {[n]
  F: 20 | WORK div n
  z: rawInit[n]; z: dctInit[n]; z: tabInit[n]
  a:`t[]; z: F rawStep/0
  b:`t[]; z: F dctStep/0
  c:`t[]; z: F tabStep/0
  d:`t[]
  ef: `f$ n*F                          / entity-frames actually run
  nr: (1000.*`f$b-a) % ef              / ns per entity-frame
  nd: (1000.*`f$c-b) % ef
  nt: (1000.*`f$d-c) % ef
  `0: (pad[($n);9]),(pad[($F);8]),(col[nr;9]),(col[nd;9]),(col[nt;9]),(col[nt%nr;8]),(col[nd%nr;8]),"\n"
  0}

qryN: {[n]
  Q: 20 | QWORK div n
  z: rawInit[n]; z: dctInit[n]; z: tabInit[n]; z: qryInit[n]
  a:`t[]; z: Q rawQry/0
  b:`t[]; z: Q dctQry/0
  c:`t[]; z: Q tabQry/0
  d:`t[]
  er: `f$ n*Q
  nr: (1000.*`f$b-a) % er
  nd: (1000.*`f$c-b) % er
  nt: (1000.*`f$d-c) % er
  `0: (pad[($n);9]),(pad[($Q);8]),(col[nr;9]),(col[nd;9]),(col[nt;9]),(col[nt%nr;8]),(col[nd%nr;8]),"\n"
  0}

NS: 100 1000 10000 100000 1000000

`0: ,"\n"
z: verify[1000]
`0: "\nframe: 5 whole-column systems (7 reads, 5 writes) — ns per entity-frame\n"
`0: "N        frames  raw      dict     table    tab/raw dct/raw\n"
z: {[n] runN[n]}' NS
`0: "\nquery: select matching rows + reduce 4 columns — ns per entity-query\n"
`0: "N        reps    raw      dict     table    tab/raw dct/raw\n"
z: {[n] qryN[n]}' NS
`0: ,"\n"
