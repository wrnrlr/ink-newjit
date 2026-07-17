/ test/kkc.k — kk.compile elementwise milestone (kk2 §2.4-2) vs CPU references.
/ Places arrays with the 9: io verb, runs kk.compile[fn; placements], fetches with 8:,
/ and checks against the same expression on the CPU (f32 tolerance). Also exercises
/ the pipeline cache and the non-elementwise rejection path.
/ Run headless:  INK_SNAP=0 ink test/kkc.k

2: "lib/kk.k"

X:  1. + `f$ !64
Y:  0.5 * `f$ !64
Z:  (`f$ !64) - 20.
M2: (8;8) # X
IW: `f$ (37 * !64) mod 64        / a permutation-ish index vector for gather
WM: {[j] `f$ ((j*17) + !64) mod 64}' !3   / a (3;64) index matrix for +/x@W
NB: {[o] `f$ (o + !64) mod 64}' (-8; 8; -1; 1)   / (4;64) neighbour matrix (walk.k)

/ walk.k Jacobi on a small 6×6 grid — the amend @[x;I;:;v] + ping-pong iterate
GN: 6
(GR;GC): 1 + !2#GN-2
GI: GC + GN*GR                    / interior flat indices (I)
GW: ((-GN),GN,1,-1) +\: GI        / (4; #I) neighbour matrix (W, a host global)
gjac: {@[x;GI;:;1.+.25*+/x@GW]}   / one Jacobi sweep (walk.k's f, verbatim)

/ scatter-add histogram: @[x;I;+;v] atomic accumulate into a bucket array. On a
/ device with caps.atomicFadd (§7) this is native f32 OpAtomicFAddEXT (float
/ result); kkScatForceI forces the i32 fixed-point fallback.
HB: 8; HK: 40
HI: (13 * !HK) mod HB             / skewed bucket indices (host global)
HV: `f$ 1 + (!HK) mod 3           / per-item weights
histc: {@[x;HI;+;1.]}             / count
histw: {@[x;HI;+;HV]}             / weighted sum

/ placed table (kk2 §2.5): named equal-length columns as a structured GPU buffer
TT: [[]px:`f$!64; py:0.5*`f$!64; vx:(`f$!64)-8.; vy:`f$64-!64]

/ Helpers are TOP-LEVEL globals: an inner lambda can't see demo's locals (ink
/ lambdas don't close over parent scope), so chk must reach chkb as a global.
ok:: 0; nok:: 0
chkb: {[nm;b] $[b; ok::ok+1; nok::nok+1]; $[b; 0; `0 0: "FAIL ",nm,"\n"]}
chk:  {[nm;gpu;cpu] chkb[nm; 0.0001 > |/abs gpu-cpu]}

