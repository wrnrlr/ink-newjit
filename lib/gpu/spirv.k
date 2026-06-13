/ lib/gpu/spirv.k — SPIR-V copy-and-patch compiler for ink shaders
/ Tiramisu 4-layer model applied to ink→SPIR-V:
/   Layer I  (Abstract Algorithm)   : ink lambda AST via `parse`
/   Layer II (Computation Mgmt)     : type-annotate, schedule (trivial for shaders)
/   Layer III (Data Mgmt)           : assign SPIR-V IDs, emit typed sections
/   Layer IV (Communication Mgmt)  : assemble SPIR-V binary in spec order
/
/ Load with:  2: "lib/gpu/spirv.k"
/ Compile:    compShader[fn; ioTypes] → int list (SPIR-V words)
/ Example:    compShader[{[x] sin x * 0.5}; [`x:`f32; `out:`f32]]

/ ── Reserved SPIR-V IDs (1–15 fixed in every module) ────────────────────────
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
Nfixed:  16 / first dynamic id

/ ── Type ID lookup tables ─────────────────────────────────────────────────────
/ ioType symbol → SPIR-V type ID
Tid:    [`f32:Tf32; `v4:Tv4; `v2:Tv2; `bool:Tbool; `i32:Ti32; `void:Tvoid]
/ ioType symbol → input/output pointer type ID
PtrIn:  [`f32:PinF32; `v4:PinV4; `v2:PinV2]
PtrOut: [`f32:PoutF32; `v4:PoutV4; `v2:PoutV2]
/ AST literal type name → SPIR-V type ID
LitTid: [`float:Tf32; `int:Ti32; `bool:Tbool]

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
opSin:  {[t;r;a]   (0x0006000C;t;r;Glsl;13;a)}    / GLSL.std.450 sin
opCos:  {[t;r;a]   (0x0006000C;t;r;Glsl;14;a)}    / GLSL.std.450 cos
opSqrt: {[t;r;a]   (0x0006000C;t;r;Glsl;31;a)}    / GLSL.std.450 sqrt
opFmin: {[t;r;a;b] (0x0007000C;t;r;Glsl;37;a;b)}  / GLSL.std.450 FMin
opFmax: {[t;r;a;b] (0x0007000C;t;r;Glsl;40;a;b)}  / GLSL.std.450 FMax
opI2f:  {[t;r;a]   (0x0004006F;t;r;a)}     / OpConvertSToF 111
opF2i:  {[t;r;a]   (0x00040070;t;r;a)}     / OpConvertFToS 112
opXtract:{[t;r;v;i](0x00050051;t;r;v;i)}   / OpCompositeExtract 81
opDot:  {[t;r;a;b] (0x00050094;t;r;a;b)}   / OpDot 148
opLoad: {[t;r;ptr] (0x0004003D;t;r;ptr)}   / OpLoad 61
opStore:{[ptr;val] (0x0003003E;ptr;val)}   / OpStore 62
opConst:{[t;r;v]   (0x0004002B;t;r;$[t=Tf32;`I$v;v])}  / OpConstant 43
opVTS:  {[t;r;v;s] (0x0005008E;t;r;v;s)}  / OpVectorTimesScalar 142
opCons4:{[t;r;a;b;c;d](0x00070050;t;r;a;b;c;d)}  / OpCompositeConstruct vec4

/ ── Type helpers ─────────────────────────────────────────────────────────────
/ Map AST literal type names → IO type symbols
LitSym: [`float:`f32; `int:`i32; `bool:`bool]

/ True if type symbol is a vector (v4 or v2)
isVecTy: {[ty] (ty~`v4) | (ty~`v2)}

/ Result type for binary op: widest operand type, else inherit output type
binRty: {[op;aty;bty;oty] $[isVecTy[aty]; aty; isVecTy[bty]; bty; oty]}

