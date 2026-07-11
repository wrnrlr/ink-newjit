/ lib/spirv.k — SPIR-V copy-and-patch compiler for ink shaders
/ Tiramisu 4-layer model applied to ink→SPIR-V:
/   Layer 1 (Abstract Algorithm)  : ink lambda AST via `parse`
/   Layer 2 (Computation Mgmt)    : type-annotate, schedule (trivial for shaders)
/   Layer 3 (Data Mgmt)           : assign SPIR-V IDs, emit typed sections
/   Layer 4 (Communication Mgmt)  : assemble SPIR-V binary in spec order
/
/ Load with:  2: "lib/spirv.k"
/ Compile:    compShader[fn; ioTypes] → int list (SPIR-V words)
/ Example:    compShader[{[uv] smoothstep[0.02;-0.02; sqrt[(uv[0]-0.5)*(uv[0]-0.5)+(uv[1]-0.5)*(uv[1]-0.5)]-0.3]}; [`uv:`v2; `out:`f32]]

/ ── Layer 1+2: public shader compiler ───────────────────────────────────────
/ FragmentShader[ioTypes; fn] → SPIR-V word list (int list)
/ ioTypes: dict of arg_name→type_sym, plus `out for the output type
/          type symbols: `f32 `v4 `v2 `v3 `i32 `bool
/ fn:      ink lambda whose args become shader inputs, return value → output
/ Lambdas can have local bindings: {[uv] d: sqrt[...]; (d;d;d;1.0)}
FragmentShader: {[ioTypes; fn]
  Nid::Nfixed; Buf::(); Con::()
  TexVars:: ()                      / no texture section (see FragmentShaderTexN)

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

/ ── FragmentShaderTexN[ioTypes; nTex; fn] → SPIR-V word list ────────────────
/ Like FragmentShader, plus nTex sampled 2-D textures at @group(1): image k is at
/ binding k, and one shared sampler at binding nTex.  The body samples texture k
/ with  sample[k; uv]  → v4 (sample[uv] is texture 0).  See compSample.  The host
/ wires the textures with gpuTexture + DrawMeshT/DrawGeomT/DrawInstancedT, passing
/ a list of texture handles.  Interpolate the UV(s) as v2 vertex varyings.
FragmentShaderTexN: {[ioTypes; nTex; fn]
  Nid::Nfixed; Buf::(); Con::()

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
FragmentShaderTex: {[ioTypes; fn] FragmentShaderTexN[ioTypes; 1; fn]}

/ ── VertexShader[inTypes; varyTypes; fn] → SPIR-V word list ─────────────────
/ inTypes:   dict argName→typeSym  (vertex attribute inputs, e.g. `pos`nor!`v3`v3)
/ varyTypes: dict name→typeSym     (interpolated varyings; use ()!() for none)
/ fn:        lambda returning (glPos_v4; vary0; ...) or just glPos_v4 if no varyings
/
/ gl_Position is always the first return element; emitted via the gl_PerVertex
/ Block struct (required by Vulkan/SPIR-V spec).  Varyings get Location 0,1,...
/ and must match the FragmentShader's input Location assignments.
VertexShader: {[inTypes; varyTypes; fn] VertexShaderU[inTypes; varyTypes; (); fn]}

/ ── VertexShaderU[inTypes; varyTypes; uniNames; fn] ─────────────────────────
/ Like VertexShader, plus a uniform block at @group(0) @binding(0).  uniNames is
/ a list of symbols, one per vec4 uniform slot; each becomes a v4 value in the
/ shader body (index components with name[i]).  The host fills the slots per draw
/ via DrawMeshU (slot k = uniform floats 4k..4k+3).  uniNames:() ⇒ no block, and
/ the emitted module is byte-identical to the old VertexShader.
VertexShaderU: {[inTypes; varyTypes; uniNames; fn]
  Nid::Nfixed; Buf::(); Con::()

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


/ ── Reserved SPIR-V IDs (1–19 fixed in every module) ────────────────────────
Tvoid:   1  / OpTypeVoid
Tfunc:   2  / OpTypeFunction void()
Tf32:    3  / OpTypeFloat 32
Tv4:     4  / OpTypeVector f32 4
Tv2:     5  / OpTypeVector f32 2
Tbool:   6  / OpTypeBool
Ti32:    7  / OpTypeInt 32 signed
Glsl:    8  / GLSL.std.450 extended instruction set
Fmain:   9  / main function
PinF32:  10 / OpTypePointer Input  f32
PoutF32: 11 / OpTypePointer Output f32
PinV4:   12 / OpTypePointer Input  v4
PoutV4:  13 / OpTypePointer Output v4
PinV2:   14 / OpTypePointer Input  v2
PoutV2:  15 / OpTypePointer Output v2
Tv3:     17 / OpTypeVector f32 3
PinV3:   18 / OpTypePointer Input  v3
PoutV3:  19 / OpTypePointer Output v3
Nfixed:  20 / first dynamic id

/ ── Type ID lookup tables ─────────────────────────────────────────────────────
/ ioType symbol → SPIR-V type ID
Tid:    [f32:Tf32; v4:Tv4; v2:Tv2; v3:Tv3; bool:Tbool; i32:Ti32; void:Tvoid]
/ ioType symbol → input/output pointer type ID
PtrIn:  [f32:PinF32; v4:PinV4; v2:PinV2; v3:PinV3]
PtrOut: [f32:PoutF32; v4:PoutV4; v2:PoutV2; v3:PoutV3]
/ AST literal type name → SPIR-V type ID
LitTid: [float:Tf32; int:Ti32; bool:Tbool]

/ ── Stencil functions (copy-and-patch templates) ─────────────────────────────
/ Convention: t=result_type  r=result_id  a b=operand ids
/ Each returns the exact SPIR-V words for one instruction.
opFadd: {[t;r;a;b] (0x00050081;t;r;a;b)}   / OpFAdd  129
opFsub: {[t;r;a;b] (0x00050083;t;r;a;b)}   / OpFSub  131
opFmul: {[t;r;a;b] (0x00050085;t;r;a;b)}   / OpFMul  133
opFdiv: {[t;r;a;b] (0x00050088;t;r;a;b)}   / OpFDiv  136
opIadd: {[t;r;a;b] (0x00050080;t;r;a;b)}   / OpIAdd  128
opIsub: {[t;r;a;b] (0x00050082;t;r;a;b)}   / OpISub  130
opImul: {[t;r;a;b] (0x00050084;t;r;a;b)}   / OpIMul  132
opFneg: {[t;r;a]   (0x0004007F;t;r;a)}     / OpFNegate 127
opFmod: {[t;r;a;b] (0x0005008D;t;r;a;b)}   / OpFMod  141 (GLSL mod: result sign = divisor)
/ GLSL.std.450 extended instructions — 1-arg
opSin:  {[t;r;a]   (0x0006000C;t;r;Glsl;13;a)}    / sin
opCos:  {[t;r;a]   (0x0006000C;t;r;Glsl;14;a)}    / cos
opSqrt: {[t;r;a]   (0x0006000C;t;r;Glsl;31;a)}    / sqrt
opExp:  {[t;r;a]   (0x0006000C;t;r;Glsl;27;a)}    / exp  (e^x)
opLog:  {[t;r;a]   (0x0006000C;t;r;Glsl;28;a)}    / log  (ln x)
opTanh: {[t;r;a]   (0x0006000C;t;r;Glsl;21;a)}    / tanh (for GELU)
opAbs:  {[t;r;a]   (0x0006000C;t;r;Glsl;4;a)}     / FAbs
opFloor:{[t;r;a]   (0x0006000C;t;r;Glsl;8;a)}     / Floor
opFract:{[t;r;a]   (0x0006000C;t;r;Glsl;10;a)}    / Fract
opSign: {[t;r;a]   (0x0006000C;t;r;Glsl;6;a)}     / FSign
opAsin: {[t;r;a]   (0x0006000C;t;r;Glsl;16;a)}    / Asin
opAcos: {[t;r;a]   (0x0006000C;t;r;Glsl;17;a)}    / Acos
opAtan: {[t;r;a]   (0x0006000C;t;r;Glsl;18;a)}    / Atan (1-arg)
opLen:  {[t;r;a]   (0x0006000C;Tf32;r;Glsl;66;a)} / Length → always f32
opNrm:  {[t;r;a]   (0x0006000C;t;r;Glsl;69;a)}    / Normalize → same type
/ GLSL.std.450 extended instructions — 2-arg
opFmin: {[t;r;a;b] (0x0007000C;t;r;Glsl;37;a;b)}  / FMin
opFmax: {[t;r;a;b] (0x0007000C;t;r;Glsl;40;a;b)}  / FMax
opAtan2:{[t;r;a;b] (0x0007000C;t;r;Glsl;25;a;b)}  / Atan2(y,x)
opPow:  {[t;r;a;b] (0x0007000C;t;r;Glsl;26;a;b)}  / Pow
opStep: {[t;r;a;b] (0x0007000C;t;r;Glsl;48;a;b)}  / Step (edge, x) → same type as x
opCrs:  {[t;r;a;b] (0x0007000C;Tv3;r;Glsl;68;a;b)} / Cross → always v3
/ GLSL.std.450 extended instructions — 3-arg
opClamp:{[t;r;a;b;c] (0x0008000C;t;r;Glsl;43;a;b;c)} / FClamp
opMix:  {[t;r;a;b;c] (0x0008000C;t;r;Glsl;46;a;b;c)} / FMix (lerp)
opSS:   {[t;r;a;b;c] (0x0008000C;t;r;Glsl;49;a;b;c)} / SmoothStep
/ Arithmetic / conversion
opI2f:  {[t;r;a]   (0x0004006F;t;r;a)}     / OpConvertSToF 111
opF2i:  {[t;r;a]   (0x00040070;t;r;a)}     / OpConvertSToF 112
opU2f:  {[t;r;a]   (0x00040070;t;r;a)}     / OpConvertUToF 112 (gid u32 → f32)
opF2s:  {[t;r;a]   (0x0004006E;t;r;a)}     / OpConvertFToS 110 (index f32 → i32)
opAtomicIAdd: {[t;r;ptr;sc;sem;v] (0x000700EA;t;r;ptr;sc;sem;v)}  / OpAtomicIAdd 234 (scatter-add)
opDot:  {[t;r;a;b] (0x00050094;t;r;a;b)}   / OpDot 148
opLoad: {[t;r;ptr] (0x0004003D;t;r;ptr)}   / OpLoad 61
opStore:{[ptr;val] (0x0003003E;ptr;val)}   / OpStore 62
opConst:{[t;r;v]   (0x0004002B;t;r;$[t=Tf32;`I$v;v])}  / OpConstant 43
opVTS:  {[t;r;v;s] (0x0005008E;t;r;v;s)}  / OpVectorTimesScalar 142
opXtract:{[t;r;v;i](0x00050051;t;r;v;i)}   / OpCompositeExtract 81
opCons2:{[t;r;a;b]     (0x00050050;t;r;a;b)}        / OpCompositeConstruct vec2
opCons3:{[t;r;a;b;c]   (0x00060050;t;r;a;b;c)}      / OpCompositeConstruct vec3
opCons4:{[t;r;a;b;c;d] (0x00070050;t;r;a;b;c;d)}    / OpCompositeConstruct vec4
/ Float comparison → always produce bool result type
opFOlt: {[t;r;a;b] (0x000500B8;Tbool;r;a;b)}  / OpFOrdLessThan 184
opFOgt: {[t;r;a;b] (0x000500BA;Tbool;r;a;b)}  / OpFOrdGreaterThan 186
opFOeq: {[t;r;a;b] (0x000500B4;Tbool;r;a;b)}  / OpFOrdEqual 180
opFOne: {[t;r;a;b] (0x000500B6;Tbool;r;a;b)}  / OpFOrdNotEqual 182
opLAnd: {[t;r;a;b] (0x000500A7;Tbool;r;a;b)}  / OpLogicalAnd 167
opLOr:  {[t;r;a;b] (0x000500A6;Tbool;r;a;b)}  / OpLogicalOr 166
opLNot: {[t;r;a]   (0x000400A8;Tbool;r;a)}    / OpLogicalNot 168
/ Ternary select: cond ? a : b (condition must be bool, a/b same type as result)
opSel:  {[t;r;c;a;b] (0x000600A9;t;r;c;a;b)}  / OpSelect 169
/ Integer compare (loop condition) → bool
opSLT:  {[t;r;a;b] (0x000500B1;t;r;a;b)}      / OpSLessThan 177
/ Structured control flow (in-kernel bounded loops — see compRsum)
opLabel:  {[r]        (0x000200F8;r)}                  / OpLabel 248
opBranch: {[t]        (0x000200F9;t)}                  / OpBranch 249
opBrCond: {[c;t;f]    (0x000400FA;c;t;f)}              / OpBranchConditional 250
opLoopMrg:{[m;c]      (0x000400F6;m;c;0)}              / OpLoopMerge 246 (LoopControl None)
opPhi2:   {[t;r;a;la;b;lb] (0x000700F5;t;r;a;la;b;lb)} / OpPhi 245 (two (value;parent) pairs)
opCopy:   {[t;r;a]    (0x00040053;t;r;a)}             / OpCopyObject 83 (bind a computed value to a pre-allocated id)

