/ lib/dye.k — the dye compiler: ink shader front-end + optimizer + SPIR-V codegen.
/
/ dye is to ink what q is to k: a language layer that compiles ink lambdas to GPU
/ shaders. It owns the CST walk (via `parse`), the shader type system, the module
/ state (id counter + word buffers), module assembly, and the public entry points
/ (shader.fragment / shader.vertex / shader.compute / shader.stencil / gpu.kernel / …).
/ It emits SPIR-V words through the pure instruction stencils in lib/spirv.k.
/
/ Tiramisu 4-layer model (doc/papers/baghdadi_2019_tiramisu.md):
/   Layer 1 (Abstract Algorithm)  : ink lambda AST via `parse`
/   Layer 2 (Computation Mgmt)    : type-annotate, schedule (trivial for shaders)
/   Layer 3 (Data Mgmt)           : assign SPIR-V IDs, emit typed sections
/   Layer 4 (Communication Mgmt)  : assemble SPIR-V binary in spec order
/
/ Load with:  2: "lib/dye.k"   (pulls in the encoder itself).
2: "lib/spirv.k"

/ ── Layer 1+2: public shader compiler ───────────────────────────────────────
/ shader.fragment[ioTypes; fn] → SPIR-V word list (int list)
/ ioTypes: dict of arg_name→type_sym, plus `out for the output type
/          type symbols: `f32 `v4 `v2 `v3 `i32 `bool
/ fn:      ink lambda whose args become shader inputs, return value → output
/ Lambdas can have local bindings: {[uv] d: sqrt[...]; (d;d;d;1.0)}
shader.fragment: {[ioTypes; fn]
  Nid::Nfixed; Buf::(); Con::(); ConKeyT::(); ConKeyV::(); ConVal::()
  TexVars:: ()                      / no texture section (see shader.fragmentTexN)

  lam: lamOf fn
  argNames: lamArgs lam

  outTySym: ioTypes[`out]
  outTy:  Tid[outTySym]
  outPtr: PtrOut[outTySym]
  inTySyms: ioTypes' argNames
  inTys:  Tid'  inTySyms
  inPtrs: PtrIn' inTySyms

  inVarIds: {[x] newId[]}' argNames
  outId: newId[]

  loadedPairs: inVarIds loadOnePair' inTySyms
  env: argNames!loadedPairs

  / Body through the neutral IR (kk2 §3) — byte-identical to the retired direct walk
  rp: kSeqIr[lamBody lam; env; outTySym]

  emitBuf opStore[outId; rp 0]

  locs: !#argNames
  buildMod[outId; inVarIds; inTys; inPtrs; outPtr; locs]
}

