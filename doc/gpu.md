# GPU Shader Compilation in ink

Write vertex, fragment, and compute shaders in ink and run them on the GPU via Dawn/WebGPU.  A restricted subset of the language compiles to SPIR-V — the binary IR Dawn accepts — without going through WGSL.  The compiler itself is written in ink, operating on the AST produced by the `parse` verb.

---

## Copy-and-patch vs TPDE

TPDE (see `doc/TPDE.pdf`) is a single-pass native-code back-end framework: it performs liveness analysis, register allocation, and instruction encoding in one pass to produce x86-64 or AArch64 machine code.  None of that applies here:

**SPIR-V is already SSA.**  Every value has a unique 32-bit ID assigned by the compiler.  Physical registers do not exist in SPIR-V; the GPU driver allocates them when it lowers SPIR-V to GPU machine code.  The core value of TPDE — greedy register allocation across live ranges — does not exist in the problem.

**We target GPU, not CPU.**  TPDE's snippet encoders extract instruction sequences from LLVM Machine IR and emit x86 / AArch64 bytes.  We want a flat sequence of 32-bit words that Dawn hands to Metal or Vulkan.

**TPDE is a C++ framework.**  We want the entire shader compiler to live in k.

The main weakness of copy-and-patch (fixed register slots → excessive moves and spills) disappears for SPIR-V precisely because the format has no physical registers.  Copy-and-patch is the right fit.

---

## Copy-and-patch for SPIR-V

A SPIR-V instruction is a fixed-length sequence of 32-bit words:

```
word 0:   (wordCount << 16) | opcode
word 1:   result_type  (ID of the type of the result)
word 2:   result_id    (fresh ID assigned by the compiler)
word 3+:  operand IDs, literals, ...
```

Each operation in the ink subset maps to a **stencil** — a known word pattern with ID slots.  Compilation is a one-pass tree walk:

```
ink expression string
  → parse                          (built-in verb; produces terse AST)
  → compExpr[ast; env]             (tree walk in k)
       for each AST node:
         newId[]                   (bump global counter)
         Op[verb][type; r; a; b]   (call stencil fn → word list)
         append to Buf             (accumulate function body)
  → buildModule[stage; ioSig]      (prepend frame, patch bound)
  → flat int list (SPIR-V)
  → gpuSpirv[words; `frag]         (Zig → Dawn pipeline, returns handle)
```

No register allocation, no scheduling, no liveness analysis.

---

## The ink shader subset

### Types

| ink symbol | SPIR-V | bits |
|---|---|---|
| `` `f32 `` | `OpTypeFloat 32` | 32 |
| `` `i32 `` | `OpTypeInt 32 1` | 32 |
| `` `bool `` | `OpTypeBool` | — |
| `` `v2 `` | `OpTypeVector f32 2` | 64 |
| `` `v4 `` | `OpTypeVector f32 4` | 128 |

### Scalar verbs

| ink | SPIR-V opcode | op |
|---|---|---|
| `+` | `OpFAdd` (129) / `OpIAdd` (128) | add |
| `-` | `OpFSub` (131) / `OpISub` (130) | subtract |
| `*` | `OpFMul` (133) / `OpIMul` (132) | multiply |
| `%` | `OpFDiv` (136) | divide |
| `neg` | `OpFNegate` (127) | negate |
| `sin` | `OpExtInst GLSL 13` | sine |
| `cos` | `OpExtInst GLSL 14` | cosine |
| `sqrt` | `OpExtInst GLSL 31` | square root |

### Fused adverbs (vector reductions)

| ink | SPIR-V | note |
|---|---|---|
| `+/` sum | `OpDot v (1 1 1 1)` | scalar result |
| `*/` product | sequential `OpFMul` over components | |
| `<./` min | `OpExtInst GLSL FMin` (37) | pairwise |
| `>./` max | `OpExtInst GLSL FMax` (40) | pairwise |

---

## SPIR-V module structure

A module is a flat word list in this order:

