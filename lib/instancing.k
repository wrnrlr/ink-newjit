/ lib/instancing.k — instanced vertex shader (depends on lib/spirv.k).
/
/ Kept OUT of lib/spirv.k so non-instanced scenes don't pay its globals against
/ the VM's 256-global ceiling (see doc/bug.md): load this only when you actually
/ instance.  Pairs with lib/gpu.k's mesh.upload (retained geometry → persistent
/ vertex buffer) and mesh.drawInstanced (one draw, N instances).
/
/ Load:  2: "lib/dye.k"  and  2: "lib/gpu.k"  then  2: "lib/instancing.k"

/ FFI bindings for retained geometry + instancing (kept here, not in lib/gpu.k,
/ so non-instancing scenes stay under the 256-global ceiling). `so` is from gpu.k.
mesh.upload:    so 2: (`gpuUploadMesh;  2)   / (verts_F; handle) → geom : geometry → persistent vertex buffer
mesh.drawInstanced: so 2: (`gpuDrawInstanced;3)  / (geom; count; inst_F) → 0 : one draw of `count` instances
gpuDrawInstancedT0: so 2: (`gpuDrawInstancedT;3)  / (geom; (count,texHandles)_I; inst_F) → 0
gpuDrawGeomResident0: so 2: (`gpuDrawGeomResident;2)  / (geom; (count,bufHandle)_I) → 0
/ Readback-free instanced draw: per-instance vec4[] data is pulled from a RESIDENT
/ compute buffer (a solver's output) instead of a host upload — no round-trip.
mesh.drawResident: {[geom;cnt;buf] gpuDrawGeomResident0[geom; cnt,buf]}   / NB: not `count` (a keyword verb)
/ Instanced draw sampling shared textures at @group(1) (shader.instancedVertex +
/ shader.fragmentTexN). texs is an int vector of handles; all instances share them.
mesh.drawInstancedT: {[geom; num; texs; inst] gpuDrawInstancedT0[geom; num,texs; inst]}

/ Per-shader scratch (set per compile, read by the top-level loadInstMember —
/ ink lambdas can't see enclosing locals): storage struct member-0 const id,
/ StorageBuffer→vec4 pointer type, the buffer variable, and the precomputed base
/ index gl_InstanceIndex*K.
IKzero:: 0
IPssboV4:: 0
ISsbo:: 0
IInstBase:: 0
/ Load per-instance vec4 slot j: data[base + j] via OpAccessChain (member 0,
/ element index) + OpLoad.  base already = gl_InstanceIndex*K, so slot j is +j.
loadInstMember: {[j] jc:newId[]; emitCon opConst[Ti32;jc;j]; ix:newId[]; emitBuf opIadd[Ti32;ix;IInstBase;jc]; p:newId[]; emitBuf opAccChain[IPssboV4;p;ISsbo;IKzero;ix]; v:newId[]; emitBuf opLoad[Tv4;v;p]; (v;`v4)}

/ ── shader.instancedVertex[inTypes; varyTypes; instNames; fn] ────────────────
/ Like shader.vertex, but every draw is INSTANCED: per-instance data lives in a
/ read-only storage buffer at @set0/@binding0 (a flat `vec4 data[]`), and the
/ shader reads instance i's slot j as data[i*K + j] via gl_InstanceIndex (K =
/ #instNames).  Each instName becomes a v4 in the body.  The host uploads the
/ geometry ONCE (mesh.upload) and issues ONE draw of instanceCount=N (mesh.drawInstanced),
/ so an N-row table collapses to a single draw call.  Camera/material that are
/ "shared" are simply duplicated into every instance's slots by the caller.
shader.instancedVertex: {[inTypes; varyTypes; instNames; fn]
  Nid::Nfixed; Buf::(); Con::()

  lam:      lamOf fn
  argNames: lamArgs lam

  inTySyms: inTypes' argNames
  inPtrs:   PtrIn'   inTySyms
  inVarIds: {[x] newId[]}' argNames
  loadedPairs: inVarIds loadOnePair' inTySyms

  / gl_PerVertex block
  TperVtx:   newId[]
  PperVtx:   newId[]
  perVtxVar: newId[]
  Kzero:     newId[]
  emitCon opConst[Ti32; Kzero; 0]

  / Varyings
  varyNames:  !varyTypes
  varyTySyms: varyTypes' varyNames
  varyPtrs:   PtrOut' varyTySyms
  varyVarIds: {[x] newId[]}' varyNames
  nVary:      #varyVarIds

  / Instance storage buffer + gl_InstanceIndex
  nInst:   #instNames
  Trta:    newId[]   / OpTypeRuntimeArray vec4
  Tssbo:   newId[]   / OpTypeStruct { vec4[] }
  Pssbo:   newId[]   / OpTypePointer StorageBuffer Tssbo
  PssboV4: newId[]   / OpTypePointer StorageBuffer vec4
  PinI32:  newId[]   / OpTypePointer Input i32
  ssboVar: newId[]   / the storage buffer variable
  iidVar:  newId[]   / gl_InstanceIndex variable
  ICK:     newId[]; emitCon opConst[Ti32; ICK; nInst]   / constant K
  IKzero::Kzero; ISsbo::ssboVar; IPssboV4::PssboV4
  instIdx: newId[]; emitBuf opLoad[Ti32; instIdx; iidVar]
  ibase:   newId[]; emitBuf opImul[Ti32; ibase; instIdx; ICK]
  IInstBase::ibase
  instPairs: $[nInst>0; loadInstMember' !nInst; ()]
  env: $[nInst>0; (argNames,instNames)!(loadedPairs,instPairs); argNames!loadedPairs]

  / Body
  stmts:    lamBody lam
  env2:     compSeqEnv[-1_stmts; env]
  lastStmt: last stmts
  outElems: $[(nVary>0) & ((kKind lastStmt)~`list); kF[lastStmt;`elem]; ,lastStmt]

  glPosVal:       compNode[outElems[0]; env2; `v4]
  glPosMemberPtr: newId[]
  emitBuf opAccChain1[PoutV4; glPosMemberPtr; perVtxVar; Kzero]
  emitBuf opStore[glPosMemberPtr; glPosVal[0]]

  rp0: $[nVary>0; compNode[outElems[1]; env2; varyTySyms[0]]; (0;`f32)]
  $[nVary>0; emitBuf opStore[varyVarIds[0]; rp0[0]]; 0]
  rp1: $[nVary>1; compNode[outElems[2]; env2; varyTySyms[1]]; (0;`f32)]
  $[nVary>1; emitBuf opStore[varyVarIds[1]; rp1[0]]; 0]
  rp2: $[nVary>2; compNode[outElems[3]; env2; varyTySyms[2]]; (0;`f32)]
  $[nVary>2; emitBuf opStore[varyVarIds[2]; rp2[0]]; 0]

  / Assemble (SPIR-V 1.4: OpEntryPoint lists EVERY global variable, so the
  / instance storage buffer joins the I/O interface)
  bnd:   Nid+1
  iface: inVarIds,(,perVtxVar),varyVarIds,(,iidVar),(,ssboVar)

  hdr: (0x07230203; 0x00010400; 0; bnd; 0)
  cap: (0x00020011; 1)
  ext: (0x0006000B; Glsl; 0x4C534C47; 0x6474732E; 0x3035342E; 0)
  mem: (0x0003000E; 0; 1)
  ep:  (0x000F+(0x10000*(5+#iface)); 0; Fmain; 0x6E69616D; 0), iface

  decIn:   ,/ inVarIds decInOne' !#inVarIds
  decBlk:  (0x00030047; TperVtx; 2)
  decPos:  (0x00050048; TperVtx; 0; 11; 0)
  decVary: $[nVary>0; ,/ varyVarIds decInOne' !nVary; !0]
  / storage buffer: ArrayStride 16, Block, member-0 Offset 0 + NonWritable, set/binding 0; InstanceIndex builtin
  decInst: (0x00040047;Trta;6;16),(0x00030047;Tssbo;2),(0x00050048;Tssbo;0;35;0),(0x00040048;Tssbo;0;24),(0x00040047;ssboVar;34;0),(0x00040047;ssboVar;33;0),(0x00040047;iidVar;11;43)

  types:    (0x00020013;Tvoid;0x00020014;Tbool;0x00030016;Tf32;32;0x00040017;Tv4;Tf32;4;0x00040017;Tv2;Tf32;2;0x00040017;Tv3;Tf32;3;0x00040015;Ti32;32;1;0x00030021;Tfunc;Tvoid;0x00040020;PinF32;1;Tf32;0x00040020;PoutF32;3;Tf32;0x00040020;PinV4;1;Tv4;0x00040020;PoutV4;3;Tv4;0x00040020;PinV2;1;Tv2;0x00040020;PoutV2;3;Tv2;0x00040020;PinV3;1;Tv3;0x00040020;PoutV3;3;Tv3)
  vtxTypes: (0x0003001E;TperVtx;Tv4;0x00040020;PperVtx;3;TperVtx)
  instTypes:(0x0003001D;Trta;Tv4;0x0003001E;Tssbo;Trta;0x00040020;Pssbo;12;Tssbo;0x00040020;PssboV4;12;Tv4;0x00040020;PinI32;1;Ti32)

  varIn:     ,/ inPtrs varInOne' inVarIds
  varPerVtx: (0x0004003B; PperVtx; perVtxVar; 3)
  varVary:   $[nVary>0; ,/ varyPtrs varOutOne' varyVarIds; !0]
  varSsbo:   (0x0004003B; Pssbo; ssboVar; 12)   / OpVariable StorageBuffer
  varIid:    (0x0004003B; PinI32; iidVar; 1)    / OpVariable Input

  label: newId[]
  fn:  (0x00050036; Tvoid; Fmain; 0; Tfunc; 0x000200F8; label)
  ret: (0x000100FD; 0x00010038)

  conWds: $[#Con; ,/Con; !0]
  bodWds: $[#Buf; ,/Buf; !0]

  ,/(hdr;cap;ext;mem;ep;decIn;decBlk;decPos;decVary;decInst;types;vtxTypes;instTypes;varIn;varPerVtx;varVary;varSsbo;varIid;conWds;fn;bodWds;ret)
}
