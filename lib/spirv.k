/ lib/spirv.k — SPIR-V instruction stencils (the copy-and-patch "stencil library").
/
/ PURE, STATELESS layer: reserved type ids, type-id lookup tables, and one op*
/ function per SPIR-V instruction. Each op* returns the exact 32-bit words for one
/ instruction with the result-id / operand-id "holes" left for the caller to patch
/ (copy-and-patch, doc/papers/copy-and-patch.md). The dye compiler (lib/dye.k) holds
/ the id counter + word buffers and stitches these stencils into a module.
/
/ Split out of the old monolithic lib/spirv.k so the front-end/optimizer (dye) can
/ later target the ink VM too. See doc/design/dye.md.

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
opSdiv: {[t;r;a;b] (0x00050087;t;r;a;b)}   / OpSDiv  135 (signed integer divide, floor for >=0)
opSrem: {[t;r;a;b] (0x0005008A;t;r;a;b)}   / OpSRem  138 (signed remainder; == mod for >=0 operands)
opBitcast: {[t;r;a] (0x0004007C;t;r;a)}    / OpBitcast 124 (reinterpret bits, e.g. gid u32 -> i32)
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
opAtomicFAdd: {[t;r;ptr;sc;sem;v] (0x00071793;t;r;ptr;sc;sem;v)}  / OpAtomicFAddEXT 6035 (native f32 scatter-add; caps AtomicFloat32AddEXT)
/ Subgroup arithmetic reductions (caps GroupNonUniformArithmetic): Operation literal
/ 0=Reduce; sc = an <id> for the Subgroup(3) execution scope. (opcodes 350/352/355/358)
opGrpFAdd: {[t;r;sc;v] (0x0006015E;t;r;sc;0;v)}   / OpGroupNonUniformFAdd 350
opGrpFMul: {[t;r;sc;v] (0x00060160;t;r;sc;0;v)}   / OpGroupNonUniformFMul 352
opGrpFMin: {[t;r;sc;v] (0x00060163;t;r;sc;0;v)}   / OpGroupNonUniformFMin 355
opGrpFMax: {[t;r;sc;v] (0x00060166;t;r;sc;0;v)}   / OpGroupNonUniformFMax 358
opSelMrg:  {[m]        (0x000300F7;m;0)}          / OpSelectionMerge 247 (merge; None)
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
/ ── Compute stencil ──────────────────────────────────────────────────────────
opAccChain: {[t;r;base;m;i] (0x00060041;t;r;base;m;i)}
/ ── Vertex shader stencils ────────────────────────────────────────────────────
opAccChain1: {[t;r;base;i] (0x00050041;t;r;base;i)}  / OpAccessChain single index
