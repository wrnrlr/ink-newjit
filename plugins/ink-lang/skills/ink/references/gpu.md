# Ink GPU: Graphics, Compute, and the dye Shader Dialect

Three layers, all autoloaded: `lib/gpu.k` (native Vulkan/MoltenVK bindings),
`lib/dye.k` (the **dye** compiler: ink lambdas → SPIR-V), and helpers
(`camera.k`, `pbr.k`, `font.k`, `color.k`).

## Window & event loop

```k
loop: {[props] … draw calls … }
window.run[loop; cfg]      / blocking; calls loop every frame
```
`props` dict: `` `width`height`mx`my`time `` plus `` `events `` — a **table** of input
events since last frame: columns `kind` (`` `text`key`mouse`scroll ``), `code`, `mods`
(1=shift 2=ctrl 4=alt 8=super), `down`, `x`/`y`, `amt`. Unused cells are null — filter.
Track held keys yourself (see `lib/camera.k`). Headless one-shot device:
`gpu.computeRun[fn]` (stash results in a global inside `fn`).
Screenshots: run with `-snap out.png` (env `INK_SNAP`).

## 2D drawing

- `gpu.fill[verts;frag]` — triangles; `verts` = flat `F` of `[x,y,u,v]` per vertex;
  `frag` = 44-float uniform block; `gpu.solid[r;g;b;a]` builds one.
- `gpu.tessellate[pts]` — triangulate polygon `F` (NaN x/y pairs separate contours = holes:
  `,/{x,0n,0n}'contours`).
- **Draw calls inside `'`/`/` adverbs are eliminated** (treated as pure) — compute vertices
  with adverbs, then issue ONE explicit `gpu.fill` per layer as a statement.

## Meshes & 3D (vertex pulling only)

```k
pipe: mesh.compilePull[vtxShader; frgShader]
mesh.drawPull[pipe; bufs; count]           / bufs = resident storage buffers
mesh.drawPullT[pipe; bufs; count; texs]    / + sampled textures at @group(1)
```
The vertex shader (`shader.vertexPull[varyTypes;fn]`) is `{[buf0;…;vid](posV4;vary0;…)}` —
last param is `gl_VertexIndex`, others are storage buffers indexed at will. Instancing =
index math (`inst: floor[vid % NV]`). Per-frame uniforms live in a storage buffer you
`gpu.write` each frame. `lib/pbr.k` = PBR shader pair; `lib/camera.k` = orbit camera
(`CamNew`, `CamUpdate[c;props]`). Textures: `texture.upload[img]` (img from `image.read`);
sample in fragment via `sample[k;uv]` with `shader.fragmentTexN`.

## Compute

- One-shot: `gpu.runShader[spirv;in]` / `runShader2[spirv;in1;in2]`.
- Resident (no readback between dispatches): `b:gpu.buffer[F]`, `gpu.write[b;F]`,
  `gpu.read[b]`/`readI`, `pipe:gpu.compileCompute[spirv;nbind]`,
  `gpu.dispatch[pipe;bufs;nThreads]`, `gpu.dispatchLoop[pipe;bufsA;bufsB;n;reps]`
  (batched ping-pong for iterative solvers).
- `gpu.pipeline[fn]` — lambda → SPIR-V → cached pipeline in one call;
  `shader.kernel[fn]` infers the binding table (i32 accumulator params fed to
  `scatterAdd`/`iget`/`iset` come first; LAST param = thread index; rest = f32 buffers).
- Workgroup shared memory: `gpu.kernelWG[fn;nAcc;nBuf;shSizes]` (shSizes = list of shared
  f32 array element-counts). In the body: `lid` (index within the workgroup = gid mod wg),
  `wgsz` (workgroup size), `lset[s;i;v]`/`lget[s;i]` (write/read shared array `s`, a literal
  index), `barrier[]` (sync — shared writes before it visible to reads after). Dispatched
  like any kernel (ceil(n/wg) workgroups); shared arrays aren't bindings, so nbind still =
  nAcc+nBuf. The algorithm must respect workgroup boundaries. Set `wg` before compiling to
  change the tile size. Example (tiled GEMM reusing one A-row per workgroup): see
  `test/kkwg.k`. Barriers inside a `+/` fold work (loop-owned, replayed in the loop body).
- Placed arrays: `d: 9: x` upload (descriptor dict), `d 9: x` overwrite in place,
  `8: d` fetch back, `n 8: d` first n (trims ×64 padding). After a name, `f 9: x` is
  dyadic — bracket `9:[x]`.
- CPU oracle: `bits.run[fn;nAcc;nBuf;bufs;count]` interprets the same kernel on CPU.

## The dye shader dialect

Shader lambdas are ink plus: vector literals, monadic math names, `<=`/`>=` allowed
(peephole), and builtins `pow min max dot cross step mod clamp mix smoothstep floor
fract sign tanh length normalize`. Types are symbols: `` `f32`v2`v3`v4 ``.

- Fragment: `shader.fragment[ioTypes;fn]`, `shader.fragmentTex/TexN` (textures).
- Host globals referenced by name in a kernel are **baked as constants at compile time**
  (numeric scalars only; recompile to pick up changes; unknown names bake NaN + warn).

### Shader-dialect gotchas

- `&`/`|` are **polysemic** (as of 2026-07-21, like host k): min/max on float/vector
  operands, logical and/or on bool operands. So ReLU is `0.|x` or `max[0.;x]` (both fine);
  `(a>b)&(c>d)` is logical-and. (Before this change they were logical-only — older code
  used `min[]`/`max[]`, which still works.)
- No `>=` on GPU either in some paths — safest is `~(a<b)`.
- Vector loop-state needs component brackets: `t[0]` not `t`.
- Params can't be named `in`; max 8 params (pack config into a buffer).
- Pad OUTPUT buffers to a multiple of 64 (dispatch granularity).
- Host globals are invisible inside kernels unless numeric scalars (baked).

## Rendering pattern (canonical frame loop)

```k
frame: {[p]
  vs: ,/{…build triangles…}' shapes    / adverbs COMPUTE only
  gpu.fill[vs; gpu.solid[0.2;0.4;0.9;1.]]   / ONE explicit draw per layer
}
window.run[frame; [width:800;height:600]]
```
