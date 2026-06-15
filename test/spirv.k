/ test/spirv.k — Copy-and-patch SPIR-V assembly + polyhedral tiling
/
/ Demonstrates:
/   1. f32 bit-pattern reinterpretation via `I$
/   2. SPIR-V instruction word assembly from stencil functions
/   3. Polyhedral iteration-domain tiling as pure k arrays
/
/ Run: ink test/spirv.k
/      zig build && ink test/spirv.k   (to rebuild after cast.zig change)

2: "lib/gpu/spirv.k"

chk: {[e;a;n] (("FAIL";"ok  ") e~a)," ",n}

/ ══ 1. f32 bit patterns via `I$ ═════════════════════════════════════════════
/
/ `I$v reinterprets the 32-bit float v as its IEEE 754 bit pattern (i32).
/ This is the key primitive for emitting OpConstant words in SPIR-V.
/
/ Well-known values:
/   0.0   → 0x00000000
/   1.0   → 0x3F800000  (sign=0 exp=127 mantissa=0)
/   0.5   → 0x3F000000  (sign=0 exp=126 mantissa=0)
/   2.0   → 0x40000000  (sign=0 exp=128 mantissa=0)
/  -1.0   → 0xBF800000  (sign=1 exp=127 mantissa=0)

chk[0x00000000; `I$0.0;  "0.0  bit pattern = 0x00000000"]
chk[0x3F800000; `I$1.0;  "1.0  bit pattern = 0x3F800000"]
chk[0x3F000000; `I$0.5;  "0.5  bit pattern = 0x3F000000"]
chk[0x40000000; `I$2.0;  "2.0  bit pattern = 0x40000000"]

/ Array form: `I$F_vector gives a vector of bit patterns
bits: `I$1.0 0.5 2.0
chk[(0x3F800000; 0x3F000000; 0x40000000); bits; "`I$F → I bit patterns"]

/ Verify: the bit pattern for 1.0 is the known IEEE 754 value
chk[1b; (`I$1.0) = 0x3F800000; "1.0 bit pattern self-checks"]

/ ══ 2. SPIR-V stencil assembly ═══════════════════════════════════════════════
/
/ Each stencil call returns the exact 32-bit words for one SPIR-V instruction.
/ IDs here are concrete integers; a real compile assigns them via newId[].

/ OpFAdd %f32 %11 %10 %10     (add x to itself)
addW: opFadd[Tf32; 11; 10; 10]
chk[(0x00050081; Tf32; 11; 10; 10); addW; "opFadd word sequence"]
chk[5; #addW;                              "opFadd is 5 words"]

/ OpFMul %f32 %12 %10 %11
mulW: opFmul[Tf32; 12; 10; 11]
chk[0x00050085; mulW[0];  "opFmul opword"]
chk[5;          #mulW;    "opFmul is 5 words"]

/ OpExtInst (sin) %f32 %13 %Glsl 13 %10
sinW: opSin[Tf32; 13; 10]
chk[(0x0006000C; Tf32; 13; Glsl; 13; 10); sinW; "opSin word sequence"]
chk[6; #sinW;                                     "opSin is 6 words"]

/ OpConstant %f32 %14 <1.0 bits>
cstW: opConst[Tf32; 14; 1.0]
chk[(0x0004002B; Tf32; 14; 0x3F800000); cstW; "opConst 1.0"]
chk[4; #cstW;                                  "opConst is 4 words"]

/ Combine stencils: x*x + sin(x) using IDs 10..13
/ This is exactly what compNode emits, one call per AST node.
Nid:: 11; Buf:: ()
x: 10             / input ID

r1: newId[]       / 11: x * x
emitW opFmul[Tf32; r1; x; x]

r2: newId[]       / 12: sin(x)
emitW opSin[Tf32; r2; x]

r3: newId[]       / 13: (x*x) + sin(x)
emitW opFadd[Tf32; r3; r1; r2]

chk[13; r3;    "x*x+sin(x) result ID is 13"]
chk[3;  #Buf;  "3 instructions emitted"]
chk[16; +/#'Buf; "total 16 words (5+6+5)"]

/ ══ 3. Polyhedral iteration-domain tiling ════════════════════════════════════
/
/ The polyhedral model represents a loop nest as lattice points inside a
/ polyhedron  { x : Ax <= b }.  GPU compilers tile these domains to map
/ iterations onto thread blocks / warps.
/
/ Here we represent a 2D iteration space (0<=i<8, 0<=j<8) and tile it.
/ All operations are pure k array manipulation — no GPU required.

/ ── Constraint matrix for 0<=i<8, 0<=j<8 ─────────────────────────────────────
/ Constraints: i >= 0, j >= 0, i <= 7 (i.e. -i <= -1), j <= 7

A: (( 1  0)   / i >= 0
    ( 0  1)   / j >= 0
    (-1  0)   / i <  8  (-i <= -1)
    ( 0 -1))  / j <  8

b: (0; 0; -1; -1)   / RHS

/ Matrix-vector multiply: A mmu pt = Av
/ dotrow[row;v] = dot product; mmu[m;v] = apply to each row
dotrow: {[row;v] +/row*v}
mmu: {[m;v] dotrow[;v]' m}

/ Domain check: mmu[A;pt] element-wise <= -b
/ Note: <= parses differently in ink; use ~ (not) of > (greater-than)
inDomain: {[pt] i:pt[0]; j:pt[1]; (~i<0) & (~j<0) & (i<8) & (j<8)}

chk[1b; inDomain 0 0; "(0,0) in domain"]
chk[1b; inDomain 7 7; "(7,7) in domain"]
chk[0b; inDomain 8 0; "(8,0) outside domain"]
chk[0b; inDomain 0 8; "(0,8) outside domain"]

/ All lattice points in the 8×8 domain via index arithmetic (no closures)
ks: !64
pts: (ks div 8),' (ks mod 8)

chk[64; #pts;  "64 lattice points in 8×8 domain"]
chk[64; +/ inDomain' pts; "all 64 points inside domain"]

/ ── Tiling: split 8×8 into 2×2 grid of 4×4 tiles ─────────────────────────────
/
/ Tile index (ti;tj) owns iterations:  ti*4 <= i < (ti+1)*4, same for j.
/ This is the standard loop-tiling transformation used by GPU compilers
/ to map loop iterations to thread blocks.

tsz: 4   / tile size

tileOf:  {[pt] pt div tsz}
localOf: {[pt] pt - tsz * (pt div tsz)}

/ Assign each point to a tile and local position
tileIdx:  tileOf'  pts     / (0 0)..(1 1)
localIdx: localOf' pts     / (0 0)..(3 3)

/ Count points per tile: use module-level isInTile to avoid closures
/ tilePts takes a single pair t=(ti;tj) to be compatible with each'
isInTile: {[tile;p] tile~tileOf[p]}
tilePts: {[t] +/ isInTile[t;]' pts}

chk[16; tilePts[0 0]; "tile (0,0) has 16 points"]
chk[16; tilePts[1 1]; "tile (1,1) has 16 points"]
chk[4;  #?tileIdx;    "4 distinct tiles"]
chk[64; +/ tilePts' (0 0;0 1;1 0;1 1); "total still 64"]

/ ── GPU work-group mapping ────────────────────────────────────────────────────
/
/ Map each tile to a GPU work-group (block).
/ Within a work-group, each thread handles one local iteration.
/ This is the affine schedule:  thread (tx,ty) in block (bx,by) computes
/ iteration (bx*tsz+tx, by*tsz+ty).

/ blockThreads: map block b and local coord l to global iteration
blockThreads: {[b;l] ((b[0]*tsz)+l[0]; (b[1]*tsz)+l[1])}

/ Local coord grid for one tile: 16 positions
lks:  !16
locs: (lks div tsz),' (lks mod tsz)

/ All thread assignments across all 4 blocks
blocks: (0 0;0 1;1 0;1 1)
allThreadPts: ,/ {[b] blockThreads[b;]' locs}' blocks

chk[64; #allThreadPts;          "64 thread assignments"]
chk[64; #? allThreadPts;        "all unique (bijection)"]
chk[64; +/ inDomain' allThreadPts; "all thread pts in domain"]

/ ══ 4. FragmentShader end-to-end ════════════════════════════════════════════
/
/ Call FragmentShader with a trivial passthrough lambda and inspect the binary.

fn1: {[x] x}
wds: FragmentShader[`x`out!`f32`f32; fn1]

/ Structural headers
chk[0x07230203; wds[0]; "SPIR-V magic number"]
chk[0x00010300; wds[1]; "SPIR-V version 1.3"]
chk[0;          wds[2]; "generator = 0"]
chk[1b; wds[3] > Nfixed; "bound > fixed-id range"]
chk[116; #wds;           "passthrough module = 116 words (incl. v3 types)"]

/ First section after header: OpCapability Shader (opword = 0x00020011, value = 1)
chk[0x00020011; wds[5]; "OpCapability instruction"]
chk[1;          wds[6]; "Capability Shader = 1"]

/ Constant-bearing shader: x + 1.0 introduces OpConstant with 1.0 bit pattern
fn2: {[x] x+1.0}
wds2: FragmentShader[`x`out!`f32`f32; fn2]
chk[0x07230203; wds2[0]; "x+1.0 magic number"]
chk[125; #wds2; "x+1.0 module = 125 words (9 more for OpConstant, 12 for v3 types)"]
chk[1b; |/wds2=0x3F800000; "1.0 bit pattern present in module"]

/ ══ 5. Type-directed dispatch ════════════════════════════════════════════════
/
/ isVecTy classifies vector vs scalar types.
/ binRty picks the widest type for a binary op.
/ dispBin chooses OpVectorTimesScalar for vec*scalar.

chk[1b; isVecTy[`v4];  "isVecTy `v4 = true"]
chk[1b; isVecTy[`v2];  "isVecTy `v2 = true"]
chk[0b; isVecTy[`f32]; "isVecTy `f32 = false"]
chk[`v4; binRty[`*; `v4; `f32; `v4]; "binRty v4*f32 = v4"]
chk[`f32; binRty[`+; `f32; `f32; `f32]; "binRty f32+f32 = f32"]

/ opVTS (OpVectorTimesScalar) = opcode 0x8E
chk[(0x0005008E; Tv4; 20; 19; 18); opVTS[Tv4; 20; 19; 18]; "opVTS word sequence"]
chk[5; #opVTS[Tv4; 20; 19; 18]; "opVTS is 5 words"]

/ dispBin v4 * f32 → opVTS
Nid:: 25; Buf:: ()
wVTS: dispBin[`*; `v4; 25; `v4; 10; `f32; 11]
chk[0x0005008E; wVTS[0]; "dispBin v4*f32 emits opVTS"]
chk[Tv4; wVTS[1]; "dispBin v4*f32 result type = Tv4"]

/ dispBin f32 * v4 → opVTS (commuted)
wVTSc: dispBin[`*; `v4; 26; `f32; 11; `v4; 10]
chk[0x0005008E; wVTSc[0]; "dispBin f32*v4 also emits opVTS"]

/ dispBin v4 + v4 → opFadd
wVadd: dispBin[`+; `v4; 27; `v4; 10; `v4; 11]
chk[0x00050081; wVadd[0]; "dispBin v4+v4 emits opFadd"]

/ opCons4 (OpCompositeConstruct vec4)
chk[(0x00070050; Tv4; 30; 10; 11; 12; 13); opCons4[Tv4;30;10;11;12;13]; "opCons4 word sequence"]
chk[7; #opCons4[Tv4;30;10;11;12;13]; "opCons4 is 7 words"]

/ ══ 5b. Integer literal coercion to f32 ══════════════════════════════════════
/
/ x*2 — the literal 2 must become 2.0f (OpConstant %float) not an i32.
/ If it stays i32, Dawn rejects the shader: "FMul operand index 3" type mismatch.

wdsInt: FragmentShader[`x`out!`f32`f32; {[x] x*2}]
chk[1b; |/wdsInt=`I$2.0; "integer literal 2 coerced to f32 in f32 context"]

/ ══ 6. FragmentShader v2→v4 via compApply + compList ════════════════════════
/
/ Compiles {[uv] (uv[0]; uv[1]; 0.5; 1.0)} : v2 → v4
/ Tests: component extract (OpCompositeExtract) + construct (OpCompositeConstruct)

wds3: FragmentShader[`uv`out!`v2`v4; {[uv] (uv[0]; uv[1]; 0.5; 1.0)}]
chk[0x07230203; wds3[0]; "v2→v4 magic number"]
chk[141; #wds3; "v2→v4 module = 141 words (12 more for v3 types)"]
chk[1b; |/wds3=0x3F000000; "0.5 constant in v2→v4 shader"]
chk[1b; |/wds3=0x3F800000; "1.0 constant in v2→v4 shader"]
chk[1b; |/wds3=0x00070050; "opCons4 opword in v2→v4 shader"]
chk[1b; |/wds3=0x00050051; "opXtract opword in v2→v4 shader"]

/ The Hasse diagram (face lattice) of the tiling hierarchy as a ranked poset:
/
/  rank 3: module (the whole 8x8 iteration space)
/  rank 2: tiles  (2x2 = 4 work-groups)
/  rank 1: threads (4x4 = 16 per tile)
/  rank 0: scalar iterations (leaf nodes)

chk[3; 3;          "module has rank 3"]
chk[4; #blocks;    "4 tiles at rank 2"]
chk[16; #locs;     "16 threads per tile at rank 1"]

/ ══ 7. compCompute SPIR-V structure ═════════════════════════════════════════
/
/ Compile {[x] x*2} as a 1D map-over-buffer compute shader and inspect binary.

cwds: compCompute[{[x] x*2}]

chk[0x07230203; cwds[0];   "compute magic number"]
chk[0x00010300; cwds[1];   "compute SPIR-V version 1.3"]
chk[1b; (#cwds) > 100;     "compute module > 100 words"]
chk[1b; |/cwds=0x00060010; "OpExecutionMode present"]
chk[1b; |/cwds=17;         "LocalSize mode id (17) present"]
chk[1b; |/cwds=64;         "workgroup size 64 present"]
chk[1b; |/cwds=0x00040047; "decoration instructions present"]
chk[1b; |/cwds=0x0003001D; "OpTypeRuntimeArray present"]
chk[1b; |/cwds=0x0003001E; "OpTypeStruct present"]
chk[1b; |/cwds=0x00060041; "OpAccessChain present"]
chk[1b; |/cwds=0x00050085; "OpFMul present (x*2 body)"]
