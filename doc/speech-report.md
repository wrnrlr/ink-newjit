# Speech / ASR + NN module — status report

Goal: transcribe speech locally in ink using **NVIDIA Parakeet‑TDT 0.6B v2**
(FastConformer encoder + Token‑and‑Duration Transducer decoder), driven from the
audio module (`lib/audio.k`, `test/replay.k`).

This report covers what was built and why, the validated state, the problems hit,
the one remaining blocker, what's left for a working demo, and how to make it
fast enough for (near) real‑time.

---

## 1. TL;DR

* The **entire Parakeet architecture is implemented in ink and validated
  numerically against a from‑scratch CPU reference to ~1e‑6/1e‑7 precision** — end
  to end: `audio → log‑mel → conv‑subsampling → FastConformer encoder (rel‑pos)
  → TDT greedy decode → detokenize → text`.
* Along the way the GPU compute dialect (`lib/spirv.k`) grew from *render‑only,
  straight‑line* into a **general neural‑network backend**: in‑kernel loops,
  reductions, real k iteration adverbs, and ~25 compute kernels.
* The real 0.6B model is downloaded and its config **exactly matches** the
  implementation. Weights are exported to f32 safetensors.
* **One hard blocker remains: ink's `safetensors.read` fails on files larger than
  ~1.5 GB**, and the model is 2.4 GB. This must be fixed in the reader (not worked
  around). Plus two small model‑side corrections (ReLU joint, 2‑layer LSTM).
* Nothing left is architectural. The path to a working — then fast — demo is
  concrete and listed below.

---

## 2. What was built, and why

### 2.1 Compute‑dialect extensions (`lib/spirv.k`)

The pre‑existing SPIR‑V compute stack (`GpKernel`, resident buffers,
`CompileCompute`/`Dispatch`, `set`/`iget`/`scatterAdd`) emitted **pure
straight‑line SSA** — even `$[…]` compiled to `OpSelect`, so there was *no control
flow at all*. Neural nets need reductions (matmul inner products, softmax,
LayerNorm) which are inherently loops. So the dialect gained, in order:

* **In‑kernel bounded loops** — the first control flow: a phi‑carried structured
  loop CFG (`OpLoopMerge`/`OpBranchConditional`/`OpPhi`). Exposed as `rsum[K;{[k]
  e}]` (Σ) and `rmax` (max reduction). This is the single primitive every
  matmul/softmax/LayerNorm/conv is built on.
* **Real k iteration adverbs** — `i f/` (N‑do) and `f g/` (While) lowered onto the
  same loop CFG via a shared `loopOpen`/`loopClose` scaffold, so the dialect uses
  k's own vocabulary rather than a bespoke intrinsic. (Fold‑over‑an‑array `+/x`
  genuinely *cannot* lower — a kernel has no materialized array value, only
  index‑addressed buffers — which is exactly why `rsum` exists as a fused
  index‑reduction.)
* **Transcendentals**: `exp`, `log`, `tanh` (GLSL.std.450), for softmax /
  activations / GELU.
* Note: shader `|` is `OpLogicalOr`, **not** max, so ReLU is `max[0.;x]`.

### 2.2 NN primitives (`lib/nn.k`)

A library of GPU kernels + host orchestration. Everything is validated against a
CPU reference. Public surface (each `*R` variant is *resident* — operates on GPU
buffer handles, no host round‑trip; the bare name is a host convenience that
uploads/reads back):

| Primitive | Notes |
|---|---|
| `Gemm`/`GemmR` | C = A·B, naive one‑thread‑per‑output + `rsum` over K |
| `Linear`/`LinearR` | Y = X·Wᵀ + b, **PyTorch [out,in] layout, no transpose** |
| `Softmax`/`SoftmaxR` | numerically stable (row‑max subtract) |
| `LayerNorm`/`LayerNormR` | per‑row mean/var + affine |
| `Silu`/`Gelu`/`AddScaledR` | activations + scaled residual |
| `FfnBlock` | conformer macaron FFN (½‑residual) |
| `Mhsa` / `MhsaRel` | scaled‑dot‑product / **Transformer‑XL rel‑pos** attention |
| `ConvModule` | conformer conv: pointwise→GLU→depthwise→BN(folded)→SiLU→pointwise |
| `ConvSubsample` | 2‑D dw‑striding 8× subsample (conv2d/dwconv2d/pwconv2d/relu/flatten) |
| `ConformerBlock` / `Encoder` | full block (37 weights, rel‑pos) + stacked encoder |
| `LogMel` (+ `nnHann`/`nnDft`/`nnMelFb`) | STFT‑power kernel + mel GEMM + log |
| `nnLstm`/`nnJoint`/`TdtGreedy` | TDT predictor + joint + host greedy loop |
| `nnDetok`/`nnLoadVocab` | SentencePiece detokenize (`▁` marker) |
| `nnLoadEncoder`/`Subsample`/`Decoder`/`nnTen` | safetensors dict → weight lists |

