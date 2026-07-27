#!/usr/bin/env python3
"""Driver for bench/tropical.k — Experiment 1 of doc/research/tropical.md.

Measures per-dispatch time t(N, K) for an elementwise GPU kernel over a grid of
problem sizes and arithmetic intensities, then checks the two predictions the
tropical cost model makes:

    T(N, K) = max( L, 8N/BW, N*w(K)/F )        (max-plus, three monomials)

  * the launch/memory vertex at N* = L*BW/8 — below it t is flat in N,
  * the memory/compute vertex (the roofline ridge) at the K where t stops being
    flat in K and starts rising linearly.

Timing method: each configuration is run at two dispatch counts R and 4R in
separate processes; the difference divided by 3R gives the per-dispatch cost with
process start-up, device creation, the upload and the readback all cancelled.
Each point is the min of --reps runs (min rejects scheduler noise, which is
one-sided).

    usage: python3 bench/tropical.py [--ink ./zig-out/bin/ink] [--reps 2] [--quick]
"""
import argparse, json, subprocess, sys, time

# kernel index -> (family, ops per element); must match bench/tropical.k's FAM/KS
KERNELS = [("f", 1), ("f", 2), ("f", 4), ("f", 8), ("f", 16),
           ("s", 1), ("s", 2), ("s", 4), ("s", 8), ("s", 16)]
SIZES = [1 << e for e in (10, 12, 14, 16, 18, 20, 22, 24)]
BYTES_PER_ELEM = 8          # one f32 read + one f32 write
WORK_BUDGET = 1 << 32       # target elements touched per timed run (caps runtime)
MIN_R = 16                  # below ~16 dispatches the R-difference is all noise


def run(ink, n, ki, r):
  t0 = time.perf_counter()
  p = subprocess.run([ink, "bench/tropical.k", str(n), str(ki), str(r)],
                     capture_output=True, text=True, timeout=600)
  dt = time.perf_counter() - t0
  if "chk=" not in p.stdout:
    raise RuntimeError(f"n={n} ki={ki} r={r} produced no result: "
                       f"{p.stdout[:120]!r} {p.stderr[:200]!r}")
  return dt


def per_dispatch(ink, n, ki, reps):
  """Seconds per dispatch, from the slope between R and 4R."""
  r1 = max(MIN_R, min(4000, WORK_BUDGET // (4 * n)))
  r2 = 4 * r1
  t1 = min(run(ink, n, ki, r1) for _ in range(reps))
  t2 = min(run(ink, n, ki, r2) for _ in range(reps))
  return (t2 - t1) / (r2 - r1), r1


def main():
  ap = argparse.ArgumentParser()
  ap.add_argument("--ink", default="./zig-out/bin/ink")
  ap.add_argument("--reps", type=int, default=2)
  ap.add_argument("--quick", action="store_true", help="3 sizes, 4 kernels")
  ap.add_argument("--json", default=None, help="also write raw points here")
  a = ap.parse_args()

  sizes = [1 << 16, 1 << 20, 1 << 24] if a.quick else SIZES
  kis = [0, 4, 5, 9] if a.quick else list(range(len(KERNELS)))

  pts = {}
  for ki in kis:
    fam, k = KERNELS[ki]
    for n in sizes:
      t, r = per_dispatch(a.ink, n, ki, a.reps)
      pts[(ki, n)] = t
      print(f"  {fam}{k:<3} n=2^{n.bit_length()-1:<2} R={r:<5} "
            f"{t*1e6:9.2f} us/dispatch  {n*BYTES_PER_ELEM/t/1e9:7.1f} GB/s",
            flush=True)

  # ── fit the three monomials ────────────────────────────────────────────────
  # L: the floor — cheapest kernel at the smallest size is pure launch cost.
  L = min(pts[(ki, sizes[0])] for ki in kis)
  # BW: from the cheapest kernel at the largest size (deep in the memory ray).
  nbig = sizes[-1]
  cheap = min(kis, key=lambda ki: KERNELS[ki][1] if KERNELS[ki][0] == "f" else 1e9)
  BW = nbig * BYTES_PER_ELEM / pts[(cheap, nbig)]
  n_star = L * BW / BYTES_PER_ELEM

  print(f"\nfitted   L  = {L*1e6:.2f} us/dispatch (launch floor)")
  print(f"fitted   BW = {BW/1e9:.1f} GB/s (memory ray)")
  import math
  print(f"predict  launch/memory vertex at N* = {n_star:,.0f} elements "
        f"(2^{math.log2(max(n_star,1)):.1f})")

  # measured N knee: smallest size whose time exceeds 2x the floor
  for ki in kis:
    row = [(n, pts[(ki, n)]) for n in sizes]
    knee = next((n for n, t in row if t > 2 * L), None)
    fam, k = KERNELS[ki]
    print(f"measured {fam}{k:<3} N knee (t > 2L): "
          f"{knee if knee else 'none in range'}")

  # measured K ridge, per family, at the largest size
  for fam in ("f", "s"):
    row = [(KERNELS[ki][1], pts[(ki, nbig)]) for ki in kis if KERNELS[ki][0] == fam]
    if len(row) < 2:
      continue
    base = row[0][1]
    ridge = next((k for k, t in row if t > 1.5 * base), None)
    tail = f"   ridge at K={ridge}" if ridge else "   no ridge in range"
    print(f"measured {fam}: t@N=2^{nbig.bit_length()-1} vs K -> "
          + ", ".join(f"K={k}:{t*1e6:.1f}us" for k, t in row) + tail)

  if a.json:
    with open(a.json, "w") as fh:
      json.dump({"points": [{"ki": ki, "fam": KERNELS[ki][0], "k": KERNELS[ki][1],
                             "n": n, "sec": t} for (ki, n), t in pts.items()],
                 "L": L, "BW": BW}, fh, indent=1)
  return 0


if __name__ == "__main__":
  sys.exit(main())
