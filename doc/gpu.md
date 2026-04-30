# GPU Architecture

Array operations on large vectors are dispatched to the GPU automatically when a WebGPU backend is attached to the VM. The design keeps the GPU entirely out of the core interpreter — only the storage layer and a handful of dispatch sites know about it.

## Files

| File | Role |
|------|------|
| `src/gpu.zig` | Public interface: `GpuCtx` vtable, `GpuRange`, op enums. No Dawn dependency. |
| `src/gpu_wgpu.zig` | Concrete backend: Dawn/wgpu-native device, arena allocator, WGSL kernels. |
| `src/value.zig` | `Rc` header carries a `loc` field; `GpuMeta` stores the range + back-pointer. |
| `src/dispatch.zig` | `dispatch2` has a GPU shortcut at the top for GPU-resident dyad operands. |
| `src/verb/helper.zig` | Monad and dyad verb table entries check for GPU-resident inputs. |
| `src/adverb/fold.zig` | `+/` `*/` `&/` `|/` route to `reduceI32`/`reduceF32` for GPU vectors. |
| `src/adverb/scan.zig` | `+\` `*\` route to `scanI32`/`scanF32` for GPU vectors. |
| `src/adverb/each1.zig` | `-'` `_'` route to `monadI32`/`monadF32` for GPU vectors. |
| `src/adverb/each2.zig` | `x +'y` etc. route to `dyadI32`/`dyadF32` for GPU vector pairs. |

## Interface (`gpu.zig`)

`GpuCtx` is a vtable struct — a pointer to `VTable` plus an allocator. Backends embed it as the first field (`ctx: GpuCtx`) so `@fieldParentPtr` can recover the concrete type. The rest of the codebase only holds a `*GpuCtx` and calls wrapper methods on it.

```zig
pub const GpuCtx = struct {
  alloc:  std.mem.Allocator,
  vtable: *const VTable,

  pub fn dyadI32(self: *GpuCtx, op: DyadOp, out: GpuRange, x: GpuRange, y: GpuRange, n: u32) !void
  pub fn scanI32(self: *GpuCtx, op: ScanOp, out: GpuRange, x: GpuRange, n: u32) !void
  // ... etc.
};
```

`GpuRange` is a `(BufferHandle, byte_offset)` pair pointing into the arena buffer. `BufferHandle` is an opaque `u32`; the backend resolves it to a `wgpu.Buffer`.

### Operation enums

| Enum | Values |
|------|--------|
| `DyadOp` | `add sub mul div min max` |
| `MonadOp` | `neg abs` |
| `ReduceOp` | `add mul min max` |
| `ScanOp` | `add mul` |

`StubBackend` provides no-op stubs for all vtable entries, used by unit tests that don't link Dawn.

## Backend (`gpu_wgpu.zig`)

`WgpuBackend` wraps a Dawn device with:

- **Arena buffer** — one 64 MB `STORAGE | COPY_SRC | COPY_DST` wgpu buffer, bump-allocated with 256-byte alignment. `free` is a no-op; the whole arena is reclaimed on `destroy`.
- **Staging buffer** — 8 MB `MAP_READ | COPY_DST` buffer for CPU readback.
- **Uniform buffer** — 256-byte buffer written before each dispatch to carry per-kernel `Params`.
- **Pipeline cache** — one `?wgpu.ComputePipeline` per (op, dtype) pair, compiled lazily on first use.

### WGSL kernel templates

Kernels are generated at comptime from small template functions:

```
dyadWgsl(dtype, op_expr)   →  "arena[out+i] = op_expr(arena[x+i], arena[y+i])"
monadWgsl(dtype, op_expr)  →  "arena[out+i] = op_expr(arena[x+i])"
reduceWgsl(dtype, init, combine)  →  grid-stride accumulation + 256-thread tree reduce
scanStepWgsl(dtype, op_expr)      →  one Hillis-Steele pass
```

All kernels share the single arena buffer at binding 0 and a `Params` uniform at binding 1. Offsets are passed as element indices (byte offset ÷ 4, valid since all types are 4 bytes).

### Prefix scan (Hillis-Steele)

`+\` and `*\` use an inclusive prefix scan. `executeScan` runs `ceil(log2(n))` passes of the step kernel, ping-ponging between the output range and a scratch allocation in the arena:

```
pass 0 (stride 1):  in=x       → out
pass 1 (stride 2):  in=out     → scratch
pass 2 (stride 4):  in=scratch → out
...
```

If the final pass wrote to scratch, a `copyBufferToBuffer` moves it to `out`.

### Reduce

`+/` `*/` `&/` `|/` dispatch a single workgroup of 256 threads. Each thread grid-strides through the input accumulating a partial result, then a shared-memory tree reduce yields the scalar output. For `n = 4096` this is a single GPU dispatch.

## Storage (`value.zig`)

Every array (`N(T)`) is headed by an `Rc` struct:

```
CPU allocation:
  [Rc: rc len loc=0 _pad] [data...]

GPU allocation:
  [Rc: rc len loc=1 _pad] [GpuMeta: range ctx]
  (data lives in the wgpu arena at range.offset)
```

`Rc` is 16 bytes. For CPU arrays the data follows immediately; for GPU arrays a `GpuMeta` block follows in its place, carrying the `GpuRange` and a back-pointer to `GpuCtx`. No inline data is stored.

Key methods on `N(T)`:

```zig
N(T).initGpu(ctx, range, n)  // allocate a GPU-resident header
n.isGpu()                    // true if loc == gpu
n.gpuRange()                 // asserts isGpu(), returns GpuMeta.range
n.slice()                    // asserts !isGpu(), returns []T
```

## Dispatch flow

A GPU-resident value is created when:
1. `!n` (iota) and `n >= 4096` and a GPU backend is attached.
2. Any GPU kernel produces an output (output is always allocated in the arena via `allocRange`).

Once a value is GPU-resident, all subsequent elementwise operations on it stay on the GPU:

```
dispatch2(vm, .@"+", x_gpu_I, y_gpu_I)
  → gpu_blk shortcut: dyadI32(.add, out_range, x.gpuRange(), y.gpuRange(), n)
  → returns V{.I = N(i32).initGpu(...)}
```

CPU fallback: if either operand is CPU-resident, or the op has no GPU mapping, the normal verb table / CPU path runs unchanged.

### Threshold

GPU dispatch only fires for vectors of **4096 elements or more** (`DYAD_GPU_THRESHOLD`, `REDUCE_GPU_THRESHOLD`, `SCAN_GPU_THRESHOLD`, `EACH_GPU_THRESHOLD` are all 4096). Below this threshold the CPU path is faster due to launch and synchronization overhead.

## VM integration

`VM` has an optional `gpu: ?*GpuCtx` field. It is `null` in the REPL and test build (which link `StubBackend` or nothing). The IDE sets it to `&wgpu_backend.ctx` after `WgpuBackend.create()`.

```zig
// Attach GPU backend (ide.zig / notebook cell):
const backend = try WgpuBackend.create(alloc);
vm.gpu = &backend.ctx;
```

Detach and free:

```zig
backend.destroy(); // releases all wgpu objects; arena is reclaimed
vm.gpu = null;
```
