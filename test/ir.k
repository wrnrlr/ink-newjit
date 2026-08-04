/ test/ir.k — the neutral IR seam (Tiramisu layer) in lib/dye.k
/
/ shader.fragment compiles a fragment lambda into a target-neutral, typed SSA IR
/ (xOp/xTy/xArg/xVal), optionally optimizes it (xFold const-fold + value-root DCE,
/ gated on xOpt), and lowers it to SPIR-V words (reusing the op* stencils). After
/ it returns, the IR still populates the xOp/… lists so xDump can print it. Here we
/   1. show the IR (textual dump of the last-compiled body),
/   2. prove xOpt=1 is byte-identical to xOpt=0 when nothing folds (optimizer safe),
/   3. show xOpt=1 const-folding shrinks the module (optimizer effective),
/   4. RENDER a real circle SDF compiled through the fragment path (GPU validity).
/
/ Run:  ink test/ir.k              (opens a window)
/       INK_SNAP=1 ink test/ir.k -snap 1   (headless snapshot)

2: "lib/dye.k"
2: "lib/gpu.k"

chk: {[e;a;n] `0 0: (("FAIL";"ok  ")e~a)," ",n}

/ Compile fn twice: (words with xOpt=0; words with xOpt=1). Restore xOpt=1 after.
both: {[io;fn] xOpt::0; a: shader.fragment[io;fn]; xOpt::1; b: shader.fragment[io;fn]; (a;b)}

/ ── 1. neutral IR (textual back-end) for a small fragment body ───────────────
`0 0: "── neutral IR for {[uv] (uv[0]; uv[1]; 0.5; 1.0)} ──"
w0: shader.fragment[(uv:`v2; out:`v4); {[uv] (uv[0]; uv[1]; 0.5; 1.0)}]
xDump[]                                    / textual IR of the just-compiled body

/ ── 2. xOpt=1 byte-identical to xOpt=0 when nothing folds (optimizer is safe) ─
b1: both[(x:`f32;out:`f32);{[x] x+x}]
chk[b1 0; b1 1; "x+x   : xOpt=1 ≡ xOpt=0 (nothing to fold)"]
b2: both[(uv:`v2;out:`v2);{[uv] uv+0.5}]
chk[b2 0; b2 1; "uv+0.5 : xOpt=1 ≡ xOpt=0 (splat, nothing to fold)"]
b3: both[(uv:`v2;out:`v4);{[uv](uv[0];uv[1];0.5;1.0)}]
chk[b3 0; b3 1; "v2→v4  : xOpt=1 ≡ xOpt=0 (nothing to fold)"]

/ ── 3. const-fold: 1.0+2.0 folds to 3.0, so xOpt=1 is shorter ────────────────
bF: both[(x:`f32;out:`f32); {[x] x+1.0+2.0}]
chk[1b; (#bF 1)<#bF 0;      "x+1.0+2.0 : xOpt=1 folds 1.0+2.0 (shorter module)"]
chk[1b; |/(bF 1)=`I$3.0;    "folded constant 3.0 present"]
chk[0b; |/(bF 1)=`I$2.0;    "un-folded 2.0 gone"]

/ ── 4. render a real circle SDF compiled through the IR path ────────────────
spirvWds: shader.fragment[(uv:`v2; out:`v4); {[uv]
  ux: ((uv[0]*2.0)-1.0)*4.0%3.0
  uy: (uv[1]*2.0)-1.0
  d: sqrt[(sqr ux)+(sqr uy)]-0.45
  c: smoothstep[0.015;-0.015;d]
  (c; c; c; 1.0)
}]
chk[0x07230203; spirvWds[0]; "circle SDF via IR → valid SPIR-V header"]

verts: 0. 0. 0. 0. 800. 0. 1. 0. 800. 600. 1. 1. 0. 0. 0. 0. 800. 600. 1. 1. 0. 600. 0. 1.
handle:: 0
loop: {[props] $[handle=0; handle:: gpu.compileSpirv[spirvWds; 0]; 0]; gpu.drawShader[verts; handle]}
window.run[loop; 0]
