# Safetensors extension

Reads [safetensors](https://github.com/huggingface/safetensors) files — the
simple, zero-copy tensor container used by Hugging Face — into an ink dict of
tensors.

## Build & use

```bash
zig build safetensors            # builds zig-out/lib/libsafetensors.dylib
```

```k
t: safetensors.read "model.safetensors"   / → dict, one entry per tensor
w: t`weight                                / [dtype:`f32; shape:2 3; data:<F>]
(w`shape) # w`data                         / reshape the flat data to its shape
```

`safetensors.read` auto-loads on first use (via `lib/safetensors.k`). The shared
library path is resolved relative to the current directory, so run from the repo
root or adjust `so:` in `lib/safetensors.k`.

## Result shape

The top-level value is a dict keyed by tensor name. Each tensor is itself a dict:

| key     | value                                                    |
|---------|----------------------------------------------------------|
| `dtype` | the *original* dtype as a symbol (`` `f32 ``, `` `bf16 ``, `` `i64 ``, …) |
| `shape` | `I` vector of dimensions                                 |
| `data`  | flat `F` or `I` vector (row-major); reshape with `shape#data` |

If the file carries a `__metadata__` object it is added as an extra entry — a
dict of string→string. Because `_` is the Drop verb in ink source you can't
write the key as a literal; build the symbol at runtime:

```k
t @ `s$"__metadata__"
```

## dtype → ink mapping

ink's value model is i32 / f32 only, so wider dtypes are narrowed and narrower
ones widened. The reported `dtype` symbol always preserves the original type.

| safetensors dtype                         | ink `data` |
|-------------------------------------------|------------|
| `BOOL` `U8` `I8` `I16` `U16` `I32`        | `I` (i32)  |
| `U32` `I64` `U64`                         | `I` (i32; values outside i32 range → `0N`) |
| `F16` `BF16` `F32`                        | `F` (f32)  |
| `F64`                                     | `F` (f32, narrowed) |

## Limitations

- **No 64-bit numbers.** `I64`/`U64`/`U32` values outside the i32 range read
  back as `0N`; `F64` is narrowed to f32.
- The 8-bit float dtypes `F8_E5M2` / `F8_E4M3` are not decoded (rejected).
- Read-only: there is no writer.

## Layout

- `../safetensors.k` — loader (enables auto-loading of `safetensors.read`)
- `src/main.zig` — k-ABI glue, `ReadSafetensors` export, dict/tensor builder,
  numeric decode (incl. F16/BF16 widening, I64 clamping)
- `src/reader.zig` — 8-byte length + JSON header parsing into tensor specs

## Test fixture

`test/safetensors.k` reads `test/data/tiny.safetensors`, generated with:

```python
import json, struct, numpy as np
tensors, blob = {}, b''
def add(name, dtype, arr, raw=None):
    global blob
    data = raw if raw is not None else arr.tobytes()
    s = len(blob); blob += data
    tensors[name] = {"dtype": dtype, "shape": list(arr.shape), "data_offsets": [s, len(blob)]}
def bf16(a):
    u = a.astype('<f4').view('<u4'); return (u >> 16).astype('<u2').tobytes()
add("weight", "F32", np.array([[1,2,3],[4,5,6]], '<f4'))
add("bias",   "I32", np.array([10,-20,30], '<i4'))
add("half",   "F16", np.array([1.5,-2.5,0.25,100.0], '<f2'))
add("bf",     "BF16", np.array([1,2,-3], '<f4'), raw=bf16(np.array([1,2,-3], '<f4')))
add("big",    "I64", np.array([1,2,5000000000], '<i8'))
add("flags",  "BOOL", np.array([True,False,True]), raw=bytes([1,0,1]))
hdr = dict(tensors); hdr["__metadata__"] = {"format":"pt","author":"ink-test"}
hb = json.dumps(hdr).encode()
open("test/data/tiny.safetensors","wb").write(struct.pack('<Q', len(hb)) + hb + blob)
```
