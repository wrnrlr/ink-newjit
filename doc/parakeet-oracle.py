#!/usr/bin/env python3
# parakeet-oracle.py — ground-truth oracle for the ink Parakeet-TDT pipeline.
#
# Loads the real .nemo model, transcribes a wav, and dumps every intermediate
# stage (mel, subsample, encoder, token ids, text) as raw f32/i32 files so
# test/asr.k can diff the ink implementation against it stage by stage.
#
# Usage:  .venv-nemo/bin/python doc/parakeet-oracle.py test/data/asr/fox.wav
#
# Writes test/data/asr/<stem>.safetensors (all stages) plus a <stem>.json manifest
# holding the reference token ids and text.

import sys, os, json, numpy as np, torch

WAV = sys.argv[1] if len(sys.argv) > 1 else "test/data/asr/fox.wav"
NEMO = "data/parakeet-tdt-0.6b-v2/parakeet-tdt-0.6b-v2.nemo"
OUT = os.path.splitext(WAV)[0]

import nemo.collections.asr as nemo_asr

m = nemo_asr.models.ASRModel.restore_from(NEMO, map_location="cpu")
m.eval()

# ── input audio (int16 wav → f32 in [-1,1), exactly like ink's audio.load) ────
import soundfile as sf
sig, sr = sf.read(WAV, dtype="int16")
sig = sig.astype(np.float32) / 32768.0
assert sr == 16000, sr
x = torch.from_numpy(sig)[None, :]
xl = torch.tensor([sig.shape[0]])

dumps = {}
def dump(name, arr):
    a = np.ascontiguousarray(np.asarray(arr), dtype=np.float32)
    dumps[name] = a
    print(f"  {name:12s} {str(list(a.shape)):20s} {a.dtype}")

with torch.inference_mode():
    # 1. preprocessor → log-mel [B, NMEL, T], already per-feature normalized
    mel, mell = m.preprocessor(input_signal=x, length=xl)
    dump("mel", mel[0].T.numpy())                       # [T, NMEL] to match ink's row-major

    # 2. pre_encode (conv subsampling 8×) → [B, T', D]
    enc_in = mel.transpose(1, 2)                        # [B, T, NMEL]
    sub, subl = m.encoder.pre_encode(x=enc_in, lengths=mell)
    dump("sub", sub[0].numpy())

    # 3. full encoder → [B, D, T']
    enc, encl = m.encoder(audio_signal=mel, length=mell)
    dump("enc", enc[0].T.numpy())                       # [T', D]

    # 4. greedy TDT decode → token ids + text
    hyps = m.decoding.rnnt_decoder_predictions_tensor(
        encoder_output=enc, encoded_lengths=encl, return_hypotheses=True)
    h = hyps[0] if not isinstance(hyps[0], list) else hyps[0][0]
    ids = np.asarray(h.y_sequence, dtype=np.int32)
    dump("ids", ids.astype(np.float32))
    text = h.text
    # raw audio too, so the ink test reads the exact same samples
    dump("sig", sig)

# also the full transcribe() path, as an end-to-end sanity check
with torch.inference_mode():
    ref = m.transcribe([WAV], batch_size=1)[0]
    ref = ref.text if hasattr(ref, "text") else ref

# ── write the stages as one safetensors (ink reads it with safetensors.read) ──
header, buffers, off = {}, [], 0
for name, arr in dumps.items():
    b = arr.tobytes()
    header[name] = {"dtype": "F32", "shape": list(arr.shape), "data_offsets": [off, off + len(b)]}
    off += len(b); buffers.append(b)
hj = json.dumps(header).encode("utf-8")
hj += b" " * ((8 - len(hj) % 8) % 8)
with open(f"{OUT}.safetensors", "wb") as f:
    f.write(len(hj).to_bytes(8, "little")); f.write(hj)
    for b in buffers: f.write(b)

meta = {
    "wav": WAV, "samples": int(sig.shape[0]), "text": text, "transcribe": ref,
    "ids": ids.tolist(), "stages": {k: list(v.shape) for k, v in dumps.items()},
}
with open(f"{OUT}.json", "w") as f:
    json.dump(meta, f, indent=1)

print("\n  ids  :", ids.tolist())
print("  text :", repr(text))
print("  xscr :", repr(ref))
print("  → ", f"{OUT}.json")
