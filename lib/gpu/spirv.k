/ lib/gpu/spirv.k — SPIR-V copy-and-patch compiler for ink shaders
/ Tiramisu 4-layer model applied to ink→SPIR-V:
/   Layer 1 (Abstract Algorithm)  : ink lambda AST via `parse`
/   Layer 2 (Computation Mgmt)    : type-annotate, schedule (trivial for shaders)
/   Layer 3 (Data Mgmt)           : assign SPIR-V IDs, emit typed sections
/   Layer 4 (Communication Mgmt)  : assemble SPIR-V binary in spec order
/
/ Load with:  2: "lib/gpu/spirv.k"
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

  lam: *|parse $fn
  argsNode: lam[1]
  argNames: argsNode@&~argsNode in `args`div

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

  / Compile body: strip seq/div markers, process bind nodes for locals
  bodySeq: lam[2]
  stmts: bodySeq@&~bodySeq in `seq`div
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
VertexShader: {[inTypes; varyTypes; fn]
  Nid::Nfixed; Buf::(); Con::()

  lam:      last parse $fn
  argsNode: lam[1]
  argNames: argsNode@&~argsNode in `args`div

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

  / Compile body stmts (all but last) to build env, then handle return tuple
  bodySeq:  lam[2]
  stmts:    bodySeq@&~bodySeq in `seq`div
  env2:     compSeqEnv[-1_stmts; env]
  lastStmt: last stmts

  / If varyings exist the last stmt is a list node; else it's the glPos expression
  outElems: $[(nVary>0) & (lastStmt[0]~`list); lastStmt[1]@&~lastStmt[1] in `seq`div; ,lastStmt]

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

  types:    (0x00020013;Tvoid;0x00020014;Tbool;0x00030016;Tf32;32;0x00040017;Tv4;Tf32;4;0x00040017;Tv2;Tf32;2;0x00040017;Tv3;Tf32;3;0x00040015;Ti32;32;1;0x00030021;Tfunc;Tvoid;0x00040020;PinF32;1;Tf32;0x00040020;PoutF32;3;Tf32;0x00040020;PinV4;1;Tv4;0x00040020;PoutV4;3;Tv4;0x00040020;PinV2;1;Tv2;0x00040020;PoutV2;3;Tv2;0x00040020;PinV3;1;Tv3;0x00040020;PoutV3;3;Tv3)
  vtxTypes: (0x0003001E;TperVtx;Tv4;0x00040020;PperVtx;3;TperVtx)

  varIn:     ,/ inPtrs varInOne' inVarIds
  varPerVtx: (0x0004003B; PperVtx; perVtxVar; 3)
  varVary:   $[nVary>0; ,/ varyPtrs varOutOne' varyVarIds; !0]

  label: newId[]
  fn:  (0x00050036; Tvoid; Fmain; 0; Tfunc; 0x000200F8; label)
  ret: (0x000100FD; 0x00010038)

  conWds: $[#Con; ,/Con; !0]
  bodWds: $[#Buf; ,/Buf; !0]

  ,/(hdr;cap;ext;mem;ep;decIn;decBlk;decPos;decVary;types;vtxTypes;varIn;varPerVtx;varVary;conWds;fn;bodWds;ret)
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
opFOle: {[t;r;a;b] (0x000500BC;Tbool;r;a;b)}  / OpFOrdLessThanEqual 188
opFOge: {[t;r;a;b] (0x000500BE;Tbool;r;a;b)}  / OpFOrdGreaterThanEqual 190
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
cmpOps: (`<;`>;`=;`~;`&;`|)
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
    op~`<;   opFOlt[at;r;a;b]
    op~`>;   opFOgt[at;r;a;b]
    op~`<=;  opFOle[at;r;a;b]
    op~`>=;  opFOge[at;r;a;b]
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

newId:   {[] r:Nid; Nid::Nid+1; r}
emitCon: {[ws] Con,:: ,ws}
emitBuf: {[ws] Buf,:: ,ws}
emitW:   emitBuf

/ ── Layer 3: math function call compiler ───────────────────────────────────
/ Compile f[a; b; c] where f is a known GLSL built-in.
/ argsSeq = (`seq; arg0; `div; arg1; ...)
compFnCall: {[name; argsSeq; env; oty]
  args: argsSeq@&~argsSeq in `seq`div
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

compLit: {[node; oty]
  litTy: node[1]
  useTy: $[(litTy~`int) & (oty~`f32); `float; litTy]
  t:   LitTid[useTy]
  val: $[(litTy~`int) & (useTy~`float); 0.+node[2]; node[2]]
  r: newId[]
  emitCon opConst[t;r;val]
  (r; LitSym[useTy])}

compVar: {[node; env] env[node[2]]}

compTrans: {[node; env; oty]
  op: node[2]
  / Feed the right hint to operands: numeric comparisons want f32, bool ops want bool
  opTy: $[op in (`<;`>;`=;`~); `f32; op in (`&;`|); `bool; oty]
  ap: compNode[node[1]; env; opTy]
  bp: compNode[node[3]; env; opTy]
  aty: ap[1]; bty: bp[1]
  rty: binRty[op; aty; bty; oty]
  r: newId[]
  emitBuf dispBin[op; rty; r; aty; ap[0]; bty; bp[0]]
  (r; rty)}

compAppos: {[node; env; oty]
  ap: compNode[node[2]; env; oty]
  r: newId[]
  emitBuf dispUn[node[1]; ap[1]; r; ap[0]]
  rty: $[node[1]~`length; `f32; node[1]~`~; `bool; ap[1]]
  (r; rty)}

/ Composite indexing fallback: v[i] → OpCompositeExtract
compApplyIdx: {[fn; argsSeq; env; oty]
  ap:  compNode[fn; env; oty]
  idx: argsSeq[1][2]
  r:   newId[]
  emitBuf opXtract[Tf32; r; ap[0]; idx]
  (r; `f32)}

/ Explicit apply: f[a;b;c]
/ Handles: math function calls AND composite indexing (v[0])
/ fn can be a symbol atom (`sqrt) or a (`literal;`var;name) node
compApply: {[node; env; oty]
  fn:     node[1]
  fnName: $[(fn[0]~`literal) & (fn[1]~`var); fn[2]; fn]
  isMath: fnName in mathFns
  $[isMath
    ; compFnCall[fnName; node[2]; env; oty]
    ; compApplyIdx[fn; node[2]; env; oty]]}

/ Tuple → vec2/vec3/vec4 via OpCompositeConstruct
/ Dispatch on element count.
compList: {[node; env; oty]
  elems: node[1]@&~node[1] in `seq`div
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
  (r; rty)}

/ $[c; then; else] and chained $[c1;t1;c2;t2;...;default] → OpSelect (eager both branches)
/ Handles scalar bool condition selecting scalar or vector values.
compCond: {[node; env; oty]
  n:   #node
  cp:  compNode[node[1]; env; `bool]
  tp:  compNode[node[2]; env; oty]
  ep:  $[n=4; compNode[node[3]; env; oty]; compCond[(,`cond), 3_node; env; oty]]
  r:   newId[]
  rty: tp[1]
  emitBuf opSel[Tid[rty]; r; cp[0]; tp[0]; ep[0]]
  (r; rty)}

