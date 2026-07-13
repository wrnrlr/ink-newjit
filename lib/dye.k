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

  / Compile body: statement rows, process bind nodes for locals
  stmts: lamBody lam
  rp: compSeq[stmts; env; outTySym]
  result: rp[0]

  emitBuf opStore[outId; result]

  locs: !#argNames
  buildMod[outId; inVarIds; inTys; inPtrs; outPtr; locs]
}

/ ── shader.fragmentTexN[ioTypes; nTex; fn] → SPIR-V word list ────────────────
/ Like shader.fragment, plus nTex sampled 2-D textures at @group(1): image k is at
/ binding k, and one shared sampler at binding nTex.  The body samples texture k
/ with  sample[k; uv]  → v4 (sample[uv] is texture 0).  See compSample.  The host
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

  / Allocate the texture ids and publish them so compSample can emit the loads.
  / One image type / sampler type shared by all nTex images; one var per image
  / plus one shared sampler var.
  Timg2::   newId[]; Tsamp2::  newId[]; TsImg::   newId[]
  PUCimg::  newId[]; PUCsamp:: newId[]
  TexVars:: {[x] newId[]}' !nTex
  SampVar:: newId[]

  loadedPairs: inVarIds loadOnePair' inTySyms
  env: argNames!loadedPairs

  stmts: lamBody lam
  rp: compSeq[stmts; env; outTySym]
  result: rp[0]

  emitBuf opStore[outId; result]

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

  / Compile body stmts (all but last) to build env, then handle return tuple
  stmts:    lamBody lam
  env2:     compSeqEnv[-1_stmts; env]
  lastStmt: last stmts

  / If varyings exist the last stmt is a list node; else it's the glPos expression
  outElems: $[(nVary>0) & ((kKind lastStmt)~`list); kF[lastStmt;`elem]; ,lastStmt]

  / Compile and store gl_Position through the Block struct member pointer
  glPosVal:       compNode[outElems[0]; env2; `v4]
  glPosMemberPtr: newId[]
  emitBuf opAccChain1[PoutV4; glPosMemberPtr; perVtxVar; Kzero]
  emitBuf opStore[glPosMemberPtr; glPosVal[0]]

  / Compile and store varyings (up to 3)
  rp0: $[nVary>0; compNode[outElems[1]; env2; varyTySyms[0]]; (0;`f32)]
  $[nVary>0; emitBuf opStore[varyVarIds[0]; rp0[0]]; 0]
  rp1: $[nVary>1; compNode[outElems[2]; env2; varyTySyms[1]]; (0;`f32)]
  $[nVary>1; emitBuf opStore[varyVarIds[1]; rp1[0]]; 0]
  rp2: $[nVary>2; compNode[outElems[3]; env2; varyTySyms[2]]; (0;`f32)]
  $[nVary>2; emitBuf opStore[varyVarIds[2]; rp2[0]]; 0]
  rp3: $[nVary>3; compNode[outElems[4]; env2; varyTySyms[3]]; (0;`f32)]
  $[nVary>3; emitBuf opStore[varyVarIds[3]; rp3[0]]; 0]

  / Assemble SPIR-V module
  bnd:   Nid+1
  iface: inVarIds,(,perVtxVar),varyVarIds

  hdr: (0x07230203; 0x00010300; 0; bnd; 0)
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
mathFns1: `abs`floor`fract`sign`sqrt`exp`log`tanh`sqr`sin`cos`asin`acos`atan`length`normalize
mathFns:  `abs`floor`fract`sign`sqrt`exp`log`tanh`sqr`sin`cos`asin`acos`atan`length`normalize`pow`min`max`atan2`dot`cross`step`mod`clamp`mix`smoothstep

/ ── Verb dispatch ────────────────────────────────────────────────────────────
dispBin: {[op;rty;r;aty;a;bty;b]
  rt: Tid[rty]
  at: Tid[aty]
  $[op~`"+";   opFadd[rt;r;a;b]
    op~`"-";   opFsub[rt;r;a;b]
    op~`"%";   opFdiv[rt;r;a;b]
    op~`"*";   $[isVecTy[aty] & ~isVecTy[bty]; opVTS[rt;r;a;b]
               isVecTy[bty] & ~isVecTy[aty]; opVTS[rt;r;b;a]
               opFmul[rt;r;a;b]]
    op~`",";   (0x00050050;rt;r;a;b)   / OpCompositeConstruct, 2 constituents: v2+f32→v3, v3+f32→v4, etc.
    op~`"<";   opFOlt[at;r;a;b]   / <= / >= are handled by the compTrans peephole
    op~`">";   opFOgt[at;r;a;b]
    op~`"=";   opFOeq[at;r;a;b]
    op~`"~";   opFOne[at;r;a;b]
    op~`"&";   opLAnd[at;r;a;b]
    op~`"|";   opLOr[at;r;a;b]
    opFadd[rt;r;a;b]]}

dispUn: {[op;ty;r;a]
  t: Tid[ty]
  $[op~`sin;       opSin[t;r;a]
    op~`cos;       opCos[t;r;a]
    op~`sqrt;      opSqrt[t;r;a]
    op~`"-";         opFneg[t;r;a]
    op~`"~";         opLNot[Tbool;r;a]
    op~`abs;       opAbs[t;r;a]
    op~`floor;     opFloor[t;r;a]
    op~`fract;     opFract[t;r;a]
    op~`sign;      opSign[t;r;a]
    op~`sqr;       opFmul[t;r;a;a]
    op~`length;    opLen[Tf32;r;a]
    op~`normalize; opNrm[t;r;a]
    opFneg[t;r;a]]}

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
/ section; set per shader, read by compSample (ink lambdas can't see enclosing
/ locals, so these live as globals).
Timg2::   0   / OpTypeImage (f32, 2D, sampled)
Tsamp2::  0   / OpTypeSampler
TsImg::   0   / OpTypeSampledImage
PUCimg::  0   / OpTypePointer UniformConstant → image
PUCsamp:: 0   / OpTypePointer UniformConstant → sampler
TexVars:: ()  / OpVariable UniformConstant image ids (image k at set 1 binding k)
SampVar:: 0   / OpVariable UniformConstant sampler (set 1, binding nTex)
/ Stencil-compute scratch: the u32-zero constant id (struct member index) and the
/ StorageBuffer→f32 pointer type id, needed by compBufIdx for a dynamic-index load
/ (ink lambdas can't close over compStencil's locals, so these live as globals).
CKz::   0     / OpConstant u32 0 — access-chain member index into the buffer struct
CPf32:: 0     / OpTypePointer StorageBuffer → f32
/ Atomic-scatter scratch (compScatter/compScatterAdd): the StorageBuffer→i32
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

/ Bug fix: splat a scalar id `sid` to vector type `vty` via OpCompositeConstruct.
/ SPIR-V OpFAdd/Sub/Div require both operands to share the exact type, so a
/ vector ⊕ scalar arithmetic op (e.g. `uv + 0.5`) must widen the scalar first —
/ otherwise the emitted module is invalid SPIR-V.
splat: {[vty; sid]
  n: ncVec[vty]; rt: Tid[vty]; r: newId[]
  $[n=2; emitBuf opCons2[rt;r;sid;sid]
    n=3; emitBuf opCons3[rt;r;sid;sid;sid]
    emitBuf opCons4[rt;r;sid;sid;sid;sid]]
  r}

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

/ ── Layer 3: math function call compiler ───────────────────────────────────
/ Compile f[a; b; c] where f is a known GLSL built-in. args are the `arg rows.
compFnCall: {[name; i; env; oty]
  args: kF[i;`arg]
  n:    #args
  a0:   compNode[args[0];env;`f32]
  a1:   $[n>1; compNode[args[1];env;`f32]; (0;`f32)]
  a2:   $[n>2; compNode[args[2];env;`f32]; (0;`f32)]
  at:   Tid[a0[1]]
  rty:  $[(name~`length)|(name~`dot); `f32; (name~`cross); `v3; a0[1]]
  r:    newId[]
  $[name~`abs;        emitBuf opAbs[at;r;a0[0]]
    name~`floor;      emitBuf opFloor[at;r;a0[0]]
    name~`fract;      emitBuf opFract[at;r;a0[0]]
    name~`sign;       emitBuf opSign[at;r;a0[0]]
    name~`sqrt;       emitBuf opSqrt[at;r;a0[0]]
    name~`exp;        emitBuf opExp[at;r;a0[0]]
    name~`log;        emitBuf opLog[at;r;a0[0]]
    name~`tanh;       emitBuf opTanh[at;r;a0[0]]
    name~`sqr;        emitBuf opFmul[at;r;a0[0];a0[0]]
    name~`sin;        emitBuf opSin[at;r;a0[0]]
    name~`cos;        emitBuf opCos[at;r;a0[0]]
    name~`asin;       emitBuf opAsin[at;r;a0[0]]
    name~`acos;       emitBuf opAcos[at;r;a0[0]]
    name~`atan;       emitBuf opAtan[at;r;a0[0]]
    name~`atan2;      emitBuf opAtan2[at;r;a0[0];a1[0]]
    name~`length;     emitBuf opLen[Tf32;r;a0[0]]
    name~`normalize;  emitBuf opNrm[at;r;a0[0]]
    name~`pow;        emitBuf opPow[at;r;a0[0];a1[0]]
    name~`min;        emitBuf opFmin[at;r;a0[0];a1[0]]
    name~`max;        emitBuf opFmax[at;r;a0[0];a1[0]]
    name~`dot;        emitBuf opDot[Tf32;r;a0[0];a1[0]]
    name~`cross;      emitBuf opCrs[Tv3;r;a0[0];a1[0]]
    name~`step;       emitBuf opStep[at;r;a0[0];a1[0]]
    name~`mod;        emitBuf opFmod[at;r;a0[0];a1[0]]
    name~`clamp;      emitBuf opClamp[at;r;a0[0];a1[0];a2[0]]
    name~`mix;        emitBuf opMix[at;r;a0[0];a1[0];a2[0]]
    name~`smoothstep; emitBuf opSS[at;r;a0[0];a1[0];a2[0]]
    0]
  (r; rty)}

/ ── Layer 3: expression compilers ─────────────────────────────────────────

/ Vector literal `127.1 311.7` → OpConstantComposite (v2/v3/v4 of f32).
/ Each component is emitted as its own f32 OpConstant first, then referenced.
/ This lets shaders write `dot[p; 127.1 311.7]` instead of `dot[p; (127.1;311.7)]`.
compVecLit: {[i]
  vals: 0.+kVal i
  n:    #vals
  ids:  {[v] constId[Tf32;v]}' vals
  rty:  $[n=2;`v2; n=3;`v3; `v4]
  r:    newId[]
  emitCon (0x2C+(0x10000*(3+n)); Tid[rty]; r),ids   / OpConstantComposite 44
  (r; rty)
}

compScalarLit: {[i; oty]
  litTy: kKind i
  useTy: $[(litTy~`int) & (oty~`f32); `float; litTy]
  t:   LitTid[useTy]
  val: $[(litTy~`int) & (useTy~`float); 0.+kVal i; kVal i]
  r: constId[t;val]
  (r; LitSym[useTy])
}

compLit: {[i; oty]
  $[(kKind i) in `floats`ints; compVecLit[i]; compScalarLit[i;oty]]
}

compVar: {[i; env] env[kVal i]}

/ x<=y → ~(x>y),  x>=y → ~(x<y).  `flip` is the strict comparison to negate;
/ the b operand is an apposit(`"=" …) wrapper, so its `a child is the real operand.
compLeGe: {[i; env; flip]
  ap: compNode[kF1[i;`a];          env; `f32]
  bp: compNode[kF1[kF1[i;`b];`a];  env; `f32]
  rc: newId[]
  emitBuf dispBin[flip; `bool; rc; ap[1]; ap[0]; bp[1]; bp[0]]
  r:  newId[]
  emitBuf opLNot[Tbool; r; rc]
  (r; `bool)
}

compTransNorm: {[i; env; oty]
  op: kVal kF1[i;`v]
  / Feed the right hint to operands: numeric comparisons want f32, bool ops want bool
  opTy: $[op in `"<"`">"`"="`"~"; `f32; op in (`"&";`"|"); `bool; oty]
  ap: compNode[kF1[i;`a]; env; opTy]
  bp: compNode[kF1[i;`b]; env; opTy]
  aty: ap[1]; bty: bp[1]
  rty: binRty[op; aty; bty; oty]
  / Bug fix: for +,-,% on vector ⊕ scalar, splat the scalar up to the vector type
  / so OpFAdd/Sub/Div see matching operands (* uses OpVectorTimesScalar already).
  bcast: (op in `"+"`"-"`"%") & isVecTy[rty] & ~(isVecTy[aty] & isVecTy[bty])
  aId: $[bcast & ~isVecTy[aty]; splat[rty; ap[0]]; ap[0]]
  bId: $[bcast & ~isVecTy[bty]; splat[rty; bp[0]]; bp[0]]
  da:  $[bcast & ~isVecTy[aty]; rty; aty]
  db:  $[bcast & ~isVecTy[bty]; rty; bty]
  r: newId[]
  emitBuf dispBin[op; rty; r; da; aId; db; bId]
  (r; rty)
}

/ Peephole for the missing <= / >= operators.  ink has no such tokens: `x<=y`
/ lexes as `x < (=y)` and `x>=y` as `x > (=y)` (monadic `"="` on the right).
/ Detect that shape and emit the De Morgan equivalent so shaders can write
/ `a<=b` / `a>=b` directly instead of `"~"(a>b)` / `"~"(a<b)`.
compTrans: {[i; env; oty]
  vN: kF1[i;`v]
  $[(kKind vN)~`term; compAdverb[i; vN; env; oty]   / adverbed verb: `i f/ x`"," `f g/ x`
    compTransOp[i; env; oty]]
}
compTransOp: {[i; env; oty]
  op: kVal kF1[i;`v]; b: kF1[i;`b]
  isEq: ((kKind b)~`apposit) & ((kVal kF1[b;`f])~`"=")
  $[(op~`"<") & isEq; compLeGe[i; env; `">"]
    (op~`">") & isEq; compLeGe[i; env; `"<"]
    compTransNorm[i; env; oty]]
}

/ Monadic application written as juxtaposition: `floor px`"," `sin px`"," `"-"x`.
/ The op slot is a bare symbol for built-in verbs (`sin`"-"x) but a var node
/ (`literal;`var;`floor) for math names that aren't ink keywords — normalise
/ both to the bare symbol so dispUn matches (else floor/fract/sign/length/
/ normalize silently fall through to negate).
/ Monadic application `floor px`"," `"-"x`. The f slot is a var row (math name) or an
/ op row (builtin verb); either way its `value holds the glyph/name for dispUn.
compAppos: {[i; env; oty]
  op: kVal kF1[i;`f]
  ap: compNode[kF1[i;`a]; env; oty]
  r: newId[]
  emitBuf dispUn[op; ap[1]; r; ap[0]]
  rty: $[op~`length; `f32; op~`"~"; `bool; ap[1]]
  (r; rty)
}

/ Composite indexing fallback: v[i] → OpCompositeExtract. `fr` is the f row.
compApplyIdx: {[fr; i; env; oty]
  ap:  compNode[fr; env; oty]
  idx: kVal kF1[i;`arg]
  r:   newId[]
  emitBuf opXtract[Tf32; r; ap[0]; idx]
  (r; `f32)
}

/ Buffer indexing (stencil intrinsic): u[j] where u is a storage buffer and j is
/ ANY expression → dynamic load. The index is computed in f32 (so all existing
/ arithmetic/conditionals just work — exact for integers ≤ 2^24), truncated to i32,
/ then OpAccessChain(member 0, j) + OpLoad. `bufId` is the buffer's OpVariable.
compBufIdx: {[bufId; i; env]
  ip: compNode[kF1[i;`arg]; env; `f32]          / index expression as f32
  si: newId[]; emitBuf opF2s[Ti32; si; ip[0]]   / f32 → i32 (truncate)
  p:  newId[]; emitBuf opAccChain[CPf32; p; bufId; CKz; si]
  r:  newId[]; emitBuf opLoad[Tf32; r; p]
  (r; `f32)
}

/ Is `nm` a storage-buffer binding in the current env? (short-circuits the lookup)
isBuf: {[nm; env] $[nm in !env; `buf~(env nm)1; 0]}

/ Atomic scatter-add (edge-list / cloth intrinsic): scatterAdd[acc; idx; val] does
/ acc[idx] += val atomically (OpAtomicIAdd, Device scope). `acc` is an i32 storage
/ buffer (a `scat` env entry), idx/val are computed in f32 then truncated to i32 —
/ so callers scale floats to fixed point (e.g. scatterAdd[acc; i; 65536.*dx]). This
/ is how many edges accumulate a correction onto the SAME particle without a race.
compScatterAdd: {[i; env]
  args: kF[i;`arg]                              / (accName; idxExpr; valExpr)
  accId: (env kVal args[0])0
  ip: compNode[args[1]; env; `f32]; si:newId[]; emitBuf opF2s[Ti32; si; ip[0]]
  vp: compNode[args[2]; env; `f32]; vi:newId[]; emitBuf opF2s[Ti32; vi; vp[0]]
  ptr: newId[]; emitBuf opAccChain[CPi32; ptr; accId; CKz; si]
  old: newId[]; emitBuf opAtomicIAdd[Ti32; old; ptr; CScope; CKz; vi]  / old value discarded
  (old; `i32)
}

/ set[buf; idx; val] — plain (non-atomic) store buf[idx]:=val into an f32 buffer.
/ Lets a kernel write several buffers as side effects (gpu.kernel has no auto-output).
compSet: {[i; env]
  args: kF[i;`arg]                              / (bufName; idxExpr; valExpr)
  bid: (env kVal args[0])0
  ip: compNode[args[1]; env; `f32]; si:newId[]; emitBuf opF2s[Ti32; si; ip[0]]
  vp: compNode[args[2]; env; `f32]
  p:  newId[]; emitBuf opAccChain[CPf32; p; bid; CKz; si]
  emitBuf opStore[p; vp[0]]
  vp
}
/ iget[acc; idx] — load i32 acc[idx] and convert to f32 (read a fixed-point accumulator).
compIget: {[i; env]
  args: kF[i;`arg]
  aid: (env kVal args[0])0
  ip: compNode[args[1]; env; `f32]; si:newId[]; emitBuf opF2s[Ti32; si; ip[0]]
  p:  newId[]; emitBuf opAccChain[CPi32; p; aid; CKz; si]
  iv: newId[]; emitBuf opLoad[Ti32; iv; p]
  fv: newId[]; emitBuf opI2f[Tf32; fv; iv]      / SToF
  (fv; `f32)
}
/ iset[acc; idx; val] — store val (truncated to i32) into an i32 accumulator. Used to
/ clear the fixed-point accumulator (iset[acc;i;0.]) between constraint passes.
compIset: {[i; env]
  args: kF[i;`arg]
  aid: (env kVal args[0])0
  ip: compNode[args[1]; env; `f32]; si:newId[]; emitBuf opF2s[Ti32; si; ip[0]]
  vp: compNode[args[2]; env; `f32]; vi:newId[]; emitBuf opF2s[Ti32; vi; vp[0]]
  p:  newId[]; emitBuf opAccChain[CPi32; p; aid; CKz; si]
  emitBuf opStore[p; vi]
  (vi; `i32)
}

/ ── In-kernel bounded loops (control flow for the compute dialect) ───────────
/ The dialect grows ONE loop CFG idiom, shared by three surfaces:
/   rsum[K; {[k] e}]  — fused index map-reduce (Σ e over k=0..K-1). k has no single
/                       adverb for this (`"+/"e'!K` needs a materialised range, which
/                       a per-thread kernel can't build) so it stays a primitive.
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

/ rsum[K; {[k] expr}] — reduction. State = the f32 accumulator; counter = the index.
compRsum: {[i; env]
  args: kF[i;`arg]                             / (Kexpr ; lambdaNode)
  lamN: args 1
  pn:   *(Cst`value)@kF[lamN;`param]            / loop-index name
  bst:  kF[lamN;`stmt]                          / lambda body rows
  kp:   compNode[args 0; env; `f32]
  Kmax: newId[]; emitBuf opF2s[Ti32; Kmax; kp 0]
  h:    loopOpen[Kmax; RCf0; `f32]              / seed acc = 0.
  iPhi:h 0; accPhi:h 1; iNext:h 2; accNext:h 3; conL:h 4; hdrL:h 5; mrgL:h 6
  kf:   newId[]; emitBuf opI2f[Tf32; kf; iPhi]  / expose counter to the body as f32 k
  benv: ((!env),pn)!(env[!env],(,(kf;`f32)))
  bp:   compSeq[bst; benv; `f32]
  nv:   newId[]; emitBuf opFadd[Tf32; nv; accPhi; bp 0]   / acc' = acc + expr
  loopClose[nv; `f32; accNext; iNext; iPhi; conL; hdrL; mrgL]
  (accPhi; `f32)
}

/ rmax[K; {[k] expr}] — max reduction (stable-softmax numerator).  Same loop as rsum
/ but seeded at -1e30 and combined with FMax.
compRmax: {[i; env]
  args: kF[i;`arg]; lamN: args 1
  pn:   *(Cst`value)@kF[lamN;`param]; bst: kF[lamN;`stmt]
  kp:   compNode[args 0; env; `f32]
  Kmax: newId[]; emitBuf opF2s[Ti32; Kmax; kp 0]
  h:    loopOpen[Kmax; RCfNeg; `f32]
  iPhi:h 0; accPhi:h 1; iNext:h 2; accNext:h 3; conL:h 4; hdrL:h 5; mrgL:h 6
  kf:   newId[]; emitBuf opI2f[Tf32; kf; iPhi]
  benv: ((!env),pn)!(env[!env],(,(kf;`f32)))
  bp:   compSeq[bst; benv; `f32]
  nv:   newId[]; emitBuf opFmax[Tf32; nv; accPhi; bp 0]   / acc' = max(acc, expr)
  loopClose[nv; `f32; accNext; iNext; iPhi; conL; hdrL; mrgL]
  (accPhi; `f32)
}

/ N-do:  i f/ x  — verb `f` (=`vN`"," a 1-param lambda) applied to state x, i times.
/ The counter drives trip count only; the verb sees the state, not the counter
/ (pure k n-do). State type follows the seed (f32 / vec2 / …).
compNdo: {[aN; vN; bN; env; oty]
  cp:   compNode[aN; env; `f32]
  Kmax: newId[]; emitBuf opF2s[Ti32; Kmax; cp 0]
  sp:   compNode[bN; env; oty]; sty: sp 1
  h:    loopOpen[Kmax; sp 0; sty]
  sPhi:h 1; iNext:h 2; sNext:h 3; conL:h 4; hdrL:h 5; mrgL:h 6; iPhi:h 0
  vpn:  *(Cst`value)@kF[vN;`param]
  venv: ((!env),vpn)!(env[!env],(,(sPhi;sty)))
  bp:   compSeq[kF[vN;`stmt]; venv; sty]         / state' = f(state)
  loopClose[bp 0; sty; sNext; iNext; iPhi; conL; hdrL; mrgL]
  (sPhi; sty)
}

/ While:  f g/ x  — body `g` (=`vN`) applied to state x while cond `f` (=`cN`"," a
/ 1-param lambda returning bool) holds. No counter: cond is re-tested in the header.
compWhile: {[cN; vN; bN; env; oty]
  sp:   compNode[bN; env; oty]; sty: sp 1
  preL:newId[]; hdrL:newId[]; bodL:newId[]; conL:newId[]; mrgL:newId[]
  sPhi:newId[]; sNext:newId[]
  emitBuf opBranch[preL]; emitBuf opLabel[preL]; emitBuf opBranch[hdrL]; emitBuf opLabel[hdrL]
  emitBuf opPhi2[Tid[sty]; sPhi; sp 0; preL; sNext; conL]
  cpn:  *(Cst`value)@kF[cN;`param]               / cond in the header, after the phi
  cenv: ((!env),cpn)!(env[!env],(,(sPhi;sty)))
  cc:   compSeq[kF[cN;`stmt]; cenv; `bool]
  emitBuf opLoopMrg[mrgL; conL]; emitBuf opBrCond[cc 0; bodL; mrgL]; emitBuf opLabel[bodL]
  vpn:  *(Cst`value)@kF[vN;`param]
  venv: ((!env),vpn)!(env[!env],(,(sPhi;sty)))
  bp:   compSeq[kF[vN;`stmt]; venv; sty]          / state' = g(state)
  emitBuf opCopy[Tid[sty]; sNext; bp 0]
  emitBuf opBranch[conL]; emitBuf opLabel[conL]; emitBuf opBranch[hdrL]; emitBuf opLabel[mrgL]
  (sPhi; sty)
}

/ Adverbed-verb transit: `x adverb-verb y`. The operator node is a `term` whose
/ value is the adverb glyph and whose `f` child is the verb. `"/"` splits N-do vs
/ While by the left arg's kind (a lambda ⇒ While cond; else ⇒ N-do count).
compAdverb: {[i; vN; env; oty]
  glyph: kVal vN
  verb:  kF1[vN;`f]
  aN:    kF1[i;`a]; bN: kF1[i;`b]
  $[glyph~`"/"; $[(kKind aN)~`lambda; compWhile[aN; verb; bN; env; oty]
                compNdo[aN; verb; bN; env; oty]]
    (0; oty)]                                     / other adverbs: not in kernels yet
}

/ sample[uv] (texture 0) or sample[k; uv] (texture k, k a literal) → texture
/ lookup: OpSampledImage(image_k, shared sampler) then OpImageSampleImplicitLod at
/ the interpolated uv. Only valid inside a shader.fragmentTexN. Returns v4.
compSample: {[i; env]
  args: kF[i;`arg]
  two:  1<#args
  ti:   $[two; kVal args[0]; 0]                   / texture index (literal) or 0
  uv:   compNode[$[two; args[1]; args[0]]; env; `v2]
  li: newId[]; emitBuf opLoad[Timg2; li; TexVars[ti]]
  ls: newId[]; emitBuf opLoad[Tsamp2; ls; SampVar]
  ci: newId[]; emitBuf (0x00050056; TsImg; ci; li; ls)      / OpSampledImage 86
  r:  newId[]; emitBuf (0x00050057; Tv4; r; ci; uv[0])       / OpImageSampleImplicitLod 87
  (r; `v4)
}

/ Explicit apply: f[a;b;c]
/ Handles: texture sampling, math function calls AND composite indexing (v[0])
compApply: {[i; env; oty]
  fr:     kF1[i;`f]
  fnName: kVal fr
  $[fnName~`sample;      compSample[i; env]
    fnName~`scatterAdd;  compScatterAdd[i; env]
    fnName~`set;         compSet[i; env]
    fnName~`iget;        compIget[i; env]
    fnName~`iset;        compIset[i; env]
    fnName~`rsum;        compRsum[i; env]
    fnName~`rmax;        compRmax[i; env]
    fnName in mathFns;   compFnCall[fnName; i; env; oty]
    isBuf[fnName; env];  compBufIdx[(env fnName)0; i; env]
    compApplyIdx[fr; i; env; oty]]
}

/ Tuple → vec2/vec3/vec4 via OpCompositeConstruct
/ gpu.dispatch on element count.
compList: {[i; env; oty]
  elems: kF[i;`elem]
  n:  #elems
  p0: compNode[elems[0];env;`f32]
  p1: compNode[elems[1];env;`f32]
  p2: $[n>2; compNode[elems[2];env;`f32]; (0;`f32)]
  p3: $[n>3; compNode[elems[3];env;`f32]; (0;`f32)]
  r:   newId[]
  rty: $[n=2; `v2; n=3; `v3; `v4]
  rt:  $[n=2; Tv2; n=3; Tv3;  Tv4]
  $[n=2; emitBuf opCons2[rt;r;p0[0];p1[0]]
    n=3; emitBuf opCons3[rt;r;p0[0];p1[0];p2[0]]
    emitBuf opCons4[rt;r;p0[0];p1[0];p2[0];p3[0]]]
  (r; rty)
}

/ $[c; then; else] and chained $[c1;t1;c2;t2;...;default] → OpSelect (eager both branches)
/ Handles scalar bool condition selecting scalar or vector values. The cond's
/ operands are its `stmt child rows, in source order.
compCond: {[i; env; oty] compCondS[kF[i;`stmt]; env; oty]}
compCondS: {[ss; env; oty]
  n:   #ss
  cp:  compNode[ss 0; env; `bool]
  tp:  compNode[ss 1; env; oty]
  ep:  $[n=3; compNode[ss 2; env; oty]; compCondS[2_ss; env; oty]]
  r:   newId[]
  rty: tp[1]
  emitBuf opSel[Tid[rty]; r; cp[0]; tp[0]; ep[0]]
  (r; rty)
}

/ CST node dispatcher — dispatch on the row's kind, recurse into child rows.
compNode: {[i; env; oty]
  tag: kKind i
  $[tag~`var;     compVar[i;env]
    tag in `int`float`ints`floats`bool`string`symbol; compLit[i;oty]
    tag~`transit;  compTrans[i;env;oty]
    tag~`apposit;  compAppos[i;env;oty]
    tag~`apply;    compApply[i;env;oty]
    tag~`list;     compList[i;env;oty]
    tag~`cond;     compCond[i;env;oty]
    tag~`right;    compNode[kF1[i;`clause];env;oty]   / parenthesised expression
    tag~`group;    compNode[kF1[i;`stmt];env;oty]
    (0; oty)]
}

/ ── Layer 3: sequential body with local bindings ──────────────────────────
/ stmts: list of statement nodes (seq/div markers already stripped)
/ For bind nodes (y: expr), compile rhs and extend env with name→result. A bare
/ (non-bind) non-final statement is compiled for its SIDE EFFECTS (set/scatterAdd/
/ iset stores) — `sfx` forces that; without it such statements were silently dropped.
/ Returns (id; ty_sym) of the last expression.
compSeqTail: {[stmts; env; oty]
  s:   stmts 0
  isb: ((kKind s)~`bind) & (0<#kF[s;`a])
  sfx: $[isb; 0; compNode[s;env;oty]]
  e2:  $[isb; ((!env),kVal kF1[s;`v])!(env[!env],(,compNode[kF1[s;`a];env;oty])); env]
  compSeq[1_stmts;e2;oty]}

compSeq: {[stmts; env; oty]
  n: #stmts
  $[n=0; (0;oty)
    n=1; compNode[stmts[0];env;oty]
    compSeqTail[stmts;env;oty]]}

/ ── Layer III helper ──────────────────────────────────────────────────────────
loadOnePair: {[vid; tsym]
  r: newId[]
  emitBuf opLoad[Tid[tsym]; r; vid]
  (r; tsym)}

/ ── Layer IV: SPIR-V module assembly ─────────────────────────────────────────
decInOne: {[vid;loc] (0x00040047; vid; 30; loc)}
varInOne: {[ptr;vid] (0x0004003B; ptr; vid; 1)}

buildMod: {[outId; inVarIds; inTys; inPtrs; outPtr; locs]
  bnd:   Nid+1
  iface: inVarIds, ,outId

  hdr:  (0x07230203; 0x00010300; 0; bnd; 0)
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


/ ── compCompute: compile element-wise compute shader ─────────────────────────
compCompute: {[fn]
  Nid::Nfixed; Buf::(); Con::(); ConKeyT::(); ConKeyV::(); ConVal::()

  Tu32:    newId[]
  Tv3u32:  newId[]
  Trta:    newId[]
  Tbuf:    newId[]
  Pbufs:   newId[]
  Pf32s:   newId[]
  Pv3u32i: newId[]

  gidVar: newId[]
  inBuf:  newId[]
  outBuf: newId[]

  Ku32z: newId[]
  emitCon (0x0004002B; Tu32; Ku32z; 0)

  lam: lamOf fn
  argName: (lamArgs lam)0

  gidId:    newId[]; emitBuf opLoad[Tv3u32; gidId; gidVar]
  gidXId:   newId[]; emitBuf opXtract[Tu32; gidXId; gidId; 0]
  inPtrId:  newId[]; emitBuf opAccChain[Pf32s; inPtrId; inBuf; Ku32z; gidXId]
  xId:      newId[]; emitBuf opLoad[Tf32; xId; inPtrId]
  env:      (,argName)!(,(xId; `f32))
  stmts:   lamBody lam
  rp:      compSeq[stmts; env; `f32]
  outPtrId: newId[]; emitBuf opAccChain[Pf32s; outPtrId; outBuf; Ku32z; gidXId]
  emitBuf opStore[outPtrId; rp[0]]

  bnd: Nid+1
  iface: (,gidVar)

  hdr: (0x07230203; 0x00010300; 0; bnd; 0)
  cap: (0x00020011; 1)
  ext: (0x0006000B; Glsl; 0x4C534C47; 0x6474732E; 0x3035342E; 0)
  mem: (0x0003000E; 0; 1)
  ep:  (0x000F+(0x10000*(5+#iface)); 5; Fmain; 0x6E69616D; 0), iface
  exm: (0x00060010; Fmain; 17; wg; 1; 1)

  decGid:    (0x00040047; gidVar; 11; 28)
  decStride: (0x00040047; Trta; 6; 4)
  decMem:    (0x00050048; Tbuf; 0; 35; 0)
  decBlk:    (0x00030047; Tbuf; 2)
  decInDs:   (0x00040047; inBuf; 34; 0)
  decInBnd:  (0x00040047; inBuf; 33; 0)
  decOutDs:  (0x00040047; outBuf; 34; 0)
  decOutBnd: (0x00040047; outBuf; 33; 1)

  / shared base types + Tv3 (one line — ink newline bug)
  sTypes: (0x00020013;Tvoid;0x00020014;Tbool;0x00030016;Tf32;32;0x00040017;Tv4;Tf32;4;0x00040017;Tv2;Tf32;2;0x00040017;Tv3;Tf32;3;0x00040015;Ti32;32;1;0x00030021;Tfunc;Tvoid)
  cTypes: (0x00040015;Tu32;32;0;0x00040017;Tv3u32;Tu32;3;0x0003001D;Trta;Tf32;0x0003001E;Tbuf;Trta;0x00040020;Pbufs;12;Tbuf;0x00040020;Pf32s;12;Tf32;0x00040020;Pv3u32i;1;Tv3u32)

  varGid: (0x0004003B; Pv3u32i; gidVar; 1)
  varIn:  (0x0004003B; Pbufs;   inBuf;  12)
  varOut: (0x0004003B; Pbufs;   outBuf; 12)

  label: newId[]
  fnh: (0x00050036; Tvoid; Fmain; 0; Tfunc; 0x000200F8; label)
  ret: (0x000100FD; 0x00010038)

  conWds: $[#Con; ,/Con; !0]
  bodWds: $[#Buf; ,/Buf; !0]

  decs: decGid,decStride,decMem,decBlk,decInDs,decInBnd,decOutDs,decOutBnd
  vars: varGid,varIn,varOut

  ,/(hdr;cap;ext;mem;ep;exm;decs;sTypes;cTypes;vars;conWds;fnh;bodWds;ret)}

/ Public name, consistent with shader.fragment / shader.vertex. Compiles an
/ element-wise f32 kernel {[x] ...} to a SPIR-V compute shader (workgroup 64,
/ reads binding 0, writes binding 1). Run it with gpu.runShader[shader.compute[fn]; inF].
/ This is the lowering target for data-parallel ECS systems (a per-entity column
/ map): compile once, then gpu.runShader the column each frame inside a gpuRun frame.
shader.compute: compCompute

/ ── compComputeU: element-wise compute + a uniform vec4 ──────────────────────────
/ Kernel {[x;u] ...}: x = element from the input buffer (binding 0), u = a uniform
/ vec4 (a true UBO at binding 2 — pass constants like scale/bias/length without a
/ storage buffer). Writes binding 1. Mirrors compCompute, adding the render path's
/ uniform block (struct{vec4}, Uniform storage class, Block/Offset/DescriptorSet/
/ Binding decorations) and loading the member via loadUniMember. Run on the resident
/ path: p:gpu.compileComputeU[shader.computeU[fn]; 2]; u:gpu.uniform[…];
/ gpu.dispatch[p; (in;out;u); n].
compComputeU: {[fn]
  Nid::Nfixed; Buf::(); Con::(); ConKeyT::(); ConKeyV::(); ConVal::()

  Tu32:    newId[]
  Tv3u32:  newId[]
  Trta:    newId[]
  Tbuf:    newId[]
  Pbufs:   newId[]
  Pf32s:   newId[]
  Pv3u32i: newId[]

  gidVar: newId[]
  inBuf:  newId[]
  outBuf: newId[]

  Ku32z: newId[]
  emitCon (0x0004002B; Tu32; Ku32z; 0)

  / uniform block scratch: struct{vec4} at set 0 binding 2
  Tuni:   newId[]
  Puni:   newId[]
  PuniV4: newId[]
  uniVar: newId[]
  Ki0:    newId[]
  emitCon opConst[Ti32; Ki0; 0]
  UTuni::Tuni; UPv4::PuniV4; UVar::uniVar   / publish for loadUniMember (lambdas can't close)

  lam: lamOf fn
  argNames: lamArgs lam

  gidId:    newId[]; emitBuf opLoad[Tv3u32; gidId; gidVar]
  gidXId:   newId[]; emitBuf opXtract[Tu32; gidXId; gidId; 0]
  inPtrId:  newId[]; emitBuf opAccChain[Pf32s; inPtrId; inBuf; Ku32z; gidXId]
  xId:      newId[]; emitBuf opLoad[Tf32; xId; inPtrId]
  uPair:    loadUniMember[Ki0]
  env:      argNames!((xId; `f32); uPair)
  stmts:   lamBody lam
  rp:      compSeq[stmts; env; `f32]
  outPtrId: newId[]; emitBuf opAccChain[Pf32s; outPtrId; outBuf; Ku32z; gidXId]
  emitBuf opStore[outPtrId; rp[0]]

  bnd: Nid+1
  iface: (,gidVar)

  hdr: (0x07230203; 0x00010300; 0; bnd; 0)
  cap: (0x00020011; 1)
  ext: (0x0006000B; Glsl; 0x4C534C47; 0x6474732E; 0x3035342E; 0)
  mem: (0x0003000E; 0; 1)
  ep:  (0x000F+(0x10000*(5+#iface)); 5; Fmain; 0x6E69616D; 0), iface
  exm: (0x00060010; Fmain; 17; wg; 1; 1)

  decGid:    (0x00040047; gidVar; 11; 28)
  decStride: (0x00040047; Trta; 6; 4)
  decMem:    (0x00050048; Tbuf; 0; 35; 0)
  decBlk:    (0x00030047; Tbuf; 2)
  decInDs:   (0x00040047; inBuf; 34; 0)
  decInBnd:  (0x00040047; inBuf; 33; 0)
  decOutDs:  (0x00040047; outBuf; 34; 0)
  decOutBnd: (0x00040047; outBuf; 33; 1)
  decUBlk:   (0x00030047; Tuni; 2)              / OpDecorate Tuni Block
  decUMem:   (0x00050048; Tuni; 0; 35; 0)       / OpMemberDecorate Offset 0
  decUDs:    (0x00040047; uniVar; 34; 0)        / DescriptorSet 0
  decUBnd:   (0x00040047; uniVar; 33; 2)        / Binding 2

  sTypes: (0x00020013;Tvoid;0x00020014;Tbool;0x00030016;Tf32;32;0x00040017;Tv4;Tf32;4;0x00040017;Tv2;Tf32;2;0x00040017;Tv3;Tf32;3;0x00040015;Ti32;32;1;0x00030021;Tfunc;Tvoid)
  cTypes: (0x00040015;Tu32;32;0;0x00040017;Tv3u32;Tu32;3;0x0003001D;Trta;Tf32;0x0003001E;Tbuf;Trta;0x00040020;Pbufs;12;Tbuf;0x00040020;Pf32s;12;Tf32;0x00040020;Pv3u32i;1;Tv3u32)
  uTypes: (0x0003001E;Tuni;Tv4;0x00040020;Puni;2;Tuni;0x00040020;PuniV4;2;Tv4)

  varGid: (0x0004003B; Pv3u32i; gidVar; 1)
  varIn:  (0x0004003B; Pbufs;   inBuf;  12)
  varOut: (0x0004003B; Pbufs;   outBuf; 12)
  varUni: (0x0004003B; Puni;    uniVar; 2)

  label: newId[]
  fnh: (0x00050036; Tvoid; Fmain; 0; Tfunc; 0x000200F8; label)
  ret: (0x000100FD; 0x00010038)

  conWds: $[#Con; ,/Con; !0]
  bodWds: $[#Buf; ,/Buf; !0]

  decs: decGid,decStride,decMem,decBlk,decInDs,decInBnd,decOutDs,decOutBnd,decUBlk,decUMem,decUDs,decUBnd
  vars: varGid,varIn,varOut,varUni

  ,/(hdr;cap;ext;mem;ep;exm;decs;sTypes;cTypes;uTypes;vars;conWds;fnh;bodWds;ret)}

shader.computeU: compComputeU

/ ── compCompute2: two-input element-wise compute shader ──────────────────────────
/ Kernel {[x;y] ...} reads input1 at binding 0 and input2 at binding 2, writes the
/ result to output at binding 1. Run with gpu.runShader2[shader.compute2[fn]; in1; in2].
/ Enables real systems that combine two columns, e.g. {[px;vx] px+vx*dt}.
compCompute2: {[fn]
  Nid::Nfixed; Buf::(); Con::(); ConKeyT::(); ConKeyV::(); ConVal::()

  Tu32:    newId[]
  Tv3u32:  newId[]
  Trta:    newId[]
  Tbuf:    newId[]
  Pbufs:   newId[]
  Pf32s:   newId[]
  Pv3u32i: newId[]

  gidVar: newId[]
  inBuf:  newId[]
  outBuf: newId[]
  in2Buf: newId[]

  Ku32z: newId[]
  emitCon (0x0004002B; Tu32; Ku32z; 0)

  lam: lamOf fn
  argNames: lamArgs lam

  gidId:    newId[]; emitBuf opLoad[Tv3u32; gidId; gidVar]
  gidXId:   newId[]; emitBuf opXtract[Tu32; gidXId; gidId; 0]
  inPtrId:  newId[]; emitBuf opAccChain[Pf32s; inPtrId; inBuf; Ku32z; gidXId]
  xId:      newId[]; emitBuf opLoad[Tf32; xId; inPtrId]
  in2PtrId: newId[]; emitBuf opAccChain[Pf32s; in2PtrId; in2Buf; Ku32z; gidXId]
  yId:      newId[]; emitBuf opLoad[Tf32; yId; in2PtrId]
  env:      argNames!((xId; `f32); (yId; `f32))
  stmts:    lamBody lam
  rp:       compSeq[stmts; env; `f32]
  outPtrId: newId[]; emitBuf opAccChain[Pf32s; outPtrId; outBuf; Ku32z; gidXId]
  emitBuf opStore[outPtrId; rp[0]]

  bnd: Nid+1
  iface: (,gidVar)

  hdr: (0x07230203; 0x00010300; 0; bnd; 0)
  cap: (0x00020011; 1)
  ext: (0x0006000B; Glsl; 0x4C534C47; 0x6474732E; 0x3035342E; 0)
  mem: (0x0003000E; 0; 1)
  ep:  (0x000F+(0x10000*(5+#iface)); 5; Fmain; 0x6E69616D; 0), iface
  exm: (0x00060010; Fmain; 17; wg; 1; 1)

  decGid:    (0x00040047; gidVar; 11; 28)
  decStride: (0x00040047; Trta; 6; 4)
  decMem:    (0x00050048; Tbuf; 0; 35; 0)
  decBlk:    (0x00030047; Tbuf; 2)
  decInDs:   (0x00040047; inBuf; 34; 0)
  decInBnd:  (0x00040047; inBuf; 33; 0)
  decOutDs:  (0x00040047; outBuf; 34; 0)
  decOutBnd: (0x00040047; outBuf; 33; 1)
  decIn2Ds:  (0x00040047; in2Buf; 34; 0)
  decIn2Bnd: (0x00040047; in2Buf; 33; 2)

  / shared base types + Tv3 (one line — ink newline bug)
  sTypes: (0x00020013;Tvoid;0x00020014;Tbool;0x00030016;Tf32;32;0x00040017;Tv4;Tf32;4;0x00040017;Tv2;Tf32;2;0x00040017;Tv3;Tf32;3;0x00040015;Ti32;32;1;0x00030021;Tfunc;Tvoid)
  cTypes: (0x00040015;Tu32;32;0;0x00040017;Tv3u32;Tu32;3;0x0003001D;Trta;Tf32;0x0003001E;Tbuf;Trta;0x00040020;Pbufs;12;Tbuf;0x00040020;Pf32s;12;Tf32;0x00040020;Pv3u32i;1;Tv3u32)

  varGid: (0x0004003B; Pv3u32i; gidVar; 1)
  varIn:  (0x0004003B; Pbufs;   inBuf;  12)
  varOut: (0x0004003B; Pbufs;   outBuf; 12)
  varIn2: (0x0004003B; Pbufs;   in2Buf; 12)

  label: newId[]
  fnh: (0x00050036; Tvoid; Fmain; 0; Tfunc; 0x000200F8; label)
  ret: (0x000100FD; 0x00010038)

  conWds: $[#Con; ,/Con; !0]
  bodWds: $[#Buf; ,/Buf; !0]

  decs: decGid,decStride,decMem,decBlk,decInDs,decInBnd,decOutDs,decOutBnd,decIn2Ds,decIn2Bnd
  vars: varGid,varIn,varOut,varIn2

  ,/(hdr;cap;ext;mem;ep;exm;decs;sTypes;cTypes;vars;conWds;fnh;bodWds;ret)}

shader.compute2: compCompute2

/ ── compStencil: gather-capable compute shader (the buffer-index intrinsic) ──────
/ Kernel {[u; i] expr}: `u` is the input storage buffer (binding 0), indexable at
/ ANY computed offset — u[i], u[i-1], u[i+W] — and `i` is this thread's flat index
/ (gl_GlobalInvocationID.x) as an f32. The result is stored to output[i] (binding 1).
/ This is the element-wise shader.compute generalised from a map to a gather: the
/ single hard-wired input[gid] load becomes u[<expr>], so stencils (Jacobi/SOR/
/ image filters) compile. Grid dims / boundaries are baked as literals in the kernel
/ (it's compiled per problem); conditionals ($[…]) and floor/mod handle edges.
/ Run on the resident path: p:gpu.compileCompute[shader.stencil[fn]; 2]; then gpu.dispatch.
compStencil: {[fn]
  Nid::Nfixed; Buf::(); Con::(); ConKeyT::(); ConKeyV::(); ConVal::()

  Tu32:    newId[]
  Tv3u32:  newId[]
  Trta:    newId[]
  Tbuf:    newId[]
  Pbufs:   newId[]
  Pf32s:   newId[]
  Pv3u32i: newId[]

  gidVar: newId[]
  inBuf:  newId[]
  outBuf: newId[]

  Ku32z: newId[]
  emitCon (0x0004002B; Tu32; Ku32z; 0)
  CKz:: Ku32z; CPf32:: Pf32s            / hand the buffer-load scratch to compBufIdx

  lam:      lamOf fn
  argNames: lamArgs lam                  / (bufName; indexName)

  gidId:  newId[]; emitBuf opLoad[Tv3u32; gidId; gidVar]
  gidXId: newId[]; emitBuf opXtract[Tu32; gidXId; gidId; 0]
  gidF:   newId[]; emitBuf opU2f[Tf32; gidF; gidXId]         / this thread's index as f32
  env:    argNames!((inBuf; `buf); (gidF; `f32))
  stmts:  lamBody lam
  rp:     compSeq[stmts; env; `f32]
  outPtrId: newId[]; emitBuf opAccChain[Pf32s; outPtrId; outBuf; Ku32z; gidXId]
  emitBuf opStore[outPtrId; rp[0]]

  bnd: Nid+1
  iface: (,gidVar)

  hdr: (0x07230203; 0x00010300; 0; bnd; 0)
  cap: (0x00020011; 1)
  ext: (0x0006000B; Glsl; 0x4C534C47; 0x6474732E; 0x3035342E; 0)
  mem: (0x0003000E; 0; 1)
  ep:  (0x000F+(0x10000*(5+#iface)); 5; Fmain; 0x6E69616D; 0), iface
  exm: (0x00060010; Fmain; 17; wg; 1; 1)

  decGid:    (0x00040047; gidVar; 11; 28)
  decStride: (0x00040047; Trta; 6; 4)
  decMem:    (0x00050048; Tbuf; 0; 35; 0)
  decBlk:    (0x00030047; Tbuf; 2)
  decInDs:   (0x00040047; inBuf; 34; 0)
  decInBnd:  (0x00040047; inBuf; 33; 0)
  decOutDs:  (0x00040047; outBuf; 34; 0)
  decOutBnd: (0x00040047; outBuf; 33; 1)

  sTypes: (0x00020013;Tvoid;0x00020014;Tbool;0x00030016;Tf32;32;0x00040017;Tv4;Tf32;4;0x00040017;Tv2;Tf32;2;0x00040017;Tv3;Tf32;3;0x00040015;Ti32;32;1;0x00030021;Tfunc;Tvoid)
  cTypes: (0x00040015;Tu32;32;0;0x00040017;Tv3u32;Tu32;3;0x0003001D;Trta;Tf32;0x0003001E;Tbuf;Trta;0x00040020;Pbufs;12;Tbuf;0x00040020;Pf32s;12;Tf32;0x00040020;Pv3u32i;1;Tv3u32)

  varGid: (0x0004003B; Pv3u32i; gidVar; 1)
  varIn:  (0x0004003B; Pbufs;   inBuf;  12)
  varOut: (0x0004003B; Pbufs;   outBuf; 12)

  label: newId[]
  fnh: (0x00050036; Tvoid; Fmain; 0; Tfunc; 0x000200F8; label)
  ret: (0x000100FD; 0x00010038)

  conWds: $[#Con; ,/Con; !0]
  bodWds: $[#Buf; ,/Buf; !0]

  decs: decGid,decStride,decMem,decBlk,decInDs,decInBnd,decOutDs,decOutBnd
  vars: varGid,varIn,varOut

  ,/(hdr;cap;ext;mem;ep;exm;decs;sTypes;cTypes;vars;conWds;fnh;bodWds;ret)}

shader.stencil: compStencil

/ ── compStencilU: stencil + a params buffer (uniforms as an indexable buffer) ────
/ Kernel {[u; g; i]}: `u`"="input (binding 0), `g`"="params (binding 2, indexable
/ g[0],g[1],…), `i`"="thread index; result → output (binding 1). Lets ONE compiled
/ pipeline serve any grid: pass N/ω/… in the params buffer instead of baking them.
/ nbind=3; gpu.dispatch order is (in; out; params). g is just another storage buffer,
/ so the buffer-index intrinsic reads it for free.
compStencilU: {[fn]
  Nid::Nfixed; Buf::(); Con::(); ConKeyT::(); ConKeyV::(); ConVal::()
  Tu32:newId[]; Tv3u32:newId[]; Trta:newId[]; Tbuf:newId[]
  Pbufs:newId[]; Pf32s:newId[]; Pv3u32i:newId[]
  gidVar:newId[]; inBuf:newId[]; outBuf:newId[]; in2Buf:newId[]
  Ku32z:newId[]; emitCon (0x0004002B; Tu32; Ku32z; 0)
  CKz::Ku32z; CPf32::Pf32s
  lam:lamOf fn; argNames:lamArgs lam
  gidId:newId[]; emitBuf opLoad[Tv3u32; gidId; gidVar]
  gidXId:newId[]; emitBuf opXtract[Tu32; gidXId; gidId; 0]
  gidF:newId[]; emitBuf opU2f[Tf32; gidF; gidXId]
  env: argNames!((inBuf;`buf);(in2Buf;`buf);(gidF;`f32))
  stmts:lamBody lam
  rp:compSeq[stmts; env; `f32]
  outPtrId:newId[]; emitBuf opAccChain[Pf32s; outPtrId; outBuf; Ku32z; gidXId]
  emitBuf opStore[outPtrId; rp[0]]
  bnd:Nid+1; iface:(,gidVar)
  hdr:(0x07230203;0x00010300;0;bnd;0)
  cap:(0x00020011;1)
  ext:(0x0006000B;Glsl;0x4C534C47;0x6474732E;0x3035342E;0)
  mem:(0x0003000E;0;1)
  ep:(0x000F+(0x10000*(5+#iface));5;Fmain;0x6E69616D;0),iface
  exm:(0x00060010;Fmain;17;wg;1;1)
  decGid:(0x00040047;gidVar;11;28)
  decStride:(0x00040047;Trta;6;4)
  decMem:(0x00050048;Tbuf;0;35;0)
  decBlk:(0x00030047;Tbuf;2)
  decInDs:(0x00040047;inBuf;34;0); decInBnd:(0x00040047;inBuf;33;0)
  decOutDs:(0x00040047;outBuf;34;0); decOutBnd:(0x00040047;outBuf;33;1)
  decIn2Ds:(0x00040047;in2Buf;34;0); decIn2Bnd:(0x00040047;in2Buf;33;2)
  sTypes:(0x00020013;Tvoid;0x00020014;Tbool;0x00030016;Tf32;32;0x00040017;Tv4;Tf32;4;0x00040017;Tv2;Tf32;2;0x00040017;Tv3;Tf32;3;0x00040015;Ti32;32;1;0x00030021;Tfunc;Tvoid)
  cTypes:(0x00040015;Tu32;32;0;0x00040017;Tv3u32;Tu32;3;0x0003001D;Trta;Tf32;0x0003001E;Tbuf;Trta;0x00040020;Pbufs;12;Tbuf;0x00040020;Pf32s;12;Tf32;0x00040020;Pv3u32i;1;Tv3u32)
  varGid:(0x0004003B;Pv3u32i;gidVar;1)
  varIn:(0x0004003B;Pbufs;inBuf;12)
  varOut:(0x0004003B;Pbufs;outBuf;12)
  varIn2:(0x0004003B;Pbufs;in2Buf;12)
  label:newId[]
  fnh:(0x00050036;Tvoid;Fmain;0;Tfunc;0x000200F8;label)
  ret:(0x000100FD;0x00010038)
  conWds:$[#Con;,/Con;!0]; bodWds:$[#Buf;,/Buf;!0]
  decs:decGid,decStride,decMem,decBlk,decInDs,decInBnd,decOutDs,decOutBnd,decIn2Ds,decIn2Bnd
  vars:varGid,varIn,varOut,varIn2
  ,/(hdr;cap;ext;mem;ep;exm;decs;sTypes;cTypes;vars;conWds;fnh;bodWds;ret)}
shader.stencilU: compStencilU

/ ── compStencilIP: in-place stencil (single state buffer) + params ──────────────
/ Kernel {[u; g; i]}: `u`"="state (binding 0, read AND written in place), `g`"="params
/ (binding 1), `i`"="thread index; result → u[i] (binding 0, same buffer). This is
/ what red-black Gauss-Seidel/SOR needs: reds read blacks and write reds in place,
/ so the just-updated reds are visible to the black pass. Non-updated cells must
/ store their own value (u[i]); the resulting same-value read/write "race" is
/ benign on real hardware (and Dawn doesn't flag it). nbind=2; gpu.dispatch (state;params).
compStencilIP: {[fn]
  Nid::Nfixed; Buf::(); Con::(); ConKeyT::(); ConKeyV::(); ConVal::()
  Tu32:newId[]; Tv3u32:newId[]; Trta:newId[]; Tbuf:newId[]
  Pbufs:newId[]; Pf32s:newId[]; Pv3u32i:newId[]
  gidVar:newId[]; inBuf:newId[]; parBuf:newId[]
  Ku32z:newId[]; emitCon (0x0004002B; Tu32; Ku32z; 0)
  CKz::Ku32z; CPf32::Pf32s
  lam:lamOf fn; argNames:lamArgs lam
  gidId:newId[]; emitBuf opLoad[Tv3u32; gidId; gidVar]
  gidXId:newId[]; emitBuf opXtract[Tu32; gidXId; gidId; 0]
  gidF:newId[]; emitBuf opU2f[Tf32; gidF; gidXId]
  env: argNames!((inBuf;`buf);(parBuf;`buf);(gidF;`f32))
  stmts:lamBody lam
  rp:compSeq[stmts; env; `f32]
  outPtrId:newId[]; emitBuf opAccChain[Pf32s; outPtrId; inBuf; Ku32z; gidXId]  / write in place
  emitBuf opStore[outPtrId; rp[0]]
  bnd:Nid+1; iface:(,gidVar)
  hdr:(0x07230203;0x00010300;0;bnd;0)
  cap:(0x00020011;1)
  ext:(0x0006000B;Glsl;0x4C534C47;0x6474732E;0x3035342E;0)
  mem:(0x0003000E;0;1)
  ep:(0x000F+(0x10000*(5+#iface));5;Fmain;0x6E69616D;0),iface
  exm:(0x00060010;Fmain;17;wg;1;1)
  decGid:(0x00040047;gidVar;11;28)
  decStride:(0x00040047;Trta;6;4)
  decMem:(0x00050048;Tbuf;0;35;0)
  decBlk:(0x00030047;Tbuf;2)
  decInDs:(0x00040047;inBuf;34;0); decInBnd:(0x00040047;inBuf;33;0)
  decParDs:(0x00040047;parBuf;34;0); decParBnd:(0x00040047;parBuf;33;1)
  sTypes:(0x00020013;Tvoid;0x00020014;Tbool;0x00030016;Tf32;32;0x00040017;Tv4;Tf32;4;0x00040017;Tv2;Tf32;2;0x00040017;Tv3;Tf32;3;0x00040015;Ti32;32;1;0x00030021;Tfunc;Tvoid)
  cTypes:(0x00040015;Tu32;32;0;0x00040017;Tv3u32;Tu32;3;0x0003001D;Trta;Tf32;0x0003001E;Tbuf;Trta;0x00040020;Pbufs;12;Tbuf;0x00040020;Pf32s;12;Tf32;0x00040020;Pv3u32i;1;Tv3u32)
  varGid:(0x0004003B;Pv3u32i;gidVar;1)
  varIn:(0x0004003B;Pbufs;inBuf;12)
  varPar:(0x0004003B;Pbufs;parBuf;12)
  label:newId[]
  fnh:(0x00050036;Tvoid;Fmain;0;Tfunc;0x000200F8;label)
  ret:(0x000100FD;0x00010038)
  conWds:$[#Con;,/Con;!0]; bodWds:$[#Buf;,/Buf;!0]
  decs:decGid,decStride,decMem,decBlk,decInDs,decInBnd,decParDs,decParBnd
  vars:varGid,varIn,varPar
  ,/(hdr;cap;ext;mem;ep;exm;decs;sTypes;cTypes;vars;conWds;fnh;bodWds;ret)}
shader.stencilIP: compStencilIP

/ ── compScatter: edge-parallel atomic scatter (the cloth/graph intrinsic) ────────
/ Kernel {[acc; a; b; g; i]}: one thread per EDGE (i = edge index). `a`","`b` are f32
/ input buffers (endpoint indices / per-edge attributes), read with a[i]; `g` is a
/ params buffer (e.g. g[0]=edge count). `acc` is an i32 accumulator scattered into
/ with scatterAdd[acc; node; val] — OpAtomicIAdd, so many edges hitting the same
/ node accumulate without a race. No per-thread output; the body is scatterAdd side
/ effects. This is XPBD's scatter-add of constraint corrections onto shared
/ particles (cloth.k's amend-with-+), on the GPU. IMPORTANT: dispatch rounds up to
/ a multiple of 64, so guard the scatter VALUE to 0 for out-of-range threads
/ ($[i<g[0];val;0.]) — atomic-add of 0 is a harmless no-op (OpSelect can't guard
/ the side effect itself). Read back with gpu.readI. nbind=4; gpu.dispatch (acc;a;b;g).
compScatter: {[fn]
  Nid::Nfixed; Buf::(); Con::(); ConKeyT::(); ConKeyV::(); ConVal::()
  Tu32:newId[]; Tv3u32:newId[]
  Trta:newId[]; Tbuf:newId[]; Pbufs:newId[]; Pf32s:newId[]
  TrtaI:newId[]; TbufI:newId[]; PbufsI:newId[]; Pi32s:newId[]
  Pv3u32i:newId[]
  gidVar:newId[]; accBuf:newId[]; aBuf:newId[]; bBuf:newId[]; gBuf:newId[]
  Ku32z:newId[]; emitCon (0x0004002B; Tu32; Ku32z; 0)
  KDev:newId[];  emitCon (0x0004002B; Tu32; KDev; 1)         / Device memory scope
  CKz::Ku32z; CPf32::Pf32s; CPi32::Pi32s; CScope::KDev
  lam:lamOf fn; argNames:lamArgs lam                          / (acc; a; b; g; i)
  gidId:newId[]; emitBuf opLoad[Tv3u32; gidId; gidVar]
  gidXId:newId[]; emitBuf opXtract[Tu32; gidXId; gidId; 0]
  gidF:newId[]; emitBuf opU2f[Tf32; gidF; gidXId]
  env: argNames!((accBuf;`scat);(aBuf;`buf);(bBuf;`buf);(gBuf;`buf);(gidF;`f32))
  stmts:lamBody lam
  rp:compSeq[stmts; env; `f32]                                / side effects only; result discarded
  bnd:Nid+1; iface:(,gidVar)
  hdr:(0x07230203;0x00010300;0;bnd;0)
  cap:(0x00020011;1)
  ext:(0x0006000B;Glsl;0x4C534C47;0x6474732E;0x3035342E;0)
  mem:(0x0003000E;0;1)
  ep:(0x000F+(0x10000*(5+#iface));5;Fmain;0x6E69616D;0),iface
  exm:(0x00060010;Fmain;17;wg;1;1)
  decGid:(0x00040047;gidVar;11;28)
  decStr:(0x00040047;Trta;6;4);   decMem:(0x00050048;Tbuf;0;35;0);  decBlk:(0x00030047;Tbuf;2)
  decStrI:(0x00040047;TrtaI;6;4); decMemI:(0x00050048;TbufI;0;35;0);decBlkI:(0x00030047;TbufI;2)
  decAccDs:(0x00040047;accBuf;34;0); decAccBnd:(0x00040047;accBuf;33;0)
  decADs:(0x00040047;aBuf;34;0);     decABnd:(0x00040047;aBuf;33;1)
  decBDs:(0x00040047;bBuf;34;0);     decBBnd:(0x00040047;bBuf;33;2)
  decGDs:(0x00040047;gBuf;34;0);     decGBnd:(0x00040047;gBuf;33;3)
  sTypes:(0x00020013;Tvoid;0x00020014;Tbool;0x00030016;Tf32;32;0x00040017;Tv4;Tf32;4;0x00040017;Tv2;Tf32;2;0x00040017;Tv3;Tf32;3;0x00040015;Ti32;32;1;0x00030021;Tfunc;Tvoid)
  cTypes:(0x00040015;Tu32;32;0;0x00040017;Tv3u32;Tu32;3;0x0003001D;Trta;Tf32;0x0003001E;Tbuf;Trta;0x00040020;Pbufs;12;Tbuf;0x00040020;Pf32s;12;Tf32;0x0003001D;TrtaI;Ti32;0x0003001E;TbufI;TrtaI;0x00040020;PbufsI;12;TbufI;0x00040020;Pi32s;12;Ti32;0x00040020;Pv3u32i;1;Tv3u32)
  varGid:(0x0004003B;Pv3u32i;gidVar;1)
  varAcc:(0x0004003B;PbufsI;accBuf;12)
  varA:(0x0004003B;Pbufs;aBuf;12)
  varB:(0x0004003B;Pbufs;bBuf;12)
  varG:(0x0004003B;Pbufs;gBuf;12)
  label:newId[]
  fnh:(0x00050036;Tvoid;Fmain;0;Tfunc;0x000200F8;label)
  ret:(0x000100FD;0x00010038)
  conWds:$[#Con;,/Con;!0]; bodWds:$[#Buf;,/Buf;!0]
  decs:decGid,decStr,decMem,decBlk,decStrI,decMemI,decBlkI,decAccDs,decAccBnd,decADs,decABnd,decBDs,decBBnd,decGDs,decGBnd
  vars:varGid,varAcc,varA,varB,varG
  ,/(hdr;cap;ext;mem;ep;exm;decs;sTypes;cTypes;vars;conWds;fnh;bodWds;ret)}
shader.scatter: compScatter

/ ── compGpN: general compute kernel — nAcc i32 accumulators + nBuf f32 buffers ────
/ Kernel {[acc0..accM; buf0..bufN; i]}: bindings 0..nAcc-1 are i32 atomic
/ accumulators (scatterAdd/iget/iset), nAcc..nAcc+nBuf-1 are f32 buffers (read with
/ b[j], written with set[b;j;v]); i is the thread index. There is NO automatic output
/ store — every write is an explicit set/scatterAdd/iset, so one kernel can update
/ several buffers (e.g. XPBD integrate writes p, v AND prev). This is the general
/ lowering the fixed shader.stencil* emitters specialise; it drives test/clothgpu.k.
/ nbind = nAcc+nBuf; gpu.dispatch order is (accumulators…; buffers…).
GAcc::   ()   / accumulator var ids (globals so the per-binding each-helpers see them)
GBuf::   ()   / f32 buffer var ids
GNAcc::  0    / accumulator count (f32 buffers start at binding GNAcc)
GPbufs:: 0    / StorageBuffer→f32-struct pointer type
GPbufsI::0    / StorageBuffer→i32-struct pointer type
gpAccDec: {[k] (0x00040047;GAcc[k];34;0),(0x00040047;GAcc[k];33;k)}
gpBufDec: {[k] (0x00040047;GBuf[k];34;0),(0x00040047;GBuf[k];33;GNAcc+k)}
gpAccVar: {[k] (0x0004003B;GPbufsI;GAcc[k];12)}
gpBufVar: {[k] (0x0004003B;GPbufs;GBuf[k];12)}
compGpN: {[fn; nAcc; nBuf]
  Nid::Nfixed; Buf::(); Con::(); ConKeyT::(); ConKeyV::(); ConVal::()
  Tu32:newId[]; Tv3u32:newId[]
  Trta:newId[]; Tbuf:newId[]; Pbufs:newId[]; Pf32s:newId[]
  TrtaI:newId[]; TbufI:newId[]; PbufsI:newId[]; Pi32s:newId[]
  Pv3u32i:newId[]
  gidVar:newId[]
  ka:!nAcc; kb:!nBuf
  accIds:{[k]newId[]}'ka
  bufIds:{[k]newId[]}'kb
  Ku32z:newId[]; emitCon (0x0004002B;Tu32;Ku32z;0)
  KDev:newId[];  emitCon (0x0004002B;Tu32;KDev;1)
  CKz::Ku32z; CPf32::Pf32s; CPi32::Pi32s; CScope::KDev
  / rsum loop constants (i32 0/1, f32 0.) — one set per compile, forward-refs by compRsum
  RCi0::newId[];   emitCon opConst[Ti32;RCi0;0]
  RCi1::newId[];   emitCon opConst[Ti32;RCi1;1]
  RCf0::newId[];   emitCon opConst[Tf32;RCf0;0.]
  RCfNeg::newId[]; emitCon opConst[Tf32;RCfNeg;-1e30]
  GAcc::accIds; GBuf::bufIds; GNAcc::nAcc; GPbufs::Pbufs; GPbufsI::PbufsI
  lam:lamOf fn; argNames:lamArgs lam
  gidId:newId[]; emitBuf opLoad[Tv3u32;gidId;gidVar]
  gidXId:newId[]; emitBuf opXtract[Tu32;gidXId;gidId;0]
  gidF:newId[]; emitBuf opU2f[Tf32;gidF;gidXId]
  accPairs:{[id](id;`scat)}'accIds
  bufPairs:{[id](id;`buf)}'bufIds
  env: argNames!(accPairs,bufPairs,(,(gidF;`f32)))
  stmts:lamBody lam
  rp:compSeq[stmts;env;`f32]
  bnd:Nid+1; iface:(,gidVar)
  hdr:(0x07230203;0x00010300;0;bnd;0)
  cap:(0x00020011;1)
  ext:(0x0006000B;Glsl;0x4C534C47;0x6474732E;0x3035342E;0)
  mem:(0x0003000E;0;1)
  ep:(0x000F+(0x10000*(5+#iface));5;Fmain;0x6E69616D;0),iface
  exm:(0x00060010;Fmain;17;wg;1;1)
  decGid:(0x00040047;gidVar;11;28)
  decStr:(0x00040047;Trta;6;4);   decMem:(0x00050048;Tbuf;0;35;0);  decBlk:(0x00030047;Tbuf;2)
  decStrI:(0x00040047;TrtaI;6;4); decMemI:(0x00050048;TbufI;0;35;0);decBlkI:(0x00030047;TbufI;2)
  accDecs:$[nAcc; ,/gpAccDec'ka; !0]
  bufDecs:$[nBuf; ,/gpBufDec'kb; !0]
  sTypes:(0x00020013;Tvoid;0x00020014;Tbool;0x00030016;Tf32;32;0x00040017;Tv4;Tf32;4;0x00040017;Tv2;Tf32;2;0x00040017;Tv3;Tf32;3;0x00040015;Ti32;32;1;0x00030021;Tfunc;Tvoid)
  cTypes:(0x00040015;Tu32;32;0;0x00040017;Tv3u32;Tu32;3;0x0003001D;Trta;Tf32;0x0003001E;Tbuf;Trta;0x00040020;Pbufs;12;Tbuf;0x00040020;Pf32s;12;Tf32;0x0003001D;TrtaI;Ti32;0x0003001E;TbufI;TrtaI;0x00040020;PbufsI;12;TbufI;0x00040020;Pi32s;12;Ti32;0x00040020;Pv3u32i;1;Tv3u32)
  accVars:$[nAcc; ,/gpAccVar'ka; !0]
  bufVars:$[nBuf; ,/gpBufVar'kb; !0]
  varGid:(0x0004003B;Pv3u32i;gidVar;1)
  label:newId[]
  fnh:(0x00050036;Tvoid;Fmain;0;Tfunc;0x000200F8;label)
  ret:(0x000100FD;0x00010038)
  conWds:$[#Con;,/Con;!0]; bodWds:$[#Buf;,/Buf;!0]
  decs:decGid,decStr,decMem,decBlk,decStrI,decMemI,decBlkI,accDecs,bufDecs
  vars:varGid,accVars,bufVars
  ,/(hdr;cap;ext;mem;ep;exm;decs;sTypes;cTypes;vars;conWds;fnh;bodWds;ret)}
gpu.kernel: compGpN

varOutOne:   {[ptr;vid]    (0x0004003B;ptr;vid;3)}    / OpVariable Output storage class

/ Helper: run stmts as binds building up env; return extended env (not last value).
/ Mirrors compSeqTail but returns env instead of the last compiled result.
compSeqEnvTail: {[stmts; env]
  s:   stmts 0
  isb: ((kKind s)~`bind) & (0<#kF[s;`a])
  e2:  $[isb; ((!env),kVal kF1[s;`v])!(env[!env],(,compNode[kF1[s;`a];env;`v4])); env]
  compSeqEnv[1_stmts; e2]}

compSeqEnv: {[stmts; env]
  $[0=#stmts; env; compSeqEnvTail[stmts; env]]}

/ ════════════════════════════════════════════════════════════════════════════
/ Neutral IR seam (the Tiramisu "Layer 1/2"). Instead of emitting SPIR-V inline,
/ the walker below builds a target-neutral, typed SSA op list; a lowering pass then
/ turns it into a target — SPIR-V words (xLowerSpirv, reusing the op* stencils) or a
/ textual dump (xDump). Optimizations (xFold, xReach/DCE) run once on the neutral IR
/ and help every target. shader.fragmentIr drives the fragment-expression subset
/ through it; the compute/loop machinery stays on the direct compNode path for now.
/ See doc/design/dye.md.  IR node = an index into these parallel lists:
xOp::  ()   / op sym:  param const cons extract select arith math neg lnot
xTy::  ()   / result type sym
xArg:: ()   / operand node indices (a list) per node
xVal:: ()   / const value / extract index / verb glyph / math name
xId::  ()   / SPIR-V id per node, filled by lowering
xRe::  ()   / reachability mask (DCE)
xReset: {[] xOp::(); xTy::(); xArg::(); xVal::(); xId::(); xRe::()}
xEmit: {[op;ty;args;val] xOp,:: ,op; xTy,:: ,ty; xArg,:: ,args; xVal,:: ,val; -1+#xOp}
xSplat: {[vty;snode] xEmit[`cons; vty; (ncVec[vty])#snode; 0n]}

/ ── IR builder: mirrors compNode, but returns (nodeIdx; ty) and records IR ──
xLit: {[i;oty] $[(kKind i) in `floats`ints; xVecLit[i]; xScalarLit[i;oty]]}
xVecLit: {[i] vals:0.+kVal i; n:#vals; cs:{[v] xEmit[`const;`f32;();v]}'vals; rty:$[n=2;`v2;n=3;`v3;`v4]; (xEmit[`cons;rty;cs;0n]; rty)}
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
  $[(op~`"<")&isEq; xLeGe[i;env;`">"]
    (op~`">")&isEq; xLeGe[i;env;`"<"]
    xTransNorm[i;env;oty]]}
xTrans: {[i;env;oty] $[(kKind kF1[i;`v])~`term; (0;oty); xTransOp[i;env;oty]]}
xAppos: {[i;env;oty]
  op: kVal kF1[i;`f]; ap: xNode[kF1[i;`a];env;oty]; aty: ap 1
  $[op in mathFns; (xEmit[`math; $[op~`length;`f32;aty]; ,ap 0; op]; $[op~`length;`f32;aty])
    op~`"~"; (xEmit[`lnot;`bool;,ap 0;`]; `bool)
    (xEmit[`neg;aty;,ap 0;`]; aty)]}
xFnCall: {[name;i;env;oty]
  args: kF[i;`arg]; n:#args
  a0: xNode[args 0;env;`f32]
  a1: $[n>1; xNode[args 1;env;`f32]; (0;`f32)]
  a2: $[n>2; xNode[args 2;env;`f32]; (0;`f32)]
  rty: $[(name~`length)|(name~`dot);`f32; name~`cross;`v3; a0 1]
  ids: $[n=1;,a0 0; n=2;(a0 0;a1 0); (a0 0;a1 0;a2 0)]
  (xEmit[`math;rty;ids;name]; rty)}
xApplyIdx: {[fr;i;env;oty] ap:xNode[fr;env;oty]; (xEmit[`extract;`f32;,ap 0; kVal kF1[i;`arg]]; `f32)}
xApply: {[i;env;oty] fr:kF1[i;`f]; nm:kVal fr; $[nm in mathFns; xFnCall[nm;i;env;oty]; xApplyIdx[fr;i;env;oty]]}
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
xNode: {[i;env;oty]
  tag: kKind i
  $[tag~`var;     env[kVal i]
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
xLoExtract: {[k] r:newId[]; emitBuf opXtract[Tf32;r;(xId@xArg k)0;xVal k]; xId[k]::r}
xLoSelect:  {[k] r:newId[]; ids:xId@xArg k; emitBuf opSel[Tid[xTy k];r;ids 0;ids 1;ids 2]; xId[k]::r}
xLoNeg:     {[k] r:newId[]; emitBuf opFneg[Tid[xTy k];r;(xId@xArg k)0]; xId[k]::r}
xLoLnot:    {[k] r:newId[]; emitBuf opLNot[Tbool;r;(xId@xArg k)0]; xId[k]::r}
xLoArith:   {[k] a:xArg k; ids:xId@a; r:newId[]; emitBuf dispBin[xVal k; xTy k; r; xTy a 0; ids 0; xTy a 1; ids 1]; xId[k]::r}
xLoMath:    {[k] a:xArg k; ids:xId@a; r:newId[]; emitBuf xMathW[xVal k; xTy k; r; ids; Tid[xTy a 0]]; xId[k]::r}
xLowerOne: {[k]
  op:xOp k
  $[op~`param;   xId[k]:: xVal k
    op~`const;   xLoConst[k]
    op~`cons;    xLoCons[k]
    op~`extract; xLoExtract[k]
    op~`select;  xLoSelect[k]
    op~`neg;     xLoNeg[k]
    op~`lnot;    xLoLnot[k]
    op~`arith;   xLoArith[k]
    op~`math;    xLoMath[k]
    0]}
/ xRe is a GLOBAL so the each's lambda can read it (no closure over the local mask).
xLowerSpirv: {[root] xId::(#xOp)#-1; xRe:: xReach[root]; {[k] $[xRe k; xLowerOne k; 0]}' !#xOp; 0}

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