/ ── Verb dispatch: type-aware, avoid dict-of-lambda (ink limitation) ──────────
/ rty,aty,bty are type symbols (`f32 `v4 `v2 `i32 `bool)
dispBin: {[op;rty;r;aty;a;bty;b]
  rt: Tid[rty]
  $[op~`+; opFadd[rt;r;a;b]
    op~`-; opFsub[rt;r;a;b]
    op~`%; opFdiv[rt;r;a;b]
    op~`*; $[isVecTy[aty] & ~isVecTy[bty]; opVTS[rt;r;a;b]
             isVecTy[bty] & ~isVecTy[aty]; opVTS[rt;r;b;a]
             opFmul[rt;r;a;b]]
    opFadd[rt;r;a;b]]}

dispUn: {[op;ty;r;a]
  t: Tid[ty]
  $[op~`sin;  opSin[t;r;a]
    op~`cos;  opCos[t;r;a]
    op~`sqrt; opSqrt[t;r;a]
    op~`-;    opFneg[t;r;a]
    opFneg[t;r;a]]}

/ ── Compiler state (reset per compShader call) ───────────────────────────────
Nid:: Nfixed  / next free SPIR-V id
Con:: ()      / OpConstant instructions (list-of-word-lists, global scope)
Buf:: ()      / function body instructions (list-of-word-lists)

newId:   {[] r:Nid; Nid::Nid+1; r}
emitCon: {[ws] Con,:: ,ws}
emitBuf: {[ws] Buf,:: ,ws}
emitW:   emitBuf  / alias for test compatibility

/ ── Layer III: expression compilers ─────────────────────────────────────────
/ Each returns (id; ty_sym) — the SPIR-V result ID and its type symbol.

/ Numeric literal: emit OpConstant to Con, return (id; ty_sym)
compLit: {[node]
  t: LitTid[node[1]]
  r: newId[]
  emitCon opConst[t;r;node[2]]
  (r; LitSym[node[1]])}

/ Variable reference: env maps name → (id; ty_sym)
compVar: {[node; env] env[node[2]]}

/ Binary transit: a op b — uses operand types to choose opcode
compTrans: {[node; env; oty]
  ap: compNode[node[1]; env; oty]
  bp: compNode[node[3]; env; oty]
  aty: ap[1]; bty: bp[1]
  rty: binRty[node[2]; aty; bty; oty]
  r: newId[]
  emitBuf dispBin[node[2]; rty; r; aty; ap[0]; bty; bp[0]]
  (r; rty)}

/ Unary apposit: fn arg — preserves operand type
compAppos: {[node; env; oty]
  ap: compNode[node[2]; env; oty]
  r: newId[]
  emitBuf dispUn[node[1]; ap[1]; r; ap[0]]
  (r; ap[1])}

/ Index into a composite: uv[0] → OpCompositeExtract %f32 result composite idx
/ node = (`apply; array_node; (`seq; (`literal;`int;idx)))
compApply: {[node; env; oty]
  ap: compNode[node[1]; env; oty]
  idx: node[2][1][2]
  r: newId[]
  emitBuf opXtract[Tf32; r; ap[0]; idx]
  (r; `f32)}

/ Tuple → vec4: (a;b;c;d) → OpCompositeConstruct
/ node = (`list; (`seq; e0; `div; e1; `div; e2; `div; e3))
compList: {[node; env; oty]
  elems: node[1]@&~node[1] in `seq`div
  p0: compNode[elems[0]; env; `f32]
  p1: compNode[elems[1]; env; `f32]
  p2: compNode[elems[2]; env; `f32]
  p3: compNode[elems[3]; env; `f32]
  r: newId[]
  emitBuf opCons4[Tv4; r; p0[0]; p1[0]; p2[0]; p3[0]]
  (r; `v4)}

/ AST node dispatcher
compNode: {[node; env; oty]
  tag: node[0]
  $[tag~`literal; $[node[1]~`var; compVar[node;env]; compLit[node]]
    tag~`transit; compTrans[node;env;oty]
    tag~`apposit; compAppos[node;env;oty]
    tag~`apply;   compApply[node;env;oty]
    tag~`list;    compList[node;env;oty]
    (0; oty)]}

/ ── Layer III helper: emit OpLoad, return (id; ty_sym) ───────────────────────
loadOnePair: {[vid; tsym]
  r: newId[]
  emitBuf opLoad[Tid[tsym]; r; vid]
  (r; tsym)}