Design choice: **layouts follow PyTorch** (weight `[out,in]` row‑major), so an
exported tensor's flat bytes drop straight into the kernels with no transpose.

### 2.3 The decoder is host‑side, on purpose

The FastConformer *encoder* is embarrassingly parallel over time and belongs on
the GPU. The TDT *decode* is a short, sequential, data‑dependent loop (emit vs
blank, variable frame advance, growing token list) with tiny per‑step matmuls —
GPU parallelism buys nothing there. So `TdtGreedy` runs in pure host k using the
host `while` adverb. (An earlier plan to use the GPU `While` for it was wrong and
corrected.)

### 2.4 Validation

Eight test files, all passing, each comparing GPU output to an independent CPU
reference:

`test/nn.k` (9 primitives, 0–2e‑7) · `test/conformer.k` (rel‑pos block 7e‑7,
3‑layer encoder 4e‑7) · `test/frontend.k` (log‑mel 1e‑4 — `log` amplifies error
near the floor) · `test/subsample.k` (convs 1e‑6, flatten exact) · `test/tdt.k`
(decode logic on controlled models) · `test/weights.k` (loader round‑trip exact +
`forward(loaded)==forward(direct)` = 0) · `test/relpos.k` (7e‑6) · `test/detok.k`.

### 2.5 Integration + model

* `test/asr.k` — combines the mic/waveform (from `replay.k`) with font text
  rendering (from `edit.k`) and the full pipeline; gated behind `LOADMODEL` so it
  runs and renders with or without weights. `audio.rec.speech[]` records at 16 kHz.
* `doc/parakeet-export.py` — offline `.nemo`→f32‑safetensors converter (torch+numpy
  only; writes the safetensors container by hand). **Verified against the real
  checkpoint**; produced `data/parakeet-tdt-0.6b-v2/parakeet.safetensors` (914
  tensors, 2.47 GB) and a clean `vocab.txt`.

---

## 3. Config verification (real model vs implementation)

Reading `model_config.yaml` from the `.nemo`, **every dimension matches**:
d_model 1024, 24 layers, 8 heads, ff×4 = 4096, conv kernel 9, dw_striding ×8 with
256 conv channels, 128 mels, n_fft 512, win 400 / hop 160, 16 kHz, per‑feature
normalize, **`self_attention_model: rel_pos`**, vocab 1024, durations [0–4],
pred/joint hidden 640. Tokenizer is SentencePiece BPE (`▁`). The checkpoint even
ships NeMo's exact window + mel filterbank, which the exporter emits directly.

Two places the checkpoint differs from current defaults (both small, both known):

1. **Joint activation is `relu`** — `nnJoint` currently uses tanh.
2. **Predictor is a 2‑layer LSTM** (`pred_rnn_layers: 2`) — `nnLstm`/`TdtGreedy`
   are single‑layer.

(The conformer Linears/convs have **no bias** in NeMo — the exporter already
writes zeros for them and folds BatchNorm into an affine.)

---

## 4. Problems encountered

### 4.1 The blocker — `safetensors.read` caps at ~1.5 GB

Measured empirically: a 1.36 GB safetensors reads fine (108 tensors); a 1.93 GB
one returns null. The 0.6B model is 2.4 GB, so **it cannot currently be loaded**.

Ruled out: it is **not** a memory limit — the machine has 32 GB, ink's slab
allocator happily holds 6.4 GB across several vectors, and a single 2 GB vector
allocates fine. The fault is inside the reader (`lib/safetensors/src`). The
`ReadSafetensors` export does:

```zig
const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, alloc,
                std.Io.Limit.limited(4 << 30)) catch return null;
```

i.e. it slurps the **entire file into one contiguous heap buffer** and then
decodes every tensor into ink vectors. The failure is in that whole‑file read
path around ~1.5–1.9 GB (a single ~2 GB `malloc`, or the `Limit`/size handling),
and the error is swallowed by `catch return null`.

**Proper fix (not a workaround):** stop reading the whole file into one buffer.
Two levels, do at least the first:

