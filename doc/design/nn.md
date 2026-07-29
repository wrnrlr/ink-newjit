# nn — neural-net primitives on the resident-compute stack

Status: implemented and validated end-to-end (Parakeet-TDT 0.6b-v2 ASR).
Files: `lib/nn.k`, `lib/conformer.k`, `lib/feat.k`, `lib/asr.k`.
Related: `doc/design/kk2.md` (compute IR), `doc/design/dye.md` (ink → SPIR-V).

---

## 1. What this is

A neural-network inference stack written in k, with the arithmetic running on the
GPU through `dye`-compiled SPIR-V kernels. It exists as one complete vertical slice —
raw audio to text — plus the generic layers that slice is built from.

The pipeline:

```
audio → logmel → subsample → conformer → tdt → asr.detok → text
        feat.k    asr.k       conformer.k  asr.k   asr.k
```

Everything is **row-major flat f32 vectors**. There are no nested arrays in the hot
path; a "matrix" is a flat vector plus the dims you pass alongside it.

### Module split

| File | Holds | Rule for belonging here |
|---|---|---|
| `lib/nn.k` | plumbing, gemm, linear, softmax, layernorm, activations, GLU, conv1d/conv2d, attention, FFN, host-side scalar helpers, LSTM | Nothing in it knows what audio is |
| `lib/conformer.k` | conv module, block, encoder stack | A reusable architecture, not an ASR detail |
| `lib/feat.k` | preemph, STFT, mel filterbank, normalization | Audio → features; useful to any audio model |
| `lib/asr.k` | conv subsampling, TDT greedy decode, Parakeet weight loading, SentencePiece detokenize | The only model-specific file |

The forcing test for the split: *could you build a local LLM decoder on `lib/nn.k`
without touching a line of ASR code?* Today, almost — see §6.

---

## 2. Naming conventions

### 2.1 The host/resident inversion

Every GPU op has two forms. The **resident** form takes and returns GPU buffer
handles; nothing crosses to the host. The **host** form uploads, runs, reads back.

The resident form gets the short name, because it is the one that composes:

```k
gemm[bc; ba; bb; M; K; N]        / resident: handles in, handle out
gemm.host[A; B; M; K; N]         / host arrays in, host array out
```

This is the reverse of the original code (`GemmR` resident, `Gemm` host). The
resident forms are what the real pipeline chains together; the host forms exist for
one-shot use, for tests, and as the **bit-exactness oracle** (§4).

### 2.2 Suffixes

| Suffix | Means | Example |
|---|---|---|
| *(none)* | public entry point, resident | `linear` |
| `.host` | upload / run / read back | `linear.host` |
| `.kern` | the `gpu.kernel` value | `linear.kern` |
| `.tile.kern` | the shared-memory tiled variant | `linear.tile.kern` |

### 2.3 Bare names and `\e`

The public verb surface uses **bare identifiers** — `gemm`, `linear`, `softmax`,
`relu`, `ffn`, `lstm` — because that is what reads well at a call site.

Bare names are not autoload-indexed by default: most bare globals in a k file are
private helpers (`so`, `tmp`, …) and indexing them all would pull half the library in
on any common identifier. So a module declares its unqualified public surface
explicitly:

```k
\e gemm linear softmax layernorm silu gelu relu addscaled glu dwconv chanaffine
\e conv2d dwconv2d pwconv2d flatten ffn lstm
```

`\e` is a runtime no-op (`src/runtime/command.zig`); it is consumed by the module
indexer at scan time (`src/cmd/modules.zig` `scanText`). Anything **not** listed stays
file-private as far as autoload is concerned.

Note that a dotted name already indexes its own prefix, so defining `gemm.kern`
makes a bare `gemm` reference autoload too. `\e` is still the right thing to write:
it states the intended public surface in one place instead of leaving it as a side
effect of which members happen to be dotted.

### 2.4 Globals are always namespaced