/ ── Layer IV: SPIR-V module assembly ─────────────────────────────────────────
/ buildMod[outId; inVarIds; inTys; inPtrs; outPtr; locs] → SPIR-V word list
/ Assembles sections in SPIR-V 1.3 spec order.
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
  types: (0x00020013; Tvoid; 0x00020014; Tbool; 0x00030016; Tf32; 32; 0x00040017; Tv4; Tf32; 4; 0x00040017; Tv2; Tf32; 2; 0x00040015; Ti32; 32; 1; 0x00030021; Tfunc; Tvoid; 0x00040020; PinF32; 1; Tf32; 0x00040020; PoutF32; 3; Tf32; 0x00040020; PinV4; 1; Tv4; 0x00040020; PoutV4; 3; Tv4; 0x00040020; PinV2; 1; Tv2; 0x00040020; PoutV2; 3; Tv2)

  varIn:  ,/ inPtrs varInOne' inVarIds
  varOut: (0x0004003B; outPtr; outId; 3)

  label: newId[]
  fn:  (0x00050036; Tvoid; Fmain; 0; Tfunc; 0x000200F8; label)
  ret: (0x000100FD; 0x00010038)

  / ,/() = unit (length 1) in ink — use !0 for truly empty sections
  conWds: $[#Con; ,/Con; !0]
  bodWds: $[#Buf; ,/Buf; !0]

  ,/(hdr; cap; ext; mem; ep; exm; decIn; decOut; types; varIn; varOut; conWds; fn; bodWds; ret)
}

/ ── Compute stencil ──────────────────────────────────────────────────────────
/ OpAccessChain: index into a runtime-array-in-struct storage buffer
/ t=result_ptr_type  r=result  base=buffer_var  m=member_const  i=element_idx
opAccChain: {[t;r;base;m;i] (0x00060041;t;r;base;m;i)}

/ ── compCompute: compile element-wise compute shader ─────────────────────────
/ fn:  ink lambda {[x] expr} — x:f32, result:f32
/ Returns SPIR-V word list for a 1D map-over-buffer compute shader.
/ Dispatched with workgroup size 64; gpuCompute pads dispatch to n_elems.
/ Use: gpuCompute[compCompute[{[x] sin x * 0.5}]; input_F] → output_F
compCompute: {[fn]
  Nid::Nfixed; Buf::(); Con::()

  / Compute-specific type IDs (allocated dynamically — not fixed like Nfixed)
  Tu32:    newId[]  / OpTypeInt 32 0
  Tv3u32:  newId[]  / OpTypeVector u32 3
  Trta:    newId[]  / OpTypeRuntimeArray f32
  Tbuf:    newId[]  / OpTypeStruct {Trta}
  Pbufs:   newId[]  / OpTypePointer StorageBuffer Tbuf
  Pf32s:   newId[]  / OpTypePointer StorageBuffer f32
  Pv3u32i: newId[]  / OpTypePointer Input v3u32

  / Variable IDs
  gidVar: newId[]   / GlobalInvocationID (Input)
  inBuf:  newId[]   / input storage buffer
  outBuf: newId[]   / output storage buffer

  / u32 constant 0 for struct member access (OpAccessChain member index)
  Ku32z: newId[]
  emitCon (0x0004002B; Tu32; Ku32z; 0)

  / Parse lambda: single argument is the element value
  lam: last parse $fn
  argName: (lam[1]@&~lam[1] in `args`div)[0]

  / Emit body: load input element, compile expression, store output element
  gidId:    newId[]; emitBuf opLoad[Tv3u32; gidId; gidVar]
  gidXId:   newId[]; emitBuf opXtract[Tu32; gidXId; gidId; 0]
  inPtrId:  newId[]; emitBuf opAccChain[Pf32s; inPtrId; inBuf; Ku32z; gidXId]
  xId:      newId[]; emitBuf opLoad[Tf32; xId; inPtrId]
  env:      (,argName)!(,(xId; `f32))
  rp:       compNode[last lam[2]; env; `f32]
  outPtrId: newId[]; emitBuf opAccChain[Pf32s; outPtrId; outBuf; Ku32z; gidXId]
  emitBuf opStore[outPtrId; rp[0]]

  / ── Module assembly (SPIR-V 1.3 spec order) ─────────────────────────────
  bnd: Nid+1
  iface: (gidVar; inBuf; outBuf)   / all used global variables (Dawn requires all)

  hdr: (0x07230203; 0x00010300; 0; bnd; 0)
  cap: (0x00020011; 1)
  ext: (0x0006000B; Glsl; 0x4C534C47; 0x6474732E; 0x3035342E; 0)
  mem: (0x0003000E; 0; 1)
  ep:  (0x000F+(0x10000*(5+#iface)); 5; Fmain; 0x6E69616D; 0), iface
  exm: (0x00060010; Fmain; 17; 64; 1; 1)   / OpExecutionMode LocalSize 64 1 1

  / Decorations
  decGid:    (0x00040047; gidVar; 11; 28)   / BuiltIn GlobalInvocationId
  decStride: (0x00040047; Trta; 6; 4)       / ArrayStride 4
  decMem:    (0x00050048; Tbuf; 0; 35; 0)   / MemberDecorate Tbuf[0] Offset 0
  decBlk:    (0x00030047; Tbuf; 2)          / Block
  decInDs:   (0x00040047; inBuf; 34; 0)     / DescriptorSet 0
  decInBnd:  (0x00040047; inBuf; 33; 0)     / Binding 0
  decOutDs:  (0x00040047; outBuf; 34; 0)    / DescriptorSet 0
  decOutBnd: (0x00040047; outBuf; 33; 1)    / Binding 1

  / Types: basic shared types + compute-specific (one line — ink newline bug)
  sTypes: (0x00020013;Tvoid;0x00020014;Tbool;0x00030016;Tf32;32;0x00040017;Tv4;Tf32;4;0x00040017;Tv2;Tf32;2;0x00040015;Ti32;32;1;0x00030021;Tfunc;Tvoid)
  cTypes: (0x00040015;Tu32;32;0;0x00040017;Tv3u32;Tu32;3;0x0003001D;Trta;Tf32;0x0003001E;Tbuf;Trta;0x00040020;Pbufs;12;Tbuf;0x00040020;Pf32s;12;Tf32;0x00040020;Pv3u32i;1;Tv3u32)

  / Global variables
  varGid: (0x0004003B; Pv3u32i; gidVar; 1)   / Input
  varIn:  (0x0004003B; Pbufs;   inBuf;  12)  / StorageBuffer
  varOut: (0x0004003B; Pbufs;   outBuf; 12)  / StorageBuffer

  label: newId[]
  fnh: (0x00050036; Tvoid; Fmain; 0; Tfunc; 0x000200F8; label)
  ret: (0x000100FD; 0x00010038)

  conWds: $[#Con; ,/Con; !0]
  bodWds: $[#Buf; ,/Buf; !0]

  decs: decGid,decStride,decMem,decBlk,decInDs,decInBnd,decOutDs,decOutBnd
  vars: varGid,varIn,varOut

  ,/(hdr;cap;ext;mem;ep;exm;decs;sTypes;cTypes;vars;conWds;fnh;bodWds;ret)}

/ ── Layer I+II: public shader compiler ───────────────────────────────────────
/ compShader[fn; ioTypes] → SPIR-V word list (int list)
/ fn:      ink lambda whose args become shader inputs, return value → output
/ ioTypes: dict of arg_name→type_sym, plus `out for the output type
/          type symbols: `f32 `v4 `v2 `i32 `bool
/ Example:
/   compShader[{[x] sin x * 0.5}; [`x:`f32; `out:`f32]]
compShader: {[fn; ioTypes]
  Nid::Nfixed; Buf::(); Con::()

  / Layer I: parse ink lambda source → AST
  lam: last parse $fn
  argsNode: lam[1]
  argNames: argsNode@&~argsNode in `args`div

  / Layer II: resolve types from ioTypes
  outTySym: ioTypes[`out]
  outTy:  Tid[outTySym]
  outPtr: PtrOut[outTySym]
  inTySyms: ioTypes' argNames
  inTys:  Tid'  inTySyms
  inPtrs: PtrIn' inTySyms

  / Layer III: allocate SPIR-V variable IDs
  inVarIds: {[x] newId[]}' argNames
  outId: newId[]

  / Layer III: emit OpLoad for each input; env maps name → (id; ty_sym)
  loadedPairs: inVarIds loadOnePair' inTySyms
  env: argNames!loadedPairs

  / Layer III: compile expression body; compNode returns (id; ty_sym)
  body: last lam[2]
  rp: compNode[body; env; outTySym]
  result: rp[0]

  / Layer III: emit OpStore result to output variable
  emitBuf opStore[outId; result]

  / Layer IV: assemble and return SPIR-V module
  locs: !#argNames
  buildMod[outId; inVarIds; inTys; inPtrs; outPtr; locs]}
