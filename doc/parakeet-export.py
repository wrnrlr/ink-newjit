#!/usr/bin/env python3
# parakeet-export.py — convert parakeet-tdt-0.6b-v2's model_weights.ckpt to an f32
# .safetensors whose tensor NAMES match lib/nn.k's loaders (nnLoad*).  Needs only
# torch + numpy (writes the safetensors container by hand — no safetensors pkg).
#
# Transforms the ink side does NOT do:
#   * conformer Linears/convs have NO bias in NeMo → write zeros for them.
#   * BatchNorm (conv module) folded to affine:  a = γ/√(var+ε),  b = β − μ·a.
#   * LSTM: sum bias_ih + bias_hh per layer (nnLstm has one bias); export BOTH layers.
#   * joint bias = enc.bias + pred.bias.
#   * conv weights [C,1,3,3]/[C,C,1,1]/[2D,D,1]/[D,1,9] flatten to 2-D.
#   * ship NeMo's exact window[400] + mel filterbank fb[128,257].
#
# Usage:  .venv/bin/python doc/parakeet-export.py

import torch, numpy as np, json, struct, os

DIR  = "data/parakeet-tdt-0.6b-v2/"
CKPT = DIR + "model_weights.ckpt"
OUT  = DIR + "parakeet.safetensors"
N_LAYERS, C, D, DFF, BN_EPS = 24, 256, 1024, 4096, 1e-5

sd = torch.load(CKPT, map_location="cpu", weights_only=False)
def g(n): return sd[n].float().numpy()
def z(*s): return np.zeros(s, np.float32)
out = {}

for i in range(N_LAYERS):
    p, e = f"encoder.layers.{i}.", f"enc.{i}."
    out[e+"ff1.ln.g"]=g(p+"norm_feed_forward1.weight"); out[e+"ff1.ln.b"]=g(p+"norm_feed_forward1.bias")
    out[e+"ff1.w1"]=g(p+"feed_forward1.linear1.weight"); out[e+"ff1.b1"]=z(DFF)
    out[e+"ff1.w2"]=g(p+"feed_forward1.linear2.weight"); out[e+"ff1.b2"]=z(D)
    out[e+"attn.ln.g"]=g(p+"norm_self_att.weight"); out[e+"attn.ln.b"]=g(p+"norm_self_att.bias")
    out[e+"attn.wq"]=g(p+"self_attn.linear_q.weight"); out[e+"attn.bq"]=z(D)
    out[e+"attn.wk"]=g(p+"self_attn.linear_k.weight"); out[e+"attn.bk"]=z(D)
    out[e+"attn.wv"]=g(p+"self_attn.linear_v.weight"); out[e+"attn.bv"]=z(D)
    out[e+"attn.wo"]=g(p+"self_attn.linear_out.weight"); out[e+"attn.bo"]=z(D)
    out[e+"attn.wpos"]=g(p+"self_attn.linear_pos.weight")
    out[e+"attn.u"]=g(p+"self_attn.pos_bias_u").reshape(-1)   # [8,128]->[1024]
    out[e+"attn.v"]=g(p+"self_attn.pos_bias_v").reshape(-1)
    out[e+"conv.ln.g"]=g(p+"norm_conv.weight"); out[e+"conv.ln.b"]=g(p+"norm_conv.bias")
    out[e+"conv.pw1.w"]=g(p+"conv.pointwise_conv1.weight").reshape(2*D, D); out[e+"conv.pw1.b"]=z(2*D)
    out[e+"conv.dw.w"]=g(p+"conv.depthwise_conv.weight").reshape(D, 9);     out[e+"conv.dw.b"]=z(D)
    gw,gb = g(p+"conv.batch_norm.weight"), g(p+"conv.batch_norm.bias")
    rm,rv = g(p+"conv.batch_norm.running_mean"), g(p+"conv.batch_norm.running_var")
    a = gw/np.sqrt(rv+BN_EPS); out[e+"conv.bn.a"]=a; out[e+"conv.bn.b"]=gb-rm*a
    out[e+"conv.pw2.w"]=g(p+"conv.pointwise_conv2.weight").reshape(D, D); out[e+"conv.pw2.b"]=z(D)
    out[e+"ff2.ln.g"]=g(p+"norm_feed_forward2.weight"); out[e+"ff2.ln.b"]=g(p+"norm_feed_forward2.bias")
    out[e+"ff2.w1"]=g(p+"feed_forward2.linear1.weight"); out[e+"ff2.b1"]=z(DFF)
    out[e+"ff2.w2"]=g(p+"feed_forward2.linear2.weight"); out[e+"ff2.b2"]=z(D)
    out[e+"norm.g"]=g(p+"norm_out.weight"); out[e+"norm.b"]=g(p+"norm_out.bias")

pe = "encoder.pre_encode."
out["sub.c0.w"]=g(pe+"conv.0.weight").reshape(C,9); out["sub.c0.b"]=g(pe+"conv.0.bias")
out["sub.dw1.w"]=g(pe+"conv.2.weight").reshape(C,9); out["sub.dw1.b"]=g(pe+"conv.2.bias")
out["sub.pw1.w"]=g(pe+"conv.3.weight").reshape(C,C); out["sub.pw1.b"]=g(pe+"conv.3.bias")
out["sub.dw2.w"]=g(pe+"conv.5.weight").reshape(C,9); out["sub.dw2.b"]=g(pe+"conv.5.bias")
out["sub.pw2.w"]=g(pe+"conv.6.weight").reshape(C,C); out["sub.pw2.b"]=g(pe+"conv.6.bias")
out["sub.proj.w"]=g(pe+"out.weight"); out["sub.proj.b"]=g(pe+"out.bias")

out["feat.window"]=g("preprocessor.featurizer.window")
out["feat.fb"]=g("preprocessor.featurizer.fb").reshape(128, 257)

dp = "decoder.prediction."
out["dec.emb"]=g(dp+"embed.weight")
for l in (0,1):
    out[f"dec.wih{l}"]=g(dp+f"dec_rnn.lstm.weight_ih_l{l}")
    out[f"dec.whh{l}"]=g(dp+f"dec_rnn.lstm.weight_hh_l{l}")
    out[f"dec.b{l}"] =g(dp+f"dec_rnn.lstm.bias_ih_l{l}") + g(dp+f"dec_rnn.lstm.bias_hh_l{l}")
out["joint.wf"]=g("joint.enc.weight");  out["joint.wg"]=g("joint.pred.weight")
out["joint.bj"]=g("joint.enc.bias") + g("joint.pred.bias")
out["joint.wo"]=g("joint.joint_net.2.weight"); out["joint.bo"]=g("joint.joint_net.2.bias")

# ── write safetensors by hand (8-byte header len | JSON header | raw f32 bytes) ──
header, buffers, off = {}, [], 0
for name, arr in out.items():
    b = np.ascontiguousarray(arr, dtype=np.float32).tobytes()
    header[name] = {"dtype":"F32","shape":list(arr.shape),"data_offsets":[off, off+len(b)]}
    off += len(b); buffers.append(b)
hj = json.dumps(header).encode("utf-8")
with open(OUT, "wb") as f:
    f.write(struct.pack("<Q", len(hj))); f.write(hj)
    for b in buffers: f.write(b)
print(f"wrote {len(out)} tensors, {off/1e9:.2f} GB -> {OUT}")
