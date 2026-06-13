# GPU Shader Compilation in ink

Write vertex, fragment, and compute shaders in ink lambdas and run them on the GPU via Dawn/WebGPU. A restricted subset of the language compiles to SPIR-V — the binary IR Dawn accepts — without going through WGSL. The compiler lives entirely in `lib/gpu/spirv.k`.

---

## Quick start

```k
/ Build the GPU library first: zig build gpu
2: "lib/gpu/spirv.k"
2: "lib/gpu/gpu.k"

/ Fragment shader: maps UV coordinates to RGBA color
spirvWds: compShader[{[uv] (uv[0]; uv[1]; 0.5; 1.0)}; [`uv:`v2; `out:`v4]]

/ Compute shader: doubles every element
computeWds: compCompute[{[x] x*2}]

/ Full-screen quad [x y u v] x 6 vertices
verts: 0. 0. 0. 0. 800. 0. 1. 0. 800. 600. 1. 1. 0. 0. 0. 0. 800. 600. 1. 1. 0. 600. 0. 1.

handle:: 0
result:: ()
loop: {[props]
  $[handle=0; handle:: gpuSpirv[spirvWds; 0]; 0]
  $[0=#result; result:: gpuCompute[computeWds; 1. 2. 3. 4.]; 0]
  gpuFillShader[verts; handle]}

gpuRun[loop; 0]
```

---

## API reference

### `lib/gpu/gpu.k` — runtime bindings

Load with `2: "lib/gpu/gpu.k"` (requires `zig build gpu` first).

| Function | Signature | Description |
|---|---|---|
| `gpuRun` | `(loop_fn; config)` | Blocking event loop. Calls `loop_fn[props]` each frame. `config` = 0 for defaults (800x600). |
| `gpuFill` | `(verts_F; frag_F)` | Draw triangles using the built-in fill shader. `verts_F`: flat f32 `[x y u v ...]`, stride 4. `frag_F`: 44 floats (FragUniforms). Call inside frame callback. |
| `gpuTess` | `pts_F` | Tessellate a polygon outline into triangle vertices. Input: flat `[x0 y0 x1 y1 ...]`. Returns flat `[x y u v ...]`. |
| `gpuSolid` | `(r; g; b; a)` | Produce 44-float FragUniforms for a solid color. Pass to `gpuFill`. |
| `gpuSpirv` | `(spirv_I; 0)` | Compile a SPIR-V fragment shader binary (int list) into a render pipeline. Returns a negative integer handle. Must be called inside the frame callback. |
| `gpuFillShader` | `(verts_F; handle)` | Draw triangles using a custom SPIR-V pipeline. `handle` is the value returned by `gpuSpirv`. |
| `gpuCompute` | `(spirv_I; input_F)` | Run a compute shader on `input_F` (float list). Returns a new float list of the same length. Must be called inside the frame callback. |

### `props` dict (frame callback argument)

| Key | Type | Description |
|---|---|---|
| `width` | f32 | Framebuffer width in pixels |
| `height` | f32 | Framebuffer height in pixels |
| `mx` | f32 | Mouse X in pixels (DPI-scaled) |
| `my` | f32 | Mouse Y in pixels (DPI-scaled) |
| `time` | f32 | Elapsed seconds since loop start |

---

## Shader compiler API (`lib/gpu/spirv.k`)

Load with `2: "lib/gpu/spirv.k"`.

### `compShader[fn; ioTypes]` → SPIR-V word list

Compiles an ink lambda into a **fragment shader**.

- `fn`: ink lambda. Arguments become shader inputs; return value becomes the output.
- `ioTypes`: dict mapping each argument name to its type symbol, plus `` `out `` for the return type.
- Returns: int list (SPIR-V binary, 32-bit words).

```k
/ Passthrough: f32 -> f32
compShader[{[x] x}; [`x:`f32; `out:`f32]]

