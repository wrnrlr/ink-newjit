/ lib/kk.k — the kk array-level GPU surface (doc/design/kk.md, kk2 §2/§6).
/
/ kk.compile[fn; placements] — idiomatic whole-array lambda → cached pipeline
/ kk.loop / kk.converge      — iterate an amend sweep on-device (ping-pong)
/ kk.reduce/sum/max/min/prod — whole-buffer reductions (subgroup fast path)
/ kk.scan/sums/maxs/mins     — inclusive prefix scans
/ kk.where                   — compaction (&mask)
/
/ The classifiers/emitters live in lib/dye.k (shader.*); the device runtime +
/ placed-array descriptors (gpu.hold / 9: / 8:) live in lib/gpu.k.
/ Load with:  2: "lib/kk.k"   (pulls in dye + gpu itself).
2: "lib/dye.k"
2: "lib/gpu.k"

/ ── kk.compile — idiomatic whole-array lambda on placements (kk2 §2, incr 5) ──
/ Milestone 2 (elementwise): kk.compile[fn; descriptors] compiles a whole-array
/ lambda in implicit-param form ({2.*x}, {x+y}, {(x+y)*z}) to a per-thread map
/ (dye's shader.map), dispatches it over the placements (one thread per element),
/ and returns an OUTPUT descriptor — so `8: kk.compile[{2.*x}; ,a]` reshapes the
/ result exactly like any placed array. The pipeline is cached by (lambda source;
/ #inputs); the output buffer is padded to the ×64 grid so stray stores land in
/ padding (descriptor n/s stay the real extent). Non-elementwise bodies (gather,
/ amend, adverbs) are rejected by kkClassify with the offending verb named — the
/ later milestones (index-buffer gather, scatter, stencil) will accept them.
kkPad: {[n] 64 * 1 | `i$ (n+63) div 64}
kkCache:: ()!()
/ ── kk.plan / kk.run (kk.md incr 4, monomorphic call site) ────────────────────
/ kk.compile[fn;args] does two things every call: CST work (lamOf parse + the
/ kkClassify/kkGathSrc/… scans that pick the path and its bindings) and dispatch
/ (buffer alloc + gpu.dispatch). The pipeline is already pooled in kkCache, so on a
/ REPEAT call at a hot site (e.g. kk.converge's per-batch |Δ| compile) the CST work
/ is pure waste. kk.plan caches a reusable PLAN — a dict [kind;pipe;…binding info]
/ that captures the classification RESULTS — keyed on (lambda source; #inputs; each
/ placement's SIGNATURE: type/shape/layout/columns). kk.run dispatches a plan against
/ fresh args with ZERO re-parse/re-classify. kk.compile = plan then run.
/ Correctness rests on the monomorphic contract: same lambda + same placement shapes
/ ⇒ same pipeline. The runners recompute n/handles from the live args each call, so a
/ plan is size-robust for map/gather/table/dict; only gather-reduce/amend bake matrix
/ dims (from the W global, stable per program). kkScatForceI is the one pipe-choosing
/ runtime knob not visible in the args, so it rides the key. Keys are SYMBOLS (a
/ string key probes char-wise → every probe a false hit).
kkPlanMisses:: 0                          / plans built from scratch (CST work done) — observability
kkPlanCache:: ()!()
kkArgSig: {[a] k: !a
  s: ($a`t),"~",($a`n)
  s: s,$[`s    in k; "~",($a`s); ""]
  s: s,$[`lay  in k; "~",($a`lay); ""]
  s: s,$[`cols in k; "~c",(","/$'a`cols); ""]
  s: s,$[`keys in k; "~k",(","/$'a`keys); ""]
  s}
kkPlanKey: {[fn;args] `$ ($fn),"|",($kkScatForceI),"|",("^"/{[a] kkArgSig a}' args)}
kk.plan: {[fn;args] key: kkPlanKey[fn;args]; $[key in !kkPlanCache; kkPlanCache key; kkPlanFresh[key;fn;args]]}
/ Rejections (kkWarn's err value) are NOT cached — they carry no reusable pipeline.
kkPlanFresh: {[key;fn;args] p: kkPlanBuild[fn;args]; $[(@p)~`"!"; p; kkStorePlan[key;p]]}
kkStorePlan: {[key;p] kkPlanCache[key]:: p; p}
kkPlanBuild: {[fn;args]
  kkPlanMisses:: kkPlanMisses + 1
  nIn: #args
  lamOf fn                                  / set Cst for the classify scans
  isTbl:  $[0<nIn; `tbl  ~ (args 0)`t; 0]
  isDict: $[0<nIn; `dict ~ (args 0)`t; 0]   / a placed dict — check BEFORE kkHasAt (dict gathers use @)
  $[isTbl;           kkPlanTable[fn;args;nIn]
    isDict;          kkPlanDict[fn;args;nIn]
    kkIsScatAdd[];   kkPlanScat[fn;args;nIn]
    kkIsAmend[];     kkPlanAmend[fn;args;nIn]
    kkIsMatReduce[]; kkPlanGathMat[fn;args;nIn]
    kkHasAt[];       kkPlanGath[fn;args;nIn]
    kkPlanMap[fn;args;nIn]]}
kk.run: {[plan;args]
  kd: plan`kind
  $[kd~`map;   kkRunMap[plan;args]
    kd~`gath;  kkRunGath[plan;args]
    kd~`gm;    kkRunGathMat[plan;args]
    kd~`amend; kkRunAmend[plan;args]
    kd~`scat;  kkRunScat[plan;args]
    kd~`tp;    kkRunTableP[plan;args]
    kd~`ti;    kkRunTableI[plan;args]
    kd~`dict;  kkRunDict[plan;args]
    plan]}
kkMiss: {[fn;nIn;key] p: gpu.compileCompute[shader.map[fn;nIn]; nIn+1]; kkCache[key]:: p; p}
/ Reject: signal an error (monadic ! on the message string) instead of warning to
/ stdout + returning !0 — kk.compile now fails loudly like any primitive.
kkWarn: {[bad;nIn] !"kk.compile: ",$[3<nIn; "more than 3 inputs unsupported"; "unsupported verb/kind ",$bad]," (elementwise subset: arith/math over x/y/z)"}
/ Key is a SYMBOL, not a string: `str in !dict` runs char-wise (a string is a char
/ vector, not an atom) and `$[]` reads the resulting non-empty vector as true — so
/ a string key makes every cache probe a false hit. Symbols are atoms → scalar in.
kkMapPipe: {[fn;nIn] key: `$ ($fn),"|",($nIn); $[key in !kkCache; kkCache key; kkMiss[fn;nIn;key]]}
kkRunMap: {[plan;args]
  a0: args 0; n: a0`n; sh: a0`s
  ob: gpu.buffer[(kkPad n)#0.]
  ih: {[d] d`gpu}' args
  gpu.dispatch[plan`pipe; ih,ob; n]
  [gpu: ob; t: `f; n: n; s: sh]}
/ ── Gather path (kk2 §2.4-3): x@y → out[d] = x[y[d]] ─────────────────────────
/ A param used as the LEFT of @ is a gather SOURCE (`buf, indexed); every other
/ param is an `elem index (auto-loaded at d). All args are placements passed
/ positionally as x/y/z; the output length = the first index's length. Pipeline
/ cached by (source|g|#inputs). (Host-vector auto-upload of free names + the
/ +/x@W matrix reduce are the next sub-steps; here both operands are placed.)
kkGMiss: {[fn;bufN;elemN;nb;key] p: gpu.compileCompute[shader.gmap[fn;bufN;elemN]; nb+1]; kkCache[key]:: p; p}
kkPlanGath: {[fn;args;nIn]
  src:   kkGathSrc[]                        / names left-of-@ (Cst set by kkPlanBuild's lamOf)
  pn:    nIn # `x`y`z
  bufN:  pn @ & pn in src
  elemN: pn @ & ~ pn in src
  nb:    #args
  key:   `$ ($fn),"|g|",($nIn)
  pipe:  $[key in !kkCache; kkCache key; kkGMiss[fn;bufN;elemN;nb;key]]
  [kind:`gath; pipe:pipe; bufN:bufN; elemN:elemN]}
kkRunGath: {[plan;args]
  pn:    (#args) # `x`y`z
  na:    pn ! args                          / param name → its descriptor
  bufN:  plan`bufN; elemN: plan`elemN
  i0:    na elemN 0                         / the primary index vector → output extent
  n:     i0`n
  ob:    gpu.buffer[(kkPad n)#0.]
  / Index the dict in kkRunGath's scope FIRST, then map handles — the inner lambda
  / can't close over `na` (ink lambdas don't capture parent locals).
  bufH:  {[d] d`gpu}' na bufN
  elemH: {[d] d`gpu}' na elemN
  gpu.dispatch[plan`pipe; bufH,elemH,ob; n]
  [gpu: ob; t: `f; n: n; s: i0`s]}

/ +/x@W matrix gather-reduce: src (left-of-@) and mat (the k×n index matrix, right-
/ of-@) are both `buf; k,n come from mat's descriptor shape and are baked into the
/ kernel (GRk/GRn → xRedGather), so the cache key carries them. Output length = n.
/ elemNames must be an empty SYMBOL vector (0#`), not !0: joining `x`y with an
/ empty INT vector upcasts to a boxed general list and breaks the env dict lookup.
kkGMMiss: {[fn;ops;k;n;key] GRk::k; GRn::n; p: gpu.compileCompute[shader.gmap[fn;ops;0#`]; (#ops)+1]; kkCache[key]:: p; p}
/ Resolve a gather operand NAME → its device descriptor: a param (x/y/z) reads the
/ passed placement; any other name is a host global numeric vector/matrix that gets
/ auto-uploaded read-only (kk2 §2.1-2), so walk.k's `W`,`I` can travel as globals.
/ `. nm` is the value of the global named nm; gpu.hold flattens+records its shape.
/ `gpu.hold . nm` would parse `.` as DYADIC (gpu.hold on its left) → apply, not
/ value; take the value in its own statement so `.` is monadic, then upload.
kkUpload: {[nm] v: . nm; gpu.hold v}
kkResolve: {[nm;na;pn] $[nm in pn; na nm; kkUpload nm]}
kkPlanGathMat: {[fn;args;nIn]
  ops: kkMatOperands[]                      / (srcName; matName), both `buf
  pn:  nIn # `x`y`z
  na:  pn ! args
  / two operands, unrolled — an each-lambda here couldn't see na/pn (no closure).
  md:  kkResolve[ops 1; na; pn]
  msh: md`s                                 / the matrix's (k;n) shape
  k:   msh 0; n: msh 1
  GRk:: k; GRn:: n
  key: `$ ($fn),"|m|",($k),"|",($n)
  pipe: $[key in !kkCache; kkCache key; kkGMMiss[fn;ops;k;n;key]]
  [kind:`gm; pipe:pipe; ops:ops; n:n]}
kkRunGathMat: {[plan;args]
  pn:  (#args) # `x`y`z
  na:  pn ! args
  ops: plan`ops
  sd:  kkResolve[ops 0; na; pn]
  md:  kkResolve[ops 1; na; pn]
  n:   plan`n
  ob:  gpu.buffer[(kkPad n)#0.]
  bufH: {[d] d`gpu}' (sd; md)               / (src; mat) handles in binding order
  gpu.dispatch[plan`pipe; bufH,ob; n]
  [gpu: ob; t: `f; n: n; s: ,n]}
/ Amend-scatter @[x;I;:;v]: one thread per interior index; out[I[d]] = v (v reads
/ x through the neighbour matrix W). I is padded to the ×64 grid with a sentinel
/ index (= full length) that lands in out's padding, so over-dispatched threads
/ don't clobber a live cell. Output = a COPY of x with the I positions rewritten
/ (a single Jacobi step); iterate with kk.loop for the ping-pong solve.
kkAMiss: {[fn;src;mat;idx;k;n;key] GRk::k; GRn::n; p: gpu.compileCompute[shader.amend[fn;src;mat;idx]; 4]; kkCache[key]:: p; p}
/ Prep the padded I buffer + a fresh out buffer that copies xbuf and reserves a
/ sentinel-padding tail. Returns (idBuf; outBuf; xn). n=#I, xn=full length.
kkAmendBufs: {[idxName; xbuf; xn; n]
  iv:  . idxName
  idBuf: gpu.buffer[(`f$ iv) , (kkPad[n] - n) # `f$ xn]
  outBuf: gpu.buffer[(gpu.read xbuf) , 64 # 0.]
  (idBuf; outBuf)}
kkAmendPipe: {[fn;srcName;matName;idxName;k;n]
  key: `$ ($fn),"|a|",($k),"|",($n)
  $[key in !kkCache; kkCache key; kkAMiss[fn;srcName;matName;idxName;k;n;key]]}
kkPlanAmend: {[fn;args;nIn]
  info: kkAmendInfo[]                       / (srcName; idxName)
  srcName: info 0; idxName: info 1
  matName: (kkMatOperands[]) 1              / W from the inner x@W gather
  pn: nIn # `x`y`z
  na: pn ! args
  md: kkResolve[matName; na; pn]            / W host global (k;n)
  msh: md`s; k: msh 0; n: msh 1
  GRk:: k; GRn:: n
  pipe: kkAmendPipe[fn;srcName;matName;idxName;k;n]
  [kind:`amend; pipe:pipe; srcName:srcName; matName:matName; idxName:idxName; mn:n]}
kkRunAmend: {[plan;args]
  pn: (#args) # `x`y`z
  na: pn ! args
  sd: kkResolve[plan`srcName; na; pn]       / x0 placement (full array)
  md: kkResolve[plan`matName; na; pn]       / W host global (k;n)
  n:  plan`mn
  xn: sd`n
  bufs: kkAmendBufs[plan`idxName; sd`gpu; xn; n]
  idBuf: bufs 0; out: bufs 1
  gpu.dispatch[plan`pipe; (sd`gpu; md`gpu; idBuf; out); n]
  [gpu: out; t:`f; n: xn; s: sd`s]}

/ Scatter-add @[x;I;+;v]: one thread per index; acc[I[d]] += v atomically. x is
/ expected zero-initialised; I is padded with a sentinel into acc's padding tail so
/ over-dispatched threads add harmlessly. v is a constant or a single value vector
/ (bindings after acc,I). n=#I threads.
/ TWO lowerings (§7): when gpu.caps reports atomicFadd (native f32 buffer atomics),
/ acc is an f32 accumulator hit by OpAtomicFAddEXT → the value adds WITHOUT integer
/ truncation (weighted float accumulation, no fixed-point scaling), result tagged
/ `f (gpu.fetch reads floats). When caps=0 (or kkScatForceI is set), the i32
/ fixed-point path is used and the result is tagged `i (gpu.readI). Set kkScatForceI
/ to force the integer path (exact integer histograms / testing the fallback).
kkScatForceI:: 0                          / 1 → always use the i32 path
kkFA:: -1                                 / cached caps.atomicFadd (−1 = not yet queried)
kkQFA:  {[] kkFA:: `i$ (gpu.caps[0])`atomicFadd; kkFA}
kkUseFA: {[] $[kkScatForceI; 0; kkFA > -1; kkFA; kkQFA[]]}
kkSMiss: {[fn;vbn;fa;key] p: gpu.compileCompute[$[fa; shader.scataddf[fn;vbn]; shader.scatadd[fn;vbn]]; 2 + #vbn]; kkCache[key]:: p; p}
kkIvals: {[idxName; idd; pn] $[idxName in pn; gpu.read idd`gpu; `f$ . idxName]}
kkPlanScat: {[fn;args;nIn]
  info: kkScatInfo[]; accName: info 0; idxName: info 1
  vbn: kkScatVbufs[accName; idxName]        / value-vector operand names in v (0 or 1)
  pn: nIn # `x`y`z
  na: pn ! args
  idd: kkResolve[idxName; na; pn]           / I index (for the baked thread count)
  GRk:: 0; GRn:: idd`n
  fa: kkUseFA[]                             / native f32 atomics available (and not forced off)?
  key: `$ ($fn),"|s|",($#vbn),$[fa;"f";"i"]
  pipe: $[key in !kkCache; kkCache key; kkSMiss[fn;vbn;fa;key]]
  [kind:`scat; pipe:pipe; accName:accName; idxName:idxName; vbn:vbn; fa:fa]}
kkRunScat: {[plan;args]
  pn: (#args) # `x`y`z
  na: pn ! args
  accName: plan`accName; idxName: plan`idxName; vbn: plan`vbn; fa: plan`fa
  ad: kkResolve[accName; na; pn]            / accumulator placement (zero-inited)
  idd: kkResolve[idxName; na; pn]           / I index
  n: idd`n; an: ad`n
  ivals: kkIvals[idxName; idd; pn]
  idBuf: gpu.buffer[ivals , (kkPad[n] - n) # `f$ an]     / sentinel = an → acc padding
  acc: gpu.buffer[(an + 64) # 0.]           / accumulator (zeros) + slack; f32 or i32 by fa
  vHnd: $[0=#vbn; !0; ,(kkResolve[vbn 0; na; pn])`gpu]
  gpu.dispatch[plan`pipe; (acc; idBuf), vHnd; n]
  [gpu: acc; t:$[fa;`f;`i]; n: an; s: ad`s]}
/ kk.loop[f; x0; niter] — iterate an amend `f:{@[x;I;:;v]}` niter times on the GPU
/ with a ping-pong: two full-size buffers, each pass reads one and writes the other
/ (Jacobi needs the previous sweep's values). Runs in ONE encoder (gpu.dispatchLoop,
/ no per-step host sync). Both buffers start as a copy of x0 so the non-interior
/ (boundary) cells carry through unchanged. Returns the result descriptor.
kk.loop: {[f; x0; niter]
  lamOf f
  info: kkAmendInfo[]; srcName: info 0; idxName: info 1
  matName: (kkMatOperands[]) 1
  md: kkUpload matName                      / W (k;n) host global
  msh: md`s; k: msh 0; n: msh 1
  GRk:: k; GRn:: n
  pipe: kkAmendPipe[f;srcName;matName;idxName;k;n]
  xn: x0`n
  x0v: (gpu.read x0`gpu) , 64 # 0.          / initial state + sentinel padding
  A: gpu.buffer[x0v]; B: gpu.buffer[x0v]
  iv: . idxName
  idBuf: gpu.buffer[(`f$ iv) , (kkPad[n] - n) # `f$ xn]
  gpu.dispatchLoop[pipe; (A;md`gpu;idBuf;B); (B;md`gpu;idBuf;A); n; niter]
  / pass 0 (config A) writes B, pass 1 (config B) writes A, … → odd niter lands in
  / B, even in A (verified against a single f-step).
  res: $[0 = niter mod 2; A; B]
  [gpu: res; t:`f; n: xn; s: x0`s]}

/ kk.converge[f; x0; tol; maxIter] — device-side converge (kk2 §6): iterate the
/ amend sweep `f` in batches on the GPU, and every CVstride sweeps measure the
/ change `|/abs(new-old)` with the whole-buffer reduce; stop once it drops below
/ `tol` (or `maxIter` sweeps elapse). This replaces walk.k's bit-fixpoint grind
/ (`f/`, a fixed 30k `kk.loop`) with a tolerance the solver decides — the device
/ does the sweeps AND the max-abs-diff reduce; the host only reads one float per
/ batch (periodic readback). CVstride is even, so a batch always lands back in A.
/ State carried through the while-adverb is (sweepsDone; lastMaxDiff); the shared
/ context lives in CV* globals (ink lambdas don't close over kk.converge's locals).
CVa:: 0; CVsnap:: 0; CVpipe:: 0; CVca:: (); CVcb:: (); CVn:: 0
CVstride:: 100; CVtol:: 0.; CVmax:: 0; CVcur:: (); CVsnp:: (); CVxn:: 0; CVs:: ()
cvCond: {[s] ((s 1) > CVtol) & (s 0) < CVmax}
cvBody: {[s]
  gpu.write[CVsnap; gpu.read CVa]                 / checkpoint current state
  gpu.dispatchLoop[CVpipe; CVca; CVcb; CVn; CVstride]   / CVstride sweeps → back in A
  dd: kk.compile[{abs[x-y]}; (CVcur; CVsnp)]      / elementwise |Δ| over the batch
  ((s 0) + CVstride; kk.max dd)}                  / (sweepsDone; maxΔ)
kk.converge: {[f; x0; tol; maxIter]
  lamOf f
  info: kkAmendInfo[]; srcName: info 0; idxName: info 1
  matName: (kkMatOperands[]) 1
  md0: kkUpload matName                      / W (k;n) host global
  msh: md0`s; k: msh 0; n: msh 1
  GRk:: k; GRn:: n
  pipe: kkAmendPipe[f;srcName;matName;idxName;k;n]
  xn: x0`n
  x0v: (gpu.read x0`gpu) , 64 # 0.
  A: gpu.buffer[x0v]; B: gpu.buffer[x0v]; snap: gpu.buffer[x0v]
  iv: . idxName
  idBuf: gpu.buffer[(`f$ iv) , (kkPad[n] - n) # `f$ xn]
  CVa:: A; CVsnap:: snap; CVpipe:: pipe; CVn:: n
  CVca:: (A; md0`gpu; idBuf; B); CVcb:: (B; md0`gpu; idBuf; A)
  CVtol:: tol; CVmax:: maxIter; CVxn:: xn; CVs:: x0`s
  CVcur:: [gpu: A; t: `f; n: xn; s: x0`s]
  CVsnp:: [gpu: snap; t: `f; n: xn; s: x0`s]
  fin: cvCond cvBody/ (0; tol + 1.)               / while maxΔ>tol & sweeps<maxIter
  CVlast:: fin                                    / (sweepsDone; finalMaxΔ) — observability
  [gpu: A; t: `f; n: xn; s: x0`s]}
/ Placed-table map (kk2 §2.5): the referenced column names come from the CST
/ (kkTableColNames). Layout is chosen at placement (gpu.holdT) and recorded on the
/ descriptor's `lay key; the SAME lambda compiles under either:
/   planar:      bind only the columns the body reads (nc+1 bindings).
/   interleaved: bind the one data buffer + output (2 bindings), positions baked.
/ The cache key carries the layout tag so the two never collide.
kkTMiss:  {[fn;tn;cn;nc;key] p: gpu.compileCompute[shader.table[fn;tn;cn]; nc+1]; kkCache[key]:: p; p}
kkTIMiss: {[fn;tn;allCols;key] p: gpu.compileCompute[shader.tableI[fn;tn;allCols]; 2]; kkCache[key]:: p; p}
kkPlanTable: {[fn;args;nIn]
  td: args 0
  cn: kkTableColNames[]                      / distinct columns actually read
  tn: kkTableName[]
  $[(td`lay)~`il; kkPlanTableI[fn;td;tn]; kkPlanTableP[fn;td;cn;tn]]}
kkPlanTableP: {[fn;td;cn;tn]
  nc: #cn
  key: `$ ($fn),"|t|",(","/$'cn)
  pipe: $[key in !kkCache; kkCache key; kkTMiss[fn;tn;cn;nc;key]]
  [kind:`tp; pipe:pipe; cn:cn]}
kkRunTableP: {[plan;args]
  td: args 0
  n: td`n
  colH: (td`hand) (td`cols) ? plan`cn        / handles for the referenced columns
  ob: gpu.buffer[(kkPad n)#0.]
  gpu.dispatch[plan`pipe; colH, ob; n]
  [gpu: ob; t:`f; n: n; s: ,n]}
kkPlanTableI: {[fn;td;tn]
  allCols: td`cols                           / full ordering — positions in the row
  key: `$ ($fn),"|ti|",(","/$'allCols)
  pipe: $[key in !kkCache; kkCache key; kkTIMiss[fn;tn;allCols;key]]
  [kind:`ti; pipe:pipe]}
kkRunTableI: {[plan;args]
  td: args 0
  n: td`n
  ob: gpu.buffer[(kkPad n)#0.]
  gpu.dispatch[plan`pipe; (td`hand; ob); n]
  [gpu: ob; t:`f; n: n; s: ,n]}
/ kk.compile = plan then run. An unsupported body returns kkWarn's err value from
/ kk.plan (never cached); pass it straight through instead of dispatching it.
kk.compile: {[fn; args] p: kk.plan[fn;args]; $[(@p)~`"!"; p; kk.run[p;args]]}
/ Placed-dict gather (kk2 §2.5): bind each referenced key as a gather source (used
/ left of @) or index/value; output extent = the primary index key's length. The
/ same keyed buffers a dict placed (gpu.holdD) drop in by name.
kkDMiss: {[fn;dn;srcKeys;elemKeys;key] p: gpu.compileCompute[shader.dict[fn;dn;srcKeys;elemKeys]; (#srcKeys)+(#elemKeys)+1]; kkCache[key]:: p; p}
kkPlanDict: {[fn;args;nIn]
  dd: args 0
  dn: kkTableName[]                          / the dict var (same (D`k) apposit shape)
  refKeys: kkTableColNames[]                 / distinct keys read
  srcKeys: kkDictSrcKeys[dn]
  elemKeys: refKeys @ & ~ refKeys in srcKeys
  keys: srcKeys, elemKeys                    / binding order: sources then indices
  key: `$ ($fn),"|dg|",(","/$'keys)
  pipe: $[key in !kkCache; kkCache key; kkDMiss[fn;dn;srcKeys;elemKeys;key]]
  [kind:`dict; pipe:pipe; elemKeys:elemKeys; keys:keys]}
kkRunDict: {[plan;args]
  dd: args 0
  n: (dd`lens) (dd`keys) ? *(plan`elemKeys)  / output length = primary index length
  handles: (dd`hand) (dd`keys) ? (plan`keys)
  ob: gpu.buffer[(kkPad n)#0.]
  gpu.dispatch[plan`pipe; handles, ob; n]
  [gpu: ob; t:`f; n: n; s: ,n]}
kkPlanMap: {[fn;args;nIn]
  bad: kkClassify fn
  $[(bad~`) & ~3<nIn; [kind:`map; pipe: kkMapPipe[fn;nIn]]; kkWarn[bad;nIn]]}

/ ── Whole-buffer reduce (kk2 §6): +/d over a placement → a host scalar ─────────
/ Two-stage fallback (dye's shader.reduce): stage 1 dispatches P grid-strided
/ threads → P partials; stage 2 folds the P partials on one thread → the scalar,
/ read back at 8:. op ∈ `sum`max`min`prod (identity+combine baked into the kernel).
/ P (partial count) is a multiple of the 64-wide workgroup. n is passed through the
/ uniform as an f32, so this is exact only up to 2^24 elements (the usual f32 cliff).
/ Float reduction reorders the sum, so the result matches CPU +/ to a relative
/ tolerance, not bit-for-bit (integer/exact reductions do match).
kkRedP:: 256
kkRedMiss: {[op;key] p: gpu.compileComputeU[shader.reduce[op]; 2]; kkCache[key]:: p; p}
kkRedPipe: {[op]
  key: `$ "reduce|",$op
  $[key in !kkCache; kkCache key; kkRedMiss[op;key]]}
/ Two-dispatch FALLBACK reduce (grid-strided serial per thread).
kkReduceFb: {[op; d]
  pipe: kkRedPipe op
  n: d`n
  P: kkRedP
  km: 1 | `i$ (n + P - 1) div P
  part: gpu.buffer[P # 0.]
  u1: gpu.uniform[(`i$n; `i$P; `i$km; 0)]       / i32 counts (exact to 2^31; exact past 2^24)
  gpu.dispatch[pipe; (d`gpu; part; u1); P]
  res: gpu.buffer[64 # 0.]
  u2: gpu.uniform[(`i$P; 1; `i$P; 0)]
  gpu.dispatch[pipe; (part; res; u2); 1]
  *gpu.read res}
/ Subgroup fast path (§6): stage 1 dispatches G workgroups × S (subgroup) lanes and
/ folds each workgroup with one OpGroupNonUniformFAdd → G partials; stage 2 folds the
/ G partials with a single workgroup. Same numeric contract as the fallback (reordered
/ float sums → CPU parity to a tolerance). Selected when gpu.caps sgArith is set.
kkRedSgMiss: {[op;S;key] p: gpu.compileComputeU[shader.reduceSg[op;S]; 2]; kkCache[key]:: p; p}
kkRedSgPipe: {[op;S] key: `$ "reduceSg|",($op),"|",($S); $[key in !kkCache; kkCache key; kkRedSgMiss[op;S;key]]}
kkReduceSg: {[op; d; S]
  pipe: kkRedSgPipe[op; S]
  n: d`n
  G: kkRedP                                / workgroups (partials)
  T1: G*S                                  / stage-1 total threads (grid-stride span)
  km1: 1 | `i$ (n + T1 - 1) div T1
  part: gpu.buffer[G # 0.]
  u1: gpu.uniform[(`i$n; `i$T1; `i$km1; 0)]     / i32 counts (exact to 2^31; exact past 2^24)
  gpu.dispatch[pipe; (d`gpu; part; u1); T1]     / T1 threads, LocalSize S → G workgroups
  res: gpu.buffer[64 # 0.]
  km2: 1 | `i$ (G + S - 1) div S
  u2: gpu.uniform[(`i$G; `i$S; `i$km2; 0)]
  gpu.dispatch[pipe; (part; res; u2); S]        / S threads → one workgroup → scalar
  *gpu.read res}
/ Cache the device caps once (needs a live device — queried on first reduce).
kkCaps:: ()
kkGetCaps: {[] $[0=#kkCaps; kkCaps:: gpu.caps[0]; 0]; kkCaps}
kkRedForceFb:: 0                            / force the fallback (test both paths)
kk.reduce: {[op; d]
  c: kkGetCaps[]
  $[(~kkRedForceFb) & c`sgArith; kkReduceSg[op; d; c`subgroup]; kkReduceFb[op; d]]}
kk.sum:  {[d] kk.reduce[`sum;  d]}
kk.max:  {[d] kk.reduce[`max;  d]}
kk.min:  {[d] kk.reduce[`min;  d]}
kk.prod: {[d] kk.reduce[`prod; d]}

/ ── Prefix scan +\d (kk2 tier-2): inclusive running combine over a placement ────
/ Three dispatches over P=256 contiguous chunks (chunk = ceil(n/P)): scanBlock does
/ each chunk's local scan + total, scanPartials exclusive-scans the P totals, and
/ addOffset folds each chunk's offset back in. out is padded to P*chunk (stores stay
/ in-bounds, chunks disjoint). Returns a placement (like the input); op selects the
/ running combine. As with kk.reduce, n rides an f32 uniform (exact to 2^24); float
/ scans reorder within a chunk so results match CPU +\ to a relative tolerance.
kkScanBMiss: {[op;key] p: gpu.compileComputeU[shader.scanBlock[op]; 3]; kkCache[key]:: p; p}
kkScanPMiss: {[op;key] p: gpu.compileCompute[shader.scanPartials[op]; 2]; kkCache[key]:: p; p}
kkScanAMiss: {[op;key] p: gpu.compileComputeU[shader.addOffset[op]; 2]; kkCache[key]:: p; p}
kkScanPipe: {[which;op;miss] key: `$ which,"|",$op; $[key in !kkCache; kkCache key; miss[op;key]]}
kk.scan: {[op; d]
  n: d`n
  P: kkRedP
  ck: 1 | `i$ (n + P - 1) div P
  m: P*ck
  pB: kkScanPipe["scanB";op;kkScanBMiss]
  pP: kkScanPipe["scanP";op;kkScanPMiss]
  pA: kkScanPipe["scanA";op;kkScanAMiss]
  ob: gpu.buffer[m # 0.]
  bt: gpu.buffer[P # 0.]
  bo: gpu.buffer[P # 0.]
  u1: gpu.uniform[(`i$n; `i$ck; 0; 0)]          / i32 counts (exact to 2^31; exact past 2^24)
  gpu.dispatch[pB; (d`gpu; ob; bt; u1); P]
  gpu.dispatch[pP; (bt; bo); P]
  u2: gpu.uniform[(`i$ck; 0; 0; 0)]
  gpu.dispatch[pA; (ob; bo; u2); P]
  [gpu: ob; t: `f; n: n; s: d`s]}
kk.sums:  {[d] kk.scan[`sum; d]}
kk.maxs:  {[d] kk.scan[`max; d]}
kk.mins:  {[d] kk.scan[`min; d]}

/ ── Compaction &mask (kk2 tier-2): indices where the mask is true ─────────────
/ The monadic `&` (Where) on a placed 0/1 mask: inclusive-scan the mask for output
/ positions, reduce it for the true count, then one scatter dispatch writes each true
/ index into its slot (shader.compact). Returns a placement of the (float) indices,
/ length = true count — so `kk.where mask` mirrors `&mask` on the CPU. Value
/ compaction `x@&mask` composes for free: kk.compile[{x@y}; (x; kk.where mask)].
kkWhereMiss: {[key] p: gpu.compileComputeU[shader.compact[]; 3]; kkCache[key]:: p; p}
kk.where: {[d]
  n: d`n
  incl: kk.sums d                                / inclusive prefix scan of the mask
  total: `i$ kk.sum d                            / count of trues (syncs → incl is final)
  pipe: $[`compact in !kkCache; kkCache `compact; kkWhereMiss[`compact]]
  ob: gpu.buffer[(total + 64) # 0.]              / true-count elements + sentinel slack
  u:  gpu.uniform[(`i$n; `i$total; 0; 0)]        / i32 counts (exact to 2^31; exact past 2^24)
  gpu.dispatch[pipe; (d`gpu; incl`gpu; ob; u); n]
  [gpu: ob; t: `f; n: total; s: ,total]}

/ ── Histogram #'=d (kk2 tier-2): bucket counts via one scatter-add dispatch ─────
/ kk.freq[d; nb] counts how many of the integer indices in d fall in each of nb
/ buckets — the device form of the CPU freq peephole `@[nb#0; d; +; 1]`. d is a
/ placement (from a prior kk stage) or a plain host vector; the count kernel is the
/ existing scatter-add path (kk.plan's `scat` kind) with a constant +1 per index, so this is a
/ thin wrapper. Returns a placement of counts (length nb); 8: it to read back.
/ Native f32 atomics accumulate 1.0 exactly (< 2^24 counts); the i32 fallback is
/ exact by construction. The index rides a module global (baked/uploaded as the
/ scatter index) — the kernel LAMBDA must be a named global so its source keys the
/ pipeline cache, and gpu.read[d`gpu] must bracket-apply (a bare `gpu.read d`gpu`
/ misparses as `(gpu.read d)`gpu`).
kkFreqI:: !0
kkFreqK:  {@[x; kkFreqI; +; 1.]}
kk.freq: {[d; nb]
  kkFreqI:: $[`m ~ @d; gpu.read[d`gpu]; `f$ d]
  kk.compile[kkFreqK; ,gpu.hold[nb#0.]]}

/ ── Group =d (kk2 §5 / kk.md §2): bucketed CSR permutation via atomic cursors ────
/ kk.group[d; nb] partitions the n integer bucket-ids in d into a CSR layout: counts
/ (kk.freq), exclusive offsets off[b] = Σ counts[0..b-1] (kk.sums − counts), and a
/ permutation `perm` of !n such that bucket b owns perm[off[b] .. off[b]+counts[b]).
/ One thread per element scatters its index into its bucket slot using a per-bucket
/ ATOMIC CURSOR: pos = atomicAdd(cursor[b], 1) is the OLD cursor value (the i32
/ scatter-add returns it — xLoSadd's `old`), so pos is this element's rank within its
/ bucket and off[b]+pos its global slot. Atomics race → intra-bucket order is
/ NONDETERMINISTIC (unlike CPU =d's stable order), but the SET per bucket and the
/ counts are exact, and d@perm is non-decreasing (correctness the oracle checks
/ order-independently). Over-dispatched threads (i≥n) read element 0 (clamped),
/ add 0 to the cursor (ok=0.) and park their write at perm[i] in the ×64 padding.
/ Returns the perm placement with `off/`cnt sub-placements attached (8: any of them).
kkGrpK: gpu.kernel[{[cursor; d; off; g; perm; i]
  n:  `i$ g[0]
  ok: $[i<n; 1.; 0.]
  ii: $[i<n; i; 0]                          / clamp the read for over-dispatched threads
  b:  `i$ d[ii]
  pos: scatterAdd[cursor; b; ok]            / OLD cursor value = rank within bucket b
  slot: $[i<n; (`i$ off[b]) + pos; i]       / i≥n → park in perm's padding at perm[i]
  set[perm; slot; `f$ i]}; 1; 4]
kkGrpPipe:: 0
kk.group: {[d; nb]
  dd:  $[`m ~ @d; d; gpu.hold `f$ d]         / accept a placement or a host vector
  cnt: kk.freq[dd; nb]                       / bucket counts (placement, length nb)
  off: kk.compile[{x-y}; (kk.sums cnt; cnt)] / exclusive offsets = inclusive scan − counts
  n:   dd`n
  $[kkGrpPipe=0; kkGrpPipe:: gpu.compileCompute[kkGrpK; 5]; 0]
  cur: gpu.buffer[(nb + 64) # 0.]            / per-bucket atomic cursors (zeroed, i32)
  g:   gpu.buffer[(`f$ n) , 63 # 0.]         / g[0] = element count (over-dispatch guard)
  perm: gpu.buffer[(kkPad n) # 0.]           / output permutation (padding parks OOB writes)
  gpu.dispatch[kkGrpPipe; (cur; dd`gpu; off`gpu; g; perm); n]
  [gpu: perm; t: `f; n: n; s: ,n; off: off; cnt: cnt]}
