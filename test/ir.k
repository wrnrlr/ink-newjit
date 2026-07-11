/ test/ir.k — the neutral IR seam (Tiramisu layer) in lib/dye.k
/
/ FragmentShaderIr compiles a fragment lambda into a target-neutral, typed SSA IR,
/ optimizes it (const-fold + DCE), and lowers it to a target — SPIR-V words
/ (xLowerSpirv, reusing the op* stencils) OR a textual dump (xDump). Here we:
/   1. show the IR + both lowerings,
/   2. prove the SPIR-V is byte-identical to the direct compiler when nothing folds,
/   3. show const-folding shrinks the module,
/   4. RENDER a real circle SDF compiled through the IR path (GPU validity).
/
/ Run:  ink test/ir.k              (opens a window)
/       INK_SNAP=1 ink test/ir.k -snap 1   (headless snapshot)

2: "lib/dye.k"
2: "lib/gpu.k"

chk: {[e;a;n] `0 0: (("FAIL";"ok  ")e~a)," ",n}

/ ── 1. neutral IR + both back-ends ──────────────────────────────────────────
`0 0: "── neutral IR for {[uv] (uv[0]; uv[1]; 0.5; 1.0)} ──"
w0: FragmentShaderIr[[uv:`v2; out:`v4]; {[uv] (uv[0]; uv[1]; 0.5; 1.0)}]
xDump[]                                    / back-end 2: textual IR

/ ── 2. byte-identical to the direct compiler when nothing folds ─────────────
chk[FragmentShader[[x:`f32;out:`f32];{[x] x+x}];      FragmentShaderIr[[x:`f32;out:`f32];{[x] x+x}];      "x+x  : IR ≡ direct"]
chk[FragmentShader[[uv:`v2;out:`v2];{[uv] uv+0.5}];   FragmentShaderIr[[uv:`v2;out:`v2];{[uv] uv+0.5}];   "uv+0.5 : IR ≡ direct (splat)"]
chk[FragmentShader[[uv:`v2;out:`v4];{[uv](uv[0];uv[1];0.5;1.0)}]; FragmentShaderIr[[uv:`v2;out:`v4];{[uv](uv[0];uv[1];0.5;1.0)}]; "v2→v4 : IR ≡ direct"]

/ ── 3. const-fold: 1.0+2.0 folds to 3.0, so the IR module is shorter ────────
dF: FragmentShader[[x:`f32;out:`f32]; {[x] x+1.0+2.0}]
iF: FragmentShaderIr[[x:`f32;out:`f32]; {[x] x+1.0+2.0}]
chk[1b; (#iF)<#dF;         "x+1.0+2.0 : IR folds 1.0+2.0 (shorter module)"]
chk[1b; |/iF=`I$3.0;       "folded constant 3.0 present"]
chk[0b; |/iF=`I$2.0;       "un-folded 2.0 gone"]

/ ── 4. render a real circle SDF compiled through the IR path ────────────────
spirvWds: FragmentShaderIr[[uv:`v2; out:`v4]; {[uv]
  ux: ((uv[0]*2.0)-1.0)*4.0%3.0
  uy: (uv[1]*2.0)-1.0
  d: sqrt[(sqr ux)+(sqr uy)]-0.45
  c: smoothstep[0.015;-0.015;d]
  (c; c; c; 1.0)
}]
chk[0x07230203; spirvWds[0]; "circle SDF via IR → valid SPIR-V header"]

verts: 0. 0. 0. 0. 800. 0. 1. 0. 800. 600. 1. 1. 0. 0. 0. 0. 800. 600. 1. 1. 0. 600. 0. 1.
handle:: 0
loop: {[props] $[handle=0; handle:: CompileSpirV[spirvWds; 0]; 0]; DrawShader[verts; handle]}
window.run[loop; 0]