demo: {[]
  a: 9: X; b: 9: Y; c: 9: Z; m: 9: M2; iw: 9: IW; wm: 9: WM

  chk["{2.*x}";     8: kk.compile[{2.*x}; ,a];      2.*X]
  chk["{x+y}";      8: kk.compile[{x+y}; (a;b)];    X+Y]
  chk["{(x+y)*z}";  8: kk.compile[{(x+y)*z}; (a;b;c)]; (X+Y)*Z]
  chk["{sqrt x}";   8: kk.compile[{sqrt x}; ,a];    sqrt X]
  chk["{$[x<y;y;x]}"; 8: kk.compile[{$[x<y;y;x]}; (a;b)]; {[u;v] $[u<v;v;u]}'[X;Y]]

  / 2-D placement: the descriptor shape round-trips through 9:/8:
  rm: 8: kk.compile[{10.*x}; ,m]
  chk["{10.*x} 8x8 values"; ,/rm; ,/10.*M2]
  chkb["8x8 shape round-trip"; (%rm)~8 8]

  / pipeline cache: recompiling the same (lambda;#inputs) reuses the pipeline
  z1: kk.compile[{7.*x}; ,a]; n0: #!kkCache
  z2: kk.compile[{7.*x}; ,a]
  chkb["cache reuse on repeat compile"; (#!kkCache)=n0]

  / gather: x@y → x[y[d]] (both operands placed; index vector = output extent)
  chk["{x@y} gather"; 8: kk.compile[{x@y}; (a;iw)]; X@`i$IW]

  / matrix gather-reduce: +/x@W and |/x@W (W a (k;n) index matrix, k baked, out = n)
  chk["{+/x@y} matrix sum"; 8: kk.compile[{+/x@y}; (a;wm)]; +/X@`i$WM]
  chk["{|/x@y} matrix max"; 8: kk.compile[{|/x@y}; (a;wm)]; |/X@`i$WM]

  / host-vector auto-upload: WM/NB are FREE names (not passed) → auto-uploaded
  / read-only from the host globals, shape read from the value (§2.1-2).
  chk["{+/x@WM} auto-upload"; 8: kk.compile[{+/x@WM}; ,a]; +/X@`i$WM]

  / walk.k interior update expression: the reduce composed with arithmetic, W free
  chk["{1.+.25*+/x@NB} walk interior"; 8: kk.compile[{1.+.25*+/x@NB}; ,a]; 1.+.25*+/X@`i$NB]

  / amend-scatter @[x;I;:;v]: one Jacobi sweep, then the ping-pong iterate (walk.k f)
  gx0: 9: (GN*GN)#0.
  chk["@[x;I;:;v] one sweep";   8: kk.compile[gjac; ,gx0];  gjac (GN*GN)#0.]
  chk["ping-pong 5 iters (even A)"; 8: kk.loop[gjac; gx0; 6]; 6 gjac/ (GN*GN)#0.]
  chk["ping-pong 7 iters (odd B)";  8: kk.loop[gjac; gx0; 7]; 7 gjac/ (GN*GN)#0.]

  / scatter-add @[x;I;+;v]: atomic histogram (duplicate buckets accumulate).
  / Default path = native f32 atomics (§7): float result, and weighted FLOAT sums
  / are exact (no i32 truncation the fixed-point path forced). CPU refs are float.
  gh0: 9: HB#0.
  chkb["scatter-add count (f-atomic)";    (8: kk.compile[histc; ,gh0]) ~ `f$ @[HB#0; HI; +; HK#1]]
  chkb["scatter-add weighted float";      1e-5 > |/ abs (8: kk.compile[histw; ,gh0]) - @[HB#0.; HI; +; HV]]
  / i32 fixed-point fallback (kkScatForceI): integer buckets, exact vs int CPU ref.
  kkScatForceI:: 1
  chkb["scatter-add count (i32 fallback)"; (8: kk.compile[histc; ,(9: HB#0)]) ~ @[HB#0; HI; +; HK#1]]
  kkScatForceI:: 0

  / placed-table column arithmetic — the CPU form `t`c` IS the column, so the same
  / lambda runs on both sides. Only the referenced columns are bound (pruning).
  pt: 9: TT                        / monadic 9: routes tables to gpu.holdT (class M)
  chk["table (px)+(vx)";       8: kk.compile[{(x`px)+(x`vx)}; ,pt]; (TT`px)+(TT`vx)]
  chk["table (px)*(vy)+(py)";  8: kk.compile[{((x`px)*(x`vy))+(x`py)}; ,pt]; ((TT`px)*(TT`vy))+(TT`py)]
  chkb["column pruning: reads 3 of 4"; 3 = #kkTableColNames[]]

  / 9:/8: verb surface (kk.md §1, the canonical spelling): roundtrip, trimmed
  / fetch, in-place overwrite, and table reassembly through 8:.
  chkb["9:/8: roundtrip";  (8: 9: X)~X]
  chkb["n 8: trimmed";     (5 8: 9: X)~5#X]
  chkb["d 9: overwrite";   (8: (9: X) 9: Y)~Y]
  chkb["8: table reassembles"; (8: pt)~TT]

  / rejection: a whole-buffer reduce is neither elementwise nor a gather → kk.compile
  / SIGNALS an error (`@x ~ `! for an err value). (+/ over the whole placement is a
  / tier-2 form.)
  chkb["{+/x} rejected"; `"!"~@kk.compile[{+/x}; ,a]]

  `0 0: "kkc: ",($ok)," ok, ",($nok)," fail\n"
  0}

gpu.computeRun[{[x] demo[]}]