/ UV gradient: v2 -> v4
compShader[{[uv] (uv[0]; uv[1]; 0.5; 1.0)}; [`uv:`v2; `out:`v4]]

/ Math: f32 -> f32
compShader[{[x] sin x * 0.5}; [`x:`f32; `out:`f32]]

/ Integer literals coerced to f32 automatically
compShader[{[x] x*2}; [`x:`f32; `out:`f32]]
```

### `compCompute[fn]` → SPIR-V word list

Compiles an ink lambda into a **1D map-over-buffer compute shader**.

- `fn`: ink lambda with a single f32 argument. Result must be f32.
- Generated shader: reads from binding 0, writes to binding 1, workgroup size 64.
- Returns: int list (SPIR-V binary).

```k
compCompute[{[x] x*2}]       / double each element
compCompute[{[x] sin x}]     / sine of each element
compCompute[{[x] x*x+1.0}]   / polynomial
```

### Type symbols

| Symbol | SPIR-V type | Bytes |
|---|---|---|
| `` `f32 `` | `OpTypeFloat 32` | 4 |
| `` `i32 `` | `OpTypeInt 32 1` | 4 |
| `` `bool `` | `OpTypeBool` | - |
| `` `v2 `` | `OpTypeVector f32 2` | 8 |
| `` `v4 `` | `OpTypeVector f32 4` | 16 |

### Supported ink expressions

| Ink | Maps to | Notes |
|---|---|---|
| `x + y` | `OpFAdd` | Scalar or vector |
| `x - y` | `OpFSub` | |
| `x * y` | `OpFMul` / `OpVectorTimesScalar` | Auto-selects VTS for vec*scalar |
| `x % y` | `OpFDiv` | Note: `%` is division in ink |
| `sin x` | `OpExtInst GLSL sin` (13) | |
| `cos x` | `OpExtInst GLSL cos` (14) | |
| `sqrt x` | `OpExtInst GLSL sqrt` (31) | |
| `v[0]` | `OpCompositeExtract` | f32 component of v2/v4 |
| `(a;b;c;d)` | `OpCompositeConstruct vec4` | 4-tuple -> v4 output |
| `1.0`, `0.5` | `OpConstant f32` | Float literals |
| `2`, `3` | `OpConstant f32` | Integer literals coerced to f32 in f32 context |

---

## Architecture

### Compiler layers (Tiramisu model)

```
Layer I  (Abstract Algorithm)  : ink lambda AST via `parse`
Layer II (Computation Mgmt)    : type annotation, IO resolution
Layer III (Data Mgmt)          : SPIR-V ID allocation, instruction emission
Layer IV (Communication Mgmt)  : module assembly in SPIR-V spec order
```

### Copy-and-patch

SPIR-V is already in SSA form — every value has a unique 32-bit ID, physical registers do not exist. Copy-and-patch is the right fit: each AST node maps to a fixed-shape stencil function; calling it with real IDs is the "patch" step. No register allocation, no scheduling.

```k
opFadd: {[t;r;a;b] (0x00050081;t;r;a;b)}   / (wordCount<<16)|opcode ; type ; result ; a ; b
opFmul: {[t;r;a;b] (0x00050085;t;r;a;b)}
opSin:  {[t;r;a]   (0x0006000C;t;r;Glsl;13;a)}
opCons4:{[t;r;a;b;c;d](0x00070050;t;r;a;b;c;d)}  / OpCompositeConstruct vec4
```

### Compiler state (reset per shader call)

```k
Nid:: Nfixed   / next free SPIR-V ID (IDs 1-15 are fixed, dynamic starts at 16)
Buf:: ()       / function body instructions (list of word lists)
Con:: ()       / constant declarations (emitted before the function body)
```

### Reserved IDs (1-15, fixed in every module)

