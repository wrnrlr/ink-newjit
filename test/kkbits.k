/ test/kkbits.k — the bits CPU backend as a cross-backend oracle (kk.md §3.2,
/ kk2 §4).  ONE kernel lambda is lowered two ways from the SAME neutral IR:
/   bits.run    → interpreted on the CPU (lib/bits.k)
/   gpu.kernel  → SPIR-V, dispatched on the GPU
/ and the two results must agree.  These are the exact kernel lambdas lib/nn.k
/ ships (gemm / softmax / layernorm / linear / activations), so this pins the
/ nn stack from one source instead of a hand-written CPU reference.
/
/ Run headless:  INK_SNAP=0 ink test/kkbits.k     (needs the gpu ext: zig build gpu)

2: "lib/bits.k"
2: "lib/gpu.k"

padTo: {[n] 64 * 1 | `i$ (n + 63) div 64}                  / grid rounds up to 64

ok:: 0; nok:: 0
chk: {[nm; a; b] e: $[0 = #a; 1.; |/ abs a - b]; good: e < 0.001
  $[good; ok:: ok + 1; nok:: nok + 1]
  $[good; 0; `0 0: "FAIL ",nm," maxerr=",($e),"\n"]}

/ Run a kernel both ways; returns (cpuBufs; gpuBufs), each the full buffer list.
cpu2: {[lam; na; nb; bufs; cnt] bits.run[lam; na; nb; bufs; cnt]}
gpu2: {[lam; na; nb; bufs; cnt]
  pipe: gpu.compileCompute[gpu.kernel[lam; na; nb]; na + nb]
  hs: {[b] gpu.buffer b}' bufs
  gpu.dispatch[pipe; hs; cnt]
  {[h] gpu.read h}' hs}

/ ── the kernels (verbatim from lib/nn.k) ─────────────────────────────────────
gemmK: {[c;a;b;g;d] n:`i$g[1]; kk:`i$g[2]; i:d div n; j:d mod n
  set[c; d; +/{[k] (a[(i*kk)+k]) * b[(k*n)+j]}'!kk]}
smStatK: {[mb;sb;x;g;i] n:`i$g[0]
  m: |/{[k] x[(i*n)+k]}'!n
  s: +/{[k] exp[(x[(i*n)+k]) - m]}'!n
  set[mb; i; m]; set[sb; i; s]}
smApplyK: {[o;x;mb;sb;g;d] n:`i$g[0]; i:d div n
  set[o; d; (exp[(x[d]) - mb[i]]) % sb[i]]}
lnStatK: {[mb;rb;x;g;i] nf:g[0]; eps:g[1]; n:`i$nf
  mean: (+/{[k] x[(i*n)+k]}'!n) % nf
  var:  (+/{[k] sqr[(x[(i*n)+k]) - mean]}'!n) % nf
  set[mb; i; mean]; set[rb; i; 1. % sqrt[var + eps]]}
lnApplyK: {[o;x;mb;rb;gm;bt;g;d] n:`i$g[0]; i:d div n; j:d mod n
  nrm: ((x[d]) - mb[i]) * rb[i]
  set[o; d; (nrm * gm[j]) + bt[j]]}
linK: {[o;x;w;b;g;d] nn:`i$g[1]; kk:`i$g[2]; i:d div nn; j:d mod nn
  set[o; d; (+/{[k] (x[(i*kk)+k]) * w[(j*kk)+k]}'!kk) + b[j]]}
siluK: {[o;x;d] t:x[d]; set[o; d; t % (1. + exp[0. - t])]}
geluK: {[o;x;d] t:x[d]; c:0.7978845608 * (t + 0.044715*t*t*t); set[o; d; (0.5*t)*(1. + tanh[c])]}
addsK: {[o;a;b;g;d] set[o; d; (a[d]) + (g[0])*b[d]]}
reluK: {[o;x;e] set[o; e; max[0.; x[e]]]}

/ compare slot `s` of the two buffer lists over its first `len` entries.
cmp: {[nm; c; g; s; len] chk[nm; len # c s; len # g s]}

run: {[]
  / GEMM 3×4×2
  GM:3; GK:4; GN:2
  GA: 1. + `f$ !GM*GK; GB: 1. + `f$ !GK*GN; grid: (0.+GM),(0.+GN),(0.+GK),0.
  bufs: ((padTo[GM*GN])#0.; GA; GB; grid)
  cmp["gemm"; cpu2[gemmK;0;4;bufs;GM*GN]; gpu2[gemmK;0;4;bufs;GM*GN]; 0; GM*GN]

  / Softmax two-pass 5×7
  SM:5; SN:7
  SX: (`f$ (!(SM*SN)) mod 11) - 5.
  sb: ((padTo SM)#0.; (padTo SM)#0.; SX; (0.+SN),0.,0.,0.)
  cS: cpu2[smStatK;0;4;sb;SM]; gS: gpu2[smStatK;0;4;sb;SM]
  cmp["smStat-max"; cS; gS; 0; SM]; cmp["smStat-sum"; cS; gS; 1; SM]
  ab: ((padTo[SM*SN])#0.; SX; (SM#cS 0); (SM#cS 1); (0.+SN),0.,0.,0.)
  cmp["smApply"; cpu2[smApplyK;0;5;ab;SM*SN]; gpu2[smApplyK;0;5;ab;SM*SN]; 0; SM*SN]

  / LayerNorm two-pass 4×6
  LM:4; LN:6; LEPS:0.00001
  LX: (`f$ (!(LM*LN)) mod 7) - 3.
  LG: 0.5 + 0.1 * `f$!LN; LB: (`f$!LN) - 2.
  lb: ((padTo LM)#0.; (padTo LM)#0.; LX; (0.+LN),LEPS,0.,0.)
  cL: cpu2[lnStatK;0;4;lb;LM]; gL: gpu2[lnStatK;0;4;lb;LM]
  cmp["lnStat-mean"; cL; gL; 0; LM]; cmp["lnStat-rstd"; cL; gL; 1; LM]
  lab: ((padTo[LM*LN])#0.; LX; (LM#cL 0); (LM#cL 1); LG; LB; (0.+LN),0.,0.,0.)
  cmp["lnApply"; cpu2[lnApplyK;0;7;lab;LM*LN]; gpu2[lnApplyK;0;7;lab;LM*LN]; 0; LM*LN]

  / Linear 4×5·Wᵀ(3×5)+b(3)
  PM:4; PK:5; PN:3
  PX: (`f$ (!(PM*PK)) mod 9) - 4.
  PW: ((`f$ (!(PN*PK)) mod 7) - 3.) % 4.; PB: (`f$!PN) - 1.
  pb: ((padTo[PM*PN])#0.; PX; PW; PB; (0.+PM),(0.+PN),(0.+PK),0.)
  cmp["linear"; cpu2[linK;0;5;pb;PM*PN]; gpu2[linK;0;5;pb;PM*PN]; 0; PM*PN]

  / Elementwise activations + scaled residual
  AN:16
  AX: 0.5 * (`f$ (!AN) mod 13) - 6.
  cmp["silu"; cpu2[siluK;0;2;((padTo AN)#0.; AX);AN]; gpu2[siluK;0;2;((padTo AN)#0.; AX);AN]; 0; AN]
  cmp["gelu"; cpu2[geluK;0;2;((padTo AN)#0.; AX);AN]; gpu2[geluK;0;2;((padTo AN)#0.; AX);AN]; 0; AN]
  cmp["relu"; cpu2[reluK;0;2;((padTo AN)#0.; AX);AN]; gpu2[reluK;0;2;((padTo AN)#0.; AX);AN]; 0; AN]
  BX: 0.3 * (`f$ (!AN) mod 5) - 2.
  adb: ((padTo AN)#0.; AX; BX; 0.5 0. 0. 0.)
  cmp["adds"; cpu2[addsK;0;4;adb;AN]; gpu2[addsK;0;4;adb;AN]; 0; AN]

  `0 0: "kkbits: ",($ok)," ok, ",($nok)," fail\n"}

gpu.computeRun[{[x] run[]}]