/ ── shader.fragmentTexN[ioTypes; nTex; fn] → SPIR-V word list ────────────────
/ Like shader.fragment, plus nTex sampled 2-D textures at @group(1): image k is at
/ binding k, and one shared sampler at binding nTex.  The body samples texture k
/ with  sample[k; uv]  → v4 (sample[uv] is texture 0).  See xSample.  The host
/ wires the textures with gpuTexture + mesh.drawT/mesh.drawGeomT/mesh.drawInstancedT, passing
/ a list of texture handles.  Interpolate the UV(s) as v2 vertex varyings.
shader.fragmentTexN: {[ioTypes; nTex; fn]
  Nid::Nfixed; Buf::(); Con::(); ConKeyT::(); ConKeyV::(); ConVal::()

  lam: lamOf fn
  argNames: lamArgs lam

  outTySym: ioTypes[`out]
  outTy:  Tid[outTySym]
  outPtr: PtrOut[outTySym]
  inTySyms: ioTypes' argNames
  inTys:  Tid'  inTySyms
  inPtrs: PtrIn' inTySyms

  inVarIds: {[x] newId[]}' argNames
  outId: newId[]

  / Allocate the texture ids and publish them so xSample can emit the loads.
  / One image type / sampler type shared by all nTex images; one var per image
  / plus one shared sampler var.
  Timg2::   newId[]; Tsamp2::  newId[]; TsImg::   newId[]
  PUCimg::  newId[]; PUCsamp:: newId[]
  TexVars:: {[x] newId[]}' !nTex
  SampVar:: newId[]

  loadedPairs: inVarIds loadOnePair' inTySyms
  env: argNames!loadedPairs

  rp: kSeqIr[lamBody lam; env; outTySym]

  emitBuf opStore[outId; rp 0]

  locs: !#argNames
  buildMod[outId; inVarIds; inTys; inPtrs; outPtr; locs]
}

/ Single-texture convenience: sample[uv] samples the one texture.
shader.fragmentTex: {[ioTypes; fn] shader.fragmentTexN[ioTypes; 1; fn]}

/ ── shader.vertex[inTypes; varyTypes; fn] → SPIR-V word list ─────────────────
/ inTypes:   dict argName→typeSym  (vertex attribute inputs, e.g. `pos`nor!`v3`v3)
/ varyTypes: dict name→typeSym     (interpolated varyings; use ()!() for none)
/ fn:        lambda returning (glPos_v4; vary0; ...) or just glPos_v4 if no varyings
/
/ gl_Position is always the first return element; emitted via the gl_PerVertex
/ Block struct (required by Vulkan/SPIR-V spec).  Varyings get Location 0,1,...
/ and must match the shader.fragment's input Location assignments.
shader.vertex: {[inTypes; varyTypes; fn] shader.vertexU[inTypes; varyTypes; (); fn]}

/ ── shader.vertexU[inTypes; varyTypes; uniNames; fn] ─────────────────────────
/ Like shader.vertex, plus a uniform block at @group(0) @binding(0).  uniNames is
/ a list of symbols, one per vec4 uniform slot; each becomes a v4 value in the
/ shader body (index components with name[i]).  The host fills the slots per draw
/ via mesh.drawU (slot k = uniform floats 4k..4k+3).  uniNames:() ⇒ no block, and
/ the emitted module is byte-identical to the old shader.vertex.
shader.vertexU: {[inTypes; varyTypes; uniNames; fn]
  Nid::Nfixed; Buf::(); Con::(); ConKeyT::(); ConKeyV::(); ConVal::()

  lam:      lamOf fn
  argNames: lamArgs lam

  inTySyms: inTypes' argNames
  inPtrs:   PtrIn'   inTySyms
  inVarIds: {[x] newId[]}' argNames

  loadedPairs: inVarIds loadOnePair' inTySyms
  env:         argNames!loadedPairs

  / gl_PerVertex block types and variable (Position must live in a Block struct)
  TperVtx:   newId[]   / OpTypeStruct { vec4 }
  PperVtx:   newId[]   / OpTypePointer Output TperVtx
  perVtxVar: newId[]   / the output block variable
  Kzero:     newId[]   / i32 constant 0 for struct member access
  emitCon opConst[Ti32; Kzero; 0]

  / Varying outputs
  varyNames:  !varyTypes
  varyTySyms: varyTypes' varyNames
  varyPtrs:   PtrOut' varyTySyms
  varyVarIds: {[x] newId[]}' varyNames
  nVary:      #varyVarIds

  / ── Uniform block @group(0) @binding(0): nUni vec4 members (std140) ─────────
  / Member i lives at byte offset i*16.  Emit the access-chain+load for each into
  / the body (before the user code), and extend env with name→loaded-v4.
  / The per-member each-helpers run as top-level functions (memberDecOne /
  / loadUniMember) reading globals UTuni/UPv4/UVar, because ink lambdas do NOT
  / close over enclosing locals — a `{[i] ..Tuni..}` inline lambda would see Tuni
  / as undefined and emit malformed (boxed/partial) words.
  nUni:    #uniNames
  Tuni:    $[nUni>0; newId[]; 0]   / OpTypeStruct { vec4 × nUni }
  Puni:    $[nUni>0; newId[]; 0]   / OpTypePointer Uniform Tuni
  PuniV4:  $[nUni>0; newId[]; 0]   / OpTypePointer Uniform vec4
  uniVar:  $[nUni>0; newId[]; 0]   / the uniform block variable
  UTuni::Tuni; UPv4::PuniV4; UVar::uniVar
  uniKIdx: $[nUni>0; {[x] r:newId[]; emitCon opConst[Ti32;r;x]; r}'!nUni; !0]
  uniPairs:$[nUni>0; loadUniMember' uniKIdx; ()]
  / Merge uniforms into env only when present: joining a symbol vector with the
  / empty list () upcasts it to a boxed general list and breaks dict key lookup,
  / so leave env untouched in the no-uniform case (keeps output byte-identical).
  env:     $[nUni>0; (argNames,uniNames)!(loadedPairs,uniPairs); argNames!loadedPairs]

  / Body through the neutral IR (kk2 §3): bind nodes first (xSeqEnv, mirror of the
  / retired compSeqEnv), then gl_Position + each varying, every store pinned by a
  / `vstore effect node at the position the direct path emitted it, so lowering
  / in build order reproduces the id sequence exactly (record-then-replay).
  stmts:    lamBody lam
  lastStmt: last stmts

  / If varyings exist the last stmt is a list node; else it's the glPos expression
  outElems: $[(nVary>0) & ((kKind lastStmt)~`list); kF[lastStmt;`elem]; ,lastStmt]

  VXpvtx:: perVtxVar; VXkz:: Kzero
  xReset[]
  e0:   (!env) ! kIrEnvOne' env[!env]
  env2: xSeqEnv[-1_stmts; e0]

  gp: xNode[outElems[0]; env2; `v4]
  xEmit[`vstore; `v4; ,gp 0; `pos]
  $[nVary>0; xVary1[outElems[1]; varyTySyms[0]; varyVarIds[0]; env2]; 0]
  $[nVary>1; xVary1[outElems[2]; varyTySyms[1]; varyVarIds[1]; env2]; 0]
  $[nVary>2; xVary1[outElems[3]; varyTySyms[2]; varyVarIds[2]; env2]; 0]
  $[nVary>3; xVary1[outElems[4]; varyTySyms[3]; varyVarIds[3]; env2]; 0]
  xLowerC[!0]                        / no value root — the vstore effects are the roots

  / Assemble SPIR-V module (SPIR-V 1.4: OpEntryPoint lists EVERY global
  / variable, so the uniform block joins the I/O interface when present)
  bnd:   Nid+1
  iface: inVarIds,(,perVtxVar),varyVarIds,$[nUni>0; ,uniVar; !0]

  hdr: (0x07230203; 0x00010400; 0; bnd; 0)
  cap: (0x00020011; 1)
  ext: (0x0006000B; Glsl; 0x4C534C47; 0x6474732E; 0x3035342E; 0)
  mem: (0x0003000E; 0; 1)
  ep:  (0x000F+(0x10000*(5+#iface)); 0; Fmain; 0x6E69616D; 0), iface

  decIn:   ,/ inVarIds decInOne' !#inVarIds
  decBlk:  (0x00030047; TperVtx; 2)
  decPos:  (0x00050048; TperVtx; 0; 11; 0)
  decVary: $[nVary>0; ,/ varyVarIds decInOne' !nVary; !0]
  / Uniform block: Block decoration + per-member std140 Offset + set/binding 0
  decUni:  $[nUni>0; ((0x00030047;Tuni;2),(,/memberDecOne'!nUni),(0x00040047;uniVar;34;0),(0x00040047;uniVar;33;0)); !0]

  types:    (0x00020013;Tvoid;0x00020014;Tbool;0x00030016;Tf32;32;0x00040017;Tv4;Tf32;4;0x00040017;Tv2;Tf32;2;0x00040017;Tv3;Tf32;3;0x00040015;Ti32;32;1;0x00030021;Tfunc;Tvoid;0x00040020;PinF32;1;Tf32;0x00040020;PoutF32;3;Tf32;0x00040020;PinV4;1;Tv4;0x00040020;PoutV4;3;Tv4;0x00040020;PinV2;1;Tv2;0x00040020;PoutV2;3;Tv2;0x00040020;PinV3;1;Tv3;0x00040020;PoutV3;3;Tv3)
  vtxTypes: (0x0003001E;TperVtx;Tv4;0x00040020;PperVtx;3;TperVtx)
  / OpTypeStruct{vec4×nUni} (wc=2+nUni, op=30), then Uniform pointers to it / to vec4
  uniTypes: $[nUni>0; ((((2+nUni)*65536)+30;Tuni),(nUni#Tv4),(0x00040020;Puni;2;Tuni),(0x00040020;PuniV4;2;Tv4)); !0]

  varIn:     ,/ inPtrs varInOne' inVarIds
  varPerVtx: (0x0004003B; PperVtx; perVtxVar; 3)
  varVary:   $[nVary>0; ,/ varyPtrs varOutOne' varyVarIds; !0]
  varUni:    $[nUni>0; (0x0004003B; Puni; uniVar; 2); !0]   / OpVariable Uniform

  label: newId[]
  fn:  (0x00050036; Tvoid; Fmain; 0; Tfunc; 0x000200F8; label)
  ret: (0x000100FD; 0x00010038)

  conWds: $[#Con; ,/Con; !0]
  bodWds: $[#Buf; ,/Buf; !0]

  ,/(hdr;cap;ext;mem;ep;decIn;decBlk;decPos;decVary;decUni;types;vtxTypes;uniTypes;varIn;varPerVtx;varVary;varUni;conWds;fn;bodWds;ret)
}



/ ── Type helpers ─────────────────────────────────────────────────────────────
LitSym: [float:`f32; int:`i32; bool:`bool]

isVecTy: {[ty] (ty~`v4) | (ty~`v2) | (ty~`v3)}

/ Component count for join result type: f32=1, v2=2, v3=3, v4=4
ncVec: [f32:1; v2:2; v3:3; v4:4]
jnRty: {[a;b] n: ncVec[a]+ncVec[b]; $[n=2;`v2;n=3;`v3;`v4]}

/ Comparison ops always produce bool; others propagate vector type or use operand type
cmpOps: `"<"`">"`"="`"~"`"&"`"|"
binRty: {[op;aty;bty;oty] $[op in cmpOps; `bool; op~`","; jnRty[aty;bty]; isVecTy[aty]; aty; isVecTy[bty]; bty; aty]}

/ ── Known 1-arg and multi-arg math function names ────────────────────────────
mathFns:  `abs`floor`fract`sign`sqrt`exp`log`tanh`sqr`sin`cos`asin`acos`atan`length`normalize`pow`min`max`atan2`dot`cross`step`mod`clamp`mix`smoothstep

/ ── Verb dispatch ────────────────────────────────────────────────────────────
dispBin: {[op;rty;r;aty;a;bty;b]
  rt: Tid[rty]
  at: Tid[aty]
  / i32-typed arith is integer index math (kk.compile-generated kernels keep
  / indices in i32 — no f32 round-trip, no 2^24 exactness cliff). User kernels
  / stay f32, so the `isi guard leaves their emission byte-identical.
  isi: rty~`i32
  $[op~`"+";   $[isi; opIadd[rt;r;a;b]; opFadd[rt;r;a;b]]
    op~`"-";   $[isi; opIsub[rt;r;a;b]; opFsub[rt;r;a;b]]
    op~`"%";   $[isi; opSdiv[rt;r;a;b]; opFdiv[rt;r;a;b]]
    op~`"*";   $[isi; opImul[rt;r;a;b]
               isVecTy[aty] & ~isVecTy[bty]; opVTS[rt;r;a;b]
               isVecTy[bty] & ~isVecTy[aty]; opVTS[rt;r;b;a]
               opFmul[rt;r;a;b]]
    op~`",";   (0x00050050;rt;r;a;b);   / OpCompositeConstruct, 2 constituents: v2+f32→v3, v3+f32→v4, etc.
    op~`"<";   opFOlt[at;r;a;b];   / <= / >= are handled by the compTrans peephole
    op~`">";   opFOgt[at;r;a;b]
    op~`"=";   opFOeq[at;r;a;b]
    op~`"~";   opFOne[at;r;a;b]
    op~`"&";   opLAnd[at;r;a;b]
    op~`"|";   opLOr[at;r;a;b]
    opFadd[rt;r;a;b]]}

/ ── Compiler state (reset per compShader call) ───────────────────────────────
Nid:: Nfixed
Con:: ()
Buf:: ()
/ Constant cache: parallel lists (typeId, encoded-word) → constant id, so an
/ identical literal (e.g. 0.0) emits a single OpConstant per module.
ConKeyT:: ()
ConKeyV:: ()
ConVal::  ()

/ Compute workgroup size baked into OpExecutionMode LocalSize (x,1,1). Sticky
/ setting: assign before compiling to tune for a GPU (e.g. wg:128). The host
/ reads this value back out of the shader's OpExecutionMode when it computes the
/ dispatch workgroup count, so shader and dispatch stay in sync automatically.
wg:: 64

/ shader.vertexU uniform-block scratch: the current block's struct type id, the
/ Uniform→vec4 pointer type id, and the block variable id.  Set per shader and
/ read by the top-level each-helpers below (ink lambdas can't see enclosing locals).
UTuni:: 0
UPv4::  0
UVar::  0

/ shader.fragmentTexN texture scratch: SPIR-V ids for the shared image / sampler
/ types, their UniformConstant pointer types, one variable per image, and the one
/ shared sampler variable.  #TexVars>0 signals buildMod to emit the texture
/ section; set per shader, read by xLoSample (ink lambdas can't see enclosing
/ locals, so these live as globals).
Timg2::   0   / OpTypeImage (f32, 2D, sampled)
Tsamp2::  0   / OpTypeSampler
TsImg::   0   / OpTypeSampledImage
PUCimg::  0   / OpTypePointer UniformConstant → image
PUCsamp:: 0   / OpTypePointer UniformConstant → sampler
TexVars:: ()  / OpVariable UniformConstant image ids (image k at set 1 binding k)
SampVar:: 0   / OpVariable UniformConstant sampler (set 1, binding nTex)
/ Stencil-compute scratch: the u32-zero constant id (struct member index) and the
/ StorageBuffer→f32 pointer type id, needed by xLoBufIdx for a dynamic-index load
/ (ink lambdas can't close over the entry's locals, so these live as globals).
CKz::   0     / OpConstant u32 0 — access-chain member index into the buffer struct
CPf32:: 0     / OpTypePointer StorageBuffer → f32
/ Atomic-scatter scratch (xLoSadd): the StorageBuffer→i32
/ pointer type and the Device memory-scope constant id for OpAtomicIAdd.
CPi32::  0    / OpTypePointer StorageBuffer → i32 (atomic accumulator element)
CScope:: 0    / OpConstant u32 1 = Device memory scope
/ Per-image decoration / variable words (read global TexVars; ink lambdas can't
/ close over locals, so these are top-level each-helpers).
texDecOne: {[k] (0x00040047;TexVars[k];34;1),(0x00040047;TexVars[k];33;k)}
texVarOne: {[k] (0x0004003B;PUCimg;TexVars[k];0)}

newId:   {[] r:Nid; Nid::Nid+1; r}
emitCon: {[ws] Con,:: ,ws}
emitBuf: {[ws] Buf,:: ,ws}
emitW:   emitBuf

/ constId[t;v] — id of an f32/int OpConstant, deduplicated within the module.
/ The value is encoded exactly as opConst does (f32 → bit pattern); the key
/ carries t too, so i32 0 and f32 0.0 (both encode to word 0) never collide.
/ Match both key columns with a boolean mask (Find on a vector key would search
/ element-wise). constMiss emits+caches a miss (each $[] arm is one expression).
constMiss: {[t;v;e] r:newId[]; emitCon opConst[t;r;v]; ConKeyT,:: t; ConKeyV,:: e; ConVal,:: r; r}
constId: {[t;v]
  e: $[t=Tf32; `I$v; v]
  / Where over the match mask (Find of 1b is broken); guard the empty cache, since
  / ()=t is a general list that & rejects. w = indices of matching cached constants.
  w: $[#ConKeyT; &((ConKeyT=t) & (ConKeyV=e)); !0]
  $[#w; ConVal w 0; constMiss[t;v;e]]}

/ One OpMemberDecorate Offset for uniform member i (std140: vec4 at byte i*16).
memberDecOne: {[i] (0x00050048; UTuni; i; 35; i*16)}
/ Load uniform member at constant id `kidx`: OpAccessChain (Uniform vec4*) + OpLoad.
loadUniMember: {[kidx] p:newId[]; emitBuf opAccChain1[UPv4;p;UVar;kidx]; v:newId[]; emitBuf opLoad[Tv4;v;p]; (v;`v4)}

/ ── CST table access ────────────────────────────────────────────────────────
/ `parse` now returns an apter-tree table (dict of columns) instead of a nested
/ list. Cst holds the current shader's tree; a node is a row index. Children of
/ row i are the rows whose `parent` = i (in pre-order = source order), selectable
/ by their `field` label.
kKind: {[i] (Cst`kind) i}                    / node type symbol
kVal:  {[i] (Cst`value) i}                   / literal payload / glyph / name
kKids: {[i] &i=Cst`parent}                   / all child rows of i
kF:    {[i;f] c:kKids i; c@&f=(Cst`field)c}  / child rows of i with field f
kF1:   {[i;f] *kF[i;f]}                       / first such child (a row index)
/ Parse a lambda value and return (lambda row; arg-name symbols; body stmt rows).
lamOf:   {[fn] Cst:: parse[$fn]; *|kF[0;`stmt]}   / last stmt of root terse = lambda (parse is a prelude name now → bracket-apply, not `parse $fn`)
lamArgs: {[lam] (Cst`value)@kF[lam;`param]}
lamBody: {[lam] kF[lam;`stmt]}

/ Is `nm` a storage-buffer binding in the current env? (short-circuits the lookup)
isBuf: {[nm; env] $[nm in !env; `buf~(env nm)1; 0]}

/ ── In-kernel bounded loops (control flow for the compute dialect) ───────────
/ The dialect grows ONE loop CFG idiom, shared by three surfaces:
/   +/{[k] e}'!K      — fused index map-reduce (Σ e over k=0..K-1), the CANONICAL
/                       spelling (kk2 §8-3); |/ → max. No range is materialised:
/                       xFoldEach recognizes the shape and lowers it to the same
/                       region node as rsum[K;{[k] e}]/rmax[…], the documented
/                       intrinsic equivalents (kept compiling, byte-identical).
/   i f/ x  (N-do)    — apply verb `f` to state `x`"," `i` times.   ← real k adverb
/   f g/ x  (While)   — apply body `g` to state `x` while cond `f x` holds. ← adverb
/ The verb/cond `{[s] …}` is NOT a runtime closure — its body is INLINED with the
/ param bound to the carried state (and, for rsum, `k` bound to the loop counter as
/ f32); enclosing locals stay visible because we compile in the current env.
/ Constants RCi0/RCi1/RCf0 (i32 0, i32 1, f32 0.) are made once per compile in
/ compGpN, so these are valid inside a gpu.kernel only (the fixed stencil emitters
/ don't create them).
RCi0:: 0    / i32 constant 0     (loop counter init)
RCi1:: 0    / i32 constant 1     (loop counter step)
RCf0:: 0    / f32 constant 0.    (rsum accumulator init)
RCfNeg:: 0  / f32 constant -1e30 (rmax accumulator init)

/ Emit a counter-driven loop scaffold threading an i32 counter (0..Kmax-1) plus one
/ carried state of type `sty` (init `seedId`), and leave the BODY block open. The
/ caller then computes the next state from the returned counter/state phis and calls
/ loopClose with it. Phis forward-reference the counter/state back-edge ids (SPIR-V
/ permits forward <id> refs), so every id is allocated before emission.
/ Returns (counterPhi; statePhi; counterNext; stateNext; contLbl; hdrLbl; mrgLbl).
loopOpen: {[Kmax; seedId; sty]
  preL:newId[]; hdrL:newId[]; bodL:newId[]; conL:newId[]; mrgL:newId[]
  iPhi:newId[]; sPhi:newId[]; iNext:newId[]; sNext:newId[]; cond:newId[]
  emitBuf opBranch[preL]                      / entry → preheader (gives the phi a known pred)
  emitBuf opLabel[preL]
  emitBuf opBranch[hdrL]
  emitBuf opLabel[hdrL]
  emitBuf opPhi2[Ti32;      iPhi; RCi0;   preL; iNext; conL]
  emitBuf opPhi2[Tid[sty];  sPhi; seedId; preL; sNext; conL]
  emitBuf opSLT[Tbool; cond; iPhi; Kmax]
  emitBuf opLoopMrg[mrgL; conL]
  emitBuf opBrCond[cond; bodL; mrgL]
  emitBuf opLabel[bodL]                        / BODY block open; caller fills it
  (iPhi; sPhi; iNext; sNext; conL; hdrL; mrgL)
}
/ Close a loopOpen: bind the computed next state, step the counter, loop back, land
/ on the merge block. `statePhi` (returned by loopOpen) then holds the final value.
loopClose: {[nv; sty; sNext; iNext; iPhi; conL; hdrL; mrgL]
  emitBuf opCopy[Tid[sty]; sNext; nv]          / stateNext := nv (phi back-edge value)
  emitBuf opBranch[conL]
  emitBuf opLabel[conL]
  emitBuf opIadd[Ti32; iNext; iPhi; RCi1]      / counter += 1
  emitBuf opBranch[hdrL]
  emitBuf opLabel[mrgL]
}

/ ── Layer III helper ──────────────────────────────────────────────────────────
loadOnePair: {[vid; tsym]
  r: newId[]
  emitBuf opLoad[Tid[tsym]; r; vid]
  (r; tsym)}

/ ── Layer IV: SPIR-V module assembly ─────────────────────────────────────────
decInOne: {[vid;loc] (0x00040047; vid; 30; loc)}
varInOne: {[ptr;vid] (0x0004003B; ptr; vid; 1)}

buildMod: {[outId; inVarIds; inTys; inPtrs; outPtr; locs] $[xErr~`; buildModW[outId; inVarIds; inTys; inPtrs; outPtr; locs]; !xErr]}
buildModW: {[outId; inVarIds; inTys; inPtrs; outPtr; locs]
  bnd:   Nid+1
  / SPIR-V 1.4: OpEntryPoint lists EVERY global variable — the texture images
  / and shared sampler (UniformConstant) join the Input/Output interface.
  iface: inVarIds,(,outId),$[#TexVars; TexVars,,SampVar; !0]

  hdr:  (0x07230203; 0x00010400; 0; bnd; 0)
  cap:  (0x00020011; 1)
  ext:  (0x0006000B; Glsl; 0x4C534C47; 0x6474732E; 0x3035342E; 0)
  mem:  (0x0003000E; 0; 1)
  ep:   (0x000F+(0x10000*(5+#iface)); 4; Fmain; 0x6E69616D; 0), iface
  exm:  (0x00030010; Fmain; 7)

  decIn:  ,/ inVarIds decInOne' locs
  decOut: (0x00040047; outId; 30; 0)

  / types: one line — newlines inside (...) inject null words in ink
  types: (0x00020013; Tvoid; 0x00020014; Tbool; 0x00030016; Tf32; 32; 0x00040017; Tv4; Tf32; 4; 0x00040017; Tv2; Tf32; 2; 0x00040017; Tv3; Tf32; 3; 0x00040015; Ti32; 32; 1; 0x00030021; Tfunc; Tvoid; 0x00040020; PinF32; 1; Tf32; 0x00040020; PoutF32; 3; Tf32; 0x00040020; PinV4; 1; Tv4; 0x00040020; PoutV4; 3; Tv4; 0x00040020; PinV2; 1; Tv2; 0x00040020; PoutV2; 3; Tv2; 0x00040020; PinV3; 1; Tv3; 0x00040020; PoutV3; 3; Tv3)

  varIn:  ,/ inPtrs varInOne' inVarIds
  varOut: (0x0004003B; outPtr; outId; 3)

  / shader.fragmentTex texture section (emitted only when TexVar was allocated):
  / DescriptorSet/Binding decorations, image/sampler/sampled-image types + their
  / UniformConstant pointers, and the two global variables.  All one line each —
  / newlines inside (...) inject null words.
  nTex:     #TexVars
  hasTex:   nTex>0
  decTex:   $[hasTex; (,/texDecOne'!nTex),(0x00040047;SampVar;34;1),(0x00040047;SampVar;33;nTex); !0]
  texTypes: $[hasTex; (0x00090019;Timg2;Tf32;1;0;0;0;1;0),(0x0002001A;Tsamp2),(0x0003001B;TsImg;Timg2),(0x00040020;PUCimg;0;Timg2),(0x00040020;PUCsamp;0;Tsamp2); !0]
  varTex:   $[hasTex; (,/texVarOne'!nTex),(0x0004003B;PUCsamp;SampVar;0); !0]

  label: newId[]
  fn:  (0x00050036; Tvoid; Fmain; 0; Tfunc; 0x000200F8; label)
  ret: (0x000100FD; 0x00010038)

  conWds: $[#Con; ,/Con; !0]
  bodWds: $[#Buf; ,/Buf; !0]

  ,/(hdr; cap; ext; mem; ep; exm; decIn; decOut; decTex; types; texTypes; varIn; varOut; varTex; conWds; fn; bodWds; ret)
}


/ ══ Consolidated compute-module emitter (doc/design/kk.md §3.1, increment 1) ══
/ Every compute entry point (map / stencil / scatter / general kernel) is the SAME
/ module: a binding table of storage buffers (+ optional uniform block), a gid
/ prologue, a body compiled by kSeqIr, an optional auto-store, and one assembly.
/ kAlloc + kGid*/kElem/kStore + kAsm factor that out; the shader.* entry points
/ below are thin wrappers that differ only in their binding spec and env shape.
/ The AK* globals mirror the old per-entry locals (ink lambdas can't close over
/ enclosing locals, so the each-helpers and kAsm read globals).

/ ── kAlloc[nAcc;nBuf;hasUni;hasLoop] — canonical prologue ─────────────────────
/ Resets compiler state; allocates the shared type ids, the gid var, and one var
/ per binding (i32 atomic accumulators first: bindings 0..nAcc-1, then f32
/ buffers) in the one canonical id order; emits the constants (u32 0, [Device
/ scope], [uniform member index 0], [loop consts]); publishes the AK*/C*/U*/RC*
/ globals the body compilers and kAsm read. Returns the binding var ids.
AKu32::0; AKv3::0                              / u32 / v3u32 type ids
AKrta::0; AKtbuf::0; AKpbufs::0; AKpf32::0     / f32 runtime-array/struct/pointers
AKrtaI::0; AKtbufI::0; AKpbufsI::0; AKpi32::0  / i32 counterparts (nAcc>0 only)
AKpv3i::0; AKgid::0                            / Input v3u32 pointer + gid var
AKids::(); AKknd::()                           / binding var ids + kinds (`i/`f)
AKz::0; AKdev::0                               / u32 0 const; Device-scope const
AKuniT::0; AKuniP::0; AKuniPv4::0; AKuniVar::0; AKuniKi::0
AKnAcc::0; AKuni::0
kAllocI:   {[] AKrtaI::newId[]; AKtbufI::newId[]; AKpbufsI::newId[]; AKpi32::newId[]}
kAllocDev: {[] AKdev::newId[]; emitCon (0x0004002B; AKu32; AKdev; 1); CPi32::AKpi32; CScope::AKdev}
kAllocUni: {[] AKuniT::newId[]; AKuniP::newId[]; AKuniPv4::newId[]; AKuniVar::newId[]; AKuniKi::newId[]; emitCon opConst[Ti32; AKuniKi; 0]; UTuni::AKuniT; UPv4::AKuniPv4; UVar::AKuniVar}
/ rsum/rmax/N-do loop constants (i32 0/1, f32 0., f32 -1e30), one set per compile
kAllocLoop:{[] RCi0::newId[]; emitCon opConst[Ti32;RCi0;0]; RCi1::newId[]; emitCon opConst[Ti32;RCi1;1]; RCf0::newId[]; emitCon opConst[Tf32;RCf0;0.]; RCfNeg::newId[]; emitCon opConst[Tf32;RCfNeg;-1e30]}
kAlloc: {[nAcc;nBuf;hasUni;hasLoop]
  xErr::`
  Nid::Nfixed; Buf::(); Con::(); ConKeyT::(); ConKeyV::(); ConVal::()
  AKu32::newId[]; AKv3::newId[]
  AKrta::newId[]; AKtbuf::newId[]; AKpbufs::newId[]; AKpf32::newId[]
  $[nAcc>0; kAllocI[]; 0]
  AKpv3i::newId[]
  AKgid::newId[]
  AKids:: {[k] newId[]}' !nAcc+nBuf
  AKknd:: (nAcc#`i),nBuf#`f
  AKz::newId[]; emitCon (0x0004002B; AKu32; AKz; 0)
  $[nAcc>0; kAllocDev[]; 0]
  $[hasUni; kAllocUni[]; 0]
  $[hasLoop; kAllocLoop[]; 0]
  CKz::AKz; CPf32::AKpf32
  AKnAcc::nAcc; AKuni::hasUni
  AKids}

/ ── gid prologue + element access ─────────────────────────────────────────────
kGidX: {[] g:newId[]; emitBuf opLoad[AKv3; g; AKgid]; x:newId[]; emitBuf opXtract[AKu32; x; g; 0]; x}
kGidF: {[gx] f:newId[]; emitBuf opU2f[Tf32; f; gx]; f}                  / thread index as f32
kGidI: {[gx] i:newId[]; emitBuf opBitcast[Ti32; i; gx]; i}              / thread index as i32 (bit-reinterpret; gid < 2^31)
kElem: {[bid;gx] p:newId[]; emitBuf opAccChain[AKpf32; p; bid; AKz; gx]; v:newId[]; emitBuf opLoad[Tf32; v; p]; (v;`f32)}
kStore:{[bid;gx;val] p:newId[]; emitBuf opAccChain[AKpf32; p; bid; AKz; gx]; emitBuf opStore[p; val]}
/ Scatter store for @[x;I;:;v]: out[I[gid]] := val. Loads the write index from the
/ I buffer at gid (f32→i32), then stores. I is padded to the dispatch grid with a
/ sentinel that lands in out's padding, so over-dispatched threads don't clobber.
kScatStore: {[outBid; idxBid; gx; val]
  p1:newId[]; emitBuf opAccChain[AKpf32; p1; idxBid; AKz; gx]
  iv:newId[]; emitBuf opLoad[Tf32; iv; p1]
  si:newId[]; emitBuf opF2s[Ti32; si; iv]
  p2:newId[]; emitBuf opAccChain[AKpf32; p2; outBid; AKz; si]
  emitBuf opStore[p2; val]}
/ Atomic scatter-add for @[x;I;+;v]: acc[I[gid]] += i32(v). acc is an i32
/ accumulator (kAlloc nAcc>0 sets CPi32/CScope); idxBid is the f32 I buffer.
/ Multiple threads hitting one bucket accumulate race-free (OpAtomicIAdd, Device).
kScatAdd: {[accBid; idxBid; gx; val]
  p1:newId[]; emitBuf opAccChain[AKpf32; p1; idxBid; AKz; gx]
  iv:newId[]; emitBuf opLoad[Tf32; iv; p1]
  si:newId[]; emitBuf opF2s[Ti32; si; iv]
  vi:newId[]; emitBuf opF2s[Ti32; vi; val]
  ptr:newId[]; emitBuf opAccChain[CPi32; ptr; accBid; AKz; si]
  old:newId[]; emitBuf opAtomicIAdd[Ti32; old; ptr; CScope; CKz; vi]}

/ ── kAsm[] — assemble the module from the AK* state ───────────────────────────
/ Per-binding DescriptorSet/Binding decorations and OpVariables (each-helpers
/ read the globals; binding k = position k in AKids).
akDecOne: {[k] (0x00040047;AKids[k];34;0),(0x00040047;AKids[k];33;k)}
akVarOne: {[k] (0x0004003B; $[`i~AKknd k; AKpbufsI; AKpbufs]; AKids[k]; 12)}
/ A latched compile error (xFoldBad/xBakeBad) aborts assembly with `!xErr`.
kAsm: {[] $[xErr~`; kAsmWords[]; !xErr]}
kAsmWords: {[]
  bnd: Nid+1
  / SPIR-V 1.4: OpEntryPoint lists EVERY global variable — gid + all storage
  / bindings + the uniform block (not just the builtin Input).
  iface: (,AKgid),AKids,$[AKuni; ,AKuniVar; !0]
  hdr: (0x07230203; 0x00010400; 0; bnd; 0)
  cap: (0x00020011; 1)
  ext: (0x0006000B; Glsl; 0x4C534C47; 0x6474732E; 0x3035342E; 0)
  mem: (0x0003000E; 0; 1)
  ep:  (0x000F+(0x10000*(5+#iface)); 5; Fmain; 0x6E69616D; 0), iface
  exm: (0x00060010; Fmain; 17; wg; 1; 1)
  decGid: (0x00040047; AKgid; 11; 28)
  decF: (0x00040047;AKrta;6;4),(0x00050048;AKtbuf;0;35;0),(0x00030047;AKtbuf;2)
  decI: $[AKnAcc>0; (0x00040047;AKrtaI;6;4),(0x00050048;AKtbufI;0;35;0),(0x00030047;AKtbufI;2); !0]
  decB: ,/akDecOne' !#AKids
  decU: $[AKuni; (0x00030047;AKuniT;2),(0x00050048;AKuniT;0;35;0),(0x00040047;AKuniVar;34;0),(0x00040047;AKuniVar;33;#AKids); !0]
  sTypes: (0x00020013;Tvoid;0x00020014;Tbool;0x00030016;Tf32;32;0x00040017;Tv4;Tf32;4;0x00040017;Tv2;Tf32;2;0x00040017;Tv3;Tf32;3;0x00040015;Ti32;32;1;0x00030021;Tfunc;Tvoid)
  cTf: (0x00040015;AKu32;32;0;0x00040017;AKv3;AKu32;3;0x0003001D;AKrta;Tf32;0x0003001E;AKtbuf;AKrta;0x00040020;AKpbufs;12;AKtbuf;0x00040020;AKpf32;12;Tf32)
  cTi: $[AKnAcc>0; (0x0003001D;AKrtaI;Ti32;0x0003001E;AKtbufI;AKrtaI;0x00040020;AKpbufsI;12;AKtbufI;0x00040020;AKpi32;12;Ti32); !0]
  cTv: (0x00040020;AKpv3i;1;AKv3)
  uT:  $[AKuni; (0x0003001E;AKuniT;Tv4;0x00040020;AKuniP;2;AKuniT;0x00040020;AKuniPv4;2;Tv4); !0]
  varGid: (0x0004003B;AKpv3i;AKgid;1)
  varB: ,/akVarOne' !#AKids
  varU: $[AKuni; (0x0004003B;AKuniP;AKuniVar;2); !0]
  label: newId[]
  fnh: (0x00050036;Tvoid;Fmain;0;Tfunc;0x000200F8;label)
  ret: (0x000100FD;0x00010038)
  conWds: $[#Con; ,/Con; !0]
  bodWds: $[#Buf; ,/Buf; !0]
  ,/(hdr;cap;ext;mem;ep;exm;decGid;decF;decI;decB;decU;sTypes;cTf;cTi;cTv;uT;varGid;varB;varU;conWds;fnh;bodWds;ret)}

/ ── Entry points (thin wrappers; see the old per-entry docs in git history) ───
/ shader.compute — element-wise map {[x] …}: x = in[gid] (binding 0) → out[gid]
/ (binding 1). Run with gpu.runShader / the resident path.
compCompute: {[fn]
  ids: kAlloc[0;2;0;0]
  lam: lamOf fn; argNames: lamArgs lam
  gx: kGidX[]
  xp: kElem[ids 0; gx]
  env: (,argNames 0)!(,xp)
  rp: kSeqIr[lamBody lam; env; `f32]
  kStore[ids 1; gx; rp 0]
  kAsm[]}
shader.compute: compCompute

/ shader.computeU — map + a uniform vec4 {[x;u] …}: true UBO at binding 2
/ (constants like scale/bias without a storage buffer). gpu.dispatch (in;out;u).
compComputeU: {[fn]
  ids: kAlloc[0;2;1;0]
  lam: lamOf fn; argNames: lamArgs lam
  gx: kGidX[]
  xp: kElem[ids 0; gx]
  uPair: loadUniMember[AKuniKi]
  env: argNames!(xp;uPair)
  rp: kSeqIr[lamBody lam; env; `f32]
  kStore[ids 1; gx; rp 0]
  kAsm[]}
shader.computeU: compComputeU

/ shader.compute2 — two-input map {[x;y] …}: x=in(0), y=in2(2) → out(1).
compCompute2: {[fn]
  ids: kAlloc[0;3;0;0]
  lam: lamOf fn; argNames: lamArgs lam
  gx: kGidX[]
  xp: kElem[ids 0; gx]
  yp: kElem[ids 2; gx]
  env: argNames!(xp;yp)
  rp: kSeqIr[lamBody lam; env; `f32]
  kStore[ids 1; gx; rp 0]
  kAsm[]}
shader.compute2: compCompute2

/ ── shader.map[fn; nIn] — N-input elementwise map (kk2 §2.4-2) ────────────────
/ A whole-array lambda in implicit-param form ({2.*x}, {x+y}, {sqrt x}) lowered to
/ a per-thread map: input k = binding k, loaded at gid into the implicit param
/ (x=arg0, y=arg1, z=arg2); the body → out[gid] at binding nIn. This is what
/ kk.compile lowers an elementwise placement map to; generalises compCompute/
/ compute2 to N inputs and the implicit-param spelling. nIn ≤ 3. GXe publishes gid
/ so the per-input load each can read it (ink lambdas can't close over locals).
GXe:: 0
kMapLoad: {[b] kElem[b; GXe]}
compMapN: {[fn; nIn]
  ids: kAlloc[0; nIn+1; 0; 0]
  lam: lamOf fn
  GXe:: kGidX[]
  loads: kMapLoad' nIn # ids
  env: (nIn # `x`y`z) ! loads
  rp: kSeqIr[lamBody lam; env; `f32]
  kStore[ids nIn; GXe; rp 0]
  kAsm[]}
shader.map: compMapN

/ ── shader.reduce[op] — whole-buffer reduction (kk2 §6, tier-2 gateway) ───────
/ A fixed two-binding kernel (in@0, out@1) + uniform vec4@2 = (n; T; Kmax; _) that
/ folds a placement with a grid-strided serial loop: thread d combines
/ in[d], in[d+T], in[d+2T], … (Kmax steps, guarded by idx<n) into out[d]. The host
/ runs it twice (kk.reduce): stage 1 with T=P threads → P partials, stage 2 with
/ T=1 on ONE thread → the scalar. `op` selects identity+combine: `sum`max`min`prod.
/ Out-of-range steps clamp the index to 0 and select the identity, so no OOB load —
/ correctness never leans on buffer padding. This is the two-dispatch FALLBACK path
/ (no shared memory / subgroups); the subgroup fast path (OpGroupNonUniformFAdd,
/ gpu.caps sgArith) layers on top later without changing this contract.
redSeed:   {[op] $[op~`max; RCfNeg; op~`min; constId[Tf32;1e30]; op~`prod; constId[Tf32;1.]; RCf0]}
redCombW:  {[op;t;r;a;b] $[op~`max; opFmax[t;r;a;b]; op~`min; opFmin[t;r;a;b]; op~`prod; opFmul[t;r;a;b]; opFadd[t;r;a;b]]}
compReduce: {[op]
  ids: kAlloc[0; 2; 1; 1]                       / in@0, out@1, uniform@2, loop consts
  uv: (loadUniMember AKuniKi) 0                 / the uniform vec4 value id
  nF:  newId[]; emitBuf opXtract[Tf32; nF;  uv; 0]
  tF:  newId[]; emitBuf opXtract[Tf32; tF;  uv; 1]
  kmF: newId[]; emitBuf opXtract[Tf32; kmF; uv; 2]
  nI:  newId[]; emitBuf opF2s[Ti32; nI;  nF]
  tI:  newId[]; emitBuf opF2s[Ti32; tI;  tF]
  kmI: newId[]; emitBuf opF2s[Ti32; kmI; kmF]
  gx:  kGidX[]
  d:   kGidI[gx]                                / thread index (i32)
  seed: redSeed op
  L: loopOpen[kmI; seed; `f32]
  iPhi:L 0; sPhi:L 1; iNext:L 2; sNext:L 3; conL:L 4; hdrL:L 5; mrgL:L 6
  m:   newId[]; emitBuf opImul[Ti32; m; iPhi; tI]     / k*T
  idx: newId[]; emitBuf opIadd[Ti32; idx; d; m]       / d + k*T
  g:   newId[]; emitBuf opSLT[Tbool; g; idx; nI]      / idx < n
  si:  newId[]; emitBuf opSel[Ti32; si; g; idx; RCi0] / clamp OOB index to 0
  p:   newId[]; emitBuf opAccChain[AKpf32; p; ids 0; AKz; si]
  vl:  newId[]; emitBuf opLoad[Tf32; vl; p]
  v:   newId[]; emitBuf opSel[Tf32; v; g; vl; seed]   / identity when out of range
  nv:  newId[]; emitBuf redCombW[op; Tf32; nv; sPhi; v]
  loopClose[nv; `f32; sNext; iNext; iPhi; conL; hdrL; mrgL]
  kStore[ids 1; gx; sPhi]                        / out[d] = accumulated
  kAsm[]}
shader.reduce: compReduce

/ ── Elementwise subset classifier (kk2 §2.1: "no silent fallback") ────────────
/ Walk the lambda body; return `nil if every node is in the elementwise subset
/ (arith/cmp/join, math builtins, unary -/~, literals, x/y/z, list/cond/group/
/ local bind), else the FIRST offending verb glyph or node kind so kk.compile can
/ name it. Rejects gather (@), amend, adverbs and any non-math apply — those forms
/ belong to the later kk.compile milestones (index-buffer gather, scatter, stencil).
kkEwOps:: `"+"`"-"`"*"`"%"`"<"`">"`"="`"~"`"&"`"|"`","
kkAny: {[rows] cs: $[0=#rows; ,`; kkChk' rows]; b: &~cs~\:`; $[#b; *(cs@b); `]}
kkT: {[i] v:kF1[i;`v]; $[(kKind v)~`term; `adverb; ~(kVal v) in kkEwOps; kVal v; kkAny (kF1[i;`a];kF1[i;`b])]}
kkA: {[i] f:kF1[i;`f]; $[(kKind f)~`term; `adverb; ~((kVal f) in mathFns)|((kVal f) in `"-"`"~"); kVal f; kkChk kF1[i;`a]]}
kkP: {[i] f:kF1[i;`f]; $[~(kVal f) in mathFns; kVal f; kkAny kF[i;`arg]]}
kkChk: {[i]
  k: kKind i
  $[k in `int`float`ints`floats`bool`var; `
    k~`list;    kkAny kF[i;`elem]
    k~`cond;    kkAny kF[i;`stmt]
    k~`right;   kkChk kF1[i;`clause]
    k~`group;   kkChk kF1[i;`stmt]
    k~`bind;    kkChk kF1[i;`a]
    k~`transit; kkT i
    k~`apposit; kkA i
    k~`apply;   kkP i
    k]}
kkClassify: {[fn] lam: lamOf fn; kkAny lamBody lam}

/ ── Gather map kernel (kk2 §2.4-3): x@w → out[d] = src[idx[d]] ─────────────────
/ Some args are `buf gather SOURCES (indexed by @), others are `elem indices/values
/ (auto-loaded at the thread index d). bufNames get bindings 0..#bufNames-1, then
/ elemNames, then the output. The body is compiled through the neutral IR with @
/ lowering to a nested buffer index (xGather) and elem names to buf[d] (xVarE).
kGmapEnvOne: {[p] (xEmit[`bufp; p 1; (); p 0]; p 1)}
compGmap: {[fn; bufNames; elemNames]
  nbuf: #bufNames; nb: nbuf + #elemNames
  ids: kAlloc[0; nb+1; 0; 1]                / hasLoop=1: +/x@W needs the rsum consts
  lam: lamOf fn
  gx: kGidX[]
  bufP:  {[id] (id;`buf)}'  nbuf # ids
  elemP: {[id] (id;`elem)}' nbuf _ nb # ids
  xReset[]
  e2: (bufNames,elemNames) ! kGmapEnvOne' bufP,elemP
  GIrGid:: xEmit[`param; `i32; (); kGidI gx]     / thread index d in i32 (index math stays integer)
  rp: xSeq[lamBody lam; e2; `f32]
  xLowerC[,rp 0]
  kStore[ids nb; gx; xId rp 0]
  kAsm[]}
shader.gmap: compGmap

/ ── Placed-table map kernel (kk2 §2.5): {(t`a)+(t`b)} over a placed table ──────
/ Each referenced column is one storage binding (0..nc-1), loaded elementwise at
/ the thread index; the table var resolves to a col-name→bufp dict (a `table env
/ entry) that xTableCol reads. Output → binding nc. Binding inference (kk.compile)
/ passes only the columns the body mentions, so dead columns cost nothing.
compTable: {[fn; tableName; colNames]
  nc: #colNames
  ids: kAlloc[0; nc+1; 0; 1]
  lam: lamOf fn
  gx: kGidX[]
  xReset[]
  colNodes: {[id] xEmit[`bufp; `col; (); id]}' nc # ids
  colDict: colNames ! colNodes
  e2: (,tableName) ! ,(colDict; `table)
  GIrGid:: xEmit[`param; `i32; (); kGidI gx]     / thread index d in i32 (index math stays integer)
  rp: xSeq[lamBody lam; e2; `f32]
  xLowerC[,rp 0]
  kStore[ids nc; gx; xId rp 0]
  kAsm[]}
shader.table: compTable

/ Column references `(t`c)`: apposit rows whose f is a var (the table) and whose
/ arg is a symbol (the column). kkTableName = the table var; kkTableColNames =
/ the DISTINCT columns actually read (drives binding pruning).
kkColRefs: {[] ap: & `apposit = Cst`kind; $[0=#ap; !0; ap @ & {[i] ((kKind kF1[i;`f])~`var) & ((kKind kF1[i;`a])~`symbol)}' ap]}
kkTableName: {[] r: kkColRefs[]; $[0=#r; `; kVal kF1[*r;`f]]}
kkTableColNames: {[] r: kkColRefs[]; $[0=#r; 0#`; ? {[i] kVal kF1[i;`a]}' r]}

/ ── Amend-scatter kernel (kk2 §2.4-4): @[x;I;:;v] → out[I[d]] = v ─────────────
/ One thread per interior index d. The value expr v (arg 3 of the @-apply, e.g.
/ 1.+.25*+/x@W) is compiled through the gather-reduce IR reading x (source) and W
/ (neighbour matrix) as buffers; the result scatters to out[I[d]] (kScatStore).
/ x,W,I are bindings 0,1,2 and out is 3; GRk/GRn (W's k,n) are baked by the caller.
compAmend: {[fn; srcName; matName; idxName]
  ids: kAlloc[0; 4; 0; 1]                     / x, W, I, out
  lam: lamOf fn
  gx: kGidX[]
  bufP: {[id] (id;`buf)}' 3 # ids
  xReset[]
  e2: (srcName;matName;idxName) ! kGmapEnvOne' bufP
  GIrGid:: xEmit[`param; `i32; (); kGidI gx]     / thread index d in i32 (index math stays integer)
  ap: *& `apply = Cst`kind                    / the @[…] apply
  vN: (kF[ap;`arg]) 3                          / arg 3 = the value expression
  rp: xNode[vN; e2; `f32]
  xLowerC[,rp 0]
  kScatStore[ids 3; ids 2; gx; xId rp 0]      / out[I[gid]] := v
  kAsm[]}
shader.amend: compAmend

/ Amend detection: an apply of @ with 4 args whose 3rd is the `:` assign verb.
/ kkAmendInfo returns (srcName; idxName) — the amended buffer and its index set.
kkIsAmendR: {[i] a:kF[i;`arg]; ((kVal kF1[i;`f])~`"@") & (3<#a) & ((kVal a 2)~`":")}
kkAmendRows: {[] ap: & `apply = Cst`kind; $[0=#ap; !0; ap @ & kkIsAmendR' ap]}
kkIsAmend: {[] 0 < # kkAmendRows[]}
kkAmendInfo: {[] r: *kkAmendRows[]; a: kF[r;`arg]; (kVal a 0; kVal a 1)}

/ ── Scatter-add kernel (kk2 §2.4-5): @[x;I;+;v] → acc[I[d]] += v ──────────────
/ One thread per index d. acc (binding 0) is an i32 fixed-point accumulator hit by
/ kScatAdd; I (binding 1) is the scatter index; valBufNames are the vector value
/ operands (bindings 2.., loaded elementwise as v[d]); host scalars in v bake.
/ Duplicate indices accumulate race-free. Read back with gpu.readI (i32 counts).
compScatAdd: {[fn; valBufNames]
  nv: #valBufNames
  ids: kAlloc[1; 1+nv; 0; 1]                   / acc(i32) + I + value bufs
  lam: lamOf fn
  gx: kGidX[]
  valP: {[id] (id;`elem)}' 2 _ (2+nv) # ids
  xReset[]
  e2: valBufNames ! kGmapEnvOne' valP
  GIrGid:: xEmit[`param; `i32; (); kGidI gx]     / thread index d in i32 (index math stays integer)
  ap: *& `apply = Cst`kind
  vN: (kF[ap;`arg]) 3
  rp: xNode[vN; e2; `f32]
  xLowerC[,rp 0]
  kScatAdd[ids 0; ids 1; gx; xId rp 0]         / acc[I[gid]] += v
  kAsm[]}
shader.scatadd: compScatAdd

/ Scatter-add detection: an @-apply whose 3rd arg is the `+` verb.
kkIsScatR: {[i] a:kF[i;`arg]; ((kVal kF1[i;`f])~`"@") & (3<#a) & ((kVal a 2)~`"+")}
kkScatRows: {[] ap: & `apply = Cst`kind; $[0=#ap; !0; ap @ & kkIsScatR' ap]}
kkIsScatAdd: {[] 0 < # kkScatRows[]}
kkScatInfo: {[] r: *kkScatRows[]; a: kF[r;`arg]; (kVal a 0; kVal a 1)}
/ All var names referenced anywhere in the body (for value-operand discovery).
kkAllVars: {[] ? (Cst`value) @ & `var = Cst`kind}
/ Value-operand names of a scatter-add: every var except the accumulator and index
/ (assumed value vectors; a host scalar in v bakes and needn't be listed here).
kkScatVbufs: {[accName; idxName] vs: kkAllVars[]; vs @ & ~ vs in (accName; idxName)}

/ Body scans for kk.compile's gather orchestration (Cst must already be set by a
/ prior lamOf). kkHasAt: does the body contain an @-transit? kkGathSrc: the set of
/ names that appear as the LEFT operand of @ (the gather sources → `buf role).
/ Guard the empty case: `f' (!0)` over an EMPTY typed vector yields a general-list
/ () (not an empty bool vector), and `&()` then `tr@…` spuriously returns one
/ element — so a body with no transits would look like it has an @. Return !0.
kkAtRows: {[] tr: & `transit = Cst`kind; $[0=#tr; !0; tr @ & {[i] (kVal kF1[i;`v])~`"@"}' tr]}
kkHasAt:  {[] 0 < # kkAtRows[]}
kkGathSrc:{[] r: kkAtRows[]; $[0=#r; !0; ? {[i] kVal kF1[i;`a]}' r]}
/ Matrix gather-reduce +/(x@W): an apposit whose f is a /-term (over + or |) and
/ whose argument is an @-transit. kkMatOperands returns (srcName; matName) of the
/ first such form (both are `buf; matName's descriptor shape gives k,n).
kkIsMatR: {[i] fN: kF1[i;`f]; $[~(kKind fN)~`term; 0; ~(kVal fN)~`"/"; 0; xIsGather kF1[i;`a]]}
kkMatRows: {[] ap: & `apposit = Cst`kind; $[0=#ap; !0; ap @ & kkIsMatR' ap]}
kkIsMatReduce: {[] 0 < # kkMatRows[]}
kkMatOperands: {[] r: *kkMatRows[]; aN: kF1[r;`a]; (kVal kF1[aN;`a]; kVal kF1[aN;`b])}

/ shader.stencil — gather kernel {[u;i] …}: u = the whole input buffer (binding
/ 0), indexable at ANY computed offset (u[i-1], u[i+W]); i = thread index (f32);
/ result → out[i] (binding 1). Jacobi/image filters; dims baked as literals.
compStencil: {[fn]
  ids: kAlloc[0;2;0;0]
  lam: lamOf fn; argNames: lamArgs lam
  gx: kGidX[]; gf: kGidF[gx]
  env: argNames!((ids 0;`buf);(gf;`f32))
  rp: kSeqIr[lamBody lam; env; `f32]
  kStore[ids 1; gx; rp 0]
  kAsm[]}
shader.stencil: compStencil

/ shader.stencilU — stencil + params buffer {[u;g;i]}: g (binding 2) is an
/ indexable params buffer (g[0]=N, …) so ONE pipeline serves any grid.
/ gpu.dispatch order (in; out; params).
compStencilU: {[fn]
  ids: kAlloc[0;3;0;0]
  lam: lamOf fn; argNames: lamArgs lam
  gx: kGidX[]; gf: kGidF[gx]
  env: argNames!((ids 0;`buf);(ids 2;`buf);(gf;`f32))
  rp: kSeqIr[lamBody lam; env; `f32]
  kStore[ids 1; gx; rp 0]
  kAsm[]}
shader.stencilU: compStencilU

/ shader.stencilIP — in-place stencil {[u;g;i]}: u (binding 0) is read AND
/ written (red-black SOR: reds read just-written blacks). Non-updated cells must
/ store their own value; the same-value read/write race is benign on real HW.
/ gpu.dispatch (state; params).
compStencilIP: {[fn]
  ids: kAlloc[0;2;0;0]
  lam: lamOf fn; argNames: lamArgs lam
  gx: kGidX[]; gf: kGidF[gx]
  env: argNames!((ids 0;`buf);(ids 1;`buf);(gf;`f32))
  rp: kSeqIr[lamBody lam; env; `f32]
  kStore[ids 0; gx; rp 0]                       / write in place (binding 0)
  kAsm[]}
shader.stencilIP: compStencilIP

/ shader.scatter — edge-parallel atomic scatter {[acc;a;b;g;i]}: one thread per
/ EDGE; acc (binding 0) is an i32 accumulator hit via scatterAdd (OpAtomicIAdd);
/ a/b/g are f32 buffers. No auto-output — the body is its side effects. Guard the
/ scatter VALUE to 0 for over-dispatched threads. Read back with gpu.readI.
compScatter: {[fn]
  ids: kAlloc[1;3;0;0]
  lam: lamOf fn; argNames: lamArgs lam
  gx: kGidX[]; gf: kGidF[gx]
  env: argNames!((ids 0;`scat);(ids 1;`buf);(ids 2;`buf);(ids 3;`buf);(gf;`f32))
  rp: kSeqIr[lamBody lam; env; `f32]           / side effects only
  kAsm[]}
shader.scatter: compScatter

/ gpu.kernel[fn;nAcc;nBuf] — the general kernel: nAcc i32 accumulators
/ (bindings 0..nAcc-1: scatterAdd/iget/iset) + nBuf f32 buffers (read b[j],
/ write set[b;j;v]) + i. No automatic output store — one kernel can update
/ several buffers (XPBD integrate writes p, v AND prev). In-kernel loops
/ (rsum/rmax, i f/ x, f g/ x) are available here (kAlloc emits the loop consts).
compGpN: {[fn; nAcc; nBuf]
  ids: kAlloc[nAcc;nBuf;0;1]
  lam: lamOf fn; argNames: lamArgs lam
  gx: kGidX[]; gf: kGidF[gx]
  accPairs: {[id] (id;`scat)}' nAcc#ids
  bufPairs: {[id] (id;`buf)}' nAcc _ ids
  env: argNames!(accPairs,bufPairs,(,(gf;`f32)))
  rp: kSeqIr[lamBody lam; env; `f32]
  kAsm[]}
gpu.kernel: compGpN

/ ── shader.kernel[fn] — gpu.kernel with the binding table INFERRED ───────────
/ Roles come from the lambda itself (kk.md incr 3, bindings-from-free-vars):
/ a param passed as the FIRST argument of scatterAdd/iget/iset anywhere in the
/ body is an i32 accumulator; the LAST param is the thread index; every other
/ param is an f32 buffer. Accumulator params must come first (bindings are
/ accs 0..nAcc-1 then bufs) — misordering warns and mis-binds, so don't.
/ nbind for the host pipeline = (#params)-1; published as KKnb so gpu.pipeline
/ (lib/gpu.k) can compile SPIR-V + pipeline in one call without re-parsing.
KKnb:: 0
/ Distinct names appearing as the first arg of an accumulator intrinsic.
kkScats: {[]
  ap: & `apply = Cst`kind
  ss: ap @ & {[i] (kVal kF1[i;`f]) in `scatterAdd`iget`iset}' ap
  ? {[i] kVal kF1[i;`arg]}' ss}    / kF1 not *kF: `kVal *kF[…]` parses as kVal TIMES kF (noun-adjacency)
shader.kernel: {[fn]
  ps: lamArgs lamOf fn                 / lamOf parses fn → Cst for kkScats
  am: ps in kkScats[]                  / per-param accumulator mask
  nAcc: +/ -1 _ am                     / the index param can't be an accumulator
  $[nAcc; $[&/ nAcc # am; 0; `0 0: "dye: accumulator params must come FIRST in a shader.kernel lambda\n"]; 0]
  KKnb:: (#ps)-1
  compGpN[fn; nAcc; ((#ps)-1)-nAcc]}

varOutOne:   {[ptr;vid]    (0x0004003B;ptr;vid;3)}    / OpVariable Output storage class

/ ════════════════════════════════════════════════════════════════════════════
/ Neutral IR seam (the Tiramisu "Layer 1/2"). Instead of emitting SPIR-V inline,
/ the walker below builds a target-neutral, typed SSA op list; a lowering pass then
/ turns it into a target — SPIR-V words (reusing the op* stencils) or a textual
/ dump (xDump). EVERY entry point now compiles through this IR (kk2 §3): compute
/ via kSeqIr, fragment/fragmentTexN via kSeqIr, vertex/vertexU via xSeqEnv +
/ per-output `vstore nodes. The direct comp* walker is retired (deleted); build
/ → lower-all in build order, loops are opaque region nodes replayed by their
/ lowerer — byte-identical to the old direct path by 1:1 id-order construction.
/ shader.fragmentIr additionally drives the fragment subset with xFold const-
/ folding + xReach DCE; every other path keeps those OFF until its oracle moves
/ from byte-identity to numeric parity (see §3 multi-root fold/DCE, still TODO).
/ See doc/design/dye.md + doc/design/kk.md.  IR node = an index into these lists:
xOp::  ()   / op sym: param const cons extract select arith math neg lnot, plus
            / bufp f2s bufidx sadd setb igetb isetb (loads/effects) and the
            / opaque loop region ops rsum rmax ndo whileL kparam kparami lparam
xTy::  ()   / result type sym
xArg:: ()   / operand node indices (a list) per node
xVal:: ()   / const value / extract index / verb glyph / math name / loop meta
xId::  ()   / SPIR-V id per node, filled by lowering
xRe::  ()   / reachability mask (DCE)
xRgn:: ()   / owning loop node per node (-1 = top level). A loop's body/cond
            / nodes are "owned": the main lowering pass skips them and the
            / loop node's lowerer replays them inside its basic blocks.
XOwn:: -1   / current region owner during build (set by the loop builders)
/ xOpt — const-fold + multi-root DCE on the effectful (compute/vertex) path.
/ 1 (default) = xFold then keep only nodes reachable from the value result(s) +
/ every store + every loop. 0 = lower every node (byte-identical to the pre-opt
/ path); test/kkgold.k pins it to 0 so its SPIR-V diff oracle stays meaningful.
/ With the optimizer on, correctness is guarded by numeric-parity oracles
/ (test/nn.k, test/kkc.k, test/walkgpu.k) + the safety asserts in test/kkopt.k.
/ See kk2 §3.
xOpt:: 1
/ Compile-error latch (`` ` `` = none): xFoldBad/xBakeBad set it to the message
/ symbol and emit a NaN placeholder so the emit walk finishes without crashing on
/ an indexed error; the module assemblers (kAsm / buildMod) return `!xErr` instead
/ of a module when it is set. Reset at the start of every compile (xReset + kAlloc).
xErr:: `
xReset: {[] xErr::`; xOp::(); xTy::(); xArg::(); xVal::(); xId::(); xRe::(); xRgn::(); XOwn::-1}
xEmit: {[op;ty;args;val] xOp,:: ,op; xTy,:: ,ty; xArg,:: ,args; xVal,:: ,val; xRgn,:: XOwn; -1+#xOp}
xSplat: {[vty;snode] xEmit[`cons; vty; (ncVec[vty])#snode; 0n]}

/ ── IR builder: mirrors compNode, but returns (nodeIdx; ty) and records IR ──
xLit: {[i;oty] $[(kKind i) in `floats`ints; xVecLit[i]; xScalarLit[i;oty]]}
/ Vector literals lower to OpConstantComposite in the constants section (`consc),
/ NOT an in-body OpCompositeConstruct (`cons) — mirrors compVecLit exactly.
xVecLit: {[i] vals:0.+kVal i; n:#vals; cs:{[v] xEmit[`const;`f32;();v]}'vals; rty:$[n=2;`v2;n=3;`v3;`v4]; (xEmit[`consc;rty;cs;0n]; rty)}
xScalarLit: {[i;oty] litTy:kKind i; useTy:$[(litTy~`int)&(oty~`f32);`float;litTy]; v:$[(litTy~`int)&(useTy~`float);0.+kVal i;kVal i]; (xEmit[`const;LitSym[useTy];();v]; LitSym[useTy])}

xTransNorm: {[i;env;oty]
  op: kVal kF1[i;`v]
  opTy: $[op in `"<"`">"`"="`"~"; `f32; op in (`"&";`"|"); `bool; oty]
  ap: xNode[kF1[i;`a];env;opTy]; bp: xNode[kF1[i;`b];env;opTy]
  aty: ap 1; bty: bp 1
  rty: binRty[op;aty;bty;oty]
  bcast: (op in `"+"`"-"`"%") & isVecTy[rty] & ~(isVecTy[aty] & isVecTy[bty])
  aN: $[bcast & ~isVecTy[aty]; xSplat[rty; ap 0]; ap 0]
  bN: $[bcast & ~isVecTy[bty]; xSplat[rty; bp 0]; bp 0]
  (xEmit[`arith; rty; (aN;bN); op]; rty)}
xLeGe: {[i;env;flip]
  ap: xNode[kF1[i;`a];env;`f32]; bp: xNode[kF1[kF1[i;`b];`a];env;`f32]
  rc: xEmit[`arith;`bool;(ap 0;bp 0);flip]
  (xEmit[`lnot;`bool;,rc;`]; `bool)}
xTransOp: {[i;env;oty]
  op: kVal kF1[i;`v]; b: kF1[i;`b]
  isEq: ((kKind b)~`apposit) & ((kVal kF1[b;`f])~`"=")
  $[op~`"@";       xGather[i;env]
    (op~`"<")&isEq; xLeGe[i;env;`">"]
    (op~`">")&isEq; xLeGe[i;env;`"<"]
    xTransNorm[i;env;oty]]}
xTrans: {[i;env;oty] $[(kKind kF1[i;`v])~`term; xAdverb[i; kF1[i;`v]; env; oty]; xTransOp[i;env;oty]]}
/ Placed-table column access `(t`c)` (kk2 §2.5): an apposit whose f is a var bound
/ to a `table env entry (a col-name→bufp dict) and whose arg is a symbol → the
/ column c's buffer, element-loaded at the thread index (like an `elem name).
xIsTableCol: {[i;env]
  fN: kF1[i;`f]
  $[~(kKind fN)~`var; 0
    ~(kVal fN) in !env; 0
    ~`table ~ (env kVal fN) 1; 0
    (kKind kF1[i;`a])~`symbol]}
xTableCol: {[i;env]
  cd: (env kVal kF1[i;`f]) 0                 / the column dict for this table
  (xElem[cd kVal kF1[i;`a]]; `f32)}          / column's bufp node → buf[d]
xAppos: {[i;env;oty]
  fN: kF1[i;`f]
  $[(kKind fN)~`term;   xApposAdv[i;fN;env;oty]
    xIsTableCol[i;env]; xTableCol[i;env]
    xApposOp[i;fN;env;oty]]}
xApposOp: {[i;fN;env;oty]
  op: kVal fN; ap: xNode[kF1[i;`a];env;oty]; aty: ap 1
  $[op in mathFns; (xEmit[`math; $[op~`length;`f32;aty]; ,ap 0; op]; $[op~`length;`f32;aty])
    op~`"~"; (xEmit[`lnot;`bool;,ap 0;`]; `bool)
    (xEmit[`neg;aty;,ap 0;`]; aty)]}
/ Monadic adverbed verb: `+/{[k] e}'!K` (and `|/…`) — the CANONICAL spelling of
/ the fused index map-reduce (doc/design/kk2.md §2.4-1/§8-3). The fold-over-each-
/ over-enumerate shape lowers through xRed to the same rsum/rmax region node as
/ the intrinsic spelling, in the same emission order (K expr; f2s; loop node;
/ kparam; body) — byte-identical by construction. Any other monadic adverb
/ application warns and bakes NaN (screaming beats a silent fallthrough to neg).
xIsEachEnum: {[aN]
  $[~(kKind aN)~`apposit; 0
    ~(kKind kF1[aN;`f])~`term; 0
    ~(kVal kF1[aN;`f])~`"'"; 0
    ~(kKind kF1[kF1[aN;`f];`f])~`lambda; 0
    ~(kKind kF1[aN;`a])~`apposit; 0
    (kVal kF1[kF1[aN;`a];`f])~`"!"]}
/ Latch the error (assemblers turn it into `!xErr`) and emit a NaN placeholder so
/ the rest of the emit walk completes without indexing a bare error into garbage.
xFoldBad: {[g] xErr:: `$"dye: unsupported adverbed verb ",($g)," in kernel (only +/{[k] e}'!K, |/…, +/x@W)"; (xEmit[`const;`f32;();0n]; `f32)}
/ +/x@W matrix gather-reduce (kk2 §2.4-3): W is a (k;n) index matrix uploaded flat
/ (W[j*n+d] = the j-th neighbour index of output element d); the fold sums the k
/ gathers of x through those indices. GRk/GRn (k and n) are baked by kk.compile
/ from W's descriptor shape; GIrGid = the thread index d. Emits a real rsum/rmax
/ region node whose body is x[W[(j*n)+d]] (j = the loop counter). Both operands are
/ `buf here (indexed) — unlike the single gather x@w where the right side is `elem.
GRk:: 0; GRn:: 0
xIsGather: {[aN] ((kKind aN)~`transit) & ((kVal kF1[aN;`v])~`"@")}
xRedGather: {[aN; env; op]
  xN: (env kVal kF1[aN;`a]) 0
  wN: (env kVal kF1[aN;`b]) 0
  kx: xEmit[`const; `i32; (); `i$GRk]                / loop bound k (i32 const)
  L:  xEmit[op; `f32; ,kx; 0n]
  sav: XOwn; XOwn:: L
  / Address math (j*n)+d stays i32 — OpIMul/OpIAdd, exact past 2^24, no f2s.
  jpar: xEmit[`kparami; `i32; (); 0n]                / loop counter j (raw i32 phi)
  nC:  xEmit[`const; `i32; (); `i$GRn]               / n (i32 const)
  jn:  xEmit[`arith; `i32; (jpar; nC); `"*"]         / j*n
  jnd: xEmit[`arith; `i32; (jn; GIrGid); `"+"]       / j*n + d
  widx:xEmit[`bufidx; `f32; (wN; jnd); 0n]           / W[(j*n)+d]  (i32 index)
  xsi: xEmit[`f2s; `i32; ,widx; 0n]                  / the loaded index VALUE → i32
  gval:xEmit[`bufidx; `f32; (xN; xsi); 0n]           / x[W[(j*n)+d]]
  XOwn:: sav
  xVal[L]:: (jpar; gval; #xOp)
  (L; `f32)}
xApposAdv: {[i;fN;env;oty]
  vg: kVal kF1[fN;`f]; aN: kF1[i;`a]
  op: $[vg~`"+"; `rsum; vg~`"|"; `rmax; `]
  ok: ((kVal fN)~`"/") & ~op~`               / a /-fold over + or | ?
  $[~ok;            xFoldBad[vg]
    xIsEachEnum[aN]; xRed[kF1[kF1[aN;`a];`a]; kF1[kF1[aN;`f];`f]; env; op]
    xIsGather[aN];   xRedGather[aN; env; op]
    xFoldBad[vg]]}
xFnCall: {[name;i;env;oty]
  args: kF[i;`arg]; n:#args
  a0: xNode[args 0;env;`f32]
  a1: $[n>1; xNode[args 1;env;`f32]; (0;`f32)]
  a2: $[n>2; xNode[args 2;env;`f32]; (0;`f32)]
  rty: $[(name~`length)|(name~`dot);`f32; name~`cross;`v3; a0 1]
  ids: $[n=1;,a0 0; n=2;(a0 0;a1 0); (a0 0;a1 0;a2 0)]
  (xEmit[`math;rty;ids;name]; rty)}
xApplyIdx: {[fr;i;env;oty] ap:xNode[fr;env;oty]; (xEmit[`extract;`f32;,ap 0; kVal kF1[i;`arg]]; `f32)}
xApply: {[i;env;oty]
  fr: kF1[i;`f]; nm: kVal fr
  $[nm~`sample;      xSample[i;env]
    nm~`scatterAdd;  xSadd[i;env]
    nm~`set;         xSet[i;env]
    nm~`iget;        xIget[i;env]
    nm~`iset;        xIset[i;env]
    nm~`rsum;        xRsum[i;env]
    nm~`rmax;        xRmax[i;env]
    nm in mathFns;   xFnCall[nm;i;env;oty]
    isBuf[nm;env];   xBufIdx[(env nm) 0; i; env]
    xApplyIdx[fr;i;env;oty]]}

/ ── IR builders for the compute dialect (mirror the comp* direct walkers) ────
/ Every f32→i32 index truncation is its OWN `f2s node, emitted at the same
/ position the direct path allocates its OpConvertFToS id — that 1:1 id-order
/ correspondence is what keeps the IR path byte-identical (record-then-replay).
xBufIdx: {[bufN; i; env]
  ip: xNode[kF1[i;`arg]; env; `f32]
  si: xEmit[`f2s; `i32; ,ip 0; 0n]
  (xEmit[`bufidx; `f32; (bufN; si); 0n]; `f32)}
xSadd: {[i; env]
  args: kF[i;`arg]
  accN: (env kVal args 0) 0
  ip: xNode[args 1; env; `f32]; si: xEmit[`f2s;`i32;,ip 0;0n]
  vp: xNode[args 2; env; `f32]; vi: xEmit[`f2s;`i32;,vp 0;0n]
  (xEmit[`sadd; `i32; (accN; si; vi); 0n]; `i32)}
xSet: {[i; env]
  args: kF[i;`arg]
  bufN: (env kVal args 0) 0
  ip: xNode[args 1; env; `f32]; si: xEmit[`f2s;`i32;,ip 0;0n]
  vp: xNode[args 2; env; `f32]
  z: xEmit[`setb; `f32; (bufN; si; vp 0); 0n]
  vp}
xIget: {[i; env]
  args: kF[i;`arg]
  accN: (env kVal args 0) 0
  ip: xNode[args 1; env; `f32]; si: xEmit[`f2s;`i32;,ip 0;0n]
  (xEmit[`igetb; `f32; (accN; si); 0n]; `f32)}
xIset: {[i; env]
  args: kF[i;`arg]
  accN: (env kVal args 0) 0
  ip: xNode[args 1; env; `f32]; si: xEmit[`f2s;`i32;,ip 0;0n]
  vp: xNode[args 2; env; `f32]; vi: xEmit[`f2s;`i32;,vp 0;0n]
  z: xEmit[`isetb; `i32; (accN; si; vi); 0n]
  (vi; `i32)}
/ sample[uv] / sample[k;uv] — texture lookup (fragmentTexN only). xVal carries
/ the literal texture index; the lowerer reads the Timg2/TexVars/SampVar globals.
xSample: {[i; env]
  args: kF[i;`arg]
  two: 1<#args
  ti: $[two; kVal args 0; 0]
  uv: xNode[$[two; args 1; args 0]; env; `v2]
  (xEmit[`sample; `v4; ,uv 0; ti]; `v4)}

/ ── Loops as opaque region nodes ─────────────────────────────────────────────
/ The loop node is emitted BEFORE its body so it lowers at the position the
/ direct path called loopOpen; body nodes built after it are owned (xRgn) and
/ replayed inside the loop's basic blocks by the loop lowerer. xVal carries
/ (param-node; result-root; owned-end[; …]) patched after the body is built.
/ Shared rsum/rmax region-node builder: kN = the trip-count expression node,
/ lamN = the 1-param body lambda node, op = `rsum or `rmax. Both the intrinsic
/ spelling (rsum[K;{[k] e}]) and the canonical full syntax (+/{[k] e}'!K, see
/ xFoldEach) land here, so the two are byte-identical by construction.
xRed: {[kN; lamN; env; op]
  pn: *(Cst`value)@kF[lamN;`param]
  kp: xNode[kN; env; `f32]
  kx: xEmit[`f2s; `i32; ,kp 0; 0n]
  L: xEmit[op; `f32; ,kx; 0n]
  sav: XOwn; XOwn:: L
  kpar: xEmit[`kparam; `f32; (); 0n]
  benv: ((!env),pn)!(env[!env],(,(kpar;`f32)))
  bp: xSeq[kF[lamN;`stmt]; benv; `f32]
  XOwn:: sav
  xVal[L]:: (kpar; bp 0; #xOp)
  (L; `f32)}
xRsum: {[i; env] args: kF[i;`arg]; xRed[args 0; args 1; env; `rsum]}
xRmax: {[i; env] args: kF[i;`arg]; xRed[args 0; args 1; env; `rmax]}
xNdo: {[aN; vN; bN; env; oty]
  cp: xNode[aN; env; `f32]
  cx: xEmit[`f2s; `i32; ,cp 0; 0n]
  sp: xNode[bN; env; oty]; sty: sp 1
  L: xEmit[`ndo; sty; (cx; sp 0); 0n]
  sav: XOwn; XOwn:: L
  spar: xEmit[`lparam; sty; (); 0n]
  vpn: *(Cst`value)@kF[vN;`param]
  venv: ((!env),vpn)!(env[!env],(,(spar;sty)))
  bp: xSeq[kF[vN;`stmt]; venv; sty]
  XOwn:: sav
  xVal[L]:: (spar; bp 0; #xOp)
  (L; sty)}
xWhile: {[cN; vN; bN; env; oty]
  sp: xNode[bN; env; oty]; sty: sp 1
  L: xEmit[`whileL; sty; ,sp 0; 0n]
  sav: XOwn; XOwn:: L
  spar: xEmit[`lparam; sty; (); 0n]      / the state phi, shared by cond + body
  cpn: *(Cst`value)@kF[cN;`param]
  cenv: ((!env),cpn)!(env[!env],(,(spar;sty)))
  cc: xSeq[kF[cN;`stmt]; cenv; `bool]
  cEnd: #xOp
  vpn: *(Cst`value)@kF[vN;`param]
  venv: ((!env),vpn)!(env[!env],(,(spar;sty)))
  bp: xSeq[kF[vN;`stmt]; venv; sty]
  XOwn:: sav
  xVal[L]:: (spar; cc 0; cEnd; bp 0; #xOp)
  (L; sty)}
xAdverb: {[i; vN; env; oty]
  glyph: kVal vN
  verb: kF1[vN;`f]
  aN: kF1[i;`a]; bN: kF1[i;`b]
  $[glyph~`"/"; $[(kKind aN)~`lambda; xWhile[aN; verb; bN; env; oty]
                xNdo[aN; verb; bN; env; oty]]
    (0; oty)]}
/ Unrolled (an inner `{[e] xNode[e;env;…]}` each can't see env — lambdas don't
/ close over parent scope), like the direct compList.
xList: {[i;env;oty]
  elems:kF[i;`elem]; n:#elems
  p0:xNode[elems 0;env;`f32]; p1:xNode[elems 1;env;`f32]
  p2:$[n>2; xNode[elems 2;env;`f32]; (0;`f32)]
  p3:$[n>3; xNode[elems 3;env;`f32]; (0;`f32)]
  ids:$[n=2;(p0 0;p1 0); n=3;(p0 0;p1 0;p2 0); (p0 0;p1 0;p2 0;p3 0)]
  rty:$[n=2;`v2;n=3;`v3;`v4]
  (xEmit[`cons;rty;ids;0n]; rty)}
xCond: {[i;env;oty] xCondS[kF[i;`stmt];env;oty]}
xCondS: {[ss;env;oty]
  n:#ss; cp:xNode[ss 0;env;`bool]; tp:xNode[ss 1;env;oty]
  ep: $[n=3; xNode[ss 2;env;oty]; xCondS[2_ss;env;oty]]
  (xEmit[`select; tp 1; (cp 0;tp 0;ep 0); 0n]; tp 1)}
/ Host-global baking on the IR path (mirrors compVar/kBake).
xBakeBad: {[nm] xErr:: `$"dye: cannot bake ",($nm)," (not a param/local, and not a numeric scalar host global)"; (xEmit[`const;`f32;();0n]; `f32)}
xBake: {[nm] v: . nm; $[(@v) in `b`i`f; (xEmit[`const;`f32;();0.+v]; `f32); xBakeBad nm]}
/ An `elem-role env entry is a whole buffer that stands for its element AT THE
/ THREAD INDEX: a bare use of the name loads buf[d] (d = GIrGid, the gid as an
/ i32 IR param the gather kernel binds). This is what lets kk.compile's gather
/ mode write `x@w` (w a whole index vector) and mean x[w[d]]. Plain `buf entries
/ (the gather sources) pass through unloaded — @/`u[i]` index them explicitly.
/ d is i32, so buf[d] indexes directly (no f32 round-trip).
GIrGid:: 0
xElem: {[bufN] xEmit[`bufidx; `f32; (bufN; GIrGid); 0n]}
xVarE: {[p] $[(p 1)~`elem; (xElem[p 0]; `f32); p]}
xVar:  {[i;env] nm: kVal i; $[nm in !env; xVarE[env nm]; xBake nm]}
/ x@w gather (kk2 §2.2): left = a `buf gather source, right = the index value
/ (an `elem name loads w[d]); result = src[f2s(index)].
xGather: {[i;env]
  srcp: xNode[kF1[i;`a]; env; `f32]
  ip:   xNode[kF1[i;`b]; env; `f32]
  si:   xEmit[`f2s; `i32; ,ip 0; 0n]
  (xEmit[`bufidx; `f32; (srcp 0; si); 0n]; `f32)}
xNode: {[i;env;oty]
  tag: kKind i
  $[tag~`var;     xVar[i;env]
    tag in `int`float`ints`floats`bool`string`symbol; xLit[i;oty]
    tag~`transit;  xTrans[i;env;oty]
    tag~`apposit;  xAppos[i;env;oty]
    tag~`apply;    xApply[i;env;oty]
    tag~`list;     xList[i;env;oty]
    tag~`cond;     xCond[i;env;oty]
    tag~`right;    xNode[kF1[i;`clause];env;oty]
    tag~`group;    xNode[kF1[i;`stmt];env;oty]
    (0;oty)]}
xSeqTail: {[stmts;env;oty]
  s: stmts 0
  isb: ((kKind s)~`bind) & (0<#kF[s;`a])
  sfx: $[isb; 0; xNode[s;env;oty]]
  e2: $[isb; ((!env),kVal kF1[s;`v])!(env[!env],(,xNode[kF1[s;`a];env;oty])); env]
  xSeq[1_stmts;e2;oty]}
xSeq: {[stmts;env;oty] n:#stmts; $[n=0;(0;oty); n=1;xNode[stmts 0;env;oty]; xSeqTail[stmts;env;oty]]}
/ Binds-only prefix walk for the vertex body: build bind nodes, return the extended
/ env (mirror of the retired compSeqEnv — bare non-final statements are dropped,
/ binds compile with the `v4 hint).
xSeqEnvTail: {[stmts; env]
  s:   stmts 0
  isb: ((kKind s)~`bind) & (0<#kF[s;`a])
  e2:  $[isb; ((!env),kVal kF1[s;`v])!(env[!env],(,xNode[kF1[s;`a];env;`v4])); env]
  xSeqEnv[1_stmts; e2]}
xSeqEnv: {[stmts; env] $[0=#stmts; env; xSeqEnvTail[stmts; env]]}
/ One varying output: compile its expression with the varying's type hint, then
/ pin the store with a `vstore node (xVal = the varying's output var id).
xVary1: {[el; ty; vid; env] rp: xNode[el; env; ty]; xEmit[`vstore; ty; ,rp 0; vid]}

/ ── IR optimizations ─────────────────────────────────────────────────────────
/ Const-fold f32 scalar arith / a few unary math whose operands are all const.
xSetConst: {[k;v] xOp[k]::`const; xVal[k]::v; xArg[k]::()}
/ Each $[] branch must be ONE expression, so the multi-statement arith/math folds
/ live in helpers. `sqrt@a etc. run on the host (dye is the CPU compiler).
xFoldArith: {[k] args:xArg k; g:xVal k; a:xVal args 0; b:xVal args 1; v:$[g~`"+";a+b;g~`"-";a-b;g~`"*";a*b;g~`"%";a%b;0n]; $[^v;0;xSetConst[k;v]]}
xFoldMath:  {[k] args:xArg k; nm:xVal k; a:xVal args 0; v:$[nm~`sqrt;`sqrt@a;nm~`sqr;a*a;nm~`abs;`abs@a;nm~`sin;`sin@a;nm~`cos;`cos@a;nm~`floor;`floor@a;0n]; $[^v;0;xSetConst[k;v]]}
xFoldOne: {[k]
  op:xOp k; args:xArg k
  $[0=#args; 0
    ~&/{[j](xOp j)~`const}'args; 0
    op~`neg; xSetConst[k; -xVal args 0]
    ~(xTy k)~`f32; 0
    op~`arith; xFoldArith[k]
    op~`math;  xFoldMath[k]
    0]}
xFold: {[] {[k] xFoldOne k}' !#xOp; 0}
/ DCE: mark nodes reachable from root; lowering skips the rest (one high→low pass,
/ since every operand has a lower index than its user).
/ Pure guarded fold (an empty-index amend `m[()]:1b` would corrupt the mask, so
/ skip leaf nodes). Args have lower indices than users, so one high→low pass suffices.
xReach: {[root] {[m;k] $[(m k) & 0<#xArg k; @[m; xArg k; :; 1b]; m]}/[@[(#xOp)#0b; root; :; 1b]; |!#xOp]}

/ ── Multi-root DCE for the effectful (compute/vertex) path ────────────────────
/ Value-only DCE (xReach) has ONE root and no effects — wrong for compute/vertex,
/ where stores have no consumer yet must survive, and a loop's body (reached only
/ via xVal, not xArg) carries the values a store reads. Roots therefore = the
/ value result(s) in `extra` + every effect node (setb/sadd/isetb/vstore) + every
/ loop node AND its result phi(s) (rsum/rmax/ndo → the accumulator/state result;
/ whileL → cond + body results). Seeding the loop results makes the one high→low
/ xArg sweep descend into owned loop bodies and mark the top-level values they use
/ (e.g. a `base` computed before the loop) — without which those would be culled.
/ Un-reached owned nodes are then skipped by xLoRegion, giving intra-loop DCE too.
xEffOps::  `setb`sadd`isetb`vstore
xLoopOps:: `rsum`rmax`ndo`whileL
xLoopRes: {[L] v:xVal L; $[(xOp L)~`whileL; (v 1;v 3); ,v 1]}
xReachC: {[extra]
  lps:   &xOp in xLoopOps
  seeds: extra, (&(xOp in xEffOps)|(xOp in xLoopOps)), $[#lps; ,/xLoopRes'lps; !0]
  {[m;k] $[(m k) & 0<#xArg k; @[m; xArg k; :; 1b]; m]}/[@[(#xOp)#0b; seeds; :; 1b]; |!#xOp]}

/ Lowering driver for the effectful path: optional fold + DCE, then lower every
/ reachable top-level node in build order (owned nodes replayed by their loop's
/ lowerer, also gated on xRe). xOpt=0 marks all nodes reachable → byte-identical.
xLowerC: {[extra]
  xId:: (#xOp)#-1
  $[xOpt; xFold[]; 0]
  xRe:: $[xOpt; xReachC[extra]; (#xOp)#1b]
  {[j] $[(0 > xRgn j) & xRe j; xLowerOne j; 0]}' !#xOp
  0}

/ ── Back-end 1: lower IR → SPIR-V words (reuse the op* stencils) ──────────────
xConsW: {[ty;r;ids] n:#ids; $[n=2;opCons2[Tid[ty];r;ids 0;ids 1]; n=3;opCons3[Tid[ty];r;ids 0;ids 1;ids 2]; opCons4[Tid[ty];r;ids 0;ids 1;ids 2;ids 3]]}
xMathW: {[name;ty;r;ids;at]
  $[name~`abs;opAbs[at;r;ids 0]; name~`floor;opFloor[at;r;ids 0]; name~`fract;opFract[at;r;ids 0]
    name~`sign;opSign[at;r;ids 0]; name~`sqrt;opSqrt[at;r;ids 0]; name~`exp;opExp[at;r;ids 0]
    name~`log;opLog[at;r;ids 0]; name~`tanh;opTanh[at;r;ids 0]; name~`sqr;opFmul[at;r;ids 0;ids 0]
    name~`sin;opSin[at;r;ids 0]; name~`cos;opCos[at;r;ids 0]; name~`asin;opAsin[at;r;ids 0]
    name~`acos;opAcos[at;r;ids 0]; name~`atan;opAtan[at;r;ids 0]; name~`atan2;opAtan2[at;r;ids 0;ids 1]
    name~`length;opLen[Tf32;r;ids 0]; name~`normalize;opNrm[at;r;ids 0]; name~`pow;opPow[at;r;ids 0;ids 1]
    name~`min;opFmin[at;r;ids 0;ids 1]; name~`max;opFmax[at;r;ids 0;ids 1]; name~`dot;opDot[Tf32;r;ids 0;ids 1]
    name~`cross;opCrs[Tv3;r;ids 0;ids 1]; name~`step;opStep[at;r;ids 0;ids 1]; name~`mod;opFmod[at;r;ids 0;ids 1]
    name~`clamp;opClamp[at;r;ids 0;ids 1;ids 2]; name~`mix;opMix[at;r;ids 0;ids 1;ids 2]
    name~`smoothstep;opSS[at;r;ids 0;ids 1;ids 2]; opFneg[at;r;ids 0]]}
/ One helper per op (each $[] branch must be a single expression). Each allocates
/ an id, emits its op* words (into Con for constants, else Buf), and records xId[k].
xLoConst:   {[k] xId[k]:: constId[Tid[xTy k]; xVal k]}
xLoCons:    {[k] r:newId[]; emitBuf xConsW[xTy k;r;xId@xArg k]; xId[k]::r}
/ Vector literal: OpConstantComposite 44 into the constants section (like compVecLit;
/ the composite itself is NOT deduplicated — each literal gets a fresh id).
xLoConsC:   {[k] r:newId[]; ids:xId@xArg k; emitCon (0x2C+(0x10000*(3+#ids)); Tid[xTy k]; r),ids; xId[k]::r}
/ Texture sample: image+sampler loads, OpSampledImage 86, ImageSampleImplicitLod 87.
xLoSample:  {[k]
  li:newId[]; emitBuf opLoad[Timg2; li; TexVars[xVal k]]
  ls:newId[]; emitBuf opLoad[Tsamp2; ls; SampVar]
  ci:newId[]; emitBuf (0x00050056; TsImg; ci; li; ls)
  r:newId[];  emitBuf (0x00050057; Tv4; r; ci; (xId@xArg k)0)
  xId[k]::r}
xLoExtract: {[k] r:newId[]; emitBuf opXtract[Tf32;r;(xId@xArg k)0;xVal k]; xId[k]::r}
xLoSelect:  {[k] r:newId[]; ids:xId@xArg k; emitBuf opSel[Tid[xTy k];r;ids 0;ids 1;ids 2]; xId[k]::r}
xLoNeg:     {[k] r:newId[]; emitBuf opFneg[Tid[xTy k];r;(xId@xArg k)0]; xId[k]::r}
xLoLnot:    {[k] r:newId[]; emitBuf opLNot[Tbool;r;(xId@xArg k)0]; xId[k]::r}
xLoArith:   {[k] a:xArg k; ids:xId@a; r:newId[]; emitBuf dispBin[xVal k; xTy k; r; xTy a 0; ids 0; xTy a 1; ids 1]; xId[k]::r}
xLoMath:    {[k] a:xArg k; ids:xId@a; r:newId[]; emitBuf xMathW[xVal k; xTy k; r; ids; Tid[xTy a 0]]; xId[k]::r}
/ ── Compute-dialect lowerers (1:1 id-order with the direct comp* emitters) ───
xLoF2s:    {[k] r:newId[]; emitBuf opF2s[Ti32; r; (xId@xArg k)0]; xId[k]::r}
xLoBufIdx: {[k] a:xArg k; p:newId[]; emitBuf opAccChain[CPf32; p; xId a 0; CKz; xId a 1]; r:newId[]; emitBuf opLoad[Tf32; r; p]; xId[k]::r}
xLoSadd:   {[k] a:xArg k; ptr:newId[]; emitBuf opAccChain[CPi32; ptr; xId a 0; CKz; xId a 1]; old:newId[]; emitBuf opAtomicIAdd[Ti32; old; ptr; CScope; CKz; xId a 2]; xId[k]::old}
xLoSet:    {[k] a:xArg k; p:newId[]; emitBuf opAccChain[CPf32; p; xId a 0; CKz; xId a 1]; emitBuf opStore[p; xId a 2]; xId[k]::0}
xLoIget:   {[k] a:xArg k; p:newId[]; emitBuf opAccChain[CPi32; p; xId a 0; CKz; xId a 1]; iv:newId[]; emitBuf opLoad[Ti32; iv; p]; fv:newId[]; emitBuf opI2f[Tf32; fv; iv]; xId[k]::fv}
xLoIset:   {[k] a:xArg k; p:newId[]; emitBuf opAccChain[CPi32; p; xId a 0; CKz; xId a 1]; emitBuf opStore[p; xId a 2]; xId[k]:: xId a 2}

/ Vertex output stores (`vstore effect node): xVal=`pos stores gl_Position through
/ the gl_PerVertex block member (access chain via the VXpvtx/VXkz per-shader
/ globals — allocates the pointer id AT ITS BUILD POSITION, keeping id order
/ byte-identical to the retired direct path); any other xVal is a varying output
/ var id, stored directly (no id allocated).
VXpvtx:: 0; VXkz:: 0
xLoVsPos:  {[k] p:newId[]; emitBuf opAccChain1[PoutV4; p; VXpvtx; VXkz]; emitBuf opStore[p; (xId@xArg k)0]; xId[k]::0}
xLoVsVar:  {[k] emitBuf opStore[xVal k; (xId@xArg k)0]; xId[k]::0}
xLoVstore: {[k] $[(xVal k)~`pos; xLoVsPos[k]; xLoVsVar[k]]}

/ Loop lowerers: replay the owned nodes inside the loop's basic blocks. The
/ phi ids travel through RKiPhi/RKsPhi globals (lambdas can't close); each
/ loop saves/restores them so nesting is safe. XLk is the region filter owner.
RKiPhi:: 0; RKsPhi:: 0; XLk:: -1
xLoKparam: {[k] r:newId[]; emitBuf opI2f[Tf32; r; RKiPhi]; xId[k]::r}
/ i32 loop counter: the raw counter phi, no i2f (used by i32 index arithmetic).
xLoKparami: {[k] xId[k]:: RKiPhi}
xLoLparam: {[k] xId[k]:: RKsPhi}
xLoRegion: {[k; lo; hi] sav: XLk; XLk:: k; {[j] $[((xRgn j)=XLk) & xRe j; xLowerOne j; 0]}' lo+!hi-lo; XLk:: sav; 0}
xLoRsum: {[k]
  a: xArg k; v: xVal k
  h: loopOpen[xId a 0; RCf0; `f32]
  svi: RKiPhi; RKiPhi:: h 0
  xLoRegion[k; 1+k; v 2]
  RKiPhi:: svi
  nv: newId[]; emitBuf opFadd[Tf32; nv; h 1; xId v 1]
  loopClose[nv; `f32; h 3; h 2; h 0; h 4; h 5; h 6]
  xId[k]:: h 1}
xLoRmax: {[k]
  a: xArg k; v: xVal k
  h: loopOpen[xId a 0; RCfNeg; `f32]
  svi: RKiPhi; RKiPhi:: h 0
  xLoRegion[k; 1+k; v 2]
  RKiPhi:: svi
  nv: newId[]; emitBuf opFmax[Tf32; nv; h 1; xId v 1]
  loopClose[nv; `f32; h 3; h 2; h 0; h 4; h 5; h 6]
  xId[k]:: h 1}
xLoNdo: {[k]
  a: xArg k; v: xVal k; sty: xTy k
  h: loopOpen[xId a 0; xId a 1; sty]
  svs: RKsPhi; RKsPhi:: h 1
  xLoRegion[k; 1+k; v 2]
  RKsPhi:: svs
  loopClose[xId v 1; sty; h 3; h 2; h 0; h 4; h 5; h 6]
  xId[k]:: h 1}
xLoWhile: {[k]
  a: xArg k; v: xVal k; sty: xTy k
  preL:newId[]; hdrL:newId[]; bodL:newId[]; conL:newId[]; mrgL:newId[]
  sPhi:newId[]; sNext:newId[]
  emitBuf opBranch[preL]; emitBuf opLabel[preL]; emitBuf opBranch[hdrL]; emitBuf opLabel[hdrL]
  emitBuf opPhi2[Tid[sty]; sPhi; xId a 0; preL; sNext; conL]
  svs: RKsPhi; RKsPhi:: sPhi
  xLoRegion[k; 1+k; v 2]                       / lparam + cond nodes (header)
  emitBuf opLoopMrg[mrgL; conL]; emitBuf opBrCond[xId v 1; bodL; mrgL]; emitBuf opLabel[bodL]
  xLoRegion[k; v 2; v 4]                       / body nodes
  RKsPhi:: svs
  emitBuf opCopy[Tid[sty]; sNext; xId v 3]
  emitBuf opBranch[conL]; emitBuf opLabel[conL]; emitBuf opBranch[hdrL]; emitBuf opLabel[mrgL]
  xId[k]:: sPhi}

xLowerOne: {[k]
  op:xOp k
  $[op~`param;   xId[k]:: xVal k
    op~`bufp;    xId[k]:: xVal k
    op~`const;   xLoConst[k]
    op~`cons;    xLoCons[k]
    op~`consc;   xLoConsC[k]
    op~`sample;  xLoSample[k]
    op~`extract; xLoExtract[k]
    op~`select;  xLoSelect[k]
    op~`neg;     xLoNeg[k]
    op~`lnot;    xLoLnot[k]
    op~`arith;   xLoArith[k]
    op~`math;    xLoMath[k]
    op~`f2s;     xLoF2s[k]
    op~`bufidx;  xLoBufIdx[k]
    op~`sadd;    xLoSadd[k]
    op~`setb;    xLoSet[k]
    op~`igetb;   xLoIget[k]
    op~`isetb;   xLoIset[k]
    op~`kparam;  xLoKparam[k]
    op~`kparami; xLoKparami[k]
    op~`lparam;  xLoLparam[k]
    op~`vstore;  xLoVstore[k]
    op~`rsum;    xLoRsum[k]
    op~`rmax;    xLoRmax[k]
    op~`ndo;     xLoNdo[k]
    op~`whileL;  xLoWhile[k]
    0]}
/ xRe is a GLOBAL so the each's lambda can read it (no closure over the local mask).
xLowerSpirv: {[root] xId::(#xOp)#-1; xRe:: xReach[root]; {[k] $[xRe k; xLowerOne k; 0]}' !#xOp; 0}

/ ── Compute bodies through the IR (kk.md incr 3: the seam migration) ─────────
/ Build the whole body as IR, then lower via xLowerC (the value result is the DCE
/ root; stores + loops are auto-rooted). loop-owned nodes are replayed by their
/ loop's lowerer. With xOpt=0 the oracle is BYTE-IDENTITY with the old direct path
/ (test/kkgold.k); xOpt=1 turns on fold+DCE (numeric parity, test/kkopt.k). Env
/ pairs from the prologue become param (loaded value) / bufp (binding var) nodes;
/ the prologue/epilogue stay direct — the IR owns only the body.
kIrEnvOne: {[p] $[(p 1) in `buf`scat; (xEmit[`bufp; p 1; (); p 0]; p 1); (xEmit[`param; p 1; (); p 0]; p 1)]}
kSeqIr: {[stmts; env; oty]
  xReset[]
  e2: (!env) ! kIrEnvOne' env[!env]
  rp: xSeq[stmts; e2; oty]
  xLowerC[,rp 0]
  ((xId rp 0); rp 1)}

/ ── Back-end 2: textual IR dump (proves the same IR retargets) ────────────────
xArgStr: {[k] a:xArg k; $[0=#a;"[]"; ","/$'a]}
xDump: {[] {[k] `0 0: ($k),": ",($xOp k)," :",($xTy k)," (",xArgStr[k],") ",$xVal k}' !#xOp; 0}

/ ── Entry point: fragment shader compiled through the neutral IR ──────────────
shader.fragmentIr: {[ioTypes; fn]
  Nid::Nfixed; Buf::(); Con::(); ConKeyT::(); ConKeyV::(); ConVal::()
  TexVars:: ()
  xReset[]
  lam: lamOf fn; argNames: lamArgs lam
  outTySym: ioTypes[`out]; outPtr: PtrOut[outTySym]
  inTySyms: ioTypes' argNames; inTys: Tid' inTySyms; inPtrs: PtrIn' inTySyms
  inVarIds: {[x] newId[]}' argNames
  outId: newId[]
  loadedPairs: inVarIds loadOnePair' inTySyms
  penv: argNames!{[p] (xEmit[`param; p 1; (); p 0]; p 1)}' loadedPairs
  rp: xSeq[lamBody lam; penv; outTySym]
  root: rp 0
  xFold[]
  xLowerSpirv[root]
  emitBuf opStore[outId; xId root]
  buildMod[outId; inVarIds; inTys; inPtrs; outPtr; !#argNames]}