| ID | Name | Role |
|---|---|---|
| 1 | `Tvoid` | `OpTypeVoid` |
| 2 | `Tfunc` | `OpTypeFunction void()` |
| 3 | `Tf32` | `OpTypeFloat 32` |
| 4 | `Tv4` | `OpTypeVector f32 4` |
| 5 | `Tv2` | `OpTypeVector f32 2` |
| 6 | `Tbool` | `OpTypeBool` |
| 7 | `Ti32` | `OpTypeInt 32 1` |
| 8 | `Glsl` | GLSL.std.450 extended instruction set |
| 9 | `Fmain` | `main` entry-point function |
| 10 | `PinF32` | `OpTypePointer Input f32` |
| 11 | `PoutF32` | `OpTypePointer Output f32` |
| 12 | `PinV4` | `OpTypePointer Input v4` |
| 13 | `PoutV4` | `OpTypePointer Output v4` |
| 14 | `PinV2` | `OpTypePointer Input v2` |
| 15 | `PoutV2` | `OpTypePointer Output v2` |
| 16 | `Nfixed` | First dynamic ID |

### Fragment shader module layout (SPIR-V 1.3 spec order)

```
header          5 words   magic 0x07230203, version 0x00010300, generator=0, bound, schema=0
OpCapability    2 words   Shader (1)
OpExtInstImport 6 words   "GLSL.std.450"
OpMemoryModel   3 words   Logical GLSL450
OpEntryPoint    5+n words Fragment(4), %main, "main", [Input/Output var IDs]
OpExecutionMode 3 words   OriginUpperLeft(7)
decorations               Location for each I/O variable
type decls                void, bool, f32, v4, v2, i32, pointer types, function type
constants                 OpConstant for each literal in the body (from Con)
I/O variables             OpVariable per input (Input) and output (Output)
function body             OpFunction, OpLabel, <body from Buf>, OpReturn, OpFunctionEnd
```

### Compute shader module layout (SPIR-V 1.3 spec order)

```
header, OpCapability, OpExtInstImport, OpMemoryModel
OpEntryPoint    GLCompute(5), %main, "main", [gidVar]  <- ONLY Input vars in SPIR-V 1.3
OpExecutionMode LocalSize 64 1 1
decorations:    BuiltIn(28) for gidVar, ArrayStride(4) for Trta,
                Block for Tbuf, DescriptorSet/Binding for inBuf/outBuf
type decls:     shared types + u32, vec3<u32>, RuntimeArray<f32>, struct{RuntimeArray}, pointers
variables:      gidVar (Input), inBuf (StorageBuffer, set=0 binding=0),
                outBuf (StorageBuffer, set=0 binding=1)
function body:  load gid, extract x, access inBuf[x], load element,
                <user expression>, access outBuf[x], store result
```

---

## Pipeline handles

| Handle value | Pipeline type |
|---|---|
| 0 | Default fill.wgsl render pipeline |
| > 0 | Custom WGSL pipeline (from `Renderer.createShader`) |
| < 0 | SPIR-V render pipeline (from `gpuSpirv`); index = `(-handle) - 1` in `spirv_pipelines` |

`gpuSpirv` and `gpuCompute` must be called inside a `gpuRun` frame callback — they access `g_renderer` which is only set during the callback. `gpuSpirv` returns a handle that is stable across frames; call it once, cache the result in a global.

---

## Vertex format

All draw calls (`gpuFill`, `gpuFillShader`) expect a flat f32 array with stride 4: `[x y u v x y u v ...]`. Coordinates `x,y` are window pixel coordinates (origin top-left). `u,v` are passed to the fragment shader as `@location(0) ftcoord: vec2f` by `fill.wgsl`'s vertex stage.

---

## `I$` — f32 bit pattern cast

`` `I$v `` reinterprets a float as its 32-bit IEEE 754 bit pattern (i32). Used by `opConst` to embed literal float constants as SPIR-V words.

```
`I$0.0  -> 0x00000000
`I$1.0  -> 0x3F800000
`I$0.5  -> 0x3F000000
`I$2.0  -> 0x40000000
`I$F    -> I    (vector form: cast each element)
```

