/ test/kkc.k — kk.compile elementwise milestone (kk2 §2.4-2) vs CPU references.
/ Places arrays with gpu.hold, runs kk.compile[wholeArrayLambda; placements], fetches,
/ and checks against the same expression on the CPU (f32 tolerance). Also exercises
/ the pipeline cache and the non-elementwise rejection path.
/ Run headless:  INK_SNAP=0 ink test/kkc.k

2: "lib/dye.k"
2: "lib/gpu.k"

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

/ scatter-add histogram: @[x;I;+;v] atomic accumulate into an i32 bucket array
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
  a: gpu.hold X; b: gpu.hold Y; c: gpu.hold Z; m: gpu.hold M2; iw: gpu.hold IW; wm: gpu.hold WM

  chk["{2.*x}";     gpu.fetch kk.compile[{2.*x}; ,a];      2.*X]
  chk["{x+y}";      gpu.fetch kk.compile[{x+y}; (a;b)];    X+Y]
  chk["{(x+y)*z}";  gpu.fetch kk.compile[{(x+y)*z}; (a;b;c)]; (X+Y)*Z]
  chk["{sqrt x}";   gpu.fetch kk.compile[{sqrt x}; ,a];    sqrt X]
  chk["{$[x<y;y;x]}"; gpu.fetch kk.compile[{$[x<y;y;x]}; (a;b)]; {[u;v] $[u<v;v;u]}'[X;Y]]

  / 2-D placement: the descriptor shape round-trips through 9:/8:
  rm: gpu.fetch kk.compile[{10.*x}; ,m]
  chk["{10.*x} 8x8 values"; ,/rm; ,/10.*M2]
  chkb["8x8 shape round-trip"; (%rm)~8 8]

  / pipeline cache: recompiling the same (lambda;#inputs) reuses the pipeline
  z1: kk.compile[{7.*x}; ,a]; n0: #!kkCache
  z2: kk.compile[{7.*x}; ,a]
  chkb["cache reuse on repeat compile"; (#!kkCache)=n0]

  / gather: x@y → x[y[d]] (both operands placed; index vector = output extent)
  chk["{x@y} gather"; gpu.fetch kk.compile[{x@y}; (a;iw)]; X@`i$IW]

  / matrix gather-reduce: +/x@W and |/x@W (W a (k;n) index matrix, k baked, out = n)
  chk["{+/x@y} matrix sum"; gpu.fetch kk.compile[{+/x@y}; (a;wm)]; +/X@`i$WM]
  chk["{|/x@y} matrix max"; gpu.fetch kk.compile[{|/x@y}; (a;wm)]; |/X@`i$WM]

  / host-vector auto-upload: WM/NB are FREE names (not passed) → auto-uploaded
  / read-only from the host globals, shape read from the value (§2.1-2).
  chk["{+/x@WM} auto-upload"; gpu.fetch kk.compile[{+/x@WM}; ,a]; +/X@`i$WM]

  / walk.k interior update expression: the reduce composed with arithmetic, W free
  chk["{1.+.25*+/x@NB} walk interior"; gpu.fetch kk.compile[{1.+.25*+/x@NB}; ,a]; 1.+.25*+/X@`i$NB]

  / amend-scatter @[x;I;:;v]: one Jacobi sweep, then the ping-pong iterate (walk.k f)
  gx0: gpu.hold (GN*GN)#0.
  chk["@[x;I;:;v] one sweep";   gpu.fetch kk.compile[gjac; ,gx0];  gjac (GN*GN)#0.]
  chk["ping-pong 5 iters (even A)"; gpu.fetch kk.loop[gjac; gx0; 6]; 6 gjac/ (GN*GN)#0.]
  chk["ping-pong 7 iters (odd B)";  gpu.fetch kk.loop[gjac; gx0; 7]; 7 gjac/ (GN*GN)#0.]

  / scatter-add @[x;I;+;v]: atomic histogram (duplicate buckets accumulate), i32 out
  gh0: gpu.hold HB#0.
  chkb["scatter-add count";    (gpu.fetch kk.compile[histc; ,gh0]) ~ @[HB#0; HI; +; HK#1]]
  chkb["scatter-add weighted"; (gpu.fetch kk.compile[histw; ,gh0]) ~ @[HB#0; HI; +; `i$HV]]

  / placed-table column arithmetic — the CPU form `t`c` IS the column, so the same
  / lambda runs on both sides. Only the referenced columns are bound (pruning).
  pt: gpu.holdT TT
  chk["table (px)+(vx)";       gpu.fetch kk.compile[{(x`px)+(x`vx)}; ,pt]; (TT`px)+(TT`vx)]
  chk["table (px)*(vy)+(py)";  gpu.fetch kk.compile[{((x`px)*(x`vy))+(x`py)}; ,pt]; ((TT`px)*(TT`vy))+(TT`py)]
  chkb["column pruning: reads 3 of 4"; 3 = #kkTableColNames[]]

  / rejection: a whole-buffer reduce is neither elementwise nor a gather → kk.compile
  / warns + returns !0 (empty). (+/ over the whole placement is a tier-2 form.)
  chkb["{+/x} rejected"; 0=#kk.compile[{+/x}; ,a]]

  `0 0: "kkc: ",($ok)," ok, ",($nok)," fail\n"
  0}

gpu.computeRun[{[x] demo[]}]