/ AST node dispatcher
compNode: {[node; env; oty]
  tag: node[0]
  $[tag~`literal;  $[node[1]~`var; compVar[node;env]; compLit[node;oty]]
    tag~`transit;  compTrans[node;env;oty]
    tag~`apposit;  compAppos[node;env;oty]
    tag~`apply;    compApply[node;env;oty]
    tag~`list;     compList[node;env;oty]
    tag~`cond;     compCond[node;env;oty]
    tag~`right;    compNode[node[1];env;oty]   / parenthesised expression
    tag~`group;    compNode[node[1];env;oty]
    (0; oty)]}

/ ── Layer 3: sequential body with local bindings ──────────────────────────
/ stmts: list of statement nodes (seq/div markers already stripped)
/ For bind nodes (y: expr), compile rhs and extend env with name→result.
/ Returns (id; ty_sym) of the last expression.
compSeqTail: {[stmts; env; oty]
  s:   stmts[0]
  isb: (s[0]~`bind) & (3=#s)
  e2:  $[isb; ((!env),s[1][2])!(env[!env],(,compNode[s[2];env;oty])); env]
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

  label: newId[]
  fn:  (0x00050036; Tvoid; Fmain; 0; Tfunc; 0x000200F8; label)
  ret: (0x000100FD; 0x00010038)

  conWds: $[#Con; ,/Con; !0]
  bodWds: $[#Buf; ,/Buf; !0]

  ,/(hdr; cap; ext; mem; ep; exm; decIn; decOut; types; varIn; varOut; conWds; fn; bodWds; ret)
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

  lam: last parse $fn
  argName: (lam[1]@&~lam[1] in `args`div)[0]

  gidId:    newId[]; emitBuf opLoad[Tv3u32; gidId; gidVar]
  gidXId:   newId[]; emitBuf opXtract[Tu32; gidXId; gidId; 0]
  inPtrId:  newId[]; emitBuf opAccChain[Pf32s; inPtrId; inBuf; Ku32z; gidXId]
  xId:      newId[]; emitBuf opLoad[Tf32; xId; inPtrId]
  env:      (,argName)!(,(xId; `f32))
  bodySeq: lam[2]
  stmts:   bodySeq@&~bodySeq in `seq`div
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

/ ── Vertex shader stencils ────────────────────────────────────────────────────
opAccChain1: {[t;r;base;i] (0x00050041;t;r;base;i)}  / OpAccessChain single index
varOutOne:   {[ptr;vid]    (0x0004003B;ptr;vid;3)}    / OpVariable Output storage class

/ Helper: run stmts as binds building up env; return extended env (not last value).
/ Mirrors compSeqTail but returns env instead of the last compiled result.
compSeqEnvTail: {[stmts; env]
  s:   stmts[0]
  isb: (s[0]~`bind) & (3=#s)
  e2:  $[isb; ((!env),s[1][2])!(env[!env],(,compNode[s[2];env;`v4])); env]
  compSeqEnv[1_stmts; e2]}

compSeqEnv: {[stmts; env]
  $[0=#stmts; env; compSeqEnvTail[stmts; env]]}