/ ── Type helpers ─────────────────────────────────────────────────────────────
LitSym: [float:`f32; int:`i32; bool:`bool]

isVecTy: {[ty] (ty~`v4) | (ty~`v2) | (ty~`v3)}

/ Component count for join result type: f32=1, v2=2, v3=3, v4=4
ncVec: [f32:1; v2:2; v3:3; v4:4]
jnRty: {[a;b] n: ncVec[a]+ncVec[b]; $[n=2;`v2;n=3;`v3;`v4]}

/ Comparison ops always produce bool; others propagate vector type or use operand type
cmpOps: `<`>`=`~`&`|
binRty: {[op;aty;bty;oty] $[op in cmpOps; `bool; op~`,; jnRty[aty;bty]; isVecTy[aty]; aty; isVecTy[bty]; bty; aty]}

/ ── Known 1-arg and multi-arg math function names ────────────────────────────
mathFns1: `abs`floor`fract`sign`sqrt`exp`log`tanh`sqr`sin`cos`asin`acos`atan`length`normalize
mathFns:  `abs`floor`fract`sign`sqrt`exp`log`tanh`sqr`sin`cos`asin`acos`atan`length`normalize`pow`min`max`atan2`dot`cross`step`mod`clamp`mix`smoothstep

/ ── Verb dispatch ────────────────────────────────────────────────────────────
dispBin: {[op;rty;r;aty;a;bty;b]
  rt: Tid[rty]
  at: Tid[aty]
  $[op~`+;   opFadd[rt;r;a;b]
    op~`-;   opFsub[rt;r;a;b]
    op~`%;   opFdiv[rt;r;a;b]
    op~`*;   $[isVecTy[aty] & ~isVecTy[bty]; opVTS[rt;r;a;b]
               isVecTy[bty] & ~isVecTy[aty]; opVTS[rt;r;b;a]
               opFmul[rt;r;a;b]]
    op~`,;   (0x00050050;rt;r;a;b)   / OpCompositeConstruct, 2 constituents: v2+f32→v3, v3+f32→v4, etc.
    op~`<;   opFOlt[at;r;a;b]   / <= / >= are handled by the compTrans peephole
    op~`>;   opFOgt[at;r;a;b]
    op~`=;   opFOeq[at;r;a;b]
    op~`~;   opFOne[at;r;a;b]
    op~`&;   opLAnd[at;r;a;b]
    op~`|;   opLOr[at;r;a;b]
    opFadd[rt;r;a;b]]}

dispUn: {[op;ty;r;a]
  t: Tid[ty]
  $[op~`sin;       opSin[t;r;a]
    op~`cos;       opCos[t;r;a]
    op~`sqrt;      opSqrt[t;r;a]
    op~`-;         opFneg[t;r;a]
    op~`~;         opLNot[Tbool;r;a]
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

/ VertexShaderU uniform-block scratch: the current block's struct type id, the
/ Uniform→vec4 pointer type id, and the block variable id.  Set per shader and
/ read by the top-level each-helpers below (ink lambdas can't see enclosing locals).
UTuni:: 0
UPv4::  0
UVar::  0

/ FragmentShaderTexN texture scratch: SPIR-V ids for the shared image / sampler
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
lamOf:   {[fn] Cst:: parse $fn; *|kF[0;`stmt]}   / last stmt of root terse = lambda
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
  ids:  {[v] r: newId[]; emitCon opConst[Tf32;r;v]; r}' vals
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
  r: newId[]
  emitCon opConst[t;r;val]
  (r; LitSym[useTy])
}

compLit: {[i; oty]
  $[(kKind i) in `floats`ints; compVecLit[i]; compScalarLit[i;oty]]
}

compVar: {[i; env] env[kVal i]}

/ x<=y → ~(x>y),  x>=y → ~(x<y).  `flip` is the strict comparison to negate;
/ the b operand is an apposit(`= …) wrapper, so its `a child is the real operand.
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
  opTy: $[op in `<`>`=`~; `f32; op in (`&;`|); `bool; oty]
  ap: compNode[kF1[i;`a]; env; opTy]
  bp: compNode[kF1[i;`b]; env; opTy]
  aty: ap[1]; bty: bp[1]
  rty: binRty[op; aty; bty; oty]
  / Bug fix: for +,-,% on vector ⊕ scalar, splat the scalar up to the vector type
  / so OpFAdd/Sub/Div see matching operands (* uses OpVectorTimesScalar already).
  bcast: (op in `+`-`%) & isVecTy[rty] & ~(isVecTy[aty] & isVecTy[bty])
  aId: $[bcast & ~isVecTy[aty]; splat[rty; ap[0]]; ap[0]]
  bId: $[bcast & ~isVecTy[bty]; splat[rty; bp[0]]; bp[0]]
  da:  $[bcast & ~isVecTy[aty]; rty; aty]
  db:  $[bcast & ~isVecTy[bty]; rty; bty]
  r: newId[]
  emitBuf dispBin[op; rty; r; da; aId; db; bId]
  (r; rty)
}

/ Peephole for the missing <= / >= operators.  ink has no such tokens: `x<=y`
/ lexes as `x < (=y)` and `x>=y` as `x > (=y)` (monadic `=` on the right).
/ Detect that shape and emit the De Morgan equivalent so shaders can write
/ `a<=b` / `a>=b` directly instead of `~(a>b)` / `~(a<b)`.
compTrans: {[i; env; oty]
  vN: kF1[i;`v]
  $[(kKind vN)~`term; compAdverb[i; vN; env; oty]   / adverbed verb: `i f/ x`, `f g/ x`
    compTransOp[i; env; oty]]
}
compTransOp: {[i; env; oty]
  op: kVal kF1[i;`v]; b: kF1[i;`b]
  isEq: ((kKind b)~`apposit) & ((kVal kF1[b;`f])~`=)
  $[(op~`<) & isEq; compLeGe[i; env; `>]
    (op~`>) & isEq; compLeGe[i; env; `<]
    compTransNorm[i; env; oty]]
}

/ Monadic application written as juxtaposition: `floor px`, `sin px`, `-x`.
/ The op slot is a bare symbol for built-in verbs (`sin`-x) but a var node
/ (`literal;`var;`floor) for math names that aren't ink keywords — normalise
/ both to the bare symbol so dispUn matches (else floor/fract/sign/length/
/ normalize silently fall through to negate).
/ Monadic application `floor px`, `-x`. The f slot is a var row (math name) or an
/ op row (builtin verb); either way its `value holds the glyph/name for dispUn.
compAppos: {[i; env; oty]
  op: kVal kF1[i;`f]
  ap: compNode[kF1[i;`a]; env; oty]
  r: newId[]
  emitBuf dispUn[op; ap[1]; r; ap[0]]
  rty: $[op~`length; `f32; op~`~; `bool; ap[1]]
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
/ Lets a kernel write several buffers as side effects (GpKernel has no auto-output).
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
/                       adverb for this (`+/e'!K` needs a materialised range, which
/                       a per-thread kernel can't build) so it stays a primitive.
/   i f/ x  (N-do)    — apply verb `f` to state `x`, `i` times.   ← real k adverb
/   f g/ x  (While)   — apply body `g` to state `x` while cond `f x` holds. ← adverb
/ The verb/cond `{[s] …}` is NOT a runtime closure — its body is INLINED with the
/ param bound to the carried state (and, for rsum, `k` bound to the loop counter as
/ f32); enclosing locals stay visible because we compile in the current env.
/ Constants RCi0/RCi1/RCf0 (i32 0, i32 1, f32 0.) are made once per compile in
/ compGpN, so these are valid inside a GpKernel only (the fixed stencil emitters
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

/ N-do:  i f/ x  — verb `f` (=`vN`, a 1-param lambda) applied to state x, i times.
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

/ While:  f g/ x  — body `g` (=`vN`) applied to state x while cond `f` (=`cN`, a
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
/ value is the adverb glyph and whose `f` child is the verb. `/` splits N-do vs
/ While by the left arg's kind (a lambda ⇒ While cond; else ⇒ N-do count).
compAdverb: {[i; vN; env; oty]
  glyph: kVal vN
  verb:  kF1[vN;`f]
  aN:    kF1[i;`a]; bN: kF1[i;`b]
  $[glyph~`/; $[(kKind aN)~`lambda; compWhile[aN; verb; bN; env; oty]
                compNdo[aN; verb; bN; env; oty]]
    (0; oty)]                                     / other adverbs: not in kernels yet
}

/ sample[uv] (texture 0) or sample[k; uv] (texture k, k a literal) → texture
/ lookup: OpSampledImage(image_k, shared sampler) then OpImageSampleImplicitLod at
/ the interpolated uv. Only valid inside a FragmentShaderTexN. Returns v4.
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
/ Dispatch on element count.
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

  / FragmentShaderTex texture section (emitted only when TexVar was allocated):
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

/ ── Compute stencil ──────────────────────────────────────────────────────────
opAccChain: {[t;r;base;m;i] (0x00060041;t;r;base;m;i)}

/ ── compCompute: compile element-wise compute shader ─────────────────────────
compCompute: {[fn]
  Nid::Nfixed; Buf::(); Con::()

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
  exm: (0x00060010; Fmain; 17; 64; 1; 1)

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

/ Public name, consistent with FragmentShader / VertexShader. Compiles an
/ element-wise f32 kernel {[x] ...} to a SPIR-V compute shader (workgroup 64,
/ reads binding 0, writes binding 1). Run it with RunShader[ComputeShader[fn]; inF].
/ This is the lowering target for data-parallel ECS systems (a per-entity column
/ map): compile once, then RunShader the column each frame inside a gpuRun frame.
ComputeShader: compCompute

/ ── compCompute2: two-input element-wise compute shader ──────────────────────────
/ Kernel {[x;y] ...} reads input1 at binding 0 and input2 at binding 2, writes the
/ result to output at binding 1. Run with RunShader2[ComputeShader2[fn]; in1; in2].
/ Enables real systems that combine two columns, e.g. {[px;vx] px+vx*dt}.
compCompute2: {[fn]
  Nid::Nfixed; Buf::(); Con::()

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
  exm: (0x00060010; Fmain; 17; 64; 1; 1)

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

ComputeShader2: compCompute2

/ ── compStencil: gather-capable compute shader (the buffer-index intrinsic) ──────
/ Kernel {[u; i] expr}: `u` is the input storage buffer (binding 0), indexable at
/ ANY computed offset — u[i], u[i-1], u[i+W] — and `i` is this thread's flat index
/ (gl_GlobalInvocationID.x) as an f32. The result is stored to output[i] (binding 1).
/ This is the element-wise ComputeShader generalised from a map to a gather: the
/ single hard-wired input[gid] load becomes u[<expr>], so stencils (Jacobi/SOR/
/ image filters) compile. Grid dims / boundaries are baked as literals in the kernel
/ (it's compiled per problem); conditionals ($[…]) and floor/mod handle edges.
/ Run on the resident path: p:CompileCompute[StencilShader[fn]; 2]; then Dispatch.
compStencil: {[fn]
  Nid::Nfixed; Buf::(); Con::()

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
  exm: (0x00060010; Fmain; 17; 64; 1; 1)

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

StencilShader: compStencil

/ ── compStencilU: stencil + a params buffer (uniforms as an indexable buffer) ────
/ Kernel {[u; g; i]}: `u`=input (binding 0), `g`=params (binding 2, indexable
/ g[0],g[1],…), `i`=thread index; result → output (binding 1). Lets ONE compiled
/ pipeline serve any grid: pass N/ω/… in the params buffer instead of baking them.
/ nbind=3; Dispatch order is (in; out; params). g is just another storage buffer,
/ so the buffer-index intrinsic reads it for free.
compStencilU: {[fn]
  Nid::Nfixed; Buf::(); Con::()
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
  exm:(0x00060010;Fmain;17;64;1;1)
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
StencilShaderU: compStencilU

/ ── compStencilIP: in-place stencil (single state buffer) + params ──────────────
/ Kernel {[u; g; i]}: `u`=state (binding 0, read AND written in place), `g`=params
/ (binding 1), `i`=thread index; result → u[i] (binding 0, same buffer). This is
/ what red-black Gauss-Seidel/SOR needs: reds read blacks and write reds in place,
/ so the just-updated reds are visible to the black pass. Non-updated cells must
/ store their own value (u[i]); the resulting same-value read/write "race" is
/ benign on real hardware (and Dawn doesn't flag it). nbind=2; Dispatch (state;params).
compStencilIP: {[fn]
  Nid::Nfixed; Buf::(); Con::()
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
  exm:(0x00060010;Fmain;17;64;1;1)
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
StencilShaderIP: compStencilIP

/ ── compScatter: edge-parallel atomic scatter (the cloth/graph intrinsic) ────────
/ Kernel {[acc; a; b; g; i]}: one thread per EDGE (i = edge index). `a`,`b` are f32
/ input buffers (endpoint indices / per-edge attributes), read with a[i]; `g` is a
/ params buffer (e.g. g[0]=edge count). `acc` is an i32 accumulator scattered into
/ with scatterAdd[acc; node; val] — OpAtomicIAdd, so many edges hitting the same
/ node accumulate without a race. No per-thread output; the body is scatterAdd side
/ effects. This is XPBD's scatter-add of constraint corrections onto shared
/ particles (cloth.k's amend-with-+), on the GPU. IMPORTANT: dispatch rounds up to
/ a multiple of 64, so guard the scatter VALUE to 0 for out-of-range threads
/ ($[i<g[0];val;0.]) — atomic-add of 0 is a harmless no-op (OpSelect can't guard
/ the side effect itself). Read back with ReadBufferI. nbind=4; Dispatch (acc;a;b;g).
compScatter: {[fn]
  Nid::Nfixed; Buf::(); Con::()
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
  exm:(0x00060010;Fmain;17;64;1;1)
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
StencilScatter: compScatter

/ ── compGpN: general compute kernel — nAcc i32 accumulators + nBuf f32 buffers ────
/ Kernel {[acc0..accM; buf0..bufN; i]}: bindings 0..nAcc-1 are i32 atomic
/ accumulators (scatterAdd/iget/iset), nAcc..nAcc+nBuf-1 are f32 buffers (read with
/ b[j], written with set[b;j;v]); i is the thread index. There is NO automatic output
/ store — every write is an explicit set/scatterAdd/iset, so one kernel can update
/ several buffers (e.g. XPBD integrate writes p, v AND prev). This is the general
/ lowering the fixed StencilShader* emitters specialise; it drives test/clothgpu.k.
/ nbind = nAcc+nBuf; Dispatch order is (accumulators…; buffers…).
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
  Nid::Nfixed; Buf::(); Con::()
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
  exm:(0x00060010;Fmain;17;64;1;1)
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
GpKernel: compGpN

/ ── Vertex shader stencils ────────────────────────────────────────────────────
opAccChain1: {[t;r;base;i] (0x00050041;t;r;base;i)}  / OpAccessChain single index
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
