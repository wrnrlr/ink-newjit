/ test/kkint.k — integer-index gpu.kernel dialect (explicit casts) vs the f32 dialect
/ and a CPU reference. The SAME kernel math written two ways: floor[d%n]/mod (f32
/ indices) vs d%n/mod on an i32 thread index with `i$ bounds. Both must match the CPU
/ GEMM bit-for-bit (integer inputs → exact). Run headless: INK_SNAP=0 ink test/kkint.k

2: "lib/dye.k"
2: "lib/gpu.k"

ok:: 0; nok:: 0
chke: {[nm;g;c] $[g~c; ok::ok+1; nok::nok+1]; $[g~c; 0; `0 0: "FAIL ",nm,"\n"]}

/ f32-index GEMM (the existing dialect): floor[d%n], mod[d;n], f32 index math
gemmF: {[c;a;b;g;d]
  n:g[1]; kk:g[2]
  i:floor[d%n]; j:mod[d;n]
  set[c; d; +/{[k] (a[(i*kk)+k]) * b[(k*n)+j]}'!kk]}
/ i32-index GEMM (explicit dialect): d is i32, bounds cast with `i$, d%n=SDiv, mod=SRem
gemmI: {[c;a;b;g;d]
  n:`i$g[1]; kk:`i$g[2]
  i:d%n; j:mod[d;n]
  set[c; d; +/{[k] (a[(i*kk)+k]) * b[(k*n)+j]}'!kk]}

runGemm: {[pipe;A;B;M;K;N]
  bc: gpu.buffer[(64*1|(M*N)div 64)#0.]; ba: gpu.buffer[A]; bb: gpu.buffer[B]
  bg: gpu.buffer[(0.+M),(0.+N),(0.+K),0.]
  gpu.dispatch[pipe; (bc;ba;bb;bg); M*N]
  (M*N) # gpu.read bc}

/ 2-D scatter kernel: transpose via integer decomposition (out[j*M+i] = in[i*N+j])
transI: {[o;x;g;d]
  m:`i$g[0]; nn:`i$g[1]
  i:d div nn; j:d mod nn
  set[o; (j*m)+i; x[d]]}
/ Globals (not demo locals) so the CPU-ref lambdas can reference them — ink lambdas
/ do not close over a caller's locals.
GM::5; GK::6; GN::4
GA:: 1.+`f$!GM*GK
GB:: (`f$ (!GK*GN) mod 7) - 3.
grefI: {[d] i:d div GN; j:d mod GN; +/ (GA@((i*GK)+!GK)) * (GB@(((!GK)*GN)+j))}
demo: {[]
  pf: gpu.compileCompute[shader.kernel  gemmF; 4]
  pii: gpu.compileCompute[shader.kernelI gemmI; 4]
  rf: runGemm[pf;  GA;GB;GM;GK;GN]
  ri: runGemm[pii; GA;GB;GM;GK;GN]
  cpu: grefI' !GM*GN
  chke["f32-index GEMM == CPU"; rf; cpu]
  chke["i32-index GEMM == CPU"; ri; cpu]
  chke["i32 GEMM == f32 GEMM";  ri; rf]

  P:4; Q:3
  X: `f$ 1 + !P*Q
  pt: gpu.compileCompute[shader.kernelI transI; 3]   / o, x, g
  bo: gpu.buffer[64#0.]; bx: gpu.buffer[X]; bgg: gpu.buffer[(0.+P),(0.+Q),0.,0.]
  gpu.dispatch[pt; (bo;bx;bgg); P*Q]
  rt: (P*Q) # gpu.read bo
  ctr: ,/ +(P;Q)#X                     / CPU transpose (flip P×Q → Q×P)
  chke["i32 transpose scatter == CPU"; rt; ctr]

  `0 0: "kkint: ",($ok)," ok, ",($nok)," fail\n"
  0}
gpu.computeRun[{[x] demo[]}]
