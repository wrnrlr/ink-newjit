#!/usr/bin/env python3
"""Benchmark lib/nn.k's resident GPU kernels — the ones the Parakeet pipeline runs.

Eight production kernels spanning shapes a synthetic elementwise sweep cannot reach:
reductions per output, shared-memory tiling, and multi-dispatch ops. Indices 8..11
repeat the four params-writing ops with the params write hoisted out of the loop, so
the wrapper-minus-hoisted gap measures per-call host/driver overhead directly. That
comparison is what located the unconditional vkQueueWaitIdle in gpuBufferWrite
(4-7.4x once fixed; see doc/research/tropical.md).

Timing is IN-PROCESS: bench/nnshapes.k brackets the dispatch loop with `t[] inside one
live device session and prints `us=`. Differencing whole-subprocess wall times, which
this driver used to do, buries per-call costs under process start-up and device
creation — it understated that same fix by ~2x.

    usage: python3 bench/nnshapes.py [--ink ./zig-out/bin/ink] [--reps 3] [--quick]
"""
import argparse, json, subprocess, sys

KERNELS = [
  ("gemm",        [64, 128, 512]),
  ("gemmt",       [64, 128, 512]),
  ("silu",        [1 << 16, 1 << 20, 1 << 24]),
  ("gelu",        [1 << 16, 1 << 20, 1 << 24]),
  ("softmax",     [64, 1024, 16384]),
  ("layernorm",   [64, 1024, 16384]),
  ("attnsc",      [64, 128, 512]),
  ("attnctx",     [64, 128, 512]),
  ("softmax-h",   [64, 1024, 16384]),
  ("layernorm-h", [64, 1024, 16384]),
  ("attnsc-h",    [64, 128, 512]),
  ("attnctx-h",   [64, 128, 512]),
]
TARGET_US = 120_000


def run(ink, ki, S, r, reps=3):
  p = subprocess.run([ink, "bench/nnshapes.k", str(ki), str(S), str(r), str(reps)],
                     capture_output=True, text=True, timeout=900)
  for tok in p.stdout.split():
    if tok.startswith("us="):
      return float(tok[3:])
  raise RuntimeError(f"ki={ki} S={S} r={r}: {p.stdout[:150]!r} {p.stderr[:200]!r}")


def per_rep(ink, ki, S, reps):
  """Cheap pilot to learn the scale, then size R for ~120ms per timed block."""
  pilot = run(ink, ki, S, 16, 1)
  r = max(8, min(3000, int(TARGET_US / max(pilot, 1.0))))
  return min(run(ink, ki, S, r, reps) for _ in range(2)), r


def main():
  ap = argparse.ArgumentParser()
  ap.add_argument("--ink", default="./zig-out/bin/ink")
  ap.add_argument("--reps", type=int, default=3)
  ap.add_argument("--quick", action="store_true")
  ap.add_argument("--json", default=None)
  a = ap.parse_args()

  rows = []
  print(f"{'kernel':12} {'S':>7} {'R':>6} {'us/rep':>10}")
  for ki, (name, sizes) in enumerate(KERNELS):
    for S in (sizes[::2] if a.quick else sizes):
      t, r = per_rep(a.ink, ki, S, a.reps)
      rows.append(dict(kernel=name, S=S, us=t))
      print(f"{name:12} {S:>7} {r:>6} {t:9.1f}", flush=True)

  print("\n=== wrapper (writes params each call) vs hoisted ===")
  print(f"{'op':12} {'S':>7} {'wrapper':>10} {'hoisted':>10} {'x slower':>9}")
  by = {(r["kernel"], r["S"]): r["us"] for r in rows}
  for base in ("softmax", "layernorm", "attnsc", "attnctx"):
    for S in [r["S"] for r in rows if r["kernel"] == base]:
      w, h = by.get((base, S)), by.get((base + "-h", S))
      if w and h:
        print(f"{base:12} {S:>7} {w:9.1f}us {h:9.1f}us {w/h:8.2f}x")

  print("\n=== plain vs 8x8-tiled GEMM (identical flops) ===")
  for S in [r["S"] for r in rows if r["kernel"] == "gemm"]:
    p_, t_ = by.get(("gemm", S)), by.get(("gemmt", S))
    if p_ and t_:
      print(f"  S={S:<6} plain {p_:8.1f}us   tiled {t_:8.1f}us   {p_/t_:.2f}x")

  if a.json:
    json.dump(rows, open(a.json, "w"), indent=1)
  return 0


if __name__ == "__main__":
  sys.exit(main())