There are no bare mutable globals. Shared plumbing lives under `nn.*`, host-side
scalar helpers under `nn.fn.*`, and each op's own state under its own prefix
(`attn.peB`, `feat.nmu`, `asr.td.vocab`). This matters more than it looks: the global
namespace is flat and shared across every loaded module, and an unset global reads as
`0` rather than erroring — so a bare-name collision corrupts silently.

> That failure mode bit during this refactor: three missed renames in `test/weights.k`
> (`nnEncNm`, `nnSubSuf`, `nnDecSuf`) resolved to `0`, built empty weight dicts, and
> produced four clean `0b` results instead of an error. Numeric oracles caught it;
> nothing else would have.

---

## 3. Plumbing

### 3.1 Padding

`gpu.dispatch` rounds the grid up to a multiple of 64, and Metal **clamps** an
out-of-bounds store to the last valid index. So every *output* buffer is allocated to
the launched thread count via `nn.pad`, and stray writes from the ragged tail land in
padding instead of corrupting live elements. Out-of-bounds *reads* clamp harmlessly
(their results are discarded).

### 3.2 Pipeline cache

`nn.pipe[`name; kernel; nbufs]` memoizes compiled pipelines in a symbol-keyed dict.
This replaced ~20 `xPipe::0` globals and their `$[p=0; p::compile; 0]` guards.

### 3.3 Params buffers — one per op, deliberately

`nn.par[`name; vals]` writes an op's dims into **that op's own** 8-float params
buffer and returns the handle.

**Do not collapse these into one shared buffer.** It looks like obvious boilerplate
removal and it is a serious performance bug. `gpuBufferWrite`
(`lib/gpu/gpu_vk.zig`) only drains the queue when the write changes bytes that
*recorded-but-unsubmitted* work still references:

```zig
if (v.hasPendingWork(b)) {
  if (std.mem.eql(u8, b.mapped[0..bytes.len], bytes)) return ki(0);
  v.sync();
}
```

With one buffer per op, an op's params write is invisible to every other op's pending
dispatches, so it stays free. With a single shared buffer, every write would collide
with every other op's pending work and force a full `vkQueueSubmit` +
`vkQueueWaitIdle` per op — the 3-10× regression measured in
`doc/research/tropical.md` Exp 2. Distinct keys are what keep the deferred batching
that the whole resident-buffer design rests on.

The same reasoning is why buffer *pooling* is listed as future work rather than done:
recycling a freed buffer for a different purpose reintroduces exactly this aliasing.

### 3.4 Workgroup size is an argument, not a global

`gpu.kernelWG[fn; nAcc; nBuf; shSizes; lsz]` takes the workgroup size explicitly
(`lsz`, `0` = inherit the sticky `wg`).

It used to read the mutable global `wg`, which meant every 256-wide kernel had to
bracket its own definition:

```k
wg:: 256
lin2dK: gpu.kernelWG[{…}; 0; 5; (256;256)]
wg:: 64                       / put it back — or every later kernel is wrong
```

A tile size is a property *of the kernel*, so it belongs in the kernel's own
declaration. Reading it from a global made kernel definitions order-dependent and
silently mis-compiled if the restore was dropped. The change emits byte-identical
SPIR-V (verified against `test/kkgold.k`).

---

## 4. The oracle discipline

The host path is the reference for the resident path. `conformer.fold` runs every
block through `conformer.block.host`, round-tripping the `[T,D]` activation to the
host between layers; `conformer` keeps it resident throughout. Both use identical
kernels and identical dispatch sizes, and host round-trips are lossless f32 copies —
so the two must agree **to the bit**, and `test/weights.k` asserts exactly that
(`maxerr=0.0`).

Keep this property. It is the only cheap way to tell "the resident plumbing broke"
apart from "the kernel is wrong".

Layered on top:

| Test | Checks |
|---|---|
| `test/nn.k` | every primitive vs a pure-k CPU reference |
| `test/relpos.k` | relative-position attention vs CPU |
| `test/conformer.k` | block and 3-layer stack, resident vs host |
| `test/frontend.k` | log-mel vs CPU |
| `test/subsample.k` | each conv kernel, then the whole subsampler |
| `test/weights.k` | safetensors round-trip + forward-pass equality |
| `test/tdt.k`, `test/detok.k` | decoder control flow, detokenizer |
| `test/asr.k` | the whole pipeline vs a real NeMo oracle dump |
| `test/kkbits.k` | the same kernel lambdas lowered to the CPU bits backend |
| `test/kkgold.k` | SPIR-V byte-identity across `dye` refactors |

**Known maintenance hazard:** `test/kkbits.k` holds *copies* of nn's kernel lambdas
rather than importing them, so the two can drift silently. Deduplicating it would
mean exporting the raw lambdas separately from the compiled kernels.

---

## 5. Negative results worth keeping

These are the things that cost real time to learn and are invisible in the code.

**Tiling gives 1.7–2.5×, not 8×.** The 8×8 tiled GEMM fetches each A/B element once
per tile instead of once per output — an exact 8× reduction in global loads. Measured
speedup at M=N=K=64/128/512 is 1.7–2.5×, because the cache already recovers most of
the traffic the tiling avoids. The analytic ratio is an upper bound, not a prediction.

**Row alignment must not be required.** `linear.tile.kern` deliberately does *not*
require the row count to be a multiple of the tile. `M` is the encoder frame count
`T'`, an arbitrary function of utterance length — a 10 s clip gives `T'=126`.
Requiring `M%16=0` would silently drop most real utterances onto the ~5× slower
scalar kernel. Only `N` and `K` are constrained (and in this model are always 1024 /
2048 / 4096). Rows round up to a whole tile and threads outside `[0,M)` neither load
nor store.

**One thread per row starves the GPU.** The scalar LayerNorm gave each row one
thread, so a `[32,1024]` norm launched 32 threads each walking 2048 dependent loads:
~0.38 ms of pure latency, ~46 ms across 5 norms × 24 layers, 15% of the encoder.
`layernorm.wide.kern` gives each row a whole 256-thread workgroup taking coalesced
strided slices. Same two-pass formulation, only the summation *order* changes.

**Column-major matvec beats row-major by 3.4×.** In the decoder, `Σ_k x[k]·W[:,k]`
(k scalar×vector products plus one fold) beats n separate length-k dot products,
because it collapses n×(alloc + multiply + reduce) into far fewer interpreter
round-trips. Same k order, so bit-identical. Row-splitting alone was already 3.1×
over indexing a flat matrix.

**Memoizing the TDT predictor is worthless.** Caching predictor output across blank
steps looks free — identical state, identical output. Measured hit rate: 0%. TDT
advances time with its duration head instead of emitting blanks, so essentially every
step emits.

**The NeMo frame count is one less than the STFT produces.** `feat.nemo.frames` is
what `torch.stft(center=True)` physically produces; `feat.nemo.valid` is NeMo's
`get_seq_len`, which is **one lower**. The trailing frame is excluded from the
normalization statistics and then zeroed by the pad mask. Getting this wrong shifts
every per-bin mean/std and corrupts the entire spectrogram — with no crash.

Two more in the same family: `torch.std()` is **unbiased** (÷ n−1), and the epsilon
is added to the **std**, not the variance. All three are why the NeMo-compatibility
constants live under a visible `feat.nemo.*` prefix.

**Zero padding, not reflect.** NeMo calls `torch.stft(pad_mode="constant")`, which is
zero padding — *not* torch's reflect default. And since only `|X|²` is kept and a time
shift only rotates phase, we pad by `(nfft÷2)−((nfft−win)÷2)` and keep the cheaper
`win`-point transform instead of widening to `nfft`.

**Shader `|` is not max.** In kernel code `|` is logical-or; ReLU must use the `max`
builtin. (`&`/`|` became polysemic in 2026-07; on floats they are min/max, on bools
logical — but the explicit `max` is what the ReLU kernel documents.)

### Two k-level traps this stack keeps stepping on

**`f ,/ x` trains, it does not apply.** Writing `nn.drop ,/ WBs` does *not* call
`nn.drop` on the razed list — the parser builds a train and the call hangs. It must be
`nn.drop[,/ WBs]`. This cost an afternoon during the module split: the one-shot
`conformer` entry point hung, but `conformer.run` and `conformer.block` were both fine,
so every component tested clean in isolation.

**An unset global is `0`, not an error.** Combined with the above, this is the stack's
main silent-failure mode. Two instances in one refactor:

- `test/weights.k` referenced three names a rename had missed; they read as `0`, built
  empty weight dicts, and printed four tidy `0b` mismatches instead of erroring.
- `test/kkwg.k` used `nn.pad` from `lib/nn.k` without defining it; renaming the symbol
  left it unset, so `bc: gpu.buffer[(padTo[M*NN])#0.]` allocated a **zero-length**
  buffer. The dispatch then wrote nowhere and the test read back all zeros — which
  looks exactly like a wrong kernel, not a missing name.

The lesson for both: after any rename, grep for the old symbols *and* re-run the
numeric oracles. Structural checks pass happily on garbage.

### Coverage gaps found while doing this

`layernorm.wide.kern` only activates at `N % 256 == 0`, and every unit test used a
small `N` (6, 8) — so the wide kernel had **no** unit coverage and was only exercised
by the full ASR run at D=1024. `linear.tile.kern` is nearly the same story (it needs N
and K both multiples of 16; `test/nn.k` uses D=8/Dff=16, which falls back to the scalar
kernel). Any shape-guarded fast path needs a test that actually trips the guard.

---

## 6. What's missing

Ordered by how much each would unlock.

### 6.1 Batch dimension
Everything is B=1. Linear/FFN/norm generalize nearly free by folding B into M;
attention needs a batch stride in the score and context kernels. This is the biggest
genuine gap and blocks any throughput-oriented use.

### 6.2 Masking
Follows directly from B=1. Variable-length batching needs a pad mask threaded through
attention and through the normalization statistics.

### 6.3 Streaming / KV cache
Attention materializes the full `[H,T,T]` score matrix, so cost is quadratic in
utterance length and decoding cannot be incremental. Streaming ASR normally uses
limited-context or chunked attention. Needed for real-time transcription.

### 6.4 The LLM-shaped gaps
To run a local transformer decoder on this stack you would still need: RMSNorm,
RoPE, grouped-query attention, a causal mask, cross-attention, and an
embedding-lookup kernel (currently a host-side gather). None are hard; each is a
kernel plus a wrapper. `lib/llm.k` today is an API client, not local inference — that
is the natural destination.

### 6.5 Shape validation
A wrong `cfg` produces silent garbage, compounding the unset-global-reads-as-0
problem from §2.4. A debug-mode assert comparing declared dims against actual buffer
lengths would convert the worst failure mode into an error message.

### 6.6 dtype flexibility
f32 only. safetensors already widens F16/BF16 at load; a resident f16 weight path
would roughly halve the ~300 ms weight upload.

### 6.7 Fusion
`linear.tile.kern` already folds bias into the store. Folding SiLU in too, and
folding the residual add into the second Linear, would remove whole dispatches and
their intermediate buffers. Same idea as the FusedMap/X100 work.

### 6.8 Buffer pooling
The resident path allocates and frees the same shapes every layer — ~600 alloc/free
cycles per utterance for a 24-layer stack. A size-keyed pool would cut it to ~25.
See the aliasing caveat in §3.3 before attempting.

### 6.9 Smaller items
- No backward pass — inference only, by design.
- Greedy decoding only: no beam search, no CTC.
- `test/kkbits.k` duplicates kernel source (§4).
- Kernel generation: `gemm.tile.kern` and `linear.tile.kern` are the same algorithm
  differing only in tile size, transpose, bias and row-guarding. Since kernels are k
  lambdas, one generator could produce both — worthwhile because shared-memory index
  math is the most bug-prone code here and is currently written twice.