```
header          5 words   magic, version, generator, bound, schema
capabilities              OpCapability Shader
extensions                OpExtInstImport "GLSL.std.450"
memory model              OpMemoryModel Logical GLSL450
entry point               OpEntryPoint Fragment %main "main" <vars>
execution mode            OpExecutionMode %main OriginUpperLeft
decorations               OpDecorate (Location bindings for I/O)
type declarations         void, f32, v4, v2, bool, i32, pointer types, function type
constant declarations     compiled from literal nodes
I/O variables             OpVariable for each input / output
function body             OpFunction … OpLabel … <stencil emissions> … OpReturn OpFunctionEnd
```

### Reserved IDs (fixed in the frame)

| ID | role |
|---|---|
| 1 | `void` type |
| 2 | `void ()` function type |
| 3 | `f32` type |
| 4 | `vec4<f32>` type |
| 5 | `vec2<f32>` type |
| 6 | `bool` type |
| 7 | `i32` type |
| 8 | GLSL.std.450 extended instruction set |
| 9 | `main` entry-point function |

Dynamic IDs (constants, temporaries, I/O variables) start at 10.

---

## Stencil library (`lib/gpu/spirv.k`)

Each stencil is a function that takes resolved IDs and returns the SPIR-V word list for one instruction.  No patching pass is needed — calling the function with real IDs is the patch step.

```k
/ Binary float ops: (type; result; a; b) → words
opFadd: {[t;r;a;b] (0x00050081;t;r;a;b)}
opFsub: {[t;r;a;b] (0x00050083;t;r;a;b)}
opFmul: {[t;r;a;b] (0x00050085;t;r;a;b)}
opFdiv: {[t;r;a;b] (0x00050088;t;r;a;b)}

/ Unary via GLSL extended instructions: (type; result; operand) → words
/ word structure: OpExtInst type result set=8 instruction operand
opSin:  {[t;r;a] (0x0006000C;t;r;8;13;a)}
opCos:  {[t;r;a] (0x0006000C;t;r;8;14;a)}
opSqrt: {[t;r;a] (0x0006000C;t;r;8;31;a)}

/ Verb dispatch table
Op: [`+:opFadd; `-:opFsub; `*:opFmul; `%:opFdiv; `sin:opSin; `cos:opCos; `sqrt:opSqrt]
```

The compiler maintains two mutable globals during a single shader compile:

```k
Nid: 10    / next free SPIR-V ID (reset per shader)
Buf: ()    / accumulated word list (reset per shader)
```

Tree walk (sketch):

```k
newId: {[] Nid+:1; Nid-1}
emitW: {[ws] Buf,: ws}