1. **`mmap` the file** instead of `readFileAlloc`. The reader already treats the
   data as a `[]u8` indexed by `data_offsets`; an mmapped view gives exactly that
   with no giant contiguous allocation and OS‑demand paging. This alone should
   remove the size limit. (Also: surface the real error instead of `catch return
   null` so failures are diagnosable.)
2. For memory scalability with big models, add a **stream‑to‑GPU path**: a
   function that reads one tensor's bytes and uploads straight into a resident GPU
   buffer, so the 2.4 GB is never all resident in host ink at once. This is the
   right long‑term design for large models (see §6).

Splitting the export into <1.5 GB shards would "work" but is a hack that hides a
real reader defect — explicitly **not** the chosen path.

Related, separate limitation: the `1:` byte‑read operator returns an ink char
vector, whose length is **i32‑capped (~2.1 G elements)**, so `1:` can't read a
>2 GB file at all. The safetensors reader must therefore keep the file as a native
`[]u8`/mmap (it does) and never materialize it as an ink vector.

### 4.2 Language / runtime gotchas hit (each cost real debugging time)

These are worth capturing as they'll recur for any NN work in ink:

* **Lambdas cap at 8 parameters** — a 9th silently fails to bind (returns a
  projection). Pack extra args into a `cfg` list. Bit us as all‑NaN LayerNorm.
* **`mod`/`div` are integer‑only** — float `mod` → `!type`, which silently
  collapses to a scalar and poisons downstream (bad buffers, length‑1 results).
* **`,/ f'x` mis‑parses** — adverb juxtaposition; precompute the each or
  parenthesize.
* **Shader `|` is `OpLogicalOr`, not max** — SPIR‑V rejects `0.|x`; ReLU = `max[0.;x]`.
* **No `>=`/`<=`** — `a>=b` parses as `a>(=b)`; use `~(a<b)`.
* **`[a;b]` inside a `$[…]` branch is a dict literal**, not a statement sequence —
  every multi‑statement op must be a named function.
* **Lambdas don't close over enclosing locals** — use top‑level helpers + globals;
  map by index over a global list.
* **Over‑dispatch**: Metal rounds dispatch up to ×64 and clamps OOB stores to the
  last valid index — pad output buffers to a multiple of 64.
* **f32 kernel indices** are exact only ≤ 2²⁴; fine for realistic sequence lengths
  but attention on very long inputs needs i32 indexing.

---

## 5. What's left for the transcription demo

Ordered; none is architectural:

1. **Fix the safetensors reader** (§4.1) so the 2.4 GB model loads. *This is the
   gate.*
2. **`nnJoint`: tanh → ReLU.**
3. **`TdtGreedy`: 2‑layer LSTM** — thread two `(h,c)` states, two weight sets;
   `nnLoadDecoder` returns emb + 2×(wih,whh,b) + 5 joint tensors (the exporter
   already writes `dec.wih0/1`, etc.).
4. **Featurizer exactness** — use the exported `feat.window`/`feat.fb`; match
   NeMo's STFT centering and log‑guard (`log(x + 2⁻²⁴)`), and per‑feature
   normalization (already have `featNorm`). These affect accuracy, not structure.
5. **Wire loading in `test/asr.k`**, flip `LOADMODEL:1`, run.
6. **Validate** one encoder layer's output against a NeMo forward dump (via the
   venv) before trusting the full stack — the most likely subtle bug is the
   rel‑pos term's relative‑shift convention.

Expected first‑run latency: a ~5 s clip is only ~60 frames after 8× subsampling,
so even the naive kernels should give a transcript in **tens of seconds** (not
minutes) — slow but usable for a first correctness demo.

---

## 6. Making it fast — toward (near) real‑time

Current design is *correctness‑first*: a naive GEMM (one thread per output element)
and **host round‑trips between every sub‑block** (each `FfnBlock`/`Mhsa`/… reads
back to host and re‑uploads). Both are the low‑hanging fruit.

In rough order of impact:

1. **Tiled GEMM.** The single biggest win. Replace the one‑thread‑per‑output
   `rsum` GEMM with a workgroup‑shared‑memory tiled kernel (e.g. 16×16 tiles,
   register‑blocked). This is 5–20× on the matmul‑bound layers and benefits every
   AI workload, not just ASR.
2. **Resident chaining — eliminate per‑sub‑block readback.** Keep activations in
   GPU buffers across the *whole* encoder: one upload, one readback. The `*R`
   resident kernels already exist; the encoder just needs to compose them on
   buffer handles instead of via the host‑convenience wrappers. This removes ~120
   host↔GPU round‑trips per clip.
