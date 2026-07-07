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
  TexVar:: 0                        / no texture section (see FragmentShaderTex)

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

/ ── FragmentShaderTex[ioTypes; fn] → SPIR-V word list ───────────────────────
/ Like FragmentShader, plus one sampled 2-D texture bound at @group(1): binding 0
/ is the image (`texture_2d<f32>`), binding 1 the sampler.  The body samples it
/ with  sample[uv]  → v4 (see compSample).  The host wires the texture with
/ gpuTexture + DrawMeshT.  Interpolate the UV as a v2 vertex varying.
FragmentShaderTex: {[ioTypes; fn]
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
  Timg2::   newId[]; Tsamp2::  newId[]; TsImg::   newId[]
  PUCimg::  newId[]; PUCsamp:: newId[]
  TexVar::  newId[]; SampVar:: newId[]

  loadedPairs: inVarIds loadOnePair' inTySyms
  env: argNames!loadedPairs

  stmts: lamBody lam
  rp: compSeq[stmts; env; outTySym]
  result: rp[0]

  emitBuf opStore[outId; result]

  locs: !#argNames
  buildMod[outId; inVarIds; inTys; inPtrs; outPtr; locs]
}

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
opAbs:  {[t;r;a]   (0x0006000C;t;r;Glsl;4;a)}     / FAbs
opFloor:{[t;r;a]   (0x0006000C;t;r;Glsl;8;a)}     / Floor
opFract:{[t;r;a]   (0x0006000C;t;r;Glsl;10;a)}    / Fract
opSign: {[t;r;a]   (0x0006000C;t;r;Glsl;6;a)}     / FSign
opLen:  {[t;r;a]   (0x0006000C;Tf32;r;Glsl;66;a)} / Length → always f32
opNrm:  {[t;r;a]   (0x0006000C;t;r;Glsl;69;a)}    / Normalize → same type
/ GLSL.std.450 extended instructions — 2-arg
opFmin: {[t;r;a;b] (0x0007000C;t;r;Glsl;37;a;b)}  / FMin
opFmax: {[t;r;a;b] (0x0007000C;t;r;Glsl;40;a;b)}  / FMax
opPow:  {[t;r;a;b] (0x0007000C;t;r;Glsl;26;a;b)}  / Pow
opStep: {[t;r;a;b] (0x0007000C;t;r;Glsl;48;a;b)}  / Step (edge, x) → same type as x
opCrs:  {[t;r;a;b] (0x0007000C;Tv3;r;Glsl;68;a;b)} / Cross → always v3
/ GLSL.std.450 extended instructions — 3-arg
opClamp:{[t;r;a;b;c] (0x0008000C;t;r;Glsl;43;a;b;c)} / FClamp
opMix:  {[t;r;a;b;c] (0x0008000C;t;r;Glsl;46;a;b;c)} / FMix (lerp)
opSS:   {[t;r;a;b;c] (0x0008000C;t;r;Glsl;49;a;b;c)} / SmoothStep
/ Arithmetic / conversion
opI2f:  {[t;r;a]   (0x0004006F;t;r;a)}     / OpConvertSToF 111
opF2i:  {[t;r;a]   (0x00040070;t;r;a)}     / OpConvertFToS 112
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
mathFns1: `abs`floor`fract`sign`sqrt`sqr`sin`cos`length`normalize
mathFns:  `abs`floor`fract`sign`sqrt`sqr`sin`cos`length`normalize`pow`min`max`dot`cross`step`mod`clamp`mix`smoothstep

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

/ FragmentShaderTex texture scratch: SPIR-V ids for the sampled image / sampler
/ types, their UniformConstant pointer types, and the two global variables.
/ TexVar>0 signals buildMod to emit the texture section; set per shader, read by
/ compSample (ink lambdas can't see enclosing locals, so these live as globals).
Timg2::   0   / OpTypeImage (f32, 2D, sampled)
Tsamp2::  0   / OpTypeSampler
TsImg::   0   / OpTypeSampledImage
PUCimg::  0   / OpTypePointer UniformConstant → image
PUCsamp:: 0   / OpTypePointer UniformConstant → sampler
TexVar::  0   / OpVariable UniformConstant image   (set 1, binding 0)
SampVar:: 0   / OpVariable UniformConstant sampler (set 1, binding 1)

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
    name~`sqr;        emitBuf opFmul[at;r;a0[0];a0[0]]
    name~`sin;        emitBuf opSin[at;r;a0[0]]
    name~`cos;        emitBuf opCos[at;r;a0[0]]
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

/ sample[uv] → texture lookup: OpSampledImage(image,sampler) then
/ OpImageSampleImplicitLod at the interpolated uv. Only valid inside a
/ FragmentShaderTex (TexVar/… hold the sampled-image ids). Returns v4.
compSample: {[i; env]
  args: kF[i;`arg]
  uv: compNode[args[0]; env; `v2]
  li: newId[]; emitBuf opLoad[Timg2; li; TexVar]
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
  $[fnName~`sample;    compSample[i; env]
    fnName in mathFns;  compFnCall[fnName; i; env; oty]
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
/ For bind nodes (y: expr), compile rhs and extend env with name→result.
/ Returns (id; ty_sym) of the last expression.
compSeqTail: {[stmts; env; oty]
  s:   stmts 0
  isb: ((kKind s)~`bind) & (0<#kF[s;`a])
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
  hasTex:   TexVar>0
  decTex:   $[hasTex; (0x00040047;TexVar;34;1),(0x00040047;TexVar;33;0),(0x00040047;SampVar;34;1),(0x00040047;SampVar;33;1); !0]
  texTypes: $[hasTex; (0x00090019;Timg2;Tf32;1;0;0;0;1;0),(0x0002001A;Tsamp2),(0x0003001B;TsImg;Timg2),(0x00040020;PUCimg;0;Timg2),(0x00040020;PUCsamp;0;Tsamp2); !0]
  varTex:   $[hasTex; (0x0004003B;PUCimg;TexVar;0),(0x0004003B;PUCsamp;SampVar;0); !0]

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