`opConst` uses this: `opConst: {[t;r;v] (0x0004002B;t;r;$[t=Tf32;\`I$v;v])}`.

---

## Known bugs and gotchas

**Underscores in global names cause silent failure.** Global variable names with underscores (e.g. `wds_int`, `Ku32_0`) store `!type` instead of the value. The `_` glyph is the Drop verb in ink, so `foo_bar` parses as `foo _ bar`. Use camelCase for all top-level names. Local variables inside a lambda body can use underscores safely.

**Newlines inside `(...)` inject null words.** Multi-line list literals insert a null element per newline. The large type tuples (`sTypes`, `cTypes`) in `buildMod` and `compCompute` must be written on a single line.

**`,/()` returns unit, not empty.** When `Con` or `Buf` is empty, `conWds: ,/Con` produces a unit value (length 1, null type) not an empty int list. Use `$[#Con; ,/Con; !0]` to guard.

**Right-to-left arithmetic in SPIR-V word encoding.** k evaluates right-to-left, so `(5+n)*65536+15` is `(5+n)*(65536+15)` — wrong. Always write `0x000F+(0x10000*(5+n))`.

**OriginUpperLeft required.** Dawn/WebGPU requires execution mode 7 (`OriginUpperLeft`) for fragment shaders. Mode 8 (`OriginLowerLeft`) is rejected with a validation error.

**SPIR-V 1.3 OpEntryPoint: no StorageBuffer in interface.** In SPIR-V 1.3, the OpEntryPoint interface must contain only Input (1) and Output (3) storage class variables. Listing StorageBuffer (12) variables causes Dawn to reject with "OpEntryPoint interfaces must be OpVariables with Storage Class of Input(1) or Output(3)". StorageBuffer vars are used via the function body, not the interface. Only SPIR-V 1.4+ requires all used globals in the interface.

**Integer literals must be coerced to f32.** `compLit` uses the AST literal type tag (`\`int` vs `` `float ``). An integer literal `2` in `x*2` would emit an i32 OpConstant, causing Dawn to reject the shader ("FMul operand index 3" type mismatch). The compiler coerces `\`int` to f32 when `oty~\`f32`.

**`kn` vs `ki_val` for atom values.** `kn(K)` returns the list length or -1 for atoms — not the atom's value. To extract the integer value of a K atom, use `ki_val`. Using `kn` to read a shader handle always returns -1.

---

## Future work

**Constant deduplication.** The same literal (e.g. `0.0`) emits a new `OpConstant` each time. A constant cache would reduce module size and the chance of hitting pool limits.

**Broader type support.** Only f32, v2, v4 I/O types are implemented. Adding i32, bool, v3 is straightforward.

**More ops.** `fmin`, `fmax`, `dot`, vector negation, explicit int/float casts (`OpConvertSToF`, `OpConvertFToS`).

**Branching.** No `$[cond; a; b]` support. A two-pass approach (emit to IR first, patch jump offsets after) would enable conditional expressions.

**Multi-output shaders.** Currently a single output variable. Multiple locations would require extending I/O resolution and decoration logic.

**SPIR-V 1.4 upgrade.** Version 0x00010400 allows listing all used globals in OpEntryPoint and unlocks other features. Would simplify compute shader interface handling.

**Configurable compute workgroup size.** Currently hardcoded to 64 in `compCompute`. Exposing this as a parameter would allow tuning for different GPU architectures.

**Headless compute (no window required).** `gpuCompute` currently requires an active `gpuRun` frame callback to access the device/queue. A standalone headless GPU device path would enable compute-only workflows without opening a window.

**Uniform buffers in compute shaders.** `compCompute` only supports runtime-array storage buffers. Uniform buffers would allow passing constants (array length, parameters) without resizing the storage buffer.

**Multi-buffer compute.** Current API: one input array, one output array. Multiple named bindings would enable reduction, scatter-gather, and multi-pass pipelines.