3. **Persistent weight buffers.** Upload the 2.4 GB of weights to GPU **once** and
   reuse across clips/frames (they never change). Combined with §1's stream‑to‑GPU
   load, host memory stays small and per‑clip cost is just activations.
4. **fp16 weights + compute.** Halves memory and bandwidth (2.4 GB → 1.2 GB) and
   roughly doubles matmul throughput on Apple GPUs. Needs f16 storage buffers +
   f16 kernels in the dialect (currently f32‑only).
5. **Kernel fusion / fewer dispatches.** Fuse bias+activation into GEMM epilogues,
   fuse LayerNorm stats+apply, fuse the attention score+softmax. Fewer dispatches =
   less launch overhead.
6. **Batch the decoder's matvecs**, and keep the predictor/joint weights resident.
7. **Streaming / cache‑aware encoder** for true real‑time: process fixed audio
   chunks with cached left‑context (Parakeet supports cache‑aware streaming),
   emitting partial transcripts as audio arrives instead of one‑shot at end.
8. **i32 kernel indices** where sequence length can exceed the f32‑exact range.

Steps 1–3 alone should take a 5 s clip from tens of seconds to ~a second, which
with §7 is enough for near‑real‑time dictation.

---

## 7. Keeping the NN/GEMM API flexible (reuse for other AI workloads)

The primitives are already general‑purpose — `GemmR`, `LinearR`, `SoftmaxR`,
`LayerNorm`, activations, `MhsaRel`, conv kernels are a standard transformer
toolkit, usable for GPT‑style LMs, embeddings, vision, etc. To keep them reusable:

* **Make the resident (`*R`) API the primary one.** It composes without host
  round‑trips and is the performant path; the bare host wrappers are conveniences
  for one‑shot use. New models should build on buffer handles.
* **Weights‑as‑lists** (the `cfg` + list‑of‑arrays convention, forced by the
  8‑param cap) is actually a clean, model‑agnostic loader interface — keep it.
  `nnTen`/`nnLoad*` are just name→list mappings; other models supply their own
  suffix tables.
* **The loader reads safetensors** — a portable, framework‑neutral interchange —
  so any model exported to safetensors (with PyTorch `[out,in]` layout) loads with
  no transpose.
* **Split "kernel library" from "Parakeet wiring."** Right now both live in
  `lib/nn.k`. As it grows, the general kernels (GEMM/attention/conv/norm) want to
  be their own module (`lib/nn.k`) with model‑specific assembly (ConformerBlock,
  TdtGreedy, LogMel) layered on top or in `lib/asr.k`.

---

## 8. Toward standalone k (removing the Python dependency)

Python (torch+numpy) is currently used **only** for the one‑time offline weight
export (`.nemo`/`.ckpt` → safetensors). Everything at *runtime* is already
k + native ink extensions.

To be fully standalone:

* The runtime path is already Python‑free once weights are in safetensors — and
  safetensors is a reasonable shipping format (export once, distribute the
  `.safetensors` + `vocab.txt`).
* To remove Python from the *conversion* too: the `.nemo` is a tar and
  `model_weights.ckpt` is a **torch zip (PK\x03\x04) of a pickled fp32
  state_dict**. A dep‑free converter (zip + a minimal pickle reader + struct) —
  in k on the native FFI, or a small standalone tool — would produce the
  safetensors with no torch. Feasible; not required for the demo.
* Fixing the safetensors reader (§4.1) is the prerequisite for loading real models
  regardless of how they're produced.

---

## 9. File map

* `lib/spirv.k` — compute dialect (loops, adverbs, transcendentals, ~25 kernels).
* `lib/nn.k` — NN primitives + ASR pipeline + loaders + detokenize.
* `lib/audio.k` — mic/playback (`audio.rec.speech[]` = 16 kHz).
* `test/asr.k` — record → transcribe → display demo (gated on `LOADMODEL`).
* `test/{nn,conformer,frontend,subsample,tdt,weights,relpos,detok}.k` — validation.
* `doc/parakeet-export.py` — offline `.nemo` → f32 safetensors + vocab.
* `lib/safetensors/src/{main,reader}.zig` — **needs the large‑file fix (§4.1)**.
* `data/parakeet-tdt-0.6b-v2/` — the model: `.nemo`, exported `parakeet.safetensors`,
  `vocab.txt`, `model_config.yaml`.
