/ test/kkwg.k — workgroup shared memory (gpu.kernelWG, kk.md finding 3) vs CPU.
/ Exercises the Workgroup-storage shared array + barrier[] + lid/wgsz through three
/ kernels: reverse-within-block and broadcast (prove cooperative load + barrier sync +
/ cross-thread read + per-workgroup shared isolation), and a tiled GEMM with A-row reuse
/ (nested +/ folds with barriers INSIDE a loop) checked against nn.k's untiled gemmK.
/ Run headless:  INK_SNAP=0 ink test/kkwg.k

2: "lib/dye.k"; 2: "lib/gpu.k"; 2: "lib/nn.k"

ok:: 0; nok:: 0
chkb: {[nm;b] $[b; ok::ok+1; nok::nok+1]; $[b; 0; `0 0: "FAIL ",nm,"\n"]}

/ reverse each wg-block: load sh[lid]=x[d], barrier, out[d]=sh[wgsz-1-lid]
revK: gpu.kernelWG[{[o;x;d] lset[0; lid; x[d]]; barrier[]; set[o; d; lget[0; (wgsz-1)-lid]]}; 0; 2; ,64; 0]
/ broadcast lane 0 of each block: out[d] = sh[0] = x[(d div wgsz)*wgsz]
bcK:  gpu.kernelWG[{[o;x;d] lset[0; lid; x[d]]; barrier[]; set[o; d; lget[0; 0]]}; 0; 2; ,64; 0]
/ tiled GEMM: each workgroup shares one A row (N%wg==0, K%wg==0), the row tile loaded
/ once per K-tile into shared memory and reused by all wg threads.
gemmTiledK: gpu.kernelWG[{[c;a;b;g;d]
  n:`i$g[1]; kk:`i$g[2]; i:d div n; j:d mod n; nt:kk div wgsz
  acc: +/{[t]
    lset[0; lid; a[(i*kk)+(t*wgsz)+lid]]
    barrier[]
    p: +/{[m] (lget[0;m]) * b[(((t*wgsz)+m)*n)+j]}'!wgsz
    barrier[]
    p}'!nt
  set[c; d; acc]}; 0; 4; ,64; 0]

demo:{[]
  N: 256; x: `f$ !N                              / 4 workgroups of 64
  bx: gpu.buffer[x]

  pr: gpu.compileCompute[revK; 2]
  bo: gpu.buffer[N#0.]
  gpu.dispatch[pr; (bo;bx); N]
  chkb["wg reverse (4 blocks, per-wg shared isolation)"; (N # gpu.read bo) ~ ,/ |:' (N div 64; 64) # x]

  pb: gpu.compileCompute[bcK; 2]
  bo2: gpu.buffer[N#0.]
  gpu.dispatch[pb; (bo2;bx); N]
  chkb["wg broadcast lane 0"; (N # gpu.read bo2) ~ `f$ 64 * (!N) div 64]

  / tiled GEMM vs the untiled reference (both sum k ascending → exact here)
  M: 64; K: 128; NN: 64
  A: (`f$ (!(M*K)) mod 7) - 3.
  B: ((`f$ (!(K*NN)) mod 5) - 2.) % 2.
  ref: gemm.host[A; B; M; K; NN]
  pg: gpu.compileCompute[gemmTiledK; 4]
  ba: gpu.buffer[A]; bb: gpu.buffer[B]
  bc: gpu.buffer[(nn.pad[M*NN])#0.]; bg: gpu.buffer[4#0.]
  gpu.write[bg; (0.+M),(0.+NN),(0.+K),0.]
  gpu.dispatch[pg; (bc;ba;bb;bg); M*NN]
  chkb["tiled GEMM (shared A-row) == gemmK"; 1e-4 > |/ abs ((M*NN) # gpu.read bc) - ref]

  / gemm's shape guard: 8-aligned dims take the shared-memory 8×8-tiled kernel (gemm2dK,
  / both A and B reused); non-square + non-64-multiple to stress the block mapping.
  M2: 24; K2: 40; N2: 16
  A2: (`f$ (!(M2*K2)) mod 7) - 3.
  B2: ((`f$ (!(K2*N2)) mod 5) - 2.) % 2.
  cpuRef: {[A;B;m;k;n] ds:!m*n; {[A;B;k;n;i;j] +/ (A@(i*k)+!k) * B@j+n*!k}[A;B;k;n;]'[ds div n; ds mod n]}[A2;B2;M2;K2;N2]
  chkb["gemm guard → 8×8-tiled (both A,B shared)"; 1e-4 > |/ abs gemm.host[A2;B2;M2;K2;N2] - cpuRef]
  / non-8-aligned dims fall back to the plain kernel (still correct)
  chkb["gemm guard → plain fallback (3×4×2)"; 1e-4 > |/ abs gemm.host[(`f$!12);(`f$!8);3;4;2] - {[A;B;m;k;n] ds:!m*n; {[A;B;k;n;i;j] +/ (A@(i*k)+!k) * B@j+n*!k}[A;B;k;n;]'[ds div n; ds mod n]}[(`f$!12);(`f$!8);3;4;2]]

  `0 0: "kkwg: ",($ok)," ok, ",($nok)," fail\n"
  0}

gpu.computeRun[{[z] demo[]}]