compExpr: {[node; env]
  tag: node[0]
  $[tag=`literal;
      [r: newId[]
       emitW (0x0004002B; Tid[node[1]]; r; f32bits node[2])   / OpConstant
       r];
    tag=`name;
      env[node[1]];                                            / look up variable ID
    tag=`transit;
      [a: compExpr[node[1]; env]
       b: compExpr[node[3]; env]
       r: newId[]
       emitW Op[node[2]][3; r; a; b]                          / 3 = Tf32
       r];
    0
  ]
}
```

`f32bits` needs a native helper to reinterpret a float value as its 32-bit IEEE 754 bit pattern (a single i32 word for `OpConstant`).

---

## Zig changes

### New KApi entry

Add `kip` (int32 array pointer) to `KApi` in `src/main.zig`:

```zig
kip: *const fn (?K) callconv(.c) ?[*]i32,
```

### `gpuSpirv` export

```zig
// gpuSpirv[words_I; stage_sym] → shader handle i32, or -1 on error
export fn gpuSpirv(words: ?K, stage: ?K) callconv(.c) ?K {
    const r = g_renderer orelse return ki(-1);
    const p = kip(words) orelse return ki(-1);
    const n: u32 = @intCast(kn(words));

    const spirv_desc = wgpu.ShaderModuleSPIRVDescriptor{
        .code_size = n,
        .code = @ptrCast(p),
    };
    const wgsl_desc = wgpu.ShaderModuleDescriptor{
        .next_in_chain = @ptrCast(&spirv_desc),
    };
    const sm = r.device.createShaderModule(wgsl_desc);
    defer sm.release();

    // createRenderPipeline with same bind group layout as fill.wgsl
    // then r.custom_pipelines.append(pipeline)
    // return ki(@intCast(r.custom_pipelines.items.len))
    _ = stage;
    return ki(-1); // TODO
}
```

### `gpu.k` addition

```k
gpuSpirv: so 2: (`gpuSpirv; 2)   / (spirv_I; stage_sym) → handle
```

---

## End-to-end usage

```k
2: "lib/gpu/spirv.k"

/ Compile a fragment shader: maps position to a color
sh: compShader["p[0]*p[1]"; [`p:`v4]; `f32]

gpuRun[{[props]
  gpuFill[verts; gpuSolid[0. 0. 0. 1.]]    / background
  gpuFillShader[verts; sh]                   / custom shader
}; 800. 600.]
```

---

## `I$` — f32 bit pattern

`` `I$v `` reinterprets the 32-bit float `v` as its IEEE 754 bit pattern (an `i32`).  Implemented as `@bitCast(f32 → i32)` in `castFloat` / `castFloats` in `src/primitive/verb/cast.zig`.

```
`I$1.0  → 0x3F800000
`I$0.5  → 0x3F000000
`I$2.0  → 0x40000000
`I$F    → I    (vector form)
```

`opConst` in `spirv.k` uses this directly: `opConst: {[t;r;v] (0x0004002B;t;r;`I$v)}`.

## I/O variable inference

Shader inputs are inferred from lambda argument names combined with a type dict.  `` $lambda `` gives the source string; the arg list is between `[...]`.

```k
/ Define shader as an ordinary ink lambda
shader: {[pos uv] pos * uv}

/ Declare types for each argument and the output
ioTypes: [`pos:`v4; `uv:`v2; `out:`v4]

/ Compile: arg names + types → OpVariable declarations in the frame
words: compShader[shader; ioTypes]
handle: gpuSpirv[words; `frag]
```

Each named arg gets a pointer type variable in Input storage class with a `Location` decoration.  The `out` key gets an Output variable.  `inputIds` in `spirv.k` assigns the SPIR-V IDs.

## Compute shaders as IPC

Compute shaders can be modelled as remote ink processes — identical to the existing k IPC pattern — with the GPU instance receiving an ink expression and storage buffer bindings:

```k
/ Open a GPU compute channel (like <` opens a k process)
gpu: <`gpu

/ Send a shader expression + data binding
gpu 2: "X: 1 2 3; reduce[+; X]"

/ Read back the result
result: gpu 1: ""
```

The GPU process receives k code as a string, compiles it to a compute shader via `spirv.k`, dispatches it on the bound storage buffers, and returns a scalar or array result.  This maps directly onto the WebGPU compute pipeline:

```
send k string → compShader → gpuSpirv → ComputePipeline
                                       → dispatch (workgroups)
                                       → mapAsync result buffer → result k value
```

## Polyhedral data layout (future)

The polyhedral model represents loop iteration spaces as integer polyhedra `Ax ≤ b` and applies affine transformations to tile, fuse, and schedule iterations.  This is directly applicable to GPU buffer layout:

- **Tiling**: cut the iteration domain into GPU work-group sized tiles
- **Coalescing**: reorder the access pattern so adjacent threads read adjacent memory
- **Shared memory**: identify reuse across a tile; emit a load into workgroup memory

In k, an iteration domain is a constraint matrix `A` and bounds vector `b`; tiles are sub-polyhedra; the full hierarchy (`module → tile → thread → scalar`) is a ranked poset — the face lattice of the tiling polytope.  See `test/spirv.k` for a worked example.

The abstract polytope structure (Hasse diagram as `(lower; upper)` incidence lists) is the natural k representation of this hierarchy, and it maps directly to the `@workgroup_id`, `@local_invocation_id`, and `@global_invocation_id` builtins in a WGSL/SPIR-V compute shader.

## Open questions

- I/O signature: actually parsing `` $fn `` to extract arg names reliably; handling closures.
- Type-directed dispatch: `+` on `` `v4 `` should emit element-wise `OpFAdd`, not scalar.  Need type inference in `compExpr`.
- Constant deduplication: `OpConstant` must appear before the function body in SPIR-V; need a two-pass approach or a constants cache.
- Compute pipeline: `gpuSpirv` currently only handles render pipelines; need a separate `gpuCompute` path with storage buffer bind group layout.
